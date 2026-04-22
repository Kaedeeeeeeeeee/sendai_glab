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

    /// Load, center horizontally + ground-snap on Y, apply an earthy
    /// Toon material, and generate collision shapes so the RootView
    /// can raycast against the surface to anchor the player.
    ///
    /// The Phase 3 first playtest revealed two issues the loader must
    /// handle, not push onto callers:
    ///   1. The Blender pipeline strips materials (for bundle size);
    ///      loading a stripped USDZ renders in RealityKit's default
    ///      magenta, which looks broken. We apply a mud-olive tint via
    ///      `ToonMaterialFactory` here so every caller gets a lit
    ///      terrain automatically.
    ///   2. The bottom-snap keeps terrain's lowest valley vertex at
    ///      Y = 0, which puts the hilltop hundreds of metres above
    ///      origin — the player spawn at (0, 0, 0) lands underground.
    ///      We ship `CollisionComponent` here so RootView can raycast
    ///      downward from above the terrain and move the player to
    ///      the actual surface.
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

        // Mud-olive base colour for "dirt with a hint of grass". Chose
        // a muted tone so it reads as "ground" rather than competing
        // with the building tiles' warm palette. Hand-tuned on real-
        // device preview; stored `internal` so tests can pin the
        // shade.
        Self.applyTerrainMaterial(
            toDescendantsOf: entity,
            baseColor: Self.defaultTerrainColor
        )

        // Collision shapes generated from the mesh. Synchronous and
        // can take a beat on 30 K tris, but happens once at load time
        // — acceptable for an app where terrain doesn't stream.
        // `recursive: true` handles any nested mesh parts the
        // decimator produces.
        entity.generateCollisionShapes(recursive: true)

        entity.name = "PlateauTerrain_\(basename)"
        return entity
    }

    // MARK: - Material

    /// The default earthy tint for terrain. Mud-olive: warm enough to
    /// not feel cold on a sunny day, dark enough to sit visually
    /// *under* the building palette. Exposed `internal` so tests can
    /// pin the value without reading through the loader.
    internal static let defaultTerrainColor = SIMD3<Float>(0.42, 0.48, 0.30)

    // MARK: - Height sampling

    /// Sample the terrain's Y in world space at a given X / Z position
    /// by finding the nearest vertex in any `ModelComponent` under
    /// `root`. Returns `nil` if no vertices could be read (e.g. the
    /// entity has no mesh geometry yet).
    ///
    /// Why not `Scene.raycast`? The make closure runs before the
    /// physics/collision world has ticked, so raycasting there
    /// reliably returns empty. Mesh sampling is synchronous,
    /// deterministic, and works the moment the entity is loaded.
    ///
    /// Precision note: "nearest vertex" is an O(vertices) sweep over
    /// a ~90 K vertex mesh. That's cheap at load time (one-shot) and
    /// precise enough for a spawn anchor — we only need Y to within a
    /// few metres of ground so the player doesn't fall through.
    ///
    /// Exposed `public` so callers in other modules (RootView) can
    /// pick a spawn Y without reopening `TerrainLoader`. `@MainActor`
    /// because `Entity.transformMatrix(relativeTo:)` and descendants
    /// traversal touch main-isolated state.
    @MainActor
    public static func sampleTerrainY(
        in root: Entity,
        atWorldXZ target: SIMD2<Float>
    ) -> Float? {
        var bestY: Float?
        var bestDistSq: Float = .infinity

        var stack: [Entity] = [root]
        while let current = stack.popLast() {
            stack.append(contentsOf: current.children)
            guard
                let modelComponent = current.components[ModelComponent.self]
            else { continue }

            // World-space transform for this entity's local vertices.
            let toWorld = current.transformMatrix(relativeTo: nil)

            for mdl in modelComponent.mesh.contents.models {
                for part in mdl.parts {
                    // `part.positions` is non-optional on iOS 18 — every
                    // mesh part has a position buffer, even if empty.
                    let positions = part.positions
                    for local in positions {
                        let world4 = toWorld * SIMD4<Float>(
                            local.x, local.y, local.z, 1
                        )
                        let dx = world4.x - target.x
                        let dz = world4.z - target.y
                        let distSq = dx * dx + dz * dz
                        if distSq < bestDistSq {
                            bestDistSq = distSq
                            bestY = world4.y
                        }
                    }
                }
            }
        }
        return bestY
    }

    // MARK: - Material

    /// Walk the entity tree and replace every `ModelComponent`'s
    /// materials with the Toon-shaded terrain material. Mirrors
    /// `PlateauEnvironmentLoader.applyToonMaterial` — kept here (not
    /// reused) because terrain uses a single colour rather than a
    /// per-tile palette, and forcing it through the building loader's
    /// API would imply a `PlateauTile` the terrain doesn't have.
    ///
    /// Exposed `internal` so tests can exercise the material swap on a
    /// synthetic entity without going through `load()`.
    @MainActor
    internal static func applyTerrainMaterial(
        toDescendantsOf root: Entity,
        baseColor: SIMD3<Float>
    ) {
        // Harder cel variant (Phase 3): terrain reads as clearly
        // cartoonish rather than a realistic-with-toon-tint ground.
        // See `ToonMaterialFactory.makeHardCelMaterial` header for the
        // difference vs. the soft `makeLayerMaterial`.
        let material = ToonMaterialFactory.makeHardCelMaterial(
            baseColor: baseColor
        )

        // Explicit iterative walk — mirrors PlateauEnvironmentLoader
        // to keep the visual contract identical between buildings and
        // terrain (same strength, same factory).
        var stack: [Entity] = [root]
        while let current = stack.popLast() {
            if var modelComponent = current.components[ModelComponent.self] {
                let count = max(1, modelComponent.materials.count)
                modelComponent.materials = Array(
                    repeating: material,
                    count: count
                )
                current.components.set(modelComponent)
            }
            stack.append(contentsOf: current.children)
        }
    }
}
