#!/bin/bash
#
# First-launch package E2E. Builds/packages a Release Rational.app artifact,
# then launches it by file URL under XCUITest from fresh isolated state to
# verify first-run behavior, and exports a human-testable signed zip. See the
# usage() block below for the full invocation and environment contract.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
source "$ROOT/Scripts/e2e-prep.sh"

CONFIG_FILE="/tmp/pie-first-launch-package-e2e.env"
RUN_ROOT="${PIE_TEST_RUN_ROOT:-/tmp/p175-first-launch-$$}"
ARCH_VALUE="${ARCH:-$(uname -m)}"
ARTIFACT_ENV="$RUN_ROOT/artifact.env"
PACKAGE_OUT="$RUN_ROOT/package"
GUI_HOME="$RUN_ROOT/gui-home"
INITIAL_PROBE_FILE="$RUN_ROOT/launched-app-path-initial.txt"
RELAUNCH_PROBE_FILE="$RUN_ROOT/launched-app-path-relaunch.txt"
GENPROJECT_BIN="${PIE_TEST_GENPROJECT_BIN:-Scripts/genproject.sh}"
PACKAGE_DMG_BIN="${PIE_TEST_PACKAGE_DMG_BIN:-Scripts/package-dmg.sh}"
HUMAN_ARTIFACT_ROOT="${PIE_TEST_HUMAN_ARTIFACT_ROOT:-${PIE_HUMAN_ARTIFACT_ROOT:-$ROOT/.build/artifacts/human-testable/pie-app/-first-launch-package}}"
HUMAN_ARTIFACT_KEEP="${PIE_TEST_HUMAN_ARTIFACT_KEEP:-${PIE_HUMAN_ARTIFACT_KEEP:-3}}"

usage() {
  cat >&2 <<'USAGE'
usage: Scripts/run-first-launch-package-e2e.sh [--init-only|--scenario-only <artifact.env>]

Default runs both phases:
  1. Build/package a Release Rational.app artifact and write <run-root>/artifact.env.
  2. Launch that artifact by file URL in XCUITest from fresh isolated state.

Environment:
  PIE_TEST_RUN_ROOT     run directory; default /tmp/p175-first-launch-$$
  ARCH                  app arch for package/build destination; default uname -m
  PIE_TEST_TCC_GRANTED  must be 1 for default/scenario phase GUI execution
  PIE_HUMAN_ARTIFACT_ROOT or PIE_TEST_HUMAN_ARTIFACT_ROOT
                        stable local export root for the verified app zip;
                        default .build/artifacts/human-testable/pie-app/-first-launch-package
  PIE_HUMAN_ARTIFACT_KEEP or PIE_TEST_HUMAN_ARTIFACT_KEEP
                        number of immutable exported run dirs to retain; default 3
USAGE
}

require_gui_preflight() {
  e2e_require_seated_gui "first-launch package e2e" || exit 2
  e2e_require_tcc "first-launch package e2e" || exit 2
}

write_artifact_env() {
  local app_path="$1"
  local dmg_path="$2"
  local suite="com.ratiothink.app.gui.s7.$(uuidgen | tr '[:upper:]' '[:lower:]')"

  cat >"$ARTIFACT_ENV" <<EOF_ENV
PIE_TEST_APP_PATH=$app_path
PIE_TEST_DMG_PATH=$dmg_path
PIE_TEST_RUN_ROOT=$RUN_ROOT
PIE_TEST_GUI_HOME=$GUI_HOME
PIE_APP_PREFERENCES_SUITE=$suite
PIE_TEST_LOGIN_ITEM_STATUS=notRegistered
PIE_TEST_FAKE_DOWNLOADS=1
PIE_TEST_INITIAL_ARTIFACT_PATH_PROBE_FILE=$INITIAL_PROBE_FILE
PIE_TEST_RELAUNCH_ARTIFACT_PATH_PROBE_FILE=$RELAUNCH_PROBE_FILE
PIE_TEST_ARCH=$ARCH_VALUE
EOF_ENV
}

