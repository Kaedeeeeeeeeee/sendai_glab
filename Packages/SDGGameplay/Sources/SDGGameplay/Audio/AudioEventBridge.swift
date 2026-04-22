// AudioEventBridge.swift
// SDGGameplay · Audio
//
// Bridges gameplay `GameEvent`s onto the platform-side `AudioService`.
//
// ## Why is this file in SDGGameplay rather than SDGPlatform?
//
// The bridge has to *import* the concrete gameplay events
// (`DrillRequested`, `SampleCreatedEvent`, `DrillFailed`). Those types
// live in SDGGameplay. Per ADR-0001 SDGPlatform is parallel to
// SDGGameplay and must not depend on it (Platform is the lower layer
// that Gameplay builds on, not the other way around). Placing the
// bridge in SDGGameplay keeps the dependency direction legal:
// SDGGameplay → SDGPlatform → SDGCore.
//
// The inverse placement (bridge in Platform, events in Platform) was
// considered and rejected: it would force Platform to know every
// gameplay event, which contradicts the "platform services" role
// ADR-0001 reserves for Platform.

import Foundation
import SDGCore
import SDGPlatform

/// Subscribes to gameplay events on the shared `EventBus` and fires
/// the matching `AudioEffect` cue on an `AudioService`.
///
/// Lifecycle:
/// - Construct with an `EventBus` and `AudioService`.
/// - Call `start()` to install subscriptions.
/// - Call `stop()` (or let the instance deinit) to tear them down.
///
/// The bridge holds a `SubscriptionToken` per handler it installed so
/// `stop()` is a clean unsubscribe, not a "hope GC runs" exit.
///
/// Why `@MainActor`? The `AudioService` façade is `@MainActor`; so is
/// most of the host UI. Keeping the bridge on the same actor removes
/// a hop on every event and makes token bookkeeping race-free without
/// extra locks.
@MainActor
public final class AudioEventBridge {

    // MARK: - Dependencies

    /// Bus the bridge listens on. Injected rather than pulled from a
    /// singleton; AGENTS.md Rule 2.
    private let eventBus: EventBus

    /// Audio façade the bridge pushes cues into. Injected for the
    /// same reason and also so tests can swap in a recording stub
    /// subclass to verify routing without playing real audio.
    private let audioService: AudioService

    // MARK: - State

    /// Tokens for every live subscription. Populated by `start()` and
    /// drained by `stop()`. Held on the main actor so the mutations
    /// don't need a lock.
    private var tokens: [SubscriptionToken] = []

    // MARK: - Init

    /// - Parameters:
    ///   - eventBus: Shared `EventBus` instance from `AppEnvironment`.
    ///   - audioService: The platform-side `AudioService` that will
    ///                   actually play the cues.
    public init(eventBus: EventBus, audioService: AudioService) {
        self.eventBus = eventBus
        self.audioService = audioService
    }

    // MARK: - Lifecycle

    /// Subscribe to every event the bridge maps. Idempotent is *not*
    /// guaranteed: calling `start()` twice without an intervening
    /// `stop()` will install duplicate handlers. Callers (AppCoordinator,
    /// tests) pair `start()` with exactly one `stop()`.
    public func start() async {
        // Capture the audio service (a reference type) directly.
        // We deliberately do *not* capture `self` weakly here because
        // an `AudioEventBridge` whose handlers have already been
        // installed is only torn down via `stop()`, which explicitly
        // cancels the tokens. Capturing `self` would also break
        // Swift 6's `@Sendable` checking on closures that hop across
        // actor isolations. The audioService is a class; it is safe
        // to keep a strong reference in the handler closure because
        // the bridge's lifetime subsumes the handler's installation.
        //
        // Each handler hops back onto MainActor via `MainActor.run`
        // because EventBus handlers run off-actor (ADR-0003 §Handler
        // isolation), while `audioService.play` is `@MainActor`.
        //
        // `MainActor.run` is generic in its return; an explicit
        // `Void` return on the trailing closure keeps Swift from
        // inferring `UUID?` (the discardable-result type of
        // `AudioService.play`) and tripping a generic-inference error.
        let audio = audioService

        let drillReqToken = await eventBus.subscribe(DrillRequested.self) { _ in
            await MainActor.run { () -> Void in
                audio.play(.drillStart)
            }
        }

        let sampleToken = await eventBus.subscribe(SampleCreatedEvent.self) { _ in
            await MainActor.run { () -> Void in
                audio.play(.feedbackSuccess)
            }
        }

        let failedToken = await eventBus.subscribe(DrillFailed.self) { _ in
            await MainActor.run { () -> Void in
                audio.play(.feedbackFailure)
            }
        }

        tokens = [drillReqToken, sampleToken, failedToken]
    }

    /// Cancel every subscription the bridge installed. Safe to call
    /// from any task: the actual `eventBus.cancel` hops into the
    /// actor, and the local `tokens` mutation is `@MainActor`-isolated.
    public func stop() async {
        for token in tokens {
            await eventBus.cancel(token)
        }
        tokens.removeAll()
    }

    // MARK: - Test-only introspection

    /// Number of live subscriptions currently held. Tests use this to
    /// verify `start()` installs the full set and `stop()` drains it.
    public var subscriptionCount: Int {
        tokens.count
    }
}
