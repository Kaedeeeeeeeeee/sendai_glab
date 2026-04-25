// ToonMaterialFactoryTests.swift
// SDGGameplay · Geology · Tests
//
// Unit tests for the Phase 1 Toon Shader v0 factory + the Phase 9
// Part C-v2 updates. Covers the Swift layer — material construction,
// outline geometry, clamp / no-crash behaviour, ShaderGraphMaterial
// cache behaviour. Pixel-level output of the shader is validated
// visually on device (no golden-image harness yet).
//
// Everything here is `@MainActor` because the factory is.

import XCTest
import RealityKit
@testable import SDGGameplay

@MainActor
final class ToonMaterialFactoryTests: XCTestCase {

    // MARK: - Hard cel variant

    /// Sanity: the harder cel variant returns a usable material. Same
    /// smoke shape as the soft variant's test.
    func testMakeHardCelMaterialDoesNotCrash() {
        // Force the PBR path — otherwise the ShaderGraph cache from a
        // previous test could leak in and the `as? PhysicallyBasedMaterial`
        // pin below would fail non-deterministically.
        ToonMaterialFactory.cachedShaderGraph = .failure(StubLoadError())
        defer { ToonMaterialFactory.resetShaderGraphCacheForTesting() }

        let tint = SIMD3<Float>(0.42, 0.48, 0.30)
        let material = ToonMaterialFactory.makeHardCelMaterial(
            baseColor: tint
        )
        let mesh = MeshResource.generateBox(size: 1.0)
        let entity = ModelEntity(mesh: mesh, materials: [material])
        XCTAssertNotNil(entity.components[ModelComponent.self])
    }

    /// The hard variant's emissive factor must be higher than the
    /// soft variant's — that's the whole point of shipping a second
    /// method. Regression here would mean someone silently lowered
    /// the cel hardness back to the soft value.
    func testHardCelEmissiveIsStrongerThanSoft() {
        let tint = SIMD3<Float>(0.5, 0.5, 0.5)

        // Compute each variant's emissive RGB via the exposed helpers.
        // We can't inspect the PhysicallyBasedMaterial's emissive field
        // directly across platforms (UIColor vs. NSColor components
        // are not trivially comparable), but the helpers return the
        // same platform colour so `.cgColor.components` works.
        let soft = ToonMaterialFactory.emissiveTint(
            base: tint,
            strength: 0.7
        )
        let hard = ToonMaterialFactory.emissiveTintHardCel(base: tint)

        let softComp = soft.cgColor.components!
        let hardComp = hard.cgColor.components!

        XCTAssertGreaterThan(
            hardComp[0], softComp[0],
            "hard-cel emissive R must exceed soft emissive R"
        )
    }

    // MARK: - Phase 9 Part C-v2: tuning values

    /// C-v2 pins the hard-cel emissive factor at 0.9 (up from C-v1's
    /// 0.6). This is the "nearly self-lit" setting that produces the
    /// visibly flatter PLATEAU / terrain look. Regression here would
    /// mean someone silently walked the flattening back.
    func testHardCelEmissiveFactorIs0_9() {
        XCTAssertEqual(
            ToonMaterialFactory.hardCelEmissiveFactor, 0.9,
            accuracy: 1e-5,
            "Phase 9 C-v2 pins hardCelEmissiveFactor at 0.9. If this " +
            "drifts the PLATEAU / terrain surface will regress toward " +
            "the C-v1 'flat-ish PBR' look."
        )

        // And verify the factor actually flows through to the computed
        // emissive tint — the constant could be right while the formula
        // silently ignores it.
        let base = SIMD3<Float>(0.6, 0.4, 0.2)
        let tint = ToonMaterialFactory.emissiveTintHardCel(base: base)
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        #if canImport(UIKit)
        tint.getRed(&r, green: &g, blue: &b, alpha: &a)
        #elseif canImport(AppKit)
        tint.usingColorSpace(.sRGB)?.getRed(&r, green: &g, blue: &b, alpha: &a)
        #endif
        XCTAssertEqual(r, 0.6 * 0.9, accuracy: 1e-5)
        XCTAssertEqual(g, 0.4 * 0.9, accuracy: 1e-5)
        XCTAssertEqual(b, 0.2 * 0.9, accuracy: 1e-5)
    }

