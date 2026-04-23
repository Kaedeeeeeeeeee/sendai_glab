#!/usr/bin/env python3
"""extract_envelopes.py — Tools/plateau-pipeline

Parse <gml:Envelope> metadata out of the 5 PLATEAU bldg CityGML tiles
(plus the one DEM GML) and emit a sidecar JSON manifest in EPSG:6677
coordinates so the Swift runtime can place each entity using real-world
geography.

Why this exists
---------------
nusamai 0.1.0 (and current revisions) centers every gltf output on its
own AABB, destroying the real-world origin of each tile. That leaves
the 5 building USDZs and the DEM USDZ all claiming (0,0,0) in their
local frames with no metadata to reconstruct their relative position.

The CityGML source files we feed nusamai still carry the source-of-truth
envelope in their XML header (``<gml:boundedBy><gml:Envelope>``). By
extracting that header *before* nusamai flattens the geometry we recover
the information the loader needs to align every tile in the same
coordinate frame at load time.

Coordinate frame notes
----------------------
* Source CRS: EPSG:6697 — JGD2011 (lat, lon, ellipsoidal height). Axis
  order is ``(lat, lon, h)``.
* Target CRS: EPSG:6677 — JGD2011 / Japan Plane Rectangular CS zone IX
  (Northing_m, Easting_m). Origin is 36°N / 139°50'E, so Sendai sits
  roughly 250 km north and 85 km east of that origin.
* pyproj's ``always_xy=False`` transformer obeys each CRS's declared
  axis order. For 6697→6677 that means ``transform(lat, lon)`` returns
  ``(northing, easting)``. We reorder to ``(easting, northing)`` in the
  JSON output so consumers can treat the first two components of
  ``*_corner_m`` as ``(x, y)`` without juggling zone conventions.

Output schema
-------------
See the JSON below. ``lower_corner_m`` / ``upper_corner_m`` are stored
as ``[x_easting_m, y_northing_m, z_elevation_m]`` triples. The DEM tile
is keyed as ``574036_05_dem`` to mirror the USDZ filename convention
(``Terrain_Sendai_574036_05.usdz``).

See also
--------
* ADR-0006 "DEM alignment deferred to Phase 4" for the original
  failure modes that motivate this approach.
* Docs/plans/push-modle-plateau-chrome-subagent-nested-rain.md for the
  Phase 4 design.
"""

from __future__ import annotations

import argparse
import datetime as _dt
import json
import math
import sys
import xml.etree.ElementTree as ET
from dataclasses import dataclass
from pathlib import Path
from typing import Final, Optional

# --- Constants --------------------------------------------------------

GML_NS: Final = "http://www.opengis.net/gml"
SOURCE_CRS: Final = "EPSG:6697"
TARGET_CRS: Final = "EPSG:6677"
SPAWN_TILE_ID: Final = "57403617"

# The bldg tiles we ship today. Order is preserved in the JSON to aid
# diffs but consumers should key by tile ID.
BLDG_TILE_IDS: Final = (
    "57403607",
    "57403608",
    "57403617",
    "57403618",
    "57403619",
)

# Sanity threshold. The Miyagi/Sendai area is ~250 km north and ~85 km
# east of the EPSG:6677 zone IX origin (36°N, 139°50'E), so the spawn
# center's distance from (0,0) lives around 260-270 km. An axis-order
# bug would instead produce values in the 10^6 m range (lat/lon
# interpreted as meters) or otherwise implausible magnitudes. We flag
# anything beyond 500 km as "almost certainly wrong" rather than the
# tighter 100 km bound that the plan initially assumed, because the
# plan's threshold predates confirming that EPSG:6677 is zone IX.
MAX_SPAWN_OFFSET_M: Final = 500_000.0

# Per-tile elevation plausibility (Sendai topography: sea level to
# Aobayama ridge around ~200 m). 500 m leaves headroom for rooftops.
ELEVATION_MIN_M: Final = -10.0
ELEVATION_MAX_M: Final = 500.0


@dataclass(frozen=True)
class _Envelope:
    """Raw envelope values in the source CRS (lat, lon, height)."""

    lower_lat: float
    lower_lon: float
    lower_h: float
    upper_lat: float
    upper_lon: float
    upper_h: float


# --- Parsing ----------------------------------------------------------


def _find_root_envelope(gml_path: Path) -> _Envelope:
    """Return the document-scope ``<gml:Envelope>`` values for ``gml_path``.

    The CityGML files we ship contain many nested envelopes at feature
    level (per Building, per ReliefFeature, ...). Only the root-level
    ``boundedBy`` inside ``<core:CityModel>`` spans the full tile — that
    is the one we want. We walk just the direct children of the root
    rather than using ``findall(...)`` with a deep path, which would
    match the first nested envelope in document order.
    """
    tree = ET.parse(str(gml_path))
    root = tree.getroot()
    bounded_tag = f"{{{GML_NS}}}boundedBy"
    envelope_tag = f"{{{GML_NS}}}Envelope"

    for child in root:
        if child.tag != bounded_tag:
            continue
        envelope = child.find(envelope_tag)
        if envelope is None:
            continue
        return _parse_envelope_element(envelope, gml_path)

    raise RuntimeError(
        f"no root-level <gml:boundedBy><gml:Envelope> found in {gml_path}"
    )


