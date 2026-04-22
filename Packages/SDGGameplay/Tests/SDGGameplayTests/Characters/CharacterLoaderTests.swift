// CharacterLoaderTests.swift
// Lightweight tests for `CharacterLoader`. The heavy work the loader
// does — USDZ parse, RealityKit geometry — cannot be exercised in the
// test bundle because we deliberately do not ship the 22 MB of Meshy
// assets into `Tests/SDGGameplayTests/Resources/`. We therefore cover
// the parts that are bundle-independent:
//
//   * Missing-asset path surfaces `.usdzNotFound` with the right
//     basename, for every role.
//   * `LoaderError` values compare correctly (Equatable contract).
//   * Camera height used by the attachment step lines up with the
//     role's declared value.
//
// Integration coverage (real USDZ round-trip) is the job of a future
// device-test target; see Phase 3 roadmap.

import XCTest
import RealityKit
@testable import SDGGameplay

@MainActor
final class CharacterLoaderTests: XCTestCase {

    // MARK: - Fixtures

    /// Bundle that definitely does not contain any
    /// `Character_*.usdz`. `Bundle.module` for the test target is
    /// the natural pick — it only ships `test_outcrop.json`. If anyone
    /// later adds character fixtures for an integration test they'll
    /// need to flip this to a throwaway bundle.
    private func makeAssetFreeBundle() -> Bundle {
        .module
    }

    // MARK: - Missing asset

    /// Each role's missing-asset load raises `.usdzNotFound` with the
    /// role's basename, preserving the diagnostic for callers.
    func testLoadAsPlayerThrowsUsdzNotFoundWhenBundleMissesAsset() async {
        let loader = CharacterLoader(bundle: makeAssetFreeBundle())
        for role in CharacterRole.allCases {
            do {
                _ = try await loader.loadAsPlayer(role)
                XCTFail("Expected usdzNotFound for \(role); got success")
            } catch let error as CharacterLoader.LoaderError {
                XCTAssertEqual(
                    error,
                    .usdzNotFound(basename: role.resourceBasename),
                    "Wrong LoaderError for \(role)"
                )
            } catch {
                XCTFail("Unexpected error type for \(role): \(error)")
            }
        }
    }

    /// NPC path uses the same resolver so missing-asset behaviour
    /// matches. Keeping the assertion separate catches drift if
    /// `loadAsNPC` ever gets its own URL lookup.
    func testLoadAsNPCThrowsUsdzNotFoundWhenBundleMissesAsset() async {
        let loader = CharacterLoader(bundle: makeAssetFreeBundle())
        do {
            _ = try await loader.loadAsNPC(.kaede)
            XCTFail("Expected usdzNotFound")
        } catch let error as CharacterLoader.LoaderError {
            XCTAssertEqual(error, .usdzNotFound(basename: "Character_Kaede"))
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    // MARK: - LoaderError equality

    /// `Equatable` conformance on the error is load-bearing for the
    /// tests above; pin it so a future refactor doesn't silently
    /// weaken equality to reference identity.
    func testLoaderErrorEquality() {
        XCTAssertEqual(
            CharacterLoader.LoaderError.usdzNotFound(basename: "X"),
            CharacterLoader.LoaderError.usdzNotFound(basename: "X")
        )
        XCTAssertNotEqual(
            CharacterLoader.LoaderError.usdzNotFound(basename: "X"),
            CharacterLoader.LoaderError.usdzNotFound(basename: "Y")
        )
        XCTAssertEqual(
            CharacterLoader.LoaderError.underlying(description: "boom"),
            CharacterLoader.LoaderError.underlying(description: "boom")
        )
        XCTAssertNotEqual(
            CharacterLoader.LoaderError.usdzNotFound(basename: "X"),
            CharacterLoader.LoaderError.underlying(description: "X")
        )
    }

    // MARK: - Camera height sanity

    /// The loader's rig step reads `role.cameraHeight` directly. We
    /// can't exercise the attach path without a real entity, but we
    /// can at least pin the contract the rig step depends on: the
    /// height is positive and finite.
    func testRoleCameraHeightIsUsable() {
        for role in CharacterRole.allCases where role.isPlayable {
            let height = role.cameraHeight
            XCTAssertTrue(height.isFinite)
            XCTAssertGreaterThan(height, 0)
        }
    }

    // MARK: - Init

    /// Default-init picks `.main`; tests should never rely on that in
    /// CI since the test binary bundle is not the app bundle. Verify
    /// the init at least doesn't crash.
    func testDefaultInitDoesNotCrash() {
        _ = CharacterLoader()
    }
}