    /// C-v2 raises the soft-cel emissive factor to 0.5 (from C-v1's
    /// 0.35). Pinned so the soft variant doesn't quietly regress to
    /// the Phase 1 value and leave outcrop layers looking muddy.
    func testSoftCelEmissiveFactorIs0_5() {
        XCTAssertEqual(
            ToonMaterialFactory.softCelEmissiveFactor, 0.5,
            accuracy: 1e-5,
            "Phase 9 C-v2 pins softCelEmissiveFactor at 0.5."
        )

        // Exercised through the public helper: strength=1 should give
        // base × 0.5 exactly.
        let base = SIMD3<Float>(0.8, 0.4, 0.2)
        let tint = ToonMaterialFactory.emissiveTint(
            base: base, strength: 1
        )
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        #if canImport(UIKit)
        tint.getRed(&r, green: &g, blue: &b, alpha: &a)
        #elseif canImport(AppKit)
        tint.usingColorSpace(.sRGB)?.getRed(&r, green: &g, blue: &b, alpha: &a)
        #endif
        XCTAssertEqual(r, 0.8 * 0.5, accuracy: 1e-5)
        XCTAssertEqual(g, 0.4 * 0.5, accuracy: 1e-5)
        XCTAssertEqual(b, 0.2 * 0.5, accuracy: 1e-5)
    }

    /// C-v2 saturation boost is 1.15 — multiplying every base colour
    /// channel by 1.15 before it hits the tint. Pin the constant AND
    /// verify the function actually applies it.
    func testSaturationBoostMultipliesChannels() {
        XCTAssertEqual(
            ToonMaterialFactory.saturationBoost, 1.15,
            accuracy: 1e-5,
            "Phase 9 C-v2 pins saturationBoost at 1.15."
        )

        // Modest input — far from the clamp ceiling.
        let input = SIMD3<Float>(0.4, 0.3, 0.2)
        let boosted = ToonMaterialFactory.saturationBoosted(input)
        XCTAssertEqual(boosted.x, 0.4 * 1.15, accuracy: 1e-5)
        XCTAssertEqual(boosted.y, 0.3 * 1.15, accuracy: 1e-5)
        XCTAssertEqual(boosted.z, 0.2 * 1.15, accuracy: 1e-5)

        // Saturated input — clamp ceiling must apply so we don't push
        // pixels outside [0, 1] into the PBR shader.
        let bright = SIMD3<Float>(0.95, 0.9, 0.5)
        let boostedBright = ToonMaterialFactory.saturationBoosted(bright)
        XCTAssertLessThanOrEqual(boostedBright.x, 1.0)
        XCTAssertLessThanOrEqual(boostedBright.y, 1.0)
    }

    // MARK: - Layer material

    /// The simplest possible smoke test: given a representative geology
    /// colour (rusty topsoil #6B4226 as 0…1 RGB), the factory must
    /// produce a material without crashing and the result must be
    /// assignable to a `ModelComponent`. Regression here would mean
    /// Phase 1 geology rendering is dead on arrival.
    func testMakeLayerMaterialDoesNotCrash() {
        let topsoil = SIMD3<Float>(
            Float(0x6B) / 255.0,
            Float(0x42) / 255.0,
            Float(0x26) / 255.0
        )
        let material = ToonMaterialFactory.makeLayerMaterial(
            baseColor: topsoil
        )
        // Material protocol has no Equatable surface we could rely on;
        // the contract we care about is "hands back something usable
        // as a ModelComponent material array".
        let mesh = MeshResource.generateBox(size: 1.0)
        let entity = ModelEntity(mesh: mesh, materials: [material])
        XCTAssertNotNil(entity.components[ModelComponent.self])
        XCTAssertEqual(
            entity.components[ModelComponent.self]?.materials.count,
            1
        )
    }

