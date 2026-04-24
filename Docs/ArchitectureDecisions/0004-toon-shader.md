# 0004. Toon Shader v0 の実装方式

- 日付: 2026-04-21
- ステータス: **Accepted**
- 作成: f.shera + Claude(Phase 1 Coder-M, task P1-T10)

## コンテキスト

GDD §0 は美術方針を **「Toon Shader(二次元卡通、参考:原神 / BotW)」** と定義しているため、Phase 1 の POC には "SimpleMaterial と明らかに区別できる" トゥーン表現が必要。

ただし RealityKit の実機レンダリング系 API は複数あり、iOS 18 / macOS 15 におけるそれぞれの **入手可否・実装コスト・エージェント検証可能性** が大きく異なる:

- **`ShaderGraphMaterial`**(RealityFoundation, iOS 18 / macOS 15) — Reality Composer Pro が吐く MaterialX ベースの `.usda` をランタイム読込し、`setParameter(name:value:)` で変数を差し替える。GUI 無しのエージェントにとって `.usda` を "手書き" することは技術的には可能だが、MaterialX グラフの 1 ノード名のタイポで `.invalidTypeFound` が出るリスクを抱える。
- **`CustomMaterial`**(RealityFoundation, iOS 15+ / macOS 12+, **visionOS は unavailable**) — `SurfaceShader(named:in: MTLLibrary)` に Metal ライブラリを渡す。SPM リソースとして `.metal` を束ねて `Bundle.module` から `MTLLibrary` 相当を取り出すパイプラインが必要、かつ visionOS では使えないため将来的に二系統コードを抱える覚悟が要る。
- **`PhysicallyBasedMaterial`**(RealityFoundation, iOS 15+ / macOS 12+ / visionOS 1+) — PBR のフラット設定 + 追加ジオメトリ(back-face hull)でトゥーン風を **擬似する**。視覚的には本物のステップ型 NdotL には遠いが、API は全プラットフォーム互換で、ユニットテスト可能、追加リソース 0。

Phase 1 の優先事項は「**動く・崩れない・壊れない**」であり、視覚品質は v0(後で差し替え前提)で良い、という前提で方式選定した。

## 選択肢

### A. `ShaderGraphMaterial` + 手書き `.usda`

- **長所**: 将来的に RCP でアーティストが直接編集できる。真のトゥーン(stepped NdotL + rim light)が書ける。
- **短所(決定打)**: `.usda` は MaterialX ノードグラフを埋め込む USD テキストで、ノード ID・パラメータ型・スキーマ版がすべて厳格。GUI もビジュアル確認もできないエージェントが "最初から動く" ものを出すのは投機的すぎる。失敗時は `ShaderGraphMaterial.LoadError.invalidTypeFound` をランタイムで食らい、Geology シーンごと読み込めなくなる(MVP を止める)。

### B. `CustomMaterial` + `ToonSurface.metal`

- **長所**: Metal シェーダを直接書ける。`stepped NdotL + 等高 3 ランプ + Fresnel リム` まで Phase 1 でも書ける。
- **短所**:
  - **visionOS unavailable** が SDK の `@available` で宣言されている。将来 visionOS 展開(GDD §4 Phase 4 目標外とはいえ潜在目標)で差し替えを強制される。
  - SPM の `resources:` に `.metal` を置くだけでは自動で `default.metallib` にコンパイルされない — ビルド時ツールチェーンかアプリターゲット側の Metal コンパイルフェーズが必要。`swift test` では Metal コンパイラが走らないため、このパッケージの単体テストで "シェーダが壊れていない" 保証が取れない。
  - SDK の `MaterialFunction` は iOS 18 から `constantValues` 要求がつき、旧ビルドと微差がある(=訓練データで見た例と挙動がずれる可能性)。

### C. `PhysicallyBasedMaterial` + **back-face hull** で擬似トゥーン ⭐

- ロジック:
  1. `baseColor = tint(layerColor)` / `roughness = 1.0` / `metallic = 0.0` — 完全マットで PBR の specular を消す。
  2. `emissiveColor = clamp(base × 0.35 × strength)` — 影側の "直接光依存" を下げ、BotW / 原神系の "ベタ塗り寄り" に寄せる。
  3. **Outline**: 同メッシュを 1.02 倍スケール・`faceCulling = .front` の黒マテリアルで覆う "Back-face Hull" テクで輪郭線を出す。シルエットのみ。法線不連続は拾わないが Phase 1 の軸整列 Box には十分。

