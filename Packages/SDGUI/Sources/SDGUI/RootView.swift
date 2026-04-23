// RootView.swift
// SDGUI
//
// Phase 1 POC root view — wires the complete gameplay loop:
// walk → drill → sample spawns → inventory.
//
// Scene layout (see GDD §1.3 / §1.5):
//   * Outcrop: 4-layer stacked box tree built by
//     `GeologySceneBuilder.loadOutcrop("test_outcrop")`. Each layer is
//     a child Entity with a toon-shaded `PhysicallyBasedMaterial`
//     (ADR-0004) + `GeologyLayerComponent` + `CollisionComponent`.
//   * Player: rounded-box capsule tagged with `PlayerComponent`, placed
//     on top of the outcrop. `PerspectiveCamera` parented at head height
//     (1.5 m). Yaw on the body, pitch on the camera (ADR P1-T1).
//   * Sample container: an invisible `Entity` that holds the spawned
//     sample cores. Each `SampleCreatedEvent` appends a
//     `SampleEntity.make(…)` child to it, 80 cm to the right of the
//     player, 50 cm up.
//
// Architectural contract (ADR-0001 §"Dependency flow"):
//   View                             Store                      Orchestrator / System
//   ─────                            ─────                      ──────────────────────
//   joystick onChange ──▶ intent(.move)     ─────────────────▶  PlayerControlSystem
//                                                                (updates Entity transforms)
//
//   DrillButton tap   ──▶ intent(.drillAt)  ──▶ publish DrillRequested
//                                                                ▼
//                                                     DrillingOrchestrator
//                                                     ├─▶ detectLayers(under: outcrop)
//                                                     ├─▶ buildSampleItem
//                                                     └─▶ publish SampleCreatedEvent
//                                                                ▼
//                                              InventoryStore.samples.append
//                                              RootView handler: SampleEntity.make(…)
//                                                                └─▶ add to sampleContainer

import SwiftUI
import RealityKit
import SDGCore
import SDGGameplay
import SDGPlatform

// MARK: - Scene references

/// Weakly-typed holder for long-lived scene Entities the view needs to
/// reach after `RealityView` has finished its initial build. Kept as a
/// plain `@MainActor` class so closures captured by the store
/// orchestrator (which outlive any particular view redraw) can still
/// read the current outcrop / player / sample container / environment.
@MainActor
final class POCSceneRefs {
    /// Root of the loaded geology outcrop, assigned once in the
    /// RealityView `make` closure.
    var outcropRoot: Entity?

    /// The player body. Used to read world position for drilling.
    var playerEntity: Entity?

    /// Invisible parent that collects spawned sample cores so they can
    /// be wiped en masse when the player clears inventory.
    var sampleContainer: Entity?

    /// Root of the loaded PLATEAU corridor (5 tiles). Optional because
    /// the USDZ files may be absent in test bundles or on first-run
    /// before the conversion pipeline has produced them.
    var environmentRoot: Entity?

    init() {}
}

// MARK: - RootView

/// Phase 1 POC root view.
///
/// Owns the full gameplay loop: player control, geology outcrop,
/// drilling → sample spawn, inventory presentation. All domain state
/// lives in Stores injected via `AppEnvironment`; nothing in this view
/// is a singleton (AGENTS.md Rule 2).
///
/// Availability: SDGUI pins iOS 18 / macOS 15 in its package manifest,
/// so no explicit `@available` marker is needed for `RealityView`,
/// `SceneUpdateContext.entities(matching:)`, or
/// `MeshResource.generateCylinder(height:radius:)`.
public struct RootView: View {

    /// Shared dependency container (EventBus, LocalizationService).
    @Environment(\.appEnvironment) private var env: AppEnvironment

    /// Player input store. Mutable `@State` so SwiftUI owns a single
    /// instance; swapped on `.task` to use the real EventBus.
    @State private var playerStore: PlayerControlStore

    /// Drilling state machine. Published `DrillRequested` / subscribed
    /// to `DrillCompleted` / `DrillFailed` once `start()` runs.
    @State private var drillingStore: DrillingStore

    /// Sample inventory backed by UserDefaults. Subscribes to
    /// `SampleCreatedEvent` once `start()` runs.
    @State private var inventoryStore: InventoryStore

    /// Retained reference to the orchestrator that converts
    /// `DrillRequested` into layer detection + SampleItem construction.
    @State private var orchestrator: DrillingOrchestrator?

    /// Long-lived Entity handles. Populated by `RealityView.make`.
    @State private var sceneRefs = POCSceneRefs()

    /// Latest joystick output. Mirrored into `PlayerControlStore` via
    /// `.onChange` so the joystick view stays decoupled from Stores.
    @State private var joystickAxis: SIMD2<Float> = .zero

    /// Frame-to-frame look baseline so we emit deltas instead of a
    /// growing absolute. Reset on gesture end.
    @State private var lastLookTranslation: CGSize = .zero

    /// Whether the inventory sheet is presented.
    @State private var showInventory: Bool = false

