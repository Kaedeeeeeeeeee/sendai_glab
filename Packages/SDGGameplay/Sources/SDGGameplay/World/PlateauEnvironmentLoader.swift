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

            // Legacy Phase 5 adaptive ground snap. Runs only when the
            // caller supplies both a manifest and a runtime DEM sampler.
            // Phase 6.1 mainline corridor loads omit the sampler because
            // the Blender pipeline now bakes per-building snap into the
            // USDZ (see `split_bldg_by_connectivity.py`), making runtime
            // snap redundant — and actively harmful, because re-snapping
            // a pre-aligned tile as a rigid body would undo the per-
            // building work. The sampler path remains live for the
            // test suite and for legacy single-mesh USDZs that have not
            // been re-baked.
            if let terrainSampler, manifest != nil {
                // Phase 6: walk tile's descendants and snap each mesh
                // entity (one per building after the
                // `split_bldg_by_connectivity.py` offline pass). Falls
                // back to tile-level snap when the USDZ is a legacy
                // single-mesh (no per-building children) — keeps the
                // Phase 5 behaviour as a fallback for stripped bundles.
                Self.snapDescendantBuildings(
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
        // No diagnostic print: Phase 6 calls this once per building
        // (~1000 times per tile), which would flood Console.app.
    }

    /// Find every descendant with a `ModelComponent` (each represents
    /// one PLATEAU building after the Phase 6 offline split pipeline)
    /// and apply `adaptiveGroundSnap` to it independently. When the
    /// tile has no mesh-bearing descendants — i.e. it's a legacy
    /// single-mesh USDZ from before the split — fall back to snapping
    /// the tile entity itself.
    ///
    /// Returns the number of descendants snapped (0 for the
    /// fallback). Exposed `internal` for tests.
    ///
    /// ### Why stop descent on first ModelComponent
    ///
    /// For a hierarchy root → building → mesh_part, we want to snap
    /// the *building* (so all its parts move together), not each
    /// mesh part. Stopping descent on the first `ModelComponent`-
    /// bearing node along each branch is the right policy as long
    /// as buildings are at most one `ModelComponent` layer deep —
    /// which is how Blender's USD export lays out the split tiles.
    @MainActor
    @discardableResult
    internal static func snapDescendantBuildings(
        tile: Entity,
        terrainSampler: TerrainHeightSampler,
        basementSkip: Float
    ) -> Int {
        // Collect the top-most mesh-bearing descendants. Iterative
        // DFS, mirroring `applyToonMaterial`'s walk pattern.
        var buildings: [Entity] = []
        var stack: [Entity] = [tile]
        while let current = stack.popLast() {
            if current.components[ModelComponent.self] != nil {
                buildings.append(current)
                // Don't descend into this subtree — snapping the
                // parent moves the children automatically.
                continue
            }
            stack.append(contentsOf: current.children)
        }

        guard !buildings.isEmpty else {
            // Legacy single-mesh USDZ (pre-split) — the tile root
            // itself has no ModelComponent and no mesh-bearing
            // descendants visible to us. Snap the tile as a rigid
            // body, Phase-5 style.
            adaptiveGroundSnap(
                tile: tile,
                terrainSampler: terrainSampler,
                basementSkip: basementSkip
            )
            return 0
        }

        for building in buildings {
            adaptiveGroundSnap(
                tile: building,
                terrainSampler: terrainSampler,
                basementSkip: basementSkip
            )
        }
        return buildings.count
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

        // 4. Toonify (Phase 11 Part D: hybrid — preserve textures when
        //    the USDZ shipped them, flat cel for everything else).
        let palette = Self.warmToonColour(for: tile)
        Self.applyHybridToonTint(toDescendantsOf: entity, baseColor: palette)

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
        if let envelopePosition = manifest.realityKitPosition(for: tile.rawValue) {
            // Phase 6.1: tiles are pre-snapped offline by
            // `split_bldg_by_connectivity.py` (each building's foundation
            // already sits on the DEM surface inside the baked USDZ).
            // Runtime placement is therefore pure envelope positioning —
            // no additional lift. The old `envelopeTileGroundLift`
            // constant (5→10→15→25→20→18 across Phase 4 iterations) was
            // a runtime compensation for the missing offline snap; with
            // Phase 6.1 it turned into pure 18 m float and caused the
            // "still flying" regression after the offline pipeline
            // landed. See ADR-0008 § Phase 6.1 for the offline contract.
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

    /// Walk the entity tree and apply a **hybrid** Toon tint to every
    /// `ModelComponent`'s material slots:
    ///
    /// * If a slot already holds a **textured `PhysicallyBasedMaterial`**
    ///   (Phase 11 Part C ships PLATEAU USDZs with baked facade JPGs),
    ///   **mutate it in place** via
    ///   `ToonMaterialFactory.mutateIntoTexturedCel(_:)`. The facade
    ///   texture survives into the render; emissive is boosted and
    ///   specular is killed so the result reads as "painted realistic"
    ///   / Borderlands-ish rather than raw PBR.
    ///
    /// * Otherwise (slot holds a `SimpleMaterial`, an *untextured* PBR
    ///   material, or anything the mutator can't identify as
    ///   texture-bearing), **replace the slot** with a fresh
    ///   `ToonMaterialFactory.makeHardCelMaterial(baseColor:)` using
    ///   the legacy per-tile warm palette. This keeps Phase 6.1's
    ///   pre-textured USDZs and any stray debug meshes visually
    ///   consistent with the rest of the cel look.
    ///
    /// The outline shell (see `ToonMaterialFactory.makeOutlineEntity(for:)`)
    /// is attached by callers, not by this function. The hybrid tint
    /// only touches the material layer.
    ///
    /// Exposed `internal` so tests can exercise the branch selection
    /// on synthetic hierarchies without going through `loadTile(...)`.
    ///
    /// - Parameters:
    ///   - root: Entity whose descendants will be walked.
    ///   - baseColor: Fallback warm-palette colour used by
    ///     `makeHardCelMaterial` for any slot that is *not* a textured
    ///     PBR. Ignored by the mutator branch (which preserves the
    ///     texture's colour identity).
    internal static func applyHybridToonTint(
        toDescendantsOf root: Entity,
        baseColor: SIMD3<Float>
    ) {
        // Phase 3 → Phase 11 Part D Toon upgrade:
        //   * Pre-Phase-11-C USDZs had no texture; hard-cel flat fill
        //     is the correct behaviour for them and is retained as the
        //     fallback branch.
        //   * Phase 11 Part C bakes facade JPGs into the USDZs. The
        //     legacy "replace every material with a flat cel" would
        //     throw the baked textures away, which was the whole
        //     regression this function exists to prevent.
        //
        // See ADR-0004 (Toon) for the Scheme C rationale and ADR-0008
        // § Phase 6.1 for why these tiles end up as single merged
        // meshes at runtime.
        let fallbackCel = ToonMaterialFactory.makeHardCelMaterial(
            baseColor: baseColor
        )

        // Iterative depth-first walk. Recursing into the built-in
        // tree can blow the stack on dense PLATEAU scenes (hundreds
        // of building parts); an explicit stack keeps us flat.
        //
        // Phase 9 Part G note — why NO collision on PLATEAU tiles:
        // Phase 6.1 merged every per-tile building into one mesh
        // to keep draw calls low (5 per corridor instead of 4 443).
        // `generateCollisionShapes(recursive:)` on a merged mesh
        // produces a single AABB covering the whole tile (~1 km
        // wide, ~150 m tall on Aobayama). A horizontal raycast
        // from inside that AABB hits its boundary at distance 0,
        // which froze the player in place on device. Accurate
        // per-building collision needs `ShapeResource
        // .generateStaticMesh(from:)` (triangle-accurate) or
        // re-splitting the tiles pre-merge. Both are Phase 10
        // follow-ups. For now buildings are visual-only and the
        // player walks through them — the lab interior still has
        // proper collision because InteriorSceneBuilder ships
        // per-slab `CollisionComponent` directly.
        var stack: [Entity] = [root]
        while let current = stack.popLast() {
            if var modelComponent = current.components[ModelComponent.self] {
                let count = max(1, modelComponent.materials.count)
                var newSlots: [RealityKit.Material] = []
                newSlots.reserveCapacity(count)
                for index in 0..<count {
                    let existing: RealityKit.Material? =
                        index < modelComponent.materials.count
                        ? modelComponent.materials[index]
                        : nil
                    newSlots.append(
                        hybridTintedMaterial(
                            for: existing,
                            fallback: fallbackCel
                        )
                    )
                }
                modelComponent.materials = newSlots
                current.components.set(modelComponent)
            }
            stack.append(contentsOf: current.children)
        }
    }

    /// Branch-selection predicate for `applyHybridToonTint`. Returns:
    ///
    /// * The result of `ToonMaterialFactory.mutateIntoTexturedCel(_:)`
    ///   if `existing` is a `PhysicallyBasedMaterial` **and** carries a
    ///   non-nil `baseColor.texture` (i.e. the USDZ baked a texture
    ///   into that slot).
    /// * `fallback` otherwise — for `SimpleMaterial`, untextured PBR,
    ///   `nil` slots, or any material type the mutator cannot identify.
    ///
    /// Exposed `internal` so `PlateauEnvironmentLoaderMaterialTests`
    /// can exercise the branch directly without constructing a full
    /// entity hierarchy.
    internal static func hybridTintedMaterial(
        for existing: RealityKit.Material?,
        fallback: RealityKit.Material
    ) -> RealityKit.Material {
        guard let pbr = existing as? PhysicallyBasedMaterial else {
            return fallback
        }
        // The texture survival test: if the USDZ shipped an actual
        // baseColor texture, keep it and push the rest of the material
        // toward the painted-cel look. Otherwise the PBR is just a
        // tinted PBR and the hard-cel replacement is the right answer.
        guard pbr.baseColor.texture != nil else {
            return fallback
        }
        return ToonMaterialFactory.mutateIntoTexturedCel(pbr)
    }
}
