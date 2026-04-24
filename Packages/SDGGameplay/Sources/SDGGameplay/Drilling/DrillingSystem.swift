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
// ## Two drill paths
//
// Phase 9 Part B introduced a second drill path alongside the original
// entity-tree one:
//
//   1. **Entity-tree (Phase 1)**: the orchestrator takes a subtree
//      root via `outcropRootProvider` and runs
//      `GeologyDetectionSystem.detectLayers(under:)` against the
//      `GeologyLayerComponent`-tagged children. Still used by the
//      `test_outcrop` demo and every pre-Phase-9 test.
//
//   2. **Region registry (Phase 9 Part B)**: the orchestrator consults
//      a `GeologyRegionRegistry` — keyed by the drill origin's XZ —
//      for the current tile's stratigraphic column, samples the
//      terrain Y via a caller-supplied closure, and feeds both into
//      the same pure detector. Production drilling uses this path so
//      drilling-anywhere-in-the-corridor works with DEM-aligned
//      surfaces.
//
// The Phase 9 path is preferred when a registry is wired in; otherwise
// the orchestrator falls through to the Phase 1 path.
//
// ## Failure mode vocabulary
//
// `DrillError` (moved to `DrillingErrors.swift` in Phase 9 Part B)
// names exactly the three observable failure surfaces: scene
// unavailable, empty column, and off-corridor. Anything richer (out
// of battery, tool cooldown) belongs in `DrillingStore.intent(_:)`
// before the request is fired.

