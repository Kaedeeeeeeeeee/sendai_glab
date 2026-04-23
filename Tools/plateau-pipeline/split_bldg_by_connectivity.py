"""Blender CLI: split a merged PLATEAU bldg GLB into per-building
pieces, snap each independently to the DEM surface under it, then
merge everything back into a single mesh and export as a single-
object USDZ.

This replaces the earlier "split-and-ship-per-building" output of
Phase 6 (which produced 275-1675 child entities per tile and cost
the device ~4 K draw calls per frame). Phase 6.1 keeps the per-
building alignment precision but moves the snap to offline, so the
runtime sees one merged mesh per tile (5 draw calls total, roughly
the Phase 2-5 draw-call budget) with every building already on its
correct DEM elevation.

Pipeline
--------
1. Import the DEM USDZ — we'll sample it for per-building ground Y.
2. Import the bldg GLB (one merged mesh, nusamai output).
3. Strip materials (runtime reapplies Toon).
4. Weld coincident verts at 1 mm so triangle soup becomes a real
   manifold mesh (critical: without this step the next LOOSE split
   produces one component per triangle, not per building).
5. `mesh.separate(type='LOOSE')` → each connected component becomes
   its own mesh object ≈ one building.
6. For each per-building object:
   - Compute centroid in Blender coords.
   - Map centroid's Miyagi XY to DEM's Blender XY using the envelope
     centres from `plateau_envelopes.json`.
   - Raycast the DEM straight down, pick up the hit elevation.
   - Translate every vertex of the building by the needed Z delta
     so its centroid Z matches the DEM-derived target.
7. Join all per-building meshes back into a single object.
8. Delete the DEM object (we don't ship it from this tile).
9. Export as USDZ — one top-level mesh, no multi-prim hierarchy.

Coordinate mapping refresher
----------------------------
Each CityGML file declares an EPSG:6677 envelope; we have both
bldg and DEM centres in `plateau_envelopes.json`. After nusamai +
glTF import into Blender (Y-up → Z-up):

- Blender X = Miyagi easting
- Blender Y = Miyagi northing
- Blender Z = Miyagi elevation (orthometric)

So converting a bldg-Blender XY to a DEM-Blender XY is just two
scalar offsets:
    dem_X = bldg_X + (bldg_env.east - dem_env.east)
    dem_Y = bldg_Y + (bldg_env.north - dem_env.north)

And the target Blender Z for a building centroid, after sampling
DEM:
    target_Z = dem_hit_Z + (dem_env.elev - bldg_env.elev)

Usage
-----
    blender --background --factory-startup \
      --python Tools/plateau-pipeline/split_bldg_by_connectivity.py \
      -- \
      --input  Resources/Environment/Environment_Sendai_57403617.glb \
      --output Resources/Environment/Environment_Sendai_57403617.usdz \
      --dem-usdz Resources/Environment/Terrain_Sendai_574036_05.usdz \
      --envelope-json Resources/Environment/plateau_envelopes.json \
      --tile-id 57403617 \
      --dem-tile-id 574036_05_dem
"""
from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path

import bpy
from mathutils import Vector  # type: ignore


def parse_post_dashdash_args() -> argparse.Namespace:
    """Parse arguments after the bare `--` separator."""
    if "--" not in sys.argv:
        print("ERROR: script arguments must follow a bare '--' separator",
              file=sys.stderr)
        sys.exit(2)
    script_args = sys.argv[sys.argv.index("--") + 1:]
    parser = argparse.ArgumentParser(
        prog="split_bldg_by_connectivity.py",
        description="Split a merged PLATEAU bldg GLB into per-building "
                    "objects and export as multi-prim USDZ.",
    )
    parser.add_argument("--input",  required=True, help="Input .glb path")
    parser.add_argument("--output", required=True, help="Output .usdz path")
    parser.add_argument(
        "--dem-usdz",
        required=True,
        help="DEM terrain USDZ to sample for per-building ground Y.",
    )
    parser.add_argument(
        "--envelope-json",
        required=True,
        help="plateau_envelopes.json with bldg + DEM tile envelope centres.",
    )
    parser.add_argument(
        "--tile-id",
        required=True,
        help="Building tile id (e.g. '57403617') — key into envelope JSON.",
    )
    parser.add_argument(
        "--dem-tile-id",
        required=True,
        help="DEM tile id (e.g. '574036_05_dem') — key into envelope JSON.",
    )
    return parser.parse_args(script_args)


