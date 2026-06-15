#!/usr/bin/env bash
#
# Static contract test guarding run-http-e2e.sh's stale-engine rebuild logic:
# asserts the wrapper declares a pie commit stamp, compares it against the live
# Vendor/pie HEAD, explains stale rebuilds, and records the HEAD after rebuild —
# so a pin bump can never silently run a stale engine. Source-only; no engine.
#
# Usage: Scripts/test-run-http-e2e-stale-pie.sh
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SCRIPT="$ROOT/Scripts/run-http-e2e.sh"

if ! grep -q 'PIE_STAMP=' "$SCRIPT"; then
  echo "FAIL: run-http-e2e.sh does not declare a pie engine commit stamp" >&2
  exit 1
fi
if ! grep -q 'rev-parse HEAD' "$SCRIPT"; then
  echo "FAIL: run-http-e2e.sh does not compare against the current Vendor/pie HEAD" >&2
  exit 1
fi
if ! grep -q 'pie engine binary stale' "$SCRIPT"; then
  echo "FAIL: run-http-e2e.sh does not explain stale engine rebuilds" >&2
  exit 1
fi
if ! grep -q 'printf.*current_pie_sha' "$SCRIPT"; then
  echo "FAIL: run-http-e2e.sh does not record the Vendor/pie HEAD after rebuild" >&2
  exit 1
fi

echo "test-run-http-e2e-stale-pie: ok"
