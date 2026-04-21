// EventBusTests.swift
// SDGCoreTests
//
// Coverage for EventBus — single/multi subscriber delivery, cancellation,
// type isolation, concurrent pressure, and ordering.

import XCTest
@testable import SDGCore

// MARK: - Test events

private struct DemoEvent: GameEvent, Equatable {
    let payload: Int
}

private struct OtherEvent: GameEvent, Equatable {
    let tag: String
}

// MARK: - Helpers

/// Thread-safe counter backed by an actor. Used by tests to accumulate
/// handler invocations without forcing `@MainActor` on the handler.
private actor Counter {
    private(set) var value = 0
    func increment() { value += 1 }
    func add(_ n: Int) { value += n }
    func get() -> Int { value }
}

/// Thread-safe ordered collector.
private actor Collector<T: Sendable> {
    private(set) var items: [T] = []
    func append(_ item: T) { items.append(item) }
    func snapshot() -> [T] { items }
}

// MARK: - Tests

final class EventBusTests: XCTestCase {

    func testSingleSubscriberReceivesSingleEvent() async {
        let bus = EventBus()
        let collector = Collector<Int>()

        _ = await bus.subscribe(DemoEvent.self) { event in
            await collector.append(event.payload)
        }

        await bus.publish(DemoEvent(payload: 42))

        let received = await collector.snapshot()
        XCTAssertEqual(received, [42])
    }

    func testMultipleSubscribersAllReceive() async {
        let bus = EventBus()
        let counter = Counter()
        let subscriberCount = 5

        for _ in 0..<subscriberCount {
            _ = await bus.subscribe(DemoEvent.self) { _ in
                await counter.increment()
            }
        }

        await bus.publish(DemoEvent(payload: 1))

        let total = await counter.get()
        XCTAssertEqual(total, subscriberCount)
    }

    func testCancelStopsDelivery() async {
        let bus = EventBus()
        let counter = Counter()

        let token = await bus.subscribe(DemoEvent.self) { _ in
            await counter.increment()
        }

        await bus.publish(DemoEvent(payload: 1))
        let afterFirst = await counter.get()
        XCTAssertEqual(afterFirst, 1)

        await bus.cancel(token)
        await bus.publish(DemoEvent(payload: 2))

        let afterSecond = await counter.get()
        XCTAssertEqual(afterSecond, 1, "cancelled handler must not be invoked")

        let remaining = await bus.subscriberCount(for: DemoEvent.self)
        XCTAssertEqual(remaining, 0)
    }

    func testCancelWithUnknownTokenIsNoOp() async {
        let bus = EventBus()
        let bogus = SubscriptionToken(id: UUID())
        // Simply must not crash.
        await bus.cancel(bogus)
        let count = await bus.subscriberCount(for: DemoEvent.self)
        XCTAssertEqual(count, 0)
    }

    func testCancelIsIdempotent() async {
        let bus = EventBus()
        let token = await bus.subscribe(DemoEvent.self) { _ in }
        await bus.cancel(token)
        await bus.cancel(token) // second cancel: no-op
        let count = await bus.subscriberCount(for: DemoEvent.self)
        XCTAssertEqual(count, 0)
    }

    func testDifferentEventTypesDoNotCrossTalk() async {
        let bus = EventBus()
        let demoCounter = Counter()
        let otherCounter = Counter()

        _ = await bus.subscribe(DemoEvent.self) { _ in
            await demoCounter.increment()
        }
        _ = await bus.subscribe(OtherEvent.self) { _ in
            await otherCounter.increment()
        }

        await bus.publish(DemoEvent(payload: 1))
        await bus.publish(DemoEvent(payload: 2))
        await bus.publish(OtherEvent(tag: "x"))

        let demos = await demoCounter.get()
        let others = await otherCounter.get()
        XCTAssertEqual(demos, 2)
        XCTAssertEqual(others, 1)
    }

    func testSerialPublishPreservesOrderToSingleSubscriber() async {
        let bus = EventBus()
        let collector = Collector<Int>()

        _ = await bus.subscribe(DemoEvent.self) { event in
            await collector.append(event.payload)
        }

        for i in 0..<50 {
            await bus.publish(DemoEvent(payload: i))
        }

        let received = await collector.snapshot()
        XCTAssertEqual(received, Array(0..<50))
    }

    func testConcurrentPressure_1000PublishesTenSubscribers() async {
        let bus = EventBus()
        let counter = Counter()

        let subscribers = 10
        for _ in 0..<subscribers {
            _ = await bus.subscribe(DemoEvent.self) { _ in
                await counter.increment()
            }
        }

        // Fire a mix of concurrent publishes. The bus serializes them
        // internally (actor) but callers issue them in parallel.
        let total = 1_000
        await withTaskGroup(of: Void.self) { group in
            for i in 0..<total {
                group.addTask {
                    await bus.publish(DemoEvent(payload: i))
                }
            }
        }

        let seen = await counter.get()
        XCTAssertEqual(seen, total * subscribers)
    }

    func testSubscriberCountReflectsSubscribeAndCancel() async {
        let bus = EventBus()
        let empty = await bus.subscriberCount(for: DemoEvent.self)
        XCTAssertEqual(empty, 0)

        let a = await bus.subscribe(DemoEvent.self) { _ in }
        let b = await bus.subscribe(DemoEvent.self) { _ in }
        let afterTwo = await bus.subscriberCount(for: DemoEvent.self)
        XCTAssertEqual(afterTwo, 2)

        await bus.cancel(a)
        let afterOneCancel = await bus.subscriberCount(for: DemoEvent.self)
        XCTAssertEqual(afterOneCancel, 1)

        await bus.cancel(b)
        let afterBothCancel = await bus.subscriberCount(for: DemoEvent.self)
        XCTAssertEqual(afterBothCancel, 0)
    }

    func testPublishWithNoSubscribersIsSafe() async {
        let bus = EventBus()
        // Must not hang, throw, or crash.
        await bus.publish(DemoEvent(payload: 0))
        let count = await bus.subscriberCount(for: DemoEvent.self)
        XCTAssertEqual(count, 0)
    }

    func testManyHandlersAllRunConcurrently() async {
        // Verify TaskGroup-based dispatch actually awaits every handler.
        let bus = EventBus()
        let counter = Counter()
        let handlerCount = 100

        for _ in 0..<handlerCount {
            _ = await bus.subscribe(DemoEvent.self) { _ in
                // Simulate async work inside the handler.
                await Task.yield()
                await counter.increment()
            }
        }

        await bus.publish(DemoEvent(payload: 1))

        let seen = await counter.get()
        XCTAssertEqual(seen, handlerCount)
    }
}
