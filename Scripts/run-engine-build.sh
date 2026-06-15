#!/usr/bin/env bash
#
# Build the pie engine (pie-server release crate in Vendor/pie) for local
# development, wrapped in sandbox-diagnostics recovery so a sandbox-denied
# cargo build surfaces actionable guidance instead of an opaque failure.
#
# Usage: Scripts/run-engine-build.sh
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=lib/sandbox-diagnostics.sh
. "$ROOT/Scripts/lib/sandbox-diagnostics.sh"

cd "$ROOT/Vendor/pie"
sandbox_diag_run_with_recovery "engine-build" env PIE_PORTABLE_METAL=1 cargo build -p pie-server --release
