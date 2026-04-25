# Phase 9 Part D — Vehicle pilot polish: RootView integration notes

Phase 7.1 (tracked under Phase 9 Part D) ships three new follow-ups
to the Phase 7 pilot UX that were explicitly listed as "Negative /
known limitations" in ADR-0009:

1. **Vertical stick** — the drone can now climb / descend via a
   dedicated 80 × 200 pt right-edge slider. No more hardcoded
   `vertical: 0` in the joystick routing.
2. **Follow cam spring damp** — the third-person boom is no longer
   rigidly bolted to the vehicle; it eases toward the target
   offset with a frame-rate-adjusted lerp, so fast drone yaw no
   longer feels stilted.
3. **Safe exit landing** — stepping out of a drone at 30 m altitude
   now drops the player on the DEM surface instead of mid-air.

This PR ships the data layer, ECS, HUD widget, and tests, **but
does not touch `RootView.swift`**. This document is the contract
for the follow-up RootView change so integration lands atomically
in a separate, review-sized diff.

## Files added / changed in this PR

### Added
- `Packages/SDGGameplay/Sources/SDGGameplay/Vehicles/VehicleFollowCamComponent.swift`
- `Packages/SDGGameplay/Sources/SDGGameplay/Vehicles/VehicleFollowCamSystem.swift`
- `Packages/SDGUI/Sources/SDGUI/HUD/VerticalSliderView.swift` — plus
  `VerticalSliderValueMapper` (pure-function value mapper for headless
  testing)
- `Packages/SDGGameplay/Tests/SDGGameplayTests/Vehicles/VehicleFollowCamSystemTests.swift`
  (8 tests)
- `Packages/SDGUI/Tests/SDGUITests/HUD/VerticalSliderViewTests.swift`
  (7 tests, covers the value mapper)

### Modified
- `Packages/SDGUI/Sources/SDGUI/HUD/HUDOverlay.swift` — new
  `verticalSliderValue` binding, new `verticalSliderColumn` slot,
  derived `verticalSliderVisible` gate. A backward-compat init
  without the new binding is retained temporarily so pre-7.1 call
  sites still compile; it defaults the slider to `.constant(0)`
  and should be deleted once every integration site is moved.
- `Packages/SDGUI/Tests/SDGUITests/HUD/HUDOverlayTests.swift` —
  updated to the post-Phase-7 HUD init signature (this was a
  pre-existing break that Phase 7 shipped without fixing).

## RootView integration steps

### 1. Register the new component + system

In `registerSystemsOnce()` (around line 1014 of `RootView.swift`),
alongside the existing `PlayerControlSystem.registerSystem()`:

```swift
VehicleFollowCamComponent.registerComponent()
VehicleFollowCamSystem.registerSystem()
```

### 2. Add the vertical slider `@State`

Next to the existing joystick `@State`:

```swift
@State private var verticalSliderValue: Float = 0
```

### 3. Update the HUDOverlay call site

In `body`, replace the existing `HUDOverlay(…)` init call with:

```swift
HUDOverlay(
    playerStore: playerStore,
    drillingStore: drillingStore,
    inventoryStore: inventoryStore,
    vehicleStore: vehicleStore,
    joystickAxis: $joystickAxis,
    verticalSliderValue: $verticalSliderValue,
    playerWorldPosition: polledPlayerPosition,
    onDrillTapped: handleDrillTap,
    onInventoryTapped: { showInventory = true },
    onBoardTapped: handleBoardTap,
    onExitVehicleTapped: handleExitVehicleTap
)
```

### 4. Route the vertical slider into `.pilot(vertical:)`

Update the joystick `onChange` to also forward vertical samples, and
add a parallel `onChange` for `verticalSliderValue`:

```swift
.onChange(of: joystickAxis) { _, new in
    let playerStore = self.playerStore
    let vehicleStore = self.vehicleStore
    let vertical = verticalSliderValue
    Task { @MainActor in
        if vehicleStore.occupiedVehicleId != nil {
            await vehicleStore.intent(.pilot(axis: new, vertical: vertical))
        } else {
            await playerStore.intent(.move(new))
        }
    }
}
.onChange(of: verticalSliderValue) { _, newVertical in
    let vehicleStore = self.vehicleStore
    let axis = joystickAxis
    Task { @MainActor in
        guard vehicleStore.occupiedVehicleId != nil else { return }
        await vehicleStore.intent(.pilot(axis: axis, vertical: newVertical))
    }
}
```

