// AuthProviding.swift
// SDGCore · Auth
//
// Phase 10 Supabase POC: protocol boundary between `AuthStore`
// (SDGGameplay) and the real `AuthService` (SDGPlatform). Lives in
// SDGCore so `AppEnvironment` can carry an `any AuthProviding`
// without pulling supabase-swift into the base layer. Production
// conformer: `AuthService` in SDGPlatform. Tests use
// `FakeAuthProvider` in SDGGameplay test target.

import Foundation

/// The slim auth surface `AuthStore` depends on. Matches the three
/// real operations: restore a persisted session on launch, sign in
/// with an Apple identity token, sign out.
///
/// All methods are `async throws`. `restoreSession` returns `nil` when
/// no session exists (not an error). Sign-in failure or network-down
/// is thrown.
public protocol AuthProviding: Sendable {

    /// Return the persisted user id if the SDK still has a valid
    /// refresh token in Keychain. `nil` if the user has never signed
    /// in on this device, or their refresh token is no longer valid.
    func restoreSession() async throws -> UUID?

    /// Exchange an Apple identity token (idToken) + raw nonce for a
    /// Supabase session. Returns the resulting user id.
    ///
    /// - Parameters:
    ///   - idToken: The UTF-8 string form of
    ///     `ASAuthorizationAppleIDCredential.identityToken`.
    ///   - rawNonce: The `raw` field of the `AppleNonce` that was
    ///     SHA-256'd into Apple's request. Supabase hashes it
    ///     server-side and compares to Apple's JWT claim.
    func signInWithApple(idToken: String, rawNonce: String) async throws -> UUID

    /// Invalidate the current session locally and on the server.
    /// Idempotent; safe to call if no session exists.
    func signOut() async throws
}
