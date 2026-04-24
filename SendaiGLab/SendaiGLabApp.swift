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
    /// when the `App` struct is created by SwiftUI. Holds the shared
    /// `EventBus`, localization, and (Phase 10) the real Supabase
    /// `AuthService` + `TelemetryService`.
    let environment: AppEnvironment

    /// Scene-phase observer publishes `AppSessionStarted` on every
    /// transition into `.active`, covering both cold launch
    /// (`.background → .inactive → .active`) and foreground-from-
    /// background. The `SessionLogBridge` in Gameplay translates the
    /// event into a `public.sessions` INSERT, iff a user is signed in.
    @Environment(\.scenePhase) private var scenePhase

    init() {
        // MARK: - Audio session
        //
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

        // MARK: - Supabase (Phase 10 POC)
        //
        // Load the plist, build the client, wrap it in our two
        // facades. A single shared `SupabaseClient` is intentional —
        // `TelemetryService` needs to inherit the access token that
        // `AuthService` just obtained so RLS (`auth.uid() = user_id`)
        // passes on the INSERT.
        //
        // Debug-crash on missing plist: forgetting to copy
        // `SupabaseConfig.plist.example` is the #1 first-run mistake
        // and should surface loudly, not silently-disable-auth.
        let config = SupabaseConfig.loadOrCrash()
        let authService = AuthService(config: config)
        let telemetry = TelemetryService(client: authService.sharedClient)

        self.environment = AppEnvironment(
            authService: authService,
            telemetry: telemetry
        )
    }

    var body: some Scene {
        WindowGroup {
            ContentView(environment: environment)
                .onChange(of: scenePhase) { _, new in
                    guard new == .active else { return }
                    // Capture the event payload now — handlers may
                    // run on a different actor later.
                    let event = AppSessionStarted(
                        at: Date(),
                        osVersion: Self.currentOSVersion(),
                        locale: Locale.current.identifier
                    )
                    let bus = environment.eventBus
                    Task { await bus.publish(event) }
                }
        }
    }

    /// iPadOS version string (e.g. `"18.3"`). Uses `ProcessInfo` so
    /// the helper doesn't force a `UIKit` import at the App level.
    private static func currentOSVersion() -> String {
        let v = ProcessInfo.processInfo.operatingSystemVersion
        return "\(v.majorVersion).\(v.minorVersion).\(v.patchVersion)"
    }
}
