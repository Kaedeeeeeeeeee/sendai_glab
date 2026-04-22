// VehicleMeshFactory.swift
// SDGGameplay · Vehicles
//
// Builds placeholder RealityKit entities for vehicles using only
// built-in `MeshResource` primitives. Phase 3 will replace the
// outputs here with Meshy-generated USDZ models; the factory's
// shape (one function per vehicle kind, returns a parented
// `Entity` root with a `VehicleComponent` already attached) stays
// constant so the scene-side code upstream does not change.
//
// ## Why the factory lives in Gameplay, not Platform or UI
//
//   * Gameplay already owns `VehicleComponent`; attaching the
//     component at creation time keeps the mesh + component
//     invariant in one place.
//   * The factory is RealityKit-dependent but not SwiftUI-
//     dependent. `arch_lint.sh` allows RealityKit in SDGGameplay;
//     this stays compliant.
//
// ## Placeholder shapes
//
//   * Drone — a thin square body (0.6 × 0.2 × 0.6 m) in blue, with
//     four small cylinders at the corners as propellers. Total
//     footprint ≈ one kitchen tile.
//
//   * Drill car — a box (2 × 1 × 1 m) in yellow, with four wheel
//     cylinders at the bottom corners. Roughly jeep-sized.
//
// Both are returned pre-registered with `VehicleComponent` so
// `VehicleControlSystem` picks them up from frame 1.

import Foundation
import RealityKit

/// Namespace for vehicle placeholder mesh construction.
///
/// Every function returns a root `Entity` that:
///
///   1. Already has a `VehicleComponent` of the appropriate type
///      attached (default-initialised — `isOccupied = false`,
///      inputs at zero).
///   2. Owns its child meshes as children of the root so moving the
///      root moves everything together.
///
/// Callers are expected to `entity.position = ...` after receipt to
/// place the vehicle in the world. Giving the factory a `position:`
/// parameter would hide the fact that the Store's snapshot and the
/// entity position are separate state; explicit is better here.
public enum VehicleMeshFactory {

    // MARK: - Drone

    /// Build a placeholder drone entity.
    ///
    /// Shape: a thin blue square body with four cylindrical
    /// "propellers" at the corners. The propellers are cosmetic —
    /// Phase 3 can animate them with `Transform` mutation on the
    /// `propellers` named entities.
    ///
    /// - Parameters:
    ///   - color: Body RGB in linear space. Defaults to a lab-blue
    ///     that reads clearly against both sky and outcrop.
    ///   - vehicleId: Optional fixed id. Defaults to a fresh
    ///     `UUID()`; pass an existing id to re-hydrate a saved
    ///     vehicle.
    /// - Returns: A root `Entity` named `"drone"` with a
    ///   `VehicleComponent(.drone, …)` attached.
    @MainActor
    public static func makeDrone(
        color: SIMD3<Float> = SIMD3<Float>(0.2, 0.4, 0.9),
        vehicleId: UUID = UUID()
    ) -> Entity {
        let root = Entity()
        root.name = "drone"
        root.components.set(VehicleComponent(
            vehicleType: .drone,
            vehicleId: vehicleId
        ))

        // Body: a thin square box.
        let body = ModelEntity(
            mesh: .generateBox(size: SIMD3<Float>(0.6, 0.2, 0.6)),
            materials: [unlit(color: color)]
        )
        body.name = "drone.body"
        root.addChild(body)

        // Four propellers — short, wide cylinders at the corners,
        // sitting just above the body. Named so Phase 3 animation
        // code can find them without relying on child order.
        let propRadius: Float = 0.12
        let propHeight: Float = 0.03
        let propOffset: Float = 0.28    // corner offset from centre
        let propY: Float = 0.12         // just above the body top

        let propColor = SIMD3<Float>(0.1, 0.1, 0.1)   // dark grey
        let corners: [(Float, Float, String)] = [
            ( propOffset,  propOffset, "drone.prop.fr"),
            (-propOffset,  propOffset, "drone.prop.fl"),
            ( propOffset, -propOffset, "drone.prop.br"),
            (-propOffset, -propOffset, "drone.prop.bl"),
        ]
        for (x, z, name) in corners {
            let prop = ModelEntity(
                mesh: .generateCylinder(height: propHeight, radius: propRadius),
                materials: [unlit(color: propColor)]
            )
            prop.name = name
            prop.position = SIMD3<Float>(x, propY, z)
            root.addChild(prop)
        }

        return root
    }

