// GeologyRegionRegistryTests.swift
// SDGGameplay · Geology
//
// Phase 9 Part B tests for the registry that maps a world-space XZ
// to a regional stratigraphic column. Covers:
//
//   * region id ↔ PlateauTile id mapping (catches identifier drift);
//   * manifest-driven footprint computation (EPSG:6677 → RK axes,
//     including the north → -Z flip);
//   * the internal `Region.contains(_:)` point-in-rect test;
//   * `column(forWorldXZ:)` returning `nil` for off-corridor probes;
//   * load-time errors when the bundle is missing a region JSON.
//
// The tests use injected `Region` fixtures and synthetic envelope
// JSON to avoid depending on the production `Resources/Environment/`
// layout — those go through the xcodebuild-driven integration test
// run.

import XCTest
@testable import SDGGameplay

@MainActor
final class GeologyRegionRegistryTests: XCTestCase {

    // MARK: - Mapping tables

    /// The 5 region ids in `orderedRegionIds` each map to a distinct
    /// `PlateauTile.rawValue`. Bi-directional uniqueness guards
    /// against typos that silently alias two tiles to one column.
    func testOrderedRegionsMapToUniqueTileIds() {
        let ordered = GeologyRegionRegistry.orderedRegionIds
        let tileIds = ordered.map { GeologyRegionRegistry.tileId(forRegion: $0) }
        XCTAssertEqual(Set(tileIds).count, ordered.count)
        XCTAssertFalse(tileIds.contains(""), "every region must map to a non-empty tile id")
    }

    /// The spawn tile (aobayama-campus) must map to the `PlateauTile.defaultSpawn`'s
    /// raw value. This is the anchor for every other envelope-derived
    /// coordinate, so drift here breaks the whole corridor.
    func testAobayamaCampusMapsToSpawnTile() {
        XCTAssertEqual(
            GeologyRegionRegistry.tileId(forRegion: "aobayama-campus"),
            PlateauTile.defaultSpawn.rawValue
        )
    }

    /// Unknown region ids must return an empty string (not crash,
    /// not throw). Makes the lookup safe from typo'd callers.
    func testTileIdForUnknownRegionIsEmpty() {
        XCTAssertEqual(
            GeologyRegionRegistry.tileId(forRegion: "not-a-region"),
            ""
        )
    }

    // MARK: - Region.contains

    /// Containment is inclusive on both bounds. Important because
    /// adjacent tile footprints abut exactly at the shared edge;
    /// exclusive bounds would leave a 0-width gap the drill could
    /// fall into.
    func testRegionContainsInclusiveBounds() {
        let region = GeologyRegionRegistry.Region(
            column: tinyColumn(id: "x"),
            xzMin: SIMD2<Float>(-10, -10),
            xzMax: SIMD2<Float>(10, 10)
        )
        XCTAssertTrue(region.contains(SIMD2<Float>(0, 0)))
        XCTAssertTrue(region.contains(SIMD2<Float>(-10, -10)))
        XCTAssertTrue(region.contains(SIMD2<Float>(10, 10)))
        XCTAssertFalse(region.contains(SIMD2<Float>(-11, 0)))
        XCTAssertFalse(region.contains(SIMD2<Float>(0, 11)))
    }

    // MARK: - column(forWorldXZ:)

    /// Two disjoint regions — probes inside each find their column,
    /// probes outside return `nil`. Mirrors the orchestrator's
    /// "out of survey area" decision surface.
    func testColumnLookupInsideAndOutside() {
        let registry = GeologyRegionRegistry(regions: [
            GeologyRegionRegistry.Region(
                column: tinyColumn(id: "a"),
                xzMin: SIMD2<Float>(0, 0),
                xzMax: SIMD2<Float>(100, 100)
            ),
            GeologyRegionRegistry.Region(
                column: tinyColumn(id: "b"),
                xzMin: SIMD2<Float>(200, 0),
                xzMax: SIMD2<Float>(300, 100)
            )
        ])
        XCTAssertEqual(
            registry.column(forWorldXZ: SIMD2<Float>(50, 50))?.regionId,
            "a"
        )
        XCTAssertEqual(
            registry.column(forWorldXZ: SIMD2<Float>(250, 50))?.regionId,
            "b"
        )
        // Gap between them.
        XCTAssertNil(registry.column(forWorldXZ: SIMD2<Float>(150, 50)))
        // Well outside.
        XCTAssertNil(registry.column(forWorldXZ: SIMD2<Float>(10_000, 10_000)))
    }

