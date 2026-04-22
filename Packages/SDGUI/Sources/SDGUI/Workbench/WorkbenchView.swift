// WorkbenchView.swift
// SDGUI · Workbench
//
// Full-screen workbench / microscope UI (Phase 2 Beta).
//
// Layout (landscape):
//
//     ┌────────────────────────────────────────────────┐
//     │ Workbench title                       [Close ✕]│
//     ├─────────────────────┬──────────────────────────┤
//     │                     │                          │
//     │  Sample grid        │   Microscope viewer      │
//     │  (LazyVGrid)        │   — thin-section image   │
//     │  pick one →         │   — pinch/pan            │
//     │                     │   — magnification text   │
//     │                     │                          │
//     ├─────────────────────┴──────────────────────────┤
//     │  Layer picker (visible after a sample is picked)│
//     │  [layer1] [layer2] [layer3]                     │
//     └────────────────────────────────────────────────┘
//
// Hosting contract: this view is intended to be presented inside a
// `fullScreenCover` / `sheet` by the app. The `onClose` closure is
// how the caller dismisses the cover — the view never dismisses
// itself. That mirrors `InventoryView` and keeps the hosting
// decision (cover vs. sheet vs. Phase 3 spatial overlay) out of the
// module.
//
// ADR-0001 compliance:
//   * Reads `workbenchStore` / `inventoryStore` via `@Bindable`.
//   * Writes via `.intent(...)` exclusively — no direct state mutation.
//   * No EventBus calls; Store owns them.

import SwiftUI
import SDGCore
import SDGGameplay

/// Phase 2 Beta workbench view. Hosts sample selection + microscope
/// viewer + layer selector, reading from the inventory Store and
/// driving the workbench Store.
public struct WorkbenchView: View {

    /// Workbench state (open/closed + selection). Observed via
    /// `@Bindable` so SwiftUI re-renders on selection changes.
    @Bindable public var workbenchStore: WorkbenchStore

    /// Inventory source — the sample grid pulls its items from here.
    /// Read-only at this layer: the workbench does not add / delete
    /// samples.
    @Bindable public var inventoryStore: InventoryStore

    /// Caller-supplied close handler. Invoked by the close button and
    /// forwarded to `workbenchStore.intent(.closeWorkbench)`; the
    /// hosting view is responsible for dismissing its container.
    public let onClose: () -> Void

    /// Bundle that holds `thin_section_index.json`. Default `.main`;
    /// tests / previews inject their own.
    public let bundle: Bundle

    /// Grid column layout for the sample list pane. Narrower than the
    /// inventory grid (min 80 pt) because the workbench allocates only
    /// ~35 % of the screen to the sample list.
    private let sampleColumns = [
        GridItem(.adaptive(minimum: 80, maximum: 120), spacing: 12)
    ]

    /// Designated initializer.
    ///
    /// - Parameters:
    ///   - workbenchStore: Live workbench Store.
    ///   - inventoryStore: Live inventory Store (read-only usage).
    ///   - onClose: Close handler; callers dismiss their container.
    ///   - bundle: Bundle containing `thin_section_index.json`.
    public init(
        workbenchStore: WorkbenchStore,
        inventoryStore: InventoryStore,
        onClose: @escaping () -> Void,
        bundle: Bundle = .main
    ) {
        self.workbenchStore = workbenchStore
        self.inventoryStore = inventoryStore
        self.onClose = onClose
        self.bundle = bundle
    }

