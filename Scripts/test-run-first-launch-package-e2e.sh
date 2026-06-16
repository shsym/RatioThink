#!/bin/bash
#
# Fast, non-GUI preflight regressions for run-first-launch-package-e2e.sh. Stubs
# xcodebuild and the package/build steps to assert the wrapper's TCC preflight
# ordering and artifact-env handoff without a seated session. Runs in
# `make test-gui-script`.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="$ROOT/Scripts/run-first-launch-package-e2e.sh"
MAKEFILE="$ROOT/Makefile"
CONFIG_FILE="/tmp/pie-first-launch-package-e2e.env"
TEST_ARTIFACT_ROOT="$ROOT/.build/artifacts/test-first-launch-package-e2e"
rm -rf "$TEST_ARTIFACT_ROOT"
trap 'rm -rf "$TEST_ARTIFACT_ROOT"' EXIT

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
  if grep -F "PIE_TEST_TCC_GRANTED=1 Scripts/run-first-launch-package-e2e.sh" "$MAKEFILE" >/dev/null; then
    echo "FAIL: make test-gui-first-launch-package must not inject PIE_TEST_TCC_GRANTED=1; the caller must attest TCC readiness" >&2
    exit 1
  fi
}

test_default_requires_tcc_before_packaging() {
  local tmp
  tmp="$(mktemp -d)"
  trap 'rm -rf "$tmp"' RETURN

  mkdir -p "$tmp/bin"
  cat >"$tmp/bin/pgrep" <<'FAKE_PGREP'
#!/bin/bash
exit 0
FAKE_PGREP
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
  if [[ "$output" == *"generating Xcode project"* || "$output" == *"packaging Release app"* ]]; then
    echo "FAIL: default E2E must check TCC before package/build work" >&2
    exit 1
  fi
}

test_init_only_writes_separate_probe_handoff_without_tcc() {
  local tmp
  tmp="$(mktemp -d)"
  trap 'rm -rf "$tmp"' RETURN

  cat >"$tmp/genproject" <<'FAKE_GENPROJECT'
#!/bin/bash
exit 0
FAKE_GENPROJECT
  cat >"$tmp/package-dmg" <<'FAKE_PACKAGE'
#!/bin/bash
set -euo pipefail
while [[ $# -gt 0 ]]; do
  case "$1" in
    --out) out="$2"; shift 2 ;;
    --arch) arch="$2"; shift 2 ;;
    *) shift ;;
  esac
done
mkdir -p "$PWD/build/xcode-${arch:-arm64}/sym/Rational.app" "$out"
: >"$out/Rational-${arch:-arm64}.dmg"
FAKE_PACKAGE
  chmod +x "$tmp/package-dmg" "$tmp/genproject"

  PIE_TEST_GENPROJECT_BIN="$tmp/genproject" \
  PIE_TEST_PACKAGE_DMG_BIN="$tmp/package-dmg" \
  PIE_TEST_RUN_ROOT="$tmp/run" \
  ARCH=arm64 \
  "$SCRIPT" --init-only >/dev/null

  local artifact_env="$tmp/run/artifact.env"
  if [[ ! -f "$artifact_env" ]]; then
    echo "FAIL: expected artifact handoff at $artifact_env" >&2
    exit 1
  fi
  local handoff
  handoff="$(cat "$artifact_env")"
  require_contains "$handoff" "PIE_TEST_APP_PATH=$ROOT/build/xcode-arm64/sym/Rational.app"
  require_contains "$handoff" "PIE_TEST_DMG_PATH=$tmp/run/package/Rational-arm64.dmg"
  require_contains "$handoff" "PIE_TEST_FAKE_DOWNLOADS=1"
  require_contains "$handoff" "PIE_TEST_LOGIN_ITEM_STATUS=notRegistered"
  require_contains "$handoff" "PIE_TEST_INITIAL_ARTIFACT_PATH_PROBE_FILE=$tmp/run/launched-app-path-initial.txt"
  require_contains "$handoff" "PIE_TEST_RELAUNCH_ARTIFACT_PATH_PROBE_FILE=$tmp/run/launched-app-path-relaunch.txt"
  if [[ "$handoff" == *"PIE_TEST_ARTIFACT_PATH_PROBE_FILE="* ]]; then
    echo "FAIL: handoff must use separate initial/relaunch probe paths, not the legacy single probe" >&2
    exit 1
  fi
}

