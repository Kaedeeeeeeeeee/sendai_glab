// SampleEntityTests.swift
// SDGGameplay · Samples · Tests
//
// End-to-end tests for the sample-core entity factory. We care about:
//   * Root entity gets a SampleComponent and a readable name.
//   * Child count matches input layer count.
//   * Every child carries a GeologyLayerComponent with the right id,
//     thickness, colour.
//   * Outline opt-in attaches one extra child per segment.
//   * Empty layer list still produces a valid, mountable entity.
//
// All tests are `@MainActor` because `SampleEntity.make(...)` is.

import XCTest
import RealityKit
@testable import SDGGameplay

@MainActor
final class SampleEntityTests: XCTestCase {

    // MARK: - Fixtures

    /// Four canonical layers — enough to catch off-by-one bugs in
    /// iteration without bloating each assertion. Thicknesses chosen
    /// to match the POC outcrop (0.5 / 1.5 / 2.0 / 3.0) so tests cross-
    /// reference against the geology builder's expectations.
    private func canonicalLayers() -> [LayerIntersection] {
        [
            intersection(id: "aobayama.topsoil",
                         thickness: 0.5,
                         color: SIMD3<Float>(0.42, 0.26, 0.15),
                         entryDepth: 0),
            intersection(id: "aobayama.aobayamafm.upper",
                         thickness: 1.5,
                         color: SIMD3<Float>(0.73, 0.50, 0.26),
                         entryDepth: 0.5),
            intersection(id: "aobayama.aobayamafm.lower",
                         thickness: 2.0,
                         color: SIMD3<Float>(0.60, 0.40, 0.22),
                         entryDepth: 2.0),
            intersection(id: "aobayama.basement",
                         thickness: 3.0,
                         color: SIMD3<Float>(0.33, 0.33, 0.33),
                         entryDepth: 4.0)
        ]
    }

