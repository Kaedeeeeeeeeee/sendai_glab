// VehicleEvents.swift
// SDGGameplay · Vehicles
//
// Cross-layer events fired by `VehicleStore` whenever the vehicle
// lifecycle crosses a boundary the rest of the app cares about. The
// subscribers today are:
//
//   * `RootView` — listens for `.summon` so it can realise a
//     RealityKit entity from `VehicleMeshFactory`, attach a
//     `VehicleComponent`, and add it to the scene.
//   * `RootView` — listens for `.entered` / `.exited` so it can
//     re-parent the `PerspectiveCamera` between player and vehicle.
//   * HUD / analytics / SFX — any side-channel that needs to react
//     to the transition but does not own the RealityKit scene.
//
// Per ADR-0001 the Store is forbidden from touching entities, so the
// event bus is the sanctioned way to ask the world to change.

import Foundation
import SDGCore

/// Published when the Store accepts a `.summon` intent. Signals "a
/// vehicle of this kind should appear at this world-space position —
/// please build its RealityKit entity and register it in the scene".
///
/// Why an event instead of returning the entity from `intent(_:)`?
/// The Store cannot import RealityKit (ADR-0001). Handing the job to
/// a scene-side subscriber (RootView's RealityView update closure)
/// keeps the layering intact and also lets tests run without a live
/// RealityKit scene.
public struct VehicleSummoned: GameEvent, Equatable {

    /// Stable identity of the newly-summoned vehicle. Matches both
    /// the `VehicleSnapshot.id` stored on the Store and the
    /// `VehicleComponent.vehicleId` on the entity once the
    /// scene-side subscriber creates it.
    public let vehicleId: UUID

    /// Which kind of vehicle to materialise. The RootView uses this
    /// to pick between `VehicleMeshFactory.makeDrone()` and
    /// `.makeDrillCar()`.
    public let vehicleType: VehicleType

    /// World-space spawn position. The spawner (usually "beside the
    /// player") is the intent-originator's concern; the event just
    /// relays the resolved value.
    public let position: SIMD3<Float>

    public init(vehicleId: UUID, vehicleType: VehicleType, position: SIMD3<Float>) {
        self.vehicleId = vehicleId
        self.vehicleType = vehicleType
        self.position = position
    }
}

/// Published when the player enters a vehicle (`.enter` intent
/// succeeded — i.e. the requested `vehicleId` was known to the
/// Store). The scene-side subscriber responds by:
///
///   1. Flipping the vehicle's `VehicleComponent.isOccupied = true`.
///   2. Re-parenting the `PerspectiveCamera` from the player to the
///      vehicle root.
///   3. Hiding the player mesh (drone is 3rd-person from behind; the
///      drill car cockpit is 1st-person).
public struct VehicleEntered: GameEvent, Equatable {

    /// Id of the vehicle that was entered.
    public let vehicleId: UUID

    /// Vehicle kind — carried so subscribers don't need to look up
    /// the snapshot list to pick a camera rig.
    public let vehicleType: VehicleType

    public init(vehicleId: UUID, vehicleType: VehicleType) {
        self.vehicleId = vehicleId
        self.vehicleType = vehicleType
    }
}

/// Published when the player exits the currently-occupied vehicle
/// (`.exit` intent). The scene-side subscriber:
///
///   1. Flips the vehicle's `VehicleComponent.isOccupied = false`
///      and zeroes its inputs.
///   2. Re-parents the `PerspectiveCamera` back to the player.
///   3. Repositions the player a safe distance from the vehicle
///      (exact geometry is the scene-side's call; GDD leaves the
///      "2 m below the drone, ground-raycast" policy from the Unity
///      reference as the pattern to keep).
public struct VehicleExited: GameEvent, Equatable {

    /// Id of the vehicle that was just exited. The Store has
    /// already cleared `occupiedVehicleId` by the time this fires.
    public let vehicleId: UUID

    public init(vehicleId: UUID) {
        self.vehicleId = vehicleId
    }
}
