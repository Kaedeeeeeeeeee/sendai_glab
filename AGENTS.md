# SDG-Lab — Contributor & AI Agent Guide

> このドキュメントは、**人間のコントリビュータ**と **AI コーディングエージェント**(Claude Code など)の両方向けのガイドラインです。
>
> This document is for **human contributors** and **AI coding agents** (Claude Code, etc.) alike.

---

## 1. プロジェクトの絶対原則 (Absolute Principles)

### 1.1 屎山禁止 — The Anti-Mud-Ball Rules

この新規プロジェクトは、前作 Unity プロジェクトの「屎山 (shit mountain)」問題から教訓を得ています。以下のルールを破ると、同じ運命を辿ります。**遵守は必須**です。

#### Rule 1: 三層アーキテクチャ (Three-Layer Architecture)

```
[SwiftUI View] ──(intent)──▶ [Store: @Observable] ──(event)──▶ [ECS: RealityKit Systems]
      ▲                              │                                 │
      └──── @Observable 状態読取 ─────┘                                 │
                                     ▲                                 │
                                     └────(event)────────────────────┘
```

- **View** は UI のレンダリングのみ。ビジネスロジック禁止。Entity を直接操作しない。
- **Store** は状態コンテナ。Intent を受けて状態を更新し、Event を発行。Store 間の直接参照禁止。
- **ECS System** は 3D 世界のロジック。SwiftUI に依存しない。Event 経由でのみ Store と通信。

#### Rule 2: シングルトン禁止 (No Singletons)

`static let shared = ...` パターン **禁止**。依存は注入すること。
例外: `LocalizationService` など、完全にステートレスな純粋サービスのみ。

#### Rule 3: Event Bus 経由の通信 (All Cross-Module via Events)

Store → Store の直接呼び出し禁止。必ず Event Bus 経由。
Event は `struct` で小さく、Codable 可能であること(デバッグ・リプレイ用)。

#### Rule 4: 修正用スクリプト禁止 (No Fixer Scripts)

前作には 15 個の `*Fixer.cs` がありました。バグは**根本原因を修正**すること。`*Fixer`, `*Patch`, `*Workaround` 系のファイル名禁止。

#### Rule 5: 死んだコードは即削除 (Dead Code Is Deleted, Not Commented Out)

使わないコードはコメントアウトせず削除。Git が履歴を持っている。

---

## 2. Project Structure

```
sendai_glab/
├── Sources/
│   ├── App/                   # Entry point
│   ├── Core/                  # Event bus, DI container, shared protocols
│   ├── Gameplay/              # Drilling, Geology, Samples, Vehicles, Story
│   ├── UI/                    # SwiftUI views (purely presentational)
│   ├── World/                 # Scene loading, PLATEAU integration
│   └── Platform/              # iOS/iPadOS adapters
├── Resources/                 # USDZ, JSON, Localization, photos
├── Tools/                     # Data pipelines (Python/shell)
├── Tests/
├── Docs/
│   ├── ArchitectureDecisions/ # ADRs
│   └── AssetPipeline.md
├── GDD.md                     # Main design document
└── README.md
```

---

## 3. Swift Coding Style

### 3.1 Naming

| 対象 | 規約 | 例 |
|------|------|------|
| Type | `PascalCase` | `DrillingSystem`, `SampleItem` |
| Property / method | `camelCase` | `currentDepth`, `performDrill()` |
| Protocol | 能力を表す | `Drillable`, `Localizable` |
| Store | suffix `Store` | `InventoryStore`, `QuestStore` |
| Event | 過去形の名詞/動詞 | `SampleCreated`, `DialogueAdvanced` |
| ECS System | suffix `System` | `DrillingSystem`, `VehicleControlSystem` |
| ECS Component | suffix `Component` | `GeologyLayerComponent` |

### 3.2 File Organization

- 1 ファイル 1 型を原則とする。関連する小さい型(enum / nested struct)は同居可。
- ファイル名 = 主型名 + `.swift`
- 500 行超えたら分割を検討。

### 3.3 Style Conventions

- インデント:4 スペース
- `var` より `let` 優先
- Force unwrap (`!`) 禁止。`guard` + `return` または `throw` を使う。
- `@Observable` マクロを状態コンテナに使用。`ObservableObject` は使わない(iOS 17+)。
- async/await 使用。Combine は必要なときのみ。

