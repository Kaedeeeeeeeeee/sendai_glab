// MicroscopeView.swift
// SDGUI · Workbench
//
// Right-pane microscope viewer inside `WorkbenchView`. Given a
// `SampleItem` + a layer index, looks up the matching thin-section
// photos via `ThinSectionLibrary`, and renders one with pinch-zoom,
// pan, and a magnification readout.
//
// Phase 2 Beta scope:
//   * Shows the first photo for the layer; if the layer has no mapped
//     photos, renders `ThinSectionLibrary.fallback`.
//   * Pinch-zoom range 1x…8x; drag-pan in screen space.
//   * Caption below the viewport, sourced from the photo's `captionKey`.
//   * "No slide available" copy if `sample == nil` or no layer picked.
//
// ADR-0001 compliance: purely presentational. Reads a `SampleItem`
// snapshot (passed down from `WorkbenchView`) plus the optional layer
// index; reads `ThinSectionLibrary` which is a stateless static API;
// never writes Store state.
//
// Photo pagination: the current layer may have multiple thin-section
// photos mapped. Phase 2 Beta displays only the first — a disclosure
// affordance lands when real photos arrive (Phase 3).

import SwiftUI
import SDGGameplay

/// Microscope viewer: zoom/pan the current layer's thin section.
public struct MicroscopeView: View {

    /// Currently inspected sample. `nil` when nothing selected — the
    /// view renders the "select a sample" empty-state then.
    public let sample: SampleItem?

    /// Currently inspected layer inside `sample`. Must be a valid
    /// index into `sample.layers`; `nil` when no layer chosen.
    public let layerIndex: Int?

    /// Bundle from which `ThinSectionLibrary` loads the mapping. The
    /// app passes `.main`; tests pass `Bundle.module`. Exposed so
    /// previews and UI tests can substitute a bundle containing a
    /// fixture JSON.
    public let bundle: Bundle

    /// Current zoom magnification, clamped to `[minZoom ... maxZoom]`.
    /// Driven by `MagnificationGesture` in `.gesture()`.
    @State private var zoom: CGFloat = 1.0

    /// Baseline captured at the start of each pinch so deltas apply
    /// relative to the committed magnification (rather than fighting
    /// the gesture's own accumulation).
    @State private var zoomBaseline: CGFloat = 1.0

    /// Pan offset applied to the image. Reset whenever the selected
    /// layer / sample changes so a zoomed-and-panned view doesn't
    /// carry over to an unrelated slide.
    @State private var pan: CGSize = .zero

    /// Baseline captured at the start of each drag for the same
    /// reason as `zoomBaseline`.
    @State private var panBaseline: CGSize = .zero

    /// Zoom floor: 1x = fit. Going below only introduces empty
    /// margins around the image, which doesn't help the player.
    private let minZoom: CGFloat = 1.0

    /// Zoom ceiling: 8x is roughly the useful range for a pixel-perfect
    /// procedural placeholder at iPad native resolution. Tighter caps
    /// (e.g. 12x) would just magnify resampling artefacts.
    private let maxZoom: CGFloat = 8.0

    /// Designated initializer.
    ///
    /// - Parameters:
    ///   - sample: Sample being inspected, or `nil` for empty state.
    ///   - layerIndex: Layer index inside `sample.layers`, or `nil`.
    ///   - bundle: Bundle containing `thin_section_index.json`.
    ///     Default `.main`; tests / previews pass their own.
    public init(
        sample: SampleItem?,
        layerIndex: Int?,
        bundle: Bundle = .main
    ) {
        self.sample = sample
        self.layerIndex = layerIndex
        self.bundle = bundle
    }

    public var body: some View {
        VStack(spacing: 12) {
            viewport
            magnificationReadout
            captionArea
        }
        .padding()
        // Reset zoom / pan whenever the layer changes so each slide
        // starts fit-to-viewport. `layerKey` is `sample.id.hash ⊕ index`
        // so distinct (sample, index) pairs trip the onChange.
        .onChange(of: layerKey) { _, _ in
            resetTransform()
        }
    }

    // MARK: - Subviews

