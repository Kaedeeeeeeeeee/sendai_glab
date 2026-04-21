// TouchInputService.swift
// SDGPlatform
//
// Platform-agnostic façade for touch / pointer pan input.
//
// SDGPlatform is forbidden from importing SwiftUI or RealityKit
// (see ADR-0001 and ci_scripts/arch_lint.sh). The actual gesture
// capture therefore lives in SDGUI; this file defines the value
// type(s) crossing the layer boundary and a stateless service
// that forwards pan values to the event bus and/or an arbitrary
// callback. Keeping the domain type here (not in SDGUI) lets
// Stores and ECS Systems consume `PanEvent` without pulling in
// SwiftUI.

import Foundation
import SDGCore

/// A single pan (drag) sample, measured in points relative to the
/// gesture's initial touch-down location.
///
/// This is a pure value type carrying the minimum information any
/// consumer (HUD, camera rig, input replay recorder) needs. We
/// deliberately avoid `CGSize` here so the package does not drag in
/// `CoreGraphics` on platforms that wouldn't otherwise need it —
/// Phase 0's goal is just "prove the wiring works".
public struct PanEvent: GameEvent, Equatable {

    /// Horizontal translation in points. Positive = finger moved right.
    public let dx: Double

    /// Vertical translation in points. Positive = finger moved down
    /// (SwiftUI's convention; we preserve it rather than invert here).
    public let dy: Double

    /// Trivial memberwise init, made explicit so the type stays
    /// usable from outside the module without `public` synthesis
    /// caveats.
    public init(dx: Double, dy: Double) {
        self.dx = dx
        self.dy = dy
    }
}

/// Stateless helper that ferries `PanEvent`s from a platform input
/// source (currently SwiftUI's `DragGesture`, wired up in SDGUI) to
/// the rest of the app via `EventBus`.
///
/// "Stateless" is load-bearing: the service stores nothing, so it's
/// safe to construct on demand inside a `View`'s body. It is a
/// `struct` (not a `class`) for the same reason — no identity to
/// preserve, no singleton temptation. AppEnvironment can vend one,
/// or UI code can create one ad-hoc; both paths end up publishing
/// to the same bus.
public struct TouchInputService: Sendable {

    /// The bus that `publish(pan:)` will fan events out through.
    ///
    /// Injected rather than pulled from a singleton (AGENTS.md
    /// Rule 2): the App entry point shares the same `EventBus`
    /// instance across all services via `AppEnvironment`.
    public let eventBus: EventBus

    public init(eventBus: EventBus) {
        self.eventBus = eventBus
    }

    /// Publish a pan sample on the shared event bus.
    ///
    /// Fire-and-forget from the caller's perspective: the bus's
    /// `publish` is `async` but does not throw, so the outer
    /// call-site only needs `await`. In Phase 0 the only subscriber
    /// is a debug logger; later phases will attach camera and HUD
    /// handlers here.
    public func publish(pan event: PanEvent) async {
        await eventBus.publish(event)
    }
}
