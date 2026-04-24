// ToonMaterialFactory.swift
// SDGGameplay · Geology
//
// Phase 9 Part C — ADR-0004 Scheme A with defensive fallback to Scheme C.
//
// The factory is the *only* public entry point geology / UI code should
// reach for when they want "a Toon-ified material for a given colour".
// It hides the specific rendering strategy so the rest of the game
// doesn't care which of the three approaches (ShaderGraphMaterial,
// CustomMaterial, PhysicallyBasedMaterial) ends up being used.
//
// ## Scheme A (primary) — `ShaderGraphMaterial` + hand-written `.usda`
//
// Loads `Resources/Shaders/StepRampToon.usda` and sets a `baseColor`
// parameter on the resulting `ShaderGraphMaterial`. That graph computes
// a three-band NdotL step ramp for a real cel-shaded look (see the
// `.usda` file for the shape).
//
// ## Scheme C (fallback) — tuned `PhysicallyBasedMaterial`
//
// Hand-written MaterialX is brittle — a single wrong node ID raises
// `ShaderGraphMaterial.LoadError.invalidTypeFound` at load time. When
// that happens, the factory logs through `os.Logger` AND `print` (so
// the failure is never silent) and falls back to the Phase 1 PBR+hull
// pseudo-toon. Gameplay must not die because of a bad shader.
//
// See ADR-0004 (and the Phase 9 Part C addendum) for the full rationale.
//
// ## What "Toon" means here
//
// * If the ShaderGraph loads: three-band NdotL step ramp, unlit output
//   (no specular), base-colour tint driven by the `baseColor` parameter.
// * If it doesn't load (fallback): flat-ish PBR with `roughness=1`,
//   `metallic=0`, and an emissive floor so shadows don't read deep
//   black. Plus the back-face-hull outline (unchanged from Phase 1).
//
// Everything here is `@MainActor` because RealityKit material / entity
// initialisers on iOS 18 are MainActor-isolated.

import Foundation
import os.log
import RealityKit

#if canImport(UIKit)
import UIKit
/// Platform colour type used by RealityKit's `PhysicallyBasedMaterial`
/// on UIKit targets (iOS / Mac Catalyst). Aliased so the factory
/// compiles on both iOS and macOS the same way `GeologySceneBuilder`
/// does it. Declared `internal` (not `private`) so test-visible
/// helpers can return it without tripping access-control warnings.
/// Prefixed `Toon` to avoid colliding with the sibling
/// `PlatformColor` alias that `GeologySceneBuilder` keeps `private` in
/// the same module.
internal typealias ToonPlatformColor = UIColor
#elseif canImport(AppKit)
import AppKit
/// See the UIKit branch above — AppKit gets `NSColor`, which is what
/// the macOS `RealityKit` module expects for the same initialiser.
internal typealias ToonPlatformColor = NSColor
#endif

// MARK: - Public factory

/// Produces Toon-shaded materials (and optional outline entities) for
/// geology layers, plus the "hard cel" variant used by the PLATEAU /
/// terrain loaders.
///
/// All methods are `@MainActor` because `PhysicallyBasedMaterial`,
/// `ShaderGraphMaterial`, and `ModelEntity` initialisers touch RealityKit
/// state. Keeping the whole factory on MainActor avoids needing the
/// caller to sprinkle `await MainActor.run {}` at every call site.
///
/// The factory is an `enum` with static methods — the same shape as
/// `GeologySceneBuilder` — because it has no state worth owning. A
/// `struct` with stored dependencies would imply a lifetime this type
/// does not have.
public enum ToonMaterialFactory {

    // MARK: Tunables

    /// How far the outline hull is scaled beyond the source mesh.
    /// 1.02 = 2 % larger on every axis. Tight enough that the outline
    /// reads as a pen stroke rather than a halo. Exposed as `internal`
    /// so tests can pin its value without parsing magic numbers.
    internal static let outlineScale: Float = 1.02

