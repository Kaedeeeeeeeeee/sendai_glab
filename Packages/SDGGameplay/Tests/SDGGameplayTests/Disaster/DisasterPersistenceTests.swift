// DisasterPersistenceTests.swift
// SDGGameplayTests · Disaster
//
// Covers `DisasterPersistence` round-trips for the `.idle` blob,
// mid-earthquake snapshots, and the `triggeredQuestIds` dedupe set.
// Plus the Store-side "survive a reload" integration for the
// quest-triggered guard.

import XCTest
import Foundation
import SDGCore
@testable import SDGGameplay

@MainActor
final class DisasterPersistenceTests: XCTestCase {

    private func makeScopedDefaults(
        _ label: String = #function
    ) throws -> (UserDefaults, String) {
        let suiteName = "sdg.disaster.tests.\(label).\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            XCTFail("could not create scoped UserDefaults suite")
            throw XCTSkip("UserDefaults(suiteName:) returned nil")
        }
        return (defaults, suiteName)
    }

    // MARK: - inMemory backend

    func testInMemoryRoundTripForIdleState() throws {
        let persistence = DisasterPersistence.inMemory
        try persistence.save(.empty)
        let loaded = try persistence.load()
        XCTAssertEqual(loaded, .empty)
        XCTAssertEqual(loaded.state, .idle)
    }

    func testInMemoryRoundTripForMidEarthquakeState() throws {
        let persistence = DisasterPersistence.inMemory
        let snapshot = DisasterPersistence.Snapshot(
            state: .earthquakeActive(
                remaining: 1.25,
                intensity: 0.5,
                questId: "q.aobayama.quake"
            ),
            triggeredQuestIds: ["q.aobayama.quake"]
        )

        try persistence.save(snapshot)
        let loaded = try persistence.load()

        XCTAssertEqual(loaded, snapshot)
        if case let .earthquakeActive(remaining, intensity, questId) = loaded.state {
            XCTAssertEqual(remaining, 1.25, accuracy: 1e-5)
            XCTAssertEqual(intensity, 0.5, accuracy: 1e-5)
            XCTAssertEqual(questId, "q.aobayama.quake")
        } else {
            XCTFail("expected .earthquakeActive, got \(loaded.state)")
        }
    }

    func testSchemaKeyIsVersioned() {
        XCTAssertEqual(DisasterPersistence.schemaKey, "sdg.disaster.v1")
    }

    // MARK: - UserDefaults backend

    func testUserDefaultsLoadThrowsOnCorruptPayload() throws {
        let (defaults, suiteName) = try makeScopedDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        defaults.set(
            Data([0xDE, 0xAD, 0xBE, 0xEF]),
            forKey: DisasterPersistence.schemaKey
        )
        let persistence = DisasterPersistence.userDefaults(defaults)

        XCTAssertThrowsError(try persistence.load()) { error in
            XCTAssertTrue(error is DecodingError,
                          "expected DecodingError, got \(error)")
        }
    }

    func testUserDefaultsRoundTripPreservesTriggeredQuestIds() throws {
        let (defaults, suiteName) = try makeScopedDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let persistence = DisasterPersistence.userDefaults(defaults)
        let snapshot = DisasterPersistence.Snapshot(
            state: .idle,
            triggeredQuestIds: ["q.a", "q.b", "q.c"]
        )

        try persistence.save(snapshot)
        let loaded = try persistence.load()

        XCTAssertEqual(loaded.triggeredQuestIds, ["q.a", "q.b", "q.c"])
    }

    // MARK: - Store integration

    /// `.markQuestTriggered` must survive across reloads so a
    /// quest-driven disaster never re-fires on the second launch.
    func testStoreMarkQuestTriggeredSurvivesReload() async {
        let persistence = DisasterPersistence.inMemory

        let writer = DisasterStore(
            eventBus: EventBus(),
            persistence: persistence
        )
        await writer.intent(.markQuestTriggered(questId: "q.kawauchi"))
        XCTAssertTrue(writer.triggeredQuestIds.contains("q.kawauchi"))

        // Fresh Store, same persistence — simulates app reload.
        let reloaded = DisasterStore(
            eventBus: EventBus(),
            persistence: persistence
        )
        await reloaded.start()

        XCTAssertTrue(
            reloaded.triggeredQuestIds.contains("q.kawauchi"),
            "quest trigger set must be hydrated on Store.start()"
        )
    }

    /// Idempotency guard: marking the same quest twice does not
    /// duplicate writes in a way that breaks Set semantics.
    func testStoreMarkQuestTriggeredIsIdempotent() async {
        let persistence = DisasterPersistence.inMemory
        let store = DisasterStore(
            eventBus: EventBus(),
            persistence: persistence
        )

        await store.intent(.markQuestTriggered(questId: "q.once"))
        await store.intent(.markQuestTriggered(questId: "q.once"))

        XCTAssertEqual(store.triggeredQuestIds.count, 1)
        XCTAssertTrue(store.triggeredQuestIds.contains("q.once"))
    }
}
