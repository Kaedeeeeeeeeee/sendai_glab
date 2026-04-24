// StoryLoader.swift
// SDGGameplay · Dialogue
//
// Locates `questN.M.json` files inside a `Bundle` and decodes them
// into `StorySequence` values. Ports Unity
// `StorySystem/StorySequenceLoader.cs::LoadFromResources` to Swift.
//
// Unlike the Unity version, we do not log warnings to stdout —
// failures come back as typed `StoryLoaderError` throws so the caller
// decides whether to log, fall back, or bubble.
//
// ### Bundle resolution
// - Production uses `Bundle.main` (the JSONs ship at the root of the
//   `.app` bundle via `project.yml`'s `Resources/Story/*.json`).
// - Tests use `Bundle.module` (SPM copies them into the test target
//   via the Resources declaration in `Package.swift`).
// - The caller decides — `StoryLoader` does not know about either
//   mechanism, matching `GeologySceneBuilder.loadOutcrop(...)`'s
//   pattern.

import Foundation

/// Typed error for `StoryLoader`. Each case corresponds to one
/// failure mode the caller can discriminate on.
public enum StoryLoaderError: Error, Equatable {

    /// The bundle does not contain a `<basename>.json` resource.
    case resourceNotFound(basename: String)

    /// The file was found but could not be read (I/O failure, not a
    /// JSON parse issue).
    case cannotReadFile(basename: String, underlying: String)

    /// The JSON parsed but did not conform to the `StorySequence`
    /// schema.
    case malformedJSON(basename: String, underlying: String)
}

/// Loads `StorySequence` definitions from a `Bundle`.
///
/// This is a stateless façade — no instance variables — so callers
/// can invoke it directly without threading a `StoryLoader` through
/// dependency injection.
public enum StoryLoader {

    /// Load a sequence by its basename (e.g. `"quest1.1"`).
    ///
    /// - Parameters:
    ///   - basename: Filename without `.json`.
    ///   - bundle: Bundle to search. Use `.main` in production and
    ///     `.module` in tests (where SPM ships the fixtures).
    /// - Throws: `StoryLoaderError` — see the enum's docs.
    /// - Returns: The parsed sequence, with `id` set to `basename`.
    public static func load(
        basename: String,
        in bundle: Bundle = .main
    ) throws -> StorySequence {
        guard let url = bundle.url(forResource: basename, withExtension: "json") else {
            throw StoryLoaderError.resourceNotFound(basename: basename)
        }
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            throw StoryLoaderError.cannotReadFile(
                basename: basename,
                underlying: String(describing: error)
            )
        }
        do {
            let decoded = try JSONDecoder().decode(StorySequence.self, from: data)
            return decoded.withId(basename)
        } catch {
            throw StoryLoaderError.malformedJSON(
                basename: basename,
                underlying: String(describing: error)
            )
        }
    }

    /// Convenience: basenames of every quest script shipped by
    /// Phase 2 Beta. Keeps the test and the runtime catalog in sync.
    ///
    /// Order matches narrative progression, mirroring the JSON file
    /// naming scheme `questCHAPTER.PART.json`.
    public static let shippedBasenames: [String] = [
        // Phase 9 Part B: quest1.3 (青葉山採集) + quest1.4 (川内採集)
        // added alongside the existing chapter-1 laboratory intros.
        // The task spec originally wanted these under the names
        // `quest1.2` / `quest1.3` but `quest1.2.json` was already
        // shipped in Phase 2 Beta with different content; the new
        // sampling scenes take 1.3 / 1.4 to preserve backwards
        // compatibility. See Docs/Phase9Integration/B.md.
        "quest1.1", "quest1.2", "quest1.3", "quest1.4",
        "quest2.1",
        "quest3.1", "quest3.2", "quest3.3", "quest3.4",
        "quest4.1", "quest4.2", "quest4.3", "quest4.4",
        "quest5.1", "quest5.2",
        "quest6.1"
    ]
}
