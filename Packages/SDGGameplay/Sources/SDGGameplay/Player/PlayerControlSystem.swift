// PlayerControlSystem.swift
// SDGGameplay · Player
//
// RealityKit ECS `System` that turns `PlayerInputComponent` state into
// actual entity motion every frame. This is the only place in the
// codebase that writes to the player's transform — everything else
// (joystick, touch panning, Store) stops at the component boundary.
//
// Runs on MainActor (System's `init(scene:)` and `update(context:)`
// are both MainActor-isolated in the RealityFoundation interface at
// iOS 18+). The `SceneUpdateContext.entities(matching:updatingSystemWhen:)`
// query API we use is iOS 18 / macOS 15; those match the SDGGameplay
// package's declared platform floor, so no per-symbol `@available`
// marker is needed.

import Foundation
import RealityKit
import SDGCore

/// Integrates `PlayerInputComponent` into `Entity.position` and
/// `Entity.orientation` each frame.
///
/// **Motion model (deliberately simple for Phase 1):**
///
///   * Horizontal: `moveAxis` is treated as a target velocity,
///     `axis.y` forward and `axis.x` strafe, both in the player
///     entity's local space. The entity translates by
///     `velocity * deltaTime` where `velocity = axis * moveSpeed`.
///     No acceleration, no physics — feels like a flat FPS, which is
///     what the 2026 GDD §1.3 "core loop" asks for at this phase.
///
///   * Yaw: `lookDelta.x` (already in radians) rotates the entity
///     around world +Y. We rotate the *player root*, not the camera,
///     so forward motion stays aligned with view direction.
///
///   * Pitch: accumulated separately (see `accumulatedPitch`) and
///     applied to the first `HasPerspectiveCamera` descendant found
///     on the player entity. Pitch is clamped to ±80° so the player
///     cannot look straight up/down and invert the camera. Pitch is
///     not applied to the root, because rolling the whole body would
///     also roll movement — first-person view convention.
///
///   * The entity keeps its Y position. Gravity and jumping are out
///     of scope for Phase 1; the GDD roadmap puts them in Phase 2.
public final class PlayerControlSystem: System {

    /// No ordering constraints against other Systems at this phase.
    /// When drilling + physics Systems land in Phase 2 we will likely
    /// want `.after(PhysicsSystem.self)` here.
    public static let dependencies: [SystemDependency] = []

    /// Forward speed at full-stick, metres per second. Tuned by eye
    /// for the 5 km sendai corridor walking pace: slightly faster
    /// than real-world walking (≈1.4 m/s) so traversal isn't tedious
    /// but slow enough to read the geology on passing outcrops.
    public static let moveSpeed: Float = 2.0

    /// Maximum absolute pitch, radians. ±80° ≈ ±1.396 rad. Keeps the
    /// camera from flipping past vertical.
    public static let pitchLimit: Float = .pi / 180 * 80

    /// The query we run each frame. Built once at init time because
    /// the predicate never changes and the query value is cheap to
    /// reuse.
    private let query: EntityQuery

    /// Accumulated pitch across frames. Lives on the System, not the
    /// component, because pitch is conceptually part of the camera's
    /// state — many subscribers need the *current* total, not just
    /// the per-frame delta.
    private var accumulatedPitch: Float = 0

    public init(scene: Scene) {
        // Match any entity that has BOTH the identity tag and the
        // input bucket. An NPC that is marked `PlayerComponent` for
        // cutscene purposes but deliberately has no input component
        // is a no-op for us — that is the right behaviour.
        self.query = EntityQuery(
            where: .has(PlayerComponent.self)
                && .has(PlayerInputComponent.self)
        )
    }

    public func update(context: SceneUpdateContext) {
        let deltaTime = Float(context.deltaTime)
        guard deltaTime > 0 else { return }

        // `.rendering` = "call us every visible frame", the right
        // cadence for player control. The alternative `.simulating`
        // ties to the physics clock, which we don't need here.
        for entity in context.entities(
            matching: query,
            updatingSystemWhen: .rendering
        ) {
            applyInput(to: entity, deltaTime: deltaTime)
        }
    }

    // MARK: - Per-entity work

    /// Read `PlayerInputComponent`, integrate, write back with
    /// `lookDelta` zeroed so the one-shot semantics hold.
    ///
    /// Exposed as `internal` so `PlayerControlSystemTests` can drive
    /// the integration step without constructing a full `Scene`.
    @discardableResult
    func applyInput(to entity: Entity, deltaTime: Float) -> PlayerInputComponent {
        guard var input = entity.components[PlayerInputComponent.self] else {
            // No component = no work. Keep an empty default so the
            // function's return is always meaningful for tests.
            return PlayerInputComponent()
        }

        // --- Yaw on root entity --------------------------------------
        // Yaw rotates around world +Y. Apply the delta on top of the
        // existing root orientation so repeated calls compose.
        let yawDelta = input.lookDelta.x
        if yawDelta != 0 {
            let yawQuat = simd_quatf(angle: -yawDelta, axis: SIMD3(0, 1, 0))
            // Right-multiply so the delta is applied in the entity's
            // *current* local frame, matching the "drag → rotate"
            // mental model (dragging right turns right, whatever way
            // you were already facing).
            entity.orientation = entity.orientation * yawQuat
        }

        // --- Pitch on first camera child -----------------------------
        // Accumulate and clamp, then assign the clamped absolute on
        // the camera entity. That way the pitch cannot drift past the
        // limits even if deltas come in fast.
        var pitchDelta = input.lookDelta.y
        if pitchDelta != 0 {
            let newPitch = simd_clamp(
                accumulatedPitch + pitchDelta,
                -Self.pitchLimit,
                Self.pitchLimit
            )
            pitchDelta = newPitch - accumulatedPitch
            accumulatedPitch = newPitch

            if let camera = findCameraChild(of: entity) {
                camera.orientation = simd_quatf(
                    angle: accumulatedPitch,
                    axis: SIMD3(1, 0, 0)
                )
            }
        }

        // --- Horizontal translation ----------------------------------
        // Local-space move: `axis.y` forward = entity's local `-Z`,
        // `axis.x` strafe = entity's local `+X`. Convert to world by
        // transforming the direction through the entity's current
        // orientation.
        let axis = input.moveAxis
        if axis != .zero {
            let localDir = SIMD3<Float>(axis.x, 0, -axis.y)
            let worldDir = entity.orientation.act(localDir)
            let step = worldDir * (Self.moveSpeed * deltaTime)
            entity.position += step
        }

        // --- Drain one-shot look delta -------------------------------
        // Preserve the persistent `moveAxis`; wipe the consumed delta
        // so the next frame starts from 0.
        input.lookDelta = .zero
        entity.components.set(input)

        return input
    }

    /// Find the first `PerspectiveCamera` descendant of `entity`.
    /// Rig convention (see `RootView`): camera is a direct child at
    /// head height. Searching recursively is cheap (player rig has
    /// single-digit children) and survives future rig changes.
    private func findCameraChild(of entity: Entity) -> Entity? {
        for child in entity.children {
            if child is PerspectiveCamera {
                return child
            }
            if let nested = findCameraChild(of: child) {
                return nested
            }
        }
        return nil
    }
}

// MARK: - Convenience for tests

extension PlayerControlSystem {

    /// Current accumulated pitch in radians, exposed for tests so
    /// they can assert on clamping behaviour without a camera entity.
    var accumulatedPitchForTesting: Float { accumulatedPitch }
}
