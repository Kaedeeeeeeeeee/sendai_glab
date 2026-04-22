// SampleDetailView.swift
// SDGUI · Inventory
//
// Full-screen detail page for a single `SampleItem`. Pushed onto the
// `InventoryView`'s `NavigationStack` when a grid cell is tapped.
//
// Layout (SwiftUI `Form`):
//   Section 1  — large sample icon (centered)
//   Section 2  — layers list (one `LayerRowView` per record)
//   Section 3  — metadata (drill depth, collection time)
//   Section 4  — custom note editor (multi-line `TextField`)
//   Section 5  — destructive delete button
//
// Why `Form` and not a hand-rolled `ScrollView { VStack { ... } }`:
//   * Automatic section grouping, insets, and separators for free.
//   * `LabeledContent` renders like a native settings row.
//   * Works identically on iPad / iPhone / macOS, which matters for
//     CI (`swift test` runs on macOS) and Phase 3 iPhone compact
//     layout.
//
// ADR-0001 compliance:
//   * View only reads `inventoryStore` state (via `@Bindable`) and
//     sends `Intent`s through `inventoryStore.intent(...)` inside
//     `Task { @MainActor in ... }` wrappers.
//   * No `EventBus.publish` here — the Store owns that.

import SwiftUI
import SDGGameplay

/// Full-screen `NavigationStack` destination for a single sample.
///
/// Hosts the icon, per-layer breakdown, metadata, and a note editor.
/// Calling `.intent(.delete(sample.id))` from the destructive button
/// removes the sample from the store; SwiftUI's
/// `navigationDestination(item:)` observes the bound `SampleItem?`
/// in the parent, so as soon as the sample disappears from
/// `inventoryStore.samples` the parent flips the selection to `nil`
/// and the stack pops automatically.
public struct SampleDetailView: View {

    /// The sample being inspected. Captured by value at push time —
    /// the grid never mutates a sample's `id` / `layers` / `createdAt`
    /// after creation, so this snapshot stays in sync with the store
    /// for the lifetime of the view.
    public let sample: SampleItem

    /// The live inventory store. `@Bindable` so the delete button's
    /// `.intent(.delete(...))` call reaches the observable state.
    @Bindable public var inventoryStore: InventoryStore

    /// SwiftUI dismiss action. Used after `.delete` to pop this view
    /// back to the inventory grid explicitly — the parent's
    /// `navigationDestination(item:)` does NOT auto-fire because the
    /// selection binding is a snapshot `SampleItem`, not a reference
    /// into `inventoryStore.samples`.
    @Environment(\.dismiss) private var dismiss

    /// Local draft for the note editor. Seeded from
    /// `sample.customNote ?? ""` in `init` and pushed back into the
    /// store on every change. Keeping it in `@State` (rather than
    /// binding straight to the store) lets the user type without
    /// paying for a Store round-trip on every keystroke *and* keeps
    /// the editor responsive if the store's persistence layer is
    /// slow.
    @State private var noteDraft: String

    /// Designated initialiser.
    ///
    /// - Parameters:
    ///   - sample: The sample to display.
    ///   - inventoryStore: The live store that owns `sample`.
    public init(sample: SampleItem, inventoryStore: InventoryStore) {
        self.sample = sample
        self.inventoryStore = inventoryStore
        self._noteDraft = State(initialValue: sample.customNote ?? "")
    }

    public var body: some View {
        Form {
            iconSection
            layersSection
            metadataSection
            noteSection
            deleteSection
        }
        .navigationTitle(Text(verbatim: titleText))
    }

    // MARK: - Sections

    /// Big centred thumbnail. `maxWidth: 200` keeps it readable on
    /// iPhone compact and doesn't dominate on iPad.
    private var iconSection: some View {
        Section {
            SampleIconView(sample: sample)
                .frame(maxWidth: 200, maxHeight: 200)
                .frame(maxWidth: .infinity, alignment: .center)
        }
    }

    /// Layer breakdown. Identified by `\.offset` because a single
    /// sample can legitimately contain two records with the same
    /// `layerId` (e.g. a repeat unit) and `id: \.offset` keeps
    /// SwiftUI's `ForEach` stable anyway — the sample is immutable
    /// for the lifetime of this view.
    private var layersSection: some View {
        Section(header: Text("sample.detail.layers")) {
            ForEach(Array(sample.layers.enumerated()), id: \.offset) { index, layer in
                LayerRowView(layer: layer, index: index)
            }
        }
    }

    /// Drill depth + timestamp. `LabeledContent` gives the native
    /// settings-row look: localized label on the leading edge,
    /// secondary-coloured value trailing.
    private var metadataSection: some View {
        Section(header: Text("sample.detail.metadata")) {
            LabeledContent {
                Text(verbatim: String(format: "%.2f m", sample.drillDepth))
            } label: {
                Text("sample.detail.drillDepth")
            }

            LabeledContent {
                Text(verbatim: sample.createdAt.formatted(
                    date: .abbreviated,
                    time: .shortened
                ))
            } label: {
                Text("sample.detail.createdAt")
            }
        }
    }

    /// Multi-line note editor. `axis: .vertical` + `lineLimit(3...6)`
    /// lets the field grow with the player's note but caps at 6 lines
    /// before scrolling kicks in, matching the rest of the Form's
    /// density.
    ///
    /// The `.onChange` handler debounces nothing on purpose — the
    /// store's `.updateNote` intent is idempotent and its persistence
    /// is best-effort. If note saving becomes hot enough to matter,
    /// add a debounce here rather than in the store.
    private var noteSection: some View {
        Section(header: Text("sample.detail.note")) {
            TextField(
                "sample.detail.notePlaceholder",
                text: $noteDraft,
                axis: .vertical
            )
            .lineLimit(3...6)
            .onChange(of: noteDraft) { _, newValue in
                let store = inventoryStore
                let id = sample.id
                let normalised: String? = newValue.isEmpty ? nil : newValue
                Task { @MainActor in
                    await store.intent(.updateNote(id, normalised))
                }
            }
        }
    }

    /// Destructive delete row. Dismisses itself explicitly after the
    /// store handles `.delete` — the parent's
    /// `navigationDestination(item:)` selection binding holds a
    /// snapshot `SampleItem`, so it does not auto-nil when the sample
    /// leaves `inventoryStore.samples`. Calling `dismiss()` here gives
    /// an unambiguous "confirm delete → return to grid" UX.
    private var deleteSection: some View {
        Section {
            Button(role: .destructive) {
                let store = inventoryStore
                let id = sample.id
                // Pop back to the grid first so the user sees the
                // remove happen on a page transition, then let the
                // store's async intent propagate.
                dismiss()
                Task { @MainActor in
                    await store.intent(.delete(id))
                }
            } label: {
                Text("sample.detail.delete")
            }
        }
    }

    // MARK: - Derived

    /// Title for the nav bar. Uses the top layer's `nameKey` when
    /// available; falls back to the default sample key otherwise.
    /// Rendered `verbatim` for the same reason the grid item does —
    /// runtime resolution is deferred to the Phase 2 L10n pass (see
    /// `SampleGridItemView` header).
    private var titleText: String {
        sample.layers.first?.nameKey ?? "sample.detail.defaultTitle"
    }
}
