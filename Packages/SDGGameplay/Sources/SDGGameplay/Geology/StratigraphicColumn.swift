// StratigraphicColumn.swift
// SDGGameplay · Geology
//
// Phase 9 Part B data contract for the 5-tile regional column system.
// Replaces the single "test_outcrop" drilling with per-region
// stratigraphic columns: drilling anywhere inside a PLATEAU tile pulls
// from that tile's column, and outside the corridor the detector
// surfaces `DrillError.outOfSurveyArea` (see `DrillingErrors.swift`).
//
// ## Scope
//
// These types model the *regional* stratigraphy (i.e. the column that
// would be observed at any drill site inside a tile). They are a
// deliberate companion to `GeologyLayerDefinition` / `TestOutcropConfig`
// — the Phase 1 test outcrop types are kept intact so the existing
// entity-tree detection path still compiles. The new types simply
// supply a second data source that the drilling orchestrator prefers
// when a region registry is wired in.
//
// Every shipped region JSON carries `confidence: "needs_geologist_review"`
// because the values were assembled from public sources (Wikipedia,
// JAGUE field-trip guides, 日本地質学会 literature) by a non-geologist.
// f.shera — the project's maintainer and a geologist — will review
// and correct the values post-ship.

import Foundation

// MARK: - StratigraphicLayer

/// One layer in a regional stratigraphic column.
///
/// Differs from `GeologyLayerDefinition` in two important ways:
///
///   1. **No `type: LayerType`**: the regional columns use a free-form
///      `lithology` string (e.g. `"mudstone"`, `"tuffaceous sandstone"`)
///      because Japanese stratigraphic literature is messier than the
///      coarse six-bucket `LayerType` enum. Callers that need
///      categorical filtering can pattern-match on the prefix.
///
///   2. **`id` is region-scoped**: a layer's `id` follows the pattern
///      `"<regionId>.<formationKey>"` (e.g. `"aobayama-campus.mukaiyama"`)
///      so the same formation appearing in multiple tiles still gets
///      distinct ids. This keeps `GeologyLayerComponent.layerId` unique
///      across the corridor without needing a composite key.
public struct StratigraphicLayer: Codable, Sendable, Equatable, Hashable {

    /// Region-scoped stable identifier (e.g. `"aobayama-campus.mukaiyama"`).
    /// The registry enforces uniqueness inside each column; cross-column
    /// duplicates are expected and intentional (same formation, different
    /// tile).
    public let id: String

    /// Localisation key for the layer's human-facing display name.
    /// Pattern: `"geology.layer.<formationKey>.name"`. The same
    /// `nameKey` can be shared by multiple layers across different
    /// regions — e.g. both `aobayama-campus` and `aobayama-north`
    /// cite the 向山層 with `"geology.layer.mukaiyama.name"`.
    public let nameKey: String

    /// Layer thickness in metres, along world Y.
    public let thickness: Float

    /// Hex-encoded RGB colour (`"#AABBCC"`, leading `#` optional).
    /// Parsing happens lazily at slab-build time via `colorRGB` below;
    /// a malformed value yields `SIMD3<Float>(0.5, 0.5, 0.5)` so a
    /// single typo doesn't blank out an entire tile.
    public let colorHex: String

    /// Free-form lithology descriptor (e.g. `"mudstone"`,
    /// `"tuffaceous sandstone"`, `"alluvium"`). No enum because the
    /// Japanese stratigraphic vocabulary is open-ended and the game
    /// only uses this for debug overlays and future encyclopedia
    /// cross-references. Uncategorised layers pass through verbatim.
    public let lithology: String

    public init(
        id: String,
        nameKey: String,
        thickness: Float,
        colorHex: String,
        lithology: String
    ) {
        self.id = id
        self.nameKey = nameKey
        self.thickness = thickness
        self.colorHex = colorHex
        self.lithology = lithology
    }

    /// Parsed RGB colour in the 0…1 range. Returns a neutral grey on
    /// parse failure so a single typo doesn't blank out a whole tile.
    ///
    /// Kept as a computed property (not a stored field) so the JSON
    /// round-trips cleanly — storing both `colorHex` and a derived
    /// `SIMD3<Float>` would risk divergence if either one is mutated.
    public var colorRGB: SIMD3<Float> {
        var text = colorHex
        if text.hasPrefix("#") { text.removeFirst() }
        guard text.count == 6, let value = UInt32(text, radix: 16) else {
            return SIMD3<Float>(0.5, 0.5, 0.5)
        }
        let r = Float((value >> 16) & 0xFF) / 255
        let g = Float((value >> 8) & 0xFF) / 255
        let b = Float(value & 0xFF) / 255
        return SIMD3<Float>(r, g, b)
    }
}

