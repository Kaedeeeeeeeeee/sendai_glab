// HUDOverlay.swift
// SDGUI · HUD
//
// Phase 1 main-HUD composition (GDD §1.5, landscape only):
//
//     ┌───────────────────────────────────────────┐
//     │           [status banner, top-center]      │
//     │                                [badge, TR] │
//     │                                            │
//     │          (RealityView lives underneath)    │
//     │                                            │
//     │  [joystick, BL]           [drill, BR]      │
//     └───────────────────────────────────────────┘
//
// The overlay owns **no** logic of its own: it reads the three
// Phase 1 stores, pipes values into presentational sub-views
// (`VirtualJoystickView`, `DrillButton`, `InventoryBadge`), and
// forwards the sub-views' callbacks back out via the parent-
// supplied closures.
//
// Why this split (overlay layout vs. sub-views):
//   * `HUDOverlay` is the "where things live on screen" layer.
//     Swapping to a compact iPhone layout later means editing
//     this file only.
//   * Sub-views are the "how a button looks" layer. They are
//     re-usable (e.g. the drill button may reappear in the
//     tool-wheel in Phase 2) and individually testable.
//
// Everything public that crosses the SwiftUI redraw boundary is
// `@Observable`-backed, so SwiftUI handles diffing automatically.
//
// ## Integration example
//
// Drop this into the SwiftUI tree above (or sibling to) the
// `RealityView`:
//
// ```swift
// @State private var joystickAxis: SIMD2<Float> = .zero
//
// var body: some View {
//     ZStack {
//         RealityView { content in /* ... */ }
//         HUDOverlay(
//             playerStore: playerStore,
//             drillingStore: drillingStore,
//             inventoryStore: inventoryStore,
//             joystickAxis: $joystickAxis,
//             onDrillTapped: {
//                 Task {
//                     await drillingStore.intent(.drillAt(
//                         origin: currentPlayerPosition,
//                         direction: SIMD3<Float>(0, -1, 0),
//                         maxDepth: 10
//                     ))
//                 }
//             },
//             onInventoryTapped: { /* P1-T9 inventory grid */ }
//         )
//     }
// }
// ```
//
// The integration itself is deliberately out of this task's
// scope (GDD Phase 1 split): P1-T8 delivers the overlay and
// sub-views; the RootView rewire lands in a later main-agent
// pass.

import SwiftUI
import SDGCore
import SDGGameplay

/// Full-screen HUD composition for Phase 1.
///
/// Expects an external `RealityView` underneath. Assembles:
///
///   * Bottom-left:   `VirtualJoystickView` writing into
///     `joystickAxis`. Parent is responsible for forwarding
///     `onChange` of that binding into
///     `PlayerControlStore.intent(.move(...))` — we do not do
///     it here because the joystick is already wired in
///     `RootView` today and we want to avoid double-publishes
///     until integration lands.
///   * Bottom-right:  `DrillButton`; tap invokes `onDrillTapped`.
///   * Top-right:     `InventoryBadge`; tap invokes
///     `onInventoryTapped`.
///   * Top-center:    Status banner derived from the
///     `DrillingStore.status` state machine; localized via the
///     `hud.status.*` keys.
///
/// ## Store parameters
///
/// `@Bindable` is applied here (iOS 17+, `Observation` runtime)
/// so SwiftUI observes the three stores directly. The parent
/// passes its long-lived store instances; the HUD never creates
/// them. Each store argument is a distinct responsibility:
///
///   * `playerStore`: held for future HUD features (compass,
///     stamina bar). Not currently read but kept in the init
///     signature so the integration site doesn't churn when we
///     add them.
///   * `drillingStore`: drives the drill-button spinner and the
///     status banner.
///   * `inventoryStore`: drives the sample count in the badge.
public struct HUDOverlay: View {

    // MARK: - Dependencies

    /// Player control Store. Currently unused by the HUD itself
    /// but kept in the public init so adding a compass /
    /// stamina bar later doesn't break existing call sites.
    @Bindable public var playerStore: PlayerControlStore

    /// Drives the drill-button spinner and the status banner.
    @Bindable public var drillingStore: DrillingStore

    /// Source of the sample count shown on the inventory badge.
    @Bindable public var inventoryStore: InventoryStore

    /// Two-way binding to the joystick axis. The parent owns the
    /// value (typically `@State`) and is responsible for
    /// forwarding changes into `PlayerControlStore.intent(.move)`.
    @Binding public var joystickAxis: SIMD2<Float>

