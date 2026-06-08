#!/usr/bin/env bash
#
# Fail closed if the committed `Vendor/pie` gitlink is NOT reachable from the
# tracking branch declared for it in `.gitmodules`.
#
# Why this matters: a fresh clone's `git submodule update --remote` (and any
# tooling that tracks the declared branch rather than the recorded gitlink)
# checks out the *branch tip*. If the pin lives on a different lineage than the
# declared branch, that silently swaps in a divergent commit — e.g. the
# pre-rebase shmem base instead of the rebased-onto-main pin — while a plain
# `--init` still works, hiding the drift until something breaks. This guard
# turns that latent drift into a hard, early CI failure.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

SUB="Vendor/pie"

pin="$(git rev-parse ":$SUB")"
branch="$(git config -f .gitmodules "submodule.$SUB.branch" 2>/dev/null || true)"

if [ -z "$branch" ]; then
  echo "[vendor-pin] FAIL: no tracking branch declared for $SUB in .gitmodules" >&2
  exit 1
fi

# Make sure the declared branch ref is present locally (CI checks out the
# submodule at the detached pin, so origin/<branch> may be absent until fetched).
git -C "$SUB" fetch --quiet origin "$branch"

if git -C "$SUB" merge-base --is-ancestor "$pin" "origin/$branch"; then
  echo "[vendor-pin] OK: $SUB gitlink $pin is reachable from origin/$branch"
  exit 0
fi

echo "[vendor-pin] FAIL: $SUB gitlink $pin is NOT reachable from origin/$branch" >&2
echo "[vendor-pin]   The branch declared in .gitmodules must contain the pinned commit," >&2
echo "[vendor-pin]   otherwise 'git submodule update --remote' and fresh-clone branch" >&2
echo "[vendor-pin]   tracking drift to a divergent lineage. Push the pin onto" >&2
echo "[vendor-pin]   '$branch', or repoint .gitmodules to the branch that contains it." >&2
exit 1
