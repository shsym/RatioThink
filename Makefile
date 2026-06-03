# RatioThink.app dev targets. All Xcode invocations use DEVELOPER_DIR override
# because `xcode-select -s` requires sudo. Override XCODE if Xcode lives
# elsewhere: `make XCODE=/Applications/Xcode-beta.app test-all`.
XCODE ?= /Applications/Xcode.app
export DEVELOPER_DIR := $(XCODE)/Contents/Developer

SHELL := /bin/bash
# NOTE: `.SHELLFLAGS` requires GNU Make ≥ 3.82 (2010). macOS ships
# `/usr/bin/make` 3.81 (2006), which silently ignores the directive.
# We therefore CANNOT rely on `set -e -o pipefail` to make a failing
# pipeline propagate. Instead every test recipe explicitly:
#   1. captures `${PIPESTATUS[0]}` from the pipeline (the only exit
#      status that matters — `tee` / `tail` are display sinks),
#   2. unconditionally prints the log path,
#   3. `exit $status` with the captured value.
#
# If a future gmake 4.x build is on the user's PATH AND has `set -e -o
# pipefail` active, the failing pipeline would otherwise abort the
# recipe before step 2/3, losing the log line. Each recipe opens with
# `set +e +o pipefail` to neutralize that latent path. Review v8 F1+F2.

# Timestamped log directory for test runs.
LOGDIR := test-logs
$(LOGDIR):
	@mkdir -p $(LOGDIR)

# GUI suites that need a real /tmp PIE_HOME (so the non-sandboxed RatioThink.app
# can write its on-disk store) cannot clean up after themselves: the
# RatioThinkGUITests-Runner is app-sandboxed (`com.apple.security.app-sandbox`)
# and its `tearDown` `removeItem` on /private/tmp is silently denied, so each
# run leaks a `<prefix>-<uuid>` home. These globs are swept by the GUI Make
# recipes below, which run in a non-sandboxed shell after xcodebuild exits
# (every test app already dead). Add a suite's prefix here if it stages a real
# /tmp home. See TEST.md "GUI temp-home cleanup".
GUI_TMP_HOMES := /tmp/pie-s285-* /tmp/pie-s286gate-*

# Canned recipe: run a focused set of RatioThinkGUITests suites via xcodebuild
# with the seated-session warning + the standard log-capture/PIPESTATUS guard
# (see the gmake note above). Body is one backslash-continued command so the
# `set +e +o pipefail` and `${PIPESTATUS[0]}` capture live in a single shell.
# $(1) = short log label; $(2) = one or more `-only-testing:` arguments.
define gui_suite_run
@set +e +o pipefail; \
  LOG=$(LOGDIR)/test-$$(date +%Y%m%d-%H%M%S)-gui-$(1).log; \
  if ! pgrep -x Dock >/dev/null 2>&1; then \
    echo "warning: no seated GUI session — GUI tests will XCTSkip."; \
  fi; \
  if [ -n "$$PIE_TEST_TCC_GRANTED" ]; then export TEST_RUNNER_PIE_TEST_TCC_GRANTED="$$PIE_TEST_TCC_GRANTED"; fi; \
  if [ -n "$$PIE_TEST_MODEL" ]; then export TEST_RUNNER_PIE_TEST_MODEL="$$PIE_TEST_MODEL"; fi; \
  xcodebuild -project RatioThink.xcodeproj -scheme RatioThinkGUITests \
    -destination 'platform=macOS,arch=arm64' \
    -parallel-testing-enabled NO \
    $(2) \
    test 2>&1 | tee $$LOG | tail -30; \
  status=$${PIPESTATUS[0]}; \
  rm -rf $(GUI_TMP_HOMES) 2>/dev/null || true; \
  echo "log: $$LOG"; \
  exit $$status
endef

.PHONY: help genproject build build-tests clean lint \
        verify-app-icon-assets test-app-icon-assets test-dmg-layout test-collect-diagnostics \
        test-xcode-chat-scaffold \
        test-unit test-scenario test-smoke test-install-guards test-e2e-http \
        test-gui-script test-gui-history test-gui-first-launch-package test-gui test-ssh test-all \
        test-gui-shell test-gui-first-launch test-gui-helper test-gui-chat \
        test-e2e-engine test-e2e-models test-e2e-load test-e2e-chat test-e2e-full test-helper-respawn \
        engine-build engine-clean engine-bundle dmg-arm64 dmg-x86_64 \
        release-dmg-arm64 release-dmg-x86_64 release-preflight test-release \
        build-inferlets stamp-inferlets verify-inferlets verify-inferlets-inputs \
        test-stamp test-inferlets