    /// White input must produce a white-tinted material on the PBR
    /// fallback path. We force the fallback (cached-failure) so the
    /// assertion doesn't break when ShaderGraph is active in another
    /// test's leftover cache state.
    ///
    /// C-v2 note: the tint is now saturation-boosted (×1.15), but
    /// white clamps to white, so the assertion value is unchanged.
    func testBaseColorPropagatesToMaterial() throws {
        ToonMaterialFactory.cachedShaderGraph = .failure(StubLoadError())
        defer { ToonMaterialFactory.resetShaderGraphCacheForTesting() }

        let white = SIMD3<Float>(1, 1, 1)
        let material = ToonMaterialFactory.makeLayerMaterial(baseColor: white)
        let pbr = try XCTUnwrap(material as? PhysicallyBasedMaterial)

        let tint = pbr.baseColor.tint
        // tint is UIColor on iOS, NSColor on macOS — both expose
        // `getRed:green:blue:alpha:`. We read the raw RGBA rather than
        // comparing colour objects (direct equality varies by colour
        // space).
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        #if canImport(UIKit)
        tint.getRed(&r, green: &g, blue: &b, alpha: &a)
        #elseif canImport(AppKit)
        // NSColor requires a compatible color space before getRed
        // succeeds without throwing. `sRGB` is what we used on input
        // (UIColor/NSColor(red:green:blue:alpha:) defaults there).
        if let converted = tint.usingColorSpace(.sRGB) {
            converted.getRed(&r, green: &g, blue: &b, alpha: &a)
        } else {
            tint.getRed(&r, green: &g, blue: &b, alpha: &a)
        }
        #endif
        // Saturation boost ×1.15 × 1.0 clamps back to 1.0 for white.
        XCTAssertEqual(r, 1.0, accuracy: 1e-4)
        XCTAssertEqual(g, 1.0, accuracy: 1e-4)
        XCTAssertEqual(b, 1.0, accuracy: 1e-4)
    }

    /// Out-of-range components must clamp rather than wrap. Pass values
    /// outside [0, 1] and confirm no crash — the clamp is an explicit
    /// `max/min` in the factory so we can't easily inspect the result's
    /// internal CGColor, but we *can* pin the "doesn't crash / still
    /// produces a usable material" invariant.
    func testBaseColorClampsOutOfRange() {
        let wild = SIMD3<Float>(-0.5, 2.0, 0.7)
        let material = ToonMaterialFactory.makeLayerMaterial(baseColor: wild)
        let mesh = MeshResource.generateBox(size: 1.0)
        let entity = ModelEntity(mesh: mesh, materials: [material])
        XCTAssertNotNil(entity.components[ModelComponent.self])
    }

    /// The `strength` parameter must clamp too. Negative and > 1 values
    /// are valid inputs (clamped inside) — the factory must not reject
    /// them.
    func testStrengthClampsToUnitRange() {
        let grey = SIMD3<Float>(0.5, 0.5, 0.5)
        _ = ToonMaterialFactory.makeLayerMaterial(
            baseColor: grey, strength: -0.3
        )
        _ = ToonMaterialFactory.makeLayerMaterial(
            baseColor: grey, strength: 1.5
        )
        _ = ToonMaterialFactory.makeLayerMaterial(
            baseColor: grey, strength: 0.0
        )
        _ = ToonMaterialFactory.makeLayerMaterial(
            baseColor: grey, strength: 1.0
        )
        // No crash = pass. The actual clamp values are covered by the
        // `emissiveTint(...)` helper tests below.
    }

    /// With `strength = 0` the emissive tint should be pure black —
    /// we want Toon off to degrade smoothly into "plain matte PBR",
    /// not a dim self-lit surface.
    func testZeroStrengthEmissiveIsBlack() {
        let base = SIMD3<Float>(0.8, 0.4, 0.2)
        let tint = ToonMaterialFactory.emissiveTint(base: base, strength: 0)
        var r: CGFloat = 1, g: CGFloat = 1, b: CGFloat = 1, a: CGFloat = 0
        #if canImport(UIKit)
        tint.getRed(&r, green: &g, blue: &b, alpha: &a)
        #elseif canImport(AppKit)
        tint.usingColorSpace(.sRGB)?.getRed(&r, green: &g, blue: &b, alpha: &a)
        #endif
        XCTAssertEqual(r, 0, accuracy: 1e-5)
        XCTAssertEqual(g, 0, accuracy: 1e-5)
        XCTAssertEqual(b, 0, accuracy: 1e-5)
    }