    /// The smallest `strength` we accept before clamping to 0. We clamp
    /// to [0, 1] inside `makeLayerMaterial(...)`; this constant documents
    /// the intent.
    internal static let minStrength: Float = 0
    internal static let maxStrength: Float = 1

    /// Basename of the `.usda` shader asset shipped under
    /// `Resources/Shaders/`. Exposed `internal` so tests can reuse the
    /// exact string rather than re-typing it.
    internal static let stepRampShaderName: String = "StepRampToon"

    /// MaterialX prim path inside `StepRampToon.usda`. Passed as the
    /// `named:` argument to `ShaderGraphMaterial(named:from:in:)`.
    internal static let stepRampMaterialPath: String = "/Root/StepRampToon"

    // MARK: - Shader cache
    //
    // `ShaderGraphMaterial(named:from:in:)` is async, but the factory's
    // public API is sync because its call sites (`StackedCylinderMeshBuilder`,
    // `PlateauEnvironmentLoader`, `TerrainLoader`) run in sync mesh
    // builders. The bridge between the two is a MainActor-isolated cache:
    //   1. App bootstrap (future work) calls `preloadStepRampShader()`
    //      once. That awaits the async init and fills `cachedShaderGraph`.
    //   2. `attemptStepRampMaterial` reads the cache synchronously. If
    //      empty, it returns `nil` so the caller falls through to the
    //      PBR path.
    //
    // This means the very first frame (before the preload completes)
    // will render every material via Scheme C. That is deliberate: we
    // prefer a consistent "PBR look on all surfaces" for one frame over
    // a mixed-scheme render that would flicker as tiles arrive.

    /// Cached ShaderGraphMaterial template. `nil` means "not yet tried
    /// / not finished loading"; `.some(.success)` means loaded once and
    /// ready to clone; `.some(.failure)` means the load finished with an
    /// error and we should skip straight to the PBR path on subsequent
    /// calls.
    ///
    /// ### Why `nonisolated(unsafe)`
    ///
    /// Every read/write happens from MainActor (preload and factory
    /// accessors are both `@MainActor`). `ShaderGraphMaterial` is not a
    /// `Sendable` type on the current SDK, so marking the static as
    /// `nonisolated(unsafe)` is the explicit escape valve Swift 6
    /// requires. It is a resource cache, not a Store — AGENTS.md §1.2
    /// singleton ban does not apply (no behaviour, no cross-layer API).
    nonisolated(unsafe) internal static var cachedShaderGraph: Result<ShaderGraphMaterial, Error>?

    /// Reset the cache. Tests call this between runs so a failure in
    /// one test doesn't poison the next. Not exposed publicly — test
    /// access is via `@testable import SDGGameplay`.
    @MainActor
    internal static func resetShaderGraphCacheForTesting() {
        cachedShaderGraph = nil
    }

    /// Preload the step-ramp ShaderGraph. Callers should `await` this
    /// once at app bootstrap — future work in `RootView` or
    /// `SendaiGLabApp`. Safe to call more than once; subsequent calls
    /// return the cached result without re-loading.
    ///
    /// - Parameter bundle: Bundle containing `StepRampToon.usda`.
    ///   Defaults to `.main`; tests pass `Bundle.module`.
    /// - Returns: `true` if Scheme A is active, `false` if the factory
    ///   will be serving Scheme C fallbacks.
    @MainActor
    @discardableResult
    public static func preloadStepRampShader(
        bundle: Bundle = .main
    ) async -> Bool {
        if case .success = cachedShaderGraph {
            return true
        }
        if case .failure = cachedShaderGraph {
            return false
        }

        do {
            let material = try await ShaderGraphMaterial(
                named: stepRampMaterialPath,
                from: stepRampShaderName,
                in: bundle
            )
            cachedShaderGraph = .success(material)
            log.info("StepRampToon preloaded; Scheme A active.")
            #if DEBUG
            print("[SDG-Lab][toon-shader] StepRampToon preloaded; Scheme A active.")
            #endif
            return true
        } catch {
            cachedShaderGraph = .failure(error)
            // Loud failure — the whole point of this project's
            // "no silent catch" rule (see AGENTS.md and CLAUDE.md
            // pitfall #9).
            log.error(
                "StepRampToon preload failed — falling back to PBR Scheme C: \(String(describing: error), privacy: .public)"
            )
            #if DEBUG
            print(
                "[SDG-Lab][toon-shader] StepRampToon preload failed (\(error)); using PBR Scheme C."
            )
            #endif
            return false
        }
    }

