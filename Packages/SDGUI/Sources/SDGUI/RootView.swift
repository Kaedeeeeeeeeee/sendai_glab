// RootView.swift
// SDGUI
//
// Phase 1 root view: capsule-as-player driven by the virtual joystick
// (left-bottom) and look-drag on the right half of the screen. All
// state mutations go through `PlayerControlStore` (ADR-0001); the
// view never writes to Entity properties directly.
//
// Scene layout:
//   * Green ground plane at y=0 (10 × 10 m).
//   * Blue "capsule" (rounded box) standing on the ground at origin,
//     tagged with `PlayerComponent` + `PlayerInputComponent`. The
//     player entity owns yaw; pitch lives on the camera child.
//   * `PerspectiveCamera` parented to the capsule, offset 1.5 m up
//     (head height) so first-person navigation follows the player
//     rig without any per-frame camera-tracking code — the System
//     only rotates entities that it owns.

import SwiftUI
import RealityKit
import SDGCore
import SDGGameplay
import SDGPlatform

/// Phase 1 root view.
///
/// Wires up the HUD virtual joystick, right-half pan look, and the
/// ECS player rig. Everything non-trivial it knows about the world is
/// reached through `AppEnvironment` (the Store + EventBus); nothing
/// in this view is a singleton.
///
/// Availability: SDGUI's package manifest pins iOS 18 / macOS 15 as
/// minimums, so no explicit `@available` marker is needed on the
/// public API — the package floor already covers
/// `SceneUpdateContext.entities(matching:)` and the modern RealityKit
/// `System` surface this view depends on transitively.
public struct RootView: View {

    /// Shared dependency container (event bus, localization). Injected
    /// by the App target via `.environment(\.appEnvironment, …)`.
    @Environment(\.appEnvironment) private var env: AppEnvironment

    /// Player control Store for the lifetime of this view. Held as
    /// `@State` so SwiftUI owns exactly one instance across redraws.
    /// Intentionally constructed in `init` (via the initializer
    /// default) so `SendaiGLabApp` can later inject a shared one if it
    /// ever needs to.
    @State private var playerStore: PlayerControlStore

    /// Latest joystick output. Mirrored into the Store via `.onChange`.
    /// Kept local so the joystick view doesn't have to know about
    /// Stores at all.
    @State private var joystickAxis: SIMD2<Float> = .zero

    /// Last look-drag translation so we can post frame-to-frame
    /// deltas instead of a growing absolute. Reset on gesture end.
    @State private var lastLookTranslation: CGSize = .zero

    /// Sensitivity: screen-space points per radian of look. 1000 pt
    /// ≈ full device width on iPad landscape; a 1000-pt drag rotating
    /// by 1 radian (≈57°) feels roughly right on first play.
    private let lookSensitivity: Float = 1.0 / 1000.0

    /// Retained across view updates so we can tear the debug
    /// subscription down in `.onDisappear`.
    @State private var debugSubscription: SubscriptionToken?

    /// Default public initializer. Allocates a fresh Store pre-bound
    /// to a placeholder bus; `.task` re-binds it to the real env bus
    /// on first appearance.
    public init() {
        // SwiftUI runs `init` before `@Environment` is readable, so we
        // seed the Store with an empty bus here and swap it for the
        // real one in `.task`. The cost of the placeholder is a fresh
        // actor with no subscribers — negligible.
        _playerStore = State(initialValue: PlayerControlStore(eventBus: EventBus()))
    }

    public var body: some View {
        ZStack {
            realityContent
            joystickOverlay
            hudOverlay
        }
        .ignoresSafeArea()
        .task {
            // Swap the placeholder Store for one bound to the real bus.
            // Safe to replace: this runs once per view lifetime before
            // any user input fires.
            playerStore = PlayerControlStore(eventBus: env.eventBus)

            if debugSubscription == nil {
                debugSubscription = await env.eventBus.subscribe(PlayerMoveIntentChanged.self) { event in
                    // Log only. Real handlers (HUD compass, analytics)
                    // subscribe here in later phases.
                    print("player move axis=\(event.axis.x),\(event.axis.y)")
                }
            }
        }
        .onDisappear {
            if let token = debugSubscription {
                let bus = env.eventBus
                Task { await bus.cancel(token) }
                debugSubscription = nil
            }
            playerStore.detach()
        }
        .onChange(of: joystickAxis) { _, new in
            // Every joystick update becomes a .move intent. The Store
            // de-duplicates identical values, so idle ticks are cheap.
            let store = playerStore
            Task { @MainActor in
                await store.intent(.move(new))
            }
        }
    }

    // MARK: - RealityView

