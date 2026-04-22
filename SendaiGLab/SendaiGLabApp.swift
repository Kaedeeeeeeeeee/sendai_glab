import SwiftUI
import AVFoundation
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

    init() {
        // Configure AVAudioSession once at app launch.
        //
        // Category: `.playback`, not `.ambient`.
        //
        // - `.ambient` respects the device's Silent switch / Control
        //   Center mute. A muted iPad therefore silenced every SFX,
        //   which is exactly what Phase 2 Alpha/Beta playtests hit.
        //   Reference: Apple's "AVAudioSession.Category.ambient" docs
        //   explicitly note "audio is silenced by the Silent switch."
        // - `.playback` is Apple's recommended category for games/media
        //   whose audio is primary content. It plays regardless of the
        //   mute state. Combined with `.mixWithOthers`, we still let
        //   the user's background Spotify / Apple Music keep playing.
        //
        // Failure here is non-fatal — if audio session setup throws on
        // some obscure device the app still runs, just silently.
        do {
            try AVAudioSession.sharedInstance().setCategory(
                .playback,
                mode: .default,
                options: [.mixWithOthers]
            )
            try AVAudioSession.sharedInstance().setActive(true)
            print("[SDG-Lab][audio] AVAudioSession activated (.playback + .mixWithOthers)")
        } catch {
            print("[SDG-Lab][audio] AVAudioSession setup failed: \(error)")
        }
    }

    var body: some Scene {
        WindowGroup {
            ContentView(environment: environment)
        }
    }
}
