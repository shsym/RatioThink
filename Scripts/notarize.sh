#!/usr/bin/env bash
# Notarize and staple a Developer ID-signed RatioThink artifact (.app or .dmg).
#
# This is the credential-driven half of the release flow: it submits an
# already-signed artifact to Apple's notary service, waits for the verdict,
# staples the ticket, and validates the result. Signing (Developer ID +
# hardened runtime + secure timestamp) is done upstream by the build —
# Scripts/package-dmg.sh --notarize / make release-dmg-* — so this script
# refuses anything that is not yet Developer ID-signed rather than wasting a
# round-trip to Apple.
#
# Usage:
#   Scripts/notarize.sh <path-to-.app-or-.dmg>
#
# Credentials (first matching mechanism wins):
#   1. Stored keychain profile (xcrun notarytool store-credentials):
#        NOTARY_KEYCHAIN_PROFILE=<profile-name>
#   2. App Store Connect API key (best for CI — no 2FA, no password expiry):
#        NOTARY_API_KEY=<path/to/AuthKey_XXXXXX.p8>
#        NOTARY_API_KEY_ID=<key id>
#        NOTARY_API_ISSUER=<issuer uuid>
#   3. Apple ID + app-specific password:
#        NOTARY_APPLE_ID=<apple-id email>
#        NOTARY_TEAM_ID=<developer team id>
#        NOTARY_PASSWORD=<app-specific password>
#
# Exit codes: 0 ok; 64 usage; 65 bad artifact; 66 not Developer ID-signed;
#             67 no credentials; 1 notarization/staple failure.

set -euo pipefail

die() { echo "notarize: $*" >&2; exit "${2:-1}"; }

ARTIFACT="${1:-}"
if [[ -z "$ARTIFACT" || "$ARTIFACT" == "-h" || "$ARTIFACT" == "--help" ]]; then
  sed -n '2,33p' "$0" >&2
  exit 64
fi
if [[ ! -e "$ARTIFACT" ]]; then
  die "artifact not found: $ARTIFACT" 65
fi

case "$ARTIFACT" in
  *.app) KIND="app" ;;
  *.dmg) KIND="dmg" ;;
  *) die "unsupported artifact (expected .app or .dmg): $ARTIFACT" 65 ;;
esac

# --- require Developer ID signing before contacting Apple -------------
# Notarization rejects ad-hoc / Apple Development / unsigned artifacts with
# a cryptic server-side error. Catch it locally with an actionable message.
SIGN_INFO="$(codesign -dvv "$ARTIFACT" 2>&1 || true)"
if ! grep -q "Authority=Developer ID Application" <<<"$SIGN_INFO"; then
  echo "notarize: '$ARTIFACT' is not signed with a 'Developer ID Application' certificate." >&2
  echo "notarize: notarization needs a paid Apple Developer Program identity." >&2
  echo "notarize: sign it first, e.g.:  make release-dmg-arm64   (Scripts/package-dmg.sh --notarize)" >&2
  echo "notarize: current signing authority:" >&2
  grep -E "Authority=|Signature" <<<"$SIGN_INFO" | sed 's/^/notarize:   /' >&2 || true
  exit 66
fi

# --- resolve notary credentials --------------------------------------
NOTARY_ARGS=()
CRED_DESC=""
if [[ -n "${NOTARY_KEYCHAIN_PROFILE:-}" ]]; then
  NOTARY_ARGS=(--keychain-profile "$NOTARY_KEYCHAIN_PROFILE")
  CRED_DESC="keychain profile '$NOTARY_KEYCHAIN_PROFILE'"
elif [[ -n "${NOTARY_API_KEY:-}" && -n "${NOTARY_API_KEY_ID:-}" && -n "${NOTARY_API_ISSUER:-}" ]]; then
  [[ -f "$NOTARY_API_KEY" ]] || die "NOTARY_API_KEY file not found: $NOTARY_API_KEY" 67
  NOTARY_ARGS=(--key "$NOTARY_API_KEY" --key-id "$NOTARY_API_KEY_ID" --issuer "$NOTARY_API_ISSUER")
  CRED_DESC="App Store Connect API key $NOTARY_API_KEY_ID"
