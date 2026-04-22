// CharacterLoader.swift
// SDGGameplay · Characters
//
// Loads a `CharacterRole`'s USDZ from the app bundle, normalises its
// scale (Meshy preview models ship with arbitrary model-space units),
// and returns an `Entity` ready to drop into a `RealityView`
// `content.add(...)`. For playable roles the returned entity is
// pre-wired with the Player ECS components and a head-height camera
// so `RootView` does not need to know anything about the model.
//
// Why a class (not a free function): the loader holds a `Bundle`
// reference so tests can inject `Bundle.module`. Injecting the bundle
// as a property rather than threading it through every call also
// lines up with how a future NPC-pool / pre-warming cache would want
// to hold it. The class stays `final` and stateless beyond that
// reference — it is not a singleton.
//
// Three-layer rule (ADR-0001): this file lives in the Gameplay layer
// and imports RealityKit. No SwiftUI imports. The Store /
// Orchestrator path is untouched — loader callers are the View layer
// (RootView) or a future scene-bootstrap system.

import Foundation
import RealityKit

/// Loads `CharacterRole` USDZ assets into RealityKit `Entity`s.
///
/// `@MainActor` because every `Entity` mutation and the async USDZ
/// loader (iOS 18 `Entity.init(contentsOf:withName:)`) is MainActor-
/// isolated in RealityFoundation.
///
/// ### Typical use from RootView / scene bootstrap
///
/// ```swift
/// let loader = CharacterLoader()
/// let player = try await loader.loadAsPlayer(.playerMale)
/// content.add(player)
/// playerStore.attach(playerEntity: player)
/// ```
///
/// ### Future extension points
///
/// * NPC 载入 reuses `loadAsNPC(_:)` and layers on an idle float /
///   dialogue hook. Phase 2 Alpha already provides
///   `CharacterIdleFloatComponent` for that.
/// * Phase 3 美術 rig: when characters carry a named `head` bone the
///   `PerspectiveCamera` should attach to that bone, not a fixed
///   1.5 m offset. The API shape stays the same.
/// * Character-wardrobe / 衣装切り替え (Phase 3+): add a second method
///   that takes a `Wardrobe` descriptor; the enum role continues to
///   pick the base mesh.
@MainActor
public final class CharacterLoader {

    /// Bundle used to resolve `Resources/Characters/*.usdz`.
    /// Defaults to `.main` (the app bundle); tests inject a bundle
    /// that does *not* ship the USDZs so the "missing asset" path can
    /// be covered without 4 MB of fixtures in the test target.
    private let bundle: Bundle

    /// - Parameter bundle: Bundle to resolve USDZ URLs from. Pass
    ///   `.main` from app code; tests should pass their own bundle
    ///   (or any bundle that has no character USDZs) to drive the
    ///   `usdzNotFound` path.
    public init(bundle: Bundle = .main) {
        self.bundle = bundle
    }

    // MARK: - Public API

    /// Load `role` as the player-controllable entity.
    ///
    /// The returned entity:
    ///
    /// * has `PlayerComponent` + `PlayerInputComponent` attached so
    ///   `PlayerControlSystem` picks it up via its `EntityQuery`;
    /// * carries a `PerspectiveCamera` child at
    ///   `SIMD3<Float>(0, role.cameraHeight, 0)` (local space) so the
    ///   first-person view sits at the head;
    /// * is scaled so the mesh is ~1.5 m tall and positioned so the
    ///   feet sit at local Y = 0.
    ///
    /// - Throws: `LoaderError.usdzNotFound` if the bundle doesn't
    ///   contain `role.resourceBasename + ".usdz"`; `.underlying` for
    ///   any error surfaced by `Entity.init(contentsOf:withName:)`.
    /// - Precondition: `role.isPlayable == true`. Passing a non-
    ///   playable role silently returns the NPC-shape entity (no
    ///   camera / no input component); we would rather be permissive
    ///   here than crash a scene build.
    public func loadAsPlayer(_ role: CharacterRole) async throws -> Entity {
        let entity = try await loadBody(role: role)
        if role.isPlayable {
            attachPlayerRig(to: entity, role: role)
        }
        return entity
    }

