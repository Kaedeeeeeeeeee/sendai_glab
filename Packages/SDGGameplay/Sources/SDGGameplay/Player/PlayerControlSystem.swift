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

    /// Forward speed at full-stick, metres per second. Phase 4 QA
    /// speed — must be reset to 8 m/s (ship default) once alignment
    /// verification is done.
    ///
    /// History:
    ///   - Phase 2 Alpha: 2.0 → 8.0 (walking too slow for 1 km tiles)
    ///   - Phase 4 iter 3: 8.0 → 800.0 (100×, too fast on device)
    ///   - Phase 4 iter 4: 800.0 → 80.0 (10× — fast enough to sweep
    ///     the corridor, slow enough to actually see buildings)
    public static let moveSpeed: Float = 80.0

    /// Maximum absolute pitch, radians. ±80° ≈ ±1.396 rad. Keeps the
    /// camera from flipping past vertical.
    public static let pitchLimit: Float = .pi / 180 * 80

    /// Multiplier applied to `moveAxis` while `PlayerComponent.isStaggered`
    /// is true. 0.3 = 70 % of forward momentum shed — the ground
    /// stealing their balance reads as a stagger, but the player can
    /// still shuffle around so they never feel soft-locked during a
    /// quake. Tuned by playtest; see ADR-0010 Phase 8.1 addendum.
    public static let staggeredMoveScale: Float = 0.3

    /// The query we run each frame. Built once at init time because
    /// the predicate never changes and the query value is cheap to
    /// reuse.
    private let query: EntityQuery

    /// Terrain-entity query; every frame we resolve this to the
    /// first match (there's exactly one DEM terrain in Phase 4) and
    /// sample its mesh to ground-follow the player.
    private let terrainQuery: EntityQuery

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
        self.terrainQuery = EntityQuery(
            where: .has(TerrainComponent.self)
        )
    }

    public func update(context: SceneUpdateContext) {
        let deltaTime = Float(context.deltaTime)
        guard deltaTime > 0 else { return }

        // Resolve the terrain entity once for all players in this
        // frame. In Phase 4 there's exactly one DEM terrain, so the
        // first match is the one we want.
        var terrainEntity: Entity?
        for entity in context.entities(
            matching: terrainQuery,
            updatingSystemWhen: .rendering
        ) {
            terrainEntity = entity
            break
        }

        // `.rendering` = "call us every visible frame", the right
        // cadence for player control. The alternative `.simulating`
        // ties to the physics clock, which we don't need here.
        for entity in context.entities(
            matching: query,
            updatingSystemWhen: .rendering
        ) {
            applyInput(to: entity, deltaTime: deltaTime)
            if let terrain = terrainEntity {
                snapToGround(player: entity, terrain: terrain)
            }
        }
    }

    /// Ground-follow the player by sampling the terrain mesh directly.
    ///
    /// ### Why not `Scene.raycast`
    ///
    /// The first Phase 4 iteration used `context.scene.raycast` against
    /// the `CollisionComponent` that `TerrainLoader` installs via
    /// `generateCollisionShapes(recursive:)`. Device playtest found the
    /// raycast reliably returned no hits — the player stayed at spawn
    /// Y and flew through the air as they walked. Rather than debug
    /// the collision-world / mask interaction, we fall back to the
    /// mesh-vertex sampler that already proved reliable in Phase 3's
    /// spawn-Y anchoring (`TerrainLoader.sampleTerrainY`).
    ///
    /// ### Cost
    ///
    /// ~15 K verts after decimation, ~0.2 ms per call on M-series.
    /// Called once per player per frame; fine at 60 / 120 Hz. If we
    /// ever need tighter perf, a BVH over the DEM verts would drop
    /// this to O(log n); not worth the complexity at Phase 4.
    private func snapToGround(player: Entity, terrain: Entity) {
        // `sampleTerrainY` is `@MainActor` because it reads RealityKit
        // entity transforms + ModelComponent. RealityKit drives
        // System.update on MainActor in practice, but the Swift 6
        // type system doesn't know that, so the call needs an
        // explicit `assumeIsolated`. `CharacterIdleFloatSystem`
        // sidesteps this by being annotated `@MainActor` on the
        // class; doing the same here would cascade to every existing
        // caller of `PlayerControlSystem` (tests, orchestrator hookup)
        // and the extra scope isn't worth it for one method call.
        let worldPos = player.position(relativeTo: nil)
        let terrainY = MainActor.assumeIsolated {
            TerrainLoader.sampleTerrainY(
                in: terrain,
                atWorldXZ: SIMD2<Float>(worldPos.x, worldPos.z)
            )
        }
        guard let terrainY else { return }
        // Player rig has feet at entity-local Y = 0, camera head at
        // local Y = 1.5. `sampleTerrainY` now does triangle-barycentric
        // interpolation, so the sampled value equals the actual mesh
        // surface Y under the player — no vertex-step error to absorb.
        // A 10 cm margin is enough to prevent z-fighting between feet
        // and the terrain material; anything larger would float the
        // character visibly, which matters for future multiplayer where
        // other clients see this rig's world Y.
        var newPos = player.position
        newPos.y = terrainY + 0.1
        player.position = newPos
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
        //
        // Phase 8.1: when the player's identity tag is flagged
        // `isStaggered` (the earthquake is shaking), scale the axis
        // by `staggeredMoveScale` so input feels sluggish. We read
        // the flag *here* rather than gating on `input.moveAxis`
        // earlier so the stagger only affects translation — yaw /
        // pitch still respond normally, which preserves look control
        // while balance is off.
        let isStaggered = entity.components[PlayerComponent.self]?
            .isStaggered ?? false
        let scale: Float = isStaggered ? Self.staggeredMoveScale : 1
        let axis = input.moveAxis * scale
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
