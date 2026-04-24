// StratigraphicColumnTests.swift
// SDGGameplay · Geology
//
// Phase 9 Part B tests for the `StratigraphicColumn` / `StratigraphicLayer`
// JSON contract and the slab-clipping arithmetic that hands off to
// `GeologyDetectionSystem.computeIntersections(...)`.
//
// Kept framework-free: every test here constructs values in Swift
// (no bundle loading, no RealityKit). The on-disk JSON round-trip is
// exercised in `GeologyRegionRegistryTests` so this file can pin the
// maths without caring about file-system layouts.

import XCTest
@testable import SDGGameplay

final class StratigraphicColumnTests: XCTestCase {

    // MARK: - Fixture helpers

    /// Single-layer fixture with a basement layer. Thickness values
    /// are chosen so the clipping tests below can assert on exact
    /// integer boundaries — no float epsilon soup.
    private func fixture() -> StratigraphicColumn {
        StratigraphicColumn(
            regionId: "test-region",
            nameKey: "geology.region.test-region.name",
            source: "unit test",
            confidence: "test",
            layers: [
                StratigraphicLayer(
                    id: "test-region.topsoil",
                    nameKey: "geology.layer.topsoil.name",
                    thickness: 1,
                    colorHex: "#6B4C2F",
                    lithology: "soil"
                ),
                StratigraphicLayer(
                    id: "test-region.upper",
                    nameKey: "geology.layer.upper.name",
                    thickness: 3,
                    colorHex: "#D4B366",
                    lithology: "sandstone"
                ),
                StratigraphicLayer(
                    id: "test-region.lower",
                    nameKey: "geology.layer.lower.name",
                    thickness: 2,
                    colorHex: "#4A4A52",
                    lithology: "mudstone"
                ),
                StratigraphicLayer(
                    id: "test-region.basement",
                    nameKey: "geology.layer.basement.name",
                    thickness: 0,  // basement absorbs the remainder
                    colorHex: "#2F2F35",
                    lithology: "basement"
                )
            ]
        )
    }

    // MARK: - Codable

    /// Column JSON must round-trip every field. If this breaks, the
    /// shipped region JSONs silently lose data on load — the kind of
    /// bug that only bites on device.
    func testColumnCodableRoundTrip() throws {
        let original = fixture()
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(
            StratigraphicColumn.self,
            from: data
        )
        XCTAssertEqual(decoded, original)
    }

    /// Layer JSON round-trip, exercised independently because the
    /// layer is decoded by the registry independently when it scans a
    /// malformed column and wants to pinpoint a bad entry.
    func testLayerCodableRoundTrip() throws {
        let layer = StratigraphicLayer(
            id: "x.y",
            nameKey: "geology.layer.y.name",
            thickness: 5.5,
            colorHex: "#ABCDEF",
            lithology: "tuff"
        )
        let data = try JSONEncoder().encode(layer)
        let decoded = try JSONDecoder().decode(
            StratigraphicLayer.self,
            from: data
        )
        XCTAssertEqual(decoded, layer)
    }

    // MARK: - colorRGB parsing

    /// Hex parsing honours the leading `#` and yields a 0…1 RGB
    /// triple. Uses pure white so the arithmetic is unambiguous.
    func testLayerColorRGBFromValidHex() {
        let layer = StratigraphicLayer(
            id: "x", nameKey: "k", thickness: 1,
            colorHex: "#FFFFFF", lithology: "-"
        )
        XCTAssertEqual(layer.colorRGB, SIMD3<Float>(1, 1, 1))
    }

    /// Leading `#` must be optional — Unity ports and older JSONs
    /// sometimes omit it.
    func testLayerColorRGBWithoutHashPrefix() {
        let layer = StratigraphicLayer(
            id: "x", nameKey: "k", thickness: 1,
            colorHex: "000000", lithology: "-"
        )
        XCTAssertEqual(layer.colorRGB, SIMD3<Float>(0, 0, 0))
    }

    /// Malformed hex must degrade gracefully to neutral grey. A single
    /// typo in a 4 KB JSON should not blank out a whole tile.
    func testLayerColorRGBMalformedReturnsGrey() {
        let layer = StratigraphicLayer(
            id: "x", nameKey: "k", thickness: 1,
            colorHex: "#NOTHEX", lithology: "-"
        )
        XCTAssertEqual(layer.colorRGB, SIMD3<Float>(0.5, 0.5, 0.5))
    }

    // MARK: - clipToSlabs

