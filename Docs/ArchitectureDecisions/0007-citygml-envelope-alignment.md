# ADR-0007: PLATEAU alignment via CityGML envelope extraction

- **Status**: Accepted
- **Date**: 2026-04-23
- **Context**: Phase 4 follow-up to ADR-0006 (DEM alignment deferred
  from Phase 3)

## Decision

Extract each PLATEAU source file's `<gml:Envelope>` metadata in an
offline Python step, transform lat/lon/height (EPSG:6697) to projected
metres (EPSG:6677), and ship a sidecar JSON manifest alongside the
USDZ assets. At runtime `EnvelopeManifest` reads this JSON and the
building + terrain loaders use the envelope centres as each entity's
real-world origin, completely skipping the per-entity bottom-snap that
caused the Phase 3 floating-building regression.

## Context

ADR-0006 documented four unsuccessful runtime-only attempts to fix the
floating-building regression. The common failure mode: nusamai 0.1.0's
gltf sink centres each emitted GLB on its own AABB and strips the
real-world coordinate origin, leaving the runtime with no shared
reference to align tiles against. Every compromise (flat Y = 0, tile
lift, terrain shift) chose which entities would float vs. bury; none
could solve the problem.

CityGML source files carry an authoritative real-world bounding box in
their `<gml:boundedBy>/<gml:Envelope>` element. That envelope is
independent of nusamai — the metadata is in the XML header before any
geometry processing. Parsing it gives us the exact origin nusamai
throws away.

The Miyagi Plane Rectangular coordinate system (EPSG:6677) places all
six PLATEAU files we ship into a single metric frame. Every
envelope's centre in that frame can be compared with every other
envelope's centre, and the difference is an exact real-world offset in
metres. That's the shared reference we need.

## Pipeline

```
sendai_2024_citygml.zip  (1.5 GB, gitignored)
      │
      ├─→ unzip → input/extracted/udx/{bldg,dem}/*.gml  (gitignored)
      │
      │     ┌───────────────────────────────────────────────┐
      └─→  extract_envelopes.py (pyproj)                    │
            │                                                │
            │  • Reads root <gml:boundedBy>/<gml:Envelope>   │
            │  • Transforms lat/lon → EPSG:6677 metres       │
            │  • Writes sidecar JSON                         │
            │                                                │
            ▼                                                ▼
Resources/Environment/plateau_envelopes.json     (nusamai → Blender pipeline)
            │                                                │
            │                                                ▼
            │                               Resources/Environment/*.usdz
            │                                                │
            └─────────────────┬──────────────────────────────┘
                              ▼
                   EnvelopeManifest (Swift)
                              │
                              ├──→ TerrainLoader(manifest:)
                              │      entity.position = manifest.realityKitPosition(for: "574036_05_dem")!
                              │      (skip centerHorizontallyAndGroundY)
                              │
                              └──→ PlateauEnvironmentLoader.loadDefaultCorridor(manifest:)
                                     for tile:
                                       tileRoot.position = manifest.realityKitPosition(for: tile.rawValue)!
                                       centerMode: .none
                                     (skip centerHorizontallyAndGroundY + skip tile.localCenter)
```

## Coordinate mapping

EPSG:6677 (Japan Plane Rectangular CS Zone IX):
- `x` = easting (positive east)
- `y` = northing (positive north)
- `z` = orthometric height (positive up)

RealityKit (right-handed, Y-up, `PlateauTile` convention):
- `+X` = east
- `+Y` = up
- `+Z` = south

Per-entity remap, with spawn tile centre as origin:
```
rk.x = env.x - spawn.x       // east matches east
rk.y = env.z - spawn.z       // elevation matches up
rk.z = -(env.y - spawn.y)    // north flips to -Z (since RK +Z is south)
```

## Implementation files

| Layer | File | Role |
|---|---|---|
| Offline | `Tools/plateau-pipeline/extract_envelopes.py` | Parse XML + pyproj project, emit JSON |
| Offline | `Tools/plateau-pipeline/extract_bldg_gmls.sh` | Unzip 5 bldg GMLs into input/extracted/ |
| Data | `Resources/Environment/plateau_envelopes.json` | 6-tile manifest (5 bldg + 1 dem) |
| Runtime | `Packages/SDGGameplay/Sources/SDGGameplay/World/EnvelopeManifest.swift` | Manifest decoder + position query |
| Runtime | `Packages/SDGGameplay/Sources/SDGGameplay/World/TerrainLoader.swift` | Terrain USDZ loader, manifest-aware |
| Runtime | `Packages/SDGGameplay/Sources/SDGGameplay/World/PlateauEnvironmentLoader.swift` | Building corridor loader, manifest-aware |
| Runtime | `Packages/SDGUI/Sources/SDGUI/RootView.swift` | Loads manifest, passes to both loaders |

