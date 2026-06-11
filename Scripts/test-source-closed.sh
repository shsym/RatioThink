#!/bin/bash
# Regressions for the launchd "source closed / re-enable / interrupt"
# invariants ( v4/v5 F1-F3). `launchctl`/`kill` are stubbed — no real
# agent or process touched.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=lib/proc-acceptance.sh
. "$ROOT/Scripts/lib/proc-acceptance.sh"

HELPER_LABEL="com.ratiothink.app.helper"
GUI_DOMAIN="gui/501"
fails=0

# Stub-controlled launchctl: print-disabled / print return PD_*/PR_* ;
# enable records to REENABLE_CALLS.
PD_RC=0; PD_OUT=""; PR_RC=1; PR_OUT=""; REENABLE_CALLS=""; KILL_CALLS=""; BOOTSTRAP_CALLS=""; BOOTSTRAP_FIXES=0
launchctl() {
  case "$1" in
    print-disabled) printf '%s' "$PD_OUT"; return "$PD_RC" ;;
    print)          printf '%s' "$PR_OUT"; return "$PR_RC" ;;
    enable)         REENABLE_CALLS="$REENABLE_CALLS $2"; return 0 ;;
    bootstrap)      BOOTSTRAP_CALLS="$BOOTSTRAP_CALLS $3"; [ "$BOOTSTRAP_FIXES" = "1" ] && PR_RC=0; return 0 ;;
    *)              return 0 ;;
  esac
}
kill() { KILL_CALLS="$KILL_CALLS $*"; }   # record re-raise, never actually signal
HELPER_PLIST="$(mktemp)"; trap 'rm -f "$HELPER_PLIST"' EXIT   # bootstrap_helper_agent needs a real file

DIS="$(printf '\t"%s" => disabled' "$HELPER_LABEL")"
ENA="$(printf '\t"%s" => enabled'  "$HELPER_LABEL")"
NF="$(printf 'Could not find service "%s" in domain for gui' "$HELPER_LABEL")"

ck() { # ck <expected 0|1> <fn> <desc>
  local want="$1" fn="$2" desc="$3"
  if $fn "$HELPER_LABEL" "$GUI_DOMAIN"; then local got=0; else local got=1; fi
  if [ "$got" = "$want" ]; then echo "ok:  $desc"; else echo "FAIL: $desc (want=$want got=$got)"; fails=$((fails+1)); fi
}

# --- F2: ensure_source_closed (fail closed on inspection failure) --------
PD_RC=0; PD_OUT="$DIS";                ck 0 ensure_source_closed "disabled → closed"
PD_RC=0; PD_OUT="$ENA";                ck 1 ensure_source_closed "enabled → NOT closed"
PD_RC=0; PD_OUT="";   PR_RC=1; PR_OUT="$NF";                 ck 0 ensure_source_closed "absent + service-not-found → closed (not registered)"
PD_RC=1; PD_OUT="";                    ck 1 ensure_source_closed "print-disabled FAILS → fail closed"
PD_RC=0; PD_OUT="";   PR_RC=1; PR_OUT="Bootstrap failed: 5: permission denied"; ck 1 ensure_source_closed "print fails (not not-found) → fail closed"
PD_RC=0; PD_OUT="";   PR_RC=0; PR_OUT="";  ck 1 ensure_source_closed "absent but job loaded → NOT closed"

# --- F1/F3: ensure_agent_enabled (verify re-enable; fail closed) ---------
MYS="$(printf '\t"%s" => mystery' "$HELPER_LABEL")"
PD_RC=0; PD_OUT="";    ck 0 ensure_agent_enabled "no disabled override → enabled"
PD_RC=0; PD_OUT="$ENA"; ck 0 ensure_agent_enabled "explicitly enabled → enabled"
PD_RC=0; PD_OUT="$DIS"; ck 1 ensure_agent_enabled "still disabled (enable failed) → NOT enabled → keep armed"
PD_RC=1; PD_OUT="";    ck 1 ensure_agent_enabled "print-disabled FAILS → not proven enabled → fail closed"
PD_RC=0; PD_OUT="$MYS"; ck 1 ensure_agent_enabled "UNKNOWN enabled-state form → fail closed (F3)"

# --- agent_registered (bootstrapped vs service-not-found) ----------------
PR_RC=0; ck 0 agent_registered "launchctl print ok → registered"
PR_RC=1; ck 1 agent_registered "service-not-found → not registered"

# --- reenable_helper_agent: enabled AND registered → clean restore -------
PD_RC=0; PD_OUT="$ENA"; PR_RC=0; HELPER_REENABLE_NEEDED=1
warn="$(reenable_helper_agent 2>&1 >/dev/null)"
[ -z "$warn" ] && echo "ok:  enabled+registered → clean restore, no warning" || { echo "FAIL: clean restore warned ($warn)"; fails=$((fails+1)); }

# --- reenable: still disabled → loud WARNING (F2) ------------------------
PD_RC=0; PD_OUT="$DIS"; PR_RC=0; HELPER_REENABLE_NEEDED=1
warn="$(reenable_helper_agent 2>&1 >/dev/null)"
case "$warn" in *WARNING*) echo "ok:  still-disabled restore → loud WARNING";; *) echo "FAIL: disabled restore silent ($warn)"; fails=$((fails+1));; esac

