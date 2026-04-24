# Phase 9 Part F — Interior scene + scene transition (integration notes)

**Agent note**: Part F did **not** touch `RootView.swift`. The main agent
owns that file; everything below is a copy-paste recipe for wiring the
new types (`LocationComponent`, `LocationTransitionComponent`,
`SceneTransitionStore`, `InteriorSceneBuilder`, `PortalEntity`) into
`RootView`.

## Goal recap

Walk up to a door near spawn → step into it → player appears in a lab
interior room → walk back to the door → step out to the PLATEAU
corridor.

- ONE interior scene (procedural lab, built by `InteriorSceneBuilder`)
- ONE portal pair (outdoor frame near spawn + indoor floor marker on
  the opposite wall)
- Scene swap via `isEnabled` flip, NOT entity replacement — both
  scenes live in the graph at all times
- Player gets teleported across via a fixed Y offset when crossing
- Indoor `PlayerControlSystem.snapToGround` already short-circuits DEM
  sampling when the player's `LocationComponent.kind == .indoor(_)`

## New public API surface

| Type | File | Role |
|---|---|---|
| `LocationKind` (enum) | `World/LocationComponent.swift` | `.outdoor` / `.indoor(sceneId: String)` — Codable, Equatable, Sendable |
| `LocationComponent` | `World/LocationComponent.swift` | Marker on the player, holds current `LocationKind` |
| `LocationTransitionComponent` | `World/LocationTransitionComponent.swift` | Data on portal entities: `targetScene` + `spawnPointInTarget` |
| `SceneTransitionStore` (@Observable @MainActor) | `World/SceneTransitionStore.swift` | State machine. Intents: `.requestTransition`, `.tickProximity`, `.resetForTesting` |
| `PortalProximitySnapshot` | `World/SceneTransitionStore.swift` | Value-type snapshot RootView builds each tick |
| `SceneTransitionStarted` / `SceneTransitionEnded` | `World/SceneTransitionEvents.swift` | Cross-layer events |
| `InteriorSceneBuilder.build(outdoorSpawnPoint:)` | `World/InteriorSceneBuilder.swift` | Procedural `LabInterior` entity |
| `PortalEntity.makeOutdoorPortal(at:targetScene:spawnPointInTarget:)` | `World/PortalEntity.swift` | Outdoor frame + `LocationTransitionComponent` |

All types live in `SDGGameplay/World/` and are imported via the
existing `import SDGGameplay` already in `RootView.swift`.

## Design decision: proximity trigger is a closure/snapshot path

The MVP did **not** introduce a new `System`. Instead:

- RootView collects the two portal entities from the scene graph
  (outdoor frame + the `LabInterior` indoor marker) once at bootstrap
  time and retains refs to them.
- The existing `playerPositionPoll` timer (`Timer.publish(every: 0.1)`,
  already wired in RootView) drives a per-tick call into
  `sceneTransitionStore.intent(.tickProximity(playerPosition:portals:))`
  with a freshly-assembled snapshot of the two portal positions + their
  `LocationTransitionComponent` payloads.

