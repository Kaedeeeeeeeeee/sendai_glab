// TerrainComponent.swift
// SDGGameplay · World
//
// Marker component attached by `TerrainLoader` to the root of the
// PLATEAU DEM entity. Exists so ECS systems can find the terrain
// in a scene-agnostic way:
//
//     let q = EntityQuery(where: .has(TerrainComponent.self))
//     for terrain in context.entities(matching: q, updatingSystemWhen: .rendering) {
//         ...sample against terrain's mesh...
//     }
//
// `PlayerControlSystem` uses this marker to ground-follow the player —
// every frame it looks up the terrain entity, calls
// `TerrainLoader.sampleTerrainY(in:atWorldXZ:)`, and snaps the player's
// Y to the surface.
//
// ### Why not `scene.raycast`
//
// The first ground-follow prototype (PR #12 iter 1) used
// `scene.raycast(origin:direction:length:query:mask:relativeTo:)`
// against the collision shapes that `Entity.generateCollisionShapes`
// attaches. Device playtest found the raycast reliably returned no
// hits — the player floated at spawn Y forever. Mesh-vertex sampling
// of the decimated DEM (15 K verts → ~0.2 ms on M-series) is cheap
// enough to do per frame and doesn't depend on the collision world
// ticking or on the mask configuration being "right" whatever that
// means. Marker + direct sampling is the pragmatic choice.

import RealityKit

/// Tag component for "this entity is the DEM terrain". Empty on
/// purpose — presence alone is the signal. The component is
/// `Codable + Sendable` via RealityKit's default conformance so it
/// plays nicely with Scene persistence / networking, though Phase 4
/// doesn't exercise either.
public struct TerrainComponent: Component {
    public init() {}
}
