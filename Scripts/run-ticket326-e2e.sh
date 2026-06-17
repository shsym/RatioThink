#!/bin/bash
# #326 merge-checklist E2E — REAL fresh-install model-download recovery.
#
# Drives the full production #326 loop with NO mock and NO
# PIE_TEST_ENGINE_BASE_URL bypass: the App's ModelDownloader fetches the
# seeded default GGUF, then the App's HelperXPCClient +
# EngineStatusStore.startEngine(profileID:) drive a real PieEngineHost
# over a real NSXPCConnection to EngineStatus.running, then an HTTP chat
# round-trip. The test downloads the model itself (the download leg is
# under test), so nothing is pre-staged.
#
# Resolves the bundled `pie` engine + chat-apc resources, sets
# PIE_TEST_MODE=1 (so the anonymous XPC listener accepts an unsigned
# caller), and runs the env-gated S326FreshInstallDownloadE2ETests.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

# --- pie engine binary: release build → app bundle (DerivedData/Applications)
PIE_BIN="${PIE_BIN:-}"
if [ -z "$PIE_BIN" ]; then
  if [ -x "$ROOT/Vendor/pie/target/release/pie" ]; then
    PIE_BIN="$ROOT/Vendor/pie/target/release/pie"
  else
    # Ask xcodebuild where it actually put the built Rational.app instead of
    # guessing the default DerivedData location — that hardcoded
    # `$HOME/Library/Developer/Xcode/DerivedData` assumption breaks on any
    # machine with a custom Xcode DerivedData location or a worktree-local
    # build (#545 / #338). `make build` (the prerequisite this script's error
    # text points at) generates RatioThink.xcodeproj; the shipped bundle is
    # Rational.app (#445 rebrand, PRODUCT_NAME=Rational; the Xcode project name
    # stays RatioThink).
    if [ -d "$ROOT/RatioThink.xcodeproj" ]; then
      # `|| true`: under set -euo pipefail (line 15) a non-zero xcodebuild
      # (unconfigured scheme, signing/toolchain hiccup, transient project lock)
      # would otherwise abort the whole script instead of falling through to the
      # find + installed-app rungs below (#545 review v2 F2).
      products_dir="$(xcodebuild -project "$ROOT/RatioThink.xcodeproj" \
        -scheme RatioThink -configuration Debug -showBuildSettings 2>/dev/null \
        | awk -F' = ' '/ BUILT_PRODUCTS_DIR = /{print $2; exit}' || true)"
      if [ -n "$products_dir" ] \
         && [ -x "$products_dir/Rational.app/Contents/Resources/pie-engine/pie" ]; then
        PIE_BIN="$products_dir/Rational.app/Contents/Resources/pie-engine/pie"
      fi
    fi
    # Fallback: scan the configured DerivedData root (custom location honored,
    # default otherwise) for the most-recent build, then the installed app.
    if [ -z "$PIE_BIN" ]; then
      # `|| true`: `defaults read` exits 1 when the key is ABSENT — the default
      # case on any machine without a custom DerivedData location — and under
      # set -euo pipefail (line 15) that single-command substitution would abort
      # the script before the `${derived_base:-…}` default below, making the
      # find/installed-app fallback unreachable on standard machines (#545
      # review v3 F3). The default on the next line supplies the fallback.
      derived_base="$(defaults read com.apple.dt.Xcode IDECustomDerivedDataLocation 2>/dev/null || true)"
      derived_base="${derived_base:-$HOME/Library/Developer/Xcode/DerivedData}"
      # `|| true`: under set -euo pipefail a missing $derived_base (fresh
      # machine, custom IDECustomDerivedDataLocation, cleaned DerivedData) makes
      # `find` exit 1 — pipefail would abort the script before the
      # /Applications/Rational.app fallback below. `head -1` can also SIGPIPE
      # (141) on a large tree. Guard so resolution falls through (#545 review
      # v2 F1, same class as the pgrep/engine_serve_pids guards).
      PIE_BIN="$(find "$derived_base" \
        -path '*RatioThink*/Build/Products/Debug/Rational.app/Contents/Resources/pie-engine/pie' \
        -type f 2>/dev/null | xargs -I{} stat -f '%m %N' {} 2>/dev/null | sort -rn | head -1 | cut -d' ' -f2- || true)"
    fi
    if [ -z "$PIE_BIN" ] && [ -x "/Applications/Rational.app/Contents/Resources/pie-engine/pie" ]; then
      PIE_BIN="/Applications/Rational.app/Contents/Resources/pie-engine/pie"
    fi
  fi
