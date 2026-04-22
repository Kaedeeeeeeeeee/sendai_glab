"""Blender CLI: convert a PLATEAU DEM GLB to a decimated terrain USDZ.

Why a separate script from `glb_to_usdz.py`
--------------------------------------------
PLATEAU DEM tiles ship as *dense* 5-metre-grid meshes. One 5×5 km
sub-tile is ~1.7 million triangles / ~200 MB as raw nusamai glTF
output. Shipping that in an iPad .app bundle is infeasible and would
grind the GPU even on an M5 iPad. We need:

  1. Geometry decimation — collapse to ~30–60 k triangles so the
     mesh loads fast and renders cheap.
  2. Material strip — DEM has no meaningful texture; we apply a flat
     toon-friendly material at runtime in RealityKit.
  3. USDZ export — RealityKit's supported interchange format.

Why not reuse `glb_to_usdz.py`?
-------------------------------
That script is the non-lossy passthrough used for building tiles
where we want to keep every triangle. Mixing in a decimation flag
would bloat its contract. Separate scripts keep each pipeline
obvious.

Usage
-----
    blender --background --factory-startup \
      --python Tools/plateau-pipeline/dem_to_terrain_usdz.py \
      -- \
      --input  /tmp/dem_ReliefFeature.glb \
      --output Resources/Environment/Terrain_Sendai_574036_05.usdz \
      --target-triangles 50000

`--target-triangles` is an approximate budget. Blender's DECIMATE
modifier operates on a ratio, so the script computes the ratio to
hit the target, clamped to [0.001, 1.0].
"""
from __future__ import annotations

import argparse
import sys
from pathlib import Path

import bmesh  # type: ignore
import bpy


def parse_post_dashdash_args() -> argparse.Namespace:
    """Parse arguments after a bare `--` separator (Blender convention)."""
    if "--" not in sys.argv:
        print("ERROR: script arguments must follow a bare '--' separator",
              file=sys.stderr)
        sys.exit(2)
    script_args = sys.argv[sys.argv.index("--") + 1:]
    parser = argparse.ArgumentParser(
        prog="dem_to_terrain_usdz.py",
        description="Decimate a PLATEAU DEM GLB and export as USDZ.",
    )
    parser.add_argument("--input", required=True, help="Input DEM .glb path")
    parser.add_argument("--output", required=True, help="Output .usdz path")
    parser.add_argument(
        "--target-triangles",
        type=int,
        default=50000,
        help="Approximate triangle budget after decimation (default 50000)."
    )
    return parser.parse_args(script_args)


def count_triangles() -> int:
    """Sum loop-triangle counts across every mesh in the active scene."""
    total = 0
    for obj in bpy.data.objects:
        if obj.type != "MESH":
            continue
        obj.data.calc_loop_triangles()
        total += len(obj.data.loop_triangles)
    return total


def join_all_meshes_into_one() -> bpy.types.Object | None:
    """Join every mesh in the scene into a single object.

    DEM output is one mesh per ReliefFeature; joining keeps the USDZ
    topology flat and lets a single DECIMATE modifier work across the
    whole surface. Returns the active (joined) object, or `None` if
    there were no meshes.
    """
    mesh_objs = [o for o in bpy.data.objects if o.type == "MESH"]
    if not mesh_objs:
        return None
    bpy.ops.object.select_all(action="DESELECT")
    for o in mesh_objs:
        o.select_set(True)
    bpy.context.view_layer.objects.active = mesh_objs[0]
    if len(mesh_objs) > 1:
        bpy.ops.object.join()
    return bpy.context.view_layer.objects.active


def strip_materials(obj: bpy.types.Object) -> None:
    """Remove every material slot; DEM has no meaningful texture and we
    apply a flat toon material at runtime in RealityKit instead.
    Keeping material slots around means Blender's USD exporter emits
    per-material subsets, which bloats the USDZ.
    """
    while obj.data.materials:
        obj.data.materials.pop(index=0)


