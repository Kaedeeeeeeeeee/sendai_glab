// QuestStore.swift
// SDGGameplay · Quest
//
// `@Observable` state container owning every quest's runtime status.
// Mirror of the Unity `QuestManager` singleton, rebuilt on the three-
// layer architecture (ADR-0001): no scene references, no SwiftUI
// dependency, pure intent→state→event.
//
// ## Lifecycle
//
//     init(bus, persistence)        // wire deps; no I/O, no subscribe
//              │
//           start()                 // hydrate from disk, subscribe to
//              │                    // SampleCreatedEvent
//              ▼
//     intent(.start(id))            // .notStarted → .inProgress + QuestStarted
//     intent(.completeObjective)    // flip objective + ObjectiveCompleted
//                                   // (all done → QuestCompleted + rewards)
//     intent(.markComplete(id))     // admin/debug shortcut
//     intent(.reset)                // zero everything; useful for tests
//              │
//            stop()                 // cancel subscription
//
// ## Phase 2 Beta scope for event-driven objectives
//
// The legacy project wired guidance targets, scene changes, and sample
// position matching into one monolithic `OnSampleAdded` handler. We
// keep that surface shallow: `SampleCreatedEvent` advances
// `q.field.phase.collect_samples` after three ingested samples. Other
// conditions (dialogue-finished, scene-returned) are `TODO` stubs so
// Phase 2 Alpha can wire them without revisiting the Store's shape.

import Foundation
import Observation
import SDGCore

/// `@Observable` store owning every quest's runtime status.
///
/// ### Single-writer discipline
/// `QuestStore` is the *only* code path that mutates `quests`. Tests
/// and UIs read via `@Observable`; cross-module code sends an intent.
///
/// ### Concurrency
/// `@MainActor` so `@Observable` mutations happen on the UI thread.
/// Event handlers bounce back into the actor via `await self?...`.
@Observable
@MainActor
public final class QuestStore: Store {

    // MARK: - Intent

    /// Commands the store accepts. Each case corresponds to one
    /// edge in the quest state machine.
    public enum Intent: Sendable, Equatable {

        /// Start the quest with the given id if it is currently
        /// `.notStarted`. No-op otherwise (same semantics as the
        /// legacy `QuestManager.StartQuest`).
        case start(questId: String)

        /// Mark an objective complete. If the objective completion
        /// finishes every objective in the quest, the quest itself
        /// transitions to `.completed` and rewards are granted.
        case completeObjective(questId: String, objectiveId: String)

        /// Force a quest into `.completed` regardless of objective
        /// state. Admin / cutscene hook; preserves the legacy
        /// manager's "I know better" escape hatch. Still grants
        /// rewards and fires `QuestCompleted`.
        case markComplete(questId: String)

        /// Reset every quest to its catalog-defined baseline and clear
        /// persistence. Used by "New Game" / test tear-down. Does not
        /// fire any events (subscribers drive off `QuestStarted`).
        case reset
    }

    // MARK: - Observable state

    /// Every quest the game ships with, merged with the persisted
    /// progress snapshot. Rebuilt on `start()` and on `.reset`.
    ///
    /// Array ordering matches `QuestCatalog.all` so UI can render a
    /// linear chapter list without re-sorting.
    public private(set) var quests: [Quest] = QuestCatalog.all

    // MARK: - Dependencies (injected)

    private let eventBus: EventBus
    private let persistence: QuestPersistence

    /// Sample-count progress for `q.field.phase.collect_samples`.
    /// Kept as an ephemeral field on the store (not persisted) — if
    /// the objective is already satisfied on launch this counter is
    /// irrelevant; if it's still open the player simply re-collects.
    /// Phase 2 Alpha will extend persistence if playtests show that
    /// reloading mid-objective is annoying.
    private var fieldPhaseSampleCount: Int = 0

    /// Three samples to complete the objective — matches the length of
    /// the legacy `FieldPhaseTargetSequence` array.
    public static let fieldPhaseSampleTarget: Int = 3

    /// Subscription bookkeeping; split per type for readable teardown.
    private var sampleSubscription: SubscriptionToken?

    /// Granted reward keys, loaded from persistence on `start()`. Used
    /// to dedupe `RewardGranted` events so a re-completed quest never
    /// double-unlocks a tool.
    private var grantedRewardKeys: Set<String> = []

    // MARK: - Init

