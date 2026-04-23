"""Blender CLI: split a merged PLATEAU bldg GLB into per-building
objects (one per connected mesh component) and export as a multi-
prim USDZ that RealityKit can descend with `entity.children`.

Why this exists
---------------
PLATEAU LOD2 tiles come out of nusamai as a single merged mesh per
tile. That merged mesh stretches ~150 m vertically across the whole
tile (hilltop buildings + valley buildings + basement geometry all
in one AABB). Runtime per-tile alignment ("Phase 5") can only snap
the whole mesh as a rigid body, so buildings at the tile's high end
or low end inevitably float or bury relative to the DEM surface
under them.

Phase 6 fixes this by turning each building into its own RealityKit
child entity. The runtime then snaps each building independently
(see `PlateauEnvironmentLoader.adaptiveGroundSnap`). The split here
is a connected-component pass: PLATEAU LOD2 buildings are typically
closed, non-touching meshes, so "loose parts" in Blender ≈ one per
building.

Usage
-----
    blender --background --factory-startup \
        --python Tools/plateau-pipeline/split_bldg_by_connectivity.py \
        -- \
        --input  Resources/Environment/Environment_Sendai_57403617.glb \
        --output Resources/Environment/Environment_Sendai_57403617.usdz

Pipeline
--------
1. Import the GLB (one merged mesh object expected).
2. Strip materials — the runtime's `ToonMaterialFactory` recolours
   each tile, so per-building material bakes would be wasted bytes.
3. Enter edit mode, select-all, `mesh.separate(type='LOOSE')`, exit.
4. Each resulting object is one building (approximately).
5. Export USDZ with `selected_objects_only: False` and
   `root_prim_path: "/root"` so every object becomes a child prim
   under `/root`.

Safety
------
- If the split produces zero objects (imported mesh had zero loose
  parts, i.e. one fully-welded mesh) the script exits non-zero with
  a diagnostic — the downstream runtime relies on the split working.
- Extreme over-split (> 5000 objects per tile) is logged but still
  exported; the runtime snap loop is O(N) so even 5 K per-tile is
  fine on M-series devices.
"""
from __future__ import annotations

import argparse
import sys
from pathlib import Path

import bpy


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
    return parser.parse_args(script_args)


def import_glb(input_glb: Path) -> None:
    """Import into an empty scene. Leaves the imported mesh object(s)
    selected and the most-recently-added one active.
    """
    bpy.ops.wm.read_factory_settings(use_empty=True)
    bpy.ops.import_scene.gltf(filepath=str(input_glb))


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

    if not input_glb.is_file():
        print(f"[FAIL] input GLB not found: {input_glb}", file=sys.stderr)
        return 1

    try:
        import_glb(input_glb)
        before_count = sum(1 for o in bpy.data.objects if o.type == "MESH")
        strip_all_materials()
        split_objects = weld_and_split_loose()
        after_count = len(split_objects)
        rename_for_readability(split_objects)
        export_usdz(output_usdz)
    except Exception as exc:  # noqa: BLE001
        print(f"[FAIL] split + export: {exc}", file=sys.stderr)
        return 1

    if after_count == 0:
        print(
            f"[FAIL] split produced zero objects from {input_glb.name} — "
            "runtime needs ≥ 1 child prim.",
            file=sys.stderr,
        )
        return 1

    size_kb = output_usdz.stat().st_size / 1024
    print(
        f"[OK] {input_glb.name} -> {output_usdz.name}  "
        f"meshes {before_count} -> {after_count} objects  "
        f"{size_kb:,.0f} KB"
    )
    if after_count > 5000:
        print(
            f"[WARN] unusually high object count ({after_count}) — "
            "verify hierarchy on device; consider merge policy.",
            file=sys.stderr,
        )
    return 0


if __name__ == "__main__":
    sys.exit(main())
