// swift-tools-version: 6.0
import PackageDescription

// SDGUI is the only layer allowed to import SwiftUI and RealityKit.
// Depends on SDGCore, SDGGameplay, and SDGPlatform.
//
// The SDGPlatform dependency is needed because gesture capture
// (SwiftUI `DragGesture`) must live in SDGUI, while the domain
// value type `PanEvent` and the `TouchInputService` façade live
// in SDGPlatform (which cannot import SwiftUI/RealityKit). SDGUI
// thus imports SDGPlatform to translate platform input into
// SDGPlatform's domain events; the reverse is never true.
//
// Tools-version rationale: see SDGCore/Package.swift.

let package = Package(
    name: "SDGUI",
    platforms: [
        .iOS(.v18),
        // macOS 15 is required because `PlayerControlSystem` (and any
        // future ECS System wiring) depends on RealityFoundation's
        // iOS 18 / macOS 15 `SceneUpdateContext.entities(matching:)` API.
        // SwiftUI and RealityKit are both available on macOS 14+, but
        // our System features aren't, so we pin to 15 here.
        .macOS(.v15)
    ],
    products: [
        .library(
            name: "SDGUI",
            targets: ["SDGUI"]
        )
    ],
    dependencies: [
        .package(path: "../SDGCore"),
        .package(path: "../SDGGameplay"),
        .package(path: "../SDGPlatform")
    ],
    targets: [
        .target(
            name: "SDGUI",
            dependencies: [
                .product(name: "SDGCore", package: "SDGCore"),
                .product(name: "SDGGameplay", package: "SDGGameplay"),
                .product(name: "SDGPlatform", package: "SDGPlatform")
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
