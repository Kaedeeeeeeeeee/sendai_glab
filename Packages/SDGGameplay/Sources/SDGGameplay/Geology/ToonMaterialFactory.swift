// ToonMaterialFactory.swift
// SDGGameplay · Geology
//
// Phase 9 Part C-v2 — ADR-0004 Scheme A (真 step-ramp ShaderGraph) with an
// aggressively tuned Scheme C fallback. The fallback is no longer the
// "Phase 1 Scheme C" values — it is pushed hard toward cartoon so that
// when the `.usda` is still a pass-through graph (or fails to load), the
// user *still* sees an unmistakably flat, saturated, cel look compared to
// mainline PBR.
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
// parameter on the resulting `ShaderGraphMaterial`. C-v2 authors a real
// 3-band NdotL step ramp in the `.usda` (see the file's header comment
// for the graph shape). If RealityKit's MaterialX parser refuses any
// of the nodes the factory falls through to Scheme C rather than
// bricking geology rendering.
//
// ## Scheme C-v2 (fallback) — heavily tuned `PhysicallyBasedMaterial`
//
// C-v1 tuning was "flat-ish PBR". C-v2 tuning is "nearly unlit cel":
//   * Emissive floor 0.9 × base (was 0.6 for hard-cel, 0.35 for soft).
//   * Saturation boost 1.15× on the base colour before feeding tint.
//   * Clearcoat = 0 (hard-kill gloss) — already was for hard-cel,
//     now also enforced for the soft layer variant.
//   * Outline hull grown 1.02 → 1.05 for a visibly thicker silhouette.
//   * Outline colour tinted by the *complement* of the base colour so
//     the ink reads intentional rather than "pure black halo":
//       warm building → dark blue outline
//       cool grey terrain → dark brown outline
//
// See ADR-0004 Phase 9 Part C-v2 section for the rationale on each knob.
//
// ## What "Toon" means here
//
// * If the ShaderGraph loads: 3-band NdotL step ramp with an unlit
//   output path (no specular), base-colour tint driven by the
//   `baseColor` parameter.
// * If it doesn't load (fallback): nearly-self-lit PBR with
//   `roughness=1`, `metallic=0`, `clearcoat=0`, saturation-boosted
//   `baseColor`, and an aggressive emissive floor. Plus a 1.05× hull
//   outline tinted by the base colour's complement.
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
    /// C-v1 shipped 1.02 (2 % larger). C-v2 ships **1.05** (5 % larger)
    /// so the silhouette reads unambiguously as a cartoon ink stroke at
    /// normal viewing distance (3 – 30 m for PLATEAU buildings). Pinned
    /// by `testOutlineHullScaleIs1_05` so the value survives refactors.
    ///
    /// ### Why 1.05 and not larger
    ///
    /// 1.10+ on thin meshes (road slabs, DEM triangles with near-zero
    /// thickness) z-fights itself; the back faces poke through the
    /// front. 1.05 is the largest value that was empirically safe in
    /// the C-v1 back-face-hull approach across the PLATEAU tile set.
    /// Real rejection of thin-mesh z-fighting would need screen-space
    /// edge detection — deferred to Phase 10 (see ADR-0004 Phase 9).
    internal static let outlineScale: Float = 1.05

    /// Saturation boost applied to `baseColor` before the PBR tint is
    /// computed, in the Scheme C fallback only. 1.0 = unchanged, 1.15
    /// = 15 % more saturated (our C-v2 value). Clamping back to [0, 1]
    /// happens after the boost; fully-saturated input colours end up
    /// unchanged, which is intentional.
    internal static let saturationBoost: Float = 1.15

    /// Emissive factor for the harder (PLATEAU / terrain) cel fallback
    /// in C-v2. 0.9 means "90 % self-lit"; the PBR shading contribution
    /// becomes a thin 10 % modulation. Pinned by
    /// `testHardCelEmissiveFactorIs0_9`.
    internal static let hardCelEmissiveFactor: Float = 0.9

    /// Emissive factor for the softer (geology layer) cel fallback in
    /// C-v2. Raised from C-v1's 0.35 to 0.5 so the layer reads closer
    /// to a cel band without the pitch-black shadow side. Still lower
    /// than the hard-cel value so outcrop core layers remain visually
    /// distinct from buildings around them.
    internal static let softCelEmissiveFactor: Float = 0.5

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
    ///   will be serving Scheme C-v2 fallbacks.
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
                "StepRampToon preload failed — falling back to PBR Scheme C-v2: \(String(describing: error), privacy: .public)"
            )
            #if DEBUG
            print(
                "[SDG-Lab][toon-shader] StepRampToon preload failed (\(error)); using PBR Scheme C-v2."
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
    ///     * Failure → `PhysicallyBasedMaterial` tuned as in Scheme C-v2.
    ///       Callers must not type-assume.
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

    /// Scheme C-v2 (fallback) for `makeLayerMaterial`. Kept as a named
    /// method so tests can exercise the fallback shape deterministically
    /// without having to force the ShaderGraph to fail.
    @MainActor
    internal static func makeLayerMaterialPBR(
        baseColor: SIMD3<Float>,
        strength: Float = 0.8
    ) -> RealityKit.Material {
        let s = max(minStrength, min(maxStrength, strength))

        var material = PhysicallyBasedMaterial()

        // 1. Tint: the layer's core identity, but C-v2 pushes saturation
        //    up 15 % so it reads as painted rather than photographed.
        let boosted = saturationBoosted(baseColor)
        let tint = clampedToonPlatformColor(from: boosted)
        material.baseColor = .init(tint: tint, texture: nil)

        // 2. Roughness = 1 gives a fully matte response. Paired with
        //    metallic = 0, the surface loses all specular highlights
        //    and reads as "flat paint". C-v2 also hard-kills clearcoat
        //    for the soft variant (C-v1 only did it for hard-cel).
        material.roughness = .init(floatLiteral: 1.0)
        material.metallic = .init(floatLiteral: 0.0)
        material.clearcoat = .init(floatLiteral: 0.0)
        material.clearcoatRoughness = .init(floatLiteral: 1.0)

        // 3. Emissive floor: C-v2 raises the soft variant's floor from
        //    0.35 → 0.5 × base so shadow bands aren't muddy. Still
        //    lower than the hard-cel 0.9 so outcrop layers remain
        //    distinguishable from buildings.
        let emissive = emissiveTint(base: baseColor, strength: s)
        material.emissiveColor = .init(color: emissive, texture: nil)
        material.emissiveIntensity = 1.0

        // 4. Faceculling stays default (.back) — we're not an outline.
        //    Blending stays `.opaque` — layers are always solid rock.

        return material
    }

    // MARK: - Harder cel variant

    /// A *harder* cel look. Phase 9 Part C routes this through the
    /// same ShaderGraph when available (the graph itself *is* a hard
    /// cel) and falls back to the aggressively-tuned PBR hard-cel
    /// otherwise.
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

    // MARK: - Phase 11 Part D: textured PBR → painted-cel mutator

    /// Emissive tint applied when mutating an existing textured
    /// `PhysicallyBasedMaterial` into the "painted-realistic /
    /// Borderlands-ish" look. Kept as a white at ~25 % alpha so the
    /// emissive *augments* the baked facade JPG rather than recolouring
    /// it — the whole point of the mutator is to leave colour identity
    /// to the texture and only push overall brightness. Pinned by
    /// `testMutateIntoTexturedCelBoostsEmissive`.
    internal static let texturedCelEmissiveWhiteAlpha: CGFloat = 0.25

    /// Mutate an existing `PhysicallyBasedMaterial` (typically one that
    /// arrived with a real `baseColor.texture` from USDZ load) into the
    /// Phase 11 Part D painted-cel look **without replacing the
    /// texture**. Returned material:
    ///
    /// * `baseColor` untouched — texture *and* tint preserved. This is
    ///   the entire point of the function: Phase 11 Part C's textured
    ///   PLATEAU tiles must keep their facade JPGs.
    /// * `roughness = 1`, `metallic = 0`, `specular = 0` — matte
    ///   response, no PBR highlight. Matches the hard-cel fallback.
    /// * `clearcoat = 0`, `clearcoatRoughness = 1` — kill any residual
    ///   sheen the authoring pass may have left on.
    /// * `emissiveColor = white @ 25% alpha` + `emissiveIntensity = 1`
    ///   — a subtle self-lit boost that brightens the texture's
    ///   darker shading side without washing out its colour identity.
    /// * `blending = .opaque` — PLATEAU facades are never meant to be
    ///   translucent; lock it explicitly so a stray alpha channel on a
    ///   facade JPG doesn't open a translucent pass.
    ///
    /// Does **not** touch the material's `normal`, `roughness.texture`,
    /// or any other sampler — those stay as the USDZ authored them.
    /// The outline shell (`makeOutlineEntity`) is still attached by
    /// callers, which is what actually delivers the "cartoon
    /// silhouette" half of the Borderlands-ish look.
    ///
    /// - Parameter material: The PBR material to mutate. Caller assigns
    ///   the return value back into the `ModelComponent`'s material
    ///   slot — `PhysicallyBasedMaterial` is a value-semantic struct so
    ///   the mutation is visible only after re-assignment.
    /// - Returns: The mutated material. `TextureResource` is
    ///   reference-backed inside `MaterialParameters.Texture`, so the
    ///   returned struct shares the original texture identity —
    ///   verified by `testMutateIntoTexturedCelPreservesBaseColorTexture`.
    ///
    /// - Important: MainActor-isolated like the rest of the factory
    ///   because `PhysicallyBasedMaterial` property setters are
    ///   MainActor in iOS 18.
    @MainActor
    public static func mutateIntoTexturedCel(
        _ material: PhysicallyBasedMaterial
    ) -> PhysicallyBasedMaterial {
        var mutated = material

        // 1. `baseColor` is intentionally untouched. `BaseColor` is a
        //    value-semantic struct whose `texture` field wraps a
        //    reference-typed `TextureResource`, so copying the struct
        //    keeps the texture bytes shared — no GPU re-upload, no
        //    sampler re-creation.

        // 2. Painted look: fully matte, no metal, no specular.
        mutated.roughness = .init(floatLiteral: 1.0)
        mutated.metallic = .init(floatLiteral: 0.0)
        mutated.specular = .init(floatLiteral: 0.0)

        // 3. Kill clearcoat in case the authoring pass left it on.
        //    Clearcoat on a matte facade reads as a glossy band that
        //    breaks the painted feel.
        mutated.clearcoat = .init(floatLiteral: 0.0)
        mutated.clearcoatRoughness = .init(floatLiteral: 1.0)

        // 4. Emissive boost. White at ~25 % alpha → lifts the shaded
        //    side of the texture without recolouring it. `UIColor`
        //    (iOS) / `NSColor` (macOS) both accept the same
        //    `(white:alpha:)` initialiser; aliased via
        //    `ToonPlatformColor` so this compiles on both platforms.
        let boost = ToonPlatformColor(
            white: 1.0,
            alpha: texturedCelEmissiveWhiteAlpha
        )
        mutated.emissiveColor = .init(color: boost, texture: nil)
        mutated.emissiveIntensity = 1.0

        // 5. Opaque blending — see header comment.
        mutated.blending = .opaque

        return mutated
    }

    /// Scheme C-v2 (fallback) for `makeHardCelMaterial`. Pushes PBR
    /// emissive to 0.9 × base — the closest PBR can get to a cel
    /// look without a custom shader.
    @MainActor
    internal static func makeHardCelMaterialPBR(
        baseColor: SIMD3<Float>
    ) -> RealityKit.Material {
        var material = PhysicallyBasedMaterial()

        // Tint: saturation-boosted like the soft variant, then clamped.
        let boosted = saturationBoosted(baseColor)
        let tint = clampedToonPlatformColor(from: boosted)
        material.baseColor = .init(tint: tint, texture: nil)

        // Fully matte response, no metal. The "harder" feel comes from
        // the emissive floor below.
        material.roughness = .init(floatLiteral: 1.0)
        material.metallic = .init(floatLiteral: 0.0)

        // Emissive floor at 90 % of base colour (C-v1 was 60 %). The
        // surface is now almost self-lit; only ~10 % of the apparent
        // tone comes from scene lighting. Closest approximation of the
        // "fully-lit band" in a cel ramp without a real step function.
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
        // 90 % of base colour, clamped. C-v2 tuning — empirically close
        // to "self-lit" without fully washing out the PBR shadow band.
        let factor: Float = hardCelEmissiveFactor
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
                "[SDG-Lab][toon-shader] setParameter(baseColor) failed: \(error); falling back to PBR scheme C-v2"
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
    ///   * scaled uniformly by `outlineScale` (1.05 × on every axis
    ///     in C-v2; was 1.02 in C-v1),
    ///   * materials replaced with a single opaque
    ///     `PhysicallyBasedMaterial` whose tint is the *complement* of
    ///     the source's base colour (when known) and whose `faceCulling`
    ///     is `.front` (so only back faces render, producing the "hull"
    ///     silhouette),
    ///   * tagged `name = "<source.name>_Outline"` for debuggability.
    ///
    /// - Important: MainActor-isolated because `ModelEntity.clone()`
    ///   and the `components[ModelComponent.self]` setter are MainActor.
    ///
    /// - Parameter entity: Source to wrap. Must carry a ModelComponent.
    /// - Parameter baseColor: Optional tint hint. When provided the
    ///   outline ink colour is derived from this colour's darkened
    ///   complement. When `nil` (default / legacy callers), the outline
    ///   falls back to the C-v1 pure-black ink.
    @MainActor
    public static func makeOutlineEntity(
        for entity: ModelEntity,
        baseColor: SIMD3<Float>? = nil
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
                materials: [makeOutlineMaterial(baseColor: baseColor)]
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

    /// Build the unlit-ish material used by the outline hull. Exposed
    /// `internal` so tests can assert on `faceCulling == .front`
    /// without having to instantiate `makeOutlineEntity(for:)`.
    ///
    /// The tint is:
    ///   * pure black when `baseColor == nil` (legacy C-v1 behaviour,
    ///     kept so tests and callers that don't know the base colour
    ///     still get a usable ink), or
    ///   * the **darkened complement** of `baseColor` otherwise — so a
    ///     warm building (base ≈ beige) gets a dark-blue outline and a
    ///     cool grey terrain gets a dark-brown outline. Darkened to ~25 %
    ///     of the complement so it still reads as "ink" not "colour
    ///     border".
    @MainActor
    internal static func makeOutlineMaterial(
        baseColor: SIMD3<Float>? = nil
    ) -> PhysicallyBasedMaterial {
        var m = PhysicallyBasedMaterial()
        let ink = outlineInkColor(for: baseColor)
        m.baseColor = .init(tint: ink, texture: nil)
        m.emissiveColor = .init(color: ink, texture: nil)
        // Emissive at ~30 % of the ink so the outline stays readable
        // even when scene lighting dies (night-time / interior). Full
        // self-emissive would destroy the "ink stroke" metaphor.
        m.emissiveIntensity = 0.3
        m.roughness = .init(floatLiteral: 1.0)
        m.metallic = .init(floatLiteral: 0.0)
        // Cull *front* faces → only back faces render → we see the
        // inside of the scaled-up hull from the outside. That silhouette
        // is the outline.
        m.faceCulling = .front
        return m
    }

    /// Derive the outline ink colour. Pure black for nil input
    /// (legacy), darkened-complement for a real base colour. Exposed
    /// internal so tests can pin the exact formula.
    internal static func outlineInkColor(
        for baseColor: SIMD3<Float>?
    ) -> ToonPlatformColor {
        guard let base = baseColor else {
            return ToonPlatformColor.black
        }
        let complement = SIMD3<Float>(
            1.0 - base.x, 1.0 - base.y, 1.0 - base.z
        )
        // Darken to 25 % so it reads as ink, not as a coloured border.
        // Empirically: anything brighter than ~40 % looks like a halo
        // on PLATEAU buildings in the M5 simulator.
        let factor: Float = 0.25
        let rgb = SIMD3<Float>(
            max(0, min(1, complement.x * factor)),
            max(0, min(1, complement.y * factor)),
            max(0, min(1, complement.z * factor))
        )
        return platformColor(from: rgb)
    }

    /// Compute the emissive tint for a layer, given its base colour
    /// and Toon strength. Pulled out for testability — bugs here show
    /// as layers looking too dark / too bright, which is the number
    /// one way a POC "just looks wrong" to playtesters.
    internal static func emissiveTint(
        base: SIMD3<Float>,
        strength: Float
    ) -> ToonPlatformColor {
        // C-v2 raises the soft-cel emissive from 0.35 → 0.5 so shadow
        // bands don't read muddy. `strength` still scales the factor
        // linearly so call sites can dial the toon feel down toward
        // PBR at their own discretion.
        let factor: Float = softCelEmissiveFactor
            * max(minStrength, min(maxStrength, strength))
        let rgb = SIMD3<Float>(
            max(0, min(1, base.x * factor)),
            max(0, min(1, base.y * factor)),
            max(0, min(1, base.z * factor))
        )
        return platformColor(from: rgb)
    }

    // MARK: - Colour bridge

    /// Multiply every channel by `saturationBoost`, clamped. A perfect
    /// saturation boost would go through HSV; this channel-wise gain is
    /// a deliberate simplification — for the earthy palette SDG-Lab
    /// uses (browns, greys, greens) the difference is imperceptible and
    /// channel-wise is trivially testable (you can check the result per
    /// component, see `testSaturationBoostMultipliesChannels`).
    /// Exposed `internal` for the same reason.
    internal static func saturationBoosted(
        _ rgb: SIMD3<Float>
    ) -> SIMD3<Float> {
        let b = saturationBoost
        return SIMD3<Float>(
            max(0, min(1, rgb.x * b)),
            max(0, min(1, rgb.y * b)),
            max(0, min(1, rgb.z * b))
        )
    }

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
