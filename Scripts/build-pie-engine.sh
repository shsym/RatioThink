#!/usr/bin/env bash
# Build the pie engine binary (Vendor/pie -> `pie-server` crate, bin `pie`)
# for one macOS architecture, codesign it with the same identity used by
# the host Rational.app target, and copy the result into the app bundle's
# Resources/pie-engine/ directory.
#
# Two invocation modes:
#
#   1. Xcode build phase (no args): reads $ARCHS, $BUILT_PRODUCTS_DIR,
#      $UNLOCALIZED_RESOURCES_FOLDER_PATH, $EXPANDED_CODE_SIGN_IDENTITY,
#      and $SRCROOT, and bundles the binary into the .app under build.
#
#   2. CLI (--arch <arm64|x86_64> [--dest <dir>] [--identity <id>]):
#      builds out-of-band for arch-specific DMG packaging. $dest defaults
#      to "$SRCROOT/build/pie-engine/<arch>/".
#
# Set PIE_PORTABLE_METAL=1 so the Metal backend is portable
# across Apple Silicon machines without machine-specific shader paths.
# The bin name is `pie` (Vendor/pie/server/Cargo.toml `[[bin]]`).

set -euo pipefail

usage() {
  cat <<'EOF' >&2
Usage:
  Scripts/build-pie-engine.sh                 # Xcode build-phase mode
  Scripts/build-pie-engine.sh --arch <arm64|x86_64> [--dest <dir>] [--identity <id>]
EOF
  exit 64
}

# ---------------------------------------------------------------------
# Parse args / env
# ---------------------------------------------------------------------
ARCH=""
DEST_DIR=""
IDENTITY=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --arch)     ARCH="$2"; shift 2 ;;
    --dest)     DEST_DIR="$2"; shift 2 ;;
    --identity) IDENTITY="$2"; shift 2 ;;
    -h|--help)  usage ;;
    *) echo "unknown arg: $1" >&2; usage ;;
  esac
done

# Repo root (one level above Scripts/).
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
SRCROOT="${SRCROOT:-$REPO_ROOT}"
# shellcheck source=lib/sandbox-diagnostics.sh
. "$REPO_ROOT/Scripts/lib/sandbox-diagnostics.sh"

# CI/static verification mode: Xcode still type-checks and packages the app +
# helper target, but the Rust pie engine build is the slow/runtime long pole.
# This mode is intentionally opt-in and auditable; release/package targets must
# leave it unset so the app bundle contains a real signed engine.
if [[ "${PIE_SKIP_ENGINE_BUILD:-0}" == "1" ]]; then
  echo "build-pie-engine.sh: PIE_SKIP_ENGINE_BUILD=1; skipping cargo pie engine build for compile-only/static verification"
  exit 0
fi

if [[ -z "$ARCH" ]]; then
  # Xcode build-phase mode. $ARCHS is space-separated.
  #
  # Deterministic unit tier opt-out: the app-hosted xcodebuild bundles
  # (RatioThinkTests via `make test-app-unit` / `test-xcode-chat-scaffold`)
  # are headless and never launch the engine, but this phase still cargo-
  # builds + restages + codesigns the engine into Rational.app. On a stale
  # signed app that re-stage fails "Operation not permitted" (insight:483),
  # and the multi-minute cargo build dwarfs the unit run. Set
  # PIE_SKIP_ENGINE_BUILD=1 to no-op the phase.
  #
  # The DMG/release path (Scripts/package-dmg.sh) also runs THIS branch —
  # it invokes xcodebuild without --arch, so the postCompile Run Script
  # lands here, not the --arch CLI mode below. The skip reads ambient
  # process env, which xcodebuild forwards into Run Script phases, so a
  # globally-exported var would otherwise leak into a release build. Gate
  # the skip mechanically on $CONFIGURATION (xcodebuild exports it into the
  # phase): the unit recipes build Debug, package-dmg.sh builds Release, so
  # this can never suppress the engine on the release/packaging path.
  if [[ -n "${PIE_SKIP_ENGINE_BUILD:-}" && "${PIE_SKIP_ENGINE_BUILD}" != "0" \
        && "${CONFIGURATION:-}" != "Release" ]]; then
    echo "build-pie-engine.sh: PIE_SKIP_ENGINE_BUILD set — skipping engine build"
    exit 0
  fi
  # v1 explicitly ships arch-specific DMGs ( §5); universal-
  # binary support is deferred. A multi-arch invocation would stage
  # each arch to the same Resources/pie-engine/pie path and silently
  # ship the last-written one (review v1 F1). Hard-fail here rather
  # than producing a wrong-arch binary that passes Xcode's mtime check.
  if [[ -z "${ARCHS:-}" ]]; then
    echo "build-pie-engine.sh: no --arch and no \$ARCHS set" >&2
    usage
  fi
  arch_count=$(echo "$ARCHS" | wc -w | tr -d ' ')
  if [[ "$arch_count" -gt 1 ]]; then
    echo "build-pie-engine.sh: refusing multi-arch \$ARCHS=\"$ARCHS\"." >&2
    echo "  v1 ships per-arch DMGs (see Scripts/package-dmg.sh). For an" >&2
    echo "  arch-specific build set ARCHS=arm64 ONLY_ACTIVE_ARCH=YES or" >&2
    echo "  use \`make dmg-arm64\` / \`make dmg-x86_64\`. Universal-binary" >&2
    echo "  packaging is deferred ( follow-up)." >&2
    exit 70
  fi
  for a in $ARCHS; do
    "$0" --arch "$a"
  done
  exit 0
