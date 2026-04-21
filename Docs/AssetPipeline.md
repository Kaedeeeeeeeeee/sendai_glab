# Asset Pipeline Overview

資産の流れとツールチェーン全体像。詳細は各 Tools/*/README.md を参照。

## 全体図

```
                          ┌─────────────────────────┐
                          │    Nano Banana /        │
                          │    Midjourney (手元)     │
                          └───────────┬─────────────┘
                                      │ concept images
                                      ▼
┌───────────────────┐         ┌───────────────────┐
│  PLATEAU Open     │         │   Meshy.ai        │
│  Data (.gml)      │         │   (API)           │
└──────┬────────────┘         └────────┬──────────┘
       │                               │
       │ Tools/                        │ Tools/
       │  plateau-pipeline/            │  meshy-pipeline/
       ▼                               ▼
┌───────────────────┐         ┌───────────────────┐
│  intermediate glb │         │ raw glb (rigged,  │
│                   │         │ animated)         │
└──────┬────────────┘         └────────┬──────────┘
       │                               │
       │ Blender Toon                  │ Blender (optional)
       ▼                               ▼
┌───────────────────────────────────────────────────┐
│         Reality Converter (CLI)                   │
└──────────────────────┬────────────────────────────┘
                       ▼
                ┌──────────────┐
                │  .usdz       │
                └──────┬───────┘
                       ▼
            Resources/{Environment,Characters,Props}/
                       ▼
            Xcode project (Git LFS)
```

## 各パイプラインの責務

| パイプライン | 入力 | 出力 | 頻度 |
|---|---|---|---|
| [plateau-pipeline](../Tools/plateau-pipeline/README.md) | CityGML | USDZ 建物/地形 | 一度きり(データ更新時) |
| [meshy-pipeline](../Tools/meshy-pipeline/README.md) | concept image | USDZ キャラ/道具 | 随時(Phase 1-2 で集中) |
| [asset-validator](../Tools/asset-validator/README.md)(予定) | USDZ | レポート | CI で毎回 |

## 命名規約

- 環境:`Environment_{Area}_{Tile}.usdz`(例:`Environment_Aobayama_01.usdz`)
- キャラ:`Character_{Role}_{Variant}.usdz`(例:`Character_Player_Male.usdz`)
- 道具:`Prop_{Name}.usdz`(例:`Prop_DrillTower.usdz`)
- UI テクスチャ:`UI_{Category}_{Name}.png`

## Git LFS

以下は LFS で管理:

```
Resources/**/*.usdz
Resources/**/*.png (>1MB)
Resources/**/*.heic
Resources/**/*.jpg
```

`.gitattributes` で設定(Phase 0 中に確定)。

## ライセンス・帰属

全資産の由来を [Docs/Attribution.md](Attribution.md) にトラック。Phase 4 までに App 内"About"画面で表示する。
