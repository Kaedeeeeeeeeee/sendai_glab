#!/usr/bin/env python3
"""SDG-Lab asset validator.

Scans `Resources/` and enforces naming conventions, size limits,
Git LFS health, and data-file integrity checks.

Exit codes:
    0 = all findings are PASS / INFO
    1 = at least one FAIL (or any WARN when --strict is set)
    2 = only WARN findings (non-strict)

Designed to be dependency-free (Python 3.11+ stdlib only) and CI-friendly.
"""

from __future__ import annotations

import argparse
import json
import os
import re
import shutil
import subprocess
import sys
from dataclasses import dataclass, field, asdict
from enum import Enum
from pathlib import Path
from typing import Iterable, Iterator


# ---------------------------------------------------------------------------
# Severity & Finding model
# ---------------------------------------------------------------------------


class Severity(str, Enum):
    PASS = "PASS"
    INFO = "INFO"
    WARN = "WARN"
    FAIL = "FAIL"


SEVERITY_ORDER = {
    Severity.PASS: 0,
    Severity.INFO: 1,
    Severity.WARN: 2,
    Severity.FAIL: 3,
}


@dataclass
class Finding:
    severity: Severity
    check: str
    path: str
    message: str

    def to_dict(self) -> dict:
        d = asdict(self)
        d["severity"] = self.severity.value
        return d


# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------


@dataclass
class Thresholds:
    usdz_warn_mb: float = 50.0
    usdz_fail_mb: float = 100.0
    png_warn_mb: float = 4.0
    heic_warn_mb: float = 2.0
    xcstrings_coverage_min: float = 0.95
    required_locales: tuple[str, ...] = ("ja", "en", "zh-Hans")


# File naming regexes derived from Docs/AssetPipeline.md
RE_ENVIRONMENT = re.compile(r"^Environment_[A-Za-z0-9]+_[A-Za-z0-9]+\.usdz$")
# Variant is optional — NPCs with only one form (e.g. Kaede, Teacher)
# legitimately have no variant suffix. Player characters still use
# Role_Variant (Player_Male / Player_Female).
RE_CHARACTER = re.compile(r"^Character_[A-Za-z0-9]+(_[A-Za-z0-9]+)?\.usdz$")
RE_PROP = re.compile(r"^Prop_[A-Za-z0-9]+\.usdz$")
RE_UI_PNG = re.compile(r"^UI_[A-Za-z0-9]+_[A-Za-z0-9]+\.png$")


# Extensions that should be managed by Git LFS per AssetPipeline.md §"Git LFS"
LFS_EXTENSIONS_ALWAYS = {".usdz", ".heic", ".jpg", ".jpeg"}
# PNG goes to LFS when > 1 MB per the pipeline spec.
LFS_PNG_THRESHOLD_BYTES = 1 * 1024 * 1024

LFS_POINTER_HEADER = b"version https://git-lfs.github.com/spec/v1"


# ---------------------------------------------------------------------------
# ANSI color helper
# ---------------------------------------------------------------------------


class Color:
    RESET = "\033[0m"
    RED = "\033[31m"
    GREEN = "\033[32m"
    YELLOW = "\033[33m"
    BLUE = "\033[34m"
    GREY = "\033[90m"
    BOLD = "\033[1m"


def _severity_color(severity: Severity) -> str:
    return {
        Severity.PASS: Color.GREEN,
        Severity.INFO: Color.BLUE,
        Severity.WARN: Color.YELLOW,
        Severity.FAIL: Color.RED,
    }[severity]


# ---------------------------------------------------------------------------
# Validator core
# ---------------------------------------------------------------------------


