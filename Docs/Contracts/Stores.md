# SDG-Lab Store Catalog

> Single source of truth for all `Store` implementations. Per
> [ADR-0001 §2](../ArchitectureDecisions/0001-layered-architecture.md),
> Stores MUST NOT reference each other directly — all cross-Store
> communication goes through [`EventBus`](../ArchitectureDecisions/0003-event-bus-design.md).
>
> Status legend:
> - 🟢 **Active** — used in Phase 1 POC
> - 🟡 **Defined** — class exists, not yet wired into the App
> - 🔴 **Deprecated** — scheduled for removal

## Format

Every Store is an `@Observable` `final class` on `@MainActor`, conforming
to [`protocol Store`](../../Packages/SDGCore/Sources/SDGCore/Store/Store.swift).
Per `Store.swift:20-23`:

- Stores MUST NOT `import SwiftUI` or `import RealityKit` — *exception*:
  `PlayerControlStore` does import RealityKit because its job is to mirror
  intent into an `Entity`'s `PlayerInputComponent`; the rationale is
  explained in detail at [`PlayerControlStore.swift:14-49`](../../Packages/SDGGameplay/Sources/SDGGameplay/Player/PlayerControlStore.swift).
- Stores MUST NOT hold a reference to another `Store`.
- Stores communicate cross-module via `EventBus` only.

## Summary

