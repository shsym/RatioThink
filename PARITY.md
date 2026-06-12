# Rational — E2E ↔ production parity matrix

How each test/script tier maps to the **real packaged-binary chat path**, and
every intentional bypass it takes. Companion to [`TEST.md`](TEST.md) (which is
the run/gate catalog); this doc is the *fidelity* catalog. Keep both current in
the same change when you add/rename a suite, a wrapper, or a `PIE_*` knob.

The motivating failure class: a tier can pass while production breaks, because
the test bypassed the layer that was actually broken (Helper launch,
SMAppService registration, model-path resolution, CLI contract). A green suite
is only as honest as the boundary it actually crosses.

## The production boundary (what "real" means)

A normally-launched, signed `/Applications/Rational.app` does **all** of:

1. **Launch topology** — App registers an `SMAppService.agent` so **launchd**
   owns the `com.ratiothink.helper` MachService; App↔Helper talk over that
   launchd-published XPC endpoint (not an anonymous in-process listener).
2. **Signing** — App + Helper are signed with a real Team ID; the Helper's XPC
   listener enforces the caller's Team-ID identity (ad-hoc `-` has no Team ID).
3. **Engine launch** — Helper runs `PieEngineHost` → `PieControlLauncher.launch`
   → real `pie serve` (driver-capability probe, free port, `config.toml`,
   handshake, `install_program` + `launch_daemon` over WS).
4. **Model resolution** — `LaunchSpecResolver` resolves `profile.model` against
   the app-staged models root then the HF/pie cache; rejects symlinks /
   directories / oversized / incomplete snapshots; served model id == profile
   slug.
5. **Filesystem** — `/Applications/Rational.app` bundle resources (embedded
   Helper, `pie-engine/pie`, `chat-apc` wasm + manifest, staged LaunchAgent
   plist), `PIE_HOME = ~/Library/Application Support/RatioThink`.
6. **UI observability** — missing model / resolver failure / engine-start
   failure / engine death / stream failure / successful persist each reach a
   visible app state (no indefinite silent "Engine starting").

Each automated tier below crosses **some** of these and stubs the rest. The
stubbed layers are listed explicitly so a reader never mistakes a green tier for
production coverage.

## Coverage matrix

Legend — **Launch**: how the engine is reached. `real-launch` = resolver →
launcher → `pie serve`; `base-URL` = `PIE_TEST_ENGINE_BASE_URL` points at a
pre-launched engine/harness (Helper + resolver + launcher all bypassed);
`anon-XPC` = real Helper but anonymous listener, not SMAppService/launchd;
`synthetic` = injected launcher closure; `n/a` = no engine. **Model**: `real` /
`fixture GGUF` / `HTTP harness` (deterministic fake) / `fake` / `n/a`.
**Signed**: does it exercise the Team-ID XPC gate.

