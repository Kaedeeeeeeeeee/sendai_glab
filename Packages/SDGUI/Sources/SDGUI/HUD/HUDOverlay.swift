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
import RealityKit
import simd
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

    /// Phase 7: drives the contextual Board / Exit button. The HUD
    /// reads `occupiedVehicleId` and `summonedVehicles` to pick the
    /// button mode; tap handlers forward into the Store through the
    /// caller-supplied closures below.
    @Bindable public var vehicleStore: VehicleStore

    /// Two-way binding to the joystick axis. The parent owns the
    /// value (typically `@State`) and is responsible for
    /// forwarding changes into `PlayerControlStore.intent(.move)`.
    @Binding public var joystickAxis: SIMD2<Float>

    /// Phase 7.1 — vertical stick value for drone climb/descend.
    /// Written by the embedded `VerticalSliderView`; the parent
    /// forwards it into `vehicleStore.intent(.pilot(vertical:))`.
    /// Visible only while a vehicle is occupied; see
    /// `verticalSliderVisible` below.
    @Binding public var verticalSliderValue: Float

    /// Invoked on drill-button tap. Typically wraps an
    /// `await drillingStore.intent(.drillAt(...))` in a `Task`.
    public let onDrillTapped: () -> Void

    /// Invoked on inventory-badge tap. Phase 1: no-op. Phase 2
    /// (P1-T9): push the inventory grid sheet.
    public let onInventoryTapped: () -> Void

    /// Phase 7: Board button tapped. Parent receives the vehicle id
    /// whose snapshot is nearest the player (within 3 m) and is
    /// expected to `await vehicleStore.intent(.enter(vehicleId:))`.
    /// Invoked only when the button is in `.boardAvailable` mode.
    public let onBoardTapped: (UUID) -> Void

    /// Phase 7: Exit button tapped. Invoked only when the button is
    /// in `.exitAvailable` mode. Parent dispatches
    /// `await vehicleStore.intent(.exit)`.
    public let onExitVehicleTapped: () -> Void

    /// Live world-space position of the player body. Updated by the
    /// parent (RootView) via a low-frequency poll — SwiftUI redraws
    /// the HUD only when this value crosses the 3 m proximity
    /// threshold into / out of a vehicle radius, so a 100 ms tick
    /// is plenty (the button doesn't need per-frame precision).
    public let playerWorldPosition: SIMD3<Float>

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
        vehicleStore: VehicleStore,
        joystickAxis: Binding<SIMD2<Float>>,
        verticalSliderValue: Binding<Float>,
        playerWorldPosition: SIMD3<Float>,
        onDrillTapped: @escaping () -> Void,
        onInventoryTapped: @escaping () -> Void,
        onBoardTapped: @escaping (UUID) -> Void,
        onExitVehicleTapped: @escaping () -> Void
    ) {
        self.playerStore = playerStore
        self.drillingStore = drillingStore
        self.inventoryStore = inventoryStore
        self.vehicleStore = vehicleStore
        self._joystickAxis = joystickAxis
        self._verticalSliderValue = verticalSliderValue
        self.playerWorldPosition = playerWorldPosition
        self.onDrillTapped = onDrillTapped
        self.onInventoryTapped = onInventoryTapped
        self.onBoardTapped = onBoardTapped
        self.onExitVehicleTapped = onExitVehicleTapped
    }

    /// Phase 7 backward-compat init — kept so the pre-7.1 RootView
    /// call sites continue to compile while the Phase 9 D integration
    /// note threads the new `verticalSliderValue` binding through. The
    /// omitted binding defaults to a constant-zero so the slider
    /// renders as hidden (`verticalSliderVisible` still gates
    /// visibility on `occupiedVehicleId`, so the only effect is that
    /// the drone cannot climb/descend until the parent actually
    /// wires a real binding).
    ///
    /// Delete this convenience init once every integration site has
    /// been updated — retaining two overloads indefinitely would
    /// invite new callers to skip the slider entirely.
    public init(
        playerStore: PlayerControlStore,
        drillingStore: DrillingStore,
        inventoryStore: InventoryStore,
        vehicleStore: VehicleStore,
        joystickAxis: Binding<SIMD2<Float>>,
        playerWorldPosition: SIMD3<Float>,
        onDrillTapped: @escaping () -> Void,
        onInventoryTapped: @escaping () -> Void,
        onBoardTapped: @escaping (UUID) -> Void,
        onExitVehicleTapped: @escaping () -> Void
    ) {
        self.init(
            playerStore: playerStore,
            drillingStore: drillingStore,
            inventoryStore: inventoryStore,
            vehicleStore: vehicleStore,
            joystickAxis: joystickAxis,
            verticalSliderValue: .constant(0),
            playerWorldPosition: playerWorldPosition,
            onDrillTapped: onDrillTapped,
            onInventoryTapped: onInventoryTapped,
            onBoardTapped: onBoardTapped,
            onExitVehicleTapped: onExitVehicleTapped
        )
    }

    // MARK: - Body

    public var body: some View {
        ZStack {
            // Each corner is its own VStack/HStack stack so
            // alignments stay readable and the four widgets
            // don't fight over a shared layout container.
            joystickCorner
            verticalSliderColumn
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

    /// Bottom-right: 80 pt drill action button, with the Phase 7
    /// BoardButton stacked above it when a vehicle is in reach
    /// (or when the player is already piloting one).
    private var drillCorner: some View {
        VStack {
            Spacer()
            HStack {
                Spacer()
                VStack(spacing: 16) {
                    BoardButton(
                        mode: boardButtonMode,
                        onTap: handleBoardOrExitTapped
                    )
                    DrillButton(
                        onTap: onDrillTapped,
                        isDrilling: isDrilling
                    )
                }
                .padding(.trailing, 40)
                .padding(.bottom, 40)
            }
        }
    }

    /// Right-edge, mid-height: 80×200 pt vertical climb stick. Sits
    /// just left of the DrillButton / BoardButton column so the
    /// pilot's thumb moves naturally between planar (left-bottom
    /// joystick) and vertical (right-mid slider) inputs. Visible
    /// only while a vehicle is occupied; otherwise the embedded
    /// `VerticalSliderView` collapses to `EmptyView()` and takes
    /// no layout space.
    private var verticalSliderColumn: some View {
        HStack {
            Spacer()
            VerticalSliderView(
                output: $verticalSliderValue,
                isVisible: verticalSliderVisible
            )
            .frame(
                width: verticalSliderVisible ? 80 : 0,
                height: verticalSliderVisible ? 200 : 0
            )
            .padding(.trailing, 140) // clear of the Drill/Board column
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

    /// Board-proximity threshold. 3 m matches the "standing next
    /// to your vehicle" feel — close enough that the player
    /// clearly walked up to it, far enough that they don't have
    /// to clip into the mesh. Tuning knob; raise if the button
    /// pops on/off too aggressively.
    private static let boardProximityMeters: Float = 3.0

    /// Phase 7.1 — show the vertical slider only while the player
    /// pilots a vehicle. On foot, the slider would be a hanging UI
    /// element with no effect (the Store ignores `.pilot` when
    /// `occupiedVehicleId == nil`), so we hide it entirely. Reading
    /// from the Store keeps the visibility source-of-truth in one
    /// place — parents don't need to thread a separate flag.
    private var verticalSliderVisible: Bool {
        vehicleStore.occupiedVehicleId != nil
    }

    /// Resolve what the BoardButton should render. Order of checks
    /// matters:
    /// 1. If the player is piloting → `.exitAvailable` always wins;
    /// 2. Else if any summoned vehicle is within range → `.boardAvailable`;
    /// 3. Else → `.hidden`.
    ///
    /// Proximity is measured on the live entity world position when
    /// the scene has registered one (vehicles move during flight),
    /// falling back to the summon snapshot otherwise.
    private var boardButtonMode: BoardButtonMode {
        if vehicleStore.occupiedVehicleId != nil {
            return .exitAvailable
        }
        let threshold = Self.boardProximityMeters
        for snapshot in vehicleStore.summonedVehicles {
            let livePosition = vehicleStore.entity(for: snapshot.id)?
                .position(relativeTo: nil) ?? snapshot.position
            let delta = livePosition - playerWorldPosition
            if simd_length(delta) <= threshold {
                return .boardAvailable
            }
        }
        return .hidden
    }

    /// Route the BoardButton's single `onTap` into the two callback
    /// slots on the HUD, based on the current mode. Keeping this in
    /// one place avoids asking the sub-view to carry two closures.
    private func handleBoardOrExitTapped() {
        switch boardButtonMode {
        case .boardAvailable:
            // Pick the nearest summoned vehicle; same live-position
            // resolution as `boardButtonMode` so the button and the
            // action can't disagree on "which vehicle is nearest".
            var best: (id: UUID, distance: Float)?
            for snapshot in vehicleStore.summonedVehicles {
                let livePosition = vehicleStore.entity(for: snapshot.id)?
                    .position(relativeTo: nil) ?? snapshot.position
                let distance = simd_length(livePosition - playerWorldPosition)
                if best == nil || distance < best!.distance {
                    best = (snapshot.id, distance)
                }
            }
            if let winner = best {
                onBoardTapped(winner.id)
            }
        case .exitAvailable:
            onExitVehicleTapped()
        case .hidden:
            break
        }
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
