// StoryProgressionBridge.swift
// SDGGameplay · Story
//
// Event-driven glue that turns narrative beats (dialogue endings, quest
// completions) into `QuestStore` intents, driving the 13-quest main arc
// without requiring RootView or any other UI-layer code to know the
// ordering.
//
// ## Why a bridge (not a QuestStore internal)
//
// QuestStore already owns quest state and reacts to `SampleCreatedEvent`
// for the one sample-count objective. Adding dialogue + quest-chain
// policy directly onto QuestStore would:
//
//   - entangle two orthogonal concerns (state machine vs. narrative
//     script). The state machine wants to be stable across story
//     rewrites; the script is exactly what a designer edits.
//   - grow the Store's subscription surface (three more handlers) and
//     blur the "Store handles its own state" contract.
//
// Instead we mirror `AudioEventBridge` (Platform events → service
// calls): here, `StoryProgressionBridge` subscribes to narrative
// events and dispatches intents to QuestStore. The Store stays focused
// on "apply intent → mutate state → publish event"; the bridge owns
// the policy table (`StoryProgressionMap`).
//
// ## Lifecycle
//
// - Construct with an `EventBus`, a `QuestStore`, and a map.
// - Call `start()` to install subscriptions. Returns when both are live.
// - Call `stop()` to drain subscriptions. Safe to re-start afterwards
//   (tokens reset).
//
// Idempotency is *not* guaranteed: calling `start()` twice without an
// intervening `stop()` installs duplicate handlers, matching the
// convention established by `AudioEventBridge`.

import Foundation
import SDGCore

/// Subscribes to `DialogueFinished` and `QuestCompleted` on the shared
/// `EventBus` and dispatches the appropriate `QuestStore.Intent` per
/// the injected `StoryProgressionMap`.
///
/// `@MainActor` because the downstream `QuestStore.intent(_:)` is
/// main-isolated; staying on the same actor avoids an extra hop per
/// event and mirrors the pattern in `AudioEventBridge`.
@MainActor
public final class StoryProgressionBridge {

    // MARK: - Dependencies

    /// Bus the bridge listens on. Injected rather than pulled from a
    /// singleton (AGENTS.md Rule 2).
    private let eventBus: EventBus

    /// Store the bridge dispatches intents to. Held strongly because
    /// the bridge's lifetime is bounded by its owner (RootView).
    private let questStore: QuestStore

    /// Narrative policy table. Injected so tests can exercise the
    /// bridge's wiring with a minimal map, and designers can swap in
    /// an alternate map for branching stories.
    private let map: StoryProgressionMap

    // MARK: - State

    /// Tokens for every live subscription. Populated by `start()` and
    /// drained by `stop()`. `@MainActor`-isolated so mutations don't
    /// need a lock.
    private var tokens: [SubscriptionToken] = []

    // MARK: - Init

    /// - Parameters:
    ///   - eventBus: Shared `EventBus` from `AppEnvironment`.
    ///   - questStore: `QuestStore` whose intents the bridge will
    ///                 dispatch.
    ///   - map: Narrative policy. Defaults to `StoryProgressionMap.builtIn`
    ///          which encodes the 13-quest main arc.
    public init(
        eventBus: EventBus,
        questStore: QuestStore,
        map: StoryProgressionMap = .builtIn
    ) {
        self.eventBus = eventBus
        self.questStore = questStore
        self.map = map
    }

    // MARK: - Lifecycle

    /// Install the dialogue→objective and quest→next-quest handlers.
    /// Safe to call before `questStore.start()` — subscriptions go
    /// through the bus, not through a direct store reference.
    public func start() async {
        // Capture locally so handler closures don't retain `self` and
        // don't re-read stored properties on each event. Matches
        // AudioEventBridge's capture pattern.
        let store = questStore
        let bindings = map.dialogueToObjective
        let chain = map.questChain

        // When a dialogue sequence finishes, look up the binding and
        // dispatch `.completeObjective`. `skipped` is deliberately not
        // checked: from the quest system's perspective a skipped
        // cutscene still closes the objective — the player chose to
        // move past the content, they shouldn't be stuck.
        let dialogueToken = await eventBus.subscribe(DialogueFinished.self) { event in
            guard let binding = bindings[event.sequenceId] else { return }
            await MainActor.run {
                Task { @MainActor in
                    await store.intent(
                        .completeObjective(
                            questId: binding.questId,
                            objectiveId: binding.objectiveId
                        )
                    )
                }
            }
        }

        // When a quest completes, auto-start its successor (if any).
        // Absence from the chain map means the quest is terminal — no
        // successor, don't do anything.
        let questToken = await eventBus.subscribe(QuestCompleted.self) { event in
            guard let nextId = chain[event.questId] else { return }
            await MainActor.run {
                Task { @MainActor in
                    await store.intent(.start(questId: nextId))
                }
            }
        }

        tokens = [dialogueToken, questToken]
    }

    /// Cancel every subscription. Call from `RootView.teardown` or when
    /// tests reset their environment.
    public func stop() async {
        for token in tokens {
            await eventBus.cancel(token)
        }
        tokens.removeAll()
    }

    // MARK: - Test-only introspection

    /// Number of live subscriptions. Tests assert this goes `0 → 2 → 0`
    /// across `start()` / `stop()` to prove token bookkeeping works.
    public var subscriptionCount: Int {
        tokens.count
    }
}