    /// Logger used for shader-load failures. `subsystem` matches the
    /// project convention used by `AudioService` so failures are easy
    /// to grep in Console.app.
    internal static let log = Logger(
        subsystem: "jp.tohoku-gakuin.fshera.sendai-glab",
        category: "toon-shader"
    )

    // MARK: - Layer material

    /// Build a Toon-shaded material for a geology layer.
    ///
    /// - Parameters:
    ///   - baseColor: Linear-ish 0…1 RGB tint (the same representation
    ///     `GeologyLayerComponent.colorRGB` uses). Out-of-range values
    ///     are clamped before handing them to `ToonPlatformColor` to avoid
    ///     the silent HSB wrap-around `UIColor`/`NSColor` do.
    ///   - strength: 0 → a vanilla-ish PBR look. 1 → maximum Toon feel
    ///     (more emissive floor, no specular). Intermediate values
    ///     interpolate. Clamped to [0, 1]. Only consumed by the PBR
    ///     fallback path; the ShaderGraph path ignores `strength` because
    ///     the band values are baked into the `.usda`.
    /// - Returns: An opaque `Material`. Concrete type depends on whether
    ///   the step-ramp ShaderGraph loaded:
    ///     * Success → `ShaderGraphMaterial` with `baseColor` parameter
    ///       set.
    ///     * Failure → `PhysicallyBasedMaterial` tuned as in Phase 1
    ///       Scheme C. Callers must not type-assume.
    ///
    /// - Important: MainActor-isolated because `PhysicallyBasedMaterial`
    ///   and `ShaderGraphMaterial` setters are on MainActor in
    ///   iOS 18 / macOS 15.
    @MainActor
    public static func makeLayerMaterial(
        baseColor: SIMD3<Float>,
        strength: Float = 0.8
    ) -> RealityKit.Material {
        if let stepRamp = attemptStepRampMaterial(baseColor: baseColor) {
            return stepRamp
        }
        return makeLayerMaterialPBR(baseColor: baseColor, strength: strength)
    }

    /// Scheme C (fallback) for `makeLayerMaterial`. Kept as a named
    /// method so tests can exercise the fallback shape deterministically
    /// without having to force the ShaderGraph to fail.
    @MainActor
    internal static func makeLayerMaterialPBR(
        baseColor: SIMD3<Float>,
        strength: Float = 0.8
    ) -> RealityKit.Material {
        let s = max(minStrength, min(maxStrength, strength))

        var material = PhysicallyBasedMaterial()

        // 1. Tint: the layer's core identity. Clamp explicitly; see
        //    `GeologySceneBuilder.platformColor(from:)` for the same
        //    pattern and rationale.
        let tint = clampedToonPlatformColor(from: baseColor)
        material.baseColor = .init(tint: tint, texture: nil)

        // 2. Roughness = 1 gives a fully matte response. Paired with
        //    metallic = 0, the surface loses all specular highlights
        //    and reads as "flat paint" — the minimum cel-shading
        //    appearance we can get out of PBR without a custom shader.
        material.roughness = .init(floatLiteral: 1.0)
        material.metallic = .init(floatLiteral: 0.0)

        // 3. Emissive floor: the "lit band" of a 2-step toon ramp would
        //    read roughly as (base × 1.0), the "shadow band" as
        //    (base × 0.5). Setting emissive to `strength × base × 0.35`
        //    raises the floor so direct lighting stops mattering as
        //    much — the entity looks closer to self-lit paint, which
        //    is the dominant aesthetic in BotW / Genshin-style toon.
        //    0.35 × 0.8 (default strength) ≈ 28 % emissive tint; high
        //    enough to mute the PBR shading without washing out reads.
        let emissive = emissiveTint(base: baseColor, strength: s)
        material.emissiveColor = .init(color: emissive, texture: nil)
        material.emissiveIntensity = 1.0

        // 4. Faceculling stays default (.back) — we're not an outline.
        //    Blending stays `.opaque` — layers are always solid rock.

        return material
    }