fi

case "$ARCH" in
  arm64)   TRIPLE="aarch64-apple-darwin" ;;
  x86_64)  TRIPLE="x86_64-apple-darwin" ;;
  *) echo "unsupported arch: $ARCH (use arm64 or x86_64)" >&2; exit 65 ;;
esac

# ---------------------------------------------------------------------
# Resolve cargo
# ---------------------------------------------------------------------
# Xcode's Run Script phase runs in a minimal PATH that does not include
# ~/.cargo/bin. Probe the standard locations explicitly so build phases
# succeed without users having to edit Xcode's scheme env.
CARGO=""
for candidate in cargo "$HOME/.cargo/bin/cargo" /opt/homebrew/bin/cargo /usr/local/bin/cargo; do
  if command -v "$candidate" >/dev/null 2>&1; then
    CARGO="$(command -v "$candidate")"
    break
  fi
done
if [[ -z "$CARGO" ]]; then
  echo "build-pie-engine.sh: cargo not found (looked in PATH, ~/.cargo/bin, brew)" >&2
  exit 66
fi

# Ensure the rust target is installed. With rustup present we just call
# `target add` (no-op if already there). Without rustup we cannot
# install, so probe rustc directly and fail fast with an actionable
# message — letting cargo run with a missing std emits a linker error
# far from the real cause (review v1 F6).
if command -v rustup >/dev/null 2>&1; then
  rustup target add "$TRIPLE" >/dev/null
else
  RUSTC="$(dirname "$CARGO")/rustc"
  if [[ ! -x "$RUSTC" ]]; then
    RUSTC="rustc"
  fi
  if ! "$RUSTC" --print target-libdir --target "$TRIPLE" >/dev/null 2>&1; then
    echo "build-pie-engine.sh: rust std for $TRIPLE not installed and rustup not on PATH." >&2
    echo "  install rustup (https://rustup.rs) then: rustup target add $TRIPLE" >&2
    exit 71
  fi
fi

# ---------------------------------------------------------------------
# Build
# ---------------------------------------------------------------------
PIE_DIR="$SRCROOT/Vendor/pie"
if [[ ! -f "$PIE_DIR/Cargo.toml" ]]; then
  echo "build-pie-engine.sh: Vendor/pie submodule missing at $PIE_DIR" >&2
  echo "  hint: git submodule update --init Vendor/pie" >&2
  exit 67
fi

