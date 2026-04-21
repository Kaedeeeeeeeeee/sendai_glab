// SDGCore — foundation layer.
// Keep this file minimal; real types land here in P0-T2 and Phase 1.
// Must not `import SwiftUI` or `import RealityKit` (enforced by convention
// and by the fact that this package does not link them).

/// Version tag so downstream layers can verify they linked against SDGCore.
public enum SDGCoreModule {
    public static let version = "0.0.0"
}
