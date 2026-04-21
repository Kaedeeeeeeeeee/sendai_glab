// SampleEntity.swift
// SDGGameplay · Samples
//
// Factory that promotes an ordered `[LayerIntersection]` into a full
// RealityKit entity tree representing the stacked sample core the
// player picks up after a drill cycle (GDD §1.3).
//
// The tree shape is:
//
//   sampleRoot (Entity, carries SampleComponent)
//   ├── Segment_0 (ModelEntity, mesh + ToonMaterial, optional outline child)
//   │     ├── ... Outline (ModelEntity, if `addOutline == true`)
//   ├── Segment_1 (ModelEntity, ...)
//   └── ...
//
// Placement is in the caller's hands — `make(...)` never touches the
// scene graph, it only produces an entity. The caller sets
// `.position` / `.parent` to drop the sample where it belongs
// (animated out of the drill, sitting in the inventory preview,
// hanging from a UI anchor, etc.).

import Foundation
import RealityKit

// MARK: - SampleComponent

/// Identity tag + stable id for the sample-core root entity.
///
/// Zero-overhead at runtime (only `sampleId`) but lets ECS systems find
/// the sample via `EntityQuery` without walking names or parents.
///
/// The `sampleId` mirrors `SampleItem.id` when a sample is persisted
/// into the inventory; it lives on the component so scene-side code
/// (drag-drop into microscope, visual highlight on inventory hover) can
/// round-trip to the inventory record without a name-based lookup.
public struct SampleComponent: Component, Sendable {

    /// Stable identifier for this sample core. Matches `SampleItem.id`
    /// once the sample has been accepted into the inventory; until then
    /// it's a pre-assigned UUID so visual debugging can still refer to
    /// the entity by a stable handle.
    public let sampleId: UUID

    /// Memberwise init. Phase 1 callers generate the UUID at build
    /// time; future code paths (replay, restore-from-save) will pass
    /// through an existing id.
    public init(sampleId: UUID = UUID()) {
        self.sampleId = sampleId
    }
}

// MARK: - SampleEntity

/// Factory for the stacked-cylinder sample core entity.
///
/// `enum` + `static func` mirrors `GeologySceneBuilder` and
/// `StackedCylinderMeshBuilder` — the factory has no state worth
/// owning and a `struct` would imply a lifetime it doesn't have.
///
/// All calls are `@MainActor` because
/// `StackedCylinderMeshBuilder.buildSegments(...)` is, and because
/// `Entity` / `ModelEntity` mutations are MainActor-isolated in iOS 18.
@MainActor
public enum SampleEntity {

    /// Build a sample-core entity from detection-pipeline intersections.
    ///
    /// - Parameters:
    ///   - layers: Intersections in depth order (ascending
    ///     `entryDepth`). Empty input returns a childless root —
    ///     the caller still sees a placeable entity, which is useful
    ///     for "drill missed everything" UX.
    ///   - radius: Cylinder radius in metres. Default 5 cm matches
    ///     the legacy Unity scale; also forwarded into every
    ///     `GeologyLayerComponent` so future raycasting code can
    ///     reconstruct the sample's footprint.
    ///   - addOutline: When `true` (default), each segment gets a
    ///     back-face-hull outline child via
    ///     `ToonMaterialFactory.attachOutline(...)`. Disable on the
    ///     "hundreds of samples on a shelf" inventory view if profiling
    ///     shows the extra draw calls hurt.
    ///   - sampleId: Optional stable id. Defaults to a fresh UUID;
    ///     pass an existing id when rebuilding an entity for an
    ///     already-persisted `SampleItem` (symmetry with replay).
    /// - Returns: The root `Entity`. Children are the per-layer
    ///   `ModelEntity`s, ordered top-to-bottom (same order as the
    ///   input). Throws whatever `StackedCylinderMeshBuilder` throws —
    ///   currently never in practice, but kept `throws` to reserve
    ///   space for future validation.
    public static func make(
        from layers: [LayerIntersection],
        radius: Float = 0.05,
        addOutline: Bool = true,
        sampleId: UUID = UUID()
    ) async throws -> Entity {
        let root = Entity()
        // Short id in the name keeps the console readable; the full
        // UUID is always available via the SampleComponent.
        let shortId = sampleId.uuidString.prefix(8)
        root.name = "Sample_\(shortId)"
        root.components.set(SampleComponent(sampleId: sampleId))

        let segments = try await StackedCylinderMeshBuilder.buildSegments(
            for: layers,
            radius: radius
        )

        for (index, segment) in segments.enumerated() {
            let child = makeSegmentEntity(
                segment: segment,
                index: index,
                radius: radius
            )
            root.addChild(child)

            if addOutline {
                // `attachOutline` is @discardableResult and no-ops if
                // the segment somehow lacks a ModelComponent — we've
                // just set one above, but the guard in
                // `ToonMaterialFactory.makeOutlineEntity` stays honest.
                ToonMaterialFactory.attachOutline(to: child)
            }
        }

        return root
    }

    // MARK: - Internal helpers (exposed for tests)

    /// Build the `ModelEntity` for one segment.
    ///
    /// Broken out so tests can assert on component wiring and
    /// positioning without building a whole sample root.
    internal static func makeSegmentEntity(
        segment: StackedCylinderMeshBuilder.Segment,
        index: Int,
        radius: Float
    ) -> ModelEntity {
        let layer = segment.sourceIntersection

        let entity = ModelEntity(
            mesh: segment.mesh,
            materials: [segment.material]
        )
        entity.name = "SampleSegment_\(index)_\(layer.layerId)"

        // Place the segment's centre at its computed Y offset. X/Z
        // stay on the sample core's central axis so the stack reads as
        // a single column.
        entity.position = SIMD3<Float>(0, segment.localYOffset, 0)

        // Reuse the GeologyLayerComponent the detection pipeline
        // already knows how to build. `depthFromSurface` is the
        // *sample-local* top-face depth, which matches the semantics
        // used in `GeologySceneBuilder` (see its init site). The
        // `layerType` is unavailable on the raw intersection — the
        // detection pipeline discards it — so we fall back to `.soil`
        // and rely on the encyclopaedia lookup (keyed by `layerId`)
        // to recover the type for UI. This trade-off is acceptable in
        // Phase 1; a future spec pass can plumb `layerType` through
        // `LayerIntersection` if it becomes load-bearing.
        let topEdgeDepth = max(0, -segment.localYOffset - layer.thickness / 2)
        entity.components.set(
            GeologyLayerComponent(
                layerId: layer.layerId,
                nameKey: layer.nameKey,
                layerType: .soil,
                colorRGB: layer.colorRGB,
                thickness: layer.thickness,
                depthFromSurface: topEdgeDepth
            )
        )

        // Collider matching the render mesh. Cylinders don't have a
        // first-class `ShapeResource.generateCylinder`-that's always
        // available-and-fast; a tight bounding box is the Phase 1
        // compromise and matches what the detection pipeline already
        // assumes for box-shaped layer entities.
        let colliderSize = SIMD3<Float>(
            radius * 2,
            layer.thickness,
            radius * 2
        )
        entity.components.set(
            CollisionComponent(
                shapes: [ShapeResource.generateBox(size: colliderSize)]
            )
        )

        return entity
    }
}
