// AuthEvents.swift
// SDGGameplay · Auth
//
// Phase 10 Supabase POC: three events that model the auth + session-
// logging pipeline. Value types, no live references — they cross actor
// boundaries (publishing from `AuthStore` / `SendaiGLabApp`, consumed
// by `SessionLogBridge`).
//
// `AppSessionStarted` is published on every `scenePhase == .active`
// transition so both cold launch and foreground-from-background land
// one row in `public.sessions` — see ADR-0011.

import Foundation
import SDGCore

/// Fired when `AuthStore` completes a Sign in with Apple round-trip
/// against Supabase, or when it restores a persisted session on boot.
/// Subscribers (currently only Gameplay-layer stores) may treat this
/// as "we now have an authenticated `userId` to attach to writes".
public struct UserSignedIn: GameEvent, Equatable {
    public let userId: UUID
    public init(userId: UUID) {
        self.userId = userId
    }
}

/// Fired when `AuthStore` signs the user out. No payload — the last-
/// known `userId` is already on subscribers if they cached it.
public struct UserSignedOut: GameEvent, Equatable {
    public init() {}
}

/// Fired by `SendaiGLabApp` on every scene-phase transition into
/// `.active`. `SessionLogBridge` subscribes and, if a user is signed
/// in, writes one row to the `sessions` table. If no user is signed
/// in the event is dropped silently (the sign-in cover will grab
/// control anyway).
public struct AppSessionStarted: GameEvent, Equatable {

    /// Moment the transition was observed, captured at publish time
    /// rather than insert time so the row reflects when the user
    /// returned to the app — not whenever the network round-trip
    /// completed.
    public let at: Date

    /// iPadOS version string (e.g. "18.3"). Collected at publish
    /// time to keep the event self-contained.
    public let osVersion: String

    /// BCP-47 locale (e.g. "ja-JP"). Useful for research across the
    /// ja / en / zh-Hant locales we ship.
    public let locale: String

    public init(at: Date, osVersion: String, locale: String) {
        self.at = at
        self.osVersion = osVersion
        self.locale = locale
    }
}
