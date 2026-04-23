# ADR-0010: Disaster events MVP (earthquake + flood)

- **Status**: Accepted
- **Date**: 2026-04-23
- **Context**: Phase 8. Phase 4〜6.1 finished PLATEAU alignment so tiles
  and terrain now share a real-world origin. First game feature that
  leans on that alignment: shake those tiles during a quake and let
  a rising water plane cover them during a flood.

## Decision

Ship a three-piece "disaster" module in `SDGGameplay/Disaster/`:

1. **`DisasterEvents.swift`** — four `GameEvent` value types:
   `EarthquakeStarted` / `EarthquakeEnded` /
   `FloodStarted` / `FloodEnded`. All `Sendable + Codable`, no
   scene-graph references.
2. **`DisasterStore.swift`** — `@Observable @MainActor` state
   machine (`.idle` / `.earthquakeActive` / `.floodActive`). Pure
   timer arithmetic; mutations via `intent(_:)`. The `.tick(dt:)`
   intent is dispatched every frame by `DisasterSystem` and ends
   the active state when the timer crosses zero, publishing the
   matching `Ended` event.
3. **`DisasterSystem.swift`** — RealityKit System that, each frame:
   * fires `Task { await store.intent(.tick) }` for next-frame state
     advance;
   * offsets every entity tagged `DisasterShakeTargetComponent` by
     a per-entity sinusoid when `.earthquakeActive`, or snaps them
     back to their cached `initialPosition` otherwise;
   * lazily builds a 3500 × 2000 m translucent water plane on the
     first `.floodActive` tick, then lerps its Y from `startY` to
     `targetY` by the store's `progress`.
4. **`DisasterAudioBridge.swift`** — event → `AudioEffect` bridge
   following the `AudioEventBridge` template.
   `.earthquakeRumble` / `.floodWater` are new `AudioEffect` cases;
   MVP uses existing Kenney SFX copied into
   `Resources/Audio/SFX/disaster/` as placeholders.

Debug triggers (🌋 / 💧 in `DebugActionsBar`) publish the trigger
intents directly. Quest-driven triggers are deferred to Phase 8.1.

## Context

### Why a Store + a System (and not just a System)

The disaster lifecycle is pure data. Extracting it into a Store:
- makes the timer math unit-testable without any RealityKit
  construction (see `DisasterStoreTests` — 9 tests, no scene);
- lets multiple consumers (shake animation + SFX bridge + future
  screen-tint shader + future UI status banner) subscribe to the
  same `Started` / `Ended` events without the animation System
  having to own SFX dispatching;
- matches the existing Store pattern (QuestStore, DialogueStore,
  VehicleStore) so code review and new-engineer onboarding stays
  homogeneous (AGENTS.md §1).

Putting the timer inside the System would have worked for MVP but
would bury the "two seconds" constant behind per-frame ECS code,
and any second consumer would have had to poll the System rather
than a value-type event — a step away from the event-driven
architecture ADR-0003 established.

### Why sinusoid shake (not perlin noise)

Perlin-noise shake reads more organic but requires a noise library
or handroll. Two decorrelated sines with per-entity phase offsets
(`sin(t·13 + idx·0.7)`, `sin(t·17 + idx·1.3)`) give each tile a
distinguishable motion without a library dependency, and matches
film-industry "earthquake" rules of thumb (two incommensurate
frequencies ≈ unpredictable feel). Good enough for MVP; Phase 8.1
can swap in GameplayKit's `GKPerlinNoiseSource` if playtest wants
a rougher texture.

### Why Y is untouched during shake

Phase 6.1 baked every PLATEAU building's foundation onto the DEM at
millimetre accuracy. A Y-axis shake would pierce the terrain or
lift buildings off it every frame. MVP shakes XZ only — visually
convincing ("the ground's moving laterally") while keeping the
expensive Phase 6.1 alignment intact.

### Why `DisasterShakeTargetComponent` per tile (not the corridor root)

Shaking the corridor root would move all 5 tiles together — reads
as a global camera shake rather than "buildings rocking". It would
also translate the player if the player were ever parented under
the corridor (currently they aren't, but the safer coupling is
per-tile). Per-tile also lets Phase 8.1 target a *subset* of tiles
(e.g. epicentre-local earthquakes).

### Why `DisasterSystem.boundStore` is a static var

RealityKit's `System.init(scene:)` signature doesn't accept app
state. Alternatives considered:

* **Component carrying a Store reference**: `Component` requires
  `Sendable`; `@Observable` classes aren't trivially Sendable.
  Rejected.
* **Subscribe to `EarthquakeTickFrame` events in the System**:
  System init doesn't see the EventBus either. Same chicken/egg.
* **Separate "tick driver" Task in RootView**: splits the
  System's frame logic across two owners, and the Task can't hook
  RealityKit's delta-time accurately.
