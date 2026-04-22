// QuestCatalog.swift
// SDGGameplay · Quest
//
// Hard-coded list of every built-in quest. Ports Unity
// `QuestSystem/QuestManager.cs::RegisterBuiltInQuests()` field-by-field
// and attaches the rewards that the legacy `GrantRewards(string questId)`
// switch used to grant out-of-band.
//
// Why a static catalog rather than a JSON file?
// - The legacy project already had these values in code and had no
//   authoring pipeline for quests — bumping to a data-file would have
//   been net-new scope.
// - The catalog is validated at compile time (typos on `QuestReward`
//   cases surface as errors, not runtime crashes).
// - Tests can assert on the catalog surface without stubbing a loader.
//
// Rewards mapping (derived from `QuestManager.GrantRewards`):
//
//     q.lab.intro       → unlockTool("hammer"), unlockTool("scene_switcher")
//     q.lab.return      → unlockTool("scene_switcher"),
//                         unlockTool("drill_simple"),
//                         unlockTool("drill_tower")
//     q.chapter5.kaede  → unlockTool("drone")
//     (all other quests) → none
//
// The legacy code also auto-chains quests after reward grant (e.g.
// finishing `q.lab.intro` auto-starts `q.lab.drkaede`). Chaining lives
// in `QuestStore.handleQuestCompletion(...)` and is not baked into the
// `rewards` field — rewards are for *tools / flags*, not control flow.

import Foundation

/// Static catalog of every quest shipped with the game.
///
/// ``all`` is the single source of truth; lookup helpers (`quest(byId:)`
/// etc.) derive from it so adding a new quest in one place is enough.
public enum QuestCatalog {

