// RootView.swift
// SDGUI
//
// The app's root SwiftUI view for Phase 0. Composes a minimal
// 3D scene (green ground plane + blue capsule-like prop) with a
// HUD text overlay, and forwards `DragGesture` translations to
// SDGPlatform's `TouchInputService` so the event bus wiring can
// be observed end-to-end in the console.
//
// The scene is intentionally bare. Real gameplay content, the
// Toon shader, and ECS Systems arrive in Phase 1. This file's
// job is just to prove the plumbing — AppEnvironment injection,
// RealityView rendering, and input → bus → subscriber — works.

import SwiftUI
import RealityKit
import SDGCore
import SDGPlatform

/// Phase 0 root view.
///
/// Call-site is `ContentView`, which wraps this in
/// `.environment(\.appEnvironment, …)` to inject the shared
/// dependency container.
///
/// - Important: The `init()` is public but takes no arguments:
///   `RootView` is pure; all state comes from `@Environment`.
public struct RootView: View {

    /// Shared dependency container (event bus, localization …).
    /// Injected via `AppEnvironmentKey`. If the App target forgot
    /// to inject one, the key's `defaultValue` keeps the view
    /// renderable (useful for Previews).
    @Environment(\.appEnvironment) private var env: AppEnvironment

    /// Retained across view updates so we can tear the debug
    /// subscription down in `.onDisappear`. Storing an optional
    /// lets us distinguish "not yet subscribed" from "already
    /// cancelled".
    @State private var debugSubscription: SubscriptionToken?

    /// Default public initializer — the view has no tunable
    /// parameters in Phase 0.
    public init() {}

    public var body: some View {
        ZStack {
            realityContent
            overlay
        }
        .ignoresSafeArea()
        .task {
            // Subscribe *once* when the view first appears. We
            // can't do this in `init()` because the environment
            // isn't readable there, and we can't do it in `body`
            // because that re-runs on every state change. `.task`
            // runs exactly once per lifetime of the view.
            if debugSubscription == nil {
                debugSubscription = await env.eventBus.subscribe(PanEvent.self) { event in
                    // Console-log only. No UI side-effects: Phase 0
                    // just needs to prove events flow through.
                    print("pan dx=\(event.dx) dy=\(event.dy)")
                }
            }
        }
        .onDisappear {
            // Release the subscription. Cancellation is async on
            // an actor; kick it off in a detached Task. Capture
            // the token value (not `self`) so the closure stays
            // Sendable.
            if let token = debugSubscription {
                let bus = env.eventBus
                Task { await bus.cancel(token) }
                debugSubscription = nil
            }
        }
    }

    // MARK: - Subviews

    /// The 3D scene: green ground plane + blue prop + camera.
    ///
    /// `DragGesture` is attached here (not on the overlay) so
    /// drags that start on empty space still register. The
    /// gesture callback pushes samples through `TouchInputService`
    /// onto the shared `EventBus`; the `.task` above subscribes
    /// and logs them.
    private var realityContent: some View {
        // Snapshot the bus before building the gesture so the
        // closure doesn't need to close over `self`. `EventBus`
        // is an actor reference, cheap and Sendable.
        let input = TouchInputService(eventBus: env.eventBus)

        return RealityView { content in
            // Ground plane: 10 m × 10 m, green, non-metallic. The
            // plane is a horizontal surface (XZ plane) so the prop
            // visually "stands on" it when placed at y > 0.
            let groundMesh = MeshResource.generatePlane(width: 10, depth: 10)
            let groundMaterial = SimpleMaterial(color: .systemGreen,
                                                roughness: 0.8,
                                                isMetallic: false)
            let ground = ModelEntity(mesh: groundMesh,
                                     materials: [groundMaterial])
            content.add(ground)

            // "Capsule" stand-in: a tall rounded box. RealityKit
            // ships no `MeshResource.generateCapsule` on iOS 18
            // (only a `ShapeResource` for physics), so we fake the
            // silhouette with `generateBox(cornerRadius:)`. Sized
            // roughly humanoid: 0.5 m wide, 1.5 m tall.
            let bodyMesh = MeshResource.generateBox(
                size: SIMD3<Float>(0.5, 1.5, 0.5),
                cornerRadius: 0.25
            )
            let bodyMaterial = SimpleMaterial(color: .systemBlue,
                                              roughness: 0.4,
                                              isMetallic: false)
            let prop = ModelEntity(mesh: bodyMesh,
                                   materials: [bodyMaterial])
            // Lift so the prop's bottom sits on y=0 (mesh is
            // centred on its origin).
            prop.position = SIMD3<Float>(0, 0.75, 0)
            content.add(prop)

            // Camera pulled back and up, aimed at the origin so
            // the ground and prop are both framed.
            let camera = PerspectiveCamera()
            camera.position = SIMD3<Float>(0, 1.8, 4)
            camera.look(at: SIMD3<Float>(0, 0.75, 0),
                        from: camera.position,
                        relativeTo: nil)
            content.add(camera)
        }
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { value in
                    // Hop onto a Task so we can call the actor
                    // without blocking the gesture recogniser.
                    let pan = PanEvent(
                        dx: Double(value.translation.width),
                        dy: Double(value.translation.height)
                    )
                    Task { await input.publish(pan: pan) }
                }
        )
    }

    /// HUD overlay — a single watermark so launch is visually
    /// confirmable even on the simulator.
    ///
    /// Not localised yet (AGENTS.md §5): Phase 0 diagnostic text
    /// only. Once we wire `LocalizationService` into views, this
    /// string moves into the string catalog.
    private var overlay: some View {
        VStack {
            Text("SDG-Lab — Phase 0")
                .font(.largeTitle)
                .foregroundStyle(.white)
                .padding(.horizontal, 24)
                .padding(.vertical, 12)
                .background(.black.opacity(0.6), in: .capsule)
                .padding(.top, 40)
            Spacer()
        }
        // Let taps fall through to the RealityView's drag
        // gesture. Without this, the VStack's hit-testing would
        // swallow drags that start over the watermark.
        .allowsHitTesting(false)
    }
}
