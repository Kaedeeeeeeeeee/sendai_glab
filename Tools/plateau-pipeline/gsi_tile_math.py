#!/usr/bin/env python3
"""gsi_tile_math.py — Tools/plateau-pipeline

Tiny helper used by `download_gsi_ortho.sh` to:

1. Convert the PLATEAU DEM envelope (EPSG:6677 m) to WGS84 lat/lon.
2. Compute the XYZ slippy-tile range at a given zoom covering that
   bounding box for the GSI WMTS endpoint.
3. (When called with the ``stitch`` subcommand) stitch the downloaded
   tiles into a single JPG mosaic and crop to the exact envelope.

## Why a separate Python helper (not inline bash/awk)

The slippy-tile math involves ``log / tan`` at double precision plus a
CRS reprojection. ``awk`` has no projection library and bash has no
floating-point math out of the box. pyproj is already pulled in for
Phase 4's ``extract_envelopes.py``, so reusing it here costs nothing and
keeps the correctness story obvious.

## GSI WMTS endpoint

Tiles come from:

    https://cyberjapandata.gsi.go.jp/xyz/seamlessphoto/{z}/{x}/{y}.jpg

At zoom 17 each tile is 256 px of imagery at roughly 1.2 m/px around
Sendai (38°N — Mercator makes tiles slightly denser as latitude rises).
For a 2.5 km × 2.5 km corridor that is ~7 × 6 tiles (~6 MB raw).

## CC BY 4.0

GSI seamlessphoto (全国最新写真シームレス) imagery is licensed under
CC BY 4.0. **The credit string "国土地理院 (Geospatial Information
Authority of Japan)" must appear in the user-visible credits** of any
shipped build. ADR-0012 (to be authored by the main agent as part of
Phase 11) should record the exact attribution text. This file exists
only to fetch + mosaic the imagery — surfacing the credit in-game is
the Swift/UI layer's responsibility.

See also https://maps.gsi.go.jp/development/ichiran.html for the list of
available GSI layers and their terms of use.
"""

from __future__ import annotations

import argparse
import json
import math
import sys
from dataclasses import dataclass
from pathlib import Path
from typing import Final


TILE_SIZE_PX: Final = 256


@dataclass(frozen=True)
class TileRange:
    """The XYZ tile range covering a WGS84 bounding box at a given zoom.

    Edges are inclusive on both ends — ``min_x..=max_x`` and
    ``min_y..=max_y``. `count` returns how many tiles the range implies,
    which is what the download loop iterates over.
    """

    z: int
    min_x: int
    max_x: int
    min_y: int
    max_y: int

    @property
    def count(self) -> int:
        return (self.max_x - self.min_x + 1) * (self.max_y - self.min_y + 1)

    @property
    def width_tiles(self) -> int:
        return self.max_x - self.min_x + 1

    @property
    def height_tiles(self) -> int:
        return self.max_y - self.min_y + 1


def _lonlat_to_tile_xy(lon_deg: float, lat_deg: float, zoom: int) -> tuple[int, int]:
    """Convert WGS84 lon/lat to integer XYZ tile coords at ``zoom``.

    This is the standard slippy-map projection (Web Mercator, tile ``y``
    grows *southward*). Formulas per OSM:
    https://wiki.openstreetmap.org/wiki/Slippy_map_tilenames
    """
    # Clamp latitude to Mercator's domain (~85.05 deg) — above that
    # tan(phi) blows up. GSI doesn't serve the poles anyway.
    lat_rad = math.radians(max(-85.05112878, min(85.05112878, lat_deg)))
    n = 2.0 ** zoom
    x = int((lon_deg + 180.0) / 360.0 * n)
    y = int((1.0 - math.asinh(math.tan(lat_rad)) / math.pi) / 2.0 * n)
    # Clamp into valid tile index range; Mercator singularities and
    # off-by-ones at integer boundaries otherwise produce x == n.
    x = max(0, min(int(n) - 1, x))
    y = max(0, min(int(n) - 1, y))
    return x, y


