// GeologyDetectionTests.swift
// Tests for the Phase 1 drilling-time layer detector.
//
// The tests are split into two tiers:
//
//   * **Pure algorithm** — exercises `computeIntersections(...)` over
//     hand-built `LayerSlab` arrays. No RealityKit required, fast,
//     deterministic, and headless-safe for CI. This is where the bulk
//     of the coverage lives.
//   * **Entity-tree integration** — feeds the real `GeologySceneBuilder`
//     output into `detectLayers(under:...)` and asserts the contract
//     against `test_outcrop.json`. Confirms the `visualBounds` bridge
//     from entity → slab preserves layer identity and geometry.

import XCTest
import RealityKit
@testable import SDGGameplay

final class GeologyDetectionTests: XCTestCase {

    // MARK: - Fixtures

    /// Build a four-layer slab stack that matches the POC outcrop
    /// geometry: topsoil (0.5 m), upper aobayamafm (1.5 m), lower
    /// aobayamafm (2.0 m), basement (3.0 m). Total 7 m, top at y = 0.
    ///
    /// Colours use distinct primaries so tests can also assert the
    /// per-layer forward of `colorRGB` to the intersection.
    private func makePOCSlabs() -> [LayerSlab] {
        [
            LayerSlab(
                layerId: "aobayama.topsoil",
                nameKey: "geology.layer.topsoil.name",
                colorRGB: SIMD3<Float>(1, 0, 0),
                topY: 0.0,
                bottomY: -0.5,
                xzCenter: .zero
            ),
            LayerSlab(
                layerId: "aobayama.aobayamafm.upper",
                nameKey: "geology.layer.aobayamafm.upper.name",
                colorRGB: SIMD3<Float>(0, 1, 0),
                topY: -0.5,
                bottomY: -2.0,
                xzCenter: .zero
            ),
            LayerSlab(
                layerId: "aobayama.aobayamafm.lower",
                nameKey: "geology.layer.aobayamafm.lower.name",
                colorRGB: SIMD3<Float>(0, 0, 1),
                topY: -2.0,
                bottomY: -4.0,
                xzCenter: .zero
            ),
            LayerSlab(
                layerId: "aobayama.basement",
                nameKey: "geology.layer.basement.name",
                colorRGB: SIMD3<Float>(1, 1, 0),
                topY: -4.0,
                bottomY: -7.0,
                xzCenter: .zero
            )
        ]
    }

    private static let down: SIMD3<Float> = [0, -1, 0]

    // MARK: - Pure algorithm: headline scenario

    /// Origin sits 0.25 m below the surface (inside topsoil); maxDepth
    /// 5 m. Ray spans world-Y [-5.25, -0.25]. Expected contributions:
    ///   topsoil   0.00 → 0.25  (t=0.25)  entry clamped to origin
    ///   upper     0.25 → 1.75  (t=1.50)  full slab (y -0.5 … -2.0)
    ///   lower     1.75 → 3.75  (t=2.00)  full slab (y -2.0 … -4.0)
    ///   basement  3.75 → 5.00  (t=1.25)  exit clamped to maxDepth
    func testOriginInsideTopLayerMaxDepthFive() {
        let slabs = makePOCSlabs()
        let origin = SIMD3<Float>(0, -0.25, 0)

        let hits = GeologyDetectionSystem.computeIntersections(
            from: origin,
            direction: Self.down,
            maxDepth: 5.0,
            layers: slabs
        )

        XCTAssertEqual(hits.count, 4)

        assertHit(
            hits[0],
            id: "aobayama.topsoil",
            entry: 0.0,
            exit: 0.25,
            thickness: 0.25
        )
        assertHit(
            hits[1],
            id: "aobayama.aobayamafm.upper",
            entry: 0.25,
            exit: 1.75,
            thickness: 1.50
        )
        assertHit(
            hits[2],
            id: "aobayama.aobayamafm.lower",
            entry: 1.75,
            exit: 3.75,
            thickness: 2.00
        )
        assertHit(
            hits[3],
            id: "aobayama.basement",
            entry: 3.75,
            exit: 5.00,
            thickness: 1.25
        )
    }

    // MARK: - Pure algorithm: full-stack traversal