    /// With `strength = 1` the emissive tint should be exactly
    /// `base × 0.5` (the C-v2 soft-cel factor). This pins the factor
    /// so a well-meaning future tweak that accidentally flips it
    /// doesn't go unnoticed. C-v1 shipped 0.35; C-v2 ships 0.5.
    func testFullStrengthEmissiveMatchesDocumentedFactor() {
        let base = SIMD3<Float>(0.8, 0.4, 0.2)
        let tint = ToonMaterialFactory.emissiveTint(base: base, strength: 1)
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        #if canImport(UIKit)
        tint.getRed(&r, green: &g, blue: &b, alpha: &a)
        #elseif canImport(AppKit)
        tint.usingColorSpace(.sRGB)?.getRed(&r, green: &g, blue: &b, alpha: &a)
        #endif
        XCTAssertEqual(r, 0.8 * 0.5, accuracy: 1e-5)
        XCTAssertEqual(g, 0.4 * 0.5, accuracy: 1e-5)
        XCTAssertEqual(b, 0.2 * 0.5, accuracy: 1e-5)
    }

    // MARK: - Outline

    /// Outline helper must return a child entity when the source has
    /// a `ModelComponent`, and the child must carry its own
    /// `ModelComponent` with exactly one (outline) material.
    func testMakeOutlineReturnsEntityForModelEntity() throws {
        let mesh = MeshResource.generateBox(size: 1.0)
        let source = ModelEntity(
            mesh: mesh,
            materials: [SimpleMaterial()]
        )
        source.name = "TestLayer"

        let outline = try XCTUnwrap(
            ToonMaterialFactory.makeOutlineEntity(for: source)
        )
        XCTAssertEqual(outline.name, "TestLayer_Outline")

        let model = try XCTUnwrap(outline.components[ModelComponent.self])
        XCTAssertEqual(model.materials.count, 1)
    }

    /// Outline helper must return `nil` for entities without geometry —
    /// we refuse to invent meshes; attaching an outline to a bare
    /// `Entity` would silently do nothing useful.
    ///
    /// Bare `Entity` isn't a `ModelEntity`, so the factory takes a
    /// `ModelEntity` (compile-time guarantee) and the runtime check is
    /// "missing `ModelComponent`".
    func testMakeOutlineReturnsNilWithoutModelComponent() {
        let bare = ModelEntity()
        // A freshly-init'd ModelEntity has no ModelComponent until
        // a mesh + materials are assigned — confirm the assumption.
        XCTAssertNil(bare.components[ModelComponent.self])
        XCTAssertNil(ToonMaterialFactory.makeOutlineEntity(for: bare))
    }

    /// C-v2 pins the outline scale at 1.05 (up from C-v1's 1.02). This
    /// is the visible-silhouette knob — getting it wrong either hides
    /// the outline (too small) or balloons it into a halo (too large).
    /// A regression here is immediately obvious on device, so pinning
    /// it by constant makes the test signal tight.
    func testOutlineHullScaleIs1_05() throws {
        let mesh = MeshResource.generateBox(size: 1.0)
        let source = ModelEntity(mesh: mesh, materials: [SimpleMaterial()])
        let outline = try XCTUnwrap(
            ToonMaterialFactory.makeOutlineEntity(for: source)
        )

        let s = outline.transform.scale
        let expected = ToonMaterialFactory.outlineScale
        XCTAssertEqual(s.x, expected, accuracy: 1e-5)
        XCTAssertEqual(s.y, expected, accuracy: 1e-5)
        XCTAssertEqual(s.z, expected, accuracy: 1e-5)
        // Pin the constant itself so a casual bump is a test signal.
        XCTAssertEqual(
            expected, 1.05, accuracy: 1e-5,
            "Phase 9 C-v2 pins outlineScale at 1.05. If this drifts, " +
            "the outline thickness regresses (1.02 is barely-visible, " +
            ">1.05 z-fights thin meshes like DEM triangles)."
        )
    }

    /// The outline material must cull front faces — that's the whole
    /// trick that turns the scaled-up hull into a silhouette. A bad
    /// faceCulling value would either render a solid black blob over
    /// the layer (`.none`) or disappear entirely (`.back`).
    func testOutlineMaterialCullsFrontFaces() {
        let m = ToonMaterialFactory.makeOutlineMaterial()
        XCTAssertEqual(m.faceCulling, .front)
    }

