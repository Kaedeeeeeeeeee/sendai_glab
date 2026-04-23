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

    /// Sample the terrain's Y in world space at a given X / Z by
    /// finding the triangle whose horizontal (XZ) projection contains
    /// the target and returning the barycentric-interpolated Y of its
    /// three vertices. Returns `nil` if no triangle in the entity's
    /// mesh covers `target` (e.g. the entity has no mesh, or the
    /// target is outside the terrain's footprint).
    ///
    /// ### Why not nearest-vertex
    ///
    /// The Phase 3 / 4 implementations used nearest-vertex sampling.
    /// On the decimated DEM (15 K verts across 5 × 5 km ≈ 28 m vertex
    /// spacing) a slope triangle's midpoint can sit several metres
    /// *above* its nearest vertex's Y. Players snapped onto that
    /// lower Y got embedded in the slope face, so the first-person
    /// camera rendered from inside the mesh ("walking over a slope
    /// the camera clips into the hill underside" — iter 4 playtest).
    /// Barycentric interpolation returns the exact mesh surface Y, so
    /// the snap can keep a centimetre-scale margin without the camera
    /// ducking under the surface.
    ///
    /// ### Cost
    ///
    /// O(triangles) worst case — we scan every triangle until one
    /// contains `target`. For the Phase 4 DEM (~30 K triangles) that's
    /// ~30 K point-in-triangle tests per call, each ~20 float ops.
    /// Well under a millisecond on M-series; fine for per-player-per-frame
    /// calls in single-player. Multiplayer scaling is a Phase 5 task
    /// (either a 2-D quadtree over triangles or a heightfield grid).
    ///
    /// ### Tolerance
    ///
    /// A small negative ε (`-1e-5`) on the barycentric bounds absorbs
    /// numerical jitter at triangle edges so a player walking *exactly*
    /// along an edge doesn't drop into a `nil` and float away.
    ///
    /// Exposed `public` for callers in other modules (RootView for
    /// spawn, `PlayerControlSystem` for ground-follow). `@MainActor`
    /// because `Entity.transformMatrix(relativeTo:)` and component
    /// access are main-isolated.
    @MainActor
    public static func sampleTerrainY(
        in root: Entity,
        atWorldXZ target: SIMD2<Float>
    ) -> Float? {
        // Small negative tolerance on the "inside triangle" test.
        // Positive guards against inclusive-edge jitter; keeping it
        // mildly negative means a point exactly on an edge counts
        // as inside exactly one of the two neighbouring triangles
        // — whichever wins the float race. That's fine for Y; both
        // sides yield the same surface value at an edge.
        let epsilon: Float = -1e-5

        var stack: [Entity] = [root]
        while let current = stack.popLast() {
            stack.append(contentsOf: current.children)
            guard
                let modelComponent = current.components[ModelComponent.self]
            else { continue }

            let toWorld = current.transformMatrix(relativeTo: nil)

            for mdl in modelComponent.mesh.contents.models {
                for part in mdl.parts {
                    if let y = sampleFromPart(
                        part: part,
                        toWorld: toWorld,
                        target: target,
                        epsilon: epsilon
                    ) {
                        return y
                    }
                }
            }
        }
        return nil
    }

    /// Inner loop of `sampleTerrainY`. Iterates every triangle in a
    /// single `MeshPart`, transforms its vertices to world, runs a
    /// 2-D point-in-triangle test on the XZ projection, and returns
    /// the interpolated Y on the first triangle that contains the
    /// target.
    @MainActor
    private static func sampleFromPart(
        part: MeshResource.Part,
        toWorld: simd_float4x4,
        target: SIMD2<Float>,
        epsilon: Float
    ) -> Float? {
        // `MeshBuffer` is an opaque `Collection` on iOS 18 without an
        // `Int` subscript in the public API, so materialise as Arrays
        // up front. Cost is one copy of ~15 K vertices + ~30 K indices
        // per sample call (a few hundred KB, O(ms) on M-series). If
        // that ever bites, cache the arrays alongside the terrain
        // entity — but for single-player Phase 4 it's fine.
        let positionsArr: [SIMD3<Float>] = Array(part.positions)
        let indicesArr: [UInt32]? = part.triangleIndices.map(Array.init)

        let triCount: Int
        if let indicesArr {
            triCount = indicesArr.count / 3
        } else {
            triCount = positionsArr.count / 3
        }

        for t in 0..<triCount {
            let ia: Int
            let ib: Int
            let ic: Int
            if let indicesArr {
                let base = t * 3
                ia = Int(indicesArr[base])
                ib = Int(indicesArr[base + 1])
                ic = Int(indicesArr[base + 2])
            } else {
                let base = t * 3
                ia = base
                ib = base + 1
                ic = base + 2
            }

            // Transform vertices to world space. We only need X/Z for
            // the in-triangle test and Y for the interpolation.
            let la = positionsArr[ia]
            let lb = positionsArr[ib]
            let lc = positionsArr[ic]
            let wa = toWorld * SIMD4<Float>(la.x, la.y, la.z, 1)
            let wb = toWorld * SIMD4<Float>(lb.x, lb.y, lb.z, 1)
            let wc = toWorld * SIMD4<Float>(lc.x, lc.y, lc.z, 1)

            // 2-D barycentric in the XZ plane. Broken into explicit
            // Float sub-expressions so the type-checker doesn't time
            // out on a single long arithmetic chain (Swift 6 known
            // issue with overload resolution on SIMD-scalar mix).
            //
            // Reference: Real-Time Collision Detection (Ericson), §3.4.
            let ax: Float = wa.x
            let az: Float = wa.z
            let ay: Float = wa.y
            let bx: Float = wb.x
            let bz: Float = wb.z
            let by: Float = wb.y
            let cx: Float = wc.x
            let cz: Float = wc.z
            let cy: Float = wc.y
            let px: Float = target.x
            let pz: Float = target.y

            let d1: Float = (bz - cz) * (ax - cx)
            let d2: Float = (cx - bx) * (az - cz)
            let denom: Float = d1 + d2
            guard abs(denom) > 1e-9 else { continue }  // degenerate tri

            let u1: Float = (bz - cz) * (px - cx)
            let u2: Float = (cx - bx) * (pz - cz)
            let u: Float = (u1 + u2) / denom

            let v1: Float = (cz - az) * (px - cx)
            let v2: Float = (ax - cx) * (pz - cz)
            let v: Float = (v1 + v2) / denom

            let w: Float = 1 - u - v

            if u >= epsilon && v >= epsilon && w >= epsilon {
                return u * ay + v * by + w * cy
            }
        }
        return nil
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