    // MARK: - Harder cel variant (Phase 3 / still used)

    /// A *harder* cel look. Phase 9 Part C routes this through the
    /// same ShaderGraph when available (the graph itself *is* a hard
    /// cel) and falls back to the tuned-PBR hard-cel otherwise.
    ///
    /// Used by the PLATEAU building and terrain loaders — the whole
    /// point is a consistent "flat" look regardless of which surface
    /// receives it, so no `strength` parameter.
    @MainActor
    public static func makeHardCelMaterial(
        baseColor: SIMD3<Float>
    ) -> RealityKit.Material {
        if let stepRamp = attemptStepRampMaterial(baseColor: baseColor) {
            return stepRamp
        }
        return makeHardCelMaterialPBR(baseColor: baseColor)
    }

    /// Scheme C (fallback) for `makeHardCelMaterial`. See the original
    /// Phase 3 implementation comments — same code, just renamed so
    /// the name documents which branch of the fallback chain it is.
    @MainActor
    internal static func makeHardCelMaterialPBR(
        baseColor: SIMD3<Float>
    ) -> RealityKit.Material {
        var material = PhysicallyBasedMaterial()

        // Tint: the surface identity. Same clamp as the soft variant.
        let tint = clampedToonPlatformColor(from: baseColor)
        material.baseColor = .init(tint: tint, texture: nil)

        // Fully matte response, no metal. Same as the soft variant —
        // the "harder" feel comes from the emissive floor below.
        material.roughness = .init(floatLiteral: 1.0)
        material.metallic = .init(floatLiteral: 0.0)

        // Emissive floor at 60 % of base colour (vs. 35 % in the soft
        // variant). This shallows the shading gradient so the surface
        // reads as nearly self-lit — the closest PBR can get to the
        // "lit band" in a cel-shaded ramp without custom shaders.
        let emissive = emissiveTintHardCel(base: baseColor)
        material.emissiveColor = .init(color: emissive, texture: nil)
        material.emissiveIntensity = 1.0

        // Remove any residual sheen: PBR's default clearcoat can leave
        // a subtle highlight band that breaks the flat look.
        material.clearcoat = .init(floatLiteral: 0.0)
        material.clearcoatRoughness = .init(floatLiteral: 1.0)

        return material
    }

    /// Hard-cel emissive tint calculation. Separate from
    /// `emissiveTint` so the two variants can tune independently
    /// without parameter sprawl.
    internal static func emissiveTintHardCel(
        base: SIMD3<Float>
    ) -> ToonPlatformColor {
        // 60 % of base colour, clamped. Empirically tuned against the
        // spawn-tile preview on iPad — any higher and the emissive
        // starts washing out the base identity.
        let factor: Float = 0.6
        let rgb = SIMD3<Float>(
            max(0, min(1, base.x * factor)),
            max(0, min(1, base.y * factor)),
            max(0, min(1, base.z * factor))
        )
        return platformColor(from: rgb)
    }

    // MARK: - Scheme A (primary): ShaderGraphMaterial

