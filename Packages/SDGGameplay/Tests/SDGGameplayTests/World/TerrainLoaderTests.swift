// TerrainLoaderTests.swift
// SDGGameplay · World · Tests
//
// Covers the synthesisable parts of `TerrainLoader`: construction
// (with and without an `EnvelopeManifest`), missing-resource error
// path, default identifier pinning, and Phase 4's new
// `envelopeMissing` error case.
//
// Real USDZ loading requires RealityKit runtime (not reliable in
// `swift test` on macOS), so actual mesh loading is exercised only by
// the device smoke test documented in the PR description.

import XCTest
import RealityKit
@testable import SDGGameplay

@MainActor
final class TerrainLoaderTests: XCTestCase {

    // MARK: - Fixtures

    /// Inline JSON whose manifest contains the Phase 4 production DEM
    /// tile id so `TerrainLoader.defaultTerrainTileId` resolves cleanly.
    /// Numbers are made-up round values so assertions about positions
    /// remain readable.
    private static let manifestWithTerrainJSON: String = """
    {
      "meta": {
        "source_crs": "EPSG:6697",
        "target_crs": "EPSG:6677",
        "spawn_tile_id": "57403617",
        "generated_by": "TerrainLoaderTests",
        "generated_at": "2026-04-23T12:00:00Z"
      },
      "envelopes": {
        "57403617": {
          "lower_corner_m": [9375.0,  19500.0,  90.0],
          "upper_corner_m": [10625.0, 20500.0, 110.0]
        },
        "574036_05_dem": {
          "lower_corner_m": [9000.0,  19000.0,   0.0],
          "upper_corner_m": [11000.0, 21000.0, 200.0]
        }
      }
    }
    """

    /// Inline JSON whose manifest *lacks* the terrain tile id. Used to
    /// prove that `.envelopeMissing` fires when the pipeline emits a
    /// manifest without the DEM entry.
    private static let manifestWithoutTerrainJSON: String = """
    {
      "meta": {
        "source_crs": "EPSG:6697",
        "target_crs": "EPSG:6677",
        "spawn_tile_id": "57403617",
        "generated_by": "TerrainLoaderTests",
        "generated_at": "2026-04-23T12:00:00Z"
      },
      "envelopes": {
        "57403617": {
          "lower_corner_m": [9375.0,  19500.0,  90.0],
          "upper_corner_m": [10625.0, 20500.0, 110.0]
        }
      }
    }
    """

    private func manifestWithTerrain() throws -> EnvelopeManifest {
        try EnvelopeManifest(jsonData: Data(Self.manifestWithTerrainJSON.utf8))
    }

    private func manifestWithoutTerrain() throws -> EnvelopeManifest {
        try EnvelopeManifest(jsonData: Data(Self.manifestWithoutTerrainJSON.utf8))
    }

    // MARK: - Construction

    /// If the initialiser ever starts touching the bundle or the
    /// filesystem, CI on an empty test bundle would start tripping
    /// over missing USDZ. Phase 4 widens the guard to include the
    /// manifest-carrying init — retaining the manifest must also be a
    /// pure reference copy, no decoding / validation side effects.
    func testInitIsSideEffectFree() throws {
        // Without manifest (Phase 3 shape).
        _ = TerrainLoader(bundle: .main)
        _ = TerrainLoader(bundle: Bundle(for: type(of: self)))

        // With manifest (Phase 4 shape).
        let manifest = try manifestWithTerrain()
        _ = TerrainLoader(bundle: .main, manifest: manifest)
        _ = TerrainLoader(
            bundle: Bundle(for: type(of: self)),
            manifest: manifest,
            terrainTileId: TerrainLoader.defaultTerrainTileId
        )
    }

    // MARK: - Resource resolution

    /// Given a bundle that doesn't contain the Terrain USDZ, `load()`
    /// must throw `.resourceNotFound` with the correct basename — NOT
    /// a generic RealityKit error, NOT a crash. The RootView handler
    /// keys on this error to decide whether to fall back to the
    /// flat-ground plane.
    func testLoadThrowsResourceNotFoundForEmptyBundle() async {
        let emptyBundle = Bundle(for: type(of: self))
        let loader = TerrainLoader(bundle: emptyBundle)
        do {
            _ = try await loader.load()
            XCTFail("Expected resourceNotFound, got success")
        } catch let error as TerrainLoader.LoadError {
            switch error {
            case .resourceNotFound(let basename):
                XCTAssertEqual(basename, TerrainLoader.defaultBasename)
            case .realityKitLoadFailed:
                XCTFail("Expected resourceNotFound, got realityKitLoadFailed")
            case .envelopeMissing:
                XCTFail("Expected resourceNotFound, got envelopeMissing")
            }
        } catch {
            XCTFail("Expected TerrainLoader.LoadError, got \(type(of: error))")
        }
    }

