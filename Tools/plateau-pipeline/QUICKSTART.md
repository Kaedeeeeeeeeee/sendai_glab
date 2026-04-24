# plateau-pipeline — Quickstart (Phase 2 validated recipe)

> Phase 2 起步で実際に使えた手順。Aobayama + Kawauchi corridor の 5 個
> 3rd mesh を `Resources/Environment/*.glb` に落とすまで。
>
> 大元の `INSTALL.md` は包括的だが、このファイルは 2026-04-22 に実際に
> 通したルートだけを書く。

## 0. 前提

- macOS Apple Silicon
- ~4 GB 空きディスク(zip 1.6 GB + 抽出中間 ~150 MB + 出力 17 MB)
- 30-45 分(うち 80% がダウンロード待ち)

## 1. nusamai CLI 取得

```bash
cd /tmp
curl -fLs 'https://github.com/Project-PLATEAU/PLATEAU-GIS-Converter/releases/download/v0.1.14/nusamai-v0.1.14-aarch64-apple-darwin.tar.gz' -o nusamai.tar.gz
tar xzf nusamai.tar.gz
# macOS Gatekeeper 解除(.tar.gz は quarantine attribute がつかない場合もある)
xattr -d com.apple.quarantine nusamai 2>/dev/null || true
./nusamai --version   # => "nusamai 0.1.0"
```

将来的にはこの nusamai バイナリをリポジトリに含めるか、Homebrew tap を
作るかしたい。今は Phase 2 placeholder なので局所配置。

## 2. CityGML zip ダウンロード(1.6 GB)

```bash
cd /Users/user/sendai_glab/Tools/plateau-pipeline/input
curl -fL --progress-bar -o sendai_2024_citygml.zip \
  'https://assets.cms.plateau.reearth.io/assets/33/3feee9-fb3f-4c08-8f19-a45c75700e6d/04100_sendai-shi_city_2024_citygml_1_op.zip'
```

URL は G空間情報センターの dataset ページから "CityGML (v4)" の詳細
→ ダウンロード。更新されたら上記 URL は古くなる。

## 3. 対象メッシュだけ解凍

Phase 11 以降は `extract_bldg_gmls.sh` が GML + `_appearance/` を
まとめて解凍してくれる(facade JPG がないと nusamai が flat-shaded
GLB を吐いてしまうため)。

```bash
bash Tools/plateau-pipeline/extract_bldg_gmls.sh
```

上記で `input/extracted/udx/bldg/` 以下に:
- `{tile}_bldg_6697_op.gml` × 5
- `{tile}_bldg_6697_appearance/*.jpg` (5 フォルダ、~1 065 JPG、~65 MB)

が展開される。手動でやる場合は下記(Phase 2 時代のワンライナー):

```bash
mkdir -p extracted && cd extracted
unzip -q ../sendai_2024_citygml.zip 'codelists/*' 'schemas/*' 'metadata/*' README.md
for m in 57403607 57403608 57403617 57403618 57403619; do
  unzip -q ../sendai_2024_citygml.zip "udx/bldg/${m}*"
done
cd ..
```

参考:このメッシュ範囲は索引図 PDF(`../input/04100_indexmap_op.pdf` に
コピー可)で確認できる。Aobayama は大まかに **57403617** の南東隅。

## 4. GLB 変換

**重要**:`--epsg 6677` を必ず指定(日本平面直角座標系第 X 系、宮城県)。
省略すると WGS84 のまま流れて "glTF sink requires Japan Plane
Rectangular coordinate system" で落ちる。

```bash
cd /Users/user/sendai_glab/Tools/plateau-pipeline/input/extracted
mkdir -p ../converted
for m in 57403607 57403608 57403617 57403618 57403619; do
  /tmp/nusamai "udx/bldg/${m}_bldg_6697_op.gml" \
    --sink gltf \
    --output "../converted/bldg_${m}.glb" \
    --epsg 6677
done
```

nusamai の出力は **ディレクトリ**(`bldg_{mesh}.glb/bldg_Building.glb`)。
単一ファイルを欲しいなら:

```bash
for m in 57403607 57403608 57403617 57403618 57403619; do
  mv "../converted/bldg_${m}.glb/bldg_Building.glb" \
     "../../../Resources/Environment/Environment_Sendai_${m}.glb"
  rmdir "../converted/bldg_${m}.glb"
done
```

## 5. 一時ファイル削除

```bash
rm -rf input/extracted input/converted
# input/sendai_2024_citygml.zip は残す(再ダウンロード防止、gitignored)
```

## 6. USDZ 変換(未実装)

Phase 2 起步点では **GLB のまま `Resources/Environment/` にコミット**
している(LFS)。RealityKit は USDZ を優先するが、GLB ロードも
`Entity(named:in:)` では一部サポート不十分で、確実には USDZ が必要。

Phase 3 の選択肢:
1. **Reality Converter.app** (Apple 公式、GUI のみ)— GLB を drag、書き出し、ファイル名を `Environment_Sendai_{mesh}.usdz` に改名
2. **`usd-core`** (Python, pip)— 書ける USD バージョンに制約あり、要検証
3. **ModelIO + Swift CLI** — 一番堅いが自前で書く必要

いずれも Phase 3 美術工程の中で決定。

## 変換結果(2026-04-22 実測)

| 3rd mesh | 概ねの場所 | GLB サイズ |
|---|---|---|
| 57403607 | 青葉山北側 | 917 KB |
| 57403608 | 青葉城跡方面 | 938 KB |
| 57403617 | 東北大青葉山 | 4.2 MB |
| 57403618 | 川内 | 3.2 MB |
| 57403619 | 片平 / 東北学院大近辺 | 7.0 MB |

**合計 16 MB**、149 建物タイル、座標系は日本平面直角座標系 第 X 系
(原点は 38.0°N 140.833°E 付近)。

RealityKit 側では Toon Shader 化(ADR-0004)と中心合わせ、スケール
調整は Phase 2 Alpha で `PlateauEnvironmentLoader` が担当する予定。
