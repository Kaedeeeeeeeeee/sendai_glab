# SDG-Lab — Claude Code Memory

> このファイルは Claude Code エージェントに常にロードされる。**AGENTS.md** も参照すること(人間向けガイドと兼用)。

## プロジェクト基本情報

- **名前**: SDG-Lab
- **リポジトリ**: https://github.com/Kaedeeeeeeeeee/sendai_glab
- **性質**: Swift + RealityKit による iPadOS 地質教育ゲーム
- **起動日**: 2026-04-21
- **現フェーズ**: Phase 0(基礎建設)
- **開発者**: f.shera(solo)

## 最重要参照ドキュメント

作業前に必ず目を通すこと:

1. **[GDD.md](GDD.md)** — ゲーム全体設計・技術アーキテクチャ・ロードマップの単一情報源
2. **[AGENTS.md](AGENTS.md)** — コーディング規約 + 屎山禁止原則
3. **[Docs/ArchitectureDecisions/](Docs/ArchitectureDecisions/)** — 設計判断の記録

## 絶対原則(AGENTS.md §1 より抜粋)

```
[View] ──intent──▶ [Store] ──event──▶ [ECS]
   ▲                   │                 │
   └── @Observable ────┘                 │
                       ▲                 │
                       └──── event ──────┘
```

- View → Store → ECS の三層を越境しない
- Singleton 禁止(`.shared` パターン)
- Cross-module は全て Event Bus 経由
- `*Fixer` / `*Patch` / `*Workaround` ファイル禁止
- 死んだコードはコメントアウトせず削除

## 現在の知見

### 旧 Unity プロジェクト `/Users/user/Unity/GeoModelTest/`

- 参考元。約 92K 行 C#。
- 保持:Drilling, Geology(CSG 抜き), Story, Quest, Inventory, Scene, Localization, Workbench, Encyclopedia, Vehicles, Mobile input
- 削除:SampleCuttingSystem(11K), WarehouseSystem(5.4K), CSG(3K), MineralSystem, 全 Fixer/Test
- Story は既に Japanese 脚本あり(StorySummary.md)

### 外部サービス・データ

| サービス | 用途 | プラン | キー保管場所 |
|---|---|---|---|
| Meshy.ai | 3D キャラ/道具生成 | Pro → 将来 Studio | `Tools/meshy-pipeline/.meshy-api-key`(.gitignore) |
| Nano Banana (Gemini) | コンセプトアート生成 | f.shera 個人アカウント | (ローカルのみ) |
| Suno / Udio | BGM 生成 | Pro($10/mo) | (ローカルのみ) |
| PLATEAU | 仙台 3D 都市データ | 商用可 | Tools/plateau-pipeline/ で取得 |

### 技術スタック

- Swift 5.10+ / RealityKit / SwiftUI / Metal
- @Observable(iOS 17+) で状態管理、Combine は限定利用
- SwiftData + UserDefaults で永続化
- String Catalog (.xcstrings) で三言語対応

### RealityKit 注意点

- API は比較的新しく、訓練データが古い可能性。**推測せず Apple 公式 docs を WebFetch で確認**。
- Toon Shader は自前 CustomShader (Metal) または RealityKit の `ShaderGraphMaterial` で実装予定。未検証。

## 進捗メモ

### Phase 0 — 完了(2026-04-21、feature branch `feat/phase-0-bootstrap`)

- [x] GDD.md 起草・確認済み
- [x] Git 初期化 + remote + MIT LICENSE + .gitignore
- [x] AGENTS.md / CLAUDE.md / ADR-0001〜0003
- [x] ディレクトリ骨格
- [x] Xcode プロジェクト(xcodegen + 4 local SPM:SDGCore/Gameplay/UI/Platform)
- [x] SDGCore 実装(EventBus / Store / DI / L10n) 22/22 tests pass
- [x] SDGUI / SDGPlatform / SDGGameplay 骨格(RootView + AppEnvironmentKey + TouchInputService)
- [x] 真機対応シーン(RealityView + 緑地面 + 蓝 capsule + pan 手势 log)
- [x] Tools/plateau-pipeline(convert.sh + blender_toon.py)
- [x] Tools/meshy-pipeline(meshy_client.py + batch driver)
- [x] Tools/asset-validator(5 ルール群、stdlib only)
- [x] Tools/localization-importer(Unity JSON → xcstrings 564 keys)
- [x] .gitattributes + Git LFS 初期化
- [x] GitHub Actions CI(lint / swift-test / ios-build、macos-15 + Xcode 26.3)
- [x] Orientation: landscape only 確定(2026-04-21 f.shera 指示)

### Phase 1 POC — 完了(2026-04-21、feature branch `feat/phase-1-poc`)

