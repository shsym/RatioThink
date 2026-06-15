#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LANDING="$ROOT/docs/landing.html"

python3 - "$LANDING" <<'PY'
from __future__ import annotations

from dataclasses import dataclass, field
from html.parser import HTMLParser
import re
import sys
from pathlib import Path

@dataclass
class Node:
    tag: str
    attrs: dict[str, str]
    order: int
    children: list["Node"] = field(default_factory=list)
    text: list[str] = field(default_factory=list)


class LandingParser(HTMLParser):
    def __init__(self) -> None:
        super().__init__(convert_charrefs=True)
        self.root = Node("document", {}, -1)
        self.stack = [self.root]
        self.order = 0

    def handle_starttag(self, tag: str, attrs: list[tuple[str, str | None]]) -> None:
        self._start(tag, attrs, push=True)

    def handle_startendtag(self, tag: str, attrs: list[tuple[str, str | None]]) -> None:
        self._start(tag, attrs, push=False)

    def handle_endtag(self, tag: str) -> None:
        for index in range(len(self.stack) - 1, 0, -1):
            if self.stack[index].tag == tag:
                del self.stack[index:]
                return

    def handle_data(self, data: str) -> None:
        if data:
            self.stack[-1].text.append(data)

    def _start(self, tag: str, attrs: list[tuple[str, str | None]], push: bool) -> None:
        node = Node(tag, {name: value or "" for name, value in attrs}, self.order)
        self.order += 1
        self.stack[-1].children.append(node)
        if push:
            self.stack.append(node)


def parse_html(html: str) -> Node:
    parser = LandingParser()
    parser.feed(html)
    parser.close()
    return parser.root


def walk(node: Node):
    for child in node.children:
        yield child
        yield from walk(child)


def has_class(node: Node, class_name: str) -> bool:
    return class_name in node.attrs.get("class", "").split()


def text_content(node: Node) -> str:
    return "".join(node.text) + "".join(text_content(child) for child in node.children)


def first_node(root: Node, tag: str, class_name: str | None = None) -> Node | None:
    for node in walk(root):
        if node.tag != tag:
            continue
        if class_name is not None and not has_class(node, class_name):
            continue
        return node
    return None


def contains_descendant_text(node: Node, tag: str, expected: str) -> bool:
    return any(child.tag == tag and expected in text_content(child) for child in walk(node))


REMOVED_TOOLBAR_MARKERS = [
    ("Model:", "model selector is still present in the landing mock toolbar"),
    ("Qwen3-0.6B", "model name is still present in the landing mock toolbar"),
    ("glyphs", "decorative toolbar icon group is still present"),
    ('title="Sampling"', "sampling toolbar icon is still present"),
    ('title="Attach"', "attach toolbar icon is still present"),
    ('title="System prompt"', "system-prompt toolbar icon is still present"),
    ("tdiv", "toolbar divider for removed controls is still present"),
]


def toolbar_marker_present(toolbar: Node, marker: str) -> bool:
    if marker in {"Model:", "Qwen3-0.6B"}:
        return marker in text_content(toolbar)
    if marker in {"glyphs", "tdiv"}:
        return any(has_class(node, marker) for node in walk(toolbar))
    if marker.startswith('title="'):
        title = marker.removeprefix('title="').removesuffix('"')
        return any(node.attrs.get("title") == title for node in walk(toolbar))
    return False


