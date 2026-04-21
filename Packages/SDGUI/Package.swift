// swift-tools-version: 6.0
import PackageDescription

// SDGUI is the only layer allowed to import SwiftUI and RealityKit.
// Depends on SDGGameplay (which re-exports nothing of UI) and SDGCore.
// Tools-version rationale: see SDGCore/Package.swift.

let package = Package(
    name: "SDGUI",
    platforms: [
        .iOS(.v18)
    ],
    products: [
        .library(
            name: "SDGUI",
            targets: ["SDGUI"]
        )
    ],
    dependencies: [
        .package(path: "../SDGCore"),
        .package(path: "../SDGGameplay")
    ],
    targets: [
        .target(
            name: "SDGUI",
            dependencies: [
                .product(name: "SDGCore", package: "SDGCore"),
                .product(name: "SDGGameplay", package: "SDGGameplay")
            ],
            swiftSettings: [
                .enableUpcomingFeature("StrictConcurrency")
            ]
        ),
        .testTarget(
            name: "SDGUITests",
            dependencies: ["SDGUI"],
            swiftSettings: [
                .enableUpcomingFeature("StrictConcurrency")
            ]
        )
    ],
    swiftLanguageModes: [.v5]
)