- **長所**:
  - 全 API が **iOS 15+ / macOS 12+ / visionOS 1+** で使用可能 — 将来の visionOS 展開に壁なし。
  - 追加シェーダリソース **ゼロ**。ビルドパイプライン増加なし。
  - すべて Swift 上で単体テスト可能(`ToonMaterialFactoryTests` で 12 ケース)。
  - 落ちた場合の代替が自然(PBR のまま roughness/metallic/emissive を戻すだけで PBR に退化)。

- **短所**:
  - 真のステップ型トゥーンではない。"フラット寄りの PBR" 止まり。グラデーションが残る。
  - Outline は pure silhouette。内部エッジ(同じ entity 上の法線不連続)は引けない。
  - ドローコールが 2 倍(本体 + アウトライン)。Phase 1 では 4 層 × 2 = 8 で問題無いが、PLATEAU tile 数百ドローに適用すると課題化する可能性(Phase 2 で再評価)。

## 決定

**選択肢 C を採用**。

`Packages/SDGGameplay/Sources/SDGGameplay/Geology/ToonMaterialFactory.swift` に統一インタフェース:

```swift
@MainActor
public static func makeLayerMaterial(
    baseColor: SIMD3<Float>,
    strength: Float = 0.8
) -> RealityKit.Material

@MainActor
public static func makeOutlineEntity(for entity: ModelEntity) -> ModelEntity?
```

および便利関数 `attachOutline(to:)` を `ToonMaterialFactory+Outline.swift` に分離。Outline 分離の意図は ADR §「将来方針」で後述。

**`GeologySceneBuilder` / `RootView` は本 ADR では改変しない** — 呼び出し側の差し替えは **メイン agent の統合フェーズ**の責務(P1-T10 は factory のみ提供)。

### 選定理由の要約

| 観点 | A (ShaderGraph) | B (CustomMaterial) | **C (PBR+Hull)** |
|---|---|---|---|
| iOS 18 で使用可能 | ✓ | ✓ | ✓ |
| macOS 15 で使用可能 | ✓ | ✓ | ✓ |
| visionOS で使用可能 | ✓ | ✗ | ✓ |
| 追加リソースが必要 | `.usda` | `.metal` | **なし** |
| `swift test` で検証可能 | 部分的 | 不可 | **可** |
| GUI 無しエージェントが実装可能 | リスク高 | リスク中 | **低** |
| Phase 1 視覚品質 | 高(真トゥーン) | 高(真トゥーン) | 中(擬似) |
| Phase 2 以降の拡張余地 | 高 | 高 | ◎(差し替え) |

## 結果

### メリット

- **Phase 1 の POC をブロックしない**。全部 Apple 公式 SDK の安定 API。
- `GeologySceneBuilder` が `GeologyLayerComponent.colorRGB` を保持しているので、将来 A に移る際は factory だけ差し替えで済む。呼び出し側は `some Material` 抽象を受けるだけ。
- Outline を分離ファイル (`ToonMaterialFactory+Outline.swift`) にしたので、A へ移る際(ShaderGraph は描線をシェーダで出す)に **ファイル削除一発で** outline パスを消せる。
- `PhysicallyBasedMaterial` は iOS 18 で `writesDepth` / `readsDepth` 等の新プロパティを持つ — Phase 2 の rim light / 半透明 UI 連携で活用可。

### デメリット / 負債

- 真のトゥーンではない。社外アーティストが見ると "toon っぽい PBR" と指摘される可能性が高い。Phase 2 での差し替えを前提として受容する。
- 描画コスト 2×(アウトライン hull)。仙台走廊 tile 数百レベルではフレーム時間要観測(Phase 3 で測定)。

### 実装の入口

- `Packages/SDGGameplay/Sources/SDGGameplay/Geology/ToonMaterialFactory.swift`
- `Packages/SDGGameplay/Sources/SDGGameplay/Geology/ToonMaterialFactory+Outline.swift`
- `Packages/SDGGameplay/Tests/SDGGameplayTests/Geology/ToonMaterialFactoryTests.swift`(12 tests)

呼び出し例(**メイン agent 統合時**):

```swift
let color = definition.colorRGB   // SIMD3<Float>
let material = ToonMaterialFactory.makeLayerMaterial(baseColor: color)
let layer = ModelEntity(mesh: mesh, materials: [material])
ToonMaterialFactory.attachOutline(to: layer)
```

