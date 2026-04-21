// DrillingSystem.swift
// SDGGameplay · Drilling
//
// Event-driven orchestrator that turns a `DrillRequested` event into a
// concrete `SampleItem`, then republishes the result onto the
// `EventBus` so the inventory (and any HUD / SFX subscribers) can
// pick it up.
//
// ## Naming: why `DrillingOrchestrator`, not `DrillingSystem`
//
// RealityKit's `System` protocol is a per-frame ECS updater; adopting
// that name for an event-driven service invites future readers to
// look for a `update(context:)` method that will never exist. The
// file name is kept as `DrillingSystem.swift` to match the Phase 1
// file plan and to make `git blame` continuity easy, but the *type*
// is `DrillingOrchestrator` — it orchestrates a chain of calls
// (`detectLayers` → `buildSampleItem` → `publish`) in response to one
// external event.
//
// ## Entity vs Scene injection
//
// Two valid knobs exist for "where does the orchestrator read the
// world from?":
//
//   1. `() -> RealityKit.Scene?` — what the production drilling
//      path ultimately touches; Scene is where `performQuery` lives.
//   2. `() -> Entity?` — hands the orchestrator a subtree root that
//      `GeologyDetectionSystem.detectLayers(under:)` walks directly.
//
// Option 2 is strictly more testable (no live scene required) and the
// production call site — the RealityView closure — already has the
// outcrop root entity on hand, so the extra flexibility isn't traded
// against ergonomics. We take option 2. If a future caller really
// wants to hand over a whole scene, the closure can still walk the
// scene graph themselves and hand back its root, or we can add a
// second initialiser variant.
//
// ## Failure mode vocabulary
//
// `DrillError` has exactly two cases because the orchestrator's
// failure branches collapse to "I had no world to work with" and "I
// had a world but the drill missed everything". Anything richer (drill
// battery empty, tool locked, etc.) belongs in the Store's intent
// validation layer, not here.

import Foundation
import RealityKit
import SDGCore

/// Failures the drilling orchestrator can surface to callers of
/// `performDrill(...)`.
///
/// Kept tiny on purpose: orchestration is a transport layer, not a
/// game-rules gate. Rules (out of battery, tool cooldown) belong in
/// `DrillingStore.intent(_:)` before the request is even fired.
public enum DrillError: Error, Sendable, Equatable {

    /// No layer intersected the drill ray. The drill physically
    /// reached something — a scene was available — but the target
    /// point was open air / off the outcrop.
    case noLayers

    /// The orchestrator has no world to read from. Either the
    /// `outcropRootProvider` closure returned `nil` (scene not yet
    /// loaded / already torn down) or the tree under the returned
    /// root carried no geology entities at all.
    case sceneUnavailable
}

/// Event-driven orchestrator for the drilling pipeline.
///
/// Despite the surrounding file being named `DrillingSystem.swift`,
/// this type is **not** a `RealityKit.System` — see the file header
/// for the naming rationale. It is a plain `@MainActor` service that:
///
///   1. subscribes to `DrillRequested` on an injected `EventBus`;
///   2. resolves the current outcrop root via the provider closure
///      passed at construction;
///   3. runs `GeologyDetectionSystem.detectLayers(under:)` against
///      that root;
///   4. constructs a `SampleItem` from the resulting intersections;
///   5. publishes `SampleCreatedEvent` (inventory feed) followed by
///      `DrillCompleted` (status / SFX / analytics).
///
/// On the failure path it publishes `DrillFailed` with a machine-
/// readable reason tag.
///
/// ### Lifecycle
///
/// Like `InventoryStore`, the orchestrator does not subscribe in
/// `init`. Callers invoke ``start()`` once the bus is hot, and
/// ``stop()`` during teardown. `start` is idempotent — repeated calls
/// do not double-subscribe. Swift does not allow `async` work in
/// `deinit`, so explicit teardown is required; the app-lifetime
/// singleton usage pattern makes this a non-issue in practice, and
/// tests tear down explicitly.
///
/// ### Why `@MainActor`?
///
/// `detectLayers(under:)` reads RealityKit `Entity.visualBounds`,
/// which is `@MainActor`-isolated in the SDK. The orchestrator runs
/// on the main actor so it can do that safely; the bus handler
/// closure hops back into the actor via `await self?...`.
@MainActor
public final class DrillingOrchestrator {

    // MARK: - Dependencies (injected, not global)

    /// Bus the orchestrator subscribes to (for `DrillRequested`) and
    /// publishes onto (for `SampleCreatedEvent`, `DrillCompleted`,
    /// `DrillFailed`).
    private let eventBus: EventBus

    /// Pull-style accessor for the scene's current outcrop root.
    /// Closure so the orchestrator does not retain a scene entity
    /// across reloads: the caller (typically the RealityView update
    /// closure or a dedicated `WorldRouter`) owns the lifetime.
    private let outcropRootProvider: @MainActor () -> Entity?

    /// Active subscription, `nil` before `start()` and after `stop()`.
    /// Matches the lifecycle pattern from `InventoryStore`.
    private var subscriptionToken: SubscriptionToken?

    // MARK: - Init

