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
# PATH shims so a hermetic run can reach the all-clear OK branch: real spctl/
# launchctl would reject a fake bundle / report no helper, and real `log show`
# is machine-dependent. Shims force spctl/launchctl success and make `log`
# emit a controlled fixture so ACTIVITY_VERIFIED is deterministic.
make_shims() { # <bin_dir> <unified_fixture_file>
  local d="$1" fixture="$2"
  mkdir -p "$d"
  printf '#!/bin/bash\nexit 0\n' > "$d/spctl"
  printf '#!/bin/bash\nexit 0\n' > "$d/launchctl"
  cat > "$d/log" <<EOF
#!/bin/bash
cat "$fixture" 2>/dev/null
exit 0
EOF
  chmod +x "$d/spctl" "$d/launchctl" "$d/log"
}
mini_app() { # <app_path> — minimal Rational.app with a version so it's "present"
  mkdir -p "$1/Contents"
  cat > "$1/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict><key>CFBundleShortVersionString</key><string>1.0</string></dict></plist>
PLIST
}

# Unzip the single produced bundle and echo its extracted root dir.
extract_bundle() { # <out_dir> <dest>
  local zip dest="$2"
  zip="$(find "$1" -maxdepth 1 -name '*.zip' | head -1)"
  [ -n "$zip" ] || { echo "NO_ZIP"; return 1; }
  mkdir -p "$dest"
  ditto -x -k "$zip" "$dest" 2>/dev/null || unzip -q "$zip" -d "$dest"
  find "$dest" -type d -name 'Rational-diagnostics-*' | head -1
}

echo "case A: empty-log / helper-missing"
A="$WORK_ROOT/A"; mkdir -p "$A/out"
RATIOTHINK_APP="$A/nonexistent/Rational.app" \
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
APP="$B/app/Rational.app"; mkdir -p "$APP/Contents"
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
echo "fake crash" > "$B/crash/Rational-2026-05-30.ips"

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
CAPP="$C/app/Rational.app"; mkdir -p "$CAPP/Contents"
cat > "$CAPP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict><key>CFBundleShortVersionString</key><string>1.0</string></dict></plist>
PLIST
echo "2026-05-30T00:00:00Z helper helper.launch version=1.0" > "$C/home/logs/helper.log"
echo "fake app crash" > "$C/crash/Rational-2026-05-30-120000.ips"
RATIOTHINK_APP="$CAPP" PIE_HOME="$C/home" RATIOTHINK_DIAG_CRASH_DIR="$C/crash" \
RATIOTHINK_DIAG_OUT_DIR="$C/out" bash "$SCRIPT" --window 1m >/dev/null
bundleC="$(extract_bundle "$C/out" "$C/x")"
assert_contains "$bundleC/report.txt" "APP_CRASHED" "C: main-app crash classified APP_CRASHED"
refute_contains "$bundleC/report.txt" "OK: no failure signature" "C: does not print OK when app crashed"

echo "case Clegacy: legacy RatioThink app/helper crash reports collected + classified during rename migration"
CL="$WORK_ROOT/Clegacy"; mkdir -p "$CL/out" "$CL/crash" "$CL/home/logs"
mini_app "$CL/app/Rational.app"
echo "2026-05-30T00:00:00Z helper helper.launch version=1.0" > "$CL/home/logs/helper.log"
echo "fake legacy app crash" > "$CL/crash/RatioThink-2026-05-30-120000.ips"
echo "fake legacy helper crash" > "$CL/crash/RatioThinkHelper-2026-05-30-120001.ips"
RATIOTHINK_APP="$CL/app/Rational.app" PIE_HOME="$CL/home" RATIOTHINK_DIAG_CRASH_DIR="$CL/crash" \
RATIOTHINK_DIAG_OUT_DIR="$CL/out" bash "$SCRIPT" --window 1m >/dev/null
bundleCL="$(extract_bundle "$CL/out" "$CL/x")"
assert_exists "$bundleCL/crash-reports/RatioThink-2026-05-30-120000.ips" "Clegacy: legacy app crash report copied"
assert_exists "$bundleCL/crash-reports/RatioThinkHelper-2026-05-30-120001.ips" "Clegacy: legacy helper crash report copied"
assert_contains "$bundleCL/report.txt" "APP_CRASHED_LEGACY" "Clegacy: legacy app crash classified explicitly"
assert_contains "$bundleCL/report.txt" "HELPER_CRASHED_OR_DEGRADED_LEGACY" "Clegacy: legacy helper crash classified explicitly"

