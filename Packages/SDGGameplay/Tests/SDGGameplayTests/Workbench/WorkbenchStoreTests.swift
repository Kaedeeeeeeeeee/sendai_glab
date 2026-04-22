// WorkbenchStoreTests.swift
// SDGGameplayTests · Workbench
//
// Unit tests for the `WorkbenchStore` state machine + event plumbing.
// Mirrors the patterns in `InventoryStoreTests` / `DrillingStoreTests`:
//   * One fresh EventBus per test (no shared singleton).
//   * `await Task.yield()` after each publish so `@MainActor`-bound
//     handlers have a chance to run before the assertion.

import XCTest
import SDGCore
@testable import SDGGameplay

@MainActor
final class WorkbenchStoreTests: XCTestCase {

    // MARK: - Initial state

    func testInitialStatusIsClosed() {
        let bus = EventBus()
        let store = WorkbenchStore(eventBus: bus)
        XCTAssertEqual(store.status, .closed)
        XCTAssertFalse(store.isOpen)
        XCTAssertNil(store.selectedSampleId)
        XCTAssertNil(store.selectedLayerIndex)
    }

    // MARK: - Open / close

    func testOpenWorkbenchTransitionsToOpenAndPublishes() async {
        let bus = EventBus()
        let store = WorkbenchStore(eventBus: bus)

        var receivedCount = 0
        _ = await bus.subscribe(WorkbenchOpened.self) { _ in
            await MainActor.run { receivedCount += 1 }
        }

        await store.intent(.openWorkbench)
        await yieldUntilPropagated()

        XCTAssertTrue(store.isOpen)
        XCTAssertEqual(receivedCount, 1)
    }

    func testOpenWorkbenchIsIdempotent() async {
        let bus = EventBus()
        let store = WorkbenchStore(eventBus: bus)

        var receivedCount = 0
        _ = await bus.subscribe(WorkbenchOpened.self) { _ in
            await MainActor.run { receivedCount += 1 }
        }

        await store.intent(.openWorkbench)
        await store.intent(.openWorkbench)
        await store.intent(.openWorkbench)
        await yieldUntilPropagated()

        XCTAssertTrue(store.isOpen)
        // No spurious events from the two extra open calls — the
        // workbench was already open.
        XCTAssertEqual(receivedCount, 1)
    }

    func testCloseWorkbenchReturnsToClosedAndClearsSelection() async {
        let bus = EventBus()
        let store = WorkbenchStore(eventBus: bus)
        let sampleId = UUID()

        await store.intent(.openWorkbench)
        await store.intent(.selectSample(sampleId))
        await store.intent(.selectLayer(layerIndex: 1))
        await yieldUntilPropagated()

        XCTAssertTrue(store.isOpen)

        await store.intent(.closeWorkbench)
        XCTAssertEqual(store.status, .closed)
        XCTAssertNil(store.selectedSampleId)
        XCTAssertNil(store.selectedLayerIndex)
    }

    func testCloseOnAlreadyClosedIsNoOp() async {
        let bus = EventBus()
        let store = WorkbenchStore(eventBus: bus)

        await store.intent(.closeWorkbench)
        await store.intent(.closeWorkbench)

        XCTAssertEqual(store.status, .closed)
    }

    // MARK: - Sample selection

    func testSelectSampleIgnoredWhileClosed() async {
        let bus = EventBus()
        let store = WorkbenchStore(eventBus: bus)
        await store.intent(.selectSample(UUID()))
        XCTAssertEqual(store.status, .closed)
        XCTAssertNil(store.selectedSampleId)
    }

    func testSelectSampleSetsSelectionAndClearsLayer() async {
        let bus = EventBus()
        let store = WorkbenchStore(eventBus: bus)
        let a = UUID()
        let b = UUID()

        await store.intent(.openWorkbench)
        await store.intent(.selectSample(a))
        await store.intent(.selectLayer(layerIndex: 2))
        XCTAssertEqual(store.selectedSampleId, a)
        XCTAssertEqual(store.selectedLayerIndex, 2)

        // Switching the sample must reset the layer index —
        // layers across samples aren't comparable.
        await store.intent(.selectSample(b))
        XCTAssertEqual(store.selectedSampleId, b)
        XCTAssertNil(store.selectedLayerIndex)
    }

    func testClearingSampleSelectionAlsoClearsLayer() async {
        let bus = EventBus()
        let store = WorkbenchStore(eventBus: bus)
        await store.intent(.openWorkbench)
        await store.intent(.selectSample(UUID()))
        await store.intent(.selectLayer(layerIndex: 0))

        await store.intent(.selectSample(nil))
        XCTAssertNil(store.selectedSampleId)
        XCTAssertNil(store.selectedLayerIndex)
    }

    // MARK: - Layer selection → SampleAnalyzed

    func testSelectLayerWithoutSampleDoesNothing() async {
        let bus = EventBus()
        let store = WorkbenchStore(eventBus: bus)
        await store.intent(.openWorkbench)

        var receivedCount = 0
        _ = await bus.subscribe(SampleAnalyzed.self) { _ in
            await MainActor.run { receivedCount += 1 }
        }

        await store.intent(.selectLayer(layerIndex: 0))
        await yieldUntilPropagated()

        XCTAssertNil(store.selectedLayerIndex)
        XCTAssertEqual(receivedCount, 0)
    }

    func testSelectLayerPublishesSampleAnalyzed() async {
        let bus = EventBus()
        let store = WorkbenchStore(eventBus: bus)
        let sampleId = UUID()

        var received: [SampleAnalyzed] = []
        _ = await bus.subscribe(SampleAnalyzed.self) { event in
            await MainActor.run { received.append(event) }
        }

        await store.intent(.openWorkbench)
        await store.intent(.selectSample(sampleId))
        await store.intent(.selectLayer(layerIndex: 3))
        await yieldUntilPropagated()

        XCTAssertEqual(received.count, 1)
        XCTAssertEqual(received.first?.sampleId, sampleId)
        XCTAssertEqual(received.first?.layerId, "layer_3")
    }

    func testDeselectingLayerDoesNotPublishSampleAnalyzed() async {
        let bus = EventBus()
        let store = WorkbenchStore(eventBus: bus)
        let sampleId = UUID()

        var receivedCount = 0
        _ = await bus.subscribe(SampleAnalyzed.self) { _ in
            await MainActor.run { receivedCount += 1 }
        }

        await store.intent(.openWorkbench)
        await store.intent(.selectSample(sampleId))
        await store.intent(.selectLayer(layerIndex: 0))
        await yieldUntilPropagated()
        // First select published exactly one event.
        XCTAssertEqual(receivedCount, 1)

        await store.intent(.selectLayer(layerIndex: nil))
        await yieldUntilPropagated()
        // Deselect must not re-publish.
        XCTAssertEqual(receivedCount, 1)
        XCTAssertNil(store.selectedLayerIndex)
    }

    func testSelectLayerIgnoredWhileClosed() async {
        let bus = EventBus()
        let store = WorkbenchStore(eventBus: bus)
        await store.intent(.selectLayer(layerIndex: 0))
        XCTAssertEqual(store.status, .closed)
    }

    // MARK: - Helpers

    private func yieldUntilPropagated(iterations: Int = 8) async {
        for _ in 0..<iterations {
            await Task.yield()
        }
    }
}
