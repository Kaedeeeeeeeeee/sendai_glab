# ADR-0006: PLATEAU DEM alignment deferred to Phase 4

- **Status**: Accepted
- **Date**: 2026-04-23
- **Context**: Phase 3 DEM terrain integration (branch `feat/phase-3-plateau-dem`, PR #11)

## Decision

Ship the offline DEM conversion pipeline (`Tools/plateau-pipeline/`)
but **do not** load the DEM at runtime for Phase 3. The 5 PLATEAU
building tiles keep the Phase 2 bottom-snap placement (every tile at
Y = 0). DEM-based terrain alignment is the first task on the Phase 4
list.

## Context

The goal of Phase 3 DEM integration was stated in CLAUDE.md as
"浮遊建物の根本修正" — root-cause fix for the floating buildings
that appeared in Phase 2 because the 5 building tiles were all
bottom-snapped to the same Y = 0 plane regardless of their real-world
elevation.

Four alignment strategies were tried in PR #11, all unsuccessful:

1. **Flat Y = 0 for everything, terrain added as a backdrop**.
   Buildings at Y = 0, terrain bottom-snapped to Y = 0 as well.
   Hill-top building tiles (Aobayama) looked reasonable but
   valley tiles (Kawauchi, Katahira) floated up to 100 m because
   their buildings' Y = 0 corresponded to the lowest building in
   that tile, not the terrain valley floor.

2. **Per-tile terrain lift — additive with overwrite**. For each
   tile, sample DEM Y at the tile's centre XZ, write the tile's
   `position = (localCenter.x, terrainY, localCenter.z)`. Buildings
   on spawn tile flew off the screen because the absolute assignment
   wiped out the `-boundsCentreX/Z` shift that
   `centerHorizontallyAndGroundY` had installed for horizontal
   centring — tiles ended up at their raw EPSG:6677 mesh origins,
   kilometres off the scene.

3. **Per-tile terrain lift — additive preserving centre**.
   `position += SIMD3(localCenter.x, terrainY, localCenter.z)`
   fixed (2)'s regression but produced the same floating pattern
   as (1): the per-tile priorY values (28…75 m of bottom-snap
   offset) stack with the sampled terrain Y (19…93 m) to place
   the lowest building foundation on the ground under the tile,
   but the *internal* 150 m vertical spread of each tile means
   the highest-elevation buildings in that tile still rise 150 m
   into the sky — which is the real Aobayama elevation range,
   relative to a camera parked at the tile's valley floor.

4. **Terrain shifted so its surface at spawn XZ = Y = 0**.
   Skips per-tile lift; uses the same Y = 0 plane for every tile,
   but lowers the terrain so the player stands on ground at Y = 0
   at the immediate spawn area. Works visually at spawn; breaks
   down everywhere else because tiles still share a single Y = 0
   bottom-snap that doesn't match the DEM's elevation variance
   away from spawn.

The postmortem: **nusamai (v0.1.0) strips each GLB's real-world
coordinate origin**. Each output is centred on its own AABB, which
means five building tiles and the DEM quadrant all claim to live at
(0, 0, 0) in their local frames, with no metadata telling us where
they *actually* are in EPSG:6677. Without a shared coordinate anchor
nothing the Swift runtime can do produces a correct layout — the
best it can do is arbitrarily pick a compromise, which is what the
four attempts above were.

## Options considered for root-cause fix

### A. Parse CityGML envelope for real-world origin recovery (chosen for Phase 4)

Every PLATEAU CityGML source file carries a `<gml:Envelope>` block
with `<gml:lowerCorner>` / `<gml:upperCorner>` in the declared CRS
(EPSG:6697/6677 for PLATEAU). Parsing this XML header gives each
file's absolute real-world bounding box before nusamai destroys the
origin.

**Implementation**:
- Write an offline or Swift-side parser that reads the envelope
  from the CityGML XML. Store the extracted origins alongside the
  USDZ output so the runtime can position each entity.
- At load time, set `entity.position = realWorldOrigin - sceneOrigin`
  where `sceneOrigin` is the spawn tile's real-world origin.
- Skip `centerHorizontallyAndGroundY` entirely — the envelope
  already places things correctly.

**Expected outcome**: buildings sit on the DEM naturally because both
use the same coordinate frame. Individual buildings may have 1–5 m
vertical drift due to DEM decimation (30K triangles over 5×5 km ≈
30 m grid), but no more flying / burial.

**Cost**: ~1–1.5 days. Mostly CityGML XML parsing. PLATEAU envelope
format is stable and well-documented.

### B. Offline per-building DEM re-projection

For each building's footprint centre, sample the DEM heightmap and
translate the building vertically so its base sits on the terrain.
Done during the Blender pipeline, persists in the USDZ.

**Advantages**: more forgiving of data quirks — individual buildings
always sit on terrain regardless of tile-level alignment.

**Disadvantages**: loses vertical accuracy between neighbouring
buildings (each is independently snapped); harder to implement
(requires heightmap sampling in Blender Python); slower turnaround
during iteration.

**Verdict**: fallback if (A) proves insufficient.

### C. Accept Phase 3 as "visible DEM, imperfect alignment"

Ship the Phase 3 work-in-progress state — terrain loads, is visually
present, buildings float in some places. Document the compromise and
move on.

**Rejected** because the f.shera playtest feedback was unambiguously
negative: "房子那些还是飘在天上" / "打开游戏的那一瞬间就都在天上".
The compromise degrades the spawn vista, which is the first
impression every player gets. Shipping it would mask the problem
rather than solving it.

### D. Drop DEM entirely, keep flat ground

The pre-Phase-3 state. No terrain. "Root-cause fix for floating
buildings" is unmet, but at least the scene is self-consistent.

**Rejected** for the same reason as (C): doesn't solve the stated
Phase 3 goal, and we've already invested in the DEM conversion
pipeline which is useful regardless.

## What this PR keeps

Even though runtime DEM loading is removed, several artefacts from
the Phase 3 work ship anyway because they stand on their own:

- `Tools/plateau-pipeline/dem_to_terrain_usdz.py` — Blender script
  that decimates a raw DEM GLB from 1.7 M triangles to 30 K with
  explicit vertex welding (`remove_doubles`) and orphan-vertex
  purge. Phase 4 can run this identically to produce the USDZ.
- `Tools/plateau-pipeline/convert_terrain_dem.sh` — single-command
  driver: zip → nusamai → Blender → USDZ.
- `ToonMaterialFactory.makeHardCelMaterial` — Phase 3 "harder cel"
  material variant used by the building loader. Unrelated to DEM;
  stays because it ships a visible improvement on its own.

## What this PR reverts

- `TerrainLoader.swift` and its tests — no runtime DEM loading.
- `Resources/Environment/Terrain_Sendai_574036_05.usdz` — can be
  regenerated from the pipeline when Phase 4 lands.
- `PlateauEnvironmentLoader.loadDefaultCorridor(terrainSampler:)` —
  reverts to the no-param form; no caller needs the alignment hook
  yet.
- RootView's terrain-loading / spawn-Y-sampling block — reverts to
  the Phase 2 bootstrap shape.

## Phase 4 scope

- Write `Tools/plateau-pipeline/extract_envelopes.py` (or Swift
  equivalent) that parses each CityGML file's envelope and emits a
  JSON sidecar: `{"574036_05": {"lowerCorner": [...], "upperCorner": [...], "crs": "EPSG:6697"}, ...}`.
- Ship the JSON in `Resources/Environment/` alongside the USDZs.
- Extend `TerrainLoader` / `PlateauEnvironmentLoader` to read the
  JSON, compute world positions relative to the spawn tile's
  real-world centre, and set `entity.position` accordingly.
- Drop the existing bottom-snap compromise for those entities.
- Re-playtest. Expected outcome: buildings sit on DEM naturally.

## References

- PR #11: https://github.com/Kaedeeeeeeeeee/sendai_glab/pull/11
- CityGML spec: OGC 12-019r1 §C.2 (Envelope)
- PLATEAU data distribution convention: G-Spatial Information
  Centre metadata
- nusamai 0.1.0 source: confirms AABB-centred glTF output with no
  translation metadata carried through
