// VehicleStore.swift
// SDGGameplay · Vehicles
//
// `@Observable` middle-layer container for the vehicle lifecycle. The
// Store is the single source of truth for:
//
//   * Which vehicles have been summoned into the world.
//   * Which one (if any) the player currently occupies.
//   * The pilot's latest joystick / climb input while occupied.
//
// Per ADR-0001 the Store owns no RealityKit entities. Scene changes
// (materialise an entity, re-parent the camera) are accomplished by
// publishing events — `VehicleSummoned`, `VehicleEntered`,
// `VehicleExited` — that the scene-side subscriber (RootView) acts on.
//
// ## Input routing
//
// `.pilot(axis:vertical:)` is the sole path from the HUD to the
// vehicle's motion:
//
//     HUD joystick ── .pilot ──▶ VehicleStore
//                                     │ (stores on snapshot)
//                                     │ (writes to VehicleComponent
//                                     │  on the entity held weakly)
//                                     ▼
//                          VehicleControlSystem reads component
//                          every frame, integrates, translates entity.
//
// We intentionally do NOT re-derive input by subscribing to the
// Player's joystick events: the HUD swaps the joystick target (player
// vs vehicle) based on `occupiedVehicleId`, and only one Store sees
// each sample. This keeps the Store source-of-truth and prevents
// double-integration bugs.
//
// ## Concurrency
//
// `@MainActor` because RealityKit `Entity` mutations are MainActor-
// isolated; the Store writes directly into the component on the
// entity it holds a weak reference to. That mirrors the pattern used
// by `PlayerControlStore.attach(playerEntity:)`.

import Foundation
import Observation
import RealityKit
import SDGCore

/// Immutable snapshot of a summoned vehicle. `Identifiable` so
/// SwiftUI `ForEach` can render the Store's `summonedVehicles` list
/// without a secondary id mapping.
///
/// Note: `position` here is the **spawn** position, not the live one.
/// Once a vehicle exists its authoritative position is the transform
/// on the RealityKit entity. Consumers that need live position must
/// read it from the scene; the snapshot only tracks "where was it
/// born".
public struct VehicleSnapshot: Sendable, Identifiable, Equatable {

    /// Stable identity, matches `VehicleComponent.vehicleId`.
    public let id: UUID

    /// Vehicle kind.
    public let type: VehicleType

    /// World-space spawn position. Frozen at summon time.
    public let position: SIMD3<Float>

    public init(id: UUID, type: VehicleType, position: SIMD3<Float>) {
        self.id = id
        self.type = type
        self.position = position
    }
}

/// Observable state for the vehicle lifecycle.
///
/// ### Intents
///
///   * ``Intent/summon(_:position:)`` — "spawn a vehicle of this
///     kind at this point". Appends a snapshot and publishes
///     `VehicleSummoned`. The actual RealityKit entity is built by
///     the event's subscriber (RootView).
///
///   * ``Intent/enter(vehicleId:)`` — "the player is now piloting
///     this vehicle". Only succeeds if the id is in the snapshot
///     list AND the player is not already occupying something.
///     Publishes `VehicleEntered` on success.
///
///   * ``Intent/exit`` — "the player stepped out". No-op if nobody
///     is occupying a vehicle. Publishes `VehicleExited`.
///
///   * ``Intent/pilot(axis:vertical:)`` — "latest joystick + climb
///     sample". Writes the values into the occupied vehicle's
///     `VehicleComponent` (via the weak entity map) and updates the
///     Store's own observable mirrors. No-op while not occupying.
///
/// ### Entity binding
///
/// `register(entity:for:)` hands the Store a weak reference to the
/// scene-side entity for a given `vehicleId`. The scene-side
/// subscriber to `VehicleSummoned` must call this as soon as the
/// entity is created; piloting samples received before the entity
/// is bound update the Store state but cannot land on the scene —
/// same "soft-fail" contract as `PlayerControlStore.attach`.
@MainActor
@Observable
public final class VehicleStore: Store {

    // MARK: - Intent

    /// Commands the Store accepts.
    public enum Intent: Sendable, Equatable {

        /// Spawn a new vehicle of `type` at the world-space
        /// `position`. The Store assigns the `UUID`; callers read
        /// the resulting snapshot from `summonedVehicles`.
        case summon(VehicleType, position: SIMD3<Float>)

        /// Attempt to pilot the vehicle with the given id. If the
        /// id is unknown or the player is already piloting, the
        /// intent is a no-op (the Store publishes nothing).
        case enter(vehicleId: UUID)

        /// Stop piloting the currently-occupied vehicle. No-op when
        /// no vehicle is occupied.
        case exit

        /// Latest joystick + climb sample from the HUD. `axis` is
        /// expected on the unit disk (`length ≤ 1`); `vertical`
        /// clamped to `[-1, 1]`. Clamping is the HUD's job — the
        /// Store accepts the value as given. No-op while
        /// `occupiedVehicleId == nil`.
        case pilot(axis: SIMD2<Float>, vertical: Float)
    }

    // MARK: - Observable state

    /// Every vehicle that has been summoned, in summon order. Exposed
    /// for HUD lists ("nearby vehicles") and for the `.enter`
    /// validation path.
    public private(set) var summonedVehicles: [VehicleSnapshot] = []

    /// The vehicle the player currently pilots, or `nil` while on
    /// foot. Used by the HUD to decide which joystick target to
    /// route samples to.
    public private(set) var occupiedVehicleId: UUID?

    // MARK: - Private

    private let eventBus: EventBus

