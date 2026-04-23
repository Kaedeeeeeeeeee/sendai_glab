// GeologyRegionRegistry.swift
// SDGGameplay · Geology
//
// Phase 9 Part B loader + XZ→region lookup for per-tile stratigraphic
// columns. Replaces the Phase 1 "one test outcrop" assumption so that
// drilling anywhere inside the 5-tile PLATEAU corridor pulls from the
// appropriate regional column, and drilling outside the corridor
// surfaces `DrillError.outOfSurveyArea` (see `DrillingErrors.swift`).
//
// ## Scope
//
// The registry is a thin container:
//
//   * At init: walk `Resources/Geology/regions/*.json`, decode each
//     as a `StratigraphicColumn`, and store alongside the region's
//     XZ bounds derived from the `EnvelopeManifest`.
//   * At runtime: given a world-space (X, Z), return the region whose
//     footprint contains that point — or `nil` if none do.
//
// No RealityKit imports. The registry is a pure data index; the
// orchestrator is the one that turns a column + terrain sample into
// RealityKit-flavoured slabs. That separation makes the registry
// independently unit-testable.
//
// ## Region ↔ tile mapping
//
// The 5 regions correspond 1:1 with the 5 `PlateauTile` cases:
//
//   | regionId            | PlateauTile rawValue |
//   |---------------------|----------------------|
//   | aobayama-north      | 57403607             |
//   | aobayama-castle     | 57403608             |
//   | aobayama-campus     | 57403617  (spawn)    |
//   | kawauchi            | 57403618             |
//   | tohoku-gakuin       | 57403619             |
//
// The mapping is hard-coded in `Self.tileId(forRegion:)` because the
// two identifier schemes carry independent meaning (mesh id vs.
// geographical nickname) and making the JSON declare both would
// invite drift. One lookup table, local to this file.

import Foundation

// MARK: - GeologyRegionRegistry

/// Per-tile stratigraphic column registry.
///
/// Loads every shipped region JSON at init time, cross-references
/// each with the `EnvelopeManifest` to recover its real-world XZ
/// footprint in RealityKit world space, and exposes an O(n) lookup
/// `column(forWorldXZ:)` that returns the region containing a point.
///
/// ### Why O(n) and not a quadtree
///
/// Five regions. Point-in-rect tests are ~6 floats each. Even at
/// 60 Hz that's noise; a spatial index would be premature
/// optimisation. When tile count grows past ~30, swap in a
/// `CGRect`-based `CoreFoundation` quadtree or a fixed grid.
///
/// `@MainActor` because the intended call sites — `DrillingOrchestrator`
/// and `RootView` bootstrap — are already on the main actor, and
/// dodging it would force a redundant hop. The registry holds no
/// live RealityKit state and could be made actor-agnostic later if
/// a background loader needs it.
@MainActor
public final class GeologyRegionRegistry {

    // MARK: - Errors

    /// Failures surfaced by `init(bundle:)`. Each case names the
    /// offending region or file so CI / asset-validator logs can
    /// point at the fix.
    public enum LoadError: Error, CustomStringConvertible {

        /// A specific region JSON was not found in the bundle. Normally
        /// surfaces when the resource wasn't added to the app target's
        /// "Copy Bundle Resources" phase.
        case resourceNotFound(regionId: String)

        /// A region JSON decoded into something malformed (e.g. zero
        /// layers, or a layer with non-finite thickness). The registry
        /// validates at load time so broken data shows up once, not on
        /// every drill.
        case decodingFailed(regionId: String, underlying: Error)

        /// The region has no matching envelope entry. This is almost
        /// always a data-pipeline bug: either the region JSON was
        /// added without the matching `PlateauTile` / envelope, or
        /// the region id / tile id mapping drifted.
        case envelopeMissing(regionId: String, tileId: String)