## 未解決(Phase 2 以降で優先度順)

1. **真のステップ型トゥーンへの昇格(A 経由)**。RCP で ShaderGraph を構築して `.usda` 化し、`ToonMaterialFactory` の `makeLayerMaterial` だけを差し替える。パラメータは `base`, `stepCount` (2 or 3), `shadowDarken`, `rimStrength`。
2. **アウトライン品質**。現在は pure silhouette。Phase 2 で以下を検討:
   - 可変アウトライン幅(カメラ距離に応じて 1.02x → 1.005x で遠景細く)。
   - 内部エッジ(同 entity 内の法線不連続)を拾う screen-space エッジ検出(`CustomMaterial` post-process か、描画後に Metal compute pass)。
3. **法線鋭化**(hard shade の手前処理)。現状軸整列 Box の面法線は 6 向きしかないので効果は限定的だが、キャラクター / PLATEAU 建物には必須。
4. **リムライト**(Fresnel 項で縁だけ明るく)。`PhysicallyBasedMaterial` では直接不可 — `ShaderGraphMaterial` 昇格タイミングで同時導入。
5. **描画コスト最適化**。アウトラインを全対象に一律つけると PLATEAU tile 群で破綻する。LOD と連動してカメラ距離 > 50 m でアウトラインを無効化するガード(P1-T10 では未実装、呼び出し側で将来ガード)。
6. **Phase 2 性能計測**。iPad Pro 実機で outline あり / なし・hull 1.02 / 1.005 のフレーム時間比較を取り、実データで 2 の再設計に入る。

## 参考

