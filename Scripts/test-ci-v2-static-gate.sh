#!/usr/bin/env bash
# Regression guard for ticket #456: the CI-v2 GitHub workflow stays
# manual/on-demand and lightweight/static, while every removed heavyweight/
# runtime suite remains reachable through named local make tiers.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

pass=0
fail=0

ok() {
  echo "ok: $*"
  pass=$((pass + 1))
}

not_ok() {
  echo "FAIL: $*" >&2
  fail=$((fail + 1))
}

assert_grep() {
  local pattern="$1" file="$2" label="$3"
  if grep -Eq -- "$pattern" "$file"; then
    ok "$label"
  else
    not_ok "$label (missing pattern: $pattern in $file)"
  fi
}

assert_no_grep() {
  local pattern="$1" file="$2" label="$3"
  if grep -Eq -- "$pattern" "$file"; then
    not_ok "$label (unexpected pattern: $pattern in $file)"
  else
    ok "$label"
  fi
}

# Make tiers: local `make ci-pr` is the normal deterministic merge-evidence
# aggregate; local/release gates keep parity for dynamic coverage kept out of
# the manual GitHub workflow.
assert_grep '^ci-pr: ' Makefile "Makefile exposes ci-pr aggregate"
assert_grep '^local-pre-merge: ' Makefile "Makefile exposes local-pre-merge aggregate"
assert_grep '^release-gate: ' Makefile "Makefile exposes release-gate aggregate"
assert_grep '^local-gui-gate: ' Makefile "Makefile exposes local-gui-gate aggregate"
assert_grep '^local-e2e-gate: ' Makefile "Makefile exposes local-e2e-gate aggregate"
assert_grep '^build-static: ' Makefile "Makefile exposes compile-only build-static target"

# Manual GitHub workflow delegates to ci-pr and avoids the known heavyweight/
# runtime jobs that made the old automatic gate slow or flaky.
assert_grep 'workflow_dispatch:' .github/workflows/lint.yml "lint workflow is manually dispatchable"
assert_no_grep '^[[:space:]]*push:' .github/workflows/lint.yml "lint workflow does not run automatically on push"
assert_no_grep '^[[:space:]]*pull_request:' .github/workflows/lint.yml "lint workflow does not run automatically on pull_request"
assert_grep 'run: make ci-pr' .github/workflows/lint.yml "manual workflow uses ci-pr aggregate"
assert_grep '^ci-pr: .*test-release' Makefile "release script contract tests stay in ci-pr aggregate"
assert_no_grep '^  real-pie-driver-contract:' .github/workflows/lint.yml "real pie binary contract kept out of manual lightweight workflow"
assert_no_grep '^  gmake-sanity-fail-injection:' .github/workflows/lint.yml "gmake 4.x canary kept out of manual lightweight workflow"
assert_no_grep '^  release-scripts:' .github/workflows/lint.yml "release script contracts are folded into ci-pr, not a separate heavy job"
assert_no_grep 'run: make build-tests' .github/workflows/lint.yml "manual lightweight workflow does not build every xcodebuild test bundle"
assert_no_grep 'run: make build-inferlets' .github/workflows/lint.yml "manual lightweight workflow does not rebuild wasm inferlets"
assert_grep 'run: make verify-inferlets' .github/workflows/lint.yml "cheap inferlet stamp provenance remains available in manual workflow"

# The Xcode compile target must be able to type-check/package the app without
# building the Rust engine long pole. Exercise the build-phase entrypoint in
# skip mode with no cargo dependency.
static_out="$(mktemp)"
if PIE_SKIP_ENGINE_BUILD=1 ARCHS=arm64 SRCROOT="$ROOT" BUILT_PRODUCTS_DIR="$(mktemp -d)" UNLOCALIZED_RESOURCES_FOLDER_PATH=RatioThink.app/Contents/Resources ./Scripts/build-pie-engine.sh >"$static_out" 2>&1; then
  if grep -q 'PIE_SKIP_ENGINE_BUILD=1' "$static_out"; then
    ok "build-pie-engine supports explicit static-build skip mode"
  else
    not_ok "build-pie-engine skip mode did not print an auditable skip reason"
  fi
else
  cat "$static_out" >&2
  not_ok "build-pie-engine skip mode should exit 0 without invoking cargo"
fi
rm -f "$static_out"

if [[ "$fail" -ne 0 ]]; then
  echo "ci-v2-static-gate: $pass passed, $fail failed" >&2
  exit 1
fi

echo "ci-v2-static-gate: $pass passed, $fail failed"
