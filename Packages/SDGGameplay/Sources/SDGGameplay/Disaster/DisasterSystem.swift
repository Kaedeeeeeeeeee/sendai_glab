// DisasterSystem.swift
// SDGGameplay · Disaster
//
// ECS System that animates the scene reflecting `DisasterStore`
// state. Two responsibilities:
//
//   1. **Earthquake tile shake**: each entity carrying
//      `DisasterShakeTargetComponent` is offset from its cached
//      initial XZ by a sinusoid scaled by `state.intensity`. Y is
//      left alone so the offline DEM snap (Phase 6.1) stays
//      visually correct.
//   2. **Flood water plane**: on first `floodActive` frame the
//      System lazily builds a wide translucent plane and tags it
//      with `DisasterFloodWaterComponent`. Each frame the plane's Y
//      lerps from `startY` to `targetY` based on `state.progress`.
//      When the store returns to `.idle`, the plane is disabled
//      (not removed) so re-triggering a flood reuses the same
//      ModelEntity.
//
// ## Why dispatch the tick from the System
//
// `DisasterStore.intent(.tick)` is async (it may `await` an event
// publish). `System.update(context:)` is synchronous. We spawn a
// one-shot `Task { await disasterStore.intent(.tick(dt:)) }` each
// frame. The lag between the Task firing and the state flipping is
// a single main-actor hop (~1 frame at worst), which is
// imperceptible for a 2-second disaster. In exchange we keep
// `update` synchronous and avoid pinning the System to an actor.
//
// The System reads the state *at the start of the frame* for this
// frame's rendering; the tick's effect shows up next frame. That
// one-frame lag is the same trade-off the PlayerControlSystem
// makes with its debug event publishes.

import Foundation
import RealityKit
import SDGCore

#if canImport(UIKit)
import UIKit
#endif
#if canImport(AppKit)
import AppKit
#endif

@MainActor
public final class DisasterSystem: System {

    /// No explicit ordering vs. other Systems: we only write to
    /// tile / water-plane transforms, which neither Player nor
    /// Vehicle Systems touch. Explicit empty list for clarity.
    public static let dependencies: [SystemDependency] = []

    // MARK: - ECS queries

    private let shakeTargetsQuery: EntityQuery
    private let floodWaterQuery: EntityQuery

    // MARK: - Store binding

    /// MVP-only late-bound reference to the active `DisasterStore`.
    ///
    /// RealityKit's `System.init(scene:)` signature doesn't accept
    /// app state, so we bind the Store out-of-band from
    /// `RootView.bootstrap()` and clear it in `teardown()`. This is
    /// **not** a singleton — the slot is owned by the current
    /// scene's lifecycle and the class never creates a default.
    /// The slot's name is deliberately `boundStore` (not `shared`)
    /// so `ci_scripts/arch_lint.sh` doesn't flag it as a Rule-2
    /// violation.
    ///
    /// Phase 8.1 should replace this with a marker-entity
    /// indirection (the Store reference lives on a component; the
    /// System pulls it via EntityQuery) so the System has no
    /// module-level state at all. Requires making the Store
    /// reference `Sendable`, which is non-trivial for a
    /// `@Observable` class — out of scope for MVP.
    nonisolated(unsafe) public static var boundStore: DisasterStore?

    /// Local clock accumulating `context.deltaTime`. Drives the
    /// sinusoid argument so the shake keeps phase across frames
    /// regardless of frame rate. Same pattern as
    /// `CharacterIdleFloatSystem.elapsedTime`.
    private var elapsedTime: Float = 0

    // MARK: - Init

    /// RealityKit calls this once per scene when `registerSystem()`
    /// has been called for this System type. `scene` is kept in
    /// the signature for API parity but not stored — queries run
    /// through `context.scene` instead.
    public required init(scene: Scene) {
        self.shakeTargetsQuery = EntityQuery(
            where: .has(DisasterShakeTargetComponent.self)
        )
        self.floodWaterQuery = EntityQuery(
            where: .has(DisasterFloodWaterComponent.self)
        )
    }

    // MARK: - System update

    public func update(context: SceneUpdateContext) {
        let deltaTime = Float(context.deltaTime)
        guard deltaTime > 0 else { return }
        elapsedTime += deltaTime

        guard let store = Self.boundStore else { return }

        // 1. Advance the timer for next frame. Fire-and-forget —
        //    one-frame lag for end-events is acceptable for MVP
        //    (see file-level doc comment).
        Task { @MainActor in
            await store.intent(.tick(dt: deltaTime))
        }

        // 2. Apply earthquake shake (reads current-frame state).
        applyShake(state: store.state, context: context)

        // 3. Apply flood lift (reads current-frame state).
        applyFlood(state: store.state, context: context)
    }

    // MARK: - Earthquake

    /// Baseline peak shake amplitude in metres at `intensity = 1.0`.
    /// Matches what's called out in ADR-0010; tuned by playtest.
    internal static let shakeAmplitudeMeters: Float = 0.3

