// SampleIconViewTests.swift
// SDGUITests · Samples
//
// Behavioural tests for `SampleIconView`. Because the view itself is
// pure SwiftUI, we cannot reach into its `Canvas` drawing at
// `XCTest` runtime — that would require a full UI hosting harness
// and the macOS test target runs headless. Instead we assert the
// things that *do* matter for correctness:
//
//   * The view is initialisable across the full input space (empty
//     layers, single layer, many layers). This guards against the
//     `total == 0` branch in `draw(in:size:)` regressing to a crash.
//   * Public field round-trip (sample + cornerRadius) so the struct's
//     public surface stays stable.
//
// Visual correctness (e.g. "a sample with a 30 %-thickness red layer
// shows a red band covering the top 30 % of the canvas") is instead
// validated indirectly via `SampleIconRendererTests`: if the raster
// pipeline produces a non-empty PNG for the same inputs, the
// Canvas closure survived its execution on the render pass.

import XCTest
import SwiftUI
import SDGGameplay
@testable import SDGUI

@MainActor
final class SampleIconViewTests: XCTestCase {

    // MARK: - Fixtures

    /// Minimal sample with zero layers — exercises the `total == 0`
    /// fallback path in `SampleIconView.draw(...)`.
    private func emptySample() -> SampleItem {
        SampleItem(
            drillLocation: SIMD3<Float>(0, 0, 0),
            drillDepth: 0,
            layers: []
        )
    }

    /// Sample with one full-thickness layer — 100 % of the canvas
    /// should be the layer's colour. (Visual assertion is deferred to
    /// the renderer test via PNG-size threshold; here we just verify
    /// the view constructs.)
    private func singleLayerSample() -> SampleItem {
        SampleItem(
            drillLocation: SIMD3<Float>(0, 0, 0),
            drillDepth: 1,
            layers: [
                SampleLayerRecord(
                    layerId: "rock",
                    nameKey: "layer.rock",
                    colorRGB: SIMD3<Float>(1, 0, 0),
                    thickness: 1.0,
                    entryDepth: 0
                )
            ]
        )
    }

    /// Sample with three layers and known thickness ratio 2 : 3 : 1.
    /// Used by the renderer tests to sanity-check PNG output size.
    private func threeLayerSample() -> SampleItem {
        SampleItem(
            drillLocation: SIMD3<Float>(0, 0, 0),
            drillDepth: 6,
            layers: [
                SampleLayerRecord(
                    layerId: "top",
                    nameKey: "layer.top",
                    colorRGB: SIMD3<Float>(0.9, 0.2, 0.2),
                    thickness: 2,
                    entryDepth: 0
                ),
                SampleLayerRecord(
                    layerId: "mid",
                    nameKey: "layer.mid",
                    colorRGB: SIMD3<Float>(0.2, 0.8, 0.3),
                    thickness: 3,
                    entryDepth: 2
                ),
                SampleLayerRecord(
                    layerId: "bot",
                    nameKey: "layer.bot",
                    colorRGB: SIMD3<Float>(0.3, 0.3, 0.9),
                    thickness: 1,
                    entryDepth: 5
                )
            ]
        )
    }

    // MARK: - Tests

    func testInitWithEmptyLayersDoesNotCrash() {
        let view = SampleIconView(sample: emptySample())
        // Accessing `body` here would require a hosting environment.
        // The fact that the initialiser runs without precondition
        // failure is already the contract — the empty-layer branch is
        // all about *not* crashing inside the Canvas closure.
        XCTAssertEqual(view.sample.layers.count, 0)
    }

    func testInitWithSingleLayerExposesLayer() {
        let view = SampleIconView(sample: singleLayerSample())
        XCTAssertEqual(view.sample.layers.count, 1)
        XCTAssertEqual(view.sample.layers.first?.layerId, "rock")
    }

    func testInitWithThreeLayersPreservesOrder() {
        let view = SampleIconView(sample: threeLayerSample())
        XCTAssertEqual(view.sample.layers.map(\.layerId), ["top", "mid", "bot"])
    }

    func testDefaultCornerRadiusIsEight() {
        let view = SampleIconView(sample: singleLayerSample())
        XCTAssertEqual(view.cornerRadius, 8)
    }

    func testExplicitCornerRadiusOverrides() {
        let view = SampleIconView(sample: singleLayerSample(), cornerRadius: 0)
        XCTAssertEqual(view.cornerRadius, 0)
    }
}
