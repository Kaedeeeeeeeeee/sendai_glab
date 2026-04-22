// DialogueEvents.swift
// SDGGameplay · Dialogue
//
// Cross-module events announcing dialogue state transitions. Fired by
// `DialogueStore`; subscribed by:
//   - HUD / dialogue view (visual update, letter-by-letter animation)
//   - AudioService bridge (optional SFX on advance, BGM change on play)
//   - QuestStore (Phase 2 Alpha) — certain quests complete objectives
//     when a specific sequence finishes.
//
// Keeping start/advance/finish as three events rather than a single
// "state changed" event means subscribers can narrowly opt into the
// transition they care about. UI wants every advance; QuestStore only
// wants finish.

import Foundation
import SDGCore

/// Published at the moment a sequence begins playback (idx 0 is about
/// to show). `DialogueStore` publishes this *before* the view reads
/// the first line, so an SFX handler can prime before the letterbox
/// appears.
public struct DialoguePlayed: GameEvent, Equatable {

    /// Id of the sequence (typically a quest JSON basename).
    public let sequenceId: String

    public init(sequenceId: String) {
        self.sequenceId = sequenceId
    }
}

/// Published when the player taps "next line" (or the store receives
/// `.advance`). Carries the new line index so analytics / audio can
/// fire per-line cues without owning their own state machine.
public struct DialogueAdvanced: GameEvent, Equatable {

    /// Id of the sequence currently playing.
    public let sequenceId: String

    /// Zero-based index of the line that is now on screen.
    public let lineIndex: Int

    public init(sequenceId: String, lineIndex: Int) {
        self.sequenceId = sequenceId
        self.lineIndex = lineIndex
    }
}

/// Published when the sequence ends — either after the final line was
/// advanced past, or because the player skipped. `skipped = true`
/// means the user bypassed remaining lines; quest objectives that
/// gate on completion should still treat this as "the cutscene is
/// over".
public struct DialogueFinished: GameEvent, Equatable {

    /// Id of the sequence that just finished.
    public let sequenceId: String

    /// Whether the sequence ended via `.skipAll` rather than the
    /// natural advance-past-last-line path.
    public let skipped: Bool

    public init(sequenceId: String, skipped: Bool) {
        self.sequenceId = sequenceId
        self.skipped = skipped
    }
}
