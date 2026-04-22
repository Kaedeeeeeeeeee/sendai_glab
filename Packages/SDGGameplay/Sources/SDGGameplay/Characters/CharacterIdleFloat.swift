// CharacterIdleFloat.swift
// SDGGameplay · Characters
//
// Fakes an idle "breathing" animation for characters whose Meshy
// preview mesh has no rigging (see Docs/MeshyGenerationLog.md §"No
// rigging / no animation"). The component records a baseline Y and
// parameters; the System walks matching entities each frame and sets
// `entity.position.y` to a sine around that baseline.
//
// **Not for player entities.** `PlayerControlSystem` already writes
// `entity.position` every frame from the joystick integration, and
// both Systems mutating the same transform race. `RootView` /
// `CharacterLoader.loadAsPlayer` deliberately skip this component.
// If an NPC carrying idle-float later gets possessed by the player
// (cutscene takeover, e.g.), remove the component first.

import Foundation
import RealityKit

/// ECS component describing a per-entity fake-breathing float.
///
/// A System reads these values each frame and drives
/// `entity.position.y = baseY + amplitude * sin(2π · frequency · t + phase)`.
/// The component is otherwise passive data — matches ADR-0001's rule
/// that Components hold data and Systems hold behaviour.
public struct CharacterIdleFloatComponent: Component, Sendable {

    /// Baseline Y (metres, world space) around which the entity
    /// oscillates. Populated by whoever adds the component — typically
    /// the entity's spawn position's `y`. The System leaves X/Z alone.
    public var baseY: Float

    /// Peak displacement either side of `baseY` (metres). Default
    /// ±2 cm matches the subtle chest rise of idle breathing; larger
    /// values start looking like levitation.
    public var amplitude: Float

    /// Oscillation frequency in Hz. Default 0.5 Hz = one full
    /// breathe-in-out every two seconds, which tracks resting human
    /// breathing (~12–18 breaths/min ≈ 0.2–0.3 Hz, rounded up so the
    /// motion reads in a game camera).
    public var frequency: Float

    /// Per-entity phase offset (radians). Pass a random value when
    /// spawning multiple NPCs in the same frame or they all breathe
    /// in unison, which looks cultish. 0 is fine for a single NPC.
    public var phase: Float

    public init(
        baseY: Float,
        amplitude: Float = 0.02,
        frequency: Float = 0.5,
        phase: Float = 0
    ) {
        self.baseY = baseY
        self.amplitude = amplitude
        self.frequency = frequency
        self.phase = phase
    }
}

/// System driving `CharacterIdleFloatComponent`-tagged entities.
///
/// Accumulates elapsed time locally: `SceneUpdateContext` exposes
/// `deltaTime` per frame but no running clock, and we need a
/// monotonically increasing `t` so the sine keeps phase between
/// frames.
///
/// The System stays self-contained and scene-scoped (one instance per
/// RealityKit `Scene`), matching the way `PlayerControlSystem` is
/// registered. No Store or EventBus dependencies — ADR-0001 layer
/// rules are honoured.
///
/// `@MainActor` on the class lifts the isolation onto every helper
/// method too. Helpers like `applyFloat(to:)` touch
/// `entity.position` / `entity.components`, both of which are
/// declared `@MainActor` on the RealityKit side; without the class-
/// level annotation Swift 6's strict-concurrency flags each helper.
@MainActor
public final class CharacterIdleFloatSystem: System {

    /// No ordering constraints: we only touch transforms, and doing
    /// so before or after physics does not matter for decorative
    /// breathing. Explicit empty list for clarity.
    public static let dependencies: [SystemDependency] = []

    /// Matches any entity carrying the component. The filter is
    /// cheap; query results are lazy so idle scenes with no NPCs pay
    /// essentially nothing here.
    private let query: EntityQuery

    /// Running total of frame `deltaTime`s, in seconds. Float is fine
    /// for gameplay sessions (24-hour drift at 60 FPS is still well
    /// within Float precision for the sin argument).
    private var elapsedTime: Float = 0

    public init(scene: Scene) {
        self.query = EntityQuery(where: .has(CharacterIdleFloatComponent.self))
    }

    public func update(context: SceneUpdateContext) {
        let deltaTime = Float(context.deltaTime)
        // Defensive: a zero or negative delta (first frame, paused
        // scene) would freeze `elapsedTime` or run it backwards.
        // Skipping keeps positions stable in those edge cases.
        guard deltaTime > 0 else { return }
        elapsedTime += deltaTime

        for entity in context.entities(
            matching: query,
            updatingSystemWhen: .rendering
        ) {
            applyFloat(to: entity)
        }
    }

    // MARK: - Per-entity work

    /// Compute and apply the sine-wave offset for one entity.
    ///
    /// Exposed as `internal` so `CharacterIdleFloatSystemTests` can
    /// validate the math without constructing a full `Scene`. Using
    /// `elapsedTime` as the time source keeps the method self-contained
    /// once the instance has ticked forward.
    @discardableResult
    func applyFloat(to entity: Entity) -> Float {
        guard let component = entity.components[CharacterIdleFloatComponent.self] else {
            return entity.position.y
        }
        let twoPi: Float = .pi * 2
        let y = component.baseY
            + component.amplitude
            * sin(twoPi * component.frequency * elapsedTime + component.phase)
        entity.position.y = y
        return y
    }

    /// Current accumulated time, for tests. `internal` to avoid
    /// leaking an implementation detail through the public API.
    var elapsedTimeForTesting: Float { elapsedTime }

    /// Manually advance the clock — test hook so
    /// `applyFloat(to:)` can be exercised at a known `t` without a
    /// live scene. Production code has no caller here.
    func tickForTesting(by deltaTime: Float) {
        elapsedTime += deltaTime
    }
}
