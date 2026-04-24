// StoryProgressionMapTests.swift
// Phase 9 Part B tests pinning the story → quest / disaster routing
// tables against `QuestCatalog`. Broken references would be silent
// footguns at runtime (a dialogue finishes → "complete objective X"
// lands on a Store that has no objective X → the bus handler quietly
// no-ops and the chapter never advances). These tests make the
// mapping explicit.

import XCTest
@testable import SDGGameplay

final class StoryProgressionMapTests: XCTestCase {

    // MARK: - Dialogue → objective referential integrity

    /// Every dialogue-completion edge must name a quest that exists
    /// in the catalog and an objective that exists on that quest.
    func testDialogueCompletionsReferenceValidObjectives() {
        for edge in StoryProgressionMap.dialogueCompletions {
            guard let quest = QuestCatalog.quest(byId: edge.questId) else {
                XCTFail("dialogue edge '\(edge.dialogueSequenceId)' references unknown quest '\(edge.questId)'")
                continue
            }
            let objectiveIds = quest.objectives.map(\.id)
            XCTAssertTrue(
                objectiveIds.contains(edge.objectiveId),
                "quest '\(quest.id)' has no objective '\(edge.objectiveId)' (edge from '\(edge.dialogueSequenceId)')"
            )
        }
    }

    /// Each dialogue sequence id appears at most once — two edges
    /// competing for the same dialogue would make the bridge's
    /// behaviour order-dependent.
    func testDialogueCompletionsHaveUniqueSequenceIds() {
        let ids = StoryProgressionMap.dialogueCompletions.map(\.dialogueSequenceId)
        XCTAssertEqual(Set(ids).count, ids.count)
    }

    // MARK: - Quest successors

    /// Every successor references an existing catalog quest on both
    /// sides. Prevents typo'd chains from silently dead-ending.
    func testQuestSuccessorsReferenceValidQuests() {
        for edge in StoryProgressionMap.questSuccessors {
            XCTAssertNotNil(
                QuestCatalog.quest(byId: edge.fromQuestId),
                "successor 'from' references unknown quest '\(edge.fromQuestId)'"
            )
            XCTAssertNotNil(
                QuestCatalog.quest(byId: edge.toQuestId),
                "successor 'to' references unknown quest '\(edge.toQuestId)'"
            )
        }
    }

    /// Each source quest appears at most once. The bridge treats the
    /// first match as authoritative, so duplicates would silently
    /// shadow each other.
    func testQuestSuccessorsHaveUniqueSources() {
        let sources = StoryProgressionMap.questSuccessors.map(\.fromQuestId)
        XCTAssertEqual(Set(sources).count, sources.count)
    }

    // MARK: - Disaster triggers

    /// Every disaster trigger references a catalog quest. Silent
    /// dead-ends here would mean the quest × disaster loop simply
    /// never fires without any runtime warning.
    func testQuestDisastersReferenceValidQuests() {
        for edge in StoryProgressionMap.questDisasters {
            XCTAssertNotNil(
                QuestCatalog.quest(byId: edge.fromQuestId),
                "disaster trigger references unknown quest '\(edge.fromQuestId)'"
            )
        }
    }

    /// There is at least one earthquake trigger and at least one
    /// flood trigger — if either disappears the Phase 9 Part B loop
    /// is only half-wired.
    func testQuestDisastersCoverBothKinds() {
        var sawEarthquake = false
        var sawFlood = false
        for edge in StoryProgressionMap.questDisasters {
            switch edge.kind {
            case .earthquake: sawEarthquake = true
            case .flood:      sawFlood = true
            }
        }
        XCTAssertTrue(sawEarthquake, "no earthquake trigger in StoryProgressionMap.questDisasters")
        XCTAssertTrue(sawFlood,      "no flood trigger in StoryProgressionMap.questDisasters")
    }

    // MARK: - Lookup helpers

    /// The `completion(forDialogueSequenceId:)` helper must return
    /// `nil` for unknown sequences rather than throwing / crashing —
    /// the bridge treats `nil` as "ignore this dialogue".
    func testCompletionLookupReturnsNilForUnknownDialogue() {
        XCTAssertNil(StoryProgressionMap.completion(forDialogueSequenceId: "not-a-real-id"))
    }

    /// And it must return the matching edge for a known sequence.
    func testCompletionLookupReturnsEdgeForKnownDialogue() {
        let edge = StoryProgressionMap.completion(forDialogueSequenceId: "quest1.1")
        XCTAssertNotNil(edge)
        XCTAssertEqual(edge?.questId, "q.lab.intro")
    }

    /// `successor(of:)` returns `nil` at the chain's tail — otherwise
    /// a final-quest completion would loop forever or dispatch to a
    /// ghost quest id.
    func testSuccessorLookupReturnsNilForTerminalQuest() {
        // Last entry in questSuccessors' "to" chain is the terminal.
        let terminal = StoryProgressionMap.questSuccessors.map(\.toQuestId)
        // The final successor in the chain (q.chapter6.kaede) should
        // have no successor of its own. If a successor is later added
        // for it, this test will guide the update.
        let terminalQuestId = "q.chapter6.kaede"
        XCTAssertTrue(
            terminal.contains(terminalQuestId),
            "expected chain to terminate at '\(terminalQuestId)'"
        )
        XCTAssertNil(StoryProgressionMap.successor(of: terminalQuestId))
    }

    // MARK: - Equatable / Hashable sanity

    /// Since the structs drive test fixtures elsewhere, a baseline
    /// identity check protects against an accidental Codable/custom
    /// equality regression.
    func testEdgeTypesEquatable() {
        let a = StoryDialogueCompletion(dialogueSequenceId: "q", questId: "x", objectiveId: "y")
        let b = StoryDialogueCompletion(dialogueSequenceId: "q", questId: "x", objectiveId: "y")
        XCTAssertEqual(a, b)

        let s1 = StoryQuestSuccessor(fromQuestId: "a", toQuestId: "b")
        let s2 = StoryQuestSuccessor(fromQuestId: "a", toQuestId: "b")
        XCTAssertEqual(s1, s2)

        let d1 = StoryQuestDisasterTrigger(
            fromQuestId: "x",
            kind: .earthquake(intensity: 0.5, durationSeconds: 2)
        )
        let d2 = StoryQuestDisasterTrigger(
            fromQuestId: "x",
            kind: .earthquake(intensity: 0.5, durationSeconds: 2)
        )
        XCTAssertEqual(d1, d2)
    }
}
