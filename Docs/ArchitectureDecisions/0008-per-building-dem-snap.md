# ADR-0008: Per-building DEM snap via Blender LOOSE-split pipeline

- **Status**: Accepted
- **Date**: 2026-04-23
- **Context**: Phase 6 follow-up to ADR-0007 (Phase 4 envelope
  alignment) and the Phase 5 per-tile adaptive snap

## Decision

Add an offline Blender pass that splits each PLATEAU building tile's
merged mesh into one mesh object per connected component (≈ one per
building). Ship the resulting multi-prim USDZ. At runtime, walk each
loaded tile's descendants and snap **every building independently**
to the DEM sampled at its own XZ centre. Replace the Phase 5
"snap whole tile as a rigid body" implementation with the new
per-building walk.

## Context

### Phase 5 postmortem

Phase 5 landed a per-tile adaptive snap: compute each tile's AABB
centre, sample DEM at the centre's XZ, shift the tile so its AABB
centre sits at `demY + skip`. In device playtest this was the best
we could do as long as each tile was a single rigid mesh, but it
capped at ~±75 m of residual drift inside any single tile.

Concrete numbers from the last iteration (device log, iter 3):

  tile 17 spawn: demY=0.94, bottomY=-57.45 → newPosY=76.39
  tile 18 kawauchi: demY=-48.15, bottomY=-60.63 → newPosY=-19.62
  tile 19 katahira: demY=-49.24, bottomY=-56.44 → newPosY=3.39

The spawn tile spans world Y [0.94, 151.84] after centre-anchoring —
150 m of internal range. Most of Aobayama's actual buildings sit on
the hilltop (real elevation ~150 m), so they end up clustered in the
upper third of that range, visually floating 30–70 m above the
hilltop DEM surface. Valley-edge outliers float the other way.

The root cause isn't the snap math — it's that nusamai ships the
whole tile as a merged mesh, and rigid-body motion over a 100-m
varying terrain cannot put every building on its own ground.

### Fix

Make each building its own mesh object so each can move
independently.

## Implementation

### Offline pipeline (Blender headless)

`Tools/plateau-pipeline/split_bldg_by_connectivity.py` does:

1. Import the shipped GLB
2. Strip materials (the runtime reapplies Toon)
3. **Weld vertices** at 1 mm threshold via
   `bpy.ops.mesh.remove_doubles`. PLATEAU LOD2 ships as triangle
   soup — every triangle owns its own verts. Without welding, step
   4 would produce one "island" per triangle (POC on the spawn
   tile: 11 603 objects). After welding, islands correspond to
   actual buildings (1 302 for the same tile).
4. **Separate by LOOSE** via
   `bpy.ops.mesh.separate(type='LOOSE')`. Each connected component
   becomes its own object.
5. Export USDZ with `selected_objects_only: False` and
   `root_prim_path: "/root"` so every mesh object becomes a child
   prim under `/root`.

`Tools/plateau-pipeline/split_all_bldgs.sh` drives the script over
the 5 tiles with standard idempotency check (skip if USDZ newer
than GLB + script).

Resulting tile object counts after split:

| Tile | Mesh objects | USDZ size |
|---|---:|---:|
| 57403607 aobayamaNorth |   275 | 363 KB |
| 57403608 aobayamaCastle |   277 | 356 KB |
| 57403617 aobayamaCampus | 1 302 | 1.6 MB |
| 57403618 kawauchiCampus |   914 | 1.2 MB |
| 57403619 tohokuGakuin | 1 675 | 3.1 MB |
| **total** | **4 443** | **6.5 MB** |

Total post-split USDZ size is slightly smaller than pre-split
because vertex welding removes nusamai's triangle-soup duplicates.

### Runtime (Swift)

New helper on `PlateauEnvironmentLoader`:

```swift
@MainActor
internal static func snapDescendantBuildings(
    tile: Entity,
    terrainSampler: TerrainHeightSampler,
    basementSkip: Float
) -> Int
```

Iterative DFS over the tile's entity tree (mirrors the
`applyToonMaterial` walk pattern). Collects every entity with a
`ModelComponent` as "a building" and stops descending into that
subtree. Calls the existing `adaptiveGroundSnap` on each. Returns
the count for diagnostics.

Fallback: if the tile has neither a root `ModelComponent` nor any
mesh-bearing descendants (i.e., a legacy single-mesh USDZ shipped
before this split), snap the tile entity itself — the Phase 5
rigid-body behaviour preserved as graceful degradation.

`loadDefaultCorridor` replaces its single `adaptiveGroundSnap` call
with `snapDescendantBuildings`. Rest of the corridor logic
(envelope placement, manifest-less fallback, center-mode policy)
stays unchanged.

### Tests

Three new unit tests in `PlateauEnvironmentLoaderTests`:

1. `testSnapDescendantBuildingsSnapsEachChildIndependently` —
   synthesises a tile with three 10 m cubes at distinct XZ and a
   sampler that returns a different Y per XZ; asserts each cube
   lands on its own target.
2. `testSnapDescendantBuildingsFallsBackOnLegacySingleMesh` — a
   `ModelEntity` root with no children exercises the "root is the
   only building" path; snap applies to the root itself.
3. `testSnapDescendantBuildingsFallsBackToTileLevelWhenEmpty` —
   an empty `Entity` with no mesh-bearing descendants triggers the
   rigid-body fallback; the sampler is not called (`bounds.isEmpty`
   short-circuits before sampling).

The existing `adaptiveGroundSnap` tests stay green — the per-Entity
contract hasn't changed.

## Performance

Back-of-envelope for a single corridor load (one-shot at startup):

- 4 443 buildings × O(30 K DEM triangles) per sample ≈ 133 M
  point-in-triangle tests
- On M-series (~100 M float ops/ms) → ~1.3 s at load time
- Acceptable for startup; Phase 7 could add a spatial index if
  multiplayer / hot-reload needs re-snapping at runtime

Draw-call concern: 4 443 child entities × 5 tiles means more
draw calls per frame than Phase 5. RealityKit may batch instanced
meshes automatically; if device playtest shows frame-rate
regression, merge small adjacent buildings or use
`ModelComponent` instancing in Phase 7.

## Known limitations

1. **Over-split by connectivity**: if a PLATEAU LOD2 building's
   walls and ground slab are modelled as separate meshes in the
   source data, LOOSE splits them into two "buildings" whose
   independent snap targets diverge slightly. Visually minor for
   typical LOD2 data but possible. Phase 7 fix: use volume
   clustering instead of pure connectivity.
2. **Under-split at shared foundations**: two adjacent buildings
   that share a mesh edge merge into one "building" and get a
   single snap target. Their individual rooftops therefore land
   at the same height even if their real ground elevations
   differ by a few metres. Again, typical LOD2 doesn't share
   mesh edges across parcels, but worth noting.
3. **No runtime mesh edits**: per-building snap only translates.
   Buildings whose real-world geometry crosses a steep DEM slope
   internally (unusually wide footprints) still have one rigid
   translation per building, so part of their ground floor may
   float or bury relative to the sloped terrain. Per-vertex snap
   would be the full fix; out of scope.

## References

- ADR-0006: DEM alignment deferred to Phase 4
- ADR-0007: CityGML envelope alignment (Phase 4)
- Blender Python API: `bpy.ops.mesh.remove_doubles`, `mesh.separate`
- PR stack: continues on `feat/phase-4-citygml-envelope-alignment`
  branch (PR #12)
