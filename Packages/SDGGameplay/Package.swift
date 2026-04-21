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
        // macOS(.v14) matches SDGCore so `swift test` can run on CI's macOS
        // runner (tests the portable business logic without a simulator).
        // This does not affect iOS runtime behavior.
        .macOS(.v14)
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
            swiftSettings: [
                .enableUpcomingFeature("StrictConcurrency")
            ]
        )
    ],
    swiftLanguageModes: [.v5]
)
