#!/usr/bin/env bash
# Regression tests for Scripts/collect-diagnostics.sh. Drives the REAL script
# (memory: script tests must hit the real tool, not a stub) through its override
# env so the run is hermetic and CI-safe — no real machine roots are touched.
# `log show` / `spctl` / `launchctl` / `codesign` run for real but their output
# is not asserted; we assert on the seeded inputs + the classification logic.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="$ROOT/Scripts/collect-diagnostics.sh"
WORK_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/ratiothink-diag-tests.XXXXXX")"
trap 'rm -rf "$WORK_ROOT"' EXIT

pass=0; fail=0
ok()   { printf '  ok   %s\n' "$1"; pass=$((pass+1)); }
bad()  { printf '  FAIL %s\n' "$1"; fail=$((fail+1)); }
assert_contains() { # <file> <needle> <label>
  if grep -qF -- "$2" "$1"; then ok "$3"; else
    bad "$3 (missing: $2)"; echo "    --- $1 ---"; sed 's/^/    /' "$1" | head -40; fi
}
assert_exists() { [ -e "$1" ] && ok "$2" || bad "$2 (no $1)"; }
refute_contains() { # <file> <needle> <label> — passes when the needle is ABSENT
  if grep -qF -- "$2" "$1"; then
    bad "$3 (unexpectedly found: $2)"; echo "    --- $1 ---"; sed 's/^/    /' "$1" | head -40
  else ok "$3"; fi
}

# Unzip the single produced bundle and echo its extracted root dir.
extract_bundle() { # <out_dir> <dest>
  local zip dest="$2"
  zip="$(find "$1" -maxdepth 1 -name '*.zip' | head -1)"
  [ -n "$zip" ] || { echo "NO_ZIP"; return 1; }
  mkdir -p "$dest"
  ditto -x -k "$zip" "$dest" 2>/dev/null || unzip -q "$zip" -d "$dest"
  find "$dest" -type d -name 'RatioThink-diagnostics-*' | head -1
}

echo "case A: empty-log / helper-missing"
A="$WORK_ROOT/A"; mkdir -p "$A/out"
RATIOTHINK_APP="$A/nonexistent/RatioThink.app" \
PIE_HOME="$A/home" \
RATIOTHINK_DIAG_CRASH_DIR="$A/crash" \
RATIOTHINK_DIAG_OUT_DIR="$A/out" \
  bash "$SCRIPT" --window 1m >/dev/null
bundleA="$(extract_bundle "$A/out" "$A/x")"
assert_exists "$bundleA/report.txt" "A: report.txt present (never an empty dir)"
assert_contains "$bundleA/report.txt" "APP_MISSING" "A: classifies app missing"
assert_contains "$bundleA/report.txt" "helper never launched" "A: classifies helper-never-launched"
assert_exists "$bundleA/unified-log.txt" "A: unified-log section present"

echo "case B: happy-path bundle shape + redaction"
B="$WORK_ROOT/B"; mkdir -p "$B/out" "$B/crash" "$B/home/logs"
APP="$B/app/RatioThink.app"; mkdir -p "$APP/Contents"
cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleShortVersionString</key><string>9.9.9</string>
  <key>CFBundleVersion</key><string>42</string>
</dict></plist>
PLIST
# Seeded breadcrumb logs (helper.log present => not "helper never launched").
printf '2026-05-30T00:00:00Z app app.launch version=9.9.9 path=%s/Library/x token=abcd1234 hf_SECRETTOKEN\n' "$HOME" > "$B/home/logs/app.log"
echo "2026-05-30T00:00:01Z helper helper.launch version=9.9.9" > "$B/home/logs/helper.log"
echo "engine starting" > "$B/home/logs/engine.log"
echo "fake crash" > "$B/crash/RatioThink-2026-05-30.ips"

RATIOTHINK_APP="$APP" \
PIE_HOME="$B/home" \
RATIOTHINK_DIAG_CRASH_DIR="$B/crash" \
RATIOTHINK_DIAG_OUT_DIR="$B/out" \
  bash "$SCRIPT" --window 1m >/dev/null
