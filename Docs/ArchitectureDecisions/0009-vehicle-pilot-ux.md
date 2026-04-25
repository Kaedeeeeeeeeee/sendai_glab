# ADR-0009: Vehicle pilot UX — joystick routing + Board button + camera re-parent

- **Status**: Accepted
- **Date**: 2026-04-23
- **Context**: Phase 7. Phase 2 Beta shipped the vehicle *data* layer
  (VehicleStore, VehicleControlSystem, `.enter`/`.exit`/`.pilot` intents,
  `VehicleSummoned`/`VehicleEntered`/`VehicleExited` events) but nothing
  in the UX layer invoked it. Real-device play let you spawn a drone
  with the 🚁 debug button, but pressing the joystick did nothing to it.

## Decision

Add three thin UX layers that connect the existing data plumbing to
the player's hands:

1. **Joystick routing swap in RootView** — a single `if`
   in `.onChange(of: joystickAxis)` picks between
   `playerStore.intent(.move(axis))` and
   `vehicleStore.intent(.pilot(axis:, vertical: 0))` based on
   `vehicleStore.occupiedVehicleId`. The joystick View stays
   ignorant of Stores (AGENTS.md §1 View→Store→ECS boundary).

2. **Board / Exit HUD button** — a new `BoardButton` view, shown
   contextually:
   - `.hidden` when the player is on foot and no summoned vehicle is
     within 3 m,
   - `.boardAvailable` when a summoned vehicle *is* within 3 m,
   - `.exitAvailable` whenever the player is currently piloting.
   HUDOverlay polls the live player world position at 10 Hz (Combine
   `Timer.publish`) so proximity doesn't churn SwiftUI every frame.
   Nearest-vehicle resolution uses live entity position (via the
   Store's new `entity(for:)` accessor), falling back to the summon
   snapshot when the scene-side entity hasn't registered yet.

3. **Camera re-parent on enter / exit** — new `VehicleEntered` and
   `VehicleExited` subscribers in `RootView.bootstrap()`. On entry
   the `PerspectiveCamera` is detached from the player body and
   re-attached under the vehicle with a third-person boom offset
   (+Y 1 m, –Z 2 m); the player body is hidden (`isEnabled = false`)
   so it doesn't clip through the cockpit. On exit the camera goes
   back to head height on the player body and the player is
   teleported to the vehicle's XZ so they don't pop back to the
   board point.

## Context

### Why routing lives in RootView, not the joystick

The joystick is a leaf SwiftUI view under SDGUI; it publishes axis
values upward via a `Binding`. Routing inputs to different Stores
based on game state is application-level logic — RootView is the
only place that already depends on both `PlayerControlStore` and
`VehicleStore`. Pushing the routing into the joystick would force
it to import both Stores and couple the presentation layer to the
data layer, which the ADR-0001 layer rules forbid.

### Why camera re-parenting lives in RootView (not the Store)

Scene graph mutation is RealityKit's business, and AGENTS.md §1
bars Stores from touching it. The Store publishes
`VehicleEntered` / `VehicleExited` as pure data; RootView reacts to
those events in the same way it already reacts to
`VehicleSummoned`. This means any other boarding trigger (future
scripted event, multiplayer peer's remote board, an NPC asking the
player to board a taxi) gets the camera swap for free.

### Why 3 m proximity, not a dedicated trigger volume

For MVP, a scalar distance is the cheapest "are you next to the
vehicle?" check. A proper collision trigger volume would need
RealityKit collision components + collision filters + subscriber
plumbing — too much for a Board button that any player can
discover on first sight. Phase 7.1 can upgrade to a trigger volume
if the Board button proves too twitchy on mixed terrain.

### Why `isEnabled = false` on the player body (not just hide the
mesh)

Ensures the player doesn't double-integrate while piloting: the
disabled body drops out of `PlayerControlSystem.update`'s entity
iteration, so movement intents silently no-op even if they slipped
through the routing swap. Defence in depth.

## Implementation

### Store (data-layer addition)

New public accessor on `VehicleStore`:

```swift
public func entity(for vehicleId: UUID) -> Entity?
```

Returns the registered entity (weak reference) for a vehicle id.
Needed by the HUD proximity check (vehicles move; snapshots go
stale) and the `VehicleEntered` handler (camera needs the live
target). Unit-tested at three surfaces: registered returns entity,
unknown id returns nil, post-unregister returns nil.

### UX (SDGUI)

* `HUDOverlay`: added `vehicleStore`, `playerWorldPosition`,
  `onBoardTapped`, `onExitVehicleTapped` to the init; new
  `boardButtonMode` computed property reads the Store and the
  position to return one of the three `BoardButtonMode` cases.
* `BoardButton` (new, 80×80 pt circle, matches `DrillButton`).
  Three visual states: hidden (`EmptyView()`), green up-arrow,
  orange down-arrow.
* `RootView.onChange(of: joystickAxis)`: single `if` routing to
  vehicle vs. player Store.
* `RootView.bootstrap()`: `VehicleEntered` / `VehicleExited`
  subscribers do the camera swap + player enable/disable. Tokens
  live on `@State` and are cancelled in `teardown()`.
* `RootView.polledPlayerPosition`: `@State SIMD3<Float>` updated
  on the 10 Hz poll; fed into `HUDOverlay.playerWorldPosition`.

### Tests

Store tests added:
* `testEntityForRegisteredIdReturnsSameEntity`
* `testEntityForUnknownIdIsNil`
* `testEntityForAfterUnregisterIsNil`

Existing Phase 2 Beta tests cover the rest of the contract:
* `testEnterPublishesVehicleEntered` / `testExitPublishesVehicleExited`
* `testPilotWhileNotOccupiedIsNoOp` / `testPilotAfterEnterWritesIntoComponent`
* `testEnterWhileAlreadyOccupiedIsNoOp`
* `testUnoccupiedVehicleIgnoresInputs` /
  `testUnoccupiedDrillCarDoesNotFall`

## Consequences

### Positive

* Pilot loop closed end to end: 🚁 → walk up → Board → fly →
  Exit → walk.
* No new Stores / ECS components: the Phase 2 Beta data layer
  was correctly designed and only needed wiring.
* Routing lives in one 7-line `if` block; easy to extend
  (e.g. route vertical-swipe gestures to `pilot(vertical:)`).

### Negative / known limitations

* Camera rig is static third-person boom (no spring damping,
  no obstacle avoidance). May clip through nearby buildings on
  a slope.
* Vertical drone input is hardcoded to 0. Phase 7.1 adds a
  vertical stick or pinch-up/-down gesture.
* `isEnabled = false` on the player body means every player
  subsystem silently pauses — works for MVP, but if a future
  system needs to run on the "piloted" player (e.g. radio chatter
  animation), it'll need a different opt-out.
* Exit snap places the player 0.5 m below the vehicle. If the
  drone was flying at 30 m altitude, the player falls 29.5 m —
  gravity will catch them if `PlayerControlSystem.snapToGround`
  works at that altitude; Phase 7.1 adds a DEM raycast for a
  safe landing Y.

## References

- ADR-0001: Layered architecture (View→Store→ECS)
- ADR-0003: Event bus design
- `Packages/SDGGameplay/Sources/SDGGameplay/Vehicles/` — Phase 2 Beta
  data layer this ADR wires into the UX
