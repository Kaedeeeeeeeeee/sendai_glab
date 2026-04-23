// PlateauEnvironmentLoaderTests.swift
// SDGGameplay · World · Tests
//
// Unit tests for the loader's *synthesisable* parts — material
// replacement and palette determinism. Full tile loading is an
// integration concern deferred to Phase 2 Beta: `swift test` runs
// host-side where the PLATEAU GLBs aren't available and RealityKit's
// native importers don't cover GLB anyway (see GLBToUSDZConverter
// doc comment for the runtime probe).

import XCTest
import RealityKit
@testable import SDGGameplay

@MainActor
final class PlateauEnvironmentLoaderTests: XCTestCase {

    // MARK: - Palette determinism

    /// Same tile → same colour across calls. Bug reports that say
    /// "the east tile keeps changing shade" would indicate this was
    /// broken, which is why we pin it.
    func testWarmToonColourIsDeterministic() {
        for tile in PlateauTile.allCases {
            let a = PlateauEnvironmentLoader.warmToonColour(for: tile)
            let b = PlateauEnvironmentLoader.warmToonColour(for: tile)
            XCTAssertEqual(a, b, "tile \(tile) returned different colours")
        }
    }

    /// Colour values must fall inside the palette. Catches an
    /// off-by-one where the index modulo math drifts beyond the
    /// palette array and returns uninitialised memory / crashes.
    func testWarmToonColoursBelongToPalette() {
        for tile in PlateauTile.allCases {
            let colour = PlateauEnvironmentLoader.warmToonColour(for: tile)
            XCTAssertTrue(
                PlateauEnvironmentLoader.warmPalette.contains(colour),
                "tile \(tile) returned off-palette colour \(colour)"
            )
        }
    }

    /// Palette itself must contain only warm-ish tones — red >= blue
    /// is the cheap proxy. Would catch a merge where someone dropped
    /// a cool blue in by mistake.
    func testWarmPaletteIsWarm() {
        for colour in PlateauEnvironmentLoader.warmPalette {
            XCTAssertGreaterThanOrEqual(
                colour.x, colour.z,
                "palette entry \(colour) is cool (blue > red)"
            )
        }
    }

    // MARK: - Material replacement

    /// Replacing materials on a lone `ModelEntity` must mutate its
    /// `materials` array in place — not rebuild the entity, not
    /// orphan the mesh. Pins the "we keep the mesh, swap the look"
    /// contract.
    func testApplyToonMaterialReplacesModelEntityMaterials() {
        let mesh = MeshResource.generateBox(size: 1)
        let entity = ModelEntity(
            mesh: mesh,
            materials: [SimpleMaterial(), SimpleMaterial()]
        )

        PlateauEnvironmentLoader.applyToonMaterial(
            toDescendantsOf: entity,
            baseColor: SIMD3<Float>(0.8, 0.6, 0.4)
        )

        let model = entity.components[ModelComponent.self]
        XCTAssertNotNil(model)
        XCTAssertEqual(
            model?.materials.count, 2,
            "material slot count must be preserved"
        )
        // The new materials must be `PhysicallyBasedMaterial` (what
        // `ToonMaterialFactory.makeLayerMaterial` returns today). If
        // we swap to ShaderGraph, this test updates at the same time
        // as the factory does.
        XCTAssertTrue(
            model?.materials.first is PhysicallyBasedMaterial,
            "expected PBR material, got \(type(of: model?.materials.first as Any))"
        )
    }

    /// Walking a nested hierarchy must touch every `ModelComponent`,
    /// not just the root. Nusamai's output is exactly this kind of
    /// nested tree (root Entity → per-mesh ModelEntity children),
    /// so if the walk stops at the root the tile stays grey.
    func testApplyToonMaterialWalksChildren() {
        let root = Entity()
        let mesh = MeshResource.generateBox(size: 1)
        let childA = ModelEntity(mesh: mesh, materials: [SimpleMaterial()])
        let childB = ModelEntity(mesh: mesh, materials: [SimpleMaterial()])
        let grandchild = ModelEntity(mesh: mesh, materials: [SimpleMaterial()])
        root.addChild(childA)
        root.addChild(childB)
        childA.addChild(grandchild)

        PlateauEnvironmentLoader.applyToonMaterial(
            toDescendantsOf: root,
            baseColor: SIMD3<Float>(0.8, 0.6, 0.4)
        )

        for candidate in [childA, childB, grandchild] {
            let mat = candidate.components[ModelComponent.self]?.materials.first
            XCTAssertTrue(
                mat is PhysicallyBasedMaterial,
                "\(candidate.name) still has non-Toon material"
            )
        }
    }

