// SampleIconView.swift
// SDGUI · Samples
//
// 2D stacked color-swatch preview for a `SampleItem`. Phase 1 POC:
// we deliberately render a flat stack of rectangles (one per
// `SampleLayerRecord`, height proportional to `thickness`) instead of
// an off-screen RealityKit snapshot of the real 3D sample core.
//
// Why 2D in Phase 1 (see task P1-T7 spec):
//   * RealityKit has no first-class off-screen snapshot API we can rely
//     on across iOS 18 / macOS 15. `ImageRenderer` on a SwiftUI view
//     is stable and already available where it matters (inventory grid,
//     HUD badges).
//   * The player-visible affordance we need right now is "which sample
//     is which" at thumbnail size. A per-layer colour stack conveys
//     layer count + colour + relative thickness in 256 px just as well
//     as a real render would, without the complexity.
//   * The full 3D preview still exists — `SampleEntity` builds it — and
//     will power the encyclopaedia 3D viewer (GDD §3.1). That path is
//     orthogonal to the thumbnail path this file owns.
//
// The view is purely presentational (ADR-0001): it takes a sample
// record, draws pixels, and owns zero business state. Parents hand it
// a `SampleItem` and optionally override the corner radius.

import SwiftUI
import SDGGameplay

/// Presents a 2D stacked colour-swatch preview of a geological sample.
///
/// Top-to-bottom the view paints one rectangle per `SampleLayerRecord`
/// in `sample.layers`, with each rectangle's height proportional to
/// the layer's `thickness` relative to the sample's total thickness.
/// A rounded-rectangle outline framed around the whole canvas gives it
/// the chunky "sticker" feel that matches the toon-shader art
/// direction (GDD §0, toon style).
///
/// ### Visual contract
/// * Canvas is square by default — the containing view is expected to
///   give it a square frame (e.g. inventory grid cell). Non-square
///   frames just stretch the stack vertically; that's intentional so
///   list-row consumers can render a wide strip if they want to.
/// * A missing / empty `layers` array draws a neutral grey fill so
///   the caller still gets a visible placeholder (matches the
///   `SampleItem` comment that explicitly allows an empty sample).
///
/// ### Color handling
/// `SampleLayerRecord.colorRGB` is defined in sRGB 0...1. We feed the
/// components straight into `Color(red:green:blue:)`; SwiftUI's
/// default colour space on iOS / macOS is sRGB, so this preserves the
/// intended hue without needing an explicit `Color.RGBColorSpace`.
public struct SampleIconView: View {

    /// The sample record to render. Held by value because `SampleItem`
    /// is `Sendable` and cheap to copy; the view does not observe the
    /// record, so parents can push any `SampleItem` in without extra
    /// `@Observable` plumbing.
    public let sample: SampleItem

    /// Corner-radius of the outer stroke + clip. Default 8 pt matches
    /// the thumbnail spec; callers that want a fully square sticker
    /// (e.g. a micro badge) pass `0`.
    public let cornerRadius: CGFloat

    /// Memberwise initialiser.
    ///
    /// - Parameters:
    ///   - sample: The inventory record to render.
    ///   - cornerRadius: Corner radius applied to the outer stroke and
    ///     clip shape. Default 8 pt.
    public init(sample: SampleItem, cornerRadius: CGFloat = 8) {
        self.sample = sample
        self.cornerRadius = cornerRadius
    }

    public var body: some View {
        Canvas { context, size in
            draw(in: context, size: size)
        }
        .overlay(
            // 2 pt stroke — matches the cartoon outline weight the
            // toon shader uses on 3D samples, so the 2D preview feels
            // stylistically unified with the real rendered sample.
            RoundedRectangle(cornerRadius: cornerRadius)
                .stroke(Color.black, lineWidth: 2)
        )
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius))
    }

    // MARK: - Drawing

    /// Paint the stacked colour bars inside `context`.
    ///
    /// Pulled out of `body` so tests and previews can reason about it
    /// directly, and because SwiftUI's `Canvas` closure is awkward to
    /// step through otherwise.
    ///
    /// The empty / zero-thickness fallback fills the whole canvas with
    /// a 50 % grey. That keeps the thumbnail visually meaningful even
    /// for a `SampleItem` that captured no layers (drill-into-empty-
    /// air edge case).
    private func draw(in context: GraphicsContext, size: CGSize) {
        let total = sample.layers.reduce(CGFloat(0)) { $0 + CGFloat($1.thickness) }
        guard total > 0 else {
            let background = Path(CGRect(origin: .zero, size: size))
            context.fill(background, with: .color(.gray.opacity(0.5)))
            return
        }

        var y: CGFloat = 0
        for layer in sample.layers {
            // Compute the next band's height in canvas space. Using
            // the ratio over running total (rather than summing pixels)
            // keeps the final band flush with the bottom edge even
            // when floating-point accumulation drifts.
            let h = CGFloat(layer.thickness) / total * size.height
            let rect = CGRect(x: 0, y: y, width: size.width, height: h)
            let color = Color(
                red: Double(layer.colorRGB.x),
                green: Double(layer.colorRGB.y),
                blue: Double(layer.colorRGB.z)
            )
            context.fill(Path(rect), with: .color(color))
            y += h
        }
    }
}

#Preview {
    let sample = SampleItem(
        drillLocation: SIMD3<Float>(0, 0, 0),
        drillDepth: 3.0,
        layers: [
            SampleLayerRecord(
                layerId: "soil",
                nameKey: "layer.soil",
                colorRGB: SIMD3<Float>(0.55, 0.35, 0.15),
                thickness: 1.0,
                entryDepth: 0.0
            ),
            SampleLayerRecord(
                layerId: "sandstone",
                nameKey: "layer.sandstone",
                colorRGB: SIMD3<Float>(0.85, 0.70, 0.45),
                thickness: 1.5,
                entryDepth: 1.0
            ),
            SampleLayerRecord(
                layerId: "basalt",
                nameKey: "layer.basalt",
                colorRGB: SIMD3<Float>(0.20, 0.20, 0.25),
                thickness: 0.5,
                entryDepth: 2.5
            )
        ]
    )
    return SampleIconView(sample: sample)
        .frame(width: 256, height: 256)
        .padding()
}
