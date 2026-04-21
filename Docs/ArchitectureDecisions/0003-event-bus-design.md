# 0003. Event Bus 設計:actor + TaskGroup fan-out 分発

- 日付: 2026-04-21
- ステータス: **Accepted**
- 作成: f.shera + Claude

## コンテキスト

ADR-0001 は「層間通信は Event Bus 経由、Store → Store 直接参照禁止」を定めた。ここでは **その Event Bus を具体的にどう実装するか** を決める。

要件は以下のとおり:

1. **Swift Strict Concurrency で無警告に動く**(`SDGCore` は Strict Concurrency オン)
2. **多対多の pub/sub**(同じ event type に複数の subscriber)
3. **型安全**(subscriber は自分が読む event type を指定、downcast は実装が隠蔽)
4. **Actor 境界を越えて安全**(`MainActor` で動く View、ECS System、Store いずれからも使える)
5. **主スレッドをブロックしない**(RealityKit は MainActor に乗っている。event 配送で固まると描画が止まる)
6. **Sendable 問題を抱え込まない**(Combine を Swift 6 で使う苦しみを回避)
7. **テスト容易**(Phase 0 で 95%+ カバレッジを狙える)
8. **拡張に耐える**(将来 event replay / priority subscription を乗せる余地)

ADR-0001 の擬似コードには「AsyncStream ベース」と書いたが、これは initial sketch であり、実装段階で再検討する前提だった。本 ADR がその決着。

## 選択肢

### A. Combine `PassthroughSubject`

- 成熟しており iOS では標準的。
- しかし:
  - Swift 6 Strict Concurrency 下での `Sendable` 物語が不透明(`ObservableObject` 時代の残滓を引きずる)
  - Combine の operator を actor から呼ぶと、どの scheduler で動くかが直感に反することがある
  - `@MainActor`-isolated な subject を background actor から書こうとすると境界越えがしんどい
- 却下。

### B. `AsyncStream<E>` (ADR-0001 初稿で言及)

- 言語標準。Sendable-safe。
- しかし **AsyncStream は「1 producer, 1 consumer」の semantics** が自然形。
- 多 subscriber にするには、publisher 側で subscriber 数だけ stream を作って全部に書き込む multiplexer を自作する必要がある。
- その multiplexer を書くなら、結局本採用の選択肢 C と大差ない複雑度になる。
- 「AsyncStream を API の顔にする」余地は残しつつ、**内部実装は別** の判断をした。

### C. 自作 `actor EventBus` + `TaskGroup` fan-out ⭐(本採用)

- `actor` で state(handler 辞書)を完全に直列化。Data race は言語が保証。
- `publish` は `TaskGroup` を回して全 handler を並列に await。
- Handler は `@Sendable (E) async -> Void` なので、どの isolation からでも安全に呼べる。
- 最小限の自作コード(現行実装 ~125 行)。

### D. `NotificationCenter`

- iOS 標準。しかし
  - **型安全でない**(`userInfo: [AnyHashable: Any]` に詰めてキャスト戻し)
  - actor 境界・Sendable の対応が弱い
  - デバッグ時に「誰が subscribe しているか」が不透明
- 却下。ADR-0001 の「Event は Codable、デバッグ可能に」方針と合わない。

## 決定

**選択肢 C を採用**:`public actor EventBus` を `SDGCore/EventBus/` に実装する。

### Event プロトコル

```swift
public protocol GameEvent: Sendable, Codable {}
```

- `Sendable`:actor を越えるので必須
- `Codable`:ADR-0001 で明示された「event stream をディスクに dump してデバッグ再生」のため
- `struct` 実装を推奨(ドキュメントコメントで指示)。参照型を詰めると Sendable 保証が崩れやすいため

### 内部ストレージ

```swift
private struct HandlerBox: Sendable {
    let invoke: @Sendable (any GameEvent) async -> Void
}

private var handlers: [ObjectIdentifier: [UUID: HandlerBox]] = [:]
```

- **外側キー** `ObjectIdentifier`:event 型のメタタイプ identity。`ObjectIdentifier(E.self)` で取る
- **内側キー** `UUID`:購読 ID。cancel で同定に使う
- **HandlerBox**:型消去されたラッパー。`@Sendable` closure のみ保持するので `Sendable` 構造体

### `subscribe`