echo "case Cmixedhelper: current + legacy helper crash reports both classify during rename migration"
CMH="$WORK_ROOT/Cmixedhelper"; mkdir -p "$CMH/out" "$CMH/crash" "$CMH/home/logs"
mini_app "$CMH/app/Rational.app"
echo "2026-05-30T00:00:00Z helper helper.launch version=1.0" > "$CMH/home/logs/helper.log"
echo "fake current helper crash" > "$CMH/crash/RationalHelper-2026-05-30-120000.ips"
echo "fake legacy helper crash" > "$CMH/crash/RatioThinkHelper-2026-05-30-120001.ips"
RATIOTHINK_APP="$CMH/app/Rational.app" PIE_HOME="$CMH/home" RATIOTHINK_DIAG_CRASH_DIR="$CMH/crash" \
RATIOTHINK_DIAG_OUT_DIR="$CMH/out" bash "$SCRIPT" --window 1m >/dev/null
bundleCMH="$(extract_bundle "$CMH/out" "$CMH/x")"
assert_contains "$bundleCMH/report.txt" "HELPER_CRASHED_OR_DEGRADED: a recent Rational Helper crash report exists" "Cmixedhelper: current helper crash classified"
assert_contains "$bundleCMH/report.txt" "HELPER_CRASHED_OR_DEGRADED_LEGACY" "Cmixedhelper: legacy helper crash classified alongside current helper"

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

echo "case F: Rust panic in engine.log (stdout/stderr tee) classifies ENGINE_FAILED"
F="$WORK_ROOT/F"; mkdir -p "$F/out" "$F/crash" "$F/home/logs"
mini_app "$F/app/Rational.app"
echo "2026-05-30T00:00:00Z helper helper.launch version=1.0" > "$F/home/logs/helper.log"
# Serve-path tracing goes to pie.log.<date>, NOT stdout — engine.log only sees
# panic prose. Use the real signal that DOES reach it.
echo "thread 'tokio-runtime-worker' panicked at runtime/src/server.rs:42:1: assertion failed" > "$F/home/logs/engine.log"
RATIOTHINK_APP="$F/app/Rational.app" PIE_HOME="$F/home" RATIOTHINK_DIAG_CRASH_DIR="$F/crash" \
RATIOTHINK_DIAG_OUT_DIR="$F/out" bash "$SCRIPT" --window 1m >/dev/null
bundleF="$(extract_bundle "$F/out" "$F/x")"
assert_contains "$bundleF/report.txt" "ENGINE_FAILED" "F: 'panicked at' in engine.log trips ENGINE_FAILED"

echo "case Fb: engine.fail breadcrumb in helper.log classifies ENGINE_FAILED"
FB="$WORK_ROOT/Fb"; mkdir -p "$FB/out" "$FB/crash" "$FB/home/logs"
mini_app "$FB/app/Rational.app"
printf '2026-05-30T00:00:00Z helper helper.launch version=1.0\n2026-05-30T12:00:00Z helper engine.fail code=spawnFailed\n' > "$FB/home/logs/helper.log"
RATIOTHINK_APP="$FB/app/Rational.app" PIE_HOME="$FB/home" RATIOTHINK_DIAG_CRASH_DIR="$FB/crash" \
RATIOTHINK_DIAG_OUT_DIR="$FB/out" bash "$SCRIPT" --window 1m >/dev/null
bundleFb="$(extract_bundle "$FB/out" "$FB/x")"
assert_contains "$bundleFb/report.txt" "ENGINE_FAILED" "Fb: engine.fail breadcrumb trips ENGINE_FAILED"