- [x] Wave α: Player 控制 + 地質シーン + Inventory store(3 並列)
- [x] Wave β.1: GeologyDetection + Toon Shader(2 並列、ADR-0004 方案 C)
- [x] Wave β.2: Drilling Orchestrator + StackedCylinderMeshBuilder(2 並列)
- [x] Wave γ.1: Sample icon + HUD 骨架 + Contracts docs(3 並列)
- [x] Wave γ.2: Inventory UI(grid + 詳細)
- [x] P1-T11 integration: RootView 全パイプ結線、POC Report

**合計 199 tests / 0 failure**(SDGCore 22 + SDGGameplay 136 + SDGUI 41)

### Phase 2 Starter — 完了(2026-04-22、PR #4)

- [x] Meshy.ai text-to-3d v2 で 5 体の placeholder 角色(USDZ 直出、22 MB)
- [x] PLATEAU 仙台 CityGML ダウンロード(1.6 GB)+ nusamai で 5 個 3rd mesh glb 変換(走廊 Aobayama-Kawauchi、16 MB GLB)
- [x] Kenney.nl CC0 SFX 22 個(UI / drill / footstep / feedback)
- [x] Docs: Phase2-Starter.md、MeshyGenerationLog.md、plateau-pipeline/QUICKSTART.md

### Phase 2 Alpha — 完了(2026-04-22、PR #5 + PR #6 修正)

- [x] PlateauEnvironmentLoader + GLBToUSDZConverter + EnvironmentCenterer(World/)
- [x] CharacterLoader + CharacterRole + IdleFloat System(Characters/)
- [x] AudioService(SDGPlatform/Audio/)+ AudioEventBridge(SDGGameplay/Audio/)
- [x] **重大発見**:ModelIO は iOS 26.4 / macOS 15 で GLB import 非対応。
      回避:Blender CLI 離線変換(glb_to_usdz.py + convert_environment_glbs.sh)
- [x] RootView 全統合:5 PLATEAU tile 描画 + Meshy 主人公 + AudioBridge 接続
- [x] SendaiGLabApp で AVAudioSession.ambient + mixWithOthers 設定
- [x] PR #6 playtest 修正:音效 bundle path + 建物 bottom-snap + walk speed 2 → 8 m/s

**合計 276 tests / 0 failure**(SDGCore 22 + SDGGameplay 194 + SDGPlatform 19 + SDGUI 41)

### Phase 2 Beta — 完了(2026-04-22、PR #7)

- [x] Quest + Dialogue 移植(13 Unity quest + 14 StorySequence JSON)
- [x] Workbench + 显微镜 UI(全屏 grid + pinch-zoom + 程序生成占位薄片)
- [x] Vehicles(drone 15 m/s + drillCar 12 m/s、placeholder mesh)
- [x] RootView Wave β 統合:DialogueOverlay + QuestTrackerView + DebugActionsBar
- [x] Story → Quest chain:quest1.1 DialogueFinished → q.lab.intro 自動起動

**合計 393 tests / 0 failure**(SDGCore 22 + SDGGameplay 303 + SDGPlatform 19 + SDGUI 49)

### 真機実測(2026-04-22 f.shera)