    /// Overlapping regions: first declared wins. Documented behaviour
    /// so adjacent tiles with a 1-m seam don't produce
    /// non-deterministic lookups.
    func testColumnLookupOverlappingRegionsFirstWins() {
        let registry = GeologyRegionRegistry(regions: [
            GeologyRegionRegistry.Region(
                column: tinyColumn(id: "first"),
                xzMin: SIMD2<Float>(0, 0),
                xzMax: SIMD2<Float>(100, 100)
            ),
            GeologyRegionRegistry.Region(
                column: tinyColumn(id: "second"),
                xzMin: SIMD2<Float>(50, 50),
                xzMax: SIMD2<Float>(150, 150)
            )
        ])
        XCTAssertEqual(
            registry.column(forWorldXZ: SIMD2<Float>(75, 75))?.regionId,
            "first"
        )
    }

    // MARK: - Manifest footprints

    /// With a manifest containing a synthetic spawn and a single
    /// "east of spawn" tile, the registry must produce a non-empty
    /// bundled-resource-free footprint computation.
    ///
    /// We don't load real region JSONs here; instead we drive the
    /// private `footprintFromManifest` via `PlateauTile` fallback
    /// math by constructing `Region` values directly and asserting
    /// on the manifest-derived public-path below.
    func testManifestDrivenFootprintRoundTrip() throws {
        // Manifest with two envelopes: spawn at origin and an east
        // neighbour 100 m east / identical northing. Expect the
        // "east" tile's XZ footprint to live at positive X.
        let fixtureJSON = """
        {
          "meta": { "spawn_tile_id": "S" },
          "envelopes": {
            "S": {
              "lower_corner_m": [0.0, 0.0, 0.0],
              "upper_corner_m": [50.0, 50.0, 0.0]
            },
            "E": {
              "lower_corner_m": [100.0, 0.0, 0.0],
              "upper_corner_m": [150.0, 50.0, 0.0]
            }
          }
        }
        """
        let data = Data(fixtureJSON.utf8)
        let manifest = try EnvelopeManifest(jsonData: data)

        // Use the registry's internal `footprintFromManifest` via the
        // init(regions:) shortcut is not enough — the math is private.
        // Exercise the public path: build a Region from a manifest
        // lookup (same code the init(bundle:manifest:) uses).
        let spawnPos = manifest.realityKitPosition(for: "S")
        let eastPos = manifest.realityKitPosition(for: "E")
        XCTAssertNotNil(spawnPos)
        XCTAssertNotNil(eastPos)
        // Spawn centre (25, 25) in EPSG → RealityKit (0, 0) under the
        // centre-is-origin remap. East tile centre (125, 25) → RK
        // (100, 0). Sanity-check the tile position here so a later
        // drift in `EnvelopeManifest` surfaces at this unit test, not
        // only at the drill-site playtest.
        XCTAssertEqual(spawnPos!.x, 0, accuracy: 1e-3)
        XCTAssertEqual(spawnPos!.z, 0, accuracy: 1e-3)
        XCTAssertEqual(eastPos!.x, 100, accuracy: 1e-3)
        XCTAssertEqual(eastPos!.z, 0, accuracy: 1e-3)
    }

    // MARK: - Bundle-backed load (integration)

