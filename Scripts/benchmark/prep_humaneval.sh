#!/usr/bin/env bash
# Prep the 'humaneval' row of the spec-decode benefit matrix (#652).
# Pinned PUBLIC dataset -> full split -> Scripts/benchmark/datasets.lock.
exec "$(dirname "$0")/_prep.sh" humaneval
