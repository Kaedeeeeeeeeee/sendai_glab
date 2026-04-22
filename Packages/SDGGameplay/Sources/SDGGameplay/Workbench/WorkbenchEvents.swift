// WorkbenchEvents.swift
// SDGGameplay · Workbench
//
// Cross-layer events published by `WorkbenchStore` for the Phase 2 Beta
// microscope / thin-section UI. Kept in a dedicated file (rather than
// inline with the Store) so the event shape can evolve independently of
// the Store implementation, and so downstream subscribers — Quest system
// in particular — can import the event type without pulling in the
// Store.
//
// ADR-0001 §"Event Bus" compliance: both types are `GameEvent`
// conformers (`Sendable + Codable`), carry only plain data, and never
// reach into live gameplay objects (Entities, other Stores).

import Foundation
import SDGCore

/// Published when the player opens the workbench / microscope UI.
///
/// Subscribers in Phase 2 Beta are limited to optional analytics;
/// Phase 3 Story may use it to gate a one-time tutorial popup the
/// first time the workbench is opened.
public struct WorkbenchOpened: GameEvent, Equatable {

    /// Wall-clock timestamp at which the workbench was opened. Carried
    /// so replay logs correlate it with nearby quest / dialogue events.
    public let openedAt: Date

    public init(openedAt: Date = Date()) {
        self.openedAt = openedAt
    }
}

/// Published when the player has selected a sample **and** a specific
/// layer inside it — i.e. "looked at this layer's thin section".
///
/// This is the hook the Quest system (sibling subagent) listens for to
/// advance "analyze N samples" objectives, and the Encyclopedia system
/// will use it to auto-unlock layer entries. Phase 2 Beta only emits
/// the event — no in-tree subscriber lands in this task.
public struct SampleAnalyzed: GameEvent, Equatable {

    /// The id of the `SampleItem` the player is inspecting.
    public let sampleId: UUID

    /// The stable id of the inspected geological layer
    /// (`SampleLayerRecord.layerId`). Matches the `layerId` carried
    /// by the corresponding `GeologyLayerComponent`, so subscribers can
    /// cross-reference the source outcrop.
    public let layerId: String

    /// Wall-clock timestamp at which the analysis occurred. Useful for
    /// deduplicating rapid-fire selections (the player flicking
    /// through layers) before awarding a single quest tick.
    public let analyzedAt: Date

    public init(
        sampleId: UUID,
        layerId: String,
        analyzedAt: Date = Date()
    ) {
        self.sampleId = sampleId
        self.layerId = layerId
        self.analyzedAt = analyzedAt
    }
}
