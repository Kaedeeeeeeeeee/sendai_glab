"""Blender CLI: convert a PLATEAU DEM GLB to a decimated terrain USDZ.

Why a separate script from `glb_to_usdz.py`
--------------------------------------------
PLATEAU DEM tiles ship as *dense* 5-metre-grid meshes. One 5×5 km
sub-tile is ~1.7 million triangles / ~200 MB as raw nusamai glTF
output. Shipping that in an iPad .app bundle is infeasible and would
grind the GPU even on an M5 iPad. We need:

  1. Geometry decimation — collapse to ~30–60 k triangles so the
     mesh loads fast and renders cheap.
  2. Planar UV projection — PLATEAU ships the DEM without UVs; we
     generate them ourselves from the post-decimation vertex bbox so
     an external orthophoto can be draped on top.
  3. Orthophoto material — pack the GSI seamlessphoto mosaic
     produced by `download_gsi_ortho.sh` into a Principled BSDF with
     `Base Color = image`. RealityKit's hybrid tint mutator sees a
     textured `PhysicallyBasedMaterial` at runtime and preserves it.
  4. USDZ export — RealityKit's supported interchange format.

Phase 11 Part E flipped the Phase 3 behaviour that stripped materials
+ UVs wholesale. The Phase 3 rationale was "DEM has no meaningful
texture so we apply a flat toon runtime material". Part E introduces a
real orthophoto, so keeping the pipeline-authored material and UVs is
correct, and the runtime now uses a hybrid mutator that preserves the
texture (ToonMaterialFactory.mutateIntoTexturedCel).

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
      --ortho  intermediate/gsi_ortho/sendai_574036_05.jpg \
      --target-triangles 50000

`--target-triangles` is an approximate budget. Blender's DECIMATE
modifier operates on a ratio, so the script computes the ratio to
hit the target, clamped to [0.001, 1.0].

`--ortho` is optional: when omitted the exporter falls back to the
Phase 3 untextured behaviour (used by tests / CI that don't have the
GSI mosaic on disk). Production pipeline always passes it.
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
    parser.add_argument(
        "--ortho",
        default=None,
        help=(
            "Optional path to a stitched orthophoto JPG (from "
            "download_gsi_ortho.sh). When provided, the terrain is "
            "exported with planar UVs + a Principled BSDF sourcing "
            "Base Color from the image. When omitted, the legacy "
            "untextured Phase 3 export is produced."
        ),
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


def weld_duplicate_vertices(obj: bpy.types.Object, threshold: float = 0.01) -> tuple[int, int]:
    """Merge coincident vertices so DECIMATE can reason about the mesh
    as a manifold surface rather than a cloud of independent triangles.

    Why this matters (Phase 3 terrain playtest postmortem):

    nusamai emits PLATEAU DEM as *triangle soup* — every triangle owns
    its own 3 vertices, shared with nobody. A 1.7 M triangle mesh
    therefore carries 5.1 M vertices (ratio 3 : 1). When Blender's
    DECIMATE COLLAPSE runs on triangle soup, collapsing one triangle
    does not snap its neighbours' coincident-but-separate vertices,
    so the output develops visible holes — the ~1.7% retention ratio
    we target for bundle size turns the continuous hillside into a
    cloud of disconnected chunks floating in mid-air. The first
    playtest screenshot showed exactly that.

    After a `remove_doubles` with a 1 cm threshold, the 5.1 M verts
    collapse to the ~800 K unique positions the source actually had.
    Each vert is then shared by ~6 triangles on average (the expected
    ratio for a triangulated heightfield). DECIMATE subsequently
    collapses triangles by moving shared verts, which keeps the
    surface manifold.

    Returns `(before, after)` vertex counts for the logger.
    """
    before = len(obj.data.vertices)
    bpy.context.view_layer.objects.active = obj
    bpy.ops.object.mode_set(mode="EDIT")
    bpy.ops.mesh.select_all(action="SELECT")
    bpy.ops.mesh.remove_doubles(threshold=threshold)
    bpy.ops.object.mode_set(mode="OBJECT")
    after = len(obj.data.vertices)
    return (before, after)


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


def generate_planar_uvs(obj: bpy.types.Object) -> tuple[tuple[float, float], tuple[float, float]]:
    """Create a planar UV layer by normalising vertex positions
    against the mesh's horizontal (XY) bounding box.

    Why a *manual* UV layer and not `bpy.ops.uv.smart_project`
    ----------------------------------------------------------
    The DEM is a heightfield — one vertex per horizontal cell, no
    seams, no disconnected shells. Smart-project's angle-limit splits
    slope triangles into separate islands, which scatters the
    orthophoto across the UV space non-monotonically and produces a
    deeply confusing ground at runtime. A direct `uv = normalize(xy)`
    preserves the spatial relationship ("pixel at (u,v) in the
    orthophoto corresponds to world (x,z) by a fixed affine"), which
    is exactly what aligned aerial imagery needs.

    Axis convention
    ---------------
    After glTF-import of nusamai output, Blender axes are:
      - X east (matches EPSG:6677 Y, nusamai already flipped it into
        Blender-X at import time)
      - Y north (matches EPSG:6677 X after nusamai's swap)
      - Z up
    The stitched orthophoto (from download_gsi_ortho.sh) has north at
    pixel-y = 0 (top of image). UV convention: V=0 is the bottom of
    the image in Blender's convention — so to map "Blender-north =
    Blender-+Y = image-top = UV-v=1", we need `v = (y - min_y) /
    (max_y - min_y)`.

    The UV.u direction is straightforward: u = (x - min_x) / span_x.

    This gives us an orientation that **should** look correct first
    try. The user can spot-check on real hardware; flipping u or v is
    a one-line change if orientation is wrong.

    Returns the (min, max) XY bbox so the caller can log it or sanity-
    check ordering.
    """
    mesh = obj.data
    if not mesh.vertices:
        return ((0.0, 0.0), (0.0, 0.0))

    xs = [v.co.x for v in mesh.vertices]
    ys = [v.co.y for v in mesh.vertices]
    min_x, max_x = min(xs), max(xs)
    min_y, max_y = min(ys), max(ys)
    span_x = max(max_x - min_x, 1e-6)
    span_y = max(max_y - min_y, 1e-6)

    # Remove any existing UV layers so we emit exactly one.
    while mesh.uv_layers:
        mesh.uv_layers.remove(mesh.uv_layers[0])
    uv_layer = mesh.uv_layers.new(name="TerrainOrthoUV")

    # `uv_layer.data` is one entry per loop (per face-corner). Each
    # loop references a vertex via `mesh.loops[i].vertex_index`.
    for loop_index, loop in enumerate(mesh.loops):
        v = mesh.vertices[loop.vertex_index]
        u = (v.co.x - min_x) / span_x
        w = (v.co.y - min_y) / span_y
        uv_layer.data[loop_index].uv = (u, w)

    mesh.update()
    return ((min_x, min_y), (max_x, max_y))


def attach_ortho_material(obj: bpy.types.Object, ortho_path: Path) -> None:
    """Replace the mesh's material slots with a single Principled BSDF
    whose Base Color samples the stitched orthophoto image.

    Roughness is pinned to 1.0 and Specular IOR Level to 0.0 so the
    PhysicallyBasedMaterial that lands in RealityKit is already in the
    "painted-matte" state the runtime Toon mutator wants. Clearing the
    residual specular here means the runtime mutator has less to
    override, and the rare case where the user ships a new USDZ
    without running the runtime path (e.g. a Reality Composer preview)
    still gets a flat painted look.
    """
    if not ortho_path.is_file():
        raise FileNotFoundError(f"Orthophoto not found: {ortho_path}")

    # Drop any existing materials — the DEM comes in with a stub
    # material slot from nusamai that has no texture and no reason to
    # survive.
    while obj.data.materials:
        obj.data.materials.pop(index=0)

    mat = bpy.data.materials.new(name="TerrainOrthoMaterial")
    mat.use_nodes = True
    nodes = mat.node_tree.nodes
    links = mat.node_tree.links
    for n in list(nodes):
        nodes.remove(n)

    output = nodes.new(type="ShaderNodeOutputMaterial")
    output.location = (300, 0)
    bsdf = nodes.new(type="ShaderNodeBsdfPrincipled")
    bsdf.location = (0, 0)
    tex = nodes.new(type="ShaderNodeTexImage")
    tex.location = (-320, 0)

    image = bpy.data.images.load(str(ortho_path), check_existing=True)
    # Pack the JPG bytes into the blend so wm.usd_export's
    # export_textures path finds the image without needing the
    # external file to exist at export time.
    image.pack()
    tex.image = image
    # Colour data (default); no interpolation tweak — sRGB is the
    # correct colour space for photographic orthophotos.

    links.new(tex.outputs["Color"], bsdf.inputs["Base Color"])
    links.new(bsdf.outputs["BSDF"], output.inputs["Surface"])

    # Painted-matte tuning. Blender 4.x renamed "Specular" → "Specular
    # IOR Level"; guard both spellings so this works across supported
    # Blender versions.
    bsdf.inputs["Roughness"].default_value = 1.0
    bsdf.inputs["Metallic"].default_value = 0.0
    for spec_name in ("Specular IOR Level", "Specular"):
        if spec_name in bsdf.inputs:
            bsdf.inputs[spec_name].default_value = 0.0
            break

    obj.data.materials.append(mat)


def export_usdz(output: Path, *, textured: bool) -> None:
    """Export the current scene as USDZ.

    `textured=True` (Phase 11 Part E) flips materials + UVs on so the
    embedded orthophoto rides along; `textured=False` keeps the legacy
    Phase 3 behaviour where the runtime applies a flat cel material.
    """
    output.parent.mkdir(parents=True, exist_ok=True)
    export_kwargs = {
        "filepath": str(output),
        "selected_objects_only": False,
        "export_animation": False,
        "export_hair": False,
        "export_uvmaps": textured,
        "export_normals": True,   # Lit shading benefits from normals.
        "export_materials": textured,
        "use_instancing": False,
        "evaluation_mode": "RENDER",
    }
    op = bpy.ops.wm.usd_export
    if hasattr(op, "get_rna_type") and "root_prim_path" in op.get_rna_type().properties.keys():
        export_kwargs["root_prim_path"] = "/root"
    # Only ask for textures to be embedded when we actually have a
    # material worth exporting — keeps the "untextured" fallback USDZ
    # bit-identical to Phase 3.
    if textured and "export_textures" in op.get_rna_type().properties.keys():
        export_kwargs["export_textures"] = True
    result = bpy.ops.wm.usd_export(**export_kwargs)
    if "FINISHED" not in result:
        raise RuntimeError(f"USD export returned non-finished status: {result}")


def convert(
    input_glb: Path,
    output_usdz: Path,
    target_triangles: int,
    ortho_path: Path | None,
) -> None:
    if not input_glb.is_file():
        raise FileNotFoundError(f"Input GLB not found: {input_glb}")

    bpy.ops.wm.read_factory_settings(use_empty=True)
    bpy.ops.import_scene.gltf(filepath=str(input_glb))

    joined = join_all_meshes_into_one()
    if joined is None:
        raise RuntimeError("Imported GLB produced no mesh objects")

    # Phase 11 Part E: only strip materials when we're not about to
    # author a new textured one. Avoids a pointless strip + rebuild.
    if ortho_path is None:
        strip_materials(joined)

    # Weld coincident verts BEFORE decimating — see the function's
    # docstring for the why (nusamai triangle-soup defeats DECIMATE).
    weld_before, weld_after = weld_duplicate_vertices(joined, threshold=0.01)

    before, after, ratio = decimate_to_target(joined, target_triangles)

    uv_bbox: tuple[tuple[float, float], tuple[float, float]] | None = None
    if ortho_path is not None:
        uv_bbox = generate_planar_uvs(joined)
        attach_ortho_material(joined, ortho_path)

    export_usdz(output_usdz, textured=ortho_path is not None)

    size_kb = output_usdz.stat().st_size / 1024
    ortho_note = ""
    if uv_bbox is not None:
        (min_x, min_y), (max_x, max_y) = uv_bbox
        ortho_note = (
            f"  uv-bbox x={max_x - min_x:,.1f}m y={max_y - min_y:,.1f}m "
            f"ortho={ortho_path.name}"
        )
    print(
        f"[OK] {input_glb.name} -> {output_usdz.name}  "
        f"verts {weld_before:,} -> welded {weld_after:,}  "
        f"tris {before:,} -> {after:,} "
        f"(ratio {ratio:.4f})  "
        f"{size_kb:,.0f} KB{ortho_note}"
    )


def main() -> int:
    args = parse_post_dashdash_args()
    try:
        ortho_path = Path(args.ortho) if args.ortho else None
        convert(
            Path(args.input),
            Path(args.output),
            int(args.target_triangles),
            ortho_path,
        )
    except Exception as exc:  # noqa: BLE001
        print(f"[FAIL] DEM conversion failed: {exc}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