    /// A deep drill should cover every declared layer: 1 + 3 + 2 = 6 m,
    /// and the basement absorbs the remainder (up to `maxDepth`).
    /// Surfacing at Y = 100 with `maxDepth` = 20 leaves the basement
    /// 14 m thick (20 − 1 − 3 − 2).
    func testClipToSlabsDeepDrillCoversAllLayers() {
        let column = fixture()
        let slabs = column.clipToSlabs(
            surfaceY: 100,
            maxDepth: 20,
            xzCenter: SIMD2<Float>(5, 7)
        )
        XCTAssertEqual(slabs.count, 4)
        XCTAssertEqual(slabs[0].layerId, "test-region.topsoil")
        XCTAssertEqual(slabs[0].topY, 100, accuracy: 1e-4)
        XCTAssertEqual(slabs[0].bottomY, 99, accuracy: 1e-4)

        XCTAssertEqual(slabs[1].layerId, "test-region.upper")
        XCTAssertEqual(slabs[1].topY, 99, accuracy: 1e-4)
        XCTAssertEqual(slabs[1].bottomY, 96, accuracy: 1e-4)

        XCTAssertEqual(slabs[2].layerId, "test-region.lower")
        XCTAssertEqual(slabs[2].topY, 96, accuracy: 1e-4)
        XCTAssertEqual(slabs[2].bottomY, 94, accuracy: 1e-4)

        // Basement is absorbed by `maxDepth`: surface − maxDepth = 80.
        XCTAssertEqual(slabs[3].layerId, "test-region.basement")
        XCTAssertEqual(slabs[3].topY, 94, accuracy: 1e-4)
        XCTAssertEqual(slabs[3].bottomY, 80, accuracy: 1e-4)

        // xzCenter stamped on every slab so non-vertical future drills
        // can reconstruct entry/exit XZs without a second lookup.
        XCTAssertEqual(slabs[0].xzCenter, SIMD2<Float>(5, 7))
    }

    /// A shallow drill should terminate mid-stack. Surfacing at
    /// Y = 10 with `maxDepth` = 2 reaches 8; the topsoil (1 m) runs
    /// into the upper layer, which is clipped at the drill floor.
    func testClipToSlabsShallowDrillTerminatesMidStack() {
        let column = fixture()
        let slabs = column.clipToSlabs(
            surfaceY: 10,
            maxDepth: 2,
            xzCenter: SIMD2<Float>(0, 0)
        )
        XCTAssertEqual(slabs.count, 2)
        XCTAssertEqual(slabs[0].layerId, "test-region.topsoil")
        XCTAssertEqual(slabs[0].topY, 10, accuracy: 1e-4)
        XCTAssertEqual(slabs[0].bottomY, 9, accuracy: 1e-4)

        // Upper layer nominal bottom at 6 but drill floor is 8.
        XCTAssertEqual(slabs[1].layerId, "test-region.upper")
        XCTAssertEqual(slabs[1].topY, 9, accuracy: 1e-4)
        XCTAssertEqual(slabs[1].bottomY, 8, accuracy: 1e-4)
    }

    /// A zero-or-negative `maxDepth` short-circuits to an empty list:
    /// the detector treats negative depth as "no drill ran", so the
    /// clipper must agree.
    func testClipToSlabsZeroDepthReturnsEmpty() {
        let column = fixture()
        XCTAssertTrue(column.clipToSlabs(
            surfaceY: 100,
            maxDepth: 0,
            xzCenter: .zero
        ).isEmpty)
        XCTAssertTrue(column.clipToSlabs(
            surfaceY: 100,
            maxDepth: -5,
            xzCenter: .zero
        ).isEmpty)
    }

    /// Empty layer list → empty slab list; guards against an
    /// accidental crash if a broken JSON produces a column with no
    /// layers (the registry's `validate` rejects these, but the
    /// clipper is also the right place for defensive termination).
    func testClipToSlabsEmptyColumnReturnsEmpty() {
        let column = StratigraphicColumn(
            regionId: "empty",
            nameKey: "k",
            source: "-",
            confidence: "-",
            layers: []
        )
        XCTAssertTrue(column.clipToSlabs(
            surfaceY: 100,
            maxDepth: 10,
            xzCenter: .zero
        ).isEmpty)
    }

    /// Top-to-bottom ordering: the returned slabs must already be in
    /// the order the detector wants (`topY` descending). This invariant
    /// lets the detector keep its cheap single-pass loop.
    func testClipToSlabsOrderedTopDown() {
        let slabs = fixture().clipToSlabs(
            surfaceY: 50,
            maxDepth: 10,
            xzCenter: .zero
        )
        for i in 1..<slabs.count {
            XCTAssertGreaterThanOrEqual(
                slabs[i - 1].topY, slabs[i].topY,
                "slab \(i) breaks top-down ordering"
            )
        }
    }
}