```swift
public func subscribe<E: GameEvent>(
    _ type: E.Type,
    handler: @escaping @Sendable (E) async -> Void
) -> SubscriptionToken {
    let typeKey = ObjectIdentifier(type)
    let id = UUID()
    let box = HandlerBox { event in
        if let typed = event as? E {
            await handler(typed)
        }
    }
    handlers[typeKey, default: [:]][id] = box
    return SubscriptionToken(id: id)
}
```

- Box 内部で `event as? E` は **理論上 100% 成功する**(`typeKey` が `E.self` と一致する bucket にしか入れていないから)
- 万一ミスルートした場合は `as?` で `nil` → 呼ばない、という fail-open な安全側
- 戻り値 `SubscriptionToken` は bus 内部のみが生成可能な opaque ハンドル(initializer は `internal`)

### `publish`

```swift
public func publish<E: GameEvent>(_ event: E) async {
    let typeKey = ObjectIdentifier(E.self)
    guard let bucket = handlers[typeKey], !bucket.isEmpty else { return }
    let snapshot = Array(bucket.values)

    await withTaskGroup(of: Void.self) { group in
        for box in snapshot {
            group.addTask {
                await box.invoke(event)
            }
        }
    }
}
```

設計ポイント:

1. **型で bucket 選別 → O(1)**:event 型ごとに辞書。全 subscriber を舐めるわけではない
2. **snapshot して配送**:配送中に別のタスクが `subscribe` / `cancel` しても現 dispatch は影響を受けない(actor の再入に対する安全)
3. **TaskGroup で並列 fan-out**:subscriber が多くても wall-clock は最遅の handler で律速(直列だと N 倍)
4. **await all**:`publish` 呼び出し側は全 handler 完了を待ってから次へ。テストしやすく、reasoning しやすい
5. **No-subscriber ショートカット**:早期 return で actor hop だけで終わる

### `cancel`

```swift
public func cancel(_ token: SubscriptionToken) {
    for key in handlers.keys {
        if handlers[key]?.removeValue(forKey: token.id) != nil {
            if handlers[key]?.isEmpty == true {
                handlers.removeValue(forKey: key)
            }
            return
        }
    }
}
```

- Token は event 型を知らない(opaque UUID のみ)ため全 bucket を線形スキャン
- N = 現在生きている event 型数。ゲーム全体でも数十オーダー見込み。十分速い
- 空になった bucket を即時削除してメモリを締める
- **Idempotent**:存在しない token を渡しても no-op(テスト済み)

### Handler の isolation

- Handler は **actor 外部** で実行される(`@Sendable (E) async -> Void`)
- UI 更新が必要なら handler 内で `await MainActor.run { ... }` を書く
- ECS System が handler 内から Entity を直接いじることは **禁止**(data race 懸念)
  - 正しいパターン:handler 内で `Component` に「次フレームでやる」フラグを立て、System の update サイクルで消費
  - 理由:RealityKit の Entity は `@MainActor` 束縛。ECS System は自前の更新タイミングで走る

### AsyncStream との関係

ADR-0001 原案は "AsyncStream ベース" と書いた。その API 体験を殺さないため、**将来の拡張として** 以下を設けうる:

```swift
// 将来の拡張案(現時点では未実装)
extension EventBus {
    public func observe<E: GameEvent>(_ type: E.Type) -> AsyncStream<E> {
        AsyncStream { continuation in
            let token = subscribe(E.self) { event in
                continuation.yield(event)
            }
            continuation.onTermination = { _ in
                Task { await self.cancel(token) }
            }
        }
    }
}
```

これで Store 側は `for await event in bus.observe(SampleCreated.self) { ... }` の書き味を選べる。

内部実装(actor + TaskGroup)は変わらず、`observe` は subscribe の薄いラッパーにすぎない。現時点では YAGNI のため未実装だが、必要になった瞬間 10 行で足せる設計になっている。

## 結果

### メリット

- **Strict Concurrency で 0 warning**
  - `@Sendable` と `actor` のみで組んだため、`Sendable` 逸脱の余地がない
  - SDGCore は `.enableUpcomingFeature("StrictConcurrency")` オンでビルド可能
- **テスト容易**
  - `EventBusTests.swift` で **11 テスト、region coverage ≈ 95.65%** を達成
  - 単一配送、多 subscriber、cancel、型隔離、1000 publish × 10 subscriber 並列圧力、empty publish、...
- **ゼロ singleton**
  - `EventBus` インスタンスは App entry で 1 つ作って注入(AGENTS.md §1.2)
  - テストごとに `EventBus()` で fresh 作れる(`init()` は安い)
- **型安全 + 動的照合**
  - Subscriber は compile time で event 型を指定
  - Bus 内部の downcast は **自分で配線した** bucket と照合するので実質常に成功