| Tier | Where | Launch | Engine/Model | Signed | Bypasses (knobs) |
|---|---|---|---|---|---|
| `RatioThinkCoreTests` (SPM) | CI | n/a | n/a | no | pure logic; no process |
| └ `LaunchSpecResolverTests` | CI | n/a | n/a | no | model-path resolution **unit-proven** (missing/dir/**symlink**/dangling/incomplete/corrupt/oversized/%2F → loud) |
| └ `PieControlLauncherConfigTests` | CI | n/a | n/a | no | **stubs the driver probe** (emulates the pie CLI contract) |
| └ `PieControlLauncherSocketBudgetTests` | CI | n/a | n/a | no | `sun_path` budget preflight **unit-proven** |
| └ `HelperRegistrationReconcilerTests` | CI | n/a | n/a | no | SMAppService register/unregister stubbed (closures) |
| └ `CallerIdentityTests` | CI | n/a | n/a | models gate | asserts unsigned-caller bypass refused in prod |
| `CLIScenarioTests/S1,S2,S3` | CI/`test-scenario` | `synthetic`/dummy | dummy driver | no (`PIE_TEST_MODE`) | dummy driver = no aux socket; isolated `PIE_HOME` |
| `StartEngineXPCIntegrationTests` | CI | `synthetic` | injected launcher | no | real XPC roundtrip, **fake launcher** |
| `XPCListenerIntegrationTests` | CI | n/a | n/a | `anon-XPC` | `PIE_ALLOW_UNSIGNED_CALLERS` (DEBUG) |
| `RealEngineLaunchE2ETests` | env-gated, manual | **real-launch (in-proc)** | **real** GGUF | no | NOT via Helper XPC / SMAppService; short `/tmp` `PIE_HOME` |
| `S3EngineSubprocessTests` (`PIE_TEST_S3_REAL`) | manual | **real `pie serve`** | **real** GGUF | no | in-proc launcher; not via Helper |
| `S4_HelperMenuBarGUITests` | seated | **real engine via Helper menu** | fixture GGUF | `anon-XPC` | `PIE_ALLOW_UNSIGNED_CALLERS=1` (not SMAppService/launchd) |
| `S5_AppWindowShellGUITests` | seated | n/a | n/a | no | shell only |
| `S7_FirstLaunchWizard*GUITests` | seated | n/a | fake / `fixture GGUF` (packaged-model) | no | `PIE_TEST_FAKE_DOWNLOADS` / fixture downloader |
| `S204_*GUITests` | seated | `base-URL` (acquisition = real HF download) | real download / HTTP | no | `PIE_TEST_ENGINE_BASE_URL` |
| `S258_ComposerSendGUITests` | seated | `base-URL` | **real inference** (harness-launched) | no | `PIE_TEST_ENGINE_BASE_URL` — **launch path not exercised** |
| `S260_ChatModelMenuGUITests` | seated | n/a | n/a | no | menu only |
| `S275_MultiTurnResumeGUITests` | seated | `base-URL` | HTTP harness (deterministic) | no | `PIE_TEST_ENGINE_BASE_URL` |
| `S279_LifecycleRecoveryGUITests` | seated | `base-URL` (stale URL) | n/a | no | `PIE_TEST_ENGINE_BASE_URL` |
| `S285/S286 GUITests` | seated | n/a | n/a | no | zero-state / no-model send gate |
| `S302_ModelLoadIndicator*GUITests` | seated | `base-URL` | HTTP harness | no | `PIE_TEST_ENGINE_BASE_URL` |
| **`Scripts/install-app.sh`** | **operator** | **real-launch via SMAppService→launchd→Helper XPC** | **real** model | **YES** | **none — full production boundary** |
| `Scripts/verify-helper-respawn.sh` | operator (signed) | real Helper respawn | — | YES | none (kills Helper, asserts launchd respawn) |
| `Scripts/run-engine-e2e.sh` | manual | **real-launch (in-proc)** | **real** GGUF | no | wraps `RealEngineLaunchE2ETests`; self-bootstraps GGUF/binary |

**Bottom line:** no *automated* tier crosses the full signed
SMAppService + launchd-MachService boundary — that requires code signing, so it
is **operator-only** via `install-app.sh`. Every automated "real model" tier is
*real inference, bypassed launch* unless the Launch column says `real-launch`.

## Bypass / test-knob inventory

| Knob | Bypasses | Gated so production is safe? |
|---|---|---|
| `PIE_TEST_ENGINE_BASE_URL` | the App-side redirect swaps the chat client's base URL *ahead of* the launch chain (Helper XPC → `EngineStatusStore` → `LaunchSpecResolver` → `PieControlLauncher` → `pie serve`), so none of that chain runs — the var is read only by the redirect, not inside each listed component | **Fully gated** — both consumers route through the shared `HelperConfig.isTestOverrideAllowed` (`PIE_TEST_MODE=1` or `#if DEBUG` only). `RatioThinkApp.isEngineBaseURLOverrideAllowed`: a Release build **ignores the redirect and logs**, so a shipped app can't be pointed at a foreign URL and a "real binary" scenario can't silently run on a fake URL. `HelperRegistrationReconciler.isTestLaunch`: the same marker no longer counts in Release, so a Release launch with the var set **still runs the launchd self-heal reconcile** instead of skipping it. |
| `PIE_ALLOW_UNSIGNED_CALLERS` | Helper XPC caller Team-ID identity check (publishes an anonymous listener) | **Yes** — `HelperXPCListener.isAnonymousModeAllowed`: `PIE_TEST_MODE` or `#if DEBUG` only; Release returns `false` + `preconditionFailure` at the call site |
| `PIE_TEST_MODE` | Helper system side effects (NSStatusBar/NSAlert/SMAppService/IOPM) | **Yes** — `HelperConfig.assertSystemSideEffectAllowed` `fatalError`s if set in a real side-effect path; override seam cannot suppress it |
| `PIE_TEST_SKIP_HELPER_RECONCILE` | launch-time SMAppService self-heal reconcile | test-launch only — `HelperRegistrationReconciler.isTestLaunch` skips the real registrar |
| `PIE_TEST_FAKE_DOWNLOADS` / `PIE_TEST_FIXTURE_DOWNLOADS` | real model downloader (wizard/Settings) | test-launch markers; production uses `ModelDownloadController()` |
| `PIE_TEST_LOGIN_ITEM_STATUS` | real SMAppService status read | stub injected for status surfaces |
| `PIE_TEST_REAL_PIE_BIN` / `_MODEL_PATH` / `_CHATAPC_WASM` / `_CHATAPC_MANIFEST` | nothing — these **force the real** engine inputs | opt-in for `RealEngineLaunchE2ETests` (the anti-bypass) |
| `PIE_TEST_S3_REAL` | nothing — opts S3 into a real `pie serve` | manual real-engine gate |
| `CODE_SIGN_IDENTITY="-"` / `CODE_SIGNING_ALLOWED=NO` | real Team-ID signing (CI/local builds are ad-hoc) | the Team-ID XPC gate is therefore **not** exercised by any automated tier; `install-app.sh` requires a real identity |

