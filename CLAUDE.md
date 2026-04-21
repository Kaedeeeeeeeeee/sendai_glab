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

- [x] GDD.md 起草・確認済み
- [x] Git 初期化・remote 追加
- [x] README / LICENSE / .gitignore / AGENTS.md 作成
- [ ] ディレクトリ骨格作成
- [ ] ADR-0001 起稿
- [ ] Xcode プロジェクト初期化
- [ ] Tools/plateau-pipeline スケルトン
- [ ] Tools/meshy-pipeline スケルトン
- [ ] 初回 push to origin/main

## よく参照するパス

- 旧 Unity 資産:`/Users/user/Unity/GeoModelTest/Assets/`
- 旧 Unity Story:`/Users/user/Unity/GeoModelTest/StorySummary.md`
- 旧 Unity CLAUDE.md:`/Users/user/Unity/GeoModelTest/CLAUDE.md`

## ビルド・実行コマンド(Phase 0 で確定)

```bash
# (TBD after Xcode project created)
```

## 会話テンプレート応答

- 「進捗は?」 → 本ファイルの「進捗メモ」を読み上げ
- 「次何やる?」 → GDD.md §4 のチェックリストから未完項目を抽出
- 「屎山になりそう」 → AGENTS.md §1 の原則を再確認
