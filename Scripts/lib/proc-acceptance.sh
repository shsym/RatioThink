# shellcheck shell=bash
# Process-acceptance helpers for install verification.
#
# Verification must only trust a Helper/engine that belongs to THIS
# install: its executable lives in the freshly-installed bundle AND it
# started at/after the acceptance epoch (recorded after a post-swap reap,
# so nothing is alive at that instant). A stale KeepAlive-respawned
# process — even one whose argv still shows the bundle path after the
# bytes were replaced — started before the epoch and is rejected.
#
# Sourced by install-app.sh; `ps`/`pgrep`/`lsof`/`curl`/`date` are
# overridable as shell functions so this is unit-testable
# (see Scripts/test-proc-acceptance.sh).

# ensure_source_closed <label> <domain> -> 0 if the agent CANNOT launch on
# its own (explicitly disabled, or PROVABLY not registered), 1 otherwise.
# Makes "source closed" an explicit, VERIFIED invariant before the
# acceptance epoch (F1). FAILS CLOSED (returns 1) whenever launchctl
# inspection itself fails (F2): a transient error, bad domain, permission
# issue, or unsupported command must NOT be mistaken for a disabled /
# not-registered agent. The not-registered path is accepted only after a
# SUCCESSFUL `print-disabled` AND a `print` result that specifically means
# service-not-found.
ensure_source_closed() {
  local label="$1" domain="$2" disout disrc disline printout printrc
  disout="$(launchctl print-disabled "$domain" 2>/dev/null)"; disrc=$?
  [ "$disrc" -eq 0 ] || return 1   # can't inspect the disabled set → fail closed
  disline="$(printf '%s\n' "$disout" | grep -F "\"$label\"" || true)"
  if [ -n "$disline" ]; then
    case "$disline" in
      *disabled*|*"=> true"*) return 0 ;;   # explicitly disabled → closed
      *) return 1 ;;                         # enabled / unknown → NOT closed
    esac
  fi
  # Absent from the disabled list: "closed" only if the job is GENUINELY
  # not registered. Distinguish service-not-found from any other failure.
  printout="$(launchctl print "$domain/$label" 2>&1)"; printrc=$?
  [ "$printrc" -ne 0 ] || return 1   # loaded → enabled → not closed
  case "$printout" in
    *"Could not find service"*|*"ould not find"*|*"No such process"*|*"not find"*)
      return 0 ;;                    # provably not registered → closed
    *) return 1 ;;                   # arbitrary inspection failure → fail closed
  esac
}

# ensure_agent_enabled <label> <domain> -> 0 only if the agent is PROVABLY
# enabled (no disabled override), 1 if still disabled OR inspection failed
# (fail closed). Used to verify the re-enable actually took before the
# installer trusts it (F1).
ensure_agent_enabled() {
  local label="$1" domain="$2" disout disrc disline
  disout="$(launchctl print-disabled "$domain" 2>/dev/null)"; disrc=$?
  [ "$disrc" -eq 0 ] || return 1   # can't inspect → not proven enabled
  disline="$(printf '%s\n' "$disout" | grep -F "\"$label\"" || true)"
  [ -z "$disline" ] && return 0    # no disabled override → enabled
  # Fail CLOSED (F3): only an EXPLICIT enabled form proves enabled. A
  # disabled form, or any unrecognized launchctl output for this label,
  # must NOT disarm the restore gate.
  case "$disline" in
    *enabled*|*"=> false"*) return 0 ;;   # explicitly enabled
    *) return 1 ;;                         # disabled OR unknown → not proven
  esac
}

# agent_registered <label> <domain> -> 0 if launchd actually knows the job
# (it was bootstrapped), 1 if service-not-found. `launchctl enable` clears
# the disabled override but does NOT re-register a job that was booted out,
# so "not disabled" is not the same as "available" (F1).
agent_registered() {
  launchctl print "$2/$1" >/dev/null 2>&1
}

# bootstrap_helper_agent -> best-effort re-register the agent from the
# installed plist (we may have booted it OUT to stop respawn). Needs
# HELPER_PLIST. SMAppService-managed agents can reject a manual bootstrap,
# so this is best-effort; the caller verifies + warns if it didn't take.
bootstrap_helper_agent() {
  [ -n "${HELPER_PLIST:-}" ] || return 0
  [ -f "$HELPER_PLIST" ] || return 0
  launchctl bootstrap "${GUI_DOMAIN:?}" "$HELPER_PLIST" 2>/dev/null || true
}