Reading both bindings every time either changes keeps the Store's
`.pilot(axis:vertical:)` sample always consistent — the Store's
contract stores both fields every call, so a lonely axis update
would accidentally zero out the vertical.

### 5. Attach `VehicleFollowCamComponent` on board

In `handleVehicleEntered`, after re-parenting the camera:

```swift
camera.removeFromParent()
vehicleEntity.addChild(camera)
// Phase 7.1: initial camera pose; System will ease this toward
// VehicleFollowCamComponent.targetOffset each frame.
camera.transform.translation = SIMD3<Float>(0, 1.0, -2.0)
vehicleEntity.components.set(VehicleFollowCamComponent())
playerBody.isEnabled = false
```

Remove the component on exit in `handleVehicleExited`:

```swift
if let vehicleEntity = vehicleStore.entity(for: event.vehicleId) {
    vehicleEntity.components.remove(VehicleFollowCamComponent.self)
    // …existing teleport code below…
}
```

### 6. Cache the terrain for safe exit landing

`POCSceneRefs` currently has no `loadedTerrain` field. Add one:

```swift
@MainActor
final class POCSceneRefs {
    var outcropRoot: Entity?
    var playerEntity: Entity?
    var sampleContainer: Entity?
    var environmentRoot: Entity?
    var loadedTerrain: Entity?   // ← new
    init() {}
}
```

In `realityContent`, at the point where `loadedTerrain` is already a
local var (around line 402), also assign it to the ref:

```swift
let terrain = try await terrainLoader.load()
content.add(terrain)
loadedTerrain = terrain
sceneRefs.loadedTerrain = terrain   // ← new
```

### 7. Use `TerrainLoader.sampleTerrainY` in exit handler

Replace the existing `handleVehicleExited` teleport block:

```swift
if let vehicleEntity = vehicleStore.entity(for: event.vehicleId) {
    let vehiclePos = vehicleEntity.position(relativeTo: nil)
    let landingY: Float
    if let terrain = sceneRefs.loadedTerrain,
       let surfaceY = TerrainLoader.sampleTerrainY(
           in: terrain,
           atWorldXZ: SIMD2<Float>(vehiclePos.x, vehiclePos.z)
       ) {
        landingY = surfaceY + 0.1
    } else {
        // No DEM coverage (e.g. drone flew off the terrain edge) —
        // fall back to the Phase 7 "just under vehicle" behaviour.
        landingY = vehiclePos.y - 0.5
    }
    playerBody.position = SIMD3<Float>(
        vehiclePos.x, landingY, vehiclePos.z
    )
}
```

### 8. Optional: delete the backward-compat init

Once this integration lands and no pre-7.1 call sites remain, delete
the second `public init` in `HUDOverlay.swift` (the one without
`verticalSliderValue:`) to stop new callers from skipping the
slider.

## Anti-patterns to avoid

- Don't call `TerrainLoader.sampleTerrainY` per frame — once at the
  exit handler is fine; per-frame calls would cost ~30 K triangle
  tests every tick.
- Don't pass `vertical: 0` in the joystick-only path (what Phase 7
  did). The vertical slider owns that axis now.
- Don't remove `VehicleFollowCamComponent` on `.pilot(vertical:)` —
  only on exit. Keeping it across frames is how the System knows
  to keep easing.

## Verification

After integration:

- `swift test --package-path Packages/SDGGameplay` — 15 vehicle tests
  pass (including the 8 new follow-cam tests).
- `swift test --package-path Packages/SDGUI` — HUD tests pass (the
  pre-existing HUDOverlayTests break was fixed in this PR).
- `xcodebuild -scheme SendaiGLab …` — full iOS Simulator build
  succeeds.
- On device: drone can climb / descend, camera drifts softly on
  fast yaw, stepping out at altitude lands on the terrain.
