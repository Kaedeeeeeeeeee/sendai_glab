// TelemetryWriting.swift
// SDGCore · Auth
//
// Phase 10 Supabase POC: the protocol `SessionLogBridge` depends on.
// Lives in SDGCore so `AppEnvironment` can carry an
// `any TelemetryWriting` without pulling supabase-swift into the
// base layer. Production conformer: `TelemetryService` in
// SDGPlatform.

import Foundation

/// Minimal write surface for research telemetry. Today just session
/// events; future work adds methods for quest / drilling / etc. The
/// protocol lives in SDGPlatform because the production impl wraps
/// supabase-swift; the abstraction lets SDGGameplay tests stay
/// hermetic.
public protocol TelemetryWriting: Sendable {

    /// Append one row to `public.sessions`. Fire-and-forget from the
    /// caller's perspective — exceptions are thrown but the bridge
    /// catches and logs them rather than crashing the app.
    ///
    /// - Parameters:
    ///   - userId: The authenticated Supabase user id. RLS will reject
    ///     the INSERT if it doesn't match `auth.uid()` on the
    ///     connection.
    ///   - at: When the session started. Captured client-side at the
    ///     scene-phase transition, not server-side at insert time.
    ///   - osVersion: e.g. `"18.3"`.
    ///   - locale: BCP-47, e.g. `"ja-JP"`.
    func logSession(
        userId: UUID,
        at: Date,
        osVersion: String,
        locale: String
    ) async throws
}
