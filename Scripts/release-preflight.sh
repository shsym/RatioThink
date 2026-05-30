#!/usr/bin/env bash
# Release preflight: assess whether a built RatioThink artifact (.app or .dmg)
# would pass Gatekeeper on a user's machine after download — and, when it
# would not, say exactly why and how to fix it.
#
# Reports every dimension the ticket calls for:
#   - quarantine attributes
#   - codesign verification (--deep --strict)
#   - signing identity / team / hardened runtime / secure timestamp
#   - absence of the get-task-allow debug entitlement
#   - spctl assessment (execute for .app, open+primary-signature for .dmg)
#   - notarization / stapling status
#   - helper registration readiness (LoginItems + sealed LaunchAgent + Team ID)
#   - bundled pie engine readiness (present, executable, hardened)
#   - recent Gatekeeper / amfid Unified Log hints
#
# Verdict: exit 0 only when the artifact is codesign-valid, spctl-accepted,
# AND stapled (a real notarized release). Otherwise it prints the full report
# then fails loudly with the remediation steps. Run it on a dev build to see
# precisely which of those three is missing.
#
# Usage:
#   Scripts/release-preflight.sh <path-to-.app-or-.dmg>

set -euo pipefail

ARTIFACT="${1:-}"
if [[ -z "$ARTIFACT" || "$ARTIFACT" == "-h" || "$ARTIFACT" == "--help" ]]; then
  sed -n '2,29p' "$0" >&2
  exit 64
fi
[[ -e "$ARTIFACT" ]] || { echo "preflight: artifact not found: $ARTIFACT" >&2; exit 65; }

case "$ARTIFACT" in
  *.app) KIND="app" ;;
  *.dmg) KIND="dmg" ;;
  *) echo "preflight: unsupported artifact (expected .app or .dmg): $ARTIFACT" >&2; exit 65 ;;
esac

# ASCII tags (not unicode glyphs) so the report is unambiguous in any
# terminal and CI log, and grep-able by the contract test.
PASS="  [ ok ]"; WARN="  [warn]"; FAIL="  [FAIL]"
FAILURES=()
note_fail() { FAILURES+=("$1"); }

hr() { printf '%s\n' "------------------------------------------------------------"; }
section() { hr; echo "$1"; hr; }
# Indent multi-line output by a prefix (avoids sed; SC2001-clean).
indent() {
  local pfx="$1" line
  while IFS= read -r line; do printf '%s%s\n' "$pfx" "$line"; done
}

# Quarantine is informational: a notarized+stapled artifact passes Gatekeeper
# even while quarantined, so its presence is never a failure here.
check_quarantine() {
  local path="$1" q
  q="$(xattr -p com.apple.quarantine "$path" 2>/dev/null || true)"
  if [[ -n "$q" ]]; then
    echo "$WARN quarantine: present ($q)"
  else
    echo "$PASS quarantine: none"
  fi
}

check_codesign() {
  local path="$1" out
  if out="$(codesign --verify --deep --strict --verbose=4 "$path" 2>&1)"; then
    echo "$PASS codesign --verify --deep --strict: valid"
  else
    echo "$FAIL codesign --verify --deep --strict: INVALID"
    indent "      " <<<"$out"
    note_fail "codesign verification failed for $path"
  fi
}

check_identity() {
  local path="$1" info auth team flags
  info="$(codesign -dvvv "$path" 2>&1 || true)"
  # `|| true`: under `set -o pipefail` a no-match grep would otherwise fail the
  # whole substitution and abort the script on any non-Developer ID artifact —
  # exactly the dev-build case this report must handle gracefully.
  auth="$(grep -m1 '^Authority=' <<<"$info" | sed 's/^Authority=//' || true)"
  team="$(grep -m1 '^TeamIdentifier=' <<<"$info" | sed 's/^TeamIdentifier=//' || true)"
  flags="$(grep -m1 '^CodeDirectory' <<<"$info" | grep -o 'flags=[^ ]*' || true)"

  if [[ "$auth" == "Developer ID Application"* ]]; then
    echo "$PASS identity: $auth"
  else
    echo "$FAIL identity: ${auth:-<unsigned/ad-hoc>} (needs 'Developer ID Application' for distribution)"
    note_fail "not signed with a Developer ID Application certificate"
  fi
  if [[ -n "$team" && "$team" != "not set" ]]; then
    echo "$PASS team identifier: $team"
  else
    echo "$WARN team identifier: not set (SMAppService helper needs a Team ID)"
  fi
  if grep -q 'runtime' <<<"$flags"; then
    echo "$PASS hardened runtime: enabled ($flags)"
  else
    echo "$FAIL hardened runtime: DISABLED (${flags:-no flags}) — notarization requires it"
    note_fail "hardened runtime not enabled"
  fi
  if grep -q '^Timestamp=' <<<"$info"; then
    echo "$PASS secure timestamp: $(grep -m1 '^Timestamp=' <<<"$info" | sed 's/^Timestamp=//')"
  else
    echo "$WARN secure timestamp: none (notary service requires a TSA timestamp)"
  fi
}

