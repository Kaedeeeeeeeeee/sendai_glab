// PlateauTileTests.swift
// SDGGameplay · World · Tests
//
// Unit tests for the tile enumeration. These are the *only* tests
// that run in CI for the PLATEAU loader today — every downstream piece
// (converter, centerer, loader proper) needs either Application Support
// access, a large binary asset, or RealityKit's native `Entity` loader,
// none of which we run in the Swift package test harness.
//
// Pinning the tile data here means schema drift (e.g. someone renaming
// a mesh id) is caught in `swift test` instead of surfacing at tile
// load time on a real device.

import XCTest
@testable import SDGGameplay

final class PlateauTileTests: XCTestCase {

    // MARK: - Identity

    /// Exactly five tiles. A new or removed tile is a content-level
    /// decision that must update GDD §0 and ADR docs, not something
    /// to slip into a code-only PR.
    func testFiveTilesExist() {
        XCTAssertEqual(PlateauTile.allCases.count, 5)
    }

    /// Mesh ids map correctly to their resource basenames. If a
    /// tile's raw value changes, the GLB shipped in
    /// Resources/Environment/ must move in lockstep — this test is
    /// the pivot that catches either side drifting.
    func testResourceBasenames() {
        XCTAssertEqual(
            PlateauTile.aobayamaNorth.resourceBasename,
            "Environment_Sendai_57403607"
        )
        XCTAssertEqual(
            PlateauTile.aobayamaCastle.resourceBasename,
            "Environment_Sendai_57403608"
        )
        XCTAssertEqual(
            PlateauTile.aobayamaCampus.resourceBasename,
            "Environment_Sendai_57403617"
        )
        XCTAssertEqual(
            PlateauTile.kawauchiCampus.resourceBasename,
            "Environment_Sendai_57403618"
        )
        XCTAssertEqual(
            PlateauTile.tohokuGakuinVicinity.resourceBasename,
            "Environment_Sendai_57403619"
        )
    }

    /// Localization keys follow the catalogued pattern. Breaking this
    /// silently leaves HUD labels as raw keys on device — a poor UX
    /// that's easy to miss in manual QA.
    func testNameKeysUseEnvironmentTilePrefix() {
        for tile in PlateauTile.allCases {
            XCTAssertTrue(
                tile.nameKey.hasPrefix("environment.tile."),
                "tile \(tile) has bad name key \(tile.nameKey)"
            )
        }
    }

    // MARK: - Default spawn

    /// Spawn tile is the campus cell. GDD §1.4 pins the opening beat
    /// on the Aobayama outcrop; `defaultSpawn` must stay aligned.
    func testDefaultSpawnIsAobayamaCampus() {
        XCTAssertEqual(PlateauTile.defaultSpawn, .aobayamaCampus)
    }

    // MARK: - Layout

    /// The spawn tile sits at the scene origin by construction. Any
    /// drift here means scene anchoring in the main-agent integration
    /// would be offset by a kilometre, which is bigger than the
    /// visible corridor.
    func testSpawnTileLocalCenterIsOrigin() {
        XCTAssertEqual(
            PlateauTile.defaultSpawn.localCenter,
            SIMD3<Float>.zero
        )
    }

    /// Every tile has a unique `localCenter`. Duplicate centres would
    /// pile two tiles on top of each other in the corridor.
    func testLocalCentresAreUnique() {
        var seen: [SIMD3<Float>: PlateauTile] = [:]
        for tile in PlateauTile.allCases {
            let centre = tile.localCenter
            // SIMD3 conforms to Hashable via componentwise hashing.
            XCTAssertNil(
                seen[centre],
                "duplicate centre \(centre) on \(tile) and \(String(describing: seen[centre]))"
            )
            seen[centre] = tile
        }
    }

    /// Row-0 tiles (aobayamaNorth, aobayamaCastle) must be *south* of
    /// the spawn, i.e. `+Z`. This pins the direction convention we
    /// picked (north → smaller Z) so a well-meaning refactor that
    /// flips it doesn't silently mirror the scene.
    func testSouthernTilesHavePositiveZ() {
        XCTAssertGreaterThan(
            PlateauTile.aobayamaNorth.localCenter.z, 0,
            "aobayamaNorth (row 0) must sit south of spawn"
        )
        XCTAssertGreaterThan(
            PlateauTile.aobayamaCastle.localCenter.z, 0,
            "aobayamaCastle (row 0) must sit south of spawn"
        )
    }