run_init_phase() {
  mkdir -p "$RUN_ROOT" "$PACKAGE_OUT" "$GUI_HOME"
  rm -f "$ARTIFACT_ENV" "$INITIAL_PROBE_FILE" "$RELAUNCH_PROBE_FILE"

  echo "first-launch package e2e: generating Xcode project"
  "$GENPROJECT_BIN"

  echo "first-launch package e2e: packaging Release app for $ARCH_VALUE"
  "$PACKAGE_DMG_BIN" --arch "$ARCH_VALUE" --configuration Release --out "$PACKAGE_OUT"

  local app_path="$ROOT/build/xcode-$ARCH_VALUE/sym/Rational.app"
  local dmg_path="$PACKAGE_OUT/Rational-$ARCH_VALUE.dmg"
  if [ ! -d "$app_path" ]; then
    echo "first-launch package e2e: packaged app missing at $app_path" >&2
    exit 1
  fi
  if [ ! -f "$dmg_path" ]; then
    echo "first-launch package e2e: DMG missing at $dmg_path" >&2
    exit 1
  fi

  write_artifact_env "$app_path" "$dmg_path"

  echo "first-launch package e2e: artifact env=$ARTIFACT_ENV"
  echo "first-launch package e2e: app artifact=$app_path"
  echo "first-launch package e2e: dmg artifact=$dmg_path"
}

source_artifact_env() {
  local env_file="$1"
  if [ ! -f "$env_file" ]; then
    echo "first-launch package e2e: artifact env missing at $env_file" >&2
    exit 1
  fi
  # shellcheck source=/dev/null
  source "$env_file"

  : "${PIE_TEST_APP_PATH:?artifact env must define PIE_TEST_APP_PATH}"
  : "${PIE_TEST_GUI_HOME:?artifact env must define PIE_TEST_GUI_HOME}"
  : "${PIE_APP_PREFERENCES_SUITE:?artifact env must define PIE_APP_PREFERENCES_SUITE}"
  if [ -z "${PIE_TEST_INITIAL_ARTIFACT_PATH_PROBE_FILE:-}" ] ||
     [ -z "${PIE_TEST_RELAUNCH_ARTIFACT_PATH_PROBE_FILE:-}" ]; then
    if [ -n "${PIE_TEST_ARTIFACT_PATH_PROBE_FILE:-}" ]; then
      local legacy_probe_dir
      legacy_probe_dir="$(dirname "$PIE_TEST_ARTIFACT_PATH_PROBE_FILE")"
      PIE_TEST_INITIAL_ARTIFACT_PATH_PROBE_FILE="$legacy_probe_dir/launched-app-path-initial.txt"
      PIE_TEST_RELAUNCH_ARTIFACT_PATH_PROBE_FILE="$legacy_probe_dir/launched-app-path-relaunch.txt"
    fi
  fi
  : "${PIE_TEST_INITIAL_ARTIFACT_PATH_PROBE_FILE:?artifact env must define PIE_TEST_INITIAL_ARTIFACT_PATH_PROBE_FILE}"
  : "${PIE_TEST_RELAUNCH_ARTIFACT_PATH_PROBE_FILE:?artifact env must define PIE_TEST_RELAUNCH_ARTIFACT_PATH_PROBE_FILE}"
  PIE_TEST_RUN_ROOT="${PIE_TEST_RUN_ROOT:-$(dirname "$PIE_TEST_INITIAL_ARTIFACT_PATH_PROBE_FILE")}"
  if [ ! -d "$PIE_TEST_APP_PATH" ]; then
    echo "first-launch package e2e: app artifact missing at $PIE_TEST_APP_PATH" >&2
    exit 1
  fi
}

