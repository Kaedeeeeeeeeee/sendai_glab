// SampleLayerRecord.swift
// SDGGameplay
//
// A single geological layer slice recorded inside a `SampleItem`. Layers
// are ordered top-to-bottom within the sample core and carry the minimum
// data the UI needs to render a stacked-cylinder preview plus localized
// label.
//
// This mirrors (and shrinks) `SampleItem.LayerInfo` from the legacy Unity
// project (`Assets/Scripts/SampleSystem/SampleItem.cs`), which stored
// heavyweight `Color` + `Material` references. Here we keep pure data:
// an RGB triple (no alpha — samples are always opaque) and an L10n key
// so UI text stays translation-ready (AGENTS.md §5).

import Foundation

/// One layer's worth of data inside a geological sample core.
///
/// All stored properties are value types so `SampleLayerRecord` round-trips
/// losslessly through `Codable` / `UserDefaults` persistence.
///
/// ### Coordinate convention
/// - `thickness` is the vertical extent of *this* layer inside the
///   sample core, in meters.
/// - `entryDepth` is the offset from the top of the sample to the top of
///   this layer, in meters. Layers are ordered by increasing `entryDepth`.
///
/// ### Cross-reference
/// `layerId` must match the `layerId` carried by the matching
/// `GeologyLayerComponent` in the ECS world; this is how a sample links
/// back to its source outcrop for the encyclopedia / microscope views.
public struct SampleLayerRecord: Codable, Sendable, Hashable {

    /// Stable id of the source geological layer in the world. Must equal
    /// the `layerId` on the corresponding `GeologyLayerComponent`.
    public let layerId: String

    /// Localization key for the layer's display name. Resolved via
    /// `LocalizationService.text(_:)` at render time (AGENTS.md §5).
    public let nameKey: String

    /// Layer color as an RGB triple in sRGB 0...1. Alpha is intentionally
    /// omitted — geological samples never render translucent.
    public let colorRGB: SIMD3<Float>

    /// Vertical extent of this layer inside the sample core, in meters.
    public let thickness: Float

    /// Offset from the sample top to this layer's top, in meters.
    /// Ordered: successive records have strictly increasing `entryDepth`.
    public let entryDepth: Float

    public init(
        layerId: String,
        nameKey: String,
        colorRGB: SIMD3<Float>,
        thickness: Float,
        entryDepth: Float
    ) {
        self.layerId = layerId
        self.nameKey = nameKey
        self.colorRGB = colorRGB
        self.thickness = thickness
        self.entryDepth = entryDepth
    }
}
