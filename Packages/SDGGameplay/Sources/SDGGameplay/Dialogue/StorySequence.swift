// StorySequence.swift
// SDGGameplay · Dialogue
//
// A single scripted cutscene. 1:1 Codable mapping of the Unity
// `StorySystem/StorySequenceLoader.cs::StorySequence` schema plus a
// synthetic `id` so views and the store can key on the file basename.
//
// The JSON on disk looks like (quest1.1.json):
//
//     {
//       "scene": "第一幕：昼休みの異変",
//       "background": "classroom_day",
//       "bgm": "school_daytime",
//       "dialogues": [ { ... DialogueLine ... }, ... ]
//     }
//
// `StoryLoader` is responsible for reading the file; this type is the
// pure Codable contract.

import Foundation

/// One loaded story cutscene.
///
/// `id` is the file basename (`"quest1.1"`) assigned by `StoryLoader`.
/// It is *not* part of the JSON — the Unity loader keyed off the
/// resource path itself, not a field inside the file.
public struct StorySequence: Codable, Sendable, Identifiable, Hashable {

    /// Synthetic identity, typically the JSON file basename. Not read
    /// from or written to JSON — see the file header. Callers that
    /// build a `StorySequence` in-memory (tests, fixtures) should pass
    /// a stable unique string.
    public let id: String

    /// Optional human-readable scene label. Displayed as a subtitle in
    /// debug overlays; not localised because the legacy JSONs only
    /// shipped a Japanese value.
    public let scene: String

    /// Background asset identifier (`"classroom_day"`, `"lab_night"`,
    /// ...). Kept opaque — the rendering layer resolves it to a
    /// concrete image / entity.
    public let background: String

    /// BGM track identifier (e.g. `"school_daytime"`). Same opaque
    /// contract as `background`; `AudioService` maps it to a file.
    public let bgm: String

    /// Ordered dialogue lines.
    public let dialogues: [DialogueLine]

    /// JSON coding keys — excludes `id` which is synthesized.
    private enum CodingKeys: String, CodingKey {
        case scene, background, bgm, dialogues
    }

    /// Memberwise init for fixtures + programmatic construction.
    public init(
        id: String,
        scene: String = "",
        background: String = "",
        bgm: String = "",
        dialogues: [DialogueLine] = []
    ) {
        self.id = id
        self.scene = scene
        self.background = background
        self.bgm = bgm
        self.dialogues = dialogues
    }

    /// JSON decode. `id` falls back to an empty string if no caller
    /// assigned one via `StoryLoader`; production callers always
    /// supply an id by calling `decoded(from:, id:)`.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.id = ""
        self.scene = try c.decodeIfPresent(String.self, forKey: .scene) ?? ""
        self.background = try c.decodeIfPresent(String.self, forKey: .background) ?? ""
        self.bgm = try c.decodeIfPresent(String.self, forKey: .bgm) ?? ""
        self.dialogues = try c.decodeIfPresent([DialogueLine].self, forKey: .dialogues) ?? []
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(scene, forKey: .scene)
        try c.encode(background, forKey: .background)
        try c.encode(bgm, forKey: .bgm)
        try c.encode(dialogues, forKey: .dialogues)
    }

    /// Replace the `id` on a decoded sequence.
    ///
    /// `Codable` does not let the decoder know which file it came
    /// from, so `StoryLoader` decodes first and then tags the sequence
    /// via this helper.
    public func withId(_ newId: String) -> StorySequence {
        StorySequence(
            id: newId,
            scene: scene,
            background: background,
            bgm: bgm,
            dialogues: dialogues
        )
    }
}
