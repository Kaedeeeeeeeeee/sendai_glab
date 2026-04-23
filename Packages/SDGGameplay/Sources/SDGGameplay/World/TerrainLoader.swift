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
// ## Alignment — Phase 4 CityGML envelope integration
//
// Phase 3 attempted four runtime alignment strategies, all of which
// failed on device because nusamai 0.1.0 centres every GLB on its own
// AABB and discards the real-world geographic origin (ADR-0006).
//
// Phase 4 solves this by parsing each source CityGML file's
// `<gml:Envelope>` block before nusamai destroys it, persisting the
// result as `Resources/Environment/plateau_envelopes.json`, and
// consuming it via `EnvelopeManifest`. When a manifest is supplied at
// construction time, the terrain is placed at its *real-world* position
// relative to the spawn tile's envelope centre — no bottom-snap, no
// AABB-centre correction, because the envelope already carries the
// absolute offset (ADR-0007).
//
// The loader still supports a manifest-less mode so tests and
// experimental callers that don't care about alignment can use the
// Phase 3 bottom-snap path. This is intentional backwards compatibility,
// not a design escape hatch — any production code path that ships the
// terrain to a user **must** pass a manifest.

import Foundation
import RealityKit

/// Loads a PLATEAU DEM terrain USDZ from the bundle and places it
/// using either a `EnvelopeManifest` (preferred, Phase 4) or the legacy
/// Phase 3 bottom-snap fallback.
///
/// Public API mirrors the building loader where practical:
///   - `init(bundle:manifest:terrainTileId:)`  — construction is cheap,
///     no I/O. The manifest is retained only to look up the terrain's
///     real-world position at `load()` time.
///   - `load()`  — returns a RealityKit `Entity` ready to add to the
///     scene as a single unit.
///
/// Tile identifier defaults to the single Phase 4 shipment
/// (`Terrain_Sendai_574036_05` / manifest key `"574036_05_dem"`) — the
/// 5 × 5 km NE quadrant of PLATEAU 2nd-mesh 574036. Additional DEM tiles
/// (when the pipeline produces them) can be loaded by passing a
/// different `terrainTileId`.
@MainActor
public final class TerrainLoader {

    /// Error surfaces produced by `load()`. Each case carries enough
    /// context for a single-line log ("terrain USDZ missing at …").
    ///
    /// `envelopeMissing(tileId:)` is Phase 4's addition: it fires when
    /// the caller supplied a manifest but the manifest does not contain
    /// the terrain's tile id. We fail loudly instead of silently
    /// falling back to bottom-snap because such a mismatch is almost
    /// always a data-pipeline misconfiguration (the Python extractor
    /// wasn't asked to emit the DEM entry, or the `defaultTerrainTileId`
    /// drifted) — and hiding it would mean the first sign of the bug is
    /// a visually subtle mis-alignment on device, which is exactly the
    /// regression Phase 4 exists to prevent.
    public enum LoadError: Error, CustomStringConvertible {
        case resourceNotFound(basename: String)
        case realityKitLoadFailed(underlying: Error)
        case envelopeMissing(tileId: String)

        public var description: String {
            switch self {
            case .resourceNotFound(let b):
                return "Terrain USDZ not found in bundle: \(b).usdz"
            case .realityKitLoadFailed(let e):
                return "RealityKit failed to load terrain USDZ: \(e)"
            case .envelopeMissing(let id):
                return "EnvelopeManifest does not contain terrain tile id `\(id)`"
            }
        }
    }

    /// Manifest key for the Phase 4 DEM tile. Matches the entry written
    /// by `Tools/plateau-pipeline/extract_envelopes.py` (the DEM is
    /// labelled `574036_05_dem` rather than the mesh id alone because
    /// it is not a 3rd-mesh and has no mesh-id rawValue to share).
    ///
    /// Kept separate from `defaultBasename` because the manifest key
    /// (identity in the envelope JSON) and the USDZ basename (identity
    /// on disk) are logically independent — the pipeline could rename
    /// either without touching the other.
    public static let defaultTerrainTileId = "574036_05_dem"

    /// Basename of the Phase 4 terrain USDZ shipped in
    /// `Resources/Environment/`. Kept as a static let (not a parameter)
    /// because the rest of the pipeline — the Blender script, the
    /// project.yml resource list, the `.gitattributes` LFS rule — all
    /// ship the same single file. A parameter would imply flexibility
    /// the pipeline doesn't yet provide.
    public static let defaultBasename = "Terrain_Sendai_574036_05"

    /// The default earthy tint for terrain. Mud-olive: warm enough to
    /// not feel cold on a sunny day, dark enough to sit visually
    /// *under* the building palette. Public so tests and call sites
    /// that want to override the tint can reference the original value.
    public static let defaultTerrainColor = SIMD3<Float>(0.42, 0.48, 0.30)

    // MARK: - Dependencies

    private let bundle: Bundle
    private let manifest: EnvelopeManifest?
    private let terrainTileId: String

