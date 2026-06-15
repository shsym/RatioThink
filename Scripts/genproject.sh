#!/usr/bin/env bash
#
# Regenerate RatioThink.xcodeproj from project.yml via xcodegen, failing with an
# install hint if xcodegen is absent.
#
# Usage: Scripts/genproject.sh
set -euo pipefail
cd "$(dirname "$0")/.."

if ! command -v xcodegen >/dev/null 2>&1; then
  echo "xcodegen not found. Install with: brew install xcodegen" >&2
  exit 1
fi

xcodegen generate
echo "Generated RatioThink.xcodeproj"