This mirrors the `DisasterStore` pattern (Store accepts per-frame
ticks; System-side concerns like "what are the current portal
positions" are handed in as plain data). The Store never imports
RealityKit and stays trivially testable. A dedicated `System` would be
overkill for two entities checked at 10 Hz.

## RootView integration

### 1. Add state at the view level

```swift
/// Phase 9 Part F: Scene transition state machine (outdoor ↔ indoor).
@State private var sceneTransitionStore: SceneTransitionStore

/// Phase 9 Part F: retained refs to the portal entities so the
/// per-tick proximity snapshot does not need a fresh scene walk.
@State private var outdoorPortalEntity: Entity?
@State private var indoorPortalEntity: Entity?

/// Phase 9 Part F: the lab interior. Lives in the scene graph the
/// whole session; `isEnabled` flips on the outdoor→indoor transition.
@State private var labInteriorEntity: Entity?

/// Phase 9 Part F: subscription token for SceneTransitionStarted.
@State private var sceneTransitionStartedToken: SubscriptionToken?
```

And init it alongside the other placeholder stores:

```swift
public init() {
    let placeholder = EventBus()
    // …existing placeholder assignments…
    _sceneTransitionStore = State(initialValue: SceneTransitionStore(eventBus: placeholder))
}
```

### 2. Register `LocationComponent` + `LocationTransitionComponent`

In `registerSystemsOnce()`:

```swift
LocationComponent.registerComponent()
LocationTransitionComponent.registerComponent()
```

### 3. In the `RealityView` make closure — after the corridor + player load

```swift
// Phase 9 Part F: build and hide the interior scene. It lives in
// the scene graph the whole session; we flip isEnabled to show it.
let lab = InteriorSceneBuilder.build(
    outdoorSpawnPoint: {
        // Point just outside the outdoor portal's +Z face so the
        // player pops back onto the corridor, facing into the frame.
        SIMD3<Float>(0, spawnY, -5 + 1.5)
    }()
)
lab.position = SIMD3<Float>(0, 0, 0)    // world origin; spawn tile centre
lab.isEnabled = false
content.add(lab)
labInteriorEntity = lab

// Phase 9 Part F: place outdoor portal 5 m south of player spawn.
// Sample DEM Y so the frame sits on the surface.
let outdoorPortalXZ = SIMD2<Float>(0, -5)
let outdoorPortalY: Float = {
    if let terrain = loadedTerrain,
       let y = TerrainLoader.sampleTerrainY(
            in: terrain,
            atWorldXZ: outdoorPortalXZ
       ) {
        return y
    }
    return 0
}()
let outdoorPortalPos = SIMD3<Float>(
    outdoorPortalXZ.x, outdoorPortalY, outdoorPortalXZ.y
)
let indoorSpawn = InteriorSceneBuilder.defaultIndoorSpawnPoint
let outdoorPortal = PortalEntity.makeOutdoorPortal(
    at: outdoorPortalPos,
    targetScene: .indoor(sceneId: InteriorSceneBuilder.defaultSceneId),
    spawnPointInTarget: indoorSpawn
)
content.add(outdoorPortal)
outdoorPortalEntity = outdoorPortal

// Find the indoor portal marker inside the lab so we can include
// it in per-frame proximity snapshots (its LocationTransitionComponent
// was attached by InteriorSceneBuilder already).
indoorPortalEntity = lab.children.first {
    $0.name == "LabInterior.indoorPortalMarker"
}

// Tag the player as outdoor.
body.components.set(LocationComponent(.outdoor))
```

### 4. In `bootstrap()`

```swift
// Phase 9 Part F: SceneTransitionStore on the real bus + subscribe
// to SceneTransitionStarted so we can teleport the player and flip
// the lab's isEnabled. We do the scene-graph mutation in the
// subscriber rather than inside the Store because Stores must not
// hold entity references (ADR-0001).
sceneTransitionStore = SceneTransitionStore(eventBus: bus)
await sceneTransitionStore.start()

sceneTransitionStartedToken = await bus.subscribe(SceneTransitionStarted.self) { event in
    await handleSceneTransition(event)
}
```

Handler:

```swift
@MainActor
private func handleSceneTransition(_ event: SceneTransitionStarted) async {
    guard
        let player = sceneRefs.playerEntity,
        let lab = labInteriorEntity
    else { return }

    // Flip the lab's visibility so the side the player is entering
    // is alive and the one they're leaving is hidden.
    switch event.to {
    case .outdoor:
        lab.isEnabled = false
    case .indoor:
        lab.isEnabled = true
    }

    // Teleport and update the marker component. Use the spawn point
    // the portal baked in; no manual Y offset here — InteriorSceneBuilder
    // puts the indoor spawn point at the floor's +10 cm margin already.
    player.position = event.spawnPoint
    player.components.set(LocationComponent(event.to))
}
```

### 5. Drive per-frame proximity inside the existing 10 Hz poll

Inside the existing `.onReceive(playerPositionPoll)` block, after the
`polledPlayerPosition` update:

```swift
// Phase 9 Part F: proximity tick. Snapshot the two portals and
// hand them to the Store; it decides whether to fire a transition.
var snapshots: [PortalProximitySnapshot] = []
if let outdoor = outdoorPortalEntity,
   let comp = outdoor.components[LocationTransitionComponent.self] {
    snapshots.append(PortalProximitySnapshot(
        position: outdoor.position(relativeTo: nil),
        transition: comp
    ))
}
if let indoor = indoorPortalEntity,
   let comp = indoor.components[LocationTransitionComponent.self] {
    snapshots.append(PortalProximitySnapshot(
        position: indoor.position(relativeTo: nil),
        transition: comp
    ))
}
let store = sceneTransitionStore
let player = polledPlayerPosition
Task { @MainActor in
    await store.intent(.tickProximity(
        playerPosition: player,
        portals: snapshots
    ))
}
```

### 6. Teardown

In `teardown()`:

```swift
if let token = sceneTransitionStartedToken {
    Task { await bus.cancel(token) }
    sceneTransitionStartedToken = nil
}
let sts = sceneTransitionStore
Task { await sts.stop() }
```

## Verification checklist (f.shera device test)

1. Start session — player spawns outdoors, lab is invisible (disabled).
2. Walk 5 m south to the outdoor portal frame. On entering the trigger
   radius (2 m), the player teleports to `InteriorSceneBuilder.defaultIndoorSpawnPoint`
   and the lab becomes visible. `PlayerControlSystem.snapToGround`
   now pins Y at 0.1 (indoor floor constant).
3. Walk to the indoor portal marker (the coloured tile on the -Z wall).
4. On entering the marker's trigger radius, the player teleports back
   near the outdoor frame and the lab disappears again. DEM ground-
   follow resumes automatically because the `LocationComponent` was
   flipped back to `.outdoor`.

## Files added in Phase 9 Part F

- `Packages/SDGGameplay/Sources/SDGGameplay/World/LocationComponent.swift`
- `Packages/SDGGameplay/Sources/SDGGameplay/World/LocationTransitionComponent.swift`
- `Packages/SDGGameplay/Sources/SDGGameplay/World/SceneTransitionEvents.swift`
- `Packages/SDGGameplay/Sources/SDGGameplay/World/SceneTransitionStore.swift`
- `Packages/SDGGameplay/Sources/SDGGameplay/World/InteriorSceneBuilder.swift`
- `Packages/SDGGameplay/Sources/SDGGameplay/World/PortalEntity.swift`

## Files modified in Phase 9 Part F

- `Packages/SDGGameplay/Sources/SDGGameplay/Player/PlayerControlSystem.swift`
  — `snapToGround` gains a `LocationComponent(.indoor(_))` short-circuit
  that pins Y to `indoorFloorY` + 0.1 m.