# ---------------------------------------------------------------------------
# Envelope loading
# ---------------------------------------------------------------------------

def envelope_center(json_path: Path, tile_id: str) -> tuple[float, float, float]:
    """Return the envelope centre (easting, northing, elevation) in m
    for `tile_id` from the manifest JSON produced by
    `Tools/plateau-pipeline/extract_envelopes.py`.
    """
    with json_path.open("r", encoding="utf-8") as f:
        data = json.load(f)
    env = data.get("envelopes", {}).get(tile_id)
    if env is None:
        raise ValueError(f"tile '{tile_id}' not found in {json_path.name}")
    lo = env["lower_corner_m"]
    up = env["upper_corner_m"]
    cx = (lo[0] + up[0]) / 2
    cy = (lo[1] + up[1]) / 2
    cz = (lo[2] + up[2]) / 2
    return (cx, cy, cz)


def reset_scene() -> None:
    """Wipe the default scene so neither cubes nor the previous run
    leak into this conversion.
    """
    bpy.ops.wm.read_factory_settings(use_empty=True)


def import_glb(input_glb: Path) -> None:
    """Import the bldg GLB into the current scene (not resetting).
    Leaves the imported mesh objects selected and the active object
    is one of them.
    """
    bpy.ops.import_scene.gltf(filepath=str(input_glb))


def import_dem_usdz(input_usdz: Path, tag_name: str) -> bpy.types.Object:
    """Import the DEM USDZ and return the resulting mesh object,
    renamed to `tag_name` so later code can tell it apart from
    the building meshes.
    """
    existing = {o.name for o in bpy.data.objects}
    bpy.ops.wm.usd_import(filepath=str(input_usdz))
    new_meshes = [
        o for o in bpy.data.objects
        if o.type == "MESH" and o.name not in existing
    ]
    if not new_meshes:
        raise RuntimeError(f"DEM USDZ {input_usdz} produced no meshes")
    # Expect exactly one mesh from the Phase 4 DEM pipeline.
    dem_obj = new_meshes[0]
    dem_obj.name = tag_name
    return dem_obj


def strip_all_materials() -> None:
    """Drop every material slot on every mesh. The runtime reapplies
    a per-tile Toon material via `ToonMaterialFactory`; keeping the
    baked ones in the USDZ is pure bundle bloat.
    """
    for obj in bpy.data.objects:
        if obj.type != "MESH":
            continue
        while obj.data.materials:
            obj.data.materials.pop(index=0)


def weld_and_split_loose(
    weld_threshold: float = 0.001,
) -> list[bpy.types.Object]:
    """Weld coincident verts, then split each mesh object into its
    connected components.

    ### Why weld first

    nusamai emits PLATEAU LOD2 buildings as triangle soup — each
    triangle owns its own three verts, with no shared edges across
    adjacent triangles. Running `mesh.separate(type='LOOSE')`
    against triangle soup produces one component *per triangle*
    (POC observed 11 603 objects on a ~30 K-triangle spawn tile).

    Welding verts at 1 mm tolerance rebuilds the topology so
    triangles that share a physical edge become connected, and
    "loose parts" then correspond to actual building meshes
    (expected 100–500 per tile).

    ### Why 1 mm threshold

    Tighter than the Phase 4 DEM pipeline's 1 cm because building
    vertex positions are precise to sub-centimetre in LOD2 and we
    don't want to accidentally weld adjacent buildings whose walls
    come within ~1 cm of each other.
    """
    # Snapshot the original mesh objects before we enter edit mode
    # because `separate` mutates `bpy.data.objects` mid-iteration.
    original_meshes = [o for o in bpy.data.objects if o.type == "MESH"]
    if not original_meshes:
        return []

    for obj in original_meshes:
        bpy.ops.object.select_all(action="DESELECT")
        obj.select_set(True)
        bpy.context.view_layer.objects.active = obj
        bpy.ops.object.mode_set(mode="EDIT")
        bpy.ops.mesh.select_all(action="SELECT")
        # 1. Weld coincident verts so triangle soup becomes a real
        #    connected mesh. Uses Blender's `remove_doubles` (aka
        #    merge-by-distance) at a sub-millimetre threshold.
        bpy.ops.mesh.remove_doubles(threshold=weld_threshold)
        # 2. Split by connected components.
        try:
            bpy.ops.mesh.separate(type="LOOSE")
        except RuntimeError as exc:
            # Single-component mesh: separate is a no-op, and Blender
            # reports that as a RuntimeError in older builds. Safe to
            # continue — the mesh stays as one object.
            print(
                f"INFO: mesh.separate returned {exc} on "
                f"{obj.name}; treating as single-component.",
                file=sys.stderr,
            )
        bpy.ops.object.mode_set(mode="OBJECT")

    return [o for o in bpy.data.objects if o.type == "MESH"]


