// VehicleComponent.swift
// SDGGameplay · Vehicles
//
// ECS component data attached to every vehicle entity. Plain data per
// ADR-0001: `VehicleControlSystem` owns the per-frame logic, this type
// only carries identity + the current frame's pilot inputs.
//
// ## Why one component, not two (unlike Player)
//
// The Player domain split identity (`PlayerComponent`) from input
// (`PlayerInputComponent`) so an NPC could be tagged `PlayerComponent`
// without being drivable. Vehicles do not have that need: there are
// no "NPC vehicles" planned — a vehicle exists only to be piloted.
// Collapsing the two responsibilities keeps the `EntityQuery` in the
// System a single `.has` predicate and the mental model smaller.

import Foundation
import RealityKit

/// Identity + pilot-input bucket for a single vehicle entity.
///
/// Attached exactly once per vehicle when the entity enters the scene
/// (`VehicleMeshFactory.makeDrone()` / `.makeDrillCar()` seed a
/// default-initialised component on the returned root). The `vehicleId`
/// is the stable identity the `VehicleStore` uses to route
/// `.enter` / `.exit` / `.pilot` intents.
///
/// ### Field contract
///
///   * `vehicleId` — set at entity creation, never mutates. Matches
///     the `id` in the corresponding `VehicleSnapshot`.
///   * `vehicleType` — drives every motion decision. Queried each
///     frame by the System rather than cached, because the value is
///     a two-byte enum and branching on it is cheaper than
///     duplicating the envelope fields onto the component.
///   * `isOccupied` — gates the System's per-frame work. A vehicle
///     that is not occupied sits idle (still has gravity if
///     `vehicleType.hasGravity`, TODO #vehicles-gravity — see
///     `VehicleControlSystem` for current behaviour).
///   * `moveAxis` — *persistent* normalised joystick axis, same
///     semantics as `PlayerInputComponent.moveAxis`. Zeroed on
///     `.exit`.
///   * `verticalInput` — *persistent* -1...1 climb axis. Only the
///     drone consumes it; the drill car has `verticalSpeed = 0` so
///     the multiplication zeroes out.
public struct VehicleComponent: Component, Sendable {

    /// Stable identity of this vehicle instance. Set at creation and
    /// NEVER rewritten — the Store keys its snapshot list on this.
    public let vehicleId: UUID

    /// Vehicle kind. Drives `maxSpeed`, `verticalSpeed`, `hasGravity`.
    public let vehicleType: VehicleType

    /// `true` between `.enter` and `.exit`. The System skips motion
    /// integration when this is `false`, so an unoccupied drone hangs
    /// in the air where it was summoned.
    public var isOccupied: Bool

    /// Normalised planar axis on the unit disk. `x` = strafe
    /// (+right), `y` = forward (+forward along local `-Z`).
    public var moveAxis: SIMD2<Float>

    /// Vertical input, clamped to `[-1, 1]`. `+1` = ascend, `-1` =
    /// descend. Drone only; drill car multiplies this by its
    /// `verticalSpeed = 0` and so ignores it.
    public var verticalInput: Float

    public init(
        vehicleType: VehicleType,
        vehicleId: UUID = UUID(),
        isOccupied: Bool = false,
        moveAxis: SIMD2<Float> = .zero,
        verticalInput: Float = 0
    ) {
        self.vehicleId = vehicleId
        self.vehicleType = vehicleType
        self.isOccupied = isOccupied
        self.moveAxis = moveAxis
        self.verticalInput = verticalInput
    }
}