def _parse_envelope_element(envelope: ET.Element, gml_path: Path) -> _Envelope:
    srs = envelope.get("srsName", "")
    if "6697" not in srs:
        raise RuntimeError(
            f"{gml_path}: expected srsName containing 'EPSG/0/6697', got {srs!r}"
        )

    lower = envelope.find(f"{{{GML_NS}}}lowerCorner")
    upper = envelope.find(f"{{{GML_NS}}}upperCorner")
    if lower is None or upper is None or not lower.text or not upper.text:
        raise RuntimeError(
            f"{gml_path}: Envelope missing lowerCorner/upperCorner text"
        )

    low = [float(v) for v in lower.text.split()]
    upp = [float(v) for v in upper.text.split()]
    if len(low) != 3 or len(upp) != 3:
        raise RuntimeError(
            f"{gml_path}: expected 3-component corners (lat lon h); got "
            f"{low!r} / {upp!r}"
        )
    return _Envelope(
        lower_lat=low[0],
        lower_lon=low[1],
        lower_h=low[2],
        upper_lat=upp[0],
        upper_lon=upp[1],
        upper_h=upp[2],
    )


# --- Projection -------------------------------------------------------


def _make_transformer():  # type: ignore[no-untyped-def]
    """Build the EPSG:6697 → EPSG:6677 transformer.

    Wrapped in a function so the ``pyproj`` import failure maps to a
    clean message instead of a crash at module-import time when someone
    just runs ``--help``.
    """
    try:
        import pyproj  # type: ignore[import-untyped]
    except ImportError:
        print("[error] pyproj not installed — run: pip3 install pyproj",
              file=sys.stderr)
        sys.exit(1)

    transformer = pyproj.Transformer.from_crs(
        SOURCE_CRS, TARGET_CRS, always_xy=False
    )

    # Sanity probe: 38.25°N, 140.8125°E is the south-west corner of the
    # DEM tile (574036_05). In EPSG:6677 zone IX this must land within
    # (±1000 km) of origin. A swapped-axis transformer would return
    # ``(inf, inf)`` or wildly off values.
    probe_n, probe_e = transformer.transform(38.25, 140.8125)
    if not (math.isfinite(probe_n) and math.isfinite(probe_e)):
        raise RuntimeError(
            "[fatal] pyproj transformer returned non-finite output for a "
            "known-good Sendai coordinate (38.25, 140.8125). Axis-order "
            "mismatch likely."
        )
    return transformer


def _project_corner(
    transformer, lat: float, lon: float, h: float  # type: ignore[no-untyped-def]
) -> tuple[float, float, float]:
    """Project one (lat, lon, h) → (x_easting_m, y_northing_m, z_m).

    The transformer's native output for 6697→6677 is
    ``(northing, easting)`` (EPSG:6677 axis order is ``X=Northing,
    Y=Easting``). We flip to ``(easting, northing)`` here so every
    downstream "first component = X/east" convention holds without the
    consumer needing to know about Japan Plane Rectangular axis order.
    Elevation passes through unchanged since both CRSs use metres for
    Z and reference the same vertical datum.
    """
    northing, easting = transformer.transform(lat, lon)
    return (easting, northing, h)


# --- Manifest assembly ------------------------------------------------


@dataclass(frozen=True)
class _ManifestEntry:
    lower_corner_m: tuple[float, float, float]
    upper_corner_m: tuple[float, float, float]

    @property
    def center_m(self) -> tuple[float, float, float]:
        return (
            (self.lower_corner_m[0] + self.upper_corner_m[0]) / 2.0,
            (self.lower_corner_m[1] + self.upper_corner_m[1]) / 2.0,
            (self.lower_corner_m[2] + self.upper_corner_m[2]) / 2.0,
        )


def _build_entry(envelope: _Envelope, transformer) -> _ManifestEntry:  # type: ignore[no-untyped-def]
    lower = _project_corner(
        transformer, envelope.lower_lat, envelope.lower_lon, envelope.lower_h
    )
    upper = _project_corner(
        transformer, envelope.upper_lat, envelope.upper_lon, envelope.upper_h
    )
    return _ManifestEntry(lower_corner_m=lower, upper_corner_m=upper)


# --- Sanity checks ----------------------------------------------------