def _centroid_xz(obj: bpy.types.Object) -> Vector:
    """Mean X / Y of the mesh's vertices — used only for sampling the
    DEM footprint. Vertical (Z) handled separately; see
    `snap_building_to_dem`'s foundation-snap policy.
    """
    verts = obj.data.vertices
    if not verts:
        return Vector((0.0, 0.0, 0.0))
    ax = 0.0
    ay = 0.0
    for v in verts:
        ax += v.co.x
        ay += v.co.y
    return Vector((ax / len(verts), ay / len(verts), 0.0))


def _foundation_z(obj: bpy.types.Object) -> float:
    """Return a Z value representing the building's foundation — the
    altitude the DEM should catch. We use the **25th percentile** of
    vertex Z values rather than the strict minimum or a low percentile.

    Rationale: PLATEAU LOD2 ships each building with an *extended*
    ground-surface polygon that drapes 1–5 m below the visible floor
    (basement walls, flared foundation collars, sometimes a whole
    terrace skirt). The minimum or a low percentile (≤10%) lands on
    that skirt — so when we snap "foundation" to the DEM, we snap the
    skirt to DEM, leaving the visible ground floor 1–5 m *above* the
    terrain (the "still flying" symptom).

    The 25th percentile steps past the skirt/basement outliers and
    lands on actual ground-floor wall vertices, so snap puts the
    visible first floor on the DEM. Chosen empirically: device
    playtest showed the 5th percentile still float by ~3–5 m, while
    the 25th sits the visible floor on-terrain for the majority of
    the corridor buildings.

    Tuning knob: if individual tiles come up buried, *lower* this
    (e.g. 15%). If they fly, *raise* it (e.g. 35%). Below ~5% you
    hit the basement skirt again; above ~50% you start anchoring on
    wall mid-height and buildings bury.
    """
    zs = [v.co.z for v in obj.data.vertices]
    if not zs:
        return 0.0
    zs.sort()
    # 25th percentile.
    idx = max(0, int(len(zs) * 0.25) - 1)
    return zs[idx]


# How far below the sampled DEM surface we anchor each building's
# foundation. Rationale: buildings are rigid bodies; on sloped terrain
# (common around Aobayama / Kawauchi), the downslope edge of the
# footprint ends up visibly flying above ground while the upslope edge
# hides behind the terrain mesh. Sinking the whole foundation by a
# small constant trades a barely-perceptible "buried" look on the
# upslope side (occluded by terrain anyway) for a much less noticeable
# gap on the downslope side — net visual improvement.
#
# 0.75 m is the Phase 6.1 iter 4 tuning point: the upslope burial
# stays hidden by DEM occlusion even at the shallowest LOD2 foundation,
# and the downslope float shrinks to a sub-metre gap that reads as
# "foundation slightly planted" rather than "building hovering".
#
# Tuning knob: raise if downslope float is still visible in playtest,
# lower if upslope burial becomes obvious where DEM occlusion is weak
# (e.g. very shallow slopes).
SLOPE_SINK_M: float = 0.75


