#!/bin/bash
# Hugging Face cache model-discovery GUI E2E.
#
# Proves a model already staged in the shared HF cache surfaces in the
# real app with no download and no engine launch:
#   Rational.app → Settings (⌘,) → Models tab → an "HF cache" row, and
#   → Profiles → ProfileEditor picker → a split-GGUF model offered with
#     its unsupported reason.
# Both are populated by CachedModelScan → HFCacheCatalog.scan(hfHome:)
# where hfHome == $HF_HOME. The scan is pure filesystem.
#
# The XCUITest runner is sandboxed and CANNOT write the fixture to /tmp
# (EPERM). So this script — running as the normal, unsandboxed user —
# stages the fixture cache + a fresh PIE_HOME on /tmp and hands their
# paths to the test via a config env file. The launched Rational.app is
# NOT sandboxed, so it reads HF_HOME and writes PIE_HOME on /tmp without
# issue. Mirrors Scripts/run-gui-e2e.sh.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

RUN_ROOT="${PIE_TEST_RUN_ROOT:-/tmp/p-cache-discovery-gui-$$}"
HF_HOME="$RUN_ROOT/hf"
PIE_HOME="$RUN_ROOT/home"
CONFIG_FILE="/tmp/pie-cache-discovery-e2e.env"
REV="0123456789abcdef0123456789abcdef01234567"

# Fixture A — a complete safetensors repo (config + tokenizer + weight).
# Surfaces in Settings → Models as an HF-cache row `acme/discovery-model`.
ST_REPO="$HF_HOME/hub/models--acme--discovery-model"
ST_SNAP="$ST_REPO/snapshots/$REV"
# Fixture B — a split-GGUF repo. The two `…-NNNNN-of-MMMMM.gguf` shards
# collapse to one option the engine cannot load; the picker offers it
# carrying its unsupported reason.
GG_REPO="$HF_HOME/hub/models--acme--split-gguf"
GG_SNAP="$GG_REPO/snapshots/$REV"
# Fixture C (#514) — a single-GGUF HF-cache repo mirroring the smallest
# CURATED entry, so Add Model → Curated classifies it "In library".
CU_REPO="$HF_HOME/hub/models--Qwen--Qwen2.5-0.5B-Instruct-GGUF"
CU_SNAP="$CU_REPO/snapshots/$REV"
# Fixture D (#514) — an app-managed install of the recommended curated
# starter (the nested <repo>/<file> slug ModelDownloader places), so
# Add Model → Curated classifies it "Installed".
APP_MODEL_DIR="$PIE_HOME/models/Qwen/Qwen3-0.6B-GGUF"

cleanup() { rm -f "$CONFIG_FILE"; rm -rf "$RUN_ROOT"; }
trap cleanup EXIT

if ! pgrep -x Dock >/dev/null 2>&1; then
  echo "cache-discovery gui e2e: no seated GUI session (Dock not running) — sit at console / Screen Sharing." >&2
  exit 2
fi
if [ "${PIE_TEST_TCC_GRANTED:-}" != "1" ]; then
  echo "cache-discovery gui e2e: Rational.app + XCTest-runner Automation/Accessibility permissions required." >&2
  echo "cache-discovery gui e2e: grant them in System Settings → Privacy & Security, then rerun:" >&2
  echo "cache-discovery gui e2e:   PIE_TEST_TCC_GRANTED=1 Scripts/run-cache-discovery-gui-e2e.sh" >&2
  exit 2
fi

# Stage both fixtures. File CONTENT is irrelevant to discovery — only
# presence + the resolver's config/tokenizer/weight completeness gate.
# refs/main lives outside snapshots/ so it never counts toward sizes.
mkdir -p "$ST_SNAP" "$ST_REPO/refs" "$GG_SNAP" "$GG_REPO/refs" "$PIE_HOME"

printf '%s' "$REV" > "$ST_REPO/refs/main"
printf '{}' > "$ST_SNAP/config.json"
printf '{}' > "$ST_SNAP/tokenizer.json"
head -c 4096 /dev/zero > "$ST_SNAP/model.safetensors"

printf '%s' "$REV" > "$GG_REPO/refs/main"
printf '{}' > "$GG_SNAP/config.json"
printf '{}' > "$GG_SNAP/tokenizer.json"
head -c 2048 /dev/zero > "$GG_SNAP/split-Q4_K_M-00001-of-00002.gguf"
head -c 2048 /dev/zero > "$GG_SNAP/split-Q4_K_M-00002-of-00002.gguf"

# #514 fixtures: leaf names must match the curated catalog exactly —
# availability compares canonical <repo>/<file> slugs.
mkdir -p "$CU_SNAP" "$CU_REPO/refs" "$APP_MODEL_DIR"
printf '%s' "$REV" > "$CU_REPO/refs/main"
printf '{}' > "$CU_SNAP/config.json"
printf '{}' > "$CU_SNAP/tokenizer.json"
head -c 2048 /dev/zero > "$CU_SNAP/qwen2.5-0.5b-instruct-q4_k_m.gguf"
head -c 4096 /dev/zero > "$APP_MODEL_DIR/Qwen3-0.6B-Q8_0.gguf"

rm -f "$CONFIG_FILE"
cat >"$CONFIG_FILE" <<EOF
PIE_TEST_DISCOVERY_HF_HOME=$HF_HOME
PIE_TEST_DISCOVERY_PIE_HOME=$PIE_HOME
EOF

echo "cache-discovery gui e2e: HF_HOME=$HF_HOME"
echo "cache-discovery gui e2e: PIE_HOME=$PIE_HOME"
echo "cache-discovery gui e2e: fixture:"
find "$HF_HOME/hub" -type f | sed "s#$RUN_ROOT/##"
echo "cache-discovery gui e2e: generating Xcode project"
Scripts/genproject.sh

LOG="${PIE_TEST_LOG:-test-$(date +%Y%m%d-%H%M%S)-cache-discovery-gui.log}"
echo "cache-discovery gui e2e: running XCUITest (log: $LOG)"
set +e
xcodebuild -project RatioThink.xcodeproj \
  -scheme RatioThinkGUITests \
  -destination 'platform=macOS,arch=arm64' \
  -parallel-testing-enabled NO \
  test \
  -only-testing:RatioThinkGUITests/S365_CachedModelDiscoveryGUITests/test_staged_cache_model_surfaces_as_hf_cache_row_in_models_tab \
  -only-testing:RatioThinkGUITests/S365_CachedModelDiscoveryGUITests/test_split_gguf_cache_model_shows_unsupported_badge_in_models_tab \
  -only-testing:RatioThinkGUITests/S365_CachedModelDiscoveryGUITests/test_split_gguf_cache_model_shows_unsupported_reason_in_picker \
  -only-testing:RatioThinkGUITests/S514_AddModelDuplicateGUITests/test_add_model_marks_installed_and_hf_cache_curated_rows \
  ENABLE_CODE_COVERAGE=NO 2>&1 | tee "$LOG"
status=${PIPESTATUS[0]}
echo "cache-discovery gui e2e: xcodebuild exit=$status; log: $LOG"
exit $status
