# 0002. Xcode 工程構造:Project + ローカル SPM パッケージ × 4 + xcodegen

- 日付: 2026-04-21
- ステータス: **Accepted**
- 作成: f.shera + Claude

## コンテキスト

Phase 0 の立ち上げにあたり、Swift + RealityKit 再実装における **Xcode 工程の物理的組織** を決定する必要がある。

ADR-0001 は「View / Store / ECS の三層アーキテクチャ」を論理ルールとして定めたが、ルールを **宣言するだけ** では前作 Unity プロジェクトの二の舞になる。前作では:

- すべてが `MonoBehaviour` で型的に区別できず、層の境界は「規約」でしか守られなかった
- 結果:UI コード内で `FindFirstObjectByType<Controller>()` が乱立、Fixer スクリプトが蓄積
- 静的リントもなく、新規ファイルがどの層に属するか曖昧

新プロジェクトでは以下を満たしたい:

1. **コンパイラが三層境界を物理的に防衛する**(規約だけに頼らない)
2. **CLI で `swift test` が走る**(CI が速く、iOS simulator 起動不要)
3. **Xcode GUI の体験が良好**(Navigator に層が見える、補完が効く)
4. **Solo 開発。ボイラープレート過多は死**(Tuist のような別ツール体系は避けたい)
5. **`pbxproj` のマージ地獄を避ける**(生成物としてコード化)

## 選択肢

### A. 単一 Xcode Project、全ソースを App target 直下

- 最も単純。チュートリアル級。
- しかし **層間境界をコンパイラで強制できない**。`UI/` フォルダから `Sources/ECS/Entity.swift` を直接 import し放題。
- 前作 Unity と同じ構造で却下。

### B. Xcode Workspace + 複数 framework target

- Framework target を分ければモジュール境界はできる。
- しかし Workspace は Project + Workspace の二段階構造で、`xcodegen` / `xcodeproj` ツール対応が薄い。
- Framework target の pbxproj は手で管理するか独自ツールが必要。Solo には管理コスト高。

### C. Xcode Project + **ローカル Swift Package** × 4 ⭐(本採用)

- App target 1 つ + ローカル SPM パッケージ複数。パッケージ間の依存は `Package.swift` で宣言。
- **モジュール境界 = パッケージ境界** がコンパイラで保証される(循環 import はビルドエラー)。
- `swift test` が CLI で走る(SPM 標準)。
- Xcode は SPM をネイティブサポート。Navigator にパッケージが見える。
- pbxproj は `xcodegen` が `project.yml` から生成(後述)。

### D. Tuist による Project 管理

- Tuist は Swift DSL で Xcode project を生成する。高機能。
- しかし Tuist 自体が追加依存(Swift バージョンに追従する責務が発生)。
- Team 開発・大規模 Mono repo では強みが出るが、Solo + 単一 app では over-engineering。

### E. 純粋 SPM(`.xcodeproj` なし)

- Swift Package 単体で iOS app を配布することは **公式には不可能**(App Store 提出には `.xcodeproj` または `.xcworkspace` が要る)。
- サンプル / フレームワーク配布なら可。本プロジェクトは不可。

## 決定

**選択肢 C を採用**:Xcode Project 1 つ + ローカル Swift Package 4 つ + `xcodegen`。

### パッケージ構成

プロジェクトルート直下 `Packages/` に 4 つのパッケージを置く:

| パッケージ | 責務 | 使ってよい Framework |
|---|---|---|
| `SDGCore` | 基盤層。Event Bus、プロトコル、ドメインモデル、純粋ロジック。 | Foundation のみ |
| `SDGGameplay` | ゲームロジック層。Store、ECS Component / System。 | Foundation, RealityKit |
| `SDGUI` | プレゼンテーション層。SwiftUI View、RealityView。 | Foundation, SwiftUI, RealityKit |
| `SDGPlatform` | プラットフォーム適応層。Persistence、Audio、Input、Location。 | Foundation, iOS 各種 |

### 依存グラフ

```
                 ┌────────────┐
                 │   SDGUI    │
                 └─────┬──────┘
                       │
                       ▼
                 ┌────────────┐          ┌──────────────┐
                 │ SDGGameplay│          │ SDGPlatform  │
                 └─────┬──────┘          └──────┬───────┘
                       │                        │
                       └────────┬───────────────┘
                                ▼
                         ┌────────────┐
                         │  SDGCore   │
                         └────────────┘

App target (SendaiGLab) ─▶ SDGCore / SDGGameplay / SDGUI / SDGPlatform
```

