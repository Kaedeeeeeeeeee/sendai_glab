// swift-tools-version: 6.0
import PackageDescription

// SDGPlatform wraps iOS/iPadOS platform services (persistence, audio, input,
// location). Depends on SDGCore only; parallel to SDGGameplay.
// Tools-version rationale: see SDGCore/Package.swift.

let package = Package(
    name: "SDGPlatform",
    platforms: [
        .iOS(.v18)
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
            swiftSettings: [
                .enableUpcomingFeature("StrictConcurrency")
            ]
        )
    ],
    swiftLanguageModes: [.v5]
)
