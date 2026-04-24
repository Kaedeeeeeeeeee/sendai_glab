# Phase 9 Part B — RootView integration notes

This is the "please hand-edit `RootView.swift` next" doc for Phase 9
Part B. Per the subagent contract, this branch does not touch
`RootView.swift`; everything below is a copy-pasteable patch for
whoever lands the final integration.

## What shipped on this branch

Non-RootView code + data:

- `Packages/SDGGameplay/Sources/SDGGameplay/Geology/StratigraphicColumn.swift`
  — `StratigraphicColumn` / `StratigraphicLayer` Codable data model
    + `clipToSlabs(surfaceY:maxDepth:xzCenter:)` for hand-off to
    `GeologyDetectionSystem.computeIntersections(...)`.
- `Packages/SDGGameplay/Sources/SDGGameplay/Geology/GeologyRegionRegistry.swift`
  — bundle loader + XZ→column lookup. Uses the existing
    `EnvelopeManifest` to derive each tile's RealityKit footprint.
- `Packages/SDGGameplay/Sources/SDGGameplay/Drilling/DrillingErrors.swift`
  — `DrillError` (moved out of `DrillingSystem.swift`) gains a new
    `.outOfSurveyArea` case + a `reasonTag` property so producers and
    HUD consumers share one reason vocabulary.
- `Packages/SDGGameplay/Sources/SDGGameplay/Drilling/DrillingSystem.swift`
  — `DrillingOrchestrator` grew two optional deps
    (`regionRegistry`, `terrainSampler`) and a region-column drill
    path. Legacy entity-tree path is untouched and still the default
    when the registry is not wired in.
- `Packages/SDGGameplay/Sources/SDGGameplay/Quest/StoryProgressionMap.swift`
  — declarative tables for `dialogueCompletions`, `questSuccessors`,
    and the Phase 9 `questDisasters`. Pure data; the bridge lives in
    RootView.
- 5 × `Resources/Geology/regions/<regionId>.json` (5 tiles).
- 2 × `Resources/Story/quest1.3.json` / `quest1.4.json`
  — new chapter-1 sampling dialogues. Names are 1.3 / 1.4 instead of
    1.2 / 1.3 because `quest1.2.json` was already shipped in Phase 2
    Beta as the laboratory intro and overwriting it would break
    the existing dialogue catalogue. `StoryLoader.shippedBasenames`
    was updated accordingly.
- Localization keys in `Resources/Localization/Localizable.xcstrings`:
  - `geology.layer.<formation>.name` (topsoil, basement, terrace,
    terrace-gravel, dainenji, dainohara-terrace, mukaiyama,
    tatsunokuchi, kameoka, hirosegawa-tuff, hirose-lower-terrace,
    diluvial-gravel, fill, alluvium) — ja + en.
  - `geology.region.<regionId>.name` for the 5 regions — ja + en.
  - `drill.error.outOfSurveyArea` — ja + en.

## What RootView needs to change

The bootstrap already constructs an `EnvelopeManifest` and a
`DrillingOrchestrator`. Two adjustments:

### 1. Build the `GeologyRegionRegistry` in `bootstrap()`

Place after the manifest is loaded. The registry loads its 5 JSONs
synchronously and cheaply; there's no need to wrap in a `Task`.

```swift
// Near the top of bootstrap(), just after `envelopeManifest` is loaded:
let regionRegistry: GeologyRegionRegistry?
do {
    regionRegistry = try GeologyRegionRegistry(
        bundle: .main,
        manifest: envelopeManifest
    )
} catch {
    print("[SDG-Lab][geology] region registry load failed: \(error)")
    regionRegistry = nil
}
```

Store this on the `sceneRefs` / `@State` sidecar. A non-nil registry
means Phase 9 Part B's drill-anywhere behaviour is live; a nil one
falls back to the Phase 1 entity-tree path, matching pre-Phase-9
behaviour.

### 2. Construct the orchestrator with the registry + terrain sampler

Find the existing `DrillingOrchestrator(eventBus:outcropRootProvider:)`
line in `bootstrap()` and extend it:

```swift
drillingOrchestrator = DrillingOrchestrator(
    eventBus: bus,
    outcropRootProvider: { [weak sceneRefs] in sceneRefs?.outcropRoot },
    regionRegistry: regionRegistry,
    terrainSampler: { xz in
        // sceneRefs.terrainEntity is the PlateauTerrain root placed
        // by TerrainLoader in the RealityView `make` closure.
        guard let terrain = sceneRefs.terrainEntity else { return nil }
        return TerrainLoader.sampleTerrainY(in: terrain, atWorldXZ: xz)
    }
)
```

Both new arguments have `nil` defaults so the call compiles against
the Phase 1 signature without them — only add them when the registry
is ready.

### 3. Surface `.outOfSurveyArea` in the HUD

The orchestrator already publishes `DrillFailed(reason: "out_of_survey_area")`
for off-corridor drills. The Phase 2 Beta HUD toast code can branch
on the reason string to pick a localisation key:

```swift
// In the DrillingStore status observer / HUD toast bridge:
switch event.reason {
case DrillError.outOfSurveyArea.reasonTag:
    hudToastKey = "drill.error.outOfSurveyArea"
case DrillError.noLayers.reasonTag:
    hudToastKey = "drill.error.noLayers"  // existing key
case DrillError.sceneUnavailable.reasonTag:
    hudToastKey = "drill.error.sceneUnavailable"  // existing key
default:
    hudToastKey = "drill.error.generic"
}
```

