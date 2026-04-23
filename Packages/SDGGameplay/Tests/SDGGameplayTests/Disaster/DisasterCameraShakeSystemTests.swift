// DisasterCameraShakeSystemTests.swift
// SDGGameplayTests · Disaster
//
// Verifies `DisasterCameraShakeSystem` applies a bounded offset to a
// player's camera while the earthquake Store state is active, and
// cleanly restores the camera to its neutral pose when the quake
// ends. We don't wire a `SceneUpdateContext` — the System exposes
// `applyCameraOffset` + `tickForTesting` for headless drive.

import XCTest
import Foundation
import RealityKit
import SDGCore
@testable import SDGGameplay

@MainActor
final class DisasterCameraShakeSystemTests: XCTestCase {

    override class func setUp() {
        super.setUp()
        PlayerComponent.registerComponent()
    }

    override func tearDown() async throws {
        DisasterSystem.boundStore = nil
        try await super.tearDown()
    }

    // MARK: - Fixtures

    private func makeSystem() -> DisasterCameraShakeSystem {
        let scene = Scene.__testInit(name: "DisasterCameraShakeSystemTests")
        return DisasterCameraShakeSystem(scene: scene)
    }

    /// A fresh camera entity at the origin. Tests treat its `position`
    /// as "neutral"; the System subtracts its own last-offset before
    /// applying a new one, so the assertions can compare against this
    /// zero baseline.
    private func makeCamera() -> Entity {
        return PerspectiveCamera()
    }

    // MARK: - Active intensity offsets the camera

    /// With a non-zero intensity and a non-zero elapsed clock, the
    /// System should leave the camera displaced from its baseline.
    func testActiveIntensityDisplacesCamera() {
        let system = makeSystem()
        system.tickForTesting(by: 0.5)  // elapsed > 0 so sin != 0
        let camera = makeCamera()

        let offset = system.applyCameraOffset(camera: camera, intensity: 1.0)

        // At least one axis must have moved. Y is deliberately part
        // of the jitter per spec; X or Y can be zero at a specific
        // sample time but not both.
        XCTAssertNotEqual(
            camera.position,
            .zero,
            "active quake should displace the camera off neutral"
        )
        XCTAssertNotEqual(
            offset,
            .zero,
            "applyCameraOffset must return the offset it applied"
        )
        // Peak amplitude clamps the offset magnitude.
        let peak = DisasterCameraShakeSystem.peakAmplitudeMeters
        XCTAssertLessThanOrEqual(abs(offset.x), peak + 1e-5)
        XCTAssertLessThanOrEqual(abs(offset.y), peak + 1e-5)
        // Z is never shaken — reserved for head-forward axis.
        XCTAssertEqual(offset.z, 0, accuracy: 1e-5)
    }

    // MARK: - Zero intensity restores baseline

    /// Transitioning to zero intensity must subtract the previous
    /// frame's offset and apply nothing — camera returns to neutral.
    func testZeroIntensityRestoresNeutralPose() {
        let system = makeSystem()
        let camera = makeCamera()
        system.tickForTesting(by: 0.25)

        // First frame: shake active.
        _ = system.applyCameraOffset(camera: camera, intensity: 1.0)
        XCTAssertNotEqual(camera.position, .zero)

        // Second frame: quake ends (intensity 0). Camera snaps back.
        let restoredOffset = system.applyCameraOffset(
            camera: camera, intensity: 0
        )

        XCTAssertEqual(
            camera.position,
            .zero,
            "idle state must restore the neutral pose"
        )
        XCTAssertEqual(restoredOffset, .zero)
        XCTAssertEqual(
            system.lastOffsetForTesting(camera: camera),
            .zero,
            "internal bookkeeping should clear once neutral"
        )
    }

    // MARK: - Intensity scales amplitude linearly

    /// Halving the intensity should halve the applied offset
    /// (modulo float noise) — the shake is a linear sinusoid.
    func testIntensityScalesAmplitudeLinearly() {
        let system1 = makeSystem()
        let system2 = makeSystem()
        // Both at the same local clock so sin(omega*t) is identical.
        system1.tickForTesting(by: 0.3)
        system2.tickForTesting(by: 0.3)
        let c1 = makeCamera()
        let c2 = makeCamera()

        let full = system1.applyCameraOffset(camera: c1, intensity: 1.0)
        let half = system2.applyCameraOffset(camera: c2, intensity: 0.5)

        // The ratio must be 2:1 across every axis. Using simd_abs
        // so the sign of the sinusoid doesn't matter.
        XCTAssertEqual(full.x, half.x * 2, accuracy: 1e-5)
        XCTAssertEqual(full.y, half.y * 2, accuracy: 1e-5)
    }

    // MARK: - Successive frames don't drift

    /// Running many active → idle cycles must return to baseline each
    /// time; any drift would mean the camera never settles after a
    /// real earthquake.
    func testRepeatedActiveIdleCyclesDoNotDrift() {
        let system = makeSystem()
        let camera = makeCamera()

        for i in 0..<5 {
            system.tickForTesting(by: 0.05 * Float(i + 1))
            _ = system.applyCameraOffset(camera: camera, intensity: 1.0)
            _ = system.applyCameraOffset(camera: camera, intensity: 0)
            XCTAssertEqual(
                camera.position,
                .zero,
                "cycle \(i) left residual offset"
            )
        }
    }
}
