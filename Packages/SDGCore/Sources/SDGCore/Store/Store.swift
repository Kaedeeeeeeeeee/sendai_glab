// Store.swift
// SDGCore
//
// Marker protocol for every `@Observable` state container in SDG-Lab.
// Concrete stores live in their own gameplay modules (InventoryStore,
// QuestStore, etc.) and must conform here.

import Foundation

/// Marker protocol for SDG-Lab's `@Observable` state containers.
///
/// Concrete stores should:
/// 1. Be `final class` annotated with `@Observable` (iOS 17+).
/// 2. Hold mutable game state as plain stored properties.
/// 3. Expose an `Intent` value type (typically an `enum`) describing every
///    user/system action that mutates state.
/// 4. Implement `intent(_:)` to mutate state and publish cross-module
///    events via an injected `EventBus`.
///
/// Architectural invariants (ADR-0001):
/// - Stores MUST NOT `import SwiftUI` or `import RealityKit`.
/// - Stores MUST NOT hold a reference to another `Store`.
/// - Stores communicate cross-module via `EventBus` only.
///
/// `AnyObject` is required because `@Observable` classes are reference
/// types. `Sendable` is required so stores can be handed to tasks; in
/// practice a store is usually `@MainActor`-isolated or annotated
/// `@unchecked Sendable` through `@Observable`'s own rules.
public protocol Store: AnyObject, Sendable {
    /// The set of commands a caller can send to this store. Typically an
    /// `enum` with associated values (e.g. `.drill(at: Position)`).
    associatedtype Intent: Sendable

    /// Apply an intent. Implementations mutate `self` and fire any
    /// follow-on events. Async so intents can await I/O if needed.
    func intent(_ intent: Intent) async
}