// MARK: - StratigraphicColumn

/// A single region's top-down stratigraphic column.
///
/// Decoded from a JSON file in `Resources/Geology/regions/`. The
/// `layers` array is ordered **top-to-bottom**: element 0 is the
/// surface, and cumulative thickness stacks downwards along -Y from
/// the terrain surface at the drill site.
///
/// The bottom layer is conventionally named "basement" (基盤) and is
/// assumed to have effectively unlimited thickness. Callers clip the
/// last layer to whatever depth remains after the drill's `maxDepth`
/// is consumed.
public struct StratigraphicColumn: Codable, Sendable, Equatable, Hashable {

    /// Stable, human-authored region identifier matching the JSON
    /// filename without extension (e.g. `"aobayama-campus"` →
    /// `aobayama-campus.json`).
    public let regionId: String

    /// Localisation key for the region's display name
    /// (e.g. `"geology.region.aobayama-campus.name"`). The UI reads
    /// this, never the regionId, so translations stay independent of
    /// the dev-facing identifier.
    public let nameKey: String

    /// Short, free-form source attribution (e.g.
    /// `"Wikipedia + 日本地質学会 巡検資料"`). Not localised — this is a
    /// breadcrumb for audit and geologist review, not a user-facing
    /// citation.
    public let source: String

    /// Self-declared confidence tag. Every shipped region currently
    /// carries `"needs_geologist_review"` because the values were
    /// assembled by a non-geologist. f.shera will update to
    /// `"reviewed"` after the geological audit.
    public let confidence: String

    /// Layers in top-to-bottom order (surface first).
    public let layers: [StratigraphicLayer]

    public init(
        regionId: String,
        nameKey: String,
        source: String,
        confidence: String,
        layers: [StratigraphicLayer]
    ) {
        self.regionId = regionId
        self.nameKey = nameKey
        self.source = source
        self.confidence = confidence
        self.layers = layers
    }

    // MARK: - Clipping

    /// Clip the column into a sequence of `LayerSlab`s, starting from
    /// `surfaceY` and descending at most `maxDepth` metres. The last
    /// layer is treated as unbounded; it absorbs whatever depth
    /// remains after the earlier layers' thicknesses are consumed.
    ///
    /// This is the bridge between the data types and
    /// `GeologyDetectionSystem.computeIntersections(...)` — the
    /// registry invokes `clipToSlabs` to produce the slab array that
    /// the pure detector expects.
    ///
    /// - Parameters:
    ///   - surfaceY: World-space Y (metres) of the drill origin's
    ///     surface projection. The top of the first layer sits here.
    ///   - maxDepth: Maximum depth of the drill pass, metres. The
    ///     terminator clips the last layer.
    ///   - xzCenter: World-space (X, Z) to stamp into each slab's
    ///     `xzCenter`. Typically the drill's origin (X, Z).
    /// - Returns: Slabs ordered top-to-bottom, matching the
    ///   detector's preferred input shape. An empty return means
    ///   either the column has no layers or `maxDepth <= 0`.
    public func clipToSlabs(
        surfaceY: Float,
        maxDepth: Float,
        xzCenter: SIMD2<Float>
    ) -> [LayerSlab] {
        guard !layers.isEmpty, maxDepth > 0 else { return [] }

        var slabs: [LayerSlab] = []
        slabs.reserveCapacity(layers.count)

        var currentTop = surfaceY
        let floorY = surfaceY - maxDepth

        for (index, layer) in layers.enumerated() {
            let isLast = index == layers.count - 1
            // The basement (last layer) is effectively unbounded; it
            // stretches down to the drill's floor regardless of its
            // nominal thickness. Every other layer honours its
            // declared thickness.
            let declaredBottom = currentTop - max(0, layer.thickness)
            let bottom = isLast ? floorY : declaredBottom

            // Stop once we've fallen below the drill's floor — any
            // remaining layers sit outside the drill's reach and
            // don't belong in the slab list.
            guard currentTop > floorY else { break }

            // Clamp to the drill floor so the final slab doesn't
            // claim more thickness than the drill reaches. Slabs whose
            // clipped thickness drops to zero are skipped; the
            // detector's own `minimumThickness` filter would discard
            // them anyway, but keeping the list minimal keeps the log
            // output readable.
            let clippedBottom = max(bottom, floorY)
            if currentTop - clippedBottom <= 0 {
                break
            }

            slabs.append(LayerSlab(
                layerId: layer.id,
                nameKey: layer.nameKey,
                colorRGB: layer.colorRGB,
                topY: currentTop,
                bottomY: clippedBottom,
                xzCenter: xzCenter
            ))

            currentTop = declaredBottom
        }

        return slabs
    }
}
