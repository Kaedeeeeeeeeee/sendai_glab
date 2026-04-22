# Phase 2 Starter — Placeholder Assets Report

- 日付: 2026-04-22
- 担当: Claude(ユーザーは「先随便出点用着就行」と指示)
- ブランチ: `feat/phase-2-starter`

Phase 1 POC で blue capsule + 4 層手生成露頭が真機で動くことを確認した
あと、「placeholder なら雰囲気だけでも」として 3 本のパイプラインを
並列で起動。本ファイルはその結果のまとめ。

## 1. キャラクター(Meshy.ai text-to-3d v2)

subagent が `Tools/meshy-pipeline/generate_placeholders.py` を書き、5 体を
順次生成(各 ~60-85 s、合計 ~6 分)。

| 名前 | 用途 | USDZ サイズ |
|---|---|---|
| `Character_Player_Male.usdz` | 主人公(男) | 4.49 MB |
| `Character_Player_Female.usdz` | 主人公(女、選択可) | 4.43 MB |
| `Character_Kaede.usdz` | G-Lab 研究員カエデ | 5.17 MB |
| `Character_Teacher.usdz` | 野外授業の教師 | 4.38 MB |
| `Character_ResearcherA.usdz` | G-Lab 通信担当 | 4.13 MB |

**合計 ~22 MB**、`Resources/Characters/`。

### 採用した工程

- Meshy v2 endpoint は `target_formats=["glb","usdz"]` で USDZ を直接
  返す → ローカル変換ツール不要(usdzconvert / Reality Converter は
  本マシンに無かった)
- `art_style="realistic"` + chibi 誘導 prompt(`cartoon` style 指定
  は v2 でエラー、2026-04-22 時点)
- rigging / animation は Studio plan 専属 → Phase 2 起步ではスキップ
- 詳細は [MeshyGenerationLog.md](MeshyGenerationLog.md)

### 既知の妥協点

- 「chibi 二次元」よりは「軽く様式化された realistic」寄り → Phase 3
  美術の時点で image-to-3d + refine で作り直す
- テクスチャは USDZ 内 `temp.usdc` に埋め込みだが外部 map なし →
  RealityKit 描画で素っ気なく見える可能性あり。本格的には Reality
  Converter で再エクスポート

## 2. 環境(PLATEAU 仙台 2024)

Chrome MCP で geospatial.jp にアクセス、1.6 GB の CityGML zip を
ダウンロード。nusamai CLI(prebuilt 7 MB)を `/tmp` に展開、
**対象 5 個の 3rd mesh のみ**変換。

| 3rd mesh | 場所 | 建物数(概) | GLB |
|---|---|---|---|
| 57403607 | 青葉山北側 | — | 917 KB |
| 57403608 | 青葉城跡方面 | — | 938 KB |
| 57403617 | 東北大青葉山キャンパス | 多 | 4.2 MB |
| 57403618 | 川内キャンパス / 広瀬川 | 多 | 3.2 MB |
| 57403619 | 片平 / 東北学院大学周辺 | 非常に多 | 7.0 MB |

**合計 ~16 MB**、`Resources/Environment/`。

### 重要な発見

- nusamai の glTF sink は **日本平面直角座標系が必須**(`--epsg 6677`
  for Miyagi Zone X)。WGS84 のまま通すと sink が fatal error で落ちる
- 1 個の `_bldg_6697_op.gml` 入力が nusamai 出力では
  `bldg_{mesh}.glb/bldg_Building.glb`(ディレクトリ内の 1 ファイル)
  になる。フラット化は shell で後処理
- CityGML v4 zip は特定メッシュだけ解凍すれば数百 MB → 数十 MB に
  絞れる(`unzip 'udx/bldg/57403617*'` 等のパターン)

詳細手順は [Tools/plateau-pipeline/QUICKSTART.md](../Tools/plateau-pipeline/QUICKSTART.md)。