cleanup_scenario() {
  local status="$1"
  rm -f "$CONFIG_FILE"
  if [ -n "${PIE_APP_PREFERENCES_SUITE:-}" ]; then
    defaults delete "$PIE_APP_PREFERENCES_SUITE" >/dev/null 2>&1 || true
  fi
  if [ "$status" -eq 0 ]; then
    rm -f "${PIE_TEST_INITIAL_ARTIFACT_PATH_PROBE_FILE:-}" \
          "${PIE_TEST_RELAUNCH_ARTIFACT_PATH_PROBE_FILE:-}"
    if safe_to_remove_run_root "${PIE_TEST_RUN_ROOT:-}"; then
      rm -rf "$PIE_TEST_RUN_ROOT"
      echo "first-launch package e2e: removed transient run root: $PIE_TEST_RUN_ROOT"
    fi
  else
    echo "first-launch package e2e: preserving run root: ${PIE_TEST_RUN_ROOT:-$RUN_ROOT}" >&2
  fi
  return "$status"
}

assert_probe_matches_artifact() {
  local label="$1"
  local probe_file="$2"
  python3 - "$PIE_TEST_APP_PATH" "$probe_file" "$label" <<'PY'
import os
import sys

expected = os.path.realpath(sys.argv[1])
probe = sys.argv[2]
label = sys.argv[3]
if not os.path.exists(probe):
    print(f"first-launch package e2e: {label} probe missing at {probe}", file=sys.stderr)
    sys.exit(1)
with open(probe, "r", encoding="utf-8") as fh:
    actual = os.path.realpath(fh.read().strip())
if actual != expected:
    print(f"first-launch package e2e: {label} launched app artifact mismatch", file=sys.stderr)
    print(f"expected={expected}", file=sys.stderr)
    print(f"actual={actual}", file=sys.stderr)
    sys.exit(1)
PY
}

assert_human_artifact_root_safe() {
  python3 - "$HUMAN_ARTIFACT_ROOT" "${PIE_TEST_RUN_ROOT:-}" <<'PY'
import os
import sys

export_root = os.path.realpath(sys.argv[1])
run_root = os.path.realpath(sys.argv[2]) if sys.argv[2] else ""

if run_root and (export_root == run_root or export_root.startswith(run_root + os.sep)):
    print(
        f"first-launch package e2e: human-testable artifact export root must not be inside transient run root: {export_root}",
        file=sys.stderr,
    )
    sys.exit(1)

if export_root.startswith("/tmp/p175-first-launch-") or export_root.startswith("/private/tmp/p175-first-launch-"):
    print(
        f"first-launch package e2e: human-testable artifact export root must not be a transient /tmp run root: {export_root}",
        file=sys.stderr,
    )
    sys.exit(1)
PY
}

make_human_artifact_run_id() {
  if [ -n "${PIE_TEST_EXPORT_RUN_ID:-}" ]; then
    printf '%s\n' "$PIE_TEST_EXPORT_RUN_ID"
    return
  fi

  local stamp git_short base candidate suffix
  stamp="$(date -u +%Y%m%dT%H%M%SZ)"
  git_short="$(git rev-parse --short HEAD 2>/dev/null || echo unknown)"
  base="$stamp-$git_short-${PIE_TEST_ARCH:-$ARCH_VALUE}"
  candidate="$base"
  suffix=2
  while [ -e "$HUMAN_ARTIFACT_ROOT/runs/$candidate" ]; do
    candidate="$base-$suffix"
    suffix=$((suffix + 1))
  done
  printf '%s\n' "$candidate"
}

