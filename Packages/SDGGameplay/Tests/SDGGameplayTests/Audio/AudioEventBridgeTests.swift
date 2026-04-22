// AudioEventBridgeTests.swift
// SDGGameplayTests · Audio
//
// Verifies `AudioEventBridge` installs the right subscriptions on
// `start()` and unsubscribes them on `stop()`. We do *not* play real
// audio; instead we subclass `AudioService` with a recording stub so
// we can assert which cues the bridge triggered.
//
// The stub lives inside the test file (not in production) because it
// is a test fixture — AGENTS.md Rule 4 forbids `*Stub` / `*Mock`
// production files, but inline test fixtures are fine.

import XCTest
import Foundation
import SDGCore
import SDGPlatform
@testable import SDGGameplay

@MainActor
final class AudioEventBridgeTests: XCTestCase {

    // MARK: - Test stub

    /// An `AudioService` subclass that records which effects were
    /// asked to play. It still ignores resource lookup failures (the
    /// base class returns `nil`) and never touches audio hardware.
    final class RecordingAudioService: AudioService {
        var playedEffects: [AudioEffect] = []

        @discardableResult
        override func play(_ effect: AudioEffect, volume: Float = 1.0) -> UUID? {
            playedEffects.append(effect)
            return super.play(effect, volume: volume)
        }
    }

    /// Minimal drainer: EventBus.publish awaits every handler, but
    /// handlers that hop to MainActor via `MainActor.run` need one
    /// more turn of the scheduler to land the `await`.
    private func drainBus() async {
        await Task.yield()
        await Task.yield()
    }

    // MARK: - Fixture builder

    private func makeBridge() -> (EventBus, RecordingAudioService, AudioEventBridge) {
        let bus = EventBus()
        let audio = RecordingAudioService(bundle: Bundle(for: type(of: self)))
        let bridge = AudioEventBridge(eventBus: bus, audioService: audio)
        return (bus, audio, bridge)
    }

    // MARK: - Subscription lifecycle

    func testStartInstallsThreeSubscriptions() async {
        let (_, _, bridge) = makeBridge()
        XCTAssertEqual(bridge.subscriptionCount, 0)

        await bridge.start()

        XCTAssertEqual(bridge.subscriptionCount, 3)
    }

    func testStopDrainsAllSubscriptions() async {
        let (_, _, bridge) = makeBridge()
        await bridge.start()
        XCTAssertEqual(bridge.subscriptionCount, 3)

        await bridge.stop()

        XCTAssertEqual(bridge.subscriptionCount, 0)
    }

    func testStopIsIdempotent() async {
        let (_, _, bridge) = makeBridge()
        await bridge.start()
        await bridge.stop()
        await bridge.stop()     // Should not crash / wrap around.
        XCTAssertEqual(bridge.subscriptionCount, 0)
    }

    func testStartAfterStopReSubscribes() async {
        let (_, _, bridge) = makeBridge()
        await bridge.start()
        await bridge.stop()
        await bridge.start()
        XCTAssertEqual(bridge.subscriptionCount, 3)
    }

    // MARK: - Event → cue mapping

    func testDrillRequestedFiresDrillStart() async {
        let (bus, audio, bridge) = makeBridge()
        await bridge.start()

        await bus.publish(DrillRequested(
            origin: .zero,
            direction: SIMD3<Float>(0, -1, 0),
            maxDepth: 2.0,
            requestedAt: Date()
        ))
        await drainBus()

        XCTAssertEqual(audio.playedEffects, [.drillStart])
    }

    func testSampleCreatedFiresFeedbackSuccess() async {
        let (bus, audio, bridge) = makeBridge()
        await bridge.start()

        let sample = SampleItem(
            drillLocation: .zero,
            drillDepth: 1.0,
            layers: []
        )
        await bus.publish(SampleCreatedEvent(sample: sample))
        await drainBus()

        XCTAssertEqual(audio.playedEffects, [.feedbackSuccess])
    }

    func testDrillFailedFiresFeedbackFailure() async {
        let (bus, audio, bridge) = makeBridge()
        await bridge.start()

        await bus.publish(DrillFailed(origin: .zero, reason: "no_layers"))
        await drainBus()

        XCTAssertEqual(audio.playedEffects, [.feedbackFailure])
    }

    /// All three mappings should fire in order when their events are
    /// published in sequence. This guards against a future refactor
    /// that accidentally collapses two handlers into one.
    func testAllThreeMappingsFireIndependently() async {
        let (bus, audio, bridge) = makeBridge()
        await bridge.start()

        await bus.publish(DrillRequested(
            origin: .zero,
            direction: SIMD3<Float>(0, -1, 0),
            maxDepth: 2.0,
            requestedAt: Date()
        ))
        await drainBus()

        let sample = SampleItem(
            drillLocation: .zero,
            drillDepth: 1.0,
            layers: []
        )
        await bus.publish(SampleCreatedEvent(sample: sample))
        await drainBus()

        await bus.publish(DrillFailed(origin: .zero, reason: "no_layers"))
        await drainBus()

        XCTAssertEqual(audio.playedEffects, [
            .drillStart,
            .feedbackSuccess,
            .feedbackFailure
        ])
    }

    /// After `stop()`, subsequent events should not trigger plays.
    func testEventsAfterStopDoNotFireCues() async {
        let (bus, audio, bridge) = makeBridge()
        await bridge.start()
        await bridge.stop()

        await bus.publish(DrillRequested(
            origin: .zero,
            direction: SIMD3<Float>(0, -1, 0),
            maxDepth: 2.0,
            requestedAt: Date()
        ))
        await drainBus()

        XCTAssertTrue(audio.playedEffects.isEmpty)
    }
}