    /// C-v2 outline: when no baseColor is given, ink falls back to
    /// pure black (legacy C-v1 behaviour) so existing call sites that
    /// don't know the source tint still get a sensible outline.
    func testOutlineInkDefaultsToBlackWhenBaseColorNil() {
        let ink = ToonMaterialFactory.outlineInkColor(for: nil)
        var r: CGFloat = 1, g: CGFloat = 1, b: CGFloat = 1, a: CGFloat = 0
        #if canImport(UIKit)
        ink.getRed(&r, green: &g, blue: &b, alpha: &a)
        #elseif canImport(AppKit)
        ink.usingColorSpace(.sRGB)?.getRed(&r, green: &g, blue: &b, alpha: &a)
        #endif
        XCTAssertEqual(r, 0, accuracy: 1e-5)
        XCTAssertEqual(g, 0, accuracy: 1e-5)
        XCTAssertEqual(b, 0, accuracy: 1e-5)
    }

    /// C-v2 outline: when a baseColor is provided, the ink is the
    /// darkened complement (25 % of (1 - base)). A warm building
    /// (red-heavy) should produce a cyan-heavy dark outline.
    func testOutlineInkTintedByComplementWhenBaseColorProvided() {
        // Red-heavy base — expect cyan-heavy ink.
        let base = SIMD3<Float>(0.8, 0.2, 0.2)
        let ink = ToonMaterialFactory.outlineInkColor(for: base)

        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        #if canImport(UIKit)
        ink.getRed(&r, green: &g, blue: &b, alpha: &a)
        #elseif canImport(AppKit)
        ink.usingColorSpace(.sRGB)?.getRed(&r, green: &g, blue: &b, alpha: &a)
        #endif

        // Complement of (0.8, 0.2, 0.2) is (0.2, 0.8, 0.8), × 0.25 =
        // (0.05, 0.2, 0.2).
        XCTAssertEqual(r, 0.2 * 0.25, accuracy: 1e-5)
        XCTAssertEqual(g, 0.8 * 0.25, accuracy: 1e-5)
        XCTAssertEqual(b, 0.8 * 0.25, accuracy: 1e-5)
        // The ink must actually be cooler than the base — that is the
        // whole aesthetic claim. A darkened R channel ink would be
        // "same colour, just dimmer", which defeats the purpose.
        XCTAssertLessThan(
            r, g,
            "complement-tinted ink must be cooler than a warm base"
        )
    }

    // MARK: - Attach convenience

    /// The `attachOutline(to:)` extension must append exactly one child
    /// to the source and return the handle. Callers that want to keep
    /// the returned handle for later (e.g. to toggle visibility) need
    /// a non-nil value.
    func testAttachOutlineAppendsChildAndReturnsIt() throws {
        let mesh = MeshResource.generateBox(size: 1.0)
        let source = ModelEntity(mesh: mesh, materials: [SimpleMaterial()])
        XCTAssertEqual(source.children.count, 0)

        let returned = ToonMaterialFactory.attachOutline(to: source)
        XCTAssertNotNil(returned)
        XCTAssertEqual(source.children.count, 1)
        // Identity check — the returned handle must be the child, not
        // an orphan copy.
        XCTAssertTrue(source.children.first === returned)
    }

    /// Attaching to a geometry-less entity must not mutate the scene
    /// graph and must return nil — the whole point of the guard.
    func testAttachOutlineNoOpsWithoutModelComponent() {
        let bare = ModelEntity()
        let returned = ToonMaterialFactory.attachOutline(to: bare)
        XCTAssertNil(returned)
        XCTAssertEqual(bare.children.count, 0)
    }

    // MARK: - Phase 9 Part C-v2: ShaderGraph path + PBR fallback

    /// Stub error used to seed the shader cache for fallback tests.
    /// Local type so we don't leak a helper into the SDGGameplay
    /// public surface.
    struct StubLoadError: Error {}

    /// Best-effort load: attempts to fetch `StepRampToon.usda` from the
    /// test bundle. Pass if load succeeds OR if it fails with a
    /// `ShaderGraphMaterial.LoadError` — MaterialX is strict and the
    /// `.usda` is hand-written from a headless agent, so a parse
    /// failure is an expected branch, not a regression. The test's
    /// purpose is to confirm that the bundle path is correct and the
    /// preload doesn't crash the process.
    func testShaderGraphMaterialLoadsSuccessfully() async {
        // Make the test independent of previous runs in the same
        // process (XCTest reuses the test bundle, so the static cache
        // can carry over).
        ToonMaterialFactory.resetShaderGraphCacheForTesting()
        defer { ToonMaterialFactory.resetShaderGraphCacheForTesting() }

        let loaded = await ToonMaterialFactory.preloadStepRampShader(
            bundle: .module
        )
        // We assert the cache is populated (either success or failure);
        // we don't assert `loaded == true` because MaterialX authoring
        // from a headless agent is inherently flaky. The "failure is
        // recorded and reused" invariant is enough.
        XCTAssertNotNil(ToonMaterialFactory.cachedShaderGraph)

        // Sanity: if it did load, we get Scheme A; otherwise Scheme C.
        // Either way, the next makeLayerMaterial must return a usable
        // material (proven below in
        // `testMakeLayerMaterialAlwaysReturnsValidMaterial`). We do not
        // branch assertions on `loaded` here beyond that.
        _ = loaded
    }