    /// Event subscription tokens retained so we can cancel on disappear.
    @State private var sampleCreatedToken: SubscriptionToken?
    @State private var moveIntentDebugToken: SubscriptionToken?

    // MARK: - Phase 2 Alpha services

    /// Loads PLATEAU Sendai corridor tiles from the app bundle.
    /// Reused across view rebuilds; cheap to construct.
    @State private var environmentLoader = PlateauEnvironmentLoader()

    /// Loads the decimated PLATEAU DEM terrain. Placed by the Phase 4
    /// envelope manifest so it shares a real-world origin with the
    /// building tiles. `nil` manifest → Phase 3 bottom-snap fallback.
    @State private var terrainLoader = TerrainLoader()

    /// CityGML `<gml:Envelope>`-derived real-world position table for
    /// every PLATEAU tile shipped (5 bldg + 1 dem). Loaded once from
    /// `Resources/Environment/plateau_envelopes.json` in `bootstrap()`
    /// and passed to both loaders so buildings + terrain agree on
    /// spatial anchoring. `nil` when the manifest file is missing
    /// (e.g. a stripped test bundle); loaders fall back to the
    /// Phase 2/3 bottom-snap layout in that case.
    @State private var envelopeManifest: EnvelopeManifest?

    /// Loads `Character_*.usdz` from the app bundle and attaches Player
    /// components + camera.
    @State private var characterLoader = CharacterLoader()

    /// SFX playback (AVAudioPlayer pool). @MainActor-isolated.
    @State private var audioService = AudioService()

    /// Subscribes the audio service to gameplay EventBus events
    /// (DrillRequested → .drillStart, SampleCreatedEvent → .feedbackSuccess,
    /// DrillFailed → .feedbackFailure). Started in `bootstrap()`.
    @State private var audioBridge: AudioEventBridge?

    // MARK: - Phase 2 Beta services

    /// Tracks all 13 quests' status; drives the QuestTracker HUD.
    @State private var questStore: QuestStore

    /// Plays story sequences from `Resources/Story/quest*.json`.
    /// Currently the chapter-1 intro only; later chapters wire later.
    @State private var dialogueStore: DialogueStore

    /// Workbench / microscope state. Closed by default; opened from
    /// the DebugActionsBar.
    @State private var workbenchStore: WorkbenchStore

    /// Vehicles (drones, drill cars). RootView is a subscriber to
    /// `VehicleSummoned` so it can spawn the matching scene Entity.
    @State private var vehicleStore: VehicleStore

    /// Phase 8: earthquake / flood state machine. Triggered from
    /// the 🌋 / 💧 debug buttons for MVP; quest-driven trigger is
    /// Phase 8.1 work (see ADR-0010).
    @State private var disasterStore: DisasterStore

    /// Phase 8: bridges `EarthquakeStarted` / `FloodStarted` to
    /// the platform `AudioService`. Started in `bootstrap()`.
    @State private var disasterAudioBridge: DisasterAudioBridge?

    /// True while the workbench full-screen cover is presented.
    @State private var showWorkbench: Bool = false

    /// Subscription tokens for the Phase 2 Beta event handlers, all
    /// torn down in `teardown()`.
    @State private var vehicleSummonedToken: SubscriptionToken?
    @State private var dialogueFinishedToken: SubscriptionToken?

    /// Phase 7: Vehicle enter/exit tokens. Retained so `teardown()`
    /// can cancel them; the bridge from events → scene graph mutation
    /// (camera re-parent) lives in `bootstrap()`.
    @State private var vehicleEnteredToken: SubscriptionToken?
    @State private var vehicleExitedToken: SubscriptionToken?

    /// Phase 7: player world position polled at 10 Hz (see
    /// `playerPositionPoll`). Feeds the HUD's Board button proximity
    /// check. Updating at every RealityKit frame would churn SwiftUI
    /// more than needed; 100 ms is plenty for a "walk up to the
    /// drone and tap Board" affordance.
    @State private var polledPlayerPosition: SIMD3<Float> = .zero

    /// Publisher that fires every 100 ms while the view is on-screen.
    /// Used to refresh `polledPlayerPosition`. A Combine `.autoconnect`
    /// keeps the timer running without manual start/stop bookkeeping.
    private let playerPositionPoll = Timer.publish(
        every: 0.1, on: .main, in: .common
    ).autoconnect()

    /// Look sensitivity: screen-space points per radian. 1000 pt ≈ full
    /// device width on iPad landscape; a 1000-pt drag rotating by one
    /// radian (≈57°) feels right on first play.
    private let lookSensitivity: Float = 1.0 / 1000.0

    /// Default public initializer. Allocates placeholder stores tied to
    /// an empty bus; `.task` re-binds them to the real env bus on first
    /// appearance. The placeholder cost is three fresh actors with no
    /// subscribers — negligible.
    public init() {
        let placeholder = EventBus()
        _playerStore = State(initialValue: PlayerControlStore(eventBus: placeholder))
        _drillingStore = State(initialValue: DrillingStore(eventBus: placeholder))
        _inventoryStore = State(initialValue: InventoryStore(eventBus: placeholder))
        _questStore = State(initialValue: QuestStore(eventBus: placeholder))
        _dialogueStore = State(initialValue: DialogueStore(eventBus: placeholder))
        _workbenchStore = State(initialValue: WorkbenchStore(eventBus: placeholder))
        _vehicleStore = State(initialValue: VehicleStore(eventBus: placeholder))
        _disasterStore = State(initialValue: DisasterStore(eventBus: placeholder))
    }