    public var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                mainSplit
                layerSelector
            }
            .navigationTitle(Text("workbench.title"))
            .modifier(InlineTitleIfAvailableWorkbench())
            .toolbar {
                ToolbarItem(placement: closePlacement) {
                    closeButton
                }
            }
        }
    }

    // MARK: - Layout pieces

    /// Side-by-side split: sample list on the left, microscope on the
    /// right. Uses `HStack` (rather than `NavigationSplitView`) because
    /// landscape iPad has plenty of width and a split view would render
    /// as a sidebar toggle on iPhone, which we don't want for this
    /// fullscreen modal.
    private var mainSplit: some View {
        HStack(spacing: 0) {
            sampleListPane
                .frame(maxWidth: .infinity, alignment: .top)
                .frame(minWidth: 220)
                .layoutPriority(0.35)

            Divider()

            microscopePane
                .frame(maxWidth: .infinity)
                .layoutPriority(0.65)
        }
    }

    /// Left pane: grid of samples the player has collected. Tapping a
    /// cell fires `.selectSample(id)`.
    private var sampleListPane: some View {
        ScrollView {
            if inventoryStore.samples.isEmpty {
                emptySampleList
            } else {
                LazyVGrid(columns: sampleColumns, spacing: 12) {
                    ForEach(inventoryStore.samples) { sample in
                        sampleCell(sample)
                    }
                }
                .padding()
            }
        }
        .background(Color.gray.opacity(0.08))
    }

    /// Single sample tile. Highlights the selected sample with a
    /// coloured border so the player knows what is loaded into the
    /// microscope.
    private func sampleCell(_ sample: SampleItem) -> some View {
        let isSelected = workbenchStore.selectedSampleId == sample.id
        return Button {
            let store = workbenchStore
            let id = sample.id
            Task { @MainActor in
                await store.intent(.selectSample(id))
            }
        } label: {
            SampleIconView(sample: sample)
                .frame(width: 72, height: 72)
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(isSelected ? Color.accentColor : .clear, lineWidth: 3)
                )
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("workbench.sample.\(sample.id.uuidString)")
    }

    /// "Pick a sample" affordance when inventory is empty. Reuses the
    /// inventory empty-state copy because the remedy — go drill — is
    /// identical. Wrapping in a plain `ContentUnavailableView` gives
    /// the Apple-native look.
    private var emptySampleList: some View {
        ContentUnavailableView(
            "inventory.empty.title",
            systemImage: "tray",
            description: Text("inventory.empty.description")
        )
        .padding()
    }

    /// Right pane: the microscope image + controls. Owns its own
    /// internal zoom/pan state; the Store only tracks the selection.
    private var microscopePane: some View {
        MicroscopeView(
            sample: selectedSample,
            layerIndex: workbenchStore.selectedLayerIndex,
            bundle: bundle
        )
        .background(Color.black.opacity(0.05))
    }

    /// Bottom strip: chips for each layer in the currently selected
    /// sample. Invisible (collapsed) when no sample is loaded so the
    /// main split can use the full height.
    @ViewBuilder
    private var layerSelector: some View {
        if let sample = selectedSample, !sample.layers.isEmpty {
            Divider()
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(Array(sample.layers.enumerated()), id: \.offset) { index, layer in
                        layerChip(index: index, layer: layer)
                    }
                }
                .padding()
            }
            .background(Color.gray.opacity(0.05))
        }
    }

    /// One layer chip. Reveals the layer name via `LocalizedStringKey`
    /// and shows a small colour swatch so the selected band is easy
    /// to spot.
    private func layerChip(index: Int, layer: SampleLayerRecord) -> some View {
        let isSelected = workbenchStore.selectedLayerIndex == index
        return Button {
            let store = workbenchStore
            Task { @MainActor in
                await store.intent(.selectLayer(layerIndex: index))
            }
        } label: {
            HStack(spacing: 8) {
                Circle()
                    .fill(Color(
                        red: Double(layer.colorRGB.x),
                        green: Double(layer.colorRGB.y),
                        blue: Double(layer.colorRGB.z)
                    ))
                    .frame(width: 12, height: 12)
                    .overlay(Circle().stroke(Color.black.opacity(0.4), lineWidth: 1))
                Text(LocalizedStringKey(layer.nameKey))
                    .font(.callout)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(
                isSelected
                    ? Color.accentColor.opacity(0.25)
                    : Color.gray.opacity(0.15),
                in: .capsule
            )
            .overlay(
                Capsule()
                    .stroke(isSelected ? Color.accentColor : .clear, lineWidth: 2)
            )
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("workbench.layer.\(index)")
    }

    // MARK: - Toolbar

    /// Close button — fires `.closeWorkbench` on the Store (so the
    /// state machine returns to `.closed`) *then* invokes the host's
    /// `onClose` closure to dismiss the cover.
    private var closeButton: some View {
        Button {
            let store = workbenchStore
            Task { @MainActor in
                await store.intent(.closeWorkbench)
            }
            onClose()
        } label: {
            Image(systemName: "xmark.circle.fill")
        }
        .accessibilityLabel(Text("workbench.button.close"))
    }

    /// `.topBarTrailing` is iOS-only; macOS falls back to
    /// `.primaryAction` so `swift test` on the macOS host compiles.
    private var closePlacement: ToolbarItemPlacement {
        #if os(iOS)
        return .topBarTrailing
        #else
        return .primaryAction
        #endif
    }

    // MARK: - Derived

    /// Currently selected `SampleItem`, looked up live from the
    /// inventory each render. Returns `nil` if the selected id was
    /// deleted out from under us (e.g. player cleared inventory
    /// elsewhere).
    private var selectedSample: SampleItem? {
        guard let id = workbenchStore.selectedSampleId else { return nil }
        return inventoryStore.samples.first { $0.id == id }
    }
}

/// Mirrors `InlineTitleIfAvailable` from `InventoryView` so the
/// workbench's nav bar uses the inline style on iOS without breaking
/// the macOS `swift test` build. Duplicated here rather than shared
/// because the inventory view's helper is file-private.
private struct InlineTitleIfAvailableWorkbench: ViewModifier {
    func body(content: Content) -> some View {
        #if os(iOS)
        content.navigationBarTitleDisplayMode(.inline)
        #else
        content
        #endif
    }
}