elif [[ -n "${NOTARY_APPLE_ID:-}" && -n "${NOTARY_TEAM_ID:-}" && -n "${NOTARY_PASSWORD:-}" ]]; then
  NOTARY_ARGS=(--apple-id "$NOTARY_APPLE_ID" --team-id "$NOTARY_TEAM_ID" --password "$NOTARY_PASSWORD")
  CRED_DESC="Apple ID $NOTARY_APPLE_ID (team $NOTARY_TEAM_ID)"
else
  cat >&2 <<'EOF'
notarize: no notary credentials found. Set ONE of these credential groups:

  # 1. Stored keychain profile (run once, then reuse):
  xcrun notarytool store-credentials RatioThink-Notary \
      --apple-id you@example.com --team-id ABCDE12345 --password <app-specific-pw>
  export NOTARY_KEYCHAIN_PROFILE=RatioThink-Notary

  # 2. App Store Connect API key (recommended for CI):
  export NOTARY_API_KEY=/path/to/AuthKey_XXXXXX.p8
  export NOTARY_API_KEY_ID=XXXXXXXXXX
  export NOTARY_API_ISSUER=xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx

  # 3. Apple ID + app-specific password:
  export NOTARY_APPLE_ID=you@example.com
  export NOTARY_TEAM_ID=ABCDE12345
  export NOTARY_PASSWORD=<app-specific-password>

Generate an app-specific password at https://appleid.apple.com (Sign-In and
Security > App-Specific Passwords); create an API key at App Store Connect >
Users and Access > Integrations > App Store Connect API.
EOF
  exit 67
fi
echo "notarize: credentials = $CRED_DESC"

# --- submit ----------------------------------------------------------
# notarytool submits a .dmg directly but needs a .app zipped first
# (ditto -c -k --keepParent preserves the bundle + its signature).
WORKDIR="$(mktemp -d)"
trap 'rm -rf "$WORKDIR"' EXIT
if [[ "$KIND" == "app" ]]; then
  SUBMIT_PATH="$WORKDIR/$(basename "$ARTIFACT").zip"
  echo "notarize: zipping app for submission..."
  ditto -c -k --keepParent "$ARTIFACT" "$SUBMIT_PATH"
else
  SUBMIT_PATH="$ARTIFACT"
fi

echo "notarize: submitting $(basename "$SUBMIT_PATH") to Apple (this can take minutes)..."
SUBMIT_JSON="$WORKDIR/submit.json"
set +e
xcrun notarytool submit "$SUBMIT_PATH" "${NOTARY_ARGS[@]}" \
  --wait --output-format json >"$SUBMIT_JSON" 2>"$WORKDIR/submit.err"
SUBMIT_RC=$?
set -e
cat "$WORKDIR/submit.err" >&2 || true

read_json() { python3 -c "import sys,json;print(json.load(open('$1')).get('$2',''))" 2>/dev/null || true; }
SUB_ID="$(read_json "$SUBMIT_JSON" id)"
SUB_STATUS="$(read_json "$SUBMIT_JSON" status)"

if [[ "$SUB_STATUS" != "Accepted" || $SUBMIT_RC -ne 0 ]]; then
  echo "notarize: FAILED — submission status='${SUB_STATUS:-unknown}' (rc=$SUBMIT_RC)." >&2
  if [[ -n "$SUB_ID" ]]; then
    echo "notarize: fetching notary log for $SUB_ID ..." >&2
    xcrun notarytool log "$SUB_ID" "${NOTARY_ARGS[@]}" >&2 2>&1 || true
    echo "notarize: full history: xcrun notarytool history ${NOTARY_ARGS[*]}" >&2
  fi
  exit 1
fi
echo "notarize: accepted (submission $SUB_ID)"

# --- staple + validate -----------------------------------------------
# Staple the ORIGINAL artifact (not the zip) so the ticket travels with the
# bundle/disk image and Gatekeeper passes offline after download.
echo "notarize: stapling ticket to $ARTIFACT ..."
xcrun stapler staple "$ARTIFACT"
xcrun stapler validate "$ARTIFACT"
echo "notarize: SUCCESS — $ARTIFACT notarized + stapled."
