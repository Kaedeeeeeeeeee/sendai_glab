// DisasterCameraShakeSystem.swift
// SDGGameplay · Disaster
//
// Phase 8.1 addition. Applies a small first-person camera jitter while
// the earthquake state is active so the **player** feels the shake,
// not just the buildings around them. Complements `DisasterSystem`:
//
//   * `DisasterSystem` shakes every tile and leaves the player alone.
//   * `DisasterCameraShakeSystem` shakes *only the player's camera*
//     and leaves the tiles alone.
//
// Both Systems read from the same `DisasterStore.boundStore` so the
// lifecycle stays perfectly in sync (no drift between "tiles shaking"
// and "camera shaking").
//
// ## Why offset the camera, not the player rig
//
// The player rig is what drives ground-follow, input integration, and
// vehicle boarding. Translating the rig during a quake would send
// spurious input into `PlayerControlSystem.snapToGround` (which resamples
// the DEM each frame) and into any other "where is the player?"
// consumer. The camera is a passive child — its local translation is
// invisible to gameplay code and ideal for visual effects.
//
// ## Why subtract the last offset instead of letting it ride
//
// A naive implementation would add `currentOffset` each frame and
// silently accumulate drift every time the Store flipped between
// active and idle. Storing `lastAppliedOffset`, restoring it, then
// applying the new offset keeps the camera's "neutral" position
// perfectly recoverable — the moment the earthquake ends the camera
// snaps back to the rig-configured head pose with zero residual.
//
// ## Why no component carrying "shake intensity"
//
// The amplitude is a pure function of `DisasterState.earthquakeActive`'s
// `intensity`. Passing it via a component would duplicate store state
// and split the source of truth. If a future feature wants per-entity
// shake (e.g. drone-specific rotor shake), that's a separate System
// with its own component — this one stays focused on earthquakes.

import Foundation
import RealityKit
import SDGCore

/// Applies a per-frame sinusoidal translation to the first
/// `PerspectiveCamera` descendant of each `PlayerComponent`-bearing
/// entity, driven by the shared `DisasterSystem.boundStore`. Runs
/// every visible frame; no-op when the Store is idle or unbound.
@MainActor
public final class DisasterCameraShakeSystem: System {

    /// Ordered after `DisasterSystem` would be nice (so the tile
    /// shake and camera shake both sample the same store frame), but
    /// RealityKit's dependency declaration is best-effort — we rely
    /// on the fact that both Systems read a snapshot of `state` at
    /// the top of their update, so either order produces the same
    /// frame output. Explicit empty list for clarity.
    public static let dependencies: [SystemDependency] = []

    // MARK: - Tuning

    /// Peak translation (metres) applied at `intensity = 1.0`. Chosen
    /// to be subtle — 8 cm peak is enough to "feel" the ground moving
    /// without reading as nausea-inducing. Spec called for this value
    /// exactly so the whole team tunes against one number.
    internal static let peakAmplitudeMeters: Float = 0.08

    /// Sinusoid frequency, in radians per second. 15 Hz matches the
    /// low-rumble band of real earthquakes — slower reads as seasick,
    /// faster reads as a vibrating phone. `2π * 15 ≈ 94.25`.
    internal static let shakeFrequencyRadiansPerSecond: Float = 2 * .pi * 15

    // MARK: - ECS queries

    private let playerQuery: EntityQuery

    // MARK: - State

    /// Running clock. Drives the sinusoid so phase is preserved
    /// across frame-rate changes.
    private var elapsedTime: Float = 0

    /// What we added to the camera's local position last frame.
    /// Subtracted before applying the new offset so the camera's
    /// neutral pose is perfectly recoverable when the quake ends.
    /// Keyed by camera entity ID — one player = one camera, but
    /// multiplayer hypothetically needs per-camera bookkeeping.
    private var lastAppliedOffset: [Entity.ID: SIMD3<Float>] = [:]

    // MARK: - Init

