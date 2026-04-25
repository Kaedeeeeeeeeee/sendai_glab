// VerticalSliderView.swift
// SDGUI · HUD
//
// Phase 7.1 vertical stick for drone climb / descend. ADR-0009's
// "Negative / known limitations" lists the hardcoded vertical = 0 as
// a Phase 7.1 follow-up; this is the follow-up.
//
// The widget is a thumb-anchored 1-D slider (80 pt wide × 200 pt tall)
// that lives just left of the DrillButton / BoardButton column on
// the right edge of the HUD. Only shown while the player pilots a
// vehicle — the parent passes `isVisible: false` otherwise and the
// view collapses to `EmptyView()` so it doesn't reserve layout space.
//
// Why a vertical slider, not a second joystick: the only use today is
// drone climb / descend, which is a 1-D axis. A full joystick would
// be either wasteful (second axis never read) or confusing (two
// joysticks, two axis conventions). A single vertical stick also
// communicates the climb affordance more directly than a disc.
//
// ## Axis convention
//
//   * Output is `-1 … +1`. `+1` = thumb at the top (= ascend),
//     `-1` = thumb at the bottom (= descend), `0` = centre / untouched.
//   * On release the knob springs back to centre and the output resets
//     to 0 — matches `VirtualJoystickView.reset`.
//
// ## Dead-zone
//
// Mirrors `VirtualJoystickView`'s 0.1 normalised dead-zone so tiny
// drifts while the thumb rests on the knob don't slowly drift the
// drone up or down. Without this, the Phase 7 symptom of "drone
// levitates away when you aren't looking" would just have been
// replaced by "drone sinks away".

import SwiftUI

/// A draggable on-screen vertical slider. Writes a normalised value
/// into `output` while the finger is down and resets to 0 on release.
///
/// Typical parent use (from `HUDOverlay`):
///
/// ```swift
/// @State private var verticalSliderValue: Float = 0
/// …
/// VerticalSliderView(
///     output: $verticalSliderValue,
///     isVisible: vehicleStore.occupiedVehicleId != nil
/// )
/// .frame(width: 80, height: 200)
/// ```
public struct VerticalSliderView: View {

    // MARK: - Visual constants

    /// Outer track width in points. Matches the `.frame(width:)` the
    /// parent is expected to supply; we duplicate the literal so the
    /// math in `update(_:)` is self-contained and doesn't need a
    /// geometry reader.
    private let trackWidth: CGFloat = 80

    /// Outer track height in points. Drives the maximum knob travel.
    private let trackHeight: CGFloat = 200

    /// Knob diameter. Slightly wider than the track so the knob
    /// visibly overflows the track edges — the widget reads as a
    /// physical thumb grip rather than a flat bar.
    private let knobDiameter: CGFloat = 60

    /// Fraction of the half-track height within which the axis reads
    /// zero. Matches `VirtualJoystickView.deadZone = 0.1` so the two
    /// widgets feel equally forgiving.
    private let deadZone: CGFloat = 0.1

    // MARK: - State + binding

    /// Live knob offset from centre in points, driven by the drag
    /// gesture. Positive = down, negative = up (SwiftUI convention);
    /// the output reads the inverse so "up" means "ascend".
    @State private var knobOffset: CGFloat = 0

    /// The two-way binding the parent view uses to wire the slider
    /// into `VehicleStore.intent(.pilot(vertical:))`. We *write* to
    /// this; consumers should treat reads as authoritative for "what
    /// is the stick currently saying".
    @Binding private var output: Float

    /// Whether the widget is visible at all. When `false` the view
    /// collapses to an empty body — callers don't have to
    /// conditionally include us. Saves the parent from wrapping this
    /// in an `if` block.
    private let isVisible: Bool

    // MARK: - Init

    /// Create a vertical slider that writes its normalised value into
    /// `output`. When `isVisible` is `false` the body becomes
    /// `EmptyView()` and no layout space is consumed.
    public init(output: Binding<Float>, isVisible: Bool) {
        self._output = output
        self.isVisible = isVisible
    }

    // MARK: - Body

    public var body: some View {
        if isVisible {
            slider
        } else {
            // Collapse completely — no frame, no tap target. Parents
            // can keep the widget in their layout tree unconditionally
            // and rely on this to vanish.
            EmptyView()
        }
    }