非対称な点:

- `SDGUI` → `SDGGameplay` → `SDGCore` の一方向
- `SDGPlatform` は `SDGGameplay` と **平行**(Platform は ECS を知らない、Gameplay は I/O を知らない)
- 逆方向 import(`SDGCore` → `SDGUI` など)は **コンパイラが循環参照として拒否**

これが ADR-0001 の「View → Store → ECS は一方向」を物理的に担保する肝である。

### ツール:xcodegen + project.yml

`.xcodeproj` は **生成物**。手書きしない。

- **真実のソース**:`project.yml`(リポジトリ直下、コミット対象)
- **生成コマンド**:`xcodegen generate`(`.xcodeproj` を再生成)
- **インストール**:`brew install xcodegen`(macOS のみ)

この方針の効果:

1. pbxproj のマージコンフリクトが事実上消える(生成し直せばよい)
2. ビルド設定の差分レビューが YAML の diff で済む
3. 新規ファイル追加で pbxproj を汚さない(xcodegen が path-based に拾う)

残るリスクは「`xcodegen generate` を忘れて出荷」だが、CI の `ci_post_clone.sh` で明示的に `xcodegen generate` を呼ぶため、クリーンビルドでは必ず最新 pbxproj が使われる。

#### pbxproj のマージ戦略

それでも人間の手元では `.xcodeproj/project.pbxproj` がコミット対象として存在する(Xcode を普通に開く体験のため)。このためのフェイルセーフ:

```
# .gitattributes
*.pbxproj merge=union
```

merge=union により同一行を 2 つ取り込む愚直なマージが効く。壊れたら `xcodegen generate` で再生成する。

### Swift tools-version / language mode の決定

各パッケージの `Package.swift` は以下の形:

```swift
// swift-tools-version: 6.0
let package = Package(
    name: "SDGCore",
    platforms: [.iOS(.v18), .macOS(.v14)],
    ...
    targets: [
        .target(
            name: "SDGCore",
            swiftSettings: [
                .enableUpcomingFeature("StrictConcurrency")
            ]
        ),
        ...
    ],
    swiftLanguageModes: [.v5]
)
```

#### 理由:tools-version 6.0 but language mode 5

- `.iOS(.v18)` の指定には **PackageDescription 6.0 以上** が必要。したがって `swift-tools-version: 6.0` は不可避。
- しかし Swift 6 言語モードは `Sendable` 周りの破壊的変更が多く、サードパーティ依存(将来追加するとして)の追従が読めない。
- 現実解:**tools-version は 6.0**(iOS 18 のため)、**language mode は .v5**(安定)、**Strict Concurrency は `enableUpcomingFeature`** で opt-in。
- 将来 Swift 6 言語モードに切り替えたとき、Strict Concurrency 挙動は変わらない(既にオンだから)。移行コストが最小化される。

#### 理由:iOS v18 + macOS v14

- `iOS(.v18)` は GDD §2.1 の最小サポート。
- `macOS(.v14)` は `SDGCore` のみに付ける。理由:**CLI から `swift test` を走らせるため**。
  - iOS-only package は macOS では build できない。
  - macOS 対応すれば `cd Packages/SDGCore && swift test` が即座に通る。
  - これで GitHub Actions は iOS simulator を起動せずに unit test を回せる(Phase 2 以降の CI 速度に効く)。
- `SDGGameplay` / `SDGUI` は RealityKit を使うため macOS には置けない(RealityKit は iOS/visionOS 中心)。iOS simulator でテストする。

### Bundle ID

- 本番 bundle ID:`jp.tohoku-gakuin.fshera.sendai-glab`
- Prefix:`jp.tohoku-gakuin.fshera`(`project.yml` の `bundleIdPrefix`)
- GDD の「開発者 f.shera / 東北学院大学」に合わせる。

### Tuist を採らない理由

- 余分な依存(Tuist 自体のバージョン管理、Swift 追従)
- DSL 学習コスト(結局 YAML より抽象度が高いだけ)
- Solo + 1 app では `project.yml` で十分
- 将来チームが増えたら再検討

### Workspace を採らない理由

- ローカル SPM パッケージは **Project に直接 add** できる(Xcode 11+)。Workspace が不要。
- Workspace を増やすと CLI で `-workspace SendaiGLab.xcworkspace -scheme ...` 指定が必要になり、コマンドが冗長。
- xcodegen の `packages:` セクションは Project 単位で設計されている。

