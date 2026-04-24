// PortalEntity.swift
// SDGGameplay · World
//
// Phase 9 Part F — Interior scene MVP.
//
// Builds the outdoor half of the portal pair: a visible rectangular
// frame on the PLATEAU corridor with a `LocationTransitionComponent`
// attached. The indoor half is built inside `InteriorSceneBuilder`
// (so that a single call produces the entire lab scene including its
// exit marker) — the two live in separate files because their shapes,
// materials, and lifecycles diverge:
//
// * The outdoor portal is a free-standing frame spawned via
//   `makeOutdoorPortal(at:)` at scene bootstrap, kept alive for the
//   whole session.
// * The indoor portal is baked into the lab interior and enabled /
//   disabled together with the rest of the room via `isEnabled`.
//
// Keeping both kinds in one factory would imply they could be swapped;
// they can't — the target-scene semantics differ.

import Foundation
import RealityKit

/// Namespace for portal entity construction.
public enum PortalEntity {

    /// Radius of the trigger approximation the Store checks against.
    /// Exposed via a `@MainActor` computed property so the builder and
    /// `SceneTransitionStore` can agree on the visible portal frame
    /// being roughly the same size as the trigger zone (slight over-
    /// sizing is fine; the Store owns the exact number). Computed
    /// rather than stored because `SceneTransitionStore.triggerRadius`
    /// is itself MainActor-isolated.
    @MainActor
    public static var outdoorPortalTriggerRadius: Float {
        SceneTransitionStore.triggerRadius
    }

    /// Dimensions of the visible frame, metres. 2 m tall matches the
    /// task spec. Width = 1.5 m so the frame reads as a doorway rather
    /// than a window.
    public static let frameHeight: Float = 2.0
    public static let frameWidth: Float = 1.5
    public static let frameDepth: Float = 0.1

    /// Thickness of the four visible frame pieces, metres. 0.15 m is
    /// chunky enough to read at a distance without eating the
    /// doorway's walkable width.
    public static let frameBarThickness: Float = 0.15

    /// Build the outdoor-side portal at the given world position.
    ///
    /// The returned entity is a root with four box children that
    /// together form a rectangular frame standing upright on its base.
    /// `LocationTransitionComponent` is attached to the root so the
    /// proximity tick can find it via a single
    /// `EntityQuery(where: .has(LocationTransitionComponent.self))`.
    ///
    /// - Parameters:
    ///   - worldPosition: Centre of the frame's base. Caller is
    ///     responsible for placing this on the DEM surface (RootView
    ///     does this via `TerrainLoader.sampleTerrainY`).
    ///   - targetScene: Scene id the portal warps into. Defaults to
    ///     the canonical lab room.
    ///   - spawnPointInTarget: World-space point inside the target
    ///     scene where the player materialises. RootView computes this
    ///     relative to `InteriorSceneBuilder.defaultIndoorSpawnPoint`.
    ///   - frameColor: RGB tint for the frame material. Saturated so
    ///     the portal reads at a distance against the earthy DEM.
    /// - Returns: A root `Entity` already positioned at `worldPosition`.
    @MainActor
    public static func makeOutdoorPortal(
        at worldPosition: SIMD3<Float>,
        targetScene: LocationKind = .indoor(sceneId: InteriorSceneBuilder.defaultSceneId),
        spawnPointInTarget: SIMD3<Float>,
        frameColor: SIMD3<Float> = SIMD3<Float>(0.85, 0.35, 0.20)
    ) -> Entity {
        let root = Entity()
        root.name = "OutdoorPortal"
        root.position = worldPosition

        // Frame material — warm saturated orange so the portal pops
        // visually against the corridor's earthy palette. HardCel so
        // the visual language matches PLATEAU + terrain.
        let material = ToonMaterialFactory.makeHardCelMaterial(
            baseColor: frameColor
        )

        // Four box children forming the frame outline (left post,
        // right post, lintel, threshold). The threshold is thin so
        // players can walk through without a lip; left here for visual
        // completeness. Positions are in the root's local frame, so
        // the frame centre ends up at `worldPosition` regardless of
        // any later reparenting.
        let halfW = frameWidth / 2
        let halfH = frameHeight / 2
        let bar = frameBarThickness

        // Left post
        let left = ModelEntity(
            mesh: .generateBox(
                size: SIMD3<Float>(bar, frameHeight, frameDepth)
            ),
            materials: [material]
        )
        left.name = "OutdoorPortal.left"
        left.position = SIMD3<Float>(-halfW + bar / 2, halfH, 0)
        root.addChild(left)

        // Right post
        let right = ModelEntity(
            mesh: .generateBox(
                size: SIMD3<Float>(bar, frameHeight, frameDepth)
            ),
            materials: [material]
        )
        right.name = "OutdoorPortal.right"
        right.position = SIMD3<Float>(halfW - bar / 2, halfH, 0)
        root.addChild(right)

        // Lintel (top)
        let top = ModelEntity(
            mesh: .generateBox(
                size: SIMD3<Float>(frameWidth, bar, frameDepth)
            ),
            materials: [material]
        )
        top.name = "OutdoorPortal.top"
        top.position = SIMD3<Float>(0, frameHeight - bar / 2, 0)
        root.addChild(top)

        // Threshold (bottom). Thinner Y so the player doesn't trip on
        // it visually.
        let bottom = ModelEntity(
            mesh: .generateBox(
                size: SIMD3<Float>(frameWidth, bar * 0.5, frameDepth)
            ),
            materials: [material]
        )
        bottom.name = "OutdoorPortal.bottom"
        bottom.position = SIMD3<Float>(0, bar * 0.25, 0)
        root.addChild(bottom)

        root.components.set(LocationTransitionComponent(
            targetScene: targetScene,
            spawnPointInTarget: spawnPointInTarget
        ))

        return root
    }
}
