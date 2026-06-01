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
    # Most-recent RatioThink.app pie-engine binary built by `make build`.
    PIE_BIN="$(find "$HOME/Library/Developer/Xcode/DerivedData" \
      -path '*RatioThink*/Build/Products/Debug/RatioThink.app/Contents/Resources/pie-engine/pie' \
      -type f 2>/dev/null | xargs -I{} stat -f '%m %N' {} 2>/dev/null | sort -rn | head -1 | cut -d' ' -f2-)"
    if [ -z "$PIE_BIN" ] && [ -x "/Applications/RatioThink.app/Contents/Resources/pie-engine/pie" ]; then
      PIE_BIN="/Applications/RatioThink.app/Contents/Resources/pie-engine/pie"
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
cleanup() {
  pkill -f 'pie .*serve' 2>/dev/null || true
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