check_get_task_allow() {
  local path="$1" ents
  ents="$(codesign -d --entitlements :- "$path" 2>/dev/null || true)"
  if grep -q 'get-task-allow' <<<"$ents"; then
    echo "$FAIL get-task-allow: PRESENT (debug entitlement — notarization rejects it; build Release)"
    note_fail "get-task-allow present (use a Release build)"
  else
    echo "$PASS get-task-allow: absent"
  fi
}

# $3 (optional) = an spctl --context value. A .dmg is a disk image, not an
# installer package: `man spctl` defines --type `install` for .pkg and `open`
# for opened documents/images, so a dmg must be assessed `-t open --context
# context:primary-signature` (Apple's documented form) — using `install` would
# spuriously reject a genuinely notarized dmg. The .app keeps `-t execute`.
check_spctl() {
  local path="$1" type="$2" context="${3:-}" out rc
  local args=(--assess --type "$type" --verbose=4)
  local label="spctl --assess --type $type"
  if [[ -n "$context" ]]; then
    args=(--assess --type "$type" --context "$context" --verbose=4)
    label="spctl --assess --type $type --context $context"
  fi
  set +e
  out="$(spctl "${args[@]}" "$path" 2>&1)"
  rc=$?
  set -e
  if [[ $rc -eq 0 ]]; then
    echo "$PASS $label: accepted"
    indent "      " <<<"$out"
  else
    echo "$FAIL $label: REJECTED (rc=$rc)"
    indent "      " <<<"$out"
    note_fail "spctl assessment rejected ($path)"
  fi
}

check_staple() {
  local path="$1" out
  if out="$(xcrun stapler validate "$path" 2>&1)"; then
    echo "$PASS stapled ticket: valid"
  else
    echo "$FAIL stapled ticket: missing/invalid"
    indent "      " <<<"$out"
    note_fail "no stapled notarization ticket on $path"
  fi
}

check_helper() {
  local app="$1" helper plist hteam
  helper="$app/Contents/Library/LoginItems/RatioThinkHelper.app"
  plist="$app/Contents/Library/LaunchAgents/com.ratiothink.app.helper.plist"
  if [[ -d "$helper" ]]; then
    echo "$PASS helper bundle: present (LoginItems/RatioThinkHelper.app)"
    hteam="$(codesign -dvv "$helper" 2>&1 | grep -m1 '^TeamIdentifier=' | sed 's/^TeamIdentifier=//' || true)"
    if [[ -n "$hteam" && "$hteam" != "not set" ]]; then
      echo "$PASS helper team identifier: $hteam"
    else
      echo "$FAIL helper team identifier: not set (SMAppService refuses an ad-hoc/teamless agent)"
      note_fail "helper has no Team ID"
    fi
  else
    echo "$FAIL helper bundle: MISSING ($helper)"
    note_fail "helper bundle missing from app"
  fi
  if [[ -f "$plist" ]]; then
    echo "$PASS helper LaunchAgent plist: sealed in bundle"
  else
    echo "$FAIL helper LaunchAgent plist: MISSING ($plist)"
    note_fail "helper LaunchAgent plist missing"
  fi
}