    /// Every quest, in narrative order.
    ///
    /// 13 entries, matching Unity `QuestManager.RegisterBuiltInQuests()`.
    /// Order corresponds to the chapter progression:
    /// - Chapter 1: q.lab.intro, q.lab.drkaede, q.lab.anomaly
    /// - Chapter 3 (field): q.field.phase, q.lab.return
    /// - Chapter 4: q.chapter4.kaede, q.chapter4.field, q.chapter4.sample,
    ///              q.chapter4.return
    /// - Chapter 5: q.chapter5.kaede, q.chapter5.field, q.chapter5.return
    /// - Chapter 6: q.chapter6.kaede
    public static let all: [Quest] = [
        Quest(
            id: "q.lab.intro",
            titleKey: "quest.lab.intro.title",
            descriptionKey: "quest.lab.intro.desc",
            objectives: [
                QuestObjective(
                    id: "q.lab.intro.intro_done",
                    titleKey: "quest.lab.intro.obj1"
                )
            ],
            rewards: [
                .unlockTool(toolId: "hammer"),
                .unlockTool(toolId: "scene_switcher")
            ]
        ),

        Quest(
            id: "q.lab.drkaede",
            titleKey: "quest.lab.drkaede.title",
            descriptionKey: "quest.lab.drkaede.desc",
            objectives: [
                QuestObjective(
                    id: "q.lab.drkaede.talk",
                    titleKey: "quest.lab.drkaede.obj1"
                )
            ]
        ),

        Quest(
            id: "q.lab.anomaly",
            titleKey: "quest.lab.anomaly.title",
            descriptionKey: "quest.lab.anomaly.desc",
            objectives: [
                QuestObjective(
                    id: "q.lab.anomaly.talk",
                    titleKey: "quest.lab.anomaly.obj1"
                )
            ]
        ),

        Quest(
            id: "q.field.phase",
            titleKey: "quest.field.phase.title",
            descriptionKey: "quest.field.phase.desc",
            objectives: [
                QuestObjective(
                    id: "q.field.phase.enter_field",
                    titleKey: "quest.field.phase.obj1"
                ),
                QuestObjective(
                    id: "q.field.phase.collect_samples",
                    titleKey: "quest.field.phase.obj2"
                )
            ]
        ),

        Quest(
            id: "q.lab.return",
            titleKey: "quest.lab.return.title",
            descriptionKey: "quest.lab.return.desc",
            objectives: [
                QuestObjective(
                    id: "q.lab.return.enter_lab",
                    titleKey: "quest.lab.return.obj1"
                )
            ],
            rewards: [
                // Scene switcher redundantly re-unlocked in Unity as a
                // safety net; preserved here for behavioural parity.
                .unlockTool(toolId: "scene_switcher"),
                .unlockTool(toolId: "drill_simple"),
                .unlockTool(toolId: "drill_tower")
            ]
        ),

        Quest(
            id: "q.chapter4.kaede",
            titleKey: "quest.chapter4.kaede.title",
            descriptionKey: "quest.chapter4.kaede.desc",
            objectives: [
                QuestObjective(
                    id: "q.chapter4.kaede.talk",
                    titleKey: "quest.chapter4.kaede.obj1"
                )
            ]
        ),

        Quest(
            id: "q.chapter4.field",
            titleKey: "quest.chapter4.field.title",
            descriptionKey: "quest.chapter4.field.desc",
            objectives: [
                QuestObjective(
                    id: "q.chapter4.field.enter_field",
                    titleKey: "quest.chapter4.field.obj1"
                )
            ]
        ),

        Quest(
            id: "q.chapter4.sample",
            titleKey: "quest.chapter4.sample.title",
            descriptionKey: "quest.chapter4.sample.desc",
            objectives: [
                QuestObjective(
                    id: "q.chapter4.sample.collect",
                    titleKey: "quest.chapter4.sample.obj1"
                )
            ]
        ),

        Quest(
            id: "q.chapter4.return",
            titleKey: "quest.chapter4.return.title",
            descriptionKey: "quest.chapter4.return.desc",
            objectives: [
                QuestObjective(
                    id: "q.chapter4.return.enter_lab",
                    titleKey: "quest.chapter4.return.obj1"
                )
            ]
        ),

        Quest(
            id: "q.chapter5.kaede",
            titleKey: "quest.chapter5.kaede.title",
            descriptionKey: "quest.chapter5.kaede.desc",
            objectives: [
                QuestObjective(
                    id: "q.chapter5.kaede.talk",
                    titleKey: "quest.chapter5.kaede.obj1"
                )
            ],
            rewards: [
                .unlockTool(toolId: "drone")
            ]
        ),

        Quest(
            id: "q.chapter5.field",
            titleKey: "quest.chapter5.field.title",
            descriptionKey: "quest.chapter5.field.desc",
            objectives: [
                QuestObjective(
                    id: "q.chapter5.field.enter_field",
                    titleKey: "quest.chapter5.field.obj1"
                )
            ]
        ),

        Quest(
            id: "q.chapter5.return",
            titleKey: "quest.chapter5.return.title",
            descriptionKey: "quest.chapter5.return.desc",
            objectives: [
                QuestObjective(
                    id: "q.chapter5.return.enter_lab",
                    titleKey: "quest.chapter5.return.obj1"
                )
            ]
        ),

        Quest(
            id: "q.chapter6.kaede",
            titleKey: "quest.chapter6.kaede.title",
            descriptionKey: "quest.chapter6.kaede.desc",
            objectives: [
                QuestObjective(
                    id: "q.chapter6.kaede.talk",
                    titleKey: "quest.chapter6.kaede.obj1"
                )
            ]
        )
    ]

    /// Lookup a quest definition by id.
    ///
    /// Returns a fresh `Quest` copy (value type); mutating the result
    /// does not mutate the catalog.
    public static func quest(byId id: String) -> Quest? {
        all.first { $0.id == id }
    }

    /// Lookup the quest that owns the given objective, if any.
    ///
    /// The legacy `QuestManager.CompleteObjective` scanned every quest
    /// for a matching objective; we expose the same lookup as a pure
    /// helper so the store's handler stays a one-liner.
    public static func questContaining(objectiveId: String) -> Quest? {
        all.first { quest in
            quest.objectives.contains { $0.id == objectiveId }
        }
    }
}
