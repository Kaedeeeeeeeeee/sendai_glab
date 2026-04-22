// VehicleControlSystem.swift
// SDGGameplay · Vehicles
//
// RealityKit ECS `System` that integrates `VehicleComponent` inputs
// into the vehicle entity's transform each frame. This is the only
// place the vehicle entity's position is written (the Store writes to
// the *component*; the System writes to the *entity*). Running on
// MainActor matches RealityKit's SDK-isolation of `Entity.position`
// and `Entity.orientation` mutators.
//
// ## Motion model
//
//   * Planar: `moveAxis` is treated as desired velocity in the
//     vehicle's *local* space (x = strafe, y = forward along -Z).
//     `velocity = axis * vehicleType.maxSpeed`, translation is
//     `velocity * deltaTime`. No acceleration, no steering lag —
//     identical to the player's model to keep feel predictable.
//
//   * Vertical (drone): `verticalInput * vehicleType.verticalSpeed`
//     added to Y. The drill car's `verticalSpeed = 0` neutralises
//     this without a branch.
//
//   * Gravity (drill car): when `hasGravity` is `true` and the
//     vehicle is occupied, the Y position accrues `-gravity * dt`
//     per frame. Phase 2 Beta has no terrain collision — the drill
//     car will fall forever below y=0. That is explicitly out of
//     scope; Phase 3 adds collision.
//
// The System deliberately does NOT apply gravity while unoccupied:
//
//   * A summoned but unpiloted drone stays exactly where the Store
//     spawned it, which is the affordance GDD §1.3 asks for
//     ("drop the drone, come back later").
//   * An unpiloted drill car also hangs at spawn Y — this is a known
//     limitation until Phase 3 physics lands. Flagged in the
//     Phase 2 Beta report.
//
// ## Yaw
//
// Not implemented in Phase 2 Beta. The vehicle entity keeps its
// initial orientation; the player uses the existing pan gesture
// (routed to Player or to a future vehicle-look HUD) to look around.
// Adding yaw here would duplicate the camera-parenting decision made
// by RootView's VehicleEntered subscriber, and making it right is
// blocked on the "third-person camera boom" design that Phase 3
// will build on.

import Foundation
import RealityKit
import SDGCore

/// RealityKit ECS `System` that drives occupied vehicles each frame.
///
/// Queries for any entity with a `VehicleComponent`; for each one
/// where `isOccupied` is true, reads `moveAxis` / `verticalInput`,
/// multiplies by the envelope from `vehicleType`, and applies the
/// delta to `entity.position`. Gravity for ground vehicles is
/// layered on after the active input.
public final class VehicleControlSystem: System {

    /// No ordering constraints today. When a `PhysicsSystem` is
    /// added in Phase 3, vehicle integration should run *before*
    /// physics resolution so collisions can reject illegal moves;
    /// `SystemDependency.before(PhysicsSystem.self)` will go here.
    public static let dependencies: [SystemDependency] = []

    /// Downward acceleration applied to gravity-bound vehicles
    /// (drill car), in m/s². ~Earth gravity. Phase 2 Beta has no
    /// terrain collision so this pulls the car through the ground;
    /// Phase 3 must address it — see file header.
    public static let gravity: Float = 9.8

    /// Compiled query matching all vehicle-bearing entities. Built
    /// once at init; the predicate never changes.
    private let query: EntityQuery

    public init(scene: Scene) {
        self.query = EntityQuery(where: .has(VehicleComponent.self))
    }

    public func update(context: SceneUpdateContext) {
        let deltaTime = Float(context.deltaTime)
        guard deltaTime > 0 else { return }

        for entity in context.entities(
            matching: query,
            updatingSystemWhen: .rendering
        ) {
            applyControl(to: entity, deltaTime: deltaTime)
        }
    }

    // MARK: - Per-entity work

    /// Read `VehicleComponent`, integrate, write back.
    ///
    /// Exposed as `internal` so `VehicleControlSystemTests` can drive
    /// the integration step without constructing a full `Scene` —
    /// same pattern as `PlayerControlSystem.applyInput`.
    @discardableResult
    func applyControl(to entity: Entity, deltaTime: Float) -> VehicleComponent {
        guard let component = entity.components[VehicleComponent.self] else {
            // No component on this entity — nothing to integrate.
            // Return a dummy so the internal return type stays
            // non-optional for test call sites.
            return VehicleComponent(vehicleType: .drone)
        }

        let type = component.vehicleType

        if component.isOccupied {
            // --- Planar translation --------------------------------
            // Same local-frame model as PlayerControlSystem: axis.y
            // points forward along entity-local -Z, axis.x strafes
            // along entity-local +X. The entity's current orientation
            // rotates the direction into world space.
            let axis = component.moveAxis
            if axis != .zero {
                let localDir = SIMD3<Float>(axis.x, 0, -axis.y)
                let worldDir = entity.orientation.act(localDir)
                entity.position += worldDir * (type.maxSpeed * deltaTime)
            }

            // --- Vertical (drone) ----------------------------------
            // verticalSpeed = 0 for drill car, so no branch needed.
            let vertical = component.verticalInput
            if vertical != 0 {
                entity.position.y += vertical * type.verticalSpeed * deltaTime
            }
        }

        // --- Gravity (drill car) -----------------------------------
        // Applied whether or not occupied, so a parked drill car
        // would eventually settle on the ground — the Phase 3
        // collision system will clamp it. Applied AFTER horizontal
        // motion so the downward component does not cancel out a
        // horizontal move.
        if type.hasGravity && component.isOccupied {
            entity.position.y -= Self.gravity * deltaTime
        }

        return component
    }
}
