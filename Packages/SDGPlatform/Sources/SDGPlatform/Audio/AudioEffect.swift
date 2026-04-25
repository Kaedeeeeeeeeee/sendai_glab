// AudioEffect.swift
// SDGPlatform · Audio
//
// An abstract catalogue of sound-effect cues the game can play.
//
// ## Why an abstraction rather than raw filenames?
//
// Gameplay code shouldn't care whether a "drill impact" is one file or
// four variants randomly sampled — that's a resource-layout concern.
// Callers say `audioService.play(.drillImpactRandom)` and the service
// resolves to a concrete `.m4a` URL (picking a variant if appropriate).
//
// ## File / folder layout
//
// Files live under `Resources/Audio/SFX/<category>/<basename>.m4a`; see
// `Resources/Audio/README.md` for the canonical manifest. Each
// `AudioEffect` case owns:
//   - a `category` (`ui` / `drill` / `footstep` / `feedback`)
//   - one or more candidate *basenames* (filename without `.m4a`)
// Cases whose rawValue contains the `"*"` wildcard are "variant" cues
// and resolve to multiple candidates; the service picks one randomly.
//
// ## Why no Codable / GameEvent conformance?
//
// `AudioEffect` is an internal platform-layer detail. It does not cross
// the `EventBus` — only gameplay events do. The bridge maps events to
// effects inside the process.

import Foundation

/// A semantic sound-effect cue. Cases model *what* the game wants to
/// play (e.g. "a drill impact"), not *which file*. Variant cues (those
/// whose rawValue contains `"*"`) map to multiple candidate files and
/// the `AudioService` picks one at play time.
///
/// Adding a cue:
/// 1. Add the `case` with a rawValue that is either a literal basename
///    (e.g. `"UI_Tap"`) or a prefix followed by `"_*"` (e.g.
///    `"Drill_Impact_*"`) to flag it as a multi-variant cue.
/// 2. Put the cue into the right bucket in `category`.
/// 3. Extend `resolveResourceNames()` if the enumeration of variants
///    cannot be inferred from the rawValue — currently all variant
///    cues enumerate `_01`…`_04` or `_01`…`_02` based on the prefix, so
///    you only need to teach the resolver about your prefix if the
///    numbering differs.
public enum AudioEffect: String, CaseIterable, Sendable {

    // MARK: UI cues

    /// Standard button tap.
    case uiTap = "UI_Tap"
    /// Tab-bar or list-row selection.
    case uiTabSelect = "UI_TabSelect"
    /// Modal / panel opening.
    case uiOpen = "UI_Open"
    /// Modal / panel closing.
    case uiClose = "UI_Close"

    // MARK: Drill cues

    /// Short metallic scrape played when the drill head is deployed /
    /// retracted — one file, no variants.
    case drillStart = "Drill_Metal_Heavy"

    /// Drill bit impacting rock. Variant cue: resolves to one of four
    /// `Drill_Impact_01`…`_04` candidates, picked at play time.
    case drillImpactRandom = "Drill_Impact_*"

    // MARK: Footstep cues

    /// Footstep on grass. Variant cue: `Footstep_Grass_01`…`_02`.
    case footstepGrass = "Footstep_Grass_*"
    /// Footstep on concrete. Variant cue: `Footstep_Concrete_01`…`_02`.
    case footstepConcrete = "Footstep_Concrete_*"

    // MARK: Feedback cues

    /// Positive confirmation (sample secured, quest step done).
    case feedbackSuccess = "Feedback_Success"
    /// Negative feedback (drill missed all layers, invalid action).
    case feedbackFailure = "Feedback_Failure"
    /// Neutral notification (new hint, subtitle prompt).
    case feedbackNotify = "Feedback_Notify"

    // MARK: Disaster cues (Phase 8)