    /// Row-1 tiles share the spawn's row, so their Z is 0. Keeps the
    /// "straight east-west corridor" geometry documented in
    /// `PlateauTile.swift` honest.
    func testRowOneTilesShareSpawnRow() {
        XCTAssertEqual(
            PlateauTile.kawauchiCampus.localCenter.z, 0,
            accuracy: 1e-5
        )
        XCTAssertEqual(
            PlateauTile.tohokuGakuinVicinity.localCenter.z, 0,
            accuracy: 1e-5
        )
    }

    /// Column ordering must produce strictly increasing +X offsets
    /// for row-1 tiles: spawn (col 7) → kawauchi (col 8) → tohoku
    /// gakuin (col 9). Pinning > rather than fuzzy ranges so a swap
    /// of raw values surfaces immediately.
    func testColumnOrderingIncreasesX() {
        XCTAssertLessThan(
            PlateauTile.aobayamaCampus.localCenter.x,
            PlateauTile.kawauchiCampus.localCenter.x
        )
        XCTAssertLessThan(
            PlateauTile.kawauchiCampus.localCenter.x,
            PlateauTile.tohokuGakuinVicinity.localCenter.x
        )
    }

    /// Tile spacing along X matches `cellWidthMetres`. Pins the grid
    /// cell size so a future designer who tightens the corridor
    /// (reducing overlap) has to update *both* the layout constant
    /// and this test — an intentional coupling.
    func testHorizontalSpacingMatchesCellWidth() {
        let dx = PlateauTile.kawauchiCampus.localCenter.x
            - PlateauTile.aobayamaCampus.localCenter.x
        XCTAssertEqual(
            dx,
            PlateauTile.cellWidthMetres,
            accuracy: 1e-3
        )
    }

    /// Tile spacing along Z matches `cellHeightMetres`.
    func testVerticalSpacingMatchesCellHeight() {
        let dz = PlateauTile.aobayamaNorth.localCenter.z
            - PlateauTile.aobayamaCampus.localCenter.z
        XCTAssertEqual(
            dz,
            PlateauTile.cellHeightMetres,
            accuracy: 1e-3
        )
    }

    /// `localCenter.y` must be 0 on all tiles — horizontal corridor,
    /// no terrain elevation handled at this layer. If vertical
    /// offsets ever become part of the layout, they belong in a
    /// dedicated terrain class, not the tile enum.
    func testLocalCentresAreFlat() {
        for tile in PlateauTile.allCases {
            XCTAssertEqual(
                tile.localCenter.y, 0,
                accuracy: 1e-5,
                "tile \(tile) has non-zero Y; corridor must be flat"
            )
        }
    }

    // MARK: - Row / column parsers

    /// Row/column derivation from the raw mesh id must match the
    /// documented 3rd-mesh convention (7th digit = row, 8th = column).
    /// The enum's layout logic stands on these — a typo here ripples
    /// through every offset.
    func testRowAndColumnDerivation() {
        XCTAssertEqual(PlateauTile.aobayamaNorth.row, 0)
        XCTAssertEqual(PlateauTile.aobayamaNorth.column, 7)

        XCTAssertEqual(PlateauTile.aobayamaCastle.row, 0)
        XCTAssertEqual(PlateauTile.aobayamaCastle.column, 8)

        XCTAssertEqual(PlateauTile.aobayamaCampus.row, 1)
        XCTAssertEqual(PlateauTile.aobayamaCampus.column, 7)

        XCTAssertEqual(PlateauTile.kawauchiCampus.row, 1)
        XCTAssertEqual(PlateauTile.kawauchiCampus.column, 8)

        XCTAssertEqual(PlateauTile.tohokuGakuinVicinity.row, 1)
        XCTAssertEqual(PlateauTile.tohokuGakuinVicinity.column, 9)
    }
}