## Parity guards

- **Release ignores `PIE_TEST_ENGINE_BASE_URL`** (`App/RatioThinkApp.swift`) — the
  one production bypass that was honored unconditionally is now gated like the
  unsigned-caller bypass. Both consumers of the var
  (`isEngineBaseURLOverrideAllowed` and `HelperRegistrationReconciler.isTestLaunch`)
  share one `HelperConfig.isTestOverrideAllowed` predicate, and its Release
  branch is unit-testable via an injected `isDebugBuild` seam (the `#if DEBUG`
  capture otherwise hides it from a DEBUG test build). Unit:
  `EngineBaseURLOverrideGateTests`, `HelperConfigTests`,
  `HelperRegistrationReconcilerTests`.
- **`sun_path` preflight** (`PieControlLauncher.launch`) — a `PIE_HOME` deep
  enough that the engine's aux Unix socket
  `$PIE_HOME/standalone/<pid>/g0/aux.sock` would overrun the 104-byte Darwin
  `sun_path` limit now throws `LaunchError.pieHomePathTooLong` **before**
  spawning (a silent-hang class), gated to real (`portable`/`metal`) drivers
  only — `dummy` binds no aux socket. Unit:
  `PieControlLauncherSocketBudgetTests`.
- **App-staged symlink model rejection** is unit-pinned
  (`LaunchSpecResolverTests.test_resolveLauncherSpec_rejects_app_staged_symlink_at_model_path`).

## Operator scenario: the full signed boundary

`Scripts/install-app.sh` is the only end-to-end exercise of the production
boundary. It: builds **signed** → verifies the signature → quits + reaps any
stale Helper/engine → atomically swaps the bundle into `/Applications` →
launches (SMAppService register / reconcile) → **polls until the engine serves
`/v1/models` and a real `/v1/chat` round-trip returns**, else fails loud with
guidance (incl. the System-Settings login-item approval hint and a
"download the seeded model" hint). `Scripts/verify-helper-respawn.sh`
adds the kill→launchd-respawn proof. Both require a real signing identity
(`DEVELOPMENT_TEAM` / `CODE_SIGN_IDENTITY` overridable); SMAppService refuses an
unsigned/ad-hoc agent, which is why this is operator-run and not CI.

## Wrapper prerequisite contract

Every real-model / GUI wrapper either sources the `Scripts/e2e-prep.sh` gate
library (seated-GUI, TCC, chat-apc, `pie`-build, HF-model gates — autoprep the
safe ones, else print the exact command and exit non-zero), self-bootstraps
(`run-engine-e2e.sh`), or prints exact setup + exits non-zero. No wrapper
bare-exits or `XCTSkip`s a missing prereq silently — a skipped prerequisite
never masquerades as coverage.

## Known parity gaps (tracked elsewhere — do not "fix" here)

- **pie CLI drift.** `PieControlLauncher`'s driver-readiness probe shells out to
  a `pie` subcommand; the config-test stubs emulate that CLI contract so CI
  stays green even if the real binary's contract drifts. Real coverage:
  `RealEngineLaunchE2ETests` + `install-app.sh` (real binary). Lesson: a pie
  submodule bump must re-validate every shelled `pie` subcommand against the
  real binary, not just stubs.
- **Signed SMAppService + launchd MachService boundary** is operator-only by
  construction (needs signing). No CI tier crosses it; `install-app.sh` is the
  acceptance gate.
- **Team-ID XPC gate** is unexercised by automated tiers (ad-hoc signing).