## Alternatives considered

### Option B: Offline per-building DEM re-projection

For each building's footprint centre, sample the DEM heightmap and
translate the building vertically so its base sits on the terrain.
Performed during the Blender pipeline and persisted in the USDZ.

**Advantages**:
- More forgiving of data quirks — every building sits on terrain
  regardless of tile-level alignment accuracy.

**Disadvantages**:
- Loses vertical accuracy between neighbouring buildings (each is
  independently snapped, so a cluster stops looking like a coherent
  block).
- Significantly more complex Blender Python (heightmap sampling +
  mesh editing + persistence).
- Doesn't solve the building-to-building alignment; only
  building-to-terrain. If two building tiles both contain part of the
  same block straddling a tile boundary, they can end up on different
  DEM samples and stutter.

**Verdict**: fallback if envelope alignment proves insufficient.
Phase 5 candidate.

### Option C: Keep Phase 3 runtime heuristics

Rejected in ADR-0006.

## Known limitations

1. **DEM mesh resolution**: the shipped terrain USDZ is decimated from
   1.7 M triangles to 30 K (~30 m horizontal grid). Building bases
   may therefore show 1-5 m vertical drift against local terrain
   wrinkles. Visually minor for a top-down-ish game camera but
   measurable in close-up.
2. **Manifest coverage**: Phase 4 ships the 5 building tiles plus DEM
   quadrant `574036_05`. If we expand to other PLATEAU quadrants
   (574036_00, 574036_50, 574036_55, or adjacent 2nd-meshes), the
   Python script handles any number of input files but the runtime
   loaders need to iterate more tile ids. Out of scope for this PR.
3. **pyproj dependency**: the offline script requires `pip install
   pyproj`. Documented in the script's error output. No runtime
   dependency on pyproj; the Swift side just reads the JSON.
4. **Plan-doc zone correction**: earlier drafts referred to EPSG:6677
   as "Miyagi Zone X" with origin at 139°50'E / 38°N. That was wrong.
   The CRS is Zone IX with natural origin at 36°N / 139°50'E, which
   places Sendai ~266 km from (0, 0). Agent A's sanity check was
   relaxed accordingly; CLAUDE.md and the plan doc should be corrected
   when touched next.

## Backwards compatibility

`TerrainLoader(manifest:)` and `loadDefaultCorridor(manifest:)` both
accept `nil` as their manifest argument and fall back to the Phase 3
bottom-snap layout. Every existing test (Phase 0 through Phase 3)
passes unchanged. `PlateauTile.localCenter` stays on the public API as
the nil-manifest fallback anchor — removing it would break legacy
callers for no benefit.

## Verification

End-to-end DONE signals:

- [x] `plateau_envelopes.json` decodes into 6 envelopes
- [x] spawn tile (`57403617`) envelope centre ≈ (88427, 251546) m in
  Miyagi Zone IX; distance to zone origin ≈ 266 km (correct for
  Sendai)
- [x] `swift test --package-path Packages/SDGGameplay` → 322 tests, 0
  failures (up from 305 pre-Phase-4: +9 EnvelopeManifest, +5
  TerrainLoader, +3 PlateauEnvironmentLoader)
- [x] `xcodebuild build` for iPad Pro 13" M5 simulator: SUCCEEDED
- [x] `.app` bundle contains `Terrain_Sendai_574036_05.usdz` (1.3 MB)
  and `plateau_envelopes.json` (1.4 KB)
- [x] `bash ci_scripts/arch_lint.sh`: green
- [ ] **f.shera device test pending** — expected visual: buildings
  sit on DEM, spawn on Aobayama hilltop surface, no large-scale
  floating. Residual 1-5 m drift acceptable (per limitations).

## References

- ADR-0006: DEM alignment deferred to Phase 4
- CityGML v2 spec: OGC 12-019r1 §C.2 (`gml:Envelope`)
- PLATEAU data convention:
  https://www.mlit.go.jp/plateau/file/libraries/doc/plateau_tech_doc_0001_ver02.pdf
- pyproj: https://pyproj4.github.io/pyproj/
- Plan doc: `/Users/user/.claude/plans/push-modle-plateau-chrome-subagent-nested-rain.md`
