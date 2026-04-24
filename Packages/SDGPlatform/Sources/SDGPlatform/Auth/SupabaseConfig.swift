// SupabaseConfig.swift
// SDGPlatform · Auth
//
// Phase 10 Supabase POC: loads the project URL + anon key from a
// bundled plist at app start. The plist is committed (the anon key is
// public by design; Postgres Row Level Security is what protects
// research data) — see ADR-0011.

import Foundation

/// Bundle-backed config for the Supabase client. Constructed once in
/// `SendaiGLabApp.init` and handed to `AuthService` / `TelemetryService`.
public struct SupabaseConfig: Sendable, Equatable {

    public let url: URL
    public let anonKey: String

    public init(url: URL, anonKey: String) {
        self.url = url
        self.anonKey = anonKey
    }

    /// Resource name (without extension) inside the app bundle. iOS
    /// flattens `Resources/Supabase/SupabaseConfig.plist` into the
    /// bundle root at build time, so we look it up without a
    /// subdirectory. SPM test bundles preserve the tree, so the
    /// loader below tries the subdirectory path too.
    private static let resourceName = "SupabaseConfig"

    public enum LoadError: Error, Sendable {
        /// The plist resource was not found in the bundle at all. In
        /// Debug this hard-crashes via `fatalError` — forgetting to
        /// copy `SupabaseConfig.plist.example` → `SupabaseConfig.plist`
        /// is the #1 first-run mistake and should surface loudly.
        case resourceNotFound
        /// The plist parsed but didn't have one of the two expected
        /// keys, or the values weren't strings.
        case malformed(reason: String)
        /// `SUPABASE_URL` was not a valid URL.
        case invalidURL(String)
    }

    /// Load the config from a bundle. Production callers pass `.main`;
    /// tests may pass an ad-hoc bundle pointing at a fixture plist.
    ///
    /// - Throws: `LoadError` if the plist is missing, malformed, or
    ///   contains an unparseable URL. In Debug the caller should treat
    ///   any throw as a setup mistake and crash hard (see `loadOrCrash`).
    public static func load(bundle: Bundle = .main) throws -> SupabaseConfig {
        let url = bundle.url(
            forResource: resourceName,
            withExtension: "plist",
            subdirectory: "Supabase"
        ) ?? bundle.url(
            forResource: resourceName,
            withExtension: "plist"
        )

        guard let plistURL = url else {
            throw LoadError.resourceNotFound
        }

        let data = try Data(contentsOf: plistURL)
        guard let raw = try PropertyListSerialization.propertyList(
            from: data, options: [], format: nil
        ) as? [String: Any] else {
            throw LoadError.malformed(reason: "root is not a dict")
        }
        guard let urlString = raw["SUPABASE_URL"] as? String, !urlString.isEmpty else {
            throw LoadError.malformed(reason: "SUPABASE_URL missing or empty")
        }
        guard let anonKey = raw["SUPABASE_ANON_KEY"] as? String, !anonKey.isEmpty else {
            throw LoadError.malformed(reason: "SUPABASE_ANON_KEY missing or empty")
        }
        guard let projectURL = URL(string: urlString) else {
            throw LoadError.invalidURL(urlString)
        }
        return SupabaseConfig(url: projectURL, anonKey: anonKey)
    }

    /// Convenience for app entry: load or crash. Debug builds crash
    /// on any load error with a message that names the missing file,
    /// so a new contributor immediately sees that they need to copy
    /// `SupabaseConfig.plist.example` → `SupabaseConfig.plist`.
    /// Release builds currently also crash — the app cannot run
    /// without auth, so there is nothing useful to fall back to.
    public static func loadOrCrash(bundle: Bundle = .main) -> SupabaseConfig {
        do {
            return try load(bundle: bundle)
        } catch {
            fatalError(
                """
                SupabaseConfig.plist could not be loaded: \(error).
                Copy Resources/Supabase/SupabaseConfig.plist.example to
                Resources/Supabase/SupabaseConfig.plist and fill in the
                project URL + anon key from the Supabase Dashboard.
                """
            )
        }
    }
}