    public init(
        eventBus: EventBus,
        persistence: QuestPersistence = .standard
    ) {
        self.eventBus = eventBus
        self.persistence = persistence
    }

    // MARK: - Lifecycle

    /// Hydrate from persistence and subscribe to gameplay events.
    ///
    /// Idempotent on the subscription: calling twice re-hydrates but
    /// keeps the first subscription token.
    public func start() async {
        // Rehydrate.
        let snapshot = (try? persistence.load()) ?? .empty
        self.grantedRewardKeys = snapshot.grantedRewardKeys

        self.quests = QuestCatalog.all.map { defn in
            var q = defn
            for idx in q.objectives.indices {
                if snapshot.completedObjectiveIds.contains(q.objectives[idx].id) {
                    q.objectives[idx].completed = true
                }
            }
            if snapshot.completedQuestIds.contains(q.id) {
                q.status = .completed
            } else if q.objectives.contains(where: \.completed) {
                // Partial progress: bump from .notStarted to .inProgress.
                q.status = .inProgress
            }
            return q
        }

        warnOnMissingLocalizationKeys()

        // Subscribe (once).
        guard sampleSubscription == nil else { return }
        sampleSubscription = await eventBus.subscribe(SampleCreatedEvent.self) { [weak self] event in
            await self?.handleSampleCreated(event)
        }
    }

    /// Tear down the subscription. Idempotent.
    public func stop() async {
        if let token = sampleSubscription {
            await eventBus.cancel(token)
            sampleSubscription = nil
        }
    }

    // MARK: - Queries

    /// Lookup current runtime state for a quest.
    public func quest(withId id: String) -> Quest? {
        quests.first { $0.id == id }
    }

    /// Whether the given objective has been marked complete in the
    /// store's current view. Cheap O(n·m) scan; n and m are both small
    /// (13 quests × ≤2 objectives).
    public func isObjectiveCompleted(_ objectiveId: String) -> Bool {
        quests.contains { quest in
            quest.objectives.contains { $0.id == objectiveId && $0.completed }
        }
    }

    // MARK: - Store protocol

    public func intent(_ intent: Intent) async {
        switch intent {
        case .start(let id):
            await startQuest(id: id)

        case let .completeObjective(questId, objectiveId):
            await completeObjective(questId: questId, objectiveId: objectiveId)

        case .markComplete(let id):
            await forceComplete(questId: id)

        case .reset:
            resetToBaseline()
        }
    }

    // MARK: - Intent handlers

    private func startQuest(id questId: String) async {
        guard let idx = quests.firstIndex(where: { $0.id == questId }) else { return }
        guard quests[idx].status == .notStarted else { return }

        quests[idx].status = .inProgress
        persistIgnoringFailure()

        await eventBus.publish(QuestStarted(questId: questId))
    }

    private func completeObjective(
        questId: String,
        objectiveId: String
    ) async {
        guard let qIdx = quests.firstIndex(where: { $0.id == questId }) else { return }
        guard let oIdx = quests[qIdx].objectives.firstIndex(where: { $0.id == objectiveId }) else {
            return
        }
        guard !quests[qIdx].objectives[oIdx].completed else { return }

        quests[qIdx].objectives[oIdx].completed = true

        // Also flip quest to `.inProgress` if the store was granted this
        // objective before a `.start(id:)` arrived (narrative shortcuts
        // occasionally complete objectives out of order).
        if quests[qIdx].status == .notStarted {
            quests[qIdx].status = .inProgress
        }

        persistIgnoringFailure()
        await eventBus.publish(ObjectiveCompleted(questId: questId, objectiveId: objectiveId))

        if quests[qIdx].areAllObjectivesCompleted {
            await finalizeCompletion(questIndex: qIdx)
        }
    }

    private func forceComplete(questId: String) async {
        guard let qIdx = quests.firstIndex(where: { $0.id == questId }) else { return }
        guard quests[qIdx].status != .completed,
              quests[qIdx].status != .rewardClaimed else {
            return
        }

        // Mark every objective complete for consistency.
        for oIdx in quests[qIdx].objectives.indices {
            quests[qIdx].objectives[oIdx].completed = true
        }

        persistIgnoringFailure()
        await finalizeCompletion(questIndex: qIdx)
    }

