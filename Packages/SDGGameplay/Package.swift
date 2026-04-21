// swift-tools-version: 6.0
import PackageDescription

// SDGGameplay contains Stores, Events, and ECS systems.
// Depends on SDGCore only. No SwiftUI, no RealityKit-specific views.
// See Docs/ArchitectureDecisions/0001-layered-architecture.md.
// Tools-version rationale: see SDGCore/Package.swift.

let package = Package(
    name: "SDGGameplay",
    platforms: [
        .iOS(.v18),
        // macOS 15 required because `PlayerControlSystem` and any
        // future RealityKit System using
        // `SceneUpdateContext.entities(matching:updatingSystemWhen:)`
        // are iOS 18 / macOS 15 minimum. CI runs macos-15 (see
        // .github/workflows/ci.yml) so `swift test` stays green.
        // Portable business-logic tests still execute because the
        // macOS 15 ceiling only *restricts* what's usable, it does
        // not narrow the host runner.
        .macOS(.v15)
    ],
    products: [
        .library(
            name: "SDGGameplay",
            targets: ["SDGGameplay"]
        )
    ],
    dependencies: [
        .package(path: "../SDGCore")
    ],
    targets: [
        .target(
            name: "SDGGameplay",
            dependencies: [
                .product(name: "SDGCore", package: "SDGCore")
            ],
            swiftSettings: [
                .enableUpcomingFeature("StrictConcurrency")
            ]
        ),
        .testTarget(
            name: "SDGGameplayTests",
            dependencies: ["SDGGameplay"],
            // The Geology tests load `test_outcrop.json` through
            // `Bundle.module`. SPM processes the Resources/ tree
            // relative to the test target root; see
            // Tests/SDGGameplayTests/Resources/.
            resources: [
                .process("Resources")
            ],
            swiftSettings: [
                .enableUpcomingFeature("StrictConcurrency")
            ]
        )
    ],
    swiftLanguageModes: [.v5]
)