echo "case Fp: real serve-path teardown line in DATE-ROLLED pie.log.<date> -> ENGINE_FAILED (V1)"
FP="$WORK_ROOT/Fp"; mkdir -p "$FP/out" "$FP/crash" "$FP/home/logs"
mini_app "$FP/app/Rational.app"
echo "2026-05-30T00:00:00Z helper helper.launch version=1.0" > "$FP/home/logs/helper.log"
# pie writes tracing_appender rolling::daily -> pie.log.<date>, never literal
# pie.log; the real engine-death line is lifecycle.rs's "driver ... exited
# unexpectedly". Both the dated filename and the anchored line are required.
echo "2026-05-30T12:00:00Z  ERROR pie_server: driver shmem-abc123 exited unexpectedly; tearing down" > "$FP/home/logs/pie.log.2026-05-30"
RATIOTHINK_APP="$FP/app/Rational.app" PIE_HOME="$FP/home" RATIOTHINK_DIAG_CRASH_DIR="$FP/crash" \
RATIOTHINK_DIAG_OUT_DIR="$FP/out" bash "$SCRIPT" --window 1m >/dev/null
bundleFp="$(extract_bundle "$FP/out" "$FP/x")"
assert_contains "$bundleFp/report.txt" "ENGINE_FAILED" "Fp: pie.log.<date> teardown line trips ENGINE_FAILED"

echo "case Fn: recoverable per-request ERROR in pie.log.<date> must NOT classify ENGINE_FAILED (V2)"
FN="$WORK_ROOT/Fn"; mkdir -p "$FN/out" "$FN/crash" "$FN/home/logs"
mini_app "$FN/app/Rational.app"
echo "2026-05-30T00:00:00Z helper helper.launch version=1.0" > "$FN/home/logs/helper.log"
# pie logs tracing::error! for recoverable churn (user quits mid-stream) — the
# engine keeps serving; this must not read as engine death.
echo "2026-05-30T12:00:00Z  ERROR pie_server::server: Error writing to ws stream: Broken pipe" > "$FN/home/logs/pie.log.2026-05-30"
RATIOTHINK_APP="$FN/app/Rational.app" PIE_HOME="$FN/home" RATIOTHINK_DIAG_CRASH_DIR="$FN/crash" \
RATIOTHINK_DIAG_OUT_DIR="$FN/out" bash "$SCRIPT" --window 1m >/dev/null
bundleFn="$(extract_bundle "$FN/out" "$FN/x")"
refute_contains "$bundleFn/report.txt" "ENGINE_FAILED" "Fn: recoverable ws-write ERROR does not trip ENGINE_FAILED"

echo "case G: all-clear with recent Unified Log activity -> verified OK headline (F2)"
G="$WORK_ROOT/G"; mkdir -p "$G/out" "$G/crash" "$G/home/logs" "$G/bin"
mini_app "$G/app/Rational.app"
echo "2026-05-30T00:00:00Z helper helper.launch version=1.0" > "$G/home/logs/helper.log"
printf '2026-05-30 12:00:00 com.ratiothink.app: ready\n' > "$G/unified.fixture"
make_shims "$G/bin" "$G/unified.fixture"
PATH="$G/bin:$PATH" RATIOTHINK_APP="$G/app/Rational.app" PIE_HOME="$G/home" \
RATIOTHINK_DIAG_CRASH_DIR="$G/crash" RATIOTHINK_DIAG_OUT_DIR="$G/out" \
  bash "$SCRIPT" --window 1m >/dev/null
bundleG="$(extract_bundle "$G/out" "$G/x")"
assert_contains "$bundleG/report.txt" "OK: no failure signature" "G: clean state -> OK verdict"
assert_contains "$bundleG/report.txt" "recent activity found"    "G: claims recent activity when Unified Log has lines"

echo "case H: all-clear with NO recent Unified Log activity -> unverified headline (F2)"
H="$WORK_ROOT/H"; mkdir -p "$H/out" "$H/crash" "$H/home/logs" "$H/bin"
mini_app "$H/app/Rational.app"
echo "2026-05-30T00:00:00Z helper helper.launch version=1.0" > "$H/home/logs/helper.log"
: > "$H/unified.empty"
make_shims "$H/bin" "$H/unified.empty"
PATH="$H/bin:$PATH" RATIOTHINK_APP="$H/app/Rational.app" PIE_HOME="$H/home" \
  RATIOTHINK_DIAG_CRASH_DIR="$H/crash" RATIOTHINK_DIAG_OUT_DIR="$H/out" \
  bash "$SCRIPT" --window 1m >/dev/null
