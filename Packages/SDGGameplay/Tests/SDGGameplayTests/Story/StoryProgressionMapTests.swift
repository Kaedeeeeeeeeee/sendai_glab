// StoryProgressionMapTests.swift
// SDGGameplayTests · Story
//
// Structural invariants for the built-in quest / dialogue map. Not
// behavioural — those live in `StoryProgressionBridgeTests`. The
// purpose of this file is to catch map edits that would silently point
// at a typo'd quest or objective id.

import XCTest
@testable import SDGGameplay

final class StoryProgressionMapTests: XCTestCase {

    // MARK: - Built-in coverage

    func testBuiltInIsNonEmpty() {
        XCTAssertFalse(
            StoryProgressionMap.builtIn.dialogueToObjective.isEmpty,
            "dialogueToObjective map must bind at least one sequence"
        )
        XCTAssertFalse(
            StoryProgressionMap.builtIn.questChain.isEmpty,
            "questChain map must describe at least one chain"
        )
    }

    // MARK: - Referential integrity

    /// Every quest id referenced by either map must exist in the
    /// catalog. Typos silently skip at runtime (map returns nil) which
    /// is exactly the kind of narrative-breaking bug this test prevents.
    func testAllReferencedQuestIdsExistInCatalog() {
        let catalogIds = Set(QuestCatalog.all.map(\.id))

        for (seq, binding) in StoryProgressionMap.builtIn.dialogueToObjective {
            XCTAssertTrue(
                catalogIds.contains(binding.questId),
                "dialogueToObjective[\(seq)].questId = \(binding.questId) does not exist in QuestCatalog"
            )
        }

        for (from, to) in StoryProgressionMap.builtIn.questChain {
            XCTAssertTrue(
                catalogIds.contains(from),
                "questChain source \(from) does not exist in QuestCatalog"
            )
            XCTAssertTrue(
                catalogIds.contains(to),
                "questChain[\(from)] = \(to) does not exist in QuestCatalog"
            )
        }
    }

    /// Each binding's objective id must exist inside its referenced
    /// quest. Catches the "right quest, wrong objective name" slip.
    func testAllReferencedObjectiveIdsExistWithinTheirQuest() {
        let catalog = Dictionary(uniqueKeysWithValues: QuestCatalog.all.map { ($0.id, $0) })

        for (seq, binding) in StoryProgressionMap.builtIn.dialogueToObjective {
            guard let quest = catalog[binding.questId] else { continue }
            let objectiveIds = Set(quest.objectives.map(\.id))
            XCTAssertTrue(
                objectiveIds.contains(binding.objectiveId),
                "dialogueToObjective[\(seq)] points at objective \(binding.objectiveId) which is not in quest \(binding.questId)"
            )
        }
    }

    // MARK: - Chain shape

    /// The chain must be acyclic and terminate. If a designer
    /// accidentally writes `"q.a": "q.b", "q.b": "q.a"`, the test will
    /// catch it — otherwise a player completing q.a would spin the
    /// game into an infinite auto-start loop.
    func testQuestChainIsAcyclic() {
        let chain = StoryProgressionMap.builtIn.questChain

        for start in chain.keys {
            var seen: Set<String> = [start]
            var cursor: String? = chain[start]
            while let next = cursor {
                if !seen.insert(next).inserted {
                    XCTFail("questChain cycle detected starting at \(start), looping through \(next)")
                    return
                }
                cursor = chain[next]
            }
        }
    }

    /// The chain should have exactly one terminal quest (no successor).
    /// A second terminal would mean two parallel endings, which the
    /// Phase 3 linear arc shouldn't have.
    func testQuestChainHasExactlyOneTerminalQuest() {
        let chain = StoryProgressionMap.builtIn.questChain
        let successors = Set(chain.values)
        let allReachable = successors.union(chain.keys)
        let terminals = allReachable.subtracting(chain.keys)
        XCTAssertEqual(
            terminals.count,
            1,
            "Expected exactly one terminal quest in chain, found: \(terminals)"
        )
    }

    // MARK: - Custom constructor

    func testCustomMapIsUsedVerbatim() {
        let map = StoryProgressionMap(
            dialogueToObjective: [
                "seq.x": DialogueObjectiveBinding(
                    questId: "q.test",
                    objectiveId: "q.test.step"
                )
            ],
            questChain: ["q.a": "q.b"]
        )
        XCTAssertEqual(map.dialogueToObjective["seq.x"]?.questId, "q.test")
        XCTAssertEqual(map.questChain["q.a"], "q.b")
    }
}
