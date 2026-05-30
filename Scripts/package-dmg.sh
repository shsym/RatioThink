#!/usr/bin/env bash
# Build an arch-specific RatioThink.app and wrap it in RatioThink-<arch>.dmg.
#
# v1 ships separate `RatioThink-arm64.dmg` and `RatioThink-x86_64.dmg`
# instead of a universal binary. Universal-binary packaging is deferred
#
# Usage:
#   Scripts/package-dmg.sh --arch <arm64|x86_64> [--identity <id>]
#                          [--out <dir>] [--configuration <Debug|Release>]
#
# Output: <out>/RatioThink-<arch>.dmg  (default <out> = build/dmg/)
#
# Requires: xcodebuild, hdiutil, cargo (the build phase in project.yml
# invokes Scripts/build-pie-engine.sh which needs the Rust toolchain).

set -euo pipefail

ARCH=""
IDENTITY=""
OUT_DIR=""
CONFIG="Release"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --arch)          ARCH="$2"; shift 2 ;;
    --identity)      IDENTITY="$2"; shift 2 ;;
    --out)           OUT_DIR="$2"; shift 2 ;;
    --configuration) CONFIG="$2"; shift 2 ;;
    -h|--help)
      sed -n '2,16p' "$0" >&2
      exit 64
      ;;
    *) echo "unknown arg: $1" >&2; exit 64 ;;
  esac
done

if [[ -z "$ARCH" ]]; then
  echo "package-dmg.sh: --arch is required (arm64 or x86_64)" >&2
  exit 64
fi
case "$ARCH" in
  arm64|x86_64) ;;
  *) echo "package-dmg.sh: unsupported arch: $ARCH" >&2; exit 65 ;;
esac

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$REPO_ROOT"

OUT_DIR="${OUT_DIR:-$REPO_ROOT/build/dmg}"
mkdir -p "$OUT_DIR"

# Per-arch build dir keeps arm64 and x86_64 artifacts isolated so a
# universal lipo merge (future work) can pick them up without
# re-running xcodebuild.
BUILD_DIR="$REPO_ROOT/build/xcode-$ARCH"
SYM_ROOT="$BUILD_DIR/sym"
OBJ_ROOT="$BUILD_DIR/obj"
DERIVED="$BUILD_DIR/derived"

# Make sure the xcodeproj exists.
if [[ ! -d "RatioThink.xcodeproj" ]]; then
  Scripts/genproject.sh
fi

# Pass identity through to the build-pie-engine.sh phase via env var.
# Xcode forwards $CODE_SIGN_IDENTITY into the script env automatically;
# we override here only when the caller supplied --identity.
SIGN_ARGS=()
if [[ -n "$IDENTITY" ]]; then
  SIGN_ARGS+=("CODE_SIGN_IDENTITY=$IDENTITY")
fi

echo "package-dmg.sh: xcodebuild RatioThink (arch=$ARCH, configuration=$CONFIG)"
xcodebuild \
  -project RatioThink.xcodeproj \
  -scheme RatioThink \
  -configuration "$CONFIG" \
  -destination "platform=macOS,arch=$ARCH" \
  -derivedDataPath "$DERIVED" \
  ARCHS="$ARCH" ONLY_ACTIVE_ARCH=YES \
  CONFIGURATION_BUILD_DIR="$SYM_ROOT" \
  OBJROOT="$OBJ_ROOT" \
  ${SIGN_ARGS[@]+"${SIGN_ARGS[@]}"} \
  build

APP_PATH="$SYM_ROOT/RatioThink.app"
if [[ ! -d "$APP_PATH" ]]; then
  echo "package-dmg.sh: build succeeded but RatioThink.app not found at $APP_PATH" >&2
  exit 70
fi

# Verify the pie engine binary made it into the bundle (
# guardrail — a silent skip of the build phase would ship a broken app).
ENGINE_BIN="$APP_PATH/Contents/Resources/pie-engine/pie"
if [[ ! -x "$ENGINE_BIN" ]]; then
  echo "package-dmg.sh: pie engine missing from bundle ($ENGINE_BIN)" >&2
  exit 71
fi

