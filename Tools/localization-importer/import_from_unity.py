#!/usr/bin/env python3
"""Import Unity localization JSON files into an Xcode String Catalog (.xcstrings).

The legacy Unity project (``GeoModelTest``) ships three locale files under
``Assets/Resources/Localization/Data/`` using a flat ``{"texts": [{"key", "value"}]}``
schema and C# ``string.Format`` placeholders (``{0}``, ``{1}`` ...).

Xcode 15+ String Catalogs are a single JSON file (``Localizable.xcstrings``) with
per-language ``stringUnit`` entries and ``%1$@`` / ``%lld`` style placeholders.

This script merges the three Unity files by ``key`` and emits a valid
``Localizable.xcstrings`` at ``Resources/Localization/Localizable.xcstrings``.

See ``README.md`` for the language-code mapping and placeholder rules.
"""

from __future__ import annotations

import argparse
import json
import re
import sys
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------

# Unity JSON file name -> (xcstrings language code, human label for reports).
# The mapping follows Apple's BCP-47 codes as accepted by Xcode:
#   zh-CN  -> zh-Hans (Simplified Chinese)
#   en-US  -> en      (English; Apple treats region-less as the default English)
#   ja-JP  -> ja
LOCALE_MAP: dict[str, str] = {
    "zh-CN.json": "zh-Hans",
    "en-US.json": "en",
    "ja-JP.json": "ja",
}

# Story source language is Japanese — used for xcstrings "sourceLanguage".
SOURCE_LANGUAGE: str = "ja"

# Default input / output paths, resolved relative to the repo root.
_REPO_ROOT = Path(__file__).resolve().parents[2]
DEFAULT_INPUT_DIR = Path(
    "/Users/user/Unity/GeoModelTest/Assets/Resources/Localization/Data"
)
DEFAULT_OUTPUT = _REPO_ROOT / "Resources" / "Localization" / "Localizable.xcstrings"


# Regex for C# ``string.Format`` positional placeholders, e.g. ``{0}`` or ``{12}``.
# We deliberately do not match ``{named}`` (not used by the Unity project) nor
# ``{{`` literal-brace escapes (also unused).
_PLACEHOLDER_RE = re.compile(r"\{(\d+)\}")


# ---------------------------------------------------------------------------
# Data model
# ---------------------------------------------------------------------------


@dataclass
class ImportStats:
    """Bookkeeping for the --report flag and end-of-run summary."""

    per_language_keys: dict[str, int] = field(default_factory=dict)
    total_keys: int = 0
    full_coverage_keys: int = 0
    missing_per_language: dict[str, list[str]] = field(default_factory=dict)
    placeholder_replacements: int = 0
    skipped_empty: int = 0


# ---------------------------------------------------------------------------
# Core logic
# ---------------------------------------------------------------------------


def convert_placeholders(value: str) -> tuple[str, int]:
    """Rewrite C# ``{N}`` placeholders to Swift/Apple positional ``%(N+1)$@``.

    We uniformly emit ``%1$@`` (object) since we do not know whether the caller
    will pass an ``Int``, ``Double`` or ``String``. ``%@`` is safe for any
    ``CVarArg`` boxed as ``NSNumber`` / ``NSString``; for exact integer
    formatting the Phase-2 pass can hand-tune specific keys to ``%1$lld`` etc.

    Returns the converted string and the number of substitutions performed.
    """

    count = 0

    def _sub(match: re.Match[str]) -> str:
        nonlocal count
        count += 1
        # C# is 0-indexed, Apple positional specifiers are 1-indexed.
        index = int(match.group(1)) + 1
        return f"%{index}$@"

    return _PLACEHOLDER_RE.sub(_sub, value), count


def load_unity_json(path: Path) -> dict[str, str]:
    """Read one Unity ``{"texts":[...]}`` file into a ``key -> value`` dict.

    Missing files are tolerated: a warning is printed and an empty dict is
    returned so the merge downstream simply marks that language as absent.
    """

    if not path.exists():
        print(f"warning: {path} not found, skipping", file=sys.stderr)
        return {}

    try:
        raw = json.loads(path.read_text(encoding="utf-8"))
    except json.JSONDecodeError as exc:
        print(f"error: {path} is not valid JSON: {exc}", file=sys.stderr)
        return {}

    texts = raw.get("texts", [])
    result: dict[str, str] = {}
    for entry in texts:
        key = entry.get("key")
        value = entry.get("value")
        if not isinstance(key, str) or not isinstance(value, str):
            continue
        # Later duplicates win; Unity occasionally ships duplicate keys and
        # the last value in the file tends to be the most current.
        result[key] = value
    return result


