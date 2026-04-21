// StackedCylinderMeshBuilderTests.swift
// SDGGameplay · Samples · Tests
//
// Unit tests for the Phase 1 stacked-cylinder mesh builder. Cover
// single-segment geometry, batch offset arithmetic, empty-input
// behaviour, and the defensive clamping that keeps degenerate inputs
// from crashing RealityKit's primitive generator.
//
// Everything is `@MainActor` because the builder is, and because
// `MeshResource` / `ModelEntity` operations in iOS 18 are MainActor.

import XCTest
import RealityKit
@testable import SDGGameplay

@MainActor
final class StackedCylinderMeshBuilderTests: XCTestCase {

    // MARK: - Fixtures

    /// Build a minimal `LayerIntersection` for tests — only the fields
    /// the mesh builder actually reads are populated with meaningful
    /// values; the rest use safe defaults. Pulled out so the expected
    /// offset maths is cleaner at each call site.
    private func makeIntersection(
        id: String = "test.layer",
        thickness: Float,
        color: SIMD3<Float> = SIMD3<Float>(0.5, 0.5, 0.5),
        entryDepth: Float = 0
    ) -> LayerIntersection {
        LayerIntersection(
            layerId: id,
            nameKey: "\(id).name",
            colorRGB: color,
            entryDepth: entryDepth,
            exitDepth: entryDepth + thickness,
            thickness: thickness,
            entryPoint: SIMD3<Float>(0, -entryDepth, 0),
            exitPoint: SIMD3<Float>(0, -(entryDepth + thickness), 0)
        )
    }

    // MARK: - Single-segment geometry

    /// The simplest smoke test: a unit cylinder must come back non-nil
    /// and be usable as the mesh of a `ModelEntity`. Failure here means
    /// Phase 1 sample rendering is DOA.
    func testMakeCylinderSegmentProducesUsableMesh() async throws {
        let mesh = try await StackedCylinderMeshBuilder.makeCylinderSegment(
            radius: 1.0,
            height: 1.0
        )
        let entity = ModelEntity(
            mesh: mesh,
            materials: [SimpleMaterial()]
        )
        XCTAssertNotNil(entity.components[ModelComponent.self])
    }

    /// Degenerate inputs (zero or negative radius / height) must not
    /// crash `MeshResource.generateCylinder`. We clamp to 1 mm in the
    /// builder; the result must still be a valid mesh. This is a
    /// defence against upstream bugs (e.g. an intersection whose
    /// thickness rounds to zero after clipping).
    func testMakeCylinderSegmentClampsDegenerateInputs() async throws {
        let mesh = try await StackedCylinderMeshBuilder.makeCylinderSegment(
            radius: 0,
            height: -5
        )
        let entity = ModelEntity(
            mesh: mesh,
            materials: [SimpleMaterial()]
        )
        XCTAssertNotNil(entity.components[ModelComponent.self])
    }

    // MARK: - Batch: structural

    /// Three intersections must yield three segments, preserving input
    /// order and intersection identity.
    func testBuildSegmentsPreservesOrderAndIdentity() async throws {
        let layers = [
            makeIntersection(id: "layer.a", thickness: 0.5),
            makeIntersection(id: "layer.b", thickness: 1.0, entryDepth: 0.5),
            makeIntersection(id: "layer.c", thickness: 1.5, entryDepth: 1.5)
        ]
        let segments = try await StackedCylinderMeshBuilder.buildSegments(
            for: layers
        )
        XCTAssertEqual(segments.count, 3)
        XCTAssertEqual(segments.map(\.sourceIntersection.layerId),
                       ["layer.a", "layer.b", "layer.c"])
    }

    /// Empty input → empty output, no throw, no crash. Needed because
    /// a drill missing every layer is a valid outcome upstream.
    func testBuildSegmentsEmptyInputReturnsEmpty() async throws {
        let segments = try await StackedCylinderMeshBuilder.buildSegments(
            for: []
        )
        XCTAssertEqual(segments.count, 0)
    }

    // MARK: - Batch: Y offset arithmetic

