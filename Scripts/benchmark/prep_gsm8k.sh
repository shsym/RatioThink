#!/usr/bin/env bash
# Prep the 'gsm8k' row of the spec-decode benefit matrix (#652).
# Pinned PUBLIC dataset -> full split -> Scripts/benchmark/datasets.lock.
exec "$(dirname "$0")/_prep.sh" gsm8k
