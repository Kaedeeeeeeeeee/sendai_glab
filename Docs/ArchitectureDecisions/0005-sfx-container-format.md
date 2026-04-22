# ADR-0005: SFX container format (M4A/AAC, not OGG Vorbis)

- **Status**: Accepted
- **Date**: 2026-04-22
- **Context**: Phase 3 audio fix (branch `fix/phase-3-audio-deep-dive`)

## Decision

All shipped SFX cues are stored as **`.m4a` (AAC, 96 kbps)** in
`Resources/Audio/SFX/`. The OGG originals from kenney.nl live under
`Tools/audio-pipeline/source/Audio/SFX/` and are transcoded by
`Tools/audio-pipeline/transcode_ogg_to_m4a.sh` on import.

`AudioService.pickURL` looks up `withExtension: "m4a"`.

## Context

Phase 2 Starter imported Kenney's free SFX packs, which ship as
Ogg Vorbis, into `Resources/Audio/SFX/` directly. In two subsequent
playtests, every SFX played silently on the iPad. Phase 2 Alpha's PR #6
"root-level fallback" for bundle layout (previously suspected as the
cause) did not resolve it.

Root cause, identified in this ADR: **iOS's `AVAudioPlayer` has no
Ogg Vorbis decoder.** `AVAudioPlayer(contentsOf: oggURL)` throws
`NSOSStatusErrorDomain Code=-39` (`fnfErr`-adjacent generic
"file format not supported"), and `AudioService.makePlayer`
caught-and-swallowed the error returning `nil`. Every call site
fire-and-forgets, so the whole audio system no-op'd with no surfaced
signal.

Apple's supported input formats for `AVAudioPlayer` are: MP3, AAC
(in M4A/CAF), Apple Lossless (ALAC), AIFF, and PCM WAV. Ogg is
supported only via `AVAudioEngine` + a third-party decoder (libvorbis
bridged to Core Audio).

## Options considered

1. **Ship `.m4a` (chosen).** AAC is Apple-native, decoded in hardware,
   has no licensing cost for game distribution, and produces files
   comparable in size to OGG for short SFX (~100–300 bytes/second at
   96 kbps, vs. OGG's ~120 bytes/second at similar quality). Pipeline
   via ffmpeg; offline; idempotent.
2. **Ship `.caf` (Apple Core Audio Format).** Also first-class on iOS.
   Slightly more efficient for uncompressed cues, but AAC-in-M4A is
   just as fast for compressed payloads and M4A is more portable for
   macOS tooling.
3. **Switch runtime to `AVAudioEngine` with a custom Ogg decoder.**
   Drops libvorbis into the project (+binary size, +Swift-package
   maintenance), rewrites `AudioService` around `AVAudioPlayerNode`
   (+complexity). No user-visible gain. Rejected.
4. **Ship `.wav` uncompressed.** Bloats SFX ~10× for zero quality win
   at this sample-rate / duration. Rejected.

## Consequences

- **Positive**:
  - Audio actually plays on device (the whole point).
  - Zero runtime cost: AAC is hardware-decoded.
  - `AudioService.makePlayer` now logs decoder failures via `os.log`
    (subsystem `jp.tohoku-gakuin.fshera.sendai-glab`, category
    `audio`). Future format mismatches surface in Console.app
    immediately, no more silent failures.
  - Pipeline is idempotent and driven by a shell script, so adding
    new kenney cues in future iterations is `cp ogg → transcode`.
  - OGG originals preserved under `Tools/audio-pipeline/source/`
    for re-runs.
- **Negative**:
  - Two assets per cue in source control (OGG archive + M4A shipped).
    Total footprint still trivial (~440 KB for 22 cues combined).
  - Pipeline depends on `ffmpeg` being installed locally. Noted in
    the script's error message; `brew install ffmpeg` is a common
    prerequisite anyway (used by other Tools/ pipelines).

## Implementation

- `Tools/audio-pipeline/transcode_ogg_to_m4a.sh` — batch driver (idempotent).
- `Tools/audio-pipeline/source/Audio/SFX/` — archived OGG originals.
- `Resources/Audio/SFX/**/*.m4a` — 22 shipped cues.
- `AudioService`:
  - `withExtension: "m4a"` (was `"ogg"`).
  - `os.Logger` wired into `makePlayer` catch + `pickURL` missing-resource path.
- `SDGPlatform` testTarget gains a `Fixtures/Audio/SFX/ui/UI_Tap.m4a`
  fixture + `testPlayResolvesAndCachesForRealM4AFixture` which
  exercises `AVAudioPlayer` on a real shipping asset. This is the
  regression guard: if someone ever drops OGG back into Resources,
  the unit test stays green but the fixture test proves we still
  ship a working format.

## References

- WWDC 2015 "What's new in AVFoundation" — AVAudioPlayer decoder list.
- Apple docs: `AVAudioPlayer` (Supported audio file formats: AAC,
  MP3, WAV, AIFF, ALAC, AMR Narrowband).
- Kenney.nl asset packs (CC0) — original OGG source.
