// DialogueLine.swift
// SDGGameplay · Dialogue
//
// Single line of dialogue inside a `StorySequence`. Ports Unity
// `StorySystem/StorySequenceLoader.cs::StoryDialogueLine` with three
// SwiftUI-friendly adjustments:
//
//   1. Adds a synthesized `UUID` id so views can `ForEach` without a
//      synthetic index. The id is *not* in the JSON; the custom
//      `init(from:)` generates it at decode time.
//   2. `shake` / `shakeAmplitude` / `speakerKey` / `textKey` are all
//      optional-with-default. Some legacy JSONs (notably
//      `quest6.1.json`) only ship `speaker` + `text`; others add
//      `shake: true` on dramatic lines. Defaulting keeps the decoder
//      tolerant of schema drift.
//   3. `shakeAmplitude` is stored as `Float` (matches the Unity type)
//      rather than the `Double` JSONDecoder would default to.

import Foundation

/// One spoken line inside a `StorySequence`.
///
/// Fields mirror the legacy JSON schema exactly; see the file header
/// for the decoding quirks.
public struct DialogueLine: Codable, Sendable, Identifiable, Hashable {

    /// Stable identity for SwiftUI diffing. Generated at decode time;
    /// *not* encoded — serializing back out produces a JSON blob the
    /// Unity runtime could still consume.
    public let id: UUID

    /// Raw speaker label from the JSON. When `speakerKey` is present,
    /// the UI should prefer the localized form; this string is a
    /// readable fallback for debug overlays and untranslated locales.
    public let speaker: String

    /// Raw inline Japanese text from the JSON. Same fallback
    /// relationship to `textKey` as `speaker` to `speakerKey`.
    public let text: String

    /// Localization key for `speaker`. Optional (defaults to empty)
    /// because `quest6.1.json` and a handful of sfx lines lack it.
    public let speakerKey: String

    /// Localization key for `text`. Optional for the same reason as
    /// `speakerKey`.
    public let textKey: String

    /// Whether playing this line should trigger the "earthquake" UI
    /// effect. Optional in JSON (defaults to `false`).
    public let shake: Bool

    /// Strength of the shake if any, in a 0..1 range matching the
    /// Unity value. Optional in JSON (defaults to `0`).
    public let shakeAmplitude: Float

    /// JSON coding keys — deliberately exclude `id` because it is
    /// synthesized, not persisted.
    private enum CodingKeys: String, CodingKey {
        case speaker, text, speakerKey, textKey, shake, shakeAmplitude
    }

    /// Memberwise init used by tests and in-code fixtures. Not derived
    /// automatically because of the custom `init(from:)`.
    public init(
        id: UUID = UUID(),
        speaker: String,
        text: String,
        speakerKey: String = "",
        textKey: String = "",
        shake: Bool = false,
        shakeAmplitude: Float = 0
    ) {
        self.id = id
        self.speaker = speaker
        self.text = text
        self.speakerKey = speakerKey
        self.textKey = textKey
        self.shake = shake
        self.shakeAmplitude = shakeAmplitude
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.id = UUID()
        // `speaker` / `text` are the only truly required fields —
        // every shipped JSON has at least those two.
        self.speaker = try c.decodeIfPresent(String.self, forKey: .speaker) ?? ""
        self.text = try c.decodeIfPresent(String.self, forKey: .text) ?? ""
        self.speakerKey = try c.decodeIfPresent(String.self, forKey: .speakerKey) ?? ""
        self.textKey = try c.decodeIfPresent(String.self, forKey: .textKey) ?? ""
        self.shake = try c.decodeIfPresent(Bool.self, forKey: .shake) ?? false
        self.shakeAmplitude = try c.decodeIfPresent(Float.self, forKey: .shakeAmplitude) ?? 0
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(speaker, forKey: .speaker)
        try c.encode(text, forKey: .text)
        if !speakerKey.isEmpty { try c.encode(speakerKey, forKey: .speakerKey) }
        if !textKey.isEmpty { try c.encode(textKey, forKey: .textKey) }
        if shake { try c.encode(shake, forKey: .shake) }
        if shakeAmplitude != 0 { try c.encode(shakeAmplitude, forKey: .shakeAmplitude) }
    }
}