- **Handler 例外隔離**
  - TaskGroup 内で各 handler は独立タスク
  - 1 つが throw しても他 subscriber には波及しない(`Void.self` group、return 型が Void)

### デメリット・トレードオフ

- **`publish` は全 handler 完了まで await する fan-out fan-in**
  - つまり呼び出し側は全 subscriber が終わるまでブロック(await)する
  - メリット:reasoning が単純、テストが順序的に書ける、主スレッドは `await` で yield 可能
  - デメリット:もし 1 つの handler が重い計算をすると `publish` 全体が遅くなる
  - **緩和策**:重い処理は handler 内で `Task.detached` に逃がせばよい(現時点は需要なし)
  - 将来 fire-and-forget 版(`publishNoWait`)を足す選択肢は残っている

- **`cancel` は O(N)(N = event 型数)**
  - Token が event 型を持たないため線形スキャン必須
  - N は現実的に 10〜30 程度(Sample、Quest、Dialogue、Disaster、... 等)
  - 許容。二次元インデックスを足せば O(1) にできるが、今の規模では複雑化のデメリットが勝つ

- **Event history / replay は別途**
  - 現行 bus は「状態を持たない配送器」。過去 event の再生はしない
  - ADR-0001 で言及された「デバッグ dump」は handler 側で書き出すか、将来 ring buffer 系の decorator を足す
  - 必要になった時点で追加 ADR

- **Handler の isolation は呼び出し側責任**
  - UI 更新は handler 内で `await MainActor.run` を明示
  - ECS 変更は Component flag 経由
  - ルールを守らないと race が起きる。AGENTS.md に記載予定(Phase 1 に入るタイミングで)

- **Framework 非依存だが `ObjectIdentifier` 依存**
  - `ObjectIdentifier(E.self)` は Swift の metatype identity に依存している
  - これは Foundation より下の言語機能で安定
  - 逆に言うと、generic event 型(`Wrapped<T>`)の区別挙動は慎重にテストする必要がある
  - 現時点のテストはこの辺までは押さえていないが、Phase 1 で generic event 需要が出た時に確認する

## 準拠確認

- テスト:`Packages/SDGCore/Tests/SDGCoreTests/EventBusTests.swift`
  - 11 ケース、すべて async
  - 1000 publish × 10 subscriber の圧力テストを含む(TSan 通過)
- 静的:`ci_scripts/arch_lint.sh` が SDGCore への SwiftUI / RealityKit import を禁止
- 参照:AGENTS.md §1.1 Rule 3 "Event Bus 経由の通信"

## 落地ファイル

- `/Users/user/sendai_glab/Packages/SDGCore/Sources/SDGCore/EventBus/GameEvent.swift`
- `/Users/user/sendai_glab/Packages/SDGCore/Sources/SDGCore/EventBus/EventBus.swift`
- `/Users/user/sendai_glab/Packages/SDGCore/Sources/SDGCore/EventBus/SubscriptionToken.swift`
- `/Users/user/sendai_glab/Packages/SDGCore/Tests/SDGCoreTests/EventBusTests.swift`

## 未決(Future Work)

Phase 1 以降で検討する拡張候補:

- **AsyncStream アダプタ `observe<E>() -> AsyncStream<E>`**
  - `for await event in ...` 書き味の提供。ラッパー 10 行。
- **Event history / replay**
  - Debug build 限定の ring buffer(最新 N 件を保持、JSON dump 可能)
  - デモ録画・バグ再現用
- **優先度付き subscriber**
  - 現在は配送順序不定。`subscribe(... priority:)` で順序保証の余地
  - 使用ケース:UI サウンド > 分析ログ の順に処理したい、等
- **Cross-process bus**
  - 将来 macOS companion や watchOS companion が出たとき
  - 現時点では YAGNI
- **`publishNoWait`(fire-and-forget)**
  - 呼び出し側が完了を気にしない場合の非同期発火
  - 現在の `publish` に `Task { await bus.publish(e) }` を書けば同等だが、API として整える余地

## 参考

- ADR-0001 三層アーキテクチャの採用(本 ADR はその「Event Bus」を具体化)
- [Swift `actor`](https://developer.apple.com/documentation/swift/actor)
- [`withTaskGroup`](https://developer.apple.com/documentation/swift/withtaskgroup(of:returning:body:))
- 前作 Unity `Assets/Scripts/Core/GameEventBus.cs`(薄すぎて死んだ参考例)
