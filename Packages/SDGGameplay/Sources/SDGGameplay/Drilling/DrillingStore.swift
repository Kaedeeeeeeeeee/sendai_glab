// DrillingStore.swift
// SDGGameplay · Drilling
//
// Middle-layer (@Observable) state container for the drilling tool.
// See ADR-0001 for the three-layer architecture this fits into:
//
//     [SwiftUI HUD "drill" button]
//                │ intent(.drillAt(…))
//                ▼
//          [DrillingStore]   ← this file
//                │ publishes DrillRequested
//                ▼
//       [DrillingOrchestrator]
//                │ publishes SampleCreated + DrillCompleted / DrillFailed
//                ▼
//          [DrillingStore]   (updates `status`)
//          [InventoryStore]  (ingests the sample)
//
// Critically, the Store does *not* wait on the orchestrator's
// result: `intent(.drillAt)` publishes the request, flips `status`
// to `.drilling`, and returns. The orchestrator's follow-on events
// land on the Store's subscriptions and drive the status machine
// from `.drilling` to `.lastCompleted` / `.lastFailed`.
//
// Why this split (rather than returning the sample directly from
// `intent`)? Stores cannot import RealityKit Entities (ADR-0001), so
// the Store has no way to read the scene. Keeping the detection +
// sample construction in the orchestrator and routing the result
// back via the bus is the sanctioned cross-layer pattern.

import Foundation
import Observation
import SDGCore

/// `@Observable` store that owns the "is the drill running?" state
/// and funnels drill requests onto the EventBus.
///
/// ### Lifecycle
///
/// `init` wires dependencies; no I/O, no subscription. Callers MUST
/// invoke ``start()`` once the bus is hot so the Store begins
/// receiving `DrillCompleted` / `DrillFailed` updates. ``stop()``
/// detaches the subscriptions and is idempotent. Both are async
/// because the bus itself is an `actor`.
///
/// ### Concurrency
///
/// `@MainActor` matches the rest of the Store layer: `@Observable`
/// mutations live on the main thread so SwiftUI's observation
/// runtime stays consistent. Bus handlers enter the actor via
/// `await self?...`.
@Observable
@MainActor
public final class DrillingStore: Store {

    // MARK: - Intent

    /// Commands a caller can send. Phase 1 has a single command; we
    /// keep the `enum` shape so the addition of, e.g.,
    /// `.drillTowerSlot(Int)` for the 0-10m tower tool (GDD §1.3)
    /// doesn't break source compatibility.
    public enum Intent: Sendable, Equatable {

        /// Drill from `origin` along `direction` up to `maxDepth`
        /// metres. `direction` is expected to be a unit vector;
        /// Phase 1 callers always pass `(0, -1, 0)`.
        case drillAt(
            origin: SIMD3<Float>,
            direction: SIMD3<Float>,
            maxDepth: Float
        )
    }

    // MARK: - Status

    /// Observable drill state machine.
    ///
    /// Transitions:
    ///   - `.idle` → `.drilling` on every `.drillAt` intent.
    ///   - `.drilling` → `.lastCompleted(sampleId, at)` on
    ///     `DrillCompleted`.
    ///   - `.drilling` → `.lastFailed(reason, at)` on `DrillFailed`.
    ///   - Any terminal state → `.drilling` on another `.drillAt`
    ///     intent (re-drilling immediately overrides the banner).
    ///
    /// `.lastCompleted` / `.lastFailed` are sticky — they stay on
    /// the Store until the next drill attempt. UI code can drive a
    /// transient toast/banner from them without an extra clearing
    /// intent.
    public enum Status: Sendable, Equatable {
        case idle
        case drilling
        case lastCompleted(sampleId: UUID, at: Date)
        case lastFailed(reason: String, at: Date)
    }

    // MARK: - Observable state

    /// Current drill status. See ``Status`` for transitions.
    public private(set) var status: Status = .idle

    // MARK: - Dependencies (injected, not global)

    private let eventBus: EventBus

    /// Two tokens because we subscribe to two event types. Stored in
    /// a tuple rather than an array so each one's purpose stays
    /// visible at the call site (and `nil` can flag teardown
    /// idempotency).
    private var completedToken: SubscriptionToken?
    private var failedToken: SubscriptionToken?

    // MARK: - Init

    /// - Parameter eventBus: Shared bus instance, typically from
    ///   `AppEnvironment`. Holding a reference is safe: `EventBus`
    ///   is an actor and carries no UI affinity.
    public init(eventBus: EventBus) {
        self.eventBus = eventBus
    }

    // MARK: - Lifecycle

    /// Subscribe to `DrillCompleted` and `DrillFailed`. Idempotent:
    /// once subscribed, a second call is a no-op. Matches
    /// `InventoryStore.start()` semantics so both stores share a
    /// mental model.
    public func start() async {
        if completedToken == nil {
            completedToken = await eventBus.subscribe(DrillCompleted.self) { [weak self] event in
                await self?.handleDrillCompleted(event)
            }
        }
        if failedToken == nil {
            failedToken = await eventBus.subscribe(DrillFailed.self) { [weak self] event in
                await self?.handleDrillFailed(event)
            }
        }
    }

    /// Drop both subscriptions. Safe to call repeatedly; safe to
    /// call without a prior `start()`.
    public func stop() async {
        if let token = completedToken {
            await eventBus.cancel(token)
            completedToken = nil
        }
        if let token = failedToken {
            await eventBus.cancel(token)
            failedToken = nil
        }
    }

    // MARK: - Store protocol

    public func intent(_ intent: Intent) async {
        switch intent {
        case let .drillAt(origin, direction, maxDepth):
            // Flip to `.drilling` *before* publishing: if a UI test
            // or a tight test loop peeks at `status` between the
            // state change and the publish's completion, it sees the
            // in-flight state, not a stale terminal one.
            status = .drilling
            await eventBus.publish(
                DrillRequested(
                    origin: origin,
                    direction: direction,
                    maxDepth: maxDepth,
                    requestedAt: Date()
                )
            )
            // No result to await — DrillingOrchestrator picks up the
            // request, publishes DrillCompleted/DrillFailed, and the
            // Store's own subscriptions advance the status machine.
        }
    }

    // MARK: - Event handlers

    private func handleDrillCompleted(_ event: DrillCompleted) async {
        status = .lastCompleted(sampleId: event.sampleId, at: Date())
    }

    private func handleDrillFailed(_ event: DrillFailed) async {
        status = .lastFailed(reason: event.reason, at: Date())
    }
}
