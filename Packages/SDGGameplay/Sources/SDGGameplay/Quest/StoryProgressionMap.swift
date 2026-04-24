// StoryProgressionMap.swift
// SDGGameplay · Quest
//
// Declarative routing tables for story → quest control flow.
//
// Phase 3 wired the first `DialogueFinished → QuestStarted` chain by
// hand inside `RootView.bootstrap()`. That single ad-hoc if-statement
// works for one chapter, but chaining all thirteen quests plus the
// Phase 9 quest → disaster triggers from the same closure would turn
// RootView into the very kind of God-object AGENTS.md §1.1 forbids.
//
// This file collects the control-flow tables into plain data:
//
//   * `dialogueCompletions`: when a `DialogueFinished` for sequence X
//     arrives, complete objective Y.
//   * `questSuccessors`: when a `QuestCompleted` for quest X arrives,
//     start quest Y.
//   * `questDisasters`: when a `QuestCompleted` for quest X arrives,
//     trigger the declared disaster (earthquake / flood).
//
// Two consumers will read the tables:
//
//   1. **StoryProgressionBridge** (implemented whenever the RootView
//      integration happens — see `Docs/Phase9Integration/B.md`).
//      Subscribes to the bus, looks up the incoming event id against
//      these tables, and fires the next intent on `QuestStore` /
//      `DisasterStore`.
//   2. **Unit tests**: the tables are pure data, so we can assert on
//      referential integrity (every listed quest id exists in the
//      catalog) without standing up the bridge.
//
// Why a new file rather than growing `QuestCatalog.swift`? The catalog
// owns *definitions*; this file owns *transitions*. Mixing them buries
// the edges of the state machine inside a node list, which is exactly
// the problem the Unity `QuestManager` had.

import Foundation

// MARK: - Entry shapes

/// One "dialogue finished → objective complete" edge.
///
/// The bridge listens for `DialogueFinished(sequenceId: <key>)` and,
/// on match, dispatches `QuestStore.Intent.completeObjective`.
public struct StoryDialogueCompletion: Sendable, Equatable, Hashable {

    /// Dialogue sequence id (the filename basename — e.g.
    /// `"quest1.1"`).
    public let dialogueSequenceId: String

    /// Quest id to advance (e.g. `"q.lab.intro"`).
    public let questId: String

    /// Specific objective to mark complete. Must reference an
    /// objective declared under `questId` in `QuestCatalog`; the
    /// `StoryProgressionMapTests` asserts this.
    public let objectiveId: String

    public init(dialogueSequenceId: String, questId: String, objectiveId: String) {
        self.dialogueSequenceId = dialogueSequenceId
        self.questId = questId
        self.objectiveId = objectiveId
    }
}

/// One "quest completed → next quest starts" edge.
///
/// The bridge listens for `QuestCompleted(questId: <from>)` and, on
/// match, dispatches `QuestStore.Intent.start(questId: <to>)`. The
/// store itself is idempotent: starting an already-started quest is a
/// no-op, so the edge can safely fire again after a reload.
public struct StoryQuestSuccessor: Sendable, Equatable, Hashable {
    public let fromQuestId: String
    public let toQuestId: String

    public init(fromQuestId: String, toQuestId: String) {
        self.fromQuestId = fromQuestId
        self.toQuestId = toQuestId
    }
}

/// One "quest completed → disaster fires" edge.
///
/// Phase 9 Part B's quest × disaster loop: completing the 青葉山 /
/// 川内 sampling quests triggers an earthquake / flood to give the
/// player immediate feedback on their actions. The bridge consults
/// this table after `QuestCompleted` and dispatches the appropriate
/// `DisasterStore` intent.
public struct StoryQuestDisasterTrigger: Sendable, Equatable, Hashable {

    /// Which disaster to fire.
    public enum Kind: Sendable, Equatable, Hashable {

        /// Fire `DisasterStore.intent(.triggerEarthquake(…))` with
        /// the packaged parameters.
        case earthquake(intensity: Float, durationSeconds: Float)