    public required init(scene: Scene) {
        self.playerQuery = EntityQuery(
            where: .has(PlayerComponent.self)
        )
    }

    // MARK: - System update

    public func update(context: SceneUpdateContext) {
        let deltaTime = Float(context.deltaTime)
        guard deltaTime > 0 else { return }
        elapsedTime += deltaTime

        let intensity = currentIntensity()
        for playerEntity in context.entities(
            matching: playerQuery,
            updatingSystemWhen: .rendering
        ) {
            guard let camera = findCameraDescendant(of: playerEntity) else {
                continue
            }
            applyCameraOffset(camera: camera, intensity: intensity)
        }
    }

    // MARK: - Per-frame work

    /// Compute the instantaneous XY offset and write it onto the
    /// camera's local position, subtracting the previous frame's
    /// offset first so the camera's neutral pose is always the
    /// reference. Y is shaken along with X because real-world
    /// head-bob during a quake feels like vertical judder — the tile
    /// shake handles the lateral sway, the camera handles the "you
    /// personally are being jostled" axis.
    ///
    /// Returns the offset that was applied, for test observability.
    @discardableResult
    internal func applyCameraOffset(
        camera: Entity,
        intensity: Float
    ) -> SIMD3<Float> {
        // 1. Restore neutral pose by subtracting last frame's offset.
        let previous = lastAppliedOffset[camera.id] ?? .zero
        camera.position -= previous

        // 2. Compute new offset. Zero intensity ⇒ pure restore (no-op).
        let offset: SIMD3<Float>
        if intensity > 0 {
            let amp = Self.peakAmplitudeMeters * intensity
            let omega = Self.shakeFrequencyRadiansPerSecond
            // Two decorrelated sines on X and Y with a 90° phase so the
            // camera traces a small Lissajous figure rather than a
            // diagonal line — reads more organic. Same idea as
            // `DisasterSystem.applyShake` but one actor per output
            // (the camera) rather than per-entity phase offsets.
            let x = sin(elapsedTime * omega) * amp
            let y = sin(elapsedTime * omega + .pi / 2) * amp
            offset = SIMD3<Float>(x, y, 0)
        } else {
            offset = .zero
        }

        // 3. Apply + remember for next frame's subtract.
        camera.position += offset
        if offset == .zero {
            // Free the slot so idle scenes don't accumulate entries
            // forever — one entry per camera ever shaken is still
            // trivial, but this keeps the dictionary focused.
            lastAppliedOffset.removeValue(forKey: camera.id)
        } else {
            lastAppliedOffset[camera.id] = offset
        }
        return offset
    }

    // MARK: - Helpers

    /// Read the active earthquake intensity from the shared bound
    /// store. Returns 0 when the Store is unbound or the state isn't
    /// `.earthquakeActive`.
    private func currentIntensity() -> Float {
        guard let store = DisasterSystem.boundStore else { return 0 }
        if case let .earthquakeActive(_, intensity, _) = store.state {
            return intensity
        }
        return 0
    }

    /// DFS for the first `PerspectiveCamera` descendant. Matches the
    /// shape `PlayerControlSystem.findCameraChild` uses — duplicated
    /// because the helper is private on that System and cross-System
    /// reuse would require a Core utility that doesn't feel worth it
    /// for two callers.
    private func findCameraDescendant(of entity: Entity) -> Entity? {
        for child in entity.children {
            if child is PerspectiveCamera {
                return child
            }
            if let nested = findCameraDescendant(of: child) {
                return nested
            }
        }
        return nil
    }

    // MARK: - Test hooks

    /// Advance the local clock manually (tests).
    internal func tickForTesting(by dt: Float) {
        elapsedTime += dt
    }

    /// Last offset applied to `camera`, for tests.
    internal func lastOffsetForTesting(camera: Entity) -> SIMD3<Float> {
        lastAppliedOffset[camera.id] ?? .zero
    }
}
