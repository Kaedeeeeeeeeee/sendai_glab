// InventoryPersistenceTests.swift
// SDGGameplayTests
//
// Exercises the `InventoryPersistence` façade's save/load contract for
// every backend the tests can isolate: `.inMemory` and a scoped
// `UserDefaults` suite that we purge at teardown. The `.standard`
// backend is deliberately *not* covered here — it would pollute the
// real defaults database and couple tests to machine state.

import XCTest
@testable import SDGGameplay

final class InventoryPersistenceTests: XCTestCase {

    // MARK: - Fixture builder

    /// Build `count` samples with distinct ids and slightly varied data
    /// so a silent index-off-by-one bug in the codec would show up.
    private func makeSamples(count: Int) -> [SampleItem] {
        var result: [SampleItem] = []
        result.reserveCapacity(count)
        for i in 0..<count {
            let note: String? = i.isMultiple(of: 2) ? "note \(i)" : nil
            let layer = SampleLayerRecord(
                layerId: "layer_\(i)",
                nameKey: "layer.\(i).name",
                colorRGB: SIMD3<Float>(0.1 * Float(i), 0.2, 0.3),
                thickness: 0.5,
                entryDepth: 0.0
            )
            let sample = SampleItem(
                id: UUID(),
                createdAt: Date(timeIntervalSince1970: 1_700_000_000 + Double(i)),
                drillLocation: SIMD3<Float>(Float(i), Float(i) * 0.5, -Float(i)),
                drillDepth: Float(i) + 1.0,
                layers: [layer],
                customNote: note
            )
            result.append(sample)
        }
        return result
    }

    // MARK: - inMemory backend

    func testInMemoryRoundTripPreservesTenSamples() throws {
        let persistence = InventoryPersistence.inMemory
        let samples = makeSamples(count: 10)

        try persistence.save(samples)
        let loaded = try persistence.load()

        XCTAssertEqual(loaded, samples)
    }

    func testInMemoryLoadOnEmptyReturnsEmptyArray() throws {
        let persistence = InventoryPersistence.inMemory
        let loaded = try persistence.load()
        XCTAssertTrue(loaded.isEmpty)
    }

    func testInMemorySaveIsIsolatedPerInstance() throws {
        // Each `.inMemory` accessor hands out a fresh backend — a leak
        // between tests would make failures non-deterministic.
        let a = InventoryPersistence.inMemory
        let b = InventoryPersistence.inMemory

        try a.save(makeSamples(count: 3))

        XCTAssertEqual(try a.load().count, 3)
        XCTAssertEqual(try b.load().count, 0)
    }

    func testInMemorySaveOverwrites() throws {
        let persistence = InventoryPersistence.inMemory
        let first = makeSamples(count: 5)
        let second = makeSamples(count: 2)

        try persistence.save(first)
        try persistence.save(second)

        let loaded = try persistence.load()
        XCTAssertEqual(loaded, second, "save must replace, not append")
    }

    // MARK: - UserDefaults backend (isolated suite)

    /// Build a `UserDefaults` suite with a unique name so concurrent test
    /// runs don't collide, and make sure we nuke it at teardown.
    private func makeScopedDefaults(
        _ label: String = #function
    ) throws -> (UserDefaults, String) {
        let suiteName = "sdg.inventory.tests.\(label).\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            XCTFail("could not create scoped UserDefaults suite")
            throw XCTSkip("UserDefaults(suiteName:) returned nil")
        }
        return (defaults, suiteName)
    }

    func testUserDefaultsRoundTripPreservesTenSamples() throws {
        let (defaults, suiteName) = try makeScopedDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let persistence = InventoryPersistence.userDefaults(defaults)
        let samples = makeSamples(count: 10)

        try persistence.save(samples)
        let loaded = try persistence.load()

        XCTAssertEqual(loaded, samples)
    }

    func testUserDefaultsLoadWhenKeyMissingReturnsEmpty() throws {
        let (defaults, suiteName) = try makeScopedDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let persistence = InventoryPersistence.userDefaults(defaults)
        let loaded = try persistence.load()

        XCTAssertTrue(loaded.isEmpty)
    }

    func testUserDefaultsLoadThrowsOnCorruptPayload() throws {
        let (defaults, suiteName) = try makeScopedDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        // Plant a non-JSON blob under the persistence key.
        defaults.set(Data([0xDE, 0xAD, 0xBE, 0xEF]), forKey: InventoryPersistence.schemaKey)

        let persistence = InventoryPersistence.userDefaults(defaults)
        XCTAssertThrowsError(try persistence.load()) { error in
            // Any DecodingError is fine; the point is: no silent zero.
            XCTAssertTrue(error is DecodingError, "expected DecodingError, got \(error)")
        }
    }

    func testSchemaKeyIsVersioned() {
        // Pin the key so a future schema bump is an intentional choice,
        // not an accidental string tweak that silently wipes inventories.
        XCTAssertEqual(InventoryPersistence.schemaKey, "sdg.inventory.v1")
    }

    func testUserDefaultsSaveOverwritesPriorPayload() throws {
        let (defaults, suiteName) = try makeScopedDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let persistence = InventoryPersistence.userDefaults(defaults)

        try persistence.save(makeSamples(count: 5))
        try persistence.save(makeSamples(count: 1))

        let loaded = try persistence.load()
        XCTAssertEqual(loaded.count, 1)
    }
}
