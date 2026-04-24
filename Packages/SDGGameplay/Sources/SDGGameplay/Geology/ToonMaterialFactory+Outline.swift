// ToonMaterialFactory+Outline.swift
// SDGGameplay · Geology
//
// Small convenience layered on top of `ToonMaterialFactory` for
// callers that want to attach an outline to a layer in one go rather
// than juggling two API calls.
//
// Lives in its own file because the outline path is *optional* — the
// approach chosen in ADR-0004 (Approach C) always uses it, but a
// future migration to ShaderGraphMaterial with a rim-light / Fresnel
// term would drop it entirely. Keeping the extension isolated makes
// that migration a one-file delete rather than surgery on the primary
// factory.
//
// ## C-v2 additions
//
// The one-arg legacy signature stays for callers that don't know their
// tint. A new overload accepts a `baseColor:` so the outline can be
// tinted by the colour's complement — see `makeOutlineEntity(for:baseColor:)`.

import Foundation
import RealityKit

public extension ToonMaterialFactory {

    /// Attach a back-face-hull outline to `entity` as a child, if the
    /// entity has renderable geometry. No-op (returns `nil`) otherwise.
    ///
    /// - Parameter entity: The `ModelEntity` to decorate. Mutated in
    ///   place: an outline child is appended. Existing children are
    ///   preserved.
    /// - Parameter baseColor: Optional base colour of the source. When
    ///   provided, the outline ink is tinted by the darkened complement
    ///   (see `ToonMaterialFactory.outlineInkColor(for:)`). When `nil`
    ///   the outline is the legacy pure black — still fine, just less
    ///   intentional-looking next to saturated bases.
    /// - Returns: The outline entity that was added, or `nil` if the
    ///   source had no `ModelComponent`. Returning the handle lets
    ///   call sites bind additional state (e.g. an `.isEnabled`
    ///   toggle driven by a settings flag).
    ///
    /// - Important: MainActor-isolated for the same reason as
    ///   `makeOutlineEntity(for:)` — RealityKit entity mutations are
    ///   MainActor in iOS 18.
    @MainActor
    @discardableResult
    static func attachOutline(
        to entity: ModelEntity,
        baseColor: SIMD3<Float>? = nil
    ) -> ModelEntity? {
        guard let outline = makeOutlineEntity(
            for: entity, baseColor: baseColor
        ) else {
            return nil
        }
        entity.addChild(outline)
        return outline
    }
}
