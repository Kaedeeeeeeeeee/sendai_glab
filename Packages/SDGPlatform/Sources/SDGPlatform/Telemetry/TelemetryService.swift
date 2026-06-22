// TelemetryService.swift
// SDGPlatform · Telemetry
//
// Phase 10 Supabase POC: production `TelemetryWriting` impl. Inserts
// one row into `public.sessions` per app launch / foreground.
//
// ## Why @MainActor?
//
// Matches `AuthService`. `SessionLogBridge` is itself @MainActor (it
// owns a `Store` reference via the EventBus handler). Keeping all
// auth-adjacent services on MainActor removes the need for actor
// hopping at the call site.
//
// ## Offline / network-down
//
// The POC drops events on network failure (logs to `os.log`). A
// queue + retry layer is explicit non-goal per ADR-0011.

import Foundation
import os
import SDGCore
import Supabase

@MainActor
open class TelemetryService: TelemetryWriting {

    /// Shared with `AuthService` so inserts use the same auth session
    /// (RLS requires `auth.uid() == user_id` to pass the INSERT policy).
    private let client: SupabaseClient

    private static let log = Logger(
        subsystem: "jp.tohoku-gakuin.fshera.sendai-glab",
        category: "telemetry"
    )

    public init(client: SupabaseClient) {
        self.client = client
    }

    public func logSession(
        userId: UUID,
        at: Date,
        osVersion: String,
        locale: String
    ) async throws {
        let row = SessionRow(
            user_id: userId.uuidString,
            started_at: Self.iso8601.string(from: at),
            os_version: osVersion,
            locale: locale
        )
        try await client.from("sessions").insert(row).execute()
        Self.log.info(
            "session logged for \(userId.uuidString, privacy: .public) at \(at.timeIntervalSince1970)"
        )
    }

    // MARK: - Row type

    /// Matches the `public.sessions` columns the client is expected to
    /// supply. `id`, `created_at` are server-filled defaults; RLS
    /// validates `user_id == auth.uid()` on insert.
    ///
    /// Snake-case field names match the column names so we don't need
    /// a custom `CodingKeys` block.
    private struct SessionRow: Encodable {
        let user_id: String       // swiftlint:disable:this identifier_name
        let started_at: String    // swiftlint:disable:this identifier_name
        let os_version: String    // swiftlint:disable:this identifier_name
        let locale: String
    }

    // MARK: - Formatter

    /// ISO8601 w/ fractional seconds — PostgREST parses this into
    /// `timestamptz` unambiguously.
    private static let iso8601: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
}