    @ViewBuilder
    private var slider: some View {
        // Max travel from centre to either edge, minus half the knob
        // so the knob's edge stays inside the track's edge.
        let maxTravel = (trackHeight - knobDiameter) / 2

        ZStack {
            // Track — translucent so it doesn't dominate the HUD.
            RoundedRectangle(cornerRadius: trackWidth / 2)
                .fill(.black.opacity(0.25))
                .overlay(
                    RoundedRectangle(cornerRadius: trackWidth / 2)
                        .stroke(.white.opacity(0.5), lineWidth: 2)
                )
                .frame(width: trackWidth, height: trackHeight)

            // Centre reference line — a subtle tick so the player can
            // tell at a glance where the neutral position is. Purely
            // cosmetic; no hit testing.
            Rectangle()
                .fill(.white.opacity(0.3))
                .frame(width: trackWidth * 0.6, height: 1)
                .allowsHitTesting(false)

            // Knob — follows the thumb on the Y axis. Hit testing
            // disabled so the drag gesture is owned by the track.
            Circle()
                .fill(.white.opacity(0.7))
                .frame(width: knobDiameter, height: knobDiameter)
                .offset(y: knobOffset)
                .allowsHitTesting(false)
        }
        .frame(width: trackWidth, height: trackHeight)
        .contentShape(Rectangle())
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { value in
                    update(
                        rawTranslationY: value.translation.height,
                        maxTravel: maxTravel
                    )
                }
                .onEnded { _ in
                    reset()
                }
        )
        .accessibilityLabel("hud.slider.verticalClimb")
    }

    // MARK: - Private helpers

    /// Clamp the drag translation to `[-maxTravel, maxTravel]`, update
    /// the knob offset, and write the normalised axis to `output`.
    ///
    /// Exposed as `internal` so `VerticalSliderValueMapper` (below)
    /// can be tested headlessly — SwiftUI Views aren't instantiable in
    /// unit tests without a window.
    private func update(rawTranslationY: CGFloat, maxTravel: CGFloat) {
        let clamped = VerticalSliderValueMapper.clamp(
            raw: rawTranslationY,
            maxTravel: maxTravel
        )
        knobOffset = clamped

        output = VerticalSliderValueMapper.normalise(
            clampedOffset: clamped,
            maxTravel: maxTravel,
            deadZone: deadZone
        )
    }

    /// Spring back to centre and zero the output. Called on touch-up
    /// or cancellation.
    private func reset() {
        withAnimation(.spring(response: 0.25, dampingFraction: 0.7)) {
            knobOffset = 0
        }
        output = 0
    }
}

// MARK: - Value mapping (headless-testable)

/// Pure-function helpers for the slider's drag → normalised-axis
/// mapping. Lives outside `VerticalSliderView` so unit tests can
/// exercise the math without instantiating SwiftUI.
///
/// The methods are tiny and algebraic — their one purpose is to give
/// the test suite a target that doesn't require a running view
/// hierarchy, while keeping the "real" View thin.
public enum VerticalSliderValueMapper {

    /// Clamp a raw drag translation (in points) to the usable range
    /// `[-maxTravel, maxTravel]`. Out-of-range drags pin to the edge.
    public static func clamp(raw: CGFloat, maxTravel: CGFloat) -> CGFloat {
        if raw > maxTravel { return maxTravel }
        if raw < -maxTravel { return -maxTravel }
        return raw
    }

    /// Normalise a *clamped* knob offset into the `-1 … +1` output
    /// axis, with a `deadZone` fraction around centre snapped to 0.
    ///
    /// Convention: the view's `knobOffset` follows SwiftUI's "positive
    /// Y is down" convention, so we invert sign here — thumb-up maps
    /// to `+output` (ascend), thumb-down maps to `-output` (descend).
    ///
    /// `deadZone` is a fraction of `maxTravel`; a value of `0.1` means
    /// the centre 20% of the track returns exactly 0.
    public static func normalise(
        clampedOffset: CGFloat,
        maxTravel: CGFloat,
        deadZone: CGFloat
    ) -> Float {
        // Guard against a zero or negative travel (would divide by
        // zero). Callers should not do this, but a pathological
        // geometry reader can; return 0 rather than crash.
        guard maxTravel > 0 else { return 0 }

        // Invert so thumb-up (negative SwiftUI Y) becomes +output.
        let raw = Float(-clampedOffset / maxTravel)

        if abs(raw) < Float(deadZone) {
            return 0
        }
        return raw
    }
}

#Preview("Visible") {
    struct PreviewHost: View {
        @State private var value: Float = 0
        var body: some View {
            ZStack {
                Color.gray.opacity(0.3).ignoresSafeArea()
                VStack(spacing: 12) {
                    Text("value = \(value, specifier: "%.2f")")
                        .foregroundStyle(.white)
                    VerticalSliderView(output: $value, isVisible: true)
                        .frame(width: 80, height: 200)
                }
            }
        }
    }
    return PreviewHost()
}

#Preview("Hidden") {
    struct PreviewHost: View {
        @State private var value: Float = 0
        var body: some View {
            ZStack {
                Color.gray.opacity(0.3).ignoresSafeArea()
                VerticalSliderView(output: $value, isVisible: false)
                    .frame(width: 80, height: 200)
            }
        }
    }
    return PreviewHost()
}
