import SwiftUI
import SDGCore
import SDGGameplay
import SDGUI
import SDGPlatform

// Entry point. Builds the single `AppEnvironment` for the process
// lifetime and hands it to the SwiftUI tree via `ContentView`.
//
// Why "one instance, not a singleton": see ADR-0001 §"Dependency
// Injection" and AGENTS.md Rule 2. The same rule lets tests and
// previews construct their own `AppEnvironment` without fighting
// a static.

@main
struct SendaiGLabApp: App {

    /// The app-wide dependency container. Constructed exactly once
    /// when the `App` struct is created by SwiftUI, and passed down
    /// through the environment. Stored as `let` so nothing can swap
    /// it out mid-session.
    let environment = AppEnvironment()

    var body: some Scene {
        WindowGroup {
            ContentView(environment: environment)
        }
    }
}
