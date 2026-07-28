#!/usr/bin/env bash
# Vendor the Diane OpenAPI spec into DianeKit (the single committed copy the
# generator plugin reads). The spec is GENERATED in diane-server — never edit
# it here; contract drift is caught by the build, loudly.
#
#   scripts/update-spec.sh                 copy from the sibling ../diane-server checkout
#   scripts/update-spec.sh <url>           curl a released openapi.yaml (api-vX.Y.Z asset)
set -euo pipefail

cd "$(dirname "$0")/.."
DEST=DianeKit/Sources/DianeKit/openapi.yaml

if [[ $# -eq 0 ]]; then
  SRC=../diane-server/packages/contracts/openapi/openapi.yaml
  [[ -f "$SRC" ]] || { echo "not found: $SRC (clone diane-server next to diane-ios, or pass a URL)"; exit 1; }
  cp "$SRC" "$DEST"
  echo "vendored from local diane-server ($(git -C ../diane-server rev-parse --short HEAD 2>/dev/null || echo 'no git'))"
elif [[ $1 == http* ]]; then
  curl -fsSL "$1" -o "$DEST"
  echo "vendored from $1"
else
  echo "release-tag fetch needs the GitHub release pipeline; pass the asset URL directly for now"
  exit 1
fi

grep -m1 "openapi:" "$DEST"
