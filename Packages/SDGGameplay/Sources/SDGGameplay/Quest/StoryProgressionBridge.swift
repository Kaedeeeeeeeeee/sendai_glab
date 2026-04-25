// StoryProgressionBridge.swift
// SDGGameplay · Quest
//
// Event-driven bridge that wires `StoryProgressionMap` into the
// running game. Subscribes to:
//
//   * `DialogueFinished` — when a scripted dialogue ends, look up
//     whether it closes a quest objective and fire the matching
//     `QuestStore.intent(.completeObjective(...))`. Replaces the
//     Phase 3 ad-hoc `dialogueFinishedToken` subscription that
//     hard-wired `quest1.1 → q.lab.intro`.
//
//   * `QuestCompleted` — when a quest finishes, fire both:
//       a) the successor quest's `.start` intent (chapter chaining),
//       b) the disaster trigger (Phase 9 Part B) — earthquake or
//          flood — via `DisasterStore` when the map has a binding.
//
// The bridge owns no state of its own beyond the subscription
// tokens; all routing tables live in `StoryProgressionMap`.
//
// ## Architecture placement
//
// Lives in `SDGGameplay/Quest/` because it combines Quest +
// Dialogue events (both SDGGameplay) with `DisasterStore`
// (SDGGameplay). RootView owns the instance, not this file.
// Matches the `AudioEventBridge` lifetime + start/stop shape.
//
// `@MainActor` for the same reason every other bridge is: bus
// handlers hop back onto main to call `@Observable` Store APIs.

import Foundation
import SDGCore

/// Closure the bridge calls when a quest completion fires a flood
/// trigger. Returns the player's current world-space Y so the
/// water plane rises relative to the player (a flood that starts
/// under the ocean floor is neither useful nor dramatic).
public typealias PlayerYProvider = @MainActor () -> Float

@MainActor
public final class StoryProgressionBridge {

    // MARK: - Dependencies

    /// Bus we subscribe to. Injected, not global (AGENTS.md §1).
    private let eventBus: EventBus

    /// Quest state machine. Receives `.completeObjective` and
    /// `.start` intents as events fire.
    private let questStore: QuestStore

    /// Disaster state machine. Receives `.triggerEarthquake` /
    /// `.triggerFlood` intents when a quest completion lands on
    /// a `StoryProgressionMap.disaster(after:)` binding.
    private let disasterStore: DisasterStore

    /// Snapshot of player Y at trigger time, used as the flood's
    /// `startY`. Injected rather than held on the bridge because
    /// the bridge is scene-graph-agnostic — only the RootView
    /// knows where the player entity lives.
    private let playerYProvider: PlayerYProvider

    // MARK: - State

    private var dialogueToken: SubscriptionToken?
    private var questToken: SubscriptionToken?

    // MARK: - Init

    public init(
        eventBus: EventBus,
        questStore: QuestStore,
        disasterStore: DisasterStore,
        playerYProvider: @escaping PlayerYProvider
    ) {
        self.eventBus = eventBus
        self.questStore = questStore
        self.disasterStore = disasterStore
        self.playerYProvider = playerYProvider
    }

    // MARK: - Lifecycle

    /// Install the two subscriptions. Idempotent is **not**
    /// guaranteed: calling `start()` twice without an intervening
    /// `stop()` will install duplicate handlers. Callers (RootView)
    /// pair `start()` with exactly one `stop()`.
    public func start() async {
        dialogueToken = await eventBus.subscribe(DialogueFinished.self) { [weak self] event in
            await self?.handleDialogue(event)
        }
        questToken = await eventBus.subscribe(QuestCompleted.self) { [weak self] event in
            await self?.handleQuest(event)
        }
    }

    /// Cancel both subscriptions. Safe to call from any task.
    public func stop() async {
        if let t = dialogueToken {
            await eventBus.cancel(t)
            dialogueToken = nil
        }
        if let t = questToken {
            await eventBus.cancel(t)
            questToken = nil
        }
    }

    // MARK: - Handlers

    private func handleDialogue(_ event: DialogueFinished) async {
        guard let completion = StoryProgressionMap.completion(
            forDialogueSequenceId: event.sequenceId
        ) else {
            return
        }
        await questStore.intent(.completeObjective(
            questId: completion.questId,
            objectiveId: completion.objectiveId
        ))
    }

    private func handleQuest(_ event: QuestCompleted) async {
        // Step 1: successor quest, if any.
        if let successorId = StoryProgressionMap.successor(of: event.questId) {
            await questStore.intent(.start(questId: successorId))
        }
        // Step 2: disaster, if the quest has a binding. Event is
        // carried on the questId so the audio / UI layers can show
        // "earthquake because you finished quest X".
        guard let kind = StoryProgressionMap.disaster(after: event.questId) else {
            return
        }
        switch kind {
        case let .earthquake(intensity, durationSeconds):
            await disasterStore.intent(.triggerEarthquake(
                intensity: intensity,
                durationSeconds: durationSeconds,
                questId: event.questId
            ))
        case let .flood(targetWaterY, riseSeconds):
            await disasterStore.intent(.triggerFlood(
                startY: playerYProvider(),
                targetWaterY: targetWaterY,
                riseSeconds: riseSeconds,
                questId: event.questId
            ))
        }
    }

    // MARK: - Test hooks

    /// Number of currently-installed subscriptions. Used by the
    /// bridge tests to verify `start()` / `stop()` symmetry.
    public var subscriptionCount: Int {
        (dialogueToken == nil ? 0 : 1) + (questToken == nil ? 0 : 1)
    }
}
