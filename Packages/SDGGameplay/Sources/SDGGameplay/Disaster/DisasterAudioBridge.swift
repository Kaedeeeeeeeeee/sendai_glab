// DisasterAudioBridge.swift
// SDGGameplay · Disaster
//
// Bridge that subscribes to disaster events and plays the matching
// `AudioEffect`. Same shape as `AudioEventBridge` — we keep the two
// bridges separate rather than extending the audio bridge so each
// has a focused scope (drilling vs. disasters) and the tests can
// instantiate one without the other.
//
// Phase 8.1 scope: start SFX on `EarthquakeStarted` / `FloodStarted`
// and stop them on `EarthquakeEnded` / `FloodEnded` via
// `AudioService.stop(_:)`. The earthquake rumble now loops forever
// (`loops: -1`) so it covers the whole shake; the Ended handler is
// what cuts it off. Flood is still a one-shot but is symmetrically
// stopped for safety (future longer flood asset would otherwise
// outlast the rise).

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

        // Phase 8.1: rumble loops for the whole quake (`loops: -1`).
        // The MVP `loops = 0` one-shot ended mid-shake and left the
        // last second of the quake silent — rumble should cover the
        // entire duration, so we loop until `EarthquakeEnded` stops it.
        let earthquakeStartToken = await eventBus.subscribe(
            EarthquakeStarted.self
        ) { _ in
            await MainActor.run { () -> Void in
                audio.play(.earthquakeRumble, loops: -1)
            }
        }

        // Phase 8.1: stop the rumble when the quake ends. Needed
        // because the Started handler now loops forever; without this
        // stop the rumble would play past the shake and into the next
        // silent minute.
        let earthquakeEndToken = await eventBus.subscribe(
            EarthquakeEnded.self
        ) { _ in
            await MainActor.run { () -> Void in
                audio.stop(.earthquakeRumble)
            }
        }

        // Flood start / end: the flood rise is a one-shot crescendo
        // (not a loop) but we still stop it on `FloodEnded` for
        // symmetry + safety if a future asset is longer than the
        // rise duration.
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
            await MainActor.run { () -> Void in
                audio.stop(.floodWater)
            }
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