bundleB="$(extract_bundle "$B/out" "$B/x")"
assert_exists "$bundleB/report.txt"        "B: report.txt present"
assert_exists "$bundleB/versions.txt"      "B: versions.txt present"
assert_exists "$bundleB/codesign.txt"      "B: codesign.txt present"
assert_exists "$bundleB/launchctl.txt"     "B: launchctl.txt present"
assert_exists "$bundleB/processes.txt"     "B: processes.txt present"
assert_exists "$bundleB/unified-log.txt"   "B: unified-log.txt present"
assert_exists "$bundleB/app-logs/app.log"  "B: app-owned logs collected"
assert_contains "$bundleB/versions.txt" "9.9.9" "B: app version parsed from Info.plist"
# Redaction: home prefix collapsed, secrets scrubbed in the collected copy.
assert_contains "$bundleB/app-logs/app.log" "~/Library/x"    "B: redacts \$HOME -> ~"
assert_contains "$bundleB/app-logs/app.log" "hf_REDACTED"    "B: redacts hf_ token"
assert_contains "$bundleB/app-logs/app.log" "token=REDACTED" "B: redacts token="
if grep -qF "$HOME/Library/x" "$bundleB/app-logs/app.log"; then
  bad "B: raw \$HOME leaked into bundle"; else ok "B: no raw \$HOME in bundle"; fi

echo "case C: main-app crash report must classify APP_CRASHED, not OK (F1)"
C="$WORK_ROOT/C"; mkdir -p "$C/out" "$C/crash" "$C/home/logs"
CAPP="$C/app/RatioThink.app"; mkdir -p "$CAPP/Contents"
cat > "$CAPP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict><key>CFBundleShortVersionString</key><string>1.0</string></dict></plist>
PLIST
echo "2026-05-30T00:00:00Z helper helper.launch version=1.0" > "$C/home/logs/helper.log"
echo "fake app crash" > "$C/crash/RatioThink-2026-05-30-120000.ips"
RATIOTHINK_APP="$CAPP" PIE_HOME="$C/home" RATIOTHINK_DIAG_CRASH_DIR="$C/crash" \
RATIOTHINK_DIAG_OUT_DIR="$C/out" bash "$SCRIPT" --window 1m >/dev/null
bundleC="$(extract_bundle "$C/out" "$C/x")"
assert_contains "$bundleC/report.txt" "APP_CRASHED" "C: main-app crash classified APP_CRASHED"
refute_contains "$bundleC/report.txt" "OK: no failure signature" "C: does not print OK when app crashed"

echo "case D: Bearer base64 token (+/=) fully redacted (F5)"
D="$WORK_ROOT/D"; mkdir -p "$D/out" "$D/crash" "$D/home/logs"
echo "2026-05-30T00:00:00Z app chat.send auth=Authorization: Bearer ab+cd/ef= done" > "$D/home/logs/app.log"
RATIOTHINK_APP="$D/nonexistent" PIE_HOME="$D/home" RATIOTHINK_DIAG_CRASH_DIR="$D/crash" \
RATIOTHINK_DIAG_OUT_DIR="$D/out" bash "$SCRIPT" --window 1m >/dev/null
bundleD="$(extract_bundle "$D/out" "$D/x")"
assert_contains "$bundleD/app-logs/app.log" "Bearer REDACTED" "D: Bearer token replaced"
# The old regex [A-Za-z0-9._-]+ stopped at '+', leaking the tail '+cd/ef='.
# Assert that leaked remainder is gone (the bytes the bug used to expose).
refute_contains "$bundleD/app-logs/app.log" "cd/ef"          "D: no base64 token tail survives"

echo "case E: benign engine.log 'error' must NOT classify ENGINE_FAILED (F3)"
E="$WORK_ROOT/E"; mkdir -p "$E/out" "$E/crash" "$E/home/logs"
echo "2026-05-30T00:00:00Z helper helper.launch version=1.0" > "$E/home/logs/helper.log"
echo "engine up: 0 errors; error_rate=0; loaded model mixtral-no-error" > "$E/home/logs/engine.log"
RATIOTHINK_APP="$E/nonexistent" PIE_HOME="$E/home" RATIOTHINK_DIAG_CRASH_DIR="$E/crash" \
RATIOTHINK_DIAG_OUT_DIR="$E/out" bash "$SCRIPT" --window 1m >/dev/null
bundleE="$(extract_bundle "$E/out" "$E/x")"
refute_contains "$bundleE/report.txt" "ENGINE_FAILED" "E: benign 'error' does not trip ENGINE_FAILED"

echo
echo "collect-diagnostics self-test: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
