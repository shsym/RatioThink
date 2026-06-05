# RatioThink — Test catalog & pre-PR gate

The single source of truth for *what tests exist, where they run, and what to
confirm before opening a PR*. `make help` lists the runnable targets; this doc
maps each to its purpose, gating, and the change types that require it.

Keep this current: when you add/rename a suite or target, update the tables
below in the same change.

## Test tiers (by `make` target)

| Target | What it runs | Runs where | Gating |
|---|---|---|---|
| `make lint` | helper side-effect invariants (static) | anywhere | — |
| `make build` | Debug build of RatioThink app + helper | anywhere | — |
| `make build-tests` | Compile every xcodebuild target + SPM probe | anywhere | — |
| `make test-xcode-chat-scaffold` | `ChatScaffoldModelSelectionTests` (xcodebuild RatioThinkTests) regression guard | anywhere | — |
| `make test-unit` | `RatioThinkCoreTests` (SPM, pure logic) | anywhere | — |
| `make test-scenario` | `CLIScenarioTests` (S0 isolation, S1/S2/S3 XPC + engine integration), headless | anywhere | — |
| `make test-smoke` | S3 engine subprocess smoke | anywhere | needs built `pie` (`make engine-build`) |
| `make test-install-guards` | launchd source-closed / agent-reenable / new-bundle acceptance regressions (stubbed) | anywhere | — (in CI) |
| `make test-collect-diagnostics` | `Scripts/collect-diagnostics.sh` self-test (redacted diagnostics bundle) | anywhere | — (in CI) |
| `make test-dmg-layout` | DMG drag-install layout verifier regression (hdiutil + codesign) | anywhere | — (in CI) |
| `make test-release` | real-tool contract tests for `notarize.sh` + `release-preflight.sh` | anywhere | — (in CI) |
| `make test-stamp` | `Inferlets/chat-apc/_stamp.py` unit tests | anywhere | — |
| `make test-e2e-http` | chat-apc HTTP API stress + SSE/concurrency + OpenAI tool-call contract (`e2e_test.py` + `stress_e2e_test.py`) vs the **dummy driver** | anywhere (headless) | self-bootstraps `pie` + wasm; needs `uv` + Qwen3-0.6B `config.json`+`tokenizer.json` in HF cache (no weights/GPU) |
| `make test-ssh` | `test-unit` + `test-scenario` + `test-smoke` + `test-install-guards` | anywhere (no GUI) | — |
| `make test-gui` | GUI scenarios (S4, S5, and the rest of `Tests/GUIScenarioTests`) via XCUITest | **seated session** | `Dock` running; Automation/Accessibility TCC |
| `make test-gui-history` | Deterministic multi-turn history/resume E2E | **seated session** | `PIE_TEST_TCC_GRANTED=1` |
| `make test-gui-first-launch-package` | Package-backed first-launch E2E (Release `.app`) | **seated session** | built artifact + TCC |
| `make test-gui-script` | Fast preflight regressions for the GUI E2E wrapper scripts | anywhere | — |
| `make test-all` | `test-ssh` + `test-gui` (GUI skips if no seated session) | seated for full | — |

The **`RatioThinkTests`** xcodebuild unit target (`Tests/Unit/*`, e.g.
`ZeroStateActionsTests`, snapshot tests) is not a standalone Make target; run a
slice with
`xcodebuild -scheme RatioThink -only-testing:RatioThinkTests/<Class> test` (see commands in
the appendices).

The **`RatioThinkGUITests`** xcodebuild UI-test target (the `S*` suites in
`Tests/GUIScenarioTests`, catalog below) backs `make test-gui`; run a single
suite with
`xcodebuild -scheme RatioThinkGUITests -only-testing:RatioThinkGUITests/<Suite> test`.

## GUI / scenario suite catalog (`Tests/GUIScenarioTests`)