    public var body: some View {
        ZStack {
            realityContent
            HUDOverlay(
                playerStore: playerStore,
                drillingStore: drillingStore,
                inventoryStore: inventoryStore,
                vehicleStore: vehicleStore,
                joystickAxis: $joystickAxis,
                playerWorldPosition: polledPlayerPosition,
                onDrillTapped: handleDrillTap,
                onInventoryTapped: { showInventory = true },
                onBoardTapped: handleBoardTap,
                onExitVehicleTapped: handleExitVehicleTap
            )

            // Phase 2 Beta debug actions: opens workbench, summons a
            // drone, plays story dialogue. Will be replaced by in-world
            // interactions in Phase 3.
            DebugActionsBar(
                onWorkbenchTapped: handleWorkbenchTap,
                onDroneTapped: handleDroneSummonTap,
                onStoryTapped: handleStoryStartTap,
                onEarthquakeTapped: handleEarthquakeTap,
                onFloodTapped: handleFloodTap
            )

            // Top-left tracker showing the active quest.
            VStack {
                HStack {
                    QuestTrackerView(questStore: questStore)
                        .padding(.top, 40)
                        .padding(.leading, 40)
                    Spacer()
                }
                Spacer()
            }
            .allowsHitTesting(false)

            // Bottom-center dialogue card. Tap-to-advance lives in
            // the overlay itself; we want it to intercept those taps
            // *above* the gameplay layer, hence no allowsHitTesting(false).
            DialogueOverlay(dialogueStore: dialogueStore)
        }
        .ignoresSafeArea()
        // `fullScreenCover` is iOS-only; macOS falls back to `sheet`
        // so `swift test` on the macOS host can still compile this view.
        #if os(iOS)
        .fullScreenCover(isPresented: $showInventory) {
            InventoryView(
                inventoryStore: inventoryStore,
                onClose: { showInventory = false }
            )
        }
        .fullScreenCover(isPresented: $showWorkbench) {
            WorkbenchView(
                workbenchStore: workbenchStore,
                inventoryStore: inventoryStore,
                onClose: handleWorkbenchClose
            )
        }
        #else
        .sheet(isPresented: $showInventory) {
            InventoryView(
                inventoryStore: inventoryStore,
                onClose: { showInventory = false }
            )
        }
        .sheet(isPresented: $showWorkbench) {
            WorkbenchView(
                workbenchStore: workbenchStore,
                inventoryStore: inventoryStore,
                onClose: handleWorkbenchClose
            )
        }
        #endif
        .task { await bootstrap() }
        .onDisappear { teardown() }
        .onReceive(playerPositionPoll) { _ in
            // Pull the current player body position into SwiftUI land
            // so the HUD's Board-button proximity check can redraw.
            // Reads ignore the character Y (we only care about XZ for
            // "did the player walk up to the vehicle") but snapshotting
            // all 3 is cheap. Writes only fire the HUD redraw when the
            // @State value actually changes (SIMD3 is Equatable).
            if let body = sceneRefs.playerEntity {
                polledPlayerPosition = body.position(relativeTo: nil)
            }
        }
        .onChange(of: joystickAxis) { _, new in
            // Phase 7 joystick routing: the same on-screen stick drives
            // either the player or the occupied vehicle depending on
            // `vehicleStore.occupiedVehicleId`. The HUD joystick View stays
            // ignorant of which Store consumes its output — the swap lives
            // here in RootView so the AGENTS.md §1 View→Store→ECS boundary
            // holds (the View knows nothing about Stores; RootView picks
            // the recipient).
            //
            // Vertical axis is wired to 0 for MVP; a dedicated vertical
            // stick (drone up/down) lands in Phase 7.1.
            let playerStore = self.playerStore
            let vehicleStore = self.vehicleStore
            Task { @MainActor in
                if vehicleStore.occupiedVehicleId != nil {
                    await vehicleStore.intent(.pilot(axis: new, vertical: 0))
                } else {
                    await playerStore.intent(.move(new))
                }
            }
        }
    }

    // MARK: - RealityView content

