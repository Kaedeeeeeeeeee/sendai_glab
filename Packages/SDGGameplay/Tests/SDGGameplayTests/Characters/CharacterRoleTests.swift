// CharacterRoleTests.swift
// Unit tests for the pure-enum `CharacterRole`. These are the cheap
// guards — if anyone renames a USDZ on disk or shuffles the enum
// cases without updating the asset pipeline, these break first.

import XCTest
@testable import SDGGameplay

final class CharacterRoleTests: XCTestCase {

    // MARK: - Basename contract

    /// Every case's `resourceBasename` must follow the
    /// `"Character_..."` naming convention recorded in
    /// `Docs/AssetPipeline.md §命名規約`. If someone adds a case with
    /// a raw value that drifts from this pattern, the installer
    /// script that copies Meshy output into `Resources/Characters/`
    /// will silently skip it — this test makes that visible early.
    func testAllBasenamesFollowCharacterPrefix() {
        for role in CharacterRole.allCases {
            XCTAssertTrue(
                role.resourceBasename.hasPrefix("Character_"),
                "Role \(role) has a non-Character_ basename: \(role.resourceBasename)"
            )
            XCTAssertFalse(
                role.resourceBasename.contains(" "),
                "Role \(role) basename must not contain spaces"
            )
        }
    }

    /// `resourceBasename` is aliased through `rawValue`, so renaming
    /// a case drags its asset along. Pin the identity so the intent
    /// is stated explicitly.
    func testBasenameEqualsRawValue() {
        for role in CharacterRole.allCases {
            XCTAssertEqual(role.resourceBasename, role.rawValue)
        }
    }

    // MARK: - Case coverage

    /// Lock in the expected five roles so adding a sixth without
    /// updating the asset pipeline / nameKey map fails loudly.
    func testCaseCountAndExpectedRoles() {
        let expected: Set<CharacterRole> = [
            .playerMale, .playerFemale, .kaede, .teacher, .researcherA
        ]
        XCTAssertEqual(Set(CharacterRole.allCases), expected)
        XCTAssertEqual(CharacterRole.allCases.count, 5)
    }

    // MARK: - Playability

    /// Only the two main-character roles are playable.
    func testPlayabilityMapping() {
        XCTAssertTrue(CharacterRole.playerMale.isPlayable)
        XCTAssertTrue(CharacterRole.playerFemale.isPlayable)
        XCTAssertFalse(CharacterRole.kaede.isPlayable)
        XCTAssertFalse(CharacterRole.teacher.isPlayable)
        XCTAssertFalse(CharacterRole.researcherA.isPlayable)
    }

    /// The default spawn is the male player per
    /// `Phase 2 Alpha` task spec ("暂无菜单 → 默认男性").
    func testDefaultPlayerIsPlayerMale() {
        XCTAssertEqual(CharacterRole.defaultPlayer, .playerMale)
        XCTAssertTrue(CharacterRole.defaultPlayer.isPlayable)
    }

    // MARK: - Camera height

    /// Phase 2 Alpha fixes the camera height at 1.5 m regardless of
    /// role. Phase 3 美術 with named head bones will relax this, but
    /// until then the value is shared and positive.
    func testCameraHeightIsPositiveAndUniform() {
        for role in CharacterRole.allCases {
            XCTAssertGreaterThan(
                role.cameraHeight, 0,
                "cameraHeight must be positive for \(role)"
            )
            XCTAssertEqual(role.cameraHeight, 1.5, accuracy: 1e-6)
        }
    }

    // MARK: - Localization keys

    /// Every role must have a distinct, non-empty `nameKey`. The
    /// xcstrings linker won't complain about a missing key until
    /// runtime, so we guard the shape here.
    func testNameKeysAreNonEmptyAndUnique() {
        var seen = Set<String>()
        for role in CharacterRole.allCases {
            let key = role.nameKey
            XCTAssertFalse(key.isEmpty, "Empty nameKey for \(role)")
            XCTAssertTrue(key.hasPrefix("character."),
                          "nameKey \(key) must be namespaced under character.*")
            XCTAssertTrue(key.hasSuffix(".name"),
                          "nameKey \(key) must end in .name")
            XCTAssertFalse(seen.contains(key),
                           "Duplicate nameKey \(key)")
            seen.insert(key)
        }
    }

    // MARK: - Raw-value spot check

    /// Spot-pin the on-disk basenames that the installer (copy in
    /// `Resources/Characters/`) relies on. Changing any of these
    /// requires renaming the USDZ too; this test is the smoke alarm.
    func testKnownRawValues() {
        XCTAssertEqual(CharacterRole.playerMale.rawValue,   "Character_Player_Male")
        XCTAssertEqual(CharacterRole.playerFemale.rawValue, "Character_Player_Female")
        XCTAssertEqual(CharacterRole.kaede.rawValue,        "Character_Kaede")
        XCTAssertEqual(CharacterRole.teacher.rawValue,      "Character_Teacher")
        XCTAssertEqual(CharacterRole.researcherA.rawValue,  "Character_ResearcherA")
    }
}
