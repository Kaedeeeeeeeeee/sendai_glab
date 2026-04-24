# Phase 9 Part C-v2 — Visible Toon Shader Integration Notes

- 日付: 2026-04-24
- ブランチ: `feat/phase-9-c-v2-visible-toon`
- 参照 ADR: [0004-toon-shader.md](../ArchitectureDecisions/0004-toon-shader.md) — Phase 9 Part C-v2 addendum

## 要約

C-v1 が視覚的に main と区別できなかった問題(pass-through `.usda` + マイルド PBR)への応答。
C-v2 は **path α(Scheme C の極端チューニング)と path β(真 3-band NdotL step ramp `.usda`)
を両方同時に投入**し、β が MaterialX parser 非対応で失敗しても α だけで "unmistakably toon" に
読めることを保証する。**RootView を一切触らずに** 入るように設計されている。

## 統合作業は **不要**

呼び出し側の API は一切変わっていない:

- `ToonMaterialFactory.makeLayerMaterial(baseColor:strength:) -> RealityKit.Material`
- `ToonMaterialFactory.makeHardCelMaterial(baseColor:) -> RealityKit.Material`
- `ToonMaterialFactory.makeOutlineEntity(for:baseColor:) -> ModelEntity?` ← `baseColor:` パラメータは **optional で default nil**。既存呼び出しは変更なし。
- `ToonMaterialFactory.attachOutline(to:baseColor:) -> ModelEntity?` ← 同上。

以下の 5 箇所の既存 call site は **そのまま動く**:

1. `StackedCylinderMeshBuilder.swift:231` — `makeLayerMaterial(baseColor:)` — 地質層
2. `TerrainLoader.swift:437` — `makeHardCelMaterial(baseColor:)` — DEM terrain
3. `PlateauEnvironmentLoader.swift:525` — `makeHardCelMaterial(baseColor:)` — PLATEAU 建物
4. `SampleEntity.swift:121` — `attachOutline(to:)` — sample icon outline(legacy black ink)
5. `ToonMaterialFactory+Outline.swift` — `attachOutline(to:)` — 同上

C-v2 の新 `baseColor:` オプションを使って complement-tinted outline にしたい call site
があれば、後続 PR で呼び出し側を 1 行ずつ強化できる。本 PR は既存挙動を破らないこと
を最優先。

## Path β の状態

`Resources/Shaders/StepRampToon.usda` は **真 3-band NdotL step ramp**に書き直した:

- `ND_normal_vector3` で world-space 法線
- `ND_constant_vector3` で固定太陽方向 `(0.32, 0.83, 0.45)`
- `ND_dotproduct_vector3` で NdotL
- `ND_ifgreater_color3` 二段で 3 band(threshold 0.33, 0.67)
- `ND_multiply_color3FA` で各 band を `base × {0.55, 0.80, 1.15}` に pre-shade
- `ND_surface_unlit` の `emission_color` に接続(PBR を double-apply しないため)

**これらの MaterialX node ID が RealityKit で全て通る保証はない**。C-v1 で検証済みなのは
`ND_surface_unlit` + `color3f input` だけ。新しく足した 5 種の node のいずれかが
`invalidTypeFound` を上げると cache に `.failure` を記録し、以降は Path α に流れる。

**失敗時のログ**は `os.log` + `print` で `[SDG-Lab][toon-shader]` を prefix に出る。
Console.app で `toon-shader` を filter すれば `preload failed` が出ているかすぐ分かる。

## Path α のチューニング一覧

Scheme C(PBR フォールバック)を以下に押し込んだ:

```swift
internal static let outlineScale: Float = 1.05            // was 1.02
internal static let saturationBoost: Float = 1.15         // new
internal static let hardCelEmissiveFactor: Float = 0.9    // was 0.6
internal static let softCelEmissiveFactor: Float = 0.5    // was 0.35
// + clearcoat = 0 を soft 変種にも適用(C-v1 は hard-cel のみ)
// + outline ink に complement-tint オプション追加
```

これだけで main PBR との違いは目視で明らか:
- 影側が深い黒にならない(ほぼ self-lit)
- Highlight / gloss が消える
- 彩度がやや高く "塗った" 感
- 輪郭が 2.5× 太く、黒ではなく darkened-complement のインク色

## 任意のプリロード統合(将来 C-v3)

Path β(Scheme A)を **初フレームから** 有効化したい場合:

```swift
// SendaiGLabApp.init か RootView bootstrap task の先頭に:
await ToonMaterialFactory.preloadStepRampShader()
```

この追加は **本 PR のスコープ外**(RootView 非編集の縛り)。入れなくても:

- アプリは確実に launch する(Path α にフォールスルー)。
- `makeLayerMaterial` を 1 回目に呼んだ時点ではまだ cache が空 → Path α。
- Preload を明示的に呼ばない限り Path β は使われない。

これは C-v2 の "保険優先" 方針と一貫している:**壊れるより Path α で動き続ける
方が良い**。

## テスト delta

C-v1 の 4 tests に加えて **+8 tests**(計 12 本の新規 + 16 本の既存回帰):

1. `testHardCelEmissiveFactorIs0_9` — 定数 0.9 + flow through
2. `testSoftCelEmissiveFactorIs0_5` — 0.5 factor + flow through
3. `testSaturationBoostMultipliesChannels` — 1.15 定数 + 3 channel multiply + clamp
4. `testOutlineHullScaleIs1_05` — outline scale 1.05 pin + z-fighting コメント
5. `testOutlineInkDefaultsToBlackWhenBaseColorNil` — nil baseColor → black(legacy 互換)
6. `testOutlineInkTintedByComplementWhenBaseColorProvided` — warm base → cool ink の配色 pin
7. `testFullStrengthEmissiveMatchesDocumentedFactor` — 0.35 → 0.5 の pin update
8. `testMakeHardCelMaterialDoesNotCrash` / `testBaseColorPropagatesToMaterial` が
   `.failure` を強制した上で PBR パスを exercise するよう更新

## Quality gate 結果

- `swift test --package-path Packages/SDGGameplay`: **416 tests / 0 failures**
  (baseline 379、ToonMaterialFactoryTests 16 → 24、他 worktree 既存 World/Interior
   suite 4 個も通過)
- `xcodebuild -scheme SendaiGLab -destination 'platform=iOS Simulator,name=iPad Pro 13-inch (M5)' build`: **BUILD SUCCEEDED**
- `bash ci_scripts/arch_lint.sh`: **OK**
- `python3 Tools/asset-validator/validate.py Resources/`: **PASS=52 FAIL=0**

## 真機で期待される見た目の違い

ユーザが実機で気づくはずの変化(Path α 単独でも、Path β が加わればなお強い):

- PLATEAU 建物 / DEM terrain がほぼ self-lit に見える(影の深い黒が消える)
- 全オブジェクトの輪郭が太くなる(1.02 → 1.05、視認できる差)
- 輪郭の色がオブジェクトごとにやや異なる(complement-tint が効く、soft reads)
- 彩度が 15% 高く、塗ったような発色
- 光沢・highlight の消失(PBR のハイライトバンドが出ない)

Path β が parser を通れば、さらに:
- 3 band の quantized shading が法線変化の激しい建物/地形で効く
- グラデーションが完全に消え、塗り分け境界がハッキリ出る
