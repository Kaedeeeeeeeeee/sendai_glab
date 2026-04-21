import SwiftUI
import SDGCore
import SDGUI

// Thin composition root: take the `AppEnvironment` the App target
// built at launch, inject it into the SwiftUI environment, and
// hand off to `RootView` (which owns the real Phase 0 scene).
//
// Kept deliberately minimal. All rendering and input lives in
// `RootView` (SDGUI); all domain state lives in `AppEnvironment`
// (SDGCore).

struct ContentView: View {

    /// The shared dependency container. Passed in from
    /// `SendaiGLabApp`'s stored property so both App and View
    /// agree on exactly one instance per launch.
    let environment: AppEnvironment

    var body: some View {
        RootView()
            .environment(\.appEnvironment, environment)
    }
}

#Preview {
    // Previews get a fresh, isolated environment. Good enough for
    // "does this render at all?"; not good enough for wiring tests.
    ContentView(environment: AppEnvironment())
}
