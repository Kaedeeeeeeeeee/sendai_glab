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
