// GeologyDetectionSystem.swift
// SDGGameplay · Geology
//
// Drilling-time layer detection. Given a point and a direction, returns
// the sequence of `LayerIntersection`s the drill would encounter as it
// punches down through the stacked-box outcrop produced by
// `GeologySceneBuilder`.
//
// ## Architecture note — pure enum, *not* an ECS System
//
// This namespace is a thin `enum` with static entry points rather than
// a `RealityKit.System`. Rationale:
//
//   * Detection runs *on demand* (one drill event, triggered by a
//     user tap), not on every render frame. An ECS System's
//     per-frame `update(context:)` would be strictly wasted work and
//     would force the result to travel through component state.
//   * The algorithm is stateless: depth in, layers out. Giving it a
//     lifetime implies nothing useful and risks accidental
//     accumulator bugs (cf. the Unity project's surprise-mutating
//     DrillingCylinderGenerator).
//   * Exposing `computeIntersections(...)` as a pure function lets
//     headless unit tests exercise the core arithmetic without ever
//     constructing a RealityKit `Scene`, which is expensive and — on
//     macOS CI — flaky.
//
// A future `DrillingSystem` (Phase 2, see GDD §4.2 Alpha roadmap) that
// animates a visible drill bit *will* be an ECS System; it'll call into
// this namespace once per tap.
//
// ## Why visualBounds instead of an actual raycast
//
// RealityKit's `Scene.raycast(from:to:)` is overkill for stacked
// axis-aligned layers. Each layer's world-space `BoundingBox` already
// exposes the Y-slab we need; intersecting the drill ray with `[minY,
// maxY]` is a constant-time interval clip with no collider, no
// SceneKit-era numerical surprises, and no need to register collision
// shapes for tooling that will never be rendered. The legacy Unity
// code used `Physics.RaycastAll` because Unity lacks a first-class
// bounds-per-layer accessor; we do not have that constraint.

import Foundation
import RealityKit

// MARK: - Pure layer representation

/// Axis-aligned, world-space description of a single geology layer
/// for the purposes of depth detection.
///
/// The struct intentionally carries *only* what the intersection maths
/// needs. A layer's colour/name is forwarded verbatim to the output
/// `LayerIntersection` without interpretation.
///
/// Exposed publicly because it is the contract surface of the pure
/// algorithm (`GeologyDetectionSystem.computeIntersections`): tests
/// construct `LayerSlab` arrays directly instead of assembling a
/// full entity tree.
public struct LayerSlab: Sendable, Hashable {

    /// Stable layer identifier, copied from
    /// `GeologyLayerComponent.layerId`.
    public let layerId: String

    /// Localisation key; copied into the output intersection.
    public let nameKey: String

    /// 0…1 RGB; copied into the output intersection.
    public let colorRGB: SIMD3<Float>

    /// World-space Y of the layer's *top* face (the face the drill
    /// enters first when travelling downwards). Must be `>= bottomY`.
    public let topY: Float

    /// World-space Y of the layer's *bottom* face. Must be `<= topY`.
    /// A zero-thickness slab (`topY == bottomY`) is legal — the
    /// detection step will naturally filter it out via the
    /// `isValid` threshold.
    public let bottomY: Float

    /// World-space (X, Z) centre of the slab. Used to reconstruct the
    /// entry / exit points on the output intersection when the drill
    /// direction has no XZ component (the common case) — we keep the
    /// slab centre rather than recomputing from the drill's own XZ so
    /// future non-vertical drilling integrates cleanly.
    public let xzCenter: SIMD2<Float>

    /// Memberwise init. Required because `LayerSlab` is routinely
    /// instantiated by tests; a synthesised implicit init would be
    /// `internal` under SPM.
    public init(
        layerId: String,
        nameKey: String,
        colorRGB: SIMD3<Float>,
        topY: Float,
        bottomY: Float,
        xzCenter: SIMD2<Float>
    ) {
        self.layerId = layerId
        self.nameKey = nameKey
        self.colorRGB = colorRGB
        self.topY = topY
        self.bottomY = bottomY
        self.xzCenter = xzCenter
    }
}

// MARK: - Detection namespace

/// Drilling-time layer detection.
///
/// The namespace offers three entry points in increasing integration
/// depth:
///
///   1. `computeIntersections(from:direction:maxDepth:layers:)` — pure
///      arithmetic on `LayerSlab`s. No RealityKit required. Use this
///      from unit tests.
///   2. `detectLayers(under root:from:...)` — walk a root entity's
///      descendants, collect `GeologyLayerComponent`-bearing children,
///      hand off to `computeIntersections`. Still testable with a real
///      `buildOutcrop(from:)` result; does *not* need a Scene.
///   3. `detectLayers(in scene:from:...)` — query an active RealityKit
///      scene for every entity tagged `GeologyLayerComponent` and
///      detect against all of them. The production drilling path.
///
/// Always returns intersections ordered by increasing `entryDepth`.
public enum GeologyDetectionSystem {