def snap_building_to_dem(
    building: bpy.types.Object,
    dem_obj: bpy.types.Object,
    bldg_env: tuple[float, float, float],
    dem_env:  tuple[float, float, float],
) -> bool:
    """Shift every vertex of `building` vertically so its **foundation**
    (25th-percentile Z) lands `SLOPE_SINK_M` below the DEM surface at
    the matching Miyagi XY. Foundation-snap beats centroid-snap on
    device because PLATEAU tiles span ~150 m vertically; centre-
    anchoring puts half the building below the DEM (invisibly clipped
    by terrain) and the upper half visibly "flying" above ground. The
    extra sub-metre sink compensates for rigid-body buildings on
    sloped terrain (see `SLOPE_SINK_M` rationale).

    Coordinate chain (see module docstring):
      - Blender X = Miyagi easting
      - Blender Y = Miyagi northing
      - Blender Z = Miyagi elevation
      - Bldg local origin  = bldg envelope centre
      - DEM local origin   = dem  envelope centre

    Returns True on success, False if the DEM doesn't cover the XY
    (raycast misses). A miss means the building's footprint is
    outside the shipped DEM quadrant; we leave it unshifted so the
    runtime can still render it, just with its original nusamai Y.
    """
    xz_centre = _centroid_xz(building)
    foundation_z = _foundation_z(building)

    # bldg_blender → dem_blender (2 scalar offsets on X and Y).
    dx_to_dem = bldg_env[0] - dem_env[0]
    dy_to_dem = bldg_env[1] - dem_env[1]
    dem_x = xz_centre.x + dx_to_dem
    dem_y = xz_centre.y + dy_to_dem

    # Ray down through the DEM in its local frame. DEM object has
    # identity transform after import, so local == world here.
    origin = Vector((dem_x, dem_y, 1000.0))
    direction = Vector((0.0, 0.0, -1.0))
    result, hit_pos, _hit_norm, _hit_idx = dem_obj.ray_cast(
        origin=origin,
        direction=direction,
        distance=2000.0,
    )
    if not result:
        return False

    dem_hit_z = hit_pos.z
    # Target Z in bldg frame for the FOUNDATION vertex:
    #   real_elev = dem_hit_Z + dem_env.Z - SLOPE_SINK_M
    #   bldg_local_Y for that real_elev = real_elev - bldg_env.Z
    target_foundation_z = (
        dem_hit_z + (dem_env[2] - bldg_env[2]) - SLOPE_SINK_M
    )
    delta_z = target_foundation_z - foundation_z

    # Bake the shift into vertex positions so `object.join` doesn't
    # need to reconcile per-object transforms.
    for v in building.data.vertices:
        v.co.z += delta_z
    return True


def snap_all_buildings(
    buildings: list[bpy.types.Object],
    dem_obj: bpy.types.Object,
    bldg_env: tuple[float, float, float],
    dem_env:  tuple[float, float, float],
) -> tuple[int, int]:
    """Loop `snap_building_to_dem` over every building. Returns
    `(snapped, missed)` counts for the summary line.
    """
    snapped = 0
    missed = 0
    for b in buildings:
        if snap_building_to_dem(b, dem_obj, bldg_env, dem_env):
            snapped += 1
        else:
            missed += 1
    return snapped, missed


def join_buildings(buildings: list[bpy.types.Object]) -> bpy.types.Object:
    """Join every building mesh into a single object. Returns the
    join target. We pick the first building as the target and make
    sure it's the active object before calling `object.join`.
    """
    if not buildings:
        raise RuntimeError("join_buildings called with an empty list")
    bpy.ops.object.select_all(action="DESELECT")
    for b in buildings:
        b.select_set(True)
    bpy.context.view_layer.objects.active = buildings[0]
    if len(buildings) > 1:
        bpy.ops.object.join()
    merged = bpy.context.view_layer.objects.active
    merged.name = "bldg_merged"
    return merged


def delete_object(obj: bpy.types.Object) -> None:
    """Remove the DEM object so it isn't exported with the tile."""
    bpy.ops.object.select_all(action="DESELECT")
    obj.select_set(True)
    bpy.context.view_layer.objects.active = obj
    bpy.ops.object.delete()


def rename_for_readability(objects: list[bpy.types.Object]) -> None:
    """Sort by X then Z and rename `bldg_000`, `bldg_001`, … so the
    USDZ prim names are stable and self-describing. Determinism matters
    because the Swift runtime reads children by name for diagnostics.
    """
    def sort_key(obj: bpy.types.Object) -> tuple[float, float]:
        # Blender world centre: use object origin, fall back to AABB
        # centre if the mesh has no transform applied.
        x = obj.location.x
        z = obj.location.z
        return (x, z)

    for idx, obj in enumerate(sorted(objects, key=sort_key)):
        obj.name = f"bldg_{idx:04d}"


