#!/usr/bin/env bash
# Regenerate Diane.xcodeproj from project.yml (the committed source of truth).
set -euo pipefail
cd "$(dirname "$0")/.."
xcodegen generate
