// PlayerControlSystemTests.swift
// Unit tests for `PlayerControlSystem`'s per-entity integration step.
//
// Constructing a real `Scene` + `SceneUpdateContext` from a unit test
// on headless macOS is impractical (there's no renderer-supplied
// context), so we bypass the query-driven entry point and exercise
// the internal `applyInput(to:deltaTime:)` directly. That method
// contains all the logic worth testing — query iteration is a
// one-liner around it.

import XCTest
import RealityKit
@testable import SDGGameplay

@MainActor
final class PlayerControlSystemTests: XCTestCase {

    /// Register the ECS component types once per test process.
    override class func setUp() {
        super.setUp()
        PlayerComponent.registerComponent()
        PlayerInputComponent.registerComponent()
    }

    // MARK: - Fixtures

    /// The System fails to initialise without a Scene reference. For
    /// unit tests we can side-step that: the init stores only the
    /// `EntityQuery`, which doesn't actually need a live scene.
    /// `Scene` has no public init, so we use `__testInit(name:)` —
    /// a SDK-provided test-hook constructor (see RealityFoundation's
    /// `.swiftinterface`).
    private func makeSystem() -> PlayerControlSystem {
        let scene = Scene.__testInit(name: "PlayerControlSystemTests")
        return PlayerControlSystem(scene: scene)
    }

    /// Build a Player entity with a custom input component.
    private func makePlayer(
        moveAxis: SIMD2<Float> = .zero,
        lookDelta: SIMD2<Float> = .zero
    ) -> Entity {
        let entity = Entity()
        entity.components.set(PlayerComponent())
        entity.components.set(PlayerInputComponent(
            moveAxis: moveAxis,
            lookDelta: lookDelta
        ))
        return entity
    }

    // MARK: - Horizontal motion

    /// With `moveAxis = (0, 1)` and 1.0 s delta, the entity must
    /// advance by `moveSpeed` metres along its local forward (-Z) axis.
    func testForwardMotionIntegratesOverTime() {
        let system = makeSystem()
        let player = makePlayer(moveAxis: SIMD2(0, 1))

        system.applyInput(to: player, deltaTime: 1.0)

        XCTAssertEqual(
            player.position.z,
            -PlayerControlSystem.moveSpeed,
            accuracy: 1e-5,
            "forward motion should move entity along local -Z"
        )
        XCTAssertEqual(player.position.x, 0, accuracy: 1e-5)
        XCTAssertEqual(player.position.y, 0, accuracy: 1e-5)
    }

    /// Strafe with `moveAxis.x = 1` advances along local +X.
    func testStrafeMotionIntegratesOverTime() {
        let system = makeSystem()
        let player = makePlayer(moveAxis: SIMD2(1, 0))

        system.applyInput(to: player, deltaTime: 0.5)

        XCTAssertEqual(
            player.position.x,
            PlayerControlSystem.moveSpeed * 0.5,
            accuracy: 1e-5
        )
        XCTAssertEqual(player.position.z, 0, accuracy: 1e-5)
    }

    /// Zero axis means no movement regardless of deltaTime.
    func testZeroAxisDoesNotMove() {
        let system = makeSystem()
        let player = makePlayer(moveAxis: .zero)
        let startPos = player.position

        system.applyInput(to: player, deltaTime: 1.0)

        XCTAssertEqual(player.position, startPos)
    }

    // MARK: - Yaw

    /// Positive yaw delta means "drag right → look right". From the
    /// starting pose (facing world -Z), a +π/2 yaw turns the player
    /// to face world +X. A subsequent forward move therefore adds
    /// `+moveSpeed * dt` to world `x` and leaves `z` unchanged.
    func testYawRotatesForwardVector() {
        let system = makeSystem()
        let player = makePlayer(lookDelta: SIMD2(Float.pi / 2, 0))

        // Frame 1: consume the yaw delta, clearing lookDelta.
        system.applyInput(to: player, deltaTime: 1.0 / 60)

        // Frame 2: re-inject forward intent and verify direction.
        var input = player.components[PlayerInputComponent.self] ?? PlayerInputComponent()
        input.moveAxis = SIMD2(0, 1)
        player.components.set(input)

        let before = player.position
        system.applyInput(to: player, deltaTime: 1.0)
        let after = player.position

        XCTAssertEqual(
            after.x - before.x,
            PlayerControlSystem.moveSpeed,
            accuracy: 1e-5,
            "90° right yaw should rotate forward motion onto +X"
        )
        XCTAssertEqual(after.z - before.z, 0, accuracy: 1e-5)
    }

    // MARK: - Pitch clamping

    /// Pitch accumulates and clamps at `pitchLimit`. Pushing well
    /// past the limit in one frame should land exactly on the limit.
    func testPitchClampsToLimit() {
        let system = makeSystem()
        let player = makePlayer(lookDelta: SIMD2(0, 10))   // far beyond limit

        system.applyInput(to: player, deltaTime: 1.0 / 60)

        XCTAssertEqual(
            system.accumulatedPitchForTesting,
            PlayerControlSystem.pitchLimit,
            accuracy: 1e-5,
            "pitch must be clamped to +limit"
        )
    }

    /// Clamping works on the negative side too.
    func testPitchClampsToNegativeLimit() {
        let system = makeSystem()
        let player = makePlayer(lookDelta: SIMD2(0, -10))

        system.applyInput(to: player, deltaTime: 1.0 / 60)

        XCTAssertEqual(
            system.accumulatedPitchForTesting,
            -PlayerControlSystem.pitchLimit,
            accuracy: 1e-5
        )
    }

    // MARK: - Look delta drain

    /// After an `update`, `lookDelta` must return to zero so the
    /// camera does not keep rotating while the finger is stationary.
    func testLookDeltaIsDrainedAfterUpdate() {
        let system = makeSystem()
        let player = makePlayer(lookDelta: SIMD2(0.1, 0.05))

        system.applyInput(to: player, deltaTime: 1.0 / 60)

        let input = player.components[PlayerInputComponent.self]
        XCTAssertEqual(input?.lookDelta, .zero,
                       "System must drain lookDelta each frame")
    }

    /// `moveAxis` is *persistent*, not one-shot. It must survive the
    /// update call so holding the joystick keeps moving the player.
    func testMoveAxisPersistsAfterUpdate() {
        let system = makeSystem()
        let player = makePlayer(moveAxis: SIMD2(0.5, 0.5))

        system.applyInput(to: player, deltaTime: 1.0 / 60)

        let input = player.components[PlayerInputComponent.self]
        XCTAssertEqual(input?.moveAxis, SIMD2(0.5, 0.5),
                       "moveAxis must persist across updates")
    }

    // MARK: - No component fallback

    /// An entity without `PlayerInputComponent` must be a no-op, not
    /// a crash. Defensive against future refactors that loosen the
    /// EntityQuery.
    func testEntityWithoutInputComponentIsNoOp() {
        let system = makeSystem()
        let entity = Entity()           // no components at all

        system.applyInput(to: entity, deltaTime: 1.0)
        XCTAssertEqual(entity.position, .zero)
    }
}
