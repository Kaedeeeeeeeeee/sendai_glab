// QuestStoreTests.swift
// SDGGameplayTests · Quest
//
// End-to-end behaviour of `QuestStore` around the intent → state →
// event loop. No SwiftUI, no RealityKit — the store is framework-free
// per ADR-0001 and these tests prove it.

import XCTest
import SDGCore
@testable import SDGGameplay

@MainActor
final class QuestStoreTests: XCTestCase {

    // MARK: - Helpers

    /// Build a sample item suitable for `SampleCreatedEvent`. Shared
    /// with `InventoryStoreTests` shape for mental consistency.
    private func makeSample(depth: Float = 2.0) -> SampleItem {
        SampleItem(
            id: UUID(),
            drillLocation: SIMD3<Float>(0, 0, 0),
            drillDepth: depth,
            layers: [
                SampleLayerRecord(
                    layerId: "layer_a",
                    nameKey: "layer.a",
                    colorRGB: SIMD3<Float>(0.5, 0.5, 0.5),
                    thickness: depth,
                    entryDepth: 0
                )
            ]
        )
    }

    /// An event-recorder: listens on a bus and writes events of a
    /// given type into an array the test can assert on.
    @MainActor
    final class Recorder<E: GameEvent>: @unchecked Sendable {
        var events: [E] = []
    }

    private func record<E: GameEvent>(
        _ type: E.Type,
        on bus: EventBus
    ) async -> (Recorder<E>, SubscriptionToken) {
        let recorder = Recorder<E>()
        let token = await bus.subscribe(type) { event in
            await MainActor.run { recorder.events.append(event) }
        }
        return (recorder, token)
    }

    /// Let the bus drain its pending dispatches.
    private func drain() async {
        // Two yields: one for the handler to enter, one for the
        // MainActor hop inside our recorder closure.
        await Task.yield()
        await Task.yield()
    }

    // MARK: - Initial state

    func testInitialStateIsCatalogBaseline() {
        let bus = EventBus()
        let store = QuestStore(eventBus: bus, persistence: .inMemory)
        XCTAssertEqual(store.quests.count, QuestCatalog.all.count)
        XCTAssertTrue(store.quests.allSatisfy { $0.status == .notStarted })
    }

    // MARK: - start()

    func testStartHydratesFromPersistence() async throws {
        let bus = EventBus()
        let persistence = QuestPersistence.inMemory
        try persistence.save(QuestPersistence.Snapshot(
            completedQuestIds: ["q.lab.intro"],
            completedObjectiveIds: ["q.lab.intro.intro_done"],
            grantedRewardKeys: []
        ))

        let store = QuestStore(eventBus: bus, persistence: persistence)
        await store.start()

        let intro = store.quest(withId: "q.lab.intro")
        XCTAssertEqual(intro?.status, .completed)
        XCTAssertTrue(store.isObjectiveCompleted("q.lab.intro.intro_done"))
    }

    func testStartWithoutSavedDataKeepsNotStarted() async {
        let bus = EventBus()
        let store = QuestStore(eventBus: bus, persistence: .inMemory)
        await store.start()
        XCTAssertTrue(store.quests.allSatisfy { $0.status == .notStarted })
    }

    func testStartIsIdempotentForSubscription() async {
        let bus = EventBus()
        let store = QuestStore(eventBus: bus, persistence: .inMemory)
        await store.start()
        await store.start()

        let count = await bus.subscriberCount(for: SampleCreatedEvent.self)
        XCTAssertEqual(count, 1, "second start() should not add a second subscription")
    }

    func testStopCancelsSubscription() async {
        let bus = EventBus()
        let store = QuestStore(eventBus: bus, persistence: .inMemory)
        await store.start()
        await store.stop()

        let count = await bus.subscriberCount(for: SampleCreatedEvent.self)
        XCTAssertEqual(count, 0)
    }

    func testStopIsIdempotent() async {
        let bus = EventBus()
        let store = QuestStore(eventBus: bus, persistence: .inMemory)
        await store.start()
        await store.stop()
        await store.stop()
        // No assertion beyond "does not crash".
    }

    // MARK: - Intent: .start

    func testStartIntentTransitionsNotStartedToInProgress() async {
        let bus = EventBus()
        let (recorder, _) = await record(QuestStarted.self, on: bus)
        let store = QuestStore(eventBus: bus, persistence: .inMemory)
        await store.start()

        await store.intent(.start(questId: "q.lab.intro"))
        await drain()

        XCTAssertEqual(store.quest(withId: "q.lab.intro")?.status, .inProgress)
        XCTAssertEqual(recorder.events, [QuestStarted(questId: "q.lab.intro")])
    }