    /// Load `role` as an NPC — no camera, no input component.
    ///
    /// The entity is scaled + feet-grounded the same way as the
    /// playable variant; callers wanting the idle-float breathing fake
    /// can add a `CharacterIdleFloatComponent` themselves (the Phase 2
    /// 脚本 decides which NPCs breathe, not the loader).
    public func loadAsNPC(_ role: CharacterRole) async throws -> Entity {
        try await loadBody(role: role)
    }

    /// Errors surfaced by the loader. Kept small and `Sendable` so
    /// callers can relay them across actors without wrapping.
    public enum LoaderError: Error, Sendable, Equatable {

        /// The bundle does not contain `basename.usdz`. Caller should
        /// check that the asset was added to the target's Copy
        /// Bundle Resources phase (or to the SPM `resources:` list
        /// for tests that really should ship the fixture).
        case usdzNotFound(basename: String)

        /// `Entity.init(contentsOf:withName:)` threw. The underlying
        /// error is wrapped as its `localizedDescription` so the
        /// `Equatable` conformance stays meaningful — RealityFoundation
        /// does not make its error types `Equatable`.
        case underlying(description: String)
    }

    // MARK: - Internals

    /// Resolve, load, normalise, name. Shared between `loadAsPlayer`
    /// and `loadAsNPC`; factored out so the two entry points only
    /// differ in the optional player-rig step.
    private func loadBody(role: CharacterRole) async throws -> Entity {
        guard let url = bundle.url(
            forResource: role.resourceBasename,
            withExtension: "usdz"
        ) else {
            throw LoaderError.usdzNotFound(basename: role.resourceBasename)
        }

        let entity: Entity
        do {
            entity = try await Entity(contentsOf: url, withName: role.rawValue)
        } catch {
            throw LoaderError.underlying(description: String(describing: error))
        }

        entity.name = role.rawValue
        normaliseScaleAndGround(entity, targetHeight: role.cameraHeight)
        return entity
    }

    /// Scale `entity` so its tallest axis (Y) measures `targetHeight`
    /// and translate it so the feet (minimum Y after scaling) sit at
    /// local Y = 0.
    ///
    /// Meshy text-to-3d preview assets do not ship with a known real-
    /// world scale (see MeshyGenerationLog §"Scale unknown"). Every
    /// spawned character therefore has to go through this pass or
    /// they'll render at 30 m tall or 3 cm tall. We measure
    /// `visualBounds(relativeTo: nil)` which walks the entity tree,
    /// scale uniformly, then re-measure and translate.
    ///
    /// Tiny-original-height guard: `max(originalHeight, 0.01)` avoids
    /// a divide-by-zero if the USDZ somehow has zero-extent bounds
    /// (headless or empty asset). 1 cm floors the denominator while
    /// still producing a visible entity if the asset is bizarre.
    private func normaliseScaleAndGround(_ entity: Entity, targetHeight: Float) {
        let preScaleBounds = entity.visualBounds(relativeTo: nil)
        let originalHeight = preScaleBounds.extents.y
        let scaleFactor = targetHeight / max(originalHeight, 0.01)
        entity.scale *= SIMD3<Float>(repeating: scaleFactor)

        // Re-measure now that the transform changed; `visualBounds`
        // reports in the *reference* entity's space, and with
        // `relativeTo: nil` that's world space — including our just-
        // applied scale.
        let postScaleBounds = entity.visualBounds(relativeTo: nil)
        // Offset the entity so postScaleBounds.min.y maps to 0 in
        // world space. Keep X / Z as-is: the outcrop / scene decides
        // where the character stands laterally.
        entity.position.y -= postScaleBounds.min.y
    }

    /// Mount `PlayerComponent`, `PlayerInputComponent`, and the head-
    /// height `PerspectiveCamera` child on an already-loaded body.
    ///
    /// Kept separate from `loadBody` so NPC loads pay nothing for the
    /// player rig, and so Phase 3 scene bootstraps that want to swap
    /// between "control" and "cutscene" rigs can call this post hoc.
    private func attachPlayerRig(to entity: Entity, role: CharacterRole) {
        entity.components.set(PlayerComponent())
        entity.components.set(PlayerInputComponent())

        let camera = PerspectiveCamera()
        camera.position = SIMD3<Float>(0, role.cameraHeight, 0)
        entity.addChild(camera)
    }
}
