// QuestCatalogTests.swift
// SDGGameplayTests · Quest
//
// The catalog is the single source of truth for "every quest we ship"
// — these tests pin that contract so a silent deletion / rename in
// `QuestCatalog.all` surfaces in CI, not on launch.

import XCTest
@testable import SDGGameplay

final class QuestCatalogTests: XCTestCase {

    // MARK: - Completeness

    /// The 13 quest ids the Unity `QuestManager.RegisterBuiltInQuests()`
    /// registered, in narrative order. This test is the "no quest was
    /// dropped on the floor during porting" guard.
    private static let expectedIds: [String] = [
        "q.lab.intro",
        "q.lab.drkaede",
        "q.lab.anomaly",
        "q.field.phase",
        "q.lab.return",
        "q.chapter4.kaede",
        "q.chapter4.field",
        "q.chapter4.sample",
        "q.chapter4.return",
        "q.chapter5.kaede",
        "q.chapter5.field",
        "q.chapter5.return",
        "q.chapter6.kaede"
    ]

    func testCatalogHasThirteenQuests() {
        XCTAssertEqual(QuestCatalog.all.count, 13)
    }

    func testCatalogPreservesNarrativeOrder() {
        XCTAssertEqual(QuestCatalog.all.map(\.id), Self.expectedIds)
    }

    func testEveryExpectedQuestIsPresent() {
        for id in Self.expectedIds {
            XCTAssertNotNil(
                QuestCatalog.quest(byId: id),
                "missing expected quest: \(id)"
            )
        }
    }

    // MARK: - Structural invariants

    func testEveryQuestHasAtLeastOneObjective() {
        for q in QuestCatalog.all {
            XCTAssertFalse(
                q.objectives.isEmpty,
                "\(q.id) has no objectives; QuestCatalog should never ship an empty quest"
            )
        }
    }

    func testEveryQuestHasUniqueId() {
        let ids = QuestCatalog.all.map(\.id)
        XCTAssertEqual(Set(ids).count, ids.count, "duplicate quest id in catalog")
    }

    func testEveryObjectiveHasUniqueId() {
        let allObjectiveIds = QuestCatalog.all.flatMap { $0.objectives.map(\.id) }
        XCTAssertEqual(
            Set(allObjectiveIds).count,
            allObjectiveIds.count,
            "duplicate objective id across the catalog"
        )
    }

    func testEveryQuestStartsNotStarted() {
        for q in QuestCatalog.all {
            XCTAssertEqual(q.status, .notStarted, "\(q.id) baseline must be .notStarted")
        }
    }

    func testEveryObjectiveStartsIncomplete() {
        for q in QuestCatalog.all {
            for obj in q.objectives {
                XCTAssertFalse(
                    obj.completed,
                    "\(q.id)/\(obj.id) baseline must be incomplete"
                )
            }
        }
    }

    // MARK: - Localization keys

    func testTitleAndDescriptionKeysFollowConvention() {
        // `quest.*.title` and `quest.*.desc` is the legacy Unity
        // convention; downstream .xcstrings mass-imports assume it.
        for q in QuestCatalog.all {
            XCTAssertTrue(q.titleKey.hasSuffix(".title"), "\(q.id) title key: \(q.titleKey)")
            XCTAssertTrue(q.descriptionKey.hasSuffix(".desc"), "\(q.id) desc key: \(q.descriptionKey)")
            XCTAssertTrue(q.titleKey.hasPrefix("quest."), "\(q.id) title prefix")
            XCTAssertTrue(q.descriptionKey.hasPrefix("quest."), "\(q.id) desc prefix")
        }
    }

    // MARK: - Rewards (legacy parity)

    func testIntroQuestUnlocksHammerAndSceneSwitcher() throws {
        let quest = try XCTUnwrap(QuestCatalog.quest(byId: "q.lab.intro"))
        XCTAssertEqual(
            Set(quest.rewards),
            Set<QuestReward>([
                .unlockTool(toolId: "hammer"),
                .unlockTool(toolId: "scene_switcher")
            ])
        )
    }

    func testLabReturnUnlocksDrillTools() throws {
        let quest = try XCTUnwrap(QuestCatalog.quest(byId: "q.lab.return"))
        XCTAssertEqual(
            Set(quest.rewards),
            Set<QuestReward>([
                .unlockTool(toolId: "scene_switcher"),
                .unlockTool(toolId: "drill_simple"),
                .unlockTool(toolId: "drill_tower")
            ])
        )
    }

    func testChapter5KaedeUnlocksDrone() throws {
        let quest = try XCTUnwrap(QuestCatalog.quest(byId: "q.chapter5.kaede"))
        XCTAssertEqual(quest.rewards, [.unlockTool(toolId: "drone")])
    }

    func testFieldPhaseHasNoRewards() throws {
        let quest = try XCTUnwrap(QuestCatalog.quest(byId: "q.field.phase"))
        XCTAssertTrue(
            quest.rewards.isEmpty,
            "legacy GrantRewards only advances quests here — no tool unlock"
        )
    }

    // MARK: - Lookups

    func testQuestContainingObjectiveId() throws {
        let quest = QuestCatalog.questContaining(objectiveId: "q.field.phase.collect_samples")
        XCTAssertEqual(quest?.id, "q.field.phase")
    }

    func testQuestByIdReturnsNilForUnknown() {
        XCTAssertNil(QuestCatalog.quest(byId: "q.made.up"))
    }
}