        /// Fire `DisasterStore.intent(.triggerFlood(…))` with the
        /// packaged parameters. `startY` is filled in by the bridge
        /// from the current scene (typically `playerY`), since the
        /// data layer doesn't know about player position.
        case flood(targetWaterY: Float, riseSeconds: Float)
    }

    public let fromQuestId: String
    public let kind: Kind

    public init(fromQuestId: String, kind: Kind) {
        self.fromQuestId = fromQuestId
        self.kind = kind
    }
}

// MARK: - Map

/// Declarative routing tables for story progression.
///
/// Every entry in `builtIn` is pinned by a unit test to an existing
/// `QuestCatalog` id. Adding a new quest takes one change to the
/// catalog plus one line here; no RootView edits.
public enum StoryProgressionMap {

    // MARK: Dialogue → objective

    /// Dialogue finishes advance specific objectives. Phase 1–3 relied
    /// on a single hard-coded edge in `RootView.bootstrap()`; this
    /// table formalises that edge and documents the six chapter-intro
    /// dialogues the current build ships.
    ///
    /// The table intentionally includes Phase 9 Part B's new
    /// `quest1.3` / `quest1.4` edges alongside the legacy ones so
    /// future chapters have a single place to declare transitions.
    public static let dialogueCompletions: [StoryDialogueCompletion] = [
        // Chapter 1 intro finishes → the q.lab.intro objective flips.
        // This replaces the ad-hoc `auto-start q.lab.intro` RootView
        // code with a proper objective advancement: the intro quest
        // is started first (see `StoryProgressionBridge.bootstrap`),
        // and its sole objective completes here.
        StoryDialogueCompletion(
            dialogueSequenceId: "quest1.1",
            questId: "q.lab.intro",
            objectiveId: "q.lab.intro.intro_done"
        ),
        // Laboratory intro → Dr. Kaede quest advances.
        StoryDialogueCompletion(
            dialogueSequenceId: "quest1.2",
            questId: "q.lab.drkaede",
            objectiveId: "q.lab.drkaede.talk"
        ),
        // Dr. Kaede debrief → anomaly quest progresses to "talk" step.
        StoryDialogueCompletion(
            dialogueSequenceId: "quest2.1",
            questId: "q.lab.anomaly",
            objectiveId: "q.lab.anomaly.talk"
        ),
        // Field-phase intro → enter_field objective flips. The
        // collect_samples objective is driven by `InventoryStore`.
        StoryDialogueCompletion(
            dialogueSequenceId: "quest3.1",
            questId: "q.field.phase",
            objectiveId: "q.field.phase.enter_field"
        ),
        // Chapter 3 return dialogue → lab return quest.
        StoryDialogueCompletion(
            dialogueSequenceId: "quest3.4",
            questId: "q.lab.return",
            objectiveId: "q.lab.return.enter_lab"
        ),
        // Chapter 4 Kaede dialogue.
        StoryDialogueCompletion(
            dialogueSequenceId: "quest4.1",
            questId: "q.chapter4.kaede",
            objectiveId: "q.chapter4.kaede.talk"
        ),
        // Chapter 4 field / sample / return dialogues.
        StoryDialogueCompletion(
            dialogueSequenceId: "quest4.2",
            questId: "q.chapter4.field",
            objectiveId: "q.chapter4.field.enter_field"
        ),
        StoryDialogueCompletion(
            dialogueSequenceId: "quest4.3",
            questId: "q.chapter4.sample",
            objectiveId: "q.chapter4.sample.collect"
        ),
        StoryDialogueCompletion(
            dialogueSequenceId: "quest4.4",
            questId: "q.chapter4.return",
            objectiveId: "q.chapter4.return.enter_lab"
        ),
        // Chapter 5 / 6 dialogue progressions.
        StoryDialogueCompletion(
            dialogueSequenceId: "quest5.1",
            questId: "q.chapter5.kaede",
            objectiveId: "q.chapter5.kaede.talk"
        ),
        StoryDialogueCompletion(
            dialogueSequenceId: "quest5.2",
            questId: "q.chapter5.return",
            objectiveId: "q.chapter5.return.enter_lab"
        ),
        StoryDialogueCompletion(
            dialogueSequenceId: "quest6.1",
            questId: "q.chapter6.kaede",
            objectiveId: "q.chapter6.kaede.talk"
        )
    ]