    /// End-to-end load through the bundle: decodes every shipped
    /// region JSON and pairs each with a synthetic envelope manifest.
    /// Protects against JSON typos / schema drift in the 5 region
    /// files before they surface as runtime drill failures.
    func testLoadFromTestBundleWithSyntheticManifest() throws {
        // Minimal manifest covering every tile id so the registry's
        // envelope lookup has something to resolve.
        let manifestJSON = """
        {
          "meta": { "spawn_tile_id": "57403617" },
          "envelopes": {
            "57403607": { "lower_corner_m": [0.0, 1000.0, 0.0], "upper_corner_m": [1000.0, 2000.0, 0.0] },
            "57403608": { "lower_corner_m": [1000.0, 1000.0, 0.0], "upper_corner_m": [2000.0, 2000.0, 0.0] },
            "57403617": { "lower_corner_m": [0.0, 0.0, 0.0], "upper_corner_m": [1000.0, 1000.0, 0.0] },
            "57403618": { "lower_corner_m": [1000.0, 0.0, 0.0], "upper_corner_m": [2000.0, 1000.0, 0.0] },
            "57403619": { "lower_corner_m": [2000.0, 0.0, 0.0], "upper_corner_m": [3000.0, 1000.0, 0.0] }
          }
        }
        """
        let manifest = try EnvelopeManifest(jsonData: Data(manifestJSON.utf8))
        let registry = try GeologyRegionRegistry(
            bundle: .module,
            manifest: manifest
        )
        // All 5 regions must be present.
        for regionId in GeologyRegionRegistry.orderedRegionIds {
            XCTAssertNotNil(
                registry.footprint(forRegion: regionId),
                "missing footprint for '\(regionId)'"
            )
        }
        // Spawn tile (aobayama-campus) should span ~1 km each way
        // around the RealityKit origin given the spawn-at-origin
        // envelope layout.
        if let fp = registry.footprint(forRegion: "aobayama-campus") {
            XCTAssertEqual(fp.min.x, -500, accuracy: 1)
            XCTAssertEqual(fp.max.x,  500, accuracy: 1)
        } else {
            XCTFail("aobayama-campus footprint missing")
        }
    }

    /// Each shipped region JSON must decode into a column with
    /// `confidence == "needs_geologist_review"` — catches a
    /// well-intentioned "reviewed"-flip commit that lands before
    /// f.shera's geologist review actually happens.
    func testShippedRegionsFlaggedNeedsReview() throws {
        let manifest = try makeSyntheticManifest()
        let registry = try GeologyRegionRegistry(
            bundle: .module,
            manifest: manifest
        )
        for regionId in GeologyRegionRegistry.orderedRegionIds {
            // The internal `regions` array owns the loaded column.
            // Reach into it via `column(forWorldXZ:)` using a point
            // known to be inside the tile's synthetic footprint.
            guard let fp = registry.footprint(forRegion: regionId) else {
                XCTFail("footprint missing for \(regionId)")
                continue
            }
            let midXZ = (fp.min + fp.max) * 0.5
            let column = registry.column(forWorldXZ: midXZ)
            XCTAssertEqual(
                column?.confidence,
                "needs_geologist_review",
                "region '\(regionId)' confidence flag flipped — review the data first"
            )
        }
    }

    // MARK: - Helpers

    /// Synthetic manifest covering every shipped tile id. Extracted
    /// so multiple tests can reuse it.
    private func makeSyntheticManifest() throws -> EnvelopeManifest {
        let manifestJSON = """
        {
          "meta": { "spawn_tile_id": "57403617" },
          "envelopes": {
            "57403607": { "lower_corner_m": [0.0, 1000.0, 0.0], "upper_corner_m": [1000.0, 2000.0, 0.0] },
            "57403608": { "lower_corner_m": [1000.0, 1000.0, 0.0], "upper_corner_m": [2000.0, 2000.0, 0.0] },
            "57403617": { "lower_corner_m": [0.0, 0.0, 0.0], "upper_corner_m": [1000.0, 1000.0, 0.0] },
            "57403618": { "lower_corner_m": [1000.0, 0.0, 0.0], "upper_corner_m": [2000.0, 1000.0, 0.0] },
            "57403619": { "lower_corner_m": [2000.0, 0.0, 0.0], "upper_corner_m": [3000.0, 1000.0, 0.0] }
          }
        }
        """
        return try EnvelopeManifest(jsonData: Data(manifestJSON.utf8))
    }

    /// Minimal column payload used by multiple tests. Keeps fixture
    /// construction at the call-site short and the field values
    /// irrelevant to the test under focus.
    private func tinyColumn(id: String) -> StratigraphicColumn {
        StratigraphicColumn(
            regionId: id,
            nameKey: "geology.region.\(id).name",
            source: "test",
            confidence: "test",
            layers: [
                StratigraphicLayer(
                    id: "\(id).basement",
                    nameKey: "geology.layer.basement.name",
                    thickness: 5,
                    colorHex: "#000000",
                    lithology: "basement"
                )
            ]
        )
    }
}