def _run_sanity_checks(manifest: dict[str, _ManifestEntry]) -> None:
    spawn = manifest.get(SPAWN_TILE_ID)
    if spawn is None:
        raise RuntimeError(f"spawn tile {SPAWN_TILE_ID} missing from manifest")
    cx, cy, cz = spawn.center_m
    offset = math.hypot(cx, cy)
    print(
        f"[sanity] spawn center = ({cx:.1f}, {cy:.1f}) meters, "
        f"|offset| = {offset / 1000.0:.2f} km"
    )
    if offset > MAX_SPAWN_OFFSET_M:
        raise RuntimeError(
            f"[fatal] spawn tile center is {offset / 1000.0:.1f} km from "
            f"EPSG:6677 origin — this is beyond the plausible "
            f"{MAX_SPAWN_OFFSET_M / 1000.0:.0f} km envelope for Sendai; "
            "pyproj axis-order bug suspected."
        )

    for tile_id in BLDG_TILE_IDS:
        entry = manifest[tile_id]
        _, _, center_z = entry.center_m
        if not (ELEVATION_MIN_M <= center_z <= ELEVATION_MAX_M):
            raise RuntimeError(
                f"[fatal] tile {tile_id} center elevation {center_z:.1f} m "
                f"is outside the plausible Sendai range "
                f"[{ELEVATION_MIN_M}, {ELEVATION_MAX_M}] m"
            )


# --- Serialization ----------------------------------------------------


def _serialize(
    manifest: dict[str, _ManifestEntry],
    out_path: Path,
    generator_rel_path: str,
) -> None:
    envelopes: dict[str, dict[str, list[float]]] = {}
    for key, entry in manifest.items():
        envelopes[key] = {
            "lower_corner_m": [round(v, 4) for v in entry.lower_corner_m],
            "upper_corner_m": [round(v, 4) for v in entry.upper_corner_m],
        }

    doc = {
        "meta": {
            "source_crs": SOURCE_CRS,
            "target_crs": TARGET_CRS,
            "spawn_tile_id": SPAWN_TILE_ID,
            "generated_by": generator_rel_path,
            "generated_at": _dt.datetime.now(_dt.timezone.utc)
            .isoformat(timespec="seconds")
            .replace("+00:00", "Z"),
        },
        "envelopes": envelopes,
    }

    out_path.parent.mkdir(parents=True, exist_ok=True)
    with out_path.open("w", encoding="utf-8") as fh:
        json.dump(doc, fh, ensure_ascii=False, indent=2)
        fh.write("\n")


# --- CLI --------------------------------------------------------------


def _default_paths(repo_root: Path) -> tuple[dict[str, Path], Path, Path]:
    """Return (gml_sources, dem_gml, output_json) for the shipping layout.

    Kept close to the caller so arg parsing can override any piece and so
    tests (or future agents) can re-use the mapping.
    """
    pipeline = repo_root / "Tools" / "plateau-pipeline"
    bldg_dir = pipeline / "input" / "extracted" / "udx" / "bldg"
    dem_gml = (
        pipeline
        / "input"
        / "extracted"
        / "udx"
        / "dem"
        / "574036_dem_6697_05_op.gml"
    )
    sources = {
        tile_id: bldg_dir / f"{tile_id}_bldg_6697_op.gml"
        for tile_id in BLDG_TILE_IDS
    }
    out = repo_root / "Resources" / "Environment" / "plateau_envelopes.json"
    return sources, dem_gml, out


def _parse_args(argv: Optional[list[str]] = None) -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description=(
            "Extract PLATEAU CityGML envelope metadata, project to "
            "EPSG:6677, and emit plateau_envelopes.json."
        ),
    )
    # Repo root defaults to two levels up from this script
    # (Tools/plateau-pipeline/ → repo root).
    default_root = Path(__file__).resolve().parent.parent.parent
    parser.add_argument(
        "--repo-root",
        type=Path,
        default=default_root,
        help=f"Project root (default: {default_root})",
    )
    parser.add_argument(
        "--output",
        type=Path,
        default=None,
        help=(
            "Override output JSON path "
            "(default: Resources/Environment/plateau_envelopes.json)"
        ),
    )
    return parser.parse_args(argv)


def main(argv: Optional[list[str]] = None) -> int:
    args = _parse_args(argv)
    repo_root = args.repo_root.resolve()
    sources, dem_gml, default_out = _default_paths(repo_root)
    out_path = (args.output.resolve() if args.output else default_out)

    missing: list[Path] = [p for p in (*sources.values(), dem_gml) if not p.exists()]
    if missing:
        msg = "\n".join(f"  - {p}" for p in missing)
        print(
            "[error] missing source GML files (run "
            "extract_bldg_gmls.sh and convert_terrain_dem.sh first):\n"
            + msg,
            file=sys.stderr,
        )
        return 1

    transformer = _make_transformer()

    manifest: dict[str, _ManifestEntry] = {}
    for tile_id, path in sources.items():
        envelope = _find_root_envelope(path)
        manifest[tile_id] = _build_entry(envelope, transformer)

    dem_envelope = _find_root_envelope(dem_gml)
    manifest["574036_05_dem"] = _build_entry(dem_envelope, transformer)

    _run_sanity_checks(manifest)

    generator_rel = "Tools/plateau-pipeline/extract_envelopes.py"
    _serialize(manifest, out_path, generator_rel)

    print(f"[ok] wrote {out_path.relative_to(repo_root)}")
    for key, entry in manifest.items():
        cx, cy, cz = entry.center_m
        print(f"  {key}: center = ({cx:.1f}, {cy:.1f}, {cz:.2f}) m")

    return 0


if __name__ == "__main__":
    sys.exit(main())
