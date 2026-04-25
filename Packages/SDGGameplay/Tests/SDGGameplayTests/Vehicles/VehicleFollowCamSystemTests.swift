// VehicleFollowCamSystemTests.swift
// SDGGameplayTests
//
// Unit tests for Phase 7.1's follow-cam System. We exercise the
// per-entity `applyFollow(to:deltaTime:)` helper directly — same
// headless pattern as `VehicleControlSystemTests` and
// `CharacterIdleFloatTests`, because building a live
// `SceneUpdateContext` on macOS is impractical.
//
// Coverage targets:
//   * Spring lerp at reference frame-rate lands at the expected
//     per-frame fraction of the remaining offset (5 tests combined).
//   * Frame-rate rescaling keeps the perceived motion constant at
//     non-60 FPS deltas.
//   * Component + camera-descent fast paths short-circuit correctly
//     when inputs are degenerate.
//
// The component is registered once per test process in `setUp()`.

import XCTest
import RealityKit
@testable import SDGGameplay

@MainActor
final class VehicleFollowCamSystemTests: XCTestCase {

    override class func setUp() {
        super.setUp()
        VehicleFollowCamComponent.registerComponent()
    }

    // MARK: - System + scene fixtures

    /// Build a `VehicleFollowCamSystem` against a test-only Scene.
    /// Same `__testInit` pattern the other vehicle tests use.
    private func makeSystem() -> VehicleFollowCamSystem {
        let scene = Scene.__testInit(name: "VehicleFollowCamSystemTests")
        return VehicleFollowCamSystem(scene: scene)
    }

    /// Build a vehicle entity with the follow-cam component attached
    /// and a `PerspectiveCamera` child parked at `cameraStart`. This
    /// mirrors the Phase 7 camera re-parent shape: the camera sits
    /// under the vehicle, the vehicle is what carries the state.
    private func makeVehicleWithCamera(
        cameraStart: SIMD3<Float>,
        targetOffset: SIMD3<Float> = VehicleFollowCamComponent.defaultTargetOffset,
        springFactor: Float = VehicleFollowCamComponent.defaultSpringFactor
    ) -> (vehicle: Entity, camera: Entity) {
        let vehicle = Entity()
        vehicle.components.set(VehicleFollowCamComponent(
            targetOffset: targetOffset,
            springFactor: springFactor
        ))
        let camera = PerspectiveCamera()
        camera.transform.translation = cameraStart
        vehicle.addChild(camera)
        return (vehicle, camera)
    }

    // MARK: - Defaults

    /// The Phase 7.1 tuning defaults must stay pinned so any edit is
    /// visible in the diff. If these change, re-evaluate the camera
    /// feel with playtest — they're not free parameters.
    func testComponentDefaults() {
        let c = VehicleFollowCamComponent()
        XCTAssertEqual(
            c.targetOffset,
            SIMD3<Float>(0, 1.5, -3.0),
            "Phase 7.1 target offset must match ADR-0009 follow-up spec"
        )
        XCTAssertEqual(c.springFactor, 0.15, accuracy: 1e-6)
    }

    // MARK: - Spring lerp math

    /// At `deltaTime = 1/60` (i.e. k = springFactor × 1) the camera
    /// should move exactly `springFactor` of the way toward the
    /// target. Start far from target so the residual is easy to read.
    func testSingleFrameStepCoversSpringFactorFraction() {
        let system = makeSystem()
        let (vehicle, camera) = makeVehicleWithCamera(
            cameraStart: .zero,
            targetOffset: SIMD3<Float>(0, 10, 0),
            springFactor: 0.15
        )

        let result = system.applyFollow(to: vehicle, deltaTime: 1.0 / 60.0)

        // With k = 0.15, 15% of 10 = 1.5.
        XCTAssertEqual(camera.transform.translation.y, 1.5, accuracy: 1e-4)
        XCTAssertEqual(result.y, 1.5, accuracy: 1e-4)
    }

