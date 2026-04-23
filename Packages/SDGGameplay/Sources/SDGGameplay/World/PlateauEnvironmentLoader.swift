// PlateauEnvironmentLoader.swift
// SDGGameplay · World
//
// Top-level entry point for loading the PLATEAU walkable corridor
// tiles into a RealityKit scene. Concrete responsibilities:
//
//   1. Locate each tile's converted resource via `GLBToUSDZConverter`
//      (which prefers a pre-shipped USDZ and falls back to ModelIO
//      runtime conversion if the OS supports it).
//   2. Load the resulting USDZ / USDC through RealityKit's
//      `Entity(contentsOf:)`.
//   3. Centre each tile on the origin of its local space so nusamai's
//      Japan-Plane-Rectangular offsets don't push it kilometres
//      away from the scene origin (`EnvironmentCenterer`).
//   4. Apply `PlateauTile.localCenter` to line tiles up in the
//      designed corridor layout.
//   5. Replace every child `ModelComponent`'s materials with a Toon
//      version (`ToonMaterialFactory`) in a deterministic warm colour
//      per tile — each tile stays recognisably distinct without the
//      loader needing to cluster-per-building.
//
// No collision components are attached here — Phase 2 Beta will add
// navmesh / collision. The current scope is "walk-around visuals".
//
// ### Architectural notes
//
// * This type is deliberately the only public symbol in `World/` that
//   takes a `Bundle`. Consumers pass whichever bundle hosts the
//   Resources/Environment/ payload (app bundle, or a test bundle).
// * The loader does *not* publish game events. Scene wiring happens
//   from the main agent's integration layer; we just return entities.
//   Keeping it event-free means `PlateauEnvironmentLoader` has no
//   hidden dependency on `SDGCore.EventBus` and stays trivially
//   testable.
// * `@MainActor` because entity construction and `addChild` are
//   MainActor in iOS 18+.

import Foundation
import RealityKit
import SDGCore

/// Errors raised by `PlateauEnvironmentLoader`. Wraps the converter's
/// errors and adds scene-graph-level failure modes.
public enum PlateauEnvironmentLoaderError: Error, Sendable {

    /// The underlying converter failed. Associated value is the
    /// original converter error for forensic logging.
    case conversionFailed(tile: PlateauTile, underlying: String)

    /// `Entity(contentsOf:)` rejected the converted asset. Usually
    /// means the file is corrupt or written in a USD schema the
    /// current RealityKit can't read.
    case entityLoadFailed(tile: PlateauTile, underlying: String)
}

/// Loads PLATEAU tiles into RealityKit.
///
/// ### Usage
///
/// ```swift
/// let loader = PlateauEnvironmentLoader(bundle: .main)
/// let corridor = try await loader.loadDefaultCorridor()
/// anchor.addChild(corridor)
/// ```
///
/// Instances are cheap — there's no per-loader state worth sharing.
/// A new loader per scene construction is fine.
@MainActor
public final class PlateauEnvironmentLoader {

    // MARK: - Dependencies

    private let bundle: Bundle

    /// - Parameter bundle: Bundle that contains
    ///   `Resources/Environment/Environment_Sendai_*.glb` (or the
    ///   pre-converted `.usdz`). Tests pass a test bundle here; app
    ///   code passes `.main`.
    public init(bundle: Bundle = .main) {
        self.bundle = bundle
    }

    // MARK: - Public API

    /// Function type for sampling the terrain's Y at a given world XZ.
    /// `RootView` supplies a closure that calls
    /// `TerrainLoader.sampleTerrainY`; the loader stays ignorant of
    /// where the terrain Y comes from so tests and alt-terrain
    /// pipelines can substitute their own.
    ///
    /// Returning `nil` means "no data for this XZ" — callers should
    /// fall back to leaving the tile at its default Y = 0.
    public typealias TerrainHeightSampler =
        @MainActor (_ worldXZ: SIMD2<Float>) -> Float?

    /// Load every tile in `PlateauTile.allCases` and compose them
    /// under a single root entity with `localCenter` offsets applied.
    ///
    /// The root is positioned at the world origin; the spawn tile
    /// (`aobayamaCampus`) therefore sits at the world origin too.
    ///
    /// Tile loads run sequentially; PLATEAU tiles are large enough
    /// that running them in parallel pushes peak memory over an
    /// iPad Air's budget (Phase 2 profiling task). Switch to a
    /// `TaskGroup` later if that measurement argues otherwise.
    ///
    /// - Parameter terrainSampler: Optional function that returns the
    ///   terrain Y at a world XZ. When supplied, each tile is raised
    ///   (or lowered) by the terrain Y at *that tile's centre*, so
    ///   the tile's lowest building foundation sits on the ground
    ///   under that tile rather than on the universal Y = 0 plane.
    ///   Leaving this `nil` gives the pre-Phase-3 behaviour where
    ///   every tile sits at Y = 0 regardless of terrain elevation.
    ///
    /// - Throws: First tile failure aborts the corridor load — one
    ///   missing tile means the corridor layout is incomplete, and
    ///   shipping a partial corridor hides the regression.
    public func loadDefaultCorridor(
        terrainSampler: TerrainHeightSampler? = nil
    ) async throws -> Entity {
        let root = Entity()
        root.name = "PlateauCorridor"

        for tile in PlateauTile.allCases {
            let tileRoot = try await loadTile(tile)

            // Horizontal placement: the standard grid (row / column
            // derived from the mesh id).
            var position = tile.localCenter

            // Vertical placement: if we have terrain, sample it at
            // the tile's centre and lift the tile so its bottom-snap
            // anchor (Y = 0 in local space) sits on the ground under
            // the tile. Tile-level adjustment only — buildings within
            // a 1 km tile still see up to ~50 m of ground-elevation
            // variance that a rigid tile shift can't correct. That
            // residual drift is acceptable for a first pass; Phase 4
            // can re-mesh each tile against DEM if needed.
            if let sampler = terrainSampler {
                let xz = SIMD2<Float>(position.x, position.z)
                if let y = sampler(xz) {
                    position.y = y
                }
            }
            tileRoot.position += position
            root.addChild(tileRoot)
        }

        return root
    }