def build_catalog(
    per_language: dict[str, dict[str, str]],
    stats: ImportStats,
) -> dict[str, Any]:
    """Merge the per-language maps into an xcstrings-shaped dict.

    ``per_language`` maps xcstrings codes (``"ja"``, ``"en"``, ``"zh-Hans"``) to
    their ``key -> value`` dict.
    """

    # Union of keys across all input files — iteration order is insertion
    # order, which we seed from the source language so the output groups
    # source-language keys first (more diff-friendly).
    all_keys: list[str] = []
    seen: set[str] = set()
    preferred_order = [SOURCE_LANGUAGE] + [
        code for code in per_language if code != SOURCE_LANGUAGE
    ]
    for code in preferred_order:
        for key in per_language.get(code, {}):
            if key not in seen:
                seen.add(key)
                all_keys.append(key)

    strings: dict[str, Any] = {}
    for key in sorted(all_keys):
        localizations: dict[str, Any] = {}
        have_languages = 0
        missing_in: list[str] = []

        for code in preferred_order:
            value = per_language.get(code, {}).get(key)
            if value is None:
                missing_in.append(code)
                continue
            if value == "":
                stats.skipped_empty += 1
                missing_in.append(code)
                continue

            converted, n = convert_placeholders(value)
            stats.placeholder_replacements += n
            localizations[code] = {
                "stringUnit": {"state": "translated", "value": converted},
            }
            have_languages += 1

        if not localizations:
            # Unity key with no usable value anywhere — drop it rather than
            # emit an empty entry (Xcode would flag it as "new").
            continue

        entry: dict[str, Any] = {
            "extractionState": "manual",
            "localizations": localizations,
        }
        strings[key] = entry

        stats.total_keys += 1
        if have_languages == len(preferred_order):
            stats.full_coverage_keys += 1
        for code in missing_in:
            stats.missing_per_language.setdefault(code, []).append(key)

    for code in preferred_order:
        stats.per_language_keys[code] = sum(
            1 for entry in strings.values() if code in entry["localizations"]
        )

    return {
        "sourceLanguage": SOURCE_LANGUAGE,
        "strings": strings,
        "version": "1.0",
    }


def write_catalog(path: Path, catalog: dict[str, Any]) -> None:
    """Write ``catalog`` as pretty-printed JSON (2-space indent, UTF-8)."""

    path.parent.mkdir(parents=True, exist_ok=True)
    # Xcode itself writes ``.xcstrings`` files with 2-space indent, UTF-8, no
    # ``ensure_ascii`` escaping, and a trailing newline.
    serialized = json.dumps(catalog, indent=2, ensure_ascii=False, sort_keys=False)
    path.write_text(serialized + "\n", encoding="utf-8")


def print_report(stats: ImportStats, verbose_missing: bool) -> None:
    """Print a coverage report to stdout."""

    print()
    print("=== Localization import report ===")
    print(f"Total keys written      : {stats.total_keys}")
    print(f"Keys with all languages : {stats.full_coverage_keys}")
    if stats.total_keys:
        coverage_pct = 100.0 * stats.full_coverage_keys / stats.total_keys
        print(f"Full-coverage share     : {coverage_pct:.1f}%")
    print(f"Placeholder rewrites    : {stats.placeholder_replacements}")
    if stats.skipped_empty:
        print(f"Empty values dropped    : {stats.skipped_empty}")
    print()
    print("Per-language key counts:")
    for code, count in stats.per_language_keys.items():
        missing = len(stats.missing_per_language.get(code, []))
        print(f"  {code:<8} {count:>5} keys  (missing {missing})")

    if verbose_missing:
        print()
        print("Missing keys per language:")
        for code, keys in stats.missing_per_language.items():
            if not keys:
                continue
            print(f"  [{code}] {len(keys)} missing:")
            for k in keys:
                print(f"    - {k}")


# ---------------------------------------------------------------------------
# CLI
# ---------------------------------------------------------------------------


def parse_args(argv: list[str] | None = None) -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description=(
            "Merge the three Unity locale JSON files into a single "
            "Xcode String Catalog (.xcstrings)."
        ),
    )
    parser.add_argument(
        "--input-dir",
        type=Path,
        default=DEFAULT_INPUT_DIR,
        help=f"Directory containing zh-CN.json / en-US.json / ja-JP.json "
        f"(default: {DEFAULT_INPUT_DIR})",
    )
    parser.add_argument(
        "--output",
        type=Path,
        default=DEFAULT_OUTPUT,
        help=f"Destination .xcstrings path (default: {DEFAULT_OUTPUT})",
    )
    parser.add_argument(
        "--report",
        action="store_true",
        help="After writing, print per-language coverage and list missing keys.",
    )
    return parser.parse_args(argv)


def main(argv: list[str] | None = None) -> int:
    args = parse_args(argv)

    input_dir: Path = args.input_dir
    output: Path = args.output

    if not input_dir.exists():
        print(f"error: input directory {input_dir} does not exist", file=sys.stderr)
        return 2

    per_language: dict[str, dict[str, str]] = {}
    for filename, code in LOCALE_MAP.items():
        data = load_unity_json(input_dir / filename)
        per_language[code] = data
        print(f"loaded {filename:<12} -> {code:<8} ({len(data)} keys)")

    stats = ImportStats()
    catalog = build_catalog(per_language, stats)
    write_catalog(output, catalog)
    print(f"wrote {output}")

    # Round-trip sanity check: re-read and decode what we just wrote so
    # callers see a failure early rather than discovering a malformed file
    # inside Xcode.
    try:
        json.loads(output.read_text(encoding="utf-8"))
    except json.JSONDecodeError as exc:
        print(f"error: generated file failed JSON round-trip: {exc}", file=sys.stderr)
        return 1

    print_report(stats, verbose_missing=args.report)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
