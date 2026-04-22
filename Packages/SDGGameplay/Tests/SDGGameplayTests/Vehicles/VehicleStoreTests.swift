// VehicleStoreTests.swift
// SDGGameplayTests
//
// Unit tests for `VehicleStore`. The Store is the middle layer: we
// drive `intent(_:)` and assert on either (a) observable state
// mutation, (b) events published to the bus, or (c) the mirror into
// the bound `VehicleComponent` on a test entity.
//
// Every test builds a fresh `EventBus` + `VehicleStore` pair so
// state cannot leak between cases.

import XCTest
import RealityKit
import SDGCore
@testable import SDGGameplay

@MainActor
final class VehicleStoreTests: XCTestCase {

    // MARK: - Fixtures

    private var bus: EventBus!
    private var store: VehicleStore!

    /// Register the ECS component type once per test process.
    /// RealityKit no-ops on repeat registration, so this is cheap
    /// and idempotent.
    override class func setUp() {
        super.setUp()
        VehicleComponent.registerComponent()
    }

    override func setUp() async throws {
        try await super.setUp()
        bus = EventBus()
        store = VehicleStore(eventBus: bus)
    }

    override func tearDown() async throws {
        store = nil
        bus = nil
        try await super.tearDown()
    }

    // MARK: - Init

    func testInitialStateIsEmpty() {
        XCTAssertTrue(store.summonedVehicles.isEmpty)
        XCTAssertNil(store.occupiedVehicleId)
    }

    // MARK: - Summon

    func testSummonAppendsSnapshot() async {
        await store.intent(.summon(.drone, position: SIMD3<Float>(1, 2, 3)))

        XCTAssertEqual(store.summonedVehicles.count, 1)
        XCTAssertEqual(store.summonedVehicles.first?.type, .drone)
        XCTAssertEqual(store.summonedVehicles.first?.position,
                       SIMD3<Float>(1, 2, 3))
    }

    func testSummonMultipleVehiclesKeepsOrder() async {
        await store.intent(.summon(.drone, position: .zero))
        await store.intent(.summon(.drillCar, position: SIMD3<Float>(5, 0, 0)))

        XCTAssertEqual(store.summonedVehicles.map(\.type), [.drone, .drillCar])
    }

    func testSummonPublishesVehicleSummonedEvent() async {
        let recorder = EventRecorder<VehicleSummoned>()
        let token = await bus.subscribe(VehicleSummoned.self) { event in
            await recorder.record(event)
        }

        await store.intent(.summon(.drone, position: SIMD3<Float>(0, 3, 0)))
        // EventBus.publish awaits handlers; a yield finishes the
        // recorder's actor-hop for the `record` call.
        await Task.yield()

        let events = await recorder.all
        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events.first?.vehicleType, .drone)
        XCTAssertEqual(events.first?.position, SIMD3<Float>(0, 3, 0))