All require a seated session (`guardSeatedGUI` → `XCTSkip` otherwise). Grouped
by product area; the **Run via** column is the focused modular target (see
"Modular suites by area" below). Suites whose **Boundary** is a wrapper
harness (`app+real-engine`, `app+fake-engine`, `packaged`) `XCTSkip` unless the
matching `Scripts/run-*.sh` wrote its `/tmp/*.env` first — run them through
that wrapper, not bare `xcodebuild`.

| Suite | Area | Proves | Boundary / real model? | Run via |
|---|---|---|---|---|
| `S5_AppWindowShellGUITests` | settings/shell | 3-column shell vocabulary (Chats + API Endpoints nav, #422), ⌘, → Settings (4 tabs, no API tab) | mock | `test-gui-shell` |
| `S7_FirstLaunchWizardGUITests` | first-launch | wizard flow (register / approval-blocked) | mock (faked login-item) | `test-gui-first-launch` |
| `S7_FirstLaunchWizardPackagedArtifactGUITests` | package/install | Release `.app` first-launch persists across relaunch; launched-artifact path | packaged-signed-app | `test-gui-first-launch-package` |
| `S4_HelperMenuBarGUITests` | helper/engine | menu-bar shell; fresh seed enables Resume; oversized-model rejected; Resume boots pie → Pause | app+real-engine (GGUF fixture) | `test-gui-helper` |
| `S204_ModelAcquisitionGUITests` | model discovery | Settings curated download → **verified** badge (sha256 == HF X-Linked-Etag) | real HF download (no inference) | `test-e2e-models` |
| `S204_UnverifiedBadgeGUITests` | model discovery | `.unverified` sidecar row badges after rescan; clean row does not | no engine/network (staged files) | `test-e2e-models` |
| `S260_ChatModelMenuGUITests` | model discovery | chat model menu contains seeded default profile model | mock (static placeholder menu) | `test-gui-chat` |
| `S302_ModelLoadIndicatorPath1GUITests` | model load/status | explicit load → "Loading…" → ready ring; mid-load Cancel clears + no late ready | app+fake-engine (`loadviz-harness.py`) | `test-e2e-load` |
| `S286_NoModelSendGateGUITests` | model load/status | send with nothing resolvable BLOCKS behind the "No model loaded" confirm (no silent load) | mock (gate fires pre-engine) | `test-gui-chat` |
| `S258_ComposerSendGUITests` | chat send/persist | send → **real pie stream** → bubble → SwiftData persist across relaunch | **app+real-engine (real Qwen3-0.6B)** | `test-e2e-chat` |
| `S204_ChatSendGUITests` | chat send/persist | INSTRUCT model answers "Paris" → persists across relaunch | **app+real-engine (real GGUF)** | `test-e2e-full` |
| `S275_MultiTurnResumeGUITests` | chat send/persist | ordered multi-turn history sent to engine + persisted across relaunch | app+fake-engine (deterministic HTTP) | `test-gui-history` |
| `S279_LifecycleRecoveryGUITests` | lifecycle/recovery | unreachable engine → visible recoverable error + composer re-enabled | app+real-engine seam (dead loopback) | `test-gui-chat` |
| `S285_ZeroStateGUITests` | zero-state | empty-state top-alignment; Start Chat CTA opens a chat; API Endpoints section opens the single live `LocalAPIView` (#422) | mock (stops at composer; no send) | `test-gui-chat` |
| `S326_FreshInstallModelDownloadGUITests` | first-launch | fresh install (seeded profile, model absent) → no-model gate offers inline **download**, not a dead-end Load | mock (fake downloader, pre-engine) | `test-gui` |
| `S327_EngineStatusIndicatorGUITests` | model load/status | always-visible engine-status pip; popover **stays open** across 1 Hz poll ticks (`pollCount` demoted from `@Published`) | mock (no engine) | `test-gui` |
| `S360_ModelsTopAlignGUITests` | settings/shell | Settings → Models empty state stays **top-aligned**, not vertically centered (mirrors S285) | mock (isolated empty `PIE_HOME`) | `test-gui` |
| `S365_CachedModelDiscoveryGUITests` | model discovery | HF-cache-staged model surfaces as a Settings **"HF-cache" row** + in the profile picker; pure filesystem scan | staged HF cache (no engine/network) | `run-cache-discovery-gui-e2e.sh` |
| `S396_RetryRecoveryGUITests` | model load/status | forced HTTP 500 load → red "Load failed" pip; popover **Retry** recovers (`retryLast`), **Dismiss** clears (default key) | app+fake-engine (`loadviz-harness.py` fail-first) | `test-e2e-396` |

> Reconciled against `Tests/GUIScenarioTests/` on 2026-06-02 — every suite on
> disk is listed above. A `S7_FirstLaunchWizardPackagedModelDownloadGUITests`
> suite named in older catalogs does **not** exist on disk: a first-launch
> **packaged model download** GUI suite is a tracked coverage gap, not an
> existing test.

## Modular suites by area

Run the area you touched for fast, attributable signal instead of the whole
matrix. GUI targets need a seated session + TCC; E2E targets additionally need
the real engine / model (or a deterministic harness) and fail loud with an
exact fix command when a human gate is unmet.

| Area | Focused target(s) | Aggregate |
|---|---|---|
| settings / app shell | `make test-gui-shell` (S5) | `test-gui` |
| first launch (wizard) | `make test-gui-first-launch` (S7 fast) | `test-gui` |
| package / install | `make test-gui-first-launch-package` (S7 packaged `.app`) | — |
| helper / engine startup | `make test-gui-helper` (S4); `make test-smoke` (S3 subprocess); `make test-e2e-engine` (real launch) | `test-gui` / `test-ssh` |
| engine-free chat surfaces | `make test-gui-chat` (S260/S279/S285/S286) | `test-gui` |
| model discovery / download | `make test-e2e-models` (S204 acquisition + unverified badge + live HF acquire); `Scripts/run-cache-discovery-gui-e2e.sh` (S365 HF-cache → Settings row) | — |
| model load / status | `make test-e2e-load` (S302 indicator); `make test-e2e-396` (S396 failed-load Retry/Dismiss) | — |
| chat send / persist (real) | `make test-e2e-chat` (S258); `make test-e2e-full` (S204 3-layer) | — |
| chat history / resume | `make test-gui-history` (S275 deterministic) | — |
| install-time launchd safety | `make test-install-guards` (stubbed, runs anywhere — in CI) | `test-ssh` |
| live helper respawn | `make test-helper-respawn` (signed/registered install) | — |
| diagnostics | `make test-collect-diagnostics` (bundle self-test, in CI) + `DiagnosticLogTests` via `test-unit` | `test-ssh` |
| notarization / release preflight | `make test-release` (notarize + preflight contract tests) + `make test-dmg-layout` (DMG layout verifier), both in CI; `release-preflight ARTIFACT=…` for a built artifact | — |

`make test-gui` still runs the **entire** `RatioThinkGUITests` matrix; the
focused targets are `-only-testing` slices of it. A few suites have **no**
focused target and run only in the full matrix: `S326` (fresh-install
download), `S327` (engine-status pip), `S360` (Models top-align).

### GUI temp-home cleanup

A GUI suite that needs the non-sandboxed `RatioThink.app` to write a real
on-disk store stages its `PIE_HOME` under a real `/tmp` path (S285, S286) —
never `NSTemporaryDirectory()`, which resolves to the sandboxed runner's
container the app cannot write. Consequence: the suite **cannot delete that
home itself**. The `RatioThinkGUITests-Runner` is app-sandboxed
(`com.apple.security.app-sandbox`), so its `tearDown` `removeItem` on
`/private/tmp` is silently denied and each run leaks a `<prefix>-<uuid>` dir
(observed: dozens of stale `/tmp/pie-s285-*`). Authoritative cleanup is the
`GUI_TMP_HOMES` sweep in the GUI Make recipes (`gui_suite_run` + `test-gui`),
which runs in a non-sandboxed shell after `xcodebuild` exits (every test app
already dead). **A new GUI suite that stages a real `/tmp` home must add its
glob to `GUI_TMP_HOMES` in the Makefile** — the in-suite `tearDown` is
best-effort and a no-op under the sandboxed runner.

## Pre-PR gate

**Automated (CI — `.github/workflows/lint.yml`, on push + pull_request,
`macos-15` runners):** `make lint` + lint self-test → build app + helper →
`make build-tests` → `make test-xcode-chat-scaffold` → `make test-unit` +
`make test-scenario` → SpawnEnvSanitizer canary → inferlet build/stamp verify.

**CI does NOT cover** (headless runners, no model/engine):
- any **GUI** scenario (`guardSeatedGUI` skips them all),
- any **real-model** path (S258, packaged-model, S3-real), and
- the **HTTP API E2E** (`make test-e2e-http`) — dummy-driver only (no GPU,
  no model weights) so it is CI-*eligible*, but it needs the `pie` binary
  built + the small Qwen3-0.6B `config.json`/`tokenizer.json` in the HF
  cache; provisioning those into `lint.yml` is a tracked follow-up. Run it
  locally/by operator for now.

There is **no local git hook**. So GUI + real-model proof is manual and
developer-owned. A PR touching those areas must carry its own evidence (log /
wrapper PASS line) in the PR body.

### Confirm-before-PR by change type

| You changed… | Run before PR |
|---|---|
| Pure logic / models / services (no UI) | `make test-ssh` (and the matching `RatioThinkCoreTests`/`RatioThinkTests` slice) |
| SwiftUI views / layout / copy / a11y ids | `make test-ssh` + the affected GUI suite(s) (e.g. `-only-testing:RatioThinkGUITests/S285_…`, `…/S5_…`, `…/S7_…`) |
| Chat ↔ engine send / streaming / persistence | the affected GUI suite **+ a real-model proof**: `Scripts/run-chat-gui-e2e.sh` (Appendix B) or `make test-gui-history` |
| First-launch / wizard / model download | `S7_*` GUI suites + `make test-gui-first-launch-package` |
| Engine launch / supervisor / XPC / helper | `make test-ssh` (incl. `test-smoke`) + `S4_HelperMenuBarGUITests`; real-engine S3 (Appendix A) if launch args changed |
| Engine subprocess / inference contract | S3-real (Appendix A) + `make test-stamp` if inferlet stamps touched |
| chat-apc HTTP routes / SSE / tool calling (`Inferlets/chat-apc/src`) | `make test-e2e-http` (rebuilds wasm + restamps via `stamp-inferlets` if you edited `src/`) |
| Broad / release / "everything" | `make test-all` on a seated session (real-model wrappers run separately) |

Rule of thumb: always run `make test-ssh` (cheap, runs anywhere); add the GUI
suite(s) whose code you touched; add a real-model wrapper only when you touched
the chat↔engine path. Don't run the full GUI matrix for an isolated change —
run the affected suites for fast, attributable signal.

The appendices below are the maintained run commands + last-observed PASS
evidence for the real-model / deterministic E2E wrappers.

---

# Appendix A — E2E verification notes

Scope: verification for the `ComposerView → HTTPEngineClient → MessageStreamWriter`
chat send path. Keep the small cached HF model path first; do not start with a
large local GGUF unless the small-model path is proven or precisely blocked.

## Prerequisites

- macOS with Apple Silicon/Metal.
- Built pie engine binary:
  `Vendor/pie/target/aarch64-apple-darwin/release/pie`
- `chat-apc` resources present:
  - `Inferlets/chat-apc/prebuilt/chat-apc.wasm`
  - `Inferlets/chat-apc/Pie.toml`
- Cached HF model for the small-model proof:
  `~/.cache/huggingface/hub/models--Qwen--Qwen3-0.6B`
- For GUI/XCUITest work:
  - Run from a seated console/Screen Sharing session; `Dock` must be running.
  - Grant Xcode/XCTest runner Automation and Accessibility permissions in
    System Settings, then export `PIE_TEST_TCC_GRANTED=1` for tests that require
    menu-bar interaction.
  - If using the existing S4 helper boot test, stage
    `Qwen3-0.6B-Q8_0.gguf` at `test-models/` or set `PIE_TEST_MODEL` to the
    fixture path. That S4 path is a GGUF fixture path and is separate from the
    small HF cache path below.

## Small-model real generation command

Run this before any 30B GGUF attempt:

```bash
PIE_TEST_S3_REAL=1 \
PIE_BIN="$PWD/Vendor/pie/target/aarch64-apple-darwin/release/pie" \
Scripts/run-swift-test.sh --filter 'S3_EngineSubprocessCLITests'
```

Expected pass evidence:

- `pie serve started + chat-apc installed`
- `GET /healthz → ok`
- `GET /v1/models → non-empty`
- `load Qwen/Qwen3-0.6B (≤90s)`
- `POST /v1/chat/completions → looks like real inference`
- XCTest exits 0.

**Gotcha:** a sandboxed run can be blocked by SwiftPM writing to
`~/.cache/clang/ModuleCache` — rerun outside the sandbox.

**Finish-reason acceptance:** the S3 drain accepts `.stop` or Qwen3's observed
`.length` only after at least one non-empty assistant delta and the
semantic-content check pass. Missing, cancelled, or other finish reasons fail.

_Last verified 2026-05-25 — 2 S3 tests, 0 failures._

## Existing GUI command and blockers

The direct small-model GUI E2E wrapper:

```bash
Scripts/run-chat-gui-e2e.sh
```

Auto-prep: the wrapper now sources `Scripts/e2e-prep.sh` and
**builds the `pie` engine** (`make engine-build`) and **downloads the HF model**
automatically if either is missing. The human-only gates (seated session, TCC)
still fail fast with exact fix steps. Set `PIE_E2E_AUTOPREP=0` to verify-only
(no build/download) for deterministic CI.

What the wrapper does:

- checks for a seated GUI session (`Dock` running),
- requires `PIE_TEST_TCC_GRANTED=1` before starting the engine so missing
  Automation/Accessibility permission fails with a recovery command instead of
  burning a model launch and timing out in Xcode automation mode,
- checks the small HF cache for `Qwen/Qwen3-0.6B`,
- launches a real `pie` engine through `chat-engine-harness`,
- preloads `Qwen/Qwen3-0.6B`,
- writes `/tmp/pie-chat-gui-e2e.env` with the live loopback URL and an
  isolated GUI `PIE_HOME`,
- runs `S258_ComposerSendGUITests`.
- removes `/tmp/pie-chat-gui-e2e.env` on exit so a failed run cannot leave
  a dead loopback URL for a later direct XCUITest invocation.

Optional environment overrides:

- `PIE_TEST_CHAT_MODEL` defaults to `Qwen/Qwen3-0.6B`.
- `PIE_BIN` defaults to
  `$PWD/Vendor/pie/target/aarch64-apple-darwin/release/pie`.
- `PIE_TEST_RUN_ROOT` defaults to `/tmp/p258-<pid>`; the wrapper uses short
  subpaths under it because the portable pie driver has a Unix socket path
  length limit.
- `PIE_TEST_TCC_GRANTED=1` is required after granting Automation and
  Accessibility permissions in System Settings.

Expected pass evidence:

- wrapper prints `chat gui e2e: engine=http://127.0.0.1:<port>`,
- wrapper prints `chat gui e2e: model=Qwen/Qwen3-0.6B` unless
  `PIE_TEST_CHAT_MODEL` explicitly overrides the small HF fallback model,
- XCUITest creates a chat, types `The capital of France is`, clicks send,
- an assistant bubble becomes visible in the GUI,
- app relaunches with the same `PIE_HOME`,
- the assistant bubble is visible again after relaunch,
- wrapper verifies `chats.sqlite` has an assistant row containing `Paris`
  (MarkdownUI truncates/splits long Accessibility static-text labels, so the
  semantic response assertion is intentionally made against SwiftData storage),
- wrapper prints `chat gui e2e: persisted assistant row contains Paris`,
- wrapper prints `chat gui e2e: PASS`.

_Last verified 2026-05-22 — `S258_ComposerSendGUITests`, 1 test, 0 failures;
wrapper printed `chat gui e2e: PASS` and the persisted assistant row contained
`Paris`._

# Appendix B — deterministic GUI history/resume command

Use this scenario for conversation-history correctness. It deliberately does
not rely on real LLM output: the wrapper starts a local deterministic HTTP
harness that implements `/healthz`, `/v1/models`, `/v1/models/load`, and
`/v1/chat/completions`, records every chat request body as JSONL, and streams
fixed assistant responses.

```bash
PIE_TEST_TCC_GRANTED=1 Scripts/run-resume-gui-history-e2e.sh
```

Equivalent Make target:

```bash
PIE_TEST_TCC_GRANTED=1 make test-gui-history
```

Expected pass evidence:

- wrapper prints `resume gui history e2e: engine=http://127.0.0.1:<port>`,
- wrapper prints `resume gui history e2e: model=resume-deterministic`,
- wrapper prints the isolated GUI `PIE_HOME` and retained request-log path,
- XCUITest sends turn 1:
  `Remember this code word: cerulean-275`,
- deterministic harness returns:
  `I will remember cerulean-275.`,
- XCUITest sends turn 2:
  `What code word did I give you?`,
- request log entry 2 contains the ordered in-session history:
  user turn 1, assistant turn 1, user turn 2,
- XCUITest terminates/relaunches RatioThink.app with the same `PIE_HOME`, selects the
  persisted chat, and sends turn 3:
  `Repeat the code word again.`,
- request log entry 3 contains the ordered persisted history:
  user turn 1, assistant turn 1, user turn 2, assistant turn 2, user turn 3,
- wrapper verifies `chats.sqlite` contains all six expected message rows in
  order,
- wrapper prints:
  `resume gui history e2e: request log contains ordered turn-2 and turn-3 histories`,
- wrapper prints:
  `resume gui history e2e: sqlite contains all 6 expected message rows in order`,
- wrapper prints `resume gui history e2e: PASS`.

_Last verified 2026-05-25 — `S275_MultiTurnResumeGUITests`, 1 test, 0 failures;
wrapper printed `resume gui history e2e: PASS`._

Lower-level fallback — the smallest real GUI engine-boot path. A missing seated
session, an unset `PIE_TEST_TCC_GRANTED=1`, or a missing model at
`test-models/Qwen3-0.6B-Q8_0.gguf` (or `PIE_TEST_MODEL`) each **`XCTSkip`** the
test with its own recovery message. The `Timed out while enabling automation
mode` failure is separate: it means the real OS Automation/Accessibility
permission is ungranted (the `PIE_TEST_TCC_GRANTED` flag only opts in — it does
not grant it), so grant it in System Settings first.

```bash
xcodebuild -project RatioThink.xcodeproj \
  -scheme RatioThinkGUITests \
  -destination 'platform=macOS,arch=arm64' \
  -parallel-testing-enabled NO \
  test \
  -only-testing:RatioThinkGUITests/S4_HelperMenuBarGUITests/test_first_run_clicking_resume_boots_engine_and_flips_to_pause \
  CODE_SIGNING_ALLOWED=NO \
  ENABLE_CODE_COVERAGE=NO
```

`S258_ComposerSendGUITests` is the first GUI suite to exercise the full
`RatioThink.app → create/select chat → ComposerView send → HTTPEngineClient →
real engine stream → MessageStreamWriter → persisted assistant message` path
end to end.
