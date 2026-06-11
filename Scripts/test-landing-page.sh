#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LANDING="$ROOT/docs/landing.html"

python3 - "$LANDING" <<'PY'
import re
import sys
from pathlib import Path

landing = Path(sys.argv[1])
html = landing.read_text(encoding="utf-8")
failures: list[str] = []

forbidden = " — real answers are longer and more detailed."
if forbidden in html:
    failures.append("demo note still overclaims answer length/detail")

if re.search(r'''(?:href|src)=["']\.\./''', html):
    failures.append("landing page contains an asset/link path that escapes docs/")

nav_match = re.search(
    r'''<nav\s+class=["']top-nav["']\s+aria-label=["']Primary["']>(.*?)</nav>''',
    html,
    re.S,
)
header_index = html.find('<header class="hero">')
if not nav_match:
    failures.append("missing primary top navigation")
elif header_index == -1 or nav_match.start() > header_index:
    failures.append("primary navigation must appear before the hero header")
else:
    nav_html = nav_match.group(1)
    if 'href="https://github.com/shsym/RatioThink"' not in nav_html:
        failures.append("GitHub repository link is not in the top navigation")
    if 'class="nav-github"' not in nav_html:
        failures.append("GitHub top-nav link must use the nav-github class")

top_nav_css = re.search(r"\.top-nav\s*\{([^}]*)\}", html, re.S)
if not top_nav_css or "justify-content:flex-end" not in re.sub(r"\s+", "", top_nav_css.group(1)):
    failures.append("top navigation is not right-aligned on desktop")

footer_match = re.search(r"<footer>(.*?)</footer>", html, re.S)
if footer_match and "https://github.com/shsym/RatioThink" in footer_match.group(1):
    failures.append("GitHub repository link is still in the footer instead of being moved")

if failures:
    for failure in failures:
        print(f"FAIL: {failure}", file=sys.stderr)
    sys.exit(1)

print("PASS: landing-page polish")
PY
