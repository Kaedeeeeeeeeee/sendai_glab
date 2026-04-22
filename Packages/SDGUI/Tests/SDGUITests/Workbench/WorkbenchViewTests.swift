// WorkbenchViewTests.swift
// SDGUITests · Workbench
//
// Light smoke tests for `WorkbenchView` + `MicroscopeView`. SwiftUI
// does not give us a headless render harness, so we assert on:
//   * Construction across the three observable states (closed,
//     open-empty, open-with-selection).
//   * `onClose` callback round-trips.
//   * L10n keys resolve to non-empty strings.
//
// See `InventoryViewTests` for precedent; we follow the same pattern.

import XCTest
import SwiftUI
import SDGCore
import SDGGameplay
@testable import SDGUI

@MainActor
final class WorkbenchViewTests: XCTestCase {

    // MARK: - Fixtures

    private func makeSample() -> SampleItem {
        SampleItem(
            drillLocation: SIMD3<Float>(0, 0, 0),
            drillDepth: 2.0,
            layers: [
                SampleLayerRecord(
                    layerId: "aobayama.topsoil",
                    nameKey: "layer.topsoil",
                    colorRGB: SIMD3<Float>(0.5, 0.4, 0.3),
                    thickness: 1.0,
                    entryDepth: 0
                ),
                SampleLayerRecord(
                    layerId: "aobayama.aobayamafm.upper",
                    nameKey: "layer.aobayama.upper",
                    colorRGB: SIMD3<Float>(0.7, 0.6, 0.4),
                    thickness: 1.0,
                    entryDepth: 1.0
                )
            ]
        )
    }

    // MARK: - Tests

    func testClosedStateRenders() {
        let bus = EventBus()
        let work = WorkbenchStore(eventBus: bus)
        let inv = InventoryStore(eventBus: bus, persistence: .inMemory)

        let view = WorkbenchView(
            workbenchStore: work,
            inventoryStore: inv,
            onClose: {}
        )
        XCTAssertEqual(view.workbenchStore.status, .closed)
        // Force body evaluation — no crashes is the smoke check.
        _ = view.body
    }

    func testOpenWithoutSamplesRenders() async {
        let bus = EventBus()
        let work = WorkbenchStore(eventBus: bus)
        let inv = InventoryStore(eventBus: bus, persistence: .inMemory)
        await inv.start()

        await work.intent(.openWorkbench)

        let view = WorkbenchView(
            workbenchStore: work,
            inventoryStore: inv,
            onClose: {}
        )
        XCTAssertTrue(view.workbenchStore.isOpen)
        XCTAssertEqual(view.inventoryStore.samples.count, 0)
        _ = view.body
    }

    func testOpenWithSampleAndLayerRenders() async {
        let bus = EventBus()
        let work = WorkbenchStore(eventBus: bus)
        let inv = InventoryStore(eventBus: bus, persistence: .inMemory)
        await inv.start()

        let sample = makeSample()
        await bus.publish(SampleCreatedEvent(sample: sample))
        await yieldUntilPropagated()

        await work.intent(.openWorkbench)
        await work.intent(.selectSample(sample.id))
        await work.intent(.selectLayer(layerIndex: 0))
        await yieldUntilPropagated()

        XCTAssertEqual(work.selectedSampleId, sample.id)
        XCTAssertEqual(work.selectedLayerIndex, 0)
        XCTAssertEqual(inv.samples.count, 1)

        let view = WorkbenchView(
            workbenchStore: work,
            inventoryStore: inv,
            onClose: {}
        )
        _ = view.body
    }

    func testOnCloseCallbackIsInvocable() {
        let bus = EventBus()
        let work = WorkbenchStore(eventBus: bus)
        let inv = InventoryStore(eventBus: bus, persistence: .inMemory)

        var closed = 0
        let view = WorkbenchView(
            workbenchStore: work,
            inventoryStore: inv,
            onClose: { closed += 1 }
        )
        view.onClose()
        view.onClose()
        XCTAssertEqual(closed, 2)
    }

    func testMicroscopeViewRendersEmptyState() {
        let view = MicroscopeView(sample: nil, layerIndex: nil)
        _ = view.body
    }

    func testMicroscopeViewRendersWithSample() {
        let sample = makeSample()
        let view = MicroscopeView(sample: sample, layerIndex: 0)
        _ = view.body
    }

    func testMicroscopeViewHandlesOutOfRangeLayerIndex() {
        // If the Store somehow hands us a layer index beyond the
        // sample's layer count, the view must not crash — it falls
        // back to the empty state.
        let sample = makeSample()
        let view = MicroscopeView(sample: sample, layerIndex: 99)
        _ = view.body
    }

    func testWorkbenchLocalizationKeysResolveToNonEmpty() {
        let keys = [
            "workbench.title",
            "workbench.button.close",
            "workbench.empty.message",
            "workbench.layer.empty",
            "thinsection.topsoil.caption",
            "thinsection.aobayama.upper.caption",
            "thinsection.aobayama.lower.caption",
            "thinsection.basement.caption",
            "thinsection.tuff.caption",
            "thinsection.placeholder.generic.caption",
            "thinsection.placeholder.credit"
        ]
        for key in keys {
            let resolved = String(localized: String.LocalizationValue(key))
            XCTAssertFalse(
                resolved.isEmpty,
                "Localization key \(key) resolved to empty string"
            )
        }
    }

    // MARK: - Helpers

    private func yieldUntilPropagated(iterations: Int = 8) async {
        for _ in 0..<iterations {
            await Task.yield()
        }
    }
}
