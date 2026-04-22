// VehicleControlSystemTests.swift
// SDGGameplayTests
//
// Unit tests for `VehicleControlSystem`'s per-entity integration
// step. A real `Scene`/`SceneUpdateContext` is impractical to build
// headless on macOS so we bypass the query-driven entry point and
// exercise the internal `applyControl(to:deltaTime:)` directly —
// same approach as `PlayerControlSystemTests`.

import XCTest
import RealityKit
@testable import SDGGameplay

@MainActor
final class VehicleControlSystemTests: XCTestCase {

    override class func setUp() {
        super.setUp()
        VehicleComponent.registerComponent()
    }

    // MARK: - System factory

    /// Instantiate a `VehicleControlSystem`. `Scene` has no public
    /// init; we use the SDK-provided test hook, same pattern as
    /// `PlayerControlSystemTests`.
    private func makeSystem() -> VehicleControlSystem {
        let scene = Scene.__testInit(name: "VehicleControlSystemTests")
        return VehicleControlSystem(scene: scene)
    }

    /// Build a vehicle entity with a configured component.
    private func makeVehicle(
        type: VehicleType,
        isOccupied: Bool = true,
        moveAxis: SIMD2<Float> = .zero,
        verticalInput: Float = 0
    ) -> Entity {
        let entity = Entity()
        entity.components.set(VehicleComponent(
            vehicleType: type,
            isOccupied: isOccupied,
            moveAxis: moveAxis,
            verticalInput: verticalInput
        ))
        return entity
    }

    // MARK: - Horizontal motion (drone)

    /// `moveAxis = (1, 0)` must advance the drone along local +X at
    /// `maxSpeed * deltaTime` metres.
    func testDroneStrafeAdvancesPositionAlongX() {
        let system = makeSystem()
        let drone = makeVehicle(type: .drone, moveAxis: SIMD2<Float>(1, 0))

        system.applyControl(to: drone, deltaTime: 1.0)

        XCTAssertEqual(
            drone.position.x,
            VehicleType.drone.maxSpeed,
            accuracy: 1e-5
        )
        XCTAssertEqual(drone.position.y, 0, accuracy: 1e-5)
        XCTAssertEqual(drone.position.z, 0, accuracy: 1e-5)
    }

    /// `moveAxis = (0, 1)` must advance the drone along local -Z.
    func testDroneForwardAdvancesPositionAlongMinusZ() {
        let system = makeSystem()
        let drone = makeVehicle(type: .drone, moveAxis: SIMD2<Float>(0, 1))

        system.applyControl(to: drone, deltaTime: 0.5)

        XCTAssertEqual(
            drone.position.z,
            -VehicleType.drone.maxSpeed * 0.5,
            accuracy: 1e-5
        )
    }

    // MARK: - Vertical motion (drone only)

    /// Positive `verticalInput` must raise the drone's Y at
    /// `verticalSpeed * deltaTime` metres.
    func testDroneVerticalInputRaisesY() {
        let system = makeSystem()
        let drone = makeVehicle(type: .drone, verticalInput: 1)

        system.applyControl(to: drone, deltaTime: 1.0)

        XCTAssertEqual(
            drone.position.y,
            VehicleType.drone.verticalSpeed,
            accuracy: 1e-5
        )
    }

    /// Negative `verticalInput` descends.
    func testDroneNegativeVerticalInputLowersY() {
        let system = makeSystem()
        let drone = makeVehicle(type: .drone, verticalInput: -1)

        system.applyControl(to: drone, deltaTime: 0.25)

        XCTAssertEqual(
            drone.position.y,
            -VehicleType.drone.verticalSpeed * 0.25,
            accuracy: 1e-5
        )
    }

    /// Drone has no gravity — it stays put when inputs are zero
    /// even with a long deltaTime.
    func testDroneWithoutInputStaysInPlace() {
        let system = makeSystem()
        let drone = makeVehicle(type: .drone)  // occupied, no inputs
        let start = drone.position

        system.applyControl(to: drone, deltaTime: 5.0)

        XCTAssertEqual(drone.position, start,
                       "drone must not drift under zero input — it hovers")
    }

    // MARK: - Drill car