        public var description: String {
            switch self {
            case .resourceNotFound(let id):
                return "GeologyRegionRegistry: region JSON missing for `\(id)`"
            case let .decodingFailed(id, err):
                return "GeologyRegionRegistry: decode failed for `\(id)` — \(err)"
            case let .envelopeMissing(id, tileId):
                return "GeologyRegionRegistry: envelope missing for region `\(id)` (tile `\(tileId)`)"
            }
        }
    }

    // MARK: - Internal record

    /// Private bundle pairing a loaded column with the axis-aligned
    /// XZ footprint we'll intersect against the drill origin.
    ///
    /// The footprint is in RealityKit world coordinates (the same
    /// space the player / drill live in), so containment tests are a
    /// direct `(x, z)` min/max check. Conversion from EPSG:6677 is
    /// done once at load time inside `computeFootprint(...)`.
    ///
    /// Exposed `internal` so tests can inspect footprints without
    /// reaching through `column(forWorldXZ:)` for every probe.
    internal struct Region {

        let column: StratigraphicColumn

        /// Minimum (X, Z) corner of the tile's footprint in RealityKit
        /// world space. `z` is the south/north delta (north = smaller
        /// Z per `PlateauTile` convention).
        let xzMin: SIMD2<Float>

        /// Maximum (X, Z) corner.
        let xzMax: SIMD2<Float>

        /// Point-in-rect test on the tile's XZ footprint.
        func contains(_ xz: SIMD2<Float>) -> Bool {
            xz.x >= xzMin.x && xz.x <= xzMax.x &&
            xz.y >= xzMin.y && xz.y <= xzMax.y
        }
    }

    // MARK: - Storage

    /// All loaded regions, in the canonical order listed in
    /// `Self.orderedRegionIds`. Order matters only for debug overlays
    /// and the region-lookup iteration order, both of which are
    /// independent of correctness.
    internal let regions: [Region]

    // MARK: - Init

    /// Load every shipped region JSON from `bundle` and pair it with
    /// the matching envelope from `manifest`.
    ///
    /// - Parameters:
    ///   - bundle: Bundle to search. Defaults to `Bundle.main`. Tests
    ///     pass `Bundle.module` so they load the fixtures shipped
    ///     under the test target.
    ///   - manifest: The Phase 4 envelope manifest. `nil` means
    ///     "no envelope manifest available" — the registry falls back
    ///     to `PlateauTile.localCenter` + a nominal 1 km × 1 km
    ///     footprint. Production code always passes a non-`nil`
    ///     manifest; the fallback exists for tests and experimental
    ///     call sites.
    /// - Throws: `LoadError` on the first broken region; the bundle
    ///   is not consulted further.
    public init(
        bundle: Bundle = .main,
        manifest: EnvelopeManifest? = nil
    ) throws {
        var regions: [Region] = []
        regions.reserveCapacity(Self.orderedRegionIds.count)

        for regionId in Self.orderedRegionIds {
            let column = try Self.loadColumn(regionId: regionId, bundle: bundle)
            let tileId = Self.tileId(forRegion: regionId)
            let footprint = Self.computeFootprint(
                tileId: tileId,
                manifest: manifest
            )
            guard let footprint else {
                throw LoadError.envelopeMissing(regionId: regionId, tileId: tileId)
            }
            regions.append(Region(
                column: column,
                xzMin: footprint.min,
                xzMax: footprint.max
            ))
        }
        self.regions = regions
    }

    /// Test-friendly init that skips the bundle lookup. Accepts the
    /// same shape `init(bundle:manifest:)` would produce — used by
    /// `GeologyRegionRegistryTests` to pin behaviour without
    /// round-tripping through the filesystem.
    internal init(regions: [Region]) {
        self.regions = regions
    }

    // MARK: - Query