# --- reenable: booted out (print=not-found), bootstrap FAILS → WARNING (F1)
PD_RC=0; PD_OUT="$ENA"; PR_RC=1; BOOTSTRAP_FIXES=0; HELPER_REENABLE_NEEDED=1
warn="$(reenable_helper_agent 2>&1 >/dev/null)"
case "$warn" in *WARNING*) echo "ok:  bootout + bootstrap fails → loud WARNING (not silent)";; *) echo "FAIL: bootout/no-restore silent ($warn)"; fails=$((fails+1));; esac

# --- reenable: booted out, bootstrap RESTORES → attempts + no warning (F1)
PD_RC=0; PD_OUT="$ENA"; PR_RC=1; BOOTSTRAP_FIXES=1; BOOTSTRAP_CALLS=""; HELPER_REENABLE_NEEDED=1
reenable_helper_agent >/dev/null 2>&1   # direct call so BOOTSTRAP_CALLS propagates
[ -n "$BOOTSTRAP_CALLS" ] && echo "ok:  bootout restore attempts re-bootstrap" || { echo "FAIL: no bootstrap attempt ($BOOTSTRAP_CALLS)"; fails=$((fails+1)); }
PD_RC=0; PD_OUT="$ENA"; PR_RC=1; BOOTSTRAP_FIXES=1; HELPER_REENABLE_NEEDED=1
warn="$(reenable_helper_agent 2>&1 >/dev/null)"
[ -z "$warn" ] && echo "ok:  bootout + bootstrap restores → no warning" || { echo "FAIL: bootstrap-restored still warned ($warn)"; fails=$((fails+1)); }

# --- disarmed → no action ------------------------------------------------
PD_RC=0; PD_OUT=""; PR_RC=0
REENABLE_CALLS=""; HELPER_REENABLE_NEEDED=0; reenable_helper_agent 2>/dev/null
[ -z "$REENABLE_CALLS" ] && echo "ok:  disarmed → no enable" || { echo "FAIL: disarmed enabled"; fails=$((fails+1)); }

# --- F3: handle_install_signal re-enables AND re-raises (aborts) ---------
REENABLE_CALLS=""; KILL_CALLS=""; HELPER_REENABLE_NEEDED=1
handle_install_signal INT
[ -n "$REENABLE_CALLS" ] && echo "ok:  INT handler re-enables" || { echo "FAIL: INT handler did not re-enable"; fails=$((fails+1)); }
case "$KILL_CALLS" in
  *"-INT $$"*) echo "ok:  INT handler re-raises (kill -INT $$) → aborts, no continue" ;;
  *) echo "FAIL: INT handler did not re-raise (KILL_CALLS=$KILL_CALLS)"; fails=$((fails+1)) ;;
esac

# --- F1: traps armed BEFORE the first launchd mutation -------------------
INSTALL="$ROOT/Scripts/install-app.sh"
arm_ln="$(grep -n 'HELPER_REENABLE_NEEDED=1' "$INSTALL" | head -1 | cut -d: -f1)"
trap_ln="$(grep -n 'trap reenable_helper_agent EXIT' "$INSTALL" | head -1 | cut -d: -f1)"
mut_ln="$(grep -n 'launchctl bootout' "$INSTALL" | head -1 | cut -d: -f1)"
if [ -n "$arm_ln" ] && [ -n "$trap_ln" ] && [ -n "$mut_ln" ] \
   && [ "$arm_ln" -lt "$mut_ln" ] && [ "$trap_ln" -lt "$mut_ln" ]; then
  echo "ok:  install-app arms restore trap (line $trap_ln) + flag (line $arm_ln) BEFORE first launchctl mutation (line $mut_ln)"
else
  echo "FAIL: restore trap/flag not armed before launchctl bootout (arm=$arm_ln trap=$trap_ln mut=$mut_ln)"; fails=$((fails+1))
fi

# --- rename migration: installer keeps build identity, installs Rational ---
if grep -q 'xcodebuild -project RatioThink.xcodeproj -scheme RatioThink' "$INSTALL"; then
  echo "ok:  install-app builds kept project/scheme identity (RatioThink.xcodeproj / RatioThink)"
else
  echo "FAIL: install-app must build kept project/scheme identity RatioThink.xcodeproj / RatioThink"; fails=$((fails+1))
fi
if grep -q '/Rational.app"' "$INSTALL"; then
  echo "ok:  install-app still resolves produced app as Rational.app"
else
  echo "FAIL: install-app must resolve the produced app bundle as Rational.app"; fails=$((fails+1))
fi
if grep -q 'RatioThinkHelper' "$INSTALL"; then
  echo "ok:  install-app explicitly reaps/checks legacy RatioThinkHelper during migration"
else
  echo "FAIL: install-app must include legacy RatioThinkHelper in stale helper cleanup"; fails=$((fails+1))
fi

if [ "$fails" -eq 0 ]; then echo "PASS: source-closed/enable/signal"; exit 0; else echo "FAIL: $fails check(s)"; exit 1; fi
