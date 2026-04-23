#!/usr/bin/env bash
# split_all_bldgs.sh
# Tools/plateau-pipeline
#
# Batch-run `split_bldg_by_connectivity.py` over every PLATEAU
# building GLB in Resources/Environment/. Each GLB becomes a multi-
# prim USDZ (one prim per building) consumed by Swift's per-building
# adaptive DEM snap (Phase 6).
#
# Idempotent: skips a tile whose USDZ is newer than its GLB.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
ENV_DIR="$REPO_ROOT/Resources/Environment"
SCRIPT="$REPO_ROOT/Tools/plateau-pipeline/split_bldg_by_connectivity.py"
BLENDER="${BLENDER:-/Applications/Blender.app/Contents/MacOS/Blender}"

if [[ ! -x "$BLENDER" ]]; then
  echo "error: Blender not found at $BLENDER" >&2
  exit 1
fi
if [[ ! -f "$SCRIPT" ]]; then
  echo "error: split script missing at $SCRIPT" >&2
  exit 1
fi

converted=0
skipped=0
failed=0

for glb in "$ENV_DIR"/Environment_Sendai_*.glb; do
  [[ -f "$glb" ]] || { echo "no GLBs found in $ENV_DIR" >&2; exit 1; }
  base="$(basename "$glb" .glb)"
  usdz="$ENV_DIR/$base.usdz"

  if [[ -f "$usdz" && "$usdz" -nt "$glb" && "$usdz" -nt "$SCRIPT" ]]; then
    echo "[skip] $base.usdz already newer than GLB + script"
    skipped=$((skipped + 1))
    continue
  fi

  echo "--- split $base ---"
  if "$BLENDER" --background --factory-startup \
       --python "$SCRIPT" -- \
       --input "$glb" --output "$usdz" 2>&1 | /usr/bin/grep -E '^(\[OK\]|\[WARN\]|\[FAIL\])'
  then
    converted=$((converted + 1))
  else
    failed=$((failed + 1))
    echo "  FAIL: $base" >&2
  fi
done

echo
echo "Done. converted=$converted skipped=$skipped failed=$failed"
if [[ "$failed" -gt 0 ]]; then
  exit 2
fi
