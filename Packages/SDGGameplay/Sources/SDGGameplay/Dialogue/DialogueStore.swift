// DialogueStore.swift
// SDGGameplay · Dialogue
//
// `@Observable` state container for whatever dialogue is currently
// on screen. Mirror of Unity's `StorySystem/StoryDirector`'s UI
// responsibilities, reshaped for the three-layer architecture:
// - The store only owns *which line is active*. Rendering, typewriter
//   effects, portrait choice, and SFX are the view layer's problem.
// - Playback is user-paced: `.advance` must come from the outside
//   (a tap, a keyboard shortcut). The store NEVER auto-advances; the
//   legacy Director had a Coroutine that auto-scrolled timed lines,
//   which fragmented responsibilities between cutscene script and
//   director. We refuse to ship that pattern.

import Foundation
import Observation
import SDGCore

/// `@Observable` dialogue playback state.
///
/// ### State machine
///     .idle                             (initial / after finish)
///        │ intent(.play(seq))
///        ▼
///     .playing(seq, currentLineIndex: 0)
///        │ intent(.advance) (0 < last)
///        ▼
///     .playing(seq, currentLineIndex: n)
///        │ intent(.advance) (n == last)
///        ▼
///     .finished(seq, skipped: false)
///
///     at any .playing:
///        │ intent(.skipAll)
///        ▼
///     .finished(seq, skipped: true)
///
/// `.finished` is terminal — a new `.play` resets to line 0 of the
/// new sequence. Re-playing the same sequence is legal and common
/// (developers testing cutscenes).
@Observable
@MainActor
public final class DialogueStore: Store {

    // MARK: - Intent

    public enum Intent: Sendable, Equatable {

        /// Start playback from line 0 of `sequence`. Overrides any
        /// currently-playing sequence; this matches the Unity
        /// director's "latest call wins" behaviour.
        case play(sequence: StorySequence)

        /// Advance to the next line. If the current line is the last,
        /// transitions into `.finished(skipped: false)`. No-op when
        /// the store is `.idle` or `.finished`.
        case advance

        /// Jump straight to `.finished(skipped: true)`. Useful for
        /// "skip cutscene" buttons; quest objectives gated on "the
        /// dialogue finished" should still satisfy because they
        /// subscribe to `DialogueFinished` regardless of `skipped`.
        case skipAll
    }

    // MARK: - Status

    /// Observable playback status.
    public enum Status: Sendable, Equatable {
        case idle
        case playing(sequence: StorySequence, currentLineIndex: Int)
        case finished(sequence: StorySequence, skipped: Bool)
    }

    // MARK: - Observable state

    /// Current playback status. Read by the dialogue view; never
    /// assigned from outside.
    public private(set) var status: Status = .idle

    // MARK: - Convenience accessors

    /// Currently visible line, if any. `nil` in `.idle` / `.finished`
    /// or when the active sequence has no dialogues.
    public var currentLine: DialogueLine? {
        guard case let .playing(seq, idx) = status,
              idx >= 0, idx < seq.dialogues.count else {
            return nil
        }
        return seq.dialogues[idx]
    }

    /// `true` if the store is playing and currently parked on the
    /// last dialogue line. UI can use this to swap "next ▸" for
    /// "finish ✓" without opening the Status enum.
    public var isOnLastLine: Bool {
        guard case let .playing(seq, idx) = status else { return false }
        return idx == seq.dialogues.count - 1
    }

    // MARK: - Dependencies

    private let eventBus: EventBus

    public init(eventBus: EventBus) {
        self.eventBus = eventBus
    }

    // MARK: - Store protocol

    public func intent(_ intent: Intent) async {
        switch intent {
        case .play(let sequence):
            await playSequence(sequence)

        case .advance:
            await advance()

        case .skipAll:
            await skipAll()
        }
    }

    // MARK: - Intent handlers

    private func playSequence(_ sequence: StorySequence) async {
        // Special case: a sequence with no dialogues fires `played`
        // followed *immediately* by `finished` so callers that await
        // DialogueFinished don't deadlock on empty scripts.
        if sequence.dialogues.isEmpty {
            status = .finished(sequence: sequence, skipped: false)
            await eventBus.publish(DialoguePlayed(sequenceId: sequence.id))
            await eventBus.publish(
                DialogueFinished(sequenceId: sequence.id, skipped: false)
            )
            return
        }
        status = .playing(sequence: sequence, currentLineIndex: 0)
        await eventBus.publish(DialoguePlayed(sequenceId: sequence.id))
    }

    private func advance() async {
        guard case let .playing(sequence, idx) = status else { return }
        let next = idx + 1
        if next >= sequence.dialogues.count {
            status = .finished(sequence: sequence, skipped: false)
            await eventBus.publish(
                DialogueFinished(sequenceId: sequence.id, skipped: false)
            )
        } else {
            status = .playing(sequence: sequence, currentLineIndex: next)
            await eventBus.publish(
                DialogueAdvanced(sequenceId: sequence.id, lineIndex: next)
            )
        }
    }

    private func skipAll() async {
        guard case let .playing(sequence, _) = status else { return }
        status = .finished(sequence: sequence, skipped: true)
        await eventBus.publish(
            DialogueFinished(sequenceId: sequence.id, skipped: true)
        )
    }
}
