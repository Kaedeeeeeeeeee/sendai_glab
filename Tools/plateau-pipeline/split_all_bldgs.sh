#!/usr/bin/env bash
# split_all_bldgs.sh
# Tools/plateau-pipeline
#
# Batch-run `split_bldg_by_connectivity.py` over every PLATEAU
# building GLB in Resources/Environment/. Each GLB becomes a single-
# mesh USDZ with per-building DEM snap baked in (Phase 6.1), with
# PLATEAU facade textures preserved + downscaled to 512 px JPEG
# (Phase 11).
#
# Idempotent: skips a tile whose USDZ is newer than every input that
# contributes to its content. The idempotency signature includes
# `PIPELINE_VERSION` (below) so whenever we change the pipeline
# semantics — e.g., turning texture passthrough on in Phase 11 —
# bumping the version invalidates every existing USDZ on the next
# run, even if their mtimes still look "newer" than the source GLB.

set -euo pipefail

# Bump this string any time the pipeline output changes meaningfully
# (adding / removing a stage, flipping an export flag, new
# downstream dependency). The version is stamped into a
# `{tile}.usdz.version` sidecar file next to each output; on the
# next run, if the sidecar's version doesn't match PIPELINE_VERSION,
# the USDZ is regenerated even if it's newer than its inputs.
#
# History:
#   p11-textures — Phase 11: export materials + textures, 512 px
#                  downscale (was: export_materials=False).
#   p6.1-snap    — Phase 6.1: per-building DEM snap offline, merge.
PIPELINE_VERSION="p11-textures"

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
ENV_DIR="$REPO_ROOT/Resources/Environment"
SCRIPT="$REPO_ROOT/Tools/plateau-pipeline/split_bldg_by_connectivity.py"
DOWNSCALE_MODULE="$REPO_ROOT/Tools/plateau-pipeline/downscale_textures_inline.py"
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
if [[ ! -f "$DOWNSCALE_MODULE" ]]; then
  echo "error: downscale module missing at $DOWNSCALE_MODULE" >&2
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
  version_stamp="$ENV_DIR/$base.usdz.version"

  # Idempotency: skip only when the USDZ is newer than every input
  # that contributes to it AND its version stamp matches the current
  # PIPELINE_VERSION. The version check is what lets Phase 11
  # invalidate Phase 6.1 outputs (which are newer than every input
  # in mtime terms but were built by a script that stripped textures).
  stamp_ok=0
  if [[ -f "$version_stamp" ]] \
     && [[ "$(/bin/cat "$version_stamp" 2>/dev/null || echo "")" == "$PIPELINE_VERSION" ]]; then
    stamp_ok=1
  fi
  if [[ -f "$usdz" \
     && "$stamp_ok" == "1" \
     && "$usdz" -nt "$glb" \
     && "$usdz" -nt "$SCRIPT" \
     && "$usdz" -nt "$DOWNSCALE_MODULE" \
     && "$usdz" -nt "$DEM_USDZ" \
     && "$usdz" -nt "$ENVELOPE_JSON" ]]; then
    echo "[skip] $base.usdz already at $PIPELINE_VERSION, newer than all inputs"
    skipped=$((skipped + 1))
    continue
  fi

  echo "--- split+snap+textures $base (tile id $tile_id) ---"
  if "$BLENDER" --background --factory-startup \
       --python "$SCRIPT" -- \
       --input         "$glb" \
       --output        "$usdz" \
       --dem-usdz      "$DEM_USDZ" \
       --envelope-json "$ENVELOPE_JSON" \
       --tile-id       "$tile_id" \
       --dem-tile-id   "$DEM_TILE_ID" \
       2>&1 | /usr/bin/grep -E '^(\[OK\]|\[WARN\]|\[FAIL\]|\[downscale\])'
  then
    # Stamp the version sidecar so next run can skip this tile.
    printf '%s\n' "$PIPELINE_VERSION" > "$version_stamp"
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
