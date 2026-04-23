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

/// How a tile's root entity should be centred after loading. Separate
/// from placement so callers can combine "skip centring" with an
/// envelope-supplied absolute position (Phase 4 CityGML alignment) or
/// keep the Phase 2 bottom-snap fallback when no manifest is supplied.
///
/// Exposed `public` because `loadTile(_:centerMode:)` takes it as a
/// parameter; callers that want to opt out of centring need the enum
/// in scope.
public enum PlateauTileCenterMode: Sendable {

    /// Centre horizontally + snap lowest vertex to Y = 0. The Phase 2
    /// Alpha default — see `EnvironmentCenterer.centerHorizontallyAndGroundY`
    /// and `loadDefaultCorridor()`'s doc comment for the trade-offs.
    case bottomSnap

    /// Translate so the AABB centre sits at the tile's local origin.
    /// Useful when downstream code wants to control Y placement itself
    /// (e.g. a caller supplying its own ground plane).
    case aabbCenter

    /// Skip centring entirely. The tile keeps whatever local origin
    /// nusamai emitted — AABB-centred in its own frame by the converter.
    /// Paired with `EnvelopeManifest.realityKitPosition(for:)` at the
    /// corridor level, this is the Phase 4 real-world-origin path: the
    /// manifest supplies the absolute position and the entity's own
    /// frame stays untouched.
    case none
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

    /// Load every tile in `PlateauTile.allCases` and compose them
    /// under a single root entity.
    ///
    /// ### Placement strategy
    ///
    /// Two modes, selected by the presence of a `manifest`:
    ///
    /// * **No manifest (legacy path, default)**: each tile is
    ///   bottom-snapped via `EnvironmentCenterer.centerHorizontallyAndGroundY`
    ///   and then offset by `tile.localCenter` — the Phase 2 Alpha
    ///   layout that spaces tiles on a nominal 3rd-mesh grid. Kept as
    ///   the default so existing callers (and the legacy test suite)
    ///   stay on the same code path.
    ///
    /// * **With manifest (Phase 4 CityGML alignment)**: each tile's
    ///   position comes from `manifest.realityKitPosition(for:)`,
    ///   which resolves the real-world envelope centre relative to
    ///   the spawn tile. Centring is skipped (`CenterMode.none`) so
    ///   the entity keeps its nusamai-emitted local origin, and the
    ///   manifest position is written **absolutely** — not added to
    ///   anything else. This is the root-cause fix for the floating-
    ///   building regression discussed in ADR-0006: with a shared
    ///   coordinate anchor, buildings and the DEM agree on where
    ///   things live.
    ///
    ///   If a tile is missing from the manifest the loader logs a
    ///   warning and falls back to the legacy `tile.localCenter` +
    ///   bottom-snap path for that tile only — a partial manifest
    ///   must not blackhole the whole corridor.
    ///
    /// The root is positioned at the world origin; the spawn tile
    /// (`aobayamaCampus`) therefore sits at the world origin too.
    ///
    /// Tile loads run sequentially; PLATEAU tiles are large enough
    /// that running them in parallel pushes peak memory over an
    /// iPad Air's budget (Phase 2 profiling task). Switch to a
    /// `TaskGroup` later if that measurement argues otherwise.
    ///
    /// - Parameter manifest: Optional CityGML envelope manifest.
    ///   `nil` (the default) keeps the Phase 2 legacy layout;
    ///   non-`nil` switches on the Phase 4 real-origin placement
    ///   path.
    /// - Throws: First tile failure aborts the corridor load — one
    ///   missing tile means the corridor layout is incomplete, and
    ///   shipping a partial corridor hides the regression.
    /// Closure that returns the world-space terrain Y at a given
    /// world XZ, or `nil` if the query is outside the terrain
    /// footprint. Supplied by `RootView` by wrapping
    /// `TerrainLoader.sampleTerrainY`. Injected (rather than the
    /// loader reaching for a `TerrainLoader` directly) so tests can
    /// substitute a deterministic fake and the layering stays clean —
    /// `PlateauEnvironmentLoader` doesn't need to know the DEM exists
    /// as an entity, only that someone can look up Y at an XZ.
    public typealias TerrainHeightSampler = @MainActor (SIMD2<Float>) -> Float?

    /// How far above the sampled DEM Y each tile's mesh-bottom is
    /// parked in the Phase 5 adaptive-snap path.
    ///
    /// History:
    ///   - iter 1: 2.0 (small z-fighting buffer + absorb DEM sampling
    ///     error; too much — device showed every building floating)
    ///   - iter 2: 2.0 → 0.0 (flush contact: buildings now visibly
    ///     sit on the DEM. Accept the risk of occasional z-fighting
    ///     where mesh and terrain share the same Y; re-introduce a
    ///     sub-metre margin only if playtest shows flicker)
    ///
    /// Exposed `internal` so a test pin can catch silent changes.
    internal static let adaptiveGroundSnapSkip: Float = 0.0

