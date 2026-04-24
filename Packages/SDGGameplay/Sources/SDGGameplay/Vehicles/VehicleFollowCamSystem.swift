// VehicleFollowCamSystem.swift
// SDGGameplay · Vehicles
//
// Phase 7.1 follow-cam System. Complements Phase 7's rigid re-parent
// (see ADR-0009) with a spring-damped ease toward the target offset,
// so a fast drone yaw no longer feels like the camera is bolted to
// the mesh.
//
// ## Design
//
// The System is the cheapest thing that can replace a static
// translation:
//
//   1. Query every entity carrying `VehicleFollowCamComponent` (one
//      per currently-piloted vehicle; Phase 7.1 only tags the
//      occupied vehicle).
//   2. For each one, descend to find the first `PerspectiveCamera`
//      child — same contract as `RootView.findPerspectiveCamera`.
//   3. Lerp the camera's *local* translation toward `targetOffset` by
//      `springFactor * deltaTime * 60`. Frame-rate-adjusting with the
//      `* 60` factor keeps the response identical at 30 / 60 / 120
//      FPS — without it, a 120 FPS run would over-damp and a 30 FPS
//      run would overshoot.
//
// The System NEVER rewrites world position; it only touches
// `camera.transform.translation` (local). The camera's parent (the
// vehicle entity) already follows the vehicle through
// `VehicleControlSystem.update`, so the follow camera "rides along"
// automatically. This keeps the System's responsibility focussed on
// "ease the local offset" and avoids tripping AGENTS.md §1 by
// touching Store state or scene-level transforms.
//
// ## Why not a Component on the camera
//
// The alternative design tags the camera entity itself with the
// component. That's a half-step closer to "ECS purist" but requires
// two lookups each frame (camera → ancestor vehicle → current offset)
// and complicates teardown (we'd need to ensure the component is
// removed when the camera re-parents back to the player body). Tagging
// the vehicle keeps the state exactly where it's meaningful: on the
// entity that the pilot input controls.
//
// ## No-op fast paths
//
//   * `deltaTime ≤ 0` — skip. Same pattern as `CharacterIdleFloatSystem`
//     (first frame, paused scene).
//   * No `PerspectiveCamera` descendant — skip that vehicle. The
//     Phase 7 `VehicleEntered` re-parent attaches one, but between
//     `.exit` and the follow-cam component being removed we might see
//     a "no camera attached" frame. Silently skipping is the
//     correct behaviour.
//   * Distance ≤ `epsilonSquared` — snap exactly to target and skip
//     the lerp. Avoids floating-point drift when already on-target
//     (otherwise `current += (target - current) * k` keeps the tiny
//     residual forever).

import Foundation
import RealityKit

/// RealityKit ECS `System` that softens the Phase 7 rigid follow cam.
///
/// Runs every rendered frame. For each entity carrying
/// `VehicleFollowCamComponent`, finds its first `PerspectiveCamera`
/// descendant and eases that camera's local translation toward the
/// component's `targetOffset`. See file header for the motion model.
///
/// `@MainActor` because `Entity.children` / `entity.transform` /
/// `entity.components[_:]` are all MainActor-isolated in
/// RealityFoundation — mirroring `CharacterIdleFloatSystem`.
@MainActor
public final class VehicleFollowCamSystem: System {

    /// No ordering constraints: we mutate a camera's local translation
    /// only. Vehicle world-position integration happens in
    /// `VehicleControlSystem`; that writes the *vehicle* entity, this
    /// System writes the *camera descendant*, so the two never race.
    public static let dependencies: [SystemDependency] = []

    /// Frame-rate normalisation constant. Multiplying `deltaTime * 60`
    /// rescales the per-frame spring so the perceived stiffness stays
    /// constant regardless of refresh rate.
    public static let referenceFrameRate: Float = 60.0

    /// Below this squared distance the camera snaps exactly to target
    /// instead of lerping forever toward it. 1e-6 m² = 1 mm² —
    /// imperceptible, and well above the float noise floor on a
    /// 128-byte SIMD3.
    public static let snapEpsilonSquared: Float = 1e-6

    /// Query matching vehicles that have a follow-cam attached.
    private let query: EntityQuery

    public init(scene: Scene) {
        self.query = EntityQuery(where: .has(VehicleFollowCamComponent.self))
    }

    public func update(context: SceneUpdateContext) {
        let deltaTime = Float(context.deltaTime)
        // Defensive: first frame / paused scene. A zero or negative
        // delta would degenerate the lerp into a snap (k = 0 means no
        // motion; k < 0 would drift the camera away). Skipping is the
        // correct behaviour for both cases.
        guard deltaTime > 0 else { return }

        for entity in context.entities(
            matching: query,
            updatingSystemWhen: .rendering
        ) {
            applyFollow(to: entity, deltaTime: deltaTime)
        }
    }

    // MARK: - Per-entity work

    /// Ease the follow camera on one vehicle toward its target offset.
    ///
    /// Exposed as `internal` so `VehicleFollowCamSystemTests` can drive
    /// the lerp directly without spinning up a RealityKit Scene —
    /// same pattern as `CharacterIdleFloatSystem.applyFloat` and
    /// `VehicleControlSystem.applyControl`.
    ///
    /// The return value is the camera's new local translation after
    /// the lerp (or `.zero` when no camera was found); tests assert
    /// on it. Production callers ignore it.
    @discardableResult
    func applyFollow(to entity: Entity, deltaTime: Float) -> SIMD3<Float> {
        guard let component = entity.components[VehicleFollowCamComponent.self] else {
            return .zero
        }
        guard let camera = findPerspectiveCamera(under: entity) else {
            // Between `.exit` publishing and the follow-cam component
            // being removed in RootView, there may be a frame with no
            // camera descendant. Skipping keeps us crash-free.
            return .zero
        }

        let current = camera.transform.translation
        let target = component.targetOffset
        let delta = target - current

        // Squared distance check: cheaper than a sqrt every frame and
        // equivalent for a "very close already" test.
        let distanceSquared = simd_length_squared(delta)
        if distanceSquared <= Self.snapEpsilonSquared {
            camera.transform.translation = target
            return target
        }

        // Rescale `springFactor` by the frame-rate factor so the
        // perceived stiffness is frame-rate-independent. At 60 FPS
        // this is identity (`1/60 * 60 == 1`); at 30 FPS it doubles
        // the per-frame coverage so the camera still feels
        // responsive.
        let k = component.springFactor * deltaTime * Self.referenceFrameRate
        // Clamp to [0, 1] so a catastrophically long frame (lock-up,
        // backgrounding) cannot overshoot past the target and induce
        // oscillation. 1.0 means "jump to target this frame" which
        // is the right degenerate behaviour.
        let kClamped = min(max(k, 0), 1)

        let next = current + delta * kClamped
        camera.transform.translation = next
        return next
    }

    /// Iterative DFS that finds the first `PerspectiveCamera`
    /// descendant of `root`. Matches `RootView.findPerspectiveCamera`
    /// — duplicated here because System ↔ View crossing would break
    /// ADR-0001, and the walk is three lines anyway.
    private func findPerspectiveCamera(under root: Entity) -> Entity? {
        var stack: [Entity] = [root]
        while let current = stack.popLast() {
            if current is PerspectiveCamera { return current }
            stack.append(contentsOf: current.children)
        }
        return nil
    }
}
