// SDGUI — the only layer allowed to import SwiftUI / RealityKit.
//
// Public surface:
//   * `RootView`             — Phase 0 app root (RealityView + HUD).
//   * `EnvironmentValues.appEnvironment` — SwiftUI injection key
//     for `SDGCore.AppEnvironment` (defined in AppEnvironmentKey.swift).
//
// Gameplay types and platform services are re-exported from their
// respective packages; SDGUI does not own domain logic.

import SDGCore
import SDGGameplay
import SDGPlatform

/// Module metadata. Bumped manually when the public surface changes;
/// useful for quick "is my build current?" checks during development.
public enum SDGUIModule {
    public static let version = "0.1.0"
}
