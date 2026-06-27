#!/usr/bin/env bash
# Prep the 'mmlu' row of the ToT generality benchmark slice (#853).
# Pinned PUBLIC dataset -> full test split -> Scripts/benchmark/datasets.lock.
exec "$(dirname "$0")/_prep.sh" mmlu