- Apple: [`ShaderGraphMaterial`](https://developer.apple.com/documentation/realitykit/shadergraphmaterial)(iOS 18 / macOS 15 / visionOS 1)
- Apple: [`CustomMaterial`](https://developer.apple.com/documentation/realitykit/custommaterial)(iOS 15+ / macOS 12+、**visionOS unavailable**)
- Apple: [`PhysicallyBasedMaterial`](https://developer.apple.com/documentation/realitykit/physicallybasedmaterial)(iOS 15+ / macOS 12+ / visionOS 1+)
- WWDC23 Reality Composer Pro: [Explore materials in Reality Composer Pro](https://developer.apple.com/videos/play/wwdc2023/10202/)
- ADR-0001(三層アーキテクチャ) — 本 factory は Gameplay 層に属し、View / ECS System からは直接呼ばれず、呼び出しは `GeologySceneBuilder` / Render パイプライン経由。

---

## Phase 9 Part C-v2 Addendum (2026-04-24)

**ステータス**: **Accepted(hybrid mode, aggressive fallback tuning)**。
C-v1 が「ShaderGraph 経路はあるが `.usda` が pass-through、
フォールバックは Phase 1 のマイルド tuning」で視覚的に main と区別がつかなかった問題への応答。
C-v2 は **Path α(Scheme C の極端化)と Path β(真 3-band step ramp `.usda`)の両方**を
同時投入し、 β が失敗したら α だけでも目視で違いが出ることを保証する。

### Path α — Scheme C を "ほぼ unlit" まで押し込む

C-v1 の Scheme C は「flat-ish PBR」だった。C-v2 では PBR フォールバックそのものを
極端にトゥーン寄りにチューニングする:

| 項目 | C-v1 | **C-v2** | 効果 |
|---|---|---|---|
| `hardCelEmissiveFactor` (建物・地形) | 0.6 | **0.9** | ほぼ自己発光 — shading gradient 消失 |
| `softCelEmissiveFactor` (outcrop 層) | 0.35 | **0.5** | 影側のマディ感軽減 |
| `saturationBoost` (全 PBR パス) | なし | **1.15** | 彩度 15% up — "塗った" 感 |
| `clearcoat` (soft 変種) | default | **0.0** | gloss/highlight を hard-kill |
| Outline hull スケール | 1.02 | **1.05** | 2.5× 太いインク |
| Outline インク色 | pure black | **darkened complement**(base×−1×0.25) | 意図のある配色に |

**Path α だけでも** main PBR とは視覚的に明らかな違いが出る:
全体的にフラット、影に深い黒が出ない、輪郭が太く色つき、ハイライトが消える。

### Path β — 真の 3-band NdotL step ramp `.usda`

`Resources/Shaders/StepRampToon.usda` を書き直し:

```
baseColor ─┬─► ×0.55 ─► ShadowBand ─┐
           ├─► ×0.80 ─► MidBand  ───┤ ← ND_ifgreater_color3 × 2
           └─► ×1.15 ─► LitBand  ───┘   (thresholds 0.33, 0.67)
                                    │
N (world) ┐                         │
          ├─► ND_dotproduct_vector3 ►│
L (const) ┘                         ▼
                              emission_color
                                    │
                                ND_surface_unlit
```

- `ND_normal_vector3` で world-space 法線、`ND_constant_vector3` で固定太陽方向
  `(0.32, 0.83, 0.45)` を与え、`ND_dotproduct_vector3` で NdotL。
- 3 band を `ND_ifgreater_color3` 二段で選択、`ND_multiply_color3FA` で各 band を
  pre-shade。
- `ND_surface_unlit` の `emission_color` に接続(engine の PBR lighting を
  double-apply しないため)。

**リスク**:RealityKit の MaterialX parser が上記の node ID を全て受け付ける保証は
ない(C-v1 で確認できたのは pass-through `ND_surface_unlit` のみ)。受け付けない
場合は `ShaderGraphMaterial.LoadError.invalidTypeFound` → cache に `.failure` を入れて
Path α にフォールスルー。**失敗しても Path α の極端 tuning が visibly-different を保証する**ため、
両賭けで損はない。

### 両 path の合成戦略

```
preloadStepRampShader() が:
  success → Scheme A(3-band step ramp ShaderGraph)
  failure → log + Scheme C-v2(tuned PBR + thick outline + complement ink)
  未実行  → Scheme C-v2(timing フォールスルー、ログ出さず)
```

どの状態でも最小でも「C-v1 の Scheme C より明確に違う」レンダリングを得る。

### RootView 統合

**本 PR では統合不要**。public API はすべて同じ `RealityKit.Material` 返却。
preload は将来 `SendaiGLabApp.init` で 1 行追加(非本 PR scope)。
詳細は `Docs/Phase9Integration/Cv2.md`。

### テスト(+8)

- `testHardCelEmissiveFactorIs0_9` — 定数 0.9 とその flow through を pin
- `testSoftCelEmissiveFactorIs0_5` — soft 変種の 0.5 factor を pin
- `testSaturationBoostMultipliesChannels` — 1.15 定数 + 3 channel multiply + clamp ceiling
- `testOutlineHullScaleIs1_05` — outline scale を 1.05 に pin(z-fighting 境界)
- `testOutlineInkDefaultsToBlackWhenBaseColorNil` — legacy 呼び出し側の互換
- `testOutlineInkTintedByComplementWhenBaseColorProvided` — warm base → cool ink
- `testFullStrengthEmissiveMatchesDocumentedFactor` — 0.35 → 0.5 の pin update
- + 既存の `testFallbackReturnsPhysicallyBasedMaterialOnLoadFailure` と
  `testMakeLayerMaterialAlwaysReturnsValidMaterial` (C-v1 由来) は C-v2 でも合格

計 baseline 379 → **416 tests / 0 failures**(C-v2 ToonMaterialFactoryTests 16 → 24、
および worktree 既存の World/Interior* や Location* 4 suite が取り込まれた結果)。

### z-fighting 考慮

1.05× hull は PLATEAU 建物(厚み > 1m)では安全だが、DEM terrain の薄い三角形
(垂直成分 cm オーダ)では back-face が front を貫く可能性がある。Phase 6.1 の
per-building pre-snap + merge で建物の厚みは維持されているので実害は低いが、
真機テストで z-fighting を目視したら即座に 1.03〜1.04 に下げる(Phase 10 で測定)。

### 負債 / 次の手

1. **真 step ramp `.usda` の検証**。MaterialX node ID が RealityKit で本当に
   認識されるかは実機 or simulator でしか確かめられない。失敗時のログを
   Console.app で grep(`toon-shader`)して `invalidTypeFound` が出ていないか確認。
2. **Preload integration**。`SendaiGLabApp.init` か bootstrap task で
   `await ToonMaterialFactory.preloadStepRampShader()` を呼ぶ PR(C-v3 scope)。
3. **Rim light**。ShaderGraph 側で Fresnel 項を書けば outline hull 廃止候補。
4. **Cascade 値の ADR への pin**。Phase 10 で playtest 後、色数 / factor 値を最終化し
   本 addendum に数値を固定。