    /// The 3D scene. Registers ECS systems once per process, loads the
    /// test outcrop from the app bundle, and places the player on top.
    ///
    /// Build logic is inlined inside the `RealityView` closure so the
    /// compiler can infer the concrete content type (iOS 18's closure
    /// parameter name is not stable across SDK versions; inference
    /// spares us from spelling it out).
    private var realityContent: some View {
        RealityView { content in
            Self.registerSystemsOnce()

            // 1. Fallback green ground plane — added only if the DEM
            //    terrain later fails to load. When terrain ships (the
            //    Phase 4 default), the plane would overlap with the
            //    DEM mesh and z-fight, so we skip it; the terrain's
            //    collision shapes catch the player via
            //    `PlayerControlSystem.snapToGround`. The plane entity
            //    is prepared here but only added to `content` inside
            //    the terrain-load failure path below.
            let fallbackGround = ModelEntity(
                mesh: .generatePlane(width: 3500, depth: 2000),
                materials: [SimpleMaterial(
                    color: .systemGreen,
                    roughness: 0.8,
                    isMetallic: false
                )]
            )
            fallbackGround.position = SIMD3<Float>(1250, -0.02, 500)
            fallbackGround.generateCollisionShapes(recursive: false)

            // 2a. CityGML envelope manifest (Phase 4 / ADR-0007). Loaded
            //     once and shared by terrain + building loaders so both
            //     anchor against the same real-world origin (spawn tile
            //     centre). Missing-manifest path is a soft fallback to
            //     the Phase 3 bottom-snap layout — tests and stripped
            //     bundles keep working.
            var loadedManifest: EnvelopeManifest?
            do {
                loadedManifest = try EnvelopeManifest(bundle: .main)
                envelopeManifest = loadedManifest
                print("[SDG-Lab][p4] envelope manifest loaded, \((loadedManifest?.envelopes.count ?? 0)) tiles")
            } catch {
                print("[SDG-Lab][p4] envelope manifest missing, falling back to Phase 3 layout: \(error)")
            }

            // 2b. PLATEAU DEM terrain. Positioned via the envelope
            //     manifest (or bottom-snapped if manifest is nil).
            //     Failure is soft: we drop in the flat fallback plane
            //     from step 1 instead so the player has something to
            //     stand on and the scene still launches.
            var loadedTerrain: Entity?
            do {
                let terrainLoader = TerrainLoader(
                    bundle: .main,
                    manifest: loadedManifest
                )
                let terrain = try await terrainLoader.load()
                content.add(terrain)
                loadedTerrain = terrain
            } catch {
                print("[SDG-Lab][p4] TerrainLoader failed, using flat fallback plane: \(error)")
                content.add(fallbackGround)
            }

            // 2c. PLATEAU corridor (5 pre-converted USDZ tiles).
            //     Phase 6.1 shipped tiles are already per-building DEM-
            //     snapped offline by `split_bldg_by_connectivity.py`,
            //     so the runtime's job is purely envelope-based tile
            //     placement — no sampler needed. Passing nil keeps the
            //     corridor loader on the "place by manifest, trust the
            //     mesh" path; the pre-snap work baked into the mesh
            //     means each building sits on its DEM without extra
            //     runtime cost (and without the 4 k-draw-call tax of
            //     the Phase 6 per-building split).
            //
            //     Player ground-follow still works: `PlayerControlSystem`
            //     locates the DEM via its own `TerrainComponent` query
            //     and calls `TerrainLoader.sampleTerrainY` directly,
            //     so it doesn't depend on a sampler closure here.
            do {
                let corridor = try await environmentLoader.loadDefaultCorridor(
                    manifest: loadedManifest
                )
                content.add(corridor)
                sceneRefs.environmentRoot = corridor
            } catch {
                print("[SDG-Lab] PlateauEnvironmentLoader failed: \(error)")
            }

            // Sample terrain Y at (0, 0) once the terrain is in the
            // scene. Used below for spawn Y. `nil` when terrain failed
            // to load — spawnY stays 0 (flat-plane fallback).
            var spawnY: Float = 0
            if let terrain = loadedTerrain,
               let surfaceY = TerrainLoader.sampleTerrainY(
                 in: terrain,
                 atWorldXZ: SIMD2<Float>(0, 0)
               ) {
                spawnY = surfaceY + 0.1
                print("[SDG-Lab][p4] terrain Y at spawn = \(surfaceY); spawning player at Y=\(spawnY)")
            }

            // 3. Test geology outcrop. Offset 10 m east of spawn so it
            //    doesn't overlap with the player and is reachable on
            //    foot. The outcrop is the drillable object until real
            //    geological data replaces it in Phase 2 Beta.
            let outcrop: Entity
            do {
                outcrop = try GeologySceneBuilder.loadOutcrop(
                    namedResource: "test_outcrop",
                    in: .main
                )
            } catch {
                print("[SDG-Lab] GeologySceneBuilder.loadOutcrop failed: \(error)")
                outcrop = ModelEntity(
                    mesh: .generatePlane(width: 10, depth: 10),
                    materials: [SimpleMaterial(color: .systemGreen, isMetallic: false)]
                )
            }
            outcrop.position = SIMD3<Float>(10, 0, 0)
            content.add(outcrop)
            sceneRefs.outcropRoot = outcrop

            // 4. Player character. CharacterLoader attaches
            //    PlayerComponent + PlayerInputComponent + a camera
            //    child at head height. Feet sit at entity-local Y=0;
            //    we spawn at (0, 0, 0) which is aobayamaCampus tile
            //    centre per PlateauTile.defaultSpawn.
            let body: Entity
            do {
                body = try await characterLoader.loadAsPlayer(.playerMale)
            } catch {
                // Fall back to the Phase 1 blue capsule so the app is
                // still controllable even if Meshy USDZ is missing.
                print("[SDG-Lab] CharacterLoader.loadAsPlayer failed: \(error)")
                let capsule = ModelEntity(
                    mesh: .generateBox(
                        size: SIMD3<Float>(0.5, 1.5, 0.5),
                        cornerRadius: 0.25
                    ),
                    materials: [SimpleMaterial(
                        color: .systemBlue,
                        roughness: 0.4,
                        isMetallic: false
                    )]
                )
                capsule.position = SIMD3<Float>(0, 0.75, 0)
                capsule.components.set(PlayerComponent())
                capsule.components.set(PlayerInputComponent())
                let camera = PerspectiveCamera()
                camera.position = SIMD3<Float>(0, 1.5, 0)
                capsule.addChild(camera)
                body = capsule
            }
            // Spawn XZ = (0, 0) (spawn tile's envelope centre, which
            // is the RealityKit world origin by EnvelopeManifest's
            // construction). Spawn Y = sampled terrain surface + 10 cm
            // when terrain loaded, else 0 for the flat-plane fallback.
            body.position = SIMD3<Float>(0, spawnY, 0)
            content.add(body)
            sceneRefs.playerEntity = body
            playerStore.attach(playerEntity: body)

            // 5. Invisible parent that collects spawned sample cores.
            let samples = Entity()
            samples.name = "SampleContainer"
            content.add(samples)
            sceneRefs.sampleContainer = samples
        }
        .gesture(lookGesture)
    }

