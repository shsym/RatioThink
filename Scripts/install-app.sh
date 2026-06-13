#!/bin/bash
# Robust install of Rational.app into /Applications — signed, and VERIFIED
# end-to-end (background Helper + engine + a real chat round-trip) before
# it claims success.
#
# Why this exists: a naive "build then cp over /Applications/Rational.app"
# breaks the background Helper. Rational registers an on-demand launchd agent
# for `com.ratiothink.helper` via SMAppService. Two traps:
#   1. Replacing the bundle under a LIVE registration leaves it stale —
#      BTM still says `enabled` but launchd never reloads the job against
#      the new bundle, so the mach service is never republished and the
#      App's XPC connect fails (4099) forever. The App self-heals on
#      launch (HelperRegistrationReconciler: unregister()+register() when
#      the Helper is unreachable), but only if it actually detects the
#      Helper as unreachable — see trap 2.
#   2. If the OLD Helper process is still alive after the bundle swap, the
#      reconciler probes it, sees "healthy", and does NOT reload — so you
#      keep running the OLD Helper binary. We must stop the stale Helper
#      (and its engine child) so the reconciler force-reloads the NEW one.
#
# Flow: build signed -> verify signature -> quit app -> stop stale
# Helper+engine -> atomic bundle swap (ditto) -> launch -> poll until the
# engine serves and a chat returns, else fail loud with guidance.
#
# First install (no prior registration) registers via the in-app
# first-launch wizard; updates self-heal via the reconciler. Both paths
# end at the same verification gate below.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

APP_DEST="/Applications/Rational.app"
DERIVED_APP=""   # resolved after build
VERIFY_TIMEOUT="${PIE_INSTALL_VERIFY_TIMEOUT:-90}"  # seconds to wait for engine

# --- signing ----------------------------------------------------------
# Team is the cert's Organizational Unit (NOT the code in the cert CN).
# Override per machine: DEVELOPMENT_TEAM=... CODE_SIGN_IDENTITY=... .
# No default team is baked in — set DEVELOPMENT_TEAM to your Apple
# Developer team (or leave empty for personal "Apple Development" signing).
DEVELOPMENT_TEAM="${DEVELOPMENT_TEAM:-}"
CODE_SIGN_IDENTITY="${CODE_SIGN_IDENTITY:-}"
if [ -z "$CODE_SIGN_IDENTITY" ]; then
  # Pin by SHA-1 to dodge "Apple Development" vs "Mac Development"
  # name-resolution ambiguity.
  CODE_SIGN_IDENTITY="$(security find-identity -v -p codesigning 2>/dev/null \
    | awk '/Apple Development/ {gsub(/[")]/,"",$2); print $2; exit}')"
fi
if [ -z "$CODE_SIGN_IDENTITY" ]; then
  echo "install: no 'Apple Development' code-signing identity in keychain." >&2
  echo "install: open Xcode > Settings > Accounts, add your Apple ID, finish 2FA," >&2
  echo "install: then re-run. (SMAppService refuses an unsigned/ad-hoc agent.)" >&2
  exit 2
fi
echo "install: signing identity = $CODE_SIGN_IDENTITY (team $DEVELOPMENT_TEAM)"

# --- build signed -----------------------------------------------------
echo "install: regenerating project + building signed Debug app..."
Scripts/genproject.sh >/dev/null
xcodebuild -project RatioThink.xcodeproj -scheme RatioThink \
  -destination 'platform=macOS,arch=arm64' -configuration Debug \
  CODE_SIGN_STYLE=Manual \
  CODE_SIGN_IDENTITY="$CODE_SIGN_IDENTITY" \
  DEVELOPMENT_TEAM="$DEVELOPMENT_TEAM" \
  PROVISIONING_PROFILE_SPECIFIER='' \
  build

DERIVED_APP="$(xcodebuild -project RatioThink.xcodeproj -scheme RatioThink \
  -destination 'platform=macOS,arch=arm64' -configuration Debug \
  -showBuildSettings 2>/dev/null \
  | awk '/ BUILT_PRODUCTS_DIR =/ {print $3; exit}')/Rational.app"
if [ ! -d "$DERIVED_APP" ]; then
  echo "install: could not locate built Rational.app at '$DERIVED_APP'" >&2
  exit 1
fi

# The "Build pie engine binary" build phase re-signs the nested
# Contents/Resources/pie-engine/pie AFTER Xcode seals Rational.app, which
# invalidates the outer bundle's seal ("a sealed resource is missing or
# invalid"). Re-seal the top-level bundle over its now-final contents
# before verifying. (Nested code — RationalHelper.app, the engine — keep their
# own valid signatures; only the outer seal is recomputed.)
echo "install: re-sealing app bundle (nested engine was re-signed post-seal)..."
codesign --force --sign "$CODE_SIGN_IDENTITY" \
  --preserve-metadata=identifier,entitlements,flags --timestamp=none "$DERIVED_APP"

echo "install: verifying signature..."
codesign --verify --deep --strict "$DERIVED_APP"
TEAM_OK="$(codesign -dvv "$DERIVED_APP" 2>&1 | awk -F= '/TeamIdentifier/ {print $2}')"
echo "install: built $DERIVED_APP (team $TEAM_OK)"

