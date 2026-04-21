// DrillingSystemTests.swift
// SDGGameplayTests
//
// Tests for `DrillingOrchestrator` (in DrillingSystem.swift). The suite
// has two tiers mirroring the orchestrator's shape:
//
//   1. `buildSampleItem` — pure, static, no RealityKit.
//   2. `performDrill`    — end-to-end integration against a real
//                          `GeologySceneBuilder.loadOutcrop` tree,
//                          asserting both the returned result and
//                          the events the orchestrator fires along
//                          the way.

import XCTest
import RealityKit
import SDGCore
@testable import SDGGameplay

@MainActor
final class DrillingSystemTests: XCTestCase {

    // MARK: - Shared fixtures

    private let origin = SIMD3<Float>(0, 0, 0)
    private let down = SIMD3<Float>(0, -1, 0)

    /// Give MainActor-bound handler continuations a turn. `publish`
    /// already awaits its handlers, but the handlers inside the
    /// orchestrator hop back onto the main actor via
    /// `await self?...`; the yield ensures that second hop completes
    /// before we assert on post-conditions.
    private func drainBus() async {
        await Task.yield()
    }

    // MARK: - buildSampleItem (pure)

    /// Three intersections must produce three records, each with the
    /// same `layerId`, `nameKey`, `colorRGB`, `thickness`,
    /// `entryDepth` as the source. Sample `drillLocation` and
    /// `drillDepth` must match the inputs verbatim.
    func testBuildSampleItemCopiesAllLayerFields() {
        let intersections = [
            LayerIntersection(
                layerId: "a",
                nameKey: "k.a",
                colorRGB: SIMD3<Float>(1, 0, 0),
                entryDepth: 0,
                exitDepth: 0.5,
                thickness: 0.5,
                entryPoint: SIMD3<Float>(0, 0, 0),
                exitPoint: SIMD3<Float>(0, -0.5, 0)
            ),
            LayerIntersection(
                layerId: "b",
                nameKey: "k.b",
                colorRGB: SIMD3<Float>(0, 1, 0),
                entryDepth: 0.5,
                exitDepth: 2.0,
                thickness: 1.5,
                entryPoint: SIMD3<Float>(0, -0.5, 0),
                exitPoint: SIMD3<Float>(0, -2.0, 0)
            ),
            LayerIntersection(
                layerId: "c",
                nameKey: "k.c",
                colorRGB: SIMD3<Float>(0, 0, 1),
                entryDepth: 2.0,
                exitDepth: 4.0,
                thickness: 2.0,
                entryPoint: SIMD3<Float>(0, -2.0, 0),
                exitPoint: SIMD3<Float>(0, -4.0, 0)
            )
        ]

        let sampleOrigin = SIMD3<Float>(10, 20, 30)
        let sample = DrillingOrchestrator.buildSampleItem(
            at: sampleOrigin,
            depth: 4.0,
            intersections: intersections
        )

        XCTAssertEqual(sample.drillLocation, sampleOrigin)
        XCTAssertEqual(sample.drillDepth, 4.0)
        XCTAssertEqual(sample.layers.count, 3)

        XCTAssertEqual(sample.layers[0].layerId, "a")
        XCTAssertEqual(sample.layers[0].nameKey, "k.a")
        XCTAssertEqual(sample.layers[0].colorRGB, SIMD3<Float>(1, 0, 0))
        XCTAssertEqual(sample.layers[0].thickness, 0.5)
        XCTAssertEqual(sample.layers[0].entryDepth, 0)

        XCTAssertEqual(sample.layers[1].layerId, "b")
        XCTAssertEqual(sample.layers[1].thickness, 1.5)
        XCTAssertEqual(sample.layers[1].entryDepth, 0.5)

        XCTAssertEqual(sample.layers[2].layerId, "c")
        XCTAssertEqual(sample.layers[2].thickness, 2.0)
        XCTAssertEqual(sample.layers[2].entryDepth, 2.0)
    }