    /// Try to build a `ShaderGraphMaterial` clone with the given base
    /// colour. Returns `nil` on ANY failure (including "preload hasn't
    /// finished yet") — caller is expected to fall through to the PBR
    /// path. Every failure branch that stems from an actual error logs
    /// via both `os.Logger` and `print`; the common "cache empty"
    /// branch stays quiet because it's not a failure, just "too early".
    ///
    /// This is deliberately `internal` so tests can exercise it in
    /// isolation without going through `makeLayerMaterial`, and so the
    /// "no accidental silent nil" invariant stays enforceable.
    ///
    /// - Parameter baseColor: Linear 0..1 RGB. Clamped before passing
    ///   to the MaterialX parameter.
    /// - Returns: A freshly-parameterised `ShaderGraphMaterial` or `nil`
    ///   if the shader has not been preloaded, failed to preload, or
    ///   could not be parameterised.
    @MainActor
    internal static func attemptStepRampMaterial(
        baseColor: SIMD3<Float>
    ) -> RealityKit.Material? {
        guard let cached = cachedShaderGraph else {
            // Preload hasn't run yet (or hasn't completed). Silent nil
            // is correct here — this is not a failure, just a timing
            // state. Callers fall through to PBR.
            return nil
        }

        let template: ShaderGraphMaterial
        switch cached {
        case .success(let material):
            template = material
        case .failure:
            // Already logged at preload time. Stay quiet on subsequent
            // attempts to avoid log spam.
            return nil
        }

        // Mutate a copy so the cached template stays clean for the next
        // caller.
        var material = template
        do {
            let clamped = SIMD3<Float>(
                max(0, min(1, baseColor.x)),
                max(0, min(1, baseColor.y)),
                max(0, min(1, baseColor.z))
            )
            try material.setParameter(
                name: "baseColor",
                value: .color(colorForShaderParameter(clamped))
            )
        } catch {
            // A parameter-setting failure is surprising — it means the
            // `.usda` loaded but its parameter schema doesn't match what
            // we expect. Log loudly and fall through to PBR so the
            // game keeps rendering something.
            log.error(
                "StepRampToon.setParameter(baseColor) failed: \(String(describing: error), privacy: .public)"
            )
            #if DEBUG
            print(
                "[SDG-Lab][toon-shader] setParameter(baseColor) failed: \(error); falling back to PBR scheme C"
            )
            #endif
            return nil
        }

        return material
    }

    /// Platform-color → CGColor bridge for the `baseColor` ShaderGraph
    /// parameter. `ShaderGraphMaterial.setParameter(name:value:)` takes
    /// `MaterialParameters.Value.color(CGColor)` on the current SDK.
    private static func colorForShaderParameter(
        _ rgb: SIMD3<Float>
    ) -> CGColor {
        let components: [CGFloat] = [
            CGFloat(rgb.x), CGFloat(rgb.y), CGFloat(rgb.z), 1.0
        ]
        let cs = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        return CGColor(colorSpace: cs, components: components) ?? CGColor(
            gray: 0.5, alpha: 1.0
        )
    }

    // MARK: - Outline entity

