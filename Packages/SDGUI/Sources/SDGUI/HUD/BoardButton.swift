// BoardButton.swift
// SDGUI · HUD
//
// Phase 7 board / disembark action button. Appears bottom-right,
// just above the DrillButton. Contextual:
//
//   * hidden when no vehicle is nearby (< 3 m) and the player is
//     on foot,
//   * shows "⬆️" + "Board" when a vehicle is in range and the
//     player is on foot,
//   * shows "⬇️" + "Exit" when the player is currently piloting
//     a vehicle.
//
// Purely presentational: the button does not know about
// `VehicleStore`. The caller derives the `mode` from
// `(vehicleStore.occupiedVehicleId, nearestVehicleDistance)` and
// wires `onTap` to the appropriate intent.
//
// Style and size match DrillButton (80×80 pt circle) so the two
// buttons read as a vertically-stacked action pair. Placement is
// handled by the containing `HUDOverlay`.

import SwiftUI

/// Mode the board button renders in. Parent computes this from
/// the VehicleStore state and player proximity; the button itself
/// stays stateless.
public enum BoardButtonMode: Sendable, Equatable {

    /// Nothing to show. Button is hidden entirely so the bottom-
    /// right corner stays clean while the player is on foot away
    /// from vehicles.
    case hidden

    /// Player is near an unoccupied vehicle; tap enters it.
    case boardAvailable

    /// Player is currently piloting a vehicle; tap disembarks.
    case exitAvailable
}

/// Circular "board a vehicle" / "exit vehicle" action button for
/// the main HUD. 80×80 pt, colour- and icon-keyed to the mode.
public struct BoardButton: View {

    /// What the button should render. `.hidden` collapses the
    /// button's frame to zero so it doesn't consume layout space.
    public let mode: BoardButtonMode

    /// Touch-up handler. Runs on the main actor. Parent typically
    /// wraps this in a `Task { await vehicleStore.intent(.enter…) }`
    /// or `.exit`.
    public let onTap: () -> Void

    public init(mode: BoardButtonMode, onTap: @escaping () -> Void) {
        self.mode = mode
        self.onTap = onTap
    }

    public var body: some View {
        switch mode {
        case .hidden:
            // Rendering `EmptyView()` instead of a zero-frame circle
            // so the parent VStack doesn't reserve 80 pt of empty
            // space for the button while it isn't relevant.
            EmptyView()

        case .boardAvailable:
            Button(action: onTap) {
                ZStack {
                    Circle().fill(Color.green)
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.title2)
                        .foregroundStyle(.white)
                }
                .frame(width: 80, height: 80)
            }
            .accessibilityLabel("hud.button.board")

        case .exitAvailable:
            Button(action: onTap) {
                ZStack {
                    Circle().fill(Color.orange)
                    Image(systemName: "arrow.down.circle.fill")
                        .font(.title2)
                        .foregroundStyle(.white)
                }
                .frame(width: 80, height: 80)
            }
            .accessibilityLabel("hud.button.exitVehicle")
        }
    }
}

#Preview("Hidden") {
    BoardButton(mode: .hidden, onTap: {})
        .padding(40)
        .background(Color.gray.opacity(0.3))
}

#Preview("Board available") {
    BoardButton(mode: .boardAvailable, onTap: {})
        .padding(40)
        .background(Color.gray.opacity(0.3))
}

#Preview("Exit available") {
    BoardButton(mode: .exitAvailable, onTap: {})
        .padding(40)
        .background(Color.gray.opacity(0.3))
}