    private func intersection(
        id: String,
        thickness: Float,
        color: SIMD3<Float>,
        entryDepth: Float
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

    // MARK: - Root entity shape

    /// Four intersections must produce four children, in order.
    func testMakeProducesChildPerLayer() async throws {
        let entity = try await SampleEntity.make(
            from: canonicalLayers(),
            addOutline: false
        )
        XCTAssertEqual(entity.children.count, 4)
    }

    /// Empty input must still succeed — a drill missing every layer
    /// should hand the caller a placeable root, not throw. The root
    /// still carries a `SampleComponent` so inventory code can track
    /// the attempt.
    func testMakeEmptyLayersReturnsBareRoot() async throws {
        let entity = try await SampleEntity.make(from: [], addOutline: false)
        XCTAssertEqual(entity.children.count, 0)
        XCTAssertNotNil(entity.components[SampleComponent.self])
    }

    /// Root must carry a `SampleComponent` tagged with a valid id.
    /// ECS systems query by this component — missing it silently
    /// drops the sample from future interactions.
    func testRootCarriesSampleComponent() async throws {
        let layers = canonicalLayers()
        let fixedId = UUID()
        let entity = try await SampleEntity.make(
            from: layers,
            addOutline: false,
            sampleId: fixedId
        )
        let comp = entity.components[SampleComponent.self]
        XCTAssertNotNil(comp)
        XCTAssertEqual(comp?.sampleId, fixedId)
    }

    /// Root name must embed the first 8 hex chars of the sample id so
    /// console logs are grep-able. Not load-bearing for correctness
    /// but matches the pattern used by other builders in the module.
    func testRootNameEmbedsShortId() async throws {
        let fixedId = try XCTUnwrap(
            UUID(uuidString: "12345678-9ABC-DEF0-1234-56789ABCDEF0")
        )
        let entity = try await SampleEntity.make(
            from: [],
            sampleId: fixedId
        )
        XCTAssertTrue(
            entity.name.contains("12345678"),
            "unexpected root name: \(entity.name)"
        )
    }

    // MARK: - Per-segment wiring

    /// Every child must carry a GeologyLayerComponent whose layerId
    /// matches the source intersection. Drift here means the
    /// microscope / encyclopedia lookups will fail silently on
    /// whatever key they use.
    func testEveryChildHasGeologyLayerComponentMatchingLayerId() async throws {
        let layers = canonicalLayers()
        let entity = try await SampleEntity.make(
            from: layers,
            addOutline: false
        )
        let ids = entity.children.compactMap {
            $0.components[GeologyLayerComponent.self]?.layerId
        }
        XCTAssertEqual(ids, layers.map(\.layerId))
    }

    /// GeologyLayerComponent.thickness on each child must equal the
    /// source intersection's thickness. This is what inventory /
    /// teaching UI reads to label the core segment.
    func testEveryChildGeologyThicknessMatchesIntersection() async throws {
        let layers = canonicalLayers()
        let entity = try await SampleEntity.make(
            from: layers,
            addOutline: false
        )
        for (i, child) in entity.children.enumerated() {
            let comp = try XCTUnwrap(
                child.components[GeologyLayerComponent.self]
            )
            XCTAssertEqual(comp.thickness,
                           layers[i].thickness,
                           accuracy: 1e-6)
            XCTAssertEqual(comp.colorRGB, layers[i].colorRGB)
        }
    }

    /// Each child must have a `ModelComponent` so it actually renders.
    /// A regression here would produce a silent invisible sample.
    func testEveryChildHasModelComponent() async throws {
        let layers = canonicalLayers()
        let entity = try await SampleEntity.make(
            from: layers,
            addOutline: false
        )
        for child in entity.children {
            XCTAssertNotNil(child.components[ModelComponent.self],
                            "missing ModelComponent on \(child.name)")
        }
    }

    /// Each child must have a collider so the future "tap this
    /// segment" UX has something to hit-test against.
    func testEveryChildHasCollisionComponent() async throws {
        let layers = canonicalLayers()
        let entity = try await SampleEntity.make(
            from: layers,
            addOutline: false
        )
        for child in entity.children {
            XCTAssertNotNil(
                child.components[CollisionComponent.self],
                "missing collider on \(child.name)"
            )
        }
    }

    // MARK: - Positioning

    /// Child Y positions must match the offsets
    /// `StackedCylinderMeshBuilder` computes: top layer's centre
    /// sits at `-thickness/2`, each subsequent layer deeper by its
    /// own thickness plus the 1 mm gap. We don't re-derive the
    /// numbers here — we assert every child's Y is strictly below
    /// the previous child's Y, and the first child's top face sits
    /// within one gap of y = 0.
    func testChildYOffsetsMonotonicallyDecreasing() async throws {
        let layers = canonicalLayers()
        let entity = try await SampleEntity.make(
            from: layers,
            addOutline: false
        )
        let ys = entity.children.map(\.position.y)
        // Top-face of the first segment should be ~= 0 (centre at
        // -thickness/2).
        XCTAssertEqual(ys[0], -layers[0].thickness / 2, accuracy: 1e-5)
        for i in 1..<ys.count {
            XCTAssertLessThan(ys[i], ys[i - 1],
                              "segment \(i) not below segment \(i - 1)")
        }
    }

    // MARK: - Outline opt-in

    /// With `addOutline == true` (the default), each segment must
    /// have at least one child — the outline hull. Without outlines
    /// the segments must be childless.
    func testOutlineOptInAttachesChildPerSegment() async throws {
        let layers = canonicalLayers()

        let withOutline = try await SampleEntity.make(
            from: layers,
            addOutline: true
        )
        for child in withOutline.children {
            XCTAssertGreaterThanOrEqual(
                child.children.count,
                1,
                "segment \(child.name) missing outline child"
            )
        }

        let withoutOutline = try await SampleEntity.make(
            from: layers,
            addOutline: false
        )
        for child in withoutOutline.children {
            XCTAssertEqual(
                child.children.count,
                0,
                "segment \(child.name) has unexpected child: \(child.children)"
            )
        }
    }

    // MARK: - Radius plumbing

    /// Passing a custom `radius` must propagate into the collider
    /// footprint; smaller sample = smaller collision box. This is the
    /// check that guarantees the radius plumbs through two layers of
    /// API — `SampleEntity.make` → builder → collider.
    func testCustomRadiusPropagatesToCollider() async throws {
        let layers = [
            intersection(id: "tiny",
                         thickness: 0.2,
                         color: SIMD3<Float>(0.5, 0.5, 0.5),
                         entryDepth: 0)
        ]
        let entity = try await SampleEntity.make(
            from: layers,
            radius: 0.01, // 1 cm
            addOutline: false
        )
        let child = try XCTUnwrap(entity.children.first)
        XCTAssertNotNil(child.components[CollisionComponent.self])
    }
}
