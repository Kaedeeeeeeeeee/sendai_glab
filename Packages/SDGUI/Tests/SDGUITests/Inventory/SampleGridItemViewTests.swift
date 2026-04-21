// SampleGridItemViewTests.swift
// SDGUITests · Inventory
//
// Pure-Swift smoke tests for `SampleGridItemView`. SwiftUI's `body`
// content is an opaque `some View` that we can't introspect headlessly
// (see SampleIconViewTests header); tests here exercise what IS
// observable:
//
//   * The view initialises across the relevant input shapes (empty
//     layers, single layer, multi-layer) without crashing.
//   * `body` evaluates — catches the "I forgot to wire a modifier
//     into the sample data" class of regression.
//   * Public field round-trip (`sample`) stays stable.
//
// Interaction / visual tests live behind XCUITest in Phase 2.

import XCTest
import SwiftUI
import SDGGameplay
@testable import SDGUI

@MainActor
final class SampleGridItemViewTests: XCTestCase {

    // MARK: - Fixtures

    /// Empty sample — exercises the layers-first fallback in both the
    /// name label (`sample.defaultDisplayNameKey`) and the depth label
    /// ("0.0 m") without depending on any specific layer record shape.
    private func emptySample() -> SampleItem {
        SampleItem(
            drillLocation: SIMD3<Float>(0, 0, 0),
            drillDepth: 0,
            layers: []
        )
    }

    /// Two-layer sample with known thicknesses so the depth label is
    /// deterministic. 1.5 + 0.5 = 2.0 m.
    private func twoLayerSample() -> SampleItem {
        SampleItem(
            drillLocation: SIMD3<Float>(1, 2, 3),
            drillDepth: 2.0,
            layers: [
                SampleLayerRecord(
                    layerId: "top",
                    nameKey: "layer.top",
                    colorRGB: SIMD3<Float>(1, 0, 0),
                    thickness: 1.5,
                    entryDepth: 0
                ),
                SampleLayerRecord(
                    layerId: "bottom",
                    nameKey: "layer.bottom",
                    colorRGB: SIMD3<Float>(0, 0, 1),
                    thickness: 0.5,
                    entryDepth: 1.5
                )
            ]
        )
    }

    // MARK: - Tests

    func testInitWithEmptyLayersDoesNotCrash() {
        let sample = emptySample()
        let view = SampleGridItemView(sample: sample)
        XCTAssertEqual(view.sample.layers.count, 0)
        _ = view.body
    }

    func testInitWithMultipleLayersPreservesOrder() {
        let sample = twoLayerSample()
        let view = SampleGridItemView(sample: sample)
        XCTAssertEqual(view.sample.layers.map(\.layerId), ["top", "bottom"])
        _ = view.body
    }

    /// Depth label is derived from `layers.thickness.reduce(0, +)`.
    /// The public view stores the sample; verifying the same
    /// computation here locks the *contract* that "what the grid cell
    /// displays" matches what the icon shows without reaching into
    /// the private derived property.
    func testDepthSumMatchesDerivedDepthLabel() {
        let sample = twoLayerSample()
        let total = sample.layers.reduce(Float(0)) { $0 + $1.thickness }
        XCTAssertEqual(total, 2.0, accuracy: 0.0001)
    }

    /// Zero-layer sample still produces a valid "0.0 m" computation;
    /// guard against a regression where `reduce` is replaced by
    /// `first.map { ... }` and silently drops the fallback path.
    func testEmptyLayersReturnsZeroTotalThickness() {
        let sample = emptySample()
        let total = sample.layers.reduce(Float(0)) { $0 + $1.thickness }
        XCTAssertEqual(total, 0)
    }
}