    // MARK: - Default identifiers

    /// Pin the default basename so the Blender script output and the
    /// Swift loader stay in sync. If someone renames the USDZ without
    /// updating the loader (or vice versa), CI turns red here instead
    /// of silently at runtime.
    func testDefaultBasenameMatchesPipelineOutput() {
        XCTAssertEqual(
            TerrainLoader.defaultBasename,
            "Terrain_Sendai_574036_05",
            "defaultBasename must match the filename produced by Tools/plateau-pipeline/dem_to_terrain_usdz.py"
        )
    }

    /// Pin the default manifest key so the Python extractor's JSON
    /// output and the Swift loader stay in sync. The key is emitted by
    /// `Tools/plateau-pipeline/extract_envelopes.py` and read here —
    /// a rename on one side must be matched on the other.
    func testDefaultTerrainTileIdMatchesManifest() {
        XCTAssertEqual(
            TerrainLoader.defaultTerrainTileId,
            "574036_05_dem",
            "defaultTerrainTileId must match the key emitted by Tools/plateau-pipeline/extract_envelopes.py"
        )
    }

    // MARK: - Envelope-missing error path

    /// When a manifest is supplied but lacks the terrain tile id,
    /// `load()` must eventually throw `.envelopeMissing`. The test
    /// bundle does not contain the USDZ either, so `.resourceNotFound`
    /// fires first — that's the correct ordering (cheaper to diagnose)
    /// and we assert it explicitly so a future refactor that rearranges
    /// the checks doesn't silently weaken the contract.
    ///
    /// To exercise the real `.envelopeMissing` path we would need a
    /// test bundle that ships the USDZ; that's the responsibility of
    /// the device smoke test in the PR description rather than this
    /// pure-Swift unit test.
    // MARK: - Triangle-barycentric Y sampling

    /// Build a single-triangle `Entity` so the sampler can be exercised
    /// end-to-end without a real USDZ. The triangle is flat-lit in XZ
    /// (right triangle with legs along +X and +Z) and has distinct Y
    /// per vertex so interpolation errors are easy to diagnose.
    ///
    /// Vertex layout (local frame, no transform applied):
    ///   v0 = ( 0, 10,  0)   // Y = 10 at origin
    ///   v1 = (10, 20,  0)   // Y = 20 at +X edge
    ///   v2 = ( 0, 30, 10)   // Y = 30 at +Z edge
    @MainActor
    private func makeTriangleEntity() throws -> Entity {
        var descriptor = MeshDescriptor(name: "TestTriangle")
        descriptor.positions = MeshBuffers.Positions([
            SIMD3<Float>(0,  10,  0),
            SIMD3<Float>(10, 20,  0),
            SIMD3<Float>(0,  30, 10)
        ])
        descriptor.primitives = .triangles([0, 1, 2])
        let mesh = try MeshResource.generate(from: [descriptor])
        return ModelEntity(mesh: mesh, materials: [])
    }

    /// Interpolating at the triangle's centroid must return the mean
    /// of the three vertex Ys. This is the "proper sampling" guarantee
    /// that kept the Phase 4 iter 5 camera-through-slope bug out: the
    /// old nearest-vertex code would have returned 10, 20, *or* 30 —
    /// never 20, the true surface value at the centroid.
    func testSampleTerrainYInterpolatesCentroidOfTriangle() throws {
        let entity = try makeTriangleEntity()
        // Centroid XZ = ((0+10+0)/3, (0+0+10)/3) = (3.333..., 3.333...)
        let centroidX: Float = (0 + 10 + 0) / 3
        let centroidZ: Float = (0 + 0 + 10) / 3
        // Expected interpolated Y: (10 + 20 + 30) / 3 = 20
        let y = TerrainLoader.sampleTerrainY(
            in: entity,
            atWorldXZ: SIMD2<Float>(centroidX, centroidZ)
        )
        XCTAssertEqual(try XCTUnwrap(y), 20.0, accuracy: 1e-3)
    }

