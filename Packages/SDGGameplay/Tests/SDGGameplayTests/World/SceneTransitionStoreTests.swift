// SceneTransitionStoreTests.swift
// SDGGameplayTests · World
//
// Phase 9 Part F — state-machine contract for `SceneTransitionStore`.
// No scene graph: we construct the Store, drive it with intents, and
// assert on `currentLocation`, `isTransitioning`, and the
// `SceneTransitionStarted` / `SceneTransitionEnded` events it
// publishes.
//
// Covers:
//   * initial state is outdoor, not transitioning
//   * direct `.requestTransition` flips state + publishes both events
//   * direct `.requestTransition` to the current location is a no-op
//     (idempotence — matters for `.requestTransition` callers that
//     don't want their scripted jump replayed)
//   * `.tickProximity` fires when a portal is inside the trigger
//     radius and its target differs from current location
//   * `.tickProximity` does NOT fire when target equals current
//     location (prevents the back-and-forth loop at the outdoor frame)
//   * the one-frame debounce: the tick immediately after a committed
//     transition does not re-fire, even if the player is still inside
//     the portal's radius
//   * distance gate: out-of-range portals do not trigger
//   * resetForTesting returns to outdoor without publishing

import XCTest
import SDGCore
@testable import SDGGameplay

@MainActor
final class SceneTransitionStoreTests: XCTestCase {

    private var bus: EventBus!
    private var store: SceneTransitionStore!

    override func setUp() async throws {
        try await super.setUp()
        bus = EventBus()
        store = SceneTransitionStore(eventBus: bus)
    }

    override func tearDown() async throws {
        store = nil
        bus = nil
        try await super.tearDown()
    }

    /// Two yields so MainActor.run continuations in bus handlers land.
    private func drainBus() async {
        await Task.yield()
        await Task.yield()
    }

    // MARK: - Initial state

    func testInitialStateIsOutdoorAndNotTransitioning() {
        XCTAssertEqual(store.currentLocation, .outdoor)
        XCTAssertFalse(store.isTransitioning)
    }

    // MARK: - Direct transition

    func testRequestTransitionFlipsStateAndPublishesBothEvents() async {
        let startedRecorder = EventRecorder<SceneTransitionStarted>()
        let endedRecorder = EventRecorder<SceneTransitionEnded>()
        let t1 = await bus.subscribe(SceneTransitionStarted.self) { event in
            await startedRecorder.record(event)
        }
        let t2 = await bus.subscribe(SceneTransitionEnded.self) { event in
            await endedRecorder.record(event)
        }

        let target = LocationKind.indoor(sceneId: "lab")
        let spawn = SIMD3<Float>(1, 2, 3)
        await store.intent(.requestTransition(to: target, spawnPoint: spawn))
        await drainBus()

        XCTAssertEqual(store.currentLocation, target)
        XCTAssertTrue(store.isTransitioning)

        let started = await startedRecorder.all
        let ended = await endedRecorder.all
        XCTAssertEqual(started.count, 1)
        XCTAssertEqual(ended.count, 1)
        XCTAssertEqual(started.first?.from, .outdoor)
        XCTAssertEqual(started.first?.to, target)
        XCTAssertEqual(started.first?.spawnPoint, spawn)
        XCTAssertEqual(ended.first?.at, target)

        await bus.cancel(t1)
        await bus.cancel(t2)
    }

    func testRequestTransitionToCurrentLocationIsNoOp() async {
        let recorder = EventRecorder<SceneTransitionStarted>()
        let token = await bus.subscribe(SceneTransitionStarted.self) { event in
            await recorder.record(event)
        }

        await store.intent(.requestTransition(
            to: .outdoor,
            spawnPoint: .zero
        ))
        await drainBus()

        XCTAssertEqual(store.currentLocation, .outdoor)
        XCTAssertFalse(store.isTransitioning)
        let events = await recorder.all
        XCTAssertTrue(events.isEmpty)

        await bus.cancel(token)
    }

    // MARK: - Proximity

    func testProximityFiresWhenInsideRadius() async {
        let recorder = EventRecorder<SceneTransitionStarted>()
        let token = await bus.subscribe(SceneTransitionStarted.self) { event in
            await recorder.record(event)
        }

        let portal = PortalProximitySnapshot(
            position: SIMD3<Float>(0, 0, 0),
            transition: LocationTransitionComponent(
                targetScene: .indoor(sceneId: "lab"),
                spawnPointInTarget: SIMD3<Float>(0, 0.1, 0)
            )
        )
        // Player sits 1 m from the portal — well inside the 2 m radius.
        await store.intent(.tickProximity(
            playerPosition: SIMD3<Float>(1, 0, 0),
            portals: [portal]
        ))
        await drainBus()

        XCTAssertEqual(
            store.currentLocation,
            .indoor(sceneId: "lab")
        )
        let events = await recorder.all
        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events.first?.to, .indoor(sceneId: "lab"))

