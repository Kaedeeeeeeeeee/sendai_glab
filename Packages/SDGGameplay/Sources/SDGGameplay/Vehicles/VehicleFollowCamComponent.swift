// VehicleFollowCamComponent.swift
// SDGGameplay · Vehicles
//
// Phase 7.1 spring-damped follow camera. ADR-0009 notes that Phase 7's
// re-parent used a static local translation (`+Y 1, -Z 2`), which reads
// rigid when the drone yaws quickly. Phase 7.1 replaces the hard
// attachment with a lerp toward the desired offset each frame, driven
// by `VehicleFollowCamSystem`.
//
// The component tags the *vehicle* entity (not the camera), because the
// System walks vehicles and then does the per-descendant camera lookup
// — the same pattern as `VehicleComponent` → camera descent in
// `RootView.findPerspectiveCamera`. That keeps the follow-cam-specific
// knob (the target offset) physically colocated with the piloted
// entity; swapping which vehicle the player is piloting automatically
// swaps which offset the cam eases toward.
//
// The camera itself stays a plain `PerspectiveCamera` descendant — no
// separate component is needed on it. We rely on the existing descent
// helper so cameras parented via `CharacterLoader` (unnamed) are found
// by type, matching the Phase 7 re-parent behaviour.

import Foundation
import RealityKit

/// ECS component describing where the follow camera should sit in the
/// vehicle's local frame, and how stiffly the camera springs toward
/// that offset.
///
/// Attached to a vehicle entity at board time (by the RootView
/// `VehicleEntered` subscriber) and removed at exit. Between those two
/// events, `VehicleFollowCamSystem` walks every entity carrying this
/// component, finds its first `PerspectiveCamera` descendant, and
/// lerps the camera's local translation toward `targetOffset` at
/// `springFactor` per normalised 60-FPS frame.
///
/// ### Field contract
///
///   * `targetOffset` — desired local-space camera translation on the
///     vehicle. Phase 7.1 default is `(0, 1.5, -3.0)`: slightly higher
///     and further back than Phase 7's rigid `(0, 1.0, -2.0)`, because
///     the lerp means the camera lags behind fast movement and a bit
///     more distance gives the mesh room to re-enter frame.
///   * `springFactor` — fraction of the remaining offset covered per
///     normalised frame (i.e. per `deltaTime == 1/60`). `0.15` feels
///     snappy-but-not-rigid in playtest; lower values trail more,
///     higher values approach the Phase 7 rigid behaviour.
public struct VehicleFollowCamComponent: Component, Sendable {

    /// Desired camera position in the vehicle's local frame (metres).
    /// Applied every frame by the System as a lerp target.
    public var targetOffset: SIMD3<Float>

    /// Spring stiffness, as a unitless fraction per normalised 60 FPS
    /// frame. The System rescales by `deltaTime * 60` so the effective
    /// response rate is frame-rate-independent — at 30 FPS each frame
    /// covers twice as much of the remaining offset, matching the
    /// visible smoothness of a 60 FPS run.
    public var springFactor: Float

    /// The Phase 7.1 camera rig target. Raised 0.5 m and pulled back
    /// 1.0 m versus Phase 7's static mount so the softened follow has
    /// room to breathe without the mesh clipping the camera.
    public static let defaultTargetOffset = SIMD3<Float>(0, 1.5, -3.0)

    /// Default spring factor — see type doc. Tuned on the simulator
    /// build; raise toward 0.5 for a tighter "glued-to-the-drone" feel
    /// at the cost of jitter on fast yaws.
    public static let defaultSpringFactor: Float = 0.15

    public init(
        targetOffset: SIMD3<Float> = VehicleFollowCamComponent.defaultTargetOffset,
        springFactor: Float = VehicleFollowCamComponent.defaultSpringFactor
    ) {
        self.targetOffset = targetOffset
        self.springFactor = springFactor
    }
}