    /// - Parameters:
    ///   - bundle: Resource bundle containing the USDZ. Defaults to the
    ///     app bundle; tests pass `Bundle(for: type(of: self))` or a
    ///     fixture bundle.
    ///   - manifest: Optional Phase 4 envelope manifest. When supplied,
    ///     the terrain is placed at its real-world origin via
    ///     `manifest.realityKitPosition(for: terrainTileId)` — the
    ///     bottom-snap `EnvironmentCenterer.centerHorizontallyAndGroundY`
    ///     call is skipped because the envelope already carries the
    ///     correct offset and stacking them would double-apply the
    ///     vertical shift. When `nil`, the loader falls back to the
    ///     Phase 3 bottom-snap path (kept for tests and experimental
    ///     callers; production must pass a manifest).
    ///   - terrainTileId: The manifest key for this terrain's envelope.
    ///     Defaults to `defaultTerrainTileId`. Exists so future DEM
    ///     shipments (e.g. a second quadrant) can be loaded without
    ///     adding another class.
    public init(
        bundle: Bundle = .main,
        manifest: EnvelopeManifest? = nil,
        terrainTileId: String = TerrainLoader.defaultTerrainTileId
    ) {
        self.bundle = bundle
        self.manifest = manifest
        self.terrainTileId = terrainTileId
    }

    /// Load, place (via manifest or fallback), apply an earthy Toon
    /// material, and generate collision shapes so RootView can raycast
    /// against the surface to anchor the player.
    ///
    /// The method does a fair amount up front (mesh load, collision
    /// generation, material walk) because the terrain is a single
    /// long-lived entity — doing the setup once at load time is
    /// preferable to leaving it as the caller's responsibility and
    /// having every call-site duplicate it.
    ///
    /// ## Error order
    ///
    /// 1. If the USDZ cannot be located in the bundle → `.resourceNotFound`.
    /// 2. If RealityKit refuses to load it → `.realityKitLoadFailed`.
    /// 3. If a manifest was supplied but lacks our terrain id →
    ///    `.envelopeMissing`. This check runs **after** the load
    ///    succeeds so tests that use an empty bundle still see
    ///    `.resourceNotFound` first (cheaper to diagnose).
    public func load() async throws -> Entity {
        let basename = Self.defaultBasename
        // Try the loose root first (iOS `.app` bundles flatten
        // `Resources/` by default), then the `Environment/` subfolder
        // (SPM test bundles preserve structure when resources are
        // processed). This matches the pattern used by `AudioService`
        // and `GeologySceneBuilder`; see CLAUDE.md §"重要な技術的落とし穴".
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

        // Phase 4 path: manifest-driven absolute placement.
        //
        // The envelope encodes the terrain's real-world centre in
        // EPSG:6677, remapped by `EnvelopeManifest` into RealityKit
        // axes with the spawn tile at the origin. Setting `position`
        // alone is enough — we deliberately do *not* call
        // `centerHorizontallyAndGroundY` here because nusamai already
        // centred the mesh on its own AABB at (0,0,0), so the manifest
        // position is what moves the tile into its real place. A
        // bottom-snap on top of that would add the AABB's half-height
        // back in, re-introducing the Phase 3 valley-floating bug.
        if let manifest {
            guard let position = manifest.realityKitPosition(for: terrainTileId) else {
                throw LoadError.envelopeMissing(tileId: terrainTileId)
            }
            entity.position = position
        } else {
            // Manifest-less fallback: preserve the Phase 3 bottom-snap
            // behaviour so tests and experimental call-sites can use
            // the loader in isolation. Production code paths must pass
            // a manifest; CI doesn't police that, but every RootView
            // integration point we ship does.
            EnvironmentCenterer.centerHorizontallyAndGroundY(entity)
        }

        // Mud-olive base colour for "dirt with a hint of grass". Chosen
        // so the ground reads as sitting *under* the buildings'
        // warm palette rather than competing with it. Hand-tuned on
        // real-device preview; see CLAUDE.md Phase 3 progress notes.
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

        // Tag so `PlayerControlSystem` (and any future ground-aware
        // system) can look up this entity via an `EntityQuery` and
        // call `sampleTerrainY` against its mesh.
        entity.components.set(TerrainComponent())

        entity.name = "PlateauTerrain_\(basename)"
        return entity
    }

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
    /// because `Entity.transformMatrix(relativeTo:)` and descendant
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
        // Harder cel variant (Phase 3 upgrade, preserved into Phase 4):
        // terrain reads as clearly cartoonish rather than a realistic-
        // with-toon-tint ground. See `ToonMaterialFactory
        // .makeHardCelMaterial` header for the difference vs. the
        // softer `makeLayerMaterial`.
        let material = ToonMaterialFactory.makeHardCelMaterial(
            baseColor: baseColor
        )

        // Explicit iterative walk — mirrors PlateauEnvironmentLoader
        // to keep the visual contract identical between buildings and
        // terrain (same strength, same factory). Recursing into the
        // built-in tree can blow the stack on dense meshes; an explicit
        // stack keeps us flat.
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