export_human_testable_app_artifact() {
  assert_human_artifact_root_safe

  local run_id runs_dir run_dir latest_dir latest_tmp zip_path checksum_path manifest_path
  local latest_zip_path latest_checksum_path latest_manifest_path latest_pointer_path latest_pointer_tmp
  run_id="$(make_human_artifact_run_id)"
  runs_dir="$HUMAN_ARTIFACT_ROOT/runs"
  run_dir="$runs_dir/$run_id"
  latest_dir="$HUMAN_ARTIFACT_ROOT/latest"
  latest_tmp="$HUMAN_ARTIFACT_ROOT/latest.tmp.$$"
  zip_path="$run_dir/Rational.app.zip"
  checksum_path="$run_dir/Rational.app.zip.sha256"
  manifest_path="$run_dir/manifest.json"
  latest_zip_path="$latest_dir/Rational.app.zip"
  latest_checksum_path="$latest_dir/Rational.app.zip.sha256"
  latest_manifest_path="$latest_dir/manifest.json"
  latest_pointer_path="$HUMAN_ARTIFACT_ROOT/latest.json"
  latest_pointer_tmp="$HUMAN_ARTIFACT_ROOT/latest.json.tmp.$$"

  rm -rf "$run_dir" "$latest_tmp" "$latest_pointer_tmp"
  mkdir -p "$run_dir" "$latest_tmp"

  echo "first-launch package e2e: exporting verified human-testable app artifact"
  ditto -c -k --sequesterRsrc --keepParent "$PIE_TEST_APP_PATH" "$zip_path"
  (cd "$run_dir" && shasum -a 256 Rational.app.zip >"$(basename "$checksum_path")")

  local sha256 size_bytes app_size_kb generated_at git_commit git_branch git_dirty git_dirty_py bundle_id
  sha256="$(awk '{print $1}' "$checksum_path")"
  size_bytes="$(stat -f '%z' "$zip_path")"
  app_size_kb="$(du -sk "$PIE_TEST_APP_PATH" | awk '{print $1}')"
  generated_at="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  git_commit="$(git rev-parse HEAD 2>/dev/null || echo unknown)"
  git_branch="$(git branch --show-current 2>/dev/null || echo unknown)"
  if git diff --quiet --ignore-submodules -- 2>/dev/null &&
     git diff --cached --quiet --ignore-submodules -- 2>/dev/null; then
    git_dirty=false
  else
    git_dirty=true
  fi
  if [ "$git_dirty" = true ]; then
    git_dirty_py=True
  else
    git_dirty_py=False
  fi
  bundle_id="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$PIE_TEST_APP_PATH/Contents/Info.plist" 2>/dev/null || true)"
  local verification_scenario artifact_path_assertions relaunch_assertion
  verification_scenario="${PIE_TEST_ARTIFACT_VERIFICATION_SCENARIO:-first-launch wizard package-backed E2E}"
  artifact_path_assertions="${PIE_TEST_ARTIFACT_PATH_ASSERTIONS:-initial and relaunch probes matched PIE_TEST_APP_PATH}"
  relaunch_assertion="${PIE_TEST_RELAUNCH_PERSISTENCE_ASSERTION:-passed}"

  python3 - "$manifest_path" "$latest_pointer_tmp" <<PY
import json
import os
import sys