    /// Origin at the outcrop surface, maxDepth large enough to pass
    /// through the 7 m stack entirely. All four layers should come
    /// back with their full native thickness.
    func testFullStackWithLargeMaxDepth() {
        let slabs = makePOCSlabs()
        let hits = GeologyDetectionSystem.computeIntersections(
            from: .zero,
            direction: Self.down,
            maxDepth: 20.0,
            layers: slabs
        )

        XCTAssertEqual(hits.count, 4)

        // Cumulative depth check: each hit must start exactly where
        // the previous one ended.
        var runningDepth: Float = 0
        let nativeThicknesses: [Float] = [0.5, 1.5, 2.0, 3.0]
        for (i, hit) in hits.enumerated() {
            XCTAssertEqual(hit.entryDepth, runningDepth, accuracy: 1e-5)
            XCTAssertEqual(
                hit.thickness,
                nativeThicknesses[i],
                accuracy: 1e-5
            )
            runningDepth += nativeThicknesses[i]
            XCTAssertEqual(hit.exitDepth, runningDepth, accuracy: 1e-5)
        }
    }

    // MARK: - Pure algorithm: origin inside second layer

    /// Origin sits half a metre into the *upper* aobayamafm (1 m below
    /// the surface). The topsoil should be entirely skipped, and only
    /// the remaining three layers contribute.
    func testOriginInsideSecondLayerSkipsFirst() {
        let slabs = makePOCSlabs()
        let origin = SIMD3<Float>(0, -1.0, 0)

        let hits = GeologyDetectionSystem.computeIntersections(
            from: origin,
            direction: Self.down,
            maxDepth: 10.0,
            layers: slabs
        )

        XCTAssertEqual(hits.count, 3)
        XCTAssertEqual(hits[0].layerId, "aobayama.aobayamafm.upper")
        XCTAssertEqual(hits[1].layerId, "aobayama.aobayamafm.lower")
        XCTAssertEqual(hits[2].layerId, "aobayama.basement")

        // First hit starts at the drill head (depth 0) since we are
        // already inside the upper layer; it extends to the layer's
        // bottom (1 m further down from y = -1, so depth = 1).
        XCTAssertEqual(hits[0].entryDepth, 0.0, accuracy: 1e-5)
        XCTAssertEqual(hits[0].exitDepth, 1.0, accuracy: 1e-5)
    }

    // MARK: - Pure algorithm: degenerate cases

    /// maxDepth = 0 produces the empty result without any allocation
    /// or sort work. Important because UI code may pass 0 during
    /// "preview" hovers.
    func testZeroMaxDepthReturnsEmpty() {
        let hits = GeologyDetectionSystem.computeIntersections(
            from: .zero,
            direction: Self.down,
            maxDepth: 0.0,
            layers: makePOCSlabs()
        )
        XCTAssertEqual(hits.count, 0)
    }

    /// Negative maxDepth is defensive nonsense — also empty.
    func testNegativeMaxDepthReturnsEmpty() {
        let hits = GeologyDetectionSystem.computeIntersections(
            from: .zero,
            direction: Self.down,
            maxDepth: -1.0,
            layers: makePOCSlabs()
        )
        XCTAssertEqual(hits.count, 0)
    }

    /// No slabs = no intersections, regardless of depth.
    func testEmptyLayersReturnsEmpty() {
        let hits = GeologyDetectionSystem.computeIntersections(
            from: .zero,
            direction: Self.down,
            maxDepth: 10.0,
            layers: []
        )
        XCTAssertEqual(hits.count, 0)
    }

    /// A paper-thin layer (topY - bottomY = 0.005 m, below the 1 cm
    /// threshold) must be silently dropped. Keeps the output free of
    /// floating-point crumbs left by clipping arithmetic.
    func testLayersThinnerThanThresholdAreFiltered() {
        let slabs = [
            LayerSlab(
                layerId: "crumb",
                nameKey: "k",
                colorRGB: .zero,
                topY: 0.0,
                bottomY: -0.005,
                xzCenter: .zero
            ),
            LayerSlab(
                layerId: "real",
                nameKey: "k2",
                colorRGB: .zero,
                topY: -0.005,
                bottomY: -1.0,
                xzCenter: .zero
            )
        ]
        let hits = GeologyDetectionSystem.computeIntersections(
            from: .zero,
            direction: Self.down,
            maxDepth: 5.0,
            layers: slabs
        )
        XCTAssertEqual(hits.count, 1)
        XCTAssertEqual(hits[0].layerId, "real")
    }

