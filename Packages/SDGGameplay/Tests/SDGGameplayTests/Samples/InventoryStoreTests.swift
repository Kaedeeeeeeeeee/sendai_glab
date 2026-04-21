// InventoryStoreTests.swift
// SDGGameplayTests
//
// End-to-end behavior of `InventoryStore` around the full three-layer
// loop: event published on the bus → store mutates → persistence
// receives the update. No SwiftUI here — stores are UI-framework-free
// per ADR-0001, and these tests prove it.

import XCTest
import SDGCore
@testable import SDGGameplay

@MainActor
final class InventoryStoreTests: XCTestCase {

    // MARK: - Fixture builder

    /// Emit one sample, with enough variation that tests can tell copies
    /// apart by id without crafting ids by hand.
    private func makeSample(depth: Float = 2.0) -> SampleItem {
        SampleItem(
            id: UUID(),
            drillLocation: SIMD3<Float>(0, 0, 0),
            drillDepth: depth,
            layers: [
                SampleLayerRecord(
                    layerId: "layer_a",
                    nameKey: "layer.a.name",
                    colorRGB: SIMD3<Float>(0.5, 0.5, 0.5),
                    thickness: depth,
                    entryDepth: 0
                )
            ]
        )
    }

    /// Publish a `SampleCreatedEvent` and give the bus a turn to dispatch.
    /// The bus awaits its handlers' tasks itself, so once `publish`
    /// returns we are guaranteed the handler has been *entered*; the
    /// handler then awaits the store's `@MainActor` hop, which is why we
    /// still yield once before asserting.
    private func publishSample(_ sample: SampleItem, on bus: EventBus) async {
        await bus.publish(SampleCreatedEvent(sample: sample))
        // Let pending MainActor-bound handler continuations run.
        await Task.yield()
    }

    // MARK: - Init + start

    func testInitialStateIsEmpty() {
        let bus = EventBus()
        let store = InventoryStore(eventBus: bus, persistence: .inMemory)
        XCTAssertTrue(store.samples.isEmpty)
        XCTAssertNil(store.selectedId)
    }

    func testStartHydratesFromPersistence() async throws {
        let bus = EventBus()
        let persistence = InventoryPersistence.inMemory
        // Pre-seed persistence with two samples.
        let seed = [makeSample(), makeSample()]
        try persistence.save(seed)

        let store = InventoryStore(eventBus: bus, persistence: persistence)
        await store.start()

        XCTAssertEqual(store.samples, seed)
    }

    // MARK: - Subscription: SampleCreatedEvent

    func testPublishingSampleCreatedAppendsToInventory() async {
        let bus = EventBus()
        let store = InventoryStore(eventBus: bus, persistence: .inMemory)
        await store.start()

        let sample = makeSample()
        await publishSample(sample, on: bus)

        XCTAssertEqual(store.samples.count, 1)
        XCTAssertEqual(store.samples.first?.id, sample.id)
    }

    func testPublishingMultipleSamplesPreservesOrder() async {
        let bus = EventBus()
        let store = InventoryStore(eventBus: bus, persistence: .inMemory)
        await store.start()

        let s1 = makeSample(depth: 1.0)
        let s2 = makeSample(depth: 2.0)
        let s3 = makeSample(depth: 3.0)

        await publishSample(s1, on: bus)
        await publishSample(s2, on: bus)
        await publishSample(s3, on: bus)

        XCTAssertEqual(store.samples.map(\.id), [s1.id, s2.id, s3.id])
    }

    func testPersistsAfterReceivingSampleCreated() async throws {
        let bus = EventBus()
        let persistence = InventoryPersistence.inMemory
        let store = InventoryStore(eventBus: bus, persistence: persistence)
        await store.start()

        let sample = makeSample()
        await publishSample(sample, on: bus)

        let persisted = try persistence.load()
        XCTAssertEqual(persisted.count, 1)
        XCTAssertEqual(persisted.first?.id, sample.id)
    }

    func testStopDetachesSubscription() async {
        let bus = EventBus()
        let store = InventoryStore(eventBus: bus, persistence: .inMemory)
        await store.start()
        await store.stop()

        // After stop(), no subscriber should remain for this event type.
        let subscriberCount = await bus.subscriberCount(for: SampleCreatedEvent.self)
        XCTAssertEqual(subscriberCount, 0)

        // And a new publish must not mutate the store.
        await publishSample(makeSample(), on: bus)
        XCTAssertTrue(store.samples.isEmpty)
    }