    /// Empty intersections → empty `layers`. The sample is still
    /// legal (no crash) — the outer code path that fires
    /// `DrillFailed` takes care of not building a sample at all,
    /// but this test pins the pure function's behaviour regardless.
    func testBuildSampleItemWithEmptyIntersectionsYieldsEmptyLayers() {
        let sample = DrillingOrchestrator.buildSampleItem(
            at: .zero,
            depth: 2.0,
            intersections: []
        )
        XCTAssertEqual(sample.layers.count, 0)
        XCTAssertEqual(sample.drillDepth, 2.0)
    }

    /// Two calls must emit distinct `id` values (the function stamps
    /// a fresh UUID on every build). Guards against an accidental
    /// static id or a caching bug sneaking in later.
    func testBuildSampleItemAssignsFreshIds() {
        let intersection = LayerIntersection(
            layerId: "x", nameKey: "k", colorRGB: .zero,
            entryDepth: 0, exitDepth: 1, thickness: 1,
            entryPoint: .zero, exitPoint: .zero
        )
        let a = DrillingOrchestrator.buildSampleItem(
            at: .zero, depth: 1.0, intersections: [intersection]
        )
        let b = DrillingOrchestrator.buildSampleItem(
            at: .zero, depth: 1.0, intersections: [intersection]
        )
        XCTAssertNotEqual(a.id, b.id)
    }

    // MARK: - performDrill success

    /// Load the 4-layer `test_outcrop.json`, hand the orchestrator
    /// its root, and drill from the surface. The returned sample
    /// must carry 4 `SampleLayerRecord`s and be published on the
    /// bus via `SampleCreatedEvent` + `DrillCompleted`.
    func testPerformDrillSuccessEmitsSampleAndCompletedEvents() async throws {
        let bus = EventBus()
        let root = try GeologySceneBuilder.loadOutcrop(
            namedResource: "test_outcrop",
            in: .module
        )
        let orchestrator = DrillingOrchestrator(
            eventBus: bus,
            outcropRootProvider: { root }
        )

        // Observe both events before kicking off the drill. The
        // XCTest expectations fire at most once each — that's the
        // assertion we want.
        let sampleExp = expectation(description: "SampleCreatedEvent observed")
        let completedExp = expectation(description: "DrillCompleted observed")

        let sampleToken = await bus.subscribe(SampleCreatedEvent.self) { event in
            if event.sample.layers.count == 4 {
                sampleExp.fulfill()
            }
        }
        let completedToken = await bus.subscribe(DrillCompleted.self) { event in
            if event.layerCount == 4 {
                completedExp.fulfill()
            }
        }

        let result = await orchestrator.performDrill(
            origin: .zero,
            direction: down,
            maxDepth: 10.0
        )

        await fulfillment(of: [sampleExp, completedExp], timeout: 2.0)

        guard case let .success(sample) = result else {
            return XCTFail("expected success, got \(result)")
        }
        XCTAssertEqual(sample.layers.count, 4)
        XCTAssertEqual(
            sample.layers.map(\.layerId),
            [
                "aobayama.topsoil",
                "aobayama.aobayamafm.upper",
                "aobayama.aobayamafm.lower",
                "aobayama.basement"
            ]
        )

        await bus.cancel(sampleToken)
        await bus.cancel(completedToken)
    }

    // MARK: - performDrill failure: scene unavailable

    func testPerformDrillWithNilProviderFailsSceneUnavailable() async {
        let bus = EventBus()
        let orchestrator = DrillingOrchestrator(
            eventBus: bus,
            outcropRootProvider: { nil }
        )

        let failedExp = expectation(description: "DrillFailed observed")
        let token = await bus.subscribe(DrillFailed.self) { event in
            if event.reason == "scene_unavailable" {
                failedExp.fulfill()
            }
        }

        let result = await orchestrator.performDrill(
            origin: origin,
            direction: down,
            maxDepth: 5.0
        )

        await fulfillment(of: [failedExp], timeout: 1.0)

        guard case .failure(.sceneUnavailable) = result else {
            return XCTFail("expected .sceneUnavailable, got \(result)")
        }

        await bus.cancel(token)
    }