bundleH="$(extract_bundle "$H/out" "$H/x")"
assert_contains "$bundleH/report.txt" "OK: no failure signature"              "H: clean state -> OK verdict"
assert_contains "$bundleH/report.txt" "No recent Unified Log activity confirmed" "H: unverified-activity headline"
refute_contains "$bundleH/report.txt" "recent activity found"                 "H: does not claim recent activity"

echo "case Fc: seeded pie crash report (pie-<date>.ips) -> ENGINE_FAILED + collected"
FC="$WORK_ROOT/Fc"; mkdir -p "$FC/out" "$FC/crash" "$FC/home/logs"
mini_app "$FC/app/Rational.app"
echo "2026-05-30T00:00:00Z helper helper.launch version=1.0" > "$FC/home/logs/helper.log"
# The engine reports as `pie` -> pie-<date>.ips; classify() greps -name
# 'pie-[0-9]*' and section_crash_reports copies it into crash-reports/.
echo '{"app_name":"pie","fake":"crash"}' > "$FC/crash/pie-2026-05-30-120000.ips"
RATIOTHINK_APP="$FC/app/Rational.app" PIE_HOME="$FC/home" RATIOTHINK_DIAG_CRASH_DIR="$FC/crash" \
RATIOTHINK_DIAG_OUT_DIR="$FC/out" bash "$SCRIPT" --window 1m >/dev/null
bundleFc="$(extract_bundle "$FC/out" "$FC/x")"
assert_contains "$bundleFc/report.txt" "ENGINE_FAILED" "Fc: seeded pie crash trips ENGINE_FAILED"
assert_exists "$bundleFc/crash-reports/pie-2026-05-30-120000.ips" "Fc: pie crash report copied into bundle"

# --- chat-collection removal (#399) -----------------------------------------
# Privacy invariant: a diagnostics bundle must NEVER carry chat content, under
# any flag, from any copy of the script. Exercised against the source script
# and, when a built app is discoverable, the app-bundled Resources copy too.

# Seed a PIE_HOME that DOES contain chats.sqlite, so "no chat artifact" is a
# real exclusion assertion (the file exists to be left out, not merely absent).
seed_chat_home() { # <home_dir>
  mkdir -p "$1/logs"
  echo "2026-05-30T00:00:00Z helper helper.launch version=1.0" > "$1/logs/helper.log"
  # Recognizable payload — if any byte lands in the bundle, the test fails.
  printf 'SQLite format 3\000CHATSECRET_user_said_hello\n' > "$1/chats.sqlite"
}
# Fail if any chat artifact (file name or payload bytes) is in <bundle_dir>.
assert_no_chats() { # <bundle_dir> <label>
  local d="$1" lbl="$2" hit
  hit="$(find "$d" -type f \( -name '*.sqlite' -o -name 'chats*' \) 2>/dev/null)"
  if [ -n "$hit" ]; then bad "$lbl (chat file in bundle: $hit)"; return; fi
  if grep -rqlF "CHATSECRET" "$d" 2>/dev/null; then
    bad "$lbl (chat payload bytes leaked into bundle)"; return; fi
  ok "$lbl"
}

# Discover the app-bundled copy (project.yml cp's it verbatim into
# Contents/Resources). Explicit override > RATIOTHINK_APP bundle > std install.
# Absent => a LOUD note (never a silent skip); the static guard (case K) still
# proves drift cannot ship the flag without any build.
BUNDLED_SCRIPT=""
if [ -n "${RATIOTHINK_BUNDLED_SCRIPT:-}" ] && [ -f "${RATIOTHINK_BUNDLED_SCRIPT}" ]; then
  BUNDLED_SCRIPT="$RATIOTHINK_BUNDLED_SCRIPT"
elif [ -n "${RATIOTHINK_APP:-}" ] && [ -f "${RATIOTHINK_APP}/Contents/Resources/collect-diagnostics.sh" ]; then
  BUNDLED_SCRIPT="${RATIOTHINK_APP}/Contents/Resources/collect-diagnostics.sh"
elif [ -f "/Applications/Rational.app/Contents/Resources/collect-diagnostics.sh" ]; then
  BUNDLED_SCRIPT="/Applications/Rational.app/Contents/Resources/collect-diagnostics.sh"
