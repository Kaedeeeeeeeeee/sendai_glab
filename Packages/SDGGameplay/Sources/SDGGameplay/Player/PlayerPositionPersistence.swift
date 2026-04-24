// PlayerPositionPersistence.swift
// SDGGameplay · Player
//
// UserDefaults-backed persistence for the player's last-known world
// pose. Lets the player quit in the middle of the corridor and
// reload roughly where they left off, instead of always snapping
// back to the lab spawn.
//
// ## Scope
//
// MVP persists only the two quantities that matter for gameplay
// resume: planar world position and yaw (heading). Pitch is
// intentionally dropped — falling asleep with the camera pointing at
// the sky and reloading to stare at the sky is worse UX than just
// levelling the horizon.
//
// Same `struct of closures` pattern as `InventoryPersistence` /
// `QuestPersistence` / `VehiclePersistence` — see InventoryPersistence's
// header for the architectural rationale.
//
// ## Why no Store for this
//
// The live player transform is owned by the RealityKit entity, not a
// Store. `PlayerControlStore` is the input-intent container; adding
// a mirror of `position` to it would duplicate state the scene graph
// already owns. Instead, the persistence is a free-standing façade
// that `AppLaunchCoordinator` drives at bootstrap (load → apply to
// entity) and teardown (read entity → save) — no Store round-trip.

import Foundation

/// Pluggable persistence façade for the player's last-known pose.
///
/// ### Backends
/// - ``standard``: `UserDefaults.standard`, for production.
/// - ``userDefaults(_:)``: caller-supplied defaults (for tests).
/// - ``inMemory``: pure RAM, fresh per call.
///
/// ### Error model
/// - `save` throws on encode failure (practically never for the
///   fixed-width float payload here).
/// - `load` returns `nil` when the defaults entry is missing (first
///   launch) — caller decides whether to fall back to a spawn point.
///   A malformed blob throws.
public struct PlayerPositionPersistence: Sendable {

    /// Snapshot of the player's last-known world pose.
    ///
    /// Stored fields:
    /// - `position`: world-space `SIMD3<Float>` (metres).
    /// - `yawRadians`: scalar heading in radians, measured from
    ///   world `-Z` (RealityKit's default forward). A full turn is
    ///   `2π`; values are not normalised on save to avoid masking
    ///   rotation history when debugging.
    ///
    /// Intentionally NOT stored:
    /// - Pitch / roll (see file header for rationale).
    /// - Velocity (gameplay resumes at rest).
    public struct Snapshot: Codable, Sendable, Equatable {

        /// World-space position in metres. Matches
        /// `Entity.position(relativeTo: nil)` coordinate space.
        public var position: SIMD3<Float>

        /// Heading in radians. Caller applies to the player entity's
        /// orientation by building a quaternion around `+Y`.
        public var yawRadians: Float

        public init(position: SIMD3<Float>, yawRadians: Float) {
            self.position = position
            self.yawRadians = yawRadians
        }
    }

    /// Persisted schema version. Bump if the `Snapshot` shape changes
    /// incompatibly.
    public static let schemaKey = "sdg.playerposition.v1"

    private let saveImpl: @Sendable (Snapshot) throws -> Void
    private let loadImpl: @Sendable () throws -> Snapshot?

    private init(
        save: @escaping @Sendable (Snapshot) throws -> Void,
        load: @escaping @Sendable () throws -> Snapshot?
    ) {
        self.saveImpl = save
        self.loadImpl = load
    }

    /// Default production backend: `UserDefaults.standard` at
    /// `"sdg.playerposition.v1"`.
    public static let standard: PlayerPositionPersistence = .userDefaults(.standard)

    /// UserDefaults-backed persistence with a caller-supplied defaults
    /// instance. See `InventoryPersistence.userDefaults(_:)` for the
    /// `@unchecked Sendable` rationale.
    public static func userDefaults(_ defaults: UserDefaults) -> PlayerPositionPersistence {
        let key = Self.schemaKey
        let box = UserDefaultsBox(defaults: defaults)
        return PlayerPositionPersistence(
            save: { snapshot in
                let data = try JSONEncoder().encode(snapshot)
                box.defaults.set(data, forKey: key)
            },
            load: {
                guard let data = box.defaults.data(forKey: key) else {
                    // Missing entry = first launch; return nil so the
                    // caller can pick a spawn point rather than
                    // placing the player at (0, 0, 0).
                    return nil
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
    public static var inMemory: PlayerPositionPersistence {
        final class Box: @unchecked Sendable {
            let lock = NSLock()
            var snapshot: Snapshot?
        }
        let box = Box()
        return PlayerPositionPersistence(
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

    /// Load the last-saved snapshot, or `nil` if none has ever been
    /// written (first launch). Throws only on a malformed blob.
    public func load() throws -> Snapshot? {
        try loadImpl()
    }
}
