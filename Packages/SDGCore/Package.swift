// swift-tools-version: 6.0
import PackageDescription

// SDGCore is the foundation layer. It must remain framework-agnostic
// (no SwiftUI, no RealityKit) so that game logic is testable on macOS CLI.
// See Docs/ArchitectureDecisions/0001-layered-architecture.md.
//
// Note on tools-version: we need `.iOS(.v18)` which requires
// PackageDescription 6.0+. The Swift *language* mode is kept at 5 via
// swiftLanguageModes to match the GDD (§2.1, Swift 5.10+). Strict
// concurrency is opted into via the upcoming-feature flag so that when
// we migrate to Swift 6 language mode the behavior is unchanged.

let package = Package(
    name: "SDGCore",
    platforms: [
        .iOS(.v18),
        // macOS target enables `swift test` on the CLI without an iOS
        // simulator. Kept in lockstep with iOS feature availability.
        .macOS(.v14)
    ],
    products: [
        .library(
            name: "SDGCore",
            targets: ["SDGCore"]
        )
    ],
    targets: [
        .target(
            name: "SDGCore",
            swiftSettings: [
                .enableUpcomingFeature("StrictConcurrency")
            ]
        ),
        .testTarget(
            name: "SDGCoreTests",
            dependencies: ["SDGCore"],
            swiftSettings: [
                .enableUpcomingFeature("StrictConcurrency")
            ]
        )
    ],
    swiftLanguageModes: [.v5]
)
