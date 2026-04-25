// SceneTransitionStore.swift
// SDGGameplay · World
//
// Phase 9 Part F — Interior scene MVP.
//
// `@Observable` + `@MainActor` state container that tracks which scene
// the player currently inhabits (outdoor PLATEAU corridor vs. a named
// indoor interior) and owns the portal-proximity → transition pipeline.
//
// Why a Store (not just a System):
//   1. The state — "current scene" — is a piece of *UI-observable*
//      gameplay data. A future HUD toast ("you are now in: Lab") will
//      want to bind to it directly; that's a Store's job.
//   2. Transitioning is a pure state-machine problem (flip kind, emit
//      two events). Keeping it out of the render System lets us
//      unit-test the full contract without building a scene graph.
//
// ## Proximity policy (MVP, single trigger path)
//
// `RootView` drives proximity detection per frame by calling
//     `store.intent(.tickProximity(playerPosition:, portals:))`
// with a snapshot of every portal-bearing entity in the current scene
// (there are two: outdoor frame + indoor marker). Passing the snapshot
// in — rather than letting the Store query the scene graph — keeps the
// Store layer-pure (ADR-0001: Stores don't import RealityKit).
//
// The Store compares the snapshot's portal positions against the
// player and fires a transition when:
//   * `isTransitioning` is false (guard against double-firing);
//   * the portal's `targetScene` differs from `currentLocation`
//     (otherwise we'd immediately loop back and forth while the player
//     stood next to the outdoor frame);
//   * the portal lies within `Self.triggerRadius` of the player in
//     world XZ distance (Y ignored so a portal on the ground still
//     triggers for a player whose head is 1.5 m above).
//
// After publishing the `Started`/`Ended` pair the Store sets
// `isTransitioning = true` long enough to drain one more tick — the
// flag is reset by the very next `.tickProximity`. Without that single-
// tick debounce the subscriber in RootView (which teleports the player
// into the portal's `spawnPointInTarget`) would still measure proximity
// to the portal it just used and re-fire a transition in the reverse
// direction on the very next frame.

import Foundation
import Observation
import SDGCore

// MARK: - Intent

/// Public commands the Store accepts.
///
/// `Sendable` on the enum because the intent flows through an
/// `actor`-style dispatch (`Store.intent(_:)` is async) and Swift 6
/// strict concurrency requires each case's associated values to cross
/// isolation safely. The `PortalProximitySnapshot` values are plain
/// SIMD + enum data and satisfy `Sendable` trivially.
public enum SceneTransitionIntent: Sendable {

    /// Directly request a transition, bypassing proximity. Used by
    /// tests and by any future "scripted jump" beat. Idempotent when
    /// already transitioning or already at the target.
    case requestTransition(to: LocationKind, spawnPoint: SIMD3<Float>)

    /// Per-frame proximity check. RootView assembles the snapshot in
    /// the RealityView update closure and forwards it to the Store.
    case tickProximity(
        playerPosition: SIMD3<Float>,
        portals: [PortalProximitySnapshot]
    )

    /// Reset to `.outdoor` without firing any events. Test-only; not
    /// wired from production code.
    case resetForTesting
}

/// Per-portal data the Store needs to evaluate proximity. A value type
/// so the Store doesn't retain any live `Entity` reference and remains
/// trivially testable.
public struct PortalProximitySnapshot: Sendable, Equatable {

    /// Portal entity's world-space position. Only X and Z are consulted
    /// for the distance check, but Y is preserved in case a future
    /// policy wants to care (e.g. second-floor portal that should only
    /// fire when the player is at the matching elevation).
    public var position: SIMD3<Float>

    /// The portal's `LocationTransitionComponent` payload, lifted out
    /// of the component so RootView can build the snapshot from an
    /// entity query without the Store knowing about Components.
    public var transition: LocationTransitionComponent

    public init(
        position: SIMD3<Float>,
        transition: LocationTransitionComponent
    ) {
        self.position = position
        self.transition = transition
    }
}

// MARK: - Store

/// Owns the player's current scene + runs the portal proximity trigger.
///
/// Lifecycle: construct once per RootView bootstrap (same pattern as
/// `DisasterStore`), feed it per-frame ticks, tear down on view
/// disappear. The store does not subscribe to any events itself — it
/// only publishes.
@Observable
@MainActor
public final class SceneTransitionStore: Store {

