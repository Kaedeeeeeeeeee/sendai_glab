#!/usr/bin/env bash
# transcode_ogg_to_m4a.sh
# Tools/audio-pipeline
#
# Batch-transcode every .ogg file under Resources/Audio/SFX/ into a
# sibling .m4a (AAC, 96 kbps). iOS AVAudioPlayer does NOT support
# Ogg Vorbis natively — the Phase 2 SFX imported from kenney.nl all
# failed silently in production because `AVAudioPlayer(contentsOf:)`
# threw and AudioService.makePlayer returned nil. See
# Docs/ArchitectureDecisions/ (to-be-written) for the full postmortem.
#
# Usage:
#   bash Tools/audio-pipeline/transcode_ogg_to_m4a.sh
#
# Idempotent: skips any .ogg that already has a sibling .m4a with a
# newer mtime.
#
# Source files live alongside outputs; keep the OGG originals in-tree
# (Tools/audio-pipeline/source/) so the pipeline can be re-run after
# new kenney packs are imported.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SFX_DIR="$REPO_ROOT/Resources/Audio/SFX"

if [[ ! -d "$SFX_DIR" ]]; then
  echo "error: $SFX_DIR does not exist" >&2
  exit 1
fi

if ! command -v ffmpeg >/dev/null 2>&1; then
  echo "error: ffmpeg not found on PATH. Install with 'brew install ffmpeg'." >&2
  exit 1
fi

# 96 kbps AAC is plenty for short UI/SFX cues and matches
# Apple's default for "Effects" in GarageBand exports. Higher bitrates
# waste bundle size for sub-second samples.
BITRATE="96k"

converted=0
skipped=0
failed=0

while IFS= read -r -d '' ogg; do
  m4a="${ogg%.ogg}.m4a"
  if [[ -f "$m4a" && "$m4a" -nt "$ogg" ]]; then
    skipped=$((skipped + 1))
    continue
  fi

  # -y overwrite; -nostdin so CI / batch jobs can't block on prompts.
  # -loglevel error silences per-file banners; we print our own summary.
  if ffmpeg -nostdin -y -loglevel error \
       -i "$ogg" -c:a aac -b:a "$BITRATE" "$m4a"; then
    converted=$((converted + 1))
    printf "  ✓ %s → %s\n" "$(basename "$ogg")" "$(basename "$m4a")"
  else
    failed=$((failed + 1))
    printf "  ✗ %s FAILED\n" "$(basename "$ogg")" >&2
  fi
done < <(find "$SFX_DIR" -type f -name '*.ogg' -print0)

echo
echo "Done. converted=$converted skipped=$skipped failed=$failed"
if [[ "$failed" -gt 0 ]]; then
  exit 2
fi