    /// The main square viewport holding the thin-section image (or
    /// the "no slide" placeholder). Masked so panning past the edges
    /// reveals the dark microscope background instead of leaking
    /// over the layer selector.
    private var viewport: some View {
        ZStack {
            // Microscope "background" — matches the Unity project's
            // near-black interior for comparable mood.
            RoundedRectangle(cornerRadius: 12)
                .fill(Color.black.opacity(0.85))

            if let currentPhoto = photoToDisplay {
                ThinSectionImageView(photo: currentPhoto)
                    .scaleEffect(zoom)
                    .offset(pan)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                    .gesture(zoomGesture)
                    .gesture(panGesture)
                    .accessibilityIdentifier("microscope.viewport.image")
            } else {
                emptyViewport
            }
        }
        .aspectRatio(1, contentMode: .fit)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// Empty-state text shown when no sample/layer is picked or no
    /// photo is mapped to the layer.
    private var emptyViewport: some View {
        VStack(spacing: 8) {
            Image(systemName: "scope")
                .font(.system(size: 48))
                .foregroundStyle(.white.opacity(0.6))
            Text(emptyStateKey)
                .font(.headline)
                .foregroundStyle(.white)
                .multilineTextAlignment(.center)
        }
        .padding()
    }

    /// "1.00×" readout below the viewport. Kept as a small badge so
    /// players can tell when they've actually zoomed in.
    private var magnificationReadout: some View {
        Text(verbatim: String(format: "%.2f×", Double(zoom)))
            .font(.caption.monospacedDigit())
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(.black.opacity(0.6), in: .capsule)
            .foregroundStyle(.white)
            .accessibilityIdentifier("microscope.magnification")
    }

    /// Caption + credit, both localized. Collapses to empty when
    /// nothing is selected.
    private var captionArea: some View {
        VStack(spacing: 4) {
            if let photo = photoToDisplay {
                Text(LocalizedStringKey(photo.captionKey))
                    .font(.callout)
                    .multilineTextAlignment(.center)
                    .accessibilityIdentifier("microscope.caption")
                if let creditKey = photo.creditKey {
                    Text(LocalizedStringKey(creditKey))
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
            }
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - Gestures

    /// Pinch → magnification. `zoomBaseline` stores the zoom at pinch
    /// start so deltas multiply relative to the last committed zoom.
    private var zoomGesture: some Gesture {
        MagnificationGesture()
            .onChanged { value in
                let proposed = zoomBaseline * value
                zoom = min(max(proposed, minZoom), maxZoom)
            }
            .onEnded { _ in
                zoomBaseline = zoom
            }
    }

    /// Drag → pan. Tracks deltas from `panBaseline` to keep the drag
    /// additive across multiple touches. No clamping in Phase 2 Beta:
    /// the image can be panned off-screen (the dark microscope
    /// background fills the gap), which matches real microscope UX
    /// better than a hard edge.
    private var panGesture: some Gesture {
        DragGesture(minimumDistance: 2)
            .onChanged { value in
                pan = CGSize(
                    width: panBaseline.width + value.translation.width,
                    height: panBaseline.height + value.translation.height
                )
            }
            .onEnded { _ in
                panBaseline = pan
            }
    }

    // MARK: - Derived

    /// Stable identifier for "which layer am I currently looking at".
    /// Used as the `onChange` trigger that resets zoom + pan so
    /// switching slides feels clean.
    private var layerKey: String {
        let sampleHash = sample.map { $0.id.uuidString } ?? "nil"
        let indexPart = layerIndex.map(String.init) ?? "nil"
        return "\(sampleHash)#\(indexPart)"
    }

    /// Resolved photo to render. `nil` collapses the view into the
    /// empty state:
    ///   * No sample selected, or
    ///   * No layer selected, or
    ///   * Selected layer has no mapped photos *and* no fallback
    ///     (which can't happen in practice — `fallback` is a static
    ///     member).
    private var photoToDisplay: ThinSectionPhoto? {
        guard let sample,
              let index = layerIndex,
              sample.layers.indices.contains(index) else {
            return nil
        }

        let layer = sample.layers[index]
        let mapped = ThinSectionLibrary.photos(
            forLayerId: layer.layerId,
            in: bundle
        )
        return mapped.first ?? ThinSectionLibrary.fallback
    }

    /// L10n key used by the empty viewport. We distinguish
    /// "no sample / no layer picked" from "layer selected but no
    /// slide mapped" because the fallback mechanism actually makes
    /// the latter almost impossible — but the UI still needs a
    /// sensible copy choice if it happens.
    private var emptyStateKey: LocalizedStringKey {
        if sample == nil || layerIndex == nil {
            return "workbench.empty.message"
        }
        return "workbench.layer.empty"
    }

    // MARK: - Helpers

    /// Reset zoom + pan to their defaults. Invoked on layer change.
    private func resetTransform() {
        zoom = 1.0
        zoomBaseline = 1.0
        pan = .zero
        panBaseline = .zero
    }
}