    /// Entities without `ModelComponent` must be skipped silently.
    /// PLATEAU tiles contain empty group entities for layout
    /// purposes; they must not crash the walker.
    func testApplyToonMaterialSkipsEntitiesWithoutModelComponent() {
        let root = Entity()
        let empty = Entity()
        root.addChild(empty)

        // No crash = pass. The function signature is non-throwing
        // and we just want the call to return.
        PlateauEnvironmentLoader.applyToonMaterial(
            toDescendantsOf: root,
            baseColor: .zero
        )

        XCTAssertNil(empty.components[ModelComponent.self])
    }

    // MARK: - Envelope-manifest placement (Phase 4)
    //
    // The placement policy is extracted into the pure-function helper
    // `tilePlacement(tile:manifest:)` so these tests don't need to
    // actually load USDZ files — `loadDefaultCorridor` composes that
    // helper with the USDZ-loading step, and the loading step is
    // already exercised by the integration layer. Driving the helper
    // directly keeps these tests hermetic + fast, and exactly mirrors
    // the information flow the corridor loop uses.

    /// Fixture that mirrors `PlateauTile.allCases` — one envelope per
    /// corridor tile, laid out on the nominal 3rd-mesh grid so the
    /// expected RealityKit positions are easy to reason about.
    ///
    /// Centres in EPSG:6677 (metres):
    /// - `57403617` (spawn, Aobayama campus)     (10000, 21000, 100)
    /// - `57403607` (Aobayama north, 1 km south) (10000, 20000, 100)
    /// - `57403608` (Aobayama castle, SE)        (11250, 20000, 100)
    /// - `57403618` (Kawauchi, E)                (11250, 21000, 100)
    /// - `57403619` (Tohoku Gakuin, EE)          (12500, 21000, 100)
    ///
    /// Each envelope is 1250 × 1000 × 20 m centred on the stated
    /// centre, which is enough for `realityKitPosition(for:)` to round-
    /// trip without floating-point surprises.
    private static let fullCorridorFixtureJSON: String = """
    {
      "meta": {
        "source_crs": "EPSG:6697",
        "target_crs": "EPSG:6677",
        "spawn_tile_id": "57403617",
        "generated_by": "PlateauEnvironmentLoaderTests"
      },
      "envelopes": {
        "57403617": {
          "lower_corner_m": [9375.0,  20500.0,  90.0],
          "upper_corner_m": [10625.0, 21500.0, 110.0]
        },
        "57403607": {
          "lower_corner_m": [9375.0,  19500.0,  90.0],
          "upper_corner_m": [10625.0, 20500.0, 110.0]
        },
        "57403608": {
          "lower_corner_m": [10625.0, 19500.0,  90.0],
          "upper_corner_m": [11875.0, 20500.0, 110.0]
        },
        "57403618": {
          "lower_corner_m": [10625.0, 20500.0,  90.0],
          "upper_corner_m": [11875.0, 21500.0, 110.0]
        },
        "57403619": {
          "lower_corner_m": [11875.0, 20500.0,  90.0],
          "upper_corner_m": [13125.0, 21500.0, 110.0]
        }
      }
    }
    """

    /// Manifest that covers only 3 of the 5 corridor tiles, for the
    /// partial-manifest fallback test. Spawn is still `57403617`.
    private static let partialCorridorFixtureJSON: String = """
    {
      "meta": {
        "spawn_tile_id": "57403617"
      },
      "envelopes": {
        "57403617": {
          "lower_corner_m": [9375.0,  20500.0,  90.0],
          "upper_corner_m": [10625.0, 21500.0, 110.0]
        },
        "57403607": {
          "lower_corner_m": [9375.0,  19500.0,  90.0],
          "upper_corner_m": [10625.0, 20500.0, 110.0]
        },
        "57403618": {
          "lower_corner_m": [10625.0, 20500.0,  90.0],
          "upper_corner_m": [11875.0, 21500.0, 110.0]
        }
      }
    }
    """