    /// Origin below every layer means nothing is ever entered on a
    /// downward drill. Empty result.
    func testOriginBelowAllLayersReturnsEmpty() {
        let slabs = makePOCSlabs()  // bottom at -7
        let origin = SIMD3<Float>(0, -20.0, 0)

        let hits = GeologyDetectionSystem.computeIntersections(
            from: origin,
            direction: Self.down,
            maxDepth: 10.0,
            layers: slabs
        )
        XCTAssertEqual(hits.count, 0)
    }

    // MARK: - Pure algorithm: unsorted input

    /// Feeding the slabs in reverse (deep-first) must not perturb the
    /// output ordering — the detector has to sort internally. Covers
    /// the implicit contract that callers can hand slabs over in any
    /// order.
    func testUnsortedInputIsNormalised() {
        let hits = GeologyDetectionSystem.computeIntersections(
            from: .zero,
            direction: Self.down,
            maxDepth: 20.0,
            layers: makePOCSlabs().reversed()
        )

        XCTAssertEqual(hits.map(\.layerId), [
            "aobayama.topsoil",
            "aobayama.aobayamafm.upper",
            "aobayama.aobayamafm.lower",
            "aobayama.basement"
        ])
    }

    // MARK: - Pure algorithm: output fields

    /// `entryPoint` and `exitPoint` must equal
    /// `origin + direction * depth`. Sanity check for future code that
    /// wants to use these fields to place icons / VFX.
    func testEntryExitPointsFollowRayParametrically() {
        let slabs = makePOCSlabs()
        let origin = SIMD3<Float>(5, 10, -3)
        let direction = SIMD3<Float>(0, -1, 0)
        let hits = GeologyDetectionSystem.computeIntersections(
            from: origin,
            direction: direction,
            maxDepth: 20.0,
            layers: slabs
        )

        for hit in hits {
            let expectedEntry = origin + direction * hit.entryDepth
            let expectedExit = origin + direction * hit.exitDepth
            XCTAssertEqual(hit.entryPoint.x, expectedEntry.x, accuracy: 1e-5)
            XCTAssertEqual(hit.entryPoint.y, expectedEntry.y, accuracy: 1e-5)
            XCTAssertEqual(hit.entryPoint.z, expectedEntry.z, accuracy: 1e-5)
            XCTAssertEqual(hit.exitPoint.x, expectedExit.x, accuracy: 1e-5)
            XCTAssertEqual(hit.exitPoint.y, expectedExit.y, accuracy: 1e-5)
            XCTAssertEqual(hit.exitPoint.z, expectedExit.z, accuracy: 1e-5)
        }
    }

    /// `centerPoint` must be the arithmetic mean of entry and exit.
    /// Not a deep invariant — the implementation is a one-liner — but
    /// cheap to pin and the UI code depends on it.
    func testCenterPointIsMidpoint() {
        let hit = LayerIntersection(
            layerId: "x",
            nameKey: "k",
            colorRGB: .zero,
            entryDepth: 1,
            exitDepth: 3,
            thickness: 2,
            entryPoint: SIMD3<Float>(0, 10, 0),
            exitPoint: SIMD3<Float>(0, 8, 0)
        )
        XCTAssertEqual(hit.centerPoint, SIMD3<Float>(0, 9, 0))
    }

    /// `isValid` must agree with the detector's own threshold.
    func testIsValidThreshold() {
        let below = LayerIntersection(
            layerId: "x", nameKey: "k", colorRGB: .zero,
            entryDepth: 0, exitDepth: 0.005, thickness: 0.005,
            entryPoint: .zero, exitPoint: .zero
        )
        let above = LayerIntersection(
            layerId: "x", nameKey: "k", colorRGB: .zero,
            entryDepth: 0, exitDepth: 0.02, thickness: 0.02,
            entryPoint: .zero, exitPoint: .zero
        )
        XCTAssertFalse(below.isValid)
        XCTAssertTrue(above.isValid)
    }

    // MARK: - Pure algorithm: forwarding of metadata

