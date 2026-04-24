// PortalEntityTests.swift
// SDGGameplayTests · World
//
// Phase 9 Part F — shape contract for `PortalEntity.makeOutdoorPortal`.
// Checks the root is positioned at the supplied world position, the
// frame has four visible child pieces, and the
// `LocationTransitionComponent` payload matches what we passed in.

import XCTest
import RealityKit
@testable import SDGGameplay

@MainActor
final class PortalEntityTests: XCTestCase {

    func testOutdoorPortalPositionedAtWorldPosition() {
        let position = SIMD3<Float>(5, 1, -3)
        let portal = PortalEntity.makeOutdoorPortal(
            at: position,
            spawnPointInTarget: .zero
        )
        XCTAssertEqual(portal.position, position)
    }

    func testOutdoorPortalHasFourFramePieces() {
        let portal = PortalEntity.makeOutdoorPortal(
            at: .zero,
            spawnPointInTarget: .zero
        )
        XCTAssertEqual(portal.children.count, 4)
        let names = Set(portal.children.map(\.name))
        XCTAssertTrue(names.contains("OutdoorPortal.left"))
        XCTAssertTrue(names.contains("OutdoorPortal.right"))
        XCTAssertTrue(names.contains("OutdoorPortal.top"))
        XCTAssertTrue(names.contains("OutdoorPortal.bottom"))
    }

    func testOutdoorPortalCarriesTransitionComponent() {
        let spawn = SIMD3<Float>(1, 2, 3)
        let portal = PortalEntity.makeOutdoorPortal(
            at: .zero,
            targetScene: .indoor(sceneId: "lab"),
            spawnPointInTarget: spawn
        )
        let transition = portal.components[LocationTransitionComponent.self]
        XCTAssertNotNil(transition)
        XCTAssertEqual(transition?.targetScene, .indoor(sceneId: "lab"))
        XCTAssertEqual(transition?.spawnPointInTarget, spawn)
    }

    func testDefaultTargetSceneIsLab() {
        let portal = PortalEntity.makeOutdoorPortal(
            at: .zero,
            spawnPointInTarget: .zero
        )
        let transition = portal.components[LocationTransitionComponent.self]
        XCTAssertEqual(
            transition?.targetScene,
            .indoor(sceneId: InteriorSceneBuilder.defaultSceneId)
        )
    }

    func testTriggerRadiusMatchesStoreConstant() {
        // The portal exposes the radius as a convenience; both should
        // stay in lockstep so level design and Store agree.
        XCTAssertEqual(
            PortalEntity.outdoorPortalTriggerRadius,
            SceneTransitionStore.triggerRadius
        )
    }
}
