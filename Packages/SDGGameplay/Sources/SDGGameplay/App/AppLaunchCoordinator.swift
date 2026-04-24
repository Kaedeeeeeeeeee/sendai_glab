// AppLaunchCoordinator.swift
// SDGGameplay · App
//
// Orchestrates the startup order of the Stores + their persistence.
// Before Phase 9-E every Store was individually `start()`-ed inside
// `RootView.bootstrap()`, which had grown to ~60 lines of scattered
// `await store.start()` calls and manual rehydrate plumbing. The
// coordinator centralises that:
//
//   * One place defines "what Stores does the app launch?"
//   * One place defines "in what order do they hydrate?"
//   * Tests can drive launch deterministically with `.inMemory`
//     persistences instead of polluting real UserDefaults.
//
// The coordinator itself owns no Store state; it is a lifecycle helper
// bound to an `EventBus` + a bundle of `*Persistence` values. The
// Stores are passed in at `launch(stores:)` time so the caller keeps
// their strong reference (SwiftUI `@State`, typically) and the
// coordinator is free to be short-lived.
//
// ## Three-layer compliance
//
// This type lives in SDGGameplay, not SDGUI, so it can depend on Stores
// and Persistences without pulling SwiftUI in. The caller (RootView)
// constructs it, invokes `launch`, and discards it — the coordinator
// holds no Store references after `launch` returns.

import Foundation
import SDGCore

/// Startup orchestrator for SDG-Lab's Stores + their persistences.
///
/// ### Construction
///
/// ```swift
/// let coordinator = AppLaunchCoordinator(
///     eventBus: env.eventBus,
///     persistences: .init(
///         inventory: .standard,
///         quest: .standard,
///         vehicle: .standard,
///         disaster: .standard,
///         playerPosition: .standard
///     )
/// )
/// ```
///
/// ### Launch
///
/// ```swift
/// await coordinator.launch(stores: .init(
///     player: playerStore,
///     inventory: inventoryStore,
///     drilling: drillingStore,
///     quest: questStore,
///     dialogue: dialogueStore,
///     workbench: workbenchStore,
///     vehicle: vehicleStore,
///     disaster: disasterStore
/// ))
/// ```
///
/// The call hydrates and subscribes each Store in the sequence below;
/// callers should not call `store.start()` themselves afterwards.
///
/// ### Order
///
/// Chosen so Stores that publish events during hydration publish them
/// only after all subscribers are live:
///
/// 1. `drillingStore.start()`      — subscribes to drill intents
/// 2. `inventoryStore.start()`     — rehydrates samples, subscribes to
///                                   `SampleCreatedEvent`
/// 3. `questStore.start()`         — rehydrates progress, subscribes to
///                                   `SampleCreatedEvent`
///     (must come AFTER inventoryStore so the first `SampleCreated`
///     fan-out has both subscribers live)
/// 4. `vehicleStore.start()`       — rehydrates + republishes
///                                   `VehicleSummoned` per snapshot
///     (republishes AFTER RootView has subscribed — see
///     `Docs/Phase9Integration/E.md` for the wiring order)
/// 5. `disasterStore.start()`      — rehydrates state + triggered ids
///
/// `dialogueStore` and `workbenchStore` currently have no-op `start()`s
/// and are accepted only so callers can be symmetric.
///
/// Player position is applied separately in a RealityView closure
/// (after the player entity exists) — see E.md.
///
/// ### Concurrency
///
/// `@MainActor` because every SDGGameplay Store is `@MainActor`. The
/// coordinator itself is a `final class` so it has a stable identity
/// for future extension (observers, completion callbacks), though for
/// MVP it just awaits and returns.
@MainActor
public final class AppLaunchCoordinator {

    // MARK: - Persistence bundle

    /// Thin aggregate of every `*Persistence` the app bootstraps.
    /// Lives here (not in Core) because only Gameplay knows the set.
    /// `Sendable` for symmetry with the Persistences; not stored
    /// anywhere off the main actor in MVP.
    public struct Persistences: Sendable {
        public var inventory: InventoryPersistence
        public var quest: QuestPersistence
        public var vehicle: VehiclePersistence
        public var disaster: DisasterPersistence
        public var playerPosition: PlayerPositionPersistence

        public init(
            inventory: InventoryPersistence = .standard,
            quest: QuestPersistence = .standard,
            vehicle: VehiclePersistence = .standard,
            disaster: DisasterPersistence = .standard,
            playerPosition: PlayerPositionPersistence = .standard
        ) {
            self.inventory = inventory
            self.quest = quest
            self.vehicle = vehicle
            self.disaster = disaster
            self.playerPosition = playerPosition
        }

        /// Convenience: all-in-memory (for tests / previews).
        public static var inMemory: Persistences {
            .init(
                inventory: .inMemory,
                quest: .inMemory,
                vehicle: .inMemory,
                disaster: .inMemory,
                playerPosition: .inMemory
            )
        }
    }

    // MARK: - Store bundle