check_engine() {
  local app="$1" engine eflags
  engine="$app/Contents/Resources/pie-engine/pie"
  if [[ -x "$engine" ]]; then
    echo "$PASS pie engine: present + executable"
    eflags="$(codesign -dvvv "$engine" 2>&1 | grep -m1 '^CodeDirectory' | grep -o 'flags=[^ ]*' || true)"
    if grep -q 'runtime' <<<"$eflags"; then
      echo "$PASS pie engine hardened runtime: enabled ($eflags)"
    else
      echo "$FAIL pie engine hardened runtime: disabled (${eflags:-none})"
      note_fail "pie engine not hardened"
    fi
  else
    echo "$FAIL pie engine: MISSING/not executable ($engine)"
    note_fail "pie engine missing from app"
  fi
}

# Best-effort, time-boxed: only meaningful right after an install/launch/assess.
# RT_PREFLIGHT_SKIP_LOGS=1 skips the (slow) `log show` — used by the contract
# test and useful in CI containers where unified logging is restricted.
log_hints() {
  if [[ "${RT_PREFLIGHT_SKIP_LOGS:-0}" == "1" ]]; then
    return 0
  fi
  section "Recent Gatekeeper / amfid log hints (last 2m, best-effort)"
  local out
  out="$(log show --last 2m --style compact \
    --predicate '(subsystem == "com.apple.syspolicy") OR (process == "amfid") OR (eventMessage CONTAINS[c] "RatioThink")' \
    2>/dev/null | tail -20 || true)"
  if [[ -n "$out" ]]; then
    indent "  " <<<"$out"
  else
    echo "  (no recent matching log entries)"
  fi
}

run_app_checks() {
  local app="$1"
  section "App: $app"
  check_quarantine "$app"
  check_codesign "$app"
  check_identity "$app"
  check_get_task_allow "$app"
  check_spctl "$app" execute
  check_staple "$app"
  check_helper "$app"
  check_engine "$app"
}

echo "preflight: assessing $KIND  $ARTIFACT"

if [[ "$KIND" == "app" ]]; then
  run_app_checks "$ARTIFACT"
else
  section "Disk image: $ARTIFACT"
  check_quarantine "$ARTIFACT"
  check_codesign "$ARTIFACT"
  check_spctl "$ARTIFACT" open "context:primary-signature"
  check_staple "$ARTIFACT"
  # Mount read-only and assess the app inside (what the user actually runs).
  MNT="$(mktemp -d)"
  # shellcheck disable=SC2329  # invoked indirectly via the EXIT trap below
  cleanup() { hdiutil detach "$MNT" >/dev/null 2>&1 || true; rm -rf "$MNT"; }
  trap cleanup EXIT
  echo "preflight: mounting dmg to inspect the app inside..."
  hdiutil attach "$ARTIFACT" -nobrowse -readonly -mountpoint "$MNT" >/dev/null
  APP_INSIDE="$(find "$MNT" -maxdepth 1 -name '*.app' -print -quit)"
  if [[ -n "$APP_INSIDE" ]]; then
    run_app_checks "$APP_INSIDE"
  else
    echo "$FAIL no .app found inside dmg"
    note_fail "dmg contains no .app"
  fi
fi

log_hints

section "Verdict"
if [[ ${#FAILURES[@]} -eq 0 ]]; then
  echo "PASS — artifact is Developer ID-signed, notarized, stapled, and Gatekeeper-accepted."
  echo "A user can download, open, and run it without removing quarantine."
  exit 0
fi
echo "FAIL — ${#FAILURES[@]} blocking issue(s):"
for f in "${FAILURES[@]}"; do echo "  - $f"; done
cat <<'EOF'

Remediation:
  This artifact will NOT pass Gatekeeper as a download. To produce a release
  that does, sign with a Developer ID + notarize + staple:

    1. Install a 'Developer ID Application' certificate (paid Apple Developer
       Program): Xcode > Settings > Accounts > Manage Certificates > + .
    2. Set notary credentials (see Scripts/notarize.sh for the three options).
    3. make release-dmg-arm64        # signs (Developer ID + hardened),
                                      # notarizes + staples the app AND dmg,
                                      # then re-runs this preflight.

  A locally-built unsigned/dev artifact is expected to FAIL here — that is the
  point. For dev use only, clear quarantine manually:
       xattr -dr com.apple.quarantine <path>
EOF
exit 1
