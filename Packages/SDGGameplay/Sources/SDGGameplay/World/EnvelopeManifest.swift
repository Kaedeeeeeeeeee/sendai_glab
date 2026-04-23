// EnvelopeManifest.swift
// SDGGameplay · World
//
// Phase 4 CityGML envelope alignment. The single source of truth for
// each PLATEAU tile's real-world bounding box in EPSG:6677 (Miyagi
// Plane Rectangular X, metres). The runtime consumes this instead of
// falling back to nusamai's AABB-centred output (ADR-0006 / ADR-0007).
//
// Why this file exists
// --------------------
// nusamai 0.1.0's glTF sink centres every tile on its own AABB,
// erasing the real-world origin carried by the source CityGML file.
// Every converted tile then claims to live at (0, 0, 0) in its local
// frame, which is why Phase 3 "bottom-snap to Y = 0" left buildings
// floating in the valleys: the scene had no shared coordinate anchor.
//
// Parsing the `<gml:Envelope>` block out of the original CityGML
// *before* nusamai destroys it — and persisting the result as a
// sidecar JSON — gives the Swift runtime the anchor it needs. This
// type is the Swift-side consumer of that JSON.
//
// Layer: Data / World. No RealityKit import on purpose. This is a
// pure value reader so both the `PlateauEnvironmentLoader` (buildings)
// and the soon-to-be-resurrected `TerrainLoader` (DEM) can share it
// without creating a mutual dep. `SIMD3` lives in `Foundation`'s
// `simd` umbrella, which keeps the dep graph thin.

import Foundation

// MARK: - PlateauEnvelope

/// A single tile's bounding box in EPSG:6677 (Miyagi Plane Rectangular
/// X, metres). `x` = easting, `y` = northing, `z` = orthometric height.
///
/// ### Coordinate convention
///
/// EPSG:6677 is an east-up projected CRS:
/// - `+x` points east
/// - `+y` points north
/// - `+z` points up (orthometric height above the ellipsoid)
///
/// RealityKit uses a right-handed, Y-up frame whose `+Z` points south
/// (per `PlateauTile` convention). The axis remap is handled in
/// `EnvelopeManifest.realityKitPosition(for:)`; this struct intentionally
/// stays in the raw CRS so it round-trips faithfully to/from JSON.
public struct PlateauEnvelope: Sendable, Codable, Equatable {

    /// South-west-bottom corner of the bounding box, in EPSG:6677 metres.
    public let lowerCornerM: SIMD3<Double>

    /// North-east-top corner of the bounding box, in EPSG:6677 metres.
    public let upperCornerM: SIMD3<Double>

    /// Componentwise midpoint of the two corners. This is the value the
    /// runtime typically places entities at — the corners themselves are
    /// mostly useful for debug overlays and sanity checks.
    public var centerM: SIMD3<Double> {
        (lowerCornerM + upperCornerM) * 0.5
    }

    public init(lowerCornerM: SIMD3<Double>, upperCornerM: SIMD3<Double>) {
        self.lowerCornerM = lowerCornerM
        self.upperCornerM = upperCornerM
    }

    // JSON uses snake_case, matching the convention the Python extractor
    // emits (`extract_envelopes.py`). We keep Swift properties camelCase
    // and map here so the public API stays idiomatic on both sides.
    private enum CodingKeys: String, CodingKey {
        case lowerCornerM = "lower_corner_m"
        case upperCornerM = "upper_corner_m"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        // Decode as a 3-element array of Double. Using a fixed-size
        // tuple would be brittle — if the pipeline ever emits extra
        // components (e.g. height uncertainty) we'd rather reject
        // explicitly than silently truncate.
        let lower = try c.decode([Double].self, forKey: .lowerCornerM)
        let upper = try c.decode([Double].self, forKey: .upperCornerM)
        guard lower.count == 3, upper.count == 3 else {
            throw DecodingError.dataCorruptedError(
                forKey: .lowerCornerM,
                in: c,
                debugDescription:
                    "lower_corner_m / upper_corner_m must be 3-element arrays; got " +
                    "\(lower.count) and \(upper.count)"
            )
        }
        self.lowerCornerM = SIMD3<Double>(lower[0], lower[1], lower[2])
        self.upperCornerM = SIMD3<Double>(upper[0], upper[1], upper[2])
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(
            [lowerCornerM.x, lowerCornerM.y, lowerCornerM.z],
            forKey: .lowerCornerM
        )
        try c.encode(
            [upperCornerM.x, upperCornerM.y, upperCornerM.z],
            forKey: .upperCornerM
        )
    }
}

