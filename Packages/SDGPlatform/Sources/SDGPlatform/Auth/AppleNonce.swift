// AppleNonce.swift
// SDGPlatform · Auth
//
// Phase 10 Supabase POC: generates the `raw` / `hash` nonce pair used
// by Sign in with Apple. Apple's `ASAuthorizationAppleIDRequest.nonce`
// receives the SHA-256 hex hash; Supabase's `signInWithIdToken` call
// receives the raw value. Apple's JWT then carries the hash in its
// `nonce` claim, and Supabase compares `SHA256(raw) == claim` on the
// server — so we MUST send raw to Supabase, hash to Apple.

import CryptoKit
import Foundation

/// The pair Sign in with Apple needs. Produced by `AppleNonce.make()`.
public struct AppleNonce: Sendable, Equatable {
    /// Raw random nonce. Hand this to Supabase's `signInWithIdToken`
    /// so it can SHA-256 the value and compare against Apple's JWT.
    public let raw: String
    /// SHA-256 hex of `raw`. Hand this to
    /// `ASAuthorizationAppleIDRequest.nonce` — Apple embeds it in the
    /// JWT `nonce` claim unchanged.
    public let hash: String

    public init(raw: String, hash: String) {
        self.raw = raw
        self.hash = hash
    }
}

public enum AppleNonceGenerator {

    /// Produce a fresh nonce pair. The raw value is 32 bytes of
    /// `SecRandomCopyBytes` output encoded as a URL-safe base64
    /// string; the hash is the lowercase hex SHA-256 of that string.
    ///
    /// `SecRandomCopyBytes` is Apple's kernel CSPRNG — suitable for
    /// CSRF nonces. 32 bytes exceeds the 128-bit minimum Apple's
    /// sample code recommends.
    public static func make() -> AppleNonce {
        let raw = randomString(byteCount: 32)
        let hashed = SHA256.hash(data: Data(raw.utf8))
        let hex = hashed.map { String(format: "%02x", $0) }.joined()
        return AppleNonce(raw: raw, hash: hex)
    }

    /// Base64url-encoded CSPRNG bytes. URL-safe encoding avoids `+ / =`
    /// so the raw string is safe to round-trip through any transport
    /// without URL-encoding surprises.
    private static func randomString(byteCount: Int) -> String {
        var bytes = [UInt8](repeating: 0, count: byteCount)
        let status = SecRandomCopyBytes(kSecRandomDefault, byteCount, &bytes)
        // `errSecSuccess == 0`. If the kernel RNG fails on iOS the
        // device is in a bad state — crashing is the honest response.
        precondition(status == errSecSuccess, "SecRandomCopyBytes failed: \(status)")
        return Data(bytes)
            .base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
