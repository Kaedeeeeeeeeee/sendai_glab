// WorkbenchStore.swift
// SDGGameplay · Workbench
//
// @Observable state container driving the workbench / microscope UI.
// See ADR-0001 §"Store"; this Store owns the presentation state machine
// for "is the workbench open?" + "which sample?" + "which layer?" and
// publishes cross-layer events when the player has committed to a
// specific sample / layer pairing.
//
// Three-layer architecture:
//
//     [SwiftUI WorkbenchView]
//             │ intent(.openWorkbench)
//             ▼
//        [WorkbenchStore]   ← this file
//             │ publishes WorkbenchOpened
//             │ publishes SampleAnalyzed (once a sample+layer pair is set)
//             ▼
//        [Quest / Encyclopedia — Phase 3+]
//
// The Store does not resolve thin-section photos itself — that is the
// UI layer's job via `ThinSectionLibrary`. Keeping the Store lean lets
// sibling agents swap in new resolvers without rewriting state logic.

import Foundation
import Observation
import SDGCore

/// `@Observable` store owning workbench open/close state plus the
/// current selection (sample + layer). Drives the Phase 2 Beta
/// microscope UI.
///
/// ### Lifecycle
/// `init` stores the bus reference only; there is no subscription to
/// start or stop (the Store is a pure publisher here). This matches
/// `PlayerControlStore` — stores that don't subscribe don't need the
/// async `start() / stop()` dance.
///
/// ### Why no subscriber half?
/// `WorkbenchOpened` / `SampleAnalyzed` are one-way outbound events
/// for quest / encyclopedia consumption. If those systems later need
/// to *close* the workbench (e.g. a cut-scene interrupts), they publish
/// a dedicated event and we add a subscriber here then — not before.
@MainActor
@Observable
public final class WorkbenchStore: Store {

    /// Mutation commands accepted by the Store. All workbench UI traffic
    /// goes through here; direct `status` writes from outside are not
    /// allowed (it's `private(set)`).
    public enum Intent: Sendable, Equatable {

        /// Open the workbench. No-op if already open.
        case openWorkbench

        /// Close the workbench. No-op if already closed. Resets the
        /// selection so reopening starts from a clean list.
        case closeWorkbench

        /// Choose (or clear, with `nil`) the currently inspected sample.
        /// Implicitly resets the layer selection because layer indices
        /// are only meaningful inside a specific sample.
        ///
        /// No-op if the workbench is closed.
        case selectSample(SampleItem.ID?)

        /// Choose (or clear, with `nil`) the layer inside the currently
        /// selected sample. `layerIndex` is the 0-based index into
        /// `SampleItem.layers`. Validation against actual sample layer
        /// count is the caller's responsibility — the Store tracks the
        /// raw index because it doesn't hold `SampleItem` values.
        ///
        /// No-op if the workbench is closed. No-op if no sample is
        /// currently selected.
        case selectLayer(layerIndex: Int?)
    }

    /// Observable state machine. Either the workbench is closed, or it
    /// is open and optionally carries a sample + layer selection.
    ///
    /// Encoding open-with-selection as associated values (rather than
    /// as two independent properties) means the UI cannot observe an
    /// invalid combination like "closed but with a sample selected".
    public enum Status: Sendable, Equatable {

        /// Workbench is not visible; no selection.
        case closed

        /// Workbench is visible. `selectedSample` / `selectedLayer`
        /// may both be `nil` (the "just opened, pick something" UI
        /// state), or only `selectedSample` may be set (the "picked a
        /// sample, now pick a layer" state), or both may be set
        /// (the "looking at a specific layer" state that triggers
        /// `SampleAnalyzed`).
        case open(selectedSample: SampleItem.ID?, selectedLayer: Int?)
    }

    // MARK: - Observable state

    /// Current workbench state. See ``Status``.
    public private(set) var status: Status = .closed

    // MARK: - Dependencies (injected, not global)

    private let eventBus: EventBus

    // MARK: - Init

    /// - Parameter eventBus: Shared bus, typically from
    ///   `AppEnvironment`.
    public init(eventBus: EventBus) {
        self.eventBus = eventBus
    }

    // MARK: - Store protocol

    public func intent(_ intent: Intent) async {
        switch intent {
        case .openWorkbench:
            await handleOpen()

        case .closeWorkbench:
            handleClose()

        case .selectSample(let id):
            await handleSelectSample(id)

        case .selectLayer(let layerIndex):
            await handleSelectLayer(layerIndex)
        }
    }

    // MARK: - Intent handlers

    /// Open the workbench if it isn't already. Publishes
    /// `WorkbenchOpened` on the transition so analytics / quest
    /// subscribers can react; no event fires on the no-op path.
    private func handleOpen() async {
        if case .open = status { return }
        status = .open(selectedSample: nil, selectedLayer: nil)
        await eventBus.publish(WorkbenchOpened(openedAt: Date()))
    }

    /// Close the workbench and clear any selection. Idempotent.
    private func handleClose() {
        if case .closed = status { return }
        status = .closed
    }

    /// Write the new sample selection. Ignored while the workbench is
    /// closed — a UI firing `.selectSample` without first opening is a
    /// programmer error, not a gameplay state we support.
    ///
    /// Selecting a new sample always clears the layer selection: layer
    /// indices are meaningless across samples (layer 0 of sample A has
    /// no connection to layer 0 of sample B), and forcing the UI to
    /// re-pick a layer keeps the "analyze" event tied to a deliberate
    /// pairing instead of a stale carry-over.
    private func handleSelectSample(_ id: SampleItem.ID?) async {
        guard case .open = status else { return }
        status = .open(selectedSample: id, selectedLayer: nil)
    }

    /// Write the new layer selection. Ignored while the workbench is
    /// closed and while no sample is currently selected (layer without
    /// sample is a contradiction).
    ///
    /// Publishes `SampleAnalyzed` **only** when both a sample *and* a
    /// non-nil layer index land, because that's the moment the player
    /// has actually "analyzed" something. Deselecting the layer
    /// (`nil`) updates state silently.
    private func handleSelectLayer(_ layerIndex: Int?) async {
        guard case let .open(selectedSample, _) = status else { return }
        guard let sampleId = selectedSample else { return }

        status = .open(selectedSample: sampleId, selectedLayer: layerIndex)

        guard let committedIndex = layerIndex else { return }
        await eventBus.publish(
            SampleAnalyzed(
                sampleId: sampleId,
                // The Store does not hold `SampleItem` values, so the
                // analyzed event carries the layerId as the stringified
                // index. View-layer callers that have the real
                // `SampleItem` on hand could post a richer event in a
                // later iteration — see the UI TODO.
                layerId: "layer_\(committedIndex)",
                analyzedAt: Date()
            )
        )
    }

    // MARK: - Introspection (test hook)

    /// Convenience boolean mirroring the `.open` case. Exposed for
    /// tests and for SwiftUI bindings that only care about "is the
    /// workbench visible?" — the UI builder prefers this to a
    /// `case ... = status` comparison on every render.
    public var isOpen: Bool {
        if case .open = status { return true }
        return false
    }

    /// Currently-selected sample id, or `nil` if the workbench is
    /// closed or the player has not picked a sample yet.
    public var selectedSampleId: SampleItem.ID? {
        if case let .open(sample, _) = status { return sample }
        return nil
    }

    /// Currently-selected layer index, or `nil` if no layer (or no
    /// sample) is selected.
    public var selectedLayerIndex: Int? {
        if case let .open(_, layer) = status { return layer }
        return nil
    }
}
