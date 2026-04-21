// VirtualJoystickView.swift
// SDGUI · HUD
//
// A thumb-anchored virtual joystick for touch-based movement. Lives
// in the left-bottom corner of the HUD (see GDD §1.5). Owns only its
// visual state; the resolved axis is pushed out via a `Binding<SIMD2<Float>>`
// so the parent view can forward it to `PlayerControlStore.intent(.move(...))`.
//
// Visual: 160×160 pt ring (base) with a 70 pt knob. The knob follows
// the finger on drag, clamped to the base's inner radius. On release,
// the knob springs back to centre and the bound axis returns to zero.
//
// Why a local `@State` offset instead of deriving the knob from the
// bound axis? The bound value is normalised (unit-disk) and lossy in
// both scale (the base radius is a render-time concern) and dead-zone
// (tiny drags are clamped to zero for gameplay but we still want the
// knob to render smoothly). Keeping both sides separate lets us style
// the knob however we want without warping the game-side signal.

import SwiftUI

/// A draggable on-screen joystick. Writes a normalised axis into
/// `output` while the finger is down and resets to `.zero` on release.
///
/// Axis convention (matches `PlayerInputComponent.moveAxis`):
///   * `x`: strafe, +right
///   * `y`: forward, +forward. We invert the SwiftUI convention here
///     because dragging **up** in screen space should mean **forward**
///     in game space.
public struct VirtualJoystickView: View {

    /// Outer ring diameter in points.
    private let baseDiameter: CGFloat = 160

    /// Knob diameter in points. A ring 160 pt across with a 70 pt
    /// knob leaves 45 pt of travel on each side; feels natural under
    /// the thumb on an iPad.
    private let knobDiameter: CGFloat = 70

    /// Fraction of the base radius within which the axis reads zero.
    /// Mirrors the old Unity `joystickDeadZone = 0.1` (normalised).
    private let deadZone: CGFloat = 0.1

    /// Live knob offset from centre, driven by the drag gesture.
    /// `@State` because this is purely visual; the game-facing value
    /// is `output`, derived from this whenever it changes.
    @State private var knobOffset: CGSize = .zero

    /// The two-way binding the parent view uses to wire the joystick
    /// into the `PlayerControlStore`. We *write* to this; consumers
    /// should treat reads as authoritative for "what is the stick
    /// currently saying" but should not write back.
    @Binding private var output: SIMD2<Float>

    /// Create a joystick that writes its normalised axis into
    /// `output`. Typical parent use:
    ///
    /// ```swift
    /// @State private var joystickAxis: SIMD2<Float> = .zero
    /// …
    /// VirtualJoystickView(output: $joystickAxis)
    ///     .onChange(of: joystickAxis) { _, new in
    ///         Task { await store.intent(.move(new)) }
    ///     }
    /// ```
    public init(output: Binding<SIMD2<Float>>) {
        self._output = output
    }

    public var body: some View {
        // Maximum distance (points) the knob can travel from centre.
        // Half the base, minus half the knob, so the knob's edge
        // stays inside the base's edge.
        let maxTravel = (baseDiameter - knobDiameter) / 2

        ZStack {
            // Base ring — translucent so it does not dominate the HUD
            // but is visible against both sky and terrain.
            Circle()
                .fill(.black.opacity(0.25))
                .overlay(Circle().stroke(.white.opacity(0.5), lineWidth: 2))
                .frame(width: baseDiameter, height: baseDiameter)

            // Knob — follows the thumb. `.allowsHitTesting(false)` on
            // the knob keeps the drag gesture owned by the base: the
            // knob is a pure visual proxy.
            Circle()
                .fill(.white.opacity(0.7))
                .frame(width: knobDiameter, height: knobDiameter)
                .offset(knobOffset)
                .allowsHitTesting(false)
        }
        .contentShape(Circle())
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { value in
                    update(
                        rawTranslation: value.translation,
                        maxTravel: maxTravel
                    )
                }
                .onEnded { _ in
                    reset()
                }
        )
    }

    // MARK: - Private

    /// Clamp the drag translation to the base's inner disc, update
    /// the knob offset, and write the normalised axis to `output`.
    private func update(rawTranslation: CGSize, maxTravel: CGFloat) {
        // Clamp to the disc of radius `maxTravel`. Using the squared
        // magnitude avoids a sqrt on every gesture tick in the common
        // case where the drag is already inside the disc.
        let dx = rawTranslation.width
        let dy = rawTranslation.height
        let magSquared = dx * dx + dy * dy
        let maxSquared = maxTravel * maxTravel

        let clamped: CGSize
        if magSquared <= maxSquared {
            clamped = CGSize(width: dx, height: dy)
        } else {
            let scale = maxTravel / sqrt(magSquared)
            clamped = CGSize(width: dx * scale, height: dy * scale)
        }
        knobOffset = clamped

        // Normalise to the unit disc for the game side. We apply a
        // radial dead-zone here so tiny unintended drags don't slowly
        // drift the player across the map while the thumb is merely
        // resting on the base.
        let nx = Float(clamped.width / maxTravel)
        // Invert: SwiftUI y+ is down, but we want y+ to mean "forward".
        let ny = Float(-clamped.height / maxTravel)

        let deadZoneSquared = Float(deadZone * deadZone)
        if (nx * nx + ny * ny) < deadZoneSquared {
            output = .zero
        } else {
            output = SIMD2(nx, ny)
        }
    }

    /// Spring back to centre and zero the output. Called on touch-up
    /// or cancellation.
    private func reset() {
        withAnimation(.spring(response: 0.25, dampingFraction: 0.7)) {
            knobOffset = .zero
        }
        output = .zero
    }
}

#Preview {
    struct PreviewHost: View {
        @State private var axis: SIMD2<Float> = .zero
        var body: some View {
            ZStack(alignment: .bottomLeading) {
                Color.gray.opacity(0.3).ignoresSafeArea()
                VirtualJoystickView(output: $axis)
                    .padding(40)
            }
        }
    }
    return PreviewHost()
}