    public typealias Intent = SceneTransitionIntent

    /// Proximity trigger radius, metres. 2 m matches the "walk up to
    /// the door" feel of the MVP: a portal frame is 2 m tall and
    /// roughly 1 m wide, so a 2 m radius fires when the player is
    /// inside the frame's immediate footprint but not from across the
    /// room. Internal so tests can pin the constant.
    internal static let triggerRadius: Float = 2.0

    /// Squared trigger radius — faster comparison (no sqrt in the
    /// hot path). Derived from `triggerRadius`.
    internal static var triggerRadiusSquared: Float {
        triggerRadius * triggerRadius
    }

    /// The scene the player currently inhabits.
    ///
    /// Observable so any SwiftUI view that binds to the Store redraws
    /// on transition — handy for a future "you are in [X]" HUD.
    public private(set) var currentLocation: LocationKind = .outdoor

    /// True for the single tick immediately after a transition has
    /// been committed. Acts as a one-frame debounce so the portal the
    /// player just used doesn't fire again in the reverse direction on
    /// the very next frame (they spawn 1 m away from the indoor marker
    /// by design; on a 120 Hz tick at 8 m/s they'd still be well
    /// within trigger radius).
    public private(set) var isTransitioning: Bool = false

    /// Event bus for `SceneTransitionStarted` / `SceneTransitionEnded`.
    /// Injected so tests own the bus.
    private let eventBus: EventBus

    public init(eventBus: EventBus) {
        self.eventBus = eventBus
    }

    // MARK: - Store protocol

    public func start() async {
        // No hydration / subscribe in MVP. Scene state resets each
        // session per the Phase 9 Part F task scope.
    }

    public func stop() async {
        // Symmetric with `start`. No subscriptions to cancel.
    }

    // MARK: - Intent

    public func intent(_ intent: SceneTransitionIntent) async {
        switch intent {
        case let .requestTransition(target, spawnPoint):
            await commitTransition(to: target, spawnPoint: spawnPoint)

        case let .tickProximity(playerPosition, portals):
            await handleProximity(
                playerPosition: playerPosition,
                portals: portals
            )

        case .resetForTesting:
            currentLocation = .outdoor
            isTransitioning = false
        }
    }

    // MARK: - Proximity

    /// Scan the snapshot, fire the first portal whose trigger radius
    /// the player has entered and whose `targetScene` differs from the
    /// current location. Only the first match matters — two portals
    /// close enough to both qualify is a level-design bug, and the
    /// store picks a deterministic winner (snapshot order).
    private func handleProximity(
        playerPosition: SIMD3<Float>,
        portals: [PortalProximitySnapshot]
    ) async {
        // Drain the one-tick debounce: if we committed a transition on
        // the previous tick, clear the flag so the next qualifying
        // portal proximity event is allowed. This runs unconditionally
        // before we look for a new match; the net effect is that a
        // transition is always followed by exactly one "grace frame"
        // where no portal fires, even if the player is still inside
        // the original trigger radius.
        if isTransitioning {
            isTransitioning = false
            return
        }

        for portal in portals {
            guard portal.transition.targetScene != currentLocation else {
                continue
            }
            let dx = portal.position.x - playerPosition.x
            let dz = portal.position.z - playerPosition.z
            let distSq = dx * dx + dz * dz
            if distSq <= Self.triggerRadiusSquared {
                await commitTransition(
                    to: portal.transition.targetScene,
                    spawnPoint: portal.transition.spawnPointInTarget
                )
                return
            }
        }
    }

    /// State flip + event publication. Shared by the proximity path
    /// and the direct `.requestTransition` path so they stay in sync.
    private func commitTransition(
        to target: LocationKind,
        spawnPoint: SIMD3<Float>
    ) async {
        // Idempotence: no work if we're already at the target. This
        // matters for `.requestTransition` callers — a scripted jump
        // should not re-play its own events just because the player
        // happened to already be in the target room.
        guard target != currentLocation else { return }

        let previous = currentLocation
        currentLocation = target
        isTransitioning = true

        await eventBus.publish(SceneTransitionStarted(
            from: previous,
            to: target,
            spawnPoint: spawnPoint
        ))
        // MVP: no animation to wait on; `Ended` fires immediately.
        await eventBus.publish(SceneTransitionEnded(at: target))
    }
}
