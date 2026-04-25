// DisasterSystemTests.swift
// SDGGameplayTests · Disaster
//
// Validates `DisasterSystem`'s per-entity shake math without a live
// `Scene`. We drive the System through its `testApplyShake` hook so
// we don't need to build a `SceneUpdateContext`.

import XCTest
import Foundation
import RealityKit
@testable import SDGGameplay

@MainActor
final class DisasterSystemTests: XCTestCase {

    override class func setUp() {
        super.setUp()
        DisasterShakeTargetComponent.registerComponent()
        DisasterFloodWaterComponent.registerComponent()
    }

    private func makeSystem() -> DisasterSystem {
        // Scene.__testInit is the same hook PlayerControlSystemTests
        // use to instantiate a System without a full scene graph.
        let scene = Scene.__testInit(name: "DisasterSystemTests")
        return DisasterSystem(scene: scene)
    }

    private func makeTile(x: Float, z: Float) -> Entity {
        let e = Entity()
        e.position = SIMD3<Float>(x, 0, z)
        e.components.set(DisasterShakeTargetComponent())
        return e
    }

    // MARK: - Baseline capture

    func testFirstShakeFrameCapturesInitialPosition() {
        let system = makeSystem()
        let tile = makeTile(x: 100, z: 50)
        system.tickForTesting(by: 0.016)  // non-zero elapsed → sin != 0

        // Drive the System with an active earthquake at full
        // intensity so we get a non-trivial offset.
        let state = DisasterState.earthquakeActive(
            remaining: 1.0, intensity: 1.0, questId: nil
        )
        _ = system.testApplyShake(state: state, on: [tile])

        let stored = tile.components[DisasterShakeTargetComponent.self]?
            .initialPosition
        XCTAssertEqual(stored, SIMD3<Float>(100, 0, 50),
                       "the first frame must latch the initial position")
    }

    // MARK: - Shake applies non-trivial XZ offset

    func testEarthquakeShakeMovesTileOffBaselineInXZ() {
        let system = makeSystem()
        let tile = makeTile(x: 10, z: 5)
        // Advance the local clock so sin(elapsed * freq) != 0.
        system.tickForTesting(by: 0.25)
        let state = DisasterState.earthquakeActive(
            remaining: 1.0, intensity: 1.0, questId: nil
        )
        _ = system.testApplyShake(state: state, on: [tile])

        // X or Z (or both) should have moved off baseline.
        let movedX = tile.position.x != 10
        let movedZ = tile.position.z != 5
        XCTAssertTrue(movedX || movedZ,
                      "earthquake should have shaken XZ")
        // Y baseline must not be touched — DEM snap depends on it.
        XCTAssertEqual(tile.position.y, 0, accuracy: 1e-5)
    }

    // MARK: - Intensity scaling

    func testZeroIntensityLeavesTileAtBaseline() {
        let system = makeSystem()
        let tile = makeTile(x: 20, z: -5)
        system.tickForTesting(by: 0.5)
        let state = DisasterState.earthquakeActive(
            remaining: 1.0, intensity: 0, questId: nil
        )
        _ = system.testApplyShake(state: state, on: [tile])

        XCTAssertEqual(tile.position, SIMD3<Float>(20, 0, -5),
                       "intensity 0 must not move the tile")
    }

    // MARK: - Idle restores baseline

    func testIdleStateRestoresTileToBaseline() {
        let system = makeSystem()
        let tile = makeTile(x: 7, z: 3)
        // First shake frame to store baseline and displace the tile.
        system.tickForTesting(by: 0.25)
        let active = DisasterState.earthquakeActive(
            remaining: 1.0, intensity: 1.0, questId: nil
        )
        _ = system.testApplyShake(state: active, on: [tile])
        XCTAssertNotEqual(tile.position, SIMD3<Float>(7, 0, 3))

        // Transition to idle — the next pass should snap back.
        _ = system.testApplyShake(state: .idle, on: [tile])

        XCTAssertEqual(tile.position, SIMD3<Float>(7, 0, 3),
                       "idle must restore the baseline XZ+Y")
    }

    // MARK: - Player stagger (Phase 8.1)

    /// While an earthquake is active, `applyPlayerStagger` must flip
    /// every `PlayerComponent`-bearing entity's `isStaggered` flag
    /// to `true`. When the state returns to `.idle`, the flag must
    /// flip back to `false`. This is the plumbing that couples
    /// `DisasterStore` state to `PlayerControlSystem`'s input scale
    /// without routing a dedicated event through the bus every frame.
    func testPlayerStaggerFollowsEarthquakeState() {
        PlayerComponent.registerComponent()
        let system = makeSystem()
        let player = Entity()
        player.components.set(PlayerComponent())  // default: not staggered
        XCTAssertEqual(
            player.components[PlayerComponent.self]?.isStaggered,
            false,
            "baseline: player should not be staggered"
        )

        // Earthquake active → player staggered.
        let active = DisasterState.earthquakeActive(
            remaining: 1.5, intensity: 0.6, questId: nil
        )
        _ = system.testApplyPlayerStagger(state: active, on: [player])
        XCTAssertEqual(
            player.components[PlayerComponent.self]?.isStaggered,
            true,
            "earthquakeActive must flip isStaggered to true"
        )

        // Back to idle → stagger clears.
        _ = system.testApplyPlayerStagger(state: .idle, on: [player])
        XCTAssertEqual(
            player.components[PlayerComponent.self]?.isStaggered,
            false,
            "idle must clear isStaggered"
        )
    }

    // MARK: - Multi-tile independence

    func testMultipleTilesShakeIndependently() {
        let system = makeSystem()
        let tileA = makeTile(x: 0, z: 0)
        let tileB = makeTile(x: 1000, z: 0)
        system.tickForTesting(by: 0.3)

        let state = DisasterState.earthquakeActive(
            remaining: 1.0, intensity: 1.0, questId: nil
        )
        let applied = system.testApplyShake(state: state, on: [tileA, tileB])
        XCTAssertEqual(applied, 2)

        // The two tiles use different phase offsets (idx 0 vs 1), so
        // their instantaneous XZ offsets from baseline should differ.
        let deltaA = tileA.position - SIMD3<Float>(0, 0, 0)
        let deltaB = tileB.position - SIMD3<Float>(1000, 0, 0)
        XCTAssertNotEqual(deltaA, deltaB,
                          "tiles must shake out of phase")
    }
}