class Validator:
    def __init__(
        self,
        root: Path,
        resources_dir: Path,
        thresholds: Thresholds,
    ) -> None:
        self.root = root
        self.resources_dir = resources_dir
        self.thresholds = thresholds
        self.findings: list[Finding] = []
        # Cache whether git-lfs is available and whether `git` finds a repo.
        self._git_lfs_available = shutil.which("git-lfs") is not None
        self._git_available = shutil.which("git") is not None
        self._git_repo_detected = self._detect_git_repo()

    # -- small utilities ----------------------------------------------------

    def _detect_git_repo(self) -> bool:
        if not self._git_available:
            return False
        try:
            result = subprocess.run(
                ["git", "rev-parse", "--is-inside-work-tree"],
                cwd=str(self.root),
                capture_output=True,
                text=True,
                check=False,
            )
        except OSError:
            return False
        return result.returncode == 0 and result.stdout.strip() == "true"

    def _rel(self, path: Path) -> str:
        try:
            return str(path.relative_to(self.root))
        except ValueError:
            return str(path)

    def _add(
        self,
        severity: Severity,
        check: str,
        path: Path | str,
        message: str,
    ) -> None:
        p = path if isinstance(path, str) else self._rel(path)
        self.findings.append(Finding(severity, check, p, message))

    # -- individual checks --------------------------------------------------

    def check_naming(self) -> None:
        """Rule 1: enforce filename conventions per AssetPipeline.md."""
        checks: list[tuple[str, Path, re.Pattern[str], str, str]] = [
            (
                "naming.environment",
                self.resources_dir / "Environment",
                RE_ENVIRONMENT,
                "*.usdz",
                "Environment_{Area}_{Tile}.usdz",
            ),
            (
                "naming.characters",
                self.resources_dir / "Characters",
                RE_CHARACTER,
                "*.usdz",
                "Character_{Role}_{Variant}.usdz",
            ),
            (
                "naming.props",
                self.resources_dir / "Props",
                RE_PROP,
                "*.usdz",
                "Prop_{Name}.usdz",
            ),
        ]

        for check_id, directory, pattern, glob, shape in checks:
            if not directory.exists():
                self._add(
                    Severity.INFO,
                    check_id,
                    directory,
                    f"directory not present yet; expected shape `{shape}` once assets exist",
                )
                continue
            any_matched = False
            for file in sorted(directory.glob(glob)):
                any_matched = True
                if pattern.match(file.name):
                    self._add(
                        Severity.PASS,
                        check_id,
                        file,
                        f"matches `{shape}`",
                    )
                else:
                    self._add(
                        Severity.FAIL,
                        check_id,
                        file,
                        f"filename violates convention `{shape}`",
                    )
            if not any_matched:
                self._add(
                    Severity.INFO,
                    check_id,
                    directory,
                    f"no {glob} files yet",
                )

        # UI PNG (recursive)
        ui_dir = self.resources_dir / "UI"
        if not ui_dir.exists():
            self._add(
                Severity.INFO,
                "naming.ui",
                ui_dir,
                "directory not present yet; expected shape `UI_{Category}_{Name}.png` once assets exist",
            )
        else:
            any_matched = False
            for file in sorted(ui_dir.rglob("*.png")):
                any_matched = True
                if RE_UI_PNG.match(file.name):
                    self._add(
                        Severity.PASS,
                        "naming.ui",
                        file,
                        "matches `UI_{Category}_{Name}.png`",
                    )
                else:
                    self._add(
                        Severity.FAIL,
                        "naming.ui",
                        file,
                        "filename violates convention `UI_{Category}_{Name}.png`",
                    )
            if not any_matched:
                self._add(
                    Severity.INFO,
                    "naming.ui",
                    ui_dir,
                    "no *.png files yet",
                )

    def _iter_resource_files(self, *exts: str) -> Iterator[Path]:
        if not self.resources_dir.exists():
            return
        normalized = {e.lower() for e in exts}
        for path in self.resources_dir.rglob("*"):
            if path.is_file() and path.suffix.lower() in normalized:
                yield path

    def check_file_sizes(self) -> None:
        """Rule 2: enforce per-extension size limits."""
        t = self.thresholds
        # USDZ
        for file in self._iter_resource_files(".usdz"):
            size_mb = file.stat().st_size / (1024 * 1024)
            if size_mb > t.usdz_fail_mb:
                self._add(
                    Severity.FAIL,
                    "size.usdz",
                    file,
                    f"{size_mb:.1f} MB exceeds hard limit {t.usdz_fail_mb:.0f} MB",
                )
            elif size_mb > t.usdz_warn_mb:
                self._add(
                    Severity.WARN,
                    "size.usdz",
                    file,
                    f"{size_mb:.1f} MB exceeds soft limit {t.usdz_warn_mb:.0f} MB",
                )
            else:
                self._add(
                    Severity.PASS,
                    "size.usdz",
                    file,
                    f"{size_mb:.1f} MB within limits",
                )
        # PNG
        for file in self._iter_resource_files(".png"):
            size_mb = file.stat().st_size / (1024 * 1024)
            if size_mb > t.png_warn_mb:
                self._add(
                    Severity.WARN,
                    "size.png",
                    file,
                    f"{size_mb:.1f} MB exceeds soft limit {t.png_warn_mb:.1f} MB",
                )
            else:
                self._add(
                    Severity.PASS,
                    "size.png",
                    file,
                    f"{size_mb:.1f} MB within limits",
                )
        # HEIC
        for file in self._iter_resource_files(".heic"):
            size_mb = file.stat().st_size / (1024 * 1024)
            if size_mb > t.heic_warn_mb:
                self._add(
                    Severity.WARN,
                    "size.heic",
                    file,
                    f"{size_mb:.1f} MB exceeds soft limit {t.heic_warn_mb:.1f} MB",
                )
            else:
                self._add(
                    Severity.PASS,
                    "size.heic",
                    file,
                    f"{size_mb:.1f} MB within limits",
                )

    def _should_track_with_lfs(self, file: Path) -> bool:
        ext = file.suffix.lower()
        if ext in LFS_EXTENSIONS_ALWAYS:
            return True
        if ext == ".png":
            try:
                return file.stat().st_size > LFS_PNG_THRESHOLD_BYTES
            except OSError:
                return False
        return False

    def _is_lfs_pointer(self, file: Path) -> bool:
        """A real LFS pointer is a tiny UTF-8 text file starting with the spec header."""
        try:
            with file.open("rb") as f:
                head = f.read(200)
        except OSError:
            return False
        return head.startswith(LFS_POINTER_HEADER)

    def _git_check_attr_filter(self, file: Path) -> str | None:
        """Return the `filter` git attribute for `file`, or None if unknown."""
        if not self._git_repo_detected:
            return None
        try:
            result = subprocess.run(
                ["git", "check-attr", "filter", "--", str(file)],
                cwd=str(self.root),
                capture_output=True,
                text=True,
                check=False,
            )
        except OSError:
            return None
        if result.returncode != 0:
            return None
        # Output format: "<path>: filter: <value>"
        line = result.stdout.strip()
        if not line:
            return None
        parts = line.rsplit(":", 1)
        if len(parts) != 2:
            return None
        value = parts[1].strip()
        if value in ("", "unspecified"):
            return None
        return value

    def check_lfs(self) -> None:
        """Rule 3: confirm files that should be in Git LFS actually are."""
        if not self._git_lfs_available:
            self._add(
                Severity.WARN,
                "lfs.tooling",
                self.root,
                "git-lfs binary not found on PATH; install via `brew install git-lfs` and run `git lfs install`",
            )
        if not self._git_repo_detected:
            self._add(
                Severity.INFO,
                "lfs.repo",
                self.root,
                "not inside a git work tree; skipping `git check-attr` path and relying on pointer sniffing only",
            )

        if not self.resources_dir.exists():
            return

        for file in self.resources_dir.rglob("*"):
            if not file.is_file():
                continue
            if not self._should_track_with_lfs(file):
                continue

            filter_attr = self._git_check_attr_filter(file)
            is_pointer = self._is_lfs_pointer(file)

            if filter_attr == "lfs" or is_pointer:
                detail = []
                if filter_attr == "lfs":
                    detail.append("git-attr=lfs")
                if is_pointer:
                    detail.append("pointer-file")
                self._add(
                    Severity.PASS,
                    "lfs.tracked",
                    file,
                    f"tracked by Git LFS ({', '.join(detail)})",
                )
            elif filter_attr is None and not self._git_repo_detected:
                # Cannot determine without a git repo; degrade to WARN once.
                self._add(
                    Severity.WARN,
                    "lfs.tracked",
                    file,
                    "cannot verify LFS status outside a git work tree",
                )
            else:
                self._add(
                    Severity.FAIL,
                    "lfs.tracked",
                    file,
                    "should be LFS-tracked but git-attr filter is not `lfs` and file is not an LFS pointer",
                )

    def check_xcstrings(self) -> None:
        """Rule 4: xcstrings coverage and duplicate-key sanity."""
        xc_path = self.resources_dir / "Localization" / "Localizable.xcstrings"
        if not xc_path.exists():
            self._add(
                Severity.INFO,
                "xcstrings",
                xc_path,
                "Localizable.xcstrings not present yet",
            )
            return

        raw_bytes = xc_path.read_bytes()
        try:
            raw_text = raw_bytes.decode("utf-8")
        except UnicodeDecodeError as e:
            self._add(
                Severity.FAIL,
                "xcstrings.encoding",
                xc_path,
                f"not valid UTF-8: {e}",
            )
            return

        # Detect duplicate keys at the JSON level. Standard json.loads drops dupes
        # silently so we pass an object_pairs_hook to flag them.
        duplicates: list[str] = []

        def _hook(pairs: list[tuple[str, object]]) -> dict:
            seen: dict[str, int] = {}
            for k, _ in pairs:
                seen[k] = seen.get(k, 0) + 1
            for k, count in seen.items():
                if count > 1:
                    duplicates.append(k)
            return dict(pairs)

        try:
            data = json.loads(raw_text, object_pairs_hook=_hook)
        except json.JSONDecodeError as e:
            self._add(
                Severity.FAIL,
                "xcstrings.parse",
                xc_path,
                f"invalid JSON: {e}",
            )
            return

        if duplicates:
            self._add(
                Severity.FAIL,
                "xcstrings.duplicates",
                xc_path,
                f"duplicate keys detected: {', '.join(sorted(set(duplicates))[:10])}",
            )

        strings = data.get("strings")
        if not isinstance(strings, dict):
            self._add(
                Severity.FAIL,
                "xcstrings.schema",
                xc_path,
                "`strings` root object missing or not a dict",
            )
            return

        total = len(strings)
        if total == 0:
            self._add(
                Severity.WARN,
                "xcstrings.coverage",
                xc_path,
                "no localization keys found",
            )
            return

        t = self.thresholds
        missing_per_locale: dict[str, list[str]] = {loc: [] for loc in t.required_locales}
        for key, entry in strings.items():
            localizations = (entry or {}).get("localizations") or {}
            for loc in t.required_locales:
                loc_entry = localizations.get(loc) or {}
                unit = loc_entry.get("stringUnit") or {}
                value = unit.get("value")
                state = unit.get("state")
                translated = isinstance(value, str) and value.strip() != "" and state == "translated"
                if not translated:
                    missing_per_locale[loc].append(key)

        for loc in t.required_locales:
            missing = missing_per_locale[loc]
            covered = total - len(missing)
            coverage = covered / total
            if coverage < t.xcstrings_coverage_min:
                preview = ", ".join(missing[:10])
                self._add(
                    Severity.WARN,
                    f"xcstrings.coverage.{loc}",
                    xc_path,
                    (
                        f"{loc} coverage {coverage * 100:.1f}% "
                        f"({covered}/{total}) below {t.xcstrings_coverage_min * 100:.0f}% "
                        f"— missing first 10: [{preview}]"
                    ),
                )
            else:
                self._add(
                    Severity.PASS,
                    f"xcstrings.coverage.{loc}",
                    xc_path,
                    f"{loc} coverage {coverage * 100:.1f}% ({covered}/{total})",
                )

        self._add(
            Severity.PASS,
            "xcstrings.summary",
            xc_path,
            f"{total} keys, source language `{data.get('sourceLanguage', '?')}`",
        )

    def check_json_data_files(self) -> None:
        """Rule 5: JSON files in Geology/ and Story/ must be valid UTF-8 JSON."""
        sub_dirs = ["Geology", "Story", "Data"]
        for sub in sub_dirs:
            directory = self.resources_dir / sub
            if not directory.exists():
                self._add(
                    Severity.INFO,
                    f"json.{sub.lower()}",
                    directory,
                    f"directory not present yet",
                )
                continue
            any_found = False
            for file in sorted(directory.rglob("*.json")):
                any_found = True
                raw = file.read_bytes()
                try:
                    text = raw.decode("utf-8")
                except UnicodeDecodeError as e:
                    self._add(
                        Severity.WARN,
                        f"json.{sub.lower()}.encoding",
                        file,
                        f"not valid UTF-8: {e}",
                    )
                    continue
                try:
                    json.loads(text)
                except json.JSONDecodeError as e:
                    self._add(
                        Severity.FAIL,
                        f"json.{sub.lower()}.parse",
                        file,
                        f"invalid JSON: {e}",
                    )
                    continue
                self._add(
                    Severity.PASS,
                    f"json.{sub.lower()}",
                    file,
                    "valid UTF-8 JSON",
                )
            if not any_found:
                self._add(
                    Severity.INFO,
                    f"json.{sub.lower()}",
                    directory,
                    "no *.json files yet",
                )

    # -- orchestration ------------------------------------------------------

    def run(self) -> None:
        if not self.resources_dir.exists():
            self._add(
                Severity.FAIL,
                "bootstrap",
                self.resources_dir,
                "Resources directory does not exist",
            )
            return
        self.check_naming()
        self.check_file_sizes()
        self.check_lfs()
        self.check_xcstrings()
        self.check_json_data_files()


