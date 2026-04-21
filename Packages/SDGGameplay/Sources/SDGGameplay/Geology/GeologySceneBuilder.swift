// GeologySceneBuilder.swift
// SDGGameplay · Geology
//
// Translates a `TestOutcropConfig` into a RealityKit entity tree:
// one root `Entity` parenting N axis-aligned box `ModelEntity`s,
// one per geological layer, each carrying a `GeologyLayerComponent`
// so raycast-based drilling (GDD §1.3) can recover metadata from
// a hit.
//
// Deliberately `enum` + `static func` — the builder is a pure
// translation step with no hidden state; a `struct` with stored
// dependencies would imply lifetime management we do not need.

import Foundation
import RealityKit

#if canImport(UIKit)
import UIKit
/// Platform colour type used by `SimpleMaterial(color:…)`. Aliased so
/// the builder compiles on both iOS (UIKit) and macOS (AppKit, used by
/// CI's `swift test`).
private typealias PlatformColor = UIColor
#elseif canImport(AppKit)
import AppKit
/// See the UIKit branch above.
private typealias PlatformColor = NSColor
#endif

// MARK: - Errors

/// Failure modes raised by `GeologySceneBuilder`.
///
/// All cases carry the offending literal so error strings are
/// actionable (the CI log names the bad layer, not just "bad config").
public enum GeologySceneBuilderError: Error, Equatable, Sendable {

    /// The bundled resource could not be located. First associated
    /// value is the resource name, second is the expected extension.
    case resourceNotFound(name: String, ext: String)

    /// The JSON decoded but `colorHex` was not a valid `"#RRGGBB"`
    /// or `"RRGGBB"` string. Associated value is the bad literal.
    case invalidColorHex(String)
}

// MARK: - Builder

/// Pure translation from config data to a RealityKit entity tree.
///
/// See `buildOutcrop(from:)` for the core call; `loadOutcrop(namedResource:in:)`
/// is the usual bundle entry point.
///
/// ### Layout
///
/// The root entity is placed at `config.origin`. Each layer is a
/// 10 m × thickness × 10 m box, centred on its own mid-height. Layer
/// 0's *top* sits at y = 0 relative to the root, so the root's origin
/// represents the outcrop's surface; subsequent layers stack downward
/// along -Y. This matches the algorithm in the legacy Unity
/// `DrillingCylinderGenerator.cs` where raycasts start in the sky and
/// record decreasing hit.y values.
public enum GeologySceneBuilder {

    /// Horizontal footprint of every layer box, in metres. Layers are
    /// square (symmetric in X and Z) because the Phase 1 outcrop is
    /// unoriented — there's no "face" to look at. Widen once real
    /// strike/dip geometry lands (Phase 2).
    internal static let layerFootprint: Float = 10.0

    // MARK: Public entry points

    /// Build a RealityKit entity tree from a fully-decoded config.
    ///
    /// - Parameter config: The outcrop definition. Layers are consumed
    ///   in the supplied order (top-to-bottom).
    /// - Returns: The root entity. Caller is responsible for adding it
    ///   to a `RealityViewContent` or another entity; the builder never
    ///   touches the scene graph.
    public static func buildOutcrop(from config: TestOutcropConfig) -> Entity {
        let root = Entity()
        root.name = "Outcrop_\(config.name)"
        root.position = config.origin

        // Running depth of the top face of the next layer, measured
        // downward from the outcrop surface. Starts at 0 (surface).
        var depthFromSurface: Float = 0

        for definition in config.layers {
            let color = parseHexOrFallback(definition.colorHex)
            let layerEntity = makeLayerEntity(
                definition: definition,
                colorRGB: color,
                depthFromSurface: depthFromSurface
            )
            root.addChild(layerEntity)
            depthFromSurface += definition.thickness
        }

        return root
    }

    /// Convenience: decode `namedResource` from `bundle` and build.
    ///
    /// - Parameters:
    ///   - namedResource: File basename, without extension. `.json`
    ///     is assumed.
    ///   - bundle: Bundle to search. Pass `.module` from a package
    ///     that bundles the JSON, or `.main` for the app target.
    /// - Throws: `GeologySceneBuilderError.resourceNotFound` if the
    ///   file is missing; `DecodingError` if JSON is malformed; any
    ///   `Error` raised by `Data(contentsOf:)`.
    public static func loadOutcrop(
        namedResource: String,
        in bundle: Bundle
    ) throws -> Entity {
        guard let url = bundle.url(
            forResource: namedResource,
            withExtension: "json"
        ) else {
            throw GeologySceneBuilderError.resourceNotFound(
                name: namedResource,
                ext: "json"
            )
        }
        let data = try Data(contentsOf: url)
        let config = try JSONDecoder().decode(TestOutcropConfig.self, from: data)
        return buildOutcrop(from: config)
    }