def _tile_xy_to_lonlat(x: int, y: int, zoom: int) -> tuple[float, float]:
    """Convert an integer tile's NW corner back to WGS84 lon/lat.

    The inverse of `_lonlat_to_tile_xy`. Used by the stitcher to
    compute the exact pixel offset of the envelope's NW corner inside
    the assembled mosaic.
    """
    n = 2.0 ** zoom
    lon_deg = x / n * 360.0 - 180.0
    lat_rad = math.atan(math.sinh(math.pi * (1.0 - 2.0 * y / n)))
    lat_deg = math.degrees(lat_rad)
    return lon_deg, lat_deg


def _load_dem_envelope(manifest_path: Path, tile_key: str) -> tuple[float, float, float, float]:
    """Read ``lower_corner_m`` / ``upper_corner_m`` for ``tile_key`` in
    EPSG:6677 (x_east_m, y_north_m, z_m). Returns ``(x_min, y_min,
    x_max, y_max)`` metres. Raises if the manifest or key is missing.
    """
    with manifest_path.open("r", encoding="utf-8") as f:
        manifest = json.load(f)
    envelopes = manifest.get("envelopes", {})
    if tile_key not in envelopes:
        raise KeyError(
            f"Envelope manifest {manifest_path} does not contain `{tile_key}`. "
            f"Available: {sorted(envelopes.keys())}"
        )
    entry = envelopes[tile_key]
    lower = entry["lower_corner_m"]
    upper = entry["upper_corner_m"]
    return float(lower[0]), float(lower[1]), float(upper[0]), float(upper[1])


def _bbox_6677_to_wgs84(
    x_min: float, y_min: float, x_max: float, y_max: float
) -> tuple[float, float, float, float]:
    """Reproject an EPSG:6677 bbox to WGS84.

    Returns ``(lon_min, lat_min, lon_max, lat_max)``. pyproj is imported
    lazily so this file remains importable for sanity checks on hosts
    without pyproj installed (the ``tilerange`` subcommand uses it; the
    unit-style helpers above do not).
    """
    try:
        from pyproj import Transformer
    except ImportError as exc:  # pragma: no cover — install-time failure
        raise RuntimeError(
            "pyproj is required for CRS reprojection. "
            "Install via `python3 -m pip install pyproj` "
            "(same dependency the Phase 4 extract_envelopes.py already uses)."
        ) from exc

    # EPSG:6677 axis order is (x_easting, y_northing) in metres.
    # EPSG:4326 (WGS84) with always_xy=True → (lon, lat).
    t = Transformer.from_crs("EPSG:6677", "EPSG:4326", always_xy=True)
    # Convert all four corners; lat/lon min-max is not axis-aligned with
    # the projected bbox in general, so we sample all four and take the
    # extents.
    lons, lats = t.transform(
        [x_min, x_max, x_min, x_max],
        [y_min, y_min, y_max, y_max],
    )
    return min(lons), min(lats), max(lons), max(lats)


# --- Subcommands -----------------------------------------------------


def _cmd_tilerange(args: argparse.Namespace) -> int:
    x_min, y_min, x_max, y_max = _load_dem_envelope(
        Path(args.manifest), args.tile_key
    )
    lon_min, lat_min, lon_max, lat_max = _bbox_6677_to_wgs84(
        x_min, y_min, x_max, y_max
    )

    # NW tile → (min_x, min_y). SE tile → (max_x, max_y). Slippy Y grows
    # SOUTH, so the *north* latitude (lat_max) maps to the *smaller* Y.
    nw_x, nw_y = _lonlat_to_tile_xy(lon_min, lat_max, args.zoom)
    se_x, se_y = _lonlat_to_tile_xy(lon_max, lat_min, args.zoom)
    tr = TileRange(
        z=args.zoom,
        min_x=min(nw_x, se_x),
        max_x=max(nw_x, se_x),
        min_y=min(nw_y, se_y),
        max_y=max(nw_y, se_y),
    )

    # Print as shell-parseable KEY=VALUE lines so `download_gsi_ortho.sh`
    # can `eval` the output into local variables without juggling JSON.
    print(f"Z={tr.z}")
    print(f"MIN_X={tr.min_x}")
    print(f"MAX_X={tr.max_x}")
    print(f"MIN_Y={tr.min_y}")
    print(f"MAX_Y={tr.max_y}")
    print(f"COUNT={tr.count}")
    print(f"WIDTH_TILES={tr.width_tiles}")
    print(f"HEIGHT_TILES={tr.height_tiles}")
    print(f"LON_MIN={lon_min:.9f}")
    print(f"LAT_MIN={lat_min:.9f}")
    print(f"LON_MAX={lon_max:.9f}")
    print(f"LAT_MAX={lat_max:.9f}")
    return 0


