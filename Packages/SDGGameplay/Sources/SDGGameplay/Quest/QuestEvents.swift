// QuestEvents.swift
// SDGGameplay · Quest
//
// Cross-module events fired by `QuestStore`. Three-layer architecture
// (ADR-0001): stores announce lifecycle transitions on the bus; UIs
// and systems listen without ever dereferencing the store directly.
//
// ## Event flow
//
//     QuestStore.intent(.start(id))
//             └─ publishes QuestStarted
//
//     QuestStore.intent(.completeObjective(questId, objId))
//             ├─ publishes ObjectiveCompleted
//             └─ (if all objectives done)
//                     ├─ publishes QuestCompleted
//                     └─ for each reward → RewardGranted
//
// We deliberately split `QuestCompleted` from `RewardGranted` rather
// than bundling rewards on `QuestCompleted`:
// - A future "claim reward" UI flow may want to defer granting.
// - Analytics consumers may want to count rewards per type without
//   destructuring quest state.
// - Tests can assert on the per-reward event without rebuilding the
//   quest payload.

import Foundation
import SDGCore

/// Published when a quest transitions from `.notStarted` → `.inProgress`.
///
/// Subscribers typically refresh the quest tracker HUD or kick off a
/// guidance arrow toward the first objective location.
public struct QuestStarted: GameEvent, Equatable {

    /// Id of the quest that just started. Matches `Quest.id`.
    public let questId: String

    public init(questId: String) {
        self.questId = questId
    }
}

/// Published when a quest objective is marked complete. May precede a
/// `QuestCompleted` event in the same publish pass if the completed
/// objective was the last open one.
public struct ObjectiveCompleted: GameEvent, Equatable {

    /// Id of the quest the objective belongs to.
    public let questId: String

    /// Id of the objective that was just completed.
    public let objectiveId: String

    public init(questId: String, objectiveId: String) {
        self.questId = questId
        self.objectiveId = objectiveId
    }
}

/// Published when a quest's status transitions into `.completed` (i.e.
/// every objective is satisfied). Fires before any `RewardGranted`
/// events so UI code can animate "quest complete!" before the reward
/// toast lands.
public struct QuestCompleted: GameEvent, Equatable {

    /// Id of the quest that just completed.
    public let questId: String

    public init(questId: String) {
        self.questId = questId
    }
}

/// Published once per reward attached to a freshly-completed quest.
///
/// `reward` carries the full `QuestReward` enum so subscribers can
/// pattern-match without reading `QuestStore` state. Example:
/// `InventoryStore` (future Phase 2) will subscribe, match on
/// `.unlockTool` and flip its `unlockedTools` set.
public struct RewardGranted: GameEvent, Equatable {

    /// Id of the quest the reward belongs to. Useful for logging /
    /// correlating with the preceding `QuestCompleted`.
    public let questId: String

    /// The reward itself.
    public let reward: QuestReward

    public init(questId: String, reward: QuestReward) {
        self.questId = questId
        self.reward = reward
    }
}