    /// The 3D scene. Registers the player System the first time the
    /// view builds its content, then assembles a ground + capsule +
    /// head-height camera rig and attaches the Store to the capsule.
    private var realityContent: some View {
        RealityView { content in
            registerSystemsIfNeeded()

            // Ground plane: 10 × 10 m, matte green. Keeps the POC
            // visually readable without needing real textures.
            let ground = ModelEntity(
                mesh: .generatePlane(width: 10, depth: 10),
                materials: [SimpleMaterial(
                    color: .systemGreen,
                    roughness: 0.8,
                    isMetallic: false
                )]
            )
            content.add(ground)

            // Player "body" — rounded box standing in for a capsule
            // (RealityKit on iOS 18 still has no built-in capsule
            // mesh generator). Sized roughly humanoid.
            let body = ModelEntity(
                mesh: .generateBox(
                    size: SIMD3<Float>(0.5, 1.5, 0.5),
                    cornerRadius: 0.25
                ),
                materials: [SimpleMaterial(
                    color: .systemBlue,
                    roughness: 0.4,
                    isMetallic: false
                )]
            )
            body.position = SIMD3<Float>(0, 0.75, 0)

            // Tag as player + input-consumer so the System picks it up.
            body.components.set(PlayerComponent())
            body.components.set(PlayerInputComponent())

            // Head-height camera parented to the body. Because it is
            // a child, it inherits the body's yaw automatically; the
            // System only has to apply pitch here.
            let camera = PerspectiveCamera()
            camera.position = SIMD3<Float>(0, 1.5, 0)
            body.addChild(camera)

            content.add(body)

            // Give the Store a handle to the entity so intents land.
            // Must happen *after* `content.add(body)` so the entity is
            // live in the scene.
            playerStore.attach(playerEntity: body)
        }
        // Right-half-screen look pan. The left half is reserved for
        // the joystick, which sits in its own gesture scope on top of
        // this one.
        .gesture(lookGesture)
    }

    // MARK: - Overlays

    /// Joystick pinned to the lower-left corner. 40-pt inset on both
    /// edges matches the GDD §1.5 HUD layout.
    private var joystickOverlay: some View {
        VStack {
            Spacer()
            HStack {
                VirtualJoystickView(output: $joystickAxis)
                    .padding(.leading, 40)
                    .padding(.bottom, 40)
                Spacer()
            }
        }
    }

    /// Non-interactive watermark (Phase 0 holdover). Not localised
    /// yet — Phase 1 diagnostic only; routes through the string
    /// catalog later.
    private var hudOverlay: some View {
        VStack {
            Text("SDG-Lab — Phase 1 POC")
                .font(.largeTitle)
                .foregroundStyle(.white)
                .padding(.horizontal, 24)
                .padding(.vertical, 12)
                .background(.black.opacity(0.6), in: .capsule)
                .padding(.top, 40)
            Spacer()
        }
        .allowsHitTesting(false)
    }

    // MARK: - Look gesture

    /// Right-half-screen `DragGesture`: translates raw point deltas
    /// into radian look-intents and forwards them to the Store.
    ///
    /// The "only respond on the right half" policy is implemented by
    /// inspecting `value.startLocation` against the current view
    /// geometry. Using a `GeometryReader` would also work but would
    /// force a layout recalculation on every drag sample, so we
    /// instead use SwiftUI's knowledge that `.gesture` on a view
    /// observes the view's own bounds.
    private var lookGesture: some Gesture {
        DragGesture(minimumDistance: 2, coordinateSpace: .global)
            .onChanged { value in
                // Ignore drags that began on the left half — those
                // belong to the joystick. We use the global start
                // location and a static reference (half the main
                // screen width) because the RealityView is full-screen.
                let halfWidth = RootView.currentScreenWidth / 2
                guard value.startLocation.x >= halfWidth else { return }

                // Frame-to-frame delta: subtract the previous
                // translation, store the new baseline.
                let dx = value.translation.width - lastLookTranslation.width
                let dy = value.translation.height - lastLookTranslation.height
                lastLookTranslation = value.translation

                // Convert points → radians and invert pitch so dragging
                // UP looks UP (screen y is positive downward).
                let yaw = Float(dx) * lookSensitivity
                let pitch = Float(-dy) * lookSensitivity

                let store = playerStore
                let bus = env.eventBus
                Task { @MainActor in
                    await store.intent(.look(SIMD2(yaw, pitch)))
                }
                // Also publish the raw event for subscribers that want
                // a platform-level hook (e.g. replay recorder).
                Task { await bus.publish(LookPanEvent(dx: Double(dx), dy: Double(dy))) }
            }
            .onEnded { _ in
                lastLookTranslation = .zero
            }
    }

    // MARK: - System registration

    /// Register ECS Systems exactly once per process. RealityKit's
    /// `registerSystem()` is idempotent in practice but does log a
    /// warning on double-registration, so we gate it with a flag.
    private func registerSystemsIfNeeded() {
        Self.registerSystemsOnce()
    }

    /// Global once-flag. File-private static; value never read by
    /// any other module. We use a plain `Bool` protected by the fact
    /// that view `make` closures run on MainActor.
    @MainActor private static var systemsRegistered = false

    @MainActor
    private static func registerSystemsOnce() {
        guard !systemsRegistered else { return }
        PlayerComponent.registerComponent()
        PlayerInputComponent.registerComponent()
        PlayerControlSystem.registerSystem()
        systemsRegistered = true
    }

    // MARK: - Screen width helper

    /// Cached screen width for left/right split logic. Updated from
    /// the main screen on each access so orientation changes or Split
    /// View resizes are picked up; the value is cheap to read.
    ///
    /// Pulled out as a static so the body stays easy to read and the
    /// compiler doesn't rebuild a `GeometryReader` on every drag.
    @MainActor
    private static var currentScreenWidth: CGFloat {
        #if canImport(UIKit)
        if let scene = UIApplication.shared.connectedScenes
            .compactMap({ $0 as? UIWindowScene })
            .first,
           let window = scene.windows.first {
            return window.bounds.width
        }
        // Fallback: iPad Pro 13" landscape.
        return 1366
        #else
        return 1366
        #endif
    }
}
