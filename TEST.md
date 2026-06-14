# Rational — Test catalog & pre-PR gate

The single source of truth for *what tests exist, where they run, and what to
confirm before opening a PR*. `make help` lists the runnable targets; this doc
maps each to its purpose, gating, and the change types that require it.

Keep this current: when you add/rename a suite or target, update the tables
below in the same change.

## Test tiers (by `make` target)

| Target | What it runs | Runs where | Gating |
|---|---|---|---|
| `make ci-pr` | Normal local merge-evidence aggregate: `lint`, CI-v2 taxonomy guard, app-icon provenance, compile/type check via `build-static`, SPM unit tests, install-guard contracts, diagnostics self-test, sanitizer canary, release-script contracts | local + optional manual GitHub workflow | **Normal local merge evidence**; on-demand GitHub verification |
| `make build-static` | Xcode Debug compile/type check of the Rational app + helper with `PIE_SKIP_ENGINE_BUILD=1` so the Rust engine long pole is not built | local + optional manual GitHub workflow | Lightweight compile/type check in `ci-pr` |
| `make local-pre-merge` | `ci-pr` plus `build-tests`, app-unit, scenario/smoke, HTTP E2E, real-pie driver contract, gmake recipe canary | local operator machine | **Mandatory before merge** for non-doc changes; carries runtime coverage kept local |
| `make local-gui-gate` | GUI wrapper script regressions + full `RatioThinkGUITests` matrix | seated local session | **Mandatory before merge** for GUI/UI changes |
| `make local-e2e-gate` | Standard real-engine/model/signing/helper E2E wrappers (`test-e2e-engine`, `test-e2e-models`, `test-e2e-chat`, `test-e2e-tot`, `test-e2e-full`, GUI history/package, helper respawn/recovery, structured quit); excludes the separate ~9 GB `test-e2e-large-model` proof | local/operator only | **Mandatory before merge/release** for affected engine/model/install paths |
| `make release-gate` | `local-pre-merge` + live-HF curated audit + DMG layout + artifact preflight | local/operator + release machine | **Mandatory before release**; also run `make release-preflight ARTIFACT=…` on the built artifact |
| `make lint` | helper side-effect invariants (static) | anywhere | Local/manual via `ci-pr` |
| `make build` | Debug build of the Rational app + helper, including real Rust engine bundle build | local | Local packaging/runtime verification |
| `make build-tests` | **Compile-only** smoke of every xcodebuild target + SPM probe (does NOT run the bundles) | local | Local pre-merge via `local-pre-merge` |
| `make test-app-unit` | **RatioThinkTests** app-unit bundle (xcodebuild): #420 deep-link/login-item guards, ChatScaffold, ZeroState, snapshots | local (headless, needs Xcode) | Local pre-merge via `local-pre-merge`; CI only type-checks app/helper via `build-static` |
| `make test-xcode-chat-scaffold` | `ChatScaffoldModelSelectionTests` focused slice of the app-unit bundle | local | Focused local app-unit slice |
| `make test-xcode-helper` | `RatioThinkHelperTests` helper-executable unit bundle with zero-test guard | local | Focused local helper slice; compiled by `build-tests` |
| `make test-unit` | `RatioThinkCoreTests` (SPM, pure/deterministic logic) | local + optional manual GitHub workflow | Local/manual via `ci-pr` |
| `make test-scenario` | `CLIScenarioTests` (S0 isolation, S1/S2/S3 XPC + engine integration), headless | local | Local pre-merge via `local-pre-merge` |
| `make test-smoke` | S3 engine subprocess smoke | local | Local pre-merge via `local-pre-merge`; needs built `pie` (`make engine-build`) |
| `make test-install-guards` | launchd source-closed / agent-reenable / new-bundle acceptance regressions (stubbed) | local + optional manual GitHub workflow | Local/manual via `ci-pr` |
| `make test-collect-diagnostics` | `Scripts/collect-diagnostics.sh` self-test (redacted diagnostics bundle) | local + optional manual GitHub workflow | Local/manual via `ci-pr` |
| `make test-sanitizer-canary` | SpawnEnvSanitizer canary through the live Swift test environment with a zero-test guard | local + optional manual GitHub workflow | Local/manual via `ci-pr` |
| `make test-ci-v2-static-gate` | Shell guard that asserts the workflow/Makefile keep the CI-v2 lightweight/manual/static taxonomy | local + optional manual GitHub workflow | Local/manual via `ci-pr` |
| `make test-real-pie-driver-contract` | Builds the worktree pie engine and runs the real `pie driver list` drift guard without silent skips | local | Local pre-merge parity for the real-pie driver contract |
| `make test-gmake-recipe-canary` | gmake 4.x recipe failure/log canary (requires Homebrew `gmake`) | local | Local pre-merge parity when Makefile recipes change |
| `make test-readme-harness` | README screenshot canned-copy branding guard | local | Focused local docs/product-name guard |
| `make test-dmg-layout` | DMG drag-install layout verifier regression (hdiutil + codesign) | local/release | Release gate via `release-gate` |
| `make test-release` | real-tool contract tests for `notarize.sh` + `release-preflight.sh` | local/release + optional manual GitHub workflow | Local/manual via `ci-pr`; also included in `release-gate` through `local-pre-merge` |
| `make test-stamp` | `Inferlets/chat-apc/_stamp.py` unit tests | local + optional manual GitHub workflow when inferlet-relevant paths changed | Conditional manual provenance gate |
| `make test-inferlets` | chat-apc Rust unit tests (native cargo test --lib) | local + optional manual GitHub workflow when inferlet-relevant paths changed | Conditional manual provenance gate |
| `make verify-inferlets` | Verify committed chat-apc prebuilt + stamp against the tree | local + optional manual GitHub workflow when inferlet-relevant paths changed | Conditional manual provenance gate |
| `make build-inferlets` / `make stamp-inferlets` / `make verify-inferlets-inputs` | Rebuild/restamp wasm and check rebuilt-tree inputs | local | Local pre-merge/release when inferlet source, WIT/vendor pin, or prebuilt wasm changes |
| `make test-curated-hf` | Live-HF existence audit of the curated catalog (`PIE_TEST_REAL_HF=1`; network) | scheduled/targeted PR workflow + local | `curated-catalog-audit` for catalog edits/nightly; release gate via `release-gate` |
| `make test-e2e-http` | chat-apc HTTP API stress + SSE/concurrency + OpenAI tool-call contract (`e2e_test.py` + `stress_e2e_test.py`) vs the **dummy driver** | local (headless) | Local pre-merge via `local-pre-merge`; needs `uv` + Qwen3-0.6B config/tokenizer HF cache |
| `make test-e2e-cache-real` | chat-apc APC prefix-cache real-engine smoke (`cache_smoke_real.py`): actual snapshot save/open KV reuse and a turn-2 cache hit vs portable-Metal real model | local/operator only | Not CI; needs `uv`, built/downloadable pie+chat-apc, and real model weights (default `Qwen/Qwen3-0.6B`) |
| `make test-apc-bench-selftest` / `make bench-apc-real` | Engine-free parser/report unit guard, plus opt-in real-engine APC benchmark (`apc_bench_real.py`) comparing cold/miss vs warm/hit continuations and writing JSON+Markdown artifacts | selftest anywhere; benchmark local/operator only | Benchmark is not CI; needs `uv`, built/downloadable pie+chat-apc, and real model weights (default `Qwen/Qwen3-0.6B`) |
| `make test-e2e-engine` | Real Helper-hosted engine launch + inference using `RealEngineLaunchE2ETests` and a staged small GGUF | anywhere (headless) | built worktree `pie` + `chat-apc`; downloads/stages small GGUF if needed |
| `make test-e2e-large-model` | **Manual** real Helper-hosted engine launch + inference for representative curated large GGUF (`Qwen/Qwen3-14B-GGUF/Qwen3-14B-Q4_K_M.gguf`, ~9 GB) | local/operator only | built **worktree** `pie` + `chat-apc`; may download ~9 GB; intentionally not PR CI |
| `make test-ssh` | `test-unit` + `test-scenario` + `test-smoke` + `test-install-guards` | local (no GUI) | Convenience local subset; not part of `ci-pr` |
| `make test-gui` | GUI scenarios (S4, S5, and the rest of `Tests/GUIScenarioTests`) via XCUITest | **seated session** | Local GUI gate via `local-gui-gate` |
| `make test-gui-history` | Deterministic multi-turn history/resume E2E | **seated session** | Local E2E gate |
| `make test-gui-stream-cancel` | #507 deterministic stream-continuity E2E (stream survives chat switch + row indicator + background finish) | **seated session** | Local E2E gate |
| `make test-gui-chat-retry` | #513 deterministic retry-from-a-prior-turn E2E (truncation confirm + regenerate from retained prefix) | **seated session** | Local E2E gate |
| `make test-gui-load-default` | #381 deterministic no-model → Load-default follow-through E2E | **seated session** | Local E2E gate |
| `make test-gui-first-launch-package` | Package-backed first-launch E2E (Release `.app`) | **seated session** | Local E2E gate |
| `make test-e2e-package` | #381-seam packaged first-launch → model download → Load-default → chat (#379) | **seated session** | Local E2E gate |
| `make test-gui-script` | Fast preflight regressions for GUI/E2E wrapper scripts | anywhere | Local GUI gate via `local-gui-gate` plus wrapper-contract coverage for operator-gated E2E scripts |
| `make test-e2e-tot` | Real-engine tree-of-thought app path completes without the #413 stall | local/operator only | Local E2E gate |
| `make test-quit-structured` | Live structured-quit acceptance: idle engine persists; `ratiothink://quit` leaves no App/Helper/pie | signed install + running engine | Local E2E/manual live gate |
| `make test-all` | `test-ssh` + `test-app-unit` + `test-gui` (GUI skips if no seated session) | seated for full | Legacy broad local convenience target |