# Rust's macOS target spec links with `-nodefaultlibs`, so clang's
# compiler-rt is NOT picked up automatically. ggml-metal-device.m
# uses `@available()`, which Apple clang lowers to a call to
# `__isPlatformVersionAtLeast` — a symbol that lives in
# libclang_rt.osx.a. Without an explicit link, the final `cc` step
# fails with `Undefined symbols: ___isPlatformVersionAtLeast`.
#
# Resolve the resource dir from the same C compiler cargo will actually
# invoke. Cargo's selection order is CC_<triple> → CC → "cc"; match it
# so a divergent host vs cross-compile setup never ends up querying one
# toolchain and linking with another (review v1 F2). Pin `-C linker=$CC_BIN`
# for the same consistency — rustc's linker selection follows the same
# precedence, but making it explicit removes ambiguity.
TRIPLE_USCORE="${TRIPLE//-/_}"
CC_BIN=""
eval "CC_BIN=\"\${CC_${TRIPLE_USCORE}:-}\""
if [[ -z "$CC_BIN" ]]; then
  CC_BIN="${CC:-}"
fi
if [[ -z "$CC_BIN" ]]; then
  CC_BIN="cc"
fi
if ! command -v "$CC_BIN" >/dev/null 2>&1; then
  echo "build-pie-engine.sh: C compiler '$CC_BIN' not found on PATH" >&2
  echo "  hint: install Xcode Command Line Tools (xcode-select --install)" >&2
  echo "        or set CC / CC_${TRIPLE_USCORE} to a valid compiler" >&2
  exit 73
fi

# Capture stdout + exit separately. An empty/erroring -print-resource-dir
# must emit a distinct diagnostic, not the wrong "missing archive"
# message — symmetric with the cargo/rustc probes above (review v1 F3).
RT_BASE="$("$CC_BIN" -print-resource-dir 2>/dev/null)" || true
if [[ -z "$RT_BASE" ]]; then
  echo "build-pie-engine.sh: '$CC_BIN -print-resource-dir' returned no path" >&2
  echo "  hint: the active toolchain is incomplete; reinstall Xcode CLT" >&2
  echo "        (xcode-select --install) or point CC at a working clang" >&2
  exit 74
fi
RT_DIR="$RT_BASE/lib/darwin"
if [[ ! -f "$RT_DIR/libclang_rt.osx.a" ]]; then
  echo "build-pie-engine.sh: libclang_rt.osx.a not found under $RT_DIR" >&2
  echo "  hint: install Xcode Command Line Tools (xcode-select --install)" >&2
  exit 72
fi

# CommandLineTools ships a thin (host-arch-only) compiler-rt archive;
# full Xcode ships a universal slice. Cross-arch builds (e.g. arm64 host
# → x86_64-apple-darwin target) pass the existence check above but
# silently link nothing useful and re-fail at link time with the very
# `___isPlatformVersionAtLeast` symptom this preflight is meant to
# preempt. Probe with `lipo -archs` and require ARCH be present (review
# v1 F1). Phase 5.10 ships per-arch DMGs (`make dmg-arm64` /
# `make dmg-x86_64`), so cross-arch is a live code path.
RT_ARCHS="$(lipo -archs "$RT_DIR/libclang_rt.osx.a" 2>/dev/null || true)"
if [[ -z "$RT_ARCHS" ]] || ! grep -qw "$ARCH" <<<"$RT_ARCHS"; then
  echo "build-pie-engine.sh: $RT_DIR/libclang_rt.osx.a missing $ARCH slice" >&2
  echo "  archive contains: ${RT_ARCHS:-<lipo failed>}" >&2
  echo "  hint: CommandLineTools ships a host-only compiler-rt. Install" >&2
  echo "        full Xcode (universal compiler-rt) for cross-arch builds," >&2
  echo "        or build natively on $ARCH." >&2
  exit 75
fi

# Strip absolute build-machine paths from the engine binary. The compiler bakes
# the source path of every translation unit into panic messages / GGML_ASSERT
# strings / debug info; without remapping, the shipped engine leaks the build
# user's home dir + username (e.g. /Users/<name>/.cargo/...). The release DMG
# must not publish personal paths. Two compilers are involved, so
# two equivalent flags are needed:
#   - rustc: --remap-path-prefix (cargo registry, rustup std, this repo).
#   - clang: -ffile-prefix-map for the ggml/llama C/C++/ObjC sources, which are
#     compiled via the cmake crate (rustc's flag does NOT reach them). CMake
#     seeds CMAKE_<LANG>_FLAGS from CFLAGS/CXXFLAGS/OBJCFLAGS at configure time.
# Both rewrite $HOME -> /home and the repo root -> /src (machine-independent,
# also improves reproducibility). $HOME first, repo root last so a checkout
# under $HOME still resolves to /src.
REMAP_FLAGS="--remap-path-prefix=$HOME=/home --remap-path-prefix=$SRCROOT=/src"
CPREFIX_MAP="-ffile-prefix-map=$HOME=/home -ffile-prefix-map=$SRCROOT=/src"

