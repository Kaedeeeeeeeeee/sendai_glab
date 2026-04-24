// VerticalSliderViewTests.swift
// SDGUITests · HUD
//
// Exercises the pure-function value mapper backing
// `VerticalSliderView`. SwiftUI Views can't be instantiated in a
// headless XCTest bundle without a running window, so the slider's
// math is factored out into `VerticalSliderValueMapper` and tested
// directly — same approach the joystick tests would take if they
// were extracted.
//
// Contract under test:
//   * `clamp(raw:maxTravel:)` pins drag translation to
//     `[-maxTravel, maxTravel]`.
//   * `normalise(clampedOffset:maxTravel:deadZone:)` inverts the
//     SwiftUI Y convention (thumb-up = +output), applies the dead
//     zone around 0, and divides-by-zero-safely.

import XCTest
@testable import SDGUI

final class VerticalSliderViewTests: XCTestCase {

    // MARK: - Clamp

    /// Values inside the usable range pass through unchanged.
    func testClampLeavesInRangeValuesAlone() {
        XCTAssertEqual(VerticalSliderValueMapper.clamp(raw: 10, maxTravel: 50), 10)
        XCTAssertEqual(VerticalSliderValueMapper.clamp(raw: -10, maxTravel: 50), -10)
        XCTAssertEqual(VerticalSliderValueMapper.clamp(raw: 0, maxTravel: 50), 0)
    }

    /// Out-of-range values pin to the edge. Prevents the knob
    /// escaping the track when the finger drags past the base.
    func testClampPinsOutOfRangeValuesToEdges() {
        XCTAssertEqual(VerticalSliderValueMapper.clamp(raw: 999, maxTravel: 50), 50)
        XCTAssertEqual(VerticalSliderValueMapper.clamp(raw: -999, maxTravel: 50), -50)
    }

    // MARK: - Normalise

    /// Thumb at the top (negative SwiftUI Y) should produce a
    /// positive ("ascend") output. Tests the sign inversion that
    /// separates SwiftUI's layout convention from the game-side axis.
    func testNormaliseInvertsYForAscend() {
        // Full up: clampedOffset = -maxTravel → output = +1.
        let up = VerticalSliderValueMapper.normalise(
            clampedOffset: -50, maxTravel: 50, deadZone: 0.1
        )
        XCTAssertEqual(up, 1.0, accuracy: 1e-5)
    }

    /// Thumb at the bottom produces a negative output.
    func testNormaliseProducesNegativeForDescend() {
        let down = VerticalSliderValueMapper.normalise(
            clampedOffset: 50, maxTravel: 50, deadZone: 0.1
        )
        XCTAssertEqual(down, -1.0, accuracy: 1e-5)
    }

    /// Offsets inside the dead zone snap to exactly 0 so tiny drifts
    /// while the thumb rests on the knob don't accumulate into a
    /// slow climb/descent.
    func testNormaliseZerosWithinDeadZone() {
        // 0.05 × maxTravel = 2.5 — within the 0.1 dead zone.
        let y = VerticalSliderValueMapper.normalise(
            clampedOffset: 2.5, maxTravel: 50, deadZone: 0.1
        )
        XCTAssertEqual(y, 0)
    }

    /// Offsets just past the dead zone pass through (no magnitude
    /// squashing / no re-normalisation). This is how
    /// `VirtualJoystickView` works and we deliberately match it.
    func testNormalisePassesThroughJustOutsideDeadZone() {
        // 0.2 × maxTravel = 10 — past the 0.1 dead zone, raw = -0.2
        // (inverted sign for +ascend).
        let y = VerticalSliderValueMapper.normalise(
            clampedOffset: -10, maxTravel: 50, deadZone: 0.1
        )
        XCTAssertEqual(y, 0.2, accuracy: 1e-5)
    }

    /// A zero or negative `maxTravel` must return 0 rather than
    /// divide-by-zero crash. Callers don't normally hit this, but a
    /// pathological geometry reader can.
    func testNormaliseHandlesZeroMaxTravel() {
        let y = VerticalSliderValueMapper.normalise(
            clampedOffset: 5, maxTravel: 0, deadZone: 0.1
        )
        XCTAssertEqual(y, 0)
    }
}