    func testStartIntentOnAlreadyInProgressIsNoOp() async {
        let bus = EventBus()
        let (recorder, _) = await record(QuestStarted.self, on: bus)
        let store = QuestStore(eventBus: bus, persistence: .inMemory)
        await store.start()

        await store.intent(.start(questId: "q.lab.intro"))
        await store.intent(.start(questId: "q.lab.intro"))
        await drain()

        XCTAssertEqual(recorder.events.count, 1, "no duplicate publish")
    }

    func testStartIntentOnUnknownIdIsNoOp() async {
        let bus = EventBus()
        let (recorder, _) = await record(QuestStarted.self, on: bus)
        let store = QuestStore(eventBus: bus, persistence: .inMemory)
        await store.start()

        await store.intent(.start(questId: "q.does.not.exist"))
        await drain()

        XCTAssertTrue(recorder.events.isEmpty)
    }

    // MARK: - Intent: .completeObjective

    func testCompleteObjectiveFlipsFlagAndPublishesEvent() async {
        let bus = EventBus()
        let (recorder, _) = await record(ObjectiveCompleted.self, on: bus)
        let store = QuestStore(eventBus: bus, persistence: .inMemory)
        await store.start()
        await store.intent(.start(questId: "q.lab.intro"))

        await store.intent(.completeObjective(
            questId: "q.lab.intro",
            objectiveId: "q.lab.intro.intro_done"
        ))
        await drain()

        XCTAssertTrue(store.isObjectiveCompleted("q.lab.intro.intro_done"))
        XCTAssertEqual(
            recorder.events,
            [ObjectiveCompleted(
                questId: "q.lab.intro",
                objectiveId: "q.lab.intro.intro_done"
            )]
        )
    }

    func testCompletingLastObjectiveTransitionsToCompletedAndGrantsRewards() async {
        let bus = EventBus()
        let (completedRecorder, _) = await record(QuestCompleted.self, on: bus)
        let (rewardRecorder, _) = await record(RewardGranted.self, on: bus)
        let store = QuestStore(eventBus: bus, persistence: .inMemory)
        await store.start()
        await store.intent(.start(questId: "q.lab.intro"))

        await store.intent(.completeObjective(
            questId: "q.lab.intro",
            objectiveId: "q.lab.intro.intro_done"
        ))
        await drain()

        XCTAssertEqual(store.quest(withId: "q.lab.intro")?.status, .completed)
        XCTAssertEqual(completedRecorder.events, [QuestCompleted(questId: "q.lab.intro")])
        XCTAssertEqual(
            Set(rewardRecorder.events.map(\.reward)),
            Set<QuestReward>([
                .unlockTool(toolId: "hammer"),
                .unlockTool(toolId: "scene_switcher")
            ])
        )
    }

    func testCompletingObjectiveTwiceDoesNotDoubleFire() async {
        let bus = EventBus()
        let (recorder, _) = await record(ObjectiveCompleted.self, on: bus)
        let store = QuestStore(eventBus: bus, persistence: .inMemory)
        await store.start()
        await store.intent(.start(questId: "q.lab.intro"))

        await store.intent(.completeObjective(
            questId: "q.lab.intro",
            objectiveId: "q.lab.intro.intro_done"
        ))
        await store.intent(.completeObjective(
            questId: "q.lab.intro",
            objectiveId: "q.lab.intro.intro_done"
        ))
        await drain()

        XCTAssertEqual(recorder.events.count, 1, "legacy QuestManager guard preserved")
    }

    func testCompleteObjectiveAutoBumpsNotStartedToInProgress() async {
        // Narrative shortcuts: some cutscenes flip an objective before
        // the explicit .start intent arrives. Store must catch up.
        let bus = EventBus()
        let store = QuestStore(eventBus: bus, persistence: .inMemory)
        await store.start()

        await store.intent(.completeObjective(
            questId: "q.lab.drkaede",
            objectiveId: "q.lab.drkaede.talk"
        ))
        // Single-objective quest → auto-completion kicks in.
        XCTAssertEqual(store.quest(withId: "q.lab.drkaede")?.status, .completed)
    }

    // MARK: - Intent: .markComplete

    func testMarkCompleteFillsObjectivesAndFires() async {
        let bus = EventBus()
        let (completedRecorder, _) = await record(QuestCompleted.self, on: bus)
        let store = QuestStore(eventBus: bus, persistence: .inMemory)
        await store.start()

        await store.intent(.markComplete(questId: "q.field.phase"))
        await drain()

        let q = store.quest(withId: "q.field.phase")
        XCTAssertEqual(q?.status, .completed)
        XCTAssertTrue(q?.objectives.allSatisfy(\.completed) ?? false)
        XCTAssertEqual(completedRecorder.events, [QuestCompleted(questId: "q.field.phase")])
    }

    // MARK: - Intent: .reset