    // MARK: - Drill button handler

    /// Converts a HUD DrillButton tap into a `DrillingStore` intent.
    /// The drill origin is the player's current world position; the
    /// Orchestrator resolves which outcrop entity to raycast against.
    private func handleDrillTap() {
        guard let player = sceneRefs.playerEntity else { return }
        let origin = player.position(relativeTo: nil)
        let store = drillingStore
        Task { @MainActor in
            await store.intent(.drillAt(
                origin: origin,
                direction: SIMD3<Float>(0, -1, 0),
                maxDepth: 10
            ))
        }
    }

    // MARK: - Phase 2 Beta debug actions

    /// 🔬 button → open the workbench / microscope full-screen cover.
    private func handleWorkbenchTap() {
        showWorkbench = true
        let store = workbenchStore
        Task { @MainActor in
            await store.intent(.openWorkbench)
        }
    }

    /// Cover dismissal → tell the store to close so its event chain
    /// matches the visible UI state.
    private func handleWorkbenchClose() {
        showWorkbench = false
        let store = workbenchStore
        Task { @MainActor in
            await store.intent(.closeWorkbench)
        }
    }

    /// 🚁 button → summon a drone next to the player. The actual
    /// scene-side Entity is created by the `VehicleSummoned`
    /// subscriber in `bootstrap()` — the Store only owns the data.
    private func handleDroneSummonTap() {
        guard let player = sceneRefs.playerEntity else { return }
        let playerPos = player.position(relativeTo: nil)
        let spawn = SIMD3<Float>(
            playerPos.x + 1.5,    // 1.5 m right of player
            playerPos.y + 0.5,    // 0.5 m off ground so propellers clear
            playerPos.z
        )
        let store = vehicleStore
        Task { @MainActor in
            await store.intent(.summon(.drone, position: spawn))
        }
    }

    /// ⬆️ Board button tapped. The HUD has already resolved which
    /// vehicle is nearest; we just forward the id to the Store. The
    /// actual camera re-parent + player hide runs out of the
    /// `VehicleEntered` subscriber in `bootstrap()` so the same
    /// behaviour fires whether boarding comes from the HUD button,
    /// a future scripted event, or a network multiplayer peer.
    private func handleBoardTap(_ vehicleId: UUID) {
        let store = vehicleStore
        Task { @MainActor in
            await store.intent(.enter(vehicleId: vehicleId))
        }
    }

    /// ⬇️ Exit button tapped. Symmetric with `handleBoardTap`; the
    /// `VehicleExited` subscriber does the scene graph work.
    private func handleExitVehicleTap() {
        let store = vehicleStore
        Task { @MainActor in
            await store.intent(.exit)
        }
    }

    /// 🌋 Phase 8 earthquake debug button. Fires a 2-second shake
    /// at intensity 0.7 via the Disaster store. `DisasterSystem`
    /// picks this up next frame.
    private func handleEarthquakeTap() {
        let store = disasterStore
        Task { @MainActor in
            await store.intent(.triggerEarthquake(
                intensity: 0.7,
                durationSeconds: 2.0,
                questId: nil
            ))
        }
    }

