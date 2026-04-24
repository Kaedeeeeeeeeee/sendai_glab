// DisasterPersistence.swift
// SDGGameplay · Disaster
//
// UserDefaults-backed persistence for `DisasterStore`. Covers two
// concerns that would otherwise evaporate across app quits:
//
//   1. The active `DisasterState`. If the player quits mid-earthquake
//      the quake resumes on reload with whatever `remaining` was last
//      saved; if the blob is idle, the world boots calm.
//
//   2. `triggeredQuestIds` — ids of quests whose quest-driven
//      disaster has already fired once. Guards against re-firing on
//      reload if the quest-completion-to-disaster bridge reprocesses
//      a completed quest.
//
// Same `struct of closures` pattern as `InventoryPersistence` /
// `QuestPersistence` — see the former's header for architectural
// rationale (value type, `Sendable`, no protocol existential, cheap
// `.inMemory` for tests).

import Foundation

/// Pluggable persistence façade for `DisasterStore`.
///
/// ### Backends
/// - ``standard``: `UserDefaults.standard`, for production.
/// - ``userDefaults(_:)``: caller-supplied defaults (for tests that
///   isolate via `UserDefaults(suiteName:)`).
/// - ``inMemory``: pure RAM, fresh per call.
///
/// ### Error model
/// - `save` throws on encode failure (`DisasterState` is a sum-type
///   Codable enum; bad payloads aren't constructable in practice,
///   but the signature keeps parity with the other persistences).
/// - `load` returns `.empty` when the defaults entry is missing.
///   A malformed blob throws.
public struct DisasterPersistence: Sendable {

    /// Snapshot of everything the Store persists.
    ///
    /// Kept tiny on purpose — we are NOT snapshotting the running
    /// tile-shake baseline or the water plane's cached startY/targetY.
    /// Those are scene-graph properties reconstructed by
    /// `DisasterSystem` when it sees the rehydrated `state`. The
    /// Store persists only what it, the Store, owns.
    public struct Snapshot: Codable, Sendable, Equatable {

        /// Current disaster phase. `.idle` on first launch and after
        /// every natural end.
        public var state: DisasterState

        /// Quest ids whose quest-driven disaster has already fired.
        /// Prevents a re-fire on reload after the quest is completed.
        public var triggeredQuestIds: Set<String>

        public init(
            state: DisasterState = .idle,
            triggeredQuestIds: Set<String> = []
        ) {
            self.state = state
            self.triggeredQuestIds = triggeredQuestIds
        }

        public static let empty = Snapshot()
    }

    /// Persisted schema version. Bump if the `Snapshot` shape changes
    /// incompatibly.
    public static let schemaKey = "sdg.disaster.v1"

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
    /// `"sdg.disaster.v1"`.
    public static let standard: DisasterPersistence = .userDefaults(.standard)

    /// UserDefaults-backed persistence with a caller-supplied defaults
    /// instance. See `InventoryPersistence.userDefaults(_:)` for the
    /// `@unchecked Sendable` rationale.
    public static func userDefaults(_ defaults: UserDefaults) -> DisasterPersistence {
        let key = Self.schemaKey
        let box = UserDefaultsBox(defaults: defaults)
        return DisasterPersistence(
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
    public static var inMemory: DisasterPersistence {
        final class Box: @unchecked Sendable {
            let lock = NSLock()
            var snapshot: Snapshot = .empty
        }
        let box = Box()
        return DisasterPersistence(
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
