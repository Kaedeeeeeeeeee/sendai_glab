// EnvironmentCenterer.swift
// SDGGameplay · World
//
// PLATEAU's nusamai CLI emits GLB geometry in Japan Plane Rectangular
// coordinates (EPSG:6677, Miyagi Zone X). Those coordinates put the
// Sendai tiles at offsets of ±tens of kilometres from the origin of
// the zone — which is the wrong place for a gameplay scene. Before
// we let the tile enter the scene graph we translate its root so its
// axis-aligned bounding-box centre sits at the origin, letting the
// `PlateauTile.localCenter` offset take over from there.
//
// Deliberately not `async` — `Entity.visualBounds(relativeTo:)` is a
// synchronous MainActor call. Callers that want to parallelise tile
// loading should do so above this step (one `Task` per tile, each
// calling `centerAtOrigin` after its load completes).

import RealityKit
import Foundation

/// Translates a loaded tile's root so its axis-aligned bounding box
/// is centred on the origin of its own local space.
///
/// ### Why AABB centring, not footprint centring
///
/// Tiles from nusamai carry a lot of vertical empty space above the
/// first floor (roof geometry, towers) and, thanks to Sendai's hilly
/// terrain, below (foundations on slopes). Centring on the full AABB
/// keeps the tile numerically stable — its world-space coordinates
/// stay within a few hundred metres of the origin — at the cost of
/// the "ground plane" not sitting at y = 0. The loader can correct
/// for that downstream by lowering `tile.localCenter.y` if needed.
///
/// Keeping the logic in its own type makes it test-independent of
/// `PlateauEnvironmentLoader`.
public enum EnvironmentCenterer {

    /// Centre `entity` at the origin of its own local space. Leaves
    /// rotation and scale untouched — only `position` is modified.
    ///
    /// - Parameter entity: The loaded tile root. Must already be
    ///   populated; calling this on an entity whose children are
    ///   still being added returns the partial AABB.
    ///
    /// - Important: MainActor-isolated because `visualBounds(...)`
    ///   is. Callers that loaded the tile off-main must `await
    ///   MainActor.run { EnvironmentCenterer.centerAtOrigin(...) }`.
    @MainActor
    public static func centerAtOrigin(_ entity: Entity) {
        _ = centerAndReport(entity)
    }

    /// Centre the entity and return both the original bounding box
    /// and the resulting translation. Useful for callers that want
    /// to log footprint metrics or snap the tile's ground plane to
    /// a known elevation after centring.
    ///
    /// - Parameter entity: The loaded tile root. Mutated in place.
    /// - Returns: Tuple of:
    ///   * `original`: bounding box of `entity` in its local space
    ///     *before* translation. Empty boxes (no geometry) return
    ///     `BoundingBox.empty` — the caller decides what to do.
    ///   * `newPosition`: the `entity.position` we just set. For
    ///     empty-AABB inputs this is unchanged.
    @MainActor
    @discardableResult
    public static func centerAndReport(
        _ entity: Entity
    ) -> (original: BoundingBox, newPosition: SIMD3<Float>) {
        let originalPosition = entity.position
        let bounds = entity.visualBounds(relativeTo: entity.parent)

        // Guard against empty geometry: `BoundingBox.empty` has
        // min = +∞, max = -∞, and its `.center` is NaN-land. Short-
        // circuit to "no-op" rather than moving the entity there.
        if bounds.isEmpty {
            return (bounds, originalPosition)
        }

        let centre = bounds.center
        // `centre` is expressed in the same frame as `bounds`; we
        // asked for "relative to parent", so subtracting it from the
        // current position moves the AABB centre to the parent
        // origin.
        let newPosition = originalPosition - centre
        entity.position = newPosition
        return (bounds, newPosition)
    }

    /// Centre `entity` horizontally (X/Z) at origin, but vertically
    /// snap so the **lowest** vertex sits on Y=0.
    ///
    /// Designed for PLATEAU buildings: nusamai outputs preserve the
    /// real-world geographic elevation of every vertex, so a tile
    /// containing both Aobayama hilltop (≈150 m AMSL) and Hirose-river
    /// valley (≈30 m AMSL) spans 120 m of vertical range. AABB-centre
    /// alignment puts half the tile under the ground plane and the
    /// other half floating in mid-air. Bottom-snap leaves all
    /// buildings *above* Y=0 with their lowest one resting on the
    /// ground; hilltop buildings remain elevated relative to valley
    /// buildings, which matches what a player without DEM terrain
    /// would intuitively expect.
    ///
    /// Permanently fixed by Phase 2 Beta DEM integration; until then
    /// this is the visually-honest fallback.
    @MainActor
    @discardableResult
    public static func centerHorizontallyAndGroundY(
        _ entity: Entity
    ) -> (original: BoundingBox, newPosition: SIMD3<Float>) {
        let originalPosition = entity.position
        let bounds = entity.visualBounds(relativeTo: entity.parent)

        if bounds.isEmpty {
            return (bounds, originalPosition)
        }

        let centre = bounds.center
        // X/Z: same as centerAtOrigin (subtract centre).
        // Y: subtract the *minimum* Y instead of the centre Y, so the
        // resulting min.y == 0 in parent space.
        let newPosition = SIMD3<Float>(
            originalPosition.x - centre.x,
            originalPosition.y - bounds.min.y,
            originalPosition.z - centre.z
        )
        entity.position = newPosition
        return (bounds, newPosition)
    }
}
