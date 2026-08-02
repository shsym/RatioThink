#!/usr/bin/env bash
# Build ratio-gateway + the inferlet wasms, stage them into Rational.app, and
# codesign the binary with its own entitlements.
#
# Modelled on Scripts/build-pie-engine.sh. Two constraints inherited from it:
#
#   1. This MUST run as a postCompileScript (pre-CodeSign). Adding a resource
#      after the bundle is signed makes notarization reject the app.
#   2. The outer bundle sign must not strip these entitlements, which is what
#      OTHER_CODE_SIGN_FLAGS: --preserve-metadata=identifier,entitlements,flags
#      on the app target is for.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
GATEWAY_DIR="$REPO_ROOT/Gateway"
ENTITLEMENTS="$REPO_ROOT/Scripts/ratio-gateway.entitlements"

if [[ "${PIE_SKIP_GATEWAY_BUILD:-0}" == "1" ]]; then
  echo "note: PIE_SKIP_GATEWAY_BUILD=1 — skipping gateway build"
  exit 0
fi

# Xcode strips PATH; cargo lives in ~/.cargo/bin.
export PATH="$HOME/.cargo/bin:/opt/homebrew/bin:$PATH"

if ! command -v cargo >/dev/null 2>&1; then
  echo "error: cargo not found — install rustup (https://rustup.rs)" >&2
  exit 1
fi

TRIPLE="${GATEWAY_TRIPLE:-aarch64-apple-darwin}"

echo "==> building ratio-gateway ($TRIPLE)"
( cd "$GATEWAY_DIR" && cargo build --release --locked -p ratio-gateway --target "$TRIPLE" )
BUILT_BIN="$GATEWAY_DIR/target/$TRIPLE/release/ratio-gateway"
[[ -x "$BUILT_BIN" ]] || { echo "error: missing $BUILT_BIN" >&2; exit 1; }

echo "==> building inferlet wasms"
if ! rustup target list --installed 2>/dev/null | grep -q wasm32-wasip2; then
  echo "error: rustup target add wasm32-wasip2" >&2
  exit 1
fi
for inf in chat echo; do
  ( cd "$REPO_ROOT/Inferlets/$inf" && cargo build --release --locked --target wasm32-wasip2 )
done

# Xcode provides these during a real build; fall back for manual runs.
DEST_ROOT="${BUILT_PRODUCTS_DIR:-$REPO_ROOT/build}/${UNLOCALIZED_RESOURCES_FOLDER_PATH:-Rational.app/Contents/Resources}"
DEST_DIR="$DEST_ROOT/gateway"
mkdir -p "$DEST_DIR/inferlets"

cp -f "$BUILT_BIN" "$DEST_DIR/ratio-gateway"
for inf in chat echo; do
  cp -f "$REPO_ROOT/Inferlets/$inf/target/wasm32-wasip2/release/$inf.wasm" "$DEST_DIR/inferlets/$inf.wasm"
  cp -f "$REPO_ROOT/Inferlets/$inf/Pie.toml" "$DEST_DIR/inferlets/$inf.Pie.toml"
done

# Same identity-resolution ladder as build-pie-engine.sh: the expanded value
# Xcode computes, else the raw setting, else ad-hoc.
IDENTITY="${EXPANDED_CODE_SIGN_IDENTITY:-${CODE_SIGN_IDENTITY:--}}"
echo "==> codesigning ratio-gateway (identity: $IDENTITY)"
codesign --force --sign "$IDENTITY" \
  --options runtime \
  --entitlements "$ENTITLEMENTS" \
  "$DEST_DIR/ratio-gateway"

echo "==> staged $(du -h "$DEST_DIR/ratio-gateway" | cut -f1) gateway + $(ls "$DEST_DIR/inferlets"/*.wasm | wc -l | tr -d ' ') wasms into $DEST_DIR"