fi
if [ -z "$PIE_BIN" ] || [ ! -x "$PIE_BIN" ]; then
  echo "e2e326: pie engine binary not found." >&2
  echo "e2e326: build it →  make build   (or  Scripts/build-pie-engine.sh --arch arm64)" >&2
  exit 2
fi

WASM="$ROOT/Inferlets/chat-apc/prebuilt/chat-apc.wasm"
MANIFEST="$ROOT/Inferlets/chat-apc/Pie.toml"
if [ ! -f "$WASM" ] || [ ! -f "$MANIFEST" ]; then
  echo "e2e326: chat-apc resources missing ($WASM / $MANIFEST) — build them →  make build-inferlets" >&2
  exit 2
fi

# --- network preflight (the test does a real ~640 MB HF download) ------
if ! curl -sSf -o /dev/null --max-time 20 -r 0-0 \
  "https://huggingface.co/Qwen/Qwen3-0.6B-GGUF/resolve/main/Qwen3-0.6B-Q8_0.gguf?download=true"; then
  echo "e2e326: cannot reach Hugging Face for the seeded default model — network required." >&2
  exit 2
fi

echo "e2e326: pie engine   = $PIE_BIN"
echo "e2e326: chat-apc wasm = $WASM"

# --- cleanup any stray engine + scratch on exit -----------------------
# Snapshot the `pie serve` PIDs that already exist BEFORE this run so cleanup
# only reaps engines THIS run spawned. The previous unconditional
# `pkill -f 'pie .*serve'` would also kill a developer's seated/manual engine
# (or a concurrent worker session's), the exact unscoped-reap hazard #545
# absorbed (#493).
# `|| true` guards against macOS /bin/bash 3.2 aborting `var="$(pipeline)"` under
# `set -e`+`pipefail` when pgrep finds no engine (rc 1) — the common cold-start
# case. Without it the snapshot line itself would kill the script (#545 / #493).
engine_serve_pids() { pgrep -f 'pie .*serve' 2>/dev/null | sort -u || true; }
PIE_SERVE_PIDS_BEFORE="$(engine_serve_pids)"
cleanup() {
  local pid
  for pid in $(engine_serve_pids); do
    if ! printf '%s\n' "$PIE_SERVE_PIDS_BEFORE" | grep -qx "$pid"; then
      kill "$pid" 2>/dev/null || true
    fi
  done
  rm -rf /tmp/p326-* 2>/dev/null || true
}
trap cleanup EXIT

LOG="$ROOT/test-$(date +%Y%m%d-%H%M%S)-ticket326-e2e.log"
echo "e2e326: running S326FreshInstallDownloadE2ETests (log: $LOG)"
set +e
# PIE_TEST_MODE=1 lets the anonymous XPC listener accept an unsigned
# caller; HelperConfig.assertStartupContract then REQUIRES a non-default
# xpcServiceName so the test never binds the prod `com.ratiothink.helper`
# mach name (the anonymous listener doesn't bind it, but the contract is
# enforced unconditionally).
PIE_TEST_MODE=1 \
PIE_XPC_SERVICE="com.ratiothink.helper.test.t326.$$" \
PIE_TEST_REAL_PIE_BIN="$PIE_BIN" \
PIE_TEST_REAL_CHATAPC_WASM="$WASM" \
PIE_TEST_REAL_CHATAPC_MANIFEST="$MANIFEST" \
  Scripts/run-swift-test.sh --filter S326FreshInstallDownloadE2ETests 2>&1 | tee "$LOG"
rc=${PIPESTATUS[0]}
set -e
echo "e2e326: swift test rc=$rc (log: $LOG)"
exit "$rc"
