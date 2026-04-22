// EnvironmentCentererTests.swift
// SDGGameplay · World · Tests
//
// Smoke tests for the AABB centerer. Exercises the empty-geometry
// guard (critical — nusamai tiles with 0 buildings still load) and
// pins "position is only touched when bounds are non-empty".
//
// Full correctness of the centring maths is harder to test without a
// live RealityKit scene — `visualBounds(relativeTo:)` returns
// `.empty` for entities that haven't entered a scene graph on some
// builds. We therefore assert on the *contract* (inputs + side
// effects) rather than on numeric outputs.

import XCTest
import RealityKit
@testable import SDGGameplay

@MainActor
final class EnvironmentCentererTests: XCTestCase {

    /// A bare `Entity` with no geometry must not be moved — the
    /// centerer's empty-AABB guard is what keeps an "empty tile" from
    /// being translated to NaN-ville.
    func testEmptyEntityIsNotMoved() {
        let entity = Entity()
        entity.position = SIMD3<Float>(42, 43, 44)

        EnvironmentCenterer.centerAtOrigin(entity)

        XCTAssertEqual(entity.position, SIMD3<Float>(42, 43, 44))
    }

    /// `centerAndReport` must echo the empty bounds back to the
    /// caller so downstream code can distinguish "centred a real
    /// tile" from "nothing to centre". Signals the no-op path
    /// explicitly.
    func testEmptyEntityReportsEmptyBounds() {
        let entity = Entity()
        let (bounds, newPos) = EnvironmentCenterer.centerAndReport(entity)

        XCTAssertTrue(
            bounds.isEmpty,
            "expected empty bounds for a geometry-less entity"
        )
        XCTAssertEqual(newPos, entity.position)
    }

    /// A `ModelEntity` with a mesh must survive centring without
    /// crashing. We don't pin the exact translation — it depends on
    /// RealityKit's bounds calculation for a MeshResource, which can
    /// round differently across OS builds — but we do demand the
    /// call returns and leaves the entity in a usable state.
    func testModelEntityCanBeCentered() {
        let mesh = MeshResource.generateBox(size: 1.0)
        let entity = ModelEntity(mesh: mesh, materials: [SimpleMaterial()])
        entity.position = SIMD3<Float>(10, 20, 30)

        EnvironmentCenterer.centerAtOrigin(entity)

        // After centring, the position must be finite. Testing
        // `isFinite` rather than a specific value shields against
        // RealityKit internals that may or may not have bounds
        // available for an entity not attached to a scene.
        XCTAssertTrue(entity.position.x.isFinite)
        XCTAssertTrue(entity.position.y.isFinite)
        XCTAssertTrue(entity.position.z.isFinite)
    }
}
