// InteriorSceneBuilder.swift
// SDGGameplay · World
//
// Phase 9 Part F — Interior scene MVP.
//
// Builds the `LabInterior` procedural room: a 10 × 4 × 8 m box (floor,
// four walls, ceiling), one placeholder workbench, and the indoor
// portal marker. Everything is parented under a single `Entity` named
// `LabInterior` so RootView can show/hide the whole scene with a
// single `isEnabled` flip.
//
// ## Why a procedural builder (and not a USDZ)
//
// The MVP explicitly wants the indoor scene *not* to block on asset
// authoring. Shipping a procedural box room buys us:
//   * Zero new asset dependencies (AGENTS.md §"small changes"),
//   * Deterministic, testable geometry — we can assert the room size
//     + wall count in unit tests without loading a file,
//   * Clear evolution path: replace this with a USDZ-backed loader
//     later by swapping the builder out. All existing wiring (portal
//     component, hide/show) stays identical.
//
// ## Coordinate convention
//
// Lab-local space with origin at the room's horizontal centre, floor
// at Y = 0, ceiling at Y = `roomHeight`. Indoor portal marker is on
// the far -Z wall (opposite side from the player's natural spawn),
// matching the task spec's "walk back to the door to exit". The
// builder keeps this local — RootView translates the whole lab to
// wherever it wants to hide / show it.

import Foundation
import RealityKit

/// Namespace for procedural interior scene construction.
///
/// `@MainActor` not on the type itself because most helpers build
/// pure `MeshResource` values; `build()` needs MainActor for
/// `ModelEntity` / `ToonMaterialFactory` and is marked explicitly.
public enum InteriorSceneBuilder {

    // MARK: - Dimensions

    /// Scene id baked into `LocationKind.indoor(sceneId:)` for the
    /// MVP's one-and-only interior. Matches the task spec.
    public static let defaultSceneId: String = "lab"

    /// Room width (X), metres.
    public static let roomWidth: Float = 10

    /// Room height (Y), metres. 4 m = 1.5× the standard office to
    /// accommodate the camera at head height without feeling
    /// oppressive on first entry.
    public static let roomHeight: Float = 4

    /// Room depth (Z), metres.
    public static let roomDepth: Float = 8

    /// Thickness of floor / walls / ceiling slabs. 0.2 m so each
    /// surface reads as a thin plate in close-up but still has enough
    /// volume to show cel-shaded highlights.
    public static let shellThickness: Float = 0.2

    /// Where RootView is expected to teleport the player when they
    /// enter the lab from outside. Local to the lab root — i.e. if
    /// the lab itself is offset, RootView adds the offset before
    /// assigning to the player.
    ///
    /// Value chosen to sit ~1.5 m inside the front (+Z) wall so the
    /// player spawns facing the room rather than at the door.
    public static var defaultIndoorSpawnPoint: SIMD3<Float> {
        SIMD3<Float>(0, 0.1, roomDepth / 2 - 1.5)
    }

    /// Where RootView is expected to teleport the player when they
    /// leave the lab. World-space fallback if the portal happens to
    /// be destroyed before the proximity tick runs — in practice
    /// RootView supplies the exact outdoor spawn via the portal's
    /// own `LocationTransitionComponent`, so this only matters as a
    /// "what should the lab remember" default. Lab-local space.
    public static var defaultIndoorPortalSpawn: SIMD3<Float> {
        SIMD3<Float>(0, 0.1, -roomDepth / 2 + 1.5)
    }

    // MARK: - Palette

    /// Floor tint: warm dark grey.
    public static let floorColor = SIMD3<Float>(0.35, 0.30, 0.28)

    /// Ceiling tint: pale cream.
    public static let ceilingColor = SIMD3<Float>(0.90, 0.88, 0.82)

    /// Four wall tints — distinct enough that players can tell which
    /// wall they're facing from the cel-shaded cue alone.
    public static let wallColors: [SIMD3<Float>] = [
        SIMD3<Float>(0.55, 0.65, 0.80),   // +X — cool blue
        SIMD3<Float>(0.80, 0.60, 0.55),   // -X — warm terracotta
        SIMD3<Float>(0.55, 0.75, 0.55),   // +Z — sage green (door wall)
        SIMD3<Float>(0.75, 0.70, 0.45)    // -Z — mustard (back wall)
    ]

    /// Workbench top tint: neutral wood.
    public static let workbenchColor = SIMD3<Float>(0.62, 0.48, 0.34)

    /// Indoor portal marker tint: matches the outdoor frame colour so
    /// the two read as "the same door seen from opposite sides".
    public static let portalMarkerColor = SIMD3<Float>(0.85, 0.35, 0.20)

    // MARK: - Build