    /// Load a single tile, centre it, and replace its materials with
    /// Toon variants. The returned entity is *not* offset by
    /// `tile.localCenter` — the caller decides whether to place it
    /// absolutely or in a corridor layout.
    public func loadTile(_ tile: PlateauTile) async throws -> Entity {
        // 1. Convert (or read the cache / pre-shipped USDZ).
        let resourceURL: URL
        do {
            resourceURL = try await GLBToUSDZConverter.convertIfNeeded(
                bundle: bundle,
                glbBasename: tile.resourceBasename
            )
        } catch {
            throw PlateauEnvironmentLoaderError.conversionFailed(
                tile: tile,
                underlying: "\(error)"
            )
        }

        // 2. Load into RealityKit.
        let entity: Entity
        do {
            entity = try await Entity(
                contentsOf: resourceURL,
                withName: tile.resourceBasename
            )
        } catch {
            throw PlateauEnvironmentLoaderError.entityLoadFailed(
                tile: tile,
                underlying: "\(error)"
            )
        }

        // 3. Centre horizontally + snap lowest vertex to Y=0. PLATEAU
        //    nusamai output keeps real-world geographic elevation, so
        //    AABB-centre alignment puts half the tile underground.
        //    Bottom-snap keeps buildings on the ground plane while
        //    hill-top buildings remain elevated relative to valley
        //    ones — visually honest until Phase 2 Beta brings DEM.
        EnvironmentCenterer.centerHorizontallyAndGroundY(entity)

        // 4. Toonify.
        let palette = Self.warmToonColour(for: tile)
        Self.applyToonMaterial(toDescendantsOf: entity, baseColor: palette)

        return entity
    }

    // MARK: - Materials

    /// Palette used for the per-tile Toon recolouring. Warm / earthy
    /// tones so real-world buildings still read as "built-up city
    /// blocks" rather than Saturday-morning-cartoon colours, while
    /// being distinct enough per tile that players can tell them
    /// apart at a glance from hilltops.
    ///
    /// Internal for testing — the test wants to assert that the
    /// mapping is deterministic (same tile → same colour every run).
    internal static let warmPalette: [SIMD3<Float>] = [
        // Pale sandstone
        SIMD3<Float>(0.89, 0.82, 0.70),
        // Warm beige
        SIMD3<Float>(0.85, 0.76, 0.62),
        // Dusty rose-brown
        SIMD3<Float>(0.80, 0.66, 0.56),
        // Light taupe
        SIMD3<Float>(0.74, 0.67, 0.58),
        // Pale ochre
        SIMD3<Float>(0.88, 0.76, 0.52),
        // Soft clay
        SIMD3<Float>(0.82, 0.70, 0.54),
        // Muted khaki
        SIMD3<Float>(0.76, 0.73, 0.58),
        // Cream
        SIMD3<Float>(0.92, 0.87, 0.76)
    ]

    /// Pick a palette entry for `tile`. Deterministic — same tile
    /// always maps to the same colour across runs so bug reports
    /// "the east tile is the wrong shade" are reproducible.
    ///
    /// Exposed `internal` so `PlateauEnvironmentLoaderMaterialTests`
    /// can assert determinism without running a full load.
    internal static func warmToonColour(for tile: PlateauTile) -> SIMD3<Float> {
        // Stable hash: index of the tile in `allCases`, modulo palette
        // size. `allCases` order is source-fixed (see `PlateauTile`),
        // so the mapping is a source-level contract rather than a
        // runtime coincidence.
        let index = PlateauTile.allCases.firstIndex(of: tile) ?? 0
        return warmPalette[index % warmPalette.count]
    }

    /// Walk the entity tree and replace every `ModelComponent`'s
    /// materials with a single Toon material coloured `baseColor`.
    /// All mesh parts on the same entity share the material — the
    /// intent is the "blocky building" look that matches the rest of
    /// the Phase 1 / Phase 2 POC aesthetic (see ADR-0004).
    ///
    /// Exposed `internal` so tests can exercise it on synthetic
    /// hierarchies without going through `loadTile(...)`.
    internal static func applyToonMaterial(
        toDescendantsOf root: Entity,
        baseColor: SIMD3<Float>
    ) {
        // Phase 3 Toon upgrade: buildings now use the "harder cel"
        // variant which pushes emissive higher and removes residual
        // specular, so the PLATEAU facades read as flat cartoon
        // volumes rather than realistic-lit buildings with a tint.
        // Geology layers inside the outcrop keep the softer
        // `makeLayerMaterial` so the drillable rock stays visually
        // distinct from the surrounding city.
        //
        // True NdotL step-ramp (ADR-0004 scheme A) is still follow-up
        // work pending Reality Composer Pro authoring.
        let material = ToonMaterialFactory.makeHardCelMaterial(
            baseColor: baseColor
        )

        // Iterative depth-first walk. Recursing into the built-in
        // tree can blow the stack on dense PLATEAU scenes (hundreds
        // of building parts); an explicit stack keeps us flat.
        var stack: [Entity] = [root]
        while let current = stack.popLast() {
            if var modelComponent = current.components[ModelComponent.self] {
                // Replace all material slots. Blocky / single-colour
                // look per ADR-0004; a future Phase 2 Beta task will
                // diversify at the individual-building level.
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
