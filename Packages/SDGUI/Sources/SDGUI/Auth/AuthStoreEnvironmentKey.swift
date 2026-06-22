// AuthStoreEnvironmentKey.swift
// SDGUI · Auth
//
// Phase 10 Supabase POC: SwiftUI EnvironmentKey for propagating the
// live `AuthStore` down to `RootView`. `ContentView` owns the store
// (it's per-session and stateful), but `RootView` needs a handle so
// `SessionLogBridge` knows whose userId to attach to each INSERT.
//
// Default is `nil` — SwiftUI previews / unit tests render without an
// injection, and `RootView.bootstrap` short-circuits the session-log
// wiring when the store isn't present. Production `ContentView`
// always overrides via `.environment(\.authStore, realStore)`.

import SwiftUI
import SDGGameplay

private struct AuthStoreKey: EnvironmentKey {
    static let defaultValue: AuthStore? = nil
}

public extension EnvironmentValues {
    /// The app-wide signed-in user state. Set by `ContentView`
    /// immediately after it constructs the real store; read by any
    /// view that needs to react to sign-in status (`RootView` and
    /// `SessionLogBridge` — currently nobody else).
    var authStore: AuthStore? {
        get { self[AuthStoreKey.self] }
        set { self[AuthStoreKey.self] = newValue }
    }
}
