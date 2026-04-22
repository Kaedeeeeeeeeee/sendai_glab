// StoryProgressionBridgeTests.swift
// SDGGameplayTests · Story
//
// Behavioural tests for the DialogueFinished / QuestCompleted event →
// QuestStore.intent pipeline. Uses a minimal `StoryProgressionMap`
// rather than the built-in one so the assertions stay stable even when
// the narrative map is re-tuned by designers.
//
// Pattern note: mirrors `QuestStoreTests` — same `Recorder` helper,
// same `drain()` yield trick, so the file reads the same way any
// future reviewer already knows from Quest/.

import XCTest
import SDGCore
@testable import SDGGameplay

@MainActor
final class StoryProgressionBridgeTests: XCTestCase {

    // MARK: - Helpers

    /// Event recorder — listens on a bus, appends events to an array
    /// tests can assert on. Duplicated from QuestStoreTests rather
    /// than extracted to shared test-support because the shape is
    /// trivial and pulling a dependency in for 10 lines would itself
    /// be worse.
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

    /// Let the bus drain its pending dispatches. Three yields: two for
    /// the original event (publish → dispatch → MainActor hop into
    /// recorder), plus a margin so the bridge-triggered intent has
    /// time to fire its own follow-on events.
    private func drain() async {
        for _ in 0..<4 { await Task.yield() }
    }

    /// Minimal map: one dialogue binding and one chain link. Keeps the
    /// tests short and obviously-scoped; the full 13-quest integrity
    /// checks live in `StoryProgressionMapTests`.
    private var testMap: StoryProgressionMap {
        StoryProgressionMap(
            dialogueToObjective: [
                "test.dialogue.intro": DialogueObjectiveBinding(
                    questId: "q.lab.intro",
                    objectiveId: "q.lab.intro.intro_done"
                )
            ],
            questChain: [
                "q.lab.intro": "q.lab.drkaede"
            ]
        )
    }

    // MARK: - Lifecycle

    func testStartInstallsTwoSubscriptions() async {
        let bus = EventBus()
        let store = QuestStore(eventBus: bus, persistence: .inMemory)
        let bridge = StoryProgressionBridge(
            eventBus: bus,
            questStore: store,
            map: testMap
        )
        XCTAssertEqual(bridge.subscriptionCount, 0, "pre-start should be 0")
        await bridge.start()
        XCTAssertEqual(bridge.subscriptionCount, 2, "start should install dialogue + quest handlers")
    }

    func testStopDrainsSubscriptions() async {
        let bus = EventBus()
        let store = QuestStore(eventBus: bus, persistence: .inMemory)
        let bridge = StoryProgressionBridge(
            eventBus: bus,
            questStore: store,
            map: testMap
        )
        await bridge.start()
        await bridge.stop()
        XCTAssertEqual(bridge.subscriptionCount, 0)

        // Also confirm the bus forgot the handlers, not just the bridge.
        let dialogueSubs = await bus.subscriberCount(for: DialogueFinished.self)
        let questSubs = await bus.subscriberCount(for: QuestCompleted.self)
        XCTAssertEqual(dialogueSubs, 0)
        XCTAssertEqual(questSubs, 0)
    }

    // MARK: - Dialogue → objective

    func testDialogueFinishedCompletesBoundObjective() async throws {
        let bus = EventBus()
        let store = QuestStore(eventBus: bus, persistence: .inMemory)
        await store.start()

        let bridge = StoryProgressionBridge(
            eventBus: bus,
            questStore: store,
            map: testMap
        )
        await bridge.start()

        // Quest must be .inProgress before its objective can be
        // completed — that's how QuestStore is designed. Mimics the
        // real flow: RootView starts q.lab.intro on the intro dialogue
        // (legacy wiring) OR the chain unlocks it upstream.
        await store.intent(.start(questId: "q.lab.intro"))
        await drain()

        await bus.publish(DialogueFinished(
            sequenceId: "test.dialogue.intro",
            skipped: false
        ))
        await drain()

        XCTAssertTrue(
            store.isObjectiveCompleted("q.lab.intro.intro_done"),
            "Dialogue finish should have auto-completed the bound objective"
        )
    }

    func testSkippedDialogueStillCompletesObjective() async throws {
        // Skipping a cutscene should not leave the player stuck —
        // QuestStore treats skip as "cutscene over", same as natural
        // end. The bridge ignores the `skipped` flag.
        let bus = EventBus()
        let store = QuestStore(eventBus: bus, persistence: .inMemory)
        await store.start()
        let bridge = StoryProgressionBridge(eventBus: bus, questStore: store, map: testMap)
        await bridge.start()

        await store.intent(.start(questId: "q.lab.intro"))
        await drain()

        await bus.publish(DialogueFinished(
            sequenceId: "test.dialogue.intro",
            skipped: true
        ))
        await drain()

        XCTAssertTrue(store.isObjectiveCompleted("q.lab.intro.intro_done"))
    }

