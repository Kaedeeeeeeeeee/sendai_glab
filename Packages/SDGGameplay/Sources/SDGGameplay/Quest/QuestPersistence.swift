// QuestPersistence.swift
// SDGGameplay · Quest
//
// UserDefaults-backed persistence for quest progression. Stores three
// sets of opaque string ids:
//   1. Completed quest ids
//   2. Completed objective ids
//   3. Granted reward ids (dedupe so rewards never double-fire)
//
// Same `struct of closures` pattern as `InventoryPersistence` — see
// that file's header for the architectural rationale (value type,
// `Sendable`, no protocol existential, cheap `.inMemory` for tests).

import Foundation

/// Pluggable persistence façade for `QuestStore`.
///
/// ### Backends
/// - ``standard``: `UserDefaults.standard`, for production.
/// - ``userDefaults(_:)``: caller-supplied defaults (for tests that
///   isolate via `UserDefaults(suiteName:)`).
/// - ``inMemory``: pure RAM, fresh per call.
///
/// ### Error model
/// - `save` throws on encode failure (practically never for
///   `[String]`). `UserDefaults.set` itself is non-throwing; `inMemory`
///   never throws.
/// - `load` returns an empty snapshot when the defaults entry is
///   missing — first-launch behaviour, not an error. A malformed blob
///   throws.
///
/// ### Reward bookkeeping
/// `QuestReward` itself is not keyable, so we flatten each reward to a
/// stable string key via ``rewardKey(questId:reward:)`` before storing.
/// Adding a new `QuestReward` case requires extending that helper —
/// enforced by the `@unknown default` branch so the compiler warns.
public struct QuestPersistence: Sendable {

    /// Snapshot of everything we persist. Kept as a value-typed Codable
    /// struct so save/load is a single JSON round-trip rather than
    /// three separate UserDefaults reads.
    public struct Snapshot: Codable, Sendable, Equatable {

        /// Ids of every quest currently in status `.completed` or
        /// `.rewardClaimed`.
        public var completedQuestIds: Set<String>

        /// Ids of every objective that has been marked complete.
        public var completedObjectiveIds: Set<String>

        /// String keys of rewards already granted. Guards against
        /// double-firing `RewardGranted` if a quest is re-entered and
        /// re-completed (shouldn't happen, but belt-and-braces).
        public var grantedRewardKeys: Set<String>

        public init(
            completedQuestIds: Set<String> = [],
            completedObjectiveIds: Set<String> = [],
            grantedRewardKeys: Set<String> = []
        ) {
            self.completedQuestIds = completedQuestIds
            self.completedObjectiveIds = completedObjectiveIds
            self.grantedRewardKeys = grantedRewardKeys
        }

        public static let empty = Snapshot()
    }

    /// Persisted schema version. Bump if the `Snapshot` shape changes
    /// incompatibly.
    public static let schemaKey = "sdg.quest.v1"

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
    /// `"sdg.quest.v1"`.
    public static let standard: QuestPersistence = .userDefaults(.standard)

    /// UserDefaults-backed persistence with a caller-supplied defaults
    /// instance. See `InventoryPersistence.userDefaults(_:)` for the
    /// `@unchecked Sendable` rationale.
    public static func userDefaults(_ defaults: UserDefaults) -> QuestPersistence {
        let key = Self.schemaKey
        let box = UserDefaultsBox(defaults: defaults)
        return QuestPersistence(
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
    public static var inMemory: QuestPersistence {
        final class Box: @unchecked Sendable {
            let lock = NSLock()
            var snapshot: Snapshot = .empty
        }
        let box = Box()
        return QuestPersistence(
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

    /// Build a stable string key for a `(questId, reward)` pair.
    ///
    /// The format `"<questId>|<kind>:<payload>"` is deliberate: the
    /// pipe is not used in any legacy quest id and keeps the key
    /// trivially greppable in UserDefaults dumps.
    ///
    /// Extending `QuestReward` requires extending this switch — the
    /// absence of a `default` arm ensures a compile error, not a
    /// silent collision.
    public static func rewardKey(questId: String, reward: QuestReward) -> String {
        switch reward {
        case .unlockTool(let toolId):
            return "\(questId)|unlockTool:\(toolId)"
        case .markStoryFlag(let key):
            return "\(questId)|markStoryFlag:\(key)"
        }
    }
}
