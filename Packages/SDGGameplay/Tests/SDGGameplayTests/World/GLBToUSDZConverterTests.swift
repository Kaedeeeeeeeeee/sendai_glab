// GLBToUSDZConverterTests.swift
// SDGGameplay · World · Tests
//
// Tests for the bundle-lookup / cache / format-negotiation bits of
// `GLBToUSDZConverter`. We deliberately do *not* invoke a real
// ModelIO convert pass in CI:
//
//   1. `swift test` runs host-side (macOS); ModelIO on the host
//      cannot import GLB (runtime-verified 2026-04-22). The test
//      would always hit the `.importerUnavailableForGLB` branch.
//   2. The PLATEAU tiles live under `Resources/Environment/` in the
//      *app* target — they're not copied into the SDGGameplayTests
//      bundle, and embedding them would bloat `swift test` cycles
//      for zero payoff.
//
// Instead, the tests pin the pure-function behaviour: cache URL
// construction, export-extension negotiation, error surfacing when
// the bundle is empty, and SHA-256 correctness.

import XCTest
@testable import SDGGameplay

final class GLBToUSDZConverterTests: XCTestCase {

    // MARK: - sourceNotFound surfacing

    /// If neither a USDZ nor a GLB exists in the given bundle, the
    /// converter must surface `.sourceNotFound` — not a nil, not a
    /// crash, not a file-system error.
    ///
    /// `Bundle.module` is the test bundle; it ships `test_outcrop.json`
    /// but no tile assets.
    func testMissingSourceThrowsSourceNotFound() async {
        do {
            _ = try await GLBToUSDZConverter.convertIfNeeded(
                bundle: .module,
                glbBasename: "Environment_Sendai_DoesNotExist"
            )
            XCTFail("expected throw")
        } catch let error as GLBToUSDZConverter.ConverterError {
            guard case .sourceNotFound(let basename) = error else {
                return XCTFail("wrong case: \(error)")
            }
            XCTAssertEqual(basename, "Environment_Sendai_DoesNotExist")
        } catch {
            XCTFail("unexpected error type: \(error)")
        }
    }

    // MARK: - Cache directory

