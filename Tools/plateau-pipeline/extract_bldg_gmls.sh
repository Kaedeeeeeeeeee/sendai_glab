#!/usr/bin/env bash
# extract_bldg_gmls.sh
# Tools/plateau-pipeline
#
# Unpack the 5 PLATEAU building CityGML files we ship today from the
# monolithic source zip so extract_envelopes.py (and any future offline
# tool) can parse their <gml:Envelope> blocks.
#
# Phase 11: also unpack each tile's `{tile}_bldg_6697_appearance/`
# directory. That folder holds the facade-photo JPGs (e.g.
# `sendai_2024_opJ_57403607_57_wall0.jpg`) that the CityGML's
# `<app:Appearance>` blocks reference by relative path. nusamai's
# gltf sink auto-picks-up an adjacent appearance folder when the
# relative URIs inside the GML resolve next to the GML on disk, so the
# only thing we need to do is extract the JPGs into the same tree
# nusamai reads from. Without this step the GLB comes out
# flat-shaded, which ripples through every downstream step of the
# pipeline and ends with untextured buildings on device.
#
# The DEM GML for the surrounding quadrant is already extracted by
# convert_terrain_dem.sh — this script only handles bldg tiles to keep
# responsibilities separated.
#
# Pipeline:
#   sendai_2024_citygml.zip
#     ├─ udx/bldg/{57403607,57403608,57403617,57403618,57403619}_bldg_6697_op.gml
#     └─ udx/bldg/{tile}_bldg_6697_appearance/*.jpg   (~1 065 JPGs, ~65 MB)
#     ↓ unzip
#   input/extracted/udx/bldg/*.gml                    (6 files)
#   input/extracted/udx/bldg/*_appearance/*.jpg       (facade photos)
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

# --- Extract each bldg GML + appearance folder ----------------------

mkdir -p "$EXTRACT_DIR"

extracted=0
skipped=0
appearance_extracted=0
appearance_skipped=0

for tile in "${TILES[@]}"; do
    # 1) The GML itself (single file).
    rel_gml="udx/bldg/${tile}_bldg_6697_op.gml"
    abs_gml="${EXTRACT_DIR}/${rel_gml}"
    if [[ -f "$abs_gml" ]]; then
        echo "[skip] $rel_gml already extracted"
        skipped=$((skipped + 1))
    else
        echo "[extract] $rel_gml …"
        /usr/bin/unzip -o "$ZIP" "$rel_gml" -d "$EXTRACT_DIR" >/dev/null
        extracted=$((extracted + 1))
    fi

    # 2) The appearance directory (many JPG facade photos). The directory
    #    MUST be extracted next to the GML because the CityGML's
    #    <app:TextureFile>…</app:TextureFile> refs are relative paths
    #    like `57403607_bldg_6697_appearance/xxx.jpg`, which nusamai
    #    resolves from the GML's own parent dir.
    rel_app_dir="udx/bldg/${tile}_bldg_6697_appearance"
    abs_app_dir="${EXTRACT_DIR}/${rel_app_dir}"
    # Idempotency: if the directory already exists and is non-empty,
    # skip. We don't re-verify file-for-file; the zip layout is stable
    # enough that presence == previously extracted.
    if [[ -d "$abs_app_dir" ]] && compgen -G "${abs_app_dir}/*" > /dev/null; then
        echo "[skip] $rel_app_dir already extracted"
        appearance_skipped=$((appearance_skipped + 1))
    else
        echo "[extract] $rel_app_dir/* …"
        # Glob pattern pulls every file under the directory (recursive).
        /usr/bin/unzip -o "$ZIP" "${rel_app_dir}/*" -d "$EXTRACT_DIR" >/dev/null
        appearance_extracted=$((appearance_extracted + 1))
    fi
done

# --- Summary --------------------------------------------------------

echo
echo "GML:         extracted=$extracted skipped=$skipped"
echo "Appearance:  extracted=$appearance_extracted skipped=$appearance_skipped"
/bin/ls -lh "${EXTRACT_DIR}/udx/bldg/"*.gml 2>/dev/null || true

# Tally the JPG payload so the user can see it landed.
jpg_count=0
jpg_bytes=0
for tile in "${TILES[@]}"; do
    dir="${EXTRACT_DIR}/udx/bldg/${tile}_bldg_6697_appearance"
    [[ -d "$dir" ]] || continue
    # `find -type f` counts regular files; use `du -k` for KiB sum.
    count=$(/usr/bin/find "$dir" -type f -name '*.jpg' 2>/dev/null | /usr/bin/wc -l | /usr/bin/tr -d ' ')
    bytes=$(/usr/bin/find "$dir" -type f -name '*.jpg' -print0 2>/dev/null \
            | /usr/bin/xargs -0 /usr/bin/stat -f '%z' 2>/dev/null \
            | /usr/bin/awk '{s+=$1} END {print s+0}')
    jpg_count=$((jpg_count + count))
    jpg_bytes=$((jpg_bytes + bytes))
done

# Pretty-print the byte count in MiB (one decimal).
if command -v /usr/bin/awk >/dev/null 2>&1; then
    jpg_mb=$(/usr/bin/awk -v b="$jpg_bytes" 'BEGIN { printf "%.1f", b/1024/1024 }')
else
    jpg_mb="${jpg_bytes}B"
fi
echo
echo "Facade JPG total: ${jpg_count} files, ${jpg_mb} MiB"
