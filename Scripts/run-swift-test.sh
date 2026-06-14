#!/bin/bash
# Forwards to `xcrun swift test` while refusing parallel-testing
# entry-point flags. CLIScenarioTests uses IsolatedTestCase, whose
# `refuseParallelTesting()` guard also fatalErrors at runtime if
# parallelism markers are present in the env — but blocking the flag
# at the swift-test boundary gives a faster, clearer error than a
# trap mid-suite. See  finding F1/F6.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=lib/sandbox-diagnostics.sh
. "$ROOT/Scripts/lib/sandbox-diagnostics.sh"

refuse() {
  echo "run-swift-test.sh: refusing '$1' — CLIScenarioTests must run serial-within-bundle ( F1/F6)" >&2
  exit 2
}

i=0
args=("$@")
while [ $i -lt ${#args[@]} ]; do
  arg="${args[$i]}"
  case "$arg" in
    --parallel)
      refuse "$arg"
      ;;
    --num-workers=*)
      n="${arg#--num-workers=}"
      if [ "$n" != "1" ]; then
        refuse "$arg"
      fi
      ;;
    --num-workers)
      # space-separated form: next arg is the value
      next_index=$((i + 1))
      if [ $next_index -lt ${#args[@]} ]; then
        n="${args[$next_index]}"
        if [ "$n" != "1" ]; then
          refuse "$arg $n"
        fi
      else
        refuse "$arg (missing value)"
      fi
      ;;
  esac
  i=$((i + 1))
done

sandbox_diag_require_swiftpm_cache "swift-test" || exit 2

sandbox_diag_run_with_recovery "swift-test" xcrun swift test "$@"