    /// The detector must copy `nameKey` and `colorRGB` verbatim from
    /// the input `LayerSlab` to the output `LayerIntersection`.
    /// Downstream consumers (HUD, encyclopedia) trust these fields to
    /// not silently mutate.
    func testMetadataIsForwardedVerbatim() {
        let slab = LayerSlab(
            layerId: "only",
            nameKey: "my.name.key",
            colorRGB: SIMD3<Float>(0.1, 0.2, 0.3),
            topY: 0.0,
            bottomY: -2.0,
            xzCenter: .zero
        )
        let hits = GeologyDetectionSystem.computeIntersections(
            from: .zero,
            direction: Self.down,
            maxDepth: 5.0,
            layers: [slab]
        )
        XCTAssertEqual(hits.count, 1)
        XCTAssertEqual(hits[0].nameKey, "my.name.key")
        XCTAssertEqual(hits[0].colorRGB, SIMD3<Float>(0.1, 0.2, 0.3))
    }

    // MARK: - Entity-tree integration

    /// Feed the real `GeologySceneBuilder` output into
    /// `detectLayers(under:...)`. With origin at the outcrop surface
    /// (y = 0) and maxDepth 10 m, all four layers must come back with
    /// their full native thicknesses, layer ids matching
    /// `test_outcrop.json`.
    @MainActor
    func testDetectLayersUnderBuilderRoot() throws {
        let root = try GeologySceneBuilder.loadOutcrop(
            namedResource: "test_outcrop",
            in: .module
        )

        let hits = GeologyDetectionSystem.detectLayers(
            under: root,
            from: .zero,
            direction: Self.down,
            maxDepth: 10.0
        )

        XCTAssertEqual(hits.count, 4)

        let expectedIds = [
            "aobayama.topsoil",
            "aobayama.aobayamafm.upper",
            "aobayama.aobayamafm.lower",
            "aobayama.basement"
        ]
        XCTAssertEqual(hits.map(\.layerId), expectedIds)

        // Thicknesses from test_outcrop.json.
        let expectedThicknesses: [Float] = [0.5, 1.5, 2.0, 3.0]
        for (i, hit) in hits.enumerated() {
            XCTAssertEqual(
                hit.thickness,
                expectedThicknesses[i],
                accuracy: 1e-4,
                "layer \(i) thickness drift"
            )
        }
    }

    /// Same builder, drilling from the surface, but this time we pin
    /// the topsoil colour. Confirms the bridge from
    /// `GeologyLayerComponent.colorRGB` through `makeSlab` to
    /// `LayerIntersection.colorRGB`.
    @MainActor
    func testDetectLayersForwardsComponentColor() throws {
        let root = try GeologySceneBuilder.loadOutcrop(
            namedResource: "test_outcrop",
            in: .module
        )

        let hits = GeologyDetectionSystem.detectLayers(
            under: root,
            from: .zero,
            direction: Self.down,
            maxDepth: 10.0
        )
        let topsoil = try XCTUnwrap(hits.first)

        // #6B4226 → (0x6B/255, 0x42/255, 0x26/255)
        XCTAssertEqual(topsoil.colorRGB.x, Float(0x6B) / 255.0, accuracy: 1e-5)
        XCTAssertEqual(topsoil.colorRGB.y, Float(0x42) / 255.0, accuracy: 1e-5)
        XCTAssertEqual(topsoil.colorRGB.z, Float(0x26) / 255.0, accuracy: 1e-5)
    }

    /// `detectLayers(under:)` with a root that has no geology
    /// descendants must return an empty array, not throw.
    @MainActor
    func testDetectLayersEmptyTreeReturnsEmpty() {
        let bareRoot = Entity()
        let hits = GeologyDetectionSystem.detectLayers(
            under: bareRoot,
            from: .zero,
            maxDepth: 10.0
        )
        XCTAssertEqual(hits.count, 0)
    }

    // MARK: - Helpers

    /// Shared assertion: `hit` matches the expected layer id, entry,
    /// exit, and thickness. Collapses the four XCTAssertEquals that
    /// otherwise repeat everywhere; failure messages stay precise
    /// because `accuracy` lets tolerance float with input magnitude.
    private func assertHit(
        _ hit: LayerIntersection,
        id: String,
        entry: Float,
        exit: Float,
        thickness: Float,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertEqual(hit.layerId, id, file: file, line: line)
        XCTAssertEqual(
            hit.entryDepth, entry, accuracy: 1e-4,
            "entryDepth", file: file, line: line
        )
        XCTAssertEqual(
            hit.exitDepth, exit, accuracy: 1e-4,
            "exitDepth", file: file, line: line
        )
        XCTAssertEqual(
            hit.thickness, thickness, accuracy: 1e-4,
            "thickness", file: file, line: line
        )
    }
}
