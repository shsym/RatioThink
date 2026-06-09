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

# --- the matrix model coordinates -------------------------------------
# KEEP IN SYNC WITH Shared/CuratedModelCatalog.swift (CuratedModelCatalog.all).
# MatrixModelCatalogSyncTests parses this block and hard-fails on any drift
# (a model added/removed/resized in the catalog but not here, or vice versa).
# Fields: <hfRepo>|<hfFile>|<minBytes = approximateSizeBytes>|<thinking 0|1>|<semantic 0|1>
# `thinking=1` (Qwen3 family) flips PIE_TEST_REAL_EXPECT_REASONING=1 so the
# chat/fast-think cells also assert the reasoning-channel split (#329).
# `semantic=1` (the larger tier, params > 1B) flips PIE_TEST_REAL_EXPECT_SEMANTIC=1
# so the chat cell adds the #484 weak semantic floor (reply must echo 'pong').
# The small 0.5–1B tier stays semantic=0 (contract-level only) so a missed
# echo — a capability limit, not an engine-compat failure — is not a false FAIL.
MATRIX_MODELS=(
  "Qwen/Qwen2.5-0.5B-Instruct-GGUF|qwen2.5-0.5b-instruct-q4_k_m.gguf|491400032|0|0"
  "Qwen/Qwen3-0.6B-GGUF|Qwen3-0.6B-Q8_0.gguf|639446688|1|0"
  "bartowski/Llama-3.2-1B-Instruct-GGUF|Llama-3.2-1B-Instruct-Q4_K_M.gguf|807694464|0|0"
  "Qwen/Qwen2.5-1.5B-Instruct-GGUF|qwen2.5-1.5b-instruct-q4_k_m.gguf|1117000000|0|1"
  "bartowski/Llama-3.2-3B-Instruct-GGUF|Llama-3.2-3B-Instruct-Q4_K_M.gguf|2020000000|0|1"
  "bartowski/Qwen2.5-7B-Instruct-GGUF|Qwen2.5-7B-Instruct-Q4_K_M.gguf|4683074240|0|1"
  "bartowski/Meta-Llama-3.1-8B-Instruct-GGUF|Meta-Llama-3.1-8B-Instruct-Q4_K_M.gguf|4920000000|0|1"
  "bartowski/Qwen2.5-Coder-14B-Instruct-GGUF|Qwen2.5-Coder-14B-Instruct-Q4_K_M.gguf|8988111072|0|1"
  "Qwen/Qwen3-14B-GGUF|Qwen3-14B-Q4_K_M.gguf|9001752960|1|1"
)

ALL_PROFILES="chat,tree-of-thought,fast-think"

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

# aggregate_cell <slug> <file> <profiles_csv> <cell_log> <cell_rc>
#
# Fold the per-profile MATRIX-CELL verdicts the test printed into <cell_log>
# into the globals SUMMARY / PASS_COUNT / FAIL_COUNT / overall_rc. Extracted
# (and source-able) so Scripts/test-matrix-aggregator.sh can unit-test the
# verdict logic engine-free.
aggregate_cell() {
  local slug="$1" file="$2" profiles_csv="$3" cell_log="$4" cell_rc="$5"
  local printed=0 failed=0
  local -a want
  IFS=',' read -ra want <<< "$profiles_csv"
  local p line reason
  for p in "${want[@]}"; do
    p="$(printf '%s' "$p" | tr -d '[:space:]')"
    [ -n "$p" ] || continue
    line="$(grep -E "^MATRIX-CELL	$file	$p	" "$cell_log" | tail -1 || true)"
    if [ -z "$line" ]; then
      # No cell line ⇒ the engine never booted/loaded for this model, so the
      # profile never ran. Record FAIL(no-cell); the run's non-zero exit is
      # captured here in the message.
      printf 'FAIL\t%s\t%s\t(no cell — engine boot/load failed; cell_rc=%s)\n' "$slug" "$p" "$cell_rc" >> "$SUMMARY"
      FAIL_COUNT=$((FAIL_COUNT + 1)); overall_rc=1
    elif printf '%s' "$line" | grep -q "	PASS"; then
      printf 'PASS\t%s\t%s\n' "$slug" "$p" >> "$SUMMARY"
      PASS_COUNT=$((PASS_COUNT + 1)); printed=$((printed + 1))
    else
      reason="$(printf '%s' "$line" | cut -f5-)"
      printf 'FAIL\t%s\t%s\t%s\n' "$slug" "$p" "$reason" >> "$SUMMARY"
      FAIL_COUNT=$((FAIL_COUNT + 1)); overall_rc=1
      printed=$((printed + 1)); failed=$((failed + 1))
    fi
  done

  # Fail-closed on the swift-test exit code (review v1 F1). The per-profile
  # verdict above is grep-driven, so a run where the engine booted and every
  # requested profile printed PASS but the process THEN exited non-zero
  # (Metal/teardown crash, host.stop() fault, IsolatedTestCase SIGKILL-reap,
  # or any sibling/build non-zero exit) would launder a red run into a green
  # table. Treat a non-zero cell_rc as a row-level failure — but only when at
  # least one cell printed AND none were already recorded FAIL, so this
  # neither double-counts the no-cell branch (printed==0, which already FAILed
  # every profile) nor a legitimately-detected per-cell FAIL (failed>0, which
  # itself drives cell_rc != 0 via the test's terminal XCTFail).
  if [ "$cell_rc" -ne 0 ] && [ "$printed" -gt 0 ] && [ "$failed" -eq 0 ]; then
    printf 'FAIL\t%s\t(cell_rc=%s despite PASS cells — run exited non-zero)\n' "$slug" "$cell_rc" >> "$SUMMARY"
    FAIL_COUNT=$((FAIL_COUNT + 1)); overall_rc=1
  fi
}

