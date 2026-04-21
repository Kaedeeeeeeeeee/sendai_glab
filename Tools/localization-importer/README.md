# localization-importer

Convert the legacy Unity project's three locale JSON files into a single
Xcode **String Catalog** (`Localizable.xcstrings`) for SDG-Lab.

This tool is **read-only** against the Unity source. It never modifies
`/Users/user/Unity/GeoModelTest/`.

## Purpose

The Unity project `GeoModelTest` ships per-language JSON files under
`Assets/Resources/Localization/Data/` using a flat key/value list and
C# `string.Format` placeholders (`{0}`, `{1}`, ...).

SDG-Lab (Swift + RealityKit) uses Xcode 15's String Catalog format
(`.xcstrings`) which is a single JSON file with per-language
`stringUnit` entries and Apple-style positional placeholders
(`%1$@`, `%2$@`, ...).

This script merges the three Unity files by key, rewrites placeholders,
and emits `Resources/Localization/Localizable.xcstrings` at the repo root.

## Requirements

- Python 3.10+ (no third-party dependencies)

## Usage

```bash
# Default paths (Unity source -> Resources/Localization/Localizable.xcstrings)
python3 import_from_unity.py

# Override input / output
python3 import_from_unity.py \
    --input-dir /path/to/Unity/Assets/Resources/Localization/Data \
    --output    /path/to/Resources/Localization/Localizable.xcstrings

# Full coverage report (lists every key missing from any language)
python3 import_from_unity.py --report

# Help
python3 import_from_unity.py --help
```

The script prints a compact coverage summary by default. Pass `--report`
to also list the specific keys missing from each language.

## Language-code mapping

| Unity file    | xcstrings code | Notes                                  |
| ------------- | -------------- | -------------------------------------- |
| `zh-CN.json`  | `zh-Hans`      | Xcode uses script subtags for Chinese. |
| `en-US.json`  | `en`           | Generic English.                       |
| `ja-JP.json`  | `ja`           | **Source language** (story origin).    |

`sourceLanguage` in the output catalog is set to `ja` because the story
is authored in Japanese.

## Placeholder conversion

Unity uses C# `string.Format` style `{N}` (0-indexed). Apple uses
positional specifiers `%N$<type>` (1-indexed).

We default to `%@` (any object) because the Unity source does not
record the runtime type at the call site:

| Unity | xcstrings | Reason                                               |
| ----- | --------- | ---------------------------------------------------- |
| `{0}` | `%1$@`    | 0-indexed → 1-indexed, Any-object formatter.         |
| `{1}` | `%2$@`    | ditto.                                               |
| `{2}` | `%3$@`    | ditto.                                               |

`%@` accepts any Swift type conforming to `CVarArg` through
`NSNumber` / `NSString` bridging, so passing an `Int` still works:

```swift
String(localized: "warehouse.dialog.discard_message", defaultValue: "...")
```

If the runtime call site already uses
`String(localized:)` with a format like
`String.LocalizationValue("...%lld...")`, the catalog can be hand-edited
in Phase 2 to narrow the specifier (e.g. `%1$lld` for integers,
`%1$f` for floats). This is a nice-to-have, not required for correctness
of `%@`.

## Opening the catalog in Xcode

1. Xcode ▸ File ▸ Open... ▸ `Resources/Localization/Localizable.xcstrings`
2. Add `Localizable.xcstrings` to the main app target (Xcode will do this
   automatically when a `*.xcstrings` file is dropped into the Project
   navigator).
3. The Catalog editor shows each key as a row; each language as a
   column. Status icons (green check, yellow dot, red flag) indicate
   translation state — after this import, every translated value is
   marked `translated`.

## Adding a new key

There are two workflows, use whichever is more ergonomic:

### A. Code-first (recommended for Swift code)

Write the call site with `String(localized:)` and let Xcode extract:

```swift
Text(String(localized: "quest.firstSample.title",
            defaultValue: "最初のサンプルを採取",
            comment: "Title of the tutorial quest"))
```

Build once; Xcode adds an entry under that key with
`extractionState = "extracted_with_value"` and the default value in the
source language. Provide translations in the Catalog editor.

### B. Catalog-first

In the Catalog editor press ⌘N (or the `+` button) to add a row. Type
the key, fill each language's value. `extractionState` will be
`manual`, which is what this importer writes for migrated keys.

## Adding a new language (e.g. Korean)

1. In the Catalog editor click `+` at the bottom of the language list
   and choose **Korean (ko)**.
2. Every existing row gets an empty Korean cell with `state = "new"`.
3. Translate in-place or export via
   **Product ▸ Export Localizations** (XLIFF) for an external service.

No code change or rerun of this importer is required. The
`LocalizationService` in `Sources/Core/` reads whatever the catalog
contains at runtime via `Bundle.main.localizedString(forKey:)`.

## File format reference

The emitted catalog follows Apple's published schema (WWDC23 "Discover
String Catalogs" + Xcode 15 docs):

```json
{
  "sourceLanguage": "ja",
  "strings": {
    "ui.settings.title": {
      "extractionState": "manual",
      "localizations": {
        "ja":      { "stringUnit": { "state": "translated", "value": "設定" } },
        "en":      { "stringUnit": { "state": "translated", "value": "Settings" } },
        "zh-Hans": { "stringUnit": { "state": "translated", "value": "设置" } }
      }
    }
  },
  "version": "1.0"
}
```

Valid `state` values observed: `translated`, `new`, `needs_review`,
`stale`. Valid `extractionState` values: `manual`,
`extracted_with_value`, `migrated`, `stale`. We emit `manual` because
these entries are hand-sourced from the Unity import, not
auto-extracted from Swift code.

Plural variations use a different shape (`variations.plural.one/other`)
and are **not produced by this importer**; Unity did not distinguish
singular/plural forms, so every key is a flat `stringUnit`. Any
plural-sensitive keys should be hand-fixed in Phase 2.

## Verification

After running the importer, sanity-check the output:

```bash
# Must be valid JSON
python3 -c "import json; json.load(open('../../Resources/Localization/Localizable.xcstrings'))"

# Expected key counts (as of the 2025-12 Unity snapshot)
python3 import_from_unity.py --report | head
```