### 3.4 Comments

- コメントは「**なぜ**」を書く。「何をしているか」は名前で示す。
- Doc comment (`///`) は公開 API のみ。
- TODO/FIXME には issue 番号を付ける:`// TODO(#42): ...`

---

## 4. Architecture Decision Records (ADRs)

重要な設計判断は `Docs/ArchitectureDecisions/NNNN-title.md` に記録。

フォーマット:
```markdown
# NNNN. タイトル

- 日付: YYYY-MM-DD
- ステータス: Proposed / Accepted / Deprecated / Superseded by NNNN

## コンテキスト
なぜ判断が必要か。

## 決定
何を決めたか。

## 結果
トレードオフと影響。
```

既存 ADR:
- [0001 三層アーキテクチャの採用](Docs/ArchitectureDecisions/0001-layered-architecture.md)

---

## 5. Multilingual Requirement (MUST)

UI に表示される**すべての**テキストは **LocalizationKey** 経由。ハードコード禁止。

```swift
// ❌ 禁止
Text("地層を採取せよ")

// ✅ OK
Text(L10n.quest.firstSample.title)
```

三言語(日本語 / English / 简体中文)すべてでキーを定義してからコミット。

---

## 6. Testing

- 新規ロジックには Unit Test を追加。
- ECS System は Integration Test で 3D 状態を検証。
- Store の Intent → State → Event の流れは必ずテスト。
- カバレッジ目標:Core / Store 80%+、ECS 50%+、UI は視覚検証。

テストファイル:`Tests/UnitTests/` or `Tests/IntegrationTests/`、`*Tests.swift`。

---

## 7. Git Workflow

### 7.1 Branches

- `main` — 常にビルド可能・デプロイ可能
- `feature/*` — 機能追加
- `fix/*` — バグ修正
- `docs/*` — ドキュメントのみ
- `chore/*` — 依存更新、CI 調整など

### 7.2 Commits

フォーマット:
```
<scope>: <imperative summary>

<optional body: why>
```

Scope 例:`core`, `ui`, `geology`, `plateau`, `meshy`, `docs`, `ci`

例:
```
geology: raycast 向けの entry/exit 検出を実装

PLATEAU の建物の中空を透過させるため、最初の hit で打ち切らず
全 hit を収集してから Y 座標昇順でソート。
```

### 7.3 Pull Requests

- タイトル = コミット形式
- 本文:変更内容 / 動機 / テスト方法 / スクリーンショット(UI)
- CI 通過必須

---

## 8. Build / Run

```bash
# Open in Xcode
open SDGLab.xcodeproj

# Command-line build (後で追加)
xcodebuild -scheme SDGLab -destination 'platform=iOS Simulator,name=iPad Pro (12.9-inch)'

# Run tests
xcodebuild test -scheme SDGLab -destination 'platform=iOS Simulator,name=iPad Pro (12.9-inch)'
```

---

## 9. Tool Usage (Data Pipelines)

- `Tools/plateau-pipeline/` — PLATEAU CityGML → USDZ
- `Tools/meshy-pipeline/` — Meshy API バッチ生成
- `Tools/asset-validator/` — 資産整合性チェック

各ツールは独立した `README.md` と requirements。

---

## 10. AI Agent-Specific Instructions

AI エージェント(Claude, GPT, etc.) がこのプロジェクトで作業する際の追加ルール:

1. **GDD.md を最初に読む** — 全体設計の単一の情報源。
2. **§1 の原則を破らない** — 三層アーキテクチャ、シングルトン禁止、Event Bus。
3. **推測せず確認する** — Swift/RealityKit の API は訓練データから古い可能性がある。不明な場合は Apple 公式ドキュメントを WebFetch で参照。
4. **小さく変更する** — 1 PR 1 目的。リファクタと機能追加を混ぜない。
5. **テストを書いてからコミット** — Core/Store 変更は必ずテスト。
6. **多言語キーを忘れない** — ハードコード文字列は CI で弾く(将来)。
7. **ADR が必要な判断を発見したら提案** — 勝手に決めず、ADR ドラフトで提起。

---

## 11. Contact / Authorship

- Maintainer: **f.shera** (東北学院大学)
- License: MIT
- Upstream design doc: [GDD.md](GDD.md)