def validate_html(html: str) -> list[str]:
    failures: list[str] = []
    root = parse_html(html)

    forbidden = " — real answers are longer and more detailed."
    if forbidden in html:
        failures.append("demo note still overclaims answer length/detail")
    if "For illustration:" in html:
        failures.append("landing page still uses ad-hoc 'For illustration' tok/s copy")

    demo_note = first_node(root, "p", "demo-note")
    if not demo_note:
        failures.append("missing landing demo note")
    elif text_content(demo_note).strip() != "A simplified illustration of how it works.":
        failures.append("landing demo note is not the friendly illustration copy")

    if re.search(r'''(?:href|src)=["']\.\./''', html):
        failures.append("landing page contains an asset/link path that escapes docs/")

    nav = next(
        (
            node
            for node in walk(root)
            if node.tag == "nav"
            and has_class(node, "top-nav")
            and node.attrs.get("aria-label") == "Primary"
        ),
        None,
    )
    header = first_node(root, "header", "hero")
    if not nav:
        failures.append("missing primary top navigation")
    elif not header or nav.order > header.order:
        failures.append("primary navigation must appear before the hero header")
    else:
        nav_links = [
            node for node in walk(nav)
            if node.tag == "a" and node.attrs.get("href") == "https://github.com/shsym/RatioThink"
        ]
        if not nav_links:
            failures.append("GitHub repository link is not in the top navigation")
        elif not any(has_class(link, "nav-github") for link in nav_links):
            failures.append("GitHub top-nav link must use the nav-github class")

    top_nav_css = re.search(r"\.top-nav\s*\{([^}]*)\}", html, re.S)
    if not top_nav_css or "justify-content:flex-end" not in re.sub(r"\s+", "", top_nav_css.group(1)):
        failures.append("top navigation is not right-aligned on desktop")

    footers = [node for node in walk(root) if node.tag == "footer"]
    if any(
        link.attrs.get("href") == "https://github.com/shsym/RatioThink"
        for footer in footers
        for link in walk(footer)
        if link.tag == "a"
    ):
        failures.append("GitHub repository link is still in the footer instead of being moved")

    toolbars = [node for node in walk(root) if node.tag == "div" and has_class(node, "toolbar")]
    if not toolbars:
        failures.append("missing landing mock toolbar")
    else:
        for toolbar in toolbars:
            for marker, message in REMOVED_TOOLBAR_MARKERS:
                if toolbar_marker_present(toolbar, marker):
                    failures.append(message)

    fast_cards = [
        node
        for node in walk(root)
        if node.tag == "div"
        and has_class(node, "card")
        and contains_descendant_text(node, "h3", "Repeat Boost")
    ]
    if not fast_cards:
        failures.append("missing Repeat Boost card")
    elif any("tok/s" in text_content(card) for card in fast_cards):
        failures.append("Repeat Boost card still contains tok/s marketing copy instead of app-style mock metrics")

    if "message.generationPerformance" not in html:
        failures.append("landing mock is missing the app-side generation performance accessibility hook")
    if "generation-performance" not in html:
        failures.append("landing mock is missing generation performance row styling")
    if "19 tok/s" not in html:
        failures.append("landing mock is missing the normal-scene generation performance row")
    if "25 tok/s" not in html:
        failures.append("landing mock is missing the Repeat Boost generation performance row")

    return failures


VALID_FIXTURE = """
<!doctype html><html><head><style>.top-nav{display:flex;justify-content:flex-end}</style></head>
<body><div class="wrap">
<nav class="top-nav" aria-label="Primary"><a class="nav-github" href="https://github.com/shsym/RatioThink">GitHub</a></nav>
<header class="hero"></header>
<div class="toolbar"><span class="pill">Profile:</span><div class="menu"></div></div>
<p class="demo-note">A simplified illustration of how it works.</p>
<div class="card"><h3>Repeat Boost</h3><p>Speculative decoding makes the text land in bursts.</p></div>
<script>var hook = "message.generationPerformance"; var cls = "generation-performance"; var normal = "19 tok/s"; var fast = "25 tok/s";</script>
<footer>Apache-2.0</footer>
</div></body></html>
"""

NEGATIVE_FIXTURES = {
    "commented nav": """
        <!doctype html><html><head><style>.top-nav{display:flex;justify-content:flex-end}</style></head>
        <body><div class="wrap">
        <!-- <nav class="top-nav" aria-label="Primary"><a class="nav-github" href="https://github.com/shsym/RatioThink">GitHub</a></nav> -->
        <header class="hero"></header>
        <div class="toolbar"><span class="pill">Profile:</span><div class="menu"></div></div>
        <p class="demo-note">A simplified illustration of how it works.</p>
        <div class="card"><h3>Repeat Boost</h3><p>Speculative decoding makes the text land in bursts.</p></div>
        <script>var hook = "message.generationPerformance"; var cls = "generation-performance"; var normal = "19 tok/s"; var fast = "25 tok/s";</script>
        <footer>Apache-2.0</footer>
        </div></body></html>
    """,
    "toolbar markers after menu": """
        <!doctype html><html><head><style>.top-nav{display:flex;justify-content:flex-end}</style></head>
        <body><div class="wrap">
        <nav class="top-nav" aria-label="Primary"><a class="nav-github" href="https://github.com/shsym/RatioThink">GitHub</a></nav>
        <header class="hero"></header>
        <div class="toolbar"><span class="pill">Profile:</span><div class="menu"></div><span>Model:</span><span>Qwen3-0.6B</span></div>
        <p class="demo-note">A simplified illustration of how it works.</p>
        <div class="card"><h3>Repeat Boost</h3><p>Speculative decoding makes the text land in bursts.</p></div>
        <script>var hook = "message.generationPerformance"; var cls = "generation-performance"; var normal = "19 tok/s"; var fast = "25 tok/s";</script>
        <footer>Apache-2.0</footer>
        </div></body></html>
    """,
}

self_test_failures: list[str] = []
if validate_html(VALID_FIXTURE):
    self_test_failures.append("valid landing fixture should pass")
for name, fixture in NEGATIVE_FIXTURES.items():
    if not validate_html(fixture):
        self_test_failures.append(f"negative self-test did not fail: {name}")
if self_test_failures:
    for failure in self_test_failures:
        print(f"SELF-TEST FAIL: {failure}", file=sys.stderr)
    sys.exit(1)

landing = Path(sys.argv[1])
failures = validate_html(landing.read_text(encoding="utf-8"))

if failures:
    for failure in failures:
        print(f"FAIL: {failure}", file=sys.stderr)
    sys.exit(1)

print("PASS: landing-page polish")
PY
