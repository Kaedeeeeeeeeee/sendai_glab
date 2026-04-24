// SceneTransitionEvents.swift
// SDGGameplay · World
//
// Phase 9 Part F — Interior scene MVP.
//
// Two events announcing the lifecycle of a portal-triggered scene swap.
// Both travel on the shared `EventBus` (ADR-0001 / ADR-0003) so any
// subscriber — AudioBridge stubs, future analytics, the RootView
// integration handler — can react without coupling to the Store.
//
// For the MVP there is no intermediate "transitioning" animation, so
// `Started` and `Ended` fire back-to-back in the same intent handler.
// The split is kept because a future Phase 9.x polish pass will almost
// certainly want a fade-to-black cover between the two.
//
// GameEvent conformance (Sendable + Codable) is satisfied by the plain
// value-type fields. `Equatable` is added for test assertions; without
// it every test that records the payload would need to reach into its
// individual fields.

import Foundation
import SDGCore

/// Fired the moment a transition is committed (state flips, player
/// gets teleported, lab entity's `isEnabled` flips).
///
/// Subscribers:
/// * Phase 9 MVP: none. The handler inside `RootView.bootstrap()` does
///   the scene-graph mutation directly after publishing — keeping the
///   event around gives us a place to plug in a future fade overlay
///   without rewiring callers.
/// * Future: fade overlay, audio stinger.
public struct SceneTransitionStarted: GameEvent, Equatable {

    /// Where the player was before the transition. Carried so a
    /// multi-phase transition (fade-out → teardown → fade-in) can use
    /// the same value in both halves without consulting the Store.
    public let from: LocationKind

    /// Where the player ends up. Equal to the target portal's
    /// `LocationTransitionComponent.targetScene`.
    public let to: LocationKind

    /// Target-scene spawn point, copied from the portal's component so
    /// the subscriber doesn't have to query the Store again.
    public let spawnPoint: SIMD3<Float>

    public init(
        from: LocationKind,
        to: LocationKind,
        spawnPoint: SIMD3<Float>
    ) {
        self.from = from
        self.to = to
        self.spawnPoint = spawnPoint
    }
}

/// Fired when the transition finishes and the player is "settled" in
/// the new scene. For the MVP this is published synchronously after
/// `Started` (no animation to wait on).
///
/// Subscribers:
/// * Phase 9 MVP: none.
/// * Future: HUD "you are now in [X]" toast, quest auto-complete hooks.
public struct SceneTransitionEnded: GameEvent, Equatable {

    /// The scene the player is now in. Matches the most recent
    /// `SceneTransitionStarted.to`.
    public let at: LocationKind

    public init(at: LocationKind) {
        self.at = at
    }
}