manifest_path, latest_pointer_path = sys.argv[1:]
manifest = {
    "schema_version": 1,
    "artifact_kind": "macos_app_zip",
    "check": "first-launch-package-e2e",
    "generated_at": "$generated_at",
    "run_id": "$run_id",
    "app": {
        "name": "Rational.app",
        "bundle_id": "$bundle_id",
        "source_path": "$PIE_TEST_APP_PATH",
        "arch": "${PIE_TEST_ARCH:-$ARCH_VALUE}",
        "configuration": "Release",
        "size_kb": int("$app_size_kb"),
    },
    "git": {
        "commit": "$git_commit",
        "branch": "$git_branch",
        "dirty": $git_dirty_py,
    },
    "verification": {
        "scenario": "$verification_scenario",
        "passed": True,
        "artifact_path_assertions": "$artifact_path_assertions",
        "relaunch_persistence_assertion": "$relaunch_assertion",
    },
    "artifact": {
        "zip_path": "$zip_path",
        "checksum_path": "$checksum_path",
        "manifest_path": "$manifest_path",
        "latest_zip_path": "$latest_zip_path",
        "latest_checksum_path": "$latest_checksum_path",
        "latest_manifest_path": "$latest_manifest_path",
        "size_bytes": int("$size_bytes"),
        "sha256": "$sha256",
    },
    "source_handoff": {
        "artifact_env": "$ARTIFACT_ENV",
        "dmg_path": "${PIE_TEST_DMG_PATH:-}",
    },
}
latest = {
    "schema_version": 1,
    "artifact_kind": "macos_app_zip",
    "check": "first-launch-package-e2e",
    "generated_at": "$generated_at",
    "run_id": "$run_id",
    "latest_zip_path": "$latest_zip_path",
    "latest_checksum_path": "$latest_checksum_path",
    "latest_manifest_path": "$latest_manifest_path",
    "sha256": "$sha256",
}
os.makedirs(os.path.dirname(manifest_path), exist_ok=True)
with open(manifest_path, "w", encoding="utf-8") as fh:
    json.dump(manifest, fh, indent=2, sort_keys=True)
    fh.write("\\n")
with open(latest_pointer_path, "w", encoding="utf-8") as fh:
    json.dump(latest, fh, indent=2, sort_keys=True)
    fh.write("\\n")
PY

  cp "$zip_path" "$latest_tmp/Rational.app.zip"
  cp "$manifest_path" "$latest_tmp/manifest.json"
  (cd "$latest_tmp" && shasum -a 256 Rational.app.zip >Rational.app.zip.sha256)
  rm -rf "$latest_dir"
  mv "$latest_tmp" "$latest_dir"
  mv "$latest_pointer_tmp" "$latest_pointer_path"

  prune_human_artifact_runs

  echo "first-launch package e2e: exported human-testable app artifact=$latest_zip_path"
  echo "first-launch package e2e: exported human-testable manifest=$latest_manifest_path"
  echo "first-launch package e2e: exported human-testable checksum=$latest_checksum_path"
  echo "first-launch package e2e: human-testable download path: $latest_zip_path"
}

prune_human_artifact_runs() {
  python3 - "$HUMAN_ARTIFACT_ROOT/runs" "$HUMAN_ARTIFACT_KEEP" <<'PY'
import os
import shutil
import sys

runs_dir = sys.argv[1]
try:
    keep = int(sys.argv[2])
except ValueError:
    keep = 3
if keep < 1:
    keep = 1
if not os.path.isdir(runs_dir):
    sys.exit(0)

runs = [
    os.path.join(runs_dir, name)
    for name in os.listdir(runs_dir)
    if os.path.isdir(os.path.join(runs_dir, name))
]
runs.sort(key=lambda path: os.path.basename(path))
for path in runs[:-keep]:
    shutil.rmtree(path)
PY
}

safe_to_remove_run_root() {
  local candidate="$1"
  case "$candidate" in
    /tmp/p175-first-launch-*|/private/tmp/p175-first-launch-*)
      [ -d "$candidate" ]
      ;;
    *)
      return 1
      ;;
  esac
}

write_scenario_config() {
  cat >"$CONFIG_FILE" <<EOF_ENV
PIE_TEST_APP_PATH=$PIE_TEST_APP_PATH
PIE_TEST_DMG_PATH=${PIE_TEST_DMG_PATH:-}
PIE_TEST_RUN_ROOT=$PIE_TEST_RUN_ROOT
PIE_TEST_GUI_HOME=$PIE_TEST_GUI_HOME
PIE_APP_PREFERENCES_SUITE=$PIE_APP_PREFERENCES_SUITE
PIE_TEST_LOGIN_ITEM_STATUS=${PIE_TEST_LOGIN_ITEM_STATUS:-notRegistered}
PIE_TEST_FAKE_DOWNLOADS=${PIE_TEST_FAKE_DOWNLOADS:-1}
PIE_TEST_INITIAL_ARTIFACT_PATH_PROBE_FILE=$PIE_TEST_INITIAL_ARTIFACT_PATH_PROBE_FILE
PIE_TEST_RELAUNCH_ARTIFACT_PATH_PROBE_FILE=$PIE_TEST_RELAUNCH_ARTIFACT_PATH_PROBE_FILE
PIE_TEST_ARCH=${PIE_TEST_ARCH:-$ARCH_VALUE}
EOF_ENV
}

