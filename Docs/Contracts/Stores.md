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
| [`VehicleStore`](#vehiclestore) | `SDGGameplay/Vehicles/VehicleStore.swift` | 🟡 | `.summon(VehicleType, position:)`, `.enter(vehicleId:)`, `.exit`, `.pilot(axis:, vertical:)` | `VehicleSummoned`, `VehicleEntered`, `VehicleExited` | — | `init(eventBus:)` + `register(entity:for:)` / `unregister(vehicleId:)`; no async start/stop |
| [`WorkbenchStore`](#workbenchstore) | `SDGGameplay/Workbench/WorkbenchStore.swift` | 🟡 | `.openWorkbench`, `.closeWorkbench`, `.selectSample(SampleItem.ID?)`, `.selectLayer(layerIndex: Int?)` | `WorkbenchOpened`, `SampleAnalyzed` | — | `init(eventBus:)`; no async start/stop (pure publisher) |
| [`QuestStore`](#queststore) | `SDGGameplay/Quest/QuestStore.swift` | 🟡 | `.start(questId:)`, `.completeObjective(questId:objectiveId:)`, `.markComplete(questId:)`, `.reset` | `QuestStarted`, `ObjectiveCompleted`, `QuestCompleted`, `RewardGranted` | `SampleCreatedEvent` | `init(eventBus:persistence:)` → `start()` → `stop()` (both idempotent) |
| [`DialogueStore`](#dialoguestore) | `SDGGameplay/Dialogue/DialogueStore.swift` | 🟡 | `.play(sequence: StorySequence)`, `.advance`, `.skipAll` | `DialoguePlayed`, `DialogueAdvanced`, `DialogueFinished` | — | `init(eventBus:)`; no async start/stop (pure publisher) |

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

### `VehicleStore`

- **File**: [`Packages/SDGGameplay/Sources/SDGGameplay/Vehicles/VehicleStore.swift`](../../Packages/SDGGameplay/Sources/SDGGameplay/Vehicles/VehicleStore.swift)
- **Declaration**: `VehicleStore.swift` — `@MainActor @Observable public final class VehicleStore: Store`
- **Status**: 🟡 Defined — the Store, its events, and the `VehicleControlSystem` are wired and tested in Phase 2 Beta; the RootView integration (camera re-parenting on `VehicleEntered`/`VehicleExited`, entity materialisation on `VehicleSummoned`) lands in a subsequent Phase 2 Beta wave.
- **Intent** (`VehicleStore.swift`, `enum Intent: Sendable, Equatable`):
  - `.summon(VehicleType, position: SIMD3<Float>)` — spawn a new vehicle. Store assigns the `UUID` and appends a `VehicleSnapshot` to `summonedVehicles`; callers read back from there.
  - `.enter(vehicleId: UUID)` — attempt to pilot. No-op if the id is unknown OR if the player is already occupying another vehicle (switching requires an explicit `.exit` first — mirrors camera rig symmetry).
  - `.exit` — stop piloting the currently-occupied vehicle. No-op when nothing is occupied.
  - `.pilot(axis: SIMD2<Float>, vertical: Float)` — latest joystick + climb sample. No-op while `occupiedVehicleId == nil`; when occupied, writes into the entity's `VehicleComponent` (if bound). Clamping of `axis` to the unit disk is the HUD's responsibility.
- **State**:
  - `summonedVehicles: [VehicleSnapshot] = []` — every summoned vehicle in summon order. `VehicleSnapshot` is `Sendable + Identifiable + Equatable` carrying `(id, type, position)`. Position is the spawn position; the live position is authoritative on the RealityKit entity.
  - `occupiedVehicleId: UUID? = nil` — id of the currently-piloted vehicle, or `nil` on foot.
- **Side effects on Entity**:
  - Holds a `[UUID: WeakEntityBox]` registry keyed by vehicle id; populated via `register(entity:for:)` from the scene-side `VehicleSummoned` subscriber.
  - On `.enter`: flips `VehicleComponent.isOccupied = true` on the registered entity (if present).
  - On `.exit`: flips `isOccupied = false` and zeroes `moveAxis` + `verticalInput` on the entity.
  - On `.pilot`: writes `moveAxis` + `verticalInput` into the entity's component.
- **Publishes**:
  - `VehicleSummoned(vehicleId:, vehicleType:, position:)` — on every `.summon` intent, after appending the snapshot.
  - `VehicleEntered(vehicleId:, vehicleType:)` — on `.enter` success (id known AND not already occupying).
  - `VehicleExited(vehicleId:)` — on `.exit` when a vehicle was actually occupied.
- **Subscribes**: — (none; `VehicleStore` is a one-way forwarder — UI → Entity + event).
- **Lifecycle**:
  - `init(eventBus: EventBus)` — stores the bus; no I/O, no subscription.
  - `register(entity: Entity, for vehicleId: UUID)` — scene-side subscriber to `VehicleSummoned` calls this after building the entity. Holds weak. Calling twice replaces quietly (scene reload-friendly).
  - `unregister(vehicleId: UUID)` — scene teardown hook. Safe even if the id was never registered.
  - `resetForTesting()` — public test hook.
  - **No `start()` / `stop()`** because the Store never subscribes to any event.

### `WorkbenchStore`

- **File**: [`Packages/SDGGameplay/Sources/SDGGameplay/Workbench/WorkbenchStore.swift`](../../Packages/SDGGameplay/Sources/SDGGameplay/Workbench/WorkbenchStore.swift)
- **Declaration**: `WorkbenchStore.swift` — `@MainActor @Observable public final class WorkbenchStore: Store`
- **Status**: 🟡 Defined — class + event pipe ship in Phase 2 Beta; RootView integration (the "🔬" HUD button that presents `WorkbenchView` in a `fullScreenCover`) lands in the main-agent integration wave.
- **Intent** (`WorkbenchStore.swift`, `enum Intent: Sendable, Equatable`):
  - `.openWorkbench` — move to `.open(nil, nil)`. No-op if already open. Publishes `WorkbenchOpened` on the transition.
  - `.closeWorkbench` — move to `.closed` and drop any selection. No-op if already closed. Publishes nothing.
  - `.selectSample(SampleItem.ID?)` — set the inspected sample (or clear with `nil`). No-op when workbench is closed. Implicitly clears `selectedLayer` because layer indices don't travel across samples.
  - `.selectLayer(layerIndex: Int?)` — set the inspected layer inside the currently-selected sample. No-op when workbench is closed or no sample is picked. Publishes `SampleAnalyzed` iff `layerIndex` is non-nil (deselecting stays silent).
- **Status enum**: `.closed` or `.open(selectedSample: SampleItem.ID?, selectedLayer: Int?)`. Encoding open+selection as associated values means the UI cannot observe an invalid "closed but selected" state.
- **Convenience getters**: `isOpen: Bool`, `selectedSampleId: SampleItem.ID?`, `selectedLayerIndex: Int?` — all derived from `status`.
- **Publishes**:
  - `WorkbenchOpened(openedAt: Date())` on the `.closed → .open` transition.
  - `SampleAnalyzed(sampleId:, layerId: "layer_\(index)", analyzedAt:)` whenever a `.selectLayer` intent commits a non-nil index with a sample already selected. `layerId` is the stringified index today — see note in Events.md for Phase 3 upgrade path.
- **Subscribes**: — (none; `WorkbenchStore` is a pure publisher).
- **Lifecycle**:
  - `init(eventBus: EventBus)` — stores the bus; no I/O, no subscription.
  - **No `start()` / `stop()`** because the Store never subscribes to any event.

### `QuestStore`

- **File**: [`Packages/SDGGameplay/Sources/SDGGameplay/Quest/QuestStore.swift`](../../Packages/SDGGameplay/Sources/SDGGameplay/Quest/QuestStore.swift)
- **Declaration**: `QuestStore.swift` — `@MainActor @Observable public final class QuestStore: Store`
- **Status**: 🟡 Defined — the store, persistence, and event pipe ship in Phase 2 Beta; UI wiring (quest tracker HUD, guidance arrows) lands in Phase 2 Alpha.
- **Intent** (`QuestStore.swift`, `enum Intent: Sendable, Equatable`):
  - `.start(questId: String)` — `.notStarted` → `.inProgress` + `QuestStarted`. No-op on unknown ids and on quests already past `.notStarted`.
  - `.completeObjective(questId: String, objectiveId: String)` — flip the objective's `completed` flag and publish `ObjectiveCompleted`. If the quest's `areAllObjectivesCompleted` becomes true, also publish `QuestCompleted` and one `RewardGranted` per attached reward.
  - `.markComplete(questId: String)` — admin / cutscene shortcut. Forces every objective to `completed`, flips `status` to `.completed`, and runs the same finalize path as above (including reward grants).
  - `.reset` — restore every quest to `QuestCatalog.all` baseline, clear reward bookkeeping, wipe persistence. No events fired; subscribers drive off `QuestStarted` on the next `.start`.
- **State**:
  - `quests: [Quest]` — every catalog-defined quest, merged with persisted progress on `start()`. Array order matches `QuestCatalog.all` so UI can render a linear chapter list.
  - `fieldPhaseSampleCount: Int` (private) — ephemeral counter for the `q.field.phase.collect_samples` auto-completion. Not persisted; re-collected after a relaunch if the objective is still open.
  - `grantedRewardKeys: Set<String>` (private) — deduped reward keys loaded from persistence; guarantees `RewardGranted` fires at most once per `(questId, reward)` pair.
  - `fieldPhaseSampleTarget: Int = 3` (public static) — how many `SampleCreatedEvent`s complete the objective. Matches the legacy `FieldPhaseTargetSequence` length.
- **Queries**:
  - `quest(withId:)` — O(n) scan; returns `nil` for unknown ids.
  - `isObjectiveCompleted(_:)` — O(n·m) scan; small constant factors (≤13 quests × ≤2 objectives each today).
- **Publishes**:
  - `QuestStarted(questId:)` — on the `.notStarted` → `.inProgress` transition.
  - `ObjectiveCompleted(questId:, objectiveId:)` — on the first `.completeObjective` for a given objective.
  - `QuestCompleted(questId:)` — once all objectives are done (via `.completeObjective` or `.markComplete`).
  - `RewardGranted(questId:, reward:)` — per reward attached to a freshly-completed quest, deduped across relaunches.
- **Subscribes**:
  - `SampleCreatedEvent` — installed in `start()`; the handler is gated on `q.field.phase` being `.inProgress`, `enter_field` already completed, and `collect_samples` still open. Counter-based (any three samples complete the objective). Position-based matching is a Phase 2 Alpha TODO, documented inline.
- **Lifecycle**:
  - `init(eventBus:persistence: = .standard)` — stores deps; no I/O, no subscription.
  - `start() async` — hydrate from `QuestPersistence`, run a lightweight localization-key probe (DEBUG-only, skipped when Bundle.main has no `ja`/`zh-Hans` — i.e. during `swift test`), then subscribe to `SampleCreatedEvent`. Idempotent on the subscription; re-running `start()` re-hydrates but keeps the one token.
  - `stop() async` — cancel the subscription. Idempotent.

### `DialogueStore`

- **File**: [`Packages/SDGGameplay/Sources/SDGGameplay/Dialogue/DialogueStore.swift`](../../Packages/SDGGameplay/Sources/SDGGameplay/Dialogue/DialogueStore.swift)
- **Declaration**: `DialogueStore.swift` — `@MainActor @Observable public final class DialogueStore: Store`
- **Status**: 🟡 Defined — store + events ship in Phase 2 Beta; UI (full-screen cutscene overlay) lands in Phase 2 Alpha.
- **Intent** (`DialogueStore.swift`, `enum Intent: Sendable, Equatable`):
  - `.play(sequence: StorySequence)` — start the given sequence from line 0. Overrides any currently-playing sequence (matches the legacy `StoryDirector` "latest call wins"). Empty sequences short-circuit through `.finished(skipped: false)` after firing `DialoguePlayed` + `DialogueFinished` so awaits never deadlock.
  - `.advance` — step forward one line. No-op in `.idle` / `.finished`. On the advance that crosses the last line, transitions to `.finished(skipped: false)` and publishes `DialogueFinished` instead of `DialogueAdvanced`.
  - `.skipAll` — jump straight to `.finished(skipped: true)`. No-op in `.idle` / `.finished`. Quest objectives gated on "dialogue finished" should treat `skipped` as equivalent to natural completion.
- **Status enum**: `.idle`, `.playing(sequence: StorySequence, currentLineIndex: Int)`, `.finished(sequence: StorySequence, skipped: Bool)`.
- **Convenience getters**: `currentLine: DialogueLine?`, `isOnLastLine: Bool` — derived from `status`, exposed so UI can swap "next ▸" for "finish ✓" without opening the Status enum.
- **Publishes**:
  - `DialoguePlayed(sequenceId:)` — on every `.play(sequence:)` intent, including the empty-sequence fast-path.
  - `DialogueAdvanced(sequenceId:, lineIndex:)` — per successful mid-sequence advance. NOT fired on the advance that finishes the sequence.
  - `DialogueFinished(sequenceId:, skipped:)` — on advance-past-last-line (`skipped: false`), `.skipAll` (`skipped: true`), and the empty-sequence path (`skipped: false`).
- **Subscribes**: — (none; `DialogueStore` is a pure publisher).
- **Lifecycle**:
  - `init(eventBus:)` — stores the bus; no I/O, no subscription.
  - **No `start()` / `stop()`** because the Store never subscribes to any event.

---

## Maintenance

1. Every new `: Store` conformer requires a summary-table row and a "Detailed spec" section.
2. When you add / remove an Intent case, update "Intent" bullets *and* the summary-table cell in the same PR.
3. When you wire a new subscription in `start()` (or remove one), update "Subscribes" and cross-reference Events.md.
4. Any new `publish(...)` call inside a Store's `intent(_:)` handler must show up under "Publishes" and trigger a matching "Published by" row in Events.md.
5. See AGENTS.md §4.1 for the binding rule.
