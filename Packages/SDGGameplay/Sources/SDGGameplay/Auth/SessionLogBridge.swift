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
//
// ## Who publishes `AppSessionStarted`
//
// Two producers, each covering a disjoint case so the bridge sees
// exactly one event per real session:
//   1. `SendaiGLabApp.onChange(scenePhase → .active)` fires on
//      foreground-from-background. (SwiftUI does NOT fire onChange
//      for the initial `.active` on cold launch, so this path is
//      explicitly NOT responsible for cold launches.)
//   2. `ContentView.onChange(authStore.currentUserId)` fires once
//      when the user id transitions from `nil` → UUID — i.e. after
//      `restoreOnLaunch` succeeds OR a fresh Sign in with Apple
//      completes. This covers the cold-launch case without racing
//      against `.active`.
// The two paths don't overlap in real usage: on cold launch only
// (2) fires; on foreground-from-background only (1) fires.

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
        // Capture dependencies by value into the handler. The bridge's
        // lifetime subsumes the handler's, so strong captures are
        // safe; matches `AudioEventBridge`'s rationale.
        let telemetry = telemetry
        let store = authStore

        let sessionToken = await eventBus.subscribe(AppSessionStarted.self) { event in
            await MainActor.run {
                guard let userId = store.currentUserId else {
                    // Unreachable in normal flow — both publishers
                    // gate on `currentUserId != nil` — but we keep
                    // the guard + log so a future new producer that
                    // forgets the gate surfaces loudly instead of
                    // silently writing NULL user ids that RLS would
                    // reject anyway.
                    Self.log.debug("AppSessionStarted dropped: no signed-in user")
                    return
                }
                Task {
                    do {
                        try await telemetry.logSession(
                            userId: userId,
                            at: event.at,
                            osVersion: event.osVersion,
                            locale: event.locale
                        )
                    } catch {
                        Self.log.error(
                            "logSession failed: \(error.localizedDescription, privacy: .public)"
                        )
                    }
                }
            }
        }

        tokens = [sessionToken]
        print("[SDG-Lab][telemetry] SessionLogBridge started with \(tokens.count) subscription")
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
