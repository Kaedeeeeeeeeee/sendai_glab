// GeologyLayerDefinition.swift
// SDGGameplay · Geology
//
// JSON data contract for the procedural outcrop builder. Each
// configuration bundle (see `Resources/Geology/test_outcrop.json`)
// decodes into a `TestOutcropConfig`, which `GeologySceneBuilder` then
// walks to produce the RealityKit entity tree.
//
// Keeping the JSON schema here — next to the runtime component — makes
// the mapping obvious and diffs self-contained. The types are
// deliberately `Sendable` so config values can cross actors freely.

import Foundation

// MARK: - Per-layer definition

/// One layer in a procedural outcrop, as it appears in JSON.
///
/// The `id` doubles as the stable `GeologyLayerComponent.layerId` the
/// scene builder stamps onto the generated entity; callers must keep
/// it unique within a single `TestOutcropConfig`.
///
/// `colorHex` accepts the common `"#RRGGBB"` form, case-insensitive.
/// The leading `#` is optional in JSON but canonical in docs; parsing
/// lives in `GeologySceneBuilder.parseHex(_:)`.
public struct GeologyLayerDefinition: Codable, Sendable, Identifiable {

    /// Unique, dotted identifier (e.g. `"aobayama.topsoil"`).
    public let id: String

    /// Localisation key for the layer's human-facing display name,
    /// resolved at render time via `SDGCore.L10n`.
    public let nameKey: String

    /// Broad rock category (`"Soil"`, `"Sedimentary"`, etc.).
    public let type: LayerType

    /// Hex-encoded RGB colour (`"#AABBCC"`). Parsed at scene-build
    /// time; decoding here only validates the string is present, not
    /// that its contents are valid hex. Malformed colours surface as
    /// a `GeologySceneBuilderError.invalidColorHex` at build time —
    /// that gives us better error messages than forcing hex parsing
    /// through a `Decoder` throwing path.
    public let colorHex: String

    /// Layer thickness in metres, along world Y.
    public let thickness: Float

    /// Memberwise init exposed publicly so tests and in-code configs
    /// can synthesise definitions without round-tripping through JSON.
    public init(
        id: String,
        nameKey: String,
        type: LayerType,
        colorHex: String,
        thickness: Float
    ) {
        self.id = id
        self.nameKey = nameKey
        self.type = type
        self.colorHex = colorHex
        self.thickness = thickness
    }
}

// MARK: - Outcrop bundle

/// Top-level config bundle decoded from a Phase 1 outcrop JSON.
///
/// Layers are ordered **top-to-bottom**: the first element is the
/// surface, subsequent elements stack downwards with cumulative
/// thickness. The scene builder relies on this ordering to compute
/// each layer's `depthFromSurface` without any sorting step.
public struct TestOutcropConfig: Codable, Sendable {

    /// Short identifier; the scene builder uses it to name the root
    /// entity (`"Outcrop_<name>"`) so debug overlays show which
    /// outcrop is which.
    public let name: String

    /// World-space anchor where the outcrop's top-centre sits. The
    /// builder places the root entity here; individual layers stack
    /// below it along -Y.
    public let origin: SIMD3<Float>

    /// Layers in top-to-bottom order (surface first).
    public let layers: [GeologyLayerDefinition]

    /// Memberwise init kept `public` so unit tests can build configs
    /// without JSON round-trips.
    public init(
        name: String,
        origin: SIMD3<Float>,
        layers: [GeologyLayerDefinition]
    ) {
        self.name = name
        self.origin = origin
        self.layers = layers
    }
}
