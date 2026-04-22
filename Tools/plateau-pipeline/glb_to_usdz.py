"""Blender CLI: convert a single GLB to USDZ.

Why this exists
---------------
ModelIO on macOS 15 / iOS 26.4 does NOT register a GLB importer
(`MDLAsset.canImportFileExtension("glb") == false`). RealityKit's
`Entity(contentsOf: glbURL)` therefore throws `noImporter`. Runtime
conversion is blocked until Apple ships a GLB importer (iOS 27+?).

Blender 3.x has a mature glTF importer AND a USD/USDZ exporter. We
use Blender in `--background` mode as a one-shot offline converter
during the plateau-pipeline.

Usage
-----
    blender --background --factory-startup \
        --python Tools/plateau-pipeline/glb_to_usdz.py \
        -- \
        --input  Resources/Environment/Environment_Sendai_57403617.glb \
        --output Resources/Environment/Environment_Sendai_57403617.usdz

Or the convenience `convert_all.sh` wrapper runs this for every GLB
in `Resources/Environment/`.

Notes
-----
- Blender passes its own arguments first; script sees everything after
  the bare `--` separator via `sys.argv`.
- `bpy.ops.wm.read_factory_settings(use_empty=True)` wipes the default
  cube/camera/light so the exported USDZ contains only the imported
  GLB content.
- USD export keyword flags vary between Blender 3.x and 4.x. We probe
  the installed version and adapt.
"""
from __future__ import annotations

import argparse
import sys
from pathlib import Path

import bpy


def parse_post_dashdash_args() -> argparse.Namespace:
    """Parse arguments that appear after the literal '--' separator.

    Blender eats everything before '--' for its own command line.
    """
    if "--" not in sys.argv:
        print("ERROR: script arguments must follow a bare '--' separator",
              file=sys.stderr)
        sys.exit(2)
    script_args = sys.argv[sys.argv.index("--") + 1:]
    parser = argparse.ArgumentParser(
        prog="glb_to_usdz.py",
        description="Convert a single GLB to USDZ via Blender.",
    )
    parser.add_argument("--input", required=True, help="Input .glb path")
    parser.add_argument("--output", required=True, help="Output .usdz path")
    return parser.parse_args(script_args)


def convert(input_glb: Path, output_usdz: Path) -> None:
    if not input_glb.is_file():
        raise FileNotFoundError(f"Input GLB not found: {input_glb}")
    if input_glb.suffix.lower() not in (".glb", ".gltf"):
        print(f"WARNING: input does not have .glb/.gltf suffix: {input_glb}",
              file=sys.stderr)

    output_usdz.parent.mkdir(parents=True, exist_ok=True)

    # Start from a truly empty scene so the exported USDZ contains only
    # the imported content.
    bpy.ops.wm.read_factory_settings(use_empty=True)

    # Import the GLB.
    bpy.ops.import_scene.gltf(filepath=str(input_glb))

    # Export as USDZ. Blender auto-detects the `.usdz` extension and
    # produces a zip archive containing the .usdc + textures.
    #
    # Blender 3.6's `wm.usd_export` accepts:
    #   filepath, selected_objects_only, export_animation,
    #   export_hair, export_uvmaps, export_normals,
    #   export_materials, use_instancing, evaluation_mode
    #
    # We want materials baked in and no instancing so RealityKit can
    # round-trip everything without an external cache.
    export_kwargs = {
        "filepath": str(output_usdz),
        "selected_objects_only": False,
        "export_animation": False,
        "export_hair": False,
        "export_uvmaps": True,
        "export_normals": True,
        "export_materials": True,
        "use_instancing": False,
        "evaluation_mode": "RENDER",
    }
    # `root_prim_path` is a 4.0+ flag that nests the export under a
    # single prim. If present we set it explicitly to "/root" so the
    # USDZ isn't flat.
    op = bpy.ops.wm.usd_export
    if hasattr(op, "get_rna_type") and "root_prim_path" in op.get_rna_type().properties.keys():
        export_kwargs["root_prim_path"] = "/root"

    result = bpy.ops.wm.usd_export(**export_kwargs)
    if "FINISHED" not in result:
        raise RuntimeError(f"USD export returned non-finished status: {result}")

    if not output_usdz.is_file():
        raise RuntimeError(
            f"USD export reported success but no file at {output_usdz}"
        )

    size_kb = output_usdz.stat().st_size / 1024
    print(f"[OK] {input_glb.name} -> {output_usdz.name}  ({size_kb:,.0f} KB)")


def main() -> int:
    args = parse_post_dashdash_args()
    try:
        convert(Path(args.input), Path(args.output))
    except Exception as exc:  # noqa: BLE001
        print(f"[FAIL] conversion failed: {exc}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
