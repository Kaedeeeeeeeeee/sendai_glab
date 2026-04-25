// DisasterStore.swift
// SDGGameplay · Disaster
//
// `@Observable` + `@MainActor` state machine for active disasters.
// Intentionally scene-graph-agnostic: the Store only tracks timers
// and publishes events. The actual tile shaking / water plane lift
// is the `DisasterSystem`'s job; wiring the SFX is the
// `DisasterAudioBridge`'s job.
//
// ## Why a Store (and not just a System)
//
// Two reasons:
//   1. The lifecycle (start / timer / end) is pure data. Unit-
//      testing a pure state machine is a lot easier than driving a
//      real RealityKit `Scene`. Tests in `DisasterStoreTests` don't
//      load any tiles.
//   2. Same event payload can drive multiple subscribers (shake
//      animation + rumble SFX + future screen-tint shader). One
//      producer, many consumers = bus territory. If we tied the
//      timer to the System, the SFX bridge would have to scrape
//      System internals.
//
// ## Lifecycle
//
//     init(bus)                      // wire dep; no I/O, no subscribe
//             │
//           start()                  // reserved for future disk hydrate
//             │
//     intent(.triggerEarthquake ...) // .idle → .earthquakeActive
//                                    //          + EarthquakeStarted
//     intent(.triggerFlood ...)      // .idle → .floodActive
//                                    //          + FloodStarted
//     intent(.tick(dt))              // every DisasterSystem frame;
//                                    // ends state at 0 + Ended event
//             │
//           stop()                   // hook for future persistence
//
// Re-entrancy: triggering while already active is a no-op (the
// already-running disaster continues uninterrupted). Phase 8.1 can
// change this to "queue the next trigger" if gameplay demands it.

import Foundation
import Observation
import SDGCore

// MARK: - Public state

/// Union of the three gameplay-relevant phases. One global value at
/// a time: a flood and an earthquake cannot currently overlap, since
/// the System would interleave amplitudes in a way we haven't
/// designed yet. Out of scope for MVP; revisit when ADR-0011 covers
/// compound disasters.
public enum DisasterState: Sendable, Equatable, Codable {
    case idle

    /// An earthquake is shaking. `remaining` counts down each tick;
    /// when it hits 0 the Store transitions back to `.idle` and
    /// publishes `EarthquakeEnded(questId:)`.
    case earthquakeActive(
        remaining: Float,
        intensity: Float,
        questId: String?
    )

    /// A flood is rising from `startY` to `targetY`; `progress`
    /// (0.0 → 1.0) is the tick-accumulated normalised position.
    /// When it hits 1.0 the Store transitions back to `.idle` and
    /// publishes `FloodEnded(questId:)`. `durationSeconds` is
    /// retained so the tick math doesn't need to reference the
    /// original event.
    case floodActive(
        progress: Float,
        startY: Float,
        targetY: Float,
        durationSeconds: Float,
        questId: String?
    )
}

// MARK: - Intents

/// What external code can ask the Store to do. `.tick` is the
/// System's per-frame hand-off; the trigger intents are the public
/// surface any gameplay code (debug button, quest bridge) uses.
public enum DisasterIntent: Sendable {

    /// Start an earthquake. No-op if a disaster is already active.
    case triggerEarthquake(
        intensity: Float,
        durationSeconds: Float,
        questId: String?
    )

    /// Start a flood. `startY` is the plane's current altitude
    /// (typically sampled by the System before dispatching this
    /// intent). No-op if a disaster is already active.
    case triggerFlood(
        startY: Float,
        targetWaterY: Float,
        riseSeconds: Float,
        questId: String?
    )

    /// Advance the active timer by `dt` seconds. The System dispatches
    /// this every frame. A no-op in `.idle`.
    case tick(dt: Float)

    /// Reset to `.idle` without firing any end events. Intended for
    /// test teardown and scene reloads.
    case resetForTesting

    /// Record that the disaster tied to `questId` has fired once
    /// already. The quest-driven trigger bridge records this so a
    /// second reload doesn't re-play the same disaster cutscene.
    /// Idempotent: adding the same id twice is a no-op.
    case markQuestTriggered(questId: String)
}

// MARK: - Store

@Observable
@MainActor
public final class DisasterStore: Store {

    public typealias Intent = DisasterIntent

    /// Observable state; the sole mutator is `intent(_:)`.
    public private(set) var state: DisasterState = .idle

    /// Quest ids whose quest-driven disaster has already fired and
    /// must not re-fire on reload. Populated by callers via
    /// `.markQuestTriggered` when they translate a quest completion
    /// into a disaster trigger. Persisted alongside `state`.
    ///
    /// Example: the Aobayama earthquake is configured to fire when
    /// `q.field.kawauchi-survey` completes. If the player quits and
    /// reloads after completing that quest, we do NOT want another
    /// earthquake — the coordinator checks this set before triggering.
    public private(set) var triggeredQuestIds: Set<String> = []

    /// Event bus for outbound notifications. Injected so tests can
    /// own the bus and assert on publications.
    private let eventBus: EventBus