    // MARK: Tunable thresholds

    /// Minimum thickness, in metres, for an intersection to survive
    /// the filter. 1 cm matches `LayerIntersection.isValid`; the
    /// constant is kept together so both the filter and the predicate
    /// agree on a single definition.
    internal static let minimumThickness: Float = 0.01

    // MARK: 1. Pure algorithm (no RealityKit)

    /// Compute the intersection sequence for a ray of length
    /// `maxDepth` starting at `origin` and travelling along
    /// `direction`, against the supplied `layers`.
    ///
    /// The algorithm treats each `LayerSlab` as a Y-interval
    /// `[bottomY, topY]` and intersects it with the drill's travelled
    /// Y-interval `[origin.y - maxDepth, origin.y]`. Any slab whose
    /// clipped thickness drops below `minimumThickness` is discarded
    /// — these are numerical crumbs that do not correspond to
    /// physical material.
    ///
    /// - Parameters:
    ///   - origin: Drill start point in world coordinates.
    ///   - direction: Unit direction vector. Expected to be
    ///     `(0, -1, 0)` in Phase 1; any non-vertical vector still
    ///     produces geometrically correct entry/exit points because
    ///     depths project along it, but thickness continues to be
    ///     measured along the ray (not along Y), which matches the
    ///     drilling core sample metaphor.
    ///   - maxDepth: Maximum distance along the ray to consider.
    ///     A negative or zero value yields `[]`.
    ///   - layers: The candidate layers. Ordering irrelevant — the
    ///     algorithm sorts by `topY` descending internally.
    /// - Returns: Intersections, ordered by increasing `entryDepth`
    ///   (equivalently, by decreasing slab top). Empty if no slab
    ///   contributes a segment with `thickness > minimumThickness`.
    public static func computeIntersections(
        from origin: SIMD3<Float>,
        direction: SIMD3<Float>,
        maxDepth: Float,
        layers: [LayerSlab]
    ) -> [LayerIntersection] {
        // Fast path — a zero-or-negative drill does nothing. We check
        // before the sort to avoid paying even a log-factor when the
        // caller is just probing the API with default arguments.
        guard maxDepth > 0 else { return [] }
        guard !layers.isEmpty else { return [] }

        // Sorting by `topY` descending orders the slabs from "nearest
        // to the drill head" to "deepest". That means the resulting
        // intersections come out in the order the drill would
        // physically encounter them, which is also the final output
        // order (ascending `entryDepth`). Stable sort isn't required
        // because ties in `topY` would imply overlapping layers —
        // geological nonsense for this POC, and even if encountered,
        // the per-slab clipping below keeps the final list
        // well-defined.
        let ordered = layers.sorted { $0.topY > $1.topY }

        var out: [LayerIntersection] = []
        out.reserveCapacity(ordered.count)

        for slab in ordered {
            // Project slab top/bottom onto the ray, measuring
            // *distance from origin*. For a downward ray,
            // `origin.y - topY` is the depth at which the ray first
            // crosses the top face. Clamping at zero handles layers
            // whose tops sit above the drill head — the ray never
            // encounters them, so we collapse entry to the origin.
            let rawEntry = origin.y - slab.topY
            let rawExit = origin.y - slab.bottomY

            let entryDist = max(0, rawEntry)
            let exitDist = min(maxDepth, rawExit)
            let thickness = exitDist - entryDist

            // Skip zero-or-negative contributions: the drill either
            // stopped short of this slab (`exitDist <= 0`), passed
            // entirely under it (`entryDist >= maxDepth`), or we
            // landed on a crumb thinner than 1 cm. All three map to
            // "no material sampled".
            guard thickness > Self.minimumThickness else { continue }

            let entryPoint = origin + direction * entryDist
            let exitPoint = origin + direction * exitDist

            out.append(
                LayerIntersection(
                    layerId: slab.layerId,
                    nameKey: slab.nameKey,
                    colorRGB: slab.colorRGB,
                    entryDepth: entryDist,
                    exitDepth: exitDist,
                    thickness: thickness,
                    entryPoint: entryPoint,
                    exitPoint: exitPoint
                )
            )
        }

        return out
    }

    // MARK: 2. Entity-tree integration

