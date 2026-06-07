#!/bin/bash
# Collect a redacted Rational diagnostics bundle for triage / a developer.
#
# This is the keystone of issue #358: when "the app does nothing", a user runs
# ONE command and gets a .zip (plus a terminal summary) that classifies WHY —
# app not copied, Gatekeeper quarantine, notarization reject, helper never
# registered, helper crashed/degraded, engine failed, or simply no activity.
#
# It works even when no Rational process can launch and
# ~/Library/Application Support/RatioThink/logs is empty: it leans on macOS
# Unified Logging (`log show`), Gatekeeper/codesign state, launchd state, the
# process list, and crash reports — not just app-owned files. The durable
# breadcrumb logs (app.log/helper.log) are collected when present and make the
# happy path provable, but their absence is itself reported, never a silent
# empty dir.
#
# Runs three ways, all the same code:
#   1. bundled:    /Applications/Rational.app/Contents/Resources/collect-diagnostics.sh
#   2. App menu:   Help -> Collect Diagnostics... (shells out to the bundled copy)
#   3. from source ./Scripts/collect-diagnostics.sh
#
# NO `set -e`: every external probe is allowed to fail (a broken install is the
# normal case) and is guarded with `|| true`. We always produce a bundle and
# exit 0 unless argument parsing itself is wrong.
#
# Override env (used by Scripts/test-collect-diagnostics.sh for hermetic,
# CI-safe runs — real machine roots are never touched):
#   RATIOTHINK_APP             app bundle path (default /Applications/Rational.app)
#   PIE_HOME                   RatioThink support root (default ~/Library/Application Support/RatioThink)
#   RATIOTHINK_DIAG_CRASH_DIR  crash-report dir (default ~/Library/Logs/DiagnosticReports)
#   RATIOTHINK_DIAG_OUT_DIR    where the .zip lands (default ~/Desktop)
set -u

usage() {
  cat <<'USAGE'
Usage: collect-diagnostics.sh [--window <dur>] [--out <path>]

  --window <dur>     Unified Logging look-back window (default: 2h). e.g. 30m, 6h, 1d
  --out <path>       Write the .zip to this exact path (default: ~/Desktop/Rational-diagnostics-<stamp>.zip)
  -h, --help         Show this help

Produces a redacted .zip and prints a terminal summary classifying the failure
mode. Safe to run after a failed launch; never sends anything anywhere.
USAGE
}

WINDOW="2h"
OUT=""
while [ $# -gt 0 ]; do
  case "$1" in
    --window) WINDOW="${2:-}"; shift 2 ;;
    --out)    OUT="${2:-}"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "unknown argument: $1" >&2; usage >&2; exit 2 ;;
  esac
done

APP="${RATIOTHINK_APP:-/Applications/Rational.app}"
ROOT="${PIE_HOME:-$HOME/Library/Application Support/RatioThink}"
LOGS_DIR="$ROOT/logs"
CRASH_DIR="${RATIOTHINK_DIAG_CRASH_DIR:-$HOME/Library/Logs/DiagnosticReports}"
OUT_DIR="${RATIOTHINK_DIAG_OUT_DIR:-$HOME/Desktop}"
HELPER_APP="$APP/Contents/Library/LoginItems/RationalHelper.app"
HELPER_LABEL="com.ratiothink.app.helper"
STAMP="$(date +%Y%m%d-%H%M%S)"
PLISTBUDDY="/usr/libexec/PlistBuddy"

WORKPARENT="$(mktemp -d "${TMPDIR:-/tmp}/ratiothink-diag.XXXXXX")"
WORK="$WORKPARENT/Rational-diagnostics-$STAMP"
mkdir -p "$WORK"
cleanup() { rm -rf "$WORKPARENT"; }
trap cleanup EXIT

REPORT="$WORK/report.txt"
VERDICTS=""   # accumulated, newline-separated
ACTIVITY_VERIFIED=0   # set by classify() iff Unified Logging had recent lines

add_verdict() { VERDICTS="${VERDICTS}$1"$'\n'; }

plist_get() { # <plist> <key>
  [ -f "$1" ] && "$PLISTBUDDY" -c "Print :$2" "$1" 2>/dev/null || true
}

# --- sections ---------------------------------------------------------------

