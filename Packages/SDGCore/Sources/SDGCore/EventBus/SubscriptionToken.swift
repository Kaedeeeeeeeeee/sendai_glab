// SubscriptionToken.swift
// SDGCore
//
// Opaque handle returned by `EventBus.subscribe`. Callers pass it back to
// `EventBus.cancel` to tear their subscription down.

import Foundation

/// Opaque handle to an `EventBus` subscription.
///
/// The bus creates tokens itself; the initializer is `internal` so external
/// code cannot forge one. Tokens are `Sendable` and `Hashable` so they can
/// live in `Set`s or be passed across isolation domains (e.g. stored on a
/// `@MainActor` view model and cancelled from a background task).
public struct SubscriptionToken: Sendable, Hashable {

    /// Unique identifier for the subscription. Exposed as `public` so callers
    /// can log/debug it, but equality is defined in terms of this id.
    public let id: UUID

    /// Bus-internal constructor. The `EventBus` actor is the sole authority.
    internal init(id: UUID) {
        self.id = id
    }
}