    /// Shared tail for the "quest just entered `.completed`" path.
    /// Flips status, persists, and publishes `QuestCompleted` followed
    /// by one `RewardGranted` per reward.
    private func finalizeCompletion(questIndex qIdx: Int) async {
        let questId = quests[qIdx].id
        quests[qIdx].status = .completed
        persistIgnoringFailure()

        await eventBus.publish(QuestCompleted(questId: questId))

        for reward in quests[qIdx].rewards {
            let key = QuestPersistence.rewardKey(questId: questId, reward: reward)
            guard !grantedRewardKeys.contains(key) else { continue }
            grantedRewardKeys.insert(key)
            persistIgnoringFailure()
            await eventBus.publish(RewardGranted(questId: questId, reward: reward))
        }
    }

    private func resetToBaseline() {
        quests = QuestCatalog.all
        grantedRewardKeys = []
        fieldPhaseSampleCount = 0
        // Wipe persistence as well — otherwise the next `start()` would
        // rebuild the old state.
        try? persistence.save(.empty)
    }

    // MARK: - Event handlers

    /// Auto-advance the "collect samples" objective of `q.field.phase`
    /// when the inventory reports a new sample. Simple count-based
    /// matching — see the class header for the scope rationale.
    private func handleSampleCreated(_ event: SampleCreatedEvent) async {
        // Phase 2 Beta: we just count, we don't validate position.
        // TODO(#phase-2-alpha): re-add guidance-target matching so
        // samples from the wrong outcrop don't advance the counter.
        _ = event // parameter retained for future position matching

        guard let quest = self.quest(withId: "q.field.phase"),
              quest.status == .inProgress,
              !isObjectiveCompleted("q.field.phase.collect_samples"),
              // enter_field must have been completed first (legacy
              // QuestManager.HandleFieldPhaseSamplingProgress gate).
              isObjectiveCompleted("q.field.phase.enter_field")
        else {
            return
        }

        fieldPhaseSampleCount += 1
        guard fieldPhaseSampleCount >= Self.fieldPhaseSampleTarget else { return }

        await completeObjective(
            questId: "q.field.phase",
            objectiveId: "q.field.phase.collect_samples"
        )
    }

    // MARK: - Persistence

    private func persistIgnoringFailure() {
        let snapshot = buildSnapshot()
        do {
            try persistence.save(snapshot)
        } catch {
            // Intentionally swallowed; matches InventoryStore semantics.
        }
    }

    private func buildSnapshot() -> QuestPersistence.Snapshot {
        var completedQuestIds: Set<String> = []
        var completedObjectiveIds: Set<String> = []
        for quest in quests {
            if quest.status == .completed || quest.status == .rewardClaimed {
                completedQuestIds.insert(quest.id)
            }
            for obj in quest.objectives where obj.completed {
                completedObjectiveIds.insert(obj.id)
            }
        }
        return QuestPersistence.Snapshot(
            completedQuestIds: completedQuestIds,
            completedObjectiveIds: completedObjectiveIds,
            grantedRewardKeys: grantedRewardKeys
        )
    }

    // MARK: - Localization sanity check

    /// Emit a lightweight warning when a quest in the catalog refers to
    /// a localization key that hasn't been translated yet. This is a
    /// *best-effort* signal: we don't want `QuestStore` to depend on
    /// the Localization module (ADR-0001 keeps stores framework-free),
    /// so we only catch missing keys when `LocalizationService` is
    /// reachable via `Bundle.main.localizations`.
    ///
    /// The check runs once per `start()` and costs O(quests) + one
    /// plist probe; skippable by release flag in Phase 2 Alpha.
    private func warnOnMissingLocalizationKeys() {
        // Skip the probe entirely when the host process has no shipped
        // localizations (e.g. `swift test` CLI, where Bundle.main is
        // the xctest runner with only `en`). In production / Xcode the
        // iPad host loads `ja`, `en`, and `zh-Hans` so the check still
        // fires when it actually matters.
        let localizations = Bundle.main.localizations
        guard localizations.contains("ja") || localizations.contains("zh-Hans") else {
            return
        }

        // Probe a handful of representative keys rather than every key
        // — the point is to catch gross omissions (e.g. the whole quest
        // catalog was not imported), not individual typos.
        let probes = [
            quests.first?.titleKey,
            quests.first?.descriptionKey,
            quests.last?.titleKey
        ].compactMap { $0 }

        for key in probes {
            let localized = Bundle.main.localizedString(forKey: key, value: key, table: nil)
            if localized == key {
                // Foundation returns the key itself when no mapping exists.
                #if DEBUG
                print("[QuestStore] warning: missing localization key '\(key)'")
                #endif
            }
        }
    }
}