    /// Build a back-face-hull outline entity for an existing
    /// `ModelEntity`. The caller attaches it as a child (or sibling)
    /// of the source; we never touch the scene graph.
    ///
    /// Returns `nil` when the source lacks a `ModelComponent` (e.g. a
    /// bare `Entity`) — there's nothing to outline.
    ///
    /// The outline is:
    ///   * same mesh as the source,
    ///   * scaled uniformly by `outlineScale` (1.02 × on every axis),
    ///   * materials replaced with a single opaque black
    ///     `PhysicallyBasedMaterial` whose `faceCulling` is `.front`
    ///     (so only back faces render, producing the "hull" silhouette),
    ///   * tagged `name = "<source.name>_Outline"` for debuggability.
    ///
    /// - Important: MainActor-isolated because `ModelEntity.clone()`
    ///   and the `components[ModelComponent.self]` setter are MainActor.
    @MainActor
    public static func makeOutlineEntity(
        for entity: ModelEntity
    ) -> ModelEntity? {
        guard let sourceModel = entity.components[ModelComponent.self] else {
            return nil
        }

        let outline = ModelEntity()
        outline.name = entity.name.isEmpty
            ? "Outline"
            : "\(entity.name)_Outline"

        // Re-use the same MeshResource handle. `MeshResource` is
        // value-ish / reference-backed; it is safe — and memory-friendly
        // — to share between the source and its hull.
        outline.components.set(
            ModelComponent(
                mesh: sourceModel.mesh,
                materials: [makeOutlineMaterial()]
            )
        )

        // Uniform scale pushes the hull just outside the source
        // silhouette. Using `Transform` rather than mutating scale
        // directly makes the intent explicit.
        outline.transform = Transform(
            scale: SIMD3<Float>(repeating: outlineScale),
            rotation: simd_quatf(ix: 0, iy: 0, iz: 0, r: 1),
            translation: .zero
        )

        return outline
    }

    // MARK: - Internal helpers (exposed for tests)

    /// Build the pure-black unlit-ish material used by the outline
    /// hull. Exposed `internal` so tests can assert on
    /// `faceCulling == .front` without having to instantiate
    /// `makeOutlineEntity(for:)`.
    @MainActor
    internal static func makeOutlineMaterial() -> PhysicallyBasedMaterial {
        var m = PhysicallyBasedMaterial()
        // Black tint + 1.0 roughness + no metallic = matte black. The
        // outline should not pick up scene lighting; setting emissive
        // to black *and* keeping roughness/metallic neutral keeps PBR
        // evaluation cheap while reading as "ink".
        m.baseColor = .init(tint: .black, texture: nil)
        m.emissiveColor = .init(color: .black, texture: nil)
        m.roughness = .init(floatLiteral: 1.0)
        m.metallic = .init(floatLiteral: 0.0)
        // Cull *front* faces → only back faces render → we see the
        // inside of the scaled-up hull from the outside. That silhouette
        // is the outline.
        m.faceCulling = .front
        return m
    }

    /// Compute the emissive tint for a layer, given its base colour
    /// and Toon strength. Pulled out for testability — bugs here show
    /// as layers looking too dark / too bright, which is the number
    /// one way a POC "just looks wrong" to playtesters.
    internal static func emissiveTint(
        base: SIMD3<Float>,
        strength: Float
    ) -> ToonPlatformColor {
        // Factor chosen empirically (35 %); see doc comment on
        // `makeLayerMaterial`.
        let factor: Float = 0.35 * max(minStrength, min(maxStrength, strength))
        let rgb = SIMD3<Float>(
            max(0, min(1, base.x * factor)),
            max(0, min(1, base.y * factor)),
            max(0, min(1, base.z * factor))
        )
        return platformColor(from: rgb)
    }

    // MARK: - Colour bridge

    /// Clamp + convert a 0…1 SIMD3 into the platform colour type.
    /// Matches the behaviour of `GeologySceneBuilder.platformColor(from:)`
    /// so the two factories round-trip identically.
    private static func clampedToonPlatformColor(
        from rgb: SIMD3<Float>
    ) -> ToonPlatformColor {
        let r = CGFloat(max(0, min(1, rgb.x)))
        let g = CGFloat(max(0, min(1, rgb.y)))
        let b = CGFloat(max(0, min(1, rgb.z)))
        return ToonPlatformColor(red: r, green: g, blue: b, alpha: 1.0)
    }

    /// Unclamped form used by helpers that have already clamped.
    private static func platformColor(
        from rgb: SIMD3<Float>
    ) -> ToonPlatformColor {
        ToonPlatformColor(
            red: CGFloat(rgb.x),
            green: CGFloat(rgb.y),
            blue: CGFloat(rgb.z),
            alpha: 1.0
        )
    }
}