test_scenario_success_removes_config_preferences_probes_and_safe_run_root() {
  local run_root
  run_root="$(mktemp -d /tmp/p175-first-launch-success.XXXXXX)"
  trap 'rm -rf "$run_root"' RETURN

  local app_path="$run_root/Rational.app"
  local export_root="$TEST_ARTIFACT_ROOT/success"
  local initial_probe="$run_root/launched-app-path-initial.txt"
  local relaunch_probe="$run_root/launched-app-path-relaunch.txt"
  local defaults_log
  defaults_log="$(mktemp)"
  trap 'rm -rf "$run_root"; rm -f "$defaults_log"' RETURN
  rm -rf "$export_root"
  mkdir -p "$run_root/bin" "$app_path" "$run_root/gui-home"
  cat >"$run_root/bin/pgrep" <<'FAKE_PGREP'
#!/bin/bash
exit 0
FAKE_PGREP
  cat >"$run_root/bin/xcodebuild" <<FAKE_XCODEBUILD
#!/bin/bash
printf '%s\n' "$app_path" >"$initial_probe"
printf '%s\n' "$app_path" >"$relaunch_probe"
exit 0
FAKE_XCODEBUILD
  cat >"$run_root/bin/defaults" <<FAKE_DEFAULTS
#!/bin/bash
echo "\$@" >>"$defaults_log"
exit 0
FAKE_DEFAULTS
  chmod +x "$run_root/bin/pgrep" "$run_root/bin/xcodebuild" "$run_root/bin/defaults"

  cat >"$run_root/artifact.env" <<EOF_ENV
PIE_TEST_APP_PATH=$app_path
PIE_TEST_DMG_PATH=$run_root/Rational-arm64.dmg
PIE_TEST_RUN_ROOT=$run_root
PIE_TEST_GUI_HOME=$run_root/gui-home
PIE_APP_PREFERENCES_SUITE=com.ratiothink.app.gui.s7.testcleanup
PIE_TEST_LOGIN_ITEM_STATUS=notRegistered
PIE_TEST_FAKE_DOWNLOADS=1
PIE_TEST_INITIAL_ARTIFACT_PATH_PROBE_FILE=$initial_probe
PIE_TEST_RELAUNCH_ARTIFACT_PATH_PROBE_FILE=$relaunch_probe
EOF_ENV

  PATH="$run_root/bin:$PATH" \
  PIE_TEST_TCC_GRANTED=1 \
  PIE_TEST_HUMAN_ARTIFACT_ROOT="$export_root" \
  PIE_TEST_EXPORT_RUN_ID=success-run \
  "$SCRIPT" --scenario-only "$run_root/artifact.env" >/dev/null

  if [[ -f "$CONFIG_FILE" ]]; then
    echo "FAIL: expected fixed XCUITest config $CONFIG_FILE to be removed during cleanup" >&2
    exit 1
  fi
  require_contains "$(cat "$defaults_log")" "delete com.ratiothink.app.gui.s7.testcleanup"
  if [[ -e "$run_root" ]]; then
    echo "FAIL: expected safe transient run root to be removed on success: $run_root" >&2
    find "$run_root" -maxdepth 2 -print >&2 || true
    exit 1
  fi
  if [[ ! -f "$export_root/latest/Rational.app.zip" ]]; then
    echo "FAIL: expected human-testable app artifact zip at $export_root/latest/Rational.app.zip" >&2
    exit 1
  fi
  if [[ ! -f "$export_root/latest/Rational.app.zip.sha256" ]]; then
    echo "FAIL: expected checksum next to latest human-testable app artifact" >&2
    exit 1
  fi
  if [[ ! -f "$export_root/latest/manifest.json" ]]; then
    echo "FAIL: expected latest artifact manifest" >&2
    exit 1
  fi
  python3 - "$export_root/latest/manifest.json" "$export_root" "$app_path" <<'PY'
import json
import os
import sys

manifest_path, export_root, app_path = sys.argv[1:]
with open(manifest_path, "r", encoding="utf-8") as fh:
    manifest = json.load(fh)
assert manifest["schema_version"] == 1
assert manifest["artifact_kind"] == "macos_app_zip"
assert manifest["check"] == "first-launch-package-e2e"
assert manifest["run_id"] == "success-run"
assert manifest["app"]["name"] == "Rational.app"
assert manifest["app"]["source_path"] == app_path
assert manifest["verification"]["passed"] is True
assert manifest["verification"]["artifact_path_assertions"] == "initial and relaunch probes matched PIE_TEST_APP_PATH"
assert manifest["verification"]["relaunch_persistence_assertion"] == "passed"
assert manifest["artifact"]["latest_zip_path"] == os.path.join(export_root, "latest", "Rational.app.zip")
assert len(manifest["artifact"]["sha256"]) == 64
PY
  (cd "$export_root/latest" && shasum -a 256 -c Rational.app.zip.sha256 >/dev/null)
}

