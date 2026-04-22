// StoryProgressionMap.swift
// SDGGameplay · Story
//
// Static data driving the quest ↔ dialogue chain. Two maps:
//
//   1. `dialogueToObjective` — when a DialogueFinished event arrives
//      with a matching `sequenceId`, auto-complete the target quest
//      objective. This is how the player experiences "finish talking
//      to Kaede → quest tick turns green."
//
//   2. `questChain` — when a QuestCompleted event arrives for quest X,
//      auto-start quest Y. This is how the whole 13-quest arc cascades
//      without RootView or another UI layer knowing the ordering.
//
// ## Why a separate map (not fields on `Quest`)?
//
// `Quest.rewards` is reserved for *unlocks* (tool unlocks, story flags)
// per ADR-0001. Control flow — "which quest follows which" — is a
// narrative concern that should not live on the same struct as gameplay
// rewards. A middle-schooler's completion ordering is also the kind of
// thing a designer should be able to tune without touching `Quest` or
// `QuestCatalog`. Splitting lets `QuestCatalog` stay the mechanical
// definition and `StoryProgressionMap` be the narrative script.
//
// ## Coverage
//
// Not every quest has a dialogue-finish ending. Field-entry and
// sample-collection objectives (e.g. `q.field.phase.enter_field`,
// `q.chapter4.field.enter_field`) fire from scene / inventory systems
// outside this bridge — those are "go here" or "do this" objectives,
// not "talk this out." The map only lists the clean "dialogue closes
// this objective" bindings; anything not listed must be driven by
// another subsystem (TODO: a future `SceneProgressionBridge`).
//
// The `questChain` map IS complete end-to-end: it covers every "X
// completes → start Y" transition across all 13 quests. Quests whose
// objectives are not dialogue-driven will simply start but stay in
// progress until the relevant scene system flips their objective.

import Foundation

/// A binding "when dialogue X finishes, complete objective Y of quest Z".
///
/// Kept as a named struct rather than a tuple so call sites and tests
/// can reference `.questId` / `.objectiveId` by name instead of
/// positional `.0` / `.1` — a small clarity win when the map is edited
/// by hand during narrative tuning.
public struct DialogueObjectiveBinding: Sendable, Equatable {

    /// Quest whose objective should tick on dialogue finish.
    public let questId: String

    /// Objective within that quest to mark complete.
    public let objectiveId: String

    public init(questId: String, objectiveId: String) {
        self.questId = questId
        self.objectiveId = objectiveId
    }
}

/// The narrative wiring between dialogue playback and quest progress.
///
/// `StoryProgressionBridge` consumes one of these at start-up. Tests
/// construct alternate maps to exercise the bridge's behaviour without
/// binding to the full 13-quest arc.
public struct StoryProgressionMap: Sendable, Equatable {

    /// `sequenceId` → objective to complete when that dialogue finishes.
    public let dialogueToObjective: [String: DialogueObjectiveBinding]

    /// `questId` → the `questId` of the next quest to auto-start when
    /// the key quest completes. Quests not present terminate the chain
    /// (the final chapter's quest has no successor).
    public let questChain: [String: String]

    public init(
        dialogueToObjective: [String: DialogueObjectiveBinding],
        questChain: [String: String]
    ) {
        self.dialogueToObjective = dialogueToObjective
        self.questChain = questChain
    }

    // MARK: - Built-in

    /// The 13-quest arc shipped with SDG-Lab Phase 3. Drawn from the
    /// semantic mapping of `Resources/Story/quest*.json` to the
    /// `QuestCatalog.all` quest IDs.
    ///
    /// Design rule for this table:
    /// - Include a dialogue→objective row only when the *closing beat*
    ///   of the dialogue is unambiguously "this quest step is done"
    ///   (character exits, scene transitions, a decision is locked in).
    /// - Mid-conversation bridges and mechanical instructions
    ///   (e.g. `quest3.1` "pre-field briefing") are deliberately absent
    ///   — they are filler, and binding them would fire an objective
    ///   before the player actually performs the action.
    public static let builtIn = StoryProgressionMap(
        dialogueToObjective: [
            // Chapter 1 — intro (classroom → G-Lab awakening)
            "quest1.1": DialogueObjectiveBinding(
                questId: "q.lab.intro",
                objectiveId: "q.lab.intro.intro_done"
            ),
            // quest1.2 (awakening narrative bridge) intentionally unbound.

            // Chapter 2 — Kaede expo + mother's consent
            "quest2.1": DialogueObjectiveBinding(
                questId: "q.lab.drkaede",
                objectiveId: "q.lab.drkaede.talk"
            ),

            // Chapter 3 — field ops (phase 1)
            // quest3.1 / quest3.2 (pre-field briefing, field arrival) intentionally unbound.
            "quest3.3": DialogueObjectiveBinding(
                questId: "q.field.phase",
                objectiveId: "q.field.phase.collect_samples"
            ),
            "quest3.4": DialogueObjectiveBinding(
                questId: "q.lab.return",
                objectiveId: "q.lab.return.enter_lab"
            ),

            // Chapter 4 — deep probe
            "quest4.1": DialogueObjectiveBinding(
                questId: "q.chapter4.kaede",
                objectiveId: "q.chapter4.kaede.talk"
            ),
            // quest4.2 (field execution chatter) intentionally unbound.
            "quest4.3": DialogueObjectiveBinding(
                questId: "q.chapter4.sample",
                objectiveId: "q.chapter4.sample.collect"
            ),
            "quest4.4": DialogueObjectiveBinding(
                questId: "q.chapter4.return",
                objectiveId: "q.chapter4.return.enter_lab"
            ),

            // Chapter 5 — drone swarm
            "quest5.1": DialogueObjectiveBinding(
                questId: "q.chapter5.kaede",
                objectiveId: "q.chapter5.kaede.talk"
            ),
            "quest5.2": DialogueObjectiveBinding(
                questId: "q.chapter5.return",
                objectiveId: "q.chapter5.return.enter_lab"
            ),

            // Chapter 6 — report
            "quest6.1": DialogueObjectiveBinding(
                questId: "q.chapter6.kaede",
                objectiveId: "q.chapter6.kaede.talk"
            )
        ],
        questChain: [
            // Chapter 1 → Chapter 2
            "q.lab.intro":       "q.lab.drkaede",
            "q.lab.drkaede":     "q.lab.anomaly",
            "q.lab.anomaly":     "q.field.phase",

            // Chapter 3 field cycle
            "q.field.phase":     "q.lab.return",
            "q.lab.return":      "q.chapter4.kaede",

            // Chapter 4 field cycle
            "q.chapter4.kaede":  "q.chapter4.field",
            "q.chapter4.field":  "q.chapter4.sample",
            "q.chapter4.sample": "q.chapter4.return",
            "q.chapter4.return": "q.chapter5.kaede",

            // Chapter 5 drone cycle
            "q.chapter5.kaede":  "q.chapter5.field",
            "q.chapter5.field":  "q.chapter5.return",
            "q.chapter5.return": "q.chapter6.kaede"
            // q.chapter6.kaede is the terminal quest — no successor.
        ]
    )
}
