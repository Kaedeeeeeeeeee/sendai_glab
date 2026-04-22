// TerrainLoader.swift
// SDGGameplay · World
//
// Loads a PLATEAU DEM (Digital Elevation Model) terrain tile converted
// to USDZ by `Tools/plateau-pipeline/dem_to_terrain_usdz.py`.
//
// ## Why a separate loader (not `PlateauEnvironmentLoader`)
//
// Building tiles (bldg module) and DEM terrain (dem module) share
// nothing at the gameplay layer:
//
//   - Different scales: one DEM tile covers 5 × 5 km (the whole corridor
//     area plus padding); each building tile covers 1 × 1 km.
//   - Different lifecycle: DEM loads once as a single unit; building
//     tiles load piecewise and can be dropped independently.
//   - Different semantics: terrain is visual backdrop, buildings are
//     occluders / landmarks. Keeping them in separate loaders lets each
//     evolve its own LOD / streaming strategy later without churning
//     the other's API surface.
//
// ## Alignment note (Phase 3 first-cut)
//
// `nusamai` centers each emitted GLB on its own AABB (both DEM and
// bldg), discarding the real-world geographic origin. With no shared
// reference point, we cannot *perfectly* align the 5 × 5 km DEM with
// the 5 building tiles spanning its NE quadrant. The Phase 3 first-cut
// bottom-snaps the DEM the same way building tiles are bottom-snapped,
// so both share Y = 0 at their lowest vertex. In practice this means:
//
//   * terrain's river-valley low point sits at Y = 0,
//   * each building tile's lowest building foundation also sits at
//     Y = 0,
//   * but tiles at hilltop elevations (Aobayama) have their "ground"
//     still at Y = 0 even though the real ground should be ~100 m higher.
//
// The trade-off: buildings stay reachable (player spawn doesn't fall
// underground), and terrain provides visible relief in the background
// instead of an infinite green plane. A Phase 4 task (see GDD §4.3)
// can replace this with true coordinate alignment by parsing CityGML
// envelope metadata.

import Foundation
import RealityKit

/// Loads a PLATEAU DEM terrain USDZ from the bundle and applies the
/// same centering convention as `PlateauEnvironmentLoader`.
///
/// Public API mirrors the building loader:
///   - `init(bundle:)`  — construction is cheap, no I/O.
///   - `load()`         — returns a RealityKit `Entity` ready to be
///                        added to the scene as a single unit.
///
/// Tile identifier is currently hard-coded to the single Phase 3 tile
/// (`Terrain_Sendai_574036_05`) — the 5 × 5 km NE quadrant of PLATEAU
/// 2nd-mesh 574036. If/when more DEM tiles ship, widen this to an
/// enum analogous to `PlateauTile`.
@MainActor
public final class TerrainLoader {

    /// Error surfaces produced by `load()`. Each case carries enough
    /// context for a single-line log ("terrain USDZ missing at …").
    public enum LoadError: Error, CustomStringConvertible {
        case resourceNotFound(basename: String)
        case realityKitLoadFailed(underlying: Error)

        public var description: String {
            switch self {
            case .resourceNotFound(let b):
                return "Terrain USDZ not found in bundle: \(b).usdz"
            case .realityKitLoadFailed(let e):
                return "RealityKit failed to load terrain USDZ: \(e)"
            }
        }
    }

    /// Basename of the Phase 3 terrain USDZ shipped in
    /// `Resources/Environment/`. Kept as a static let (not a parameter)
    /// because the rest of the pipeline — the Blender script, the
    /// project.yml resource list, the `.gitattributes` LFS rule — all
    /// ship the same single file. A parameter would imply flexibility
    /// the pipeline doesn't yet provide.
    public static let defaultBasename = "Terrain_Sendai_574036_05"

    private let bundle: Bundle

    public init(bundle: Bundle = .main) {
        self.bundle = bundle
    }

    /// Load, center horizontally + ground-snap on Y. The returned
    /// entity can be parented directly under the scene root; it carries
    /// no collision, no physics — it's a visual-only backdrop at
    /// Phase 3. Add `CollisionComponent` in a follow-up task if/when
    /// the player needs to walk on the terrain.
    public func load() async throws -> Entity {
        let basename = Self.defaultBasename
        guard
            let url = bundle.url(forResource: basename, withExtension: "usdz")
                ?? bundle.url(
                    forResource: basename,
                    withExtension: "usdz",
                    subdirectory: "Environment"
                )
        else {
            throw LoadError.resourceNotFound(basename: basename)
        }

        let entity: Entity
        do {
            entity = try await Entity(contentsOf: url)
        } catch {
            throw LoadError.realityKitLoadFailed(underlying: error)
        }

        // Same centering treatment as building tiles so both share the
        // Y = 0 reference plane. The alignment caveat is documented in
        // the file header.
        EnvironmentCenterer.centerHorizontallyAndGroundY(entity)
        entity.name = "PlateauTerrain_\(basename)"
        return entity
    }
}
