// DrillingErrors.swift
// SDGGameplay · Drilling
//
// Failure cases the drilling orchestrator can surface to callers of
// `performDrill(...)`. Split into its own file at Phase 9 Part B when
// `.outOfSurveyArea` joined the existing two cases — the vocabulary is
// public API the HUD and SFX bridges branch on, so giving it an
// obvious home keeps churn localised.
//
// Historical note: the enum lived inside `DrillingSystem.swift` through
// Phases 1-8. Moving it here is a pure source split; the type's name,
// visibility, and existing cases are unchanged, so no call site
// breaks.

import Foundation

/// Failures the drilling orchestrator can surface to callers of
/// `performDrill(...)`.
///
/// Kept tiny on purpose: orchestration is a transport layer, not a
/// game-rules gate. Rules (out of battery, tool cooldown) belong in
/// `DrillingStore.intent(_:)` before the request is even fired.
///
/// ### Reason tag vocabulary
///
/// The Orchestrator stamps a short machine-readable tag onto the
/// `DrillFailed.reason` field when publishing failure events. Each
/// case below corresponds to exactly one reason tag:
///
///   | Case                 | DrillFailed.reason tag       |
///   |----------------------|------------------------------|
///   | `.noLayers`          | `"no_layers"`                |
///   | `.sceneUnavailable`  | `"scene_unavailable"`        |
///   | `.outOfSurveyArea`   | `"out_of_survey_area"`       |
///
/// Keeping this mapping visible on the enum (rather than scattered
/// across publish call-sites) makes it cheap for HUD and analytics
/// subscribers to branch on the reason.
public enum DrillError: Error, Sendable, Equatable {

    /// No layer intersected the drill ray. The drill physically
    /// reached something — a scene was available — but the target
    /// point was open air / off the outcrop.
    case noLayers

    /// The orchestrator has no world to read from. Either the
    /// `outcropRootProvider` closure returned `nil` (scene not yet
    /// loaded / already torn down) or the tree under the returned
    /// root carried no geology entities at all.
    case sceneUnavailable

    /// Phase 9 Part B: the drill origin was outside every known
    /// survey region. The orchestrator had a working scene *and* a
    /// `GeologyRegionRegistry`, but no region's XZ footprint contained
    /// the drill origin — the player is drilling in the ocean / off the
    /// PLATEAU corridor.
    ///
    /// HUD code typically maps this to a localised
    /// `"drill.error.outOfSurveyArea"` toast so the player gets a
    /// self-explanatory message instead of a silent no-op.
    case outOfSurveyArea

    /// Short machine-readable tag written into `DrillFailed.reason`.
    /// Centralised here so producers and consumers agree on the
    /// vocabulary without a literal-string dance.
    public var reasonTag: String {
        switch self {
        case .noLayers:         return "no_layers"
        case .sceneUnavailable: return "scene_unavailable"
        case .outOfSurveyArea:  return "out_of_survey_area"
        }
    }
}