section_versions() {
  local f="$WORK/versions.txt"
  {
    echo "app bundle:    $APP"
    echo "app exists:    $([ -d "$APP" ] && echo yes || echo no)"
    echo "app version:   $(plist_get "$APP/Contents/Info.plist" CFBundleShortVersionString) ($(plist_get "$APP/Contents/Info.plist" CFBundleVersion))"
    echo "helper bundle: $HELPER_APP"
    echo "helper exists: $([ -d "$HELPER_APP" ] && echo yes || echo no)"
    echo "helper version:$(plist_get "$HELPER_APP/Contents/Info.plist" CFBundleShortVersionString) ($(plist_get "$HELPER_APP/Contents/Info.plist" CFBundleVersion))"
    echo "macOS:         $(sw_vers -productVersion 2>/dev/null) ($(sw_vers -buildVersion 2>/dev/null))"
    echo "arch:          $(uname -m)"
  } > "$f" 2>&1
}

section_codesign() {
  local f="$WORK/codesign.txt"
  {
    echo "=== codesign -dv --verbose=4 ==="
    [ -d "$APP" ] && codesign -dv --verbose=4 "$APP" 2>&1 || echo "(app not present)"
    echo
    echo "=== spctl --assess --type execute -vvv ==="
    [ -d "$APP" ] && spctl --assess --type execute -vvv "$APP" 2>&1 || echo "(app not present)"
    echo
    echo "=== quarantine xattr ==="
    if [ -d "$APP" ]; then
      xattr -l "$APP" 2>&1 | grep -i quarantine || echo "(no com.apple.quarantine xattr)"
    else
      echo "(app not present)"
    fi
  } > "$f" 2>&1
}

section_launchctl() {
  local f="$WORK/launchctl.txt"
  {
    echo "=== launchctl print gui/$(id -u)/$HELPER_LABEL ==="
    launchctl print "gui/$(id -u)/$HELPER_LABEL" 2>&1 || echo "(not registered / launchctl error)"
    echo
    echo "=== launchctl list | grep ratiothink ==="
    launchctl list 2>/dev/null | grep -i ratiothink || echo "(no ratiothink jobs listed)"
  } > "$f" 2>&1
}

section_processes() {
  local f="$WORK/processes.txt"
  {
    echo "=== pgrep -fl Rational ==="
    pgrep -fl Rational || echo "(no Rational processes)"
    echo
    echo "=== running pie engine / helper ==="
    ps -Ao pid,comm,args 2>/dev/null | grep -iE 'ratiothink|pie-engine/pie' | grep -v grep || echo "(none)"
  } > "$f" 2>&1
}

section_unified_log() {
  local f="$WORK/unified-log.txt"
  log show --predicate 'subsystem BEGINSWITH "com.ratiothink"' \
    --info --debug --last "$WINDOW" > "$f" 2>&1 || echo "(log show failed)" > "$f"
}

section_crash_reports() {
  local dest="$WORK/crash-reports"
  mkdir -p "$dest"
  if [ -d "$CRASH_DIR" ]; then
    # Case-sensitive, anchored process names only — the engine reports as
    # `pie` (`pie-<date>.ips`). During the RatioThink → Rational compatibility
    # window, collect both current and legacy app/helper crash names so upgrade
    # failures caused by a still-running legacy helper are visible.
    find "$CRASH_DIR" -maxdepth 1 -type f \
      \( -name 'Rational-*' -o -name 'RationalHelper-*' \
         -o -name 'RatioThink-*' -o -name 'RatioThinkHelper-*' \
         -o -name 'pie-[0-9]*' \) \
      -mtime -7 -exec cp {} "$dest/" \; 2>/dev/null || true
  fi
  [ -n "$(ls -A "$dest" 2>/dev/null)" ] || echo "(no recent Rational/RatioThink/pie crash reports)" > "$dest/NONE.txt"
}

section_app_logs() {
  local dest="$WORK/app-logs"
  mkdir -p "$dest"
  if [ -d "$LOGS_DIR" ]; then
    find "$LOGS_DIR" -maxdepth 1 -type f -name '*.log*' \
      -exec cp {} "$dest/" \; 2>/dev/null || true
  fi
  [ -n "$(ls -A "$dest" 2>/dev/null)" ] || echo "(app-owned logs dir empty or absent: $LOGS_DIR)" > "$dest/NONE.txt"
}

# --- classification ---------------------------------------------------------

