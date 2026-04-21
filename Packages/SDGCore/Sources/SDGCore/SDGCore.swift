// SDGCore.swift
// SDGCore — foundation layer for SDG-Lab.
//
// Public API lives in the sibling files: `EventBus/`, `Store/`, `DI/`,
// `L10n/`. This file is intentionally tiny; it only carries the module
// version tag so downstream packages can verify they linked a matching
// build of SDGCore.
//
// SDGCore MUST NOT `import SwiftUI` or `import RealityKit`. This lets
// the entire foundation be tested on macOS CLI (no simulator required)
// and keeps the three-layer architecture honest; see
// Docs/ArchitectureDecisions/0001-layered-architecture.md.

import Foundation

/// Compile-time metadata for the SDGCore module.
public enum SDGCoreModule {
    /// Semantic version of the SDGCore API surface. Bump on every public
    /// API change so downstream layers can assert compatibility.
    public static let version = "0.1.0"
}
