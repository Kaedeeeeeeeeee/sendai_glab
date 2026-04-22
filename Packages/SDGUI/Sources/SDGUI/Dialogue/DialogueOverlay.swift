// DialogueOverlay.swift
// SDGUI · Dialogue
//
// Bottom-of-screen dialogue box that surfaces whatever the
// `DialogueStore` is currently playing. Tap anywhere on the box to
// advance to the next line. Hidden entirely when the store is in
// `.idle` or `.finished` state.
//
// Why a single overlay (not many per-scene views): the dialogue UX is
// global — Kaede's narration overrides whatever scene the player is
// in. One overlay, one source of truth, lifecycle owned by RootView.
//
// Visual layout (横屏):
//   bottom 28% of screen, ~70% width centred,
//   black 70% alpha rounded rect,
//   speaker label (yellow, smaller font) above the line text,
//   white body text,
//   tiny "tap to advance" hint bottom-right when not on last line,
//   "▶ End" hint when on the last line.

import SwiftUI
import SDGGameplay
import SDGCore

/// Overlay that renders the active line of `DialogueStore.status`.
///
/// Drop it inside a `ZStack` *after* the gameplay view so it floats
/// above the 3D scene. Use `allowsHitTesting(false)` on the parent
/// `ZStack` if you don't want the dialogue box to intercept taps; we
/// deliberately *want* taps so the user can tap-to-advance.
public struct DialogueOverlay: View {

    /// Source of the active sequence. `@Bindable` so we re-render the
    /// moment the Store status changes.
    @Bindable public var dialogueStore: DialogueStore

    public init(dialogueStore: DialogueStore) {
        self.dialogueStore = dialogueStore
    }

    public var body: some View {
        if let line = currentLine {
            VStack {
                Spacer()
                dialogueCard(line: line)
                    .padding(.horizontal, 80)
                    .padding(.bottom, 60)
            }
            .transition(.move(edge: .bottom).combined(with: .opacity))
        }
    }

    // MARK: - Card

    /// The actual dialogue card. Tap anywhere on it advances; the
    /// Store handles "advance past last line" → finished transition.
    private func dialogueCard(line: DialogueLine) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(speakerDisplay(line.speaker))
                    .font(.headline)
                    .foregroundStyle(speakerColor(line.speaker))
                Spacer()
                Text(advanceHint)
                    .font(.caption2)
                    .foregroundStyle(.white.opacity(0.5))
            }
            Text(line.text)
                .font(.body)
                .foregroundStyle(.white)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.black.opacity(0.75), in: .rect(cornerRadius: 12))
        .contentShape(Rectangle())   // make the whole card tappable
        .onTapGesture {
            let store = dialogueStore
            Task { @MainActor in
                await store.intent(.advance)
            }
        }
    }

    // MARK: - Derived

    /// Pulls the active line from the Store. `nil` when the store is
    /// idle or finished — in which case the overlay renders nothing.
    private var currentLine: DialogueLine? {
        guard case .playing(let sequence, let index) = dialogueStore.status else {
            return nil
        }
        guard index >= 0, index < sequence.dialogues.count else {
            return nil
        }
        return sequence.dialogues[index]
    }

    /// `true` when we're on the final line of the active sequence.
    /// Used to swap the advance hint from "tap to continue" to "end".
    private var isOnLastLine: Bool {
        guard case .playing(let sequence, let index) = dialogueStore.status else {
            return false
        }
        return index >= sequence.dialogues.count - 1
    }

    private var advanceHint: String {
        isOnLastLine ? "▶ End" : "Tap to continue"
    }

    /// Maps a raw speaker key (e.g. `"narration"`, `"カエデ"`) to a
    /// display string. Phase 2 Beta uses the speaker token verbatim
    /// because `Localizable.xcstrings` already carries pre-localised
    /// names for the canonical speakers; Phase 3 will route through
    /// `LocalizationService.t(_:)` once dynamic key resolution lands.
    private func speakerDisplay(_ speaker: String) -> String {
        switch speaker {
        case "narration": return ""    // narrator lines render unbadged
        default:          return speaker
        }
    }

    /// Distinguish narrator (white) from named speakers (yellow). Tiny
    /// affordance that helps the player parse who's talking at a
    /// glance without reading the speaker label.
    private func speakerColor(_ speaker: String) -> Color {
        speaker == "narration" ? .white.opacity(0.7) : .yellow
    }
}