# --- close the source: disable the launchd agent ---------------------
# launchd (RunAtLoad/KeepAlive) can respawn the Helper independently —
# during the swap/reap, or in the window between our last reap check and
# `open`. Disabling the agent stops it from launching on its own, so the
# reaped slate stays clean and the ONLY thing that can start the Helper
# afterwards is the new app launch/repair we explicitly trigger (F1). Re-
# enabled just before launch below.
HELPER_LABEL="com.ratiothink.app.helper"
GUI_DOMAIN="gui/$(id -u)"
HELPER_PLIST="$APP_DEST/Contents/Library/LaunchAgents/$HELPER_LABEL.plist"
export HELPER_LABEL GUI_DOMAIN HELPER_PLIST
# shellcheck source=lib/proc-acceptance.sh
. "$ROOT/Scripts/lib/proc-acceptance.sh"

# Arm the restore traps BEFORE the first launchd mutation (F1): an
# interrupt/TERM landing during `launchctl disable` — or in the window
# before arming — would otherwise exit via the default disposition with
# the agent half-disabled and no cleanup. The handlers are idempotent
# (re-enabling a not-yet-disabled agent is a harmless no-op), so arming
# pre-mutation is safe. EXIT is status-preserving cleanup; INT/TERM
# re-enable then RE-RAISE so cancellation ABORTS rather than continuing
# with the source reopened (F3).
HELPER_REENABLE_NEEDED=1
trap reenable_helper_agent EXIT
trap 'handle_install_signal INT'  INT
trap 'handle_install_signal TERM' TERM

echo "install: disabling launchd agent $HELPER_LABEL (stop independent respawn)..."
launchctl bootout "$GUI_DOMAIN/$HELPER_LABEL" 2>/dev/null || true
launchctl disable "$GUI_DOMAIN/$HELPER_LABEL" 2>/dev/null || true

# F1: the disable is best-effort, so VERIFY the source is actually closed
# before trusting the post-epoch acceptance window. Only a genuinely
# not-registered agent (fresh machine) or an explicitly-disabled one is
# acceptable; a still-enabled registered agent could respawn after the
# epoch and be blessed as the new install.
if ! ensure_source_closed "$HELPER_LABEL" "$GUI_DOMAIN"; then
  echo "install: FAILED — could not disable launchd agent $HELPER_LABEL;" >&2
  echo "install: it is still enabled and could respawn a stale Helper after launch." >&2
  echo "install: run 'launchctl bootout $GUI_DOMAIN/$HELPER_LABEL; launchctl disable $GUI_DOMAIN/$HELPER_LABEL' and re-run." >&2
  exit 1
fi

# --- quit running app + stop stale Helper/engine ----------------------
# Order matters: quit the App first, then stop the stale Helper+engine so
# the freshly-launched App finds com.ratiothink.helper unreachable and the
# reconciler force-reloads the NEW Helper binary (trap 2 above).
echo "install: quitting running Rational..."
osascript -e 'tell application "Rational" to quit' >/dev/null 2>&1 || true
sleep 2
pkill -x Rational 2>/dev/null || true

echo "install: stopping stale Helper + engine so the new binary loads..."
for helper_name in RationalHelper RatioThinkHelper; do
  pkill -x "$helper_name" 2>/dev/null || true
done
pkill -x pie 2>/dev/null || true
sleep 1

# --- atomic bundle swap (ditto preserves signing/xattrs) --------------
echo "install: installing into ${APP_DEST}..."
STAGE="$(dirname "$APP_DEST")/.Rational.app.installing.$$"
rm -rf "$STAGE"
ditto "$DERIVED_APP" "$STAGE"
rm -rf "$APP_DEST"
mv "$STAGE" "$APP_DEST"
codesign --verify --deep --strict "$APP_DEST"
echo "install: installed + verified."

# --- post-swap reap: guarantee a clean slate AT the acceptance epoch ---
# The agent is disabled (above), so nothing can respawn independently.
# Reap once more AFTER the bundle is in place and confirm nothing survives.
echo "install: reaping any respawned stale Helper/engine post-swap..."
for helper_name in RationalHelper RatioThinkHelper; do
  pkill -x "$helper_name" 2>/dev/null || true
done
pkill -x pie 2>/dev/null || true
sleep 1
for pid in $(pgrep -x pie 2>/dev/null) $(pgrep -x RationalHelper 2>/dev/null) $(pgrep -x RatioThinkHelper 2>/dev/null); do
  kill -9 "$pid" 2>/dev/null || true
done
sleep 1
if pgrep -x pie >/dev/null 2>&1 || pgrep -x RationalHelper >/dev/null 2>&1 || pgrep -x RatioThinkHelper >/dev/null 2>&1; then
  echo "install: FAILED — could not reap stale Helper/engine before launch:" >&2
  ps -o pid=,comm=,etimes= $(pgrep -x pie; pgrep -x RationalHelper; pgrep -x RatioThinkHelper) 2>/dev/null | sed 's/^/install:   /' >&2
  echo "install: kill them manually (kill -9 <pid>) and re-run." >&2
  exit 1
