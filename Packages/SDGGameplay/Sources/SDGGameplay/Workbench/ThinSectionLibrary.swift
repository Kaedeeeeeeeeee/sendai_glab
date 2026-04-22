// ThinSectionLibrary.swift
// SDGGameplay · Workbench
//
// Loads and caches the `layerId → [ThinSectionPhoto]` mapping used by
// the microscope UI. The mapping is encoded in
// `Resources/Geology/thin_section_index.json`, shipped in the main app
// bundle.
//
// ## Placeholder strategy (Phase 2 Beta)
//
// f.shera's research lab has real thin-section photos but they're not
// yet integrated into the project. Rather than ship 3-5 MB of
// public-domain placeholder images that would be swapped out within a
// few weeks, this module emits `ThinSectionPhoto` records whose `id`
// references a *symbolic* key — never a file on disk. The UI layer
// (`PlaceholderThinSectionView`) renders a fully procedural SwiftUI
// placeholder for any record it encounters, so the app ships
// zero-binary for thin sections in Phase 2 Beta.
//
// When real photos land in Phase 3, this module gets an optional
// second code path: an image file matching `photo.id` in
// `Resources/Geology/ThinSections/` is preferred, otherwise the
// procedural placeholder remains the fallback. No call-site changes
// required.
//
// ## ADR-0001 compliance
//
// - Pure data module. No SwiftUI / RealityKit imports.
// - No singleton (`Self.shared`). The tiny cache is keyed by bundle
//   identity so tests on alternate bundles observe independent state.
// - `@MainActor` isolation on the cache read mirrors the rest of the
//   Gameplay stores — the microscope UI reads the library during a
//   SwiftUI redraw (main thread), and actor isolation is free.

import Foundation

/// One thin-section photograph record, as described in
/// `thin_section_index.json`. Pure value type, `Codable` for easy JSON
/// decoding and event-log replay.
///
/// ### Stability
/// `id` is a stable, translation-free identifier used both as the
/// dictionary key inside `thin_section_index.json` and as a lookup
/// key the UI maps to a real image file (once Phase 3 bindings land).
/// Do not change an `id` casually — downstream quest completion /
/// encyclopedia progress may persist references to it.
public struct ThinSectionPhoto: Codable, Sendable, Identifiable, Hashable {

    /// Stable identifier for the photo. Also serves as the basename
    /// of any real image resource that ships later.
    public let id: String

    /// Localization key for the human-readable caption displayed under
    /// the photo in the microscope UI (AGENTS.md §5).
    public let captionKey: String

    /// Optional localization key describing the source / credit of the
    /// photo. `nil` in Phase 2 Beta because every record is a
    /// procedural placeholder.
    public let creditKey: String?

    public init(
        id: String,
        captionKey: String,
        creditKey: String? = nil
    ) {
        self.id = id
        self.captionKey = captionKey
        self.creditKey = creditKey
    }
}

/// On-disk shape of the thin-section index JSON. Private — callers
/// consume the parsed `[layerId: [ThinSectionPhoto]]` map via
/// ``ThinSectionLibrary/photos(forLayerId:in:)``.
private struct ThinSectionIndexFile: Codable {
    let version: String
    let mapping: [String: [ThinSectionPhoto]]
}

/// Namespace for thin-section photo lookup.
///
/// The library caches parsed indices by bundle identity so that tests
/// loading the bundled fixture JSON pay the decode cost once; the main
/// app shares a single cache entry for `Bundle.main`.
public enum ThinSectionLibrary {

    /// Fallback record returned when no mapping exists for a given
    /// `layerId`. The UI is expected to render this through
    /// `PlaceholderThinSectionView` (or a future real-image viewer
    /// once Phase 3 adds one) — i.e. the player always sees *something*,
    /// never a blank viewport.
    public static let fallback = ThinSectionPhoto(
        id: "placeholder_generic",
        captionKey: "thinsection.placeholder.generic.caption",
        creditKey: nil
    )

    /// Look up every thin-section photo registered for `layerId`.
    ///
    /// - Parameters:
    ///   - layerId: Stable layer id (matches `SampleLayerRecord.layerId`
    ///     / `GeologyLayerComponent.layerId`).
    ///   - bundle: The bundle that contains `thin_section_index.json`.
    ///     Defaults to `.main` for the app; tests inject the test
    ///     bundle (`Bundle.module` of `SDGGameplayTests`).
    /// - Returns: The registered photos in declaration order. Empty if
    ///   the layer is unmapped (callers typically fall back to
    ///   ``fallback``).
    @MainActor
    public static func photos(
        forLayerId layerId: String,
        in bundle: Bundle = .main
    ) -> [ThinSectionPhoto] {
        let index = loadIndex(from: bundle)
        return index[layerId] ?? []
    }

    /// Force a cache rebuild. Exists so tests that mutate the bundle
    /// during a run (rare — we currently don't) can observe a fresh
    /// parse. Production callers never need this.
    @MainActor
    public static func resetCacheForTesting() {
        cache.removeAll()
    }

    // MARK: - Private cache

    /// Parsed index keyed by bundle identity. Swift's `ObjectIdentifier`
    /// fits `Bundle` (reference type) and is cheap to hash.
    @MainActor
    private static var cache: [ObjectIdentifier: [String: [ThinSectionPhoto]]] = [:]

    /// Decode (or return cached) mapping for `bundle`. Returns an empty
    /// dictionary on any error — a missing / malformed index file
    /// degrades gracefully to "every layer shows the fallback" rather
    /// than crashing the workbench. The deliberate swallow mirrors
    /// `InventoryStore.persistIgnoringFailure()`'s philosophy.
    @MainActor
    private static func loadIndex(from bundle: Bundle) -> [String: [ThinSectionPhoto]] {
        let key = ObjectIdentifier(bundle)
        if let cached = cache[key] { return cached }

        guard let url = bundle.url(
            forResource: "thin_section_index",
            withExtension: "json"
        ) else {
            // No index file in this bundle — treat as empty mapping.
            // Phase 3 app bundles will include it via project.yml;
            // tests that need coverage inject a fixture.
            cache[key] = [:]
            return [:]
        }

        do {
            let data = try Data(contentsOf: url)
            let decoded = try JSONDecoder().decode(
                ThinSectionIndexFile.self, from: data
            )
            cache[key] = decoded.mapping
            return decoded.mapping
        } catch {
            cache[key] = [:]
            return [:]
        }
    }
}
