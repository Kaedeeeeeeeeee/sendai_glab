// DisasterEvents.swift
// SDGGameplay · Disaster
//
// Phase 8 MVP disaster events. Published by `DisasterStore` on state
// transitions; consumed by `DisasterSystem` (animation) and
// `DisasterAudioBridge` (SFX). Quest-driven triggers (via a
// `disasterOnComplete` JSON field) are deferred to Phase 8.1 — for
// MVP the only producer is the 🌋 / 💧 debug buttons.
//
// All four events are value types with no live-entity references
// (GameEvent contract: `Sendable + Codable`). Deciding *what* to
// animate is the System's job, not the event's.

import Foundation
import SDGCore

// MARK: - Earthquake

/// Fired when an earthquake becomes active. Subscribers:
///
/// * `DisasterSystem`: begins the per-frame tile shake.
/// * `DisasterAudioBridge`: starts the rumble SFX loop.
public struct EarthquakeStarted: GameEvent, Equatable {

    /// Optional binding to the quest / story beat that triggered
    /// this earthquake. `nil` for the debug-button trigger path.
    /// Carried through `EarthquakeEnded` so consumers can correlate
    /// start / end pairs.
    public let questId: String?

    /// Shake amplitude scale, 0.0 → 1.0. The System multiplies a
    /// baseline amplitude (currently 0.3 m) by this value, so 0.5
    /// halves the displacement and 1.0 is the full effect. Out-of-
    /// range values are clamped at the System boundary.
    public let intensity: Float

    /// How long the earthquake lasts, in seconds. The Store's tick
    /// loop counts this down and publishes `EarthquakeEnded` at
    /// zero, even if no external stop signal arrives. Keeps audio
    /// loops from running forever if a caller forgets to unwind.
    public let durationSeconds: Float

    public init(questId: String?, intensity: Float, durationSeconds: Float) {
        self.questId = questId
        self.intensity = intensity
        self.durationSeconds = durationSeconds
    }
}

/// Fired when the Store's earthquake timer reaches zero, or when a
/// caller explicitly cancels the earthquake. Subscribers:
///
/// * `DisasterSystem`: restores tiles to their initial position.
/// * `DisasterAudioBridge`: stops the rumble SFX.
public struct EarthquakeEnded: GameEvent, Equatable {
    public let questId: String?
    public init(questId: String?) { self.questId = questId }
}

// MARK: - Flood

/// Fired when a flood starts rising. The target water elevation is
/// supplied by the caller (typically the debug button picks
/// `playerY + 2 m`; quest-driven triggers in Phase 8.1 will read
/// it from the quest manifest).
public struct FloodStarted: GameEvent, Equatable {
    public let questId: String?

    /// World-space Y (metres) where the water plane settles after
    /// the rise finishes. Measured in RealityKit coordinates so the
    /// Store doesn't need to know about envelope alignment.
    public let targetWaterY: Float

    /// Seconds to lerp from the plane's current Y to `targetWaterY`.
    /// The Store advances a normalised progress each tick; the
    /// System reads it for the actual plane position.
    public let riseSeconds: Float

    public init(
        questId: String?,
        targetWaterY: Float,
        riseSeconds: Float
    ) {
        self.questId = questId
        self.targetWaterY = targetWaterY
        self.riseSeconds = riseSeconds
    }
}

/// Fired when the flood's rise phase completes (progress reaches
/// 1.0). MVP does not model a drain / recession phase — the water
/// plane stays at `targetWaterY` until the Store is reset.
public struct FloodEnded: GameEvent, Equatable {
    public let questId: String?
    public init(questId: String?) { self.questId = questId }
}
