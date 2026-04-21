#!/bin/bash
# ==========================================================================
# SDG-Lab architectural compliance lint.
#
# Enforces AGENTS.md §1 ("屎山禁止") rules the Swift compiler can't catch:
#   * SDGCore / SDGGameplay must not pull in UI or rendering frameworks.
#   * No `static let shared` singletons (one stateless exception whitelisted).
#   * No *Fixer / *Patch / *Workaround filenames (屎山 red flag from prior
#     Unity project; see ADR 0001 §Context).
#
# Called by .github/workflows/ci.yml (lint job) AND runnable locally:
#     bash ci_scripts/arch_lint.sh
#
# Exits non-zero on the first violation and prints the offending file(s).
# ==========================================================================
set -euo pipefail

# Resolve repo root from this script's location so it runs from anywhere.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$REPO_ROOT"

echo "== SDG-Lab architectural lint =="
echo "repo root: $REPO_ROOT"

fail=0

# ---------------------------------------------------------------------------
# 1. SDGCore must not import SwiftUI or RealityKit.
#    (Pure domain layer. UI frameworks are SDGUI's job.)
# ---------------------------------------------------------------------------
if grep -rnE '^\s*import\s+(SwiftUI|RealityKit)\b' \
     Packages/SDGCore/Sources/ 2>/dev/null; then
    echo "FAIL: SDGCore imports forbidden UI / rendering framework."
    fail=1
fi

# ---------------------------------------------------------------------------
# 2. SDGGameplay must not import SwiftUI.
#    RealityKit is allowed here (ECS Components / Systems live here).
# ---------------------------------------------------------------------------
if grep -rnE '^\s*import\s+SwiftUI\b' \
     Packages/SDGGameplay/Sources/ 2>/dev/null; then
    echo "FAIL: SDGGameplay imports SwiftUI (Views belong to SDGUI)."
    fail=1
fi

# ---------------------------------------------------------------------------
# 3. No singletons. (ADR 0001, AGENTS.md Rule 2.)
#    Whitelist: LocalizationService is the one permitted *stateless* service.
# ---------------------------------------------------------------------------
SINGLETONS=$(grep -rnE 'static\s+let\s+shared\b' \
    Packages/SDGCore/Sources/ \
    Packages/SDGGameplay/Sources/ \
    Packages/SDGUI/Sources/ \
    Packages/SDGPlatform/Sources/ 2>/dev/null \
    | grep -v 'LocalizationService' || true)
if [ -n "$SINGLETONS" ]; then
    echo "FAIL: singleton pattern detected (AGENTS.md Rule 2):"
    echo "$SINGLETONS"
    fail=1
fi

# ---------------------------------------------------------------------------
# 4. No banned filename suffixes. (AGENTS.md Rule 4.)
#    Use /usr/bin/find explicitly so macOS + Linux behave identically and
#    any `fd`/`bfind` aliases on the runner don't shadow us.
# ---------------------------------------------------------------------------
if /usr/bin/find Packages -type f \
     \( -name "*Fixer.swift" \
        -o -name "*Patch.swift" \
        -o -name "*Workaround.swift" \) \
     2>/dev/null | grep -q . ; then
    echo "FAIL: banned filename pattern found (Fixer/Patch/Workaround)."
    /usr/bin/find Packages -type f \
        \( -name "*Fixer.swift" \
           -o -name "*Patch.swift" \
           -o -name "*Workaround.swift" \)
    fail=1
fi

if [ "$fail" -ne 0 ]; then
    echo "== arch_lint FAILED =="
    exit 1
fi

echo "== arch_lint OK: all architectural checks passed =="
