#!/usr/bin/env bash
# SDG-Lab PLATEAU Pipeline - CityGML -> glTF -> Toon-simplified glb -> USDZ
#
# Phase 0 minimum-viable pass-through script.
# Phase 1 (P1-T10) will extend `blender_toon.py` with real Toon shader work.
#
# Usage:
#   ./convert.sh --input <path.gml> --output <path.usdz> [--lod N]
#   ./convert.sh --help
#
# Tool chain (each checked for existence before running):
#   - nusamai        (plateau-gis-converter CLI binary)
#   - blender        (Blender 4.0+ with the bundled glTF addon)
#   - usdzconvert    (from Apple USDPython / Reality Converter tooling) - optional
#
# See INSTALL.md for how to install the prerequisites on macOS Apple Silicon.

set -euo pipefail

# ----------------------------------------------------------------------------
# Locate script directory (resolves symlinks) so resource paths are stable
# regardless of where the user invokes from.
# ----------------------------------------------------------------------------
SCRIPT_SOURCE="${BASH_SOURCE[0]}"
while [ -h "$SCRIPT_SOURCE" ]; do
    SCRIPT_DIR_TMP="$(cd -P "$(dirname "$SCRIPT_SOURCE")" && pwd)"
    SCRIPT_SOURCE="$(readlink "$SCRIPT_SOURCE")"
    [[ "$SCRIPT_SOURCE" != /* ]] && SCRIPT_SOURCE="$SCRIPT_DIR_TMP/$SCRIPT_SOURCE"
done
SCRIPT_DIR="$(cd -P "$(dirname "$SCRIPT_SOURCE")" && pwd)"

BLENDER_SCRIPT="${SCRIPT_DIR}/blender_toon.py"
LOD_CONFIG="${SCRIPT_DIR}/lod_config.json"

# ----------------------------------------------------------------------------
# Colors (TTY only).
# ----------------------------------------------------------------------------
if [ -t 1 ]; then
    C_RED=$'\033[31m'
    C_GREEN=$'\033[32m'
    C_YELLOW=$'\033[33m'
    C_BLUE=$'\033[34m'
    C_RESET=$'\033[0m'
else
    C_RED=""; C_GREEN=""; C_YELLOW=""; C_BLUE=""; C_RESET=""
fi

log_info()  { printf '%s[info]%s %s\n'  "$C_BLUE"   "$C_RESET" "$*"; }
log_warn()  { printf '%s[warn]%s %s\n'  "$C_YELLOW" "$C_RESET" "$*" >&2; }
log_error() { printf '%s[error]%s %s\n' "$C_RED"    "$C_RESET" "$*" >&2; }
log_ok()    { printf '%s[ok]%s %s\n'    "$C_GREEN"  "$C_RESET" "$*"; }

# ----------------------------------------------------------------------------
# Help / usage.
# ----------------------------------------------------------------------------
print_help() {
    cat <<'EOF'
convert.sh - SDG-Lab PLATEAU CityGML -> USDZ pipeline

USAGE
    ./convert.sh --input <path.gml> --output <path.usdz> [--lod N]
    ./convert.sh --help

OPTIONS
    --input   <path>   Input CityGML (.gml) file. Required.
    --output  <path>   Output USDZ (.usdz) file path. Required.
    --lod     <N>      Target LOD level (0..3). Default: 2.
                       Passed to nusamai as `-t max_lod=N`.
    -h, --help         Print this message and exit.

PIPELINE STAGES
    1. nusamai    CityGML (.gml)  -> intermediate glTF binary (.glb)
    2. blender    glTF            -> simplified/toon-prepped .glb
                                     (blender_toon.py, headless)
    3. usdzconvert .glb           -> .usdz (or prompt the user to drop the
                                     intermediate into Reality Converter if
                                     usdzconvert is not installed).

ENVIRONMENT
    BLENDER_PATH            Override path to the `blender` binary.
    NUSAMAI_PATH            Override path to the `nusamai` binary.
    USDZCONVERT_PATH        Override path to the `usdzconvert` script.
    PLATEAU_PIPELINE_KEEP_TMP=1   Keep intermediate .glb files for debugging.

EXAMPLES
    # Convert one Sendai Tsuchitoi tile to USDZ with LOD 2 (default).
    ./convert.sh \
        --input  ./input/Sendai_Tsuchitoi.gml \
        --output ../../Resources/Environment/Tsuchitoi.usdz

    # LOD 1 (coarser, smaller) for distant tiles.
    ./convert.sh --input ./input/Aobayama_03.gml \
                 --output ../../Resources/Environment/Aobayama_03.usdz \
                 --lod 1

FURTHER READING
    Tools/plateau-pipeline/README.md       (概要)
    Tools/plateau-pipeline/INSTALL.md      (install each dependency)
    Docs/AssetPipeline.md                  (overall asset flow)
    GDD.md §7                              (design intent)

EOF
}

# ----------------------------------------------------------------------------
# Argument parsing.
# ----------------------------------------------------------------------------
INPUT=""
OUTPUT=""
LOD=""

# No args -> print help and exit 0 (spec requires non-error help path).
if [ "$#" -eq 0 ]; then
    print_help
    exit 0
fi

while [ "$#" -gt 0 ]; do
    case "$1" in
        -h|--help)
            print_help
            exit 0
            ;;
        --input)
            [ "$#" -ge 2 ] || { log_error "--input requires a value"; exit 2; }
            INPUT="$2"
            shift 2
            ;;
        --output)
            [ "$#" -ge 2 ] || { log_error "--output requires a value"; exit 2; }
            OUTPUT="$2"
            shift 2
            ;;
        --lod)
            [ "$#" -ge 2 ] || { log_error "--lod requires a value"; exit 2; }
            LOD="$2"
            shift 2
            ;;
        --)
            shift
            break
            ;;
        *)
            log_error "Unknown argument: $1"
            echo ""
            print_help
            exit 2
            ;;
    esac
done

# ----------------------------------------------------------------------------
# Load defaults from lod_config.json (graceful fall back if parse fails).
# ----------------------------------------------------------------------------
DEFAULT_LOD=2
if [ -f "$LOD_CONFIG" ] && command -v python3 >/dev/null 2>&1; then
    # If reading fails, keep compiled-in default.
    LOD_FROM_CONFIG="$(python3 -c "import json,sys
try:
    cfg = json.load(open('$LOD_CONFIG'))
    print(cfg.get('default_lod', 2))
except Exception:
    print(2)" 2>/dev/null || echo 2)"
    if [[ "$LOD_FROM_CONFIG" =~ ^[0-9]+$ ]]; then
        DEFAULT_LOD="$LOD_FROM_CONFIG"
    fi
fi

LOD="${LOD:-$DEFAULT_LOD}"

# ----------------------------------------------------------------------------
# Argument validation.
# ----------------------------------------------------------------------------
if [ -z "$INPUT" ]; then
    log_error "--input is required."
    echo ""
    print_help
    exit 2
fi

if [ -z "$OUTPUT" ]; then
    log_error "--output is required."
    echo ""
    print_help
    exit 2
fi

if [[ ! "$LOD" =~ ^[0-9]+$ ]] || [ "$LOD" -gt 3 ]; then
    log_error "--lod must be an integer in 0..3, got: $LOD"
    exit 2
fi

if [ ! -f "$INPUT" ]; then
    log_error "Input file not found: $INPUT"
    exit 1
fi

# Reject obviously wrong extensions but do not hard-fail (CityGML allows
# .gml / .xml / .citygml variants).
case "$INPUT" in
    *.gml|*.GML|*.xml|*.XML|*.citygml|*.CityGML)
        ;;
    *)
        log_warn "Input does not look like CityGML (.gml/.xml/.citygml): $INPUT"
        ;;
esac

# Normalise output to absolute path (portable via python3).
OUTPUT_ABS="$(python3 -c "import os,sys; print(os.path.abspath(sys.argv[1]))" "$OUTPUT")"
OUTPUT_DIR="$(dirname "$OUTPUT_ABS")"
mkdir -p "$OUTPUT_DIR"

case "$OUTPUT_ABS" in
    *.usdz|*.USDZ)
        ;;
    *)
        log_warn "Output does not end in .usdz: $OUTPUT_ABS"
        ;;
esac

# ----------------------------------------------------------------------------
# Tool discovery.
# ----------------------------------------------------------------------------
# 1) nusamai (plateau-gis-converter CLI) - REQUIRED.
NUSAMAI_BIN="${NUSAMAI_PATH:-}"
if [ -z "$NUSAMAI_BIN" ]; then
    if command -v nusamai >/dev/null 2>&1; then
        NUSAMAI_BIN="$(command -v nusamai)"
    fi
fi
if [ -z "$NUSAMAI_BIN" ] || [ ! -x "$NUSAMAI_BIN" ]; then
    log_error "nusamai (plateau-gis-converter) not found."
    cat >&2 <<'EOF'
  Install:
    - Releases:  https://github.com/MIERUNE/plateau-gis-converter/releases
                 https://github.com/Project-PLATEAU/PLATEAU-GIS-Converter/releases
    - macOS (Apple Silicon): download nusamai-<VERSION>-aarch64-apple-darwin.tar.gz,
      then:
          tar -xzf nusamai-*-aarch64-apple-darwin.tar.gz
          xattr -d com.apple.quarantine nusamai   # release Gatekeeper
          sudo install -m 755 nusamai /usr/local/bin/nusamai
    - Or set NUSAMAI_PATH=/abs/path/to/nusamai before running this script.
EOF
    exit 127
fi

# 2) Blender - REQUIRED.
BLENDER_BIN="${BLENDER_PATH:-}"
if [ -z "$BLENDER_BIN" ]; then
    if command -v blender >/dev/null 2>&1; then
        BLENDER_BIN="$(command -v blender)"
    elif [ -x "/Applications/Blender.app/Contents/MacOS/Blender" ]; then
        BLENDER_BIN="/Applications/Blender.app/Contents/MacOS/Blender"
    fi
fi
if [ -z "$BLENDER_BIN" ] || [ ! -x "$BLENDER_BIN" ]; then
    log_error "Blender not found."
    cat >&2 <<'EOF'
  Install:
    - Official:  https://www.blender.org/download/      (Blender 4.0+)
    - Homebrew:  brew install --cask blender
    - Or set BLENDER_PATH=/abs/path/to/blender before running this script.
    - On macOS the app is typically at:
        /Applications/Blender.app/Contents/MacOS/Blender
EOF
    exit 127
fi

if [ ! -f "$BLENDER_SCRIPT" ]; then
    log_error "Missing companion script: $BLENDER_SCRIPT"
    exit 1
fi

# 3) usdzconvert - OPTIONAL.
USDZCONVERT_BIN="${USDZCONVERT_PATH:-}"
if [ -z "$USDZCONVERT_BIN" ]; then
    if command -v usdzconvert >/dev/null 2>&1; then
        USDZCONVERT_BIN="$(command -v usdzconvert)"
    fi
fi
HAVE_USDZCONVERT=0
if [ -n "$USDZCONVERT_BIN" ] && [ -x "$USDZCONVERT_BIN" ]; then
    HAVE_USDZCONVERT=1
fi

log_info "nusamai:     $NUSAMAI_BIN"
log_info "blender:     $BLENDER_BIN"
if [ "$HAVE_USDZCONVERT" -eq 1 ]; then
    log_info "usdzconvert: $USDZCONVERT_BIN"
else
    log_warn "usdzconvert: NOT FOUND (final .usdz step will be manual)"
fi
log_info "input:       $INPUT"
log_info "output:      $OUTPUT_ABS"
log_info "lod:         $LOD"

# ----------------------------------------------------------------------------
# Temporary workspace with cleanup trap.
# ----------------------------------------------------------------------------
TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/sdglab-plateau.XXXXXXXX")"

cleanup() {
    local code=$?
    if [ "${PLATEAU_PIPELINE_KEEP_TMP:-0}" = "1" ]; then
        log_info "keeping tmp dir (PLATEAU_PIPELINE_KEEP_TMP=1): $TMP_DIR"
    else
        rm -rf "$TMP_DIR"
    fi
    if [ "$code" -ne 0 ]; then
        log_error "pipeline failed with exit code $code"
    fi
    exit "$code"
}
trap cleanup EXIT INT TERM

STAGE1_GLB="$TMP_DIR/stage1_raw.glb"
STAGE2_GLB="$TMP_DIR/stage2_toon.glb"

# ----------------------------------------------------------------------------
# Stage 1: CityGML -> glTF via nusamai.
# ----------------------------------------------------------------------------
log_info "stage 1/3: nusamai -> $STAGE1_GLB"
"$NUSAMAI_BIN" \
    "$INPUT" \
    --sink gltf \
    --output "$STAGE1_GLB" \
    -t "max_lod=$LOD"

if [ ! -s "$STAGE1_GLB" ]; then
    log_error "nusamai produced no/empty output at $STAGE1_GLB"
    exit 1
fi
log_ok "stage 1 done"

# ----------------------------------------------------------------------------
# Stage 2: Blender batch simplify (Phase 0 placeholder for Toon).
# ----------------------------------------------------------------------------
log_info "stage 2/3: blender --background $BLENDER_SCRIPT"
"$BLENDER_BIN" --background --factory-startup \
    --python "$BLENDER_SCRIPT" \
    -- \
    --input  "$STAGE1_GLB" \
    --output "$STAGE2_GLB" \
    --config "$LOD_CONFIG"

if [ ! -s "$STAGE2_GLB" ]; then
    log_error "blender produced no/empty output at $STAGE2_GLB"
    exit 1
fi
log_ok "stage 2 done"

# ----------------------------------------------------------------------------
# Stage 3: glb -> usdz.
# ----------------------------------------------------------------------------
log_info "stage 3/3: glb -> usdz"
if [ "$HAVE_USDZCONVERT" -eq 1 ]; then
    "$USDZCONVERT_BIN" "$STAGE2_GLB" "$OUTPUT_ABS"
    if [ ! -s "$OUTPUT_ABS" ]; then
        log_error "usdzconvert produced no/empty output at $OUTPUT_ABS"
        exit 1
    fi
    log_ok "stage 3 done"
else
    # No CLI available. Park the intermediate next to the intended USDZ output
    # so the user can drop it into Reality Converter manually.
    MANUAL_GLB="${OUTPUT_ABS%.*}.glb"
    cp "$STAGE2_GLB" "$MANUAL_GLB"
    log_warn "usdzconvert not installed. Manual step required:"
    log_warn "  1. Open Reality Converter (https://developer.apple.com/augmented-reality/tools/)"
    log_warn "  2. Drop this file into it:"
    log_warn "        $MANUAL_GLB"
    log_warn "  3. Export as:"
    log_warn "        $OUTPUT_ABS"
    log_warn "  (or install usdzconvert and re-run - see INSTALL.md)"
fi

log_ok "pipeline complete: $OUTPUT_ABS"
