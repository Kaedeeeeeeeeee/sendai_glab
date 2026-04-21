// SDGGameplay — Stores, Events, ECS systems.
// Phase 1 POC introduces the first concrete submodule: Geology
// (procedural geological scene + ECS component). See
// `Geology/GeologySceneBuilder.swift`.
import SDGCore

/// Compile-time metadata for the SDGGameplay module.
///
/// `coreVersion` is read from `SDGCoreModule` at build time; mismatches
/// surface in `SDGGameplayTests.testGameplayLinksCore` so we can't link
/// against a stale SDGCore by accident.
public enum SDGGameplayModule {
    /// Semantic version of the SDGGameplay API surface. Bump on every
    /// public API change that downstream layers might depend on.
    public static let version = "0.1.0"

    /// The `SDGCoreModule.version` resolved at link time. Used by tests
    /// to detect a stale-core / stale-gameplay pairing in the package graph.
    public static let coreVersion = SDGCoreModule.version
}