    func testResetRestoresCatalogBaseline() async {
        let bus = EventBus()
        let persistence = QuestPersistence.inMemory
        let store = QuestStore(eventBus: bus, persistence: persistence)
        await store.start()
        await store.intent(.start(questId: "q.lab.intro"))
        await store.intent(.completeObjective(
            questId: "q.lab.intro",
            objectiveId: "q.lab.intro.intro_done"
        ))

        await store.intent(.reset)

        XCTAssertTrue(store.quests.allSatisfy { $0.status == .notStarted })
        XCTAssertFalse(store.isObjectiveCompleted("q.lab.intro.intro_done"))
        let snapshot = try? persistence.load()
        XCTAssertEqual(snapshot, .empty)
    }

    // MARK: - SampleCreatedEvent subscription

    func testSampleCreatedAdvancesFieldPhaseAfterThreeSamples() async {
        let bus = EventBus()
        let (recorder, _) = await record(ObjectiveCompleted.self, on: bus)
        let store = QuestStore(eventBus: bus, persistence: .inMemory)
        await store.start()
        await store.intent(.start(questId: "q.field.phase"))
        await store.intent(.completeObjective(
            questId: "q.field.phase",
            objectiveId: "q.field.phase.enter_field"
        ))

        // 2 samples not enough.
        await bus.publish(SampleCreatedEvent(sample: makeSample()))
        await bus.publish(SampleCreatedEvent(sample: makeSample()))
        await drain()
        XCTAssertFalse(
            store.isObjectiveCompleted("q.field.phase.collect_samples"),
            "2 < target should not complete"
        )

        // 3rd triggers completion.
        await bus.publish(SampleCreatedEvent(sample: makeSample()))
        await drain()
        XCTAssertTrue(store.isObjectiveCompleted("q.field.phase.collect_samples"))

        let collectEvents = recorder.events.filter {
            $0.objectiveId == "q.field.phase.collect_samples"
        }
        XCTAssertEqual(collectEvents.count, 1, "single-shot completion event")
    }

    func testSampleCreatedBeforeEnterFieldIsIgnored() async {
        let bus = EventBus()
        let store = QuestStore(eventBus: bus, persistence: .inMemory)
        await store.start()
        await store.intent(.start(questId: "q.field.phase"))
        // enter_field intentionally NOT completed.

        for _ in 0..<5 {
            await bus.publish(SampleCreatedEvent(sample: makeSample()))
        }
        await drain()

        XCTAssertFalse(
            store.isObjectiveCompleted("q.field.phase.collect_samples"),
            "legacy HandleFieldPhaseSamplingProgress gate preserved"
        )
    }

    func testSampleCreatedIgnoredWhenQuestNotInProgress() async {
        let bus = EventBus()
        let store = QuestStore(eventBus: bus, persistence: .inMemory)
        await store.start()
        // Don't start q.field.phase.

        for _ in 0..<5 {
            await bus.publish(SampleCreatedEvent(sample: makeSample()))
        }
        await drain()

        XCTAssertEqual(
            store.quest(withId: "q.field.phase")?.status,
            .notStarted
        )
    }

    // MARK: - Persistence integration

    func testIntentsPersistAcrossRestart() async throws {
        let bus1 = EventBus()
        let persistence = QuestPersistence.inMemory
        let store1 = QuestStore(eventBus: bus1, persistence: persistence)
        await store1.start()
        await store1.intent(.start(questId: "q.lab.intro"))
        await store1.intent(.completeObjective(
            questId: "q.lab.intro",
            objectiveId: "q.lab.intro.intro_done"
        ))
        await store1.stop()

        // New bus and store instance, same persistence.
        let bus2 = EventBus()
        let store2 = QuestStore(eventBus: bus2, persistence: persistence)
        await store2.start()

        XCTAssertEqual(store2.quest(withId: "q.lab.intro")?.status, .completed)
        XCTAssertTrue(store2.isObjectiveCompleted("q.lab.intro.intro_done"))
    }

    func testRewardsGrantedOnlyOnce() async throws {
        let bus = EventBus()
        let persistence = QuestPersistence.inMemory
        let (recorder, _) = await record(RewardGranted.self, on: bus)
        let store = QuestStore(eventBus: bus, persistence: persistence)
        await store.start()
        await store.intent(.start(questId: "q.lab.intro"))
        await store.intent(.completeObjective(
            questId: "q.lab.intro",
            objectiveId: "q.lab.intro.intro_done"
        ))
        await drain()
        let firstCount = recorder.events.count
        XCTAssertEqual(firstCount, 2)

        // Force-complete again; persistence should have remembered the
        // grant and block a second publish.
        await store.intent(.markComplete(questId: "q.lab.intro"))
        await drain()
        XCTAssertEqual(
            recorder.events.count,
            firstCount,
            "RewardGranted must not fire twice for the same quest"
        )
    }
}
