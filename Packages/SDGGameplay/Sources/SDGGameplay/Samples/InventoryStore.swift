// InventoryStore.swift
// SDGGameplay
//
// The player-facing sample inventory. Three-layer architecture
// (ADR-0001) compliance:
// - View reads `samples` / `selectedId` via `@Observable` and sends
//   `Intent`s through `intent(_:)`.
// - ECS never touches this store; it fires `SampleCreatedEvent` on the
//   `EventBus` and we pick it up.
// - Persistence is a plain value-typed dependency (`InventoryPersistence`),
//   not a singleton. Tests inject `.inMemory`.

import Foundation
import Observation
import SDGCore

/// `@Observable` store owning the player's collected sample list.
///
/// ### Lifecycle
/// `init` wires dependencies but performs no I/O and no subscription.
/// Callers MUST invoke ``start()`` once the store is hosted (e.g. in
/// `App.init` or a view's `.task`). ``stop()`` tears the subscription
/// down again and is idempotent.
///
/// ### Why no auto-cancel in `deinit`?
/// Swift does not allow `async` work inside `deinit`. Two patterns were
/// considered (see task spec):
/// - **A. Explicit `stop()`** — chosen here. The store lives for the full
///   app lifetime in practice, so manual teardown is only needed in
///   tests, which do it anyway.
/// - B. Fire-and-forget `Task { await bus.cancel(token) }` in `deinit`
///   leaks the subscription for one more dispatch cycle and races with
///   the bus's internal state. Not worth the subtle lifetime bugs.
///
/// ### Concurrency
/// `@MainActor` so `@Observable` mutations stay on the main thread (the
/// SwiftUI observation runtime expects that). The EventBus handler
/// closure bounces back into the actor via `await self?...`; the store
/// itself is never touched off-actor.
@Observable
@MainActor
public final class InventoryStore: Store {

    /// Mutation commands accepted by the store. All cross-layer write
    /// traffic goes through here.
    public enum Intent: Sendable {
        /// Highlight (or deselect with `nil`) a sample in the UI.
        case select(SampleItem.ID?)
        /// Remove the sample with the given id, if present.
        case delete(SampleItem.ID)
        /// Drop every sample. Used by "new game" / settings-level reset.
        case clearAll
        /// Replace the custom note for a single sample. `nil` clears it.
        case updateNote(SampleItem.ID, String?)
    }

    // MARK: - Observable state

    /// All collected samples in collection order (append-on-create).
    public private(set) var samples: [SampleItem] = []

    /// Id of the sample currently selected in the UI, if any. Cleared
    /// when the selected sample is deleted or the inventory is emptied.
    public private(set) var selectedId: SampleItem.ID?

    // MARK: - Dependencies (injected, not global)

    private let eventBus: EventBus
    private let persistence: InventoryPersistence
    private var subscriptionToken: SubscriptionToken?

    // MARK: - Init

    /// - Parameters:
    ///   - eventBus: Shared `EventBus` actor; typically from `AppEnvironment`.
    ///   - persistence: Storage backend. Defaults to `UserDefaults.standard`
    ///     via `.standard`; tests use `.inMemory`.
    public init(
        eventBus: EventBus,
        persistence: InventoryPersistence = .standard
    ) {
        self.eventBus = eventBus
        self.persistence = persistence
    }

    // MARK: - Lifecycle

    /// Hydrate state from persistence and subscribe to `SampleCreatedEvent`.
    ///
    /// Idempotent: calling twice keeps the first subscription and
    /// re-loads from disk. Persistence errors are swallowed silently —
    /// first launch has no saved data and a corrupt blob is treated as
    /// "start empty" rather than crashing the app. (Tests exercise the
    /// explicit `throws` path through `InventoryPersistence` directly.)
    public func start() async {
        // Re-hydrate state.
        if let loaded = try? persistence.load() {
            self.samples = loaded
        }

        // Wire the subscription only on the first `start()`.
        guard subscriptionToken == nil else { return }
        subscriptionToken = await eventBus.subscribe(SampleCreatedEvent.self) { [weak self] event in
            // Handlers run outside the store's MainActor isolation; hop
            // back in before touching state.
            await self?.handleSampleCreated(event)
        }
    }

    /// Drop the EventBus subscription, if any. Safe to call multiple
    /// times; safe to call without a prior `start()`.
    public func stop() async {
        guard let token = subscriptionToken else { return }
        await eventBus.cancel(token)
        subscriptionToken = nil
    }

    // MARK: - Event handler

    /// Handles a newly-created sample: append, persist, stay on main.
    /// Kept `private` — ingest is exclusively event-driven.
    private func handleSampleCreated(_ event: SampleCreatedEvent) async {
        samples.append(event.sample)
        persistIgnoringFailure()
    }

    // MARK: - Store protocol

    public func intent(_ intent: Intent) async {
        switch intent {
        case .select(let id):
            selectedId = id

        case .delete(let id):
            samples.removeAll { $0.id == id }
            if selectedId == id {
                selectedId = nil
            }
            persistIgnoringFailure()

        case .clearAll:
            samples.removeAll()
            selectedId = nil
            persistIgnoringFailure()

        case .updateNote(let id, let note):
            if let idx = samples.firstIndex(where: { $0.id == id }) {
                samples[idx].customNote = note
                persistIgnoringFailure()
            }
        }
    }

    // MARK: - Persistence helper

    /// Best-effort save. Persistence failure must not crash gameplay;
    /// in the worst case the player loses a single drill's worth of data
    /// on next launch. Production diagnostics can be added later by
    /// routing to an `os.Logger` at call sites, not here — keeping this
    /// module framework-free matches ADR-0001.
    private func persistIgnoringFailure() {
        do {
            try persistence.save(samples)
        } catch {
            // Intentionally swallowed. See doc comment above.
        }
    }
}