fi
SCRIPTS_UNDER_TEST=("$SCRIPT")
if [ -n "$BUNDLED_SCRIPT" ]; then
  SCRIPTS_UNDER_TEST+=("$BUNDLED_SCRIPT")
  echo "note: also exercising app-bundled copy: $BUNDLED_SCRIPT"
else
  echo "note: no app-bundled copy found — running source-only chat E2E."
  echo "      to also exercise the shipped artifact, build/install the app and re-run:"
  echo "        make install-app                       # build + sign into /Applications"
  echo "        RATIOTHINK_APP=/Applications/Rational.app Scripts/test-collect-diagnostics.sh"
  echo "      (case K below still proves no --include-chats can ship via packaging drift)"
fi

i=0
for SUT in "${SCRIPTS_UNDER_TEST[@]}"; do
  tag="src"; [ "$i" -gt 0 ] && tag="bundled"; i=$((i+1))

  echo "case I[$tag]: chats.sqlite present + NORMAL run -> bundle excludes all chat content"
  ID="$WORK_ROOT/I$tag"; mkdir -p "$ID/out" "$ID/crash"
  seed_chat_home "$ID/home"; mini_app "$ID/app/Rational.app"
  RATIOTHINK_APP="$ID/app/Rational.app" PIE_HOME="$ID/home" \
  RATIOTHINK_DIAG_CRASH_DIR="$ID/crash" RATIOTHINK_DIAG_OUT_DIR="$ID/out" \
    bash "$SUT" --window 1m >/dev/null
  bundleI="$(extract_bundle "$ID/out" "$ID/x")"
  assert_exists "$bundleI/report.txt"  "I[$tag]: bundle produced"
  assert_no_chats "$bundleI"           "I[$tag]: no chat artifact in normal bundle"

  echo "case J[$tag]: old --include-chats flag never yields chat content"
  JD="$WORK_ROOT/J$tag"; mkdir -p "$JD/out" "$JD/crash"
  seed_chat_home "$JD/home"; mini_app "$JD/app/Rational.app"
  rc=0
  RATIOTHINK_APP="$JD/app/Rational.app" PIE_HOME="$JD/home" \
  RATIOTHINK_DIAG_CRASH_DIR="$JD/crash" RATIOTHINK_DIAG_OUT_DIR="$JD/out" \
    bash "$SUT" --window 1m --include-chats >/dev/null 2>&1 || rc=$?
  # Acceptable: fail clearly (exit!=0, no bundle) OR ignore safely (bundle with
  # no chats). NEVER: succeed with chats. Both branches assert no chat leak.
  zJ="$(find "$JD/out" -maxdepth 1 -name '*.zip' 2>/dev/null | head -1)"
  if [ "$rc" -ne 0 ]; then
    ok "J[$tag]: --include-chats rejected (exit $rc, fails clearly)"
    [ -z "$zJ" ] && ok "J[$tag]: rejection produced no bundle" \
                 || bad "J[$tag]: rejection still wrote a bundle ($zJ)"
  else
    bundleJ="$(extract_bundle "$JD/out" "$JD/x")"
    assert_no_chats "$bundleJ" "J[$tag]: ignored-flag bundle carries no chats"
  fi
  if find "$JD/out" -type f -name '*.sqlite' 2>/dev/null | grep -q .; then
    bad "J[$tag]: chats.sqlite leaked into out dir"
  else ok "J[$tag]: no chats.sqlite under out dir"; fi
done

echo "case K: packaging-drift guard — no chat collection in source, shipped verbatim"
refute_contains "$SCRIPT" "include-chats" "K: source script has no --include-chats"
refute_contains "$SCRIPT" "chats.sqlite"  "K: source script never references chats.sqlite"
# project.yml bundles via a verbatim cp of THIS exact source path, so the shipped
# Resources copy is byte-identical — drift cannot reintroduce the flag.
assert_contains "$ROOT/project.yml" 'cp "${SRCROOT}/Scripts/collect-diagnostics.sh"' \
  "K: project.yml bundles the source script verbatim (cp)"
if [ -n "$BUNDLED_SCRIPT" ]; then
  refute_contains "$BUNDLED_SCRIPT" "include-chats" "K: app-bundled copy has no --include-chats"
fi

echo
echo "collect-diagnostics self-test: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
