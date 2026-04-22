#!/usr/bin/env bash
#
# convert_environment_glbs.sh
#
# Run the Blender-based GLB -> USDZ converter for every
# Environment_Sendai_*.glb in Resources/Environment/, producing a
# sibling .usdz file next to each. Idempotent: existing USDZs that are
# newer than their source GLB are skipped.
#
# Why we need this: ModelIO on macOS 15 / iOS 26.4 has no GLB importer,
# so RealityKit cannot load the nusamai output directly. This is the
# bridge step that keeps the Phase 2 pipeline working today.
#
# Once Apple ships a GLB importer (iOS 27+?), delete this script and
# rely on `MDLAsset(url:)` at runtime instead.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

BLENDER="${BLENDER_PATH:-/Applications/Blender.app/Contents/MacOS/Blender}"
if [ ! -x "$BLENDER" ]; then
    echo "ERROR: Blender not found at $BLENDER" >&2
    echo "Override with BLENDER_PATH=/path/to/blender environment var." >&2
    exit 127
fi

ENV_DIR="$REPO_ROOT/Resources/Environment"
if [ ! -d "$ENV_DIR" ]; then
    echo "ERROR: $ENV_DIR does not exist" >&2
    exit 1
fi

CONVERTER="$SCRIPT_DIR/glb_to_usdz.py"
if [ ! -f "$CONVERTER" ]; then
    echo "ERROR: $CONVERTER not found" >&2
    exit 1
fi

shopt -s nullglob
converted=0
skipped=0
failed=0
for glb in "$ENV_DIR"/*.glb; do
    base="$(basename "$glb" .glb)"
    usdz="$ENV_DIR/$base.usdz"
    if [ -f "$usdz" ] && [ "$usdz" -nt "$glb" ]; then
        echo "[skip] $base — USDZ already up-to-date"
        skipped=$((skipped + 1))
        continue
    fi
    echo "[convert] $base"
    if "$BLENDER" --background --factory-startup \
        --python "$CONVERTER" \
        -- --input "$glb" --output "$usdz" > "/tmp/blender-$base.log" 2>&1; then
        converted=$((converted + 1))
    else
        echo "[FAIL] $base  (see /tmp/blender-$base.log)" >&2
        failed=$((failed + 1))
    fi
done

echo ""
echo "Summary: converted=$converted skipped=$skipped failed=$failed"
if [ "$failed" -gt 0 ]; then
    exit 1
fi
