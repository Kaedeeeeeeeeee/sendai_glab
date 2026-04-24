#!/usr/bin/env bash
# download_gsi_ortho.sh
# Tools/plateau-pipeline
#
# Phase 11 Part E — download the 国土地理院 (GSI) "seamlessphoto" WMTS
# orthophoto tiles covering the Sendai DEM tile (574036_05) and stitch
# them into a single JPG that `dem_to_terrain_usdz.py` bakes into the
# terrain USDZ as a baseColor texture.
#
# ## Input
#
# - Resources/Environment/plateau_envelopes.json — uses the
#   `574036_05_dem` entry's lower_corner_m / upper_corner_m (EPSG:6677).
#
# ## Output
#
# - intermediate/gsi_ortho/sendai_574036_05.jpg — single stitched
#   orthophoto aligned with the DEM's EPSG:6677 bbox, cropped to exact
#   bounds and down-sampled to 1024×1024.
# - intermediate/gsi_ortho/tiles_z17/{z}_{x}_{y}.jpg — raw tile cache.
#
# ## Resolution choice
#
# GSI seamlessphoto tops out at zoom 17 for this area (some regions go
# to 18). At zoom 17 each tile is ~1.2 m/px around Sendai; a 2.5×2.5 km
# DEM tile therefore needs ~9×9 ≈ 81 tiles. We stitch, crop to the
# DEM's real-world bbox, and downscale to 1024×1024 — giving ~2.4 m/px
# in the final texture, which is plenty at the camera distances the
# player normally looks at terrain from. Keeping the output to
# 1024×1024 keeps the USDZ bundle delta around +1 MB rather than
# +5 MB; 2048² was rejected as over-budget for the benefit.
#
# ## GSI 利用規約 (CC BY 4.0)
#
# GSI tiles are published under a license that requires attribution
# ("出典: 国土地理院" or equivalent). ADR-0012 and Resources/Credits.md
# must surface this. Do NOT ship a build without the credit.
# See https://www.gsi.go.jp/kikakuchousei/kikakuchousei40182.html
#
# ## Idempotency
#
# Already-downloaded tiles are skipped (atomic existence check).
# Clear the `intermediate/gsi_ortho/` dir to force a fresh download.
# The stitched mosaic is regenerated unconditionally because stitching
# is cheap (~1 s on M-series).
#
# ## Usage
#
#   bash Tools/plateau-pipeline/download_gsi_ortho.sh
#
# ## Prereqs
#
# - python3 with `pyproj` and `Pillow` (pip install -r requirements.txt).
# - curl (macOS default).
# - Network access to cyberjapandata.gsi.go.jp (no auth required).
#
# The slippy-tile math + mosaic stitching is in the sibling
# `gsi_tile_math.py` helper so that logic is unit-testable in isolation;
# this script orchestrates the loop and polite rate-limit between HTTP
# fetches.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

REPO_ROOT="$(cd ../.. && pwd)"
ENVELOPE_JSON="${REPO_ROOT}/Resources/Environment/plateau_envelopes.json"
DEM_TILE_ID="574036_05_dem"
ZOOM=17
OUT_DIR="intermediate/gsi_ortho"
TILE_DIR="${OUT_DIR}/tiles_z${ZOOM}"
OUT_MOSAIC="${OUT_DIR}/sendai_574036_05.jpg"
MOSAIC_SIZE=1024
GSI_BASE="https://cyberjapandata.gsi.go.jp/xyz/seamlessphoto"
HELPER="${SCRIPT_DIR}/gsi_tile_math.py"

# --- Sanity checks --------------------------------------------------

[[ -f "$ENVELOPE_JSON" ]] || { echo "error: envelope manifest missing at $ENVELOPE_JSON" >&2; exit 1; }
[[ -f "$HELPER" ]]       || { echo "error: helper missing at $HELPER" >&2; exit 1; }
command -v python3 >/dev/null || { echo "error: python3 not in PATH" >&2; exit 1; }
command -v curl    >/dev/null || { echo "error: curl not in PATH"    >&2; exit 1; }

mkdir -p "$TILE_DIR"

# --- Step 1: compute GSI tile range from envelope -------------------
#
# Defer the CRS reprojection + slippy-tile math to the Python helper,
# which prints shell-parseable KEY=VALUE lines we can `eval` into local
# variables. Keeps the double-precision math out of bash.

RANGE_OUTPUT=$(python3 "$HELPER" tilerange \
    --manifest "$ENVELOPE_JSON" \
    --tile-key "$DEM_TILE_ID" \
    --zoom "$ZOOM")

# Only accept the lines we expect — defence-in-depth against someone
# accidentally adding a shell-special character into the helper's
# output. The helper emits plain digits and dots; `grep` filters to
# that safely.
eval "$(echo "$RANGE_OUTPUT" | grep -E '^[A-Z_]+=[0-9.-]+$')"

: "${Z:?helper did not emit Z}"
: "${MIN_X:?helper did not emit MIN_X}"
: "${MAX_X:?helper did not emit MAX_X}"
: "${MIN_Y:?helper did not emit MIN_Y}"
: "${MAX_Y:?helper did not emit MAX_Y}"
: "${COUNT:?helper did not emit COUNT}"

echo "[1/3] DEM envelope → GSI z${Z} tile range:"
echo "      x=[${MIN_X}..${MAX_X}] y=[${MIN_Y}..${MAX_Y}] (${COUNT} tile(s))"
echo "      lat=[${LAT_MIN}..${LAT_MAX}] lon=[${LON_MIN}..${LON_MAX}]"

if (( COUNT > 400 )); then
    echo "error: tile count ${COUNT} is suspiciously large — refusing to flood GSI" >&2
    exit 4
fi

# --- Step 2: download each tile (skip if present) -------------------

downloaded=0
skipped=0
for (( y = MIN_Y; y <= MAX_Y; y++ )); do
    for (( x = MIN_X; x <= MAX_X; x++ )); do
        out="${TILE_DIR}/${Z}_${x}_${y}.jpg"
        if [[ -s "$out" ]]; then
            skipped=$((skipped + 1))
            continue
        fi
        url="${GSI_BASE}/${Z}/${x}/${y}.jpg"
        # --fail turns HTTP 4xx/5xx into a non-zero exit; -sS keeps curl
        # quiet on success but still prints errors. User-Agent is set
        # because GSI's edge sometimes 403s default libcurl UAs.
        if curl -fsS \
            --max-time 15 \
            -A "sendai-glab-dev-ortho-fetch/0.1 (+phase-11)" \
            -o "$out.partial" "$url"; then
            mv "$out.partial" "$out"
            downloaded=$((downloaded + 1))
            # Light politeness pause — GSI is a public service.
            sleep 0.1
        else
            rm -f "$out.partial"
            echo "warn: failed to fetch ${url} — some tiles may be ocean / absent" >&2
        fi
    done
done

echo "[2/3] tiles: ${downloaded} fetched, ${skipped} cached in ${TILE_DIR}"

# --- Step 3: stitch + crop + downscale via helper -------------------

python3 "$HELPER" stitch \
    --manifest "$ENVELOPE_JSON" \
    --tile-key "$DEM_TILE_ID" \
    --zoom "$ZOOM" \
    --tiles-dir "$TILE_DIR" \
    --output "$OUT_MOSAIC" \
    --downscale "$MOSAIC_SIZE"

echo
echo "Done. Orthophoto mosaic ready for dem_to_terrain_usdz.py."
/bin/ls -lh "$OUT_MOSAIC"