    private func makeManifest(jsonString: String) throws -> EnvelopeManifest {
        try EnvelopeManifest(jsonData: Data(jsonString.utf8))
    }

    /// With a full manifest, every tile's placement must come from
    /// `manifest.realityKitPosition(for:)`, centring is skipped, and
    /// the position equals what the manifest returned. Pins the
    /// Phase 4 real-origin path end-to-end at the helper boundary.
    func testCorridorWithManifestPositionsTilesByEnvelope() throws {
        let manifest = try makeManifest(jsonString: Self.fullCorridorFixtureJSON)

        let lift = PlateauEnvironmentLoader.envelopeTileGroundLift
        for tile in PlateauTile.allCases {
            let manifestPos = try XCTUnwrap(
                manifest.realityKitPosition(for: tile.rawValue),
                "fixture missing tile \(tile.rawValue); test setup bug"
            )
            let expected = SIMD3<Float>(
                manifestPos.x,
                manifestPos.y + lift,
                manifestPos.z
            )
            let placement = PlateauEnvironmentLoader.tilePlacement(
                tile: tile,
                manifest: manifest
            )
            XCTAssertEqual(
                placement.position, expected,
                "tile \(tile.rawValue) placement diverged from manifest + ground lift"
            )
            XCTAssertEqual(
                placement.centerMode, .none,
                "tile \(tile.rawValue) must skip centring on the envelope path"
            )
        }

        // Sanity-check one well-known offset end-to-end so a bug in
        // `realityKitPosition` doesn't silently make this test tautological.
        // Kawauchi (57403618) is 1250 m east, same northing → (1250, lift, 0).
        let kawauchi = PlateauEnvironmentLoader.tilePlacement(
            tile: .kawauchiCampus,
            manifest: manifest
        )
        XCTAssertEqual(kawauchi.position.x, 1250.0, accuracy: 1e-3)
        XCTAssertEqual(kawauchi.position.y, lift,  accuracy: 1e-3)
        XCTAssertEqual(kawauchi.position.z,    0.0, accuracy: 1e-3)
    }

    /// Tiles missing from the manifest must fall back to the legacy
    /// `localCenter` + `.bottomSnap` pair, not blow up or end at the
    /// origin. A partial manifest is a pipeline reality — bring-up
    /// sometimes ships envelopes for a subset of tiles while the rest
    /// are still being authored.
    func testCorridorWithPartialManifestFallsBackToLocalCenter() throws {
        let manifest = try makeManifest(jsonString: Self.partialCorridorFixtureJSON)

        let covered: Set<String> = ["57403617", "57403607", "57403618"]

        for tile in PlateauTile.allCases {
            let placement = PlateauEnvironmentLoader.tilePlacement(
                tile: tile,
                manifest: manifest
            )
            if covered.contains(tile.rawValue) {
                let manifestPos = try XCTUnwrap(
                    manifest.realityKitPosition(for: tile.rawValue)
                )
                let expected = SIMD3<Float>(
                    manifestPos.x,
                    manifestPos.y + PlateauEnvironmentLoader.envelopeTileGroundLift,
                    manifestPos.z
                )
                XCTAssertEqual(
                    placement.position, expected,
                    "covered tile \(tile.rawValue) must use manifest position + ground lift"
                )
                XCTAssertEqual(placement.centerMode, .none)
            } else {
                XCTAssertEqual(
                    placement.position, tile.localCenter,
                    "uncovered tile \(tile.rawValue) must fall back to localCenter"
                )
                XCTAssertEqual(
                    placement.centerMode, .bottomSnap,
                    "uncovered tile \(tile.rawValue) must bottom-snap on the fallback path"
                )
            }
        }
    }

    /// Regression guard: calling `loadDefaultCorridor()` without a
    /// manifest — the default — must still pin every tile to its
    /// `localCenter` and bottom-snap, preserving Phase 2 Alpha
    /// behaviour for any caller that hasn't opted in to Phase 4.
    func testCorridorWithoutManifestUsesLegacyPath() {
        for tile in PlateauTile.allCases {
            let placement = PlateauEnvironmentLoader.tilePlacement(
                tile: tile,
                manifest: nil
            )
            XCTAssertEqual(
                placement.position, tile.localCenter,
                "legacy path must place \(tile.rawValue) at its localCenter"
            )
            XCTAssertEqual(
                placement.centerMode, .bottomSnap,
                "legacy path must bottom-snap \(tile.rawValue)"
            )
        }
    }

