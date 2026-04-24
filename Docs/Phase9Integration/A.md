# Phase 9 Part A — RootView integration notes

> Phase 8.1 "Disaster reaction polish" was implemented under branch
> `feat/phase-9-a-disaster-polish`. The subagent that authored the
> change was **not** allowed to modify `RootView.swift`; these are the
> minimal edits the integrating human (or next agent) must apply by
> hand before the new polish actually shows up in-game.

## Summary of new moving parts

| Symbol | Kind | Purpose |
| --- | --- | --- |
| `DisasterCameraShakeSystem` | RealityKit `System` (`SDGGameplay`) | First-person camera jitter while earthquake active |
| `PlayerComponent.isStaggered` | `Bool` on existing component | `DisasterSystem` flips it on; `PlayerControlSystem.applyInput` reads it and scales `moveAxis` by `staggeredMoveScale` (0.3) |
| `AudioService.play(_:volume:loops:)` | Extended API (`SDGPlatform`) | `loops: -1` to loop forever. Default `0` preserves every existing call site |
| `AudioService.stop(_:)` / `stop(category:)` / `stop(category:AudioCategory)` | New API (`SDGPlatform`) | Silences a cue / category on demand |
| `AudioCategory` | New enum (`SDGPlatform`) | Typed sibling of `AudioEffect.category` string |
| `DisasterAudioBridge` | Updated | Starts rumble with `loops: -1`; Ended handlers call `audio.stop(…)` |
| `DisasterSystem.applyPlayerStagger` | Internal helper | Every frame, mirrors `DisasterState.earthquakeActive` onto the `PlayerComponent.isStaggered` flag |

No existing `RootView` method signatures changed.
No existing `DebugActionsBar` buttons changed.

## What RootView.swift must change

### 1. Register `DisasterCameraShakeSystem` alongside `DisasterSystem`

Add exactly one line inside `registerSystemsOnce()`, right after
`DisasterSystem.registerSystem()`:

```swift
private static func registerSystemsOnce() {
    guard !systemsRegistered else { return }
    PlayerComponent.registerComponent()
    PlayerInputComponent.registerComponent()
    PlayerControlSystem.registerSystem()
    // Phase 8: Disaster components + System. DisasterSystem's
    // Store binding happens after bootstrap constructs the Store
    // (via `DisasterSystem.shared(...).bind(disasterStore:)`).
    DisasterShakeTargetComponent.registerComponent()
    DisasterFloodWaterComponent.registerComponent()
    DisasterSystem.registerSystem()
    // Phase 8.1: player-side shake. Reads `DisasterSystem.boundStore`
    // so no extra binding is needed; just register it after
    // `DisasterSystem` so the dependency order is stable.
    DisasterCameraShakeSystem.registerSystem()
    systemsRegistered = true
}
```

The new System reads `DisasterSystem.boundStore` directly — no
separate binding slot, no `@State` field on `RootView`, no teardown
wiring required.

### 2. (Optional but recommended) Drop the MVP `DisasterAudioBridge`
self-terminate assumption comment

Nothing in `bootstrap()` / `teardown()` needs code changes — the
bridge is already created, started, and stopped there. The updated
bridge simply does more under the hood.

Before shipping, scan `bootstrap()` for any comment claiming the
rumble "self-terminates" or `Phase 8.1 TODO: call stop`; those are
now stale. Grep term: `Phase 8.1` in `RootView.swift`.

### 3. No change needed to the corridor-tile tagging loop

The existing `corridor.children.forEach { $0.components.set(…) }`
block still applies `DisasterShakeTargetComponent` to each tile; the
new camera-shake system targets the *player* entity (not tiles) so
the tile tagging stays identical.

### 4. No change needed to `SendaiGLabApp`

Audio session category (`.playback` + `.mixWithOthers`) is still
correct. The added `loops: -1` relies on nothing new from the audio
session.

## Verification after integration

1. `swift test --package-path Packages/SDGGameplay` — should report
   **362** tests (baseline 354 + 8 new).
2. Device playtest checklist:
   - Tap 🌋 → camera visibly jitters (~8 cm peak), tiles shake as
     before, moving on the joystick feels "sluggish" (70 % speed
     reduction), rumble plays for the whole 2 s.
   - Tap 💧 → water plane rises as before, no rumble, no stagger,
     no camera shake.
   - After quake ends: camera returns to neutral, player speed
     snaps back to normal, rumble cuts off cleanly.
   - No residual dict entries: re-triggering 🌋 three times in a
     row produces identical behaviour each time.

## File index

- Added: `Packages/SDGGameplay/Sources/SDGGameplay/Disaster/DisasterCameraShakeSystem.swift`
- Added: `Packages/SDGGameplay/Tests/SDGGameplayTests/Disaster/DisasterCameraShakeSystemTests.swift`
- Modified: `Packages/SDGPlatform/Sources/SDGPlatform/Audio/AudioEffect.swift`
- Modified: `Packages/SDGPlatform/Sources/SDGPlatform/Audio/AudioService.swift`
- Modified: `Packages/SDGGameplay/Sources/SDGGameplay/Player/PlayerComponents.swift`
- Modified: `Packages/SDGGameplay/Sources/SDGGameplay/Player/PlayerControlSystem.swift`
- Modified: `Packages/SDGGameplay/Sources/SDGGameplay/Disaster/DisasterSystem.swift`
- Modified: `Packages/SDGGameplay/Sources/SDGGameplay/Disaster/DisasterAudioBridge.swift`
- Modified: `Packages/SDGGameplay/Tests/SDGGameplayTests/Audio/AudioEventBridgeTests.swift`
  (only the `RecordingAudioService` override signature; no behavioural change)
- Modified: `Packages/SDGGameplay/Tests/SDGGameplayTests/Disaster/DisasterAudioBridgeTests.swift`
- Modified: `Packages/SDGGameplay/Tests/SDGGameplayTests/Disaster/DisasterSystemTests.swift`
- Modified: `Packages/SDGGameplay/Tests/SDGGameplayTests/Player/PlayerControlSystemTests.swift`