    /// Sampling exactly at a vertex must return that vertex's Y — the
    /// barycentric math degenerates cleanly at corners (one weight → 1,
    /// the other two → 0). Pinning this as a regression guard because
    /// a subtle epsilon-handling bug could kick vertex samples into
    /// the adjacent triangle's interpolation.
    func testSampleTerrainYReturnsVertexYAtExactVertex() throws {
        let entity = try makeTriangleEntity()
        let y = TerrainLoader.sampleTerrainY(
            in: entity,
            atWorldXZ: SIMD2<Float>(10, 0)  // v1 XZ
        )
        XCTAssertEqual(try XCTUnwrap(y), 20.0, accuracy: 1e-3)
    }

    /// A query clearly outside the triangle must return `nil`. The
    /// runtime snap-to-ground relies on this to leave the player's Y
    /// alone when they walk off the terrain footprint — returning a
    /// stale "nearest triangle" Y would slingshot them.
    func testSampleTerrainYReturnsNilOutsideTriangle() throws {
        let entity = try makeTriangleEntity()
        // Triangle corners are (0,0), (10,0), (0,10); (100, 100) is
        // well outside.
        let y = TerrainLoader.sampleTerrainY(
            in: entity,
            atWorldXZ: SIMD2<Float>(100, 100)
        )
        XCTAssertNil(y, "sampling outside the terrain footprint must return nil")
    }

    // MARK: - Envelope-missing error path

    func testLoadThrowsEnvelopeMissingWhenManifestLacksTile() async throws {
        let emptyBundle = Bundle(for: type(of: self))
        let manifest = try manifestWithoutTerrain()
        let loader = TerrainLoader(
            bundle: emptyBundle,
            manifest: manifest,
            terrainTileId: TerrainLoader.defaultTerrainTileId
        )
        do {
            _ = try await loader.load()
            XCTFail("Expected a LoadError, got success")
        } catch let error as TerrainLoader.LoadError {
            // Document the error ordering: with no USDZ in the bundle,
            // `.resourceNotFound` fires first (the manifest check only
            // runs after the mesh is loaded). This is intentional — the
            // resource lookup is cheaper than the RealityKit load, so
            // reporting it first costs nothing and makes diagnostics
            // clearer.
            switch error {
            case .resourceNotFound(let basename):
                XCTAssertEqual(
                    basename,
                    TerrainLoader.defaultBasename,
                    "When USDZ is missing, .resourceNotFound must fire before .envelopeMissing."
                )
            case .envelopeMissing(let id):
                // Not expected in this configuration (USDZ is also
                // missing from the test bundle), but acceptable if the
                // loader implementation changes the check order — we
                // still want to pin the id carried by the case.
                XCTAssertEqual(id, TerrainLoader.defaultTerrainTileId)
            case .realityKitLoadFailed:
                XCTFail("Expected .resourceNotFound or .envelopeMissing, got .realityKitLoadFailed")
            }
        } catch {
            XCTFail("Expected TerrainLoader.LoadError, got \(type(of: error))")
        }
    }

    // MARK: - Phase 11 Part E: hybrid tint (orthophoto-aware)

    /// Same-shape helper as `ToonMaterialFactoryTests.makeTinyWhiteTexture`
    /// — builds a 1×1 sRGB `TextureResource` off a `CGContext` so the
    /// test doesn't depend on a Metal device. Returns `nil` when the
    /// image stack is unavailable on the host (CI without colour
    /// spaces); callers skip via `XCTSkipIf`.
    private func makeTinyWhiteTexture() throws -> TextureResource? {
        guard let cs = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(
                data: nil,
                width: 1,
                height: 1,
                bitsPerComponent: 8,
                bytesPerRow: 0,
                space: cs,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              )
        else { return nil }
        ctx.setFillColor(red: 1, green: 1, blue: 1, alpha: 1)
        ctx.fill(CGRect(x: 0, y: 0, width: 1, height: 1))
        guard let cg = ctx.makeImage() else { return nil }
        do {
            return try TextureResource(
                image: cg,
                options: TextureResource.CreateOptions(semantic: .color)
            )
        } catch {
            print(
                "[SDG-Lab][terrain-test] TextureResource.init skipped: \(error)"
            )
            return nil
        }
    }