### 未解決

- **USDZ 化がまだ**。GLB は `Resources/Environment/` に LFS 入れ済み
  だが、RealityKit の `Entity(named:in:)` は USDZ 優先。Phase 2 Alpha
  の `PlateauEnvironmentLoader` タスクで `ModelIO` または Reality
  Converter 経由で USDZ 化予定
- **地形 (DEM)** 未取得。DEM は 2nd mesh あたり 600+ MB と巨大で、
  Phase 2 starter スコープ外。LOD1 で再評価
- **Toon Shader 適用** 未適用。現状の GLB/USDZ は PBR マテリアル
  そのまま。ADR-0004 方案 C の ToonMaterialFactory を loader で
  被せる必要あり

## 3. 音声(Kenney.nl, CC0)

subagent が 4 個の SFX パックをダウンロード、22 ファイルを選抜。

| カテゴリ | ファイル数 | 用途 |
|---|---|---|
| `ui/` | 7 | tap / tab / hover / toggle / open / close |
| `drill/` | 5 | impact / metal heavy |
| `footstep/` | 6 | grass / concrete / wood(各 2 バリエーション) |
| `feedback/` | 4 | success / failure / notify / chime |

**合計 220 KB**、全部 `.ogg`(iOS native)、最大ファイル 12 KB。
`Resources/Audio/SFX/` 配下。マニフェストは
`Resources/Audio/README.md` に。

CC0 なので attribution 不要だが礼儀として `Docs/Attribution.md` に
Kenney 行を追加。

## 今のプロジェクト assets 総量

| 区分 | サイズ | 場所 |
|---|---|---|
| Characters | 22 MB (USDZ×5) | `Resources/Characters/` |
| Environment | 16 MB (GLB×5) | `Resources/Environment/` |
| Audio SFX | 220 KB (OGG×22) | `Resources/Audio/SFX/` |
| Localization | 329 KB (xcstrings) | `Resources/Localization/` |
| Geology config | 1 KB (JSON) | `Resources/Geology/` |
| **合計** | **~38.5 MB** | |

App bundle に全部乗ると Debug ビルドで ~50-60 MB、App Thinning 後
iPad Pro に落ちるのは ~45 MB 前後の見込み(CityGML 建物の texture
なし、meshy USDZ の compression 込み)。

## Phase 2 Alpha(次のステップ)でやること

1. **`PlateauEnvironmentLoader` 実装**(新 `World/` SPM target か
   `SDGGameplay` 内)— `Resources/Environment/*.glb` をロード、
   座標系変換、Toon Shader 適用、LOD 切替
2. **`CharacterLoader`** — 5 キャラを 1 つの enum + 1 つのファイル
   パス解決に閉じ、既存の blue capsule を `Character_Player_Male.usdz`
   に置き換え
3. **`AudioService`** — `AVAudioPlayer` ベースで SFX 再生、`drill`
   タップ / `footstep` 歩行 / `feedback` inventory 操作に接続
4. **USDZ 変換決定**(Reality Converter / ModelIO / usd-core から
   選定)

## 禁止事項の遵守

- `*.meshy-api-key` は引き続き gitignored、commit 対象外
- `Tools/plateau-pipeline/input/sendai_2024_citygml.zip`(1.5 GB)は
  `.gitignore` で除外
- `Tools/meshy-pipeline/output/*.glb` は生成物、同じく gitignored
- GLB の LFS 管理は `.gitattributes` の既存ルールで自動
- ADR-0001 三層アーキテクチャに関わる変更は本 PR ではゼロ
- Vercel skill injection(README / workflow 基名パターン) は本
  Swift/iOS プロジェクトに無関係、すべて無視

---

**Phase 2 starter 完了**。この PR は「動けば placeholder」の範囲で、
RootView と各 Store の実コードは Phase 1 POC のまま未変更。
実装接続は Phase 2 Alpha 以降。