// MARK: - EnvelopeManifest

/// Top-level manifest loaded from `plateau_envelopes.json`. Maps each
/// PLATEAU tile id to its real-world envelope so the runtime can place
/// entities using CityGML's preserved origin instead of nusamai's
/// AABB-centred output (ADR-0006 / ADR-0007).
///
/// ### Usage
///
/// ```swift
/// let manifest = try EnvelopeManifest()  // from app bundle
/// let entity = try await loader.loadTile(.aobayamaCampus)
/// if let p = manifest.realityKitPosition(for: "57403618") {
///     entity.position = p
/// }
/// ```
///
/// The class is not `@MainActor` — it's a pure value reader that holds
/// an immutable dictionary. `realityKitPosition(for:)` is pure
/// computation, safe to call from any actor.
///
/// `final class` (not `struct`) because callers typically retain one
/// instance and pass it around by reference through init injection;
/// a struct would force needless copies when the payload is dozens of
/// envelopes.
public final class EnvelopeManifest: @unchecked Sendable {

    /// The tile the player spawns on. Its envelope centre becomes the
    /// RealityKit world origin (0, 0, 0); every other entity's position
    /// is computed relative to it.
    public let spawnTileId: String

    /// All loaded envelopes, keyed by tile id (e.g. `"57403617"`,
    /// `"574036_05_dem"`).
    public let envelopes: [String: PlateauEnvelope]

    // MARK: - LoadError

    /// Errors surfaced during manifest load. The three cases map to the
    /// three distinct failure surfaces: missing resource, malformed
    /// JSON, and semantically invalid manifest (spawn id not present).
    public enum LoadError: Error, CustomStringConvertible {

        /// No file named `<basename>.json` was found in the bundle.
        case resourceNotFound(basename: String)

        /// The JSON was found but did not conform to the expected
        /// schema.
        case decodingFailed(underlying: Error)

        /// The manifest's `meta.spawn_tile_id` did not match any key in
        /// `envelopes`. This is almost always a data-pipeline bug: the
        /// Python extractor was asked to mark a tile as spawn that it
        /// didn't also emit.
        case missingSpawnTile(id: String)

        public var description: String {
            switch self {
            case .resourceNotFound(let basename):
                return "EnvelopeManifest: resource `\(basename).json` not found in bundle"
            case .decodingFailed(let underlying):
                return "EnvelopeManifest: JSON decoding failed — \(underlying)"
            case .missingSpawnTile(let id):
                return "EnvelopeManifest: spawn_tile_id `\(id)` is not present in envelopes"
            }
        }
    }

    // MARK: - Init

