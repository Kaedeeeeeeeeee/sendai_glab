// DialogueStoreTests.swift
// SDGGameplayTests · Dialogue
//
// State-machine coverage for the dialogue playback store: .idle →
// .playing → .finished with both natural advance and `.skipAll`
// paths, plus event publication in each transition.

import XCTest
import SDGCore
@testable import SDGGameplay

@MainActor
final class DialogueStoreTests: XCTestCase {

    // MARK: - Fixtures

    private func makeSequence(
        id: String = "fixture",
        lineCount: Int = 3
    ) -> StorySequence {
        let lines = (0..<lineCount).map { i in
            DialogueLine(
                speaker: "s\(i)",
                text: "line \(i)",
                speakerKey: "k.s\(i)",
                textKey: "k.t\(i)"
            )
        }
        return StorySequence(
            id: id,
            scene: "scene",
            background: "bg",
            bgm: "bgm",
            dialogues: lines
        )
    }

    // Event recorder — same pattern as QuestStoreTests.
    @MainActor
    final class Recorder<E: GameEvent>: @unchecked Sendable {
        var events: [E] = []
    }

    private func record<E: GameEvent>(
        _ type: E.Type,
        on bus: EventBus
    ) async -> Recorder<E> {
        let recorder = Recorder<E>()
        _ = await bus.subscribe(type) { event in
            await MainActor.run { recorder.events.append(event) }
        }
        return recorder
    }

    private func drain() async {
        await Task.yield()
        await Task.yield()
    }

    // MARK: - Initial state

    func testInitialStateIsIdle() {
        let bus = EventBus()
        let store = DialogueStore(eventBus: bus)
        XCTAssertEqual(store.status, .idle)
        XCTAssertNil(store.currentLine)
        XCTAssertFalse(store.isOnLastLine)
    }

    // MARK: - Play

    func testPlayEntersPlayingAndPublishesPlayed() async {
        let bus = EventBus()
        let playedRecorder = await record(DialoguePlayed.self, on: bus)
        let store = DialogueStore(eventBus: bus)
        let seq = makeSequence(id: "s1", lineCount: 2)

        await store.intent(.play(sequence: seq))
        await drain()

        if case let .playing(s, idx) = store.status {
            XCTAssertEqual(s.id, "s1")
            XCTAssertEqual(idx, 0)
        } else {
            XCTFail("expected .playing, got \(store.status)")
        }
        XCTAssertEqual(playedRecorder.events, [DialoguePlayed(sequenceId: "s1")])
    }

    func testCurrentLineReflectsStatus() async {
        let bus = EventBus()
        let store = DialogueStore(eventBus: bus)
        let seq = makeSequence(id: "s1", lineCount: 3)

        await store.intent(.play(sequence: seq))
        XCTAssertEqual(store.currentLine?.text, "line 0")

        await store.intent(.advance)
        XCTAssertEqual(store.currentLine?.text, "line 1")
    }

    func testIsOnLastLineFlipsAtFinalIndex() async {
        let bus = EventBus()
        let store = DialogueStore(eventBus: bus)
        let seq = makeSequence(lineCount: 2)

        await store.intent(.play(sequence: seq))
        XCTAssertFalse(store.isOnLastLine)

        await store.intent(.advance)
        XCTAssertTrue(store.isOnLastLine)
    }

    // MARK: - Advance

    func testAdvanceAdvancesIndexAndPublishes() async {
        let bus = EventBus()
        let advancedRecorder = await record(DialogueAdvanced.self, on: bus)
        let store = DialogueStore(eventBus: bus)
        let seq = makeSequence(id: "s1", lineCount: 3)

        await store.intent(.play(sequence: seq))
        await store.intent(.advance)
        await drain()

        XCTAssertEqual(
            advancedRecorder.events,
            [DialogueAdvanced(sequenceId: "s1", lineIndex: 1)]
        )
    }

    func testAdvancePastLastLineFinishes() async {
        let bus = EventBus()
        let finishedRecorder = await record(DialogueFinished.self, on: bus)
        let store = DialogueStore(eventBus: bus)
        let seq = makeSequence(id: "s1", lineCount: 2)

        await store.intent(.play(sequence: seq))
        await store.intent(.advance)
        await store.intent(.advance)   // crosses the boundary
        await drain()

        if case let .finished(s, skipped) = store.status {
            XCTAssertEqual(s.id, "s1")
            XCTAssertFalse(skipped)
        } else {
            XCTFail("expected .finished, got \(store.status)")
        }
        XCTAssertEqual(
            finishedRecorder.events,
            [DialogueFinished(sequenceId: "s1", skipped: false)]
        )
    }

