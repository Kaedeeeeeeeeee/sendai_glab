// QuestTrackerView.swift
// SDGUI · Quest
//
// Top-left HUD card that surfaces the player's current active quest
// and its remaining objectives. Hidden when no quest is in progress.
//
// Visual:
//   small dark card pinned to top-left,
//   "🎯  <quest title>" header (yellow),
//   bullet list of objectives, each with ☐ or ☑ prefix.
//
// Reads from `QuestStore.activeQuests`. Picks the *first*
// `.inProgress` quest as "current"; multi-quest UI is a Phase 3 task.

import SwiftUI
import SDGGameplay

/// Top-left HUD overlay surfacing the active quest. Renders nothing
/// when no quest is in progress, so it's safe to drop into the HUD
/// `ZStack` unconditionally.
public struct QuestTrackerView: View {

    @Bindable public var questStore: QuestStore

    public init(questStore: QuestStore) {
        self.questStore = questStore
    }

    public var body: some View {
        if let quest = currentInProgressQuest {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    Text("🎯")
                        .font(.body)
                    // Quest title is a localisation key in Catalog;
                    // pass through to SwiftUI's automatic resolution
                    // via `LocalizedStringKey`.
                    Text(LocalizedStringKey(quest.titleKey))
                        .font(.headline)
                        .foregroundStyle(.yellow)
                }
                ForEach(quest.objectives) { obj in
                    HStack(alignment: .top, spacing: 6) {
                        Text(obj.completed ? "☑" : "☐")
                            .font(.caption)
                            .foregroundStyle(obj.completed ? .green : .white.opacity(0.7))
                        Text(LocalizedStringKey(obj.titleKey))
                            .font(.caption)
                            .foregroundStyle(obj.completed ? .white.opacity(0.5) : .white)
                            .strikethrough(obj.completed, color: .white.opacity(0.4))
                    }
                }
            }
            .padding(12)
            .background(.black.opacity(0.65), in: .rect(cornerRadius: 8))
            .frame(maxWidth: 280, alignment: .leading)
        }
    }

    /// Pick the first `.inProgress` quest from the Store. Phase 3
    /// will swap this for a player-selected "tracked quest" when
    /// concurrent quests become a thing.
    private var currentInProgressQuest: Quest? {
        questStore.quests.first(where: { $0.status == .inProgress })
    }
}
