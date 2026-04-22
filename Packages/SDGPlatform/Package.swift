// swift-tools-version: 6.0
import PackageDescription

// SDGPlatform wraps iOS/iPadOS platform services (persistence, audio, input,
// location). Depends on SDGCore only; parallel to SDGGameplay.
// Tools-version rationale: see SDGCore/Package.swift.

let package = Package(
    name: "SDGPlatform",
    platforms: [
        .iOS(.v18),
        // Match SDGCore so package graph resolves.
        .macOS(.v14)
    ],
    products: [
        .library(
            name: "SDGPlatform",
            targets: ["SDGPlatform"]
        )
    ],
    dependencies: [
        .package(path: "../SDGCore")
    ],
    targets: [
        .target(
            name: "SDGPlatform",
            dependencies: [
                .product(name: "SDGCore", package: "SDGCore")
            ],
            swiftSettings: [
                .enableUpcomingFeature("StrictConcurrency")
            ]
        ),
        .testTarget(
            name: "SDGPlatformTests",
            dependencies: ["SDGPlatform"],
            resources: [
                // Test fixtures for AudioService integration: verifies
                // that `.m4a` (AAC) assets we actually ship are loadable
                // through `AVAudioPlayer` — the Phase 2 regression where
                // all OGG files silently failed would have been caught
                // by this.
                .copy("Fixtures")
            ],
            swiftSettings: [
                .enableUpcomingFeature("StrictConcurrency")
            ]
        )
    ],
    swiftLanguageModes: [.v5]
)
