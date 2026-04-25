// DisasterStoreTests.swift
// SDGGameplayTests · Disaster
//
// Exercises `DisasterStore` as a pure state machine. No scene, no
// RealityKit entities — we care about state transitions and emitted
// events only. Scene-level behaviour is covered by the separate
// `DisasterSystemTests`.

import XCTest
import Foundation
import SDGCore
@testable import SDGGameplay

@MainActor
final class DisasterStoreTests: XCTestCase {

    // MARK: - Fixtures

    private var bus: EventBus!
    private var store: DisasterStore!

    override func setUp() async throws {
        try await super.setUp()
        bus = EventBus()
        store = DisasterStore(eventBus: bus)
    }

    override func tearDown() async throws {
        store = nil
        bus = nil
        try await super.tearDown()
    }

    // Two yields so MainActor.run continuations in bus handlers land.
    private func drainBus() async {
        await Task.yield()
        await Task.yield()
    }

    // MARK: - Initial state

    func testInitialStateIsIdle() {
        XCTAssertEqual(store.state, .idle)
    }

    // MARK: - Earthquake trigger

    func testTriggerEarthquakeEntersActiveStateAndPublishes() async {
        let recorder = EventRecorder<EarthquakeStarted>()
        let token = await bus.subscribe(EarthquakeStarted.self) { event in
            await recorder.record(event)
        }

        await store.intent(.triggerEarthquake(
            intensity: 0.5,
            durationSeconds: 2.0,
            questId: "q.debug"
        ))
        await drainBus()

        if case let .earthquakeActive(remaining, intensity, questId) = store.state {
            XCTAssertEqual(remaining, 2.0, accuracy: 1e-5)
            XCTAssertEqual(intensity, 0.5, accuracy: 1e-5)
            XCTAssertEqual(questId, "q.debug")
        } else {
            XCTFail("expected .earthquakeActive, got \(store.state)")
        }

        let events = await recorder.all
        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events.first?.intensity, 0.5)
        XCTAssertEqual(events.first?.durationSeconds, 2.0)
        XCTAssertEqual(events.first?.questId, "q.debug")

        await bus.cancel(token)
    }

    /// Out-of-range intensity must clamp into [0, 1] so downstream
    /// amplitude math can't drive non-physical positions.
    func testTriggerEarthquakeClampsIntensity() async {
        await store.intent(.triggerEarthquake(
            intensity: 5.0,
            durationSeconds: 1.0,
            questId: nil
        ))
        if case let .earthquakeActive(_, intensity, _) = store.state {
            XCTAssertEqual(intensity, 1.0, accuracy: 1e-5)
        } else {
            XCTFail("state did not enter earthquakeActive")
        }
    }

    func testTriggerEarthquakeWhileActiveIsNoOp() async {
        await store.intent(.triggerEarthquake(
            intensity: 0.5, durationSeconds: 2.0, questId: "first"
        ))
        await store.intent(.triggerEarthquake(
            intensity: 1.0, durationSeconds: 5.0, questId: "second"
        ))

        // First trigger must survive intact.
        if case let .earthquakeActive(_, _, questId) = store.state {
            XCTAssertEqual(questId, "first")
        } else {
            XCTFail("state left earthquakeActive on duplicate trigger")
        }
    }

    // MARK: - Earthquake tick

    func testTickDecrementsRemainingAndEndsAtZero() async {
        let recorder = EventRecorder<EarthquakeEnded>()
        let token = await bus.subscribe(EarthquakeEnded.self) { event in
            await recorder.record(event)
        }

        await store.intent(.triggerEarthquake(
            intensity: 0.6,
            durationSeconds: 1.0,
            questId: "q.debug"
        ))
        // Two half-second ticks consume the duration exactly.
        await store.intent(.tick(dt: 0.5))
        if case let .earthquakeActive(remaining, _, _) = store.state {
            XCTAssertEqual(remaining, 0.5, accuracy: 1e-5)
        } else {
            XCTFail("state ended too early")
        }
        await store.intent(.tick(dt: 0.6))  // crosses zero
        await drainBus()

        XCTAssertEqual(store.state, .idle)
        let events = await recorder.all
        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events.first?.questId, "q.debug")

        await bus.cancel(token)
    }

    // MARK: - Flood trigger

    func testTriggerFloodEntersActiveStateAndPublishes() async {
        let recorder = EventRecorder<FloodStarted>()
        let token = await bus.subscribe(FloodStarted.self) { event in
            await recorder.record(event)
        }

        await store.intent(.triggerFlood(
            startY: 0,
            targetWaterY: 5.0,
            riseSeconds: 2.5,
            questId: nil
        ))
        await drainBus()

        if case let .floodActive(progress, startY, targetY, dur, _) = store.state {
            XCTAssertEqual(progress, 0, accuracy: 1e-5)
            XCTAssertEqual(startY, 0, accuracy: 1e-5)
            XCTAssertEqual(targetY, 5.0, accuracy: 1e-5)
            XCTAssertEqual(dur, 2.5, accuracy: 1e-5)
        } else {
            XCTFail("expected .floodActive, got \(store.state)")
        }

        let events = await recorder.all
        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events.first?.targetWaterY, 5.0)

        await bus.cancel(token)
    }

    func testFloodProgressLerpsAndEndsAtFull() async {
        let recorder = EventRecorder<FloodEnded>()
        let token = await bus.subscribe(FloodEnded.self) { event in
            await recorder.record(event)
        }

        await store.intent(.triggerFlood(
            startY: 0, targetWaterY: 10, riseSeconds: 2.0, questId: "flood-1"
        ))
        // Half-way.
        await store.intent(.tick(dt: 1.0))
        if case let .floodActive(progress, _, _, _, _) = store.state {
            XCTAssertEqual(progress, 0.5, accuracy: 1e-5)
        } else {
            XCTFail("state left flood too early")
        }
        // Overshoot.
        await store.intent(.tick(dt: 1.5))
        await drainBus()

        XCTAssertEqual(store.state, .idle)
        let events = await recorder.all
        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events.first?.questId, "flood-1")

        await bus.cancel(token)
    }

    // MARK: - Tick in idle

    func testTickInIdleIsNoOp() async {
        await store.intent(.tick(dt: 1.0))
        XCTAssertEqual(store.state, .idle)
    }

    // MARK: - Reset

    func testResetForTestingReturnsToIdle() async {
        await store.intent(.triggerEarthquake(
            intensity: 0.5, durationSeconds: 2.0, questId: nil
        ))
        XCTAssertNotEqual(store.state, .idle)

        await store.intent(.resetForTesting)

        XCTAssertEqual(store.state, .idle)
    }
}

// MARK: - Support

/// Actor-isolated recorder for event-bus assertions. Duplicated from
/// the Vehicles test file because Swift's file-scoped `private`
/// prevents reuse across test modules; copying is cheaper than
/// introducing a shared test fixture module.
private actor EventRecorder<E: Sendable> {
    private var events: [E] = []

    func record(_ event: E) {
        events.append(event)
    }

    var all: [E] { events }
}
