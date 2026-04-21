// PlayerControlStoreTests.swift
// Unit tests for `PlayerControlStore`: Intent → state mutation, event
// publication, and entity-bridge write-through.
//
// Every test spins up a fresh `EventBus` + `PlayerControlStore` pair
// so state cannot leak between cases.

import XCTest
import RealityKit
import SDGCore
@testable import SDGGameplay

@MainActor
final class PlayerControlStoreTests: XCTestCase {

    // MARK: - Fixtures

    private var bus: EventBus!
    private var store: PlayerControlStore!

    /// Register the ECS component types once per test process. RealityKit
    /// no-ops on repeat registration, so this is cheap and idempotent.
    override class func setUp() {
        super.setUp()
        PlayerComponent.registerComponent()
        PlayerInputComponent.registerComponent()
    }

    override func setUp() async throws {
        try await super.setUp()
        bus = EventBus()
        store = PlayerControlStore(eventBus: bus)
    }

    override func tearDown() async throws {
        store = nil
        bus = nil
        try await super.tearDown()
    }

    // MARK: - State mutation

    /// `.move(axis)` must update `currentMoveAxis` exactly to the
    /// value the Store was handed — the Store does NOT re-clamp or
    /// dead-zone, those are HUD concerns.
    func testMoveIntentUpdatesState() async {
        await store.intent(.move(SIMD2(0.3, -0.7)))
        XCTAssertEqual(store.currentMoveAxis, SIMD2(0.3, -0.7))
    }

    /// `.stop` is semantically "stick released"; state must return to
    /// zero regardless of the prior value.
    func testStopIntentZeroesMove() async {
        await store.intent(.move(SIMD2(1, 1)))
        await store.intent(.stop)
        XCTAssertEqual(store.currentMoveAxis, .zero)
    }

    /// `.look(delta)` must *accumulate* deltas, not replace them. Two
    /// consecutive drags of 0.1 rad each should yield 0.2 rad pending.
    func testLookIntentsAccumulate() async {
        await store.intent(.look(SIMD2(0.1, -0.05)))
        await store.intent(.look(SIMD2(0.1, 0.05)))
        XCTAssertEqual(store.pendingLookDelta, SIMD2(0.2, 0.0),
                       "look deltas must sum, not replace")
    }

    // MARK: - Event publication

    /// A `.move` whose value *changed* must publish
    /// `PlayerMoveIntentChanged`. Idempotent re-sends must NOT publish.
    func testChangingMoveAxisPublishesEvent() async {
        let exp = expectation(description: "event observed")

        // Retain the subscription; the handler fires off-actor.
        let token = await bus.subscribe(PlayerMoveIntentChanged.self) { event in
            if event.axis == SIMD2<Float>(0.5, 0.5) {
                exp.fulfill()
            }
        }

        await store.intent(.move(SIMD2(0.5, 0.5)))
        await fulfillment(of: [exp], timeout: 1.0)

        await bus.cancel(token)
    }

    /// Re-sending the exact same axis must not spam the bus.
    /// Verifies the Store's de-dupe guard.
    func testIdempotentMoveIntentDoesNotRepublish() async {
        let counter = EventCounter<PlayerMoveIntentChanged>()
        let token = await bus.subscribe(PlayerMoveIntentChanged.self) { event in
            await counter.record(event)
        }

        await store.intent(.move(SIMD2(0.2, 0.2)))
        await store.intent(.move(SIMD2(0.2, 0.2)))
        await store.intent(.move(SIMD2(0.2, 0.2)))

        // Give handler tasks a chance to drain. The bus awaits all
        // handlers inside `publish`, so after `await intent(...)`
        // returns the count is already authoritative, but we yield
        // once more for safety on slow CI.
        await Task.yield()

        let count = await counter.count
        XCTAssertEqual(count, 1,
                       "duplicate .move with same axis must not republish")

        await bus.cancel(token)
    }

    // MARK: - Entity bridge

    /// After `attach`, `.move` must mirror the axis into the
    /// `PlayerInputComponent` on the target entity.
    func testMoveIntentWritesIntoEntityComponent() async {
        let entity = makePlayerEntity()
        store.attach(playerEntity: entity)

        await store.intent(.move(SIMD2(0.4, -0.6)))

        guard let input = entity.components[PlayerInputComponent.self] else {
            return XCTFail("PlayerInputComponent missing after attach")
        }
        XCTAssertEqual(input.moveAxis, SIMD2(0.4, -0.6))
    }

    /// After `attach`, `.look` deltas must accumulate in the entity
    /// component just like they accumulate in the Store.
    func testLookIntentAccumulatesIntoEntityComponent() async {
        let entity = makePlayerEntity()
        store.attach(playerEntity: entity)

        await store.intent(.look(SIMD2(0.1, 0.05)))
        await store.intent(.look(SIMD2(0.1, 0.05)))

        guard let input = entity.components[PlayerInputComponent.self] else {
            return XCTFail("PlayerInputComponent missing after attach")
        }
        XCTAssertEqual(input.lookDelta, SIMD2(0.2, 0.1),
                       accuracy: 1e-6)
    }

    /// After `detach`, subsequent intents must still update the
    /// Store's own state (so the HUD joystick view keeps working) but
    /// must NOT touch the formerly-attached entity.
    func testDetachStopsEntityMirroring() async {
        let entity = makePlayerEntity()
        store.attach(playerEntity: entity)

        await store.intent(.move(SIMD2(0.9, 0.1)))
        store.detach()
        await store.intent(.move(SIMD2(-1.0, 0.0)))

        XCTAssertEqual(store.currentMoveAxis, SIMD2(-1.0, 0.0),
                       "store state must update regardless of attach")

        guard let input = entity.components[PlayerInputComponent.self] else {
            return XCTFail("component should still exist from first mirror")
        }
        XCTAssertEqual(input.moveAxis, SIMD2(0.9, 0.1),
                       "entity must retain the last pre-detach value")
    }

    // MARK: - Helpers

    /// Build an entity with the two player components pre-installed,
    /// matching what `RootView` does at scene build time.
    private func makePlayerEntity() -> Entity {
        let entity = Entity()
        entity.components.set(PlayerComponent())
        entity.components.set(PlayerInputComponent())
        return entity
    }
}

// MARK: - Support

/// Tiny actor-isolated counter we can hand off to an `@Sendable`
/// handler. Keeps tests clean without resorting to `@unchecked Sendable`.
private actor EventCounter<E: Sendable> {
    private(set) var count = 0

    func record(_ event: E) {
        count += 1
    }
}

/// XCTest only accepts `XCTAssertEqual(_:_:accuracy:)` for scalar
/// `FloatingPoint`; this helper extends it to `SIMD2<Float>` so tests
/// can assert element-wise with a shared tolerance.
private func XCTAssertEqual(
    _ lhs: SIMD2<Float>,
    _ rhs: SIMD2<Float>,
    accuracy: Float,
    file: StaticString = #file,
    line: UInt = #line
) {
    XCTAssertEqual(lhs.x, rhs.x, accuracy: accuracy, file: file, line: line)
    XCTAssertEqual(lhs.y, rhs.y, accuracy: accuracy, file: file, line: line)
}
