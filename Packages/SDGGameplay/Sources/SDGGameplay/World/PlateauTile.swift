// PlateauTile.swift
// SDGGameplay · World
//
// Enumeration of the Phase 2 Alpha PLATEAU corridor tiles. Each case
// corresponds to one 3rd-order Japanese Standard Mesh (第三次メッシュ)
// cell converted from the city's 2024 CityGML LOD2 distribution; the
// five cells together form the walkable corridor Aobayama → Kawauchi →
// 片平 described in GDD §0 / §4.3 ("月 2: 内容と場所").
//
// Why an enum and not a struct
// ----------------------------
// We know the exact five tiles up front, and each tile has fixed
// metadata (mesh id, display-name key, centre offset). Modelling it as
// an enum gives us exhaustiveness at switch sites and a zero-cost
// `CaseIterable` for "load all five". A struct would imply a tile set
// that grows at runtime, which it does not — new tiles only arrive when
// the PLATEAU pipeline re-runs, which is a build-time event.
//
// Coordinate layout
// -----------------
// The 5 meshes occupy a 3 × 2 grid in the standard mesh scheme:
//
//    col 7     col 8     col 9
//   ┌────────┬────────┬────────┐
//   │ (17)   │ (18)   │ (19)   │  row 1 (north)
//   ├────────┼────────┼────────┤
//   │ (07)   │ (08)   │   —    │  row 0 (south)
//   └────────┴────────┴────────┘
//
// One 3rd mesh is ~1 km north–south by ~1.25 km east–west. We put
// tile 17 (Aobayama campus, the spawn location) at the origin and
// lay out the others in RealityKit world space with:
//
//   +X  →  east
//   +Z  →  south
//   +Y  →  up (not used at tile layout)
//
// Resulting offsets (see `localCenter`):
//
//   (07)  (0,    0, 1000)    — Aobayama north, south of campus
//   (08)  (1250, 0, 1000)    — Aobayama castle direction, SE of campus
//   (17)  (0,    0, 0)       — Aobayama campus (spawn) ★
//   (18)  (1250, 0, 0)       — Kawauchi campus, E of campus
//   (19)  (2500, 0, 0)       — Katahira / Tohoku Gakuin, EE of campus
//
// Wait: geography inspection. Campus (17) is the *northern* mesh,
// 07 is south of it → +Z (south). Check. And 17 is the *western*
// column; 18 east, 19 further east → +X. Check.

import Foundation

/// The five Phase 2 Alpha PLATEAU corridor tiles. Each case is one
/// Japanese third-order standard mesh (`第三次メッシュ`) covering part
/// of the Aobayama → Kawauchi → 片平 corridor.
///
/// ### Usage
///
/// ```swift
/// for tile in PlateauTile.allCases {
///     let root = try await loader.loadTile(tile)
///     root.position = tile.localCenter
///     scene.addAnchor(anchor(root))
/// }
/// ```
///
/// The `rawValue` is the mesh id (e.g. `"57403617"`). `.defaultSpawn`
/// names the tile the player starts on at Phase 2 Alpha.
public enum PlateauTile: String, CaseIterable, Sendable {

    /// 青葉山北側 — mesh 57403607. South of the campus tile.
    case aobayamaNorth       = "57403607"

    /// 青葉城跡方面 — mesh 57403608. South-east of the campus tile.
    case aobayamaCastle      = "57403608"

    /// 東北大青葉山キャンパス — mesh 57403617. Player spawn.
    case aobayamaCampus      = "57403617"

    /// 川内キャンパス / 広瀬川 — mesh 57403618. East of the campus tile.
    case kawauchiCampus      = "57403618"

    /// 片平 / 東北学院大学周辺 — mesh 57403619. Two columns east of
    /// the campus tile.
    case tohokuGakuinVicinity = "57403619"

    // MARK: - Layout constants

    /// North–south extent of one 3rd mesh cell, in metres.
    /// Japanese standard mesh definition pins this at 30″ of latitude
    /// ≈ 925 m near Sendai's latitude. Rounded to 1 km for level-design
    /// legibility; the corridor is a game-play abstraction, not a
    /// cartographically precise overlay.
    ///
    /// Exposed `internal` so `PlateauTileTests` can pin it without
    /// reopening the enum.
    internal static let cellHeightMetres: Float = 1000

    /// East–west extent of one 3rd mesh cell, in metres.
    /// 45″ of longitude near Sendai's latitude ≈ 1 113 m; we round up
    /// to 1 250 m so adjacent tiles don't overlap after the loader's
    /// centroid-snap (`EnvironmentCenterer`) leaves each tile's real
    /// footprint slightly under the nominal cell size.
    internal static let cellWidthMetres: Float = 1250

    // MARK: - Identity

    /// Basename of the GLB resource in `Resources/Environment/`. The
    /// actual file extension is attached by the loader — this returns
    /// `"Environment_Sendai_57403617"`, not the full filename, to
    /// mirror the pattern `Bundle.url(forResource:withExtension:)` uses.
    public var resourceBasename: String {
        "Environment_Sendai_\(rawValue)"
    }

    /// Localization key for this tile's display name. Matches the
    /// pattern used elsewhere in the catalog (`geology.layer.*`,
    /// `tool.*`). No human-readable string is hard-coded here — HUD
    /// code must go through `L10n` (AGENTS.md §5).
    public var nameKey: String {
        "environment.tile.\(rawValue)"
    }

    // MARK: - Layout

    /// Grid row in the 3rd mesh scheme: `0` = south, `1` = north.
    /// Derived from the 7th digit of the mesh id.
    internal var row: Int {
        // e.g. "57403617" → 7th digit (index 6, 0-based) = '1'. We take
        // it from `rawValue` at runtime rather than switch on the enum
        // so there's a single source of truth (the mesh id).
        let digits = Array(rawValue)
        // Defensive: mesh ids are always 8 digits.
        guard digits.count == 8,
              let v = Int(String(digits[6])) else {
            return 0
        }
        return v
    }

    /// Grid column in the 3rd mesh scheme: `0`…`9`, where larger =
    /// further east. Derived from the 8th digit of the mesh id.
    internal var column: Int {
        let digits = Array(rawValue)
        guard digits.count == 8,
              let v = Int(String(digits[7])) else {
            return 0
        }
        return v
    }

    /// Tile centre in the shared scene's local space (metres).
    ///
    /// Computed so the spawn tile (`.aobayamaCampus`) sits at the
    /// origin. Offsets are laid out in RealityKit world conventions
    /// (+X east, +Z south, +Y up).
    ///
    /// - Note: Returns `.zero` for the spawn tile by construction, so
    ///   `EnvironmentCenterer` + this offset compose cleanly — the
    ///   spawn point is both scene origin and tile origin.
    public var localCenter: SIMD3<Float> {
        // Row delta: higher row = further north = smaller +Z. The
        // campus tile is the reference (row 1). Tiles at row 0 sit
        // south of it.
        let spawn = PlateauTile.aobayamaCampus
        let colDelta = Float(column - spawn.column)
        let rowDelta = Float(row - spawn.row)

        let x = colDelta * Self.cellWidthMetres
        // north → smaller Z. rowDelta > 0 means farther north → −Z.
        let z = -rowDelta * Self.cellHeightMetres

        return SIMD3<Float>(x, 0, z)
    }

    /// The tile players start on at Phase 2 Alpha. Pinned to the
    /// Aobayama campus (mesh 57403617) to match the opening beat of
    /// GDD §1.4 ("0-10 min: 青葉山露頭, 東北大").
    public static let defaultSpawn: PlateauTile = .aobayamaCampus
}
