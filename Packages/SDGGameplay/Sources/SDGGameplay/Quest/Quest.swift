// Quest.swift
// SDGGameplay · Quest
//
// Value-typed, framework-free representation of a player quest. Ports
// the Unity `QuestSystem/Quest.cs` types into Swift, keeping only the
// data that actually travels between the store, persistence, and UI.
//
// Scope vs. legacy Unity:
// - No `MonoBehaviour`, no singleton. Pure data.
// - The old runtime attached no reward information to `Quest`; rewards
//   were hard-coded inside `QuestManager.GrantRewards(...)`. We lift
//   them onto the quest definition (see `QuestReward`) so the catalog
//   is a single source of truth and tests can assert on the surface
//   without re-reading `QuestManager`.
// - `IsAllObjectivesCompleted()` stays, but as a computed property
//   (`areAllObjectivesCompleted`) — Swift idiom, no behavioural change.

import Foundation

/// Lifecycle status of a quest.
///
/// Mirrors Unity `QuestSystem/Quest.cs::QuestStatus` exactly. The
/// `rewardClaimed` case is kept even though the legacy project never
/// transitioned into it (the Unity manager stopped at `Completed`); we
/// reserve it for Phase 2 reward-gating UI without a second migration.
public enum QuestStatus: String, Codable, Sendable, Hashable {
    /// The quest exists in the catalog but the player has not begun it.
    case notStarted
    /// The quest has been started and at least one objective is still open.
    case inProgress
    /// Every objective is complete. Rewards may or may not have been granted.
    case completed
    /// Completed *and* rewards consumed. Reserved for Phase 2 UX gating.
    case rewardClaimed
}

/// A single objective inside a quest (e.g. "talk to Dr. Kaede",
/// "collect 3 samples"). Mirrors Unity `QuestObjective`.
///
/// Identity is `String` rather than `UUID` so the catalog can stay
/// human-authored and persistence can round-trip ids without relying on
/// a codable-uuid mapping.
public struct QuestObjective: Codable, Sendable, Identifiable, Hashable {

    /// Stable identifier, e.g. `q.lab.intro.intro_done`. Used as the
    /// key in `QuestPersistence` to mark an objective finished.
    public let id: String

    /// Localization key for the objective label in the quest tracker.
    public let titleKey: String

    /// Whether the objective has been satisfied. `QuestStore` writes
    /// this through `.completeObjective(...)`.
    public var completed: Bool

    public init(id: String, titleKey: String, completed: Bool = false) {
        self.id = id
        self.titleKey = titleKey
        self.completed = completed
    }
}

/// Reward granted when a quest is completed.
///
/// New to the Swift port — the legacy Unity `QuestManager` hard-coded
/// rewards inside `GrantRewards(string questId)` which made them
/// invisible to the data layer. Modeling rewards as a `Codable` case
/// lets the catalog declare them once and the store publish a
/// `RewardGranted` event without cross-referencing a switch-case soup.
public enum QuestReward: Codable, Sendable, Hashable {

    /// Unlock an inventory tool the player can equip. `toolId` is the
    /// canonical tool identifier (e.g. `"hammer"`, `"scene_switcher"`).
    /// Tool identifiers are strings rather than an enum so the catalog
    /// stays data-driven and new tools in Phase 2 don't require
    /// recompiling Quest.swift.
    case unlockTool(toolId: String)

    /// Mark a named story flag. Used by dialogue / quest conditions
    /// that key on "player has already seen X". Phase 2 Beta keeps
    /// flags as opaque strings; a first-class `StoryFlag` enum can land
    /// later when the flag vocabulary stabilises.
    case markStoryFlag(key: String)
}

/// A quest definition plus its current player-specific status.
///
/// `Quest` values live in the `QuestStore.quests` array. The store
/// hydrates status from `QuestPersistence` on `start()`, mutates status
/// on intents, and is the only writer.
public struct Quest: Codable, Sendable, Identifiable, Hashable {

    /// Stable, human-authored identifier (e.g. `q.lab.intro`). Matches
    /// the id used as a PlayerPrefs set entry in the legacy project.
    public let id: String

    /// Localization key for the quest title ("Introduction to the Lab").
    public let titleKey: String

    /// Localization key for the quest description / flavour text.
    public let descriptionKey: String

    /// Objectives in display order. The Unity manager only ever
    /// completed objectives by explicit id lookup, so order is purely
    /// presentational.
    public var objectives: [QuestObjective]

    /// Current lifecycle status. Default `.notStarted` so catalog
    /// literals don't need to repeat the value.
    public var status: QuestStatus

    /// Rewards to grant when `status` transitions into `.completed`.
    /// Empty for quests that only drive the story forward (no tool
    /// unlock, no flag bump).
    public var rewards: [QuestReward]

    public init(
        id: String,
        titleKey: String,
        descriptionKey: String,
        objectives: [QuestObjective],
        status: QuestStatus = .notStarted,
        rewards: [QuestReward] = []
    ) {
        self.id = id
        self.titleKey = titleKey
        self.descriptionKey = descriptionKey
        self.objectives = objectives
        self.status = status
        self.rewards = rewards
    }

    /// `true` iff `objectives` is non-empty and every objective is
    /// marked complete. Non-empty guard mirrors the legacy behaviour —
    /// a quest with zero objectives is *not* considered finished, which
    /// avoids accidentally auto-completing malformed entries.
    public var areAllObjectivesCompleted: Bool {
        guard !objectives.isEmpty else { return false }
        return objectives.allSatisfy(\.completed)
    }
}
