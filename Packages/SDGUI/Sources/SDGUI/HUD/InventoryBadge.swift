// InventoryBadge.swift
// SDGUI · HUD
//
// Right-top sample counter for the main HUD (GDD §1.5). Pure
// presentation: the badge does not know about `InventoryStore`.
// The caller passes a plain `count` and a tap callback; wiring
// the count to `InventoryStore.samples.count` stays in the
// composing view (`HUDOverlay`).
//
// The count is clamped visually (not semantically) to `99+` so
// extreme inventories don't push the badge layout around — the
// actual number is still exposed via the accessibility label.

import SwiftUI

/// Circular sample-count badge. 60×60 pt, shows a tray icon and
/// the current `count`, fires `onTap` on touch-up.
///
/// Intended use is in the top-right of the main HUD. The view is
/// intentionally independent of `InventoryStore` so:
///
///   * Tests can mount it with a fixed integer.
///   * The same widget can be re-used in the inventory detail
///     screen (P1-T9) as a close-affordance without pulling the
///     whole store in.
public struct InventoryBadge: View {

    /// Number of samples to display. 0 is rendered as "0" (not
    /// hidden) because the badge is a persistent HUD affordance,
    /// not a notification; always-visible prevents it from
    /// appearing to "pop in" when the player drills their first
    /// sample.
    public let count: Int

    /// Touch-up handler. In production this opens the inventory
    /// grid (P1-T9); in Phase 1 tests it is a no-op.
    public let onTap: () -> Void

    /// Designated initializer.
    ///
    /// - Parameters:
    ///   - count: Value to render. Clamped to `99+` visually at
    ///     100 or above; the full integer is still read by
    ///     VoiceOver via the accessibility label.
    ///   - onTap: Closure invoked on tap.
    public init(count: Int, onTap: @escaping () -> Void) {
        self.count = count
        self.onTap = onTap
    }

    public var body: some View {
        Button(action: onTap) {
            ZStack {
                // Orange sits between the green ground and the
                // blue drill button; picks the badge out without
                // competing for attention while the player
                // explores.
                Circle().fill(.orange)

                VStack(spacing: 0) {
                    // `tray.fill` is a stable SF Symbol (iOS 13+)
                    // and reads as "container / inventory" at a
                    // glance without needing supporting text.
                    Image(systemName: "tray.fill")
                        .font(.title3)
                    Text(displayCount)
                        .font(.caption)
                        .fontWeight(.bold)
                        // `monospacedDigit()` keeps the badge
                        // width visually stable as the count
                        // rolls over 9 → 10 → 99.
                        .monospacedDigit()
                }
                .foregroundStyle(.white)
            }
            .frame(width: 60, height: 60)
        }
        // Localized label — see hud.button.inventory in
        // Resources/Localization/Localizable.xcstrings.
        .accessibilityLabel("hud.button.inventory")
        // Surface the exact count to VoiceOver so users aren't
        // dependent on the (potentially clamped) visual string.
        .accessibilityValue(Text("\(count)"))
    }

    /// Visual string: clamps to "99+" at 100 or above to keep
    /// the 60×60 pt footprint stable.
    private var displayCount: String {
        count >= 100 ? "99+" : "\(count)"
    }
}

#Preview("Empty") {
    InventoryBadge(count: 0, onTap: {})
        .padding(40)
        .background(Color.gray.opacity(0.3))
}

#Preview("Few") {
    InventoryBadge(count: 3, onTap: {})
        .padding(40)
        .background(Color.gray.opacity(0.3))
}

#Preview("Many") {
    InventoryBadge(count: 142, onTap: {})
        .padding(40)
        .background(Color.gray.opacity(0.3))
}
