// DisasterAudioBridge.swift
// SDGGameplay · Disaster
//
// Bridge that subscribes to disaster events and plays the matching
// `AudioEffect`. Same shape as `AudioEventBridge` — we keep the two
// bridges separate rather than extending the audio bridge so each
// has a focused scope (drilling vs. disasters) and the tests can
// instantiate one without the other.
//
// MVP scope: start SFX on `EarthquakeStarted` / `FloodStarted`. The
// current `AudioService` has no stop-by-cue API, so the `Ended`
// events are subscribed to but don't forcefully silence the loop.
// Both placeholder SFX are short enough that they self-terminate.
// Phase 8.1 adds `AudioService.stop(_:)` and hooks the Ended
// subscribers to it.

import Foundation
import SDGCore
import SDGPlatform

/// Bridges `EarthquakeStarted` / `FloodStarted` events onto the
/// platform-side `AudioService`. Symmetric with `AudioEventBridge`.
@MainActor
public final class DisasterAudioBridge {

    // MARK: - Dependencies

    private let eventBus: EventBus
    private let audioService: AudioService

    // MARK: - State

    private var tokens: [SubscriptionToken] = []

    // MARK: - Init

    public init(eventBus: EventBus, audioService: AudioService) {
        self.eventBus = eventBus
        self.audioService = audioService
    }

    // MARK: - Lifecycle

    /// Install subscriptions. Call exactly once, pair with `stop()`.
    public func start() async {
        let audio = audioService

        let earthquakeStartToken = await eventBus.subscribe(
            EarthquakeStarted.self
        ) { _ in
            await MainActor.run { () -> Void in
                audio.play(.earthquakeRumble)
            }
        }

        // Subscribe to Ended even though MVP has no stop capability:
        // installing the subscription now means Phase 8.1's
        // `AudioService.stop(_:)` plug-in requires only the handler
        // body to change, not this bridge's public contract.
        let earthquakeEndToken = await eventBus.subscribe(
            EarthquakeEnded.self
        ) { _ in
            // No-op for MVP. Placeholder is short enough to self-
            // terminate. Phase 8.1: `audio.stop(.earthquakeRumble)`.
        }

        let floodStartToken = await eventBus.subscribe(
            FloodStarted.self
        ) { _ in
            await MainActor.run { () -> Void in
                audio.play(.floodWater)
            }
        }

        let floodEndToken = await eventBus.subscribe(
            FloodEnded.self
        ) { _ in
            // MVP no-op; see EarthquakeEnded comment.
        }

        tokens = [
            earthquakeStartToken,
            earthquakeEndToken,
            floodStartToken,
            floodEndToken
        ]

        print("[SDG-Lab][audio] DisasterAudioBridge started with " +
              "\(tokens.count) subscriptions")
    }

    /// Cancel every subscription. Safe to call multiple times.
    public func stop() async {
        for token in tokens {
            await eventBus.cancel(token)
        }
        tokens.removeAll()
    }

    /// Test hook: number of live subscriptions.
    public var subscriptionCount: Int { tokens.count }
}
