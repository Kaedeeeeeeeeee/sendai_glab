// CharacterRole.swift
// SDGGameplay · Characters
//
// Enumerates the five Phase 2 starter characters produced by the
// Meshy.ai text-to-3d pass (see Docs/MeshyGenerationLog.md). Values
// map 1:1 to the USDZ basenames under `Resources/Characters/` so any
// lookup needed by the loader is a straight `rawValue` read — no
// parallel string tables to keep in sync.
//
// Phase 3 美術 will likely replace or extend this enum with proper
// rigged / animated variants. Until then, the placeholder assets back
// every case.

import Foundation

/// One of the five Phase 2 placeholder characters.
///
/// Each case's `rawValue` matches the on-disk USDZ basename exactly
/// (see `resourceBasename`); the `CaseIterable` conformance is
/// intentional so scripted content audits can walk the full roster
/// without repeating the list.
///
/// `Sendable` because roles flow through the `EventBus` actor (Phase 3
/// dialogue / quest events will carry a role) and across MainActor
/// boundaries from the loader.
public enum CharacterRole: String, CaseIterable, Sendable {

    /// Male middle-school protagonist. Default `Self.defaultPlayer`.
    case playerMale = "Character_Player_Male"

    /// Female middle-school protagonist, selectable from the (unbuilt)
    /// main menu.
    case playerFemale = "Character_Player_Female"

    /// Dr. Kaede — G-Lab 地质灾害予测班 researcher, main teaching NPC.
    case kaede = "Character_Kaede"

    /// Field-trip 引率 teacher. Opens the prologue.
    case teacher = "Character_Teacher"

    /// G-Lab 通信担当. Appears mid-to-late in the main story arc.
    case researcherA = "Character_ResearcherA"

    /// On-disk USDZ basename (no extension). The loader appends
    /// `.usdz` when it resolves the bundle URL. Aliased through
    /// `rawValue` so renaming the enum case forces a rename of the
    /// on-disk asset too — that's the right direction of coupling.
    public var resourceBasename: String { rawValue }

    /// Localization key for the human-facing display name. Three-locale
    /// strings live in `Resources/Localization/Localizable.xcstrings`
    /// under these keys (AGENTS.md §5: UI text is never hardcoded).
    public var nameKey: String {
        switch self {
        case .playerMale:   return "character.playerMale.name"
        case .playerFemale: return "character.playerFemale.name"
        case .kaede:        return "character.kaede.name"
        case .teacher:      return "character.teacher.name"
        case .researcherA:  return "character.researcherA.name"
        }
    }

    /// Whether this role is player-controllable. The loader uses this
    /// to decide whether to attach `PlayerComponent` +
    /// `PlayerInputComponent` + a head-height camera.
    public var isPlayable: Bool {
        self == .playerMale || self == .playerFemale
    }

    /// Camera / head height for the first-person rig, in metres.
    ///
    /// Phase 2 Alpha uses a fixed 1.5 m for every playable role — the
    /// Meshy preview models are roughly that tall once normalised (see
    /// `CharacterLoader`'s scale pass). Phase 3 美術 with proper rigs
    /// will read a named `head` bone transform instead and this
    /// property can go away.
    public var cameraHeight: Float { 1.5 }

    /// Default role when the player hasn't picked one (no main menu
    /// yet in Phase 2 Alpha — see GDD §4.3 roadmap).
    public static let defaultPlayer: CharacterRole = .playerMale
}