help: ## Show available targets
	@awk 'BEGIN {FS = ":.*##"} /^[a-zA-Z0-9_-]+:.*##/ {printf "  %-18s %s\n", $$1, $$2}' $(MAKEFILE_LIST)

genproject: ## Regenerate RatioThink.xcodeproj from project.yml
	Scripts/genproject.sh

build: genproject ## xcodebuild Debug build of RatioThink app + helper
	xcodebuild -project RatioThink.xcodeproj -scheme RatioThink \
	  -destination 'platform=macOS,arch=arm64' \
	  -configuration Debug ENABLE_CODE_COVERAGE=NO build

install-app: ## Signed install into /Applications, verified end-to-end (Helper+engine+chat). Override DEVELOPMENT_TEAM / CODE_SIGN_IDENTITY per machine.
	Scripts/install-app.sh

build-tests: genproject ## Compile every xcodebuild target + the SPM probe (review v5 F2)
	xcodebuild -project RatioThink.xcodeproj -scheme RatioThink \
	  -destination 'platform=macOS,arch=arm64' \
	  -configuration Debug ENABLE_CODE_COVERAGE=NO build-for-testing
	xcodebuild -project RatioThink.xcodeproj -scheme RatioThinkGUITests \
	  -destination 'platform=macOS,arch=arm64' \
	  -configuration Debug ENABLE_CODE_COVERAGE=NO build-for-testing
	@# pie-resolve-probe is an SPM executable target — xcodebuild
	@# doesn't build it. Without this step, ResolveProbe.find() throws
	@# XCTSkip and the F2/F3/F9 regression tests silently vanish under
	@# the xcodebuild test entry point. Review v5 F2.
	xcrun swift build --product pie-resolve-probe

test-xcode-chat-scaffold: genproject $(LOGDIR) ## Run Xcode-only ChatScaffold unit regressions with zero-test guard
	@set +e +o pipefail; \
	  LOG=$(LOGDIR)/test-$$(date +%Y%m%d-%H%M%S)-xcode-chat-scaffold.log; \
	  xcodebuild -project RatioThink.xcodeproj -scheme RatioThink \
	    -destination 'platform=macOS,arch=arm64' \
	    -configuration Debug \
	    -parallel-testing-enabled NO \
	    -only-testing:RatioThinkTests/ChatScaffoldModelSelectionTests \
	    ENABLE_CODE_COVERAGE=NO \
	    test 2>&1 | tee $$LOG | tail -40; \
	  status=$${PIPESTATUS[0]}; \
	  echo "log: $$LOG"; \
	  if [ "$$status" -ne 0 ]; then exit "$$status"; fi; \
	  if ! grep -Eq "Test Suite 'ChatScaffoldModelSelectionTests' passed" $$LOG; then \
	    echo "FAIL: ChatScaffoldModelSelectionTests did not execute (filter may have matched zero tests)"; \
	    exit 1; \
	  fi; \
	  if ! grep -Eq 'Executed [1-9][0-9]* tests, with 0 failures' $$LOG; then \
	    echo "FAIL: expected XCTest executed-test summary for ChatScaffoldModelSelectionTests"; \
	    exit 1; \
	  fi

engine-build: ## Build pie engine binary (host arch, no triple) — used by test-smoke
	cd Vendor/pie && PIE_PORTABLE_METAL=1 cargo build -p pie-server --release

# Default ARCH to the host's native arch so Intel-host devs do not get
# a silent arm64 cross-build (review v1 F7). Override with
# `make engine-bundle ARCH=x86_64` etc.
HOST_ARCH := $(shell uname -m)
ARCH ?= $(HOST_ARCH)

engine-bundle: ## Build pie engine for given arch and stage+codesign (ARCH=arm64|x86_64, default: host)
	Scripts/build-pie-engine.sh --arch $(ARCH)

engine-clean: ## Remove pie engine build artifacts
	cd Vendor/pie && cargo clean
	rm -rf build/pie-engine

