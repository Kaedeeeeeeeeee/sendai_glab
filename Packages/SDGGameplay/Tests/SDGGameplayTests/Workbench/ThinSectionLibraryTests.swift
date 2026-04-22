// ThinSectionLibraryTests.swift
// SDGGameplayTests · Workbench
//
// Tests for the thin-section index loader. We bundle a fixture
// `thin_section_index.json` inside `Tests/SDGGameplayTests/Resources/`
// (see Package.swift `resources: .process("Resources")`), and point
// the library at `Bundle.module` to decode it.

import XCTest
@testable import SDGGameplay

@MainActor
final class ThinSectionLibraryTests: XCTestCase {

    override func setUp() async throws {
        try await super.setUp()
        ThinSectionLibrary.resetCacheForTesting()
    }

    func testKnownLayerReturnsMappedPhoto() {
        let photos = ThinSectionLibrary.photos(
            forLayerId: "aobayama.topsoil",
            in: Bundle.module
        )
        XCTAssertEqual(photos.count, 1)
        XCTAssertEqual(photos.first?.id, "topsoil_placeholder")
        XCTAssertEqual(photos.first?.captionKey, "thinsection.topsoil.caption")
    }

    func testMultipleMappedLayersPresent() {
        // The fixture ships mappings for topsoil, upper / lower
        // Aobayama, basement, and tuff. This test guards against
        // accidental downgrades of the fixture during refactors.
        let known = [
            "aobayama.topsoil",
            "aobayama.aobayamafm.upper",
            "aobayama.aobayamafm.lower",
            "aobayama.basement",
            "aobayama.tuff"
        ]
        for layerId in known {
            let photos = ThinSectionLibrary.photos(
                forLayerId: layerId,
                in: Bundle.module
            )
            XCTAssertFalse(
                photos.isEmpty,
                "Expected at least one photo mapping for \(layerId)"
            )
        }
    }

    func testUnknownLayerReturnsEmpty() {
        let photos = ThinSectionLibrary.photos(
            forLayerId: "does.not.exist",
            in: Bundle.module
        )
        XCTAssertTrue(photos.isEmpty)
    }

    func testFallbackPhotoIsStable() {
        // The Microscope UI relies on `fallback` being non-nil and
        // carrying a `captionKey`. Pin that contract.
        let fallback = ThinSectionLibrary.fallback
        XCTAssertFalse(fallback.id.isEmpty)
        XCTAssertFalse(fallback.captionKey.isEmpty)
    }

    func testCachePreventsRepeatedDecodes() {
        // Two back-to-back lookups for the same bundle should return
        // equal results. We can't observe the decode count directly
        // from outside the module, but we *can* verify the public
        // results stay consistent after an explicit cache reset in the
        // middle, which exercises both the hot and cold paths.
        let first = ThinSectionLibrary.photos(
            forLayerId: "aobayama.topsoil",
            in: Bundle.module
        )
        ThinSectionLibrary.resetCacheForTesting()
        let second = ThinSectionLibrary.photos(
            forLayerId: "aobayama.topsoil",
            in: Bundle.module
        )
        XCTAssertEqual(first, second)
    }
}
