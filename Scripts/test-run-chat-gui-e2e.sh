#!/bin/bash
#
# Fast, non-GUI preflight regressions for run-chat-gui-e2e.sh. Drives the REAL
# wrapper to assert its preflight gate ordering (seated-GUI, TCC, model cache)
# and config cleanup without a seated session. Runs in `make test-gui-script`.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="$ROOT/Scripts/run-chat-gui-e2e.sh"

require_contains() {
  local haystack="$1"
  local needle="$2"
  if [[ "$haystack" != *"$needle"* ]]; then
    echo "FAIL: expected output to contain: $needle" >&2
    echo "--- output ---" >&2
    printf '%s\n' "$haystack" >&2
    exit 1
  fi
}

test_requires_tcc_before_starting_engine() {
  local tmp
  tmp="$(mktemp -d)"
  trap 'rm -rf "$tmp"' RETURN

  mkdir -p "$tmp/bin" "$tmp/hf/hub/models--Qwen--Qwen3-0.6B"
  cat >"$tmp/bin/pgrep" <<'FAKE_PGREP'
#!/bin/bash
exit 0
FAKE_PGREP
  chmod +x "$tmp/bin/pgrep"
  touch "$tmp/pie"
  chmod +x "$tmp/pie"

  set +e
  local output
  output="$(
    PATH="$tmp/bin:$PATH" \
    HF_HOME="$tmp/hf" \
    PIE_BIN="$tmp/pie" \
    PIE_TEST_TCC_GRANTED= \
    PIE_TEST_RUN_ROOT="$tmp/run" \
    "$SCRIPT" 2>&1
  )"
  local status=$?
  set -e

  if [[ "$status" -ne 2 ]]; then
    echo "FAIL: expected missing TCC preflight to exit 2, got $status" >&2
    echo "--- output ---" >&2
    printf '%s\n' "$output" >&2
    exit 1
  fi
  require_contains "$output" "Automation/Accessibility permission required"
  require_contains "$output" "PIE_TEST_TCC_GRANTED=1"
  if [[ "$output" == *"starting portable GGUF engine harness"* ]]; then
    echo "FAIL: TCC preflight must happen before starting the engine harness" >&2
    exit 1
  fi
}

test_removes_stale_config_on_exit() {
  local tmp
  tmp="$(mktemp -d)"
  trap 'rm -rf "$tmp"' RETURN

  local config="/tmp/pie-chat-gui-e2e.env"
  printf 'PIE_TEST_ENGINE_BASE_URL=http://127.0.0.1:9\n' >"$config"

  mkdir -p "$tmp/bin" "$tmp/hf/hub/models--Qwen--Qwen3-0.6B"
  cat >"$tmp/bin/pgrep" <<'FAKE_PGREP'
#!/bin/bash
exit 0
FAKE_PGREP
  chmod +x "$tmp/bin/pgrep"

  set +e
  PATH="$tmp/bin:$PATH" \
  HF_HOME="$tmp/hf" \
  PIE_BIN="$tmp/missing-pie" \
  PIE_TEST_TCC_GRANTED=1 \
  PIE_E2E_AUTOPREP=0 \
  STAGE_TEST_MODEL_DEST="$tmp/fixture/Qwen3-0.6B-Q8_0.gguf" \
  PIE_TEST_RUN_ROOT="$tmp/run" \
  "$SCRIPT" >/dev/null 2>&1
  set -e

  if [[ -e "$config" ]]; then
    echo "FAIL: stale $config should be removed on wrapper exit" >&2
    rm -f "$config"
    exit 1
  fi
}