# Optional local signing for the non-notarized DMG: set SIGN_IDENTITY (cert
# name or SHA-1) and/or DEVELOPMENT_TEAM to team-sign with a local Apple
# Development identity (needed for SMAppService to register the Helper). Unset,
# the build auto-detects an Apple Development identity in the keychain, else
# falls back to ad-hoc / unsigned. Export so both `VAR=… make dmg-arm64` and
# `make dmg-arm64 VAR=…` reach package-dmg.sh.
export SIGN_IDENTITY DEVELOPMENT_TEAM

dmg-arm64: ARCH := arm64
dmg-x86_64: ARCH := x86_64
dmg-arm64 dmg-x86_64: genproject ## Build RatioThink-<arch>.dmg (release; SIGN_IDENTITY/DEVELOPMENT_TEAM team-signs, else auto-detect Apple Development, else ad-hoc)
	Scripts/package-dmg.sh --arch $(ARCH)

release-dmg-arm64: ARCH := arm64
release-dmg-x86_64: ARCH := x86_64
release-dmg-arm64 release-dmg-x86_64: genproject ## Signed+notarized+stapled RatioThink-<arch>.dmg (needs Developer ID + notarytool creds; see Scripts/notarize.sh)
	Scripts/package-dmg.sh --arch $(ARCH) --notarize

release-preflight: ## Assess a built artifact for Gatekeeper readiness (ARTIFACT=path/to/.app|.dmg)
	@test -n "$(ARTIFACT)" || { echo "usage: make release-preflight ARTIFACT=build/dmg/RatioThink-arm64.dmg" >&2; exit 64; }
	Scripts/release-preflight.sh "$(ARTIFACT)"

test-release: ## Real-tool contract tests for the notarize + preflight scripts (CI-safe)
	Scripts/test-release-preflight.sh
	Scripts/test-notarize.sh

build-inferlets: ## Build chat-apc inferlet wasm (wasm32-wasip2) into Inferlets/chat-apc/prebuilt/
	Scripts/stamp-chat-apc.sh build

stamp-inferlets: ## Build chat-apc wasm + regenerate prebuilt/chat-apc.wasm.stamp
	Scripts/stamp-chat-apc.sh write

verify-inferlets: ## Verify committed chat-apc prebuilt + stamp against the tree (full)
	Scripts/stamp-chat-apc.sh verify

verify-inferlets-inputs: ## Verify only the input-side stamp fields (post-build CI gate)
	Scripts/stamp-chat-apc.sh verify-inputs

test-stamp: ## Unit tests for Inferlets/chat-apc/_stamp.py (review v1 follow-ups)
	python3 Inferlets/chat-apc/_stamp_test.py

test-inferlets: ## Run chat-apc Rust unit tests (native cargo test --lib)
	cd Inferlets/chat-apc && cargo test --lib

test-unit: $(LOGDIR) ## Unit tests (XCTest) via xcrun swift test
	@set +e +o pipefail; \
	  LOG=$(LOGDIR)/test-$$(date +%Y%m%d-%H%M%S)-unit.log; \
	  Scripts/run-swift-test.sh --filter 'RatioThinkCoreTests' 2>&1 | tee $$LOG | tail -20; \
	  status=$${PIPESTATUS[0]}; \
	  if [ "$$status" -ne 0 ]; then \
	    echo "=== failing tests (grepped from full log; the tail above truncates parallel output) ==="; \
	    grep -nE "Test Case .+ failed|: error:|XCTAssert|recorded an issue|Fatal error|Restarting after|crashed|failed \(" $$LOG | grep -v "warning:" | tail -100; \
	  fi; \
	  echo "log: $$LOG"; \
	  exit $$status

test-scenario: $(LOGDIR) ## Headless scenarios (S1, S2, S3) via CLIRunner
	@set +e +o pipefail; \
	  LOG=$(LOGDIR)/test-$$(date +%Y%m%d-%H%M%S)-scenario.log; \
	  Scripts/run-swift-test.sh --filter 'CLIScenarioTests' 2>&1 | tee $$LOG | tail -30; \
	  status=$${PIPESTATUS[0]}; \
	  if [ "$$status" -ne 0 ]; then \
	    echo "=== failing tests (grepped from full log; the tail above truncates parallel output) ==="; \
	    grep -nE "Test Case .+ failed|: error:|XCTAssert|recorded an issue|Fatal error|Restarting after|crashed|failed \(" $$LOG | grep -v "warning:" | tail -100; \
	  fi; \
	  echo "log: $$LOG"; \
	  exit $$status

