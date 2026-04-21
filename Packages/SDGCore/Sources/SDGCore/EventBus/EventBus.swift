// EventBus.swift
// SDGCore
//
// Actor-based pub/sub for `GameEvent`s. This is the sole sanctioned
// cross-layer communication channel (ADR-0001). No singleton; callers
// own an `EventBus` instance and inject it via `AppEnvironment`.

import Foundation

/// A concurrency-safe pub/sub bus for `GameEvent` values.
///
/// Subscribers register a handler for a specific event type; publishers
/// fire events of that type. Every subscribed handler for the matching
/// type is invoked concurrently (via `TaskGroup`) on each publish; the
/// publish call awaits all handlers before returning.
///
/// The bus is an `actor`: `publish`, `subscribe`, and `cancel` are
/// serialized against each other. Handlers themselves run outside actor
/// isolation (they're `@Sendable` closures); if a handler needs UI
/// isolation it is the caller's responsibility to `await MainActor.run`
/// inside the closure.
///
/// Cancellation semantics: a handler cancelled mid-flight (token passed
/// to `cancel` while `publish` is dispatching) may or may not receive the
/// in-flight event, but will not receive any subsequent one.
public actor EventBus {

    /// Type-erased wrapper around a typed `(E) async -> Void` handler.
    /// We keep the original closure in its typed form and downcast the
    /// opaque `GameEvent` argument at call time. The downcast is always
    /// safe because we store the box under `ObjectIdentifier(E.self)`.
    private struct HandlerBox: Sendable {
        let invoke: @Sendable (any GameEvent) async -> Void
    }

    /// Handlers bucketed by event type.
    ///
    /// Outer key: `ObjectIdentifier` of the concrete event metatype.
    /// Inner key: subscription `UUID`, used for cancellation.
    private var handlers: [ObjectIdentifier: [UUID: HandlerBox]] = [:]

    /// Create an empty bus. Intentionally cheap so tests can spin up
    /// fresh instances.
    public init() {}

    // MARK: - Subscribe

    /// Subscribe to events of type `E`.
    ///
    /// - Parameters:
    ///   - type: The event type to observe. Pass `MyEvent.self`.
    ///   - handler: `@Sendable` async closure invoked for each published
    ///              event of that exact type. Runs off-actor.
    /// - Returns: A token to pass back to `cancel(_:)`. Retain it for as
    ///            long as the subscription should live.
    public func subscribe<E: GameEvent>(
        _ type: E.Type,
        handler: @escaping @Sendable (E) async -> Void
    ) -> SubscriptionToken {
        let typeKey = ObjectIdentifier(type)
        let id = UUID()
        let box = HandlerBox { event in
            // Safe: we only call this box for events stored under `typeKey`,
            // which matches exactly `E.self`. If somehow mis-routed, ignore
            // rather than crash — `as?` is the fail-open path.
            if let typed = event as? E {
                await handler(typed)
            }
        }
        handlers[typeKey, default: [:]][id] = box
        return SubscriptionToken(id: id)
    }

    // MARK: - Publish

    /// Publish an event to every current subscriber of its concrete type.
    ///
    /// Handlers are invoked concurrently; `publish` returns once every
    /// handler's `await` chain has resolved. Handlers added or removed
    /// during this call do not affect the current dispatch (we snapshot
    /// the handler list before dispatching).
    public func publish<E: GameEvent>(_ event: E) async {
        let typeKey = ObjectIdentifier(E.self)
        guard let bucket = handlers[typeKey], !bucket.isEmpty else { return }
        // Snapshot to avoid racing with a concurrent `cancel` during dispatch.
        let snapshot = Array(bucket.values)

        await withTaskGroup(of: Void.self) { group in
            for box in snapshot {
                group.addTask {
                    await box.invoke(event)
                }
            }
        }
    }

    // MARK: - Cancel

    /// Cancel a subscription. No-op if the token is unknown (already
    /// cancelled, or from a different bus). After this returns, the
    /// handler will not receive any further events.
    public func cancel(_ token: SubscriptionToken) {
        // We don't know which type bucket the token lives in without a
        // secondary map; scan buckets. N is small (one per event type,
        // not one per subscriber), so this is cheap.
        for key in handlers.keys {
            if handlers[key]?.removeValue(forKey: token.id) != nil {
                // Clean up empty buckets so `handlers.keys` stays bounded.
                if handlers[key]?.isEmpty == true {
                    handlers.removeValue(forKey: key)
                }
                return
            }
        }
    }

    // MARK: - Introspection (test hook)

    /// Number of live subscribers for a given event type.
    /// Exposed as `public` so tests in other modules can assert on it;
    /// production callers should not rely on this.
    public func subscriberCount<E: GameEvent>(for type: E.Type) -> Int {
        handlers[ObjectIdentifier(type)]?.count ?? 0
    }
}