    public func loadDefaultCorridor(
        manifest: EnvelopeManifest? = nil,
        terrainSampler: TerrainHeightSampler? = nil
    ) async throws -> Entity {
        let root = Entity()
        root.name = "PlateauCorridor"

        for tile in PlateauTile.allCases {
            let placement = Self.tilePlacement(tile: tile, manifest: manifest)
            let tileRoot = try await loadTile(tile, centerMode: placement.centerMode)
            // Absolute assignment in both modes. See `tilePlacement` docs
            // and ADR-0006 for the `+=` → `=` history.
            tileRoot.position = placement.position

            // Phase 5 adaptive ground snap. When the caller supplies
            // a DEM sampler (and we're on the envelope/manifest path),
            // override the per-tile Y so the tile's mesh bottom sits
            // `adaptiveGroundSnapSkip` above the sampled DEM Y at the
            // tile's own XZ. That replaces the Phase 4 global
            // `envelopeTileGroundLift` constant — playtest confirmed
            // a single constant can't serve every tile because nusamai's
            // AABB centre is a tile-specific distance from the typical
            // foundation depending on how much basement / ground-surface
            // geometry the LOD2 data happens to include.
            //
            // Runs only when BOTH manifest and sampler are present.
            // Without a manifest, tiles are on the legacy localCenter
            // grid at Y = 0 and the DEM isn't in play. Without a sampler,
            // the constant lift stays in place for the stripped-bundle
            // / test-bundle fallback.
            if let terrainSampler, manifest != nil {
                Self.adaptiveGroundSnap(
                    tile: tileRoot,
                    terrainSampler: terrainSampler,
                    basementSkip: Self.adaptiveGroundSnapSkip
                )
            }
            root.addChild(tileRoot)
        }

        return root
    }

    /// Shift `tile.position.y` so the entity's current world-space
    /// visualBounds min Y lands `basementSkip` above `terrainSampler`
    /// sampled at the tile's XZ. No-op if the sampler returns `nil`
    /// or the tile has no bounded mesh yet — keeping the call safe
    /// even before the full scene graph is ready.
    ///
    /// Exposed `internal` for a dedicated unit test; RootView is
    /// expected to call it indirectly through `loadDefaultCorridor`.
    @MainActor
    internal static func adaptiveGroundSnap(
        tile: Entity,
        terrainSampler: TerrainHeightSampler,
        basementSkip: Float
    ) {
        // Read bounds first so we can sample the DEM at the mesh's
        // actual world XZ centre (see earlier `/root` transform note).
        let bounds = tile.visualBounds(relativeTo: nil)
        guard !bounds.isEmpty else { return }
        let xz = SIMD2<Float>(bounds.center.x, bounds.center.z)
        guard let demY = terrainSampler(xz) else { return }

        // Snap on the AABB **centre** (not min). Rationale from the
        // first Phase 5 device test: PLATEAU LOD2 tiles come out of
        // nusamai with ~150 m of internal Y range (hilltop buildings +
        // valley-floor basements / ground surfaces all in the same
        // GLB). Anchoring `bounds.min.y` at DEM puts the entire mesh
        // *above* the DEM — every building flies 0…150 m up. Anchoring
        // the **centre** instead distributes the tile's Y range around
        // the DEM level: roughly half the mesh peeks above the
        // terrain surface (the visible buildings), the lower half
        // submerges below the DEM mesh (where the terrain mesh
        // naturally occludes it — no visual artefact unless the
        // player walks under).
        //
        // This matches what a player standing on the terrain expects:
        // buildings on the hill above them, distant buildings receding
        // into lower valleys. Residual misalignment inside a tile is
        // capped at ~±75 m (half the tile's Y range) and only matters
        // for outlier geometry — phase 6 per-building re-projection
        // is the full fix.
        //
        // `basementSkip` (despite the historical name) now shifts the
        // centre-anchored tile a few metres UP from the DEM so the
        // visible building cluster reads as "on top of" the terrain
        // rather than straddling it.
        let currentCentreY = bounds.center.y
        let delta = (demY + basementSkip) - currentCentreY
        tile.position.y += delta

        // Diagnostic breadcrumb. Keep through Phase 5 QA; delete for
        // ship. Prints are a few per corridor-load — not hot-path.
        print(
            "[SDG-Lab][p5] snap tile name=\(tile.name) " +
            "pos=(\(tile.position.x), \(tile.position.z)) " +
            "centerXZ=(\(bounds.center.x), \(bounds.center.z)) " +
            "centerY=\(currentCentreY) → demY=\(demY) delta=\(delta) " +
            "newPosY=\(tile.position.y)"
        )
    }

