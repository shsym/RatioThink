#!/bin/bash
#
# Contract self-test for run-ticket326-e2e.sh's PIE_BIN resolution ladder
# (#338). Guards the bash-3.2 pipefail-abort class (#545 review v2 F1/F2): the
# xcodebuild|awk and find|...|cut command substitutions must NOT abort the
# script under `set -euo pipefail` when their inputs are missing/failing — they
# must fall through to the next resolution rung (ultimately the installed
# /Applications/Rational.app, else the "pie engine binary not found" exit 2).
#
# Runs under the SAME /bin/bash the wrapper uses (macOS 3.2, where
# `var="$(failing-pipeline)"` aborts under set -e + pipefail).
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="$ROOT/Scripts/run-ticket326-e2e.sh"
fail=0

# 1) STRUCTURAL pin (drift-proof): both substitutions must carry the `|| true`
#    guard. Dropping either re-introduces the pipefail abort.
if ! grep -Eq "BUILT_PRODUCTS_DIR.*\|\| true\)\"|awk -F' = '.*\|\| true\)\"" "$SCRIPT"; then
  echo "FAIL: xcodebuild|awk products_dir substitution missing '|| true' guard in $SCRIPT" >&2
  fail=1
fi
if ! grep -Eq "cut -d' ' -f2- \|\| true\)\"" "$SCRIPT"; then
  echo "FAIL: find|...|cut PIE_BIN substitution missing '|| true' guard in $SCRIPT" >&2
  fail=1
fi

# 2) BEHAVIORAL repro: the exact pipeline shapes must survive a missing root /
#    failing first stage under set -euo pipefail (the live-run failure mode).
missing="$(mktemp -d)/does-not-exist"

if ! out="$(set -euo pipefail
  derived_base="$missing"
  PIE_BIN="$(find "$derived_base" \
    -path '*RatioThink*/Build/Products/Debug/Rational.app/Contents/Resources/pie-engine/pie' \
    -type f 2>/dev/null | xargs -I{} stat -f '%m %N' {} 2>/dev/null | sort -rn | head -1 | cut -d' ' -f2- || true)"
  echo "reached-fallthrough PIE_BIN=[$PIE_BIN]")"; then
  echo "FAIL: find-based resolution aborted under set -euo pipefail on a missing derived_base" >&2
  fail=1
elif [ "$out" != "reached-fallthrough PIE_BIN=[]" ]; then
  echo "FAIL: find-based resolution did not fall through cleanly: $out" >&2
  fail=1
fi

if ! out="$(set -euo pipefail
  products_dir="$(false | awk -F' = ' '/ BUILT_PRODUCTS_DIR = /{print $2; exit}' || true)"
  echo "reached-fallthrough products_dir=[$products_dir]")"; then
  echo "FAIL: xcodebuild|awk resolution aborted under set -euo pipefail on a non-zero first stage" >&2
  fail=1
elif [ "$out" != "reached-fallthrough products_dir=[]" ]; then
  echo "FAIL: xcodebuild|awk resolution did not fall through cleanly: $out" >&2
  fail=1
fi

if [ "$fail" -eq 0 ]; then
  echo "test-run-ticket326-resolve: PASS"
else
  echo "test-run-ticket326-resolve: FAIL"
  exit 1
fi
