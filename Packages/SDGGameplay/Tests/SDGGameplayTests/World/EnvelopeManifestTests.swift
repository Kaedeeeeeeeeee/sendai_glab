// EnvelopeManifestTests.swift
// SDGGameplay · World · Tests
//
// Unit tests for the Phase 4 CityGML envelope manifest. We drive the
// type with an inline JSON fixture instead of the real pipeline output
// (`plateau_envelopes.json`) because:
//   • The real file is produced by Agent A's Python extractor on a
//     separate schedule, so coupling these tests to it would create a
//     false sequencing dependency.
//   • An inline fixture makes the expected axis behaviour readable —
//     you can see the "1250 m east" tile and the "1000 m north" tile
//     in the JSON itself, then verify the mapping in the assertions.
//
// Fixture layout (3 tiles, mimicking the 3rd-mesh spacing used in
// `PlateauTile.swift`):
//
//   "57403617"       spawn tile, centred somewhere around Aobayama in
//                    Miyagi Plane X coords. Picked round-ish numbers
//                    so the arithmetic in tests is obvious.
//   "57403618"       1250 m east, same northing, same elevation.
//   "574036_05_dem"  1000 m north, same easting, 50 m lower ground.

import XCTest
@testable import SDGGameplay

final class EnvelopeManifestTests: XCTestCase {

    // MARK: - Fixture

    /// Three tiles: spawn at a nominal (10000, 20000, 100) centre, an
    /// eastward tile offset by 1250 m in easting, and a DEM tile
    /// offset by 1000 m in northing with ground 50 m lower.
    ///
    /// Each envelope is 1250 × 1000 × 20 m centred on the stated
    /// centre (so lower/upper corners bracket it evenly).
    private static let fixtureJSON: String = """
    {
      "meta": {
        "source_crs": "EPSG:6697",
        "target_crs": "EPSG:6677",
        "spawn_tile_id": "57403617",
        "generated_by": "EnvelopeManifestTests",
        "generated_at": "2026-04-23T12:00:00Z"
      },
      "envelopes": {
        "57403617": {
          "lower_corner_m": [9375.0,  19500.0,  90.0],
          "upper_corner_m": [10625.0, 20500.0, 110.0]
        },
        "57403618": {
          "lower_corner_m": [10625.0, 19500.0,  90.0],
          "upper_corner_m": [11875.0, 20500.0, 110.0]
        },
        "574036_05_dem": {
          "lower_corner_m": [9375.0,  20500.0,  40.0],
          "upper_corner_m": [10625.0, 21500.0,  60.0]
        }
      }
    }
    """

    private func makeManifest(
        jsonString: String = EnvelopeManifestTests.fixtureJSON
    ) throws -> EnvelopeManifest {
        let data = Data(jsonString.utf8)
        return try EnvelopeManifest(jsonData: data)
    }

    // MARK: - Decode

    /// Smoke test: valid JSON round-trips into a manifest with the
    /// expected spawn id and a full envelopes map.
    func testDecodesValidJSON() throws {
        let manifest = try makeManifest()
        XCTAssertEqual(manifest.spawnTileId, "57403617")
        XCTAssertEqual(manifest.envelopes.count, 3)
        XCTAssertNotNil(manifest.envelopes["57403617"])
        XCTAssertNotNil(manifest.envelopes["57403618"])
        XCTAssertNotNil(manifest.envelopes["574036_05_dem"])
    }

    /// `PlateauEnvelope.centerM` must be the midpoint of lower/upper.
    /// Pinning this keeps a future refactor of the formula from
    /// silently shifting every entity by half a tile.
    func testCenterComputedCorrectly() throws {
        let manifest = try makeManifest()
        let env = try XCTUnwrap(manifest.envelopes["57403617"])
        // Lower (9375, 19500, 90), Upper (10625, 20500, 110) →
        // Centre (10000, 20000, 100).
        XCTAssertEqual(env.centerM.x, 10000.0, accuracy: 1e-9)
        XCTAssertEqual(env.centerM.y, 20000.0, accuracy: 1e-9)
        XCTAssertEqual(env.centerM.z,   100.0, accuracy: 1e-9)
    }

    // MARK: - Coordinate mapping

    /// The spawn tile must sit at the RealityKit world origin by
    /// construction — every other position is expressed relative to
    /// it. A drift here would offset the entire scene.
    func testSpawnTileIsAtOrigin() throws {
        let manifest = try makeManifest()
        let p = try XCTUnwrap(manifest.realityKitPosition(for: manifest.spawnTileId))
        XCTAssertEqual(p, SIMD3<Float>.zero)
    }

