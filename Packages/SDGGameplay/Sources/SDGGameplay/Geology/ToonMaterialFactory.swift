// ToonMaterialFactory.swift
// SDGGameplay · Geology
//
// Phase 1 Toon Shader v0 — minimum viable "二次元" look for geology
// layers. See ADR-0004 and GDD §0 / §7.3.
//
// The factory is the *only* public entry point geology / UI code should
// reach for when they want "a Toon-ified material for a given colour".
// It hides the specific rendering strategy so the rest of the game
// doesn't care which of the three approaches (ShaderGraphMaterial,
// CustomMaterial, PhysicallyBasedMaterial) ends up being used.
//
// ## Why Approach C (PhysicallyBasedMaterial + backface-hull outline)
//
// Evaluated three paths (ADR-0004):
//   A. `ShaderGraphMaterial` + hand-written `.usda` — unverifiable from
//      a headless agent; one typo in the MaterialX graph bricks the
//      bundle at load time.
//   B. `CustomMaterial` + Metal `.metal` file — API available on iOS 18
//      but needs an MTLLibrary compiled into the SPM bundle, and it's
//      visionOS-unavailable, which would force us to carry two code
//      paths from day one.
//   C. `PhysicallyBasedMaterial` tuned for a flat, cel-ish look, with a
//      sibling back-face hull for the outline — all validated API,
//      portable across iOS / macOS / visionOS, zero extra resources.
//
// C ships today; Phase 2 can upgrade to A once Reality Composer Pro is
// part of the artist pipeline.
//
// ## What "Toon" means here
//
// Not a real stepped NdotL ramp. We fake the look with:
//   * `baseColor` at the requested tint,
//   * `roughness = 1.0` + `metallic = 0.0` so IBL contributes a soft,
//     even fill — approximates the "ambient" band of a cel-shaded look,
//   * an `emissiveColor` floor ≈ strength × base so there's no deep
//     black in shadow, matching the bright-ish anime reading in the
//     reference (原神, BotW),
//   * a **back-face hull** outline entity: same mesh scaled by 1.02,
//     `faceCulling = .front` so only back faces render, material is
//     pure black and unlit-ish (PBR with tint=black, emissive≈black,
//     roughness=1). This is a *silhouette* outline; it doesn't react
//     to normal discontinuities but is exactly right for the simple
//     axis-aligned layer boxes in Phase 1.
//
// Everything here is `@MainActor` because RealityKit material / entity
// initialisers on iOS 18 are MainActor-isolated.

import Foundation
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
/// geology layers in Phase 1.
///
/// All methods are `@MainActor` because `PhysicallyBasedMaterial` and
/// `ModelEntity` initialisers touch RealityKit state. Keeping the whole
/// factory on MainActor avoids needing the caller to sprinkle
/// `await MainActor.run {}` at every call site.
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
    ///     interpolate. Clamped to [0, 1].
    /// - Returns: An opaque `Material`. The concrete type today is
    ///   `PhysicallyBasedMaterial`; callers must not assume that.
    ///
    /// - Important: MainActor-isolated because `PhysicallyBasedMaterial`
    ///   setters are on MainActor in iOS 18 / macOS 15.
    @MainActor
    public static func makeLayerMaterial(
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