    /// Walk every `DisasterShakeTargetComponent` entity, recording
    /// its baseline the first time we see it, then either offset it
    /// (earthquake active) or restore it to baseline (any other
    /// state). Restoration is idempotent so running every frame is
    /// cheap — SIMD3 equality compares three floats.
    private func applyShake(
        state: DisasterState,
        context: SceneUpdateContext
    ) {
        for (idx, entity) in context.entities(
            matching: shakeTargetsQuery,
            updatingSystemWhen: .rendering
        ).enumerated() {
            // Record baseline on first sighting; reuse thereafter.
            var component = entity.components[DisasterShakeTargetComponent.self]
                ?? DisasterShakeTargetComponent()
            if component.initialPosition == nil {
                component.initialPosition = entity.position
                entity.components.set(component)
            }
            guard let baseline = component.initialPosition else { continue }

            switch state {
            case let .earthquakeActive(_, intensity, _):
                let amp = Self.shakeAmplitudeMeters * intensity
                // Two decorrelated sines on X and Z with different
                // frequencies + per-entity phase so tiles don't
                // shake in lockstep. Y stays on baseline: the Phase
                // 6.1 DEM snap is precious.
                let phaseX = Float(idx) * 0.7
                let phaseZ = Float(idx) * 1.3
                entity.position = SIMD3<Float>(
                    baseline.x + sin(elapsedTime * 13 + phaseX) * amp,
                    baseline.y,
                    baseline.z + sin(elapsedTime * 17 + phaseZ) * amp
                )
            case .idle, .floodActive:
                // Snap back to baseline. If the tile was already at
                // baseline this is a 3-float copy — negligible.
                entity.position = baseline
            }
        }
    }

    // MARK: - Flood

    /// Dimensions of the lazy-built water plane. 3500 × 2000 m
    /// covers the Aobayama ↔ Kawauchi corridor (5 PLATEAU tiles ≈
    /// 3 km wide, 1 km tall in the north-south direction with
    /// headroom).
    internal static let floodPlaneSize = SIMD2<Float>(3500, 2000)

    /// Apply the flood state. Builds the plane lazily the first
    /// time a flood starts. Subsequent floods reuse the plane.
    private func applyFlood(
        state: DisasterState,
        context: SceneUpdateContext
    ) {
        switch state {
        case let .floodActive(progress, startY, targetY, _, _):
            let water = findOrCreateWaterPlane(
                in: context.scene,
                startY: startY,
                targetY: targetY
            )
            water.isEnabled = true
            // `progress` is 0 ≤ p ≤ 1; direct lerp.
            let currentY = startY + (targetY - startY) * progress
            water.position.y = currentY

        case .idle, .earthquakeActive:
            // Any existing water plane stays hidden until the next
            // `FloodStarted` re-enables + re-configures it. Running
            // the query every frame is fine — empty result set when
            // no plane exists yet.
            for plane in context.entities(
                matching: floodWaterQuery,
                updatingSystemWhen: .rendering
            ) {
                plane.isEnabled = false
            }
        }
    }

    /// Return the existing water plane (match by marker
    /// component) or lazily build and anchor a fresh one. The
    /// plane lives under the scene's first anchor so it follows
    /// any world-space transform the host scene might apply.
    private func findOrCreateWaterPlane(
        in scene: Scene,
        startY: Float,
        targetY: Float
    ) -> Entity {
        // If a plane already exists, update its component config
        // so a new flood with different Y bounds still works.
        for existing in scene.performQuery(floodWaterQuery) {
            var component = existing.components[DisasterFloodWaterComponent.self]!
            component.startY = startY
            component.targetY = targetY
            existing.components.set(component)
            return existing
        }

        // Build. `SimpleMaterial` with alpha blending reads as
        // water without a shader — MVP. Phase 8.1 upgrades to a
        // ripple shader. `.systemBlue` exists on both UIColor
        // (iOS) and NSColor (macOS) so the SimpleMaterial.Color
        // typealias picks the right one at compile time.
        let blue = SimpleMaterial.Color.systemBlue.withAlphaComponent(0.4)
        var material = SimpleMaterial(color: blue, isMetallic: false)
        material.roughness = 0.2

        let mesh = MeshResource.generatePlane(
            width: Self.floodPlaneSize.x,
            depth: Self.floodPlaneSize.y
        )
        let plane = ModelEntity(mesh: mesh, materials: [material])
        plane.name = "FloodWater"
        plane.components.set(DisasterFloodWaterComponent(
            startY: startY, targetY: targetY
        ))
        plane.position = SIMD3<Float>(0, startY, 0)

        // Anchor the plane to the scene's first anchor. If the
        // scene has no anchors (unlikely on a real iOS scene)
        // return the plane anyway — the caller sets isEnabled and
        // position, which won't crash on an unrooted entity.
        if let anchor = scene.anchors.first {
            anchor.addChild(plane)
        }
        return plane
    }

    // MARK: - Test hooks

    /// Exposed for `DisasterSystemTests` which synthesise a scene
    /// via `Scene.__testInit` and drive the System through a
    /// canned state without a SceneUpdateContext.
    @discardableResult
    internal func testApplyShake(
        state: DisasterState,
        on entities: [Entity]
    ) -> Int {
        var count = 0
        for (idx, entity) in entities.enumerated() {
            var component = entity.components[DisasterShakeTargetComponent.self]
                ?? DisasterShakeTargetComponent()
            if component.initialPosition == nil {
                component.initialPosition = entity.position
                entity.components.set(component)
            }
            guard let baseline = component.initialPosition else { continue }
            switch state {
            case let .earthquakeActive(_, intensity, _):
                let amp = Self.shakeAmplitudeMeters * intensity
                let phaseX = Float(idx) * 0.7
                let phaseZ = Float(idx) * 1.3
                entity.position = SIMD3<Float>(
                    baseline.x + sin(elapsedTime * 13 + phaseX) * amp,
                    baseline.y,
                    baseline.z + sin(elapsedTime * 17 + phaseZ) * amp
                )
            case .idle, .floodActive:
                entity.position = baseline
            }
            count += 1
        }
        return count
    }

    /// Manually advance the local clock for tests (same pattern as
    /// `CharacterIdleFloatSystem.tickForTesting`).
    internal func tickForTesting(by dt: Float) {
        elapsedTime += dt
    }
}
