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

### Phase 3 残り候補

1. **DEM alignment の完全解決** (ADR-0006 方案 A、Phase 4 最優先)
2. 真 step-ramp Toon Shader(ADR-0004 方案 A、Reality Composer Pro)
3. 灾害イベント(地震 + 洪水)— PLATEAU hazard layer 利用
4. Meshy image-to-3d で chibi 再生成(f.shera の concept art 待ち)
5. Vehicle pilot UX(入力をどう joystick から Vehicle.intent(.pilot) に回すか)
6. 真の薄片写真(f.shera 研究室素材)

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
