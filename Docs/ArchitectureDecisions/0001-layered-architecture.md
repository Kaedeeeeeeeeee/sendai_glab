# 0001. 三層アーキテクチャの採用 (View / Store / ECS)

- 日付: 2026-04-21
- ステータス: **Accepted**
- 作成: f.shera + Claude

## コンテキスト

前作 Unity プロジェクト `GeoModelTest`(~92K 行)は、以下の構造的問題により保守困難に陥った:

1. **ロジックの散在**:ほぼ全コードが `MonoBehaviour` のサブクラス。UI 描画・入力処理・ゲームロジック・永続化がしばしば同一クラスに混在。
2. **シングルトン過多**:`GameInitializer`, `ToolManager`, `GameSceneManager`, `LocalizationManager`, `StoryDirector` などが互いに直接参照。変更の影響範囲が追えない。
3. **Event 欠如**:薄い `GameEventBus`(1 イベントのみ)が存在したが、実際の結合は `FindFirstObjectByType<T>()` と `.Instance` で行われていた。
4. **屎山の副作用**:Fixer スクリプト 15 個、Debug スクリプト 20+ 個、Test スクリプト 28 個が UI 層に蓄積(いずれも UI 設計の欠陥を fix する workaround だった)。

Swift + RealityKit での再実装にあたり、同じ轍を踏まないためのアーキテクチャ選定が必要。

## 選択肢

### A. MVC/MVVM + SwiftUI (伝統型)

- ViewModel が Store + Controller を兼ねる
- 直感的だが、3D ゲームの状態(Entity, Component)をどこに置くか曖昧

### B. TCA (The Composable Architecture)

- Reducer / Action / State による完全な関数型
- 学習コスト高、RealityKit ECS との統合パターンが未確立
- solo 開発者には overkill の可能性

### C. 三層アーキテクチャ: View / Store / ECS (本提案) ⭐

- SwiftUI View はプレゼンテーションのみ
- `@Observable` Store が状態とビジネスロジックを保持
- RealityKit の ECS (Entity / Component / System) が 3D 世界を所有
- 層間通信は一方向 + Event Bus

### D. 単一 GameManager (前作と同じ)

- 却下。屎山の原因そのもの。

## 決定

**選択肢 C を採用**。

### 層の責務

#### View(SwiftUI)

- `@Observable` な Store を `@Environment` で受け取り、状態を表示
- ユーザ操作を Store の `intent:` メソッドに委譲
- **禁止**: Entity の直接操作、ビジネスロジック、永続化呼び出し

#### Store (`@Observable`)

- ゲームの状態を保持(例:`InventoryStore.samples: [SampleItem]`)
- `intent(_:)` メソッドで Intent を受け取る(`.drill(at:)`, `.selectTool(id:)`)
- 状態更新 + `EventBus.publish(...)` で他レイヤーに通知
- **禁止**: 他 Store への直接参照、View の呼び出し

#### ECS(RealityKit)

- `System` がゲーム世界の物理的ロジックを担う(衝突、物理、レイキャスト、VFX)
- `Component` は純粋なデータ
- `EventBus` を経由して Store にイベントを通知(例:`SampleCreated`)
- **禁止**: SwiftUI への依存、Store の直接呼び出し

### Event Bus

```swift
protocol GameEvent: Sendable {}

actor EventBus {
    func publish<E: GameEvent>(_ event: E)
    func subscribe<E: GameEvent>(
        _ type: E.Type,
        handler: @escaping @Sendable (E) async -> Void
    ) -> SubscriptionToken
}
```

- AsyncStream ベース
- Event は Codable を推奨(デバッグ時のダンプ用)
- 購読解除はトークン経由

### Dependency Injection

- Store は App エントリで生成、`.environment(\.xxxStore, ...)` で View 階層に注入
- ECS System は `RealityKitScene` 初期化時に登録
- Singleton (`static let shared`) は**禁止**(例外:完全 stateless なサービス、e.g. `LocalizationService`)

## 結果

### メリット

- 層の責務が明確。新規参加者(=将来の自分)が迷わない
- Store 単位でユニットテスト可能(View / ECS をモック不要)
- UI 置換容易(iPad ↔ iPhone、将来 visionOS)
- Event ベースのため、クロスレイヤー変更の影響範囲が限定的
- Fixer スクリプトの温床だった「View と Logic の混線」を根絶

### デメリット・トレードオフ

- 初期のボイラープレート(Intent / Event の定義)がやや多い
- 「単純な UI 更新」でも Intent → Store 往復が必要
  → **緩和**: 純粋な視覚効果(hover, animation)は View 内の `@State` で OK
- ECS ↔ Store の Event マッピングに慣れが必要
  → **緩和**: Phase 1 POC で 2-3 例確立し、テンプレート化

### 実装の入口

- `Sources/Core/EventBus.swift`
- `Sources/Core/Store.swift`(プロトコル)
- `Sources/Core/GameEvent.swift`
- `Sources/Gameplay/**/XxxStore.swift`(各ドメイン Store)
- `Sources/Gameplay/**/XxxSystem.swift`(ECS System)

## 準拠確認

AGENTS.md §1 にルール化。CI で検証可能にする案:

- Store → Store 直接参照を禁じる lint ルール
- View → Entity / Component 直接参照を禁じる lint ルール
- Phase 1 完了時に手動レビュー、Phase 2 から自動化

## 参考

- [The Composable Architecture](https://github.com/pointfreeco/swift-composable-architecture)(選択肢 B、参考のみ)
- [RealityKit ECS ガイド](https://developer.apple.com/documentation/realitykit/)
- 前作 Unity プロジェクト `Assets/Scripts/Core/GameEventBus.cs`(教訓として)