echo "build-pie-engine.sh: cargo build pie-server ($TRIPLE)"
(
  cd "$PIE_DIR"
  sandbox_diag_run_with_recovery "build-pie-engine" env \
    RUSTFLAGS="${RUSTFLAGS:-} -C linker=$CC_BIN -C link-arg=-L$RT_DIR -C link-arg=-lclang_rt.osx $REMAP_FLAGS" \
    CFLAGS="${CFLAGS:-} $CPREFIX_MAP" \
    CXXFLAGS="${CXXFLAGS:-} $CPREFIX_MAP" \
    OBJCFLAGS="${OBJCFLAGS:-} $CPREFIX_MAP" \
    OBJCXXFLAGS="${OBJCXXFLAGS:-} $CPREFIX_MAP" \
    PIE_PORTABLE_METAL=1 "$CARGO" build --release -p pie-server --target "$TRIPLE"
)

BUILT_BIN="$PIE_DIR/target/$TRIPLE/release/pie"
if [[ ! -x "$BUILT_BIN" ]]; then
  echo "build-pie-engine.sh: expected $BUILT_BIN, not found" >&2
  exit 68
fi

# ---------------------------------------------------------------------
# Stage into destination
# ---------------------------------------------------------------------
if [[ -z "$DEST_DIR" ]]; then
  if [[ -n "${BUILT_PRODUCTS_DIR:-}" && -n "${UNLOCALIZED_RESOURCES_FOLDER_PATH:-}" ]]; then
    # Xcode build-phase mode.
    DEST_DIR="$BUILT_PRODUCTS_DIR/$UNLOCALIZED_RESOURCES_FOLDER_PATH/pie-engine"
  else
    DEST_DIR="$SRCROOT/build/pie-engine/$ARCH"
  fi
fi

mkdir -p "$DEST_DIR"
DEST_BIN="$DEST_DIR/pie"
# `cp -c` (APFS clone) is fast on the staging volume but falls back to
# a plain copy on non-APFS volumes — let cp pick the right path.
cp -f "$BUILT_BIN" "$DEST_BIN"
chmod +x "$DEST_BIN"

# ---------------------------------------------------------------------
# Codesign
# ---------------------------------------------------------------------
# Identity resolution order:
#   1. --identity CLI flag
#   2. EXPANDED_CODE_SIGN_IDENTITY (set by Xcode after CODE_SIGN_IDENTITY
#      is resolved to a specific cert hash)
#   3. CODE_SIGN_IDENTITY (raw user setting, e.g. "-" for ad-hoc)
#   4. "-" (ad-hoc) — matches project.yml default
if [[ -z "$IDENTITY" ]]; then
  IDENTITY="${EXPANDED_CODE_SIGN_IDENTITY:-${CODE_SIGN_IDENTITY:-"-"}}"
fi

ENTITLEMENTS="$SCRIPT_DIR/pie-engine.entitlements"
if [[ ! -f "$ENTITLEMENTS" ]]; then
  echo "build-pie-engine.sh: entitlements not found at $ENTITLEMENTS" >&2
  exit 69
fi

# Timestamp policy: ad-hoc (`-`) does not contact Apple's TSA, but a
# real Developer ID must — Apple's notary service rejects submissions
# whose signatures were produced with `--timestamp=none` (review v1
# F4). Default `--timestamp` (secure TSA) for any non-ad-hoc identity.
TS_FLAGS=(--timestamp)
if [[ "$IDENTITY" == "-" ]]; then
  TS_FLAGS=(--timestamp=none)
fi

echo "build-pie-engine.sh: codesign $DEST_BIN (identity=$IDENTITY)"
codesign --force \
  --sign "$IDENTITY" \
  --options runtime \
  --entitlements "$ENTITLEMENTS" \
  "${TS_FLAGS[@]}" \
  "$DEST_BIN"

echo "build-pie-engine.sh: ok ($DEST_BIN)"