classify() {
  local unified="$WORK/unified-log.txt"
  local app_log="$LOGS_DIR/app.log"
  local helper_log="$LOGS_DIR/helper.log"
  local engine_log="$LOGS_DIR/engine.log"

  if [ ! -d "$APP" ]; then
    add_verdict "APP_MISSING: Rational.app not found at $APP — was it dragged into /Applications?"
  else
    if xattr -p com.apple.quarantine "$APP" >/dev/null 2>&1; then
      add_verdict "QUARANTINE_PRESENT: Gatekeeper quarantine xattr is set — clear it: xattr -dr com.apple.quarantine \"$APP\""
    fi
    if ! spctl --assess --type execute "$APP" >/dev/null 2>&1; then
      add_verdict "SPCTL_REJECTED: Gatekeeper rejected the app (unsigned / not notarized / damaged) — see codesign.txt"
    fi
  fi

  if ! launchctl print "gui/$(id -u)/$HELPER_LABEL" >/dev/null 2>&1; then
    add_verdict "HELPER_LAUNCHCTL_MISSING: launchd has no '$HELPER_LABEL' agent — the helper was never registered (or registration was rejected)"
  fi

  # Main app crashed: a Rational-* crash report (anchored to exclude the
  # helper's RationalHelper-* reports). This is the single most common
  # "the app does nothing" cause and must not slip through to an OK verdict.
  if find "$CRASH_DIR" -maxdepth 1 -type f -name 'Rational-*' ! -name 'RationalHelper-*' -mtime -7 2>/dev/null | grep -q .; then
    add_verdict "APP_CRASHED: a recent Rational crash report exists — the main app started then crashed; see crash-reports/"
  fi
  if find "$CRASH_DIR" -maxdepth 1 -type f -name 'RatioThink-*' ! -name 'RatioThinkHelper-*' -mtime -7 2>/dev/null | grep -q .; then
    add_verdict "APP_CRASHED_LEGACY: a recent legacy RatioThink crash report exists during the rename migration — see crash-reports/"
  fi

  # Helper crashed / degraded: helper crash reports (current and legacy are
  # independent during rename migration), or a degraded breadcrumb only when no
  # helper crash report exists.
  helper_crash_found=0
  if find "$CRASH_DIR" -maxdepth 1 -type f -name 'RationalHelper-*' -mtime -7 2>/dev/null | grep -q .; then
    add_verdict "HELPER_CRASHED_OR_DEGRADED: a recent Rational Helper crash report exists — see crash-reports/"
    helper_crash_found=1
  fi
  if find "$CRASH_DIR" -maxdepth 1 -type f -name 'RatioThinkHelper-*' -mtime -7 2>/dev/null | grep -q .; then
    add_verdict "HELPER_CRASHED_OR_DEGRADED_LEGACY: a recent legacy RatioThinkHelper crash report exists during the rename migration — see crash-reports/"
    helper_crash_found=1
  fi
  if [ "$helper_crash_found" -eq 0 ] && [ -f "$helper_log" ] && grep -qiE 'helper\.degraded|cannot start' "$helper_log" 2>/dev/null; then
    add_verdict "HELPER_CRASHED_OR_DEGRADED: helper.log shows a degraded boot — see app-logs/helper.log"
  fi

  # Engine failed — GENUINE death signals only (never bare ERROR/FATAL): pie has
  # no FATAL level, and tracing::error! marks RECOVERABLE per-request churn
  # (ws-write / auth / msgpack on a still-serving engine — Vendor/pie
  # runtime/src/server.rs), so matching the level token would false-fire when a
  # user quits mid-stream. The real signals:
  #  · engine.fail breadcrumb in helper.log — the supervisor observed a .failed
  #    transition (incl. bootstrap-fatal via handshake timeout);
  #  · a pie-* crash report;
  #  · a Rust `panicked at` in engine.log (PieSupervisor's stdout/stderr tee —
  #    pie's serve-path tracing goes to pie.log.<date>, NOT stdout, so only
  #    panic prose lands in engine.log);
  #  · pie's serve-path teardown line `driver <name> exited unexpectedly` in the
  #    DATE-ROLLED pie.log.* files (Vendor/pie server/src/serve/lifecycle.rs;
  #    tracing_appender rolling::daily writes pie.log.YYYY-MM-DD, never a literal
  #    `pie.log`).
  local engine_failed=0
  if [ -f "$helper_log" ] && grep -q 'engine\.fail' "$helper_log" 2>/dev/null; then
    engine_failed=1
  fi
  if [ -f "$engine_log" ] && grep -qF 'panicked at' "$engine_log" 2>/dev/null; then
    engine_failed=1
  fi
  for pl in "$LOGS_DIR"/pie.log*; do
    [ -f "$pl" ] || continue
    if grep -qE 'driver .* exited unexpectedly' "$pl" 2>/dev/null; then
      engine_failed=1; break
    fi
  done
  if find "$CRASH_DIR" -maxdepth 1 -type f -name 'pie-[0-9]*' -mtime -7 2>/dev/null | grep -q .; then
    engine_failed=1
  fi
  if [ "$engine_failed" -eq 1 ]; then
    add_verdict "ENGINE_FAILED: an engine failure was recorded — see app-logs/{helper.log,engine.log,pie.log*}, crash-reports/"
  fi

  # Activity / empty-log handling — always actionable, never an empty dir.
  local unified_has_lines=0
  [ -s "$unified" ] && grep -q 'com.ratiothink' "$unified" 2>/dev/null && unified_has_lines=1
  # Surfaced to the OK headline so it only claims "recent activity" when
  # Unified Logging actually returned com.ratiothink lines in the window —
  # breadcrumb files are size-rotated, not time-bounded, so their presence
  # is NOT evidence of recent activity (F2).
  ACTIVITY_VERIFIED="$unified_has_lines"
  if [ ! -f "$helper_log" ]; then
    add_verdict "NOTE: no helper.log breadcrumb — the helper never launched, or never reached its logs dir"
  fi
  if [ ! -f "$app_log" ] && [ ! -f "$helper_log" ]; then
    if [ "$unified_has_lines" -eq 1 ]; then
      add_verdict "NOTE: only Unified Logging is available (no durable breadcrumb files yet) — see unified-log.txt"
    else
      add_verdict "NO_RECENT_ACTIVITY: no Rational Unified Log entries in the last $WINDOW and no breadcrumb logs — the app may not have run"
    fi
  fi
}