| Store | File | Status | Intent cases | Publishes | Subscribes | Lifecycle |
|---|---|---|---|---|---|---|
| [`PlayerControlStore`](#playercontrolstore) | `SDGGameplay/Player/PlayerControlStore.swift` | 🟢 | `.move(SIMD2<Float>)`, `.look(SIMD2<Float>)`, `.stop` | `PlayerMoveIntentChanged` | — | `init(eventBus:)` + `attach(playerEntity:)` / `detach()`; no async start/stop |
| [`DrillingStore`](#drillingstore) | `SDGGameplay/Drilling/DrillingStore.swift` | 🟢 | `.drillAt(origin:, direction:, maxDepth:)` | `DrillRequested` | `DrillCompleted`, `DrillFailed` | `init(eventBus:)` → `start()` → `stop()` (both idempotent) |
| [`InventoryStore`](#inventorystore) | `SDGGameplay/Samples/InventoryStore.swift` | 🟢 | `.select(SampleItem.ID?)`, `.delete(SampleItem.ID)`, `.clearAll`, `.updateNote(SampleItem.ID, String?)` | — | `SampleCreatedEvent` | `init(eventBus:, persistence:)` → `start()` → `stop()` (both idempotent) |

---

## Detailed spec

### `PlayerControlStore`

- **File**: [`Packages/SDGGameplay/Sources/SDGGameplay/Player/PlayerControlStore.swift`](../../Packages/SDGGameplay/Sources/SDGGameplay/Player/PlayerControlStore.swift)
- **Declaration**: `PlayerControlStore.swift:68-70` — `@MainActor @Observable public final class PlayerControlStore: Store`
- **Status**: 🟢 Active
- **Intent** (`PlayerControlStore.swift:74-91`, `enum Intent: Sendable, Equatable`):
  - `.move(SIMD2<Float>)` — virtual joystick moved. Axis must be on the unit disk (`length ≤ 1`); the joystick view is responsible for clamping + dead-zone filtering before handing it here (`PlayerControlStore.swift:77-79`).
  - `.look(SIMD2<Float>)` — right-half-screen pan delivered a yaw/pitch delta in **radians**. Deltas are *added* to the pending look buffer; the System drains the buffer each frame (`PlayerControlStore.swift:82-84`).
  - `.stop` — user lifted their finger off the joystick. Equivalent to `.move(.zero)` semantically but kept distinct so subscribers can distinguish "paused" from "actively centering" (`PlayerControlStore.swift:86-90`).
- **State** (`PlayerControlStore.swift:96-103`):
  - `currentMoveAxis: SIMD2<Float> = .zero` — current move axis, already clamped to the unit disk. Read by SwiftUI views that want a trailing joystick indicator.
  - `pendingLookDelta: SIMD2<Float> = .zero` — look delta accumulated since the last System update. **Not** a HUD value — drained to zero every frame by `PlayerControlSystem`. Exposed for tests.
- **Side effects on Entity** (`PlayerControlStore.swift:113-114`, `:128-133`, `:165-180`, `:185-195`):
  - Holds a `weak var playerEntity: Entity?`, attached via `attach(playerEntity:)` and cleared via `detach()`.
  - On `.move` / `.stop`: writes `PlayerInputComponent.moveAxis` on the attached entity.
  - On `.look`: writes `PlayerInputComponent.lookDelta` on the attached entity *and* accumulates into its own `pendingLookDelta`.
  - Architectural rationale for the Store-writes-Component pattern is spelled out at `PlayerControlStore.swift:14-43` ("option c" over pull-from-Store or events-only).
- **Publishes**:
  - `PlayerMoveIntentChanged(axis:)` at `PlayerControlStore.swift:179` — only on `.move`/`.stop` transitions where the axis value *actually changed* (equality guard at `PlayerControlStore.swift:166`).
  - *No event is fired for `.look`* — per comment at `PlayerControlStore.swift:193-194`, `PlayerLookApplied` is reserved for `PlayerControlSystem` to publish after the rotation lands, not when intent arrives.
- **Subscribes**: — (none)
- **Lifecycle**:
  - `init(eventBus: EventBus)` (`PlayerControlStore.swift:118-120`) — stores the bus; no I/O, no subscription.
  - `attach(playerEntity: Entity)` (`PlayerControlStore.swift:128-133`) — MUST be called once before `.move`/`.look` intents can affect the world. Calling twice silently replaces the target (useful for scene reloads / tests).
  - `detach()` (`PlayerControlStore.swift:137-139`) — drops the entity reference during scene teardown.
  - `resetForTesting()` (`PlayerControlStore.swift:200-206`) — public test hook; not for production code.
  - **No `start()` / `stop()`** because the Store is a one-way forwarder (UI → Entity + event); it never subscribes to anything.

### `DrillingStore`

- **File**: [`Packages/SDGGameplay/Sources/SDGGameplay/Drilling/DrillingStore.swift`](../../Packages/SDGGameplay/Sources/SDGGameplay/Drilling/DrillingStore.swift)
- **Declaration**: `DrillingStore.swift:52-54` — `@Observable @MainActor public final class DrillingStore: Store`
- **Status**: 🟢 Active
- **Intent** (`DrillingStore.swift:62-72`, `enum Intent: Sendable, Equatable`):
  - `.drillAt(origin: SIMD3<Float>, direction: SIMD3<Float>, maxDepth: Float)` — drill from `origin` along `direction` up to `maxDepth` metres. `direction` is expected to be a unit vector; Phase 1 callers always pass `(0, -1, 0)` (`DrillingStore.swift:67-71`).
  - The `enum` shape is kept deliberately so future commands (e.g. `.drillTowerSlot(Int)`) don't break source compatibility (`DrillingStore.swift:60-61`).
- **State** (`DrillingStore.swift:90-100`):
  - `status: Status = .idle` — observable drill state machine. `Status` cases:
    - `.idle`
    - `.drilling`
    - `.lastCompleted(sampleId: UUID, at: Date)`
    - `.lastFailed(reason: String, at: Date)`
  - **Transitions** (`DrillingStore.swift:78-89`):
    - `.idle` → `.drilling` on every `.drillAt` intent.
    - `.drilling` → `.lastCompleted(sampleId, at)` on `DrillCompleted`.
    - `.drilling` → `.lastFailed(reason, at)` on `DrillFailed`.
    - Any terminal state → `.drilling` on another `.drillAt` intent (re-drilling overrides the banner).
  - `.lastCompleted` / `.lastFailed` are sticky — they stay until the next drill attempt, so UI code can drive a transient toast/banner without an extra clearing intent.
- **Publishes**:
  - `DrillRequested(origin:, direction:, maxDepth:, requestedAt: Date())` at `DrillingStore.swift:164-171`. The Store flips `status` to `.drilling` *before* publishing so in-flight state is observable to tests (`DrillingStore.swift:162-163`).
- **Subscribes**:
  - `DrillCompleted` — subscribed in `start()` at `DrillingStore.swift:130-133`; handler `handleDrillCompleted` at `DrillingStore.swift:180-182` sets `status = .lastCompleted(sampleId: event.sampleId, at: Date())`.
  - `DrillFailed` — subscribed in `start()` at `DrillingStore.swift:135-138`; handler `handleDrillFailed` at `DrillingStore.swift:184-186` sets `status = .lastFailed(reason: event.reason, at: Date())`.
- **Lifecycle**:
  - `init(eventBus: EventBus)` (`DrillingStore.swift:118-120`) — stores the bus; no subscription.
  - `start() async` (`DrillingStore.swift:128-139`) — subscribes to both events. **Idempotent**: a second call is a no-op (guarded by `completedToken == nil` / `failedToken == nil`).
  - `stop() async` (`DrillingStore.swift:143-152`) — cancels both subscriptions. Safe to call repeatedly; safe to call without a prior `start()`.

### `InventoryStore`

- **File**: [`Packages/SDGGameplay/Sources/SDGGameplay/Samples/InventoryStore.swift`](../../Packages/SDGGameplay/Sources/SDGGameplay/Samples/InventoryStore.swift)
- **Declaration**: `InventoryStore.swift:40-42` — `@Observable @MainActor public final class InventoryStore: Store`
- **Status**: 🟢 Active
- **Intent** (`InventoryStore.swift:46-55`, `enum Intent: Sendable`):
  - `.select(SampleItem.ID?)` — highlight (or deselect with `nil`) a sample in the UI (`InventoryStore.swift:48`).
  - `.delete(SampleItem.ID)` — remove the sample with the given id, if present (`InventoryStore.swift:50`).
  - `.clearAll` — drop every sample; used by "new game" / settings-level reset (`InventoryStore.swift:52`).
  - `.updateNote(SampleItem.ID, String?)` — replace the custom note for a single sample; `nil` clears it (`InventoryStore.swift:54`).
- **State** (`InventoryStore.swift:59-64`):
  - `samples: [SampleItem] = []` — all collected samples in collection order (append-on-create).
  - `selectedId: SampleItem.ID? = nil` — id of the sample currently selected in the UI, if any. Cleared when the selected sample is deleted or the inventory is emptied (`InventoryStore.swift:135-137`, `:142-143`).
- **Intent handlers** (`InventoryStore.swift:129-152`):
  - `.select`: sets `selectedId` directly.
  - `.delete`: removes the sample and clears `selectedId` if it matched; then persists.
  - `.clearAll`: empties `samples`, clears `selectedId`, persists.
  - `.updateNote`: mutates `samples[idx].customNote`, persists.
  - All mutations other than `.select` go through `persistIgnoringFailure()` (`InventoryStore.swift:161-167`) — "best-effort save; persistence failure must not crash gameplay".
- **Publishes**: — (none)
- **Subscribes**:
  - `SampleCreatedEvent` — subscribed in `start()` at `InventoryStore.swift:103-107`; handler `handleSampleCreated` at `InventoryStore.swift:122-125` appends `event.sample` to `samples` and persists.
- **Lifecycle**:
  - `init(eventBus: EventBus, persistence: InventoryPersistence = .standard)` (`InventoryStore.swift:78-84`) — wires dependencies; no I/O, no subscription. `.standard` uses `UserDefaults.standard`; tests pass `.inMemory`.
  - `start() async` (`InventoryStore.swift:95-108`) — hydrates from persistence (`try? persistence.load()`, corrupt/missing blobs are treated as "start empty") then subscribes. **Idempotent on the subscription**: a second call re-loads from disk but keeps the original subscription (guarded by `subscriptionToken == nil`).
  - `stop() async` (`InventoryStore.swift:112-116`) — cancels the subscription. Safe to call multiple times; safe to call without a prior `start()`.
  - No auto-cancel in `deinit` — Swift does not allow `async` work inside `deinit`; see the design note at `InventoryStore.swift:25-33`.

---

## Maintenance

1. Every new `: Store` conformer requires a summary-table row and a "Detailed spec" section.
2. When you add / remove an Intent case, update "Intent" bullets *and* the summary-table cell in the same PR.
3. When you wire a new subscription in `start()` (or remove one), update "Subscribes" and cross-reference Events.md.
4. Any new `publish(...)` call inside a Store's `intent(_:)` handler must show up under "Publishes" and trigger a matching "Published by" row in Events.md.
5. See AGENTS.md §4.1 for the binding rule.