If the HUD doesn't yet have a toast subscriber, the simplest drop-in
is to publish a separate `DialogueStore.intent(.show(textKey: ...))`
from the `DrillFailed` handler so the player sees a one-liner.

### 4. Wire the story progression bridge

Phase 9 Part B ships the routing tables (`StoryProgressionMap`) but
not the bridge. A minimal bridge is ~40 lines and belongs in
`Packages/SDGGameplay/Sources/SDGGameplay/Quest/StoryProgressionBridge.swift`:

```swift
@MainActor
public final class StoryProgressionBridge {
    private let bus: EventBus
    private let questStore: QuestStore
    private let disasterStore: DisasterStore
    private var dialogueToken: SubscriptionToken?
    private var questToken: SubscriptionToken?

    public init(
        eventBus: EventBus,
        questStore: QuestStore,
        disasterStore: DisasterStore
    ) {
        self.bus = eventBus
        self.questStore = questStore
        self.disasterStore = disasterStore
    }

    public func start() async {
        dialogueToken = await bus.subscribe(DialogueFinished.self) { [weak self] event in
            await self?.handleDialogue(event)
        }
        questToken = await bus.subscribe(QuestCompleted.self) { [weak self] event in
            await self?.handleQuest(event)
        }
    }

    public func stop() async {
        if let t = dialogueToken { await bus.cancel(t); dialogueToken = nil }
        if let t = questToken    { await bus.cancel(t); questToken = nil }
    }

    private func handleDialogue(_ event: DialogueFinished) async {
        guard let edge = StoryProgressionMap.completion(
            forDialogueSequenceId: event.sequenceId
        ) else { return }
        await questStore.intent(.completeObjective(
            questId: edge.questId,
            objectiveId: edge.objectiveId
        ))
    }

    private func handleQuest(_ event: QuestCompleted) async {
        // Successor quest.
        if let next = StoryProgressionMap.successor(of: event.questId) {
            await questStore.intent(.start(questId: next))
        }
        // Disaster trigger.
        if let kind = StoryProgressionMap.disaster(after: event.questId) {
            switch kind {
            case let .earthquake(intensity, duration):
                await disasterStore.intent(.triggerEarthquake(
                    intensity: intensity,
                    durationSeconds: duration,
                    questId: event.questId
                ))
            case let .flood(targetY, riseSeconds):
                // startY: sample current player Y from sceneRefs.
                let startY = sceneRefs.playerEntity?.position(relativeTo: nil).y ?? 0
                await disasterStore.intent(.triggerFlood(
                    startY: startY,
                    targetWaterY: targetY,
                    riseSeconds: riseSeconds,
                    questId: event.questId
                ))
            }
        }
    }
}
```

RootView bootstrap would then:

```swift
let bridge = StoryProgressionBridge(
    eventBus: bus,
    questStore: questStore,
    disasterStore: disasterStore
)
await bridge.start()
// Store in a @State so teardown() can call await bridge.stop().
```

This replaces the current ad-hoc `dialogueFinishedToken`
subscription that hard-wires `q.lab.intro` auto-start.

### 5. Remove the hard-wired quest auto-start

The existing block in `bootstrap()`:

```swift
dialogueFinishedToken = await bus.subscribe(DialogueFinished.self) { event in
    guard event.sequenceId == "quest1.1" else { return }
    let store = questStore
    Task { @MainActor in
        await store.intent(.start(questId: "q.lab.intro"))
    }
}
```

…is redundant once the bridge is in place, but with one caveat: the
bridge completes `q.lab.intro.intro_done` rather than starting
`q.lab.intro`. To keep the existing chapter-1 flow, add one line to
`bootstrap()` so the quest enters `.inProgress` before the dialogue
finishes:

```swift
// Bootstrap kick-off: start the chapter-1 intro quest. Idempotent —
// re-entering bootstrap after a scene reload does not double-start.
await questStore.intent(.start(questId: "q.lab.intro"))
```

## Testing the integration

1. `swift test --package-path Packages/SDGGameplay` — all 361 tests
   on this branch green.
2. iPad simulator build — drill near spawn, confirm sample drops with
   the Aobayama-campus column (should see Hirosegawa Tuff + Tatsunokuchi
   layers). Walk east past the corridor edge (~625 m east of spawn) and
   drill again — confirm `DrillFailed(reason: "out_of_survey_area")`
   and the HUD toast.
3. After RootView integrates the bridge: finish `quest1.1` dialogue,
   confirm `q.lab.intro` flips to `.completed`. Complete
   `q.chapter4.field` (青葉山) and confirm an earthquake fires.
   Complete `q.chapter4.sample` (川内) and confirm a flood fires.

## Known deviations from the task spec

- **Quest filenames**: task asked for `quest1.2.json` / `quest1.3.json`;
  shipped as `quest1.3.json` / `quest1.4.json` because
  `quest1.2.json` already existed. No behaviour change — the dialogue
  loader reads basenames from `shippedBasenames`.
- **Test count**: this branch is rooted at the Phase 4 commit, which
  has a 332-test baseline (not the 354 the task memo assumed). The
  +29 new tests here bring the branch to 361. Merging forward will
  cleanly add the same +29 on top of whatever mainline is.
