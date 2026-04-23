// DebugActionsBar.swift
// SDGUI · HUD
//
// Phase 2 Beta scratch HUD: a vertical strip of small buttons sitting
// just under the inventory badge on the right edge. Hosts the three
// Phase 2 Beta debug actions:
//
//   🔬  open the workbench / microscope
//   🚁  summon a drone next to the player
//   📖  start the chapter-1 intro dialogue
//
// Why a separate file (not bolted onto HUDOverlay):
//   * HUDOverlay's API surface is the Phase 1 contract — three stores
//     and two callbacks. Growing it for every Beta feature would push
//     the existing call site to keep changing.
//   * Phase 3 will replace these debug buttons with proper in-world
//     interactions (walk to a desk to open the workbench, tool-wheel
//     for the drone tool, etc.). When that lands, this file deletes
//     cleanly with zero impact on HUDOverlay.

import SwiftUI

/// Vertical stack of debug-only secondary actions, pinned just below
/// the inventory badge. Render alongside `HUDOverlay`; do NOT replace
/// it.
public struct DebugActionsBar: View {

    /// Tap → open the workbench / microscope sheet.
    public let onWorkbenchTapped: () -> Void

    /// Tap → spawn a drone vehicle next to the player at ground
    /// level. Phase 3 will move this behind a "use Drone Tool" UX.
    public let onDroneTapped: () -> Void

    /// Tap → load the next chapter intro dialogue and play it.
    /// Phase 3 will replace this with auto-trigger from quest state.
    public let onStoryTapped: () -> Void

    /// Phase 8: Tap → publish `EarthquakeStarted`. 2-second shake at
    /// intensity 0.7. Phase 8.1 moves this behind a quest trigger
    /// (`disasterOnComplete` JSON field).
    public let onEarthquakeTapped: () -> Void

    /// Phase 8: Tap → publish `FloodStarted`. Rises to `playerY + 2m`
    /// over 5 s. Phase 8.1 also moves this quest-side.
    public let onFloodTapped: () -> Void

    public init(
        onWorkbenchTapped: @escaping () -> Void,
        onDroneTapped: @escaping () -> Void,
        onStoryTapped: @escaping () -> Void,
        onEarthquakeTapped: @escaping () -> Void,
        onFloodTapped: @escaping () -> Void
    ) {
        self.onWorkbenchTapped = onWorkbenchTapped
        self.onDroneTapped = onDroneTapped
        self.onStoryTapped = onStoryTapped
        self.onEarthquakeTapped = onEarthquakeTapped
        self.onFloodTapped = onFloodTapped
    }

    public var body: some View {
        VStack {
            // Skip the top 110 pt — that's where InventoryBadge sits
            // (40 pt top inset + 60 pt badge + 10 pt breathing room).
            Spacer().frame(height: 110)
            HStack {
                Spacer()
                VStack(spacing: 12) {
                    debugButton(symbol: "scope",          bg: .purple, action: onWorkbenchTapped)
                    debugButton(symbol: "airplane",       bg: .cyan,   action: onDroneTapped)
                    debugButton(symbol: "book.closed",    bg: .pink,   action: onStoryTapped)
                    // Phase 8 disaster debug buttons. Placed last so
                    // they read as the most experimental additions.
                    debugButton(symbol: "waveform.path.ecg", bg: .red,    action: onEarthquakeTapped)
                    debugButton(symbol: "drop.fill",      bg: .blue,   action: onFloodTapped)
                }
                .padding(.trailing, 40)
            }
            Spacer()
        }
    }

    // MARK: - Sub-view

    /// Standardised round 50-pt button with an SF symbol on a
    /// translucent coloured disc. Kept private because the surface
    /// area for Phase 2 Beta debug actions is exactly three buttons.
    private func debugButton(
        symbol: String,
        bg: Color,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            ZStack {
                Circle().fill(bg.opacity(0.85))
                Image(systemName: symbol)
                    .font(.title3)
                    .foregroundStyle(.white)
            }
            .frame(width: 50, height: 50)
        }
    }
}