    // MARK: Quest → successor quest

    /// When a quest finishes, automatically start the next one.
    /// Mirrors the legacy `QuestManager.HandleQuestCompletion` switch
    /// but lifts the table out of code.
    public static let questSuccessors: [StoryQuestSuccessor] = [
        StoryQuestSuccessor(fromQuestId: "q.lab.intro",      toQuestId: "q.lab.drkaede"),
        StoryQuestSuccessor(fromQuestId: "q.lab.drkaede",    toQuestId: "q.lab.anomaly"),
        StoryQuestSuccessor(fromQuestId: "q.lab.anomaly",    toQuestId: "q.field.phase"),
        StoryQuestSuccessor(fromQuestId: "q.field.phase",    toQuestId: "q.lab.return"),
        StoryQuestSuccessor(fromQuestId: "q.lab.return",     toQuestId: "q.chapter4.kaede"),
        StoryQuestSuccessor(fromQuestId: "q.chapter4.kaede", toQuestId: "q.chapter4.field"),
        StoryQuestSuccessor(fromQuestId: "q.chapter4.field", toQuestId: "q.chapter4.sample"),
        StoryQuestSuccessor(fromQuestId: "q.chapter4.sample", toQuestId: "q.chapter4.return"),
        StoryQuestSuccessor(fromQuestId: "q.chapter4.return", toQuestId: "q.chapter5.kaede"),
        StoryQuestSuccessor(fromQuestId: "q.chapter5.kaede", toQuestId: "q.chapter5.field"),
        StoryQuestSuccessor(fromQuestId: "q.chapter5.field", toQuestId: "q.chapter5.return"),
        StoryQuestSuccessor(fromQuestId: "q.chapter5.return", toQuestId: "q.chapter6.kaede")
    ]

    // MARK: Quest → disaster trigger

    /// Phase 9 Part B: completing specific quests fires a disaster
    /// event so the player feels the consequences of their survey.
    /// Parameters are intentionally small (3 s earthquake, 4 s flood
    /// rise) so the immediate on-screen effect is obvious while
    /// keeping audio loops short — real disaster SFX can be swapped
    /// in without retuning these constants.
    public static let questDisasters: [StoryQuestDisasterTrigger] = [
        // Chapter-1 青葉山 sampling quest triggers a modest earthquake.
        StoryQuestDisasterTrigger(
            fromQuestId: "q.chapter4.field",
            kind: .earthquake(intensity: 0.6, durationSeconds: 3.0)
        ),
        // Chapter-1 川内 sampling quest triggers a flood (typical
        // scenario in 広瀬川 flood-plain playtest discussions).
        StoryQuestDisasterTrigger(
            fromQuestId: "q.chapter4.sample",
            kind: .flood(targetWaterY: 2.0, riseSeconds: 4.0)
        )
    ]

    // MARK: - Lookups

    /// Look up the objective to complete for a finished dialogue.
    /// Returns `nil` if the dialogue id isn't in the table (the
    /// expected state for ordinary NPC chatter).
    public static func completion(
        forDialogueSequenceId id: String
    ) -> StoryDialogueCompletion? {
        dialogueCompletions.first { $0.dialogueSequenceId == id }
    }

    /// Look up the next quest id to start after `questId` completes.
    public static func successor(of questId: String) -> String? {
        questSuccessors.first { $0.fromQuestId == questId }?.toQuestId
    }

    /// Look up the disaster to fire when `questId` completes.
    public static func disaster(
        after questId: String
    ) -> StoryQuestDisasterTrigger.Kind? {
        questDisasters.first { $0.fromQuestId == questId }?.kind
    }
}