    /// Invoked on drill-button tap. Typically wraps an
    /// `await drillingStore.intent(.drillAt(...))` in a `Task`.
    public let onDrillTapped: () -> Void

    /// Invoked on inventory-badge tap. Phase 1: no-op. Phase 2
    /// (P1-T9): push the inventory grid sheet.
    public let onInventoryTapped: () -> Void

    // MARK: - Init

    /// Designated initializer.
    ///
    /// - Parameters:
    ///   - playerStore: Player Store. Reserved for future HUD
    ///     widgets; the current overlay does not read from it.
    ///   - drillingStore: Store whose `status` feeds the drill
    ///     button and the status banner.
    ///   - inventoryStore: Store whose `samples.count` feeds the
    ///     inventory badge.
    ///   - joystickAxis: Binding mirrored to the embedded
    ///     `VirtualJoystickView`. Parent forwards to
    ///     `PlayerControlStore`.
    ///   - onDrillTapped: Closure invoked on drill button tap.
    ///   - onInventoryTapped: Closure invoked on inventory
    ///     badge tap.
    public init(
        playerStore: PlayerControlStore,
        drillingStore: DrillingStore,
        inventoryStore: InventoryStore,
        joystickAxis: Binding<SIMD2<Float>>,
        onDrillTapped: @escaping () -> Void,
        onInventoryTapped: @escaping () -> Void
    ) {
        self.playerStore = playerStore
        self.drillingStore = drillingStore
        self.inventoryStore = inventoryStore
        self._joystickAxis = joystickAxis
        self.onDrillTapped = onDrillTapped
        self.onInventoryTapped = onInventoryTapped
    }

    // MARK: - Body

    public var body: some View {
        ZStack {
            // Each corner is its own VStack/HStack stack so
            // alignments stay readable and the four widgets
            // don't fight over a shared layout container.
            joystickCorner
            drillCorner
            inventoryCorner
            statusBannerArea
        }
    }

    // MARK: - Corners

    /// Bottom-left: 160 pt virtual joystick.
    private var joystickCorner: some View {
        VStack {
            Spacer()
            HStack {
                VirtualJoystickView(output: $joystickAxis)
                    .frame(width: 160, height: 160)
                    .padding(.leading, 40)
                    .padding(.bottom, 40)
                Spacer()
            }
        }
    }

    /// Bottom-right: 80 pt drill action button.
    private var drillCorner: some View {
        VStack {
            Spacer()
            HStack {
                Spacer()
                DrillButton(
                    onTap: onDrillTapped,
                    isDrilling: isDrilling
                )
                .padding(.trailing, 40)
                .padding(.bottom, 40)
            }
        }
    }

    /// Top-right: 60 pt sample-count badge.
    private var inventoryCorner: some View {
        VStack {
            HStack {
                Spacer()
                InventoryBadge(
                    count: inventoryStore.samples.count,
                    onTap: onInventoryTapped
                )
                .padding(.top, 40)
                .padding(.trailing, 40)
            }
            Spacer()
        }
    }

    /// Top-center: transient status banner. Empty string = no
    /// banner (prevents a pill with no content while idle).
    private var statusBannerArea: some View {
        VStack {
            if !statusText.isEmpty {
                statusLabel
                    .padding(.top, 40)
            }
            Spacer()
        }
        // Banner is informational; don't let it steal taps
        // intended for the RealityView underneath.
        .allowsHitTesting(false)
    }

    private var statusLabel: some View {
        Text(statusText)
            .font(.callout)
            .foregroundStyle(.white)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(.black.opacity(0.5), in: .capsule)
    }

    // MARK: - Derived state

    /// `true` while a drill cycle is in-flight. Pulled out so
    /// the switch on `status` lives in one place and the body
    /// stays readable.
    private var isDrilling: Bool {
        if case .drilling = drillingStore.status { return true }
        return false
    }

    /// Localized banner text derived from the current drilling
    /// status. Idle returns `""` so the banner collapses away
    /// entirely (handled in `statusBannerArea`).
    ///
    /// The three visible states use the `hud.status.*` keys in
    /// `Resources/Localization/Localizable.xcstrings`; they are
    /// added in lockstep with this view.
    private var statusText: String {
        switch drillingStore.status {
        case .idle:
            return ""
        case .drilling:
            return String(localized: "hud.status.drilling")
        case .lastCompleted:
            return String(localized: "hud.status.drillSuccess")
        case .lastFailed:
            return String(localized: "hud.status.drillFailed")
        }
    }
}
