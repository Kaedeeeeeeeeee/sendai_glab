// InventoryView.swift
// SDGUI · Inventory
//
// Full-screen "backpack" view: `NavigationStack` hosting a lazy grid
// of every `SampleItem` in `InventoryStore.samples`, with per-cell
// push-navigation into `SampleDetailView`.
//
// Presentation is the caller's responsibility (`sheet` /
// `fullScreenCover`) — see `HUDOverlay`'s `onInventoryTapped`
// closure for the wire-up pattern. This view only owns what happens
// *inside* the backpack.
//
// ADR-0001: the view reads `inventoryStore.samples` via `@Bindable`
// and fires intents through `inventoryStore.intent(...)`. It never
// mutates the store's private state directly and never reaches into
// the ECS layer.
//
// ## Empty state
// `ContentUnavailableView` (iOS 17+) is used for the empty
// backpack — consistent with the Apple-native "nothing here yet"
// affordance the player sees elsewhere in the system (e.g. empty
// Files, empty Mail). Added to the module because the ECS has no
// way to populate the grid until the drilling pipeline lands; a
// clear empty state prevents the player from wondering whether the
// view is broken on first launch.
//
// ## Navigation destination binding
// We use `navigationDestination(item:destination:)` (iOS 17+) with
// a `@State SampleItem?`. Tapping a cell sets the selection; the
// modifier push-pops the detail view. The detail view's delete
// button removes the sample from the store, which — because
// `SampleItem` is `Hashable` and equality is by stored value —
// trips the binding's equality check and pops the stack for free.

import SwiftUI
import SDGGameplay

/// Full-screen inventory grid.
///
/// The three logical states are:
///
///   * **Empty**: a `ContentUnavailableView` with a tray icon tells
///     the player to go drill.
///   * **Populated**: a 4-ish-column adaptive `LazyVGrid` (minimum
///     120 pt, maximum 160 pt — landscape iPad comfortably fits 4
///     at 120 pt, iPhone compact fits 2).
///   * **Detail**: `NavigationStack` pushes `SampleDetailView` when
///     `selectedSample` is non-nil.
///
/// - Parameters:
///   - inventoryStore: The live store owning the sample list. Held
///     by `@Bindable` so SwiftUI observes `samples` for insertions
///     and deletions from the ECS layer (`SampleCreatedEvent`).
///   - onClose: Invoked when the user taps the top-trailing close
///     button. The caller is responsible for dismissing whatever
///     container hosts this view (sheet / fullScreenCover).
public struct InventoryView: View {

    // MARK: - Dependencies

    /// Live inventory store. `@Bindable` wires up `@Observable`
    /// tracking so `samples` re-renders the grid automatically.
    @Bindable public var inventoryStore: InventoryStore

    /// Caller-supplied close handler. The view cannot dismiss itself
    /// because the container (`sheet`, `fullScreenCover`, or in the
    /// future `NavigationSplitView`) is chosen one level up.
    public let onClose: () -> Void

    // MARK: - Local state

    /// Currently-pushed sample, or `nil` when the grid is showing.
    /// Driving navigation through `navigationDestination(item:)`
    /// (rather than per-cell `NavigationLink`) keeps the grid a
    /// plain button ForEach and makes "pop after delete" automatic.
    @State private var selectedSample: SampleItem?

    /// Grid column specification. `.adaptive(min: 120, max: 160)`
    /// lets iPad landscape fit 4-5 columns and iPhone compact fit 2
    /// without hard-coding either layout. `spacing: 16` matches the
    /// outer padding for a consistent rhythm.
    private let columns = [
        GridItem(.adaptive(minimum: 120, maximum: 160), spacing: 16)
    ]

    // MARK: - Init

    /// Designated initialiser.
    ///
    /// - Parameters:
    ///   - inventoryStore: Live store, usually passed from the
    ///     parent HUD or `AppEnvironment`.
    ///   - onClose: Invoked when the close button is tapped.
    public init(
        inventoryStore: InventoryStore,
        onClose: @escaping () -> Void
    ) {
        self.inventoryStore = inventoryStore
        self.onClose = onClose
    }

    // MARK: - Body

    public var body: some View {
        NavigationStack {
            // `navigationBarTitleDisplayMode` and `.topBarTrailing` are
            // UIKit-only — they compile-fail on macOS (`swift test`
            // host). SDGUI's iOS 18 / macOS 15 package floor means we
            // have to keep both platforms green, so the
            // UIKit-specific modifiers are wrapped behind
            // `#if os(iOS)`. On macOS the toolbar falls back to
            // `.primaryAction`, which places the close button in the
            // native trailing position for window-style nav bars.
            gridScroll
                .navigationTitle(Text("inventory.title"))
                .modifier(InlineTitleIfAvailable())
                .toolbar {
                    ToolbarItem(placement: closePlacement) {
                        closeButton
                    }
                }
                .overlay {
                    if inventoryStore.samples.isEmpty {
                        emptyState
                    }
                }
                .navigationDestination(item: $selectedSample) { sample in
                    SampleDetailView(
                        sample: sample,
                        inventoryStore: inventoryStore
                    )
                }
        }
    }

    /// Toolbar placement for the close button. `.topBarTrailing` is
    /// iOS-only; macOS hosts get `.primaryAction`, which anchors the
    /// button to the trailing edge of the window toolbar.
    private var closePlacement: ToolbarItemPlacement {
        #if os(iOS)
        return .topBarTrailing
        #else
        return .primaryAction
        #endif
    }

    // MARK: - Subviews

    /// The scrollable grid body. Kept separate so the navigation
    /// modifiers above read top-to-bottom without a noisy stack of
    /// `.foo { ... }.bar { ... }` chains.
    private var gridScroll: some View {
        ScrollView {
            LazyVGrid(columns: columns, spacing: 16) {
                ForEach(inventoryStore.samples) { sample in
                    Button {
                        selectedSample = sample
                    } label: {
                        SampleGridItemView(sample: sample)
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("inventory.grid.item.\(sample.id.uuidString)")
                }
            }
            .padding()
        }
    }

    /// Top-trailing close affordance. Uses an SF Symbol so it
    /// visually matches the rest of the HUD; the accessibility
    /// label routes through the `ui.button.close` L10n key that
    /// already exists in `Localizable.xcstrings`.
    private var closeButton: some View {
        Button(action: onClose) {
            Image(systemName: "xmark.circle.fill")
        }
        .accessibilityLabel(Text("ui.button.close"))
    }

    /// Empty-inventory placeholder. `ContentUnavailableView` is the
    /// Apple-native "nothing here yet" pattern; title + icon +
    /// description all localise through the String Catalog.
    private var emptyState: some View {
        ContentUnavailableView(
            "inventory.empty.title",
            systemImage: "tray",
            description: Text("inventory.empty.description")
        )
    }
}

/// Applies `.navigationBarTitleDisplayMode(.inline)` on iOS; no-op on
/// macOS where the modifier is unavailable. Pulled out into a
/// `ViewModifier` so the call site in `InventoryView.body` stays a
/// clean chain of modifiers instead of a `#if` that splits the
/// chain across a whole `some View` build.
private struct InlineTitleIfAvailable: ViewModifier {
    func body(content: Content) -> some View {
        #if os(iOS)
        content.navigationBarTitleDisplayMode(.inline)
        #else
        content
        #endif
    }
}