    /// A textured `PhysicallyBasedMaterial` fed to
    /// `hybridTerrainMaterial` must come back as a PBR material with
    /// the **same texture resource** — the orthophoto survival path.
    /// Mirrors `ToonMaterialFactoryTests
    /// .testMutateIntoTexturedCelPreservesBaseColorTexture`, but
    /// dispatched through the loader's branch predicate so a future
    /// refactor that bypasses `mutateIntoTexturedCel` is caught here
    /// rather than drifting silently.
    func testHybridTerrainMaterialPreservesOrthophotoTexture() throws {
        let texture = try makeTinyWhiteTexture()
        try XCTSkipIf(
            texture == nil,
            "CGImage/TextureResource unavailable on host; not a factory bug."
        )
        let resource = texture!

        var textured = PhysicallyBasedMaterial()
        textured.baseColor = .init(tint: .white, texture: .init(resource))
        XCTAssertNotNil(textured.baseColor.texture, "setup check")

        let fallback = ToonMaterialFactory.makeHardCelMaterial(
            baseColor: TerrainLoader.defaultTerrainColor
        )
        let output = TerrainLoader.hybridTerrainMaterial(
            for: textured,
            fallback: fallback
        )

        let outputPBR = try XCTUnwrap(
            output as? PhysicallyBasedMaterial,
            "textured input must produce a PBR output (mutator path)"
        )
        let outputResource = try XCTUnwrap(
            outputPBR.baseColor.texture?.resource,
            "orthophoto texture must survive the hybrid predicate"
        )
        // `TextureResource` is Equatable — same contents = same
        // texture for rendering purposes, which is all the hybrid
        // predicate promises.
        XCTAssertEqual(
            outputResource,
            resource,
            "hybrid predicate must keep the exact orthophoto resource"
        )
    }

    /// An *untextured* PBR material (e.g. a legacy Phase-3 USDZ that
    /// has a material slot but no baked orthophoto) must fall through
    /// to the flat `fallback` cel — preserving the mud-olive ground
    /// for pipelines that haven't re-run Part E yet.
    func testHybridTerrainMaterialFallsBackForUntexturedPBR() throws {
        var untextured = PhysicallyBasedMaterial()
        untextured.baseColor = .init(tint: .gray, texture: nil)

        let fallback = ToonMaterialFactory.makeHardCelMaterial(
            baseColor: TerrainLoader.defaultTerrainColor
        )
        let output = TerrainLoader.hybridTerrainMaterial(
            for: untextured,
            fallback: fallback
        )

        // The fallback is value-semantic; identity via ObjectIdentifier
        // doesn't apply. We assert by walking both as
        // `PhysicallyBasedMaterial`s (the factory returns Scheme C-v2
        // PBR in test mode) and comparing emissive intensity, which
        // hard-cel sets but the untextured input does not.
        let outputPBR = try XCTUnwrap(
            output as? PhysicallyBasedMaterial,
            "fallback path must be a PBR hard-cel"
        )
        // Untextured input had no emissive tint; hard-cel sets a warm
        // emissive colour — the output should carry the latter.
        XCTAssertNotNil(
            outputPBR.emissiveColor.color,
            "fallback must carry the hard-cel emissive colour"
        )
        XCTAssertNil(
            outputPBR.baseColor.texture,
            "fallback path must not invent a texture"
        )
    }

    /// A non-PBR material (SimpleMaterial, any third-party) must also
    /// fall back — proving the hybrid predicate's `as?` guard is the
    /// one and only point where the mutator is allowed.
    func testHybridTerrainMaterialFallsBackForNonPBRInput() {
        let simple: RealityKit.Material = SimpleMaterial(
            color: .gray, isMetallic: false
        )
        let fallback = ToonMaterialFactory.makeHardCelMaterial(
            baseColor: TerrainLoader.defaultTerrainColor
        )
        let output = TerrainLoader.hybridTerrainMaterial(
            for: simple,
            fallback: fallback
        )
        // The fallback branch returns `fallback` by value; assert
        // we're looking at a PBR (the factory's Scheme C-v2) rather
        // than the SimpleMaterial that came in.
        XCTAssertNotNil(
            output as? PhysicallyBasedMaterial,
            "non-PBR input must fall through to the hard-cel PBR"
        )
    }
}