    /// 💧 Phase 8 flood debug button. Rises to `playerY + 2 m` over
    /// 5 s. The start-Y matches the player's current Y so the flood
    /// reads as "water rising from where you're standing"; the
    /// target gives 2 m of visible submersion without filling the
    /// whole level.
    private func handleFloodTap() {
        guard let player = sceneRefs.playerEntity else { return }
        let playerY = player.position(relativeTo: nil).y
        let store = disasterStore
        Task { @MainActor in
            await store.intent(.triggerFlood(
                startY: playerY,
                targetWaterY: playerY + 2,
                riseSeconds: 5.0,
                questId: nil
            ))
        }
    }

    /// 📖 button → load the chapter-1 intro and have the dialogue
    /// store play it. Phase 3 will trigger this automatically from
    /// quest state instead of a manual button.
    private func handleStoryStartTap() {
        let store = dialogueStore
        Task { @MainActor in
            do {
                let sequence = try StoryLoader.load(basename: "quest1.1", in: .main)
                await store.intent(.play(sequence: sequence))
            } catch {
                print("[SDG-Lab] StoryLoader failed for quest1.1: \(error)")
            }
        }
    }

    /// Subscriber for `VehicleSummoned` — builds the placeholder mesh
    /// with the right `vehicleId` and registers it with the Store so
    /// future `.pilot` calls can find it.
    @MainActor
    private func handleVehicleSummoned(_ event: VehicleSummoned) {
        let entity: Entity
        switch event.vehicleType {
        case .drone:
            entity = VehicleMeshFactory.makeDrone(vehicleId: event.vehicleId)
        case .drillCar:
            entity = VehicleMeshFactory.makeDrillCar(vehicleId: event.vehicleId)
        }
        entity.position = event.position
        // The simplest place to anchor a free-floating vehicle is the
        // sample container — it's a plain Entity already in the scene
        // tree as a sibling of the player and outcrop.
        if let container = sceneRefs.sampleContainer {
            container.addChild(entity)
        }
        vehicleStore.register(entity: entity, for: event.vehicleId)
    }

    /// Subscriber for `VehicleEntered` — re-parent the camera onto
    /// the vehicle so the player sees from the pilot seat. Hides
    /// the character body so the mesh doesn't clip through the
    /// cockpit / get carried awkwardly.
    ///
    /// MVP camera rig: 1 m above vehicle origin, 2 m behind (local
    /// +Z is the drone's "forward"; -Z puts the camera behind).
    /// Doesn't try to be clever — just a static offset. Phase 7.1
    /// will add a proper follow cam if playtest demands.
    @MainActor
    private func handleVehicleEntered(_ event: VehicleEntered) {
        guard
            let playerBody = sceneRefs.playerEntity,
            let camera = findPerspectiveCamera(under: playerBody),
            let vehicleEntity = vehicleStore.entity(for: event.vehicleId)
        else {
            print("[SDG-Lab][p7] VehicleEntered: camera or vehicle missing; " +
                  "skipping re-parent")
            return
        }
        camera.removeFromParent()
        vehicleEntity.addChild(camera)
        camera.transform.translation = SIMD3<Float>(0, 1.0, -2.0)
        // Disable AFTER camera detach; `isEnabled = false` propagates
        // to descendants, so a still-parented camera would go dark.
        playerBody.isEnabled = false
    }

    /// Symmetric counterpart to `handleVehicleEntered`: camera
    /// returns to the player, character re-enables, and the body
    /// is teleported under the vehicle so the player doesn't pop
    /// back to where they boarded (common annoyance on first
    /// prototypes of board/exit UX).
    @MainActor
    private func handleVehicleExited(_ event: VehicleExited) {
        guard let playerBody = sceneRefs.playerEntity else { return }
        // Camera may be under the vehicle or back on the player
        // depending on timing / duplicate events; search globally.
        let camera =
            findPerspectiveCamera(under: playerBody)
            ?? (vehicleStore.entity(for: event.vehicleId).flatMap { veh in
                findPerspectiveCamera(under: veh)
            })
        if let camera {
            camera.removeFromParent()
            playerBody.addChild(camera)
            // Back to head height — matches CharacterLoader default.
            camera.transform.translation = SIMD3<Float>(0, 1.5, 0)
        }
        playerBody.isEnabled = true
        if let vehicleEntity = vehicleStore.entity(for: event.vehicleId) {
            let vehiclePos = vehicleEntity.position(relativeTo: nil)
            // Place the player 0.5 m below vehicle origin so the feet
            // are on the ground when the vehicle was hovering. Phase
            // 7.1 can raycast the DEM for a real landing Y; MVP trusts
            // the vehicle's hover height.
            playerBody.position = SIMD3<Float>(
                vehiclePos.x, vehiclePos.y - 0.5, vehiclePos.z
            )
        }
    }

    /// Iterative DFS that returns the first `PerspectiveCamera`
    /// descendant of `root`. Camera is unnamed in both the Meshy
    /// character and the capsule fallback, so we match by type.
    @MainActor
    private func findPerspectiveCamera(under root: Entity) -> Entity? {
        var stack: [Entity] = [root]
        while let current = stack.popLast() {
            if current is PerspectiveCamera { return current }
            stack.append(contentsOf: current.children)
        }
        return nil
    }

    // MARK: - Bootstrap