    func testStopIsIdempotent() async {
        let bus = EventBus()
        let store = InventoryStore(eventBus: bus, persistence: .inMemory)
        await store.start()
        await store.stop()
        await store.stop()
        // No assertion beyond "does not crash / hang" — repeated stops
        // are a common teardown pattern worth pinning explicitly.
    }

    // MARK: - Intents

    func testSelectIntentUpdatesSelection() async {
        let bus = EventBus()
        let store = InventoryStore(eventBus: bus, persistence: .inMemory)
        await store.start()

        let sample = makeSample()
        await publishSample(sample, on: bus)
        await store.intent(.select(sample.id))

        XCTAssertEqual(store.selectedId, sample.id)

        await store.intent(.select(nil))
        XCTAssertNil(store.selectedId)
    }

    func testDeleteIntentRemovesSample() async {
        let bus = EventBus()
        let store = InventoryStore(eventBus: bus, persistence: .inMemory)
        await store.start()

        let a = makeSample()
        let b = makeSample()
        await publishSample(a, on: bus)
        await publishSample(b, on: bus)

        await store.intent(.delete(a.id))

        XCTAssertEqual(store.samples.map(\.id), [b.id])
    }

    func testDeleteClearsSelectionWhenSelectedRemoved() async {
        let bus = EventBus()
        let store = InventoryStore(eventBus: bus, persistence: .inMemory)
        await store.start()

        let sample = makeSample()
        await publishSample(sample, on: bus)
        await store.intent(.select(sample.id))

        await store.intent(.delete(sample.id))

        XCTAssertNil(store.selectedId, "selection must follow deletion")
        XCTAssertTrue(store.samples.isEmpty)
    }

    func testDeleteKeepsSelectionWhenUnrelatedRemoved() async {
        let bus = EventBus()
        let store = InventoryStore(eventBus: bus, persistence: .inMemory)
        await store.start()

        let a = makeSample()
        let b = makeSample()
        await publishSample(a, on: bus)
        await publishSample(b, on: bus)
        await store.intent(.select(a.id))

        await store.intent(.delete(b.id))

        XCTAssertEqual(store.selectedId, a.id)
    }

    func testClearAllIntentEmptiesSamplesAndSelection() async {
        let bus = EventBus()
        let store = InventoryStore(eventBus: bus, persistence: .inMemory)
        await store.start()

        let sample = makeSample()
        await publishSample(sample, on: bus)
        await store.intent(.select(sample.id))

        await store.intent(.clearAll)

        XCTAssertTrue(store.samples.isEmpty)
        XCTAssertNil(store.selectedId)
    }

    func testUpdateNoteIntentChangesNote() async {
        let bus = EventBus()
        let store = InventoryStore(eventBus: bus, persistence: .inMemory)
        await store.start()

        let sample = makeSample()
        await publishSample(sample, on: bus)

        await store.intent(.updateNote(sample.id, "mica-rich, unusual"))
        XCTAssertEqual(store.samples.first?.customNote, "mica-rich, unusual")

        await store.intent(.updateNote(sample.id, nil))
        XCTAssertNil(store.samples.first?.customNote)
    }

    func testUpdateNoteOnUnknownIdIsNoOp() async {
        let bus = EventBus()
        let store = InventoryStore(eventBus: bus, persistence: .inMemory)
        await store.start()

        await store.intent(.updateNote(UUID(), "ghost note"))
        XCTAssertTrue(store.samples.isEmpty)
    }

    // MARK: - Persistence integration

    func testIntentsArePersisted() async throws {
        let bus = EventBus()
        let persistence = InventoryPersistence.inMemory
        let store = InventoryStore(eventBus: bus, persistence: persistence)
        await store.start()

        let a = makeSample()
        let b = makeSample()
        await publishSample(a, on: bus)
        await publishSample(b, on: bus)

        await store.intent(.delete(a.id))

        let persisted = try persistence.load()
        XCTAssertEqual(persisted.map(\.id), [b.id])

        await store.intent(.clearAll)
        XCTAssertTrue(try persistence.load().isEmpty)
    }

    func testSelectIntentDoesNotNeedToPersist() async throws {
        // `.select` is pure UI state; forcing a disk write on every tap
        // would be wasteful. Pin the current behavior.
        let bus = EventBus()
        let persistence = InventoryPersistence.inMemory
        let store = InventoryStore(eventBus: bus, persistence: persistence)
        await store.start()

        let sample = makeSample()
        await publishSample(sample, on: bus)

        // Baseline: one save from the publish above.
        let baseline = try persistence.load()
        XCTAssertEqual(baseline.count, 1)

        // Select — persistence content should not change.
        await store.intent(.select(sample.id))
        let after = try persistence.load()
        XCTAssertEqual(after, baseline)
    }
}