test_scenario_failure_preserves_run_root_but_cleans_external_state() {
  local run_root
  run_root="$(mktemp -d /tmp/p175-first-launch-failure.XXXXXX)"
  trap 'rm -rf "$run_root"' RETURN

  local app_path="$run_root/Rational.app"
  local defaults_log
  defaults_log="$(mktemp)"
  trap 'rm -rf "$run_root"; rm -f "$defaults_log"' RETURN
  mkdir -p "$run_root/bin" "$app_path" "$run_root/gui-home"
  cat >"$run_root/bin/pgrep" <<'FAKE_PGREP'
#!/bin/bash
exit 0
FAKE_PGREP
  cat >"$run_root/bin/xcodebuild" <<'FAKE_XCODEBUILD'
#!/bin/bash
echo "simulated xcodebuild failure" >&2
exit 42
FAKE_XCODEBUILD
  cat >"$run_root/bin/defaults" <<FAKE_DEFAULTS
#!/bin/bash
echo "\$@" >>"$defaults_log"
exit 0
FAKE_DEFAULTS
  chmod +x "$run_root/bin/pgrep" "$run_root/bin/xcodebuild" "$run_root/bin/defaults"

  cat >"$run_root/artifact.env" <<EOF_ENV
PIE_TEST_APP_PATH=$app_path
PIE_TEST_DMG_PATH=$run_root/Rational-arm64.dmg
PIE_TEST_RUN_ROOT=$run_root
PIE_TEST_GUI_HOME=$run_root/gui-home
PIE_APP_PREFERENCES_SUITE=com.ratiothink.app.gui.s7.testfailure
PIE_TEST_LOGIN_ITEM_STATUS=notRegistered
PIE_TEST_FAKE_DOWNLOADS=1
PIE_TEST_INITIAL_ARTIFACT_PATH_PROBE_FILE=$run_root/launched-app-path-initial.txt
PIE_TEST_RELAUNCH_ARTIFACT_PATH_PROBE_FILE=$run_root/launched-app-path-relaunch.txt
EOF_ENV

  set +e
  local output
  output="$(PATH="$run_root/bin:$PATH" PIE_TEST_TCC_GRANTED=1 "$SCRIPT" --scenario-only "$run_root/artifact.env" 2>&1)"
  local status=$?
  set -e

  if [[ "$status" -ne 42 ]]; then
    echo "FAIL: expected xcodebuild status 42 to propagate, got $status" >&2
    printf '%s\n' "$output" >&2
    exit 1
  fi
  require_contains "$output" "preserving run root: $run_root"
  if [[ -f "$CONFIG_FILE" ]]; then
    echo "FAIL: expected fixed XCUITest config $CONFIG_FILE to be removed on failure" >&2
    exit 1
  fi
  require_contains "$(cat "$defaults_log")" "delete com.ratiothink.app.gui.s7.testfailure"
  if [[ ! -d "$run_root" ]]; then
    echo "FAIL: expected failed run root to be preserved: $run_root" >&2
    exit 1
  fi
  if [[ -e "$TEST_ARTIFACT_ROOT/failure/latest/Rational.app.zip" ]]; then
    echo "FAIL: failed scenario must not export a human-testable app artifact" >&2
    exit 1
  fi
}

