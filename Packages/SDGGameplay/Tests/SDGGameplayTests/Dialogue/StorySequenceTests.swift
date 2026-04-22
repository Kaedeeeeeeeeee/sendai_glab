// StorySequenceTests.swift
// SDGGameplayTests · Dialogue
//
// Codable contract for `StorySequence` + an end-to-end "load every
// real JSON" check. The second bucket is the more load-bearing: if
// the on-disk JSON schema drifts away from our Swift model, dialogue
// playback silently degrades instead of crashing visibly. Failing a
// CI test is cheaper.

import XCTest
@testable import SDGGameplay

final class StorySequenceTests: XCTestCase {

    // MARK: - Round-trip

    func testInMemoryRoundTripPreservesAllFields() throws {
        let original = StorySequence(
            id: "test",
            scene: "Scene",
            background: "bg",
            bgm: "bgm",
            dialogues: [
                DialogueLine(
                    speaker: "narration",
                    text: "hello",
                    speakerKey: "k.speaker",
                    textKey: "k.text",
                    shake: true,
                    shakeAmplitude: 0.25
                ),
                DialogueLine(
                    speaker: "alice",
                    text: "plain"
                    // speakerKey/textKey/shake default away
                )
            ]
        )
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(StorySequence.self, from: data).withId("test")

        XCTAssertEqual(decoded.scene, original.scene)
        XCTAssertEqual(decoded.background, original.background)
        XCTAssertEqual(decoded.bgm, original.bgm)
        XCTAssertEqual(decoded.dialogues.count, original.dialogues.count)
        XCTAssertEqual(decoded.dialogues[0].speaker, "narration")
        XCTAssertEqual(decoded.dialogues[0].text, "hello")
        XCTAssertEqual(decoded.dialogues[0].speakerKey, "k.speaker")
        XCTAssertEqual(decoded.dialogues[0].textKey, "k.text")
        XCTAssertTrue(decoded.dialogues[0].shake)
        XCTAssertEqual(decoded.dialogues[0].shakeAmplitude, 0.25)
        // Defaults survive absence.
        XCTAssertEqual(decoded.dialogues[1].speakerKey, "")
        XCTAssertEqual(decoded.dialogues[1].textKey, "")
        XCTAssertFalse(decoded.dialogues[1].shake)
        XCTAssertEqual(decoded.dialogues[1].shakeAmplitude, 0)
    }

    func testIdIsNotInJSON() throws {
        // The synthesized UUID / basename should never leak into JSON
        // output. If it did, round-tripping through the Unity runtime
        // would break.
        let sequence = StorySequence(
            id: "should_not_serialize",
            dialogues: [DialogueLine(speaker: "x", text: "y")]
        )
        let data = try JSONEncoder().encode(sequence)
        let text = String(decoding: data, as: UTF8.self)
        XCTAssertFalse(text.contains("should_not_serialize"))
    }

    func testDialogueLineDecodingHandlesMissingShakeFields() throws {
        // quest6.1.json shape — `speaker` + `text` only.
        let json = #"""
        { "speaker": "x", "text": "hi" }
        """#.data(using: .utf8)!
        let line = try JSONDecoder().decode(DialogueLine.self, from: json)
        XCTAssertEqual(line.speaker, "x")
        XCTAssertEqual(line.text, "hi")
        XCTAssertFalse(line.shake)
        XCTAssertEqual(line.shakeAmplitude, 0)
        XCTAssertEqual(line.speakerKey, "")
        XCTAssertEqual(line.textKey, "")
    }

    // MARK: - Real JSON fixtures

    /// Every shipped JSON must parse. This is the actual "port did
    /// not break any file" gate.
    func testEveryShippedJSONParses() throws {
        for basename in StoryLoader.shippedBasenames {
            let sequence = try StoryLoader.load(basename: basename, in: .module)
            XCTAssertEqual(sequence.id, basename)
            XCTAssertFalse(
                sequence.dialogues.isEmpty,
                "\(basename) decoded with zero lines — schema drift?"
            )
        }
    }

    func testQuest1_1PreservesShakeFieldsOnDramaticLines() throws {
        // quest1.1.json line 9 has shake=true, amplitude=0.25 in Unity.
        let seq = try StoryLoader.load(basename: "quest1.1", in: .module)
        let shakingLines = seq.dialogues.filter(\.shake)
        XCTAssertGreaterThan(
            shakingLines.count,
            0,
            "quest1.1 should contain at least one shake=true line"
        )
        for line in shakingLines {
            XCTAssertGreaterThan(
                line.shakeAmplitude,
                0,
                "shake=true lines must carry a non-zero amplitude"
            )
        }
    }

    func testStoryLoaderMissingResourceThrows() {
        XCTAssertThrowsError(
            try StoryLoader.load(basename: "nonexistent_fixture", in: .module)
        ) { error in
            guard case StoryLoaderError.resourceNotFound(let basename) = error else {
                return XCTFail("unexpected error: \(error)")
            }
            XCTAssertEqual(basename, "nonexistent_fixture")
        }
    }

    func testShippedBasenameCountMatchesJSONFixtureCount() {
        // 14 files (the spec mentions 13 quests but ships 14 JSONs —
        // quest5 and quest6 each split into numbered parts).
        XCTAssertEqual(StoryLoader.shippedBasenames.count, 14)
    }
}
