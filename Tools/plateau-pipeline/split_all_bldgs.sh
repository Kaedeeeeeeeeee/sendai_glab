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
DEM_USDZ="$ENV_DIR/Terrain_Sendai_574036_05.usdz"
ENVELOPE_JSON="$ENV_DIR/plateau_envelopes.json"
DEM_TILE_ID="574036_05_dem"
BLENDER="${BLENDER:-/Applications/Blender.app/Contents/MacOS/Blender}"

if [[ ! -x "$BLENDER" ]]; then
  echo "error: Blender not found at $BLENDER" >&2
  exit 1
fi
if [[ ! -f "$SCRIPT" ]]; then
  echo "error: split script missing at $SCRIPT" >&2
  exit 1
fi
if [[ ! -f "$DEM_USDZ" ]]; then
  echo "error: DEM USDZ missing at $DEM_USDZ — run convert_terrain_dem.sh first" >&2
  exit 1
fi
if [[ ! -f "$ENVELOPE_JSON" ]]; then
  echo "error: envelope manifest missing at $ENVELOPE_JSON — run extract_envelopes.py first" >&2
  exit 1
fi

converted=0
skipped=0
failed=0

for glb in "$ENV_DIR"/Environment_Sendai_*.glb; do
  [[ -f "$glb" ]] || { echo "no GLBs found in $ENV_DIR" >&2; exit 1; }
  base="$(basename "$glb" .glb)"
  # Extract the 8-digit tile id from the filename, e.g.
  # Environment_Sendai_57403617 → 57403617
  tile_id="${base##*_}"
  usdz="$ENV_DIR/$base.usdz"

  # Idempotency: skip when the USDZ is newer than every input that
  # contributes to it (GLB, script, DEM, envelope JSON).
  if [[ -f "$usdz" \
     && "$usdz" -nt "$glb" \
     && "$usdz" -nt "$SCRIPT" \
     && "$usdz" -nt "$DEM_USDZ" \
     && "$usdz" -nt "$ENVELOPE_JSON" ]]; then
    echo "[skip] $base.usdz already newer than all inputs"
    skipped=$((skipped + 1))
    continue
  fi

  echo "--- split+snap $base (tile id $tile_id) ---"
  if "$BLENDER" --background --factory-startup \
       --python "$SCRIPT" -- \
       --input         "$glb" \
       --output        "$usdz" \
       --dem-usdz      "$DEM_USDZ" \
       --envelope-json "$ENVELOPE_JSON" \
       --tile-id       "$tile_id" \
       --dem-tile-id   "$DEM_TILE_ID" \
       2>&1 | /usr/bin/grep -E '^(\[OK\]|\[WARN\]|\[FAIL\])'
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