    /// Runs once on first `.task`. Swaps the placeholder stores for
    /// ones bound to the real EventBus, starts their subscriptions,
    /// spins up the DrillingOrchestrator, and wires the
    /// `SampleCreatedEvent` → scene handler.
    @MainActor
    private func bootstrap() async {
        let bus = env.eventBus

        // Rebind stores to the real bus. Safe because no intents have
        // been submitted yet (we're inside the view's first .task).
        playerStore = PlayerControlStore(eventBus: bus)
        drillingStore = DrillingStore(eventBus: bus)
        inventoryStore = InventoryStore(eventBus: bus)

        // Re-attach the Store to the already-built player entity.
        if let body = sceneRefs.playerEntity {
            playerStore.attach(playerEntity: body)
        }

        await drillingStore.start()
        await inventoryStore.start()

        // Orchestrator reads outcropRoot via closure so it sees the
        // latest reference even if the scene is rebuilt later.
        let refs = sceneRefs
        let orch = DrillingOrchestrator(
            eventBus: bus,
            outcropRootProvider: { refs.outcropRoot }
        )
        await orch.start()
        orchestrator = orch

        // Subscribe to sample creation so newly drilled cores appear in
        // the scene next to the player.
        sampleCreatedToken = await bus.subscribe(SampleCreatedEvent.self) { event in
            await spawnSampleInScene(for: event.sample)
        }

        // AudioEventBridge: wire EventBus → AudioService so drilling
        // and sample events play their SFX without any caller having
        // to know about AVAudioPlayer. Kept as the last step so audio
        // doesn't trigger on startup-driven events.
        let bridge = AudioEventBridge(eventBus: bus, audioService: audioService)
        await bridge.start()
        audioBridge = bridge

        // Phase 2 Beta stores: rebind to real bus + start subscriptions.
        questStore = QuestStore(eventBus: bus)
        dialogueStore = DialogueStore(eventBus: bus)
        workbenchStore = WorkbenchStore(eventBus: bus)
        vehicleStore = VehicleStore(eventBus: bus)
        await questStore.start()

        // Phase 8: Disaster store + audio bridge. Rebind on the real
        // bus; bind the System to the fresh Store so
        // `DisasterSystem.update` sees today's state (and is safe to
        // unbind in teardown). Tag every PLATEAU corridor tile with
        // `DisasterShakeTargetComponent` so the earthquake System's
        // query picks them up.
        disasterStore = DisasterStore(eventBus: bus)
        DisasterSystem.boundStore = disasterStore
        let dBridge = DisasterAudioBridge(
            eventBus: bus,
            audioService: audioService
        )
        await dBridge.start()
        disasterAudioBridge = dBridge

        if let corridor = sceneRefs.environmentRoot {
            for tile in corridor.children {
                tile.components.set(DisasterShakeTargetComponent())
            }
        }

        // Subscribe to VehicleSummoned so we materialise the scene
        // entity. The Store only knows snapshots; we own the meshes.
        vehicleSummonedToken = await bus.subscribe(VehicleSummoned.self) { event in
            await handleVehicleSummoned(event)
        }

        // Phase 7: camera re-parent on board / disembark. Kept in
        // the RootView because it's scene-graph mutation (which the
        // Store must not touch); the Store has already flipped
        // `occupiedVehicleId` by the time we run, so the joystick
        // routing in `.onChange(of: joystickAxis)` is already aimed
        // at the right Store.
        vehicleEnteredToken = await bus.subscribe(VehicleEntered.self) { event in
            await handleVehicleEntered(event)
        }
        vehicleExitedToken = await bus.subscribe(VehicleExited.self) { event in
            await handleVehicleExited(event)
        }

        // When the chapter intro dialogue finishes, kick off the
        // first quest so the QuestTracker becomes visible. Phase 3
        // will replace this with a proper QuestCoordinator that
        // chains all 13 quests.
        dialogueFinishedToken = await bus.subscribe(DialogueFinished.self) { event in
            // Only the chapter-1 intro should trigger the auto-start;
            // ignore any other dialogue (e.g. mid-game NPC banter).
            guard event.sequenceId == "quest1.1" else { return }
            let store = questStore
            Task { @MainActor in
                await store.intent(.start(questId: "q.lab.intro"))
            }
        }

        // Developer-facing debug: log every move intent. Real HUD
        // subscribers land in Phase 2.
        if moveIntentDebugToken == nil {
            moveIntentDebugToken = await bus.subscribe(PlayerMoveIntentChanged.self) { event in
                print("player move axis=\(event.axis.x),\(event.axis.y)")
            }
        }
    }

