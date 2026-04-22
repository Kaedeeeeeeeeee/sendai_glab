# Resources/Audio

SDG-Lab で使用する音声アセット。

## 構成

```
Audio/
└── SFX/            Placeholder SFX (Phase 2 起步)
    ├── ui/         UI button / tab / toggle / open / close
    ├── drill/      Drilling hammer impacts
    ├── footstep/   Player footsteps (grass / concrete / wood)
    └── feedback/   Success / Failure / Notify / Chime
```

BGM 専用ディレクトリは Phase 3(Suno / Udio)で追加予定。

---

## SFX マニフェスト

すべて [Kenney (kenney.nl)](https://kenney.nl/) の **CC0** パックから抜粋。
Phase 2 の Placeholder であり、Phase 3 以降に差し替え・追加される可能性あり。

### `ui/` — インターフェース

| ファイル | 用途 | 元素材 | 元パック |
|---|---|---|---|
| UI_Tap.ogg         | 標準ボタンタップ                   | click1.ogg         | UI Audio |
| UI_TapAlt.ogg      | バリエーションタップ(連打抑制用)   | click3.ogg         | UI Audio |
| UI_TabSelect.ogg   | タブ切替・リスト選択               | select_001.ogg     | Interface Sounds |
| UI_Hover.ogg       | ホバー/フォーカス移動              | rollover1.ogg      | UI Audio |
| UI_Toggle.ogg      | トグル・チェックボックス           | switch_001.ogg     | Interface Sounds |
| UI_Close.ogg       | モーダル/パネルを閉じる           | close_001.ogg      | Interface Sounds |
| UI_Open.ogg        | モーダル/パネルを開く             | open_001.ogg       | Interface Sounds |

### `drill/` — 掘削

| ファイル | 用途 | 元素材 | 元パック |
|---|---|---|---|
| Drill_Impact_01.ogg | ドリル打撃 (variant 1) | impactMining_000.ogg    | Impact Sounds |
| Drill_Impact_02.ogg | ドリル打撃 (variant 2) | impactMining_001.ogg    | Impact Sounds |
| Drill_Impact_03.ogg | ドリル打撃 (variant 3) | impactMining_002.ogg    | Impact Sounds |
| Drill_Impact_04.ogg | ドリル打撃 (variant 4) | impactMining_003.ogg    | Impact Sounds |
| Drill_Metal_Heavy.ogg | ドリル設置/撤去の金属音 | impactMetal_heavy_000.ogg | Impact Sounds |

ランダム再生は 4 variant の中からサンプリングすることでループ感を抑える想定。

### `footstep/` — 足音

| ファイル | 用途 | 元素材 | 元パック |
|---|---|---|---|
| Footstep_Grass_01.ogg    | 草地 (variant 1) | footstep_grass_000.ogg    | Impact Sounds |
| Footstep_Grass_02.ogg    | 草地 (variant 2) | footstep_grass_001.ogg    | Impact Sounds |
| Footstep_Concrete_01.ogg | 舗装路 (variant 1) | footstep_concrete_000.ogg | Impact Sounds |
| Footstep_Concrete_02.ogg | 舗装路 (variant 2) | footstep_concrete_001.ogg | Impact Sounds |
| Footstep_Wood_01.ogg     | 木板 (variant 1) | footstep_wood_000.ogg     | Impact Sounds |
| Footstep_Wood_02.ogg     | 木板 (variant 2) | footstep_wood_001.ogg     | Impact Sounds |

素材選定の理由:Phase 2 の仙台 Plateau 地表は草(公園)・舗装(道路)・木(桟橋・縁側)が中心。
雪・カーペット等は除外(本ゲームのロケーションに合わない)。

### `feedback/` — 成否フィードバック

| ファイル | 用途 | 元素材 | 元パック |
|---|---|---|---|
| Feedback_Success.ogg | Quest 達成・標本取得成功 | confirmation_001.ogg | Interface Sounds |
| Feedback_Failure.ogg | 失敗・エラー             | error_003.ogg        | Interface Sounds |
| Feedback_Notify.ogg  | 新着通知・ヒント出現     | question_001.ogg     | Interface Sounds |
| Feedback_Chime.ogg   | 章切り替え・重要イベント | bong_001.ogg         | Interface Sounds |

---

## フォーマット

- 全 `.ogg`(Vorbis)
- iOS は `AVAudioPlayer` / RealityKit の `AudioFileResource` で直接再生可能
- 合計 **22 ファイル / ~220 KB**(Phase 2 起步のベースライン)

## ライセンス

全ファイルは **Creative Commons Zero (CC0)**。
Kenney からの attribution は「強制ではないが礼儀として保留」:[Docs/Attribution.md](../../Docs/Attribution.md) を参照。

## 元パック

| パック | URL | 収録 |
|---|---|---|
| Interface Sounds | https://kenney.nl/assets/interface-sounds | UI 系 + feedback 系 |
| Impact Sounds    | https://kenney.nl/assets/impact-sounds    | drill 系 + footstep 系 |
| UI Audio         | https://kenney.nl/assets/ui-audio         | 基本 click / rollover |

`RPG Audio` と `Footsteps`(独立パック)も候補だったが、
`Impact Sounds` に必要な footstep/mining が揃っており採用せず。

## 追加・差し替えルール

1. 新しい SFX を追加するとき、本 README の該当カテゴリ表に 1 行追加
2. 元パックが CC0 以外ならば `Docs/Attribution.md` にライセンスを明記
3. Phase 3 で Suno/Udio の BGM を入れるときは `Audio/BGM/` を新設

## 関連

- GDD.md §5.5「音響設計」
- Docs/Attribution.md 音声セクション