* **Static `nonisolated(unsafe)` slot bound from RootView**: one
  reference, cleared on teardown, pragmatic MVP. Not a singleton —
  the slot is explicitly bound to the current scene's Store. The
  lint rule (ADR-0001, `ci_scripts/arch_lint.sh`) only rejects
  `static let shared`; `boundStore` passes. Chose this.

Phase 8.1 can revisit with a marker-entity indirection once the
Store has been audited for Sendable-ness.

### Why placeholder SFX

Real disaster SFX need either f.shera to record / source, or a
licensed library entry. Rather than block the Phase 8 visual MVP,
the audio bridge currently plays copies of existing Kenney files:
`Drill_Metal_Heavy.m4a` → `Earthquake_Rumble.m4a`,
`Feedback_Notify.m4a` → `Flood_Water.m4a`. Trivial to swap in
real assets — drop a new `.m4a` with the same filename into
`Resources/Audio/SFX/disaster/`.

## Implementation

### File layout

```
Packages/SDGGameplay/Sources/SDGGameplay/Disaster/
├── DisasterEvents.swift        # 4 GameEvent structs
├── DisasterStore.swift         # state machine
├── DisasterComponent.swift     # 2 ECS markers
├── DisasterSystem.swift        # animation + water plane
└── DisasterAudioBridge.swift   # event → SFX
```

```
Packages/SDGGameplay/Tests/SDGGameplayTests/Disaster/
├── DisasterStoreTests.swift         # 9 tests (pure state machine)
├── DisasterSystemTests.swift        # 5 tests (shake math, idle restore)
└── DisasterAudioBridgeTests.swift   # 5 tests (routing, lifecycle)
```

```
Resources/Audio/SFX/disaster/
├── Earthquake_Rumble.m4a   # placeholder (copy of Drill_Metal_Heavy)
└── Flood_Water.m4a         # placeholder (copy of Feedback_Notify)
```

### RootView wiring

* `@State disasterStore`, initialised with the placeholder bus in
  `init()` and rebound to the real bus in `bootstrap()`.
* `@State disasterAudioBridge`, created + started in `bootstrap()`,
  stopped in `teardown()`.
* `DisasterSystem.boundStore = disasterStore` immediately after
  rebind; cleared in `teardown()`.
* `registerSystemsOnce()` registers both component types + the
  System.
* Every PLATEAU corridor tile gets a `DisasterShakeTargetComponent`
  attached after the corridor loads.
* Two handlers — `handleEarthquakeTap`, `handleFloodTap` —
  dispatch trigger intents; wired to `DebugActionsBar`'s new
  `onEarthquakeTapped` / `onFloodTapped` closures.

### HUD surface

`DebugActionsBar` adds two buttons below the 📖 story button:
🌋 red `waveform.path.ecg` and 💧 blue `drop.fill`, matching the
existing 50×50 pt button style.

## Consequences

### Positive

* Unit-test coverage on the state machine with zero scene
  construction — 9 tests sub-millisecond each.
* Event-driven shape leaves room for future consumers (screen-
  tint shader, UI warning banner, quest bridge) without touching
  the System.
* Pipeline for placeholder → real SFX is a drop-in file swap.

### Negative / known limitations

* Debug-button trigger only — no quest-driven path in MVP.
* No audio stop-on-Ended; placeholder SFX self-terminate which
  papers over the gap.
* Static `boundStore` breaks the "no module-level state" purity
  of Phase 2 Beta — documented and scoped, but still a wart.
* One disaster at a time (state machine is one-of); concurrent
  disasters (earthquake + flood overlap) fall through to
  "second trigger no-ops".
* Shake amplitude is a constant (`shakeAmplitudeMeters = 0.3`);
  will feel too strong or too weak at some scene scales.
* Water plane reuses a single `ModelEntity` — fine visually, but
  re-entering `.floodActive` with a different start Y skips the
  spawn and can pop the plane abruptly. Acceptable for MVP.

## Follow-up (Phase 8.1 candidates)

- Add `quest.disasterOnComplete` JSON schema so quests can fire
  disasters without debug-button UI.
- Implement `AudioService.stop(_:)` and wire the `Ended` subscribers
  to it so longer loops work.
- Replace `boundStore` with a marker-entity pattern.
- Switch shake to perlin noise; add epicentre attenuation so
  distant tiles shake less than near ones.
- Source real earthquake / flood SFX.
- Ripple / reflection shader on the flood plane (Reality Composer
  Pro asset).

## References

- ADR-0001: Layered architecture
- ADR-0003: Event bus design
- ADR-0008: Phase 6.1 per-building DEM snap (shake Y guardrail)
- `Packages/SDGGameplay/Sources/SDGGameplay/Audio/AudioEventBridge.swift` —
  template for `DisasterAudioBridge`
