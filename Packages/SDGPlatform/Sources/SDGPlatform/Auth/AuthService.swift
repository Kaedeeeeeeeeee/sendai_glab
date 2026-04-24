// AuthService.swift
// SDGPlatform · Auth
//
// Phase 10 Supabase POC: production `AuthProviding` impl. Wraps a
// `SupabaseClient` for Sign in with Apple + session restore.
//
// ## Why @MainActor?
//
// Matches `AudioService`'s rationale: the SDK is `Sendable` but the
// surface we call it from is the UI thread. Pinning the facade to
// MainActor keeps isolation boundaries simple for callers (which are
// themselves @MainActor `Store`s).
//
// ## Session persistence
//
// `supabase-swift` 2.x caches the access+refresh tokens in the
// Keychain via its `sessionStorage`. We rely on that — no manual
// Keychain code here. `restoreSession()` just asks the SDK whether
// a valid session is already in memory / storage.

import Foundation
import os
import SDGCore
import Supabase

@MainActor
open class AuthService: AuthProviding {

    private let client: SupabaseClient

    private static let log = Logger(
        subsystem: "jp.tohoku-gakuin.fshera.sendai-glab",
        category: "auth"
    )

    /// Init from a parsed config. `AppEnvironment` holds the
    /// `SupabaseClient` (single instance, shared by `TelemetryService`
    /// too) so the two services talk to the same auth state.
    public init(client: SupabaseClient) {
        self.client = client
    }

    /// Convenience for the app entry path: `AuthService(config:)` hides
    /// the SDK type behind the plist-driven config.
    public convenience init(config: SupabaseConfig) {
        self.init(client: SupabaseClient(
            supabaseURL: config.url,
            supabaseKey: config.anonKey
        ))
    }

    // MARK: - AuthProviding

    public func restoreSession() async throws -> UUID? {
        // `currentSession` is sync, nonisolated. It returns nil if no
        // refresh token in Keychain OR the token is expired and no
        // refresh has succeeded yet. The SDK also exposes an async
        // `session` that refreshes on demand; we keep to the sync form
        // because launch-time is latency-sensitive and an expired
        // refresh token should push the user to the sign-in cover
        // rather than quietly blocking on a network round-trip.
        guard let session = client.auth.currentSession else { return nil }
        return session.user.id
    }

    public func signInWithApple(idToken: String, rawNonce: String) async throws -> UUID {
        let credentials = OpenIDConnectCredentials(
            provider: .apple,
            idToken: idToken,
            nonce: rawNonce
        )
        let session = try await client.auth.signInWithIdToken(
            credentials: credentials
        )
        Self.log.info(
            "signInWithApple succeeded: \(session.user.id.uuidString, privacy: .public)"
        )
        return session.user.id
    }

    public func signOut() async throws {
        try await client.auth.signOut()
        Self.log.info("signOut complete")
    }

    // MARK: - Shared client accessor

    /// Sibling services (`TelemetryService`) need the same client so
    /// their `from("...")` calls inherit the current session. Exposed
    /// as a plain getter — `AppEnvironment` does the wiring at init
    /// time and nobody mutates the client after that.
    public var sharedClient: SupabaseClient { client }
}
