// DrillButton.swift
// SDGUI · HUD
//
// Right-bottom action button that kicks off a drill cycle
// (GDD §1.5 main HUD). Pure presentation: the button does not
// know about `DrillingStore`. The caller passes:
//
//   * `onTap` — invoked on touch-up, typically wrapping a
//     `Task { await drillingStore.intent(.drillAt(...)) }`.
//   * `isDrilling` — a boolean derived from the Store's
//     `status == .drilling`. While true, the button is disabled
//     and shows a spinner so the player has a clear "wait" signal.
//
// Keeping the Store out of this view lets us unit-test the button
// in isolation (no `@MainActor` store needed) and reuse it later
// for the drill-tower workflow where the intent payload differs.
//
// Size is 80×80 pt — 8 pt above the Apple HIG 44×44 minimum touch
// target, matching the visual weight of the 160 pt joystick base
// in the opposite corner.

import SwiftUI

/// Circular drill action button for the main HUD. 80×80 pt,
/// disabled with a spinner overlay while drilling is in-flight.
///
/// ## Why a separate view (vs. inline in `HUDOverlay`)?
///
/// Keeps the drill-specific presentation rules (color, icon,
/// spinner, accessibility) in one place. When the Phase 2 drill
/// tower adds a "which depth slot?" chooser (GDD §1.3), only this
/// file needs to change; `HUDOverlay` stays purely compositional.
public struct DrillButton: View {

    /// Touch-up handler. Runs on the main actor (SwiftUI `Button`
    /// action closures inherit the caller's isolation).
    public let onTap: () -> Void

    /// Bound to the outer `DrillingStore.status == .drilling`.
    /// While `true` the button is disabled and shows a spinner;
    /// we do not auto-dismiss the spinner after a timeout — the
    /// Store's terminal events (`DrillCompleted` / `DrillFailed`)
    /// are the single source of truth.
    public let isDrilling: Bool

    /// Designated initializer.
    ///
    /// - Parameters:
    ///   - onTap: Closure invoked on tap. Typically wraps an
    ///     `await drillingStore.intent(.drillAt(...))` in a `Task`.
    ///   - isDrilling: `true` while the Store reports an in-flight
    ///     drill cycle. Defaults to `false` so test callers and
    ///     previews can omit it.
    public init(onTap: @escaping () -> Void, isDrilling: Bool = false) {
        self.onTap = onTap
        self.isDrilling = isDrilling
    }

    public var body: some View {
        Button(action: onTap) {
            ZStack {
                Circle()
                    // Blue when available, desaturated gray while
                    // drilling. High contrast against both the
                    // green ground and the sky on iPad landscape.
                    .fill(isDrilling ? Color.gray : Color.blue)

                // `hammer.fill` is a stable SF Symbol present
                // since iOS 13; `drill` is not guaranteed on the
                // iOS 18 floor we pin against. Swap to a custom
                // asset in Phase 2 when the art pipeline lands.
                Image(systemName: isDrilling ? "hourglass" : "hammer.fill")
                    .font(.title2)
                    .foregroundStyle(.white)

                if isDrilling {
                    // The spinner sits on top of the icon so both
                    // cue the user at once ("busy" + "wait"). The
                    // icon is only partially occluded; this is
                    // intentional — purely a spinner would blank
                    // the button and feel laggy.
                    ProgressView()
                        .progressViewStyle(.circular)
                        .tint(.white)
                }
            }
            .frame(width: 80, height: 80)
        }
        .disabled(isDrilling)
        // Localized label — see hud.button.drill in
        // Resources/Localization/Localizable.xcstrings. Using the
        // `LocalizedStringKey` overload so String Catalog
        // extraction picks it up automatically.
        .accessibilityLabel("hud.button.drill")
    }
}

#Preview("Idle") {
    DrillButton(onTap: {}, isDrilling: false)
        .padding(40)
        .background(Color.gray.opacity(0.3))
}

#Preview("Drilling") {
    DrillButton(onTap: {}, isDrilling: true)
        .padding(40)
        .background(Color.gray.opacity(0.3))
}
