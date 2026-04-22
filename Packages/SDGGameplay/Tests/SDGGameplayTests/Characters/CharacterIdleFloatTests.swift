// CharacterIdleFloatTests.swift
// Exercises the pure-math portion of the idle-float System without
// standing up a full RealityKit Scene.

import XCTest
import RealityKit
@testable import SDGGameplay

@MainActor
final class CharacterIdleFloatTests: XCTestCase {

    // MARK: - Registration

    /// Component has to be registered before the ECS will attach it
    /// to any entity; do it once per test class process.
    override class func setUp() {
        super.setUp()
        CharacterIdleFloatComponent.registerComponent()
    }

    private func makeSystem() -> CharacterIdleFloatSystem {
        let scene = Scene.__testInit(name: "CharacterIdleFloatTests")
        return CharacterIdleFloatSystem(scene: scene)
    }

    // MARK: - Component defaults

    /// Defaults encode the "~2 cm, ~0.5 Hz" idle-breathing target.
    /// Pin them so a tweak to the tuning is visible in the diff.
    func testComponentDefaults() {
        let c = CharacterIdleFloatComponent(baseY: 1.0)
        XCTAssertEqual(c.baseY, 1.0, accuracy: 1e-6)
        XCTAssertEqual(c.amplitude, 0.02, accuracy: 1e-6)
        XCTAssertEqual(c.frequency, 0.5, accuracy: 1e-6)
        XCTAssertEqual(c.phase, 0, accuracy: 1e-6)
    }

    // MARK: - Math

    /// At t=0 with phase=0 the entity should sit exactly on `baseY`
    /// (sin(0) = 0).
    func testApplyFloatAtZeroTimeReturnsBaseY() {
        let system = makeSystem()
        let entity = Entity()
        entity.components.set(CharacterIdleFloatComponent(
            baseY: 2.5, amplitude: 0.1, frequency: 1.0, phase: 0
        ))

        let y = system.applyFloat(to: entity)
        XCTAssertEqual(y, 2.5, accuracy: 1e-5)
        XCTAssertEqual(entity.position.y, 2.5, accuracy: 1e-5)
    }

    /// At t = 1/(4·frequency) the sine reaches +1, so the entity
    /// must sit at `baseY + amplitude`. Tests that the formula uses
    /// a proper 2π · frequency · t argument (not a raw scalar).
    func testApplyFloatAtQuarterPeriodHitsPeak() {
        let system = makeSystem()
        let entity = Entity()
        entity.components.set(CharacterIdleFloatComponent(
            baseY: 1.0, amplitude: 0.1, frequency: 1.0, phase: 0
        ))

        // Advance the System's clock to t = 0.25 s — i.e. a quarter
        // period for a 1 Hz oscillation.
        system.tickForTesting(by: 0.25)
        let y = system.applyFloat(to: entity)
        XCTAssertEqual(y, 1.1, accuracy: 1e-5)
    }

    /// A π/2 phase offset should make the entity start at `baseY +
    /// amplitude` at t = 0 (sin(π/2) = 1). Nails down that `phase`
    /// plugs into the argument correctly.
    func testPhaseOffsetShiftsStartPosition() {
        let system = makeSystem()
        let entity = Entity()
        entity.components.set(CharacterIdleFloatComponent(
            baseY: 0.0, amplitude: 0.05, frequency: 0.5, phase: .pi / 2
        ))

        let y = system.applyFloat(to: entity)
        XCTAssertEqual(y, 0.05, accuracy: 1e-5)
    }

    /// An entity without the component must be a no-op — the System
    /// will enumerate via `EntityQuery` in production so this path
    /// is defensive against direct test usage.
    func testApplyFloatNoopsWithoutComponent() {
        let system = makeSystem()
        let entity = Entity()
        entity.position.y = 3.14

        let y = system.applyFloat(to: entity)
        XCTAssertEqual(y, 3.14, accuracy: 1e-5)
        XCTAssertEqual(entity.position.y, 3.14, accuracy: 1e-5)
    }

    // MARK: - Clock accumulation

    /// `tickForTesting` must monotonically advance the elapsed-time
    /// clock; the sine-wave math above depends on it.
    func testTickAccumulatesElapsedTime() {
        let system = makeSystem()
        XCTAssertEqual(system.elapsedTimeForTesting, 0, accuracy: 1e-6)
        system.tickForTesting(by: 0.1)
        system.tickForTesting(by: 0.25)
        XCTAssertEqual(system.elapsedTimeForTesting, 0.35, accuracy: 1e-5)
    }
}