    /// Bundle of every Store the coordinator knows how to launch.
    /// Intentionally NOT `Sendable` — every member is `@MainActor`,
    /// so the bundle can only exist on the main actor anyway and
    /// marking it `Sendable` would require each Store to cross actor
    /// boundaries the coordinator never actually hops through.
    public struct Stores {
        public var player: PlayerControlStore
        public var inventory: InventoryStore
        public var drilling: DrillingStore
        public var quest: QuestStore
        public var dialogue: DialogueStore
        public var workbench: WorkbenchStore
        public var vehicle: VehicleStore
        public var disaster: DisasterStore

        public init(
            player: PlayerControlStore,
            inventory: InventoryStore,
            drilling: DrillingStore,
            quest: QuestStore,
            dialogue: DialogueStore,
            workbench: WorkbenchStore,
            vehicle: VehicleStore,
            disaster: DisasterStore
        ) {
            self.player = player
            self.inventory = inventory
            self.drilling = drilling
            self.quest = quest
            self.dialogue = dialogue
            self.workbench = workbench
            self.vehicle = vehicle
            self.disaster = disaster
        }
    }

    // MARK: - Dependencies

    /// Shared EventBus. Stored so future `launch` callers don't need
    /// to re-supply it — mirrors the `.appEnvironment` pattern.
    public let eventBus: EventBus

    /// Persistences bundle. Exposed `public` so RootView can reuse the
    /// same `playerPosition` instance at save-on-teardown time without
    /// re-constructing the `.standard` façade.
    public let persistences: Persistences

    // MARK: - Init

    public init(eventBus: EventBus, persistences: Persistences = .init()) {
        self.eventBus = eventBus
        self.persistences = persistences
    }

    // MARK: - Launch

    /// Hydrate every Store and start its subscriptions in the order
    /// documented in the type header. Returns when all Stores are
    /// ready to accept intents.
    ///
    /// Player-entity-dependent steps (position hydrate, player attach)
    /// are NOT handled here — they run after the RealityView builds
    /// the player entity. See `Docs/Phase9Integration/E.md`.
    public func launch(stores: Stores) async {
        // 1. Drilling: no persistence today but owns a subscription
        //    and must be live before Inventory so a just-created
        //    sample lands in both stores on the same fan-out.
        await stores.drilling.start()

        // 2. Inventory: hydrates [SampleItem] + subscribes to
        //    SampleCreatedEvent.
        await stores.inventory.start()

        // 3. Quest: hydrates progress + subscribes to
        //    SampleCreatedEvent. Must come after Inventory so both
        //    subscribers are live before the first drill.
        await stores.quest.start()

        // 4. Dialogue / Workbench: no-op start()s today, kept for
        //    symmetry so adding a subscription later doesn't require
        //    touching call sites.
        await stores.dialogue.start()
        await stores.workbench.start()

        // 5. Vehicles: rehydrates + republishes `VehicleSummoned` per
        //    saved snapshot. Callers MUST have subscribed to
        //    `VehicleSummoned` before `launch` runs — see E.md.
        await stores.vehicle.start()

        // 6. Disaster: rehydrates state + triggeredQuestIds. No
        //    subscriptions of its own.
        await stores.disaster.start()
    }

    // MARK: - Player position helpers

    /// Load the last-known player pose, if any. Exposed as a helper
    /// so RootView can apply it to the player entity inside the
    /// RealityView closure (NOT from `launch`, because that call site
    /// doesn't have the entity yet). Returns `nil` on first launch
    /// and on a malformed blob (the latter swallowed to match the
    /// other Store `start()` behaviours).
    public func loadPlayerPosition() -> PlayerPositionPersistence.Snapshot? {
        do {
            return try persistences.playerPosition.load()
        } catch {
            return nil
        }
    }

    /// Persist the given player pose. Best-effort; errors are
    /// intentionally swallowed (matches `persistIgnoringFailure` in
    /// the Stores). Call from scene teardown or a debounced
    /// `onChange` observer — see E.md for wiring.
    public func savePlayerPosition(_ snapshot: PlayerPositionPersistence.Snapshot) {
        do {
            try persistences.playerPosition.save(snapshot)
        } catch {
            // Intentionally swallowed. A lost position write is a
            // minor annoyance on next launch, not a crash.
        }
    }
}

// MARK: - Store start() stubs for Dialogue / Workbench

// Until Phase 9-E every Dialogue / Workbench caller handled the
// "does this store need .start()?" question individually. For the
// coordinator to treat all Stores uniformly we need a no-arg
// `start()` on each. If the concrete store already has one (e.g.
// `InventoryStore`) we leave it alone; these extensions add a safe
// default where the Store has none yet.

extension DialogueStore {
    /// No-op lifecycle hook. `DialogueStore` currently holds no
    /// subscriptions; the extension exists so
    /// `AppLaunchCoordinator.launch` can call `.start()` symmetrically
    /// across every Store. Adding a real subscription later requires
    /// moving this method into the main file — the compiler will
    /// surface a duplicate declaration then.
    @MainActor public func start() async {
        // Intentionally empty.
    }
}

extension WorkbenchStore {
    /// See `DialogueStore.start()` above for the rationale.
    @MainActor public func start() async {
        // Intentionally empty.
    }
}
