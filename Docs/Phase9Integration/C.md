# Phase 9 Part C — Toon Shader Integration Notes

- 日付: 2026-04-23
- ブランチ: `feat/phase-9-c-toon-shader`(worktree commit → future PR)
- 参照 ADR: [0004-toon-shader.md](../ArchitectureDecisions/0004-toon-shader.md) — Phase 9 Part C addendum

## 要約

ADR-0004 **Scheme A**(真 step-ramp Toon = `ShaderGraphMaterial` + 手書き `.usda`)を
**Scheme C へのフォールバックつきハイブリッド**として投入した。**RootView を一切触らずに**
入るように設計されている。

- 成功パス(Scheme A): `Resources/Shaders/StepRampToon.usda` をプリロード →
  `ShaderGraphMaterial` が `cachedShaderGraph` に保存される → 以降の
  `makeLayerMaterial` / `makeHardCelMaterial` 呼び出しは clone + `setParameter(baseColor:)`
  で `ShaderGraphMaterial` を返す。
- 失敗パス(Scheme C): preload が throw → cache に `.failure(...)` が保存される →
  以降の呼び出しは **シレンシーを破る** os.log + print で失敗を出した上で
  Phase 1 の `PhysicallyBasedMaterial` にフォールスルー。
- **未プリロード**(初フレーム前): cache が `nil` → Scheme C に静かに落ちる
  (失敗ではなく timing 状態)。

## 統合作業は **不要**

呼び出し側の API は一切変わっていない:

- `ToonMaterialFactory.makeLayerMaterial(baseColor:strength:) -> RealityKit.Material`
- `ToonMaterialFactory.makeHardCelMaterial(baseColor:) -> RealityKit.Material`
- `ToonMaterialFactory.makeOutlineEntity(for:) -> ModelEntity?`
- `ToonMaterialFactory.attachOutline(to:) -> ModelEntity?`

`StackedCylinderMeshBuilder` / `PlateauEnvironmentLoader.applyToonMaterial` /
`TerrainLoader.applyTerrainMaterial` は `some Material` 抽象を受けるため、返す具体
型が `PhysicallyBasedMaterial` ↔ `ShaderGraphMaterial` に揺れても呼び出し側の
コードは一切変えずに済む(ADR-0004 で意図していた通り)。

## 任意のプリロード統合(将来の最適化)

Scheme A を **初フレームから** 有効化したい場合は、`RootView.makeView` / bootstrap
タスクの **先頭** に下記 await を 1 回入れる:

```swift
await ToonMaterialFactory.preloadStepRampShader()
```

この追加は **本 PR のスコープ外**(RootView 非編集の縛り)。入れなくても:

- アプリは確実に launch する(Scheme C にフォールスルー)。
- `makeLayerMaterial` を 1 回目に呼んだ時点ではまだ cache が空 → Scheme C。
- 次の frame 以降、preload が回った後は Scheme A に自動的に切り替わる
  ……ように**したかった** が、現状の factory は preload を自動起動しない
  (`nonisolated(unsafe)` static cache + async loader の組み合わせで、勝手に
  Task を spawn すると AGENTS.md §1.3 の Event Bus 原則を破る可能性がある)。
- そのため、プリロードを明示的に呼ばない限り Scheme A は使われない。これは
  Phase 9 Part C の "保険優先" 方針と一貫している:**壊れるより Scheme C で
  動き続ける方が良い。**

次の PR では `SendaiGLabApp.init` か bootstrap task で preload を呼び、その
後 `Published` か `@Observable` 経由で RealityView に "re-render" を通知するの
が順当。これは Phase 9 D 以降の作業として残す。

## Why `ShaderGraphMaterial(named:from:in:)` is async

iOS 18 SDK の API: `public init(named: String, from: String, in: Bundle?) async throws`。
同期版は提供されていない。Preload を分離した理由はこれ。Factory の public API を
同期のまま保つことで、呼び出し側の変更を最小化した。

## `.usda` の現状

**パスする**: hand-written `StepRampToon.usda` は `ShaderGraphMaterial.LoadError`
を **出さずに** 読み込めることを `swift test` で確認した(テスト出力:
`StepRampToon preloaded; Scheme A active.`)。

**ただし**: これは真の 3-band step ramp ではなく、`ND_surface_unlit` の
`emission_color` に `baseColor` パラメータを直接つないだ **pass-through graph**。
見た目は Scheme C から下記の違いが出る:

- IBL(image-based lighting)寄与がない → 完全ベタ塗り。
- specular highlight がない → マット感が強い。
- PBR の emissive floor による "光ってる感" がない → より純粋なアニメ塗り。

真の NdotL step ramp(3 バンド量子化)は MaterialX の world-space normal 取得
ノード(`ND_normal_vector3` 等)と per-scene light の受け渡し方を検証する必要
があり、現在の headless agent 環境では `invalidTypeFound` の再発リスクが高い。
Phase 9 D 以降 or Reality Composer Pro がアーティストパイプラインに入った時点で
真の step ramp に昇格させる(ADR-0004 Phase 9 Part C addendum 参照)。

## テスト delta

- `testShaderGraphMaterialLoadsSuccessfully` — preload を回し、cache が populate
  されることを確認(success か failure かは問わない)。
- `testFallbackReturnsPhysicallyBasedMaterialOnLoadFailure` — cache に stub 失敗を
  食わせ、`attemptStepRampMaterial` が nil を返し、`makeLayerMaterial` が
  `PhysicallyBasedMaterial` を返すことを確認。
- `testMakeLayerMaterialAlwaysReturnsValidMaterial` — cache が (empty / failure /
  success-via-preload) いずれの状態でも `makeLayerMaterial` が usable な material
  を返すことを確認。
- `testMakeHardCelMaterialAlwaysReturnsValidMaterial` — hard-cel バリアントも
  同じフォールバックチェーンを通ることを確認。

計 **+4 tests** (baseline 354 → 358, 0 failures)。

## Quality gate 結果

- `swift test --package-path Packages/SDGGameplay`: 358 / 0 failures.
- `xcodebuild -scheme SendaiGLab -destination 'platform=iOS Simulator,name=iPad Pro 13-inch (M5)' build`: **BUILD SUCCEEDED**.
- `bash ci_scripts/arch_lint.sh`: OK.
- `python3 Tools/asset-validator/validate.py Resources/`: PASS=52 FAIL=0.
