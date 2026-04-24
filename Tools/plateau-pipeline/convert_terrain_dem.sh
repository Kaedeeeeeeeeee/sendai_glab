#!/usr/bin/env bash
# convert_terrain_dem.sh
# Tools/plateau-pipeline
#
# Batch driver: extract one PLATEAU DEM CityGML from the source zip,
# run nusamai → glTF, then Blender → decimated USDZ. Designed to be
# re-run when adjusting the triangle budget or switching to a new
# sub-tile.
#
# Phase 11 Part E: additionally fetch + stitch the GSI seamlessphoto
# orthophoto covering the DEM bbox and bake it as a baseColor texture
# on the terrain material. The Blender step is now UV-aware + material-
# aware; the runtime TerrainLoader uses ToonMaterialFactory
# .mutateIntoTexturedCel to preserve the orthophoto while pushing the
# rest of the material toward painted-cel.
#
# Pipeline:
#   sendai_2024_citygml.zip
#     └─ udx/dem/574036_dem_6697_05_op.gml              (~630 MB, one 5×5 km quadrant)
#     ↓ unzip
#   input/extracted/udx/dem/…gml
#     ↓ nusamai --sink gltf --epsg 6677
#   intermediate/dem/dem_ReliefFeature.glb              (~200 MB, ~1.7 M tris)
#     │  (parallel)
#     │  GSI WMTS seamlessphoto/z17
#     │    ↓ download_gsi_ortho.sh (curl + PIL stitch)
#     │  intermediate/gsi_ortho/sendai_574036_05.jpg    (1024×1024 JPG, ~700 KB)
#     ↓ Blender decimate 30K tris + orphan-vertex purge + planar UVs + ortho material
#   Resources/Environment/Terrain_Sendai_574036_05.usdz (~3 MB, 30K tris + baked JPG)
#
# Usage:
#   bash Tools/plateau-pipeline/convert_terrain_dem.sh
#
# Prereqs (see INSTALL.md):
#   - /tmp/nusamai binary (v0.1.0+)
#   - Blender 3.x at /Applications/Blender.app
#   - input/sendai_2024_citygml.zip present (~1.5 GB)
#   - Python: pyproj + Pillow (requirements.txt)
#   - Network access to cyberjapandata.gsi.go.jp (one-shot; ~9×9 tiles)

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
ORTHO_JPG="intermediate/gsi_ortho/sendai_${MESH}_${QUADRANT}.jpg"
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
    echo "[1/4] GML already extracted: ${EXTRACT_DIR}/${GML_REL}"
else
    echo "[1/4] extracting ${GML_REL} from zip…"
    /usr/bin/unzip -o "$ZIP" "$GML_REL" -d "$EXTRACT_DIR"
fi

# --- Step 2: nusamai → GLB -----------------------------------------

mkdir -p "$GLB_OUT_DIR"
# nusamai's gltf sink writes an output DIRECTORY containing one GLB
# per feature class. For DEM there is exactly one: dem_ReliefFeature.glb.
GLB_BUNDLE="${GLB_OUT_DIR}/${MESH}_${QUADRANT}"
GLB_FILE="${GLB_BUNDLE}/dem_ReliefFeature.glb"
if [[ -f "$GLB_FILE" ]]; then
    echo "[2/4] GLB already exists: $GLB_FILE"
else
    echo "[2/4] nusamai converting ${GML_REL} → glTF (EPSG:6677)…"
    rm -rf "$GLB_BUNDLE"
    "$NUSAMAI" \
        --sink gltf \
        --output "$GLB_BUNDLE" \
        --epsg 6677 \
        "${EXTRACT_DIR}/${GML_REL}"
fi

# --- Step 3: GSI orthophoto fetch + stitch --------------------------
#
# Phase 11 Part E. Sibling script handles its own idempotency (skips
# already-downloaded tiles). Loud failure here is the right behaviour
# — a bundled terrain JPG with missing tiles is a silent ship-blocker
# we'd rather surface before running Blender.

if [[ -f "$ORTHO_JPG" ]]; then
    echo "[3/4] orthophoto already stitched: $ORTHO_JPG"
else
    echo "[3/4] fetching + stitching GSI seamlessphoto (zoom 17)…"
    bash "${SCRIPT_DIR}/download_gsi_ortho.sh"
    [[ -f "$ORTHO_JPG" ]] || {
        echo "error: orthophoto stitch ran but $ORTHO_JPG is missing" >&2
        exit 1
    }
fi

# --- Step 4: Blender decimate + UV + texture + USDZ export ----------

mkdir -p "$(dirname "$OUT_USDZ")"
echo "[4/4] Blender decimate (target=${TARGET_TRIS} tris) + planar UV + ortho bake…"
"$BLENDER" --background --factory-startup \
    --python "${SCRIPT_DIR}/dem_to_terrain_usdz.py" -- \
    --input "$GLB_FILE" \
    --output "$OUT_USDZ" \
    --ortho "$ORTHO_JPG" \
    --target-triangles "$TARGET_TRIS"

echo
echo "Done. Output: $OUT_USDZ"
/bin/ls -lh "$OUT_USDZ"
