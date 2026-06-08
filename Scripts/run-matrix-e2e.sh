#!/usr/bin/env bash
# #473 — REAL-engine compatibility matrix: every curated model × profile.
#
# Drives the production launch path (real LaunchSpecResolver → real
# PieControlLauncher → real `pie serve` → HTTP) once per curated model and
# fires all three profile request shapes against that single booted engine:
#   · chat            → POST /v1/chat/completions
#   · tree-of-thought → POST /v1/inferlet {inferlet:"tree-of-thought"}
#   · fast-think      → POST /v1/chat/completions + a `speculation` field
# Routing is per-REQUEST, not per-launch-profile, so one loaded model proves
# every profile against it — 10 boots / 30 cells instead of 30 cold boots
# (decisive for the slow ~9 GB 14B loads).
#
# The FULL run downloads ~36 GB (incl. two ~9 GB 14B models) and runs the
# real Metal engine for every cell — minutes to hours. It must NEVER run by
# default or in CI, so it is behind a single explicit env gate
# (PIE_TEST_E2E_MATRIX=1) and is wired to no aggregate/CI Make target.
#
# Per cell it prints a `MATRIX-CELL <model> <profile> PASS|FAIL` line; this
# wrapper aggregates them into a table and exits non-zero on any FAIL (or on
# a model that booted-but-emitted-no-cells = a load failure).
#
# Tunables (all optional):
#   PIE_TEST_E2E_PROFILES        csv subset of chat,tree-of-thought,fast-think  (default: all)
#   PIE_TEST_E2E_MATRIX_MODELS   csv of case-insensitive substrings; keep only matching models
#   PIE_BIN                      pie engine binary (default: the worktree release build)
#   PIE_TEST_E2E_MODELS_DIR      staging dir for downloaded GGUFs (default: /tmp/pie-e2e-models)
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

# --- single explicit operator gate ------------------------------------
if [ "${PIE_TEST_E2E_MATRIX:-}" != "1" ]; then
  echo "matrix: refusing to run without explicit opt-in." >&2
  echo "matrix: the full matrix downloads ~36 GB and runs the real Metal engine for 30 cells." >&2
  echo "matrix: opt in with the env gate:" >&2
  echo "matrix:     PIE_TEST_E2E_MATRIX=1 Scripts/run-matrix-e2e.sh" >&2
  echo "matrix: or via make:  RUN_MATRIX=1 make test-e2e-matrix" >&2
  exit 2
fi

# --- the matrix model coordinates -------------------------------------
# KEEP IN SYNC WITH Shared/CuratedModelCatalog.swift (CuratedModelCatalog.all).
# MatrixModelCatalogSyncTests parses this block and hard-fails on any drift
# (a model added/removed/resized in the catalog but not here, or vice versa).
# Fields: <hfRepo>|<hfFile>|<minBytes = approximateSizeBytes>|<thinking 0|1>
# `thinking=1` (Qwen3 family) flips PIE_TEST_REAL_EXPECT_REASONING=1 so the
# chat/fast-think cells also assert the reasoning-channel split (#329).
MATRIX_MODELS=(
  "Qwen/Qwen2.5-0.5B-Instruct-GGUF|qwen2.5-0.5b-instruct-q4_k_m.gguf|491400032|0"
  "Qwen/Qwen3-0.6B-GGUF|Qwen3-0.6B-Q8_0.gguf|639446688|1"
  "bartowski/Llama-3.2-1B-Instruct-GGUF|Llama-3.2-1B-Instruct-Q4_K_M.gguf|807694464|0"
  "Qwen/Qwen2.5-1.5B-Instruct-GGUF|qwen2.5-1.5b-instruct-q4_k_m.gguf|1117000000|0"
  "bartowski/Llama-3.2-3B-Instruct-GGUF|Llama-3.2-3B-Instruct-Q4_K_M.gguf|2020000000|0"
  "bartowski/Phi-3.5-mini-instruct-GGUF|Phi-3.5-mini-instruct-Q4_K_M.gguf|2390000000|0"
  "bartowski/Qwen2.5-7B-Instruct-GGUF|Qwen2.5-7B-Instruct-Q4_K_M.gguf|4683074240|0"
  "bartowski/Meta-Llama-3.1-8B-Instruct-GGUF|Meta-Llama-3.1-8B-Instruct-Q4_K_M.gguf|4920000000|0"
  "bartowski/Qwen2.5-Coder-14B-Instruct-GGUF|Qwen2.5-Coder-14B-Instruct-Q4_K_M.gguf|8988111072|0"
  "Qwen/Qwen3-14B-GGUF|Qwen3-14B-Q4_K_M.gguf|9001752960|1"
)

ALL_PROFILES="chat,tree-of-thought,fast-think"
PROFILES="${PIE_TEST_E2E_PROFILES:-$ALL_PROFILES}"
MODEL_FILTER="${PIE_TEST_E2E_MATRIX_MODELS:-}"