    /// Builds a 3D representation of a newly drilled sample and parents
    /// it to the sample container, offset from the player so it lands
    /// in view rather than at the outcrop origin.
    @MainActor
    private func spawnSampleInScene(for sample: SampleItem) async {
        guard
            let container = sceneRefs.sampleContainer,
            let player = sceneRefs.playerEntity
        else { return }

        // Reconstruct `[LayerIntersection]` from the recorded layers.
        // We use depth-from-sample-top as entry/exit; the sample core's
        // geometry only cares about relative depth, not the original
        // world-space positions.
        var cursor: Float = 0
        var intersections: [LayerIntersection] = []
        intersections.reserveCapacity(sample.layers.count)
        for layer in sample.layers {
            let entry = cursor
            let exit = cursor + layer.thickness
            intersections.append(LayerIntersection(
                layerId: layer.layerId,
                nameKey: layer.nameKey,
                colorRGB: layer.colorRGB,
                entryDepth: entry,
                exitDepth: exit,
                thickness: layer.thickness,
                entryPoint: SIMD3<Float>(0, -entry, 0),
                exitPoint: SIMD3<Float>(0, -exit, 0)
            ))
            cursor = exit
        }

        do {
            let entity = try await SampleEntity.make(
                from: intersections,
                radius: 0.05,
                addOutline: true
            )
            let playerPos = player.position(relativeTo: nil)
            entity.position = SIMD3<Float>(
                playerPos.x + 0.8,  // 80 cm to the right of the player
                playerPos.y + 0.5,  // 50 cm above ground for "float"
                playerPos.z
            )
            container.addChild(entity)
        } catch {
            print("[SDG-Lab] SampleEntity.make failed: \(error)")
        }
    }

    // MARK: - Teardown

    /// Cancels subscriptions and stops Store lifecycles when the view
    /// disappears. Best-effort — scheduled on detached Tasks because
    /// `onDisappear` is synchronous.
    private func teardown() {
        let bus = env.eventBus
        if let token = sampleCreatedToken {
            Task { await bus.cancel(token) }
            sampleCreatedToken = nil
        }
        if let token = moveIntentDebugToken {
            Task { await bus.cancel(token) }
            moveIntentDebugToken = nil
        }
        if let token = vehicleSummonedToken {
            Task { await bus.cancel(token) }
            vehicleSummonedToken = nil
        }
        if let token = vehicleEnteredToken {
            Task { await bus.cancel(token) }
            vehicleEnteredToken = nil
        }
        if let token = vehicleExitedToken {
            Task { await bus.cancel(token) }
            vehicleExitedToken = nil
        }
        if let token = dialogueFinishedToken {
            Task { await bus.cancel(token) }
            dialogueFinishedToken = nil
        }
        let ds = drillingStore
        let inv = inventoryStore
        let orch = orchestrator
        let bridge = audioBridge
        let dBridge = disasterAudioBridge
        let qs = questStore
        Task {
            await ds.stop()
            await inv.stop()
            await qs.stop()
            if let orch { await orch.stop() }
            if let bridge { await bridge.stop() }
            if let dBridge { await dBridge.stop() }
        }
        audioBridge = nil
        disasterAudioBridge = nil
        // Clear the Phase 8 System binding so a subsequent view
        // creation re-binds to the fresh store rather than the
        // stale one from the previous scene.
        DisasterSystem.boundStore = nil
        audioService.stopAll()
        playerStore.detach()
    }

    // MARK: - Look gesture

    /// Right-half-screen `DragGesture`: translates raw point deltas
    /// into radian look-intents and forwards them to the Store.
    private var lookGesture: some Gesture {
        DragGesture(minimumDistance: 2, coordinateSpace: .global)
            .onChanged { value in
                let halfWidth = Self.currentScreenWidth / 2
                guard value.startLocation.x >= halfWidth else { return }

                let dx = value.translation.width - lastLookTranslation.width
                let dy = value.translation.height - lastLookTranslation.height
                lastLookTranslation = value.translation

                let yaw = Float(dx) * lookSensitivity
                let pitch = Float(-dy) * lookSensitivity

                let store = playerStore
                let bus = env.eventBus
                Task { @MainActor in
                    await store.intent(.look(SIMD2(yaw, pitch)))
                }
                Task { await bus.publish(LookPanEvent(dx: Double(dx), dy: Double(dy))) }
            }
            .onEnded { _ in
                lastLookTranslation = .zero
            }
    }

    // MARK: - ECS system registration

    @MainActor private static var systemsRegistered = false

    @MainActor
    private static func registerSystemsOnce() {
        guard !systemsRegistered else { return }
        PlayerComponent.registerComponent()
        PlayerInputComponent.registerComponent()
        PlayerControlSystem.registerSystem()
        // Phase 8: Disaster components + System. DisasterSystem's
        // Store binding happens after bootstrap constructs the Store
        // (via `DisasterSystem.shared(...).bind(disasterStore:)`).
        DisasterShakeTargetComponent.registerComponent()
        DisasterFloodWaterComponent.registerComponent()
        DisasterSystem.registerSystem()
        systemsRegistered = true
    }

    // MARK: - Screen width helper

    @MainActor
    private static var currentScreenWidth: CGFloat {
        #if canImport(UIKit)
        if let scene = UIApplication.shared.connectedScenes
            .compactMap({ $0 as? UIWindowScene })
            .first,
           let window = scene.windows.first {
            return window.bounds.width
        }
        return 1366
        #else
        return 1366
        #endif
    }
}