    /// Low-frequency rumble looped during an earthquake. MVP reuses
    /// the Drill_Metal_Heavy file as a placeholder (the same
    /// low-end content reads convincingly as ground rumble at
    /// playback levels below the drill's normal gain); Phase 8.1
    /// swaps in a bespoke earthquake SFX.
    case earthquakeRumble = "Earthquake_Rumble"

    /// Rising-water crescendo, played once per flood. MVP reuses
    /// Feedback_Notify as a placeholder; the fidelity bar is low
    /// because the visible water plane carries most of the feedback.
    case floodWater = "Flood_Water"

    /// Subdirectory under `Resources/Audio/SFX/` where this cue's
    /// candidate files live. Used by `AudioService` to build the bundle
    /// lookup key. Kept as a plain `String` (not an enum) because the
    /// on-disk directory name is the source of truth — the README
    /// contract — not a Swift construct.
    ///
    /// Delegates to the typed `categoryKind` so the mapping only lives
    /// in one place. Callers that need to discriminate without matching
    /// magic strings (e.g. `AudioService.stop(category:)`) should use
    /// `categoryKind` instead.
    public var category: String { categoryKind.rawValue }

    /// Typed sibling of `category`. Phase 8.1 added
    /// `AudioService.stop(category:)` which needs a safe, exhaustive way
    /// to bucket every cue — a plain `String` parameter risks typos
    /// silently stopping nothing. New callers should prefer this; the
    /// raw-string `category` is retained because the on-disk directory
    /// names are the README contract.
    public var categoryKind: AudioCategory {
        switch self {
        case .uiTap, .uiTabSelect, .uiOpen, .uiClose:
            return .ui
        case .drillStart, .drillImpactRandom:
            return .drill
        case .footstepGrass, .footstepConcrete:
            return .footstep
        case .feedbackSuccess, .feedbackFailure, .feedbackNotify:
            return .feedback
        case .earthquakeRumble, .floodWater:
            return .disaster
        }
    }

    /// Candidate resource basenames for this cue (no `.m4a` extension).
    ///
    /// - For single-file cues this is a 1-element array.
    /// - For variant cues (rawValue contains `"*"`), returns every
    ///   numbered sibling that is known to ship with the project. The
    ///   caller (`AudioService`) picks one uniformly at random.
    ///
    /// Why enumerate statically rather than scan the bundle at runtime?
    /// Bundle scanning forces I/O on the hot path and hides typos (a
    /// missing file silently drops from the pool). A hard-coded list
    /// makes the game fail loudly during bring-up — the right default
    /// for Phase 2 Alpha.
    public func resolveResourceNames() -> [String] {
        let raw = rawValue
        // Non-variant: raw is the single basename.
        guard raw.hasSuffix("_*") else { return [raw] }

        // Variant. Strip the trailing "_*" and substitute numbered
        // suffixes. The enumeration ranges match `Resources/Audio/README.md`.
        let prefix = String(raw.dropLast(2))
        switch self {
        case .drillImpactRandom:
            return (1...4).map { "\(prefix)_\(String(format: "%02d", $0))" }
        case .footstepGrass, .footstepConcrete:
            return (1...2).map { "\(prefix)_\(String(format: "%02d", $0))" }
        default:
            // Unknown variant prefix: return the literal prefix as a
            // best-effort fallback. We choose not to `fatalError` here
            // so a future half-landed cue doesn't take the process down.
            return [prefix]
        }
    }
}

// MARK: - AudioCategory

/// Typed bucket for `AudioEffect`. Added in Phase 8.1 so
/// `AudioService.stop(category:)` can target all cues in a bucket
/// without taking a raw `String`. The `rawValue`s match the on-disk
/// directory names (`Resources/Audio/SFX/<rawValue>/…`) so the old
/// `category: String` API keeps working unchanged.
///
/// Keeping the enum in the same file as `AudioEffect` because every
/// case line-up needs to be edited together.
public enum AudioCategory: String, CaseIterable, Sendable {
    case ui
    case drill
    case footstep
    case feedback
    case disaster
}