    /// Build the lab interior as a single parented `Entity`.
    ///
    /// The returned entity is positioned at the origin; RootView is
    /// expected to translate it to wherever the lab should "live" in
    /// world space. Toggling visibility via `entity.isEnabled` flips
    /// the whole room (walls + workbench + indoor portal) atomically.
    ///
    /// - Parameter outdoorSpawnPoint: World-space point the indoor
    ///   portal warps the player back to on exit. This value is
    ///   baked into the portal's `LocationTransitionComponent`. For
    ///   tests a zero vector is fine; RootView passes a real point
    ///   near the outdoor frame.
    /// - Returns: Root Entity named `LabInterior`.
    @MainActor
    public static func build(
        outdoorSpawnPoint: SIMD3<Float> = .zero
    ) -> Entity {
        let root = Entity()
        root.name = "LabInterior"

        // Shell: floor, ceiling, four walls. Each is a thin flat box.
        addShellSlab(
            to: root,
            size: SIMD3<Float>(roomWidth, shellThickness, roomDepth),
            position: SIMD3<Float>(0, -shellThickness / 2, 0),
            color: floorColor,
            name: "LabInterior.floor"
        )
        addShellSlab(
            to: root,
            size: SIMD3<Float>(roomWidth, shellThickness, roomDepth),
            position: SIMD3<Float>(0, roomHeight + shellThickness / 2, 0),
            color: ceilingColor,
            name: "LabInterior.ceiling"
        )
        addShellSlab(
            to: root,
            size: SIMD3<Float>(shellThickness, roomHeight, roomDepth),
            position: SIMD3<Float>(roomWidth / 2 + shellThickness / 2, roomHeight / 2, 0),
            color: wallColors[0],
            name: "LabInterior.wall.posX"
        )
        addShellSlab(
            to: root,
            size: SIMD3<Float>(shellThickness, roomHeight, roomDepth),
            position: SIMD3<Float>(-roomWidth / 2 - shellThickness / 2, roomHeight / 2, 0),
            color: wallColors[1],
            name: "LabInterior.wall.negX"
        )
        addShellSlab(
            to: root,
            size: SIMD3<Float>(roomWidth, roomHeight, shellThickness),
            position: SIMD3<Float>(0, roomHeight / 2, roomDepth / 2 + shellThickness / 2),
            color: wallColors[2],
            name: "LabInterior.wall.posZ"
        )
        addShellSlab(
            to: root,
            size: SIMD3<Float>(roomWidth, roomHeight, shellThickness),
            position: SIMD3<Float>(0, roomHeight / 2, -roomDepth / 2 - shellThickness / 2),
            color: wallColors[3],
            name: "LabInterior.wall.negZ"
        )

        // Workbench placeholder: a 1.5 × 1 × 0.8 m box. Sits roughly
        // in front of the player's spawn so there's something to look
        // at on entry.
        let workbenchSize = SIMD3<Float>(1.5, 1.0, 0.8)
        let workbench = ModelEntity(
            mesh: .generateBox(size: workbenchSize),
            materials: [ToonMaterialFactory.makeHardCelMaterial(
                baseColor: workbenchColor
            )]
        )
        workbench.name = "LabInterior.workbench"
        workbench.position = SIMD3<Float>(
            0,
            workbenchSize.y / 2,
            0
        )
        root.addChild(workbench)

        // Indoor portal marker: a thin coloured plane on the floor
        // against the -Z wall, with a `LocationTransitionComponent`
        // whose target is `.outdoor`. Players walk onto the plane to
        // trigger the exit transition.
        let marker = makeIndoorPortalMarker(
            outdoorSpawnPoint: outdoorSpawnPoint
        )
        marker.position = SIMD3<Float>(
            0,
            0.05,
            -roomDepth / 2 + 0.8
        )
        root.addChild(marker)

        return root
    }

    // MARK: - Helpers

    /// Build and parent one slab (floor / wall / ceiling piece).
    @MainActor
    private static func addShellSlab(
        to parent: Entity,
        size: SIMD3<Float>,
        position: SIMD3<Float>,
        color: SIMD3<Float>,
        name: String
    ) {
        let entity = ModelEntity(
            mesh: .generateBox(size: size),
            materials: [ToonMaterialFactory.makeHardCelMaterial(
                baseColor: color
            )]
        )
        entity.name = name
        entity.position = position
        parent.addChild(entity)
    }

    /// Build the indoor portal marker: a flat coloured tile with
    /// `LocationTransitionComponent(.outdoor, spawnPointInTarget:)`.
    ///
    /// Exposed `internal` so tests can exercise it without rebuilding
    /// the whole lab.
    @MainActor
    internal static func makeIndoorPortalMarker(
        outdoorSpawnPoint: SIMD3<Float>
    ) -> Entity {
        let root = Entity()
        root.name = "LabInterior.indoorPortalMarker"

        // Visible floor tile — 1.5 × 1.5 m, 10 cm thick (so it pokes
        // above the floor slab enough to be visible).
        let visibleSize = SIMD3<Float>(1.5, 0.1, 1.5)
        let tile = ModelEntity(
            mesh: .generateBox(size: visibleSize),
            materials: [ToonMaterialFactory.makeHardCelMaterial(
                baseColor: portalMarkerColor
            )]
        )
        tile.name = "LabInterior.indoorPortalMarker.tile"
        root.addChild(tile)

        root.components.set(LocationTransitionComponent(
            targetScene: .outdoor,
            spawnPointInTarget: outdoorSpawnPoint
        ))
        return root
    }
}
