// LayerIntersection.swift
// SDGGameplay · Geology
//
// Output datum of `GeologyDetectionSystem.detectLayers(...)`. Describes
// one geological layer's entry/exit along a downward drilling ray,
// expressed both as scalar depths (metres from the drill's origin) and
// as world-space points (for future sample icon placement and debug
// overlays).
//
// Pure value type; `Hashable` + `Sendable` so it can cross actors,
// participate in `Set`/dictionary keys, and round-trip through
// `XCTAssertEqual`. No RealityKit dependency so this symbol is usable
// from CI headless unit tests.

import Foundation

/// One layer's contribution to a drill-down ray, in the order it would
/// be encountered from the drill's `origin` downwards.
///
/// The struct is denormalised on purpose — `nameKey` and `colorRGB` are
/// copied out of the originating `GeologyLayerComponent` so downstream
/// code (HUD, sample icon renderer, encyclopedia unlock trigger) does
/// not need to re-query the scene graph, which may have changed by the
/// time the intersection is consumed.
///
/// ### Invariants
/// - `entryDepth >= 0`
/// - `exitDepth >= entryDepth`
/// - `thickness == exitDepth - entryDepth` (numeric equality up to the
///   construction-site arithmetic; the field is stored rather than
///   computed so `Hashable`/`Equatable` stay symmetric with the points).
public struct LayerIntersection: Sendable, Hashable {

    /// Stable layer identifier, copied from the originating
    /// `GeologyLayerComponent.layerId`. Join key into sample drops,
    /// encyclopedia entries, and teaching notes.
    public let layerId: String

    /// Localisation key for the layer's display name. Also copied from
    /// the component so the UI never has to chase a weak reference back
    /// into the scene.
    public let nameKey: String

    /// 0…1 RGB. Same semantics as `GeologyLayerComponent.colorRGB`.
    public let colorRGB: SIMD3<Float>

    /// Depth in metres along the drill ray at which the ray *enters*
    /// this layer, measured from the drill's world origin. Always
    /// `>= 0` — the algorithm clamps at the origin so layers entirely
    /// above the drill point produce no intersection rather than a
    /// negative depth.
    public let entryDepth: Float

    /// Depth in metres along the drill ray at which the ray *exits*
    /// this layer. Always `>= entryDepth`; clamped above by the
    /// caller-supplied `maxDepth` so the final segment's tail sits on
    /// the drill's bottom face.
    public let exitDepth: Float

    /// `exitDepth - entryDepth`. Stored rather than computed so
    /// `Hashable`/`Equatable` remain self-consistent (two intersections
    /// with the same entry/exit but different rounding in thickness
    /// would otherwise be considered unequal by the synthesized
    /// conformance — not a real concern at current tolerances, but
    /// cheap insurance).
    public let thickness: Float

    /// World-space point where the ray enters the layer.
    /// = `origin + direction * entryDepth` at construction time.
    public let entryPoint: SIMD3<Float>

    /// World-space point where the ray exits the layer.
    /// = `origin + direction * exitDepth` at construction time.
    public let exitPoint: SIMD3<Float>

    /// Memberwise initialiser. All fields are required because a
    /// `LayerIntersection` with a missing `nameKey` or `colorRGB` would
    /// propagate a hole straight into UI code that assumes both are
    /// populated.
    public init(
        layerId: String,
        nameKey: String,
        colorRGB: SIMD3<Float>,
        entryDepth: Float,
        exitDepth: Float,
        thickness: Float,
        entryPoint: SIMD3<Float>,
        exitPoint: SIMD3<Float>
    ) {
        self.layerId = layerId
        self.nameKey = nameKey
        self.colorRGB = colorRGB
        self.entryDepth = entryDepth
        self.exitDepth = exitDepth
        self.thickness = thickness
        self.entryPoint = entryPoint
        self.exitPoint = exitPoint
    }

    /// Midpoint of the segment, in world space. Handy for anchoring the
    /// future "layer icon" sprite at the visual centre of a sample
    /// core.
    public var centerPoint: SIMD3<Float> {
        (entryPoint + exitPoint) * 0.5
    }

    /// Whether this intersection represents a meaningful slice of
    /// material. Anything thinner than 1 cm is most likely a
    /// floating-point crumb left over from an intersection that was
    /// clipped to zero by `origin`/`maxDepth` bounds; the detection
    /// pipeline filters these out before returning, but the predicate
    /// stays public so adjacent systems can re-check if they cache
    /// intersections from an older run.
    public var isValid: Bool { thickness > 0.01 }
}