def decimate_to_target(
    obj: bpy.types.Object,
    target_triangles: int,
) -> tuple[int, int, float]:
    """Apply a DECIMATE modifier with a computed ratio.

    Returns `(before, after, ratio_applied)` for logging. Blender's
    COLLAPSE decimation preserves overall shape well for heightfields,
    which is exactly what a DEM is.
    """
    obj.data.calc_loop_triangles()
    before = len(obj.data.loop_triangles)
    if before == 0:
        return (0, 0, 1.0)

    # Compute the ratio needed to hit the target. Clamp to a minimum
    # so a very-large target against a small mesh still produces a
    # valid modifier call.
    ratio = target_triangles / before
    ratio = max(0.001, min(1.0, ratio))

    mod = obj.modifiers.new(name="TerrainDecimate", type="DECIMATE")
    mod.decimate_type = "COLLAPSE"
    mod.ratio = ratio

    # Apply destructively so the export bakes the reduced topology.
    bpy.context.view_layer.objects.active = obj
    bpy.ops.object.modifier_apply(modifier=mod.name)

    # Blender's DECIMATE modifier drops triangles but leaves every
    # original vertex in the buffer. For a DEM going from 5 M verts
    # down to 15 K triangles, that would leave ~3.5 M unreferenced
    # vertices — which the USD exporter faithfully serialises,
    # bloating the output USDZ to 40+ MB for 15 K triangles.
    #
    # `bpy.ops.mesh.select_loose` only catches verts with neither
    # faces nor edges; DECIMATE leaves dangling edges attached, so
    # we drop down to bmesh and delete every vert with zero
    # linked_faces. This is the only path that actually shrinks the
    # vertex buffer.
    bm = bmesh.new()
    bm.from_mesh(obj.data)
    unused_verts = [v for v in bm.verts if not v.link_faces]
    if unused_verts:
        bmesh.ops.delete(bm, geom=unused_verts, context="VERTS")
    bm.to_mesh(obj.data)
    bm.free()
    obj.data.update()

    obj.data.calc_loop_triangles()
    after = len(obj.data.loop_triangles)
    return (before, after, ratio)


def export_usdz(output: Path) -> None:
    """Export the current scene as USDZ with the same flags as the
    building pipeline so RealityKit sees identical scene graphs.
    """
    output.parent.mkdir(parents=True, exist_ok=True)
    export_kwargs = {
        "filepath": str(output),
        "selected_objects_only": False,
        "export_animation": False,
        "export_hair": False,
        "export_uvmaps": False,   # DEM has no UVs worth keeping.
        "export_normals": True,   # Lit shading benefits from normals.
        "export_materials": False,  # See strip_materials() rationale.
        "use_instancing": False,
        "evaluation_mode": "RENDER",
    }
    op = bpy.ops.wm.usd_export
    if hasattr(op, "get_rna_type") and "root_prim_path" in op.get_rna_type().properties.keys():
        export_kwargs["root_prim_path"] = "/root"
    result = bpy.ops.wm.usd_export(**export_kwargs)
    if "FINISHED" not in result:
        raise RuntimeError(f"USD export returned non-finished status: {result}")


def convert(input_glb: Path, output_usdz: Path, target_triangles: int) -> None:
    if not input_glb.is_file():
        raise FileNotFoundError(f"Input GLB not found: {input_glb}")

    bpy.ops.wm.read_factory_settings(use_empty=True)
    bpy.ops.import_scene.gltf(filepath=str(input_glb))

    joined = join_all_meshes_into_one()
    if joined is None:
        raise RuntimeError("Imported GLB produced no mesh objects")

    strip_materials(joined)
    before, after, ratio = decimate_to_target(joined, target_triangles)

    export_usdz(output_usdz)

    size_kb = output_usdz.stat().st_size / 1024
    print(
        f"[OK] {input_glb.name} -> {output_usdz.name}  "
        f"tris {before:,} -> {after:,} "
        f"(ratio {ratio:.4f})  "
        f"{size_kb:,.0f} KB"
    )


def main() -> int:
    args = parse_post_dashdash_args()
    try:
        convert(
            Path(args.input),
            Path(args.output),
            int(args.target_triangles),
        )
    except Exception as exc:  # noqa: BLE001
        print(f"[FAIL] DEM conversion failed: {exc}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
