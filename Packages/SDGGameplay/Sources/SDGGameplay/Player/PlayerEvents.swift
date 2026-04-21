// PlayerEvents.swift
// SDGGameplay · Player
//
// Cross-layer events fired by `PlayerControlStore` and consumed by
// anyone who needs to react to player motion (HUD minimap, audio,
// analytics, future quest triggers). See ADR-0003 for why events are
// the only sanctioned cross-module channel.
//
// Events are small value types; per ADR-0003 they are `Sendable` +
// `Codable` so debug builds can dump the event stream to disk.

import Foundation
import SDGCore

/// Fired every time the player's *input axis* materially changes —
/// i.e. when the virtual joystick crosses into or out of the dead
/// zone, or when the user switches direction. Not fired every frame;
/// per-frame integration is the `PlayerControlSystem`'s job.
///
/// `axis` is already normalised to the unit disk (`length ≤ 1`). The
/// `y` component uses SwiftUI convention: positive = forward (away
/// from the camera). The `x` component: positive = strafe right.
///
/// Why publish this at all? Subscribers that do not own the
/// player entity (HUD compass arrow, analytics, future NPC awareness
/// Systems) need a way to observe intent without reaching into the
/// ECS. They subscribe here; the Store does the mutation.
public struct PlayerMoveIntentChanged: GameEvent, Equatable {

    /// Horizontal movement axis on the unit disk. `x` = strafe,
    /// `y` = forward. `.zero` means "stick released".
    public let axis: SIMD2<Float>

    public init(axis: SIMD2<Float>) {
        self.axis = axis
    }
}

/// Fired whenever the player look-delta is consumed by the control
/// system; carries the *yaw* and *pitch* the player has just applied
/// (radians) plus the current accumulated pitch so listeners can
/// detect clamping against the vertical look limits.
///
/// Publishing is rate-limited by the Store — we only fire when the
/// system has actually rotated the camera on this frame, not for
/// every touch sample. That keeps the bus quiet when the player
/// isn't looking around.
public struct PlayerLookApplied: GameEvent, Equatable {

    /// Yaw delta applied this frame, radians. Positive = right.
    public let yawDelta: Float

    /// Pitch delta applied this frame *after* clamping, radians.
    /// Positive = look up.
    public let pitchDelta: Float

    /// Accumulated pitch (radians) after this frame's delta. Useful
    /// for HUDs that draw a horizon line.
    public let accumulatedPitch: Float

    public init(yawDelta: Float, pitchDelta: Float, accumulatedPitch: Float) {
        self.yawDelta = yawDelta
        self.pitchDelta = pitchDelta
        self.accumulatedPitch = accumulatedPitch
    }
}
