# RatioThink

A native macOS chat + local-server app for the [Pie](https://github.com/pie-project/pie)
inference engine. Built with SwiftUI + AppKit. It ships a bundled Pie engine supervised by a
menu-bar helper, and serves an OpenAI-compatible HTTP endpoint locally with a first-class
APC-enabled chat inferlet.

## Install (DMG)

Release DMGs are signed with a Developer ID and notarized by Apple, so they
pass Gatekeeper with no extra steps:

1. Download `RatioThink-arm64.dmg` (Apple Silicon) from Releases and open it.
2. Drag **RatioThink.app** into **Applications**.
3. Open **RatioThink** from Applications.

> **Unsigned / development builds.** A DMG or app you build yourself
> (`make dmg-arm64`) is *not* notarized, so Gatekeeper blocks it. For local
> use only, clear the quarantine flag — notarized release downloads never need
> this:
> ```bash
> xattr -dr com.apple.quarantine /Applications/RatioThink.app
> ```

## Build from source

**Prerequisites:** an Apple Silicon Mac (arm64), macOS 14+, Xcode (with command-line tools), [XcodeGen](https://github.com/yonaskolb/XcodeGen)
(`brew install xcodegen`), and a Rust toolchain (`rustup`) — the build compiles the bundled Pie engine.

```bash
git clone --recurse-submodules https://github.com/shsym/RatioThink.git
cd RatioThink
make build          # generates RatioThink.xcodeproj, then builds RatioThink.app + helper
```

To install a signed build into `/Applications` (verified end-to-end: helper + engine + a chat
round-trip), use `make install-app`. It needs an Apple "Apple Development" signing identity in your
keychain; override `DEVELOPMENT_TEAM` / `CODE_SIGN_IDENTITY` per machine. The background helper is
registered via `SMAppService`, which refuses an unsigned/ad-hoc agent — so signing is required for a
working install.

```bash
make install-app    # build, sign, install into /Applications, launch, verify
```

`make install-app` uses a local **Apple Development** identity. That is enough
to run and debug locally, but it is *not* a distribution identity — Gatekeeper
rejects it on download. Producing a DMG that passes `spctl` on other Macs
requires the notarized release flow below.

## Releasing (maintainers)

A notarized DMG that passes Gatekeeper on any Mac requires a paid **Apple
Developer Program** membership (for a *Developer ID Application* certificate)
and **notarytool** credentials.

1. Install the Developer ID certificate — Xcode → Settings → Accounts → Manage
   Certificates → **+** → *Developer ID Application* — and confirm it is found:

   ```bash
   security find-identity -v -p codesigning | grep "Developer ID Application"
   ```

2. Provide notary credentials via **one** of these (see `Scripts/notarize.sh`):

   ```bash
   # App Store Connect API key (recommended, esp. for CI — no 2FA/expiry):
   export NOTARY_API_KEY=/path/to/AuthKey_XXXXXX.p8
   export NOTARY_API_KEY_ID=XXXXXXXXXX
   export NOTARY_API_ISSUER=xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx

   # …or a stored keychain profile:
   xcrun notarytool store-credentials RatioThink-Notary \
       --apple-id you@example.com --team-id ABCDE12345 --password <app-specific-pw>
   export NOTARY_KEYCHAIN_PROFILE=RatioThink-Notary

   # …or an Apple ID + app-specific password (appleid.apple.com → App-Specific Passwords):
   export NOTARY_APPLE_ID=you@example.com
   export NOTARY_TEAM_ID=ABCDE12345
   export NOTARY_PASSWORD=<app-specific-password>
   ```

3. Build, sign, notarize, staple, and verify in one step:

   ```bash
   make release-dmg-arm64   # signs (Developer ID + hardened runtime),
                            # notarizes + staples the app AND the dmg,
                            # then runs the preflight as an acceptance gate
   ```

   The build **fails loudly** if the certificate or credentials are missing.
   The Developer ID identity is auto-detected; override with
   `DEVELOPER_ID_IDENTITY=<name-or-SHA1>` (and `DEVELOPMENT_TEAM=<team>` if
   needed).

Assess any built artifact at any time (reports quarantine, codesign, identity,
hardened runtime, `spctl`, stapling, and helper/engine readiness):

```bash
make release-preflight ARTIFACT=build/dmg/RatioThink-arm64.dmg
```

On a notarized release it exits **0** ("Gatekeeper-accepted"); on an unsigned
or dev build it exits non-zero and prints exactly what is missing.

## Troubleshooting / Collect diagnostics

If RatioThink "does nothing" after launch — no window, no menu-bar icon, no chat —
collect a diagnostics bundle and send it to the developer.

**From the app** (if it opens): **Help → Collect Diagnostics…**. It writes a
`.zip` to your Desktop and reveals it in Finder.

**From Terminal** (works even when the app or helper won't launch):

```bash
/Applications/RatioThink.app/Contents/Resources/collect-diagnostics.sh
```

This prints a short verdict (e.g. *quarantine present*, *helper never
launched*, *Gatekeeper rejected*, *engine failed*) and writes
`~/Desktop/RatioThink-diagnostics-<timestamp>.zip`. Attach that `.zip` to your
report.

The bundle contains app/helper versions, codesign + Gatekeeper + quarantine
status, the launchd helper state, the running-process list, recent macOS
Unified Logging for `com.ratiothink*`, recent crash reports, and the app's own
breadcrumb logs (`app.log` / `helper.log` / `engine.log`). It is **redacted**:
your home path is collapsed to `~` and obvious tokens are stripped. Chat
contents are **not** included unless you pass `--include-chats`. Other flags:
`--window <dur>` (Unified Logging look-back, default `2h`) and `--out <path>`.

## Repo layout

```
RatioThink/
├── App/            # Main SwiftUI app target (RatioThink.app)
├── Helper/         # SMAppService menu-bar helper (RatioThinkHelper.app)
├── Shared/         # Cross-target Swift library (RatioThinkCore: engine client, XPC, models, persistence)
├── Inferlets/      # chat-apc inferlet (Rust → wasm) + prebuilt artifact
├── Resources/      # App icon + asset catalog
├── Scripts/        # Build, packaging, and end-to-end test scripts
├── Sources/        # SPM CLI tools used by the test harness
├── Tests/          # XCTest unit, scenario, and GUI tests
└── Vendor/pie/     # Pie engine (vendored submodule)
```

## License

[Apache-2.0](LICENSE) — matching the Pie engine.
