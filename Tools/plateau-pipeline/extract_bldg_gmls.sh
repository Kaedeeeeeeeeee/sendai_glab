#!/usr/bin/env bash
# extract_bldg_gmls.sh
# Tools/plateau-pipeline
#
# Unpack the 5 PLATEAU building CityGML files we ship today from the
# monolithic source zip so extract_envelopes.py (and any future offline
# tool) can parse their <gml:Envelope> blocks.
#
# The DEM GML for the surrounding quadrant is already extracted by
# convert_terrain_dem.sh — this script only handles bldg tiles to keep
# responsibilities separated.
#
# Pipeline:
#   sendai_2024_citygml.zip
#     └─ udx/bldg/{57403607,57403608,57403617,57403618,57403619}_bldg_6697_op.gml
#     ↓ unzip
#   input/extracted/udx/bldg/*.gml (~3-14 MB each, 6 files total)
#
# Usage:
#   bash Tools/plateau-pipeline/extract_bldg_gmls.sh
#
# Prereqs:
#   - input/sendai_2024_citygml.zip present (~1.5 GB, see QUICKSTART.md)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

ZIP="input/sendai_2024_citygml.zip"
EXTRACT_DIR="input/extracted"
TILES=(57403607 57403608 57403617 57403618 57403619)

# --- Sanity checks --------------------------------------------------

[[ -f "$ZIP" ]] || { echo "error: $ZIP not found (see QUICKSTART.md)" >&2; exit 1; }

# --- Extract each bldg GML ------------------------------------------

mkdir -p "$EXTRACT_DIR"

extracted=0
skipped=0
for tile in "${TILES[@]}"; do
    rel="udx/bldg/${tile}_bldg_6697_op.gml"
    abs="${EXTRACT_DIR}/${rel}"
    if [[ -f "$abs" ]]; then
        echo "[skip] $rel already extracted"
        skipped=$((skipped + 1))
    else
        echo "[extract] $rel …"
        /usr/bin/unzip -o "$ZIP" "$rel" -d "$EXTRACT_DIR" >/dev/null
        extracted=$((extracted + 1))
    fi
done

echo
echo "Done. Extracted: $extracted, skipped: $skipped."
/bin/ls -lh "${EXTRACT_DIR}/udx/bldg/"*.gml 2>/dev/null || true
