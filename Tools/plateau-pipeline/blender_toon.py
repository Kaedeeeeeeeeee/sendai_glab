"""SDG-Lab PLATEAU pipeline - Blender batch (Phase 0).

Intended to be run by `convert.sh` as::

    blender --background --factory-startup \
        --python blender_toon.py -- \
        --input  <stage1.glb> \
        --output <stage2.glb> \
        --config <lod_config.json>

Phase 0 scope (minimum viable):

  1. Import the input .glb
  2. Apply a Decimate modifier (ratio taken from lod_config.json,
     default 0.5) to every mesh object and bake it into the mesh
  3. Emit a warning for meshes that remain very dense
  4. Export the scene as a .glb (keeping original materials)

Phase 1 (P1-T10) will replace this body with the real Toon shader work:
swap materials for a Toon node group, add an Outline modifier, bake ramps,
etc. For now we only do mesh simplification so the rest of the pipeline
(convert.sh -> usdzconvert) has something to chew on.

API references (verified against Blender 4.2 glTF addon source,
`io_scene_gltf2/__init__.py`):

    bpy.ops.import_scene.gltf(filepath=...)
    bpy.ops.export_scene.gltf(filepath=..., export_format='GLB')

The `bl_idname`s `import_scene.gltf` / `export_scene.gltf` have been
stable since Blender 3.x and are still present in 4.x.
"""

from __future__ import annotations

import argparse
import json
import os
import sys
from typing import Any, Dict


def _split_args() -> list[str]:
    """Return just the args after the `--` separator.

    Blender passes everything on its own CLI through `sys.argv`; our
    script-specific args live after a literal `--`.
    """
    if "--" in sys.argv:
        return sys.argv[sys.argv.index("--") + 1:]
    return []


def _parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        prog="blender_toon.py",
        description="Phase 0 Blender batch: import glb, decimate, export glb.",
    )
    parser.add_argument("--input",  required=True, help="input .glb path")
    parser.add_argument("--output", required=True, help="output .glb path")
    parser.add_argument(
        "--config",
        default=None,
        help="optional lod_config.json path (uses defaults otherwise)",
    )
    return parser.parse_args(_split_args())


def _load_config(config_path: str | None) -> Dict[str, Any]:
    defaults: Dict[str, Any] = {
        "default_lod": 2,
        "decimate_ratio": 0.5,
        "max_mesh_verts_warn": 50000,
    }
    if not config_path:
        return defaults
    if not os.path.isfile(config_path):
        print(f"[blender_toon] config not found, using defaults: {config_path}",
              file=sys.stderr)
        return defaults
    try:
        with open(config_path, "r", encoding="utf-8") as f:
            cfg = json.load(f)
    except (OSError, json.JSONDecodeError) as exc:
        print(f"[blender_toon] failed to read config ({exc}); using defaults",
              file=sys.stderr)
        return defaults
    merged = {**defaults, **{k: v for k, v in cfg.items() if not k.startswith("_") and k != "comment"}}
    return merged


def _reset_scene(bpy_mod) -> None:
    """Start from a clean slate so `--factory-startup` assumptions hold."""
    # Remove everything currently in the scene.
    bpy_mod.ops.object.select_all(action="SELECT")
    bpy_mod.ops.object.delete(use_global=False)
    # Purge orphaned data (materials, meshes, images from the default cube etc.)
    for collection in (
        bpy_mod.data.meshes,
        bpy_mod.data.materials,
        bpy_mod.data.images,
        bpy_mod.data.textures,
    ):
        for item in list(collection):
            try:
                collection.remove(item)
            except RuntimeError:
                # Some datablocks may still be referenced; leave them alone.
                pass


def _iter_mesh_objects(bpy_mod):
    """Yield mesh objects in the current scene (Blender 4.x safe)."""
    for obj in bpy_mod.data.objects:
        if obj.type == "MESH":
            yield obj


def _apply_decimate(bpy_mod, ratio: float, warn_threshold: int) -> int:
    """Add a COLLAPSE decimate modifier to each mesh and apply it.

    Returns the number of meshes processed.
    """
    count = 0
    # Iterate over a snapshot list; applying modifiers can mutate bpy.data.objects.
    mesh_objects = list(_iter_mesh_objects(bpy_mod))
    for obj in mesh_objects:
        mod = obj.modifiers.new(name="SDGLab_Decimate", type="DECIMATE")
        # Type signature verified against Blender current docs
        # (bpy.types.DecimateModifier): decimate_type='COLLAPSE', ratio ∈ [0,1].
        mod.decimate_type = "COLLAPSE"
        mod.ratio = float(ratio)
        mod.use_collapse_triangulate = True

        # Make this the active object then apply the modifier.
        # Blender 4.x requires an active object in a view layer to apply modifiers.
        try:
            bpy_mod.context.view_layer.objects.active = obj
        except AttributeError:
            # headless edge case; fall through to a direct call
            pass

        try:
            # `ops.object.modifier_apply` takes the modifier name.
            bpy_mod.ops.object.modifier_apply(modifier=mod.name)
        except RuntimeError as exc:
            print(f"[blender_toon] warning: could not apply decimate on "
                  f"{obj.name!r}: {exc}", file=sys.stderr)

        # Post-apply vertex count warning.
        if hasattr(obj.data, "vertices"):
            n = len(obj.data.vertices)
            if n > warn_threshold:
                print(f"[blender_toon] warning: mesh {obj.name!r} still has "
                      f"{n} verts (> {warn_threshold})", file=sys.stderr)

        count += 1
    return count


def _import_gltf(bpy_mod, path: str) -> None:
    if not os.path.isfile(path):
        raise FileNotFoundError(f"input .glb not found: {path}")
    bpy_mod.ops.import_scene.gltf(filepath=path)


def _export_gltf(bpy_mod, path: str) -> None:
    out_dir = os.path.dirname(os.path.abspath(path))
    os.makedirs(out_dir, exist_ok=True)
    bpy_mod.ops.export_scene.gltf(
        filepath=path,
        export_format="GLB",
        # `use_selection=False` is the default in 4.x; keep things explicit.
        use_selection=False,
        export_apply=True,
    )


def main() -> int:
    args = _parse_args()
    config = _load_config(args.config)

    # Import bpy lazily so this file can be parsed / linted outside Blender.
    import bpy  # type: ignore

    ratio = float(config.get("decimate_ratio", 0.5))
    if not 0.0 < ratio <= 1.0:
        print(f"[blender_toon] invalid decimate_ratio {ratio}; "
              f"clamping to 0.5", file=sys.stderr)
        ratio = 0.5
    warn_threshold = int(config.get("max_mesh_verts_warn", 50000))

    print(f"[blender_toon] input       = {args.input}")
    print(f"[blender_toon] output      = {args.output}")
    print(f"[blender_toon] config      = {args.config}")
    print(f"[blender_toon] ratio       = {ratio}")
    print(f"[blender_toon] warn_verts  = {warn_threshold}")

    _reset_scene(bpy)
    _import_gltf(bpy, args.input)

    processed = _apply_decimate(bpy, ratio=ratio, warn_threshold=warn_threshold)
    print(f"[blender_toon] decimated {processed} mesh object(s)")

    _export_gltf(bpy, args.output)
    print(f"[blender_toon] exported {args.output}")
    return 0


if __name__ == "__main__":
    # Blender swallows non-zero exits for --python unless we sys.exit().
    try:
        rc = main()
    except Exception as exc:  # noqa: BLE001
        print(f"[blender_toon] FATAL: {exc}", file=sys.stderr)
        sys.exit(1)
    sys.exit(rc)