# reenable_helper_agent -> EXIT trap body / restore helper. Re-enables the
# agent iff still armed (HELPER_REENABLE_NEEDED=1), so a failure between
# disable and the explicit re-enable can't leave the user's Helper
# suppressed. Restore must cover EVERYTHING we mutated (F1): we may have
# both disabled AND booted out the agent, so `enable` alone is not enough —
# also re-bootstrap and verify the job is actually registered + enabled.
# Idempotent; status-preserving (trap context); never silent on failure.
reenable_helper_agent() {
  [ "${HELPER_REENABLE_NEEDED:-0}" = "1" ] || return 0
  launchctl enable "${GUI_DOMAIN:?}/${HELPER_LABEL:?}" 2>/dev/null || true
  agent_registered "$HELPER_LABEL" "$GUI_DOMAIN" || bootstrap_helper_agent
  if ensure_agent_enabled "$HELPER_LABEL" "$GUI_DOMAIN" \
     && agent_registered "$HELPER_LABEL" "$GUI_DOMAIN"; then
    return 0
  fi
  echo "install: WARNING — RatioThink Helper agent $HELPER_LABEL is NOT restored (disabled and/or not registered after install)." >&2
  echo "install: relaunch Rational.app to re-register it via SMAppService, or run:" >&2
  echo "install:   launchctl enable $GUI_DOMAIN/$HELPER_LABEL" >&2
  echo "install:   launchctl bootstrap $GUI_DOMAIN \"${HELPER_PLIST:-/Applications/Rational.app/Contents/Library/LaunchAgents/$HELPER_LABEL.plist}\"" >&2
}

# handle_install_signal <sig> -> INT/TERM trap body (F3). Restore the agent
# then RE-RAISE the signal so the install ABORTS — never continues with the
# source reopened (a bare returning signal trap would resume execution).
handle_install_signal() {
  local sig="$1"
  reenable_helper_agent
  trap - "$sig"
  kill -"$sig" "$$"
}

# proc_is_new_bundle <pid> <app_dest> <accept_epoch> -> 0 if new, 1 if stale/foreign
proc_is_new_bundle() {
  local pid="$1" app_dest="$2" accept_epoch="$3" args etimes now start
  args="$(ps -o args= -p "$pid" 2>/dev/null)" || return 1
  case "$args" in "$app_dest/"*) ;; *) return 1 ;; esac
  etimes="$(ps -o etimes= -p "$pid" 2>/dev/null | tr -d ' ')"
  [ -n "$etimes" ] || return 1
  now="$(date +%s)"
  start=$(( now - etimes ))
  # STRICT greater-than (not >=): `etimes` is whole-second, so a process
  # that respawned in the same wall-clock second as the acceptance epoch
  # computes `start == accept_epoch`. The caller adds a one-second barrier
  # (epoch recorded, sleep 1, THEN launch) so a genuinely-new process
  # starts at epoch+1 and clears `> epoch`, while any same-second
  # pre-barrier respawn is rejected. `etimes` truncation only makes
  # `start` later than the true start, so it never ages a new process out.
  [ "$start" -gt "$accept_epoch" ]
}

# http_port <app_dest> <accept_epoch> -> prints the HTTP port served by a
# NEW-bundle pie that answers /v1/models, or returns 1.
http_port() {
  local app_dest="$1" accept_epoch="$2" pid p
  for pid in $(pgrep -x pie 2>/dev/null); do
    proc_is_new_bundle "$pid" "$app_dest" "$accept_epoch" || continue
    for p in $(lsof -nP -p "$pid" 2>/dev/null \
        | awk '/LISTEN/ {print $9}' | grep -oE '[0-9]+$' | sort -u); do
      if curl -s --max-time 3 "http://127.0.0.1:$p/v1/models" 2>/dev/null \
          | grep -q '"data"'; then
        echo "$p"; return 0
      fi
    done
  done
  return 1
}

# stale_procs <app_dest> <accept_epoch> -> prints one line per surviving
# pie/RationalHelper/legacy RatioThinkHelper that is NOT from this install.
stale_procs() {
  local app_dest="$1" accept_epoch="$2" pid
  for pid in $(pgrep -x pie 2>/dev/null) $(pgrep -x RationalHelper 2>/dev/null) $(pgrep -x RatioThinkHelper 2>/dev/null); do
    proc_is_new_bundle "$pid" "$app_dest" "$accept_epoch" \
      || ps -o pid=,comm=,etimes= -p "$pid" 2>/dev/null
  done
}