    /// Persistence backend. Injected so tests pass `.inMemory`;
    /// default `.standard` hits `UserDefaults.standard`.
    private let persistence: DisasterPersistence

    public init(
        eventBus: EventBus,
        persistence: DisasterPersistence = .standard
    ) {
        self.eventBus = eventBus
        self.persistence = persistence
    }

    // MARK: - Intent

    public func intent(_ intent: DisasterIntent) async {
        switch intent {
        case let .triggerEarthquake(intensity, durationSeconds, questId):
            guard case .idle = state else { return }
            // Defensive clamp on the intensity envelope. Out-of-range
            // callers would otherwise drive `sinf(...) * amp` into
            // non-physical amplitudes.
            let clampedIntensity = max(0, min(1, intensity))
            // Also guard against negative / zero durations — publishing
            // an "event ended" before the start propagated would be a
            // footgun.
            let clampedDuration = max(0.1, durationSeconds)
            state = .earthquakeActive(
                remaining: clampedDuration,
                intensity: clampedIntensity,
                questId: questId
            )
            persistIgnoringFailure()
            await eventBus.publish(EarthquakeStarted(
                questId: questId,
                intensity: clampedIntensity,
                durationSeconds: clampedDuration
            ))

        case let .triggerFlood(startY, targetWaterY, riseSeconds, questId):
            guard case .idle = state else { return }
            let clampedDuration = max(0.1, riseSeconds)
            state = .floodActive(
                progress: 0,
                startY: startY,
                targetY: targetWaterY,
                durationSeconds: clampedDuration,
                questId: questId
            )
            persistIgnoringFailure()
            await eventBus.publish(FloodStarted(
                questId: questId,
                targetWaterY: targetWaterY,
                riseSeconds: clampedDuration
            ))

        case let .tick(dt):
            await advance(by: dt)

        case .resetForTesting:
            state = .idle
            triggeredQuestIds = []
            try? persistence.save(.empty)

        case let .markQuestTriggered(questId):
            // Set insertion is idempotent; only save if the set
            // actually grew, to avoid a defaults write every tick if
            // someone accidentally fires this in a hot loop.
            let (inserted, _) = triggeredQuestIds.insert(questId)
            if inserted {
                persistIgnoringFailure()
            }
        }
    }

    // MARK: - Tick helpers

    /// Pure timer arithmetic: peel `dt` off the active state and
    /// transition to `.idle` + publish `Ended` when we cross the
    /// boundary. Split out of `intent` so it stays readable.
    private func advance(by dt: Float) async {
        guard dt > 0 else { return }
        switch state {
        case .idle:
            return

        case let .earthquakeActive(remaining, intensity, questId):
            let next = remaining - dt
            if next <= 0 {
                state = .idle
                persistIgnoringFailure()
                await eventBus.publish(EarthquakeEnded(questId: questId))
            } else {
                state = .earthquakeActive(
                    remaining: next,
                    intensity: intensity,
                    questId: questId
                )
                // Intentionally do NOT persist on every tick. The
                // tick cadence is 60 Hz; writing JSON to UserDefaults
                // 60× per second would be wasteful. Save-on-boundary
                // (start / end / reset / markTriggered) is enough to
                // restore the *existence* of an active quake on
                // reload; the exact remaining-time delta across an
                // app quit is not gameplay-critical.
            }

        case let .floodActive(progress, startY, targetY, duration, questId):
            // `duration` is the total rise seconds; `dt/duration`
            // is the incremental progress. At 1.0 we flip to idle
            // and fire `FloodEnded`. The water plane stays at
            // `targetY` — the System reads `progress` from the
            // previous state before we mutate it, so one extra
            // tick past 1.0 doesn't matter.
            let next = progress + dt / duration
            if next >= 1 {
                state = .idle
                persistIgnoringFailure()
                await eventBus.publish(FloodEnded(questId: questId))
            } else {
                state = .floodActive(
                    progress: next,
                    startY: startY,
                    targetY: targetY,
                    durationSeconds: duration,
                    questId: questId
                )
                // See earthquake branch above for why we don't
                // persist per-tick.
            }
        }
    }

    // MARK: - Store protocol

    public func start() async {
        // Hydrate from disk. Loading failure is a soft reset: first
        // launch (no data) and a corrupt blob both land back at
        // `.idle` with no fired quests — that's the safest state.
        guard let snapshot = try? persistence.load() else { return }
        state = snapshot.state
        triggeredQuestIds = snapshot.triggeredQuestIds
    }

    public func stop() async {
        // Symmetric with `start`; no subscriptions to tear down.
    }

    // MARK: - Persistence helper

    /// Best-effort save. Persistence failure must not crash gameplay;
    /// in the worst case the disaster state rolls back on next launch.
    /// Mirrors `InventoryStore.persistIgnoringFailure` — one place
    /// owns the swallow so call sites stay readable.
    private func persistIgnoringFailure() {
        let snapshot = DisasterPersistence.Snapshot(
            state: state,
            triggeredQuestIds: triggeredQuestIds
        )
        do {
            try persistence.save(snapshot)
        } catch {
            // Intentionally swallowed. Worst case: the player's
            // last disaster state won't survive the next launch.
        }
    }
}