    /// Load a single tile and replace its materials with Toon variants.
    /// The returned entity is *not* offset by `tile.localCenter` — the
    /// caller decides whether to place it absolutely or in a corridor
    /// layout.
    ///
    /// - Parameter tile: The PLATEAU tile to load.
    /// - Parameter centerMode: How to centre the loaded entity before
    ///   returning. Defaults to `.bottomSnap` — the Phase 2 Alpha
    ///   behaviour, kept as the default so existing callers don't have
    ///   to opt in. Phase 4 callers that place tiles via an envelope
    ///   manifest pass `.none` so the entity keeps its nusamai-emitted
    ///   local origin.
    public func loadTile(
        _ tile: PlateauTile,
        centerMode: PlateauTileCenterMode = .bottomSnap
    ) async throws -> Entity {
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

        // 3. Centre according to the caller's chosen mode. PLATEAU
        //    nusamai output keeps real-world geographic elevation, so
        //    AABB-centre alignment puts half the tile underground.
        //    Bottom-snap keeps buildings on the ground plane while
        //    hill-top buildings remain elevated relative to valley
        //    ones — visually honest when no envelope manifest is
        //    supplied. The Phase 4 envelope path skips centring
        //    entirely and relies on the manifest's real-world origin
        //    for absolute placement.
        switch centerMode {
        case .bottomSnap:
            EnvironmentCenterer.centerHorizontallyAndGroundY(entity)
        case .aabbCenter:
            EnvironmentCenterer.centerAtOrigin(entity)
        case .none:
            break
        }

        // 4. Toonify.
        let palette = Self.warmToonColour(for: tile)
        Self.applyToonMaterial(toDescendantsOf: entity, baseColor: palette)

        return entity
    }

    // MARK: - Placement helper

    /// Compute a tile's final position and centring mode given an
    /// optional envelope manifest. Pure function — no scene graph
    /// access — so the placement policy is unit-testable without
    /// loading a USDZ.
    ///
    /// Semantics:
    /// * `manifest == nil` → legacy path: `(tile.localCenter, .bottomSnap)`.
    /// * `manifest` supplies the tile id → Phase 4 path:
    ///   `(manifest.realityKitPosition(for: tile.rawValue)!, .none)`.
    /// * `manifest` omits the tile id → partial-manifest fallback:
    ///   `(tile.localCenter, .bottomSnap)`, plus a warning log so
    ///   the gap is visible during bring-up.
    ///
    /// Exposed `internal` for the test suite. Returning a struct with
    /// named fields (rather than a tuple) keeps the call sites readable
    /// and makes adding a third axis — e.g. per-tile scale overrides —
    /// a non-breaking change.
    internal static func tilePlacement(
        tile: PlateauTile,
        manifest: EnvelopeManifest?
    ) -> (position: SIMD3<Float>, centerMode: PlateauTileCenterMode) {
        guard let manifest else {
            return (tile.localCenter, .bottomSnap)
        }
        if var envelopePosition = manifest.realityKitPosition(for: tile.rawValue) {
            // Phase 4 iteration 2: on-device inspection shows buildings
            // sinking ~5 m into the DEM surface. The envelope's Z centre
            // doesn't quite line up with the mesh's geometric Y centre
            // because CityGML's LOD2 bldg data includes basement walls
            // and ground surfaces below the apparent foundation, dragging
            // the mesh AABB lower than the envelope midpoint. A constant
            // vertical nudge is the pragmatic fix while we stay within
            // DEM-grid-resolution anyway (~30 m); Phase 5 can refine with
            // per-building ground sampling if needed.
            envelopePosition.y += Self.envelopeTileGroundLift
            return (envelopePosition, .none)
        }
        // Partial manifest — fall back per-tile so the rest of the
        // corridor can still load. Visible as a warning so playtest
        // bug reports of "one tile in the wrong place" lead back to
        // the pipeline output rather than the runtime.
        print(
            "[SDG-Lab][plateau] envelope manifest missing tile id \(tile.rawValue); " +
            "falling back to localCenter + bottom-snap"
        )
        return (tile.localCenter, .bottomSnap)
    }

    /// Constant upward nudge applied to every tile positioned via the
    /// envelope manifest. See `tilePlacement` for the rationale.
    /// Exposed `internal` so a future test can pin the value without
    /// reopening the type — tuning this constant is a frequent kind
    /// of playtest iteration.
    ///
    /// History:
    ///   - Phase 4 iter 2: 5.0 (first guess after "buildings sunk ~5 m")
    ///   - Phase 4 iter 4: 5.0 → 10.0 (still slightly sunk at 5 m)
    ///   - Phase 4 iter 5: 10.0 → 15.0 (buildings at hilltops still clip
    ///     terrain; extra 5 m defends against the worst LOD2 basement dip)
    ///   - Phase 4 iter 7: 15.0 → 25.0 (large cluster of buildings still
    ///     visibly sunk)
    ///   - Phase 4 iter 8: 25.0 → 20.0 (25 flew buildings above terrain)
    ///   - Phase 4 iter 9: 20.0 → 18.0 (20 still slightly high on most
    ///     tiles; 18 trades the last 2 m back toward "sitting on" look)
    ///
    /// 18 m is well outside "rounding artefact" territory — this
    /// really is a structural tile-by-tile mismatch. A single global
    /// constant is the wrong shape; Phase 5 should do per-tile lift
    /// (derived from the envelope / DEM sample at each tile's centre)
    /// or per-building DEM re-projection in the Blender pipeline.
    /// Tracked in ADR-0007's "Known limitations" section.
    internal static let envelopeTileGroundLift: Float = 18.0

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
