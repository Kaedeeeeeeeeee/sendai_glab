// DisasterComponent.swift
// SDGGameplay · Disaster
//
// ECS markers used by `DisasterSystem` to find its inputs and
// remember their baselines. Two components:
//
//   * `DisasterShakeTargetComponent` — tag entity "I can be shaken
//     by an earthquake". Stores the entity's pre-shake position so
//     the System can both offset from it during the quake and
//     restore it cleanly when the quake ends.
//
//   * `DisasterFloodWaterComponent` — tag the water-plane entity
//     created on the first flood. The System uses this marker both
//     to recognise "flood plane already exists, reuse it" and to
//     look up the plane for each frame's Y lerp.
//
// Both are plain data (ADR-0001: Components hold state, Systems own
// behaviour). RootView registers them at app start via
// `DisasterSystem.registerComponents()`.

import Foundation
import RealityKit

/// Marker that an entity is subject to earthquake shake. Typically
/// attached to each PLATEAU tile root inside the `PlateauCorridor`
/// so the System can shake all five tiles independently — shaking
/// the corridor root would move the player with it (the player's
/// `sceneRefs.playerEntity` is a sibling of the corridor, not a
/// child, so this should be safe, but per-tile shaking also lets
/// the eyes read individual building clusters rocking).
///
/// `initialPosition` is recorded the first time the System sees
/// the entity; that's the canonical pose we restore when the quake
/// ends. Stored here (not in a `@State` somewhere) because the
/// lifecycle of a RealityKit entity is owned by the scene graph,
/// not by the RootView / Store.
public struct DisasterShakeTargetComponent: Component, Sendable, Equatable {

    /// World-space position captured when the System first processed
    /// this entity. `nil` until the first tick with this component
    /// attached; once populated it stays put so repeat earthquakes
    /// all shake around the same baseline rather than drifting.
    public var initialPosition: SIMD3<Float>?

    public init(initialPosition: SIMD3<Float>? = nil) {
        self.initialPosition = initialPosition
    }
}

/// Marker for the flood water plane created on the first
/// `FloodStarted`. The System looks this component up each frame to
/// lerp the plane's Y from `startY` to `targetY` based on the
/// Store's normalised `progress`. Storing `startY` and `targetY` on
/// the component (rather than reading them every frame from the
/// Store) lets the System compute the instant Y with one multiply
/// and without locking the Store.
public struct DisasterFloodWaterComponent: Component, Sendable, Equatable {
    public var startY: Float
    public var targetY: Float

    public init(startY: Float, targetY: Float) {
        self.startY = startY
        self.targetY = targetY
    }
}
