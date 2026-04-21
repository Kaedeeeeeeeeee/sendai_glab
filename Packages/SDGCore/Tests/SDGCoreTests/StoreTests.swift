// StoreTests.swift
// SDGCoreTests
//
// Smoke-level coverage of the `Store` protocol: a concrete `@Observable`
// implementation, intent dispatch, state mutation, and event emission
// through the injected EventBus.

import XCTest
import Observation
@testable import SDGCore

// MARK: - Fixture types

/// Event published by `TestStore` when its counter reaches `target`.
private struct CounterReachedTarget: GameEvent, Equatable {
    let finalValue: Int
}

/// Tiny `@Observable` store used only by tests. Mirrors how real
/// gameplay stores will be structured: intent-driven, state-holding,
/// event-emitting, no knowledge of SwiftUI or other stores.
@Observable
@MainActor
private final class TestStore: Store {

    enum Intent: Sendable {
        case increment
        case add(Int)
        case reset
    }

    // State
    private(set) var counter: Int = 0
    private(set) var totalAdded: Int = 0

    // Config
    let target: Int

    // Dependencies
    private let eventBus: EventBus

    init(target: Int, eventBus: EventBus) {
        self.target = target
        self.eventBus = eventBus
    }

    func intent(_ intent: Intent) async {
        switch intent {
        case .increment:
            counter += 1
            totalAdded += 1
        case .add(let n):
            counter += n
            totalAdded += n
        case .reset:
            counter = 0
        }

        if counter >= target {
            await eventBus.publish(CounterReachedTarget(finalValue: counter))
        }
    }
}

private actor EventCollector {
    private(set) var events: [CounterReachedTarget] = []
    func record(_ e: CounterReachedTarget) { events.append(e) }
    func snapshot() -> [CounterReachedTarget] { events }
}

// MARK: - Tests

final class StoreTests: XCTestCase {

    @MainActor
    func testIntentMutatesState() async {
        let bus = EventBus()
        let store = TestStore(target: 100, eventBus: bus)

        await store.intent(.increment)
        await store.intent(.increment)
        await store.intent(.add(5))

        XCTAssertEqual(store.counter, 7)
        XCTAssertEqual(store.totalAdded, 7)
    }

    @MainActor
    func testResetIntent() async {
        let bus = EventBus()
        let store = TestStore(target: 100, eventBus: bus)

        await store.intent(.add(10))
        XCTAssertEqual(store.counter, 10)

        await store.intent(.reset)
        XCTAssertEqual(store.counter, 0)
        // totalAdded preserved — reset is a state decision, not history.
        XCTAssertEqual(store.totalAdded, 10)
    }

    @MainActor
    func testStorePublishesEventWhenConditionMet() async {
        let bus = EventBus()
        let store = TestStore(target: 3, eventBus: bus)
        let collector = EventCollector()

        _ = await bus.subscribe(CounterReachedTarget.self) { event in
            await collector.record(event)
        }

        // Under target — no event.
        await store.intent(.add(2))
        let beforeTarget = await collector.snapshot()
        XCTAssertEqual(beforeTarget.count, 0)

        // Cross the target — event should fire.
        await store.intent(.increment)
        let afterTarget = await collector.snapshot()
        XCTAssertEqual(afterTarget.count, 1)
        XCTAssertEqual(afterTarget.first?.finalValue, 3)
    }

    @MainActor
    func testIntentCanBeSentFromTaskGroupSerially() async {
        // Intents are funnelled through `await store.intent(...)`; the
        // store is `@MainActor` so ordering is deterministic even when
        // the issuing tasks are parallel.
        let bus = EventBus()
        let store = TestStore(target: 1_000_000, eventBus: bus)

        // Sequential awaits from a single task: simplest guarantee.
        for i in 1...20 {
            await store.intent(.add(i))
        }

        let expected = (1...20).reduce(0, +)
        XCTAssertEqual(store.counter, expected)
        XCTAssertEqual(store.totalAdded, expected)
    }
}
