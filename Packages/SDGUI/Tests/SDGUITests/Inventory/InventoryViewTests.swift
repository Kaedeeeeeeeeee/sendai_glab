// InventoryViewTests.swift
// SDGUITests · Inventory
//
// Smoke + state-branch tests for `InventoryView`. Because SwiftUI
// does not ship a headless render harness (AGENTS.md §3; see
// DrillButtonTests / HUDOverlayTests for precedent), we assert on:
//
//   * Construction across empty and populated inventories.
//   * The observable store state the view reads (`samples.count`)
//     — this pins the binding end-to-end.
//   * The close callback is a stored property and is callable.
//
// Tap-to-push navigation and the destination content are indirectly
// covered by `SampleDetailViewTests` and by the fact that
// `navigationDestination(item: $selectedSample)` is plumbed to the
// same store the tests manipulate here.

import XCTest
import SwiftUI
import SDGCore
import SDGGameplay
@testable import SDGUI

@MainActor
final class InventoryViewTests: XCTestCase {

    // MARK: - Helpers

    /// Spin up a fresh store on an isolated EventBus with in-memory
    /// persistence so each test starts empty and leaves no UserDefaults
    /// residue on the CI machine.
    private func makeStore() -> InventoryStore {
        let bus = EventBus()
        return InventoryStore(eventBus: bus, persistence: .inMemory)
    }

    /// Deterministic single-layer sample for seeding the store.
    private func makeSample(thickness: Float = 1.0) -> SampleItem {
        SampleItem(
            drillLocation: SIMD3<Float>(0, 0, 0),
            drillDepth: thickness,
            layers: [
                SampleLayerRecord(
                    layerId: "rock",
                    nameKey: "layer.rock",
                    colorRGB: SIMD3<Float>(0.5, 0.5, 0.5),
                    thickness: thickness,
                    entryDepth: 0
                )
            ]
        )
    }

    // MARK: - Tests

    /// Fresh store: `samples.count == 0`. The view's overlay renders
    /// `ContentUnavailableView` — the bound state is 0, which is what
    /// we can assert at this layer.
    func testEmptyInventoryReflectsZeroSamples() {
        let store = makeStore()
        XCTAssertEqual(store.samples.count, 0)

        let view = InventoryView(inventoryStore: store, onClose: {})
        XCTAssertEqual(view.inventoryStore.samples.count, 0)
        _ = view.body
    }

    /// Populated store: after seeding via the event pipeline, the
    /// view observes a non-empty `samples` array (the empty-state
    /// overlay collapses and the grid body renders).
    func testPopulatedInventoryExposesSamples() async {
        let bus = EventBus()
        let store = InventoryStore(eventBus: bus, persistence: .inMemory)
        await store.start()

        let sample = makeSample()
        await bus.publish(SampleCreatedEvent(sample: sample))

        // EventBus dispatches async — yield once so the handler can
        // run on the main actor before we read back.
        await yieldUntilPropagated()

        XCTAssertEqual(store.samples.count, 1)

        let view = InventoryView(inventoryStore: store, onClose: {})
        XCTAssertEqual(view.inventoryStore.samples.count, 1)
        XCTAssertEqual(view.inventoryStore.samples.first?.id, sample.id)
        _ = view.body
    }

    /// The `onClose` callback is stored and callable — the parent is
    /// responsible for dismissing the sheet / fullScreenCover, and
    /// this test guards against accidentally dropping the closure.
    func testOnCloseCallbackIsInvocable() {
        let store = makeStore()
        var closed = 0

        let view = InventoryView(inventoryStore: store) {
            closed += 1
        }

        view.onClose()
        view.onClose()
        XCTAssertEqual(closed, 2)
    }

    /// `inventory.title` + `inventory.empty.title` +
    /// `inventory.empty.description` + `ui.button.close` must all
    /// resolve to non-empty strings. String Catalog returns the key
    /// itself on miss, so this is a smoke check; the canonical
    /// "three-language parity" guarantee is enforced by the asset
    /// validator in CI.
    func testLocalizationKeysResolveToNonEmptyStrings() {
        let keys = [
            "inventory.title",
            "inventory.empty.title",
            "inventory.empty.description",
            "ui.button.close"
        ]
        for key in keys {
            let resolved = String(localized: String.LocalizationValue(key))
            XCTAssertFalse(
                resolved.isEmpty,
                "Localization key \(key) resolved to an empty string"
            )
        }
    }

    // MARK: - Test helpers

    /// Tiny cooperative yield loop so event-bus dispatches land
    /// before the assertion runs. EventBus is backed by an actor;
    /// publishes hop twice before arriving at a @MainActor handler.
    private func yieldUntilPropagated(iterations: Int = 8) async {
        for _ in 0..<iterations {
            await Task.yield()
        }
    }
}