import Foundation
import RealityKit
import SDGCore

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
    /// Only used on the legacy (Phase 1 `test_outcrop`) fallback path.
    /// Production (Phase 9 Part B) drilling goes through the
    /// `GeologyRegionRegistry` + `terrainSampler` closures, which do
    /// not need a scene-graph subtree.
    private let outcropRootProvider: @MainActor () -> Entity?

    /// Phase 9 Part B: optional region registry. When present, the
    /// orchestrator prefers the region-column path:
    ///
    ///   1. look up the region from the drill origin's XZ,
    ///   2. sample `terrainSampler` for the surface Y,
    ///   3. clip the region's column into `LayerSlab`s, and
    ///   4. run the same pure detector the entity-tree path uses.
    ///
    /// When `nil`, the orchestrator falls back to the legacy entity-
    /// tree path (`outcropRootProvider` → `detectLayers(under:)`), which
    /// is still used by Phase 1 tests and the `test_outcrop` demo.
    private let regionRegistry: GeologyRegionRegistry?

    /// Phase 9 Part B: optional terrain Y sampler. Paired with
    /// `regionRegistry` — the registry says "which column" and the
    /// sampler says "where the ground is at that XZ". Returning `nil`
    /// from this closure means "no terrain mesh covers the drill XZ":
    /// the orchestrator then falls back to the drill origin's Y as the
    /// surface, matching the Phase 1 behaviour where the drill head
    /// was placed on the outcrop surface by construction.
    private let terrainSampler: (@MainActor (SIMD2<Float>) -> Float?)?

    /// Active subscription, `nil` before `start()` and after `stop()`.
    /// Matches the lifecycle pattern from `InventoryStore`.
    private var subscriptionToken: SubscriptionToken?

    // MARK: - Init

    /// - Parameters:
    ///   - eventBus: Shared `EventBus`. Typically injected from
    ///     `AppEnvironment`.
    ///   - outcropRootProvider: `@MainActor` closure the orchestrator
    ///     calls whenever it needs to read the world on the legacy
    ///     entity-tree path. Returning `nil` from this *and* not
    ///     supplying a region registry surfaces as
    ///     `DrillError.sceneUnavailable` and publishes `DrillFailed`
    ///     with reason `"scene_unavailable"`.
    ///   - regionRegistry: Phase 9 Part B registry for per-tile
    ///     stratigraphic columns. When supplied, the orchestrator uses
    ///     the region-column path; without it, it falls back to the
    ///     entity-tree path and keeps Phase 1 behaviour.
    ///   - terrainSampler: Phase 9 Part B paired closure returning the
    ///     terrain surface Y at an (X, Z). Only consulted when
    ///     `regionRegistry` is non-`nil`.
    public init(
        eventBus: EventBus,
        outcropRootProvider: @escaping @MainActor () -> Entity?,
        regionRegistry: GeologyRegionRegistry? = nil,
        terrainSampler: (@MainActor (SIMD2<Float>) -> Float?)? = nil
    ) {
        self.eventBus = eventBus
        self.outcropRootProvider = outcropRootProvider
        self.regionRegistry = regionRegistry
        self.terrainSampler = terrainSampler
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
        // Phase 9 Part B: region-column path. Preferred when the
        // registry is wired in — it supports drill-anywhere inside
        // the PLATEAU corridor and surfaces `.outOfSurveyArea` as a
        // first-class failure.
        if let registry = regionRegistry {
            return await performDrillViaRegistry(
                registry: registry,
                origin: origin,
                direction: direction,
                maxDepth: maxDepth
            )
        }

        // Legacy (Phase 1) entity-tree path. Kept so the test outcrop
        // + the `GeologySceneBuilder` integration tests continue to
        // exercise the same orchestration code.
        guard let root = outcropRootProvider() else {
            await publishFailed(origin: origin, error: .sceneUnavailable)
            return .failure(.sceneUnavailable)
        }

        let intersections = GeologyDetectionSystem.detectLayers(
            under: root,
            from: origin,
            direction: direction,
            maxDepth: maxDepth
        )

        guard !intersections.isEmpty else {
            await publishFailed(origin: origin, error: .noLayers)
            return .failure(.noLayers)
        }

        return await publishSuccess(
            origin: origin,
            maxDepth: maxDepth,
            intersections: intersections
        )
    }

    // MARK: - Registry path (Phase 9 Part B)

    /// Drill flow that consults the `GeologyRegionRegistry` instead of
    /// an entity tree. Kept as a private helper so `performDrill` reads
    /// as a two-branch dispatch and the failure-publish bookkeeping
    /// stays in one obvious place.
    private func performDrillViaRegistry(
        registry: GeologyRegionRegistry,
        origin: SIMD3<Float>,
        direction: SIMD3<Float>,
        maxDepth: Float
    ) async -> Result<SampleItem, DrillError> {
        let xz = SIMD2<Float>(origin.x, origin.z)

        // Region lookup: "am I inside any surveyed tile?"
        guard let column = registry.column(forWorldXZ: xz) else {
            await publishFailed(origin: origin, error: .outOfSurveyArea)
            return .failure(.outOfSurveyArea)
        }

        // Surface Y: prefer the terrain sampler (real DEM elevation);
        // fall back to the drill origin's Y when the sampler reports
        // nothing (e.g. test harness with no terrain mesh). Using the
        // origin as the surface is a safe default because the caller
        // supplies the drill head at or just above the ground.
        let surfaceY = terrainSampler?(xz) ?? origin.y

        let slabs = column.clipToSlabs(
            surfaceY: surfaceY,
            maxDepth: maxDepth,
            xzCenter: xz
        )

        // Start the drill at the surface Y — not the caller's `origin.y`
        // — so shallow layers aren't erroneously skipped when the drill
        // head sits slightly above the DEM surface. The direction is
        // preserved; callers still supply `(0, -1, 0)` in practice.
        let rayOrigin = SIMD3<Float>(origin.x, surfaceY, origin.z)

        let intersections = GeologyDetectionSystem.computeIntersections(
            from: rayOrigin,
            direction: direction,
            maxDepth: maxDepth,
            layers: slabs
        )

        guard !intersections.isEmpty else {
            // `noLayers` rather than `outOfSurveyArea` — we *are* inside
            // a surveyed tile; the drill just happened to probe an
            // empty column. Current data never triggers this (every
            // region has at least a basement), but the branch exists
            // so a typo'd JSON doesn't fall through to success with
            // an empty sample.
            await publishFailed(origin: origin, error: .noLayers)
            return .failure(.noLayers)
        }

        return await publishSuccess(
            origin: origin,
            maxDepth: maxDepth,
            intersections: intersections
        )
    }

    // MARK: - Shared publish helpers

    /// Publish a `DrillFailed` event with the canonical reason tag for
    /// `error`. Centralised so the enum stays the single source of
    /// truth for the reason vocabulary (see `DrillingErrors.swift`).
    private func publishFailed(
        origin: SIMD3<Float>,
        error: DrillError
    ) async {
        await eventBus.publish(
            DrillFailed(origin: origin, reason: error.reasonTag)
        )
    }

    /// Build a `SampleItem`, publish `SampleCreatedEvent` + `DrillCompleted`
    /// (in that order — see the sequencing note), and return the
    /// success wrapped in a `Result`.
    ///
    /// Order matters: publish the sample *first* so the inventory
    /// ingest already happened by the time any `DrillCompleted`
    /// subscriber (e.g. HUD "new sample!" toast) reads the inventory
    /// state. Both `publish` calls await their subscribers, so
    /// sequencing is deterministic.
    private func publishSuccess(
        origin: SIMD3<Float>,
        maxDepth: Float,
        intersections: [LayerIntersection]
    ) async -> Result<SampleItem, DrillError> {
        let sample = Self.buildSampleItem(
            at: origin,
            depth: maxDepth,
            intersections: intersections
        )
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