    /// Return the column whose XZ footprint contains `xz`, or `nil`
    /// if none do. `nil` is the explicit "off-corridor" signal the
    /// orchestrator maps to `DrillError.outOfSurveyArea`.
    ///
    /// Regions are checked in declaration order; the first containing
    /// rect wins. Adjacent tiles may overlap by a few metres at their
    /// shared border because the envelopes are sourced independently.
    /// Whichever tile appears first in `orderedRegionIds` wins those
    /// borderline cases — acceptable for a game with ~1 m drill
    /// spatial resolution.
    public func column(forWorldXZ xz: SIMD2<Float>) -> StratigraphicColumn? {
        for region in regions {
            if region.contains(xz) {
                return region.column
            }
        }
        return nil
    }

    /// Test-only accessor: the internal footprint of a region by id.
    /// Exposed so tests can assert containment without going through
    /// `column(forWorldXZ:)` for every probe. `internal` scope keeps
    /// it out of the production API.
    internal func footprint(forRegion regionId: String) -> (min: SIMD2<Float>, max: SIMD2<Float>)? {
        guard let region = regions.first(where: { $0.column.regionId == regionId }) else {
            return nil
        }
        return (region.xzMin, region.xzMax)
    }

    // MARK: - Static mapping tables

    /// Canonical list of shipped region ids, in corridor-layout order
    /// (west-south → east-north). Iterating this order gives a
    /// deterministic lookup for borderline XZ points shared between
    /// adjacent tiles.
    public static let orderedRegionIds: [String] = [
        "aobayama-north",
        "aobayama-castle",
        "aobayama-campus",
        "kawauchi",
        "tohoku-gakuin"
    ]

    /// Return the `PlateauTile.rawValue` for a given region id, or the
    /// empty string for an unknown region.
    ///
    /// Exposed `public` so other modules (e.g. RootView integration)
    /// can ask the inverse question without duplicating the table.
    public static func tileId(forRegion regionId: String) -> String {
        switch regionId {
        case "aobayama-north":  return "57403607"
        case "aobayama-castle": return "57403608"
        case "aobayama-campus": return "57403617"
        case "kawauchi":        return "57403618"
        case "tohoku-gakuin":   return "57403619"
        default:                return ""
        }
    }

    // MARK: - Private loaders

