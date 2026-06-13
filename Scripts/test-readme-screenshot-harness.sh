#!/usr/bin/env bash
# Lightweight guard for product-facing canned README screenshot copy.
set -euo pipefail
python3 - <<'PY'
import importlib.util
from pathlib import Path
path = Path('Scripts/readme-screenshot-harness.py')
spec = importlib.util.spec_from_file_location('readme_screenshot_harness', path)
mod = importlib.util.module_from_spec(spec)
spec.loader.exec_module(mod)
answer = mod.DEFAULT_ANSWER
if 'RatioThink' in answer:
    raise SystemExit('FAIL: DEFAULT_ANSWER still contains legacy user-facing product name RatioThink')
if 'Rational' not in answer:
    raise SystemExit('FAIL: DEFAULT_ANSWER does not contain Rational')
print('PASS: readme screenshot harness canned copy uses Rational, not RatioThink')
PY
