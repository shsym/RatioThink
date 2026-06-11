#!/bin/bash
# Manual seated-console smoke for Phase 2.3 menu-bar status item.
#
# Walks the helper through every dot state (gray/amber/green/red)
# WITHOUT a Rational.app GUI by driving `PieSupervisor` via the XPC
# `startEngine` / `stopEngine` selectors. Requires a seated console
# (the helper publishes NSStatusItem, which a non-GUI session
# cannot render).
#
# Usage:
#   Scripts/smoke-helper-statusbar.sh [--keep]
#
#   --keep    leave the helper running after the script finishes,
#             so you can eyeball the dot in the menu bar. Otherwise
#             the script SIGTERMs RationalHelper at exit.
#
# What the script does:
#   1. make build       — produce Rational.app + RationalHelper.app
#   2. launch RationalHelper directly (no Rational.app, no SMAppService).
#      Skips login-item registration; we just want the menu bar item.
#   3. tail helper logs in the background so you see supervisor state
#      transitions in real time.
#   4. prints a checklist for the operator: "look at the menu bar,
#      verify dot is gray; press Enter to continue", etc.
#
# Why this exists: the supervisor → menu bar leg has 14 unit tests
# (RatioThinkCoreTests/HelperStatusItem*) that cover the EngineStatus → model
# → binding-closure projection. They do NOT cover the AppKit render
# itself (palette color reaching NSImage, SF Symbol availability,
# tint visibility under dark mode). This script is the visual ground
# truth for those properties.

set -euo pipefail

KEEP=0
HOLD_SECONDS=""
DRIVE_ENGINE=0
GREEN_HOLD=8
for arg in "$@"; do
  case "$arg" in
    --keep) KEEP=1 ;;
    --hold=*) HOLD_SECONDS="${arg#--hold=}" ;;
    --drive-engine) DRIVE_ENGINE=1 ;;
    --green-hold=*) GREEN_HOLD="${arg#--green-hold=}" ;;
    -h|--help)
      sed -n '2,30p' "$0" | sed 's/^# \{0,1\}//'
      cat <<'EOF'
Extra flags:
  --drive-engine        Launch the helper with a fake pie engine and
                        auto-drive start → hold → stop so the dot
                        flips gray → amber → green → amber → gray
                        live. DEBUG builds only.
  --green-hold=<sec>    Seconds to hold green before stop. Default 8.
EOF
      exit 0
      ;;
    *) echo "unknown arg: $arg" >&2; exit 2 ;;
  esac
done

if ! pgrep -x Dock >/dev/null 2>&1; then
  echo "error: no seated console detected (Dock not running)." >&2
  echo "       Run this from a Terminal inside the macOS console session" >&2
  echo "       (or Screen Sharing). SSH alone cannot render NSStatusItem." >&2
  exit 1
fi

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

LOG_DIR="$ROOT/.logs"
mkdir -p "$LOG_DIR"
STAMP=$(date +%Y%m%d-%H%M%S)
HELPER_LOG="$LOG_DIR/smoke-helper-$STAMP.log"

# Pin DerivedData to a worktree-local path. Without this, each
# worktree gets a different hashed `RatioThink-<sha>` dir under the global
# DerivedData root, and parallel agents building in sibling worktrees
# leave behind newer-mtime dirs that a naive "pick newest" finder
# would launch — silently running a stale binary from another branch.
DERIVED_DIR="$ROOT/.DerivedData-smoke"
BUILD_LOG="$LOG_DIR/smoke-build-$STAMP.log"
echo "==> Building Rational.app + RationalHelper.app (DerivedData=$DERIVED_DIR)"
# Review v1 F8: under `set -e`, `xcodebuild` failure aborts the
# script BEFORE the post-hoc `BUILD_RC=$?` check could fire, so the
# operator saw a silent exit with no stderr (build output was
# redirected to the log file). Wrap in `if !` so the failure path
# explicitly surfaces the log location.
if ! DEVELOPER_DIR=${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer} \
  xcodebuild -project RatioThink.xcodeproj -scheme RatioThink \
    -configuration Debug \
    -derivedDataPath "$DERIVED_DIR" \
    -destination 'platform=macOS,arch=arm64' \
    build >"$BUILD_LOG" 2>&1
then
  echo "error: xcodebuild failed. See $BUILD_LOG" >&2
  tail -20 "$BUILD_LOG" >&2 || true
  exit 1
fi

HELPER_APP="$DERIVED_DIR/Build/Products/Debug/Rational.app/Contents/Library/LoginItems/RationalHelper.app"
if [ ! -d "$HELPER_APP" ]; then
  echo "error: RationalHelper.app not found at $HELPER_APP" >&2
  exit 1
fi
HELPER_BIN="$HELPER_APP/Contents/MacOS/RationalHelper"
echo "==> Helper: $HELPER_BIN"

