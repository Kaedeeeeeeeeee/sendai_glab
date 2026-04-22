// VehicleType.swift
// SDGGameplay · Vehicles
//
// The vocabulary of kinds of vehicles the player can pilot. Phase 2
// Beta ships two entries — `drone` (6-DOF, hovers, no gravity) and
// `drillCar` (ground, gravity-bound, eventually tows a drill tower).
// GDD §1.3 "工具" puts both in the core tool loadout; the Encyclopedia
// (Phase 2 Alpha, GDD §1.4) will surface them with the `nameKey`
// localisation entries defined here.
//
// ## Why an enum, not a protocol
//
// A protocol with `DroneConfig` / `DrillCarConfig` conforming structs
// was considered. It was rejected for two reasons:
//
//   1. The parameter surface is tiny (three numbers + one Bool). A
//      protocol-based dispatch would add ceremony for no reuse.
//   2. ECS `Component` types cannot store an existential without
//      losing `Sendable`/`Codable`. An `enum` is already both; a
//      `any VehicleConfig` stored on the component would not be.
//
// If Phase 3 adds dozens of vehicle variants the tradeoff flips; at
// that point introducing a `VehicleConfig` protocol is a mechanical
// refactor (one new case → one new struct).
//
// ## Unit rationale
//
// `maxSpeed` is in **m/s** to match `PlayerControlSystem.moveSpeed`
// (`= 8.0`) and the rest of the gameplay layer. The scene-to-real
// conversion is 1 Unity metre = 1 SceneUnit = 1 m (PLATEAU pipeline
// outputs preserve this, see Tools/plateau-pipeline/convert.sh).

import Foundation

/// Distinct kinds of vehicles the player can pilot.
///
/// Each case carries its own motion envelope (`maxSpeed`,
/// `verticalSpeed`, `hasGravity`); `VehicleControlSystem` reads
/// these values per frame, no branching in the System itself.
///
/// The raw `String` backing lets us serialise to save files and use
/// cases as keys in localisation / UI asset lookups without a second
/// mapping table.
public enum VehicleType: String, Codable, Sendable, CaseIterable {

    /// Air-mobile scout, hovers and climbs. Used to reach rooftops
    /// and survey distant outcrops quickly.
    case drone

    /// Ground-bound, gravity-affected car that will later haul the
    /// 0-10m drill tower (GDD §1.3). Phase 2 Beta only implements
    /// the driving envelope; the drill mount is Phase 3.
    case drillCar

    // MARK: - Motion envelope

    /// Top planar speed in **m/s**. `PlayerControlSystem.moveSpeed`
    /// is 8 m/s for reference; vehicles are faster so the 5 km
    /// corridor in the Phase 2 Alpha playtest becomes crossable:
    ///
    ///   - Drone @ 15 m/s ≈ 54 km/h, crosses the corridor in <6 min.
    ///   - Drill car @ 12 m/s ≈ 43 km/h, slower because it is heavier
    ///     and in Phase 3 will carry a tower that clips on terrain.
    public var maxSpeed: Float {
        switch self {
        case .drone:    return 15.0
        case .drillCar: return 12.0
        }
    }

    /// Vertical climb/descent speed in **m/s**. Only the drone uses
    /// it; the drill car returns 0 so the System's "apply vertical
    /// input" branch becomes a no-op with no additional `if`.
    public var verticalSpeed: Float {
        switch self {
        case .drone:    return 8.0
        case .drillCar: return 0.0
        }
    }

    /// Whether the vehicle is subject to gravity while occupied.
    ///
    ///   - Drone: `false` — hover behaviour, altitude stays put
    ///     unless the pilot pushes the vertical axis.
    ///   - Drill car: `true` — rolls on terrain, Y-axis answers to
    ///     a fixed downward pull (`VehicleControlSystem.gravity`).
    public var hasGravity: Bool {
        switch self {
        case .drone:    return false
        case .drillCar: return true
        }
    }

    // MARK: - Presentation

    /// Localisation key for the vehicle's display name.
    ///
    /// The key lives in `Resources/Localization/Localizable.xcstrings`
    /// (three-language: ja / en / zh-Hans). Views resolve via
    /// `LocalizationService`.
    public var nameKey: String {
        switch self {
        case .drone:    return "vehicle.drone.name"
        case .drillCar: return "vehicle.drillCar.name"
        }
    }
}
