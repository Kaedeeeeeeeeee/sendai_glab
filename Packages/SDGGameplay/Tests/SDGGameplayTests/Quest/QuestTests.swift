// QuestTests.swift
// SDGGameplayTests · Quest
//
// Pins the data-shape contract for `Quest`, `QuestObjective`, and
// `QuestReward`. These types cross the EventBus and go to disk, so
// even a seemingly-cosmetic change (renaming a case, reordering
// fields, adding a required property) can break on-device saves and
// analytics. Tests fail early if that happens.

import XCTest
@testable import SDGGameplay

final class QuestTests: XCTestCase {

    // MARK: - Quest

    func testQuestCodableRoundTrip() throws {
        let original = Quest(
            id: "q.test.example",
            titleKey: "quest.test.example.title",
            descriptionKey: "quest.test.example.desc",
            objectives: [
                QuestObjective(id: "q.test.example.a", titleKey: "obj.a", completed: false),
                QuestObjective(id: "q.test.example.b", titleKey: "obj.b", completed: true)
            ],
            status: .inProgress,
            rewards: [
                .unlockTool(toolId: "hammer"),
                .markStoryFlag(key: "saw.intro")
            ]
        )
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(Quest.self, from: data)
        XCTAssertEqual(original, decoded)
    }

    func testAreAllObjectivesCompletedRequiresNonEmpty() {
        let q = Quest(
            id: "q.empty",
            titleKey: "t",
            descriptionKey: "d",
            objectives: []
        )
        // Legacy Unity behaviour: empty objective list is NOT "done".
        XCTAssertFalse(q.areAllObjectivesCompleted)
    }

    func testAreAllObjectivesCompletedWhenAllTrue() {
        let q = Quest(
            id: "q.all",
            titleKey: "t",
            descriptionKey: "d",
            objectives: [
                QuestObjective(id: "a", titleKey: "a", completed: true),
                QuestObjective(id: "b", titleKey: "b", completed: true)
            ]
        )
        XCTAssertTrue(q.areAllObjectivesCompleted)
    }

    func testAreAllObjectivesCompletedWhenOnePartial() {
        let q = Quest(
            id: "q.part",
            titleKey: "t",
            descriptionKey: "d",
            objectives: [
                QuestObjective(id: "a", titleKey: "a", completed: true),
                QuestObjective(id: "b", titleKey: "b", completed: false)
            ]
        )
        XCTAssertFalse(q.areAllObjectivesCompleted)
    }

    // MARK: - QuestStatus

    func testQuestStatusRawValuesAreStable() {
        // On-disk stability: bumping these without a migration is a bug.
        XCTAssertEqual(QuestStatus.notStarted.rawValue, "notStarted")
        XCTAssertEqual(QuestStatus.inProgress.rawValue, "inProgress")
        XCTAssertEqual(QuestStatus.completed.rawValue, "completed")
        XCTAssertEqual(QuestStatus.rewardClaimed.rawValue, "rewardClaimed")
    }

    // MARK: - QuestReward

    func testQuestRewardCodableForUnlockTool() throws {
        let reward: QuestReward = .unlockTool(toolId: "drone")
        let data = try JSONEncoder().encode(reward)
        let decoded = try JSONDecoder().decode(QuestReward.self, from: data)
        XCTAssertEqual(reward, decoded)
    }

    func testQuestRewardCodableForStoryFlag() throws {
        let reward: QuestReward = .markStoryFlag(key: "chapter4.start")
        let data = try JSONEncoder().encode(reward)
        let decoded = try JSONDecoder().decode(QuestReward.self, from: data)
        XCTAssertEqual(reward, decoded)
    }

    // MARK: - QuestObjective default init

    func testObjectiveDefaultsToIncomplete() {
        let obj = QuestObjective(id: "x", titleKey: "y")
        XCTAssertFalse(obj.completed)
    }
}