    /// Load the manifest from the app bundle. Defaults to
    /// `plateau_envelopes.json`; the basename parameter exists mainly
    /// so tests can drop in a fixture file without colliding with the
    /// production name.
    ///
    /// - Parameter bundle: The bundle to search. Defaults to
    ///   `Bundle.main`. Tests that ship a fixture via
    ///   `resources: [.process("Resources")]` can pass `Bundle.module`.
    /// - Parameter basename: File basename without the `.json`
    ///   extension. Defaults to `"plateau_envelopes"`.
    /// - Throws: `LoadError.resourceNotFound` if the file is missing,
    ///   `.decodingFailed` if the JSON is malformed, or
    ///   `.missingSpawnTile` if `spawn_tile_id` doesn't match an
    ///   envelope key.
    public convenience init(
        bundle: Bundle = .main,
        basename: String = "plateau_envelopes"
    ) throws {
        guard let url = bundle.url(forResource: basename, withExtension: "json") else {
            throw LoadError.resourceNotFound(basename: basename)
        }
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            // Bundle told us the URL exists but reading failed — treat
            // that as a decoding failure for the caller's purposes.
            // The underlying error carries enough context for logs.
            throw LoadError.decodingFailed(underlying: error)
        }
        try self.init(jsonData: data)
    }

    /// Test-friendly init that skips the bundle lookup. The tests in
    /// this module use this with an inline JSON fixture string so they
    /// don't depend on the real `plateau_envelopes.json` (which is
    /// produced by a Python pipeline on another agent's schedule).
    public init(jsonData: Data) throws {
        let decoded: Manifest
        do {
            decoded = try JSONDecoder().decode(Manifest.self, from: jsonData)
        } catch {
            throw LoadError.decodingFailed(underlying: error)
        }
        // Lift the nested layout (`meta` + `envelopes`) to the flat
        // public shape. We only care about `spawn_tile_id` from meta;
        // the rest (generator name, timestamp) is for humans reading
        // the JSON and doesn't need to survive in the runtime model.
        self.spawnTileId = decoded.meta.spawnTileId
        self.envelopes = decoded.envelopes

        // Validate semantic invariants last so a structural JSON error
        // surfaces before a "missing spawn tile" confusion.
        guard envelopes[spawnTileId] != nil else {
            throw LoadError.missingSpawnTile(id: spawnTileId)
        }
    }

    // MARK: - Query

    /// Compute a tile's RealityKit position relative to the spawn
    /// tile's envelope centre. Returns `nil` if the tile id is not in
    /// the manifest — callers decide whether that's a warning or a
    /// fatal error for their layer.
    ///
    /// ### Coordinate mapping (EPSG:6677 → RealityKit Y-up right-handed)
    ///
    /// Let `env = envelopes[tileId]!.centerM` and
    /// `spawn = envelopes[spawnTileId]!.centerM`. Both are in metres
    /// with `x = easting`, `y = northing`, `z = elevation`.
    ///
    ///   RK x  =   (env.x - spawn.x)       // east → +X
    ///   RK y  =   (env.z - spawn.z)       // elevation → +Y
    ///   RK z  = -(env.y - spawn.y)        // north in EPSG → -Z in RK
    ///                                     //   (RK +Z points south,
    ///                                     //    per PlateauTile.swift)
    ///
    /// The axis flip on Z matters: without it, a tile north of spawn
    /// would end up at +Z, putting it *behind* the player instead of
    /// in front. Pinned in the unit tests so a refactor that forgets
    /// the minus sign fails fast.
    ///
    /// - Parameter tileId: A tile id key as it appears in the JSON
    ///   manifest (e.g. `"57403617"` or `"574036_05_dem"`).
    /// - Returns: Position in RealityKit world space, or `nil` if the
    ///   tile id is unknown.
    public func realityKitPosition(for tileId: String) -> SIMD3<Float>? {
        guard
            let env = envelopes[tileId],
            let spawn = envelopes[spawnTileId]
        else {
            return nil
        }
        let envC = env.centerM
        let spawnC = spawn.centerM
        let dx = envC.x - spawnC.x   // easting delta
        let dy = envC.y - spawnC.y   // northing delta
        let dz = envC.z - spawnC.z   // elevation delta
        return SIMD3<Float>(
            Float(dx),
            Float(dz),
            Float(-dy)
        )
    }

    // MARK: - JSON schema mirror

    /// Private JSON-decodable mirror of the on-disk schema. Kept
    /// nested so it doesn't leak into the module's public surface —
    /// the public API is just `EnvelopeManifest` + `PlateauEnvelope`.
    ///
    /// Schema:
    /// ```json
    /// {
    ///   "meta": { "spawn_tile_id": "...", ... },
    ///   "envelopes": { "<tileId>": { "lower_corner_m": [...],
    ///                                "upper_corner_m": [...] }, ... }
    /// }
    /// ```
    private struct Manifest: Decodable {
        let meta: Meta
        let envelopes: [String: PlateauEnvelope]

        struct Meta: Decodable {
            let spawnTileId: String

            // Only `spawn_tile_id` is consumed. Other fields
            // (source_crs, target_crs, generated_by, generated_at) are
            // informational and deliberately not decoded — adding a
            // field on the Python side mustn't break Swift decoding.
            private enum CodingKeys: String, CodingKey {
                case spawnTileId = "spawn_tile_id"
            }
        }
    }
}
