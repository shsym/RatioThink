#!/usr/bin/env bash
# Verify the committed docs/landing web icons (favicon + landing hero) match the
# locked manifest. They are derived from the app-icon master by
# Scripts/generate-docs-icons.py; this cheap, dependency-free guard catches any
# committed-byte drift in CI. Scripts/test-verify-docs-icons.sh additionally
# proves the generator still reproduces these bytes from the master.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MANIFEST="$ROOT/Scripts/docs-icons.sha256"

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

require_file() {
  local path="$1"
  [[ -f "$path" ]] || fail "missing file: ${path#$ROOT/}"
}

require_file "$MANIFEST"
for asset in \
  docs/assets/pie-icon.png \
  docs/assets/apple-touch-icon.png \
  docs/favicon.ico; do
  require_file "$ROOT/$asset"
done

(
  cd "$ROOT"
  shasum -a 256 -c "${MANIFEST#$ROOT/}" >/dev/null
) || fail "docs web icon hashes do not match Scripts/docs-icons.sha256 (regenerate with Scripts/generate-docs-icons.py and re-lock the manifest)"

echo "Docs web icons verified"
