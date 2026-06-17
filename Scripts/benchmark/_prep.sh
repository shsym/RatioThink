#!/usr/bin/env bash
#
# Shared worker for the per-dataset prep scripts (#652). Each prep_<key>.sh is
# a one-line wrapper that calls this with its dataset key. Downloads the dataset
# PINNED by revision hash, emits the FULL canonical split as the prompt set, and
# records count + content sha256 + license/citation into datasets.lock.
#
# NO sampling, NO subsetting, NO seed-based pick — see Scripts/benchmark/prep_datasets.py.
# Re-running reproduces the same count + hash (the no-cherrypick guard).
set -euo pipefail

KEY="${1:?usage: _prep.sh <dataset-key>}"
HERE="$(cd "$(dirname "$0")" && pwd)"

if ! command -v uv >/dev/null 2>&1; then
  echo "[prep] FATAL: 'uv' not found on PATH." >&2
  echo "       install it: https://docs.astral.sh/uv/getting-started/installation/" >&2
  exit 2
fi

uv run --quiet --with "datasets>=2.18" python "$HERE/prep_datasets.py" emit "$KEY"