# ---------------------------------------------------------------------------
# Output formatters
# ---------------------------------------------------------------------------


def summary_counts(findings: Iterable[Finding]) -> dict[str, int]:
    counts = {sev.value: 0 for sev in Severity}
    for f in findings:
        counts[f.severity.value] += 1
    return counts


def format_text(findings: list[Finding], use_color: bool) -> str:
    lines: list[str] = []
    for f in findings:
        tag = f.severity.value.ljust(4)
        if use_color:
            colored = f"{_severity_color(f.severity)}{tag}{Color.RESET}"
        else:
            colored = tag
        lines.append(f"{colored}  [{f.check}] {f.path} — {f.message}")
    counts = summary_counts(findings)
    summary = (
        f"PASS={counts['PASS']}  INFO={counts['INFO']}  "
        f"WARN={counts['WARN']}  FAIL={counts['FAIL']}  "
        f"total={len(findings)}"
    )
    if use_color:
        summary = f"{Color.BOLD}{summary}{Color.RESET}"
    lines.append("")
    lines.append(summary)
    return "\n".join(lines)


def format_json(findings: list[Finding]) -> str:
    payload = {
        "summary": summary_counts(findings) | {"total": len(findings)},
        "findings": [f.to_dict() for f in findings],
    }
    return json.dumps(payload, indent=2, ensure_ascii=False)


