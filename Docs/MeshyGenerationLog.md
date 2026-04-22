# Meshy Generation Log

Records of Meshy.ai batch generations for SDG-Lab. Append-only.

---

## 2026-04-22 — Phase 2 starter: 5 placeholder characters

**Branch**: `feat/phase-2-starter`
**Operator**: Claude Code agent (general-purpose)
**Driver**: [Tools/meshy-pipeline/generate_placeholders.py](../Tools/meshy-pipeline/generate_placeholders.py)
**Endpoint**: `POST /openapi/v2/text-to-3d` (preview mode)
**Options**: `art_style="realistic"`, `target_formats=["glb","usdz"]`

### Results

All 5 characters generated successfully. Total wall-clock: **358 seconds** (~1 min per preview task + ~10-30 s download).

| Name | Status | task_id | Duration | GLB | USDZ |
|---|---|---|---|---|---|
| player_male | OK | `019db2ec-01e8-7985-a333-d766522bff8b` | 62.3 s | 7.09 MB | 4.49 MB |
| player_female | OK | `019db2ec-f8f8-79b5-86d8-202d9c12e24b` | 62.7 s | 6.90 MB | 4.43 MB |
| kaede | OK | `019db2ed-f35a-7406-932e-9e49118646f1` | 62.0 s | 8.06 MB | 5.17 MB |
| teacher | OK | `019db2ee-ea7f-78eb-8178-f4e07e056136` | 82.7 s | 6.91 MB | 4.38 MB |
| researcher_a | OK | `019db2f0-31bf-7a87-9c9a-a71bc802da02` | 82.4 s | 6.52 MB | 4.13 MB |

### Prompts

| Name | Prompt |
|---|---|
| `player_male` | A cheerful middle-school boy in a Japanese school uniform, chibi anime style, 3-head proportion, casual backpack, cute, clean topology |
| `player_female` | A cheerful middle-school girl in a Japanese school uniform with sailor-style collar, chibi anime style, 3-head proportion, cute, clean topology |
| `kaede` | A young female scientist named Kaede in a lab coat, chibi anime style, 3-head proportion, short brown hair, intellectual, game-ready |
| `teacher` | A friendly male science teacher in casual jacket, chibi anime style, 3-head proportion, glasses, holding a clipboard, game-ready |
| `researcher_a` | A female researcher in lab coat with a headset, chibi anime style, 3-head proportion, focused expression, game-ready |

### Raw outputs

```
Tools/meshy-pipeline/output/
  player_male.glb    player_male.usdz    player_male.json
  player_female.glb  player_female.usdz  player_female.json
  kaede.glb          kaede.usdz          kaede.json
  teacher.glb        teacher.usdz        teacher.json
  researcher_a.glb   researcher_a.usdz   researcher_a.json
  _batch_summary.json
```

### Installed into Resources

USDZ variants copied into `Resources/Characters/` with the naming convention from [AssetPipeline.md §命名規約](AssetPipeline.md):

```
Resources/Characters/Character_Player_Male.usdz
Resources/Characters/Character_Player_Female.usdz
Resources/Characters/Character_Kaede.usdz
Resources/Characters/Character_Teacher.usdz
Resources/Characters/Character_ResearcherA.usdz
```

These files must be tracked via **Git LFS** (per `.gitattributes`). The main agent handles that step — do not add them to the repo from a worktree without LFS being ready.

### API behaviour observed

- **`art_style` in v2 text-to-3d is effectively locked to `"realistic"`** as of 2026-04-22. Submitting `"cartoon"` (which appears in older Meshy docs for v1) returns **400 Bad Request**: `{"message":"Invalid values: ArtStyle must be one of [realistic]"}`. The chibi/anime look is therefore 100% prompt-driven in this batch. See "Known limitation" below.
- **`target_formats=["glb","usdz"]` works on the v2 endpoint** — Meshy returns both download URLs in `model_urls`, no local converter required. This is the big win: we do not need `usdzconvert` (confirmed absent from Xcode 26.4 SDK on this machine) or `pxr`/`usd-core`.
- **Preview task latency is consistent** at ~60-85 s per task including the final SUCCEEDED state transition (which lags the 99% progress report by ~30-45 s — the progress signal is misleading).
- **Download URLs are signed** with a far-future `Expires=4930416000` (year 2126), so re-download is effectively always possible during dev.
- No rate-limit hits encountered with 5 serial submissions over ~6 minutes.
- No content-moderation refusals on these prompts.

### USDZ content inspection

```
unzip -l Character_Player_Male.usdz
-> temp.usdc   (4.7 MB binary USD)
```

Meshy's USDZ export packages a single `temp.usdc` file — **no separate texture assets bundled inside the archive**. Textures appear to be either (a) baked into the USDC as embedded data or (b) missing entirely. The GLB variant contains the full PBR material graph. If RealityKit renders these USDZs untextured on device, the fallback is to re-export locally from GLB with `usdzconvert`/Reality Converter (which packages textures into the zip explicitly).

All 5 USDZ files are valid "store"-compressed ZIP archives — i.e. they meet the USDZ spec (which requires no compression for fast random access).

### Known limitations of this batch

1. **Not actually chibi / not toon-shaded.** `art_style=realistic` + prompt tricks is the best we can do on the v2 text-to-3d endpoint. Expect photorealistic-ish characters with modest stylistic lean.
2. **No rigging / no animation.** Deliberately skipped — Studio plan feature and unnecessary for placeholder use.
3. **Preview mode quality.** Low polycount, auto topology, no refine pass. Suitable for replacing the blue capsule; not shippable.
4. **USDZ may be untextured on device.** See above.
5. **Scale unknown.** Meshy doesn't set a real-world scale; the models will need manual scaling when spawned in RealityKit.

### Phase 3 (or later) formal art pass — recommended changes

- Use **image-to-3d** (`/openapi/v1/image-to-3d`) with Nano Banana / Midjourney-generated concept images. `art_style` gains more options there (`cartoon`, `sculpture`, etc.) and reference images drive consistent style — critical for an anime/chibi look, which pure text-to-3d cannot deliver.
- Add a **refine pass** (`mode=refine` with `preview_task_id`) on accepted previews — Meshy refine produces clean topology + 4K textures.
- Add **`rigging`** (Studio plan) + **`animations`** (idle / walk / run / talk / wave) once characters are approved.
- Re-export USDZ locally from the GLB via Reality Converter (after installing it) to guarantee textures ride along in the `.usdz` zip.
- Move the batch driver from `generate_placeholders.py` into `meshy_batch.py` + `character_config.yaml` (the structured schema already exists) once the workflow stabilises.

### Reproducing

```bash
cd /Users/user/sendai_glab
source Tools/meshy-pipeline/.venv/bin/activate
python Tools/meshy-pipeline/generate_placeholders.py
```

The script is **idempotent**: existing `{name}.glb` in the output dir skips that character. Delete files to force regeneration.
