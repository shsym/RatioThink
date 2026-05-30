# Vendored Python packages

Pure-Python, MIT-licensed dependencies vendored so the DMG packaging build is
self-contained (no `pip`/network at build time). Used by
`Scripts/make-dmg-dsstore.py` to write a styled `.DS_Store` deterministically —
Finder AppleScript is unreliable under automation and impossible in CI, so we
generate the icon-view layout (positions + background) directly, exactly as
`dmgbuild` does.

| Package | Version | Source | License |
|---------|---------|--------|---------|
| `ds_store` | 1.3.2 | https://pypi.org/project/ds-store/ | MIT (`ds_store/LICENSE`) |
| `mac_alias` | 2.2.3 | https://pypi.org/project/mac-alias/ | MIT (`mac_alias/LICENSE`) |

To refresh: `pip install ds_store==<v> mac_alias==<v> -t /tmp/x`, then copy the
`ds_store/` and `mac_alias/` package dirs here (drop `__pycache__`) and update
the versions above.