def format_markdown(findings: list[Finding]) -> str:
    counts = summary_counts(findings)
    lines = [
        "# Asset Validator Report",
        "",
        "## Summary",
        "",
        f"- PASS: {counts['PASS']}",
        f"- INFO: {counts['INFO']}",
        f"- WARN: {counts['WARN']}",
        f"- FAIL: {counts['FAIL']}",
        f"- Total: {len(findings)}",
        "",
        "## Findings",
        "",
        "| Severity | Check | Path | Message |",
        "| --- | --- | --- | --- |",
    ]
    for f in findings:
        path = f.path.replace("|", "\\|")
        message = f.message.replace("|", "\\|")
        lines.append(f"| {f.severity.value} | `{f.check}` | `{path}` | {message} |")
    return "\n".join(lines) + "\n"


# ---------------------------------------------------------------------------
# CLI
# ---------------------------------------------------------------------------


def build_argparser() -> argparse.ArgumentParser:
    p = argparse.ArgumentParser(
        prog="validate.py",
        description=(
            "Validate SDG-Lab asset directory for naming, size, Git LFS, "
            "xcstrings coverage, and JSON health."
        ),
    )
    p.add_argument(
        "resources",
        nargs="?",
        default="Resources",
        help="Path to Resources/ directory (default: Resources)",
    )
    p.add_argument(
        "--root",
        default=None,
        help="Repository root (defaults to parent of resources path if it looks like a repo, else cwd)",
    )
    p.add_argument(
        "--strict",
        action="store_true",
        help="Treat WARN findings as FAIL for exit-code purposes",
    )
    p.add_argument(
        "--report",
        action="store_true",
        help="Emit a Markdown summary report after the default output",
    )
    p.add_argument(
        "--format",
        choices=("text", "json", "markdown"),
        default="text",
        help="Output format (default: text)",
    )
    p.add_argument(
        "--no-color",
        action="store_true",
        help="Disable ANSI color output (default: auto, based on TTY)",
    )
    p.add_argument("--max-usdz-mb", type=float, default=Thresholds.usdz_warn_mb)
    p.add_argument("--fail-usdz-mb", type=float, default=Thresholds.usdz_fail_mb)
    p.add_argument("--max-png-mb", type=float, default=Thresholds.png_warn_mb)
    p.add_argument("--max-heic-mb", type=float, default=Thresholds.heic_warn_mb)
    p.add_argument(
        "--xcstrings-coverage-min",
        type=float,
        default=Thresholds.xcstrings_coverage_min,
        help="Minimum per-locale coverage ratio (default: 0.95)",
    )
    return p