test_missing_gguf_fixture_is_not_accepted() {
  local tmp
  tmp="$(mktemp -d)"
  trap 'rm -rf "$tmp"' RETURN

  # Fake a seated session and a runnable pie so the flow reaches the GGUF
  # fixture gate, then stage incomplete cache shapes under the exact repo dir
  # stage-test-model.sh inspects. Partial/aborted downloads must be rejected
  # before starting the portable GGUF engine harness.
  mkdir -p "$tmp/bin"
  cat >"$tmp/bin/pgrep" <<'FAKE_PGREP'
#!/bin/bash
exit 0
FAKE_PGREP
  chmod +x "$tmp/bin/pgrep"
  touch "$tmp/pie"
  chmod +x "$tmp/pie"

  local shape cache dest output status
  for shape in bare-repo empty-snapshots metadata-only dangling-gguf; do
    rm -rf "$tmp/hf" "$tmp/run" "$tmp/staged"
    cache="$tmp/hf/hub/models--Qwen--Qwen3-0.6B-GGUF"
    dest="$tmp/staged/$shape/Qwen3-0.6B-Q8_0.gguf"
    case "$shape" in
      bare-repo)
        mkdir -p "$cache"
        ;;
      empty-snapshots)
        mkdir -p "$cache/snapshots"
        ;;
      metadata-only)
        mkdir -p "$cache/snapshots/rev"
        printf '{}' >"$cache/snapshots/rev/config.json"
        ;;
      dangling-gguf)
        mkdir -p "$cache/snapshots/rev" "$cache/blobs"
        ln -s "../../blobs/missing-gguf" "$cache/snapshots/rev/Qwen3-0.6B-Q8_0.gguf"
        ;;
    esac

    set +e
    output="$(
      PATH="$tmp/bin:$PATH" \
      HF_HOME="$tmp/hf" \
      PIE_BIN="$tmp/pie" \
      PIE_TEST_TCC_GRANTED=1 \
      PIE_E2E_AUTOPREP=0 \
      PIE_TEST_RUN_ROOT="$tmp/run" \
      STAGE_TEST_MODEL_DEST="$dest" \
      "$SCRIPT" 2>&1
    )"
    status=$?
    set -e

    if [[ "$status" -ne 2 ]]; then
      echo "FAIL: partial GGUF cache '$shape' must fail the model gate (exit 2), got $status" >&2
      echo "--- output ---" >&2
      printf '%s\n' "$output" >&2
      exit 1
    fi
    require_contains "$output" "stage-test-model: model fixture NOT staged"
    require_contains "$output" "Looked in HF cache: $cache"
    require_contains "$output" "GGUF fixture unavailable"
    require_contains "$output" "cannot run the GGUF chat E2E"
    if [[ "$output" == *"starting portable GGUF engine harness"* ]]; then
      echo "FAIL: partial GGUF cache '$shape' wrongly accepted as a staged fixture — engine harness started" >&2
      exit 1
    fi
  done
}
# The GGUF-fixture caching contract (partial/dangling-state rejection) is now
# enforced end-to-end by test_missing_gguf_fixture_is_not_accepted above, which
# drives the wrapper against the live Scripts/stage-test-model.sh gate. The
# former `_e2e_hf_model_cached` / `e2e_ensure_hf_model` helpers this wrapper
# once used were orphaned by that migration and removed (#545 / #383), so the
# direct-helper contract test that pinned them was removed here too.

# The "engine harness started too early" negative assertions above are only
# meaningful while their needle matches the wrapper's actual banner. If the
# wrapper reworded the echo, the negative checks would pass vacuously (never
# matching anything) and silently stop guarding ordering — the exact self-test
# drift #545 absorbed (#500). Pin the coupling: the banner the guards key on
# MUST exist verbatim in the wrapper source.
test_engine_harness_banner_marker_is_current() {
  if ! grep -qF "starting portable GGUF engine harness" "$SCRIPT"; then
    echo "FAIL: run-chat-gui-e2e.sh no longer prints 'starting portable GGUF engine harness'" >&2
    echo "      — the ordering negative-assertions are now vacuous; update both this" >&2
    echo "      self-test's needle and the wrapper banner together." >&2
    exit 1
  fi
}

