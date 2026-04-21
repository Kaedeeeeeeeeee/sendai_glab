// SampleGridItemView.swift
// SDGUI · Inventory
//
// A single cell inside the inventory grid (`InventoryView`). Renders a
// square `SampleIconView` thumbnail plus a two-line label: the top
// layer's name (localization key) and the total drilled depth. The
// view is purely presentational (ADR-0001) — no store reference, no
// business state, just a `SampleItem` in and pixels out.
//
// Why such a small dedicated type:
//   * Extracted from `InventoryView` so the grid body stays a clean
//     `ForEach { ... button ... }` without inlining layout math.
//   * Kept separate from `SampleIconView` because this view owns the
//     *cell's* typography / spacing; `SampleIconView` owns the *icon*.
//     Mixing them would force one of them to know about the other's
//     concern (GDD §1.5 inventory layout vs. toon-style sample icon).
//
// ## Localization TODO(#L10n-sample-layer-names)
// `layer.*` and `sample.defaultName` are L10n keys carried on the
// domain record (`SampleLayerRecord.nameKey`). In Phase 1 we render
// them verbatim via `Text(verbatim:)` because the canonical runtime
// resolver (`LocalizationService.text(_:)`) has not been wired yet;
// a follow-up pass will swap each `Text(verbatim: layer.nameKey)`
// call site for `Text(String(localized: LocalizationValue(...)))`
// (or an equivalent `LocalizationService` call). The UI text pulled
// from the String Catalog (e.g. `inventory.empty.title`) already goes
// through SwiftUI's auto-localisation via `Text(LocalizedStringKey)`.

import SwiftUI
import SDGGameplay

/// A single inventory grid cell: icon + name + depth label.
///
/// Sized by its container. The embedded `SampleIconView` is pinned to
/// a 1:1 aspect ratio so the thumbnail always reads as a square even
/// when the grid cell is slightly taller than wide (which happens on
/// iPads at the default 120–160 pt column width).
public struct SampleGridItemView: View {

    /// The inventory record this cell displays. Value-typed, so the
    /// view does not observe the store — parents are expected to pass
    /// a fresh `SampleItem` from a `ForEach` over `InventoryStore.samples`.
    public let sample: SampleItem

    /// Designated initialiser.
    ///
    /// - Parameter sample: The inventory record to render.
    public init(sample: SampleItem) {
        self.sample = sample
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            SampleIconView(sample: sample)
                .aspectRatio(1, contentMode: .fit)

            // Top-layer display name. `nameKey` is a LocalizationKey
            // on the domain record; see the header comment for the
            // L10n migration plan. Falling back to `sample.defaultName`
            // matches `SampleItem.defaultDisplayNameKey` so empty
            // samples still show *something* legible.
            Text(verbatim: sample.layers.first?.nameKey ?? sample.defaultDisplayNameKey)
                .font(.caption)
                .foregroundStyle(.primary)
                .lineLimit(1)

            Text(verbatim: depthLabel)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Derived

    /// "1.5 m" style label for the stacked-core total depth. Computed
    /// from `layers` (summed `thickness`) rather than `drillDepth` so
    /// the number the player sees matches the number of visible bands
    /// in the `SampleIconView` thumbnail. Empty samples render "0.0 m",
    /// matching the neutral-grey placeholder the icon draws.
    private var depthLabel: String {
        let total = sample.layers.reduce(Float(0)) { $0 + $1.thickness }
        return String(format: "%.1f m", total)
    }
}
