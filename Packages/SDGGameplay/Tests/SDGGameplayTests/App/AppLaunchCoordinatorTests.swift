// AppLaunchCoordinatorTests.swift
// SDGGameplayTests · App
//
// Tests the startup orchestration: `launch(stores:)` must hydrate
// every Store from its injected `.inMemory` persistence and start
// their subscriptions in an order that doesn't drop fan-out events.

import XCTest
import Foundation
import SDGCore
@testable import SDGGameplay

@MainActor
final class AppLaunchCoordinatorTests: XCTestCase {

    // MARK: - Fixtures

    /// Bundle matching what `AppLaunchCoordinator.launch(stores:)`
    /// expects. Factored out so each test case starts from an
    /// identical baseline.
    private func makeStores(bus: EventBus) -> AppLaunchCoordinator.Stores {
        .init(
            player: PlayerControlStore(eventBus: bus),
            inventory: InventoryStore(eventBus: bus, persistence: .inMemory),
            drilling: DrillingStore(eventBus: bus),
            quest: QuestStore(eventBus: bus, persistence: .inMemory),
            dialogue: DialogueStore(eventBus: bus),
            workbench: WorkbenchStore(eventBus: bus),
            vehicle: VehicleStore(eventBus: bus, persistence: .inMemory),
            disaster: DisasterStore(eventBus: bus, persistence: .inMemory)
        )
    }

    // MARK: - launch()

    /// `launch` completes without throwing on a stock empty-persistence
    /// environment — the "first app launch ever" case.
    func testLaunchOnFirstRunCompletesCleanly() async {
        let bus = EventBus()
        let coordinator = AppLaunchCoordinator(
            eventBus: bus,
            persistences: .inMemory
        )
        let stores = makeStores(bus: bus)

        await coordinator.launch(stores: stores)

        // Nothing was pre-seeded, so every Store should be at its
        // documented initial state after hydrate.
        XCTAssertTrue(stores.inventory.samples.isEmpty)
        XCTAssertTrue(stores.vehicle.summonedVehicles.isEmpty)
        XCTAssertEqual(stores.disaster.state, .idle)
    }

    /// A vehicle pre-seeded in the persistence must be rehydrated by
    /// `launch` AND republished as a `VehicleSummoned` so a scene-side
    /// subscriber (the real app's RootView analogue) can rebuild the
    /// entity. This is the core replay semantic of the coordinator.
    func testLaunchRepublishesVehicleSummonedFromSavedSnapshot() async {
        let bus = EventBus()

        // Subscribe BEFORE launching — mirrors the RootView contract
        // documented in E.md.
        let recorder = EventRecorder<VehicleSummoned>()
        let token = await bus.subscribe(VehicleSummoned.self) { event in
            await recorder.record(event)
        }

        // Seed the vehicle persistence with a pre-existing snapshot.
        let vehiclePersistence = VehiclePersistence.inMemory
        let savedId = UUID()
        try? vehiclePersistence.save(.init(
            summonedVehicles: [
                .init(id: savedId, type: .drone, position: SIMD3<Float>(5, 2, 1))
            ],
            occupiedVehicleId: nil
        ))

        let coordinator = AppLaunchCoordinator(
            eventBus: bus,
            persistences: .init(
                inventory: .inMemory,
                quest: .inMemory,
                vehicle: vehiclePersistence,
                disaster: .inMemory,
                playerPosition: .inMemory
            )
        )
        let stores = AppLaunchCoordinator.Stores(
            player: PlayerControlStore(eventBus: bus),
            inventory: InventoryStore(eventBus: bus, persistence: .inMemory),
            drilling: DrillingStore(eventBus: bus),
            quest: QuestStore(eventBus: bus, persistence: .inMemory),
            dialogue: DialogueStore(eventBus: bus),
            workbench: WorkbenchStore(eventBus: bus),
            vehicle: VehicleStore(eventBus: bus, persistence: vehiclePersistence),
            disaster: DisasterStore(eventBus: bus, persistence: .inMemory)
        )

        await coordinator.launch(stores: stores)
        // Two yields so MainActor continuations in the bus handler land.
        await Task.yield()
        await Task.yield()

        let events = await recorder.all
        XCTAssertEqual(events.count, 1, "one saved vehicle → one VehicleSummoned")
        XCTAssertEqual(events.first?.vehicleId, savedId)
        XCTAssertEqual(events.first?.vehicleType, .drone)
        XCTAssertEqual(stores.vehicle.summonedVehicles.count, 1)

        await bus.cancel(token)
    }

    /// Disaster `triggeredQuestIds` saved across reloads must land
    /// back in the Store after `launch`.
    func testLaunchHydratesDisasterTriggeredQuestIds() async {
        let bus = EventBus()
        let disasterPersistence = DisasterPersistence.inMemory
        try? disasterPersistence.save(.init(
            state: .idle,
            triggeredQuestIds: ["q.kawauchi", "q.aobayama"]
        ))

        let coordinator = AppLaunchCoordinator(
            eventBus: bus,
            persistences: .init(
                inventory: .inMemory,
                quest: .inMemory,
                vehicle: .inMemory,
                disaster: disasterPersistence,
                playerPosition: .inMemory
            )
        )
        let stores = AppLaunchCoordinator.Stores(
            player: PlayerControlStore(eventBus: bus),
            inventory: InventoryStore(eventBus: bus, persistence: .inMemory),
            drilling: DrillingStore(eventBus: bus),
            quest: QuestStore(eventBus: bus, persistence: .inMemory),
            dialogue: DialogueStore(eventBus: bus),
            workbench: WorkbenchStore(eventBus: bus),
            vehicle: VehicleStore(eventBus: bus, persistence: .inMemory),
            disaster: DisasterStore(eventBus: bus, persistence: disasterPersistence)
        )

        await coordinator.launch(stores: stores)

        XCTAssertEqual(
            stores.disaster.triggeredQuestIds,
            ["q.kawauchi", "q.aobayama"]
        )
    }

    // MARK: - Player position helpers

    /// `loadPlayerPosition` returns `nil` on first launch; `save` +
    /// `load` round-trip through the injected persistence.
    func testPlayerPositionSaveLoadRoundTripsThroughCoordinator() async {
        let playerPersistence = PlayerPositionPersistence.inMemory
        let coordinator = AppLaunchCoordinator(
            eventBus: EventBus(),
            persistences: .init(
                inventory: .inMemory,
                quest: .inMemory,
                vehicle: .inMemory,
                disaster: .inMemory,
                playerPosition: playerPersistence
            )
        )

        XCTAssertNil(coordinator.loadPlayerPosition(),
                     "first launch must report 'no saved pose'")

        let snapshot = PlayerPositionPersistence.Snapshot(
            position: SIMD3<Float>(10, 1.6, -3),
            yawRadians: .pi / 6
        )
        coordinator.savePlayerPosition(snapshot)

        XCTAssertEqual(coordinator.loadPlayerPosition(), snapshot)
    }
}

// MARK: - Support

/// Actor-isolated recorder for event-bus assertions. Duplicated from
/// the sibling test files because Swift's file-scoped `private`
/// prevents reuse across them; copying is cheaper than introducing a
/// shared test-fixture module.
private actor EventRecorder<E: Sendable> {
    private var events: [E] = []

    func record(_ event: E) {
        events.append(event)
    }

    var all: [E] { events }
}