    // MARK: - Phase 5 adaptive ground snap

    /// Build a minimal entity with a 20 m cube mesh at a given world
    /// position. Its visualBounds.min.y after placement is
    /// `position.y - 10`, which we use to verify the adaptive snap
    /// math lands the mesh bottom exactly where we expect.
    @MainActor
    private func makeCubeEntity(at worldY: Float) -> Entity {
        let entity = ModelEntity(
            mesh: .generateBox(size: 20),
            materials: [SimpleMaterial()]
        )
        entity.position = SIMD3<Float>(0, worldY, 0)
        return entity
    }

    /// Adaptive snap shifts the tile so its bounds.min.y sits exactly
    /// `basementSkip` above the sampled DEM Y. This is the Phase 5
    /// replacement for the Phase 4 `envelopeTileGroundLift` global
    /// constant — per-tile, data-driven. Uses a non-default skip to
    /// prove the parameter is respected.
    func testAdaptiveGroundSnapLandsMeshBottomOnDemPlusSkip() {
        // A 20 m cube at y=100 → world bounds.min.y = 90, max.y = 110
        let tile = makeCubeEntity(at: 100)
        // Sampler returns Y = 50 at any XZ.
        let sampler: PlateauEnvironmentLoader.TerrainHeightSampler = { _ in 50 }
        PlateauEnvironmentLoader.adaptiveGroundSnap(
            tile: tile,
            terrainSampler: sampler,
            basementSkip: 2.0
        )
        // After snap: mesh bottom at demY + skip = 50 + 2 = 52.
        // Cube is 20 m tall centred on position.y, so position.y = 52 + 10 = 62.
        XCTAssertEqual(tile.position.y, 62.0, accuracy: 1e-3)
        let bounds = tile.visualBounds(relativeTo: nil)
        XCTAssertEqual(bounds.min.y, 52.0, accuracy: 1e-3)
    }

    /// When the sampler returns nil (query outside terrain footprint),
    /// the tile's position must stay untouched — leaving a stale snap
    /// from an earlier frame would slingshot the tile.
    func testAdaptiveGroundSnapNoOpOnNilSample() {
        let tile = makeCubeEntity(at: 100)
        let startY = tile.position.y
        let sampler: PlateauEnvironmentLoader.TerrainHeightSampler = { _ in nil }
        PlateauEnvironmentLoader.adaptiveGroundSnap(
            tile: tile,
            terrainSampler: sampler,
            basementSkip: 2.0
        )
        XCTAssertEqual(tile.position.y, startY)
    }

    /// Repeating the snap with the same sampler must produce the
    /// exact same position: the algorithm is idempotent because it
    /// works from absolute world bounds, not relative deltas.
    /// Matters for any future scene hot-reload path.
    func testAdaptiveGroundSnapIsIdempotent() {
        let tile = makeCubeEntity(at: 100)
        let sampler: PlateauEnvironmentLoader.TerrainHeightSampler = { _ in 50 }
        PlateauEnvironmentLoader.adaptiveGroundSnap(
            tile: tile,
            terrainSampler: sampler,
            basementSkip: 2.0
        )
        let y1 = tile.position.y
        PlateauEnvironmentLoader.adaptiveGroundSnap(
            tile: tile,
            terrainSampler: sampler,
            basementSkip: 2.0
        )
        XCTAssertEqual(tile.position.y, y1, accuracy: 1e-3)
    }

    /// Pin the basement-skip constant so device tuning can't silently
    /// drift. If a playtest wants a different value it shows up in
    /// the diff. Phase 5 iter 2 walked the default 2 → 0 after "all
    /// buildings floating" feedback.
    func testAdaptiveGroundSnapSkipDefault() {
        XCTAssertEqual(
            PlateauEnvironmentLoader.adaptiveGroundSnapSkip,
            0.0,
            accuracy: 1e-6
        )
    }
}
