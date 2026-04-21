// DrillingStoreTests.swift
// SDGGameplayTests
//
// Unit tests for `DrillingStore`. These focus on the middle layer in
// isolation — we never actually spin up a `DrillingOrchestrator`.
// Instead we drive the Store via `intent(.drillAt)` and fake the
// orchestrator by publishing `DrillCompleted` / `DrillFailed` directly
// onto the bus. That proves the Store's status machine in isolation
// from the scene-side detection code.

import XCTest
import SDGCore
@testable import SDGGameplay

@MainActor
final class DrillingStoreTests: XCTestCase {

    // MARK: - Fixtures

    /// `SIMD3<Float>` literal for the drill origin used throughout.
    private let origin = SIMD3<Float>(1, 2, 3)
    private let down = SIMD3<Float>(0, -1, 0)

    /// Give pending MainActor-bound handler continuations a turn
    /// to run. EventBus.publish awaits its handlers, so after the
    /// publish returns the handler has at least been *entered*; the
    /// store's own `await self?...` hop then completes on a yield.
    private func drainBus() async {
        await Task.yield()
    }

    // MARK: - Init

    func testInitialStatusIsIdle() {
        let bus = EventBus()
        let store = DrillingStore(eventBus: bus)
        XCTAssertEqual(store.status, .idle)
    }

    // MARK: - Intent → status transition

    func testDrillAtIntentFlipsStatusToDrilling() async {
        let bus = EventBus()
        let store = DrillingStore(eventBus: bus)
        await store.start()

        await store.intent(.drillAt(origin: origin, direction: down, maxDepth: 2.0))

        XCTAssertEqual(store.status, .drilling)
    }

    func testDrillAtIntentPublishesDrillRequested() async {
        let bus = EventBus()
        let store = DrillingStore(eventBus: bus)

        let exp = expectation(description: "DrillRequested observed")
        let token = await bus.subscribe(DrillRequested.self) { event in
            if event.origin == SIMD3<Float>(1, 2, 3),
               event.direction == SIMD3<Float>(0, -1, 0),
               event.maxDepth == 2.0 {
                exp.fulfill()
            }
        }

        await store.intent(.drillAt(origin: origin, direction: down, maxDepth: 2.0))
        await fulfillment(of: [exp], timeout: 1.0)

        await bus.cancel(token)
    }

    // MARK: - DrillCompleted subscription

    func testDrillCompletedEventTransitionsStatusToLastCompleted() async {
        let bus = EventBus()
        let store = DrillingStore(eventBus: bus)
        await store.start()

        // Simulate a drill in progress.
        await store.intent(.drillAt(origin: origin, direction: down, maxDepth: 2.0))
        XCTAssertEqual(store.status, .drilling)

        let sampleId = UUID()
        await bus.publish(
            DrillCompleted(sampleId: sampleId, layerCount: 3, totalDepth: 2.0)
        )
        await drainBus()

        // We only pin the id; the `at` timestamp is assigned inside
        // the handler and is a moving target.
        guard case let .lastCompleted(observedId, _) = store.status else {
            return XCTFail("expected .lastCompleted, got \(store.status)")
        }
        XCTAssertEqual(observedId, sampleId)
    }

    // MARK: - DrillFailed subscription

    func testDrillFailedEventTransitionsStatusToLastFailed() async {
        let bus = EventBus()
        let store = DrillingStore(eventBus: bus)
        await store.start()

        await store.intent(.drillAt(origin: origin, direction: down, maxDepth: 2.0))

        await bus.publish(DrillFailed(origin: origin, reason: "no_layers"))
        await drainBus()

        guard case let .lastFailed(reason, _) = store.status else {
            return XCTFail("expected .lastFailed, got \(store.status)")
        }
        XCTAssertEqual(reason, "no_layers")
    }

    // MARK: - Re-drill resets status from terminal back to .drilling

    func testRedrillAfterCompletedReturnsToDrilling() async {
        let bus = EventBus()
        let store = DrillingStore(eventBus: bus)
        await store.start()

        await store.intent(.drillAt(origin: origin, direction: down, maxDepth: 2.0))
        await bus.publish(
            DrillCompleted(sampleId: UUID(), layerCount: 2, totalDepth: 2.0)
        )
        await drainBus()

        // Pre-condition: we're in a terminal state.
        guard case .lastCompleted = store.status else {
            return XCTFail("setup: expected .lastCompleted")
        }

        // Re-drill — must go straight back to `.drilling`.
        await store.intent(.drillAt(origin: origin, direction: down, maxDepth: 1.0))
        XCTAssertEqual(store.status, .drilling)
    }

    func testRedrillAfterFailedReturnsToDrilling() async {
        let bus = EventBus()
        let store = DrillingStore(eventBus: bus)
        await store.start()

        await store.intent(.drillAt(origin: origin, direction: down, maxDepth: 2.0))
        await bus.publish(DrillFailed(origin: origin, reason: "no_layers"))
        await drainBus()

        guard case .lastFailed = store.status else {
            return XCTFail("setup: expected .lastFailed")
        }

        await store.intent(.drillAt(origin: origin, direction: down, maxDepth: 1.0))
        XCTAssertEqual(store.status, .drilling)
    }

    // MARK: - Lifecycle

    func testStartIsIdempotent() async {
        let bus = EventBus()
        let store = DrillingStore(eventBus: bus)

        await store.start()
        await store.start()

        // Subscriber count must not double: a second start must not
        // create a second handler for the same event type.
        let completedCount = await bus.subscriberCount(for: DrillCompleted.self)
        let failedCount = await bus.subscriberCount(for: DrillFailed.self)
        XCTAssertEqual(completedCount, 1)
        XCTAssertEqual(failedCount, 1)
    }

    func testStopDetachesBothSubscriptions() async {
        let bus = EventBus()
        let store = DrillingStore(eventBus: bus)
        await store.start()
        await store.stop()

        let completedCount = await bus.subscriberCount(for: DrillCompleted.self)
        let failedCount = await bus.subscriberCount(for: DrillFailed.self)
        XCTAssertEqual(completedCount, 0)
        XCTAssertEqual(failedCount, 0)
    }

    func testStopWithoutStartIsNoOp() async {
        let bus = EventBus()
        let store = DrillingStore(eventBus: bus)
        await store.stop()
        // No crash, no hang: pass.
    }

    func testEventsAfterStopDoNotMutateStatus() async {
        let bus = EventBus()
        let store = DrillingStore(eventBus: bus)
        await store.start()
        await store.stop()

        // Publish — the Store is no longer listening.
        await bus.publish(
            DrillCompleted(sampleId: UUID(), layerCount: 1, totalDepth: 1.0)
        )
        await drainBus()

        XCTAssertEqual(store.status, .idle)
    }
}