def _resolve_root(resources_path: Path, explicit_root: str | None) -> Path:
    if explicit_root:
        return Path(explicit_root).resolve()
    # Assume repo root is the parent of Resources/ if the resources path is named
    # "Resources"; otherwise use cwd.
    candidate = resources_path.resolve().parent
    return candidate


def main(argv: list[str] | None = None) -> int:
    parser = build_argparser()
    args = parser.parse_args(argv)

    resources_path = Path(args.resources).resolve()
    root = _resolve_root(resources_path, args.root)

    thresholds = Thresholds(
        usdz_warn_mb=args.max_usdz_mb,
        usdz_fail_mb=args.fail_usdz_mb,
        png_warn_mb=args.max_png_mb,
        heic_warn_mb=args.max_heic_mb,
        xcstrings_coverage_min=args.xcstrings_coverage_min,
    )

    validator = Validator(root=root, resources_dir=resources_path, thresholds=thresholds)
    validator.run()
    findings = validator.findings

    use_color = (
        not args.no_color
        and args.format == "text"
        and sys.stdout.isatty()
        and os.environ.get("NO_COLOR") is None
    )

    if args.format == "json":
        sys.stdout.write(format_json(findings) + "\n")
    elif args.format == "markdown":
        sys.stdout.write(format_markdown(findings))
    else:
        sys.stdout.write(format_text(findings, use_color) + "\n")

    if args.report and args.format != "markdown":
        sys.stdout.write("\n")
        sys.stdout.write(format_markdown(findings))

    counts = summary_counts(findings)
    if counts["FAIL"] > 0:
        return 1
    if counts["WARN"] > 0:
        return 1 if args.strict else 2
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