# Kill any stale helper from a prior run. Review v1 F9: don't
# blindly swallow pkill's exit — a "no such process" is fine, but
# a "permission denied" (helper owned by launchd ctx) means the
# stale process survives and races the fresh helper for the menu-bar
# slot. After kill, verify nothing answers to the name anymore.
pkill -x RationalHelper 2>/dev/null || true
sleep 0.3
if pgrep -x RationalHelper >/dev/null 2>&1; then
  echo "error: stale RationalHelper still running after pkill — refusing to launch a second instance" >&2
  echo "       pid(s): $(pgrep -x RationalHelper | tr '\n' ' ')" >&2
  exit 1
fi

# --drive-engine writes a fake pie engine and points the helper at
# it. Helper's DEBUG smoke seam auto-drives start → hold → stop.
FAKE_ENGINE=""
if [ "$DRIVE_ENGINE" -eq 1 ]; then
  FAKE_ENGINE="$LOG_DIR/smoke-fake-pie-$STAMP.sh"
  cat > "$FAKE_ENGINE" <<'FAKE'
#!/bin/bash
echo "HTTP_LISTEN=127.0.0.1:55555"
exec sleep 600
FAKE
  chmod +x "$FAKE_ENGINE"
  echo "==> --drive-engine: fake engine at $FAKE_ENGINE (green-hold=${GREEN_HOLD}s)"
fi

echo "==> Launching RationalHelper (log: $HELPER_LOG)"
# DEBUG dev builds are ad-hoc-signed (no Team ID).
# `HelperXPCListener.verifyStartupInvariants` preconditionFails on
# `.teamIDAbsent` unless a bypass env is set. Smoke is local-only;
# bypassing is correct here. Production helpers launched via
# SMAppService have a real Team ID and never enter this branch.
if [ "$DRIVE_ENGINE" -eq 1 ]; then
  PIE_ALLOW_UNSIGNED_CALLERS=1 \
    PIE_SMOKE_FAKE_ENGINE_BIN="$FAKE_ENGINE" \
    PIE_SMOKE_AUTO_GREEN_HOLD_SECONDS="$GREEN_HOLD" \
    "$HELPER_BIN" >"$HELPER_LOG" 2>&1 &
else
  PIE_ALLOW_UNSIGNED_CALLERS=1 "$HELPER_BIN" >"$HELPER_LOG" 2>&1 &
fi
HELPER_PID=$!

cleanup() {
  if [ "$KEEP" -eq 0 ] && kill -0 "$HELPER_PID" 2>/dev/null; then
    echo "==> Stopping helper (pid=$HELPER_PID)"
    kill -TERM "$HELPER_PID" 2>/dev/null || true
    sleep 1
    kill -KILL "$HELPER_PID" 2>/dev/null || true
  elif [ "$KEEP" -eq 1 ]; then
    echo "==> --keep: helper left running (pid=$HELPER_PID)"
    echo "    Stop manually: kill $HELPER_PID"
  fi
}
trap cleanup EXIT

# Give the helper a moment to register the status item.
sleep 1.5

cat <<'EOF'

────────────────────────────────────────────────────────────────────
Seated-console smoke for Phase 2.3 menu-bar status item
────────────────────────────────────────────────────────────────────

  Look at the menu bar (top-right). You should see a Rational status item.

  Checklist:

    [ ] Dot is GRAY (outline circle) — supervisor is .stopped.
    [ ] Click the dot. Menu shows:
          · Show Rational                          (Cmd+0)
          · ─────
          · Engine: stopped                   (disabled)
          · Resume Engine                     (disabled —  wires it)
          · ─────
          · Settings…                         (Cmd+,)
          · Open Logs…
          · ─────
          · Quit Rational                          (Cmd+Q)
    [ ] Click "Open Logs…" → Finder opens ~/Library/Application Support/RatioThink/logs/.

  To see LIVE dot transitions, re-run with --drive-engine:

      Scripts/smoke-helper-statusbar.sh --drive-engine \
                                        --green-hold=8 --hold=20

  Helper auto-drives a fake engine through start → green-hold →
  stop on a timer (DEBUG builds only).

  Headless state-machine coverage: see
  HelperStatusItemSupervisorIntegrationTests in RatioThinkCoreTests.

Press Enter to stop the helper (or Ctrl+C).
EOF

# Stream helper logs while the operator inspects the menu bar.
tail -f "$HELPER_LOG" &
TAIL_PID=$!
trap '
  kill "$TAIL_PID" 2>/dev/null || true
  cleanup
' EXIT INT TERM

if [ -n "$HOLD_SECONDS" ]; then
  echo "==> --hold=$HOLD_SECONDS: holding for $HOLD_SECONDS seconds, then stopping."
  sleep "$HOLD_SECONDS"
else
  # Review v1 F10: interactive smoke needs a TTY. Under CI / nohup /
  # `&`, `read` returns immediately on closed stdin and the script
  # would SIGTERM the helper before the operator could inspect
  # anything — defeating the purpose. Refuse and tell the caller to
  # pass --hold=<seconds>.
  if [ ! -t 0 ]; then
    echo "error: stdin is not a TTY; refusing to run interactive smoke." >&2
    echo "       Pass --hold=<seconds> for non-interactive runs." >&2
    exit 1
  fi
  read -r _ || true
fi

echo
echo "==> Helper log saved to: $HELPER_LOG"
