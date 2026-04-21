// SampleItem.swift
// SDGGameplay
//
// Player-facing inventory record for a single geological sample core.
// Produced by `DrillingSystem` (P1-T4) when the player finishes a drill
// cycle, consumed by `InventoryStore` (this task, P1-T6), persisted via
// `InventoryPersistence`, and eventually displayed by the inventory UI.
//
// Design notes vs. legacy Unity `SampleItem.cs`:
// - Value type, fully `Codable`, no `MonoBehaviour` / scene references.
// - No mirror bookkeeping of "is this sample in world vs. inventory";
//   placing a sample back in the world will be handled via a separate
//   event (P1-T7+), not a state flag on the record itself.
// - No preview `Sprite` / `Texture2D`; the inventory UI renders previews
//   from the structured `layers` data (stacked cylinders) instead of
//   baking a raster.

import Foundation

/// A single player-collected geological sample. Value type.
///
/// `SampleItem` is the canonical record that flows from the drilling ECS
/// into `InventoryStore` and onto disk. Conforms to:
/// - `Identifiable` via `id: UUID` so SwiftUI `ForEach` / diffing works.
/// - `Codable` for `UserDefaults` persistence + event-log replay.
/// - `Sendable` because it crosses the `EventBus` actor boundary.
/// - `Hashable` so UIs can hold selection sets.
public struct SampleItem: Identifiable, Codable, Sendable, Hashable {

    /// Stable unique identifier, assigned at creation time. Never rotated.
    public let id: UUID

    /// Wall-clock timestamp when the sample was drilled. Displayed on the
    /// inventory tile and used to sort by collection order.
    public let createdAt: Date

    /// World-space position of the drill point where the sample was
    /// collected, in meters. The inventory uses this to plot collection
    /// sites on a future map view; the microscope view re-locates the
    /// source outcrop for context.
    public let drillLocation: SIMD3<Float>

    /// Total drilled depth for this sample, in meters. Equals
    /// `layers.map(\.thickness).reduce(0, +)` for well-formed samples but
    /// stored explicitly so a tool-reported depth (e.g. drill tower 0-10m
    /// slot) survives even if layers are later re-bucketed.
    public let drillDepth: Float

    /// Layers composing the sample core, ordered top-to-bottom (ascending
    /// `entryDepth`). May be empty if the drill hit empty air — the
    /// inventory still records the attempt.
    public let layers: [SampleLayerRecord]

    /// Optional user-authored note. Mutable so the inventory UI can let
    /// the player annotate without re-creating the whole record.
    public var customNote: String?

    public init(
        id: UUID = UUID(),
        createdAt: Date = Date(),
        drillLocation: SIMD3<Float>,
        drillDepth: Float,
        layers: [SampleLayerRecord],
        customNote: String? = nil
    ) {
        self.id = id
        self.createdAt = createdAt
        self.drillLocation = drillLocation
        self.drillDepth = drillDepth
        self.layers = layers
        self.customNote = customNote
    }

    /// Localization key for the default display name when the user has
    /// not supplied a `customNote`. The UI is expected to resolve it via
    /// `LocalizationService.text(_:)` and substitute depth / first-layer
    /// information itself — this type stays presentation-free.
    public var defaultDisplayNameKey: String { "sample.defaultName" }
}
