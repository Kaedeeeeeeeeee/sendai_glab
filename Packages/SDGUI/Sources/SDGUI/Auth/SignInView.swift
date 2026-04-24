// SignInView.swift
// SDGUI · Auth
//
// Phase 10 Supabase POC: the fullScreenCover shown by ContentView
// while `AuthStore.currentUserId == nil`. Wraps Apple's native
// `SignInWithAppleButton` and hands the result back to `AuthStore`.
//
// No skip button — research use requires a signed-in identity, and
// the user explicitly chose "block gameplay until signed in"
// (see /Users/user/.claude/plans/supabase-tender-sloth.md).

import AuthenticationServices
import SwiftUI
import SDGGameplay
import SDGPlatform

public struct SignInView: View {

    /// Generated once per view appearance. `onRequest` hands the
    /// `hash` to Apple; `onCompletion` passes the `raw` to Supabase
    /// (which hashes and compares server-side). Regenerated on each
    /// new attempt so replays are impossible.
    @State private var nonce: AppleNonce = AppleNonceGenerator.make()

    /// The `AuthStore` to drive. `@Bindable` gives SwiftUI a
    /// Observation subscription without needing `@State` semantics.
    @Bindable public var store: AuthStore

    public init(store: AuthStore) {
        self.store = store
    }

    public var body: some View {
        VStack(spacing: 24) {
            Spacer()

            // Minimal POC chrome. A research consent screen and
            // proper branding are out of scope here; follow-up work
            // before App Store submission will dress this up.
            VStack(spacing: 8) {
                Text("SDG-Lab")
                    .font(.largeTitle.weight(.bold))
                Text("Sign in to start the research session")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }

            SignInWithAppleButton(
                .signIn,
                onRequest: { request in
                    // Apple receives the SHA-256 hex of our raw
                    // nonce. Supabase will verify the claim
                    // server-side. No scopes requested — we don't
                    // need email/name for the POC session log.
                    request.requestedScopes = []
                    request.nonce = nonce.hash
                },
                onCompletion: { result in
                    Task { await handle(result: result) }
                }
            )
            .signInWithAppleButtonStyle(.black)
            .frame(width: 280, height: 48)
            .disabled(store.inFlight)

            if let error = store.lastError {
                Text(error)
                    .font(.footnote)
                    .foregroundStyle(.red)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 40)
            }

            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Self.backgroundColor)
    }

    /// Platform-appropriate opaque background. iOS uses the system
    /// background colour; macOS falls through to `white` so the view
    /// still compiles for the cross-platform SDGUI target.
    private static var backgroundColor: Color {
        #if canImport(UIKit)
        Color(uiColor: .systemBackground)
        #else
        Color.white
        #endif
    }

    // MARK: - Completion

    private func handle(
        result: Result<ASAuthorization, any Error>
    ) async {
        switch result {
        case .failure(let error):
            store.reportUIError("Apple cancelled: \(error.localizedDescription)")
        case .success(let auth):
            guard let credential = auth.credential
                    as? ASAuthorizationAppleIDCredential,
                  let tokenData = credential.identityToken,
                  let idToken = String(data: tokenData, encoding: .utf8)
            else {
                store.reportUIError("Apple returned no identity token")
                return
            }
            let raw = nonce.raw
            // Regenerate before awaiting the sign-in so a retry
            // tap uses a fresh nonce.
            nonce = AppleNonceGenerator.make()
            await store.intent(.signInWithApple(
                idToken: idToken, rawNonce: raw
            ))
        }
    }
}
