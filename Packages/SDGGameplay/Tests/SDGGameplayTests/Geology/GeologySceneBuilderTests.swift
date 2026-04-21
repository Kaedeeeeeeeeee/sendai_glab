// GeologySceneBuilderTests.swift
// End-to-end tests for the procedural outcrop builder.
// Loads the same `test_outcrop.json` that ships in the app bundle
// (copied into Tests/.../Resources/ at package-manifest level) so a
// schema drift between the data file and the `Codable` types is
// caught in CI rather than at runtime on device.

import XCTest
import RealityKit
@testable import SDGGameplay

final class GeologySceneBuilderTests: XCTestCase {

    // MARK: - Fixtures

    /// The four layers the POC JSON is expected to contain.
    /// Hard-coded here — rather than reading the file — so test
    /// assertions pin the data contract instead of silently mirroring
    /// whatever's on disk.
    private static let expectedLayerIds = [
        "aobayama.topsoil",
        "aobayama.aobayamafm.upper",
        "aobayama.aobayamafm.lower",
        "aobayama.basement"
    ]

    /// Expected thicknesses, matching `test_outcrop.json`.
    private static let expectedThicknesses: [Float] = [0.5, 1.5, 2.0, 3.0]

    // MARK: - Loading

    /// `loadOutcrop(namedResource:in:)` must find the bundled JSON
    /// and produce a non-empty entity tree.
    func testLoadOutcropFromBundle() throws {
        let root = try GeologySceneBuilder.loadOutcrop(
            namedResource: "test_outcrop",
            in: .module
        )
        XCTAssertEqual(root.children.count, 4)
        XCTAssertEqual(root.name, "Outcrop_AobayamaTestOutcrop")
    }

    /// Missing resources must surface as a typed, inspectable error,
    /// not a silent nil / fatal.
    func testMissingResourceThrows() {
        XCTAssertThrowsError(
            try GeologySceneBuilder.loadOutcrop(
                namedResource: "does_not_exist",
                in: .module
            )
        ) { err in
            guard case GeologySceneBuilderError.resourceNotFound = err else {
                return XCTFail("unexpected error type: \(err)")
            }
        }
    }

    // MARK: - Structure

    /// Every child entity must carry a `GeologyLayerComponent` so
    /// downstream raycast code can trust the lookup without a
    /// fallback branch.
    func testEveryChildHasGeologyComponent() throws {
        let root = try GeologySceneBuilder.loadOutcrop(
            namedResource: "test_outcrop",
            in: .module
        )
        for child in root.children {
            XCTAssertNotNil(
                child.components[GeologyLayerComponent.self],
                "missing component on \(child.name)"
            )
        }
    }

    /// Every child must also have a `CollisionComponent` so raycasts
    /// hit something. Missing colliders were a frequent failure mode
    /// in the legacy Unity project.
    func testEveryChildHasCollisionComponent() throws {
        let root = try GeologySceneBuilder.loadOutcrop(
            namedResource: "test_outcrop",
            in: .module
        )
        for child in root.children {
            XCTAssertNotNil(
                child.components[CollisionComponent.self],
                "missing collider on \(child.name)"
            )
        }
    }

    /// The POC layer ids and ordering must match the spec. A
    /// regression here would mean future systems that key off
    /// `layerId` (e.g. encyclopedia unlocks) break quietly.
    func testChildrenPreserveOrderAndIds() throws {
        let root = try GeologySceneBuilder.loadOutcrop(
            namedResource: "test_outcrop",
            in: .module
        )
        let ids = root.children.compactMap {
            $0.components[GeologyLayerComponent.self]?.layerId
        }
        XCTAssertEqual(ids, Self.expectedLayerIds)
    }

    // MARK: - Geometry

    /// Layer 0's top face must sit at y = 0 (outcrop surface);
    /// subsequent layers must stack downward by cumulative
    /// thickness. We check each layer's entity position against the
    /// analytic formula `y = -(runningDepth + thickness/2)`.
    func testLayerStackingPositions() throws {
        let root = try GeologySceneBuilder.loadOutcrop(
            namedResource: "test_outcrop",
            in: .module
        )

        var runningDepth: Float = 0
        for (i, child) in root.children.enumerated() {
            let thickness = Self.expectedThicknesses[i]
            let expectedY = -(runningDepth + thickness / 2)
            XCTAssertEqual(
                child.position.y,
                expectedY,
                accuracy: 1e-5,
                "layer \(i) (\(child.name)) y position wrong"
            )
            runningDepth += thickness
        }
    }