    /// A tile east of the spawn (larger easting) must map to a
    /// positive RealityKit X. This pins the "east → +X" half of the
    /// axis convention documented in `realityKitPosition(for:)`.
    func testEastwardTileHasPositiveX() throws {
        let manifest = try makeManifest()
        let p = try XCTUnwrap(manifest.realityKitPosition(for: "57403618"))
        // 1250 m east, no northing or elevation delta.
        XCTAssertEqual(p.x, 1250.0, accuracy: 1e-3)
        XCTAssertEqual(p.y,    0.0, accuracy: 1e-3)
        XCTAssertEqual(p.z,    0.0, accuracy: 1e-3)
    }

    /// A tile north of the spawn (larger northing) must map to a
    /// *negative* RealityKit Z — RK +Z points south per
    /// `PlateauTile.swift`. If this flip is removed, every northward
    /// tile ends up behind the player.
    func testNorthwardTileHasNegativeZ() throws {
        let manifest = try makeManifest()
        let p = try XCTUnwrap(manifest.realityKitPosition(for: "574036_05_dem"))
        // 1000 m north, 50 m lower ground, no easting delta.
        XCTAssertEqual(p.x,     0.0, accuracy: 1e-3)
        XCTAssertEqual(p.y,   -50.0, accuracy: 1e-3)   // elevation 50 m below spawn
        XCTAssertEqual(p.z, -1000.0, accuracy: 1e-3)   // north → -Z
    }

    /// Unknown tile id returns `nil` — callers (terrain / env loader)
    /// rely on this to distinguish "not in manifest, fall back to
    /// legacy layout" from "at origin".
    func testUnknownTileIdReturnsNil() throws {
        let manifest = try makeManifest()
        XCTAssertNil(manifest.realityKitPosition(for: "unknown"))
        XCTAssertNil(manifest.realityKitPosition(for: ""))
    }

    // MARK: - Error paths

    /// If `meta.spawn_tile_id` refers to a tile that isn't present in
    /// `envelopes`, load must throw `missingSpawnTile`. This is almost
    /// always an upstream pipeline bug and must fail loudly.
    func testMissingSpawnTileThrows() throws {
        let badJSON = """
        {
          "meta": { "spawn_tile_id": "does_not_exist" },
          "envelopes": {
            "57403617": {
              "lower_corner_m": [0.0, 0.0, 0.0],
              "upper_corner_m": [1.0, 1.0, 1.0]
            }
          }
        }
        """
        XCTAssertThrowsError(try makeManifest(jsonString: badJSON)) { error in
            guard let loadError = error as? EnvelopeManifest.LoadError else {
                XCTFail("expected EnvelopeManifest.LoadError, got \(error)")
                return
            }
            switch loadError {
            case .missingSpawnTile(let id):
                XCTAssertEqual(id, "does_not_exist")
            default:
                XCTFail("expected .missingSpawnTile, got \(loadError)")
            }
        }
    }

    /// Malformed JSON (wrong corner array length) surfaces as
    /// `.decodingFailed` rather than crashing. Pinning because the
    /// pipeline is under active development — a shape drift must
    /// produce a readable error, not undefined behaviour.
    func testMalformedCornerArrayThrowsDecodingFailed() throws {
        let badJSON = """
        {
          "meta": { "spawn_tile_id": "57403617" },
          "envelopes": {
            "57403617": {
              "lower_corner_m": [0.0, 0.0],
              "upper_corner_m": [1.0, 1.0, 1.0]
            }
          }
        }
        """
        XCTAssertThrowsError(try makeManifest(jsonString: badJSON)) { error in
            guard let loadError = error as? EnvelopeManifest.LoadError else {
                XCTFail("expected EnvelopeManifest.LoadError, got \(error)")
                return
            }
            if case .decodingFailed = loadError {
                // ok
            } else {
                XCTFail("expected .decodingFailed, got \(loadError)")
            }
        }
    }

    // MARK: - Round-trip

    /// Encoding a `PlateauEnvelope` must emit the same snake_case keys
    /// the on-disk JSON uses, so a Swift-produced manifest could be
    /// consumed by the same Python tooling (debug flow / regeneration).
    func testEnvelopeRoundTripsThroughJSON() throws {
        let original = PlateauEnvelope(
            lowerCornerM: SIMD3<Double>(1.5, 2.5, 3.5),
            upperCornerM: SIMD3<Double>(4.5, 5.5, 6.5)
        )
        let encoded = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(PlateauEnvelope.self, from: encoded)
        XCTAssertEqual(decoded, original)
    }
}