    /// - Parameters:
    ///   - eventBus: Shared `EventBus`. Typically injected from
    ///     `AppEnvironment`.
    ///   - outcropRootProvider: `@MainActor` closure the orchestrator
    ///     calls whenever it needs to read the world. Returning `nil`
    ///     surfaces as `DrillError.sceneUnavailable` and publishes
    ///     `DrillFailed` with reason `"scene_unavailable"`.
    public init(
        eventBus: EventBus,
        outcropRootProvider: @escaping @MainActor () -> Entity?
    ) {
        self.eventBus = eventBus
        self.outcropRootProvider = outcropRootProvider
    }

    // MARK: - Lifecycle

    /// Subscribe to `DrillRequested`. Idempotent: a second call is a
    /// no-op while the first subscription is still alive.
    public func start() async {
        guard subscriptionToken == nil else { return }
        subscriptionToken = await eventBus.subscribe(DrillRequested.self) { [weak self] event in
            // Handlers execute off the orchestrator's actor; hop back
            // in explicitly before touching `self`.
            await self?.handleDrillRequested(event)
        }
    }

    /// Drop the subscription. Safe to call repeatedly; safe to call
    /// without a prior `start()`.
    public func stop() async {
        guard let token = subscriptionToken else { return }
        await eventBus.cancel(token)
        subscriptionToken = nil
    }

    // MARK: - Event handler

    /// Translate a `DrillRequested` into a drill pass. Broken out
    /// from the subscribe closure so the actor-hopped body stays
    /// easy to reason about.
    private func handleDrillRequested(_ event: DrillRequested) async {
        _ = await performDrill(
            origin: event.origin,
            direction: event.direction,
            maxDepth: event.maxDepth
        )
    }

    // MARK: - Core drill pass (also public for tests / manual trigger)

    /// Execute one drill pass end-to-end, publishing the resulting
    /// events on the bus before returning.
    ///
    /// Exposed `public` so tests can drive it directly without
    /// round-tripping through the event bus; production use goes
    /// through the `DrillRequested` handler wired in `start()`.
    ///
    /// - Parameters:
    ///   - origin: World-space drill start point.
    ///   - direction: Unit direction vector. Phase 1 = `(0, -1, 0)`.
    ///   - maxDepth: Max metres along `direction` to consider.
    /// - Returns: `.success(sample)` on a hit (and the bus has
    ///   already seen both `SampleCreatedEvent` and
    ///   `DrillCompleted`); `.failure(DrillError)` otherwise (the
    ///   bus has already seen `DrillFailed`).
    @discardableResult
    public func performDrill(
        origin: SIMD3<Float>,
        direction: SIMD3<Float>,
        maxDepth: Float
    ) async -> Result<SampleItem, DrillError> {
        guard let root = outcropRootProvider() else {
            await eventBus.publish(
                DrillFailed(origin: origin, reason: "scene_unavailable")
            )
            return .failure(.sceneUnavailable)
        }

        let intersections = GeologyDetectionSystem.detectLayers(
            under: root,
            from: origin,
            direction: direction,
            maxDepth: maxDepth
        )

        guard !intersections.isEmpty else {
            await eventBus.publish(
                DrillFailed(origin: origin, reason: "no_layers")
            )
            return .failure(.noLayers)
        }

        let sample = Self.buildSampleItem(
            at: origin,
            depth: maxDepth,
            intersections: intersections
        )

        // Order matters: publish the sample *first* so the inventory
        // ingest already happened by the time any `DrillCompleted`
        // subscriber (e.g. HUD "new sample!" toast) reads the
        // inventory state. Both `publish` calls await their
        // subscribers, so sequencing is deterministic.
        await eventBus.publish(SampleCreatedEvent(sample: sample))
        await eventBus.publish(
            DrillCompleted(
                sampleId: sample.id,
                layerCount: sample.layers.count,
                totalDepth: sample.drillDepth
            )
        )

        return .success(sample)
    }

    // MARK: - Pure construction (static, trivially unit-testable)

    /// Build a `SampleItem` from a set of layer intersections.
    ///
    /// Pure function — no RealityKit, no bus, no store. Kept `static`
    /// so tests can invoke it without standing up an orchestrator and
    /// so the conversion contract is pinned in one obvious place.
    ///
    /// The mapping is intentionally lossless for the fields
    /// downstream consumers care about (`layerId`, `nameKey`,
    /// `colorRGB`, `thickness`, `entryDepth`); the geometric
    /// `entryPoint` / `exitPoint` stay on the intersection because
    /// the sample UI reconstructs its own stacked-cylinder preview
    /// from `thickness`.
    ///
    /// - Parameters:
    ///   - origin: World-space drill start point.
    ///   - depth: Requested drill depth (metres). Stored verbatim on
    ///     the sample so the tool-reported depth survives even if
    ///     layers were clipped by `maxDepth` inside the detector.
    ///   - intersections: Layers crossed, already ordered by
    ///     ascending `entryDepth` (the detector guarantees this).
    /// - Returns: A fresh `SampleItem` with a new `UUID` and
    ///   `createdAt = Date()`.
    public static func buildSampleItem(
        at origin: SIMD3<Float>,
        depth: Float,
        intersections: [LayerIntersection]
    ) -> SampleItem {
        let records = intersections.map { intersection in
            SampleLayerRecord(
                layerId: intersection.layerId,
                nameKey: intersection.nameKey,
                colorRGB: intersection.colorRGB,
                thickness: intersection.thickness,
                entryDepth: intersection.entryDepth
            )
        }
        return SampleItem(
            id: UUID(),
            createdAt: Date(),
            drillLocation: origin,
            drillDepth: depth,
            layers: records,
            customNote: nil
        )
    }
}
