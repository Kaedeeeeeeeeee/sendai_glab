# Tools/asset-validator

`Resources/` 配下の資産に対する構造化チェックを CI で毎回回すための Python CLI。

## 目的

- 命名規約の破れを早期検出する(例:`aobayama.usdz` は FAIL、`Environment_Aobayama_01.usdz` は PASS)
- 肥大化した `.usdz` / `.png` / `.heic` を閾値ベースで警告する
- Git LFS で管理すべきファイルが本当に LFS ポインタに置き換わっているか確認する
- `Localizable.xcstrings` の三言語(ja / en / zh-Hans)カバレッジを追跡する
- `Resources/**/*.json` の JSON / UTF-8 健全性を検査する

## 依存

**ゼロ(Python 3.11+ の stdlib のみ)**。`requirements.txt` は CI の発見しやすさのため置いてあるだけ。

追加で外部コマンドを使う箇所:

| コマンド | 用途 | 無くても | 
|---|---|---|
| `git` | `git check-attr filter` で LFS フィルタを検出 | 動作する(pointer 頭バイト検査にフォールバック) |
| `git-lfs` | 存在確認のみ | 動作する(WARN を 1 個出す) |

## チェック規則

### 1. 命名規約(`naming.*`)

| ディレクトリ | パターン | 違反時 |
|---|---|---|
| `Resources/Environment/*.usdz` | `Environment_{Area}_{Tile}.usdz` or `Terrain_{Area}_{TileId}.usdz` | FAIL |
| `Resources/Characters/*.usdz` | `Character_{Role}_{Variant}.usdz` | FAIL |
| `Resources/Props/*.usdz` | `Prop_{Name}.usdz` | FAIL |
| `Resources/UI/**/*.png` | `UI_{Category}_{Name}.png` | FAIL |

ディレクトリが未作成の場合は INFO のみ(Phase 0 では通るようにするため)。

### 2. ファイルサイズ(`size.*`)

| 種類 | WARN 閾値 | FAIL 閾値 |
|---|---|---|
| `.usdz` | 50 MB | 100 MB |
| `.png` | 4 MB | (なし) |
| `.heic` | 2 MB | (なし) |

各閾値は CLI で上書き可能(下記「CLI」参照)。

### 3. Git LFS 健全性(`lfs.tracked`)

対象: `.usdz` / `.heic` / `.jpg` / `.jpeg`、および `1 MB` 超の `.png`。

判定ロジック(いずれか満たせば PASS):

1. `git check-attr filter -- <path>` の出力が `lfs`
2. ファイル先頭が `version https://git-lfs.github.com/spec/v1` で始まる(= LFS pointer 本体)

どちらも満たさなければ **FAIL**。git work tree 外で走らせた場合は検証不能として **WARN** にデグレード。

git-lfs バイナリが PATH に無い場合も **WARN** を 1 行出す(導入案内付き)。

### 4. xcstrings 健全性(`xcstrings.*`)

`Resources/Localization/Localizable.xcstrings` が存在する場合のみ走る。

- JSON としてパースできなければ **FAIL**
- JSON レベルで重複キーがあれば **FAIL**(`object_pairs_hook` で検出)
- `ja` / `en` / `zh-Hans` の各言語について、`state == "translated"` かつ `value` が非空のキー割合を集計
- カバレッジが `--xcstrings-coverage-min`(デフォルト 0.95)未満なら **WARN**、欠落キーの先頭 10 件を表示

### 5. JSON データファイル(`json.*`)

`Resources/Geology/`、`Resources/Story/`、`Resources/Data/` 配下の `*.json` に対して:

- UTF-8 でデコードできなければ **WARN**
- JSON 構文違反なら **FAIL**

## CLI

```bash
python3 validate.py                              # デフォルトで ./Resources をスキャン
python3 validate.py Resources/                   # 明示
python3 validate.py /abs/path/to/Resources       # 絶対パスでも可

# 挙動切替
python3 validate.py --strict                     # WARN も FAIL と同じ終了コードに
python3 validate.py --report                     # デフォルト出力に加えて Markdown レポートも追記
python3 validate.py --format json                # 機械可読 JSON(CI 向け)
python3 validate.py --format markdown            # Markdown テーブルのみ
python3 validate.py --no-color                   # ANSI カラー無効(パイプ時は自動無効)

# 閾値上書き
python3 validate.py --max-usdz-mb 80 --fail-usdz-mb 150
python3 validate.py --max-png-mb 2
python3 validate.py --xcstrings-coverage-min 0.9
```

### 終了コード

| 状況 | exit |
|---|---|
| すべて PASS / INFO | `0` |
| WARN のみ(通常) | `2` |
| WARN のみ(`--strict`) | `1` |
| FAIL あり | `1` |

### JSON スキーマ

```json
{
  "summary": { "PASS": 3, "INFO": 7, "WARN": 1, "FAIL": 0, "total": 11 },
  "findings": [
    {
      "severity": "WARN",
      "check": "xcstrings.coverage.zh-Hans",
      "path": "Resources/Localization/Localizable.xcstrings",
      "message": "zh-Hans coverage 81.7% ..."
    }
  ]
}
```

## GitHub Actions 連携例

```yaml
# .github/workflows/asset-validator.yml
name: asset-validator
on:
  pull_request:
    paths:
      - 'Resources/**'
      - 'Tools/asset-validator/**'
  push:
    branches: [main]

jobs:
  validate:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
        with:
          lfs: false  # we want to see pointer files, not the real blobs
      - uses: actions/setup-python@v5
        with:
          python-version: '3.11'
      - name: Run asset-validator
        run: |
          python3 Tools/asset-validator/validate.py \
            --no-color \
            --format json \
            Resources/ | tee validator.json
      - name: Fail if FAIL findings exist
        run: |
          python3 -c "
          import json, sys
          d = json.load(open('validator.json'))
          sys.exit(1 if d['summary']['FAIL'] > 0 else 0)
          "
```

`--strict` を付ければ WARN も CI を止める。Phase 0 の段階では `--strict` を外しておくと、
まだ未翻訳の xcstrings キーが残っていても CI を通せる。

## 新しいチェックを追加する

1. `validate.py` の `Validator` クラスに `check_<name>(self)` メソッドを足す。
2. `Validator.run` の末尾でそのメソッドを呼ぶ。
3. メソッド内で発見ごとに `self._add(Severity.XXX, "check.id", path, message)` を呼ぶ。
   - `Severity`: `PASS` / `INFO` / `WARN` / `FAIL`
   - `check.id`: ドット区切り階層名(例:`lfs.tracked`)。CI で grep しやすくする。
   - `path`: `Path` でも `str` でも可。自動で repo-root 相対パスに変換される。
4. 閾値が必要なら `Thresholds` dataclass に追加し、`build_argparser` に CLI オプションを足す。
5. README のチェック規則表に追記する。

## 注意

- このツールはリポジトリの他の場所(`Packages/`、`.github/`、`.gitattributes`)を編集しない。
- 検査専用。自動修復はしない。
- 3rd-party ライブラリに依存しないので、`pip install` 無しで `python3 validate.py --help` が動く前提。
