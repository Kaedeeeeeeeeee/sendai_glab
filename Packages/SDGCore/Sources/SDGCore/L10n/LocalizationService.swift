// LocalizationService.swift
// SDGCore
//
// Stateless wrapper around Foundation's String Catalog lookup. SDGCore
// must remain framework-agnostic, so we deliberately use pure Foundation
// (`String(localized:)`), not SwiftUI's `Text(_ key:)`.

import Foundation

/// Stateless lookup service for localized strings.
///
/// Resolves a key from the main bundle's compiled `.xcstrings` file using
/// `String(localized:)`. On miss, returns the key itself (fail-open) so
/// placeholder UI is obvious instead of crashing.
///
/// This is a `struct` with a `Sendable` stored `Bundle` so instances can
/// freely cross actor boundaries. The default instance is exposed as
/// `.default` for convenience; it is **not** a singleton — tests should
/// (and do) create fresh instances with a custom bundle.
public struct LocalizationService: Sendable {

    /// Bundle to search. Defaults to `.main`, which finds the compiled
    /// Localizable.xcstrings shipped with the host app.
    private let bundle: Bundle

    /// Create a service bound to a specific bundle. Defaults to `.main`.
    public init(bundle: Bundle = .main) {
        self.bundle = bundle
    }

    /// Shared default instance.
    ///
    /// Exposed as `let` on the type so callers can write
    /// `LocalizationService.default` without allocating. Not a singleton:
    /// it's a value, and callers can freely construct their own.
    public static let `default`: LocalizationService = LocalizationService()

    // MARK: - Lookup

    /// Look up `key` and return its localized value.
    ///
    /// - Parameters:
    ///   - key: A key from `LocalizationKey.swift` (`L10n.UI.settingsTitle`,
    ///          etc.). Raw strings are accepted so this works from test
    ///          code, but production call sites should go through `L10n`.
    ///   - args: Optional `printf`-style arguments interpolated into the
    ///           resolved string (which may contain `%@`, `%d`, etc.).
    /// - Returns: The localized string, or `key` itself on miss.
    public func t(_ key: String, _ args: CVarArg...) -> String {
        // `String(localized:bundle:)` is the Foundation API that reads
        // from the compiled String Catalog. It falls back to the key
        // when no entry exists, which matches our fail-open contract.
        //
        // We pass `String.LocalizationValue(stringLiteral:)` via the
        // `defaultValue:` slot so a missing entry yields the key rather
        // than an empty string.
        let resolved = String(
            localized: String.LocalizationValue(key),
            bundle: bundle
        )
        // If there are format args, apply them. Otherwise return as-is to
        // avoid accidental `%` interpretation in keys that contain literal
        // percent signs.
        guard !args.isEmpty else { return resolved }
        return String(format: resolved, arguments: args)
    }

    /// Current preferred language code (e.g. `"ja"`, `"en"`, `"zh-Hans"`).
    ///
    /// Follows the system's preferred language list. Returns `"en"` if
    /// no preferred language is configured (should never happen on
    /// device; possible in synthetic test environments).
    public func currentLanguage() -> String {
        Bundle.main.preferredLocalizations.first
            ?? Locale.preferredLanguages.first
            ?? "en"
    }
}