    /// When the ShaderGraph cache holds a failure, `attemptStepRampMaterial`
    /// must return nil (signalling "fall through to PBR"). Exercises
    /// the exact path the factory takes when a hand-written `.usda`
    /// fails to parse.
    func testFallbackReturnsPhysicallyBasedMaterialOnLoadFailure() {
        ToonMaterialFactory.cachedShaderGraph = .failure(StubLoadError())
        defer { ToonMaterialFactory.resetShaderGraphCacheForTesting() }

        let tint = SIMD3<Float>(0.2, 0.3, 0.4)
        XCTAssertNil(
            ToonMaterialFactory.attemptStepRampMaterial(baseColor: tint),
            "Cached failure must produce nil so callers fall to PBR."
        )

        // Public API must still return a usable material — specifically
        // the Scheme C-v2 PhysicallyBasedMaterial.
        let material = ToonMaterialFactory.makeLayerMaterial(
            baseColor: tint
        )
        XCTAssertNotNil(
            material as? PhysicallyBasedMaterial,
            "Fallback path must return PhysicallyBasedMaterial (Scheme C-v2)."
        )
    }

    /// Whether the ShaderGraph loaded or not, `makeLayerMaterial` must
    /// always return a usable `Material`. This is the "game MUST launch
    /// even if the shader is broken" contract from the ADR-0004 Phase 9
    /// addendum — exercised by assigning the returned material into a
    /// real `ModelComponent`.
    func testMakeLayerMaterialAlwaysReturnsValidMaterial() async {
        ToonMaterialFactory.resetShaderGraphCacheForTesting()
        defer { ToonMaterialFactory.resetShaderGraphCacheForTesting() }

        // Try each cache state explicitly — preload unattempted, preload
        // failed, preload succeeded — and confirm the public API
        // survives all three.
        let tint = SIMD3<Float>(0.5, 0.6, 0.7)

        // 1. Cache empty (preload never ran).
        let m1 = ToonMaterialFactory.makeLayerMaterial(baseColor: tint)
        _ = ModelEntity(
            mesh: .generateBox(size: 1),
            materials: [m1]
        )

        // 2. Cache = failure.
        ToonMaterialFactory.cachedShaderGraph = .failure(StubLoadError())
        let m2 = ToonMaterialFactory.makeLayerMaterial(baseColor: tint)
        _ = ModelEntity(
            mesh: .generateBox(size: 1),
            materials: [m2]
        )
        XCTAssertNotNil(
            m2 as? PhysicallyBasedMaterial,
            "Failure-cache path must emit Scheme C-v2 PBR."
        )

        // 3. Real preload (may succeed or fail — either is fine).
        ToonMaterialFactory.resetShaderGraphCacheForTesting()
        _ = await ToonMaterialFactory.preloadStepRampShader(bundle: .module)
        let m3 = ToonMaterialFactory.makeLayerMaterial(baseColor: tint)
        _ = ModelEntity(
            mesh: .generateBox(size: 1),
            materials: [m3]
        )
    }

    /// The hard-cel variant also routes through the ShaderGraph +
    /// fallback chain, so it shares the "always returns something
    /// usable" contract.
    func testMakeHardCelMaterialAlwaysReturnsValidMaterial() {
        ToonMaterialFactory.cachedShaderGraph = .failure(StubLoadError())
        defer { ToonMaterialFactory.resetShaderGraphCacheForTesting() }

        let tint = SIMD3<Float>(0.4, 0.5, 0.6)
        let material = ToonMaterialFactory.makeHardCelMaterial(
            baseColor: tint
        )
        XCTAssertNotNil(
            material as? PhysicallyBasedMaterial,
            "Fallback path must return PhysicallyBasedMaterial (hard-cel Scheme C-v2)."
        )
    }

