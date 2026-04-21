// GameEvent.swift
// SDGCore
//
// All cross-layer events in SDG-Lab flow through the EventBus and MUST
// conform to this protocol. See Docs/ArchitectureDecisions/0001-layered-architecture.md.

import Foundation

/// The base protocol for every event that flows across SDG-Lab's three layers
/// (View / Store / ECS).
///
/// `Sendable` is required because events cross actor boundaries (the `EventBus`
/// is an actor, and handlers may run on `MainActor`). `Codable` is required so
/// event streams can be dumped to disk for debug replay without extra
/// serialization plumbing — an explicit goal of ADR-0001.
///
/// Conformers should be small value types (`struct`). Do not attach references
/// to live gameplay objects (Entities, Stores); include only plain data.
public protocol GameEvent: Sendable, Codable {}
