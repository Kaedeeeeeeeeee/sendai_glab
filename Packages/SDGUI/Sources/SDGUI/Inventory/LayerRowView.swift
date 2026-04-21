// LayerRowView.swift
// SDGUI · Inventory
//
// Renders a single `SampleLayerRecord` inside the `SampleDetailView`
// layers section. One row per layer, top-to-bottom, ordered the same
// way the 3D sample core stacks.
//
// Layout:
//   [color swatch]  name
//                   thickness                [#index]
//
// Kept dedicated (not inlined in `SampleDetailView`) so the row can be
// unit-tested and so a future "tap-through to encyclopedia entry" CTA
// lives in exactly one place.

import SwiftUI
import SDGGameplay

/// A single layer row inside `SampleDetailView`.
///
/// The color-swatch uses `Color(red:green:blue:)` on the record's
/// sRGB 0...1 triple — same convention as `SampleIconView`, so the
/// swatch's hue always matches the corresponding band in the
/// thumbnail.
public struct LayerRowView: View {

    /// The layer to render. Held by value — this view never mutates it.
    public let layer: SampleLayerRecord

    /// Zero-based position of this row in the enclosing layer list.
    /// Displayed as `#<index+1>` at the trailing edge so the player
    /// can refer to a specific layer by number in notes / guidance.
    public let index: Int

    /// Designated initialiser.
    ///
    /// - Parameters:
    ///   - layer: The layer record to render.
    ///   - index: Zero-based index of this row inside the sample's
    ///     `layers` array.
    public init(layer: SampleLayerRecord, index: Int) {
        self.layer = layer
        self.index = index
    }

    public var body: some View {
        HStack(spacing: 12) {
            // 24 pt coloured square with a 1 pt black stroke — matches
            // the chunky toon-shader "sticker" outline used by
            // `SampleIconView` so the detail screen stays visually
            // continuous with the grid thumbnail.
            swatch

            VStack(alignment: .leading, spacing: 2) {
                // TODO(#L10n-sample-layer-names): swap for runtime
                // localization once `LocalizationService.text(_:)` is
                // wired. See `SampleGridItemView` header comment.
                Text(verbatim: layer.nameKey)
                    .font(.subheadline)
                    .foregroundStyle(.primary)

                Text(verbatim: String(format: "%.2f m", layer.thickness))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            // Human-readable layer index. `#1` is the topmost (entry
            // depth 0); numbering proceeds downward through the core.
            Text(verbatim: "#\(index + 1)")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
    }

    // MARK: - Subviews

    /// The 24 pt colour swatch. Pulled out so the outlined +
    /// clipped rounded-rectangle stack stays readable.
    private var swatch: some View {
        RoundedRectangle(cornerRadius: 4)
            .fill(Color(
                red: Double(layer.colorRGB.x),
                green: Double(layer.colorRGB.y),
                blue: Double(layer.colorRGB.z)
            ))
            .frame(width: 24, height: 24)
            .overlay(
                RoundedRectangle(cornerRadius: 4)
                    .stroke(Color.black, lineWidth: 1)
            )
    }
}
