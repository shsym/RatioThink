#!/bin/bash
set -euo pipefail

# Fast, non-GUI preflight regressions for the #379 packaged first-launch
# model-download GUI E2E wrapper + suite. Runs in make test-gui-script without
# a seated session.

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="$ROOT/Scripts/run-first-launch-package-model-download-e2e.sh"
SUITE="$ROOT/Tests/GUIScenarioTests/S7_FirstLaunchWizardPackagedModelDownloadGUITests.swift"
MAKEFILE="$ROOT/Makefile"

require_contains() {
  local haystack="$1"
  local needle="$2"
  if [[ "$haystack" != *"$needle"* ]]; then
    echo "FAIL: expected output to contain: $needle" >&2
    echo "--- output ---" >&2
    printf '%s\n' "$haystack" >&2
    exit 1
  fi
}

test_make_target_does_not_inject_tcc_attestation() {
  if grep -F "PIE_TEST_TCC_GRANTED=1 Scripts/run-first-launch-package-model-download-e2e.sh" "$MAKEFILE" >/dev/null; then
    echo "FAIL: the make target must not inject PIE_TEST_TCC_GRANTED=1; the caller must attest TCC readiness" >&2
    exit 1
  fi
}

test_default_requires_tcc_before_packaging() {
  local tmp
  tmp="$(mktemp -d)"
  trap 'rm -rf "$tmp"' RETURN

  mkdir -p "$tmp/bin"
  # Dock "present" so the seated-GUI gate passes and we reach the TCC gate.
  cat >"$tmp/bin/pgrep" <<'FAKE_PGREP'
#!/bin/bash
exit 0
FAKE_PGREP
  # Any package/build invocation here is a contract violation (TCC must gate
  # first) — make it loud.
  cat >"$tmp/bin/xcodebuild" <<'FAKE_XCODEBUILD'
#!/bin/bash
echo "unexpected xcodebuild" >&2
exit 99
FAKE_XCODEBUILD
  chmod +x "$tmp/bin/pgrep" "$tmp/bin/xcodebuild"

  set +e
  local output
  output="$(
    PATH="$tmp/bin:$PATH" \
    PIE_TEST_TCC_GRANTED= \
    PIE_TEST_RUN_ROOT="$tmp/run" \
    "$SCRIPT" 2>&1
  )"
  local status=$?
  set -e

  if [[ "$status" -ne 2 ]]; then
    echo "FAIL: expected missing TCC preflight to exit 2, got $status" >&2
    echo "--- output ---" >&2
    printf '%s\n' "$output" >&2
    exit 1
  fi
  require_contains "$output" "Automation/Accessibility permission required"
  require_contains "$output" "PIE_TEST_TCC_GRANTED=1"
  if [[ "$output" == *"generating Xcode project"* || "$output" == *"packaging"* ]]; then
    echo "FAIL: the E2E must check TCC before any package/build work" >&2
    exit 1
  fi
}

# F1 regression guard: the chat must resolve the persisted default through the
# Load-default gate, NOT a PIE_TEST_CHAT_MODEL env injection (which the request
# model resolver returns with top precedence, making the assertion circular).
test_resolves_via_load_default_not_chat_model_injection() {
  # Match the injection syntax (`PIE_TEST_CHAT_MODEL=` in the config heredoc or
  # `["PIE_TEST_CHAT_MODEL"]` in launchEnvironment), not prose mentions. Also
  # catch the sibling `PIE_TEST_CHAT_MODEL_PIN` seam (ChatCreation.swift) — its
  # _PIN suffix would pin chat.modelID and re-introduce the v1-F1 circularity.
  if grep -Eq 'PIE_TEST_CHAT_MODEL(_PIN)?(=|"\])' "$SCRIPT" "$SUITE"; then
    echo "FAIL: PIE_TEST_CHAT_MODEL[_PIN] must not be injected — the chat must resolve the persisted default via the Load-default gate (#379 F1)" >&2
    grep -EnH 'PIE_TEST_CHAT_MODEL(_PIN)?(=|"\])' "$SCRIPT" "$SUITE" >&2 || true
    exit 1
  fi
  for needle in "PIE_TEST_ENGINE_START_TO_RUNNING" "noModel.load"; do
    if ! grep -q "$needle" "$SUITE"; then
      echo "FAIL: the suite must drive the Load-default path (missing $needle)" >&2
      exit 1
    fi
  done
}

test_make_target_does_not_inject_tcc_attestation
test_default_requires_tcc_before_packaging
test_resolves_via_load_default_not_chat_model_injection

echo "test-run-first-launch-package-model-download-e2e: PASS"
