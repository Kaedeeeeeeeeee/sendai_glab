// LocalizationServiceTests.swift
// SDGCoreTests
//
// The test bundle at `swift test` time does not contain a compiled
// String Catalog, so key lookups will miss. These tests verify the
// fail-open contract (missing key → key itself returned) and the
// language-reporting fallback, both of which are safe to exercise
// on the CLI.

import XCTest
@testable import SDGCore

final class LocalizationServiceTests: XCTestCase {

    func testMissingKeyReturnsKeyItself() {
        // No String Catalog is linked into the test bundle, so every
        // lookup misses and should return the key unchanged.
        let service = LocalizationService(bundle: .main)
        let key = "ui.totally.unknown.key"
        XCTAssertEqual(service.t(key), key)
    }

    func testKnownL10nKeysAreStable() {
        // Keys live in LocalizationKey.swift. Tests here assert the
        // *shape* of the namespace, not translated values.
        XCTAssertEqual(L10n.UI.settingsTitle, "ui.settings.title")
        XCTAssertEqual(L10n.UI.buttonConfirm, "ui.button.confirm")
        XCTAssertEqual(L10n.UI.buttonClose, "ui.button.close")
        XCTAssertEqual(L10n.Story.speakerNarration, "story.speaker.narration")
    }

    func testCurrentLanguageReturnsSomething() {
        let service = LocalizationService.default
        let lang = service.currentLanguage()
        XCTAssertFalse(lang.isEmpty)
    }

    func testDefaultInstanceIsUsable() {
        // Smoke test for the type-level `default` entry point.
        _ = LocalizationService.default.t("ui.button.confirm")
    }
}