test-smoke: engine-build $(LOGDIR) ## Engine subprocess smoke (depends on built pie)
	@set +e +o pipefail; \
	  LOG=$(LOGDIR)/test-$$(date +%Y%m%d-%H%M%S)-smoke.log; \
	  Scripts/run-swift-test.sh --filter 'S3_EngineSubprocessCLITests' 2>&1 | tee $$LOG | tail -20; \
	  status=$${PIPESTATUS[0]}; \
	  echo "log: $$LOG"; \
	  exit $$status

test-install-guards: ## Install-time launchd-safety regression guards (stubbed, deterministic — runs anywhere)
	Scripts/test-proc-acceptance.sh
	Scripts/test-source-closed.sh

test-e2e-http: $(LOGDIR) ## HTTP API stress + tool-call contract E2E (dummy driver; self-bootstraps pie+wasm; needs uv + Qwen3-0.6B config/tokenizer in HF cache)
	@set +e +o pipefail; \
	  LOG=$(LOGDIR)/test-$$(date +%Y%m%d-%H%M%S)-http-e2e.log; \
	  Scripts/run-http-e2e.sh 2>&1 | tee $$LOG | tail -50; \
	  status=$${PIPESTATUS[0]}; \
	  echo "log: $$LOG"; \
	  exit $$status

test-gui-script: ## Fast preflight regressions for GUI E2E wrappers
	Scripts/test-run-stage-test-model.sh
	Scripts/test-run-chat-gui-e2e.sh
	Scripts/test-run-resume-gui-history-e2e.sh
	Scripts/test-run-first-launch-package-e2e.sh

test-gui-history: genproject ## Deterministic  GUI history/resume E2E — needs seated session
	Scripts/run-resume-gui-history-e2e.sh

test-gui-first-launch-package: ## Package-backed  first-launch E2E — needs seated session
	Scripts/run-first-launch-package-e2e.sh

lint: ## Static checks for  helper-side-effect invariants
	@Scripts/lint-helper-side-effects.sh

verify-app-icon-assets: ## Verify committed app-icon source, generated PNGs, and XcodeGen wiring
	Scripts/verify-app-icon-assets.sh

test-app-icon-assets: ## Regression-test the app-icon verifier failure modes
	Scripts/test-verify-app-icon-assets.sh

test-dmg-layout: ## Regression-test the DMG drag-install layout verifier (hdiutil + codesign, no xcodebuild)
	Scripts/test-verify-dmg-layout.sh

test-collect-diagnostics: $(LOGDIR) ## Real-script self-test for Scripts/collect-diagnostics.sh (CI-safe via override env)
	@set +e +o pipefail; \
	  LOG=$(LOGDIR)/test-$$(date +%Y%m%d-%H%M%S)-collect-diag.log; \
	  Scripts/test-collect-diagnostics.sh 2>&1 | tee $$LOG | tail -30; \
	  status=$${PIPESTATUS[0]}; \
	  echo "log: $$LOG"; \
	  exit $$status

test-gui: genproject $(LOGDIR) ## GUI scenarios — full RatioThinkGUITests matrix (see test-gui-* for focused areas); needs seated session
	@# Provision the model fixture (symlink from HF cache) so the
	@# model-dependent helper-menu test resolves its seeded profile.
	@# Guide-and-continue: if the model is absent the tests XCTSkip with
	@# the same instruction this prints, so the suite never hard-fails on it.
	@Scripts/stage-test-model.sh || echo "warning: model fixture unavailable — model-dependent GUI tests will XCTSkip; see guidance above."
	@set +e +o pipefail; \
	  LOG=$(LOGDIR)/test-$$(date +%Y%m%d-%H%M%S)-gui.log; \
	  if ! pgrep -x Dock >/dev/null 2>&1; then \
	    echo "warning: no seated GUI session — GUI tests will XCTSkip."; \
	  fi; \
	  if [ -z "$$SSH_CONNECTION" ]; then :; else \
	    echo "warning: running under SSH ($$SSH_CONNECTION)."; \
	    echo "         XCUITest typically hangs because the test runner has no"; \
	    echo "         Accessibility/AppleEvents TCC permission for this shell."; \
	    echo "         Run \`make test-gui\` from a Terminal inside the seated"; \
	    echo "         console session (or Screen Sharing) the first time, so"; \
	    echo "         macOS can prompt for permission. Subsequent SSH runs may"; \
	    echo "         then work if the same shell binary holds the grant."; \
	  fi; \
	  xcodebuild -project RatioThink.xcodeproj -scheme RatioThinkGUITests \
	    -destination 'platform=macOS,arch=arm64' \
	    -parallel-testing-enabled NO \
	    test 2>&1 | tee $$LOG | tail -30; \
	  status=$${PIPESTATUS[0]}; \
	  rm -rf $(GUI_TMP_HOMES) 2>/dev/null || true; \
	  echo "log: $$LOG"; \
	  exit $$status

