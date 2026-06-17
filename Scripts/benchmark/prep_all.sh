#!/usr/bin/env bash
# Prep every row of the spec-decode benefit matrix (#652) in one shot.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
for s in "$HERE"/prep_*.sh; do
  [ "$(basename "$s")" = "prep_all.sh" ] && continue
  echo "== $(basename "$s") =="
  "$s"
done
echo "[prep] all datasets locked -> $HERE/datasets.lock"
