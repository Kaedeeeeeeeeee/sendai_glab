// PlayerControlStore.swift
// SDGGameplay · Player
//
// `@Observable` state container for the player's move + look inputs.
// Sits at the middle layer of the three-layer architecture (ADR-0001):
//
//     SwiftUI (HUD joystick, pan gestures) ──intent──▶ [PlayerControlStore]
//                                                          │
//                                                          │ (MainActor write)
//                                                          ▼
//                           PlayerInputComponent  ◀── [ECS: PlayerControlSystem]
//                           on the player Entity             reads & integrates
//
// Architecture rationale for the Store-writes-Component pattern:
//
//   We considered two alternatives:
//
//     (a) The System pulls from the Store each frame. Requires the
//         System to hold a reference to the Store, which breaks ADR-
//         0001's "ECS must not reference Stores" rule AND couples the
//         System's Scene to a specific Store instance.
//
//     (b) Events-only: Store publishes a `MoveIntent` event, System
//         subscribes and writes the component. Adds latency (an actor
//         hop) for every joystick sample and requires the System to
//         subscribe to the EventBus, which is awkward because Systems
//         have no lifecycle hook for teardown.
//
//   We chose (c): the Store holds a weak reference to the player
//   Entity and writes `PlayerInputComponent` directly on MainActor.
//   The Store never reads back from the component. The System reads
//   the component, updates the entity, and zeroes `lookDelta`. This
//   gives us:
//
//     * Zero cross-layer references: Store → Entity is the view of
//       "player state", not a Store-to-Store or Store-to-System
//       coupling.
//     * Synchronous, lossless input (no event queue drops).
//     * The System stays self-contained; tests can build it without
//       any Store.
//     * Events are still fired (PlayerMoveIntentChanged) for HUD /
//       analytics subscribers that don't own the entity.
//
// `@MainActor` isolation is load-bearing: RealityKit Entity mutations
// must happen on MainActor (see `Entity.position` and friends — every
// mutator is `@_Concurrency.MainActor` isolated in the SDK). The Store
// being `@MainActor` also lines up with SwiftUI `@Observable`'s
// expected usage pattern.

import Foundation
import RealityKit
import SDGCore

/// Observable state container for the player's move + look input.
///
/// Consumers (SwiftUI) call `intent(_:)` with user actions; the Store
/// mutates its own state, forwards the value into the player's
/// `PlayerInputComponent`, and publishes an event for unrelated
/// subscribers (HUD, analytics).
///
/// The Store must be bound to a specific player entity via
/// `attach(playerEntity:)` before any intent that affects motion
/// takes effect in the world. Intents received before the entity is
/// attached update the Store's own state (so the HUD stays consistent)
/// but cannot be applied to the world — this is intentional, not a
/// bug: during app launch the SwiftUI tree may render one frame
/// before RealityKit finishes creating the entity.
@MainActor
@Observable
public final class PlayerControlStore: Store {

    /// Commands the Store accepts. Every user action on the HUD boils
    /// down to one of these four cases.
    public enum Intent: Sendable, Equatable {

        /// The virtual joystick moved. Axis must be on the unit disk
        /// (`length ≤ 1`); the joystick view is responsible for
        /// clamping and dead-zone filtering before handing it here.
        case move(SIMD2<Float>)

        /// A right-half-screen pan delivered a yaw/pitch delta in
        /// radians. Deltas are *added* to the pending look buffer;
        /// the System drains the buffer each frame.
        case look(SIMD2<Float>)

        /// The user lifted their finger off the joystick. Equivalent
        /// to `.move(.zero)` semantically but kept distinct so
        /// subscribers can distinguish "paused" from "actively
        /// centering".
        case stop
    }

    // MARK: - Observable state

    /// Current move axis, already clamped to the unit disk. SwiftUI
    /// views that want to render a trailing joystick indicator read
    /// this directly.
    public private(set) var currentMoveAxis: SIMD2<Float> = .zero

    /// Look delta that has accumulated since the last System update.
    /// Consumers should *not* rely on this for HUD — it is drained to
    /// zero every frame by `PlayerControlSystem`. Exposed for tests.
    public private(set) var pendingLookDelta: SIMD2<Float> = .zero

    // MARK: - Private

    /// The bus we publish outward to. Stored, not looked up, per
    /// AGENTS.md §1.2 (no singletons).
    private let eventBus: EventBus

    /// Weak reference to the player entity. Weak so the Store does
    /// not prevent scene teardown; strong owners are the Scene /
    /// ContentView.
    private weak var playerEntity: Entity?

    // MARK: - Init

    public init(eventBus: EventBus) {
        self.eventBus = eventBus
    }

    // MARK: - Entity binding

    /// Bind the Store to the entity it should drive. Must be called
    /// exactly once, after the entity is added to the scene; calling
    /// a second time quietly replaces the target (useful for tests
    /// and scene reloads, explicit so it isn't a foot-gun).
    public func attach(playerEntity: Entity) {
        self.playerEntity = playerEntity
        // Seed the component so queries can find it even before the
        // first intent fires.
        playerEntity.components.set(PlayerInputComponent())
    }

    /// Drop the entity reference. Called during scene teardown so the
    /// Store does not keep pointing at a dead entity.
    public func detach() {
        playerEntity = nil
    }

    // MARK: - Store protocol

    public func intent(_ intent: Intent) async {
        switch intent {
        case .move(let axis):
            await apply(move: axis)
        case .stop:
            await apply(move: .zero)
        case .look(let delta):
            apply(look: delta)
        }
    }

    // MARK: - Private application

    /// Update `currentMoveAxis`, push it into the entity component,
    /// and publish `PlayerMoveIntentChanged` iff the value actually
    /// changed. The equality guard keeps the bus quiet while the
    /// stick is at rest.
    ///
    /// Awaits the publish so `await intent(.move(...))` implies "every
    /// subscriber has seen this change". Tests depend on that
    /// ordering; the bus's fan-out is concurrent (ADR-0003) so the
    /// await is cheap.
    private func apply(move axis: SIMD2<Float>) async {
        guard axis != currentMoveAxis else { return }
        currentMoveAxis = axis

        // Mirror into the entity component if we're attached. The
        // System reads from the component, not the Store; this keeps
        // the System Store-free (ADR-0001).
        if let entity = playerEntity {
            var input = entity.components[PlayerInputComponent.self]
                ?? PlayerInputComponent()
            input.moveAxis = axis
            entity.components.set(input)
        }

        await eventBus.publish(PlayerMoveIntentChanged(axis: axis))
    }

    /// Accumulate a yaw/pitch delta. Unlike `.move` this is additive:
    /// a second call while the finger is still dragging bumps the
    /// pending total, and the System zeroes it after consuming.
    private func apply(look delta: SIMD2<Float>) {
        pendingLookDelta += delta
        if let entity = playerEntity {
            var input = entity.components[PlayerInputComponent.self]
                ?? PlayerInputComponent()
            input.lookDelta += delta
            entity.components.set(input)
        }
        // No event here: `PlayerLookApplied` is fired by the System
        // once the rotation actually lands, not when intent arrives.
    }

    // MARK: - Test hook

    /// Reset to defaults. Test-only, but `public` so cross-module
    /// tests can reach it without a protocol hole. Production code
    /// has no reason to call this — the Store's lifetime is the app's.
    public func resetForTesting() {
        currentMoveAxis = .zero
        pendingLookDelta = .zero
        playerEntity = nil
    }
}