        await bus.cancel(token)
    }

    // MARK: - Enter

    func testEnterUnknownIdIsNoOp() async {
        await store.intent(.enter(vehicleId: UUID()))
        XCTAssertNil(store.occupiedVehicleId)
    }

    func testEnterKnownIdSetsOccupied() async {
        await store.intent(.summon(.drone, position: .zero))
        let id = store.summonedVehicles[0].id

        await store.intent(.enter(vehicleId: id))

        XCTAssertEqual(store.occupiedVehicleId, id)
    }

    func testEnterWhileAlreadyOccupiedIsNoOp() async {
        await store.intent(.summon(.drone, position: .zero))
        await store.intent(.summon(.drillCar, position: SIMD3<Float>(10, 0, 0)))
        let droneId = store.summonedVehicles[0].id
        let carId = store.summonedVehicles[1].id

        await store.intent(.enter(vehicleId: droneId))
        // Attempting to switch without an explicit exit must not
        // succeed — the player cannot be in two vehicles at once
        // and we prefer a no-op over silent swap.
        await store.intent(.enter(vehicleId: carId))

        XCTAssertEqual(store.occupiedVehicleId, droneId)
    }

    func testEnterPublishesVehicleEntered() async {
        await store.intent(.summon(.drone, position: .zero))
        let id = store.summonedVehicles[0].id

        let recorder = EventRecorder<VehicleEntered>()
        let token = await bus.subscribe(VehicleEntered.self) { event in
            await recorder.record(event)
        }

        await store.intent(.enter(vehicleId: id))
        await Task.yield()

        let events = await recorder.all
        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events.first?.vehicleId, id)
        XCTAssertEqual(events.first?.vehicleType, .drone)

        await bus.cancel(token)
    }

    func testEnterFlipsIsOccupiedOnBoundEntity() async {
        await store.intent(.summon(.drone, position: .zero))
        let id = store.summonedVehicles[0].id

        let entity = makeEntity(type: .drone, vehicleId: id)
        store.register(entity: entity, for: id)

        await store.intent(.enter(vehicleId: id))

        XCTAssertEqual(entity.components[VehicleComponent.self]?.isOccupied, true)
    }

    // MARK: - Exit

    func testExitWhenNotOccupiedIsNoOp() async {
        await store.intent(.exit)
        XCTAssertNil(store.occupiedVehicleId)
    }

    func testEnterThenExitResetsState() async {
        await store.intent(.summon(.drone, position: .zero))
        let id = store.summonedVehicles[0].id
        await store.intent(.enter(vehicleId: id))

        await store.intent(.exit)

        XCTAssertNil(store.occupiedVehicleId)
    }

    func testExitPublishesVehicleExited() async {
        await store.intent(.summon(.drone, position: .zero))
        let id = store.summonedVehicles[0].id
        await store.intent(.enter(vehicleId: id))

        let recorder = EventRecorder<VehicleExited>()
        let token = await bus.subscribe(VehicleExited.self) { event in
            await recorder.record(event)
        }

        await store.intent(.exit)
        await Task.yield()

        let events = await recorder.all
        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events.first?.vehicleId, id)

        await bus.cancel(token)
    }

    func testExitClearsEntityComponentState() async {
        await store.intent(.summon(.drone, position: .zero))
        let id = store.summonedVehicles[0].id
        let entity = makeEntity(type: .drone, vehicleId: id)
        store.register(entity: entity, for: id)

        await store.intent(.enter(vehicleId: id))
        await store.intent(.pilot(axis: SIMD2<Float>(0.5, 0.5), vertical: 0.3))

        // Pre-condition: the component reflects the last pilot sample.
        let pre = entity.components[VehicleComponent.self]
        XCTAssertEqual(pre?.moveAxis, SIMD2<Float>(0.5, 0.5))

        await store.intent(.exit)

        let post = entity.components[VehicleComponent.self]
        XCTAssertEqual(post?.isOccupied, false)
        XCTAssertEqual(post?.moveAxis, .zero)
        XCTAssertEqual(post?.verticalInput, 0)
    }

    // MARK: - Pilot

    func testPilotWhileNotOccupiedIsNoOp() async {
        await store.intent(.summon(.drone, position: .zero))
        let id = store.summonedVehicles[0].id
        let entity = makeEntity(type: .drone, vehicleId: id)
        store.register(entity: entity, for: id)

        // No `.enter` — the component should stay at defaults.
        await store.intent(.pilot(axis: SIMD2<Float>(1, 0), vertical: 1))

        let component = entity.components[VehicleComponent.self]
        XCTAssertEqual(component?.moveAxis, .zero,
                       "pilot samples must not affect an unoccupied vehicle")
        XCTAssertEqual(component?.verticalInput, 0)
    }

    func testPilotAfterEnterWritesIntoComponent() async {
        await store.intent(.summon(.drone, position: .zero))
        let id = store.summonedVehicles[0].id
        let entity = makeEntity(type: .drone, vehicleId: id)
        store.register(entity: entity, for: id)

        await store.intent(.enter(vehicleId: id))
        await store.intent(.pilot(axis: SIMD2<Float>(0.4, -0.2), vertical: 0.6))

        let component = entity.components[VehicleComponent.self]
        XCTAssertEqual(component?.moveAxis, SIMD2<Float>(0.4, -0.2))
        XCTAssertEqual(component?.verticalInput, 0.6)
    }

    // MARK: - Reset

    func testResetForTestingClearsState() async {
        await store.intent(.summon(.drone, position: .zero))
        let id = store.summonedVehicles[0].id
        await store.intent(.enter(vehicleId: id))

        store.resetForTesting()

        XCTAssertTrue(store.summonedVehicles.isEmpty)
        XCTAssertNil(store.occupiedVehicleId)
    }

    // MARK: - Helpers

    /// Build a bare entity carrying a `VehicleComponent` with the
    /// matching id. Standing in for what the scene-side subscriber
    /// to `VehicleSummoned` would produce in the real app.
    private func makeEntity(type: VehicleType, vehicleId: UUID) -> Entity {
        let entity = Entity()
        entity.components.set(VehicleComponent(
            vehicleType: type,
            vehicleId: vehicleId
        ))
        return entity
    }
}

// MARK: - Support

/// Actor-isolated recorder for event-bus assertions. Lets tests
/// observe events without resorting to `@unchecked Sendable`.
private actor EventRecorder<E: Sendable> {
    private var events: [E] = []

    func record(_ event: E) {
        events.append(event)
    }

    var all: [E] { events }
}
