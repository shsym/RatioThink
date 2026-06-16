#!/usr/bin/env bash
# Regression tests for the docs/landing web-icon guard. Proves two things:
#   1. Scripts/generate-docs-icons.py still reproduces the committed icon bytes
#      from the app-icon master (under a pinned Pillow), so the manifest is not
#      a frozen artifact nobody can regenerate.
#   2. Scripts/verify-docs-icons.sh catches every committed-byte / manifest
#      drift, and the generator fails fast on a bad master.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/pie-docs-icon-verifier-tests.XXXXXX")"

# Pin the regeneration toolchain exactly to the Pillow the committed icons were
# produced with (byte-identical at 12.2.0). Bump deliberately alongside a
# manifest re-lock; a floating 12.* would red CI on any future Lanczos/PNG/ICO
# encoding change even when the artwork and generator are unchanged.
PILLOW_PIN="pillow==12.2.0"

cleanup() {
  rm -rf "$WORK_ROOT"
}
trap cleanup EXIT

copy_fixture() {
  local fixture="$1"
  mkdir -p "$fixture/Resources/AppIcon" "$fixture/Scripts" "$fixture/docs/assets"

  cp "$ROOT/Resources/AppIcon/rational-icon-highres.png" "$fixture/Resources/AppIcon/"
  cp "$ROOT/Scripts/generate-docs-icons.py" "$fixture/Scripts/"
  cp "$ROOT/Scripts/verify-docs-icons.sh" "$fixture/Scripts/"
  cp "$ROOT/Scripts/docs-icons.sha256" "$fixture/Scripts/"
  cp "$ROOT/docs/assets/pie-icon.png" "$fixture/docs/assets/"
  cp "$ROOT/docs/assets/apple-touch-icon.png" "$fixture/docs/assets/"
  cp "$ROOT/docs/favicon.ico" "$fixture/docs/"
}

prepare_fixture() {
  local name="$1"
  local fixture="$WORK_ROOT/$name"
  copy_fixture "$fixture"
  printf "%s" "$fixture"
}

append_png_text_chunk() {
  local png="$1"
  python3 - "$png" <<'PY'
import pathlib
import struct
import sys
import zlib

png_path = pathlib.Path(sys.argv[1])
data = png_path.read_bytes()
iend = data.rfind(b"\x00\x00\x00\x00IEND\xaeB`\x82")
if iend == -1:
    raise SystemExit(f"missing IEND chunk in {png_path}")

chunk_type = b"tEXt"
payload = b"pie-docs-verifier-test\x00content-drift"
chunk = (
    struct.pack(">I", len(payload))
    + chunk_type
    + payload
    + struct.pack(">I", zlib.crc32(chunk_type + payload) & 0xFFFFFFFF)
)
png_path.write_bytes(data[:iend] + chunk + data[iend:])
PY
}

run_verifier() {
  local fixture="$1"
  (
    cd "$fixture"
    Scripts/verify-docs-icons.sh
  )
}

run_generator() {
  local fixture="$1"
  command -v uv >/dev/null 2>&1 || {
    echo "FAIL: uv is required to regenerate the docs icons under a pinned Pillow" >&2
    exit 1
  }
  (
    cd "$fixture"
    uv run --no-project --with "$PILLOW_PIN" python3 Scripts/generate-docs-icons.py
  )
}

expect_success() {
  local name="$1"
  local fixture
  fixture="$(prepare_fixture "$name")"

  if ! run_verifier "$fixture" >"$fixture/verify.log" 2>&1; then
    cat "$fixture/verify.log" >&2
    echo "FAIL: expected verifier success for $name" >&2
    exit 1
  fi
}

expect_failure() {
  local name="$1"
  local mutation="$2"
  local fixture
  fixture="$(prepare_fixture "$name")"

  "$mutation" "$fixture"

  if run_verifier "$fixture" >"$fixture/verify.log" 2>&1; then
    cat "$fixture/verify.log" >&2
    echo "FAIL: expected verifier failure for $name" >&2
    exit 1
  fi
}

expect_reproducible_manifest() {
  local name="$1"
  local fixture
  fixture="$(prepare_fixture "$name")"

  if ! run_generator "$fixture" >"$fixture/regen.log" 2>&1; then
    cat "$fixture/regen.log" >&2
    echo "FAIL: generate-docs-icons.py failed during reproducibility check for $name" >&2
    exit 1
  fi

  # The regenerated icons must still hash to the committed manifest, so a
  # generator or artwork drift (changed master, resize filter, ICO sizes) is
  # caught and not silently re-locked.
  if ! (
    cd "$fixture"
    shasum -a 256 -c Scripts/docs-icons.sha256
  ) >"$fixture/regen-verify.log" 2>&1; then
    cat "$fixture/regen-verify.log" >&2
    echo "FAIL: regenerated docs icon bytes do not match Scripts/docs-icons.sha256 for $name" >&2
    exit 1
  fi
}

expect_generator_failure() {
  local name="$1"
  local mutation="$2"
  local fixture
  fixture="$(prepare_fixture "$name")"

  "$mutation" "$fixture"

  if run_generator "$fixture" >"$fixture/regen.log" 2>&1; then
    cat "$fixture/regen.log" >&2
    echo "FAIL: expected generate-docs-icons.py to fail fast for $name" >&2
    exit 1
  fi
}

mutate_pie_icon() {
  append_png_text_chunk "$1/docs/assets/pie-icon.png"
}

mutate_apple_touch_icon() {
  append_png_text_chunk "$1/docs/assets/apple-touch-icon.png"
}

mutate_favicon() {
  printf 'drift' >>"$1/docs/favicon.ico"
}

mutate_missing_icon() {
  rm -f "$1/docs/assets/pie-icon.png"
}

mutate_manifest_hash() {
  python3 - "$1/Scripts/docs-icons.sha256" <<'PY'
import pathlib
import sys

path = pathlib.Path(sys.argv[1])
lines = path.read_text().splitlines()
# Flip the first hex digit of the first manifest entry.
first = lines[0]
flipped = ("1" if first[0] == "0" else "0") + first[1:]
lines[0] = flipped
path.write_text("\n".join(lines) + "\n")
PY
}

# Master mutations need Pillow; run them under the same pinned toolchain as the
# generator so the test never depends on a system Pillow being installed.
pil() {
  uv run --no-project --with "$PILLOW_PIN" python3 - "$@"
}

mutate_master_empty_alpha() {
  pil "$1/Resources/AppIcon/rational-icon-highres.png" <<'PY'
import pathlib
import sys

from PIL import Image

path = pathlib.Path(sys.argv[1])
Image.new("RGBA", (1024, 1024), (0, 0, 0, 0)).save(path)
PY
}

mutate_master_wrong_size() {
  pil "$1/Resources/AppIcon/rational-icon-highres.png" <<'PY'
import pathlib
import sys

from PIL import Image

path = pathlib.Path(sys.argv[1])
Image.open(path).convert("RGBA").resize((512, 512)).save(path)
PY
}

expect_reproducible_manifest "regenerate-matches-manifest"
expect_success "baseline"
expect_failure "pie-icon-drift" mutate_pie_icon
expect_failure "apple-touch-icon-drift" mutate_apple_touch_icon
expect_failure "favicon-drift" mutate_favicon
expect_failure "missing-icon" mutate_missing_icon
expect_failure "manifest-hash-drift" mutate_manifest_hash
expect_generator_failure "master-empty-alpha" mutate_master_empty_alpha
expect_generator_failure "master-wrong-size" mutate_master_wrong_size

echo "Docs web icon verifier regression tests passed"
