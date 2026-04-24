# ADR-0012 — PLATEAU + GSI texture pipeline (Phase 11)

**Status**: Accepted (2026-04-24)
**Context**: Phase 11 texture pass — replace the flat-shaded city corridor with real PLATEAU facade textures + real Sendai orthophoto on the DEM.

## Context

Through Phase 3–10 the playable corridor rendered as:

- Buildings: flat warm-palette Toon materials (per-tile baseColor, no texture).
- Ground (DEM): flat mud-olive Toon material (no UVs, no texture).

PLATEAU's LOD2 CityGML for Sendai actually ships with ~1065 building facade JPGs inside `{tile}_bldg_6697_appearance/` folders, and the 国土地理院 (GSI) publishes free CC BY 4.0 aerial imagery tiles at zoom 17 covering every inch of Sendai. Both were being thrown away at different stages of our offline pipeline. Phase 11 plumbs them through.

## Where the textures were being lost (pre-Phase 11)

Five layers of strip-it-all. Any one of them fixed in isolation would have been useless:

1. **`extract_bldg_gmls.sh`** only unpacked `.gml` files from the source zip; the sibling `_appearance/` JPG folders were ignored by the `unzip` globs.
2. **`convert.sh`** invoked `nusamai` with no special flag. nusamai 0.1.0 has no `--textures` CLI flag — appearance passthrough is driven by file layout: if the `_appearance/` folder sits next to the GML, nusamai's gltf sink resolves the references automatically. With Layer 1 missing, the folder was never there.
3. **`split_bldg_by_connectivity.py`** explicitly called `strip_all_materials()` on load, and exported with `export_materials: False` + `export_textures: False`.
4. **`dem_to_terrain_usdz.py`** exported with `export_uvmaps: False` + `export_materials: False` + called `strip_materials()`. No UVs meant no orthophoto could ever be draped.
5. **Runtime `applyToonMaterial`** in both loaders walked every `ModelComponent` and replaced every material with a flat `makeHardCelMaterial` — throwing away any texture the USDZ did carry.

## Decision

**Fix all five layers in a single coordinated change**, gated behind `feat/phase-11-textures`.

### Offline pipeline

| Layer | Change |
| --- | --- |
| 1. Extract | `extract_bldg_gmls.sh` now also unpacks `{tile}_bldg_6697_appearance/` folders next to each GML. ~1065 JPGs, ~65 MB extracted per run. |
| 2. nusamai | No flag change needed; Layer 1's output is sufficient. `convert.sh` warns loudly if no adjacent appearance folder is seen after stage 1 — a self-healing check if someone else re-introduces Layer 1's bug. |
| 3. Blender bldg split | `split_bldg_by_connectivity.py` drops the `strip_all_materials()` call, flips `export_materials`/`export_textures`/`export_uvmaps` to `True`, and chains in `downscale_textures_inline.py` which packs every `bpy.data.image` down to 512×512 JPEG q=80 before export. `split_all_bldgs.sh` carries a `PIPELINE_VERSION=p11-textures` sidecar stamp so pre-Phase-11 USDZs are regenerated on the next run. |
| 4. Blender DEM | `download_gsi_ortho.sh` (new) fetches GSI seamlessphoto tiles at zoom 17 covering the DEM envelope (~81 tiles), stitches them via `gsi_tile_math.py` (pyproj + Pillow), crops to the exact EPSG:6677 bbox, and downscales to 1024×1024 JPG. `dem_to_terrain_usdz.py` now emits planar UVs (normalized vertex XY) and bakes the stitched JPG into a Principled BSDF. Phase-3 untextured fallback is preserved behind an optional `--ortho` flag for tests. `convert_terrain_dem.sh` chains `download_gsi_ortho.sh` before the Blender step. |

### Runtime Swift

| Layer | Change |
| --- | --- |
| 5. Hybrid tint | New `ToonMaterialFactory.mutateIntoTexturedCel(_:)`: takes a `PhysicallyBasedMaterial`, keeps `baseColor.texture` as-is (TextureResource passes through by value-copy without GPU re-upload), boosts emissive by ~25% white, kills specular/clearcoat, forces roughness=1. `PlateauEnvironmentLoader.applyToonMaterial` and `TerrainLoader.applyTerrainMaterial` are renamed to `applyHybridToonTint` / `applyHybridTerrainTint` and branch per slot: textured PBR → mutator; everything else → `makeHardCelMaterial` fallback with the legacy per-tile or mud-olive colour. |

