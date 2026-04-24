// InteriorSceneBuilderTests.swift
// SDGGameplayTests · World
//
// Phase 9 Part F — shape contract for `InteriorSceneBuilder.build()`.
// These tests check pure structure: the builder returns an entity
// with the expected name, known-count shell pieces, a workbench, and
// an indoor portal marker carrying `LocationTransitionComponent`.
// We do not render or compile materials.

import XCTest
import RealityKit
@testable import SDGGameplay

@MainActor
final class InteriorSceneBuilderTests: XCTestCase {

    func testBuildReturnsNamedRoot() {
        let lab = InteriorSceneBuilder.build()
        XCTAssertEqual(lab.name, "LabInterior")
    }

    func testBuildIncludesSixShellSlabsPlusWorkbenchPlusPortal() {
        let lab = InteriorSceneBuilder.build()
        // 6 shell (floor + ceiling + 4 walls) + 1 workbench + 1 portal
        // marker = 8 direct children.
        XCTAssertEqual(lab.children.count, 8)
    }

    func testBuildIncludesWorkbenchChild() {
        let lab = InteriorSceneBuilder.build()
        let names = lab.children.map(\.name)
        XCTAssertTrue(names.contains("LabInterior.workbench"))
    }

    func testBuildIncludesFourWallsByName() {
        let lab = InteriorSceneBuilder.build()
        let names = Set(lab.children.map(\.name))
        XCTAssertTrue(names.contains("LabInterior.wall.posX"))
        XCTAssertTrue(names.contains("LabInterior.wall.negX"))
        XCTAssertTrue(names.contains("LabInterior.wall.posZ"))
        XCTAssertTrue(names.contains("LabInterior.wall.negZ"))
        XCTAssertTrue(names.contains("LabInterior.floor"))
        XCTAssertTrue(names.contains("LabInterior.ceiling"))
    }

    func testIndoorPortalMarkerCarriesTransitionComponent() {
        let lab = InteriorSceneBuilder.build(
            outdoorSpawnPoint: SIMD3<Float>(7, 8, 9)
        )
        let marker = lab.children.first {
            $0.name == "LabInterior.indoorPortalMarker"
        }
        XCTAssertNotNil(marker)
        let transition = marker?.components[LocationTransitionComponent.self]
        XCTAssertNotNil(transition)
        XCTAssertEqual(transition?.targetScene, .outdoor)
        XCTAssertEqual(
            transition?.spawnPointInTarget,
            SIMD3<Float>(7, 8, 9)
        )
    }

    func testDefaultIndoorSpawnPointIsInsideRoom() {
        let spawn = InteriorSceneBuilder.defaultIndoorSpawnPoint
        // Room is 10 × 4 × 8 centred on origin, Y floor at 0.
        let halfW = InteriorSceneBuilder.roomWidth / 2
        let halfD = InteriorSceneBuilder.roomDepth / 2
        XCTAssertGreaterThan(spawn.x, -halfW)
        XCTAssertLessThan(spawn.x, halfW)
        XCTAssertGreaterThan(spawn.z, -halfD)
        XCTAssertLessThan(spawn.z, halfD)
        XCTAssertGreaterThanOrEqual(spawn.y, 0)
        XCTAssertLessThan(spawn.y, InteriorSceneBuilder.roomHeight)
    }
}