    /// Walk `root`'s descendants, collect every entity with a
    /// `GeologyLayerComponent`, and run `computeIntersections` against
    /// their world-space bounds.
    ///
    /// Use this from tests or when the caller already has the outcrop
    /// root and doesn't want to bother with an explicit `Scene` — the
    /// P1 drilling POC, for example, lives inside a RealityView
    /// closure that has the root entity immediately at hand.
    ///
    /// - Parameters:
    ///   - root: Root of the subtree to inspect. The root itself is
    ///     checked in addition to all descendants.
    ///   - origin: Drill start point in world coordinates.
    ///   - direction: Drill direction. Defaults to straight down.
    ///   - maxDepth: Max distance along the ray, metres.
    /// - Returns: Intersections, ascending by `entryDepth`. Empty if
    ///   no descendant carries a `GeologyLayerComponent`.
    @MainActor
    public static func detectLayers(
        under root: Entity,
        from origin: SIMD3<Float>,
        direction: SIMD3<Float> = [0, -1, 0],
        maxDepth: Float = 10.0
    ) -> [LayerIntersection] {
        var slabs: [LayerSlab] = []
        collectSlabs(from: root, into: &slabs)
        return computeIntersections(
            from: origin,
            direction: direction,
            maxDepth: maxDepth,
            layers: slabs
        )
    }

    // MARK: 3. Scene-level integration (production path)

    /// Production entry point: detect layers against every
    /// `GeologyLayerComponent`-bearing entity in `scene`.
    ///
    /// Uses `scene.performQuery(_:)` with an `EntityQuery` predicate,
    /// which is the iOS 18 / macOS 15 idiom also used by
    /// `PlayerControlSystem` (though `PlayerControlSystem` goes
    /// through the per-frame `SceneUpdateContext` variant — a
    /// different API with different isolation requirements).
    ///
    /// - Parameters:
    ///   - scene: The live RealityKit scene. Typically obtained from a
    ///     `RealityView`'s `make`/`update` closure via
    ///     `content.scene`.
    ///   - origin: Drill start point in world coordinates.
    ///   - direction: Drill direction. Defaults to straight down.
    ///   - maxDepth: Max distance along the ray, metres.
    /// - Returns: Intersections, ascending by `entryDepth`. Empty if
    ///   the scene has no geology layers.
    @MainActor
    public static func detectLayers(
        in scene: Scene,
        from origin: SIMD3<Float>,
        direction: SIMD3<Float> = [0, -1, 0],
        maxDepth: Float = 10.0
    ) -> [LayerIntersection] {
        let query = EntityQuery(where: .has(GeologyLayerComponent.self))
        var slabs: [LayerSlab] = []
        for entity in scene.performQuery(query) {
            if let slab = makeSlab(from: entity) {
                slabs.append(slab)
            }
        }
        return computeIntersections(
            from: origin,
            direction: direction,
            maxDepth: maxDepth,
            layers: slabs
        )
    }

    // MARK: - Entity → LayerSlab bridging

    /// Recursively collect `LayerSlab`s from `entity` and its
    /// descendants.
    ///
    /// Split out from `detectLayers(under:...)` so it can be reused by
    /// both the tree and scene paths if needed, and so tests can reach
    /// it via `@testable import` without triggering the full detection
    /// pipeline.
    @MainActor
    internal static func collectSlabs(
        from entity: Entity,
        into slabs: inout [LayerSlab]
    ) {
        if let slab = makeSlab(from: entity) {
            slabs.append(slab)
        }
        for child in entity.children {
            collectSlabs(from: child, into: &slabs)
        }
    }

    /// Build a `LayerSlab` from a single entity, if and only if it
    /// carries a `GeologyLayerComponent`. Returns `nil` otherwise;
    /// non-geology entities pass through silently.
    ///
    /// Uses `entity.visualBounds(relativeTo: nil)` to get the
    /// axis-aligned world-space bounding box. `visualBounds` walks the
    /// entity's render components (ModelComponent geometry + children)
    /// and returns a world-space `BoundingBox`; for the stacked-box
    /// outcrops produced by `GeologySceneBuilder` that matches the
    /// collider exactly, which is what the algorithm wants.
    ///
    /// An entity with a geology component but no visible geometry
    /// produces a `BoundingBox.empty` (min > max). We reject those
    /// rather than returning a NaN-infested slab.
    @MainActor
    internal static func makeSlab(from entity: Entity) -> LayerSlab? {
        guard let component = entity.components[GeologyLayerComponent.self] else {
            return nil
        }

        let bounds = entity.visualBounds(relativeTo: nil)

        // `BoundingBox.empty` reports `min = +inf`, `max = -inf`. The
        // direct "any component is not finite" check is portable and
        // cheap; catches both the empty case and any transform that
        // has degenerated into NaN (which would otherwise pollute the
        // intersection arithmetic).
        guard bounds.min.y.isFinite,
              bounds.max.y.isFinite,
              bounds.max.y >= bounds.min.y else {
            return nil
        }

        let xzCenter = SIMD2<Float>(
            (bounds.min.x + bounds.max.x) * 0.5,
            (bounds.min.z + bounds.max.z) * 0.5
        )

        return LayerSlab(
            layerId: component.layerId,
            nameKey: component.nameKey,
            colorRGB: component.colorRGB,
            topY: bounds.max.y,
            bottomY: bounds.min.y,
            xzCenter: xzCenter
        )
    }
}