    // MARK: Internal helpers (exposed for tests)

    /// Parse `"#RRGGBB"` or `"RRGGBB"` into linear-ish 0…1 RGB.
    ///
    /// Returns the parsed components on success, throws on anything
    /// else (wrong length, non-hex chars). Alpha is not represented —
    /// geology is opaque — and the conversion is a straight
    /// `byte / 255` with no gamma correction; that's good enough for
    /// Phase 1 Toon lighting and keeps the POC comparable against
    /// reference colour pickers.
    internal static func parseHex(_ hex: String) throws -> SIMD3<Float> {
        var s = hex
        if s.hasPrefix("#") { s.removeFirst() }
        guard s.count == 6,
              let value = UInt32(s, radix: 16) else {
            throw GeologySceneBuilderError.invalidColorHex(hex)
        }
        let r = Float((value >> 16) & 0xFF) / 255.0
        let g = Float((value >>  8) & 0xFF) / 255.0
        let b = Float( value        & 0xFF) / 255.0
        return SIMD3<Float>(r, g, b)
    }

    /// Non-throwing wrapper: bad hex maps to magenta so issues are
    /// *visible* in the scene rather than crashing the builder.
    /// We trade loudness for fail-safety here; tests still pin the
    /// throwing behaviour on the `parseHex` entry point.
    private static func parseHexOrFallback(_ hex: String) -> SIMD3<Float> {
        (try? parseHex(hex)) ?? SIMD3<Float>(1, 0, 1)
    }

    /// Build one child entity for a layer. Broken out so tests can
    /// assert on position / component wiring without reconstructing
    /// the whole config.
    internal static func makeLayerEntity(
        definition: GeologyLayerDefinition,
        colorRGB: SIMD3<Float>,
        depthFromSurface: Float
    ) -> ModelEntity {
        let size = SIMD3<Float>(
            layerFootprint,
            definition.thickness,
            layerFootprint
        )
        let mesh = MeshResource.generateBox(size: size)
        let material = SimpleMaterial(
            color: platformColor(from: colorRGB),
            roughness: 0.9,
            isMetallic: false
        )
        let entity = ModelEntity(mesh: mesh, materials: [material])
        entity.name = "Layer_\(definition.id)"

        // The box is centred on its origin, so shifting the entity's
        // position by -(depthFromSurface + thickness/2) places the
        // top face exactly at y = -depthFromSurface (surface + running
        // depth). Layer 0 therefore sits with its top face at y = 0.
        entity.position = SIMD3<Float>(
            0,
            -(depthFromSurface + definition.thickness / 2),
            0
        )

        // Geology metadata: the raycast pipeline reads this off the
        // hit entity to reconstruct layer identity.
        entity.components.set(
            GeologyLayerComponent(
                layerId: definition.id,
                nameKey: definition.nameKey,
                layerType: definition.type,
                colorRGB: colorRGB,
                thickness: definition.thickness,
                depthFromSurface: depthFromSurface
            )
        )

        // Collider matching the render mesh, so Phase 1 raycasts have
        // something to intersect. A single convex box is cheap and
        // exact — no need for a generated-from-mesh shape.
        entity.components.set(
            CollisionComponent(shapes: [ShapeResource.generateBox(size: size)])
        )

        return entity
    }

    // MARK: - Colour bridge

    /// Convert 0…1 RGB into the platform colour type
    /// `SimpleMaterial` wants. Clamps defensively: values outside
    /// 0…1 silently wrap into nonsense HSB otherwise.
    private static func platformColor(from rgb: SIMD3<Float>) -> PlatformColor {
        let r = CGFloat(max(0, min(1, rgb.x)))
        let g = CGFloat(max(0, min(1, rgb.y)))
        let b = CGFloat(max(0, min(1, rgb.z)))
        return PlatformColor(red: r, green: g, blue: b, alpha: 1.0)
    }
}
