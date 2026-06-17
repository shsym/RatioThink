#!/usr/bin/env bash
# Regression test for Scripts/package-dmg.sh stale-staging hardening (ticket #648).
#
# package-dmg.sh reuses a persistent per-arch staging dir
# (build/xcode-<arch>/sym = CONFIGURATION_BUILD_DIR). A prior run's
# RatioThink.app — including the pie engine staged into its Resources — survives
# there. If a build's engine phase is ever skipped, no-op'd, or left half-done
# (interrupted/crashed prior build, manual tampering, or a future opt-out), that
# stale-but-valid engine would ship while every downstream guard still passes.
# package-dmg.sh must wipe $SYM_ROOT before xcodebuild so the build starts from
# clean staging.
#
# Drives the REAL package-dmg.sh with a stub `xcodebuild` on PATH (no cargo, no
# compile, no signing): the stub records whether the planted stale app survived
# into the build and which CONFIGURATION_BUILD_DIR it was handed, then exits
# non-zero to abort the run before the heavyweight DMG steps. Staging is rooted
# under a temp dir via PACKAGE_DMG_BUILD_ROOT, so the test never touches the
# repo's real build/. Mirrors test-verify-dmg-layout.sh (real script, stubbed
# heavy tool).

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PKG="$ROOT/Scripts/package-dmg.sh"

WORK="$(mktemp -d "${TMPDIR:-/tmp}/pie-package-dmg-staging.XXXXXX")"
TARGET_ARCH="arm64"
BUILD_ROOT="$WORK/build"
TARGET_SYM="$BUILD_ROOT/xcode-$TARGET_ARCH/sym"
# package-dmg.sh runs genproject.sh (via relative path, not PATH) when the
# xcodeproj is absent. Create a placeholder only if there is none, and remove it
# in cleanup so the test neither runs xcodegen nor clobbers a real project.
XCODEPROJ="$ROOT/RatioThink.xcodeproj"
MADE_XCODEPROJ=0

cleanup() {
  rm -rf "$WORK"
  [[ "$MADE_XCODEPROJ" -eq 1 ]] && rm -rf "$XCODEPROJ"
  return 0
}
trap cleanup EXIT

# Plant a stale RatioThink.app in the target arch's staging dir; the wipe before
# xcodebuild must remove it.
mkdir -p "$TARGET_SYM/RatioThink.app/Contents/Resources/pie-engine"
echo "stale-engine" >"$TARGET_SYM/RatioThink.app/Contents/Resources/pie-engine/pie"

if [[ ! -e "$XCODEPROJ" ]]; then
  mkdir -p "$XCODEPROJ"
  MADE_XCODEPROJ=1
fi

# Stub xcodebuild: record whether the stale bundle survived into the build and
# the CONFIGURATION_BUILD_DIR it received, then fail so package-dmg.sh aborts
# before make-styled-dmg / codesign / hdiutil.
BIN="$WORK/bin"
mkdir -p "$BIN"
cat >"$BIN/xcodebuild" <<EOF
#!/usr/bin/env bash
sym=""
for a in "\$@"; do
  case "\$a" in CONFIGURATION_BUILD_DIR=*) sym="\${a#CONFIGURATION_BUILD_DIR=}" ;; esac
done
echo "\$sym" >"$WORK/symdir"
if [[ -e "\$sym/RatioThink.app" ]]; then
  echo STALE_PRESENT >"$WORK/marker"
else
  echo STALE_ABSENT >"$WORK/marker"
fi
exit 1
EOF
chmod +x "$BIN/xcodebuild"

# Run the real packager (expected to abort at the stub xcodebuild).
set +e
PATH="$BIN:$PATH" PACKAGE_DMG_BUILD_ROOT="$BUILD_ROOT" \
  "$PKG" --arch "$TARGET_ARCH" --configuration Debug \
  >"$WORK/run.log" 2>&1
rc=$?
set -e

if [[ ! -f "$WORK/marker" ]]; then
  echo "FAIL: package-dmg.sh never reached xcodebuild (rc=$rc):" >&2
  cat "$WORK/run.log" >&2
  exit 1
fi

# Core property: the stale bundle was wiped before the build ran.
marker="$(cat "$WORK/marker")"
if [[ "$marker" != "STALE_ABSENT" ]]; then
  echo "FAIL: stale RatioThink.app survived into the build ($marker)" >&2
  echo "      package-dmg.sh must wipe \$SYM_ROOT before xcodebuild" >&2
  exit 1
fi

# The wiped dir must be the arch-scoped staging dir (build/xcode-<arch>/sym), so
# the wipe is targeted at this arch and not some shared/cross-arch location. A
# mutation that derived a non-arch or wrong-arch CONFIGURATION_BUILD_DIR is
# caught here.
symdir="$(cat "$WORK/symdir")"
if [[ "$symdir" != "$TARGET_SYM" ]]; then
  echo "FAIL: xcodebuild got CONFIGURATION_BUILD_DIR=\"$symdir\"," >&2
  echo "      expected arch-scoped \"$TARGET_SYM\"" >&2
  exit 1
fi

echo "package-dmg.sh stale-staging regression test passed"