# Confirm the embedded engine matches the requested arch *exactly*.
# `file -b` on a fat mach-o prints both arches as substrings and arm64e
# strings contain "arm64", so a substring grep would let fat or arm64e
# binaries through (review v1 F5). `lipo -archs` prints space-
# separated arch slices; require exactly one, equal to $ARCH.
ENGINE_ARCHS="$(lipo -archs "$ENGINE_BIN")"
ENGINE_ARCH_COUNT=$(echo "$ENGINE_ARCHS" | wc -w | tr -d ' ')
if [[ "$ENGINE_ARCH_COUNT" -ne 1 || "$ENGINE_ARCHS" != "$ARCH" ]]; then
  echo "package-dmg.sh: engine arch mismatch — expected single \"$ARCH\", got: \"$ENGINE_ARCHS\"" >&2
  exit 72
fi

# Verify the outer bundle seal first. Without this, the per-engine
# entitlement check below cannot tell the difference between "engine
# resigned cleanly inside a valid bundle" and "engine present in a
# bundle whose CodeResources seal is broken" — notarization rejects
# both, but only the strict --verify catches the broken-seal case
# (review v2 F2). --deep walks nested binaries (RatioThinkHelper, the
# engine, frameworks); --strict enforces sealed-resource integrity.
if ! codesign --verify --strict --deep --verbose=2 "$APP_PATH"; then
  echo "package-dmg.sh: bundle signature verification failed for $APP_PATH" >&2
  exit 74
fi

# Confirm the engine still carries its own entitlements after Xcode's
# final CodeSign pass on the bundle (review v1 F3). All four keys
# (allow-jit, allow-unsigned-executable-memory, network.client,
# network.server) must be present — anything less means a higher-up
# resign stripped or replaced them and the engine will fail under
# hardened runtime. No `|| true`: a `codesign -d` failure means the
# engine is entirely unsigned, which should surface as a single
# explicit error rather than four downstream "missing entitlement"
# messages (review v2 F2).
if ! ENGINE_ENTITLEMENTS="$(codesign -d --entitlements :- "$ENGINE_BIN" 2>&1)"; then
  echo "package-dmg.sh: failed to read engine entitlements ($ENGINE_BIN):" >&2
  echo "$ENGINE_ENTITLEMENTS" >&2
  exit 73
fi
for key in com.apple.security.cs.allow-jit \
           com.apple.security.cs.allow-unsigned-executable-memory \
           com.apple.security.network.client \
           com.apple.security.network.server; do
  if ! grep -q "$key" <<<"$ENGINE_ENTITLEMENTS"; then
    echo "package-dmg.sh: engine missing entitlement $key (final bundle resign likely stripped it)" >&2
    exit 73
  fi
done

DMG_PATH="$OUT_DIR/RatioThink-$ARCH.dmg"
rm -f "$DMG_PATH"

# Stage a DMG root holding the app plus an `Applications` symlink so the
# mounted window offers the standard drag-install target (ticket #354).
# `ditto` clones the *verified* bundle — preserving its signature and
# xattrs — into staging, leaving $APP_PATH untouched; hdiutil's
# `-srcfolder` then copies the staged tree (app + symlink) faithfully
# into the HFS+ image, keeping the symlink a symlink.
STAGE_DIR="$BUILD_DIR/dmg-stage"
rm -rf "$STAGE_DIR"
mkdir -p "$STAGE_DIR"
ditto "$APP_PATH" "$STAGE_DIR/RatioThink.app"
ln -s /Applications "$STAGE_DIR/Applications"

echo "package-dmg.sh: hdiutil create $DMG_PATH"
# UDZO = compressed read-only.
hdiutil create \
  -volname "RatioThink" \
  -srcfolder "$STAGE_DIR" \
  -fs HFS+ \
  -format UDZO \
  "$DMG_PATH"

# Mount the finished image and assert the drag-install layout plus that
# the staged app survived packaging with its seal intact. Self-verifying
# packaging — a silent layout/seal regression fails the build here rather
# than shipping a DMG users cannot install from (ticket #354 acceptance).
"$SCRIPT_DIR/verify-dmg-layout.sh" "$DMG_PATH"

echo "package-dmg.sh: ok ($DMG_PATH)"
