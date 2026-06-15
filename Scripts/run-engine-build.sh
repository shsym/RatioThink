#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=lib/sandbox-diagnostics.sh
. "$ROOT/Scripts/lib/sandbox-diagnostics.sh"

cd "$ROOT/Vendor/pie"
sandbox_diag_run_with_recovery "engine-build" env PIE_PORTABLE_METAL=1 cargo build -p pie-server --release
