// TerrainLoaderTests.swift
// SDGGameplay · World · Tests
//
// Covers the synthesisable parts of `TerrainLoader`: construction,
// missing-resource error path. Real USDZ loading requires RealityKit
// runtime (not reliable in `swift test` on macOS), so actual mesh
// loading is exercised only by the device smoke test documented in
// the PR description.

import XCTest
@testable import SDGGameplay

@MainActor
final class TerrainLoaderTests: XCTestCase {

    // MARK: - Construction

    func testInitIsSideEffectFree() {
        // If the initialiser ever starts touching the bundle or the
        // filesystem, CI on an empty test bundle would start tripping
        // over missing USDZ. This is the cheap guard against that
        // regression.
        _ = TerrainLoader(bundle: .main)
        _ = TerrainLoader(bundle: Bundle(for: type(of: self)))
    }

    // MARK: - Resource resolution

    /// Given a bundle that doesn't contain the Terrain USDZ, `load()`
    /// must throw `.resourceNotFound` with the correct basename — NOT
    /// a generic RealityKit error, NOT a crash. The RootView handler
    /// keys on this error to decide whether to fall back to the
    /// flat-ground plane.
    func testLoadThrowsResourceNotFoundForEmptyBundle() async {
        let emptyBundle = Bundle(for: type(of: self))
        let loader = TerrainLoader(bundle: emptyBundle)
        do {
            _ = try await loader.load()
            XCTFail("Expected resourceNotFound, got success")
        } catch let error as TerrainLoader.LoadError {
            switch error {
            case .resourceNotFound(let basename):
                XCTAssertEqual(basename, TerrainLoader.defaultBasename)
            case .realityKitLoadFailed:
                XCTFail("Expected resourceNotFound, got realityKitLoadFailed")
            }
        } catch {
            XCTFail("Expected TerrainLoader.LoadError, got \(type(of: error))")
        }
    }

    // MARK: - Default basename

    /// Pin the default basename so the Blender script output and the
    /// Swift loader stay in sync. If someone renames the USDZ without
    /// updating the loader (or vice versa), CI turns red here instead
    /// of silently at runtime.
    func testDefaultBasenameMatchesPipelineOutput() {
        XCTAssertEqual(
            TerrainLoader.defaultBasename,
            "Terrain_Sendai_574036_05",
            "defaultBasename must match the filename produced by Tools/plateau-pipeline/dem_to_terrain_usdz.py"
        )
    }
}