fi

# Acceptance epoch + one-second barrier (F1): record the epoch on a clean,
# disabled slate, then sleep 1 so anything THIS launch starts lands at
# epoch+1 and clears the strict `start > epoch` check — while any
# same-second pre-barrier respawn (impossible while disabled, but defended
# anyway) computes start == epoch and is rejected.
INSTALL_EPOCH="$(date +%s)"
sleep 1

# Re-enable the agent so the new app launch / reconciler register() can
# bring the Helper up. This is the ONLY explicit action that re-opens the
# source, AFTER the acceptance boundary.
echo "install: re-enabling launchd agent $HELPER_LABEL..."
launchctl enable "$GUI_DOMAIN/$HELPER_LABEL" 2>/dev/null || true
# Restore must cover what was mutated (F1): we may have booted the agent
# OUT, so also re-bootstrap if launchd no longer knows the job.
agent_registered "$HELPER_LABEL" "$GUI_DOMAIN" || bootstrap_helper_agent
# Disarm the restore trap ONLY once the agent is provably enabled AND
# registered. If it is enabled but not yet registered, that's expected on
# this path — the imminent app launch re-registers it via SMAppService —
# so KEEP the trap armed so the EXIT cleanup re-verifies and warns loudly
# if the Helper never comes back. A still-DISABLED agent is a hard failure.
if ! ensure_agent_enabled "$HELPER_LABEL" "$GUI_DOMAIN"; then
  echo "install: FAILED — could not re-enable launchd agent $HELPER_LABEL (still disabled)." >&2
  echo "install: the restore trap stays armed and retries on exit; if it persists, run:" >&2
  echo "install:   launchctl enable $GUI_DOMAIN/$HELPER_LABEL" >&2
  exit 1
fi
if agent_registered "$HELPER_LABEL" "$GUI_DOMAIN"; then
  HELPER_REENABLE_NEEDED=0   # fully restored by the script
else
  echo "install: note — agent enabled but not yet registered; the app launch will re-register it (SMAppService)." >&2
  echo "install: restore trap stays armed to verify + warn on exit if it does not."
fi

# --- launch -----------------------------------------------------------
echo "install: launching..."
open "$APP_DEST"

# --- verify end-to-end ------------------------------------------------
echo "install: waiting up to ${VERIFY_TIMEOUT}s for the engine to serve..."
deadline=$(( $(date +%s) + VERIFY_TIMEOUT ))
PORT=""
while [ "$(date +%s)" -lt "$deadline" ]; do
  if PORT="$(http_port "$APP_DEST" "$INSTALL_EPOCH")"; then break; fi
  sleep 2
done

if [ -z "$PORT" ]; then
  echo "" >&2
  echo "install: FAILED — no engine from the NEW install (${APP_DEST}) served within ${VERIFY_TIMEOUT}s." >&2
  echo "install: Helper running: $(pgrep -x RationalHelper >/dev/null && echo yes || pgrep -x RatioThinkHelper >/dev/null && echo legacy-RatioThinkHelper || echo NO)" >&2
  echo "install: engine running: $(pgrep -x pie >/dev/null && echo yes || echo NO)" >&2
  STALE="$(stale_procs "$APP_DEST" "$INSTALL_EPOCH")"
  if [ -n "$STALE" ]; then
    echo "install: STALE processes from a previous install survived the pkill — the new Helper was NOT loaded:" >&2
    echo "$STALE" | sed 's/^/install:   /' >&2
    echo "install: kill them (kill -9 <pid>) and re-run, or quit Rational fully first." >&2
  else
    echo "install: Most likely cause: SMAppService needs your approval (or the seeded model isn't downloaded yet)." >&2
    echo "install:   System Settings > General > Login Items & Extensions → enable 'Rational', then re-run." >&2
  fi
  exit 1
fi

MODEL_ID="$(curl -s --max-time 5 "http://127.0.0.1:$PORT/v1/models" 2>/dev/null \
  | python3 -c "import sys,json;print(json.load(sys.stdin)['data'][0]['id'])" 2>/dev/null)"
echo "install: engine serving on port $PORT — model id '$MODEL_ID'"

echo "install: chat round-trip..."
REPLY="$(curl -s --max-time 60 -X POST "http://127.0.0.1:$PORT/v1/chat/completions" \
  -H 'Content-Type: application/json' \
  -d "{\"model\":\"$MODEL_ID\",\"messages\":[{\"role\":\"user\",\"content\":\"/no_think Reply with exactly: pong\"}],\"max_tokens\":32,\"stream\":false}" 2>/dev/null \
  | python3 -c "import sys,json;d=json.load(sys.stdin);m=d['choices'][0]['message'];print(' '.join((m.get('content') or m.get('reasoning_content') or '').split()))" 2>/dev/null)"

if [ -z "$REPLY" ]; then
  echo "install: FAILED — chat round-trip returned no content (engine up but not generating)." >&2
  exit 1
fi
echo "install: chat OK — engine replied: ${REPLY:0:80}"
echo ""
echo "install: SUCCESS — Rational installed, Helper + engine running, chat verified."
