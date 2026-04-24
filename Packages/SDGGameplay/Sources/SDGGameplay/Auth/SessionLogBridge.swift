// SessionLogBridge.swift
// SDGGameplay · Auth
//
// Phase 10 Supabase POC: subscribes to `AppSessionStarted` on the
// EventBus and, if a user is signed in, writes one row to the
// `public.sessions` table via `TelemetryWriting`.
//
// ## Why is this file in SDGGameplay rather than SDGPlatform?
//
// Same reason as `AudioEventBridge`: the bridge imports the concrete
// `AppSessionStarted` type (declared in SDGGameplay/Auth/). Placing
// the bridge in Gameplay keeps the ADR-0001 dependency direction
// legal (Gameplay → Platform → Core).

import Foundation
import os
import SDGCore

@MainActor
public final class SessionLogBridge {

    // MARK: - Dependencies

    private let eventBus: EventBus
    private let authStore: AuthStore
    private let telemetry: any TelemetryWriting

    // MARK: - State

    private var tokens: [SubscriptionToken] = []

    private static let log = Logger(
        subsystem: "jp.tohoku-gakuin.fshera.sendai-glab",
        category: "telemetry"
    )

    // MARK: - Init

    public init(
        eventBus: EventBus,
        authStore: AuthStore,
        telemetry: any TelemetryWriting
    ) {
        self.eventBus = eventBus
        self.authStore = authStore
        self.telemetry = telemetry
    }

    // MARK: - Lifecycle

    public func start() async {
        // Capture dependencies by value into handlers. The bridge's
        // lifetime subsumes the handler's, so strong captures are
        // safe; matches `AudioEventBridge`'s rationale.
        let telemetry = telemetry
        let store = authStore

        // 1. Foreground / cold-launch transitions — payload carries
        //    osVersion + locale (captured at publish time by the App).
        let sessionToken = await eventBus.subscribe(AppSessionStarted.self) { event in
            await MainActor.run {
                guard let userId = store.currentUserId else {
                    // First-launch path: user hasn't signed in yet.
                    // The `.signIn` handler below will fire once they
                    // do, so the session still gets logged.
                    Self.log.debug("AppSessionStarted dropped: no signed-in user")
                    return
                }
                Self.log(
                    telemetry: telemetry,
                    userId: userId,
                    at: event.at,
                    osVersion: event.osVersion,
                    locale: event.locale
                )
            }
        }

        // 2. Fresh sign-in — the `.active` event already fired with
        //    `userId == nil` so the first-launch session would be
        //    missed without this hook. We gather osVersion / locale
        //    here rather than carry them on `UserSignedIn` because
        //    they're a telemetry detail that should not bleed into
        //    every consumer of the auth event.
        let signInToken = await eventBus.subscribe(UserSignedIn.self) { event in
            await MainActor.run {
                Self.log(
                    telemetry: telemetry,
                    userId: event.userId,
                    at: Date(),
                    osVersion: Self.currentOSVersion(),
                    locale: Self.currentLocale()
                )
            }
        }

        tokens = [sessionToken, signInToken]
        print("[SDG-Lab][telemetry] SessionLogBridge started with \(tokens.count) subscriptions")
    }

    // MARK: - Helpers

    /// Fire-and-forget session INSERT. Errors are swallowed into
    /// `os.log` so a failed write never crashes gameplay.
    private static func log(
        telemetry: any TelemetryWriting,
        userId: UUID,
        at: Date,
        osVersion: String,
        locale: String
    ) {
        Task {
            do {
                try await telemetry.logSession(
                    userId: userId,
                    at: at,
                    osVersion: osVersion,
                    locale: locale
                )
            } catch {
                log.error(
                    "logSession failed: \(error.localizedDescription, privacy: .public)"
                )
            }
        }
    }

    /// iPadOS version string (e.g. `"18.3"`). Uses `ProcessInfo`
    /// rather than `UIDevice` so the bridge remains usable in a
    /// macOS test host.
    private static func currentOSVersion() -> String {
        let v = ProcessInfo.processInfo.operatingSystemVersion
        return "\(v.majorVersion).\(v.minorVersion).\(v.patchVersion)"
    }

    /// BCP-47 locale (e.g. `"ja-JP"`). Matches the identifiers Apple
    /// returns from `Locale.current.identifier`.
    private static func currentLocale() -> String {
        Locale.current.identifier
    }

    public func stop() async {
        for token in tokens {
            await eventBus.cancel(token)
        }
        tokens.removeAll()
    }

    // MARK: - Test-only introspection

    public var subscriptionCount: Int { tokens.count }
}