# --- pie engine binary: enforce the worktree build --------------------
# Like run-large-model-e2e.sh: a stale /Applications engine must not green
# this proof. run-engine-e2e.sh honors PIE_BIN; pin it to the worktree.
find_worktree_pie() {
  local p
  for p in \
    "$ROOT/Vendor/pie/target/release/pie" \
    "$ROOT/Vendor/pie/target/aarch64-apple-darwin/release/pie"
  do
    [ -x "$p" ] && { printf '%s\n' "$p"; return 0; }
  done
  return 1
}
PIE_BIN="${PIE_BIN:-$(find_worktree_pie || true)}"
if [ -z "$PIE_BIN" ] || [ ! -x "$PIE_BIN" ]; then
  echo "matrix: worktree pie binary not found — build it:  make engine-build" >&2
  echo "matrix: expected under Vendor/pie/target/.../release/pie" >&2
  exit 2
fi
export PIE_BIN

echo "matrix: pie engine = $PIE_BIN"
echo "matrix: profiles   = $PROFILES"
[ -n "$MODEL_FILTER" ] && echo "matrix: model filter = $MODEL_FILTER"

# --- run the matrix ---------------------------------------------------
mkdir -p "$ROOT/logs"
STAMP="$(date +%Y%m%d-%H%M%S)"
SUMMARY="$ROOT/logs/test-$STAMP-matrix-e2e.summary.log"
: > "$SUMMARY"

PASS_COUNT=0
FAIL_COUNT=0
overall_rc=0

for entry in "${MATRIX_MODELS[@]}"; do
  IFS='|' read -r repo file minbytes thinking <<< "$entry"
  slug="$repo/$file"

  if [ -n "$MODEL_FILTER" ]; then
    keep=0
    IFS=',' read -ra filters <<< "$MODEL_FILTER"
    for f in "${filters[@]}"; do
      f="$(printf '%s' "$f" | tr -d '[:space:]')"
      [ -n "$f" ] && printf '%s' "$slug" | grep -qiF "$f" && { keep=1; break; }
    done
    [ "$keep" = "1" ] || { echo "matrix: skip (filtered) $slug"; continue; }
  fi

  echo ""
  echo "==== MATRIX MODEL: $slug  (thinking=$thinking)  profiles=[$PROFILES] ===="
  CELL_LOG="$ROOT/logs/test-$STAMP-matrix-$(printf '%s' "$file" | tr -c 'A-Za-z0-9._-' '_').log"

  # Per-cell environment for run-engine-e2e.sh. The FILTER targets only the
  # profile-matrix method so the single boot does not also run the
  # happy-path + reasoning tests.
  env_args=(
    "PIE_TEST_E2E_REPO=$repo"
    "PIE_TEST_E2E_FILE=$file"
    "PIE_TEST_E2E_MIN_BYTES=$minbytes"
    "PIE_TEST_E2E_PROFILES=$PROFILES"
    "PIE_TEST_E2E_FILTER=RealEngineLaunchE2ETests/test_realEngine_profileMatrixCell"
  )
  if [ "$thinking" = "1" ]; then
    env_args+=("PIE_TEST_REAL_EXPECT_REASONING=1")
  fi

  set +e
  env "${env_args[@]}" "$ROOT/Scripts/run-engine-e2e.sh" 2>&1 | tee "$CELL_LOG"
  cell_rc=${PIPESTATUS[0]}
  set -e

  # Aggregate the per-profile verdicts the test printed. A profile with no
  # MATRIX-CELL line never ran — the engine failed to boot/load — so every
  # requested profile for this model is recorded FAIL(no-cell).
  IFS=',' read -ra want_profiles <<< "$PROFILES"
  for p in "${want_profiles[@]}"; do
    p="$(printf '%s' "$p" | tr -d '[:space:]')"
    [ -n "$p" ] || continue
    line="$(grep -E "^MATRIX-CELL	$file	$p	" "$CELL_LOG" | tail -1 || true)"
    if [ -z "$line" ]; then
      printf 'FAIL\t%s\t%s\t(no cell — engine boot/load failed; cell_rc=%s)\n' "$slug" "$p" "$cell_rc" >> "$SUMMARY"
      FAIL_COUNT=$((FAIL_COUNT + 1)); overall_rc=1
    elif printf '%s' "$line" | grep -q "	PASS"; then
      printf 'PASS\t%s\t%s\n' "$slug" "$p" >> "$SUMMARY"
      PASS_COUNT=$((PASS_COUNT + 1))
    else
      reason="$(printf '%s' "$line" | cut -f5-)"
      printf 'FAIL\t%s\t%s\t%s\n' "$slug" "$p" "$reason" >> "$SUMMARY"
      FAIL_COUNT=$((FAIL_COUNT + 1)); overall_rc=1
    fi
  done
done

echo ""
echo "================= REAL-ENGINE MATRIX SUMMARY ================="
echo "RESULT  MODEL / PROFILE"
echo "-------------------------------------------------------------"
cat "$SUMMARY"
echo "-------------------------------------------------------------"
echo "PASS=$PASS_COUNT  FAIL=$FAIL_COUNT  (summary: $SUMMARY)"
echo "============================================================="
exit "$overall_rc"
