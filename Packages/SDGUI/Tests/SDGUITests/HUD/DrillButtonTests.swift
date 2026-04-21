// DrillButtonTests.swift
// SDGUITests · HUD
//
// SwiftUI view-struct smoke tests. SwiftUI does not ship a
// headless render harness and the project has a zero-external-
// dependency rule (see AGENTS.md §3 / Package.swift), so these
// tests focus on what IS observable from pure Swift:
//
//   * The view initializes with every input permutation.
//   * The public facade (init, body-type) is stable.
//
// Interaction-level assertions ("tap triggers onTap", "button is
// disabled when drilling") are deferred to the Phase 2 UI test
// plan, which can use XCUITest against a hosting app target.

import XCTest
import SwiftUI
@testable import SDGUI

final class DrillButtonTests: XCTestCase {

    /// Idle construction: the default `isDrilling` value is
    /// `false`, the callback is retained, and `body` is
    /// reachable without crashing during view description
    /// resolution.
    @MainActor
    func testInitIdle() {
        var tapped = 0
        let view = DrillButton(onTap: { tapped += 1 })
        XCTAssertFalse(view.isDrilling)
        // Touch `body` to force property-wrapper evaluation.
        // The resulting `some View` opaque type doesn't matter;
        // if any stored property fails type-check at runtime,
        // this crashes. That's the assertion.
        _ = view.body
        XCTAssertEqual(tapped, 0, "tap closure must not fire during init")
    }

    /// In-flight construction: `isDrilling = true` keeps the
    /// tap closure intact (we don't drop it to force "nothing
    /// can tap this") and keeps `body` reachable.
    @MainActor
    func testInitDrilling() {
        let view = DrillButton(onTap: {}, isDrilling: true)
        XCTAssertTrue(view.isDrilling)
        _ = view.body
    }

    /// The `onTap` stored property preserves reference identity
    /// (closures are value types in Swift but capture state;
    /// calling the button's stored closure must reach our
    /// counter, otherwise the binding is broken).
    @MainActor
    func testOnTapCallbackIsInvocable() {
        var tapped = 0
        let view = DrillButton(onTap: { tapped += 1 })
        view.onTap()
        view.onTap()
        XCTAssertEqual(tapped, 2, "stored onTap closure should be callable")
    }
}
