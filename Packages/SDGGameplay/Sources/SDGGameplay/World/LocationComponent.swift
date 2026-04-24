// LocationComponent.swift
// SDGGameplay · World
//
// Phase 9 Part F — Interior scene MVP.
//
// Marker `Component` that records whether the tagged entity is currently
// "outdoors" (on the PLATEAU corridor) or "indoors" (inside a procedural
// interior room). Exactly one player entity carries this component at a
// time; its value gates a small amount of per-frame behaviour, most
// visibly `PlayerControlSystem.snapToGround` which skips the DEM sample
// when the player is inside.
//
// ## Why a component (and not a Store flag)
//
// Per ADR-0001, Systems can read Components cheaply every frame but
// must not reach for Stores (`SDGCore` Store protocol lives behind
// event/intent boundaries). The ground-follow branch needs the current
// location *every frame* and cannot afford an async Store round-trip —
// so the player's location is mirrored into a Component by the same
// bootstrap that drives the SceneTransitionStore, and Systems read the
// Component directly.
//
// `LocationKind` is deliberately a public top-level enum (rather than
// nested inside the component) because `SceneTransitionStore` and the
// portal `LocationTransitionComponent` both use it to describe scenes
// in a uniform way. Keeping one source of truth avoids the "two kinds
// of outdoor" bug that would arise if each declared its own enum.

import Foundation
import RealityKit

/// The two logical scenes a player can inhabit in Phase 9 Part F.
///
/// MVP contract:
/// * `.outdoor` — the PLATEAU corridor loaded by `PlateauEnvironmentLoader`.
/// * `.indoor(sceneId: String)` — one of the procedurally built interior
///   rooms produced by `InteriorSceneBuilder`. The `sceneId` is a plain
///   string rather than an enum case so future interior scenes can be
///   added without touching this type; the MVP ships a single
///   `"lab"` scene.
///
/// `Codable` so we can persist the player's current location across
/// launches later (not wired in this MVP — scene state resets each
/// session — but the contract is future-proofed at zero cost).
///
/// `Equatable` for state-transition guards (`if currentLocation ==
/// target { skip }`) and for test assertions.
///
/// `Sendable` because the Store holding this value is `@MainActor`-
/// isolated but event payloads carrying the kind cross actor boundaries
/// via the `EventBus` (`GameEvent` requires `Sendable`).
public enum LocationKind: Sendable, Equatable, Codable {
    case outdoor
    case indoor(sceneId: String)
}

/// ECS component that tags an entity with its current `LocationKind`.
///
/// The component lives on the **player** entity only for the MVP; we
/// could extend it to NPCs or props later but nothing in the current
/// scope needs that, and AGENTS.md §5 ("dead code is deleted") argues
/// against extending the surface speculatively.
///
/// Rebuilt (not mutated in place) whenever the player crosses a portal:
/// `entity.components.set(LocationComponent(newKind))`. The swap is
/// cheap — the struct is trivially copyable — and eliminates any
/// partial-update race between the transition handler and any System
/// reading the component on the same frame.
public struct LocationComponent: Component, Sendable, Equatable, Codable {

    /// The player's current scene.
    public var kind: LocationKind

    public init(_ kind: LocationKind) {
        self.kind = kind
    }
}
