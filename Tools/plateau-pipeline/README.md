# Tools/plateau-pipeline

PLATEAU CityGML → USDZ 変換パイプライン。

## 目的

仙台市 2024 年度 PLATEAU データ(CityGML)を、SDG-Lab が使う `.usdz` アセットに変換する。

```
CityGML (.gml)
  → plateau-gis-converter (Rust CLI)
  → glTF (.glb)
  → Blender batch script (Toon 化 + LOD 簡略化)
  → usdz via Reality Converter
  → ../../Resources/Environment/
```

## 必要なツール

| ツール | バージョン | インストール |
|---|---|---|
| [plateau-gis-converter](https://github.com/Project-PLATEAU/PLATEAU-GIS-Converter) | latest | Release から macOS Apple Silicon バイナリを DL、`xattr -d com.apple.quarantine` で隔離解除 |
| Blender | 4.0+ | https://www.blender.org/ |
| Reality Converter | latest | https://developer.apple.com/augmented-reality/tools/ |

## データソース

- [PLATEAU 仙台市 2024](https://www.geospatial.jp/ckan/dataset/plateau-04100-sendai-shi-2024)
- ライセンス:Project PLATEAU サイトポリシー(商用可)

## カバー範囲(Phase 2 で順次追加)

- [ ] 土樋 / 五橋(東北学院大学周辺)
- [ ] 広瀬川 沿い
- [ ] 青葉城跡
- [ ] 東北大 川内キャンパス
- [ ] 東北大 青葉山キャンパス

## スクリプト(TBD)

```
convert.sh           # メインパイプライン
blender_toon.py      # Blender バッチ Toon 化
lod_config.json      # LOD しきい値設定
```

Phase 0 で最小 1 tile の貫通テストを行う。

## 実行例(予定)

```bash
./convert.sh --input ./input/Sendai_Tsuchitoi.gml \
             --output ../../Resources/Environment/Tsuchitoi.usdz \
             --lod 2
```

## 注意

- 入力の .gml ファイルは `.gitignore` 対象(サイズが大きい)
- 処理済みの .usdz は Git LFS で管理
- API Key 等は存在しない(全てローカルツール)
