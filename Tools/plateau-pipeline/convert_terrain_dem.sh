#!/usr/bin/env bash
# convert_terrain_dem.sh
# Tools/plateau-pipeline
#
# Batch driver: extract one PLATEAU DEM CityGML from the source zip,
# run nusamai → glTF, then Blender → decimated USDZ. Designed to be
# re-run when adjusting the triangle budget or switching to a new
# sub-tile.
#
# Pipeline:
#   sendai_2024_citygml.zip
#     └─ udx/dem/574036_dem_6697_05_op.gml              (~630 MB, one 5×5 km quadrant)
#     ↓ unzip
#   input/extracted/udx/dem/…gml
#     ↓ nusamai --sink gltf --epsg 6677
#   intermediate/dem/dem_ReliefFeature.glb              (~200 MB, ~1.7 M tris)
#     ↓ Blender decimate 30K tris + orphan-vertex purge
#   Resources/Environment/Terrain_Sendai_574036_05.usdz (~2 MB, 30K tris)
#
# Usage:
#   bash Tools/plateau-pipeline/convert_terrain_dem.sh
#
# Prereqs (see INSTALL.md):
#   - /tmp/nusamai binary (v0.1.0+)
#   - Blender 3.x at /Applications/Blender.app
#   - input/sendai_2024_citygml.zip present (~1.5 GB)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

ZIP="input/sendai_2024_citygml.zip"
MESH="574036"
QUADRANT="05"     # NE quadrant covers the 5 building tiles (rows 0-4, cols 5-9).
GML_REL="udx/dem/${MESH}_dem_6697_${QUADRANT}_op.gml"
EXTRACT_DIR="input/extracted"
INTERMEDIATE_DIR="intermediate/dem"
GLB_OUT_DIR="${INTERMEDIATE_DIR}/glb"
OUT_USDZ="../../Resources/Environment/Terrain_Sendai_${MESH}_${QUADRANT}.usdz"
TARGET_TRIS="30000"

NUSAMAI="${NUSAMAI:-/tmp/nusamai}"
BLENDER="${BLENDER:-/Applications/Blender.app/Contents/MacOS/Blender}"

# --- Sanity checks --------------------------------------------------

[[ -f "$ZIP" ]] || { echo "error: $ZIP not found (see QUICKSTART.md)" >&2; exit 1; }
[[ -x "$NUSAMAI" ]] || { echo "error: nusamai binary missing or not executable at $NUSAMAI" >&2; exit 1; }
[[ -x "$BLENDER" ]] || { echo "error: Blender not found at $BLENDER" >&2; exit 1; }

# --- Step 1: extract DEM GML ---------------------------------------

mkdir -p "$EXTRACT_DIR"
if [[ -f "${EXTRACT_DIR}/${GML_REL}" ]]; then
    echo "[1/3] GML already extracted: ${EXTRACT_DIR}/${GML_REL}"
else
    echo "[1/3] extracting ${GML_REL} from zip…"
    /usr/bin/unzip -o "$ZIP" "$GML_REL" -d "$EXTRACT_DIR"
fi

# --- Step 2: nusamai → GLB -----------------------------------------

mkdir -p "$GLB_OUT_DIR"
# nusamai's gltf sink writes an output DIRECTORY containing one GLB
# per feature class. For DEM there is exactly one: dem_ReliefFeature.glb.
GLB_BUNDLE="${GLB_OUT_DIR}/${MESH}_${QUADRANT}"
GLB_FILE="${GLB_BUNDLE}/dem_ReliefFeature.glb"
if [[ -f "$GLB_FILE" ]]; then
    echo "[2/3] GLB already exists: $GLB_FILE"
else
    echo "[2/3] nusamai converting ${GML_REL} → glTF (EPSG:6677)…"
    rm -rf "$GLB_BUNDLE"
    "$NUSAMAI" \
        --sink gltf \
        --output "$GLB_BUNDLE" \
        --epsg 6677 \
        "${EXTRACT_DIR}/${GML_REL}"
fi

# --- Step 3: Blender decimate + USDZ export -------------------------

mkdir -p "$(dirname "$OUT_USDZ")"
echo "[3/3] Blender decimate (target=${TARGET_TRIS} tris) + USDZ export…"
"$BLENDER" --background --factory-startup \
    --python "${SCRIPT_DIR}/dem_to_terrain_usdz.py" -- \
    --input "$GLB_FILE" \
    --output "$OUT_USDZ" \
    --target-triangles "$TARGET_TRIS"

echo
echo "Done. Output: $OUT_USDZ"
/bin/ls -lh "$OUT_USDZ"