The **`RatioThinkTests`** xcodebuild app-unit target (`Tests/Unit/*`, e.g.
`ZeroStateActionsTests`, `SettingsDeepLinkBundleTests`,
`LoginItemPersistenceSummaryTests`, snapshot tests) runs as a whole via
`make test-app-unit`; run a single slice with
`xcodebuild -scheme RatioThink -only-testing:RatioThinkTests/<Class> test` (see commands in
the appendices). It is a **local-tier** bundle: `make ci-pr` and the manual GitHub workflow only type-check the
app/helper targets via `make build-static`; `make build-tests` compiles the
app-unit and GUI bundles locally through `make local-pre-merge`, so app-tier
guards assert before merge rather than in the lightweight GitHub path.

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
| `S5_AppWindowShellGUITests` | settings/shell | simplified Chat/API shell vocabulary (Chats + API Endpoints nav, chat search, #422), ⌘, → Settings (4 tabs, no API tab) | mock | `test-gui-shell` |
| `S411_AppMenuUpdateGUITests` | settings/shell | app main-menu surface + New Chat removal (#411) | mock | full `test-gui` |
| `S421_SamplingPopoverGUITests` | chat/sampling | sampling popover (#421): Temperature + Top-p carry labelled tick scales; Max-tokens slider removed (now an engine-launch concern, #438) | mock (engine-free; edits local `ChatSampling`) | full `test-gui` |
| `S7_FirstLaunchWizardGUITests` | first-launch | wizard flow (register / approval-blocked) | mock (faked login-item) | `test-gui-first-launch` |
| `S7_FirstLaunchWizardPackagedArtifactGUITests` | package/install | Release `.app` first-launch persists across relaunch; launched-artifact path | packaged-signed-app | `test-gui-first-launch-package` |
| `S7_FirstLaunchWizardPackagedModelDownloadGUITests` | package/install | packaged `.app`: first-launch wizard → Settings model **download** (fixture lands file + probe) → no-model gate offers **Load** (not Download) → Load resolves the **persisted default** (no `PIE_TEST_CHAT_MODEL`) → send streams a reply that survives relaunch (#379) | packaged-app (Debug config) + #381 start→running stub + mock | `test-e2e-package` |
| `S4_HelperMenuBarGUITests` | helper/engine | menu-bar shell; fresh seed enables Resume; oversized-model rejected; Resume boots pie → Pause | app+real-engine (GGUF fixture) | `test-gui-helper` |
| `S204_ModelAcquisitionGUITests` | model discovery | Settings curated download → **verified** badge (sha256 == HF X-Linked-Etag) | real HF download (no inference) | `test-e2e-models` |
| `S204_UnverifiedBadgeGUITests` | model discovery | `.unverified` sidecar row badges after rescan; clean row does not | no engine/network (staged files) | `test-e2e-models` |
| `S218_CancelAffordancesGUITests` | model discovery | download cancel arms an inline Keep/Discard confirm; Discard hard-cancels to `.cancelled` | mock (fake downloader, `PIE_TEST_FAKE_DOWNLOADS`) | full `test-gui` |
| `S260_ChatModelMenuGUITests` | model discovery | chat model menu contains seeded default profile model | mock (static placeholder menu) | `test-gui-chat` |
| `S286_NoModelSendGateGUITests` | model load/status | send with nothing resolvable BLOCKS behind the "No model loaded" confirm (no silent load) | mock (gate fires pre-engine) | `test-gui-chat` |
| `S258_ComposerSendGUITests` | chat send/persist | send → **real pie stream** → bubble → SwiftData persist across relaunch | **app+real-engine (real Qwen3-0.6B)** | `test-e2e-chat` |
| `S426_FastThinkProfileGUITests` | chat send/persist | seeded "Fast Think" speculative-decoding profile is selectable + streams a real reply | **app+real-engine (real Qwen3-0.6B)** | `test-e2e-chat` (`run-chat-gui-e2e.sh`) |
| `S204_ChatSendGUITests` | chat send/persist | INSTRUCT model answers "Paris" → persists across relaunch | **app+real-engine (real GGUF)** | `test-e2e-full` |
| `S275_MultiTurnResumeGUITests` | chat send/persist | ordered multi-turn history sent to engine + persisted across relaunch | app+fake-engine (deterministic HTTP) | `test-gui-history` |
| `S507_StreamContinuityGUITests` | chat send/persist | switch chats mid-stream → stream survives (no cancel), row indicator, background release persists, stop affordance keeps partial; PLUS 5 chats streaming concurrently with per-row indicator count + per-chat reply persistence | app+fake-engine (holding SSE + atomic counting /control/release?n=K) | `test-gui-stream-cancel` |
| `S513_ChatRetryGUITests` | chat send/persist | earlier-turn retry → "Retry from here?" confirm (Cancel = no-op; Retry erases later conversation + regenerates from retained prefix); latest-turn retry skips confirm, no duplicate assistant turns | app+fake-engine (numbered replies) | `test-gui-chat-retry` |
| `S381_NoModelLoadDefaultGUITests` | model load/status | no-model gate's **Load default** → engine starts + serves → gate dismisses → send streams a reply | app+fake-engine (start→running stub + mock) | `test-gui-load-default` |
| `S279_LifecycleRecoveryGUITests` | lifecycle/recovery | unreachable engine → visible recoverable error + composer re-enabled | app+real-engine seam (dead loopback) | `test-gui-chat` |
| `S285_ZeroStateGUITests` | zero-state | empty-state top-alignment; Start Chat CTA opens a chat; API Endpoints section opens the single live `LocalAPIView` (#422) | mock (stops at composer; no send) | `test-gui-chat` |
| `S326_FreshInstallModelDownloadGUITests` | first-launch | fresh install (seeded profile, model absent) → no-model gate offers inline **download**, not a dead-end Load | mock (fake downloader, pre-engine) | `test-gui` |
| `S327_EngineStatusIndicatorGUITests` | model load/status | always-visible engine-status pip; popover **stays open** across 1 Hz poll ticks (`pollCount` demoted from `@Published`) | mock (no engine) | `test-gui` |
| `S360_ModelsTopAlignGUITests` | settings/shell | Settings → Models empty state stays **top-aligned**, not vertically centered (mirrors S285) | mock (isolated empty `PIE_HOME`) | `test-gui` |
| `S365_CachedModelDiscoveryGUITests` | model discovery | HF-cache-staged model surfaces as a Settings **"HF-cache" row** + in the profile picker; pure filesystem scan | staged HF cache (no engine/network) | `run-cache-discovery-gui-e2e.sh` |
| `S514_AddModelDuplicateGUITests` | model discovery | Add Model → Curated marks a staged app-managed install **"Installed"** and an HF-cache mirror **"In library"** (no Add button); a not-staged row keeps Add | staged HF cache + `PIE_HOME/models` (no engine/network) | `run-cache-discovery-gui-e2e.sh` |
| `S420_SettingsDeepLinkGUITests` | settings/shell | `ratiothink://settings` deep link opens the Settings scene (`onOpenURL` → `SettingsDeepLink.isSettings` → `openSettings()`); guards the #420 window-group wiring | mock | full `test-gui` |
| `S446_ComposerAutoGrowGUITests` | chat/composer | composer auto-grows for **soft-wrapped** lines (not just hard newlines); real SwiftUI + NSTextView layout (#446) | mock (engine-free; no send) | `test-gui-chat` |
| `S459_ProfileSwapKeepCurrentGUITests` | model discovery | explicit model pins stay pinned across profile changes; cross-model swap popover fires only when "Follow profile default model" is opted in (#459/#460/#527) | mock (DEBUG `PIE_TEST_CHAT_MODEL_PIN`; dead loopback) | `test-gui-chat` |
| `S486_ModelMenuNoResidentConfirmGUITests` | model discovery | toolbar model-menu pick with **no** resident model commits silently — no spurious "Switch model?" confirm (#486) | mock (DEBUG pin; dead loopback) | `test-gui-chat` |
| `S496_HelperOverlayRemovedGUITests` | lifecycle/recovery | window stays fully interactive while the Helper is unreachable — the full-bleed recovery overlay is gone; state reads on the bounded window banner (#496) | mock (`PIE_TEST_PIN_HELPER_HEALTH` seam) | `test-gui-chat` |
| `S511_ChatListGeometryGUITests` | settings/shell | chat-list rows stay vertically ordered + pairwise non-overlapping; each row's title/timestamp stay inside its own frame (asserts a11y FRAMES, not just existence) (#511) | mock (pinned-running + dead loopback) | `test-gui-chat-geometry` |
| `S512_ChatLifecycleGUITests` | chat send/persist | untouched "New Chat" draft is pruned on leave + launch-reconcile; a chat with a committed message survives even when send **fails** + auto-titles in the sidebar (#512) | mock (dead loopback for fail-send; isolated `/tmp` `PIE_HOME`) | `test-gui-chat-lifecycle` |
| `S515_CopyTranscriptGUITests` | chat/transcript | bubble context-menu "Copy Answer" puts the **canonical multi-section Markdown source** on `NSPasteboard` (MarkdownUI fragments block drag-select) (#515) | app+fake-engine (deterministic stream harness) | `test-gui-copy` (`run-copy-gui-e2e.sh`) |
| `S520_MultiPartContentGUITests` | chat send/persist | external OpenAI-client multi-part `content[]` succeeds non-stream + stream on the shared engine; malformed part → 400 (never dropped); GUI chat still streams after (#115) | **app+real-engine (real Qwen3-0.6B)** | `test-e2e-chat` (`run-chat-gui-e2e.sh`) |
| `S527_PinnedResidentMismatchGUITests` | model load/status | an explicit per-chat pin must not send into a running engine serving a **different** resident model; the mismatch guard fires before the user turn is persisted (#527) | mock (pinned-running + dead loopback) | full `test-gui` |
| `S572_JSONThinkProfileGUITests` | chat send/persist | seeded "JSON Think" profile is selectable in the switcher + send streams a **JSON** reply (`response_format` attached) against a real engine (#572) | **app+real-engine (real Qwen3-0.6B)** | `test-e2e-chat` (`run-chat-gui-e2e.sh`) |
| `S577_LeftPanelGUITests` | settings/shell | chat list persists as a bottom sidebar region across view selections; a row chosen from any view switches the main view back to that chat (#577) | mock (isolated `/tmp` `PIE_HOME`) | `test-gui-left-panel` |

> Reconciled against `Tests/GUIScenarioTests/` on 2026-06-13 — every suite on
> disk is listed above. The
> first-launch **packaged model-download → persisted-default chat** suite
> (`S7_FirstLaunchWizardPackagedModelDownloadGUITests`, #379) exists and closes
> the coverage gap the #373 audit filed. The chat resolves the persisted
> default through the no-model gate's **Load-default** path (the #381
> `PIE_TEST_ENGINE_START_TO_RUNNING` stub), **without** `PIE_TEST_CHAT_MODEL` —
> so the download → persisted-default → chat link is causal (the gate offers
> Load only because the downloaded default is on disk and the persisted profile
> default names it), not an injected echo. Its package is built **Debug** (not
> Release): the engine seams (`PIE_TEST_ENGINE_BASE_URL`,
> `PIE_TEST_ENGINE_START_TO_RUNNING`) are gated to DEBUG builds by
> `HelperConfig.isTestOverrideAllowed` (the #325 hardening), so a deterministic
> chat from a packaged bundle requires a Debug-configured package; the
> Release-signed artifact + wizard persistence stay covered by
> `S7_FirstLaunchWizardPackagedArtifactGUITests`.
>
> `ReadmeScreenshotsGUITests` is excluded from the catalog **by design**: it is
> tooling, not coverage — it exports README screenshots (`.keepAlways`
> attachments) and is driven by `Scripts/capture-readme-screenshots.sh`, not a
> `make test*` target.

## Modular suites by area

Run the area you touched for fast, attributable signal instead of the whole
matrix. GUI targets need a seated session + TCC; E2E targets additionally need
the real engine / model (or a deterministic harness) and fail loud with an
exact fix command when a human gate is unmet.

| Area | Focused target(s) | Aggregate |
|---|---|---|
| settings / app shell | `make test-gui-shell` (S5) | `test-gui` |
| first launch (wizard) | `make test-gui-first-launch` (S7 fast) | `test-gui` |
| package / install | `make test-gui-first-launch-package` (S7 packaged `.app` wizard/persist); `make test-e2e-package` (S7 packaged model-download → persisted-default chat, #379) | — |
| helper / engine startup | `make test-gui-helper` (S4); `make test-smoke` (S3 subprocess); `make test-e2e-engine` (real launch) | `test-gui` / `test-ssh` |
| large curated model real-engine proof | `make test-e2e-large-model` (manual/local; representative Qwen3 14B single-file GGUF, override with `PIE_TEST_E2E_REPO`/`PIE_TEST_E2E_FILE`) | — |
| engine-free chat surfaces | `make test-gui-chat` (S260/S279/S285/S286/S446/S459/S486/S496/S511/S512/S577); split-out focused targets `make test-gui-chat-geometry` (S511), `make test-gui-chat-lifecycle` (S512), `make test-gui-left-panel` (S577) | `test-gui` |
| copy transcript | `make test-gui-copy` (S515, via `run-copy-gui-e2e.sh`, deterministic stream harness) | — |
| model discovery / download | `make test-e2e-models` (S204 acquisition + unverified badge + live HF acquire); `Scripts/run-cache-discovery-gui-e2e.sh` (S365 HF-cache → Settings row + S514 duplicate-block); `make test-gui-chat` (S446/S459/S486 model-menu/profile-swap surfaces) | — |
| model load / status | engine-restart surface (#469: the `/v1/models/load` load-indicator UI was removed — a model switch is an engine restart). Unit: `EngineIndicatorStateTests` / `ChatStartGateTests` / `ModelLoadIndicatorLabelTests` / `ModelLoadPopoverConfirmTests`; restart-serves-X proven by `RealEngineLaunchE2ETests.test_realEngine_servesExplicitPick_andResumeHonorsMarker` (`test-e2e-engine`) | — |
| chat send / persist (real) | `make test-e2e-chat` (S258 send + S260 seeded menu + S426 Fast-Think + S520 multi-part + S572 JSON-Think, via `run-chat-gui-e2e.sh`); `make test-e2e-full` (S204 3-layer) | — |
| chat history / resume | `make test-gui-history` (S275 deterministic) | — |
| install-time launchd safety | `make test-install-guards` (stubbed, runs anywhere — local/manual via `ci-pr`) | `test-ssh` / `ci-pr` |
| live helper respawn | `make test-helper-respawn` (signed/registered install) | — |
| diagnostics | `make test-collect-diagnostics` (bundle self-test, local/manual via `ci-pr`) + `DiagnosticLogTests` via `test-unit` | `test-ssh` / `ci-pr` |
| notarization / release preflight | `make test-release` (notarize + preflight contract tests, local/manual via `ci-pr`) + `make test-dmg-layout` (DMG layout verifier), via `make release-gate`; `release-preflight ARTIFACT=…` for a built artifact | `ci-pr` / `release-gate` |

`make test-gui` still runs the **entire** `RatioThinkGUITests` matrix; the
focused targets are `-only-testing` slices of it. A few suites have **no**
focused target and run only in the full matrix: `S326` (fresh-install
download), `S327` (engine-status pip), `S360` (Models top-align), `S218`
(download cancel confirm), `S411` (app menu update), `S421` (sampling
popover), `S420` (settings deep link), `S527` (pinned-resident mismatch).

### Manual / visual tools (not `make` targets)

A couple of seated-console helpers are operator tools, not automated suites,
so they are intentionally not wired to a `make` target:

- `Scripts/smoke-helper-statusbar.sh` — manual visual smoke for the menu-bar
  status-item render. Drives `RationalHelper` through every dot state
  (gray/amber/green/red) via XPC so an operator can eyeball palette/SF-symbol/
  dark-mode tint that the `HelperStatusItem*` unit tests cannot assert. It is
  interactive (prompts the operator to press Enter), so it stays a hand-run
  tool, not a CI/`make` step.
- `Scripts/capture-readme-screenshots.sh` — exports README screenshots via the
  `ReadmeScreenshotsGUITests` suite (see note under the catalog above).

## Live CLI diagnostics

### KV usage model_status diagnostic

`KVUsageModelStatusLiveTests` is gated behind:

- `PIE_TEST_REAL_PIE_BIN`
- `PIE_TEST_REAL_CHATAPC_WASM`
- `PIE_TEST_REAL_CHATAPC_MANIFEST`

It launches dummy pie, queries the existing control-plane `model_status`
endpoint, parses `kv_pages_used/total`, and confirms the App parser sees the
runtime-reported totals.

Run it with:

```bash
PIE_TEST_REAL_PIE_BIN="$PWD/Vendor/pie/target/debug/pie" \
PIE_TEST_REAL_CHATAPC_WASM="$PWD/Inferlets/chat-apc/prebuilt/chat-apc.wasm" \
PIE_TEST_REAL_CHATAPC_MANIFEST="$PWD/Inferlets/chat-apc/Pie.toml" \
swift test --filter KVUsageModelStatusLiveTests
```

### GUI temp-home cleanup

A GUI suite that needs the non-sandboxed `Rational.app` to write a real
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

### Test resource leases (`hc testlease`) — seated-GUI serialization

The seated GUI seat is a single machine-local resource: two concurrent
`xcodebuild ... RatioThinkGUITests ... test` runs collide on the one console
session (focus theft, window-frame races, helper/PIE_HOME contention). The
daemon exposes `hc testlease` (`gui-seat`, capacity 1; `xcode-build`,
capacity 2) with a FIFO queue, automatic heartbeats, and crash-safe revocation
(holder death → daemon revokes by TTL; no lock file to clean up).

Every seated-GUI xcodebuild now runs through the lease wrapper, so a second
`make test-gui*` **queues** behind the first instead of colliding:

- `gui_suite_run` (all focused `test-gui-*` suites) →
  `hc testlease run gui-seat --label "gui-<area>" -- xcodebuild …`
- `test-gui` (full matrix) →
  `hc testlease run gui-seat --label "test-gui" -- xcodebuild …`
- `build-tests` build-for-testing trio →
  `hc testlease run xcode-build --label "build-tests-*" -- xcodebuild …`

The wrapper propagates the wrapped command's exit code, so the existing
`| tee $LOG | tail` + `${PIPESTATUS[0]}` capture, `GUI_TMP_HOMES` sweep, and
seated-session warning are unchanged. Inspect live state with
`hc testlease status` (holders / queue / recent).

**Daemon-side classifier gaps (follow-up, not worked around here).**
`hc testlease classify` is the daemon's source of truth for whether a command
*requires* a lease. It currently matches on the `make` target string, not the
underlying xcodebuild, so two real GUI/build paths are mis-classified as
"No daemon test lease required":

1. A **raw** `xcodebuild -scheme RatioThinkGUITests … test` (run directly, not
   via `make test-gui*`) — a genuine seated-GUI run that classify lets through
   without a `gui-seat` lease.
2. `build`/`build-tests`/`build-for-testing` invocations — classify reports no
   lease even though the `xcode-build` resource exists explicitly for "native
   build-for-testing invocations that consume build slots."

The Makefile wrappers above acquire the correct lease regardless, but anyone
invoking xcodebuild directly bypasses the seat. The fix belongs in the daemon
classifier (match the xcodebuild scheme/action, not the make-target string);
tracked under #545 as a daemon follow-up.

**Frontend Tests tab (confirmed, lives in the daemon repo).** The left-nav
"Tests" tab already exists in the Hephaestus daemon UI — not in this native
app repo (it has no `frontend/`), but in the parent daemon's
`frontend/src/components/Tests/TestsView.tsx`. It fetches
`GET /api/testleases/status` (the same holders / queue / recent surfaced by
`hc testlease status`), live-updates on `testlease.{queued,granted,released,
revoked,priority_bumped}` events, and offers operator revoke / bump-priority.
No work needed here; the wrappers above are exactly what populate it.

## Pre-PR, pre-merge, and release gates

**CI v2 policy (#456): normal merge evidence is local.** Run `make ci-pr`
locally, plus the local parity gates below for affected runtime/UI/release paths.
GitHub Actions for this ticket are **manual/on-demand verification**, not an
automatic per-commit or per-PR requirement. The lightweight checks may run
formatting/lint/static checks, compile/type checks, cheap provenance checks, and
deterministic unit/contract tests. They must not depend on a seated GUI session,
real model weights, real engine launch, network/live-HF access, release
signing/notarization credentials, Homebrew gmake installation, or broad
integration/runtime timing. The release-script contract tests stay in `make
ci-pr`: they use local throwaway ad-hoc artifacts and real macOS tools, but no
signing secrets, notarization service call, GUI session, engine, or network.
Coverage kept out of `make ci-pr` is mandatory locally through the exact targets
below.

**Unit-test timing rule:** unit tests must not rely on real wall-clock budgets
(`Task.sleep`, `asyncAfter`, timer deadlines, short timeout slack) to make a
state-machine assertion true. Components that own timers must expose an
injectable clock/sleep seam, and unit tests must advance that seam explicitly;
timeout-fired, process-died, handshake-done, and cleanup-finished should be
modeled as data/events with generation or lease tokens making stale events
no-ops. Keep real-clock coverage in an integration/local tier with generous
budgets when it is specifically valuable.

### Manual GitHub verification workflow

`.github/workflows/lint.yml` is intentionally `workflow_dispatch`-only. It does
not run automatically on `push` or `pull_request`; operators may dispatch it when
a GitHub-hosted copy of the lightweight/static evidence is useful. The workflow
has two check families:

| Job | Classification | Runs | Notes |
|---|---|---|---|
| `PR static gate` | manual-static + lightweight-runtime | `make ci-pr` | Lint, CI taxonomy guard, app-icon provenance, `build-static`, SPM unit tests, install/diagnostics contracts, sanitizer canary, release-script contracts. |
| `chat-apc inferlet provenance` | manual cheap provenance, path-conditional | `make test-stamp`; `make test-inferlets`; `make verify-inferlets` | Uses a job-level `if:` with `needs.changes.outputs.inferlets != 'false'` and `!cancelled()` so manual runs with unrelated paths skip-as-Success, while detector failures fail open by running the checks. |
| `curated-catalog-audit` workflow | separate scheduled/manual + targeted catalog PR audit | `make test-curated-hf` | Separate non-#456 lightweight gate. It still has nightly/manual coverage and a targeted PR audit for curated catalog/test changes; unrelated PRs do not hit live HF. This is the remaining automatic non-PR audit by design. |

`make build-static` is the lightweight compile/type check. It uses
`PIE_SKIP_ENGINE_BUILD=1` so the Xcode app/helper targets still compile while
skipping the Rust pie-engine build phase that caused the old long pole. Do not
use `PIE_SKIP_ENGINE_BUILD=1` for packaging, release, or runtime verification.

### Local parity commands for coverage kept out of lightweight CI

Every suite/job kept out of `make ci-pr` or the manual lightweight workflow maps to an explicit local command:

| Local-only or manually verified suite | Classification | Replacement command | When it is mandatory |
|---|---|---|---|
| Full `build every xcodebuild target` coverage (`make build` + `make build-tests`) | local-required-before-merge | `make local-pre-merge` (contains `make build-tests`); use `make build` for real bundle/runtime packaging checks | Before merge for non-doc code changes; always before release |
| `RatioThinkTests` app-unit bundle | local-required-before-merge | `make test-app-unit` or aggregate `make local-pre-merge` | App/UI/deep-link/login-item/snapshot changes |
| `CLIScenarioTests` / old CI scenario step | local-required-before-merge | `make test-scenario` or aggregate `make local-pre-merge` | Engine/helper/XPC/scenario-affecting changes |
| S3 engine subprocess smoke | local-required-before-merge | `make test-smoke` or aggregate `make local-pre-merge` | Engine subprocess/inference launch changes |
| Real pie driver contract | local-required-before-merge | `make test-real-pie-driver-contract` or aggregate `make local-pre-merge` | Pie driver/probe/engine launch contract changes; before release |
| gmake sanity-fail injection canary | local-required-before-merge for Makefile work | `make test-gmake-recipe-canary` (install Homebrew `gmake` first if needed) | Makefile recipe/logging changes; before release if recipes changed |
| Release-script contract tests | lightweight-runtime | `make test-release` through `make ci-pr` | Required local merge evidence; also part of `make release-gate` through `local-pre-merge` |
| DMG layout verifier | local-required-before-release | `make test-dmg-layout`; aggregate `make release-gate` | Before release or when packaging layout changes |
| Live-HF curated catalog existence | optional/manual + local release | `make test-curated-hf`; also scheduled/targeted `curated-catalog-audit` workflow | Before release; on curated catalog/test changes; nightly drift check |
| Inferlet wasm rebuild/restamp (`make build-inferlets`) | local-required-before-merge for inferlet changes | `make stamp-inferlets` then `make verify-inferlets-inputs`; cheap `make test-stamp test-inferlets verify-inferlets` remains available in the conditional manual workflow | When `Inferlets/**`, `Vendor/pie`, WIT/vendor pin, or prebuilt wasm changes |
| HTTP API E2E | local-required-before-merge | `make test-e2e-http` or aggregate `make local-pre-merge` | chat-apc HTTP/SSE/tool-call changes |
| APC real-engine KV reuse smoke | operator-gated local | `make test-e2e-cache-real` | APC prefix-cache save/open or App cache-directive/reuse-identity changes |
| APC real-continuation benchmark/report | selftest local; benchmark operator-gated local | `make test-apc-bench-selftest`; optionally `make bench-apc-real` for JSON+Markdown performance/memory evidence | APC benchmark/report changes or before making user-visible APC performance claims |
| GUI/XCUITest suites | local-required-before-merge for UI | `make local-gui-gate` or focused `make test-gui-*` targets | SwiftUI/layout/copy/a11y/menu/wizard/model UI changes; requires seated session + TCC |
| Real-engine/model/signing/helper E2E wrappers | local-required-before-merge/release for affected paths | `make local-e2e-gate` or focused standard targets: `make test-e2e-engine`, `make test-e2e-models`, `make test-e2e-chat`, `make test-e2e-tot`, `make test-e2e-full`, `make test-gui-history`, `make test-gui-first-launch-package`, `make test-helper-respawn`, `make test-helper-recovery` | Engine/model/download/chat persistence/install/helper lifecycle changes; before release for affected areas. The ~9 GB `make test-e2e-large-model` proof is a separate manual/operator target invoked directly, not part of `local-e2e-gate`, `release-gate`, or PR CI. |
| Packaging/notarization artifact assessment | local-required-before-release | `make release-preflight ARTIFACT=path/to/RatioThink.app` or `make release-preflight ARTIFACT=path/to/RatioThink-<arch>.dmg` after packaging/notarization | Every release candidate artifact |

### Confirm-before-PR by change type

| You changed… | Run before PR / before merge |
|---|---|
| Docs-only / comments-only | `make test-ci-v2-static-gate` if CI taxonomy docs/workflow/Makefile changed; otherwise no broad local gate required |
| Manual CI workflow / Makefile taxonomy | `make test-ci-v2-static-gate`; `make ci-pr`; optionally dispatch the manual GitHub workflow; `make test-gmake-recipe-canary` if recipe failure/logging behavior changed |
| Pure logic / models / services (no UI) | `make ci-pr` locally, then `make local-pre-merge` before merge |
| Deep link / URL scheme / login-item / menu-bar persistence copy (#420/#440) | `make local-pre-merge` (includes `make test-app-unit`; `SettingsDeepLinkBundleTests` and `LoginItemPersistenceSummaryTests` assert locally) |
| SwiftUI views / layout / copy / a11y ids | `make local-pre-merge` + `make local-gui-gate` or the affected focused GUI suite(s) |
| Chat ↔ engine send / streaming / persistence | `make local-pre-merge` + affected GUI suite + real-model proof: `make test-e2e-chat`, `Scripts/run-chat-gui-e2e.sh`, or `make test-gui-history` |
| First-launch / wizard / model download | `make local-gui-gate` focused to S7 where possible + `make test-gui-first-launch-package` + `make test-e2e-package` (#379 packaged download → Load-default chat); add `make test-e2e-models` for real model acquisition/download paths |
| Engine launch / supervisor / XPC / helper | `make local-pre-merge` + `make test-e2e-engine`; add `make test-gui-helper` / `make test-helper-respawn` / `make test-helper-recovery` for helper lifecycle or signed-install changes |
| Engine subprocess / inference contract | `make test-smoke` + `make test-real-pie-driver-contract`; add S3-real from Appendix A when launch args or inference semantics changed |
| chat-apc HTTP routes / SSE / tool calling (`Inferlets/chat-apc/src`) | `make test-e2e-http`; `make stamp-inferlets`; `make verify-inferlets-inputs`; the manual GitHub workflow can also run `make test-stamp`, `make test-inferlets`, `make verify-inferlets` |
| Curated catalog coordinates | `make test-curated-hf`; the separate `curated-catalog-audit` workflow still runs live HF for targeted catalog PRs and nightly drift checks |
| Packaging / notarization / release scripts | `make ci-pr` for release-script contract tests; `make release-gate`; after building the candidate artifact, run `make release-preflight ARTIFACT=…` |
| Broad / release / "everything" | `make release-gate` + `make local-gui-gate` + `make local-e2e-gate` on an operator machine with the documented models, TCC, signing, and live-service prerequisites |

There is **no local git hook**. Local verification is developer-owned and
mandatory for normal merge evidence and for coverage kept out of `make ci-pr`. A PR touching one
of the local-only areas should carry the relevant command/log evidence in the
PR body.

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
harness that implements `/healthz`, `/v1/models`, and
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
- XCUITest terminates/relaunches Rational.app with the same `PIE_HOME`, selects the
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
`Rational.app → create/select chat → ComposerView send → HTTPEngineClient →
real engine stream → MessageStreamWriter → persisted assistant message` path
end to end.