    /// The core invariant: layer offsets accumulate thickness + gap
    /// from the sample's top face downward. Manual numbers pinned
    /// here so a change in the arithmetic must surface in review.
    ///
    /// For `[t0=0.5, t1=1.0, t2=1.5]`, gap `g = 0.001`:
    ///   - seg[0] = -t0/2                     = -0.25
    ///   - seg[1] = -t0 - g - t1/2            = -0.5 - 0.001 - 0.5 = -1.001
    ///   - seg[2] = -t0 - g - t1 - g - t2/2   = -0.5 - 0.001 - 1.0 - 0.001 - 0.75 = -2.252
    func testBuildSegmentsYOffsetsAccumulate() async throws {
        let layers = [
            makeIntersection(id: "a", thickness: 0.5),
            makeIntersection(id: "b", thickness: 1.0),
            makeIntersection(id: "c", thickness: 1.5)
        ]
        let segments = try await StackedCylinderMeshBuilder.buildSegments(
            for: layers
        )

        XCTAssertEqual(segments[0].localYOffset, -0.25, accuracy: 1e-5)
        XCTAssertEqual(segments[1].localYOffset, -1.001, accuracy: 1e-5)
        XCTAssertEqual(segments[2].localYOffset, -2.252, accuracy: 1e-5)
    }

    /// A single-layer sample has no gaps to insert — offset must be
    /// exactly `-thickness / 2`. Guards against accidentally charging
    /// the gap to the first segment.
    func testBuildSegmentsSingleLayerHasNoGapBeforeIt() async throws {
        let layers = [makeIntersection(thickness: 2.0)]
        let segments = try await StackedCylinderMeshBuilder.buildSegments(
            for: layers
        )
        XCTAssertEqual(segments.count, 1)
        XCTAssertEqual(segments[0].localYOffset, -1.0, accuracy: 1e-5)
    }

    /// The `safeGap` constant must stay 1 mm. Pinning the value keeps
    /// a well-intentioned "let's make it bigger" tweak from shifting
    /// every sample visibly out of place without review.
    func testSafeGapIsPinnedToOneMillimeter() {
        XCTAssertEqual(
            StackedCylinderMeshBuilder.safeGap,
            0.001,
            accuracy: 1e-7
        )
    }

    // MARK: - Batch: per-segment content

    /// Each segment must carry the intersection it was built from —
    /// this is what `SampleEntity` reads to attach a
    /// `GeologyLayerComponent`. Drift here would silently mismatch
    /// colour and metadata.
    func testBuildSegmentsCarryMatchingIntersection() async throws {
        let layers = [
            makeIntersection(
                id: "red",
                thickness: 0.5,
                color: SIMD3<Float>(1, 0, 0)
            ),
            makeIntersection(
                id: "blue",
                thickness: 0.5,
                color: SIMD3<Float>(0, 0, 1)
            )
        ]
        let segments = try await StackedCylinderMeshBuilder.buildSegments(
            for: layers
        )
        XCTAssertEqual(segments[0].sourceIntersection.layerId, "red")
        XCTAssertEqual(segments[0].sourceIntersection.colorRGB,
                       SIMD3<Float>(1, 0, 0))
        XCTAssertEqual(segments[1].sourceIntersection.layerId, "blue")
        XCTAssertEqual(segments[1].sourceIntersection.colorRGB,
                       SIMD3<Float>(0, 0, 1))
    }

    /// Each segment's material must be one that `ModelEntity` can
    /// actually mount — we don't probe the PBR fields here
    /// (`ToonMaterialFactoryTests` owns those), we just assert the
    /// handoff is intact.
    func testBuildSegmentsProducesMountableMaterial() async throws {
        let layers = [makeIntersection(thickness: 1.0)]
        let segments = try await StackedCylinderMeshBuilder.buildSegments(
            for: layers
        )
        let entity = ModelEntity(
            mesh: segments[0].mesh,
            materials: [segments[0].material]
        )
        XCTAssertNotNil(entity.components[ModelComponent.self])
        XCTAssertEqual(
            entity.components[ModelComponent.self]?.materials.count,
            1
        )
    }
}
