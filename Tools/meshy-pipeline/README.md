# Tools/meshy-pipeline

Meshy.ai API を使った 3D キャラクタ・道具の一括生成パイプライン。

## 目的

コンセプトアート(Nano Banana / Midjourney 等で生成)→ Meshy.ai の API を使って 3D モデル化 → リグ付け → アニメーション生成 → USDZ 変換。

```
Concept image (.png)
  → Meshy /image-to-3d      (GLB, PBR texture)
  → Meshy /rigging          (humanoid bone)
  → Meshy /animation        (walk, idle, talk, ...)     [Studio plan 必要]
  → Blender optional post-processing
  → Reality Converter
  → ../../Resources/Characters/
```

## 必要なもの

- Meshy Pro 以上のアカウント(Studio で animation API 解放)
- API Key(公式ダッシュボードから取得)
- Python 3.11+
- Blender 4.0+(任意、後処理)

## セットアップ

```bash
cd Tools/meshy-pipeline
python -m venv .venv
source .venv/bin/activate
pip install -r requirements.txt
echo "MESHY_API_KEY=sk-..." > .meshy-api-key  # .gitignore 済み
```

## 参考

- [Meshy API Docs](https://docs.meshy.ai/en)
- 主要エンドポイント:
  - `/text-to-3d`
  - `/image-to-3d`
  - `/multi-image-to-3d`
  - `/rigging`
  - `/animation`
  - `/retexture`
  - `/remesh`

## 生産計画(GDD §5.1 参照)

| 資産 | 数量 | 優先度 |
|---|---|---|
| 主角(男 / 女) | 2 | P0 |
| Dr. Kaede | 1 | P0 |
| 教師 | 1 | P1 |
| 研究員 A | 1 | P2 |
| 路人 NPC | 3-5 | P2 |
| 道具(ハンマー / 钻 / 瓶) | 3 | P0 |
| 钻塔 / 无人机 / 钻车 | 3 | P1 |
| 实验室装置 | 5-8 | P1 |
| 自然装饰 | 5-10 | P2 |

## スクリプト(Phase 0 で最小実装)

```
meshy_batch.py          # 一括生成ドライバ
character_config.yaml   # キャラ定義(名前、ref 画像、アニメ一覧)
.meshy-api-key          # API key(.gitignore)
output/                 # GLB / USDZ 出力(.gitignore 対象、LFS で管理)
```

## 注意

- API Key は絶対に commit しない
- 生成済み GLB は重いので output/ ディレクトリは .gitignore
- 確定版 USDZ のみ `Resources/Characters/` に LFS 管理で置く
- Meshy 利用規約(Studio plan)での商用利用条件を遵守