test_scenario_latest_update_and_retention() {
  local export_root="$TEST_ARTIFACT_ROOT/latest-retention"
  rm -rf "$export_root"

  local run_ids=(retention-run-1 retention-run-2 retention-run-3 retention-run-4)
  for run_id in "${run_ids[@]}"; do
    local run_root
    run_root="$(mktemp -d /tmp/p175-first-launch-retention.XXXXXX)"
    local app_path="$run_root/Rational.app"
    mkdir -p "$run_root/bin" "$app_path" "$run_root/gui-home"
    cat >"$run_root/bin/pgrep" <<'FAKE_PGREP'
#!/bin/bash
exit 0
FAKE_PGREP
    cat >"$run_root/bin/xcodebuild" <<FAKE_XCODEBUILD
#!/bin/bash
printf '%s\n' "$app_path" >"$run_root/launched-app-path-initial.txt"
printf '%s\n' "$app_path" >"$run_root/launched-app-path-relaunch.txt"
exit 0
FAKE_XCODEBUILD
    cat >"$run_root/bin/defaults" <<'FAKE_DEFAULTS'
#!/bin/bash
exit 0
FAKE_DEFAULTS
    chmod +x "$run_root/bin/pgrep" "$run_root/bin/xcodebuild" "$run_root/bin/defaults"
    cat >"$run_root/artifact.env" <<EOF_ENV
PIE_TEST_APP_PATH=$app_path
PIE_TEST_DMG_PATH=$run_root/Rational-arm64.dmg
PIE_TEST_RUN_ROOT=$run_root
PIE_TEST_GUI_HOME=$run_root/gui-home
PIE_APP_PREFERENCES_SUITE=com.ratiothink.app.gui.s7.$run_id
PIE_TEST_LOGIN_ITEM_STATUS=notRegistered
PIE_TEST_FAKE_DOWNLOADS=1
PIE_TEST_INITIAL_ARTIFACT_PATH_PROBE_FILE=$run_root/launched-app-path-initial.txt
PIE_TEST_RELAUNCH_ARTIFACT_PATH_PROBE_FILE=$run_root/launched-app-path-relaunch.txt
PIE_TEST_ARCH=arm64
EOF_ENV
    PATH="$run_root/bin:$PATH" \
    PIE_TEST_TCC_GRANTED=1 \
    PIE_TEST_HUMAN_ARTIFACT_ROOT="$export_root" \
    PIE_TEST_EXPORT_RUN_ID="$run_id" \
    PIE_TEST_HUMAN_ARTIFACT_KEEP=3 \
    "$SCRIPT" --scenario-only "$run_root/artifact.env" >/dev/null
  done

  python3 - "$export_root/latest.json" "$export_root/latest/manifest.json" <<'PY'
import json
import sys

latest_path, manifest_path = sys.argv[1:]
with open(latest_path, "r", encoding="utf-8") as fh:
    latest = json.load(fh)
with open(manifest_path, "r", encoding="utf-8") as fh:
    manifest = json.load(fh)
assert latest["run_id"] == "retention-run-4"
assert latest["latest_zip_path"].endswith("/latest/Rational.app.zip")
assert manifest["run_id"] == "retention-run-4"
PY
  if [[ -d "$export_root/runs/retention-run-1" ]]; then
    echo "FAIL: expected retention to prune oldest immutable run" >&2
    exit 1
  fi
  for run_id in retention-run-2 retention-run-3 retention-run-4; do
    if [[ ! -f "$export_root/runs/$run_id/Rational.app.zip" ]]; then
      echo "FAIL: expected retained run artifact for $run_id" >&2
      exit 1
    fi
  done
}

test_make_target_does_not_inject_tcc_attestation
test_default_requires_tcc_before_packaging
test_init_only_writes_separate_probe_handoff_without_tcc
test_scenario_success_removes_config_preferences_probes_and_safe_run_root
test_scenario_failure_preserves_run_root_but_cleans_external_state
test_scenario_latest_update_and_retention
echo "test-run-first-launch-package-e2e: PASS"