    // MARK: - Drill car

    /// Build a placeholder drill car entity.
    ///
    /// Shape: a 2 × 1 × 1 m yellow box with four black wheel
    /// cylinders at the bottom corners, axles aligned on world X
    /// (so the wheels face outward from the sides of the car).
    ///
    /// The body sits so its underside is at the entity's y = 0,
    /// which makes "place at ground level" easy at the call site:
    /// `drillCar.position = SIMD3(x, groundY, z)`.
    ///
    /// - Parameters:
    ///   - color: Body RGB. Defaults to a construction-yellow.
    ///   - vehicleId: Optional fixed id, same rationale as
    ///     `makeDrone`.
    @MainActor
    public static func makeDrillCar(
        color: SIMD3<Float> = SIMD3<Float>(0.9, 0.7, 0.1),
        vehicleId: UUID = UUID()
    ) -> Entity {
        let root = Entity()
        root.name = "drillCar"
        root.components.set(VehicleComponent(
            vehicleType: .drillCar,
            vehicleId: vehicleId
        ))

        // Body: raise the box by half its height so the bottom
        // face sits at local y=0.
        let bodyHeight: Float = 1.0
        let body = ModelEntity(
            mesh: .generateBox(size: SIMD3<Float>(2, bodyHeight, 1)),
            materials: [unlit(color: color)]
        )
        body.name = "drillCar.body"
        body.position = SIMD3<Float>(0, bodyHeight / 2 + 0.3, 0)  // hover on wheels
        root.addChild(body)

        // Four wheels. Orient each cylinder so its axis runs along
        // world X (so they look like wheels from the side). The
        // cylinder default axis is Y, so rotate 90° around Z.
        let wheelRotation = simd_quatf(
            angle: .pi / 2,
            axis: SIMD3<Float>(0, 0, 1)
        )
        let wheelRadius: Float = 0.3
        let wheelHeight: Float = 0.25  // width of the wheel along its axle
        let wheelColor = SIMD3<Float>(0.1, 0.1, 0.1)

        let wheelX: Float = 0.9        // ± offsets in X (car length)
        let wheelZ: Float = 0.5 + wheelHeight / 2    // outside body width
        let wheelY: Float = wheelRadius

        let wheelPlacements: [(Float, Float, String)] = [
            ( wheelX,  wheelZ, "drillCar.wheel.fr"),
            (-wheelX,  wheelZ, "drillCar.wheel.br"),
            ( wheelX, -wheelZ, "drillCar.wheel.fl"),
            (-wheelX, -wheelZ, "drillCar.wheel.bl"),
        ]
        for (x, z, name) in wheelPlacements {
            let wheel = ModelEntity(
                mesh: .generateCylinder(height: wheelHeight, radius: wheelRadius),
                materials: [unlit(color: wheelColor)]
            )
            wheel.name = name
            wheel.position = SIMD3<Float>(x, wheelY, z)
            wheel.orientation = wheelRotation
            root.addChild(wheel)
        }

        return root
    }

    // MARK: - Material helpers

    /// Cheap unlit material in the target colour. Placeholder
    /// vehicles don't need the toon shader — they are visually
    /// distinct enough without shading, and swapping the factory
    /// for Meshy USDZ imports in Phase 3 will bring real materials.
    @MainActor
    private static func unlit(color: SIMD3<Float>) -> UnlitMaterial {
        var material = UnlitMaterial()
        material.color = .init(
            tint: PlatformColor(
                red: CGFloat(color.x),
                green: CGFloat(color.y),
                blue: CGFloat(color.z),
                alpha: 1.0
            )
        )
        return material
    }
}

// MARK: - Platform bridge

// `UIColor` on iOS, `NSColor` on macOS. We bridge through a typealias
// so the factory compiles for both targets (SDGGameplay's
// Package.swift declares iOS 18 and macOS 15).
#if canImport(UIKit)
import UIKit
private typealias PlatformColor = UIColor
#elseif canImport(AppKit)
import AppKit
private typealias PlatformColor = NSColor
#endif