    /// Find a region JSON in the bundle. Tries the flat layout first
    /// (how the iOS `.app` bundle stores resources after codesign
    /// flattening) and then the `Geology/regions/` subdirectory (how
    /// SPM test bundles preserve structure). Mirrors the loader
    /// pattern in `TerrainLoader` / `GeologySceneBuilder`; see
    /// CLAUDE.md §"重要な技術的落とし穴".
    private static func loadColumn(
        regionId: String,
        bundle: Bundle
    ) throws -> StratigraphicColumn {
        let basename = regionId
        guard
            let url = bundle.url(forResource: basename, withExtension: "json")
                ?? bundle.url(
                    forResource: basename,
                    withExtension: "json",
                    subdirectory: "Geology/regions"
                )
                ?? bundle.url(
                    forResource: basename,
                    withExtension: "json",
                    subdirectory: "regions"
                )
        else {
            throw LoadError.resourceNotFound(regionId: regionId)
        }
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            throw LoadError.decodingFailed(regionId: regionId, underlying: error)
        }
        do {
            let column = try JSONDecoder().decode(StratigraphicColumn.self, from: data)
            try validate(column: column)
            return column
        } catch let err as LoadError {
            throw err
        } catch {
            throw LoadError.decodingFailed(regionId: regionId, underlying: error)
        }
    }

    /// Basic sanity validation — surfaces broken data at load time so
    /// it doesn't manifest as a silent empty sample during play.
    private static func validate(column: StratigraphicColumn) throws {
        guard !column.layers.isEmpty else {
            throw LoadError.decodingFailed(
                regionId: column.regionId,
                underlying: CocoaError(.coderValueNotFound)
            )
        }
        for layer in column.layers {
            guard layer.thickness.isFinite, layer.thickness >= 0 else {
                throw LoadError.decodingFailed(
                    regionId: column.regionId,
                    underlying: CocoaError(.coderReadCorrupt)
                )
            }
        }
    }

    /// Compute a tile's RealityKit-world XZ footprint.
    ///
    /// When an `EnvelopeManifest` is available, the footprint comes
    /// from the tile's CityGML envelope:
    ///
    ///   * The spawn tile's envelope centre is the RealityKit world
    ///     origin (by `EnvelopeManifest.realityKitPosition(...)`'s
    ///     contract).
    ///   * We translate each corner of this tile's envelope by the
    ///     spawn-relative delta, apply the EPSG:6677 → RK axis remap
    ///     (north flips to -Z), and take the axis-aligned
    ///     `[min, max]` pair.
    ///
    /// When no manifest is supplied (tests, experimental), we fall
    /// back to a nominal 1 km × 1 km rectangle centred on
    /// `PlateauTile.localCenter`.
    private static func computeFootprint(
        tileId: String,
        manifest: EnvelopeManifest?
    ) -> (min: SIMD2<Float>, max: SIMD2<Float>)? {
        if let manifest {
            return footprintFromManifest(tileId: tileId, manifest: manifest)
        }
        return footprintFromPlateauTile(tileId: tileId)
    }

    /// Derive the XZ footprint from a CityGML envelope.
    ///
    /// Both corners are offset from the spawn envelope centre (same
    /// reference as `EnvelopeManifest.realityKitPosition`), then
    /// axis-remapped with the `y`-northing flip that gets us into
    /// RealityKit's `+Z = south` convention.
    private static func footprintFromManifest(
        tileId: String,
        manifest: EnvelopeManifest
    ) -> (min: SIMD2<Float>, max: SIMD2<Float>)? {
        guard
            let env = manifest.envelopes[tileId],
            let spawn = manifest.envelopes[manifest.spawnTileId]
        else {
            return nil
        }
        let spawnC = spawn.centerM
        let lower = env.lowerCornerM
        let upper = env.upperCornerM

        // Convert both EPSG:6677 corners into RealityKit XZ space. The
        // axis remap is the same one `EnvelopeManifest.realityKitPosition`
        // uses:  RK.x =  env.x - spawn.x      (east →  +X)
        //        RK.z = -(env.y - spawn.y)    (north → -Z)
        let lowerX = Float(lower.x - spawnC.x)
        let upperX = Float(upper.x - spawnC.x)
        let lowerZ = Float(-(lower.y - spawnC.y))
        let upperZ = Float(-(upper.y - spawnC.y))

        // North-in-envelope → smaller Z-in-RealityKit, so `upper.y` in
        // EPSG may map to a smaller RK.z than `lower.y`. Sort per axis
        // to get a proper axis-aligned rect.
        let minX = min(lowerX, upperX)
        let maxX = max(lowerX, upperX)
        let minZ = min(lowerZ, upperZ)
        let maxZ = max(lowerZ, upperZ)

        return (
            min: SIMD2<Float>(minX, minZ),
            max: SIMD2<Float>(maxX, maxZ)
        )
    }

    /// Fallback footprint when no envelope manifest is available.
    /// Uses `PlateauTile.localCenter` and the nominal 1 km × 1 km
    /// cell size. Kept internal so tests without manifest fixtures
    /// still get a deterministic footprint.
    private static func footprintFromPlateauTile(
        tileId: String
    ) -> (min: SIMD2<Float>, max: SIMD2<Float>)? {
        guard let tile = PlateauTile(rawValue: tileId) else { return nil }
        let centre = tile.localCenter
        // 1 km on each axis (matches `PlateauTile.cellHeightMetres` /
        // `cellWidthMetres` within rounding). Generous enough that
        // adjacent footprints touch without gap.
        let halfX: Float = 625  // cellWidthMetres / 2
        let halfZ: Float = 500  // cellHeightMetres / 2
        return (
            min: SIMD2<Float>(centre.x - halfX, centre.z - halfZ),
            max: SIMD2<Float>(centre.x + halfX, centre.z + halfZ)
        )
    }
}