    /// Cache directory must resolve and be creatable. We don't care
    /// where it ends up (Application Support path varies by OS and
    /// test runner sandbox), only that it exists after one call.
    func testCacheDirectoryIsAccessible() throws {
        let dir = try GLBToUSDZConverter.cacheDirectory
        var isDir: ObjCBool = false
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: dir.path,
                isDirectory: &isDir
            )
        )
        XCTAssertTrue(isDir.boolValue)
        // Path should end in our sub-tree name so we don't pollute a
        // shared Application Support root.
        XCTAssertTrue(
            dir.pathComponents.contains("sdg-lab"),
            "cache dir \(dir.path) isn't namespaced"
        )
        XCTAssertTrue(
            dir.pathComponents.contains("env-cache"),
            "cache dir \(dir.path) isn't namespaced"
        )
    }

    /// Calling twice returns the same path — we cache inside the
    /// function body via `FileManager.url(for:...)`, but the guarantee
    /// callers care about is "same directory every time".
    func testCacheDirectoryIsStableAcrossCalls() throws {
        let a = try GLBToUSDZConverter.cacheDirectory
        let b = try GLBToUSDZConverter.cacheDirectory
        XCTAssertEqual(a, b)
    }

    // MARK: - Export extension negotiation

    /// The preferred export extension must be either `usdz` (if this
    /// OS's ModelIO can write it) or `usdc` (the fallback RealityKit
    /// can read just fine). Anything else means the negotiation is
    /// broken.
    func testPreferredExportExtensionIsUsdzOrUsdc() {
        let ext = GLBToUSDZConverter.preferredExportExtension()
        XCTAssertTrue(
            ext == "usdz" || ext == "usdc",
            "unexpected export extension: \(ext)"
        )
    }

    // MARK: - Target URL shape

    /// `targetURL(for:hash:)` must produce a file inside the cache
    /// directory whose basename is `{basename}.{hash}.{ext}`. This is
    /// what lets `pruneOldCacheEntries` key on the `{basename}.`
    /// prefix when sweeping stale hashes.
    func testTargetURLNaming() throws {
        let url = try GLBToUSDZConverter.targetURL(
            for: "Environment_Sendai_57403617",
            hash: "deadbeef"
        )
        let expectedExt = GLBToUSDZConverter.preferredExportExtension()
        XCTAssertEqual(url.pathExtension, expectedExt)

        // Drop the extension and the hash to recover the basename;
        // we don't want a rigid `contains` test that admits lucky
        // false positives.
        let lastComponent = url.lastPathComponent
        XCTAssertTrue(
            lastComponent.hasPrefix("Environment_Sendai_57403617."),
            "unexpected name: \(lastComponent)"
        )
        XCTAssertTrue(
            lastComponent.contains("deadbeef"),
            "hash missing from \(lastComponent)"
        )
    }

    // MARK: - SHA-256

    /// `sha256Hex(of:)` must produce the known digest for a known
    /// payload. Pins CryptoKit's output format (lowercase hex) so a
    /// platform change wouldn't silently invalidate every cached
    /// tile by flipping case.
    func testSha256OfKnownPayload() throws {
        let payload = "sdg-lab\n"
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "GLBToUSDZConverterTests_\(UUID().uuidString).bin"
            )
        let bytes = try XCTUnwrap(payload.data(using: .utf8))
        try bytes.write(to: tmp)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let hex = try GLBToUSDZConverter.sha256Hex(of: tmp)
        // `printf 'sdg-lab\n' | shasum -a 256` →
        // c2edc3c47e70c2072422fe9c9d46025c990fe7a50123bd5ffcc803eca00cd5a1
        XCTAssertEqual(
            hex,
            "c2edc3c47e70c2072422fe9c9d46025c990fe7a50123bd5ffcc803eca00cd5a1"
        )
        // Lowercase + length pin — catches encoding regressions even
        // if someone legitimately updates the payload above.
        XCTAssertEqual(hex.count, 64)
        XCTAssertEqual(hex, hex.lowercased())
    }

    /// Different bytes → different digest. Trivially true, but pins
    /// the guard against a future "always return empty string"
    /// regression if someone refactors the streaming path.
    func testSha256DistinguishesPayloads() throws {
        let tmpA = FileManager.default.temporaryDirectory
            .appendingPathComponent("glb_conv_A_\(UUID().uuidString).bin")
        let tmpB = FileManager.default.temporaryDirectory
            .appendingPathComponent("glb_conv_B_\(UUID().uuidString).bin")
        try XCTUnwrap("A".data(using: .utf8)).write(to: tmpA)
        try XCTUnwrap("B".data(using: .utf8)).write(to: tmpB)
        defer {
            try? FileManager.default.removeItem(at: tmpA)
            try? FileManager.default.removeItem(at: tmpB)
        }

        let a = try GLBToUSDZConverter.sha256Hex(of: tmpA)
        let b = try GLBToUSDZConverter.sha256Hex(of: tmpB)
        XCTAssertNotEqual(a, b)
    }

    /// Missing source file → `.hashFailed`. Important because the
    /// converter relies on this error to distinguish "bad I/O"
    /// from "ModelIO said no".
    func testSha256MissingFileThrowsHashFailed() {
        let missing = FileManager.default.temporaryDirectory
            .appendingPathComponent("glb_conv_missing_\(UUID().uuidString).bin")
        XCTAssertThrowsError(
            try GLBToUSDZConverter.sha256Hex(of: missing)
        ) { err in
            guard
                let ce = err as? GLBToUSDZConverter.ConverterError,
                case .hashFailed = ce
            else {
                return XCTFail("unexpected error: \(err)")
            }
        }
    }
}