    func testAdvanceWhileIdleIsNoOp() async {
        let bus = EventBus()
        let advancedRecorder = await record(DialogueAdvanced.self, on: bus)
        let store = DialogueStore(eventBus: bus)

        await store.intent(.advance)
        await drain()

        XCTAssertEqual(store.status, .idle)
        XCTAssertTrue(advancedRecorder.events.isEmpty)
    }

    func testAdvanceAfterFinishIsNoOp() async {
        let bus = EventBus()
        let store = DialogueStore(eventBus: bus)
        let seq = makeSequence(lineCount: 1)

        await store.intent(.play(sequence: seq))
        await store.intent(.advance)   // finishes

        if case .finished = store.status {} else {
            return XCTFail("setup: expected .finished")
        }
        await store.intent(.advance)
        if case .finished = store.status {} else {
            XCTFail("advancing past finished should stay finished")
        }
    }

    // MARK: - Skip

    func testSkipAllWhilePlayingGoesToFinishedSkipped() async {
        let bus = EventBus()
        let finishedRecorder = await record(DialogueFinished.self, on: bus)
        let store = DialogueStore(eventBus: bus)
        let seq = makeSequence(id: "s1", lineCount: 10)

        await store.intent(.play(sequence: seq))
        await store.intent(.advance)
        await store.intent(.skipAll)
        await drain()

        if case let .finished(_, skipped) = store.status {
            XCTAssertTrue(skipped)
        } else {
            XCTFail("expected .finished, got \(store.status)")
        }
        XCTAssertEqual(
            finishedRecorder.events,
            [DialogueFinished(sequenceId: "s1", skipped: true)]
        )
    }

    func testSkipAllWhileIdleIsNoOp() async {
        let bus = EventBus()
        let store = DialogueStore(eventBus: bus)
        await store.intent(.skipAll)
        XCTAssertEqual(store.status, .idle)
    }

    // MARK: - Empty sequence

    func testPlayEmptySequenceFinishesImmediately() async {
        let bus = EventBus()
        let playedRecorder = await record(DialoguePlayed.self, on: bus)
        let finishedRecorder = await record(DialogueFinished.self, on: bus)
        let store = DialogueStore(eventBus: bus)
        let seq = StorySequence(id: "empty")

        await store.intent(.play(sequence: seq))
        await drain()

        if case let .finished(s, skipped) = store.status {
            XCTAssertEqual(s.id, "empty")
            XCTAssertFalse(skipped, "natural, not skipped")
        } else {
            XCTFail("expected .finished, got \(store.status)")
        }
        XCTAssertEqual(playedRecorder.events.count, 1)
        XCTAssertEqual(finishedRecorder.events.count, 1)
    }

    // MARK: - Replay the same sequence

    func testReplayingResetsIndex() async {
        let bus = EventBus()
        let store = DialogueStore(eventBus: bus)
        let seq = makeSequence(lineCount: 3)

        await store.intent(.play(sequence: seq))
        await store.intent(.advance)
        await store.intent(.advance)
        await store.intent(.play(sequence: seq))

        if case let .playing(_, idx) = store.status {
            XCTAssertEqual(idx, 0, "replay resets index")
        } else {
            XCTFail("expected .playing, got \(store.status)")
        }
    }

    // MARK: - Integration: real JSON via StoryLoader

    func testPlayingRealJSONDrivesStateToFinish() async throws {
        let bus = EventBus()
        let finishedRecorder = await record(DialogueFinished.self, on: bus)
        let store = DialogueStore(eventBus: bus)
        let seq = try StoryLoader.load(basename: "quest3.2", in: .module)

        await store.intent(.play(sequence: seq))
        // quest3.2 has 3 dialogues.
        for _ in 0..<seq.dialogues.count {
            await store.intent(.advance)
        }
        await drain()

        if case let .finished(_, skipped) = store.status {
            XCTAssertFalse(skipped)
        } else {
            XCTFail("expected .finished for quest3.2, got \(store.status)")
        }
        XCTAssertEqual(finishedRecorder.events.count, 1)
    }
}
