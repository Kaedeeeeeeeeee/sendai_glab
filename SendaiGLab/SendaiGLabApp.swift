import SwiftUI
import SDGCore
import SDGGameplay
import SDGUI
import SDGPlatform

// Entry point. The real `AppEnvironment` (wiring EventBus, Stores, platform
// services) will be constructed here in P0-T2. For now the app boots into
// a placeholder view so we can verify the four-package scaffold builds.

@main
struct SendaiGLabApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}
