// LayerType.swift
// SDGGameplay · Geology
//
// Enumerates the broad rock categories that appear in SDG-Lab's
// procedurally-built outcrops. The set is deliberately coarse: Phase 1
// just needs something to hang colour palettes and default physical
// properties off. Future phases (see GDD §1.3 "地层呈现机制") will refine
// this — e.g. splitting sedimentary into sandstone/mudstone/tuff — when
// the sample catalogue expands.
//
// The raw values are stable, capitalised English tokens so they can
// round-trip through JSON (see `GeologyLayerDefinition`) without
// localisation churn; human-readable names live in the String Catalog
// and are looked up via `GeologyLayerComponent.nameKey`.

import Foundation

/// Broad geological category of a rock layer, used to drive defaults
/// (density, colour hints) and to classify samples in the future
/// encyclopedia UI.
///
/// The cases cover the six types present in the legacy Unity project's
/// `GeologyLayer.cs` so data migration is loss-less. See
/// `/Users/user/Unity/GeoModelTest/Assets/Scripts/GeologySystem/GeologyLayer.cs`
/// for the original definition.
public enum LayerType: String, Codable, Sendable, CaseIterable {

    /// Surface soil / organic layer.
    case soil = "Soil"

    /// Sedimentary rock (sandstone, mudstone, limestone, tuffaceous…).
    /// The bulk of the Sendai corridor (青葉山層 etc.) falls here.
    case sedimentary = "Sedimentary"

    /// Igneous rock (extrusive or intrusive).
    case igneous = "Igneous"

    /// Metamorphic rock (schist, gneiss, marble…). Used for the
    /// crystalline basement in the POC outcrop.
    case metamorphic = "Metamorphic"

    /// Unconsolidated alluvial deposits (river terrace gravels, etc.).
    case alluvium = "Alluvium"

    /// Generic basement rock when a more specific classification is
    /// unavailable.
    case bedrock = "Bedrock"

    /// Nominal bulk density in g/cm³, used by future sample-mass
    /// calculations. Numbers are rounded midpoints of typical ranges
    /// from standard reference tables (e.g. Carmichael 1989); they are
    /// good enough for gameplay maths but must be overridden at the
    /// sample level when real lab data is available.
    ///
    /// The values are intentionally conservative so integer-times-density
    /// multiplications stay in a safe `Float` range.
    public var defaultDensity: Float {
        switch self {
        case .soil:        return 1.5
        case .alluvium:    return 1.9
        case .sedimentary: return 2.4
        case .metamorphic: return 2.8
        case .igneous:     return 2.9
        case .bedrock:     return 2.7
        }
    }
}
