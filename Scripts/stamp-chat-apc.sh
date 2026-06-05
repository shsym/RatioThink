#!/usr/bin/env bash
# Build the chat-apc inferlet and maintain its provenance stamp.
#
#
# Modes (no default — bare invocation prints usage and exits non-zero):
#   build          Build the wasm via
#                  `cargo build --release --locked --target wasm32-wasip2`
#                  and copy it into `prebuilt/`. Does NOT touch the
#                  stamp (CI uses this to prove buildability without
#                  overwriting the committed stamp + wasm).
#   write          `build`, then regenerate
#                  `prebuilt/chat-apc.wasm.stamp` from the current
#                  tree. Use after editing `src/`, manifests, or
#                  bumping the `Vendor/pie` submodule.
#   verify         Read the committed stamp and fail if any field
#                  drifts from the current tree. Does not build,
#                  copy, or write.
#   verify-inputs  Like `verify`, but compares only the source-side
#                  fields (vendor_pie_sha, src_sha256). CI runs this
#                  AFTER `build` to catch Cargo.lock drift / stale-
#                  cache divergence that the pre-build verify cannot
#                  see (review v1 F3).
#
# Stamp file mode is pinned to 0644 regardless of the caller's umask
# (item 6b — avoid drift between local checkouts and CI).

set -euo pipefail

# This script lives at Scripts/stamp-chat-apc.sh.
ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

usage() {
  cat >&2 <<'USAGE'
usage: Scripts/stamp-chat-apc.sh <build|write|verify|verify-inputs>
USAGE
}

# Review v1 F8: no default mode. A bare invocation must NOT mutate
# the committed prebuilt + stamp; print usage + exit non-zero instead.
if [ "$#" -lt 1 ]; then
  usage
  exit 2
fi

MODE="$1"
case "$MODE" in
  build|write|verify|verify-inputs) ;;
  -h|--help|help)
    sed -n '2,/^set -euo/p' "${BASH_SOURCE[0]}" | sed '$d; s/^# \{0,1\}//'
    exit 0
    ;;
  *)
    usage
    exit 2
    ;;
esac

INFERLET_DIR="Inferlets/chat-apc"
PREBUILT_DIR="$INFERLET_DIR/prebuilt"
WASM_OUT="$PREBUILT_DIR/chat-apc.wasm"
STAMP_FILE="$PREBUILT_DIR/chat-apc.wasm.stamp"
BUILT_WASM="$INFERLET_DIR/target/wasm32-wasip2/release/chat_apc.wasm"

needs_build=0
case "$MODE" in
  build|write) needs_build=1 ;;
esac

if [ "$needs_build" = "1" ]; then
  if ! command -v cargo >/dev/null 2>&1; then
    echo "error: cargo not on PATH; install Rust before running '$0 $MODE'" >&2
    exit 1
  fi
  # The pie sdk path-dep lives in the Vendor/pie submodule; the build
  # silently fails with a misleading "package not found" if the
  # submodule was checked out without --recursive.
  if [ ! -f "Vendor/pie/sdk/rust/inferlet/Cargo.toml" ]; then
    echo "error: Vendor/pie submodule looks empty; run 'git submodule update --init --recursive Vendor/pie'" >&2
    exit 1
  fi

  # Review v1 F5: --locked forbids transitive crate version drift
  # between the developer who regenerated the stamp and any later
  # rebuild (CI or otherwise). Cargo.lock IS the input declaration.
  # Strip absolute build-machine paths from the wasm. Without remapping, rustc
  # bakes the build user's home dir + username (cargo registry, rustup std, and
  # this repo path) into the prebuilt artifact's panic/debug strings, which then
  # ship both in git and inside the app bundle. --remap-path-prefix
  # rewrites them to machine-independent roots; this also aids reproducibility.
  REMAP_FLAGS="--remap-path-prefix=$HOME=/home --remap-path-prefix=$ROOT=/src"
  echo "[stamp] cargo build --release --locked --target wasm32-wasip2 ($INFERLET_DIR)"
  (cd "$INFERLET_DIR" && \
    RUSTFLAGS="${RUSTFLAGS:-} $REMAP_FLAGS" \
    cargo build --release --locked --target wasm32-wasip2)

  if [ ! -f "$BUILT_WASM" ]; then
    echo "error: cargo reported success but $BUILT_WASM is missing" >&2
    exit 1
  fi
  mkdir -p "$PREBUILT_DIR"
  cp "$BUILT_WASM" "$WASM_OUT"
  chmod 0644 "$WASM_OUT"
  echo "[stamp] copied $(basename "$BUILT_WASM") -> $WASM_OUT"
fi

if [ "$MODE" = "build" ]; then
  exit 0
fi

# Item 6b: pin perms regardless of caller umask, so the committed stamp
# does not flip mode in CI vs local checkouts.
umask 022

case "$MODE" in
  verify)
    python3 "$INFERLET_DIR/_stamp.py" verify
    ;;
  verify-inputs)
    python3 "$INFERLET_DIR/_stamp.py" verify --inputs-only
    ;;
  write)
    python3 "$INFERLET_DIR/_stamp.py" write
    chmod 0644 "$STAMP_FILE"
    ;;
esac