### Visual style

"Painted-realistic" / Borderlands-ish. Real facade photo survives into the render, but the emissive boost + matte roughness + killed specular pull it away from raw PBR toward a softly-lit painted look. The existing outline shell (Phase 9 C/C-v2) keeps the comic silhouette. Verified on device after Blender regeneration — user confirmation pending at the time of this ADR.

## Consequences

### Positive

- Each of the 5 tiles (4443 buildings after Phase 6.1 per-building merge) wears its real Sendai facade.
- DEM terrain shows Aobayama green / Kawauchi river lines / Katahira grid.
- Pipeline is now additive: dropping a new CityGML tile through `extract → convert → split_all_bldgs` emits a textured USDZ with zero per-tile config.
- Runtime cost: one extra `as?` cast per material slot per tile load. Negligible on M-series iPads (~5000 slots total, single-digit milliseconds).
- Bundle size: +15.5 MB (measured): Environment USDZs go from ~6 MB total to ~21.5 MB total (Terrain +1.6 MB, 5 bldg tiles +~14 MB at 512² JPEG q=80).

### Negative / trade-offs

- **GSI attribution required**. CC BY 4.0 obligates us to credit 国土地理院 in any shipped build. Surfaced in `Resources/Credits.md` and the in-game credits screen (tracked separately).
- **Blender dependency**. Regenerating the 5 tile USDZs requires the user to run Blender locally — sub-agents can edit scripts but cannot execute them headless. The PIPELINE_VERSION sidecar makes the regen idempotent so a partial run is safe to resume.
- **Texture downscale is lossy**. 512×512 JPEG q=80 per facade is plenty at the camera distances the player normally looks at buildings; closer than ~5 m the artefacts become visible. If that becomes a problem we bump to 768×768 (+~30% bundle) or per-tile selective high-res; both are mechanical changes behind the same pipeline.
- **DEM UV uses planar XY projection**. A heightfield has no seams so this is actually the *right* answer; smart_project was rejected because it scatters the orthophoto across disconnected UV islands (tested and confirmed visibly wrong).
- **Hybrid runtime path branches on `baseColor.texture != nil`**. A degenerate "PBR material with an explicit empty texture" would accidentally hit the mutator path. Not observed in any USDZ we ship, but the branch predicate is a single line in each loader — easy to harden later if needed.

### Risks mitigated vs realized

From the Phase 11 plan file:

| Risk | Outcome |
| --- | --- |
| R1: iOS 18 `baseColor.texture` read-only | Mitigated. iOS 26.4 swiftinterface exposes it as public read/write. Round-trip via value-copy works cleanly. Fallback path never needed. |
| R2: nusamai no `--appearance` flag | Real. No flag exists; fixed by Layer 1 file-layout alone. |
| R3: GSI attribution | Realized. Addressed via `Resources/Credits.md` + in-game credits. |
| R4: Smart UV Project fallback | Avoided. Manual planar UV is simpler and correct-by-construction. |
| R5: Bundle +15 MB overrun | Realized at +15.5 MB. On target. |
| R6: 512² facade readability | Not yet playtested post-regen. Escape valve: bump to 768 with one constant change. |
| R7: Multi-material per tile | Not observed; Blender's join handles multi-slot gracefully. |
| R8: nusamai re-convert time | ~30 min/tile; acceptable as one-off. |

## References

- Phase 11 plan: `/Users/user/.claude/plans/push-modle-plateau-chrome-subagent-nested-rain.md`
- ADR-0004: Toon shader decision (hybrid tint is the Scheme C evolution).
- ADR-0006 / 0007: DEM alignment postmortem + CityGML envelope fix (necessary groundwork for accurate UV bounds).
- ADR-0008: Phase 6.1 per-building merge (why tiles are single-mesh at runtime and still work with multi-slot textured PBR).
- GSI terms of use: https://www.gsi.go.jp/kikakuchousei/kikakuchousei40182.html
- GSI seamlessphoto endpoint: https://cyberjapandata.gsi.go.jp/xyz/seamlessphoto/{z}/{x}/{y}.jpg