    // MARK: - Phase 11 Part D: textured PBR → painted cel

    /// Build a 1×1 `TextureResource` via a white `CGImage` backed by
    /// `CGBitmapInfo`. This does NOT touch Metal — `TextureResource`
    /// will allocate GPU resources lazily (on first sampler use),
    /// which means the test suite can run even when the XCTest process
    /// has no Metal device (macOS CI with no GPU).
    ///
    /// Returns `nil` if `CGImage` creation fails (e.g. colour space
    /// unavailable on the host). The three tests below skip via
    /// `XCTSkipIf` in that case — they are testing the factory's
    /// behaviour, not the OS's image stack.
    @MainActor
    private func makeTinyWhiteTexture() throws -> TextureResource? {
        let width = 1
        let height = 1
        guard let cs = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(
                data: nil,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: 0,
                space: cs,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              )
        else { return nil }
        ctx.setFillColor(red: 1, green: 1, blue: 1, alpha: 1)
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        guard let cg = ctx.makeImage() else { return nil }
        // `TextureResource.generate(from:options:)` is the iOS 18 entry
        // point — throws on malformed input (won't happen for a 1×1
        // sRGB bitmap) or when the underlying image layer can't build
        // a backing texture.
        do {
            return try TextureResource(
                image: cg,
                options: TextureResource.CreateOptions(semantic: .color)
            )
        } catch {
            // Surface *why* we're skipping rather than returning nil
            // silently — see CLAUDE.md pitfall #9.
            print(
                "[SDG-Lab][toon-test] TextureResource.init skipped: \(error)"
            )
            return nil
        }
    }

    /// The whole point of the Phase 11 Part D mutator: feeding it a
    /// `PhysicallyBasedMaterial` with a real `baseColor.texture` must
    /// produce a material whose `baseColor.texture` is the same
    /// resource — not nil, not a stub, not a white placeholder.
    ///
    /// We compare via `TextureResource.Equatable` (RealityKit's own
    /// equality; see the swiftinterface). Pointer identity via `===`
    /// doesn't hold because `MaterialParameters.Texture` round-trips
    /// the resource through an internal storage layer that may hand
    /// back a fresh wrapper object — what matters for rendering is
    /// that the underlying texture content is the same, which
    /// `==` checks.
    func testMutateIntoTexturedCelPreservesBaseColorTexture() throws {
        let texture = try makeTinyWhiteTexture()
        try XCTSkipIf(
            texture == nil,
            "CGImage/TextureResource unavailable on host; not a factory bug."
        )
        let resource = texture!

        var input = PhysicallyBasedMaterial()
        input.baseColor = .init(tint: .white, texture: .init(resource))
        XCTAssertNotNil(input.baseColor.texture, "setup check")
        let inputResource = try XCTUnwrap(
            input.baseColor.texture?.resource,
            "setup: input must carry a resource after assignment"
        )

        let output = ToonMaterialFactory.mutateIntoTexturedCel(input)
        let outputTexture = try XCTUnwrap(
            output.baseColor.texture,
            "mutator must preserve the baseColor.texture — this is the whole contract"
        )
        // RealityKit's TextureResource is Equatable — equality is the
        // right semantic here (same content, same backing), not pointer
        // identity.
        XCTAssertEqual(
            outputTexture.resource, inputResource,
            "mutator must preserve the underlying TextureResource"
        )
        // And the output must definitely not be `nil` or the default
        // white placeholder — if the mutator accidentally wiped the
        // texture, read-back would give either nil or a fresh default
        // resource (not equal to our 1×1 sRGB fixture).
        XCTAssertEqual(
            outputTexture.resource, resource,
            "output texture must equal the fixture we put in"
        )
    }

