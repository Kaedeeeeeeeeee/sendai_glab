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
}