    /// `depthFromSurface` on the component must match the cumulative
    /// thickness of preceding layers — this is what future raycast
    /// code reads to answer "at what depth did I hit?".
    func testDepthFromSurfaceCumulative() throws {
        let root = try GeologySceneBuilder.loadOutcrop(
            namedResource: "test_outcrop",
            in: .module
        )
        var expectedDepth: Float = 0
        for (i, child) in root.children.enumerated() {
            let component = try XCTUnwrap(
                child.components[GeologyLayerComponent.self]
            )
            XCTAssertEqual(
                component.depthFromSurface,
                expectedDepth,
                accuracy: 1e-5,
                "layer \(i) depthFromSurface wrong"
            )
            expectedDepth += Self.expectedThicknesses[i]
        }
    }

    /// Total stacked height must equal the sum of individual
    /// thicknesses (7.0 m for the POC). Acts as a cheap sanity
    /// integration test — catches off-by-one accumulation bugs.
    func testTotalHeightMatchesSumOfThicknesses() throws {
        let root = try GeologySceneBuilder.loadOutcrop(
            namedResource: "test_outcrop",
            in: .module
        )
        let sumThickness = root.children.compactMap {
            $0.components[GeologyLayerComponent.self]?.thickness
        }.reduce(0, +)
        XCTAssertEqual(sumThickness, 7.0, accuracy: 1e-5)
    }

    // MARK: - Colours

    /// Colours from JSON must be resolved into the 0…1 `colorRGB`
    /// field of the component — i.e. the hex `#6B4226` → roughly
    /// (0.42, 0.26, 0.15). We compare with generous tolerance because
    /// the conversion is just `byte / 255`.
    func testTopsoilColorDecoded() throws {
        let root = try GeologySceneBuilder.loadOutcrop(
            namedResource: "test_outcrop",
            in: .module
        )
        let topsoil = try XCTUnwrap(root.children.first)
        let comp = try XCTUnwrap(topsoil.components[GeologyLayerComponent.self])
        // #6B4226
        XCTAssertEqual(comp.colorRGB.x, Float(0x6B) / 255.0, accuracy: 1e-5)
        XCTAssertEqual(comp.colorRGB.y, Float(0x42) / 255.0, accuracy: 1e-5)
        XCTAssertEqual(comp.colorRGB.z, Float(0x26) / 255.0, accuracy: 1e-5)
    }

    // MARK: - In-memory build

    /// `buildOutcrop(from:)` must honour a non-zero `origin` by
    /// placing the root there. Relative-to-root positions of
    /// children must not shift — origin only affects the root.
    func testBuildOutcropHonoursOrigin() {
        let config = TestOutcropConfig(
            name: "Test",
            origin: SIMD3<Float>(10, 20, 30),
            layers: [
                GeologyLayerDefinition(
                    id: "one",
                    nameKey: "k",
                    type: .soil,
                    colorHex: "#FFFFFF",
                    thickness: 1.0
                )
            ]
        )
        let root = GeologySceneBuilder.buildOutcrop(from: config)
        XCTAssertEqual(root.position, SIMD3<Float>(10, 20, 30))
        // Single layer of thickness 1 → centred at y = -0.5.
        XCTAssertEqual(root.children.first?.position.y ?? 0, -0.5, accuracy: 1e-5)
    }

    /// Building an empty-layer config must still yield a valid root
    /// — useful for future "placeholder outcrop before data loads"
    /// use cases. Better to return an empty entity than to crash.
    func testBuildOutcropWithNoLayers() {
        let config = TestOutcropConfig(
            name: "Empty",
            origin: .zero,
            layers: []
        )
        let root = GeologySceneBuilder.buildOutcrop(from: config)
        XCTAssertEqual(root.children.count, 0)
        XCTAssertEqual(root.name, "Outcrop_Empty")
    }
}
