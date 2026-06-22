// AppEnvironment.swift
// SDGCore
//
// Dependency container passed top-down from the App entry point.
// Deliberately NOT a singleton — the App target constructs one at
// launch and injects it; tests and previews construct their own.

import Foundation

/// Aggregate of every framework-agnostic dependency a Store, System, or
/// View might need.
///
/// The App target creates a single `AppEnvironment` at launch and hands
/// it to the SwiftUI view tree via a `SwiftUI.EnvironmentKey` (defined
/// separately in `SDGUI` because that conformance requires
/// `import SwiftUI`, which this package cannot do).
///
/// Intentionally a value type: copying shares the underlying `EventBus`
/// actor reference while letting consumers treat the container itself as
/// immutable data.
public struct AppEnvironment: Sendable {

    /// Shared pub/sub bus for cross-layer events.
    public let eventBus: EventBus

    /// Localization lookup. Stateless; safe to share.
    public let localization: LocalizationService

    /// Sign in with Apple + Supabase session management. The default
    /// (`NoopAuthProvider`) lets previews/tests render without
    /// reaching the network; production `SendaiGLabApp.init`
    /// overrides with the real `AuthService` from SDGPlatform.
    public let authService: any AuthProviding

    /// Research telemetry writer (today just `sessions` rows). The
    /// default drops writes on the floor; production overrides with
    /// `TelemetryService` from SDGPlatform.
    public let telemetry: any TelemetryWriting

    /// Build an environment. Every argument has a sensible default so the
    /// App entry point can construct `AppEnvironment()` in the common
    /// case, and tests can override any single dependency.
    public init(
        eventBus: EventBus = EventBus(),
        localization: LocalizationService = .default,
        authService: any AuthProviding = NoopAuthProvider(),
        telemetry: any TelemetryWriting = NoopTelemetryWriter()
    ) {
        self.eventBus = eventBus
        self.localization = localization
        self.authService = authService
        self.telemetry = telemetry
    }
}