run_scenario_phase() {
  local env_file="$1"
  require_gui_preflight
  source_artifact_env "$env_file"

  mkdir -p "$PIE_TEST_GUI_HOME" \
    "$(dirname "$PIE_TEST_INITIAL_ARTIFACT_PATH_PROBE_FILE")" \
    "$(dirname "$PIE_TEST_RELAUNCH_ARTIFACT_PATH_PROBE_FILE")"
  rm -f "$PIE_TEST_INITIAL_ARTIFACT_PATH_PROBE_FILE" \
        "$PIE_TEST_RELAUNCH_ARTIFACT_PATH_PROBE_FILE" \
        "$CONFIG_FILE"
  write_scenario_config

  trap 'cleanup_scenario "$?"' EXIT

  local test_arch="${PIE_TEST_ARCH:-$ARCH_VALUE}"
  echo "first-launch package e2e: app artifact=$PIE_TEST_APP_PATH"
  echo "first-launch package e2e: gui PIE_HOME=$PIE_TEST_GUI_HOME"
  echo "first-launch package e2e: preferences suite=$PIE_APP_PREFERENCES_SUITE"
  echo "first-launch package e2e: initial artifact probe=$PIE_TEST_INITIAL_ARTIFACT_PATH_PROBE_FILE"
  echo "first-launch package e2e: relaunch artifact probe=$PIE_TEST_RELAUNCH_ARTIFACT_PATH_PROBE_FILE"
  echo "first-launch package e2e: retained run root=${PIE_TEST_RUN_ROOT:-$RUN_ROOT}"
  echo "first-launch package e2e: running packaged first-launch XCUITest"

  xcodebuild -project RatioThink.xcodeproj \
    -scheme RatioThinkGUITests \
    -destination "platform=macOS,arch=$test_arch" \
    -configuration Debug \
    -parallel-testing-enabled NO \
    test \
    -only-testing:RatioThinkGUITests/S7_FirstLaunchWizardPackagedArtifactGUITests/test_packaged_app_first_launch_flow_persists_after_relaunch \
    ENABLE_CODE_COVERAGE=NO

  assert_probe_matches_artifact "initial" "$PIE_TEST_INITIAL_ARTIFACT_PATH_PROBE_FILE"
  assert_probe_matches_artifact "relaunch" "$PIE_TEST_RELAUNCH_ARTIFACT_PATH_PROBE_FILE"
  echo "first-launch package e2e: initial and relaunch artifact probes matched $PIE_TEST_APP_PATH"
  export_human_testable_app_artifact
  echo "first-launch package e2e: PASS"
}

mode="both"
case "${1:-}" in
  "") ;;
  --init-only)
    mode="init"
    shift
    ;;
  --scenario-only)
    mode="scenario"
    shift
    if [ $# -ne 1 ]; then
      usage
      exit 64
    fi
    ARTIFACT_ENV="$1"
    ;;
  -h|--help)
    usage
    exit 0
    ;;
  *)
    usage
    exit 64
    ;;
esac

case "$mode" in
  both)
    require_gui_preflight
    run_init_phase
    run_scenario_phase "$ARTIFACT_ENV"
    ;;
  init)
    run_init_phase
    ;;
  scenario)
    run_scenario_phase "$ARTIFACT_ENV"
    ;;
esac
