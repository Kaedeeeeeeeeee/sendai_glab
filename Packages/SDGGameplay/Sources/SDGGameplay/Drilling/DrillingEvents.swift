// DrillingEvents.swift
// SDGGameplay · Drilling
//
// Cross-layer events for the drilling pipeline. See ADR-0003 for the
// event-bus rationale; ADR-0001 for why cross-module calls go through
// events rather than direct references.
//
// ## Event flow
//
//     DrillingStore  ── DrillRequested ─▶  DrillingOrchestrator
//                                               │
//                                               │ (runs detection,
//                                               │  builds SampleItem)
//                                               ▼
//                          SampleCreatedEvent ─▶ InventoryStore
//                          DrillCompleted     ─▶ DrillingStore (status)
//                          DrillFailed        ─▶ DrillingStore (status)
//
// Keeping the events in their own file (rather than next to the
// orchestrator) matches the pattern already set by
// `Samples/SampleCreatedEvent.swift`: the event surface is a public
// contract that outlives any one producer/consumer.

import Foundation
import SDGCore

/// Request a drill pass. Published by `DrillingStore` the moment the
/// user taps the HUD drill button; consumed by `DrillingOrchestrator`
/// which owns the scene-side detection + sample construction.
///
/// Why an event rather than a direct call? `DrillingStore` has no
/// reference to the active RealityKit scene (and must not — stores
/// cannot import RealityKit entities per ADR-0001). The orchestrator
/// does. Routing through the bus keeps the Store framework-free.
public struct DrillRequested: GameEvent, Equatable {

    /// World-space start point of the drill, in metres.
    public let origin: SIMD3<Float>

    /// Unit direction vector the drill travels. Phase 1 is always
    /// straight down `(0, -1, 0)`; future tool variants (horizontal
    /// core, drone-mounted) will vary this.
    public let direction: SIMD3<Float>

    /// Maximum drill depth along `direction`, in metres. Positive;
    /// `<= 0` values are treated as a no-op by the orchestrator.
    public let maxDepth: Float

    /// Wall-clock timestamp at request time. Carried so subscribers
    /// (analytics, replay) can correlate the request with the later
    /// `DrillCompleted` or `DrillFailed` without re-stamping.
    public let requestedAt: Date

    public init(
        origin: SIMD3<Float>,
        direction: SIMD3<Float>,
        maxDepth: Float,
        requestedAt: Date
    ) {
        self.origin = origin
        self.direction = direction
        self.maxDepth = maxDepth
        self.requestedAt = requestedAt
    }
}

/// Published by `DrillingOrchestrator` when a drill pass produced a
/// sample. Fired in addition to `SampleCreatedEvent`:
///
/// - `SampleCreatedEvent` carries the full `SampleItem`. Its single
///   business subscriber is `InventoryStore`.
/// - `DrillCompleted` carries only id/metadata summary and is intended
///   for side-channel subscribers — HUD flash, SFX trigger, analytics,
///   and the `DrillingStore` status machine.
///
/// Splitting the two lets the inventory path stay narrow (1 event, 1
/// consumer) while still giving everyone else something lightweight to
/// listen to.
public struct DrillCompleted: GameEvent, Equatable {

    /// Id of the sample that was just created. Matches `SampleItem.id`.
    public let sampleId: UUID

    /// How many layers the drill cut through. `0` is impossible here —
    /// a zero-layer result takes the `DrillFailed` path instead.
    public let layerCount: Int

    /// Actual depth drilled, in metres. For a successful drill this
    /// equals the supplied `maxDepth` clamped by the deepest layer the
    /// ray crossed; see `DrillingOrchestrator.performDrill`.
    public let totalDepth: Float

    public init(sampleId: UUID, layerCount: Int, totalDepth: Float) {
        self.sampleId = sampleId
        self.layerCount = layerCount
        self.totalDepth = totalDepth
    }
}

/// Published by `DrillingOrchestrator` when a drill pass could not
/// produce a sample (zero layers hit, or the scene was unavailable).
///
/// `reason` is a short machine-readable tag (not a localised string):
/// consumers can branch on it, and UI code resolves the user-facing
/// text via `LocalizationService`. Current tags:
///   - `"no_layers"`   — ray missed every geology layer
///   - `"scene_unavailable"` — orchestrator had no scene / entity root
public struct DrillFailed: GameEvent, Equatable {

    /// World-space origin where the drill was attempted. Mirrors the
    /// `DrillRequested.origin` so subscribers can correlate without
    /// joining to the original request.
    public let origin: SIMD3<Float>

    /// Short machine-readable reason tag. See the type's doc comment
    /// for the vocabulary.
    public let reason: String

    public init(origin: SIMD3<Float>, reason: String) {
        self.origin = origin
        self.reason = reason
    }
}
