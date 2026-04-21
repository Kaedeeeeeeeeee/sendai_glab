#!/bin/bash
# ==========================================================================
# Xcode Cloud: ci_post_clone.sh
#
# Runs in the Xcode Cloud workflow right after the repo is cloned,
# BEFORE dependency resolution and xcodebuild.
#
# Phase 0 placeholder. Populated in Phase 3 when Xcode Cloud goes live.
# Planned content:
#   * brew install xcodegen
#   * xcodegen generate
#   * (optionally) brew install plateau-gis-converter for asset checks
# ==========================================================================
set -euo pipefail

echo "ci_post_clone: SDG-Lab (placeholder, Phase 0)"
# Intentionally empty; real setup arrives in Phase 3 per GDD.md §4.3.
