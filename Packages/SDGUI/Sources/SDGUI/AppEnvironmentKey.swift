// AppEnvironmentKey.swift
// SDGUI
//
// SwiftUI glue for `AppEnvironment`. Lives in SDGUI (not SDGCore)
// because `EnvironmentKey` comes from SwiftUI and SDGCore must stay
// framework-agnostic (see ADR-0001 and ci_scripts/arch_lint.sh).

import SwiftUI
import SDGCore

/// SwiftUI `EnvironmentKey` for propagating an `AppEnvironment`
/// instance down the view tree.
///
/// The App target builds the real environment at launch and injects
/// it via `.environment(\.appEnvironment, env)`. Previews and tests
/// fall back to `AppEnvironment()` (constructed from `defaultValue`)
/// — that's enough to render views without crashing, and any test
/// that cares about wiring can override the key explicitly.
///
/// This type is intentionally `private` (module-private via file
/// scope on the `private struct`): callers should always go through
/// the `appEnvironment` accessor on `EnvironmentValues`, never reach
/// the key directly. That keeps the public surface small and
/// prevents someone from mutating a shared static.
private struct AppEnvironmentKey: EnvironmentKey {
    // SwiftUI requires a non-optional default so views compile
    // without a mandatory injection site. A fresh `AppEnvironment()`
    // is cheap and stateless (EventBus starts empty) — it is safe
    // for previews but *not* what production code should rely on;
    // the App target always overrides this.
    static let defaultValue: AppEnvironment = AppEnvironment()
}

public extension EnvironmentValues {
    /// The app-wide dependency container (event bus, localization,
    /// future platform services).
    ///
    /// Read it from a View with
    /// `@Environment(\.appEnvironment) private var env`.
    /// Write it from the App target with
    /// `.environment(\.appEnvironment, myEnvironment)`.
    var appEnvironment: AppEnvironment {
        get { self[AppEnvironmentKey.self] }
        set { self[AppEnvironmentKey.self] = newValue }
    }
}
