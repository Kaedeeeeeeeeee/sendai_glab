// SampleCreatedEvent.swift
// SDGGameplay
//
// Cross-layer event fired when a new geological sample has been produced.
// Publisher: `DrillingSystem` (P1-T4, not yet landed). Subscriber(s) in
// Phase 1: `InventoryStore` (this task, P1-T6).
//
// Event-driven design per ADR-0001: ECS systems never touch stores
// directly; they hand the store a plain value through the `EventBus`.
// Keeping this type defined inside the Samples module (next to
// `SampleItem`) means `SampleItem`'s shape and its companion event
// evolve together.

import Foundation
import SDGCore

/// Published when a new `SampleItem` has just been created and is ready
/// for the inventory to ingest.
///
/// The producer (drilling ECS) owns sample assembly; by the time this
/// event fires, `sample.id` is already final. The inventory simply
/// appends and persists.
public struct SampleCreatedEvent: GameEvent {

    /// The completed sample. Value-typed, so the payload is a full copy —
    /// subscribers cannot mutate the producer's state by reference.
    public let sample: SampleItem

    public init(sample: SampleItem) {
        self.sample = sample
    }
}
