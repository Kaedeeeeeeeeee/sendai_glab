# SDG-Lab — Third-party credits

Shipped assets and services used by SDG-Lab, and the attribution required by each licence.

An in-game credits screen must surface the attribution lines below verbatim (or a visually-equivalent translation) before a build is shipped.

## Map & geospatial data

### PLATEAU (国土交通省) — Sendai 3D city model

- **Source**: 国土交通省 Project PLATEAU `udx/bldg/` CityGML LOD2 (Sendai 2024 release).
- **Licence**: CC BY 4.0. Commercial use permitted with attribution.
- **Attribution line**: `出典: 国土交通省 Project PLATEAU`
- **Scope of use**: building geometry and facade textures for the 5 PLATEAU corridor tiles (Aobayama N / Castle / Campus, Kawauchi, Tohoku Gakuin).
- **Pipeline**: `Tools/plateau-pipeline/extract_bldg_gmls.sh` → `convert.sh` → `split_all_bldgs.sh`.

### 国土地理院 — GSI seamlessphoto orthophoto (Phase 11)

- **Source**: 国土地理院 タイルサービス "seamlessphoto" (全国最新写真シームレス) via https://cyberjapandata.gsi.go.jp/xyz/seamlessphoto/{z}/{x}/{y}.jpg
- **Licence**: CC BY 4.0.
- **Attribution line**: `出典: 国土地理院 (Geospatial Information Authority of Japan)`
- **Scope of use**: DEM terrain baseColor texture for the Sendai corridor, stitched offline and baked into `Resources/Environment/Terrain_Sendai_574036_05.usdz`.
- **Pipeline**: `Tools/plateau-pipeline/download_gsi_ortho.sh` → `dem_to_terrain_usdz.py`.
- **Terms link**: https://www.gsi.go.jp/kikakuchousei/kikakuchousei40182.html

## Audio (Phase 2)

### Kenney.nl — UI / SFX packs

- **Source**: Kenney.nl (https://kenney.nl).
- **Licence**: CC0 1.0 (public domain). Attribution not required but recommended.
- **Attribution line**: `SFX: Kenney.nl (CC0)`
- **Scope of use**: 22 sound effects under `Resources/Audio/SFX/` (UI taps, drill loops, footsteps, feedback tones, disaster placeholders).

## 3D models (Phase 2 Starter)

### Meshy.ai — text-to-3D character placeholders

- **Source**: Meshy.ai Pro API (text-to-3d v2).
- **Licence**: Meshy's Pro plan grants commercial-use rights to generated assets.
- **Attribution line**: none required; commercial-use assets owned by the project.
- **Scope of use**: 5 placeholder chibi character USDZs under `Resources/Characters/` (main character + 4 NPCs). To be replaced by f.shera's hand-crafted art in a later phase.

## Fonts, shaders, code

No external fonts ship today. All shader source (including the Phase 9 step-ramp Toon shader in `Resources/Shaders/`) is original to this project and MIT-licensed with the rest of the repository.

## Update policy

Any addition or removal of a third-party asset must:

1. Update this file in the same PR.
2. Update the in-game credits screen if the attribution line changes.
3. Record the licence text, source URL, and attribution line — not just the licence name.
4. Link the relevant ADR if the asset motivates an architecture decision (e.g. ADR-0012 for the PLATEAU/GSI texture pipeline).
