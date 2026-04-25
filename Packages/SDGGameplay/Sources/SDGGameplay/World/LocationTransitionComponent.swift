// LocationTransitionComponent.swift
// SDGGameplay · World
//
// Phase 9 Part F — Interior scene MVP.
//
// Marker `Component` for the "portal" entities that trigger a scene
// swap when the player walks up to them. One portal lives on each side
// of the `LabInterior` door (outdoor frame near spawn → indoor floor
// marker on the opposite wall of the lab).
//
// Usage contract:
// 1. `InteriorSceneBuilder` / `PortalEntity.makeOutdoorPortal` attach
//    this component when building their side of the portal pair.
// 2. An external per-frame proximity check (see `SceneTransitionStore`'s
//    `.tickProximity` intent) measures the distance from the player to
//    every portal-tagged entity. On entering the trigger radius, the
//    component's `targetScene` + `spawnPointInTarget` get packaged into
//    a `SceneTransitionStarted` event.
//
// The component is plain data. Transition policy (how big the radius
// is, whether transitions are re-entrant, etc.) lives in the Store.

import Foundation
import RealityKit

/// Data held on a portal entity so the proximity / transition layer can
/// decide where to send the player.
///
/// `Sendable + Codable + Equatable` for the same reasons as
/// `LocationComponent` — test assertions, future persistence, and
/// `EventBus` handoff if we ever wrap the payload in an event.
public struct LocationTransitionComponent: Component, Sendable, Equatable, Codable {

    /// Where the player will end up after crossing this portal.
    public var targetScene: LocationKind

    /// World-space position to teleport the player to inside
    /// `targetScene`. For the outdoor-side portal this is a point
    /// inside the lab (e.g. 1 m in front of the indoor portal marker).
    /// For the indoor-side portal this is a point outside the lab,
    /// typically back on the corridor next to the outdoor frame.
    ///
    /// Stored as `SIMD3<Float>` rather than a node/entity reference so
    /// the component remains value-semantic and Codable.
    public var spawnPointInTarget: SIMD3<Float>

    public init(
        targetScene: LocationKind,
        spawnPointInTarget: SIMD3<Float>
    ) {
        self.targetScene = targetScene
        self.spawnPointInTarget = spawnPointInTarget
    }
}
