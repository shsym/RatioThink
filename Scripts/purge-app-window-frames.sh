#!/bin/bash
# Purge saved "NSWindow Frame *" keys from the app's REAL defaults domain
# before a seated GUI run (#511, trap first documented in #507).
#
# SwiftUI mints the window-frame autosave key from the WindowGroup's
# environmentObject chain, and AppKit writes it to the app's standard
# defaults (com.ratiothink.app) even when the test launches with an
# isolated PIE_APP_PREFERENCES_SUITE. A frame saved under an old display
# arrangement (or by a previous test at a different size) then restores
# badly for every later launch — XCUITest sees offscreen / stale-size
# windows and "not hittable" controls. Tests cannot purge it themselves:
# the XCTRunner is sandboxed and cannot exec `defaults`.
set -euo pipefail

DOMAIN="com.ratiothink.app"

python3 - "$DOMAIN" <<'EOF'
import plistlib
import subprocess
import sys

domain = sys.argv[1]
try:
    out = subprocess.run(
        ["defaults", "export", domain, "-"],
        capture_output=True, check=True,
    ).stdout
except subprocess.CalledProcessError as e:
    if b"does not exist" in (e.stderr or b""):
        sys.exit(0)  # domain does not exist yet — nothing to purge
    # Any other export failure (corrupt plist, cfprefsd error) must be
    # LOUD: a silently skipped purge resurfaces as offscreen / not-hittable
    # GUI flakes with no breadcrumb (#507 trap).
    sys.stderr.write(f"defaults export {domain} failed: {e.stderr.decode(errors='replace')}\n")
    sys.exit(1)

for key in [k for k in plistlib.loads(out) if k.startswith("NSWindow Frame")]:
    subprocess.run(["defaults", "delete", domain, key], check=True)
    print(f"purged: {key[:60]}…")
EOF
