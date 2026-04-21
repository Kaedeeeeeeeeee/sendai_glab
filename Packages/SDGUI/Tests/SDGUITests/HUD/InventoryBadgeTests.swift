// InventoryBadgeTests.swift
// SDGUITests · HUD
//
// Pure-Swift smoke tests for `InventoryBadge`. See
// `DrillButtonTests` for the rationale on what is (and isn't)
// tested at this layer.

import XCTest
import SwiftUI
@testable import SDGUI

final class InventoryBadgeTests: XCTestCase {

    /// Empty inventory: badge shows "0" and `body` evaluates.
    @MainActor
    func testInitEmpty() {
        let view = InventoryBadge(count: 0, onTap: {})
        XCTAssertEqual(view.count, 0)
        _ = view.body
    }

    /// Small count: the view stores the raw integer — the
    /// caller isn't required to clamp before passing it in.
    @MainActor
    func testInitSmallCount() {
        let view = InventoryBadge(count: 3, onTap: {})
        XCTAssertEqual(view.count, 3)
        _ = view.body
    }

    /// Large count: we clamp visually at 100+ inside the view.
    /// The stored property still carries the true number so
    /// the accessibility value is accurate.
    @MainActor
    func testInitLargeCount() {
        let view = InventoryBadge(count: 9999, onTap: {})
        XCTAssertEqual(view.count, 9999)
        _ = view.body
    }

    /// `onTap` remains callable after construction.
    @MainActor
    func testOnTapCallbackIsInvocable() {
        var tapped = 0
        let view = InventoryBadge(count: 7, onTap: { tapped += 1 })
        view.onTap()
        XCTAssertEqual(tapped, 1)
    }
}