def _cmd_stitch(args: argparse.Namespace) -> int:
    """Stitch downloaded tiles into a single JPG mosaic, crop to the
    envelope's lat/lon bbox, then downscale.

    PIL (Pillow) is imported lazily because it is the only external
    dependency this subcommand has, and the ``tilerange`` subcommand
    doesn't need it.
    """
    try:
        from PIL import Image
    except ImportError as exc:  # pragma: no cover — install-time failure
        raise RuntimeError(
            "Pillow is required to stitch tiles. "
            "Install via `python3 -m pip install Pillow`."
        ) from exc

    x_min, y_min, x_max, y_max = _load_dem_envelope(
        Path(args.manifest), args.tile_key
    )
    lon_min, lat_min, lon_max, lat_max = _bbox_6677_to_wgs84(
        x_min, y_min, x_max, y_max
    )
    nw_x, nw_y = _lonlat_to_tile_xy(lon_min, lat_max, args.zoom)
    se_x, se_y = _lonlat_to_tile_xy(lon_max, lat_min, args.zoom)
    tr = TileRange(
        z=args.zoom,
        min_x=min(nw_x, se_x),
        max_x=max(nw_x, se_x),
        min_y=min(nw_y, se_y),
        max_y=max(nw_y, se_y),
    )

    tiles_dir = Path(args.tiles_dir)
    full_w = tr.width_tiles * TILE_SIZE_PX
    full_h = tr.height_tiles * TILE_SIZE_PX
    # "RGB" not "RGBA" — GSI orthophoto is a JPG (no alpha). Fill blanks
    # with a neutral grey so any 404 during download shows up as visible
    # patches in the mosaic rather than a pure-black hole.
    mosaic = Image.new("RGB", (full_w, full_h), (128, 128, 128))

    missing: list[tuple[int, int]] = []
    for ty in range(tr.min_y, tr.max_y + 1):
        for tx in range(tr.min_x, tr.max_x + 1):
            tile_path = tiles_dir / f"{tr.z}_{tx}_{ty}.jpg"
            if not tile_path.is_file():
                missing.append((tx, ty))
                continue
            try:
                with Image.open(tile_path) as img:
                    img.load()  # eagerly decode before paste
                    dx = (tx - tr.min_x) * TILE_SIZE_PX
                    dy = (ty - tr.min_y) * TILE_SIZE_PX
                    # Convert to RGB defensively — some GSI responses
                    # return palette-mode JPGs for cloud-heavy regions.
                    if img.mode != "RGB":
                        img = img.convert("RGB")
                    mosaic.paste(img, (dx, dy))
            except OSError as exc:
                print(
                    f"[gsi-stitch] warn: could not decode {tile_path}: {exc}",
                    file=sys.stderr,
                )
                missing.append((tx, ty))

    if missing:
        print(
            f"[gsi-stitch] warn: {len(missing)} tile(s) missing or corrupt; "
            "neutral grey placeholder used. Re-run the downloader to fetch them.",
            file=sys.stderr,
        )

    # Compute pixel coordinates of the exact envelope corners so the
    # crop matches the DEM footprint (otherwise the mosaic overshoots
    # into the neighbouring tile rows by up to one tile on each side).
    # We compute the lon/lat of the NW corner of the NW tile and use
    # the Mercator projection's linearity in lon (but not lat) to place
    # the envelope edges.
    nw_tile_lon, nw_tile_lat = _tile_xy_to_lonlat(tr.min_x, tr.min_y, tr.z)
    se_tile_lon, se_tile_lat = _tile_xy_to_lonlat(
        tr.max_x + 1, tr.max_y + 1, tr.z
    )

    def lon_to_px(lon: float) -> float:
        return (lon - nw_tile_lon) / (se_tile_lon - nw_tile_lon) * full_w

    def lat_to_px(lat: float) -> float:
        # Mercator Y: use the Y-tile projection directly rather than a
        # linear lat interpolation (lat → Y is non-linear far from the
        # equator). Reusing the same projection the downloader uses
        # keeps the cropping exact.
        n = 2.0 ** tr.z
        lat_rad = math.radians(max(-85.05112878, min(85.05112878, lat)))
        y_frac = (1.0 - math.asinh(math.tan(lat_rad)) / math.pi) / 2.0 * n
        # Pixel offset from the top of the mosaic.
        return (y_frac - tr.min_y) * TILE_SIZE_PX

    crop_left = lon_to_px(lon_min)
    crop_right = lon_to_px(lon_max)
    crop_top = lat_to_px(lat_max)  # lat_max is NORTH → smaller Y
    crop_bottom = lat_to_px(lat_min)

    # PIL wants integer pixel coords. Round outward so we never crop
    # *inside* the envelope.
    crop_box = (
        max(0, int(math.floor(crop_left))),
        max(0, int(math.floor(crop_top))),
        min(full_w, int(math.ceil(crop_right))),
        min(full_h, int(math.ceil(crop_bottom))),
    )
    cropped = mosaic.crop(crop_box)

    # Downscale to the requested side (default 1024). A 2.5 km × 2.5 km
    # envelope at zoom 17 is ~2048 × ~1600 raw pixels; 1024 preserves
    # ~1 building-width per 2 px which is plenty for a DEM drape.
    target = args.downscale
    if target > 0:
        cropped.thumbnail((target, target), Image.LANCZOS)

    out_path = Path(args.output)
    out_path.parent.mkdir(parents=True, exist_ok=True)
    # quality=85 is the sweet spot for ortho JPG: visibly ~identical to
    # 95 but ~35% smaller. Higher hurts the bundle with no visual gain.
    cropped.save(out_path, format="JPEG", quality=85, optimize=True)

    final_size = out_path.stat().st_size
    print(
        f"[gsi-stitch] wrote {out_path} "
        f"({cropped.size[0]}×{cropped.size[1]} px, "
        f"{final_size / 1024:.0f} KB, "
        f"{tr.count} tile(s) stitched, {len(missing)} missing)"
    )
    return 0


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(
        prog="gsi_tile_math.py",
        description="GSI slippy-tile math + orthophoto mosaic stitcher.",
    )
    sub = parser.add_subparsers(dest="cmd", required=True)

    p_range = sub.add_parser(
        "tilerange",
        help=(
            "Print KEY=VALUE lines describing the XYZ tile range "
            "covering a PLATEAU DEM envelope at a given zoom."
        ),
    )
    p_range.add_argument("--manifest", required=True)
    p_range.add_argument("--tile-key", required=True)
    p_range.add_argument("--zoom", type=int, required=True)
    p_range.set_defaults(func=_cmd_tilerange)

    p_stitch = sub.add_parser(
        "stitch",
        help=(
            "Stitch previously-downloaded tiles into a mosaic JPG, "
            "crop to the envelope, and downscale."
        ),
    )
    p_stitch.add_argument("--manifest", required=True)
    p_stitch.add_argument("--tile-key", required=True)
    p_stitch.add_argument("--zoom", type=int, required=True)
    p_stitch.add_argument("--tiles-dir", required=True)
    p_stitch.add_argument("--output", required=True)
    p_stitch.add_argument(
        "--downscale",
        type=int,
        default=1024,
        help="Max side length in pixels (0 = no downscale). Default 1024.",
    )
    p_stitch.set_defaults(func=_cmd_stitch)

    args = parser.parse_args(argv)
    return args.func(args)


if __name__ == "__main__":
    sys.exit(main())