    func testUnboundDialogueDoesNothing() async throws {
        let bus = EventBus()
        let store = QuestStore(eventBus: bus, persistence: .inMemory)
        await store.start()
        let bridge = StoryProgressionBridge(eventBus: bus, questStore: store, map: testMap)
        await bridge.start()

        await store.intent(.start(questId: "q.lab.intro"))
        await drain()

        // A dialogue that the map doesn't mention — e.g. mid-scene
        // NPC banter in a later chapter. Must not accidentally tick
        // an unrelated objective.
        await bus.publish(DialogueFinished(
            sequenceId: "not.in.map",
            skipped: false
        ))
        await drain()

        XCTAssertFalse(
            store.isObjectiveCompleted("q.lab.intro.intro_done"),
            "Unbound dialogue must not affect quest state"
        )
    }

    // MARK: - Quest → next quest

    func testQuestCompletedAutoStartsSuccessor() async throws {
        let bus = EventBus()
        let store = QuestStore(eventBus: bus, persistence: .inMemory)
        await store.start()
        let bridge = StoryProgressionBridge(eventBus: bus, questStore: store, map: testMap)
        await bridge.start()

        // Record QuestStarted so we can prove the successor started.
        let (startedRecorder, startedToken) = await record(QuestStarted.self, on: bus)
        defer { Task { await bus.cancel(startedToken) } }

        // Full flow: start q.lab.intro → complete its objective →
        // QuestCompleted fires → bridge auto-starts q.lab.drkaede.
        await store.intent(.start(questId: "q.lab.intro"))
        await drain()
        await store.intent(.completeObjective(
            questId: "q.lab.intro",
            objectiveId: "q.lab.intro.intro_done"
        ))
        await drain()

        let startedIds = startedRecorder.events.map(\.questId)
        XCTAssertTrue(
            startedIds.contains("q.lab.drkaede"),
            "Expected q.lab.drkaede to auto-start after q.lab.intro completed; started=\(startedIds)"
        )
        XCTAssertEqual(
            store.quest(withId: "q.lab.drkaede")?.status,
            .inProgress
        )
    }

    func testTerminalQuestCompletionHasNoSuccessor() async throws {
        // A quest whose id is NOT a key in questChain is the end of
        // the narrative. Its completion must not accidentally start
        // something random.
        let map = StoryProgressionMap(
            dialogueToObjective: [:],
            questChain: [:] // nothing chained
        )
        let bus = EventBus()
        let store = QuestStore(eventBus: bus, persistence: .inMemory)
        await store.start()
        let bridge = StoryProgressionBridge(eventBus: bus, questStore: store, map: map)
        await bridge.start()

        let (startedRecorder, startedToken) = await record(QuestStarted.self, on: bus)
        defer { Task { await bus.cancel(startedToken) } }

        await store.intent(.start(questId: "q.lab.intro"))
        await drain()
        await store.intent(.completeObjective(
            questId: "q.lab.intro",
            objectiveId: "q.lab.intro.intro_done"
        ))
        await drain()

        // Only q.lab.intro should have fired QuestStarted; no follow-on.
        XCTAssertEqual(startedRecorder.events.map(\.questId), ["q.lab.intro"])
    }

    // MARK: - End-to-end cascade

    func testDialogueDrivesFullCascade() async throws {
        // The happy path: a player watches a dialogue, the objective
        // auto-completes, the quest auto-completes, the next quest
        // auto-starts. This is the Phase 3 feature in one test.
        let bus = EventBus()
        let store = QuestStore(eventBus: bus, persistence: .inMemory)
        await store.start()
        let bridge = StoryProgressionBridge(eventBus: bus, questStore: store, map: testMap)
        await bridge.start()

        // No explicit start — use the legacy RootView path where the
        // very first dialogue also triggers `.start`. For this test
        // we front-load it to avoid coupling to that external wiring.
        await store.intent(.start(questId: "q.lab.intro"))
        await drain()

        await bus.publish(DialogueFinished(
            sequenceId: "test.dialogue.intro",
            skipped: false
        ))
        await drain()

        XCTAssertEqual(
            store.quest(withId: "q.lab.intro")?.status,
            .completed,
            "Expected q.lab.intro to be completed once its only objective was ticked"
        )
        XCTAssertEqual(
            store.quest(withId: "q.lab.drkaede")?.status,
            .inProgress,
            "Expected successor q.lab.drkaede to auto-start"
        )
    }
}