# recognized_profile_count <profiles_csv>
#
# Echo how many recognized profiles (chat|tree-of-thought|fast-think) remain in
# the csv after trimming whitespace and dropping empty fields. Extracted (like
# aggregate_cell) so Scripts/test-matrix-aggregator.sh can unit-test the #483
# hollow-green guard engine-free. An explicitly-set but empty / whitespace-only
# / all-commas PIE_TEST_E2E_PROFILES resolves to zero recognized profiles: the
# per-cell loop would then record no MATRIX-CELL rows and exit 0 with
# PASS=0 FAIL=0 — a hollow green. The caller fails closed on a zero count.
recognized_profile_count() {
  local csv="$1" p n=0
  local -a parts
  IFS=',' read -ra parts <<< "$csv"
  # ${parts[@]+...} is the nounset-safe expansion: an empty csv yields a
  # zero-element array, and a bare "${parts[@]}" under `set -u` (bash 3.2 on
  # macOS) is an "unbound variable" error — the very empty-input case this
  # guard must handle.
  for p in ${parts[@]+"${parts[@]}"}; do
    p="$(printf '%s' "$p" | tr -d '[:space:]')"
    case "$p" in
      chat|tree-of-thought|fast-think) n=$((n + 1)) ;;
    esac
  done
  printf '%s\n' "$n"
}