# Termination-source classifier (#545 / #549): a fresh crash report must be
# reported as a CRASH; an empty crash dir must read as "not a process crash".
# Runs the classifier under the SAME `set -euo pipefail` the wrapper uses, and
# asserts the verdict runs to COMPLETION (the live-pids line + closing rule) —
# the live run revealed the classifier aborting mid-verdict under macOS
# /bin/bash 3.2 when `pgrep` found no match (pipefail+errexit killed the
# `var="$(pgrep|tr)"` assignment). Asserting only the early lines would miss it.
test_termination_classification() {
  source "$ROOT/Scripts/e2e-prep.sh"
  local tmp; tmp="$(mktemp -d)"
  trap 'rm -rf "$tmp"' RETURN
  mkdir -p "$tmp/crash"

  # Empty crash dir, since=now → not a crash. Capture rc too: the classifier
  # must RETURN 0 (run to completion), not die under set -e mid-pgrep.
  local since out rc
  since="$(e2e_run_start_epoch)"
  set +e
  out="$(set -euo pipefail; RATIOTHINK_DIAG_CRASH_DIR="$tmp/crash" \
         e2e_classify_app_termination "selftest" "$since" 2>&1)"
  rc=$?
  set -e
  if [ "$rc" -ne 0 ]; then
    echo "FAIL: classifier aborted (rc=$rc) under set -euo pipefail — pgrep no-match must not kill it" >&2
    printf '%s\n' "$out" >&2
    exit 1
  fi
  require_contains "$out" "not a process crash"
  require_contains "$out" "live Rational:"          # reached the live-pids line
  require_contains "$out" "deep bundle:"            # reached the closing block

  # Seed a fresh Rational crash report → reported as CRASH. Classifier only
  # counts reports with mtime >= since, so stamp it at/after the reference.
  printf 'fake' >"$tmp/crash/Rational-2026-01-01-000000.ips"
  since="$(e2e_run_start_epoch)"
  touch "$tmp/crash/Rational-2026-01-01-000000.ips"   # mtime = now (>= since)
  out="$(set -euo pipefail; RATIOTHINK_DIAG_CRASH_DIR="$tmp/crash" \
         e2e_classify_app_termination "selftest" "$since" 2>&1)"
  require_contains "$out" "CRASH: Rational-2026-01-01-000000.ips"
  require_contains "$out" "deep bundle:"            # still runs to completion
}

# DB-verification honesty pin (#545 review v5 F5): the post-xcodebuild content
# gates were once downgraded to `if sqlite3 … 2>/dev/null; then …; else NOTE`,
# which collapsed the wrapper's verdict to XCODEBUILD_RC and masked a genuinely
# missing/corrupt chats.sqlite — a missing DB read as the benign "no match" NOTE
# and PASSED, indistinguishable from the quarantined truncation. The gate body
# runs only after a real xcodebuild flow (unreachable in this fast self-test), so
# pin it structurally: a missing/empty DB MUST hard-fail, and each sqlite3 query
# MUST capture its rc so a corrupt/unreadable DB stays fatal while an empty
# result set stays a tolerated NOTE. Dropping any guard re-introduces the silent
# failure this PR exists to prevent.
test_db_gate_hard_fails_on_missing_or_corrupt_db() {
  # 1) Missing/empty DB is fatal, not a benign NOTE.
  if ! grep -qF '[ ! -s "$GUI_HOME/chats.sqlite" ]' "$SCRIPT"; then
    echo "FAIL: run-chat-gui-e2e.sh dropped the missing/empty chats.sqlite hard-assert" >&2
    echo "      — a DB that was never created would silently PASS via the content-gate NOTE." >&2
    exit 1
  fi
  # 2) Each content gate captures sqlite3's rc so a QUERY ERROR is fatal.
  local rc_guards
  rc_guards="$(grep -cE 'sqlite3 query failed \(rc=' "$SCRIPT" || true)"
  if [ "$rc_guards" -lt 2 ]; then
    echo "FAIL: content gates missing per-query rc handling (found $rc_guards, need >= 2)" >&2
    echo "      — a corrupt/unreadable DB must hard-fail, not collapse to the no-match NOTE." >&2
    exit 1
  fi
  # 3) The blanket `2>/dev/null` that masked genuine sqlite3 errors must be gone
  #    from the content-gate queries (stderr now goes to a captured .err file).
  if grep -qE 'sqlite3 "\$GUI_HOME/chats.sqlite".*2>/dev/null' "$SCRIPT"; then
    echo "FAIL: content-gate sqlite3 query still swallows stderr with 2>/dev/null — masks DB errors" >&2
    exit 1
  fi
}

test_requires_tcc_before_starting_engine
test_removes_stale_config_on_exit
test_missing_gguf_fixture_is_not_accepted
test_engine_harness_banner_marker_is_current
test_termination_classification
test_db_gate_hard_fails_on_missing_or_corrupt_db
echo "test-run-chat-gui-e2e: PASS"
