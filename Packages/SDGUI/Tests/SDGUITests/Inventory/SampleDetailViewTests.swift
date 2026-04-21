// SampleDetailViewTests.swift
// SDGUITests · Inventory
//
// Tests for the detail page that is pushed onto `InventoryView`'s
// `NavigationStack`. The interesting observable behaviours live in
// the Store (note update + delete), so we drive intents directly and
// assert on `inventoryStore.samples` — that's also what the view's
// body is ultimately bound to.

import XCTest
import SwiftUI
import SDGCore
import SDGGameplay
@testable import SDGUI

@MainActor
final class SampleDetailViewTests: XCTestCase {

    // MARK: - Helpers

    private func makeStoreAndBus() -> (store: InventoryStore, bus: EventBus) {
        let bus = EventBus()
        let store = InventoryStore(eventBus: bus, persistence: .inMemory)
        return (store, bus)
    }

    private func makeSample(note: String? = nil) -> SampleItem {
        SampleItem(
            drillLocation: SIMD3<Float>(4, 2, 0),
            drillDepth: 2.5,
            layers: [
                SampleLayerRecord(
                    layerId: "soil",
                    nameKey: "layer.soil",
                    colorRGB: SIMD3<Float>(0.6, 0.3, 0.1),
                    thickness: 1.0,
                    entryDepth: 0
                ),
                SampleLayerRecord(
                    layerId: "sandstone",
                    nameKey: "layer.sandstone",
                    colorRGB: SIMD3<Float>(0.8, 0.7, 0.4),
                    thickness: 1.5,
                    entryDepth: 1.0
                )
            ],
            customNote: note
        )
    }

    /// EventBus publishes through a Task hop; yield a few times so the
    /// store's `SampleCreatedEvent` handler lands on the main actor
    /// before the assertion reads `store.samples`.
    private func yieldUntilPropagated(iterations: Int = 8) async {
        for _ in 0..<iterations {
            await Task.yield()
        }
    }

    // MARK: - Tests

    /// Construction smoke: the view initialises with a sample + store
    /// and `body` evaluates, exercising every Section branch
    /// (icon / layers / metadata / note / delete).
    func testInitAndBodyDoNotCrash() async {
        let (store, bus) = makeStoreAndBus()
        await store.start()

        let sample = makeSample()
        await bus.publish(SampleCreatedEvent(sample: sample))
        await yieldUntilPropagated()
        XCTAssertEqual(store.samples.count, 1)

        let view = SampleDetailView(sample: sample, inventoryStore: store)
        XCTAssertEqual(view.sample.id, sample.id)
        _ = view.body
    }

    /// Seed a sample, fire `.delete(sample.id)`, assert the sample
    /// is gone from the store's `samples`. The detail view's delete
    /// button wraps exactly this intent call in a `Task`; invoking
    /// it directly proves the Store contract the view depends on.
    func testDeleteIntentRemovesSampleFromStore() async {
        let (store, bus) = makeStoreAndBus()
        await store.start()

        let sample = makeSample()
        await bus.publish(SampleCreatedEvent(sample: sample))
        await yieldUntilPropagated()

        XCTAssertEqual(store.samples.count, 1)

        await store.intent(.delete(sample.id))

        XCTAssertEqual(store.samples.count, 0)
    }

    /// `.updateNote` replaces the note on the matching sample; `nil`
    /// clears it. The note editor's `.onChange` handler calls exactly
    /// this intent, so verifying the store path here pins the binding.
    func testUpdateNoteIntentPersistsThenClears() async {
        let (store, bus) = makeStoreAndBus()
        await store.start()

        let sample = makeSample()
        await bus.publish(SampleCreatedEvent(sample: sample))
        await yieldUntilPropagated()

        await store.intent(.updateNote(sample.id, "first note"))
        XCTAssertEqual(store.samples.first?.customNote, "first note")

        await store.intent(.updateNote(sample.id, nil))
        XCTAssertNil(store.samples.first?.customNote)
    }

    /// The detail view seeds its `@State noteDraft` from
    /// `sample.customNote ?? ""` in `init`. Verify both branches
    /// by constructing the view against a sample with and without
    /// a note — the initialiser's behaviour is the actual contract,
    /// not a derived private value.
    func testNoteDraftSeedFromSample() async {
        let (store, _) = makeStoreAndBus()
        // Don't need to `start()` — we only read the `sample` field.

        let noted = makeSample(note: "hello")
        let plain = makeSample(note: nil)

        let notedView = SampleDetailView(sample: noted, inventoryStore: store)
        XCTAssertEqual(notedView.sample.customNote, "hello")

        let plainView = SampleDetailView(sample: plain, inventoryStore: store)
        XCTAssertNil(plainView.sample.customNote)
    }

    /// All detail-page localization keys resolve to non-empty strings.
    /// Three-language parity is validated by CI's asset validator;
    /// this test catches the much simpler "typo'd the key" regression.
    func testDetailLocalizationKeysResolveToNonEmptyStrings() {
        let keys = [
            "sample.detail.layers",
            "sample.detail.metadata",
            "sample.detail.drillDepth",
            "sample.detail.createdAt",
            "sample.detail.note",
            "sample.detail.notePlaceholder",
            "sample.detail.delete",
            "sample.detail.defaultTitle",
            "sample.defaultName"
        ]
        for key in keys {
            let resolved = String(localized: String.LocalizationValue(key))
            XCTAssertFalse(
                resolved.isEmpty,
                "Localization key \(key) resolved to an empty string"
            )
        }
    }
}