    /// Drill car has `verticalSpeed = 0`; a vertical input must
    /// not move it on Y (the gravity pull is separate).
    func testDrillCarIgnoresVerticalInput() {
        let system = makeSystem()
        let car = makeVehicle(type: .drillCar, verticalInput: 1)

        system.applyControl(to: car, deltaTime: 1.0)

        // Y should have *only* the gravity component, no climb.
        XCTAssertEqual(
            car.position.y,
            -VehicleControlSystem.gravity,
            accuracy: 1e-5,
            "drill car's verticalInput should be a no-op (verticalSpeed=0)"
        )
    }

    /// A gravity-bound vehicle loses Y at `gravity * deltaTime`
    /// while occupied, with no collision clamp (Phase 2 Beta scope).
    func testDrillCarGravityPullsDownOverTime() {
        let system = makeSystem()
        let car = makeVehicle(type: .drillCar)  // occupied, no inputs

        system.applyControl(to: car, deltaTime: 1.0)
        XCTAssertEqual(
            car.position.y,
            -VehicleControlSystem.gravity,
            accuracy: 1e-5
        )

        system.applyControl(to: car, deltaTime: 1.0)
        XCTAssertEqual(
            car.position.y,
            -2 * VehicleControlSystem.gravity,
            accuracy: 1e-5,
            "gravity must accumulate — drill car falls continuously"
        )
    }

    /// Drill car still responds to planar input while also being
    /// pulled down. Y gets gravity's share; X gets the input's share.
    func testDrillCarCombinesHorizontalMotionAndGravity() {
        let system = makeSystem()
        let car = makeVehicle(type: .drillCar, moveAxis: SIMD2<Float>(1, 0))

        system.applyControl(to: car, deltaTime: 0.5)

        XCTAssertEqual(
            car.position.x,
            VehicleType.drillCar.maxSpeed * 0.5,
            accuracy: 1e-5
        )
        XCTAssertEqual(
            car.position.y,
            -VehicleControlSystem.gravity * 0.5,
            accuracy: 1e-5
        )
    }

    // MARK: - Occupancy gate

    /// An unoccupied vehicle must not respond to inputs. Inputs are
    /// the Store's job to zero on `.exit`, but even if a stray
    /// sample sneaks in here, the System must ignore it.
    func testUnoccupiedVehicleIgnoresInputs() {
        let system = makeSystem()
        let drone = makeVehicle(
            type: .drone,
            isOccupied: false,
            moveAxis: SIMD2<Float>(1, 1),
            verticalInput: 1
        )
        let start = drone.position

        system.applyControl(to: drone, deltaTime: 1.0)

        XCTAssertEqual(drone.position, start,
                       "unoccupied vehicle must not move despite inputs")
    }

    /// Unoccupied drill car also does NOT fall — gravity gating
    /// keeps parked vehicles at their spawn altitude until a pilot
    /// is inside. Rationale: pre-collision Phase 2 Beta would drop
    /// every parked drill car through the floor otherwise.
    func testUnoccupiedDrillCarDoesNotFall() {
        let system = makeSystem()
        let car = makeVehicle(type: .drillCar, isOccupied: false)
        let start = car.position

        system.applyControl(to: car, deltaTime: 2.0)

        XCTAssertEqual(car.position, start,
                       "parked drill car must not fall in Phase 2 Beta")
    }

    // MARK: - No component fallback

    /// An entity without `VehicleComponent` must be a no-op. Guards
    /// against future refactors that loosen the EntityQuery.
    func testEntityWithoutComponentIsNoOp() {
        let system = makeSystem()
        let entity = Entity()

        system.applyControl(to: entity, deltaTime: 1.0)
        XCTAssertEqual(entity.position, .zero)
    }

    // MARK: - VehicleType envelope invariants

    /// Sanity-check the envelope values so tuning them later does
    /// not silently break the motion tests above.
    func testDroneEnvelopeInvariants() {
        XCTAssertFalse(VehicleType.drone.hasGravity)
        XCTAssertGreaterThan(VehicleType.drone.maxSpeed, 0)
        XCTAssertGreaterThan(VehicleType.drone.verticalSpeed, 0)
    }

    func testDrillCarEnvelopeInvariants() {
        XCTAssertTrue(VehicleType.drillCar.hasGravity)
        XCTAssertGreaterThan(VehicleType.drillCar.maxSpeed, 0)
        XCTAssertEqual(VehicleType.drillCar.verticalSpeed, 0)
    }
}