# --- redaction --------------------------------------------------------------

redact_all() {
  # Collapse the real home prefix and scrub obvious secrets across every text
  # artifact in the bundle. Diagnostics never bundles chat content (#399), so
  # every collected file is redactable text.
  local home_esc
  home_esc="$(printf '%s' "$HOME" | sed -e 's/[&#\\]/\\&/g')"
  find "$WORK" -type f -print0 2>/dev/null | while IFS= read -r -d '' f; do
    LC_ALL=C sed -i '' -E \
      -e "s#${home_esc}#~#g" \
      -e 's/hf_[A-Za-z0-9]+/hf_REDACTED/g' \
      -e 's/([Bb]earer )[^[:space:]]+/\1REDACTED/g' \
      -e 's/(token|access_token|api_key|apikey)=[^ &"'"'"']+/\1=REDACTED/g' \
      "$f" 2>/dev/null || true
  done
}

# --- run --------------------------------------------------------------------

{
  echo "Rational diagnostics — $STAMP"
  echo "generated by collect-diagnostics.sh (#358)"
  echo "app:    $APP"
  echo "root:   $ROOT"
  echo "window: $WINDOW"
  echo
} > "$REPORT"

section_versions
section_codesign
section_launchctl
section_processes
section_unified_log
section_crash_reports
section_app_logs
classify

VERDICT_BLOCK="================ VERDICTS ================"$'\n'
if [ -n "$VERDICTS" ]; then
  VERDICT_BLOCK="${VERDICT_BLOCK}${VERDICTS}"
elif [ "${ACTIVITY_VERIFIED:-0}" -eq 1 ]; then
  VERDICT_BLOCK="${VERDICT_BLOCK}OK: no failure signature detected — app present, helper registered, recent activity found."$'\n'
else
  VERDICT_BLOCK="${VERDICT_BLOCK}OK: no failure signature detected — app present, helper registered. No recent Unified Log activity confirmed in the last $WINDOW (see unified-log.txt); any breadcrumb logs may be from an earlier run."$'\n'
fi

{
  printf '%s' "$VERDICT_BLOCK"
  echo
  echo "================ FILES ==================="
  ( cd "$WORK" && find . -type f | sed 's#^\./#  #' | sort )
} >> "$REPORT"

redact_all

# Zip (ditto = the correct macOS archiver; keeps the parent dir).
if [ -n "$OUT" ]; then
  ZIP="$OUT"
else
  mkdir -p "$OUT_DIR"
  ZIP="$OUT_DIR/Rational-diagnostics-$STAMP.zip"
fi
mkdir -p "$(dirname "$ZIP")"
ditto -c -k --keepParent "$WORK" "$ZIP" 2>/dev/null || true

# Terminal summary.
echo "Rational diagnostics collected."
echo
printf '%s' "$VERDICT_BLOCK"
echo
if [ -f "$ZIP" ]; then
  echo "Bundle: $ZIP"
  echo "Attach this .zip when reporting the issue."
else
  echo "WARNING: could not write the .zip; the unredacted working copy is at: $WORK"
  trap - EXIT   # keep the working dir so the report is not lost
fi
exit 0