    /// Frame-rate independence: at 30 FPS (dt = 1/30) the k rescales
    /// to 0.3, so a single frame covers 30% of the remaining offset.
    /// This is the headline property of the `deltaTime * 60` rescale.
    func testLowerFrameRateRescalesSpringCoverage() {
        let system = makeSystem()
        let (vehicle, camera) = makeVehicleWithCamera(
            cameraStart: .zero,
            targetOffset: SIMD3<Float>(0, 10, 0),
            springFactor: 0.15
        )

        system.applyFollow(to: vehicle, deltaTime: 1.0 / 30.0)

        // k = 0.15 * (1/30) * 60 = 0.30  →  3.0 out of 10.
        XCTAssertEqual(camera.transform.translation.y, 3.0, accuracy: 1e-4)
    }

    /// A catastrophically long frame (pathological deltaTime) must
    /// clamp k to 1.0, snapping to target rather than overshooting
    /// past and inducing oscillation. Use dt such that unclamped k
    /// would be 2.0, and verify the camera lands exactly on target.
    func testExcessiveDeltaTimeClampsToTargetWithoutOvershoot() {
        let system = makeSystem()
        let (vehicle, camera) = makeVehicleWithCamera(
            cameraStart: .zero,
            targetOffset: SIMD3<Float>(0, 0, -5),
            // springFactor 0.15; dt such that k = 0.15 * dt * 60 = 2.0
            // ⇒ dt = 2 / (0.15 * 60) = 0.2222… s. A 222 ms frame
            // would only happen under a hang; clamp must kick in.
            springFactor: 0.15
        )

        system.applyFollow(to: vehicle, deltaTime: 0.25)

        // Clamped to 1.0 means "jump straight to target this frame".
        XCTAssertEqual(camera.transform.translation.z, -5, accuracy: 1e-4)
    }

    /// Already-on-target: the snap fast path kicks in and the camera
    /// lands exactly on the target without accumulating float drift.
    func testCameraAlreadyAtTargetSnapsToTarget() {
        let system = makeSystem()
        let target = SIMD3<Float>(0.5, 1.5, -3.0)
        let (vehicle, camera) = makeVehicleWithCamera(
            cameraStart: target,
            targetOffset: target,
            springFactor: 0.15
        )

        let result = system.applyFollow(to: vehicle, deltaTime: 1.0 / 60.0)

        XCTAssertEqual(camera.transform.translation, target)
        XCTAssertEqual(result, target)
    }

    // MARK: - Guards

    /// Zero / negative deltaTime: helper still runs (System.update
    /// guards the global case) but we verify the clamped k = 0 path
    /// doesn't move the camera. Defensive against future callers of
    /// `applyFollow` directly.
    func testZeroDeltaTimeDoesNotMoveCamera() {
        let system = makeSystem()
        let start = SIMD3<Float>(0, 2, -1)
        let (vehicle, camera) = makeVehicleWithCamera(
            cameraStart: start,
            targetOffset: SIMD3<Float>(0, 5, -5)
        )

        system.applyFollow(to: vehicle, deltaTime: 0)

        XCTAssertEqual(camera.transform.translation, start,
                       "deltaTime=0 must not budge the camera")
    }

    /// An entity without the component is a no-op — guards future
    /// refactors that loosen the EntityQuery.
    func testEntityWithoutFollowComponentIsNoOp() {
        let system = makeSystem()
        let bare = Entity()

        let result = system.applyFollow(to: bare, deltaTime: 1.0 / 60.0)
        XCTAssertEqual(result, .zero)
    }

    /// A vehicle carrying the component but no PerspectiveCamera
    /// descendant is also a no-op. Can briefly happen between
    /// VehicleExited firing and the follow-cam component being
    /// removed in RootView.
    func testVehicleWithNoCameraDescendantIsNoOp() {
        let system = makeSystem()
        let vehicle = Entity()
        vehicle.components.set(VehicleFollowCamComponent())
        // Add a non-camera child to make sure the DFS is actually
        // looking at type, not "any child means success".
        let noise = Entity()
        vehicle.addChild(noise)

        let result = system.applyFollow(to: vehicle, deltaTime: 1.0 / 60.0)
        XCTAssertEqual(result, .zero)
    }
}
