// GeologyLayerComponent.swift
// SDGGameplay · Geology
//
// ECS component attached to every layer entity produced by
// `GeologySceneBuilder`. Future raycast-based drilling (see
// GDD §1.3 and the legacy `DrillingCylinderGenerator.cs` algorithm)
// will look this up on each hit collider to reconstruct per-layer
// metadata — layerId, thickness, etc. — without a side channel.
//
// Pure data. No behaviour, no RealityKit-side references; the render
// geometry is owned by the sibling `ModelComponent` on the same entity.

import Foundation
import RealityKit

/// ECS component carrying stable, read-only geological metadata for
/// a single outcrop layer entity.
///
/// A layer entity is a simple axis-aligned box (see
/// `GeologySceneBuilder`) whose visual material reflects the
/// `colorRGB` field. This component is what future systems will query
/// when a drill-down raycast hits the entity: the component's
/// `layerId` serves as the stable join key into any external catalog
/// (sample drops, encyclopedia entries, teaching notes).
///
/// All members are `let` — a running entity's geology identity does
/// not mutate. To change a layer, rebuild the outcrop.
public struct GeologyLayerComponent: Component, Sendable {

    /// Stable, dotted identifier for the layer, e.g. `"aobayama.topsoil"`.
    /// Must be unique inside a single outcrop. Used as a join key into
    /// external tables (localisation, sample drops, teaching notes).
    public let layerId: String

    /// Localisation key for the human-facing layer name, resolved via
    /// `SDGCore.L10n`. Lives in the String Catalog, e.g.
    /// `"geology.layer.topsoil.name"`.
    public let nameKey: String

    /// Broad rock category; drives default physical properties and
    /// future encyclopedia filtering.
    public let layerType: LayerType

    /// Linear RGB in the 0…1 range. Unclamped intentionally so callers
    /// can pass emissive-ish values during debugging; the scene
    /// builder clamps before handing it to `SimpleMaterial`.
    public let colorRGB: SIMD3<Float>

    /// Layer thickness in metres, along the world Y axis.
    public let thickness: Float

    /// Depth of this layer's *top* face, measured from the outcrop
    /// origin (surface = 0, increasing downwards). Makes raycast
    /// depth-to-layer lookup O(1) without walking siblings.
    public let depthFromSurface: Float

    /// Designated initialiser. All fields are required — the component
    /// is meant to be built once in `GeologySceneBuilder` from a
    /// definition + computed geometry, never patched incrementally.
    public init(
        layerId: String,
        nameKey: String,
        layerType: LayerType,
        colorRGB: SIMD3<Float>,
        thickness: Float,
        depthFromSurface: Float
    ) {
        self.layerId = layerId
        self.nameKey = nameKey
        self.layerType = layerType
        self.colorRGB = colorRGB
        self.thickness = thickness
        self.depthFromSurface = depthFromSurface
    }
}
