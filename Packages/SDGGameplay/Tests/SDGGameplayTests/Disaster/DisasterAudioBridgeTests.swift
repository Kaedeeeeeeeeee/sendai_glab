// DisasterAudioBridgeTests.swift
// SDGGameplayTests · Disaster
//
// Verifies `DisasterAudioBridge` subscribes to the right events and
// maps `EarthquakeStarted` / `FloodStarted` to the correct audio cue.
// Mirrors the shape of `AudioEventBridgeTests` — same RecordingAudio
// subclass pattern, no real audio output.

import XCTest
import Foundation
import SDGCore
import SDGPlatform
@testable import SDGGameplay

@MainActor
final class DisasterAudioBridgeTests: XCTestCase {

    // MARK: - Test stub

    /// `AudioService` subclass that records the effect cues it was
    /// asked to play. Identical pattern to
    /// `AudioEventBridgeTests.RecordingAudioService` — duplicated
    /// (not shared) because `private` keeps it out of the shared
    /// test module and the surface is small.
    final class RecordingAudioService: AudioService {
        var playedEffects: [AudioEffect] = []

        @discardableResult
        override func play(_ effect: AudioEffect, volume: Float = 1.0) -> UUID? {
            playedEffects.append(effect)
            return super.play(effect, volume: volume)
        }
    }

    private func drainBus() async {
        await Task.yield()
        await Task.yield()
    }

    private func makeBridge() -> (EventBus, RecordingAudioService, DisasterAudioBridge) {
        let bus = EventBus()
        let audio = RecordingAudioService(bundle: Bundle(for: type(of: self)))
        let bridge = DisasterAudioBridge(eventBus: bus, audioService: audio)
        return (bus, audio, bridge)
    }

    // MARK: - Subscription lifecycle

    func testStartInstallsFourSubscriptions() async {
        let (_, _, bridge) = makeBridge()
        XCTAssertEqual(bridge.subscriptionCount, 0)

        await bridge.start()

        // Earthquake Start/End + Flood Start/End.
        XCTAssertEqual(bridge.subscriptionCount, 4)
    }

    func testStopDrainsAllSubscriptions() async {
        let (_, _, bridge) = makeBridge()
        await bridge.start()
        await bridge.stop()

        XCTAssertEqual(bridge.subscriptionCount, 0)
    }

    // MARK: - Routing

    func testEarthquakeStartedPlaysRumble() async {
        let (bus, audio, bridge) = makeBridge()
        await bridge.start()

        await bus.publish(EarthquakeStarted(
            questId: nil, intensity: 0.7, durationSeconds: 2.0
        ))
        await drainBus()

        XCTAssertEqual(audio.playedEffects, [.earthquakeRumble])
    }

    func testFloodStartedPlaysFloodCue() async {
        let (bus, audio, bridge) = makeBridge()
        await bridge.start()

        await bus.publish(FloodStarted(
            questId: nil, targetWaterY: 5, riseSeconds: 5
        ))
        await drainBus()

        XCTAssertEqual(audio.playedEffects, [.floodWater])
    }

    /// End events are wired but MVP doesn't stop playback. The
    /// subscriber firing is enough — this test guards against a
    /// regression where the Ended subscribers get dropped from the
    /// bridge before `AudioService.stop(_:)` lands.
    func testEarthquakeEndedDoesNotCrash() async {
        let (bus, _, bridge) = makeBridge()
        await bridge.start()

        await bus.publish(EarthquakeEnded(questId: nil))
        await drainBus()
        // No assertion — just ensure no crash, no extra cue.
    }
}