        await bus.cancel(token)
    }

    func testProximityIgnoresSameTargetAsCurrent() async {
        let recorder = EventRecorder<SceneTransitionStarted>()
        let token = await bus.subscribe(SceneTransitionStarted.self) { event in
            await recorder.record(event)
        }

        let portal = PortalProximitySnapshot(
            position: SIMD3<Float>(0, 0, 0),
            transition: LocationTransitionComponent(
                targetScene: .outdoor,   // same as current
                spawnPointInTarget: .zero
            )
        )
        await store.intent(.tickProximity(
            playerPosition: .zero,
            portals: [portal]
        ))
        await drainBus()

        XCTAssertEqual(store.currentLocation, .outdoor)
        let events = await recorder.all
        XCTAssertTrue(events.isEmpty)

        await bus.cancel(token)
    }

    func testProximityIgnoresOutOfRange() async {
        let recorder = EventRecorder<SceneTransitionStarted>()
        let token = await bus.subscribe(SceneTransitionStarted.self) { event in
            await recorder.record(event)
        }

        let portal = PortalProximitySnapshot(
            position: SIMD3<Float>(0, 0, 0),
            transition: LocationTransitionComponent(
                targetScene: .indoor(sceneId: "lab"),
                spawnPointInTarget: .zero
            )
        )
        // 10 m away > 2 m trigger radius.
        await store.intent(.tickProximity(
            playerPosition: SIMD3<Float>(10, 0, 0),
            portals: [portal]
        ))
        await drainBus()

        XCTAssertEqual(store.currentLocation, .outdoor)
        let events = await recorder.all
        XCTAssertTrue(events.isEmpty)

        await bus.cancel(token)
    }

    func testProximityDebouncesImmediatelyAfterTransition() async {
        let recorder = EventRecorder<SceneTransitionStarted>()
        let token = await bus.subscribe(SceneTransitionStarted.self) { event in
            await recorder.record(event)
        }

        let outdoorPortal = PortalProximitySnapshot(
            position: SIMD3<Float>(0, 0, 0),
            transition: LocationTransitionComponent(
                targetScene: .indoor(sceneId: "lab"),
                spawnPointInTarget: SIMD3<Float>(0, 0.1, 0)
            )
        )

        // Frame 1: player inside outdoor portal → transitions to lab.
        await store.intent(.tickProximity(
            playerPosition: SIMD3<Float>(0.5, 0, 0),
            portals: [outdoorPortal]
        ))
        await drainBus()
        XCTAssertEqual(store.currentLocation, .indoor(sceneId: "lab"))
        XCTAssertTrue(store.isTransitioning)

        // Frame 2: same portal list, player still inside radius. The
        // debounce must swallow this tick — no new transition.
        await store.intent(.tickProximity(
            playerPosition: SIMD3<Float>(0.5, 0, 0),
            portals: [outdoorPortal]
        ))
        await drainBus()
        XCTAssertFalse(store.isTransitioning)
        let events = await recorder.all
        XCTAssertEqual(events.count, 1)

        await bus.cancel(token)
    }

    func testProximityFiresAgainAfterDebounceGrace() async {
        // Once the debounce tick has drained, the next qualifying
        // proximity snapshot fires normally. Cover with a portal
        // heading back to outdoor after we're indoors.
        await store.intent(.requestTransition(
            to: .indoor(sceneId: "lab"),
            spawnPoint: .zero
        ))
        await drainBus()
        XCTAssertEqual(store.currentLocation, .indoor(sceneId: "lab"))
        XCTAssertTrue(store.isTransitioning)

        // Grace tick: no portal qualifying, but the flag clears.
        await store.intent(.tickProximity(
            playerPosition: .zero,
            portals: []
        ))
        XCTAssertFalse(store.isTransitioning)

        // Now a portal back to outdoor should fire.
        let indoorPortal = PortalProximitySnapshot(
            position: .zero,
            transition: LocationTransitionComponent(
                targetScene: .outdoor,
                spawnPointInTarget: SIMD3<Float>(5, 0, 5)
            )
        )
        await store.intent(.tickProximity(
            playerPosition: .zero,
            portals: [indoorPortal]
        ))
        await drainBus()
        XCTAssertEqual(store.currentLocation, .outdoor)
    }

    // MARK: - Reset

    func testResetReturnsToOutdoorWithoutPublishing() async {
        await store.intent(.requestTransition(
            to: .indoor(sceneId: "lab"),
            spawnPoint: .zero
        ))
        await drainBus()

        let recorder = EventRecorder<SceneTransitionStarted>()
        let token = await bus.subscribe(SceneTransitionStarted.self) { event in
            await recorder.record(event)
        }

        await store.intent(.resetForTesting)
        await drainBus()

        XCTAssertEqual(store.currentLocation, .outdoor)
        XCTAssertFalse(store.isTransitioning)
        let events = await recorder.all
        XCTAssertTrue(events.isEmpty)

        await bus.cancel(token)
    }
}

// MARK: - Event recorder (local copy, per convention in sibling tests)

private actor EventRecorder<E: Sendable> {
    private var events: [E] = []

    func record(_ event: E) {
        events.append(event)
    }

    var all: [E] { events }
}
