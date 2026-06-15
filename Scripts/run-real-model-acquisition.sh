#!/bin/bash
# Real-model acquisition leg.
#
# Drives the REAL ModelDownloader against live Hugging Face for the
# smallest curated catalog entry (the same coordinates Settings →
# Models → Add Model… enqueues) and asserts the download verifies and
# completes. This is the end-to-end proof of the real-acquisition fix and the
# one leg the cache-seeded tests do not cover (they pre-seed the HF cache).
#
# The acquisition substance lives at the integration tier, NOT the GUI
# tier: pie-mac's SwiftUI Settings TabView is a documented unreliable
# XCUITest surface (tab content is not exposed to app.buttons[...]), so
# the GUI tier asserts only that the Settings tabs exist (S5). No pie
# engine, GUI session, or TCC grant is required here — only network.
#
# Chat-apc send/persist with a real model is covered by  /
# run-chat-gui-e2e.sh.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

TEST='ModelDownloaderTests/test_acquire_smallest_curated_model_live'

# Gate: network reachability to Hugging Face (curl a 1-byte ranged GET
# of a known curated file; the smallest catalog entry as of ).
PROBE="https://huggingface.co/Qwen/Qwen2.5-0.5B-Instruct-GGUF/resolve/main/qwen2.5-0.5b-instruct-q4_k_m.gguf?download=true"
if ! curl -sSf -o /dev/null --max-time 20 -r 0-0 "$PROBE"; then
  echo "acquisition: cannot reach Hugging Face — network required for a real download." >&2
  exit 2
fi

REPO="Qwen/Qwen2.5-0.5B-Instruct-GGUF"
FILE="qwen2.5-0.5b-instruct-q4_k_m.gguf"
MODELS_ROOT="${PIE_TEST_RUN_ROOT:-/tmp/p204-acq-$$}/models"
mkdir -p "$MODELS_ROOT"

echo "acquisition: running live ModelDownloader against Hugging Face"
echo "acquisition: test=$TEST"
echo "acquisition: models root=$MODELS_ROOT"
PIE_TEST_LIVE_HF=1 PIE_TEST_ACQUIRE_MODELS_ROOT="$MODELS_ROOT" \
  Scripts/run-swift-test.sh --filter "$TEST"

# Independent on-disk re-verification: the downloader already asserted
# verification == .verified internally; this is a second, separate
# check that the placed bytes' sha256 equals HF's advertised
# X-Linked-Etag (the LFS content hash on the resolve 302, ).
PLACED="$MODELS_ROOT/$REPO/$FILE"
if [ ! -f "$PLACED" ]; then
  echo "acquisition: placed GGUF not found at $PLACED" >&2
  exit 1
fi
EXPECTED="$(curl -sS -D - -o /dev/null --max-time 30 \
  "https://huggingface.co/$REPO/resolve/main/$FILE?download=true" \
  | awk 'tolower($1) ~ /^x-linked-etag:/ {v=$2; gsub(/[\r"]/,"",v); sub(/^sha256:/,"",v); print tolower(v); exit}')"
if [ -z "$EXPECTED" ]; then
  echo "acquisition: could not read X-Linked-Etag from HF" >&2
  exit 1
fi
ACTUAL="$(shasum -a 256 "$PLACED" | awk '{print $1}')"
if [ "$ACTUAL" != "$EXPECTED" ]; then
  echo "acquisition: on-disk sha256 mismatch for $PLACED" >&2
  echo "acquisition:   expected (HF X-Linked-Etag) = $EXPECTED" >&2
  echo "acquisition:   actual   (on-disk bytes)    = $ACTUAL" >&2
  exit 1
fi
echo "acquisition: on-disk sha256 matches HF X-Linked-Etag ($EXPECTED)"
echo "acquisition: PASS"
