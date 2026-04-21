// SampleIconRendererTests.swift
// SDGUITests · Samples
//
// Tests for the PNG pipeline in `SampleIconRenderer`. These run on
// macOS (swift-test CLI) which has a full SwiftUI renderer available
// via `ImageRenderer`, so we can actually assert on the bytes that
// come out instead of just on the code path.
//
// Every test routes its cache through `cacheDirectoryURL()` so
// artefacts land in Application Support (already how production
// behaves). We clean up created files at the end of each test to
// keep the shared directory tidy across runs.

import XCTest
import SDGGameplay
@testable import SDGUI

@MainActor
final class SampleIconRendererTests: XCTestCase {

    // MARK: - Fixtures

    /// Canonical "3-layer known-colour" sample referenced by the
    /// task spec. Used across tests so any renderer regression shows
    /// up consistently.
    private func makeSample() -> SampleItem {
        SampleItem(
            drillLocation: SIMD3<Float>(0, 0, 0),
            drillDepth: 6,
            layers: [
                SampleLayerRecord(
                    layerId: "top",
                    nameKey: "layer.top",
                    colorRGB: SIMD3<Float>(0.9, 0.2, 0.2),
                    thickness: 2,
                    entryDepth: 0
                ),
                SampleLayerRecord(
                    layerId: "mid",
                    nameKey: "layer.mid",
                    colorRGB: SIMD3<Float>(0.2, 0.8, 0.3),
                    thickness: 3,
                    entryDepth: 2
                ),
                SampleLayerRecord(
                    layerId: "bot",
                    nameKey: "layer.bot",
                    colorRGB: SIMD3<Float>(0.3, 0.3, 0.9),
                    thickness: 1,
                    entryDepth: 5
                )
            ]
        )
    }

    private func emptySample() -> SampleItem {
        SampleItem(
            drillLocation: SIMD3<Float>(0, 0, 0),
            drillDepth: 0,
            layers: []
        )
    }

    /// Collected test-created sample ids to delete in `tearDown`.
    /// Each test pushes its sample id here so the directory stays
    /// empty across runs even if an assertion fails mid-test.
    private var createdIds: [UUID] = []

    override func tearDown() async throws {
        // Best-effort cleanup — we *want* the assertions already made
        // to stand regardless of whether the OS lets us delete.
        for id in createdIds {
            try? await MainActor.run {
                try SampleIconRenderer.removeCache(for: id)
            }
        }
        createdIds.removeAll()
        try await super.tearDown()
    }

    // MARK: - In-memory render

    func testRenderPNGDataReturnsNonEmptyBlob() throws {
        let sample = makeSample()
        let data = SampleIconRenderer.renderPNGData(for: sample)
        let bytes = try XCTUnwrap(data, "ImageRenderer produced no raster")
        // PNG header: 8 bytes of magic + IHDR. A 256×256 image, even
        // a single solid-colour band, comes out well over 100 B. We
        // assert >= 200 B as a conservative lower bound: catches
        // "zero-size" regressions without fighting PNG's own
        // compression on extremely uniform images.
        XCTAssertGreaterThan(bytes.count, 200)
        // Verify PNG magic — guards against future "accidentally
        // emitted JPEG" regressions if the UTI ever gets mis-wired.
        let magic: [UInt8] = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]
        XCTAssertEqual(Array(bytes.prefix(8)), magic)
    }

    func testRenderPNGDataHandlesEmptySample() throws {
        let data = SampleIconRenderer.renderPNGData(for: emptySample())
        // Even with no layers, we paint a grey placeholder; the PNG
        // pipeline must still produce bytes.
        let bytes = try XCTUnwrap(data, "Empty sample produced no raster")
        XCTAssertGreaterThan(bytes.count, 200)
    }

    func testRenderPNGDataRespectsCustomSize() throws {
        let sample = makeSample()
        let small = try XCTUnwrap(
            SampleIconRenderer.renderPNGData(
                for: sample,
                size: CGSize(width: 64, height: 64),
                scale: 1.0
            )
        )
        let large = try XCTUnwrap(
            SampleIconRenderer.renderPNGData(
                for: sample,
                size: CGSize(width: 256, height: 256),
                scale: 2.0
            )
        )
        // 512×512 raster must be strictly bigger than a 64×64 one for
        // the same content. This catches a size/scale mix-up where
        // both calls accidentally render at the same resolution.
        XCTAssertGreaterThan(large.count, small.count)
    }

    // MARK: - Disk cache

    func testRenderAndCacheWritesFile() throws {
        let sample = makeSample()
        createdIds.append(sample.id)

        let url = try SampleIconRenderer.renderAndCache(for: sample)
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))

        // Size on disk should match what the in-memory path produced.
        let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
        let size = attrs[.size] as? Int ?? 0
        XCTAssertGreaterThan(size, 200)
    }

    func testCachedIconURLFindsWrittenFile() throws {
        let sample = makeSample()
        createdIds.append(sample.id)

        let writtenURL = try SampleIconRenderer.renderAndCache(for: sample)
        let lookupURL = try XCTUnwrap(
            SampleIconRenderer.cachedIconURL(for: sample.id)
        )
        // `standardizedFileURL` normalises `/private` vs `/` prefix
        // differences macOS can inject on temp paths.
        XCTAssertEqual(
            writtenURL.standardizedFileURL,
            lookupURL.standardizedFileURL
        )
    }

    func testCachedIconURLReturnsNilForUnknownSample() {
        XCTAssertNil(SampleIconRenderer.cachedIconURL(for: UUID()))
    }

    func testRemoveCacheDeletesFile() throws {
        let sample = makeSample()
        createdIds.append(sample.id)

        let url = try SampleIconRenderer.renderAndCache(for: sample)
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))

        try SampleIconRenderer.removeCache(for: sample.id)

        XCTAssertNil(SampleIconRenderer.cachedIconURL(for: sample.id))
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    }

    func testRemoveCacheIsNoOpForMissingFile() {
        // Must not throw — the contract is "the file is gone after
        // this call", and a missing file already satisfies that.
        XCTAssertNoThrow(try SampleIconRenderer.removeCache(for: UUID()))
    }

    func testRenderAndCacheIsIdempotent() throws {
        let sample = makeSample()
        createdIds.append(sample.id)

        let urlA = try SampleIconRenderer.renderAndCache(for: sample)
        let urlB = try SampleIconRenderer.renderAndCache(for: sample)
        XCTAssertEqual(urlA, urlB)
        XCTAssertTrue(FileManager.default.fileExists(atPath: urlB.path))
    }

    // MARK: - Directory helpers

    func testCacheDirectoryURLEndsWithSampleIconsPath() throws {
        let url = try XCTUnwrap(SampleIconRenderer.cacheDirectoryURL())
        XCTAssertTrue(
            url.path.hasSuffix("sdg-lab/sample_icons") ||
            url.path.hasSuffix("sdg-lab/sample_icons/"),
            "Unexpected cache path: \(url.path)"
        )
    }
}