    // MARK: - performDrill failure: no layers

    /// Hand the orchestrator a bare `Entity()` tree — no geology
    /// descendants. Detection returns empty; orchestrator must
    /// publish `DrillFailed(reason: "no_layers")` and report
    /// `.noLayers`. It must NOT publish `SampleCreatedEvent` or
    /// `DrillCompleted` in this path.
    func testPerformDrillWithEmptyTreeFailsNoLayers() async {
        let bus = EventBus()
        let bareRoot = Entity()
        let orchestrator = DrillingOrchestrator(
            eventBus: bus,
            outcropRootProvider: { bareRoot }
        )

        let failedExp = expectation(description: "DrillFailed observed")
        let failedToken = await bus.subscribe(DrillFailed.self) { event in
            if event.reason == "no_layers" {
                failedExp.fulfill()
            }
        }

        // Also subscribe to SampleCreatedEvent / DrillCompleted and
        // assert they are NOT fired. An XCTestExpectation with
        // `isInverted = true` is XCTest's canonical "this must not
        // happen" check; fulfillment(timeout:) then waits the
        // timeout out to confirm silence.
        let silenceSample = expectation(description: "no SampleCreatedEvent")
        silenceSample.isInverted = true
        let silenceCompleted = expectation(description: "no DrillCompleted")
        silenceCompleted.isInverted = true

        let sampleToken = await bus.subscribe(SampleCreatedEvent.self) { _ in
            silenceSample.fulfill()
        }
        let completedToken = await bus.subscribe(DrillCompleted.self) { _ in
            silenceCompleted.fulfill()
        }

        let result = await orchestrator.performDrill(
            origin: origin,
            direction: down,
            maxDepth: 5.0
        )

        await fulfillment(
            of: [failedExp, silenceSample, silenceCompleted],
            timeout: 0.5
        )

        guard case .failure(.noLayers) = result else {
            return XCTFail("expected .noLayers, got \(result)")
        }

        await bus.cancel(failedToken)
        await bus.cancel(sampleToken)
        await bus.cancel(completedToken)
    }

    // MARK: - start() wires DrillRequested → performDrill

    /// After `start()`, publishing `DrillRequested` on the bus must
    /// drive a full drill pass. Confirms the subscribe wiring.
    func testStartSubscribesToDrillRequested() async throws {
        let bus = EventBus()
        let root = try GeologySceneBuilder.loadOutcrop(
            namedResource: "test_outcrop",
            in: .module
        )
        let orchestrator = DrillingOrchestrator(
            eventBus: bus,
            outcropRootProvider: { root }
        )
        await orchestrator.start()

        let sampleExp = expectation(description: "SampleCreatedEvent observed")
        let token = await bus.subscribe(SampleCreatedEvent.self) { event in
            if event.sample.layers.count == 4 {
                sampleExp.fulfill()
            }
        }

        await bus.publish(
            DrillRequested(
                origin: .zero,
                direction: down,
                maxDepth: 10.0,
                requestedAt: Date()
            )
        )

        await fulfillment(of: [sampleExp], timeout: 2.0)

        await bus.cancel(token)
        await orchestrator.stop()
    }

    func testStopDetachesDrillRequestedSubscription() async {
        let bus = EventBus()
        let orchestrator = DrillingOrchestrator(
            eventBus: bus,
            outcropRootProvider: { nil }
        )
        await orchestrator.start()
        await orchestrator.stop()

        let count = await bus.subscriberCount(for: DrillRequested.self)
        XCTAssertEqual(count, 0)
    }

    func testStartIsIdempotent() async {
        let bus = EventBus()
        let orchestrator = DrillingOrchestrator(
            eventBus: bus,
            outcropRootProvider: { nil }
        )
        await orchestrator.start()
        await orchestrator.start()

        let count = await bus.subscriberCount(for: DrillRequested.self)
        XCTAssertEqual(count, 1)
        await orchestrator.stop()
    }
}