- ✅ Kaede 対話起動 + 逐句推進 OK
- ✅ 対話終了後 Quest Tracker 左上表示
- ✅ Drone 召喚視覚化
- ✅ Workbench 全画面遷移 + 薄片ビューア
- ✅ 既存(drilling / inventory / detail / delete)全て異常なし
- ❌ **音效仍然没声音**(PR #6 の "root-level fallback" 修正でも直らず)
  → ✅ **Phase 3 audio-fix で根治**(branch `fix/phase-3-audio-deep-dive`、ADR-0005)
    真因は bundle path ではなく **iOS AVAudioPlayer が OGG Vorbis を非対応**。
    Kenney OGG を全て AAC/M4A に事前変換 + pipeline script 化 + makePlayer に
    os.log を追加してサイレント失敗を根絶。

### Phase 2 Audio Fix — 完了(2026-04-22、PR #9)

**真機で音が鳴ることを f.shera が確認済み。** 2 層の原因を順に潰した:

**第 1 層:iOS AVAudioPlayer は Ogg Vorbis 非対応**
- `AVAudioPlayer(contentsOf: .ogg)` throws → `makePlayer` の `catch { return nil }` が
  silently swallow → 全 SFX 無音の連鎖
- [x] `Tools/audio-pipeline/transcode_ogg_to_m4a.sh`(ffmpeg 経由、idempotent)
- [x] 22 OGG → 22 M4A (AAC 96kbps) 変換、OGG 原本は `Tools/audio-pipeline/source/` に退避
- [x] AudioService: extension を "m4a" に変更、失敗時は os.log + print 両方で surface
- [x] 退行ガード:`Fixtures/Audio/SFX/ui/UI_Tap.m4a` を実 AVAudioPlayer に食わせる
      `testPlayResolvesAndCachesForRealM4AFixture`

**第 2 層:`AVAudioSession.Category.ambient` は silent switch で完全無音化される**
- Apple docs:「.ambient is silenced by the Silent switch and screen locking」
- f.shera の iPad が(または Control Center の)ミュートだと M4A が再生可能でも無音
- [x] `SendaiGLabApp.init`:`.ambient` → `.playback`(ゲームの primary audio category)
- [x] `.mixWithOthers` は維持 → 背景の Apple Music 等は止めない

**ドキュメント & 診断**
- [x] ADR-0005: SFX container format (M4A/AAC, not OGG Vorbis)
- [x] AudioEffect / Audio README / Phase2-Starter docs 更新
- [x] 起動時 breadcrumb print を 2 箇所(`AVAudioSession activated` / `AudioEventBridge started`)
      残した。将来また無音になったら Console.app で最初に見る

**合計 394 tests / 0 failure**(SDGCore 22 + SDGGameplay 303 + SDGPlatform 20 + SDGUI 49)

### Phase 3 Quest Chain — 完了(2026-04-22、PR #10)

- [x] `StoryProgressionMap.builtIn`:10 条 dialogue→objective + 12 条 quest→successor
- [x] `StoryProgressionBridge`:DialogueFinished + QuestCompleted 購読 → QuestStore.intent
- [x] RootView:旧 hand-wired dialogueFinishedToken 撤去、bootstrap で q.lab.intro
      を 1 回 auto-start(冪等)
- [x] 14 tests 追加(map 整合性 6 + bridge 挙動 8)

**合計 408 tests / 0 failure**(SDGCore 22 + SDGGameplay 317 + SDGPlatform 20 + SDGUI 49)

### Phase 3 PLATEAU DEM Terrain — **部分採用 / runtime は Phase 4 に延期**(2026-04-23、PR #11)

f.shera 真機テストで 4 種類の tile alignment 戦略(flat / absolute-lift / additive-lift /
terrain-shift)すべて視覚的に失敗。**真因は nusamai 0.1.0 が各 GLB の real-world
Y origin を捨てる**こと — ランタイムにだけ触れる修正では本質的に解けない。

ADR-0006 に postmortem と Phase 4 計画を記録。本 PR #11 では:

**採用**:
- [x] オフライン DEM 変換管線(`Tools/plateau-pipeline/dem_to_terrain_usdz.py` +
      `convert_terrain_dem.sh`): nusamai → Blender 過激 decimate
      (1.7M → 30K 三角形、`remove_doubles` + orphan-vert purge で 41MB → 1.3MB)
- [x] `ToonMaterialFactory.makeHardCelMaterial`:硬めの cel 見た目
      (emissive floor 35% → 60%、specular/clearcoat ゼロ)。建物と任意の地形両方で利用可。
- [x] ADR-0006: DEM alignment を Phase 4 に延期する判断と方案 A 計画

**延期(ADR-0006 の対応作業、Phase 4 専用 PR)**:
- [ ] CityGML `<gml:Envelope>` パーサ(Swift or Python) → 各 GLB の real-world 原点復元
- [ ] 復元した原点でランタイム配置: `entity.position = realWorldOrigin - spawnOrigin`
- [ ] `TerrainLoader.swift` + `Terrain_Sendai_574036_05.usdz` は Phase 4 で再投入
- [ ] 見積:1〜1.5 日専用 PR

**既知の教訓**:
1. nusamai 0.1.0 の gltf sink は各ファイルを自前の AABB 中心に移す → 座標は失われる
2. 1km PLATEAU 建物 tile は real-world で 150m 垂直跨度を持つ場合がある(青葉山)。
   bottom-snap は "最低点 = Y=0" なので、その tile の建物全てが地形相対で +150m 浮く
3. ランタイム側の tile-level rigid shift では上記 2 つを補正できない
4. 「諦める判断」はコストを抑える上で必要 — 4 次試行した後明らかだった

### Phase 6.1 per-building snap 移到 Blender 离线 — 完了(2026-04-23)

Phase 6 run-time per-building snap 真機有 FPS drop(4443 draw call)。
→ Phase 6.1: Blender 里 split → **per-building DEM snap** → **merge 回单 mesh** → 导出。
Runtime 见单 mesh per tile,5 draw call 总。精度保留,FPS 恢复。

- [x] `split_bldg_by_connectivity.py`:加 `--dem-usdz` / `--envelope-json` / `--tile-id` / `--dem-tile-id` 参数
- [x] Blender 端 `Object.ray_cast` 采 DEM,coord 映射:`dem_X = bldg_X + (bldg_env.east - dem_env.east)` 等
- [x] 单个建筑 snap 完之后 `bpy.ops.object.join()` 回单 mesh
- [x] 5 tile 重新生成:5.8 MB 总(3 栋建筑在 DEM 覆盖边界外、留 nusamai 原 Y,可接受)
- [x] RootView 不再传 `terrainSampler` 给 `loadDefaultCorridor`(tile 已 pre-snap、runtime 不该再移)
- [x] ADR-0008 加 Phase 6.1 addendum

**合計 332 tests / 0 failures**(SDGGameplay 332)

### Phase 6.1 仕上げ — 完了(2026-04-23、commits `a59f28b` / `9e4fdb7` / `0d44a2d`)

Phase 6.1 初版は真機で依然「建物が飛ぶ」症状。3 回の iter で根治:

- [x] **iter 1 (`a59f28b`)** — foundation-snap を centroid → 5th pct → 25th pct に変更。
      LOD2 の basement skirt(真の 1 階より 1〜5m 下に垂れてる ground-surface
      polygon)を飛び越えて本当の 1 階壁頂点をアンカーにする狙い。
      副次的に vertex 数が少ない単純 cube(8〜12 verts)だと 25% も strict min と
      同じになるが、複雑建物では差が出る。
- [x] **iter 2 (`9e4fdb7`) — 真因修正**:残ってた `envelopeTileGroundLift = 18.0`
      を削除。これは Phase 4 iter 2〜9 で「runtime snap が足りない分を定数 lift で
      誤魔化す」ため入れた値で、Phase 6.1 Blender オフラインが完璧に snap して
      以降は **純粋な 18m 浮き**になってた。診断スクリプトで「ベイク済み USDZ は
      全 building が DEM に 0.00m 誤差で載ってる」を確認 → ランタイムに原因を
      特定 → `tilePlacement` の `+=` を削除。
- [x] **iter 3 (`0d44a2d`) — 坂面対策**:平地は OK になったが青葉山 / 川内の坂面で
      建物が剛体故に片側浮き。全 building foundation を DEM より **0.75m 下**に
      沈める `SLOPE_SINK_M = 0.75` を Blender 側に追加。坂上側の埋まり(不可視、
      terrain occlude 頼り)と引き換えに坂下側の浮きを sub-metre に縮小。

**教訓**:
1. 数学の方向性を確認せず直感で percentile を振るとハマる。delta 式が
   `target - anchor` なら anchor が低いほど shift UP が大きくなる(直感の逆)。
2. 「runtime 側をキレイにする」類の移行は、**過去の iter で入れた定数が残ってないか**
   必ず grep する。今回の 18m lift は 3 ヶ月前の Phase 4 の残滓だった。
3. **剛体 building + 坂面**は per-vertex 変形しない限り本質解なし。
   SLOPE_SINK_M で誤魔化すのが現実解。per-building slope-aware dynamic sink
   は将来最適化として保留(ray_cast 4 方向勾配取れる)。

**合計 415 tests / 0 failures**(SDGCore 22 + SDGGameplay 324 + SDGPlatform 20 + SDGUI 49)

### Phase 6 PLATEAU per-building DEM snap — 完了(2026-04-23、同 PR #12 branch)

Phase 5 per-tile rigid-body snap で tile 内部 150m 高差に対応できず、真機で一部建筑飞天/埋地。
→ Phase 6: 各 tile の mesh を Blender で**建物ごとに分割**、RealityKit 加载時各建筑独立 snap。

- [x] `Tools/plateau-pipeline/split_bldg_by_connectivity.py` — weld 1mm → LOOSE separate → multi-object USDZ
- [x] `Tools/plateau-pipeline/split_all_bldgs.sh` batch driver
- [x] 5 tile 再生成:275 / 277 / 1302 / 914 / 1675 = **4443 栋建筑**、合計 6.5 MB
- [x] `PlateauEnvironmentLoader.snapDescendantBuildings` — DFS walk、各 ModelComponent 実体を独立 snap
- [x] 3 新 tests、ADR-0008 記録
- [x] (后被 Phase 6.1 覆盖:runtime snap 搬到 Blender 离线 + merge,precision 保留 FPS 恢复)

**合計 332 tests / 0 failures**(SDGGameplay 332)

### (旧) Phase 4 PLATEAU 真対齐 — 完了(2026-04-23、branch `feat/phase-4-citygml-envelope-alignment`)

**ADR-0006 で延期していた DEM 整合を root-cause で解決**。

- [x] `Tools/plateau-pipeline/extract_envelopes.py` + `extract_bldg_gmls.sh`
      — 各 CityGML の `<gml:Envelope>` を解析、pyproj で EPSG:6697→6677 投影、
      sidecar JSON に出力
- [x] `Resources/Environment/plateau_envelopes.json`(1.4 KB、6 tiles)
      — 5 bldg + 1 dem の real-world 原点を ship
- [x] `Packages/SDGGameplay/.../World/EnvelopeManifest.swift`
      — `PlateauEnvelope` 構造体 + manifest loader + `realityKitPosition(for:)`
      (EPSG:6677 → RK Y-up 座標変換内包)
- [x] `TerrainLoader.swift` 復活 + manifest 統合(envelope 時は
      `centerHorizontallyAndGroundY` スキップ)
- [x] `PlateauEnvironmentLoader.loadDefaultCorridor(manifest:)` — manifest
      あれば各 tile を `realityKitPosition(tile.rawValue)` で絶対配置、
      `PlateauTileCenterMode.none` で centering skip、一部欠損時は legacy fallback
- [x] RootView:bootstrap で manifest 読み込み → 両 loader に注入 →
      spawn Y = terrain 表面 Y + 0.1m
- [x] 5 waves 並列 subagent(Python + Swift model 並列 → Terrain + BldgLoader 並列 → main integration)
- [x] ADR-0007: CityGML envelope alignment
- [x] 17 新規 tests(EnvelopeManifest 9 + TerrainLoader 5 + EnvLoader 3)

**合計 322 tests / 0 failures**(SDGCore 22 + SDGGameplay **322** + SDGPlatform 20 + SDGUI 49)

**真機実測予定**:f.shera 次回確認。期待:青葉山建築群が山上、川内建築群が谷、spawn で視差感あり。残余 1-5m ズレは DEM 粒度(30m)由来で許容。

### 訂正(ADR-0007 途中で発見)

- **EPSG:6677 は Zone IX、ではなく(仮)Zone X** — 当初計画は X と書いていたが
  実際は Zone IX(原点 36°N / 139°50'E)。仙台は原点から ~266 km 離れてる。
  Python script の sanity check 閾値 500km に緩和、ADR-0007 に明記。

### Phase 7 Vehicle pilot UX — 完了(2026-04-23、branch `feat/phase-7-vehicle-pilot`)

Phase 2 Beta で data 層(VehicleStore / VehicleControlSystem / .enter/.exit/.pilot
intent + VehicleSummoned/Entered/Exited event)は全実装済だが、真機で 🚁 押して
drone 召喚はできても**乗れない**状態だった。UX 層 3 枚を足して closed loop に。

- [x] **joystick 経路切替** in RootView:`.onChange(of: joystickAxis)` で
      `vehicleStore.occupiedVehicleId != nil` なら `vehicleStore.intent(.pilot)`、
      それ以外は `playerStore.intent(.move)`。joystick View は Store を知らないまま。
- [x] **BoardButton**(`Packages/SDGUI/Sources/SDGUI/HUD/BoardButton.swift`):
      80×80pt 円形、3 mode(`.hidden` / `.boardAvailable` / `.exitAvailable`)。
      HUDOverlay が `vehicleStore.occupiedVehicleId` + `vehicleStore.summonedVehicles`
      + `playerWorldPosition` から mode を導出。3m 以内で最近傍の vehicle に board。
- [x] **camera re-parent** in RootView.bootstrap():`VehicleEntered` 購読 →
      PerspectiveCamera を player から vehicle に移し(boom +Y1m / -Z2m)、
      playerBody.isEnabled = false。`VehicleExited` で逆操作 + player を
      vehicle 位置に teleport。
- [x] **VehicleStore.entity(for:)** public API 追加(HUD proximity + RootView
      camera handler 両方が必要、3 tests 追加)
- [x] RootView で 10Hz `Timer.publish` polling → `polledPlayerPosition` を
      HUD に流す(毎 frame redraw 回避)
- [x] ADR-0009 記録

**架構決定**:
- 経路切替は RootView に押し付け(joystick View は Store 非依存のまま)
- camera mutation は RootView 側(Store は scene graph に触らない、AGENTS.md §1)
- proximity は scalar distance 3m(collision trigger は Phase 7.1 送り)
- `isEnabled = false` で player system も自動停止(defence in depth)

**残課題(Phase 7.1 候補)**:
- 垂直スティック(drone 上下)— MVP は vertical 0 固定
- camera spring damping + obstacle avoidance
- exit 時に DEM raycast で safe landing Y

### Phase 8 Disaster events MVP — 完了(2026-04-23、同 branch)

Phase 4〜6.1 で PLATEAU 位置合わせが仕上がった直後、地形を活かす最初のゲーム機能。
earthquake + flood の両方、debug button で手動トリガー。quest 駆動は Phase 8.1 送り。

- [x] `Packages/SDGGameplay/Sources/SDGGameplay/Disaster/` 新規モジュール
  - `DisasterEvents.swift`:4 GameEvent(Earthquake/Flood × Started/Ended)
  - `DisasterStore.swift`:`@Observable @MainActor` 純粋状態マシン(idle / earthquakeActive / floodActive)
  - `DisasterComponent.swift`:`DisasterShakeTargetComponent` + `DisasterFloodWaterComponent` 2 marker
  - `DisasterSystem.swift`:毎 frame `Task { await store.intent(.tick) }` + tile XZ shake(Y 無視して DEM 貴重)+ flood water plane 遅延生成 + lerp
  - `DisasterAudioBridge.swift`:`AudioEventBridge` の双子、`EarthquakeStarted` → `.earthquakeRumble` 等
- [x] `AudioEffect.swift` に `.earthquakeRumble` / `.floodWater` 追加
- [x] `Resources/Audio/SFX/disaster/` placeholder SFX(既存 Kenney copy)
- [x] `DebugActionsBar` に 🌋(waveform.path.ecg) と 💧(drop.fill) 追加
- [x] RootView: DisasterStore 作成、`DisasterSystem.boundStore` バインド、
      corridor tile 全部に `DisasterShakeTargetComponent` 付与、🌋/💧 handler
- [x] Disaster tests 19 本(Store 9 + System 5 + AudioBridge 5)
- [x] ADR-0010 記録

**架構決定**:
- Store + System 分離(Store = 時間管理、System = 描画)
- XZ だけ揺らす(Phase 6.1 DEM snap を壊さない)
- 2 正弦波(13Hz / 17Hz)で非周期的 shake(noise lib 不要)
- per-tile marker で個別 shake(corridor root 揺らすと player も動く)
- `DisasterSystem.boundStore` は `static var`(System.init(scene:) 制約の妥協、
  `static let shared` でないので arch_lint OK、ADR で根拠明記)
- Placeholder SFX は既存 Kenney copy(後で差し替え可能)

**残課題(Phase 8.1 候補)**:
- quest → disaster 自動トリガー(`disasterOnComplete` JSON schema)
- `AudioService.stop(_:)` 実装 + Ended subscriber で停止
- `boundStore` → marker entity 間接指定
- perlin noise / epicentre attenuation
- 本物の earthquake/flood SFX
- 洪水 ripple shader(Reality Composer Pro)

### Phase 11 PLATEAU 建物纹理 + GSI orthophoto — 完了(2026-04-24、branch `feat/phase-11-textures`)

Phase 10 まで、街並は「暖色一色の Toon 建物 + 均一オリーブ緑の地面」だった。
PLATEAU の LOD2 は実写 facade JPG(1065 枚/65 MB)を持っているが、パイプラインの
**5 層**で全部落とされていた:

1. `extract_bldg_gmls.sh` は `.gml` だけ展開、`_appearance/` フォルダ捨てる
2. `convert.sh` → nusamai に texture flag 無し(実は flag そのものが存在しない、layout 駆動)
3. `split_bldg_by_connectivity.py` が `strip_all_materials()` 呼んで `export_materials: False`
4. `dem_to_terrain_usdz.py` が `export_uvmaps: False` + strip_materials()(DEM に UV 無し)
5. 実行時 `applyToonMaterial` が全 ModelComponent を flat cel で上書き

全部直した。視覚スタイル: **painted-realistic**(テクスチャ保持 + emissive +0.25 + ink outline)。

- [x] **Part A** `extract_bldg_gmls.sh`: `_appearance/` も展開(~1065 JPG ≈ 65 MB)
- [x] **Part B** `convert.sh`: nusamai は layout 駆動(flag 不要)と判明。loud warn 追加
- [x] **Part C** `split_bldg_by_connectivity.py`: strip_all_materials 削除、
      export_materials/textures/uvmaps 全部 True、`downscale_textures_inline.py`(新規)
      で全 JPG を 512×512 q=80 に縮小、`split_all_bldgs.sh` に `PIPELINE_VERSION=p11-textures`
      sidecar stamp 追加(Phase 6.1 USDZ が次回 run で regenerate される)
- [x] **Part D** `ToonMaterialFactory.mutateIntoTexturedCel`(新メソッド)+
      `PlateauEnvironmentLoader.applyHybridToonTint`(rename + 新動作)
      PBR w/ texture → 保持 + emissive boost;それ以外 → flat cel fallback
- [x] **Part E** `download_gsi_ortho.sh` + `gsi_tile_math.py`(GSI WMTS zoom 17 で
      ~81 tile 取得、PIL stitch、EPSG:6677 bbox にトリム、1024² へ downscale)+
      `dem_to_terrain_usdz.py` に `generate_planar_uvs` + `attach_ortho_material` +
      `TerrainLoader.applyHybridTerrainTint`(同じ hybrid pattern)
- [x] **Part F** ADR-0012、`Resources/Credits.md`(CC BY 4.0 要件)、本ファイル

**iOS 26.4 API 発見**(β sub-agent):`PhysicallyBasedMaterial.baseColor.texture` は
public read/write。`TextureResource` は Equatable だが `===` identity は通らない
(内部 wrapper の fresh handle)。value-copy 経由で round-trip 成立。Risk R1 回避。

**合計 480 tests / 0 failures**(SDGCore 22 + SDGGameplay 409 + SDGPlatform 20 + SDGUI 49)

**ユーザ作業(Blender 必要、sub-agent には不可能)**:

```bash
# 1. 建物 pipeline 再生成(~30 分/tile × 5)
rm -rf Tools/plateau-pipeline/input/extracted
bash Tools/plateau-pipeline/extract_bldg_gmls.sh
bash Tools/plateau-pipeline/convert.sh
bash Tools/plateau-pipeline/split_all_bldgs.sh

# 2. DEM pipeline(初回は GSI tile 取得で ~10 秒)
bash Tools/plateau-pipeline/download_gsi_ortho.sh
bash Tools/plateau-pipeline/convert_terrain_dem.sh

# 3. ビルド + 真機確認
xcodebuild -scheme SendaiGLab -destination 'platform=iOS Simulator,name=iPad Pro 13-inch (M5)' build
```

**予算**:Environment USDZ 合計 6 MB → ~21.5 MB(+15.5 MB 内、Git LFS 自動追跡)。

**Wave 4 実行で発覚したリスク R2(nusamai 0.1.0 限界)** — ADR-0012 に記録済:

- nusamai 0.1.0 の `gltf` sink は texture 関連オプションを一切サポートしていない
  (`use_lod` のみ)。adjacent `_appearance/` folder は何の効果も持たない。
- `3dtiles` sink はオプション文字列を parse するが 0.1.0 では機能未完成で tile GLB を書き出さない。
- 追加発見:5 tile のうち **57403619 の 1 つだけ**が PLATEAU 2024 release の zip に
  `_appearance/` folder を持つ。他 4 tile は source データ側でテクスチャ無し。

**実際に ship したもの**:
- Part A–D の Swift + pipeline コードは全部 land(nusamai 新版が来たら即点火する仕込み)
- **Part E (DEM orthophoto) 完走** — Terrain USDZ に 326 KB GSI 卫星图が焼き込まれた
  (`unzip -l` で `textures/sendai_574036_05.jpg` 確認済)
- 建物 USDZ 再生成は skip(意味がないため — hybrid runtime の fallback branch で
  現状維持)

**unblock 条件**(将来 phase):
1. nusamai upgrade が `--sink gltf` で texture を emit するように
2. CityGML の `<app:TextureFile>` を Blender で手動 remap する post-process script
3. PLATEAU の再リリースで全 5 tile に `_appearance/` が入る

**未検証(次 playtest)**:
- DEM 地面が仙台衛星写真として真機でまともに表示されるか
- UV 方向が合ってるか(逆転が必要なら dem_to_terrain_usdz.py で u/v を flip)
- 走廊 FPS(現状 60 fps、1024² JPG 1 枚で落ちないはず)
- outline 濃度 + emissive で "painted-realistic" 感(地面だけ)

### Phase 3 残り候補(次回以降)

1. 真 step-ramp Toon Shader(ADR-0004 方案 A、Reality Composer Pro)
2. ~~灾害イベント(地震 + 洪水)~~ — **Phase 8 で完了**
3. Meshy image-to-3d で chibi 再生成(f.shera の concept art 待ち)
4. ~~Vehicle pilot UX~~ — **Phase 7 で完了**
5. 真の薄片写真(f.shera 研究室素材)
6. ~~per-building DEM re-projection~~ — **Phase 6.1 で完了**
7. ~~PR #12 をマージ~~ — **完了(main `48396f3`)**
8. ~~PLATEAU 建物纹理 + DEM orthophoto~~ — **Phase 11 で完了**
8. Phase 8.1: disaster クオリティ向上(quest 連携、本物 SFX、noise 関数)

## よく参照するパス

- 旧 Unity 資産:`/Users/user/Unity/GeoModelTest/Assets/`
- 旧 Unity Story:`/Users/user/Unity/GeoModelTest/StorySummary.md`
- 旧 Unity CLAUDE.md:`/Users/user/Unity/GeoModelTest/CLAUDE.md`

## ビルド・実行コマンド

```bash
# xcodeproj の再生成(project.yml を変更した時)
xcodegen generate

# iOS simulator build(M4/M5 どちらも可、CI は dynamic 解決)
xcodebuild -scheme SendaiGLab \
  -destination 'platform=iOS Simulator,name=iPad Pro 13-inch (M5)' build

# Core の単体テスト
swift test --package-path Packages/SDGCore

# 架构合規 lint
bash ci_scripts/arch_lint.sh

# 資産バリデーション
python3 Tools/asset-validator/validate.py Resources/
```

## 会話テンプレート応答

- 「進捗は?」 → 本ファイルの「進捗メモ」を読み上げ
- 「次何やる?」 → 進捗メモ末尾の「Phase 3 候補」リストを読む
- 「屎山になりそう」 → AGENTS.md §1 の原則を再確認

## 重要な技術的落とし穴(再発防止)

これまでに 2 回以上衝突した問題。新しいコードを書く前に該当箇所を確認:

1. **iOS .app bundle は Resources/ を**平坦化**する**(folder-reference でない限り)
   - 影響:`Bundle.main.url(forResource:subdirectory:)` でサブディレクトリ指定すると
     production で file not found になる一方、SPM test bundle(`Bundle.module`)では
     サブディレクトリが保存される
   - 対策:両方試すパターン(subdirectory 先 → root fallback)を使う。参考:
     `AudioService.pickURL`、`GeologySceneBuilder.loadOutcrop`
2. **iOS `AVAudioPlayer` は Ogg Vorbis を再生できない**(Phase 2 audio bug 第 1 層)
   - 症状:`AVAudioPlayer(contentsOf: .ogg)` が throw → makePlayer が silently
     swallow → 全 SFX 無音。bundle path を何度修正しても直らない。
   - 対応:対応フォーマットは AAC/M4A、MP3、WAV、AIFF、ALAC。Kenney 等の OGG 素材を
     import するときは **必ず事前に M4A へ transcode**。参考:
     `Tools/audio-pipeline/transcode_ogg_to_m4a.sh`、ADR-0005
   - 予防:新しい audio 形式を使うときは `AudioService.makePlayer` の
     `os.log` error(category `audio`)を Console.app で確認
3. **`AVAudioSession.Category.ambient` は silent switch で完全無音化される**(Phase 2 audio bug 第 2 層)
   - 症状:デコード・再生は成功しているのに iPad(/Control Center)がミュート状態だと
     全 SFX が一切聞こえない。M4A に直した後も残った最後の壁。
   - 対策:ゲーム/メディア app は `AVAudioSession.Category.playback` + option
     `.mixWithOthers` を使う(参考:`SendaiGLabApp.init`)。`.playback` は silent
     switch を無視、`.mixWithOthers` で Apple Music 等は止めない。
   - 予防:新しい audio 実装時は iPad をミュートにしてテストする。起動時の
     `[SDG-Lab][audio] AVAudioSession activated` breadcrumb が Console.app
     に出ているか確認。
4. **ModelIO は GLB を読めない(iOS 26.4 現時点)**
   - 回避:Blender CLI で事前 USDZ 変換。参考:`Tools/plateau-pipeline/glb_to_usdz.py`
5. **project.yml の `type: folder` は iOS codesign を破壊する**
   - 理由:`.app/Resources/` サブディレクトリが codesign に "nested bundle" と誤解される
   - 対策:`type: folder` を使わず、個別ファイル参照か通常 `buildPhase: resources`
6. **Meshy v2 text-to-3d は `art_style="cartoon"` を拒否**(2026-04-22 現在)
   - `art_style="realistic"` + prompt で chibi 誘導するしかない
7. **Swift 6 Strict Concurrency で `@MainActor` が必要な箇所**
   - RealityKit System → `@MainActor`(scene mutation のため)
   - `@Observable` Store は View からアクセスするなら `@MainActor`
   - AVAudioPlayer 非 Sendable → AudioService 全体 `@MainActor`
8. **`DEVELOPMENT_TEAM` はリポジトリに commit しない**
   - 各開発者の `LocalSigning.xcconfig`(gitignored)で管理
   - project.yml の `configFiles` で参照
9. **Silent `catch { return nil }` は絶対に避ける**
   - 例:`AudioService.makePlayer` で `AVAudioPlayer` 初期化失敗を swallow
     していたら OGG 無音が 2 phase に跨って再現。catch 節には必ず `os.log`
     か `#if DEBUG print` を残す。
   - 教訓:fire-and-forget API でも **失敗は observable にする**
