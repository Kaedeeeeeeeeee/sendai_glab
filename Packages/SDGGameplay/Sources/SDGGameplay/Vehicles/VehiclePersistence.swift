// VehiclePersistence.swift
// SDGGameplay · Vehicles
//
// UserDefaults-backed persistence for the vehicle lifecycle. Persists
// the `[VehicleSnapshot]` roster plus the currently-occupied vehicle
// id so a summoned drone survives app quit; the scene-side subscriber
// to `VehicleSummoned` (RootView) re-materialises the entities on
// reload through the same code path as an interactive summon.
//
// Same `struct of closures` pattern as `InventoryPersistence` /
// `QuestPersistence` — see the former's header for the architectural
// rationale (value type, `Sendable`, no protocol existential, cheap
// `.inMemory` for tests).

import Foundation

/// Pluggable persistence façade for `VehicleStore`.
///
/// ### Backends
/// - ``standard``: `UserDefaults.standard`, for production.
/// - ``userDefaults(_:)``: caller-supplied defaults (for tests that
///   isolate via `UserDefaults(suiteName:)`).
/// - ``inMemory``: pure RAM, fresh per call.
///
/// ### Error model
/// - `save` throws on encode failure. `UserDefaults.set` itself is
///   non-throwing; `.inMemory` never throws.
/// - `load` returns an empty snapshot when the defaults entry is
///   missing — first-launch behaviour, not an error. A malformed blob
///   throws.
public struct VehiclePersistence: Sendable {

    /// Snapshot of everything the Store persists. Kept as a
    /// value-typed `Codable` struct so save/load is a single JSON
    /// round-trip, mirroring `QuestPersistence.Snapshot`.
    public struct Snapshot: Codable, Sendable, Equatable {

        /// Every vehicle the player has summoned, in summon order.
        /// `VehicleSnapshot` is already `Codable` via its `UUID` +
        /// `VehicleType` (String raw) + `SIMD3<Float>` members.
        public var summonedVehicles: [VehicleSnapshot]

        /// Which vehicle (if any) the player was piloting at the
        /// time of the last save. `nil` = on foot.
        public var occupiedVehicleId: UUID?

        public init(
            summonedVehicles: [VehicleSnapshot] = [],
            occupiedVehicleId: UUID? = nil
        ) {
            self.summonedVehicles = summonedVehicles
            self.occupiedVehicleId = occupiedVehicleId
        }

        public static let empty = Snapshot()
    }

    /// Persisted schema version. Bump if the `Snapshot` shape changes
    /// incompatibly.
    public static let schemaKey = "sdg.vehicles.v1"

    private let saveImpl: @Sendable (Snapshot) throws -> Void
    private let loadImpl: @Sendable () throws -> Snapshot

    private init(
        save: @escaping @Sendable (Snapshot) throws -> Void,
        load: @escaping @Sendable () throws -> Snapshot
    ) {
        self.saveImpl = save
        self.loadImpl = load
    }

    /// Default production backend: `UserDefaults.standard` at
    /// `"sdg.vehicles.v1"`.
    public static let standard: VehiclePersistence = .userDefaults(.standard)

    /// UserDefaults-backed persistence with a caller-supplied defaults
    /// instance. See `InventoryPersistence.userDefaults(_:)` for the
    /// `@unchecked Sendable` rationale.
    public static func userDefaults(_ defaults: UserDefaults) -> VehiclePersistence {
        let key = Self.schemaKey
        let box = UserDefaultsBox(defaults: defaults)
        return VehiclePersistence(
            save: { snapshot in
                let data = try JSONEncoder().encode(snapshot)
                box.defaults.set(data, forKey: key)
            },
            load: {
                guard let data = box.defaults.data(forKey: key) else {
                    return .empty
                }
                return try JSONDecoder().decode(Snapshot.self, from: data)
            }
        )
    }

    private final class UserDefaultsBox: @unchecked Sendable {
        let defaults: UserDefaults
        init(defaults: UserDefaults) { self.defaults = defaults }
    }

    /// In-memory backend for tests. Fresh per call.
    public static var inMemory: VehiclePersistence {
        final class Box: @unchecked Sendable {
            let lock = NSLock()
            var snapshot: Snapshot = .empty
        }
        let box = Box()
        return VehiclePersistence(
            save: { snap in
                box.lock.lock()
                defer { box.lock.unlock() }
                box.snapshot = snap
            },
            load: {
                box.lock.lock()
                defer { box.lock.unlock() }
                return box.snapshot
            }
        )
    }

    public func save(_ snapshot: Snapshot) throws {
        try saveImpl(snapshot)
    }

    public func load() throws -> Snapshot {
        try loadImpl()
    }
}