def export_usdz(output: Path) -> None:
    """Export the scene as USDZ with every mesh object becoming a
    child prim under `/root`. Mirrors `glb_to_usdz.py`'s kwargs so
    the runtime sees a consistent hierarchy across the two pipelines.
    """
    output.parent.mkdir(parents=True, exist_ok=True)
    export_kwargs = {
        "filepath": str(output),
        "selected_objects_only": False,
        "export_animation": False,
        "export_hair": False,
        "export_uvmaps": True,
        "export_normals": True,
        # Materials are stripped; explicitly disable export so Blender
        # doesn't reintroduce a default.
        "export_materials": False,
        "use_instancing": False,
        "evaluation_mode": "RENDER",
    }
    op = bpy.ops.wm.usd_export
    if hasattr(op, "get_rna_type") and \
       "root_prim_path" in op.get_rna_type().properties.keys():
        export_kwargs["root_prim_path"] = "/root"
    result = bpy.ops.wm.usd_export(**export_kwargs)
    if "FINISHED" not in result:
        raise RuntimeError(f"USD export returned non-finished status: {result}")
    if not output.is_file():
        raise RuntimeError(f"USD export reported success but no file at {output}")


def main() -> int:
    args = parse_post_dashdash_args()
    input_glb = Path(args.input)
    output_usdz = Path(args.output)
    dem_usdz = Path(args.dem_usdz)
    envelope_json = Path(args.envelope_json)

    for required in (input_glb, dem_usdz, envelope_json):
        if not required.is_file():
            print(f"[FAIL] missing input: {required}", file=sys.stderr)
            return 1

    try:
        bldg_env = envelope_center(envelope_json, args.tile_id)
        dem_env = envelope_center(envelope_json, args.dem_tile_id)
    except Exception as exc:  # noqa: BLE001
        print(f"[FAIL] envelope lookup: {exc}", file=sys.stderr)
        return 1

    try:
        reset_scene()
        # DEM first so it's in the scene when we iterate / raycast.
        dem_obj = import_dem_usdz(dem_usdz, tag_name="DEM_SAMPLE")
        # bldg second — weld + split produces one obj per building.
        existing = {o.name for o in bpy.data.objects}
        import_glb(input_glb)
        bldg_meshes_initial = [
            o for o in bpy.data.objects
            if o.type == "MESH" and o.name not in existing
        ]
        before_count = len(bldg_meshes_initial)
        strip_all_materials()

        # `weld_and_split_loose` operates on every mesh in the scene;
        # temporarily hide the DEM so it stays untouched.
        for o in [dem_obj]:
            o.hide_set(True)
            o.hide_select = True
        all_split = weld_and_split_loose()
        for o in [dem_obj]:
            o.hide_set(False)
            o.hide_select = False
        # Keep only the bldg split products (exclude DEM).
        buildings = [o for o in all_split if o.name != dem_obj.name]
        split_count = len(buildings)

        # Phase 6.1: per-building DEM snap. Shifts vertex Z so each
        # building sits on the DEM surface under it.
        snapped, missed = snap_all_buildings(
            buildings, dem_obj, bldg_env, dem_env
        )

        # Merge everything back into one mesh — this is the perf win
        # over Phase 6: RealityKit sees one ModelComponent per tile
        # instead of thousands.
        merged = join_buildings(buildings)
        # After join, `buildings` names are now invalid; rename the
        # single result for readable USDZ prims.
        merged.name = "bldg"
        rename_for_readability([merged])

        # Ship only the merged bldg mesh, not the DEM.
        delete_object(dem_obj)
        export_usdz(output_usdz)
    except Exception as exc:  # noqa: BLE001
        print(f"[FAIL] split+snap+merge: {exc}", file=sys.stderr)
        return 1

    if split_count == 0:
        print(
            f"[FAIL] split produced zero building objects from "
            f"{input_glb.name}",
            file=sys.stderr,
        )
        return 1

    size_kb = output_usdz.stat().st_size / 1024
    print(
        f"[OK] {input_glb.name} -> {output_usdz.name}  "
        f"initial_meshes {before_count} split {split_count} "
        f"snapped {snapped} missed {missed} merged → 1 mesh  "
        f"{size_kb:,.0f} KB"
    )
    if missed > 0:
        print(
            f"[WARN] {missed} building(s) had no DEM coverage — "
            "they were left at nusamai's original Y.",
            file=sys.stderr,
        )
    return 0


if __name__ == "__main__":
    sys.exit(main())
