// SampleItemTests.swift
// SDGGameplayTests
//
// Value-type guarantees for `SampleItem`: identifier uniqueness and
// lossless Codable round-trips through `JSONEncoder` / `JSONDecoder`.

import XCTest
@testable import SDGGameplay

final class SampleItemTests: XCTestCase {

    // MARK: - Helpers

    /// Build a representative sample with non-trivial floats, a couple of
    /// layers, and a note, so the round-trip check covers every field.
    private func makeSample(
        id: UUID = UUID(),
        note: String? = "test note"
    ) -> SampleItem {
        SampleItem(
            id: id,
            // Fixed timestamp so we can compare bit-for-bit after JSON.
            createdAt: Date(timeIntervalSince1970: 1_713_600_000),
            drillLocation: SIMD3<Float>(1.5, -2.25, 3.75),
            drillDepth: 4.5,
            layers: [
                SampleLayerRecord(
                    layerId: "sandstone_upper",
                    nameKey: "layer.sandstone_upper.name",
                    colorRGB: SIMD3<Float>(0.82, 0.65, 0.40),
                    thickness: 1.2,
                    entryDepth: 0.0
                ),
                SampleLayerRecord(
                    layerId: "shale_mid",
                    nameKey: "layer.shale_mid.name",
                    colorRGB: SIMD3<Float>(0.30, 0.32, 0.38),
                    thickness: 0.8,
                    entryDepth: 1.2
                )
            ],
            customNote: note
        )
    }

    // MARK: - Codable round-trip

    func testCodableRoundTripPreservesAllFields() throws {
        let original = makeSample()

        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(SampleItem.self, from: data)

        XCTAssertEqual(decoded.id, original.id)
        XCTAssertEqual(decoded.createdAt, original.createdAt)
        XCTAssertEqual(decoded.drillLocation, original.drillLocation)
        XCTAssertEqual(decoded.drillDepth, original.drillDepth)
        XCTAssertEqual(decoded.layers, original.layers)
        XCTAssertEqual(decoded.customNote, original.customNote)
        // `Hashable`/`Equatable` are derived from all stored fields, so
        // this whole-value compare is the strongest single assertion.
        XCTAssertEqual(decoded, original)
    }

    func testCodableRoundTripWithNilNote() throws {
        let original = makeSample(note: nil)

        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(SampleItem.self, from: data)

        XCTAssertNil(decoded.customNote)
        XCTAssertEqual(decoded, original)
    }

    func testCodableRoundTripWithEmptyLayers() throws {
        // An "air drill" — rare but legal.
        let original = SampleItem(
            drillLocation: SIMD3<Float>(0, 0, 0),
            drillDepth: 0.0,
            layers: []
        )

        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(SampleItem.self, from: data)

        XCTAssertTrue(decoded.layers.isEmpty)
        XCTAssertEqual(decoded, original)
    }

    // MARK: - Identity

    func testDefaultInitializerGeneratesDistinctIds() {
        // Two samples created back-to-back must not collide even though
        // every other field is equal — UUID is the stable identity.
        let a = SampleItem(
            drillLocation: SIMD3<Float>(0, 0, 0),
            drillDepth: 1.0,
            layers: []
        )
        let b = SampleItem(
            drillLocation: SIMD3<Float>(0, 0, 0),
            drillDepth: 1.0,
            layers: []
        )
        XCTAssertNotEqual(a.id, b.id)
    }

    func testDefaultDisplayNameKeyIsLocalizationKey() {
        // Locked so the inventory UI has a predictable key to localize.
        let sample = makeSample()
        XCTAssertEqual(sample.defaultDisplayNameKey, "sample.defaultName")
    }

    func testHashableInvariantAfterRoundTrip() throws {
        let original = makeSample()
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(SampleItem.self, from: data)

        // Round-trip must not perturb the hash.
        var hasher1 = Hasher()
        original.hash(into: &hasher1)
        var hasher2 = Hasher()
        decoded.hash(into: &hasher2)
        XCTAssertEqual(hasher1.finalize(), hasher2.finalize())
    }
}
