# Vendored DMG-styling dependencies (git submodules)

`Scripts/make-dmg-dsstore.py` writes the styled DMG `.DS_Store` deterministically
(Finder AppleScript is unreliable under automation and impossible in CI), exactly
as `dmgbuild` does. It depends on two of the `dmgbuild` author's pure-Python
libraries, pinned here as git submodules to specific release commits:

| Submodule | Pinned tag | Commit | Upstream |
|-----------|-----------|--------|----------|
| `ds_store` | v1.3.2 | `493956bcdfd0d52fd9d413579e18e2bec020124e` | https://github.com/dmgbuild/ds_store |
| `mac_alias` | v2.2.3 | `caa30be84fa49efd0675c3864a18ae6ffac9f6db` | https://github.com/dmgbuild/mac_alias |

Both use a `src/` layout, so the importable package lives at
`Scripts/vendor/<name>/src/<name>/`; the scripts add those `src` dirs to
`sys.path`.

## These are REQUIRED runtime deps — initialize them

```bash
git submodule update --init --recursive
```

`make dmg-arm64` / `make-dmg-dsstore.py` / `verify-dmg-layout.sh` fail loud with
this exact command if the submodules are missing.

## Bump a pinned version

```bash
cd Scripts/vendor/ds_store && git fetch --tags && git checkout v<new> && cd -
git add Scripts/vendor/ds_store           # records the new pinned commit
```

Update the table above with the new tag + commit.
