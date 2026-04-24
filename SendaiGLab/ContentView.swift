import SwiftUI
import SDGCore
import SDGGameplay
import SDGUI

// Thin composition root: take the `AppEnvironment` the App target
// built at launch, construct the single per-process `AuthStore`,
// decide whether the game is reachable (signed in) or gated
// (SignInView cover), and hand off to `RootView` (which owns the
// real Phase 0+ scene).
//
// All rendering and input lives in `RootView` (SDGUI); all domain
// state lives in `AppEnvironment` (SDGCore).

struct ContentView: View {

    /// The shared dependency container. Passed in from
    /// `SendaiGLabApp`'s stored property so both App and View
    /// agree on exactly one instance per launch.
    let environment: AppEnvironment

    /// Sign-in status store. Created once at first render with the
    /// live `AuthService` from the environment. `@State` keeps it
    /// for the view's lifetime.
    @State private var authStore: AuthStore

    init(environment: AppEnvironment) {
        self.environment = environment
        self._authStore = State(initialValue: AuthStore(
            eventBus: environment.eventBus,
            authService: environment.authService
        ))
    }

    var body: some View {
        RootView()
            .environment(\.appEnvironment, environment)
            .environment(\.authStore, authStore)
            .fullScreenCover(isPresented: notSignedIn) {
                SignInView(store: authStore)
            }
            .task {
                // Phase 10 POC: attempt to restore a persisted
                // Supabase session on first render. If it succeeds
                // the cover dismisses itself via `notSignedIn`; if
                // not, the cover stays up and prompts Sign in with
                // Apple.
                await authStore.intent(.restoreOnLaunch)
            }
    }

    /// Binding the cover observes. `get` drives presentation;
    /// `set` is a deliberate no-op — the cover can't be dismissed
    /// by the user (research use requires a signed-in identity).
    /// It will close naturally once `currentUserId` becomes
    /// non-nil.
    private var notSignedIn: Binding<Bool> {
        Binding(
            get: { authStore.currentUserId == nil },
            set: { _ in }
        )
    }
}

#Preview {
    // Previews get a fresh, isolated environment (Noop auth +
    // telemetry). Good enough for "does this render at all?";
    // not good enough for wiring tests.
    ContentView(environment: AppEnvironment())
}
