// ToonMaterialFactory+Outline.swift
// SDGGameplay · Geology
//
// Small convenience layered on top of `ToonMaterialFactory` for
// callers that want to attach an outline to a layer in one go rather
// than juggling two API calls.
//
// Lives in its own file because the outline path is *optional* — the
// approach chosen in ADR-0004 (Approach C) always uses it, but a
// future migration to ShaderGraphMaterial (Approach A) would drop it.
// Keeping the extension isolated makes that migration a one-file
// delete rather than surgery on the primary factory.

import Foundation
import RealityKit

public extension ToonMaterialFactory {

    /// Attach a back-face-hull outline to `entity` as a child, if the
    /// entity has renderable geometry. No-op (returns `nil`) otherwise.
    ///
    /// - Parameter entity: The `ModelEntity` to decorate. Mutated in
    ///   place: an outline child is appended. Existing children are
    ///   preserved.
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
    static func attachOutline(to entity: ModelEntity) -> ModelEntity? {
        guard let outline = makeOutlineEntity(for: entity) else {
            return nil
        }
        entity.addChild(outline)
        return outline
    }
}
