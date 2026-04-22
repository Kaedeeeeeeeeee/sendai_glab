// AudioEffectTests.swift
// SDGPlatformTests · Audio
//
// Exercises the pure lookup logic in `AudioEffect`. No AVFoundation,
// no bundle I/O: we're verifying the enum's category mapping and the
// resource-name resolver stay coherent as new cues are added.

import XCTest
@testable import SDGPlatform

final class AudioEffectTests: XCTestCase {

    /// Every declared cue must report a non-empty `category`. A blank
    /// category would cause `AudioService` to build `/Audio/SFX//Foo.ogg`
    /// which silently misses the file — we'd rather catch that here.
    func testEveryCaseHasNonEmptyCategory() {
        for effect in AudioEffect.allCases {
            XCTAssertFalse(
                effect.category.isEmpty,
                "AudioEffect.\(effect) has empty category"
            )
        }
    }

    /// `resolveResourceNames()` must never return an empty list:
    /// an empty list would make `pickURL` deterministically fail.
    func testEveryCaseResolvesAtLeastOneName() {
        for effect in AudioEffect.allCases {
            XCTAssertFalse(
                effect.resolveResourceNames().isEmpty,
                "AudioEffect.\(effect) resolved to no basenames"
            )
        }
    }

    /// Single-file cues must resolve to their rawValue unchanged.
    func testSingleFileCueResolvesToItsRawValue() {
        XCTAssertEqual(AudioEffect.uiTap.resolveResourceNames(), ["UI_Tap"])
        XCTAssertEqual(
            AudioEffect.feedbackSuccess.resolveResourceNames(),
            ["Feedback_Success"]
        )
        XCTAssertEqual(
            AudioEffect.drillStart.resolveResourceNames(),
            ["Drill_Metal_Heavy"]
        )
    }

    /// Drill impacts are expected to ship four numbered variants so
    /// random selection feels non-repetitive.
    func testDrillImpactExpandsToFourVariants() {
        let names = AudioEffect.drillImpactRandom.resolveResourceNames()
        XCTAssertEqual(names.count, 4)
        XCTAssertEqual(
            Set(names),
            Set((1...4).map { "Drill_Impact_\(String(format: "%02d", $0))" })
        )
    }

    /// Grass footsteps ship two variants at Phase 2 Alpha.
    func testFootstepGrassExpandsToTwoVariants() {
        XCTAssertEqual(
            AudioEffect.footstepGrass.resolveResourceNames(),
            ["Footstep_Grass_01", "Footstep_Grass_02"]
        )
    }

    /// Concrete footsteps ship two variants at Phase 2 Alpha.
    func testFootstepConcreteExpandsToTwoVariants() {
        XCTAssertEqual(
            AudioEffect.footstepConcrete.resolveResourceNames(),
            ["Footstep_Concrete_01", "Footstep_Concrete_02"]
        )
    }

    /// UI cues all live under the `ui/` subdirectory.
    func testUICasesShareUICategory() {
        for effect in [AudioEffect.uiTap, .uiTabSelect, .uiOpen, .uiClose] {
            XCTAssertEqual(effect.category, "ui")
        }
    }

    /// Drill cues all live under the `drill/` subdirectory.
    func testDrillCasesShareDrillCategory() {
        for effect in [AudioEffect.drillStart, .drillImpactRandom] {
            XCTAssertEqual(effect.category, "drill")
        }
    }

    /// Footstep cues all live under the `footstep/` subdirectory.
    func testFootstepCasesShareFootstepCategory() {
        for effect in [AudioEffect.footstepGrass, .footstepConcrete] {
            XCTAssertEqual(effect.category, "footstep")
        }
    }

    /// Feedback cues all live under the `feedback/` subdirectory.
    func testFeedbackCasesShareFeedbackCategory() {
        for effect in [
            AudioEffect.feedbackSuccess,
            .feedbackFailure,
            .feedbackNotify
        ] {
            XCTAssertEqual(effect.category, "feedback")
        }
    }
}