    /// Weak map from `vehicleId` to the RealityKit entity that the
    /// scene-side subscriber created. Weak so the Store does not
    /// keep entities alive past scene teardown. `NSMapTable` was
    /// considered; a plain `[UUID: WeakEntityBox]` is simpler and
    /// the N is tiny (single-digit vehicles per session).
    private var entityRegistry: [UUID: WeakEntityBox] = [:]

    // MARK: - Init

    public init(eventBus: EventBus) {
        self.eventBus = eventBus
    }

    // MARK: - Scene-side binding

    /// Register the RealityKit entity created for a previously-
    /// summoned `vehicleId`. Called by the RootView subscriber to
    /// `VehicleSummoned` once the entity is in the scene. Holds a
    /// weak reference internally.
    ///
    /// Calling twice replaces the reference — useful for scene
    /// reloads; quiet rather than fatal so it isn't a foot-gun.
    public func register(entity: Entity, for vehicleId: UUID) {
        entityRegistry[vehicleId] = WeakEntityBox(entity: entity)
    }

    /// Forget the entity for a vehicle id. Safe even if the id was
    /// never registered. Intended for scene teardown.
    public func unregister(vehicleId: UUID) {
        entityRegistry.removeValue(forKey: vehicleId)
    }

    /// Look up the scene-side entity for a previously-registered
    /// vehicle id. Returns `nil` if the id is unknown or the entity
    /// has been deallocated (weak reference).
    ///
    /// Used by the Phase 7 UX layer (RootView) to:
    /// * re-parent the camera onto the vehicle on `VehicleEntered`,
    /// * read the vehicle's live world position for the Board / Exit
    ///   HUD button's proximity check (snapshot positions go stale
    ///   the moment the vehicle starts moving).
    public func entity(for vehicleId: UUID) -> Entity? {
        entityRegistry[vehicleId]?.entity
    }

    // MARK: - Store protocol

    public func intent(_ intent: Intent) async {
        switch intent {
        case let .summon(type, position):
            await summon(type: type, at: position)
        case let .enter(vehicleId):
            await enter(vehicleId: vehicleId)
        case .exit:
            await exitCurrent()
        case let .pilot(axis, vertical):
            applyPilot(axis: axis, vertical: vertical)
        }
    }

    // MARK: - Private: summon

    private func summon(type: VehicleType, at position: SIMD3<Float>) async {
        let id = UUID()
        let snapshot = VehicleSnapshot(id: id, type: type, position: position)
        summonedVehicles.append(snapshot)
        await eventBus.publish(
            VehicleSummoned(vehicleId: id, vehicleType: type, position: position)
        )
    }

    // MARK: - Private: enter

    private func enter(vehicleId: UUID) async {
        // Guard: already occupying something. Swapping vehicles
        // requires an explicit `.exit` first so the camera rig /
        // HUD transitions stay symmetric and debuggable.
        guard occupiedVehicleId == nil else { return }

        // Guard: the id must be a vehicle we know about.
        guard let snapshot = summonedVehicles.first(where: { $0.id == vehicleId }) else {
            return
        }

        occupiedVehicleId = vehicleId

        // Flip the component's `isOccupied` if the entity is bound
        // yet. If the scene hasn't registered the entity by the
        // time `.enter` fires, the Store state is still authoritative
        // and the scene-side subscriber to `VehicleEntered` can flip
        // the flag when it binds.
        if let entity = entityRegistry[vehicleId]?.entity {
            var component = entity.components[VehicleComponent.self]
                ?? VehicleComponent(vehicleType: snapshot.type, vehicleId: vehicleId)
            component.isOccupied = true
            entity.components.set(component)
        }

        await eventBus.publish(
            VehicleEntered(vehicleId: vehicleId, vehicleType: snapshot.type)
        )
    }

    // MARK: - Private: exit

    private func exitCurrent() async {
        guard let vehicleId = occupiedVehicleId else { return }
        occupiedVehicleId = nil

        // Clear the component state so a parked vehicle does not
        // keep integrating whatever the last joystick sample was.
        if let entity = entityRegistry[vehicleId]?.entity,
           var component = entity.components[VehicleComponent.self] {
            component.isOccupied = false
            component.moveAxis = .zero
            component.verticalInput = 0
            entity.components.set(component)
        }

        await eventBus.publish(VehicleExited(vehicleId: vehicleId))
    }

    // MARK: - Private: pilot

    /// Write the latest joystick sample into the currently-occupied
    /// vehicle's component. No-op while not occupying; that is the
    /// right semantics because the HUD never produces samples for a
    /// non-existent target. A stray sample after `.exit` should not
    /// scoot a parked vehicle.
    private func applyPilot(axis: SIMD2<Float>, vertical: Float) {
        guard let vehicleId = occupiedVehicleId else { return }
        guard let entity = entityRegistry[vehicleId]?.entity else { return }
        guard var component = entity.components[VehicleComponent.self] else { return }

        component.moveAxis = axis
        component.verticalInput = vertical
        entity.components.set(component)
    }

    // MARK: - Test hook

    /// Reset to a fresh state. Test-only. `public` so cross-module
    /// tests can reach it; production owns the Store for the app's
    /// full lifetime.
    public func resetForTesting() {
        summonedVehicles = []
        occupiedVehicleId = nil
        entityRegistry = [:]
    }
}

// MARK: - Weak entity box

/// Tiny wrapper so `entityRegistry` can hold weak references in a
/// plain dictionary. `NSMapTable` would work but imports Foundation
/// collections we don't need elsewhere here.
@MainActor
private final class WeakEntityBox {
    weak var entity: Entity?
    init(entity: Entity) {
        self.entity = entity
    }
}
