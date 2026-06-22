// NoopAuth.swift
// SDGCore · Auth
//
// Phase 10 Supabase POC: zero-dependency stubs used as
// `AppEnvironment` defaults for SwiftUI previews and tests that do
// not care about auth. Production builds always replace these with
// the real `AuthService` / `TelemetryService` in `SendaiGLabApp.init`.

import Foundation

/// Always returns `nil` for restore, throws on any sign-in attempt.
/// Used as the default value for `AppEnvironment.authService` so
/// previews can render without crashing.
public struct NoopAuthProvider: AuthProviding {

    public init() {}

    public func restoreSession() async throws -> UUID? { nil }

    public func signInWithApple(
        idToken: String, rawNonce: String
    ) async throws -> UUID {
        throw NoopError.notAvailable
    }

    public func signOut() async throws {}

    public enum NoopError: Error, Sendable {
        /// Preview / test environment without a real auth backend.
        case notAvailable
    }
}

/// Drops every `logSession` call on the floor. Used as the default
/// value for `AppEnvironment.telemetry` so previews and tests do not
/// accidentally send rows to a real database.
public struct NoopTelemetryWriter: TelemetryWriting {

    public init() {}

    public func logSession(
        userId: UUID,
        at: Date,
        osVersion: String,
        locale: String
    ) async throws {
        // intentionally empty
    }
}
