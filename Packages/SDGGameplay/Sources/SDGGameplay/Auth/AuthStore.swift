// AuthStore.swift
// SDGGameplay · Auth
//
// Phase 10 Supabase POC: `@Observable` state container for the user's
// signed-in status. Owned by `ContentView`; `SignInView` observes
// `currentUserId` / `lastError` / `inFlight` via `@Bindable`.
//
// ## Lifecycle
//
//     init(bus, auth)              // wire deps; no I/O
//     intent(.restoreOnLaunch)     // read persisted Supabase session
//     intent(.signInWithApple...)  // exchange Apple idToken for session
//     intent(.signOut)             // drop session locally + server-side
//
// Errors surface on `lastError` (a short human-readable string the
// cover UI can display). The research flow is narrow enough that a
// full typed-error UI is overkill at this stage — follow-up work can
// refine this surface.

import Foundation
import Observation
import SDGCore

// MARK: - Intent

public enum AuthIntent: Sendable {
    /// Check for a persisted Supabase session on boot. Success
    /// populates `currentUserId` and publishes `UserSignedIn`. No-op
    /// (silently) when no session exists — the caller's UI decides
    /// whether to present the sign-in cover.
    case restoreOnLaunch

    /// Exchange an Apple identity token for a Supabase session.
    /// Callers must also supply the raw nonce whose SHA-256 was sent
    /// to Apple as part of the request.
    case signInWithApple(idToken: String, rawNonce: String)

    /// Invalidate the current session.
    case signOut
}

// MARK: - Store

@Observable @MainActor
public final class AuthStore: Store {

    // MARK: - Observable state

    /// The signed-in user's Supabase `auth.users.id`, or `nil` if
    /// there's no live session. `ContentView` watches this to decide
    /// between `SignInView` (nil) and `RootView` (non-nil).
    public private(set) var currentUserId: UUID?

    /// Short human-readable error string, or `nil`. Set by a failed
    /// sign-in intent; cleared on next attempt. Not a typed error —
    /// the POC only distinguishes "something failed" from success.
    public private(set) var lastError: String?

    /// True while a sign-in / restore round-trip is in flight. The
    /// sign-in button binds its `disabled` state to this so a user
    /// can't spam-tap during the Apple popup + Supabase exchange.
    public private(set) var inFlight: Bool = false

    // MARK: - Dependencies

    private let eventBus: EventBus
    private let authService: any AuthProviding

    // MARK: - Init

    public init(eventBus: EventBus, authService: any AuthProviding) {
        self.eventBus = eventBus
        self.authService = authService
    }

    // MARK: - UI error reporting

    /// Let the sign-in surface (e.g. `SignInView`) report a
    /// client-side failure before the intent even reaches Supabase —
    /// for example Apple cancelled, or returned no identity token.
    /// Keeps `lastError` a single source of truth for the POC's
    /// "something went wrong" UX.
    public func reportUIError(_ message: String) {
        lastError = message
    }

    // MARK: - Intent

    public func intent(_ intent: AuthIntent) async {
        switch intent {
        case .restoreOnLaunch:
            await handleRestore()
        case .signInWithApple(let idToken, let rawNonce):
            await handleSignIn(idToken: idToken, rawNonce: rawNonce)
        case .signOut:
            await handleSignOut()
        }
    }

    // MARK: - Private

    private func handleRestore() async {
        inFlight = true
        defer { inFlight = false }
        do {
            if let userId = try await authService.restoreSession() {
                currentUserId = userId
                await eventBus.publish(UserSignedIn(userId: userId))
            }
            // No session to restore is the common first-launch path —
            // silent, not an error. Leave `lastError` alone.
        } catch {
            // A throwing restore path is rare (e.g. Keychain corruption).
            // Surface it so a developer sees it in Console.app; the UI
            // treats it as "not signed in" and shows the cover.
            lastError = "restore failed: \(error.localizedDescription)"
        }
    }

    private func handleSignIn(idToken: String, rawNonce: String) async {
        lastError = nil
        inFlight = true
        defer { inFlight = false }
        do {
            let userId = try await authService.signInWithApple(
                idToken: idToken, rawNonce: rawNonce
            )
            currentUserId = userId
            await eventBus.publish(UserSignedIn(userId: userId))
        } catch {
            lastError = "sign-in failed: \(error.localizedDescription)"
        }
    }

    private func handleSignOut() async {
        inFlight = true
        defer { inFlight = false }
        do {
            try await authService.signOut()
        } catch {
            // Even if the server call fails we still clear local state
            // — the user wanted out. Server-side session will expire
            // naturally.
            lastError = "sign-out partial: \(error.localizedDescription)"
        }
        currentUserId = nil
        await eventBus.publish(UserSignedOut())
    }
}