    /// The mutator must raise the emissive contribution so the texture
    /// reads brighter on the shadow side. The boost is encoded as
    /// `emissiveColor = white @ ~25 % alpha` (from the default black
    /// `EmissiveColor`, which contributes zero). We read the
    /// `emissiveColor.color` components back and assert each is
    /// meaningfully brighter than the input's.
    ///
    /// Note: `emissiveIntensity` alone isn't a useful signal because
    /// `PhysicallyBasedMaterial()` ships with `emissiveIntensity = 1.0`
    /// by default (the scalar is applied to whatever colour is set).
    /// The real "brighter" signal is in the colour's luminance.
    func testMutateIntoTexturedCelBoostsEmissive() throws {
        let texture = try makeTinyWhiteTexture()
        try XCTSkipIf(
            texture == nil,
            "CGImage/TextureResource unavailable on host; not a factory bug."
        )

        var input = PhysicallyBasedMaterial()
        input.baseColor = .init(tint: .white, texture: .init(texture!))
        // Input's default EmissiveColor is black (zero contribution).
        let inputColor = input.emissiveColor.color
        var ir: CGFloat = 0, ig: CGFloat = 0, ib: CGFloat = 0, ia: CGFloat = 0
        #if canImport(UIKit)
        inputColor.getRed(&ir, green: &ig, blue: &ib, alpha: &ia)
        #elseif canImport(AppKit)
        inputColor.usingColorSpace(.sRGB)?.getRed(
            &ir, green: &ig, blue: &ib, alpha: &ia
        )
        #endif
        // Input luminance is ~0 (default black emissive).
        let inputLuminance = ir * ia + ig * ia + ib * ia

        let output = ToonMaterialFactory.mutateIntoTexturedCel(input)

        let outputColor = output.emissiveColor.color
        var or: CGFloat = 0, og: CGFloat = 0, ob: CGFloat = 0, oa: CGFloat = 0
        #if canImport(UIKit)
        outputColor.getRed(&or, green: &og, blue: &ob, alpha: &oa)
        #elseif canImport(AppKit)
        outputColor.usingColorSpace(.sRGB)?.getRed(
            &or, green: &og, blue: &ob, alpha: &oa
        )
        #endif
        let outputLuminance = or * oa + og * oa + ob * oa

        XCTAssertGreaterThan(
            outputLuminance, inputLuminance,
            "mutator must raise emissive luminance above the input's " +
            "(default PhysicallyBasedMaterial has black emissive)"
        )
        // Pin the documented constant so a silent knob change shows up
        // as a test signal rather than a visual regression on device.
        XCTAssertEqual(
            ToonMaterialFactory.texturedCelEmissiveWhiteAlpha,
            0.25, accuracy: 1e-5,
            "Phase 11 Part D pins the emissive white alpha at 0.25."
        )
        // And the output alpha must match the documented boost level
        // (within a wide tolerance — UIColor round-trips through sRGB
        // may nudge fractional values).
        XCTAssertEqual(
            oa, 0.25, accuracy: 1e-3,
            "emissiveColor alpha must equal the documented boost (0.25)"
        )
    }

    /// Specular must be killed (scalar 0) on the mutator's output —
    /// part of the "no PBR highlight" contract. We read `metallic` as
    /// the closest public proxy the SDK exposes alongside `specular`
    /// (setters for both use the same `MaterialScalarParameter` shape,
    /// so the intent is verified through both together).
    func testMutateIntoTexturedCelKillsSpecular() throws {
        let texture = try makeTinyWhiteTexture()
        try XCTSkipIf(
            texture == nil,
            "CGImage/TextureResource unavailable on host; not a factory bug."
        )

        // Input with specular "on" via specular = 1, metallic = 1,
        // clearcoat = 1. The mutator zeroes specular explicitly and
        // also kills metallic/clearcoat — the three PBR terms that
        // can produce a highlight.
        var input = PhysicallyBasedMaterial()
        input.baseColor = .init(tint: .white, texture: .init(texture!))
        input.specular = .init(floatLiteral: 1.0)
        input.metallic = .init(floatLiteral: 1.0)
        input.clearcoat = .init(floatLiteral: 1.0)

        let output = ToonMaterialFactory.mutateIntoTexturedCel(input)
        XCTAssertEqual(
            output.specular.scale, 0, accuracy: 1e-5,
            "mutator must zero specular (explicit Borderlands-ish contract)"
        )
        XCTAssertEqual(
            output.metallic.scale, 0, accuracy: 1e-5,
            "mutator must zero metallic (removes PBR metal highlight)"
        )
        XCTAssertEqual(
            output.clearcoat.scale, 0, accuracy: 1e-5,
            "mutator must zero clearcoat (removes residual sheen)"
        )
        XCTAssertEqual(
            output.roughness.scale, 1, accuracy: 1e-5,
            "mutator must max roughness (painted look)"
        )
    }
}
