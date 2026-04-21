// StackedCylinderMeshBuilder.swift
// SDGGameplay · Samples
//
// Phase 1 sample-core geometry: takes the ordered
// `[LayerIntersection]` produced by
// `GeologyDetectionSystem.detectLayers(...)` and turns each layer into
// one upright cylinder segment, together forming the "stacked sample
// core" the player sees pop out of the drill (GDD §1.3).
//
// The builder is deliberately split into two public entry points:
//
//   * `makeCylinderSegment(radius:height:)` — pure geometry. Handy for
//     tests, previews, and future one-off cylinder needs that aren't
//     driven by a `LayerIntersection` (e.g. a drill-bit cosmetic).
//   * `buildSegments(for:radius:)` — the Phase 1 product: batch over a
//     list of intersections, producing a ready-to-mount
//     `(mesh, material, localYOffset, source)` per layer. The caller
//     (`SampleEntity`) glues these into a parent entity.
//
// ## Mesh strategy — RealityKit built-in cylinder
//
// iOS 18 exposes `MeshResource.generateCylinder(height:radius:)`
// (verified against the Apple Developer Documentation for iOS 18.0+).
// This beats every alternative we considered:
//
//   * Rolling a cylinder mesh by hand via `MeshDescriptor` would match
//     the legacy Unity `GeometricSampleReconstructor.CreateCylinderMesh`
//     algorithm but adds ~70 lines of maths that the platform already
//     ships, bug-free, behind a one-liner.
//   * `LowLevelMesh` (iOS 18) is the right choice when we need custom
//     vertex attributes (e.g. per-segment colour ramp, procedural
//     strain markers). Phase 1 does not need that, so paying for the
//     API surface is premature optimisation.
//   * Falling back to `generateBox(size:)` would ship today but look
//     wrong — the task name is *StackedCylinder*, and a sample core
//     reads as round in every reference we have (including the legacy
//     Unity build).
//
// The enum is `static func` only, mirroring `GeologySceneBuilder`. No
// stored state — the builder is a pure translation step.

import Foundation
import RealityKit

/// Mesh + material factory for the stacked-cylinder sample core.
///
/// Callers should normally go through `SampleEntity.make(from:...)`
/// rather than touching this type directly; the builder is public so
/// gameplay code can compose alternative layouts (e.g. a horizontally
/// laid-out teaching diagram) without reimplementing cylinder
/// generation.
public enum StackedCylinderMeshBuilder {

    // MARK: - Tunables

    /// Vertical gap (in metres) inserted between adjacent cylinder
    /// segments. Exists to defend against Z-fighting at the shared
    /// boundary plane — two opaque faces at identical Y will flicker
    /// on real device GPUs. 1 mm is small enough to be visually
    /// invisible at the default 5 cm sample radius but large enough to
    /// survive Float rounding at the depths Phase 1 drills (tens of
    /// metres at most).
    ///
    /// Exposed `internal` so tests can pin the constant rather than
    /// hand-copy the magic number.
    internal static let safeGap: Float = 0.001

    /// Default circumferential segment count for
    /// `makeCylinderSegment(...)`. Matches the legacy Unity build's
    /// value (12) bumped to 16 — still cheap (~32 triangles per
    /// segment) but reads as noticeably rounder on the iPad Pro
    /// display. Not currently honoured by the RealityKit built-in (it
    /// picks its own tessellation), kept as a parameter so callers
    /// can opt into a hand-built `MeshDescriptor` path in Phase 2
    /// without changing the API.
    public static let defaultRadialSegments: Int = 16

    // MARK: - Segment type

    /// One cylinder segment ready to be mounted onto a parent entity.
    ///
    /// Bundles everything the consumer needs to build the corresponding
    /// `ModelEntity` *and* the metadata that would otherwise be lost
    /// (the source `LayerIntersection`) so the consumer can attach an
    /// ECS component without plumbing a parallel array.
    ///
    /// Intentionally **not** `Sendable`: `RealityKit.Material` is a
    /// non-`Sendable` protocol (see Apple docs), and AGENTS.md §3
    /// forbids `@unchecked Sendable` as a workaround. The whole builder
    /// + consumer chain runs on `@MainActor`, so segments never need to
    /// cross an actor boundary for the Phase 1 pipeline.
    public struct Segment {

        /// The cylinder mesh for this layer. Local origin is the
        /// segment centre.
        public let mesh: MeshResource

        /// The Toon-shaded material bound to this layer's colour.
        /// Typed as the abstract `RealityKit.Material` so future
        /// migrations (e.g. `ShaderGraphMaterial`) don't cascade into
        /// this struct's public API.
        public let material: RealityKit.Material

        /// The segment's centre Y position relative to the sample's
        /// top face (y = 0). Always `<= 0` — layers stack downwards.
        /// The consumer assigns this straight to
        /// `modelEntity.position.y` when parenting the segment to the
        /// sample root.
        public let localYOffset: Float

