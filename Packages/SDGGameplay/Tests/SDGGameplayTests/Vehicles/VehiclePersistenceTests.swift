// VehiclePersistenceTests.swift
// SDGGameplayTests · Vehicles
//
// Exercises `VehiclePersistence` save/load round-trips, plus the
// store-side integration that round-trips through the Store's
// `.summon` → reload → `start()` republish path.

import XCTest
import Foundation
import SDGCore
@testable import SDGGameplay

@MainActor
final class VehiclePersistenceTests: XCTestCase {

    // MARK: - Fixtures

    /// Build `count` vehicle snapshots with distinct ids / positions
    /// so a silent index-off-by-one in the codec would be visible.
    private func makeSnapshots(count: Int) -> [VehicleSnapshot] {
        (0..<count).map { i in
            VehicleSnapshot(
                id: UUID(),
                type: i.isMultiple(of: 2) ? .drone : .drillCar,
                position: SIMD3<Float>(Float(i), Float(i) * 0.5, -Float(i))
            )
        }
    }

    /// Build a `UserDefaults` suite with a unique name so concurrent
    /// test runs don't collide, and make sure we nuke it at teardown.
    private func makeScopedDefaults(
        _ label: String = #function
    ) throws -> (UserDefaults, String) {
        let suiteName = "sdg.vehicles.tests.\(label).\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            XCTFail("could not create scoped UserDefaults suite")
            throw XCTSkip("UserDefaults(suiteName:) returned nil")
        }
        return (defaults, suiteName)
    }

    // MARK: - inMemory backend

    func testInMemoryRoundTripPreservesSnapshots() throws {
        let persistence = VehiclePersistence.inMemory
        let snapshots = makeSnapshots(count: 4)
        let occupied = snapshots[1].id

        try persistence.save(.init(
            summonedVehicles: snapshots,
            occupiedVehicleId: occupied
        ))
        let loaded = try persistence.load()

        XCTAssertEqual(loaded.summonedVehicles, snapshots)
        XCTAssertEqual(loaded.occupiedVehicleId, occupied)
    }

    func testInMemoryLoadOnEmptyReturnsEmptySnapshot() throws {
        let persistence = VehiclePersistence.inMemory
        let loaded = try persistence.load()
        XCTAssertEqual(loaded, .empty)
        XCTAssertTrue(loaded.summonedVehicles.isEmpty)
        XCTAssertNil(loaded.occupiedVehicleId)
    }

    func testSchemaKeyIsVersioned() {
        // Pin the key so a future schema bump is an intentional
        // choice, not an accidental string tweak that silently wipes
        // the saved vehicles.
        XCTAssertEqual(VehiclePersistence.schemaKey, "sdg.vehicles.v1")
    }

    // MARK: - UserDefaults backend

    func testUserDefaultsRoundTripPreservesSnapshots() throws {
        let (defaults, suiteName) = try makeScopedDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let persistence = VehiclePersistence.userDefaults(defaults)
        let snapshots = makeSnapshots(count: 3)

        try persistence.save(.init(
            summonedVehicles: snapshots,
            occupiedVehicleId: nil
        ))
        let loaded = try persistence.load()

        XCTAssertEqual(loaded.summonedVehicles, snapshots)
        XCTAssertNil(loaded.occupiedVehicleId)
    }

    func testUserDefaultsLoadThrowsOnCorruptPayload() throws {
        let (defaults, suiteName) = try makeScopedDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        defaults.set(
            Data([0xDE, 0xAD, 0xBE, 0xEF]),
            forKey: VehiclePersistence.schemaKey
        )
        let persistence = VehiclePersistence.userDefaults(defaults)

        XCTAssertThrowsError(try persistence.load()) { error in
            XCTAssertTrue(error is DecodingError,
                          "expected DecodingError, got \(error)")
        }
    }

    // MARK: - Store integration

    /// A summon through the Store must land in the persistence so a
    /// fresh Store wired to the same persistence re-reads it on
    /// `start()`.
    func testStoreSummonPersistsAcrossReloads() async {
        let bus = EventBus()
        let persistence = VehiclePersistence.inMemory

        let writer = VehicleStore(eventBus: bus, persistence: persistence)
        await writer.intent(.summon(.drone, position: SIMD3<Float>(1, 2, 3)))
        let originalId = writer.summonedVehicles[0].id

        // Simulate a second app launch: new bus, new Store, same
        // persistence.
        let reloaded = VehicleStore(eventBus: EventBus(), persistence: persistence)
        await reloaded.start()

        XCTAssertEqual(reloaded.summonedVehicles.count, 1)
        XCTAssertEqual(reloaded.summonedVehicles.first?.id, originalId)
        XCTAssertEqual(reloaded.summonedVehicles.first?.type, .drone)
        XCTAssertEqual(
            reloaded.summonedVehicles.first?.position,
            SIMD3<Float>(1, 2, 3)
        )
    }

    /// `resetForTesting` must also wipe the persistence; otherwise a
    /// subsequent `start()` would silently rehydrate the pre-reset
    /// state and make tests non-deterministic.
    func testStoreResetWipesPersistenceSoNextStartIsEmpty() async {
        let bus = EventBus()
        let persistence = VehiclePersistence.inMemory

        let store = VehicleStore(eventBus: bus, persistence: persistence)
        await store.intent(.summon(.drone, position: .zero))
        XCTAssertEqual(store.summonedVehicles.count, 1)

        store.resetForTesting()

        let fresh = VehicleStore(eventBus: EventBus(), persistence: persistence)
        await fresh.start()
        XCTAssertTrue(fresh.summonedVehicles.isEmpty)
    }

    /// A dangling `occupiedVehicleId` (i.e. one whose vehicle is no
    /// longer in the saved roster) must be dropped on reload. Guards
    /// against a corrupt blob leaving the HUD stuck on a phantom.
    func testStoreStartDropsDanglingOccupiedVehicleId() async {
        let persistence = VehiclePersistence.inMemory
        try? persistence.save(.init(
            summonedVehicles: [],                // empty roster
            occupiedVehicleId: UUID()            // stale id
        ))

        let store = VehicleStore(eventBus: EventBus(), persistence: persistence)
        await store.start()

        XCTAssertNil(store.occupiedVehicleId,
                     "dangling occupiedVehicleId should be dropped")
    }
}
