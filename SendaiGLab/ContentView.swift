import SwiftUI

// Placeholder root view. Replaced by the real `RealityView`-based HUD in
// P0-T8. Kept deliberately trivial so P0-T1 only verifies the toolchain.

struct ContentView: View {
    var body: some View {
        Text("SDG-Lab — Phase 0")
            .font(.largeTitle)
    }
}

#Preview {
    ContentView()
}