        /// The original intersection. Carried forward so consumers can
        /// attach a `GeologyLayerComponent` without re-querying
        /// upstream, and so tests can assert segment ↔ intersection
        /// identity without extra bookkeeping.
        public let sourceIntersection: LayerIntersection

        /// Memberwise initialiser, `internal` because only the builder
        /// should construct these — an externally-built `Segment` with
        /// a mismatched `localYOffset` would silently misplace the
        /// sample core.
        internal init(
            mesh: MeshResource,
            material: RealityKit.Material,
            localYOffset: Float,
            sourceIntersection: LayerIntersection
        ) {
            self.mesh = mesh
            self.material = material
            self.localYOffset = localYOffset
            self.sourceIntersection = sourceIntersection
        }
    }

    // MARK: - Single-segment geometry

    /// Build one upright cylinder mesh, centred at the local origin.
    ///
    /// The mesh is axis-aligned along Y; the parent entity rotates it
    /// if a non-vertical sample is ever needed.
    ///
    /// - Parameters:
    ///   - radius: Radius in metres. Must be strictly positive;
    ///     negative or zero inputs are clamped to a minimum of 1 mm
    ///     so the RealityKit primitive doesn't fault on a degenerate
    ///     geometry (Phase 1 tolerates a tiny bullet rather than
    ///     propagating an error).
    ///   - height: Height in metres. Same clamping rules as `radius`.
    ///   - radialSegments: Requested circumferential tessellation.
    ///     Currently informational — `MeshResource.generateCylinder`
    ///     picks its own triangle count. Kept in the signature for
    ///     API stability; a future hand-written `MeshDescriptor`
    ///     path will honour it. Must be `>= 3` to form a valid
    ///     polygon; lower values are silently clamped.
    /// - Returns: A non-nil `MeshResource`. Currently never throws in
    ///   practice; the `throws` on the signature reserves space for
    ///   future validation (e.g. rejecting NaN) without a source
    ///   break.
    @MainActor
    public static func makeCylinderSegment(
        radius: Float,
        height: Float,
        radialSegments: Int = defaultRadialSegments
    ) async throws -> MeshResource {
        let safeRadius = max(0.001, radius)
        let safeHeight = max(0.001, height)
        // `radialSegments` is honoured by the not-yet-live hand-built
        // path; the built-in cylinder ignores it but we still sanity
        // clamp so future plumbing changes don't trip on a stashed
        // value of 2.
        _ = max(3, radialSegments)
        return MeshResource.generateCylinder(
            height: safeHeight,
            radius: safeRadius
        )
    }

    // MARK: - Batch over intersections

    /// Build one `Segment` per intersection, computing each segment's
    /// `localYOffset` by accumulating thickness + `safeGap` from the
    /// sample's top face downward.
    ///
    /// For intersections `[t0, t1, t2, …]` with gap `g`, the offsets
    /// are:
    ///
    ///   * seg[0] = -t0 / 2
    ///   * seg[1] = -(t0 + g) - t1 / 2
    ///   * seg[2] = -(t0 + g + t1 + g) - t2 / 2
    ///   * …
    ///
    /// i.e. each segment's centre sits below the running "bottom edge
    /// of the previous segment + one gap" by half its own thickness.
    ///
    /// - Parameters:
    ///   - layers: Ordered intersections, top-to-bottom (ascending
    ///     `entryDepth`). Empty input returns an empty array rather
    ///     than an error — the caller may legitimately drill through
    ///     air.
    ///   - radius: Cylinder radius in metres. Defaults to 5 cm to
    ///     match the legacy Unity scale reference.
    /// - Returns: Segments in input order. `.count == layers.count`.
    @MainActor
    public static func buildSegments(
        for layers: [LayerIntersection],
        radius: Float = 0.05
    ) async throws -> [Segment] {
        guard !layers.isEmpty else { return [] }

        var segments: [Segment] = []
        segments.reserveCapacity(layers.count)

        // `runningTopEdge` tracks the Y coordinate at which the next
        // segment's *top* face must sit. Starts at 0 (sample surface)
        // and marches downward.
        var runningTopEdge: Float = 0

        for (index, intersection) in layers.enumerated() {
            let thickness = intersection.thickness
            // For the first segment, no gap above. For every
            // subsequent segment, insert a `safeGap` between the
            // previous segment's bottom face and this one's top face.
            if index > 0 {
                runningTopEdge -= safeGap
            }
            let centreY = runningTopEdge - thickness / 2

            let mesh = try await makeCylinderSegment(
                radius: radius,
                height: thickness
            )
            let material = ToonMaterialFactory.makeLayerMaterial(
                baseColor: intersection.colorRGB
            )

            segments.append(
                Segment(
                    mesh: mesh,
                    material: material,
                    localYOffset: centreY,
                    sourceIntersection: intersection
                )
            )

            // Advance running edge past the segment we just placed.
            runningTopEdge -= thickness
        }

        return segments
    }
}