# --- Focused GUI suites by product area (xcodebuild -only-testing) ----------
# Engine-free / mock GUI suites; need a seated session + TCC. Run the area you
# touched for fast, attributable signal instead of the whole `test-gui` matrix.
test-gui-shell: genproject $(LOGDIR) ## GUI area: app window shell + Settings 5 tabs (S5)
	$(call gui_suite_run,shell,-only-testing:RatioThinkGUITests/S5_AppWindowShellGUITests)

test-gui-first-launch: genproject $(LOGDIR) ## GUI area: first-launch wizard, fast/mock (S7)
	$(call gui_suite_run,first-launch,-only-testing:RatioThinkGUITests/S7_FirstLaunchWizardGUITests)

test-gui-helper: genproject $(LOGDIR) ## GUI area: menu-bar helper + engine startup (S4)
	$(call gui_suite_run,helper,-only-testing:RatioThinkGUITests/S4_HelperMenuBarGUITests)

test-gui-chat: genproject $(LOGDIR) ## GUI area: engine-free chat surfaces — model menu, recovery, zero-state, send-gate (S260/S279/S285/S286)
	$(call gui_suite_run,chat,-only-testing:RatioThinkGUITests/S260_ChatModelMenuGUITests -only-testing:RatioThinkGUITests/S279_LifecycleRecoveryGUITests -only-testing:RatioThinkGUITests/S285_ZeroStateGUITests -only-testing:RatioThinkGUITests/S286_NoModelSendGateGUITests)

# --- E2E wrappers by product area ------------------------------------------
# Operator-gated (seated session + TCC; real engine/model or deterministic
# harness). Each wrapper fails loud with an exact fix command when a human
# gate is unmet — these targets only make every wrapper discoverable via
# `make help` instead of rotting as undocumented orphan scripts (GUI/E2E audit).
test-e2e-engine: ## E2E area: real Helper-hosted engine launch + inference (RealEngineLaunchE2ETests)
	Scripts/run-engine-e2e.sh

test-e2e-models: ## E2E area: model discovery/download/verify + unverified badge (S204 acquisition/badge, live HF)
	Scripts/run-gui-e2e.sh
	Scripts/run-unverified-badge-e2e.sh
	Scripts/run-real-model-acquisition.sh

test-e2e-load: ## E2E area: model-load indicator path-1 loading→ready + cancel + #396 honest popover (S302, mock harness)
	Scripts/run-gui-load-indicator-e2e.sh

test-e2e-396: ## E2E area: #396 failed-load Retry recovery + Dismiss-clears (S396, fail-first mock harness)
	Scripts/run-gui-396-retry-e2e.sh

test-e2e-chat: ## E2E area: real small-model chat send streams + persists (S258, real Qwen3-0.6B)
	Scripts/run-chat-gui-e2e.sh

test-e2e-full: ## E2E area: 3-layer real-model proof — GUI download → engine boot → chat persist (S204)
	Scripts/run-full-e2e.sh

test-helper-respawn: ## Acceptance: live launchd Helper auto-respawn (needs signed/registered install)
	Scripts/verify-helper-respawn.sh

test-helper-recovery: ## Acceptance: App-side runtime helper recovery #412 (needs signed install + RatioThink.app running)
	Scripts/verify-helper-recovery.sh

test-ssh: test-unit test-scenario test-smoke test-install-guards ## Everything runnable under SSH (no GUI)

test-all: test-ssh test-gui ## Everything (GUI tests skip if no seated session)

clean: ## Remove build outputs
	rm -rf .build RatioThink.xcodeproj DerivedData $(LOGDIR)
