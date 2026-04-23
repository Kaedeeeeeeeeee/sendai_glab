// PlayerComponents.swift
// SDGGameplay · Player
//
// ECS component types tagging and driving the player entity. Kept as
// plain data per ADR-0001: all behaviour lives in `PlayerControlSystem`.
//
// Two components split the concerns cleanly:
//
//   * `PlayerComponent`      — identity tag. "This entity IS the player."
//   * `PlayerInputComponent` — this frame's desired motion, a moving
//                              target the Store keeps current.
//
// A separate tag for identity is deliberate: query predicates can match
// `.has(PlayerComponent.self) && .has(PlayerInputComponent.self)` so we
// never accidentally drive a non-player entity (e.g. an NPC that also
// ended up with an input component during cutscenes).

import Foundation
import RealityKit

/// Identity tag for the player-controlled entity.
///
/// Primary job is to distinguish the player from NPCs, inventory
/// props, and geology entities in an `EntityQuery`.
///
/// Phase 8.1 added the `isStaggered` flag so the earthquake system
/// can tell `PlayerControlSystem` to dampen input without routing an
/// extra event through the bus every frame. Putting it on the
/// identity tag (rather than on `PlayerInputComponent`) keeps the
/// input component a pure "current frame's desired motion" value —
/// stagger state lives longer than a single frame's input snapshot.
public struct PlayerComponent: Component, Sendable {

    /// `true` while an earthquake is shaking. When set,
    /// `PlayerControlSystem.applyInput` multiplies `moveAxis` by
    /// `Self.staggeredMoveScale` (0.3) so movement feels sluggish —
    /// the player can still walk, but the ground stealing 70 % of
    /// their forward momentum reads as loss of balance. Cleared when
    /// the earthquake state ends.
    public var isStaggered: Bool

    public init(isStaggered: Bool = false) {
        self.isStaggered = isStaggered
    }
}

/// This frame's motion request for the player entity.
///
/// **Semantic contract — read this before touching it:**
///
/// * `moveAxis` is a *persistent* value. Touch input sets it when the
///   finger is down and zeroes it on release. The System re-reads it
///   each frame and treats the vector as "desired forward+strafe
///   velocity in normalised [-1, 1]". Integrating over time is the
///   System's job; the Store is pure state.
///
/// * `lookDelta` is a *one-shot increment*. It accumulates raw pan
///   deltas between frames and is **zeroed by the System** after
///   being applied on each `update(context:)`. Treating it as one-shot
///   matches how mouse/touch delta naturally arrives and prevents the
///   camera from drifting when the finger is stationary.
///
/// Units:
///   * `moveAxis` — dimensionless, `length ≤ 1` after joystick
///     clamping. `x` is strafe (+right), `y` is forward (+forward).
///   * `lookDelta` — radians. `x` rotates yaw (+right), `y` rotates
///     pitch (+up). Callers (e.g. the touch layer in SDGUI) convert
///     from screen-space point deltas to radians via a tunable
///     sensitivity constant; components only see the resolved angle.
///
/// This is a plain struct, not a class, so mutating the component
/// requires the standard RealityKit pattern of read → mutate → write
/// back (see `PlayerControlSystem`).
public struct PlayerInputComponent: Component, Sendable {

    /// Normalised strafe+forward axis. `x` = strafe (+right),
    /// `y` = forward (+forward along the entity's local `-Z`).
    public var moveAxis: SIMD2<Float>

    /// Pending look rotation this frame, in radians. Accumulated by
    /// the Store as touch samples arrive, consumed (zeroed) by the
    /// `PlayerControlSystem` on the next `update(context:)`.
    public var lookDelta: SIMD2<Float>

    public init(
        moveAxis: SIMD2<Float> = .zero,
        lookDelta: SIMD2<Float> = .zero
    ) {
        self.moveAxis = moveAxis
        self.lookDelta = lookDelta
    }
}