main() {
  cd "$ROOT"

  # --- single explicit operator gate ----------------------------------
  if [ "${PIE_TEST_E2E_MATRIX:-}" != "1" ]; then
    echo "matrix: refusing to run without explicit opt-in." >&2
    echo "matrix: the full matrix downloads ~36 GB and runs the real Metal engine for 30 cells." >&2
    echo "matrix: opt in with the env gate:" >&2
    echo "matrix:     PIE_TEST_E2E_MATRIX=1 Scripts/run-matrix-e2e.sh" >&2
    echo "matrix: or via make:  RUN_MATRIX=1 make test-e2e-matrix" >&2
    exit 2
  fi

  local PROFILES="${PIE_TEST_E2E_PROFILES:-$ALL_PROFILES}"
  local MODEL_FILTER="${PIE_TEST_E2E_MATRIX_MODELS:-}"

  # Fail closed on a profile set that resolves to zero recognized profiles
  # (#483). `${VAR:-default}` already covers an empty value, but a non-empty yet
  # profile-free override (whitespace-only, all-commas, or only-typos) slips
  # through and would silently iterate zero cells into a hollow green.
  if [ "$(recognized_profile_count "$PROFILES")" -eq 0 ]; then
    echo "matrix: PIE_TEST_E2E_PROFILES resolved to no recognized profile (got: '$PROFILES')." >&2
    echo "matrix: expected a csv subset of: $ALL_PROFILES" >&2
    exit 2
  fi

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

  mkdir -p "$ROOT/logs"
  local STAMP; STAMP="$(date +%Y%m%d-%H%M%S)"
  SUMMARY="$ROOT/logs/test-$STAMP-matrix-e2e.summary.log"
  : > "$SUMMARY"

  PASS_COUNT=0
  FAIL_COUNT=0
  overall_rc=0

  local entry repo file minbytes thinking semantic slug keep f minfloor cell_rc CELL_LOG
  local -a filters env_args
  for entry in "${MATRIX_MODELS[@]}"; do
    IFS='|' read -r repo file minbytes thinking semantic <<< "$entry"
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
    echo "==== MATRIX MODEL: $slug  (thinking=$thinking semantic=$semantic)  profiles=[$PROFILES] ===="
    CELL_LOG="$ROOT/logs/test-$STAMP-matrix-$(printf '%s' "$file" | tr -c 'A-Za-z0-9._-' '_').log"

    # Partial-download tripwire floor. The catalog's approximateSizeBytes is
    # the EXACT blob size for the Qwen entries but a ROUNDED value for some
    # bartowski entries (e.g. Llama-3.2-3B's 2_020_000_000 rounds ABOVE the
    # real 2_019_377_696). The min-bytes guard exists to catch a truncated
    # download, not to assert the byte-exact size, so floor it at 90% of the
    # catalog figure — comfortably below any real complete file yet far above
    # a partial one (insight #122). MATRIX_MODELS still carries the exact
    # catalog value so the drift guard stays a 1:1 catalog check.
    minfloor=$(( minbytes * 9 / 10 ))

    # Per-cell environment for run-engine-e2e.sh. The FILTER targets only the
    # profile-matrix method so the single boot does not also run the
    # happy-path + reasoning tests.
    env_args=(
      "PIE_TEST_E2E_REPO=$repo"
      "PIE_TEST_E2E_FILE=$file"
      "PIE_TEST_E2E_MIN_BYTES=$minfloor"
      "PIE_TEST_E2E_PROFILES=$PROFILES"
      "PIE_TEST_E2E_FILTER=RealEngineLaunchE2ETests/test_realEngine_profileMatrixCell"
    )
    if [ "$thinking" = "1" ]; then
      env_args+=("PIE_TEST_REAL_EXPECT_REASONING=1")
    fi
    if [ "$semantic" = "1" ]; then
      env_args+=("PIE_TEST_REAL_EXPECT_SEMANTIC=1")
    fi

    set +e
    env "${env_args[@]}" "$ROOT/Scripts/run-engine-e2e.sh" 2>&1 | tee "$CELL_LOG"
    cell_rc=${PIPESTATUS[0]}
    set -e

    aggregate_cell "$slug" "$file" "$PROFILES" "$CELL_LOG" "$cell_rc"
  done

  echo ""
  echo "================= REAL-ENGINE MATRIX SUMMARY ================="
  echo "RESULT  MODEL / PROFILE"
  echo "-------------------------------------------------------------"
  cat "$SUMMARY"
  echo "-------------------------------------------------------------"
  echo "PASS=$PASS_COUNT  FAIL=$FAIL_COUNT  (summary: $SUMMARY)"
  echo "============================================================="

  # Zero-row backstop (#483). A matrix run that recorded no MATRIX-CELL rows
  # never proved anything — e.g. PIE_TEST_E2E_MATRIX_MODELS matched no model and
  # every entry was skipped — yet PASS=0 FAIL=0 would otherwise exit 0 as a
  # hollow green. The recognized-profile guard above covers the empty-profile
  # path; this is the catch-all invariant: no cells ⇒ not a pass.
  if [ $((PASS_COUNT + FAIL_COUNT)) -eq 0 ]; then
    echo "matrix: ERROR — recorded zero MATRIX-CELL rows; a zero-row run is never a pass." >&2
    exit 2
  fi
  exit "$overall_rc"
}

# Run main only when executed directly. When sourced (by
# Scripts/test-matrix-aggregator.sh to unit-test aggregate_cell), only the
# function + constant definitions load.
if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
  main "$@"
fi