## 結果

### メリット

- **三層境界がコンパイラに物理防衛される**
  - `SDGCore` から SwiftUI の型を参照しようとすると未定義シンボル
  - `SDGUI` から `SDGCore` 内部型への循環 import はビルドエラー
  - 新規ファイルを置く場所で自然に層が決まる(パッケージ = ドメイン = 層)
- **CLI で `swift test` が走る**
  - SDGCore は macOS 対応しているため、Xcode simulator 不要でテスト可能
  - CI の lint ジョブは `bash ci_scripts/arch_lint.sh` + `swift test -p Packages/SDGCore` で完結
- **Xcode GUI 体験も良好**
  - Navigator にパッケージが独立した Group で見える
  - `⌘ + click` で型ジャンプが Package 境界を超えて動く
  - Indexing は SPM 対応済み
- **pbxproj のマージ衝突が実質消失**
  - `project.yml` が真実のソース
  - 生成物は `merge=union` + `xcodegen generate` の再生成で復帰可能

### デメリット・トレードオフ

- **Framework-level import は禁止できない**
  - `import SwiftUI` や `import RealityKit` は **システム framework** なので、どのパッケージからでも書けてしまう
  - 例えば `SDGCore/Foo.swift` に `import SwiftUI` と書いても **コンパイラは通す**
  - ここは **`ci_scripts/arch_lint.sh`** の grep ルールで弾く(CI で fail)
  - 本 ADR はこの制約を受け入れる(コンパイラで 100% 防衛できない点は lint で補完)

- **xcodegen の追加依存**
  - `brew install xcodegen` が必要。CI 環境で `xcodegen` が使える必要がある
  - CI は `ci_scripts/ci_post_clone.sh` で `brew install xcodegen` + `xcodegen generate` を行う
  - ローカル開発者も 1 回だけ `brew install xcodegen` が必要(README で明示)

- **`.xcodeproj/project.pbxproj` はコミット対象として残る**
  - GitHub 上でプロジェクトを開いたとき Xcode でそのまま起動できる体験のため削除しない
  - 代わりに `.gitattributes` の `merge=union` で衝突耐性を付ける
  - 衝突したら `xcodegen generate` で再生成が第一選択肢

- **SDGCore 以外は macOS 対応しない**
  - `SDGGameplay` / `SDGUI` は iOS simulator でしかテストできない
  - 許容:RealityKit 依存のため避けられない。純粋ロジックテストは SDGCore に寄せる設計にする
  - SDGPlatform も今後 `AVFoundation` / `CoreLocation` を使うため macOS には持ち込まない

## 準拠確認

- CI (`.github/workflows/ci.yml` 想定)
  1. `ci_post_clone.sh` が `xcodegen generate` を実行
  2. `arch_lint.sh` が禁止 import / singleton / banned filename を grep でチェック
  3. `xcodebuild build -scheme SendaiGLab -destination 'platform=iOS Simulator,...'`
  4. `swift test` を SDGCore のみ macOS runner で走らせる(速い)
- Phase 1 以降、新規パッケージ追加時は本 ADR の依存ルール遵守を手動レビュー。

## 落地ファイル

- `/Users/user/sendai_glab/project.yml` — xcodegen の真実ソース
- `/Users/user/sendai_glab/SendaiGLab.xcodeproj/project.pbxproj` — 生成物(コミット対象だが `merge=union`)
- `/Users/user/sendai_glab/Packages/SDGCore/Package.swift`
- `/Users/user/sendai_glab/Packages/SDGGameplay/Package.swift`
- `/Users/user/sendai_glab/Packages/SDGUI/Package.swift`
- `/Users/user/sendai_glab/Packages/SDGPlatform/Package.swift`
- `/Users/user/sendai_glab/ci_scripts/arch_lint.sh` — framework import を補完防衛
- `/Users/user/sendai_glab/.gitattributes` — `*.pbxproj merge=union`

## 参考

- [XcodeGen](https://github.com/yonaskolb/XcodeGen)
- [Swift Package Manager Documentation](https://www.swift.org/documentation/package-manager/)
- ADR-0001 三層アーキテクチャの採用(本 ADR はその物理実装)
- [Swift tools version 6.0](https://github.com/swiftlang/swift-package-manager/blob/main/Documentation/PackageDescription.md)
