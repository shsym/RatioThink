#!/usr/bin/env bash
# Regression test for Scripts/package-dmg.sh stale-staging hardening (ticket #648).
#
# package-dmg.sh reuses a persistent per-arch staging dir
# (build/xcode-<arch>/sym = CONFIGURATION_BUILD_DIR). A prior run's
# RatioThink.app — including the pie engine staged into its Resources — survives
# there. If the next build's engine phase is ever skipped or no-ops (the #643
# PIE_SKIP_ENGINE_BUILD opt-out can, on a --configuration Debug DMG), the stale
# engine would ship while every downstream guard still passes. package-dmg.sh
# must wipe $SYM_ROOT before xcodebuild so the build starts from clean staging.
#
# Drives the REAL package-dmg.sh with a stub `xcodebuild` on PATH (no cargo, no
# compile, no signing): the stub records whether the planted stale app survived
# into the build, then exits non-zero to abort the run before the heavyweight
# DMG steps. Mirrors test-verify-dmg-layout.sh (real script, stubbed heavy tool).

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PKG="$ROOT/Scripts/package-dmg.sh"

WORK="$(mktemp -d "${TMPDIR:-/tmp}/pie-package-dmg-staging.XXXXXX")"
TARGET_ARCH="arm64"
OTHER_ARCH="x86_64"
TARGET_SYM="$ROOT/build/xcode-$TARGET_ARCH/sym"
OTHER_SYM="$ROOT/build/xcode-$OTHER_ARCH/sym"
# package-dmg.sh runs genproject.sh (via relative path, not PATH) when the
# xcodeproj is absent. Create a placeholder only if there is none, and remove it
# in cleanup so the test neither runs xcodegen nor clobbers a real project.
XCODEPROJ="$ROOT/RatioThink.xcodeproj"
MADE_XCODEPROJ=0

cleanup() {
  rm -rf "$WORK" "$TARGET_SYM" "$OTHER_SYM"
  [[ "$MADE_XCODEPROJ" -eq 1 ]] && rm -rf "$XCODEPROJ"
  return 0
}
trap cleanup EXIT

# Plant a stale RatioThink.app in BOTH the target arch's staging dir (must be
# wiped) and the sibling arch's dir (must survive — per-arch isolation).
plant_stale_app() {
  local sym="$1"
  rm -rf "$sym"
  mkdir -p "$sym/RatioThink.app/Contents/Resources/pie-engine"
  echo "stale-engine" >"$sym/RatioThink.app/Contents/Resources/pie-engine/pie"
}
plant_stale_app "$TARGET_SYM"
plant_stale_app "$OTHER_SYM"

if [[ ! -e "$XCODEPROJ" ]]; then
  mkdir -p "$XCODEPROJ"
  MADE_XCODEPROJ=1
fi

# Stub xcodebuild: record whether the stale bundle survived into the build, then
# fail so package-dmg.sh aborts before make-styled-dmg / codesign / hdiutil.
BIN="$WORK/bin"
mkdir -p "$BIN"
cat >"$BIN/xcodebuild" <<EOF
#!/usr/bin/env bash
sym=""
for a in "\$@"; do
  case "\$a" in CONFIGURATION_BUILD_DIR=*) sym="\${a#CONFIGURATION_BUILD_DIR=}" ;; esac
done
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
PATH="$BIN:$PATH" "$PKG" --arch "$TARGET_ARCH" --configuration Debug \
  >"$WORK/run.log" 2>&1
rc=$?
set -e

if [[ ! -f "$WORK/marker" ]]; then
  echo "FAIL: package-dmg.sh never reached xcodebuild (rc=$rc):" >&2
  cat "$WORK/run.log" >&2
  exit 1
fi

marker="$(cat "$WORK/marker")"
if [[ "$marker" != "STALE_ABSENT" ]]; then
  echo "FAIL: stale RatioThink.app survived into the build ($marker)" >&2
  echo "      package-dmg.sh must wipe \$SYM_ROOT before xcodebuild" >&2
  exit 1
fi

# Sibling arch's staging must be untouched (per-arch isolation preserved).
if [[ ! -e "$OTHER_SYM/RatioThink.app" ]]; then
  echo "FAIL: sibling arch staging ($OTHER_SYM) was wiped; only the target" >&2
  echo "      arch's \$SYM_ROOT should be cleaned" >&2
  exit 1
fi

echo "package-dmg.sh stale-staging regression test passed"
