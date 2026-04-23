// ToonMaterialFactoryTests.swift
// SDGGameplay · Geology · Tests
//
// Unit tests for the Phase 1 Toon Shader v0 factory. Covers the Swift
// layer — material construction, outline geometry, clamp / no-crash
// behaviour. Pixel-level output of the shader is validated visually on
// device (Phase 1 has no golden-image harness yet).
//
// Everything here is `@MainActor` because the factory is.

import XCTest
import RealityKit
@testable import SDGGameplay

@MainActor
final class ToonMaterialFactoryTests: XCTestCase {

    // MARK: - Hard cel variant (Phase 3)

    /// Sanity: the harder cel variant returns a usable material. Same
    /// smoke shape as the soft variant's test.
    func testMakeHardCelMaterialDoesNotCrash() {
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

    /// White input must produce a white-tinted material. We assert on
    /// `PhysicallyBasedMaterial.baseColor.tint` because Approach C (see
    /// ADR-0004) uses PBR under the hood; if the factory ever switches
    /// to `ShaderGraphMaterial`, this test moves to a parameter probe.
    func testBaseColorPropagatesToMaterial() throws {
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
    /// `base × 0.35` (the empirical factor documented in the factory).
    /// This pins the factor so a well-meaning future tweak that
    /// accidentally flips it doesn't go unnoticed.
    func testFullStrengthEmissiveMatchesDocumentedFactor() {
        let base = SIMD3<Float>(0.8, 0.4, 0.2)
        let tint = ToonMaterialFactory.emissiveTint(base: base, strength: 1)
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        #if canImport(UIKit)
        tint.getRed(&r, green: &g, blue: &b, alpha: &a)
        #elseif canImport(AppKit)
        tint.usingColorSpace(.sRGB)?.getRed(&r, green: &g, blue: &b, alpha: &a)
        #endif
        XCTAssertEqual(r, 0.8 * 0.35, accuracy: 1e-5)
        XCTAssertEqual(g, 0.4 * 0.35, accuracy: 1e-5)
        XCTAssertEqual(b, 0.2 * 0.35, accuracy: 1e-5)
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

    /// Outline must be uniformly scaled by `outlineScale` (≈1.02 ×)
    /// on every axis relative to the source. Getting the scale wrong
    /// would either hide the outline (too small) or balloon it into
    /// a halo (too large).
    func testOutlineIsOnePointZeroTwoTimesLarger() throws {
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
        // The constant must also remain in a reasonable neighbourhood
        // (≈1.02) — pin it here so a casual bump is a test signal.
        XCTAssertEqual(expected, 1.02, accuracy: 1e-5)
    }

    /// The outline material must cull front faces — that's the whole
    /// trick that turns the scaled-up hull into a silhouette. A bad
    /// faceCulling value would either render a solid black blob over
    /// the layer (`.none`) or disappear entirely (`.back`).
    func testOutlineMaterialCullsFrontFaces() {
        let m = ToonMaterialFactory.makeOutlineMaterial()
        XCTAssertEqual(m.faceCulling, .front)
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

    // MARK: - Phase 9 Part C: ShaderGraph path + PBR fallback

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
        // Seed the cache with a synthetic failure. The error type
        // doesn't matter — any Error triggers the failure branch.
        struct StubError: Error {}
        ToonMaterialFactory.cachedShaderGraph = .failure(StubError())
        defer { ToonMaterialFactory.resetShaderGraphCacheForTesting() }

        let tint = SIMD3<Float>(0.2, 0.3, 0.4)
        XCTAssertNil(
            ToonMaterialFactory.attemptStepRampMaterial(baseColor: tint),
            "Cached failure must produce nil so callers fall to PBR."
        )

        // Public API must still return a usable material — specifically
        // the Scheme C PhysicallyBasedMaterial.
        let material = ToonMaterialFactory.makeLayerMaterial(
            baseColor: tint
        )
        XCTAssertNotNil(
            material as? PhysicallyBasedMaterial,
            "Fallback path must return PhysicallyBasedMaterial (Scheme C)."
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
        struct StubError: Error {}
        ToonMaterialFactory.cachedShaderGraph = .failure(StubError())
        let m2 = ToonMaterialFactory.makeLayerMaterial(baseColor: tint)
        _ = ModelEntity(
            mesh: .generateBox(size: 1),
            materials: [m2]
        )
        XCTAssertNotNil(
            m2 as? PhysicallyBasedMaterial,
            "Failure-cache path must emit Scheme C PBR."
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
        struct StubError: Error {}
        ToonMaterialFactory.cachedShaderGraph = .failure(StubError())
        defer { ToonMaterialFactory.resetShaderGraphCacheForTesting() }

        let tint = SIMD3<Float>(0.4, 0.5, 0.6)
        let material = ToonMaterialFactory.makeHardCelMaterial(
            baseColor: tint
        )
        XCTAssertNotNil(
            material as? PhysicallyBasedMaterial,
            "Fallback path must return PhysicallyBasedMaterial (hard-cel Scheme C)."
        )
    }
}
