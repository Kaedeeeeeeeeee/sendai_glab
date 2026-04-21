# SDG-Lab Event Catalog

> Single source of truth for all cross-module events. Every cross-Store
> communication in this project happens via these events (per
> [ADR-0001 §3](../ArchitectureDecisions/0001-layered-architecture.md) /
> [ADR-0003](../ArchitectureDecisions/0003-event-bus-design.md)).
> **Adding a new event requires a row here.**
>
> Status legend:
> - 🟢 **Active** — published *and* subscribed in Phase 1
> - 🟡 **Defined** — struct exists, at least one end of the pipe is not wired
> - 🔴 **Deprecated** — scheduled for removal

## Format

Every event is `Sendable + Codable` (enforced by
[`protocol GameEvent`](../../Packages/SDGCore/Sources/SDGCore/EventBus/GameEvent.swift)).
Conformers should be small value types (`struct`). Do not attach
references to live gameplay objects (Entities, Stores) — include only
plain data (`GameEvent.swift:17-18`).

## Summary

| Event | Status | Module | Published By | Subscribed By | Purpose |
|---|---|---|---|---|---|
| [`PlayerMoveIntentChanged`](#playermoveintentchanged) | 🟢 | `SDGGameplay/Player` | `PlayerControlStore.apply(move:)` | Phase 1: `RootView` debug logger only | Notify HUD / analytics of joystick axis transitions |
| [`PlayerLookApplied`](#playerlookapplied) | 🟡 | `SDGGameplay/Player` | — (reserved for `PlayerControlSystem`, not yet published) | — (none) | Future: surface per-frame yaw/pitch applied by the System |
| [`DrillRequested`](#drillrequested) | 🟢 | `SDGGameplay/Drilling` | `DrillingStore.intent(.drillAt)` | `DrillingOrchestrator.start()` | Fan a drill request out from the Store to the scene-side orchestrator |
| [`DrillCompleted`](#drillcompleted) | 🟢 | `SDGGameplay/Drilling` | `DrillingOrchestrator.performDrill` (success branch) | `DrillingStore.start()` | Status / SFX / analytics hook after a successful drill |
| [`DrillFailed`](#drillfailed) | 🟢 | `SDGGameplay/Drilling` | `DrillingOrchestrator.performDrill` (two failure branches) | `DrillingStore.start()` | Status / UI hook for drill misses and scene-unavailable errors |
| [`SampleCreatedEvent`](#samplecreatedevent) | 🟢 | `SDGGameplay/Samples` | `DrillingOrchestrator.performDrill` (success branch) | `InventoryStore.start()` | Hand a completed `SampleItem` to the inventory |
| [`PanEvent`](#panevent) | 🟡 | `SDGPlatform` | — (`TouchInputService.publish(pan:)` exists; no current caller) | — (none) | Generic pan sample envelope; not yet used in Phase 1 |
| [`LookPanEvent`](#lookpanevent) | 🟡 | `SDGPlatform` | `RootView.lookGesture.onChanged` (and `TouchInputService.publish(look:)`) | — (none) | Raw right-half-screen pan delta — no in-app subscriber yet, exposed for future replay / analytics |

---

## Detailed spec

### `PlayerMoveIntentChanged`

- **File**: [`Packages/SDGGameplay/Sources/SDGGameplay/Player/PlayerEvents.swift`](../../Packages/SDGGameplay/Sources/SDGGameplay/Player/PlayerEvents.swift)
- **Declaration**: `PlayerEvents.swift:28` — `public struct PlayerMoveIntentChanged: GameEvent, Equatable`
- **Status**: 🟢 Active
- **Fields**:
  - `axis: SIMD2<Float>` — horizontal movement axis on the unit disk. `x` = strafe (+right), `y` = forward (+forward in SwiftUI convention, i.e. away from the camera). `.zero` means "stick released". (`PlayerEvents.swift:31-32`)
- **Published by**:
  - `PlayerControlStore.apply(move:)` — [`PlayerControlStore.swift:179`](../../Packages/SDGGameplay/Sources/SDGGameplay/Player/PlayerControlStore.swift). Only fires when the axis value has *actually changed*; the equality guard at `PlayerControlStore.swift:166` keeps the bus quiet while the stick is at rest.
  - Triggered from intents `.move(SIMD2<Float>)` and `.stop` (the latter routes through `apply(move: .zero)`).
- **Subscribed by**:
  - [`SDGUI.RootView.body.task`](../../Packages/SDGUI/Sources/SDGUI/RootView.swift) at `RootView.swift:93` — Phase 1 POC subscription that simply `print`s the axis. Explicitly labelled "Log only. Real handlers (HUD compass, analytics) subscribe here in later phases." (`RootView.swift:94-95`).
  - (Tests: `PlayerControlStoreTests.swift:76` and `:92` also subscribe, test-only.)
- **Payload example** (JSON):
  ```json
  {
    "axis": [0.5, -0.3]
  }
  ```

### `PlayerLookApplied`

- **File**: [`Packages/SDGGameplay/Sources/SDGGameplay/Player/PlayerEvents.swift`](../../Packages/SDGGameplay/Sources/SDGGameplay/Player/PlayerEvents.swift)
- **Declaration**: `PlayerEvents.swift:48` — `public struct PlayerLookApplied: GameEvent, Equatable`
- **Status**: 🟡 Defined — the struct is reserved for `PlayerControlSystem` to publish once per frame after applying rotation, but as of Phase 1 the System integrates rotations without publishing this event. See the "No event here" note at `PlayerControlStore.swift:193`.
- **Fields**:
  - `yawDelta: Float` — yaw delta applied this frame, radians. Positive = right. (`PlayerEvents.swift:51`)
  - `pitchDelta: Float` — pitch delta applied this frame *after* clamping, radians. Positive = look up. (`PlayerEvents.swift:54-55`)
  - `accumulatedPitch: Float` — accumulated pitch (radians) after this frame's delta. Useful for HUDs that draw a horizon line. (`PlayerEvents.swift:58-59`)
- **Published by**: — (none yet; see *Status* above. Intended publisher: `PlayerControlSystem.applyInput` when `pitchDelta != 0` or `yawDelta != 0`.)
- **Subscribed by**: — (none)
- **Payload example** (JSON):
  ```json
  {
    "yawDelta": 0.01,
    "pitchDelta": -0.005,
    "accumulatedPitch": 0.12
  }
  ```

### `DrillRequested`

- **File**: [`Packages/SDGGameplay/Sources/SDGGameplay/Drilling/DrillingEvents.swift`](../../Packages/SDGGameplay/Sources/SDGGameplay/Drilling/DrillingEvents.swift)
- **Declaration**: `DrillingEvents.swift:35` — `public struct DrillRequested: GameEvent, Equatable`
- **Status**: 🟢 Active
- **Fields**:
  - `origin: SIMD3<Float>` — world-space start point of the drill, in metres. (`DrillingEvents.swift:37-38`)
  - `direction: SIMD3<Float>` — unit direction vector the drill travels. Phase 1 is always `(0, -1, 0)`. (`DrillingEvents.swift:41-43`)
  - `maxDepth: Float` — maximum drill depth along `direction`, in metres. Positive; `<= 0` is a no-op on the orchestrator. (`DrillingEvents.swift:45-47`)
  - `requestedAt: Date` — wall-clock timestamp at request time, carried so subscribers can correlate with the later `DrillCompleted`/`DrillFailed` without re-stamping. (`DrillingEvents.swift:49-52`)
- **Published by**:
  - `DrillingStore.intent(.drillAt)` — [`DrillingStore.swift:164-171`](../../Packages/SDGGameplay/Sources/SDGGameplay/Drilling/DrillingStore.swift). The Store flips `status` to `.drilling` *before* publishing so in-flight state is observable (`DrillingStore.swift:162-163`).
- **Subscribed by**:
  - `DrillingOrchestrator.start()` — [`DrillingSystem.swift:147`](../../Packages/SDGGameplay/Sources/SDGGameplay/Drilling/DrillingSystem.swift); dispatches to `handleDrillRequested` which calls `performDrill`.
- **Payload example** (JSON):
  ```json
  {
    "origin": [1.0, 2.0, 3.0],
    "direction": [0.0, -1.0, 0.0],
    "maxDepth": 2.0,
    "requestedAt": "2026-04-21T13:45:00Z"
  }
  ```

### `DrillCompleted`

- **File**: [`Packages/SDGGameplay/Sources/SDGGameplay/Drilling/DrillingEvents.swift`](../../Packages/SDGGameplay/Sources/SDGGameplay/Drilling/DrillingEvents.swift)
- **Declaration**: `DrillingEvents.swift:79` — `public struct DrillCompleted: GameEvent, Equatable`
- **Status**: 🟢 Active
- **Fields**:
  - `sampleId: UUID` — id of the sample that was just created. Matches `SampleItem.id`. (`DrillingEvents.swift:81-82`)
  - `layerCount: Int` — how many layers the drill cut through. `0` is impossible here — a zero-layer result takes the `DrillFailed` path instead. (`DrillingEvents.swift:84-86`)
  - `totalDepth: Float` — actual depth drilled, in metres. For a successful drill equals the supplied `maxDepth` clamped by the deepest layer the ray crossed. (`DrillingEvents.swift:88-91`)
- **Published by**:
  - `DrillingOrchestrator.performDrill` (success branch) — [`DrillingSystem.swift:231-237`](../../Packages/SDGGameplay/Sources/SDGGameplay/Drilling/DrillingSystem.swift). Published *after* `SampleCreatedEvent` (see `DrillingSystem.swift:225-230` for the ordering rationale).
- **Subscribed by**:
  - `DrillingStore.start()` — [`DrillingStore.swift:130-133`](../../Packages/SDGGameplay/Sources/SDGGameplay/Drilling/DrillingStore.swift); handler at `DrillingStore.swift:180-182` transitions `status` to `.lastCompleted(sampleId:, at: Date())`.
- **Payload example** (JSON):
  ```json
  {
    "sampleId": "11111111-1111-1111-1111-111111111111",
    "layerCount": 3,
    "totalDepth": 2.0
  }
  ```

### `DrillFailed`

- **File**: [`Packages/SDGGameplay/Sources/SDGGameplay/Drilling/DrillingEvents.swift`](../../Packages/SDGGameplay/Sources/SDGGameplay/Drilling/DrillingEvents.swift)
- **Declaration**: `DrillingEvents.swift:108` — `public struct DrillFailed: GameEvent, Equatable`
- **Status**: 🟢 Active
- **Fields**:
  - `origin: SIMD3<Float>` — world-space origin where the drill was attempted. Mirrors `DrillRequested.origin` so subscribers can correlate without joining. (`DrillingEvents.swift:111-113`)
  - `reason: String` — short machine-readable tag (not a localised string). Current vocabulary:
    - `"no_layers"` — ray missed every geology layer (`DrillingEvents.swift:105`)
    - `"scene_unavailable"` — orchestrator had no scene / entity root (`DrillingEvents.swift:106`)
    UI code resolves the user-facing string via `LocalizationService`.
- **Published by**:
  - `DrillingOrchestrator.performDrill` — two call sites:
    - [`DrillingSystem.swift:199-202`](../../Packages/SDGGameplay/Sources/SDGGameplay/Drilling/DrillingSystem.swift) — `outcropRootProvider() == nil` → `reason: "scene_unavailable"`.
    - [`DrillingSystem.swift:213-216`](../../Packages/SDGGameplay/Sources/SDGGameplay/Drilling/DrillingSystem.swift) — `intersections.isEmpty` → `reason: "no_layers"`.
- **Subscribed by**:
  - `DrillingStore.start()` — [`DrillingStore.swift:135-138`](../../Packages/SDGGameplay/Sources/SDGGameplay/Drilling/DrillingStore.swift); handler at `DrillingStore.swift:184-186` transitions `status` to `.lastFailed(reason:, at: Date())`.
- **Payload example** (JSON):
  ```json
  {
    "origin": [1.0, 2.0, 3.0],
    "reason": "no_layers"
  }
  ```

### `SampleCreatedEvent`

- **File**: [`Packages/SDGGameplay/Sources/SDGGameplay/Samples/SampleCreatedEvent.swift`](../../Packages/SDGGameplay/Sources/SDGGameplay/Samples/SampleCreatedEvent.swift)
- **Declaration**: `SampleCreatedEvent.swift:23` — `public struct SampleCreatedEvent: GameEvent`
- **Status**: 🟢 Active
- **Fields**:
  - `sample: SampleItem` — the completed sample. Value-typed, so the payload is a full copy; subscribers cannot mutate the producer's state by reference. (`SampleCreatedEvent.swift:25-27`). `SampleItem` carries `id`, `createdAt`, `drillLocation`, `drillDepth`, `layers: [SampleLayerRecord]`, `customNote` (see [`SampleItem.swift:30-56`](../../Packages/SDGGameplay/Sources/SDGGameplay/Samples/SampleItem.swift)).
- **Published by**:
  - `DrillingOrchestrator.performDrill` (success branch) — [`DrillingSystem.swift:230`](../../Packages/SDGGameplay/Sources/SDGGameplay/Drilling/DrillingSystem.swift). Published *before* `DrillCompleted` so the inventory ingest happens before any "new sample!" HUD toast reads inventory state (`DrillingSystem.swift:225-230`).
- **Subscribed by**:
  - `InventoryStore.start()` — [`InventoryStore.swift:103-107`](../../Packages/SDGGameplay/Sources/SDGGameplay/Samples/InventoryStore.swift); handler `handleSampleCreated` at `InventoryStore.swift:122-125` appends to `samples` and persists.
- **Payload example** (JSON):
  ```json
  {
    "sample": {
      "id": "11111111-1111-1111-1111-111111111111",
      "createdAt": "2026-04-21T13:45:00Z",
      "drillLocation": [1.0, 0.0, 3.0],
      "drillDepth": 2.0,
      "layers": [
        {
          "layerId": "aobayama.tuff",
          "nameKey": "geology.tuff",
          "colorRGB": [0.6, 0.55, 0.4],
          "thickness": 1.0,
          "entryDepth": 0.0
        }
      ],
      "customNote": null
    }
  }
  ```

### `PanEvent`

- **File**: [`Packages/SDGPlatform/Sources/SDGPlatform/TouchInputService.swift`](../../Packages/SDGPlatform/Sources/SDGPlatform/TouchInputService.swift)
- **Declaration**: `TouchInputService.swift:26` — `public struct PanEvent: GameEvent, Equatable`
- **Status**: 🟡 Defined — envelope type exists and `TouchInputService.publish(pan:)` is implemented (`TouchInputService.swift:106-108`), but no source file in Phase 1 currently calls it.
- **Fields**:
  - `dx: Double` — horizontal translation in points. Positive = finger moved right. (`TouchInputService.swift:28-29`)
  - `dy: Double` — vertical translation in points. Positive = finger moved down (SwiftUI convention preserved). (`TouchInputService.swift:31-33`)
- **Published by**: — (none in Phase 1 code paths; only the `TouchInputService.publish(pan:)` facade is available.)
- **Subscribed by**: — (none)
- **Payload example** (JSON):
  ```json
  {
    "dx": 12.0,
    "dy": -3.5
  }
  ```

### `LookPanEvent`

- **File**: [`Packages/SDGPlatform/Sources/SDGPlatform/TouchInputService.swift`](../../Packages/SDGPlatform/Sources/SDGPlatform/TouchInputService.swift)
- **Declaration**: `TouchInputService.swift:59` — `public struct LookPanEvent: GameEvent, Equatable`
- **Status**: 🟡 Defined — published from the UI layer, but Phase 1 has no business subscriber. Comment in `TouchInputService.swift:55-58` notes this is "raw screen-space point deltas; converting to radians is the consumer's responsibility".
- **Fields**:
  - `dx: Double` — horizontal delta since the previous look sample, in points. Positive = finger moved right. (`TouchInputService.swift:61-63`)
  - `dy: Double` — vertical delta since the previous look sample, in points. Positive = finger moved down (SwiftUI convention; callers invert for natural pitch). (`TouchInputService.swift:65-67`)
- **Published by**:
  - [`SDGUI.RootView.lookGesture.onChanged`](../../Packages/SDGUI/Sources/SDGUI/RootView.swift) at `RootView.swift:251` — published alongside `PlayerControlStore.intent(.look)` so subscribers that want "platform-level" look samples (e.g. a replay recorder) have a hook.
  - `TouchInputService.publish(look:)` at `TouchInputService.swift:116-118` is the public facade; `RootView` currently calls `bus.publish(...)` directly.
- **Subscribed by**: — (none in Phase 1)
- **Payload example** (JSON):
  ```json
  {
    "dx": 4.0,
    "dy": -2.0
  }
  ```

---

## Maintenance

1. Every new `: GameEvent` struct requires a summary-table row and a "Detailed spec" section.
2. When you wire or remove a publisher/subscriber, update the "Published by" / "Subscribed by" bullets *and* the summary-table cell in the same PR.
3. Promote a 🟡 event to 🟢 only after both a real publisher and a real subscriber (not a test) land.
4. See AGENTS.md §4.1 for the binding rule.
