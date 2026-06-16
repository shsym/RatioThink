# Rational.app dev targets. All Xcode invocations use DEVELOPER_DIR override
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

# GUI suites that need a real /tmp PIE_HOME (so the non-sandboxed Rational.app
# can write its on-disk store) cannot clean up after themselves: the
# RatioThinkGUITests-Runner is app-sandboxed (`com.apple.security.app-sandbox`)
# and its `tearDown` `removeItem` on /private/tmp is silently denied, so each
# run leaks a `<prefix>-<uuid>` home. These globs are swept by the GUI Make
# recipes below, which run in a non-sandboxed shell after xcodebuild exits
# (every test app already dead). Add a suite's prefix here if it stages a real
# /tmp home. See TEST.md "GUI temp-home cleanup".
GUI_TMP_HOMES := /tmp/pie-s285-* /tmp/pie-s286gate-* /tmp/pie-s326dl-* /tmp/pie-s326done-* /tmp/pie-s459swap-* /tmp/pie-s512-* /tmp/pie-s530-* /tmp/pie-s678-*

# Canned recipe: run a focused set of RatioThinkGUITests suites via xcodebuild
# with the seated-session warning + the standard log-capture/PIPESTATUS guard
# (see the gmake note above). Body is one backslash-continued command so the
# `set +e +o pipefail` and `${PIPESTATUS[0]}` capture live in a single shell.
# $(1) = short log label; $(2) = one or more `-only-testing:` arguments.
define gui_suite_run
@set +e +o pipefail; \
  LOG=$(LOGDIR)/test-$$(date +%Y%m%d-%H%M%S)-gui-$(1).log; \
  . Scripts/lib/sandbox-diagnostics.sh; \
  sandbox_diag_require_xcodebuild_caches "test-gui-$(1)" || exit 2; \
  seated=0; \
  if ! pgrep -x Dock >/dev/null 2>&1; then \
    echo "warning: no seated GUI session — GUI tests will XCTSkip."; \
  else seated=1; fi; \
  Scripts/purge-app-window-frames.sh || echo "warning: window-frame purge failed — saved NSWindow Frame keys may poison GUI runs"; \
  if [ -n "$$PIE_TEST_TCC_GRANTED" ]; then export TEST_RUNNER_PIE_TEST_TCC_GRANTED="$$PIE_TEST_TCC_GRANTED"; fi; \
  if [ -n "$$PIE_TEST_MODEL" ]; then export TEST_RUNNER_PIE_TEST_MODEL="$$PIE_TEST_MODEL"; fi; \
  hc testlease run gui-seat --label "gui-$(1)" -- \
  xcodebuild -project RatioThink.xcodeproj -scheme RatioThinkGUITests \
    -destination 'platform=macOS,arch=arm64' \
    -parallel-testing-enabled NO \
    $(2) \
    test 2>&1 | tee $$LOG | tail -30; \
  status=$${PIPESTATUS[0]}; \
  if [ $$status -ne 0 ]; then Scripts/gui-testmanagerd-hint.sh "$$LOG"; fi; \
  rm -rf $(GUI_TMP_HOMES) 2>/dev/null || true; \
  echo "log: $$LOG"; \
  if [ "$$status" -ne 0 ]; then sandbox_diag_report_from_log "test-gui-$(1)" "$$LOG"; fi; \
  if [ "$$status" -eq 0 ]; then \
    Scripts/assert-gui-tests-executed.sh "$(1)" "$$LOG" "$$seated" || status=$$?; \
  fi; \
  exit $$status
endef

.PHONY: help genproject build build-static build-tests clean lint verify-tot-docs ci-pr check-vendor-pin local-pre-merge local-gui-gate local-e2e-gate release-gate \
        verify-app-icon-assets test-app-icon-assets verify-docs-icons test-docs-icons test-dmg-layout test-package-dmg-staging test-collect-diagnostics test-landing-page \
        test-ci-v2-static-gate test-lint-gui-only-testing test-assert-gui-tests-executed test-xcode-chat-scaffold test-app-unit test-xcode-helper \
        test-unit test-scenario test-smoke test-tot-real-smoke-unit test-tot-real-smoke test-curated-hf test-install-guards test-sandbox-diagnostics test-readme-harness test-e2e-http \
        test-spec-smoke test-spec-bench test-spec-matrix-selftest bench-spec-matrix bench-datasets-prep bench-datasets-verify \
        test-gui-script test-gui-history test-gui-first-launch-package test-gui-stream-cancel test-gui-chat-retry test-gui-load-default test-gui test-ssh test-all \
        test-gui-shell test-gui-first-launch test-gui-helper test-gui-chat test-gui-chat-lifecycle test-gui-chat-switch test-gui-menu test-gui-engine-status test-gui-model-download test-menubar-icon-template \
        test-e2e-engine test-e2e-large-model test-e2e-models test-e2e-chat test-e2e-tot test-e2e-tot-batched test-e2e-budget-sweep bench-tot test-e2e-full test-e2e-package test-helper-respawn test-helper-recovery test-quit-structured \
        test-real-pie-driver-contract test-sanitizer-canary test-gmake-recipe-canary test-harsh-load-selftest test-apc-bench-selftest test-e2e-harsh-load test-e2e-cache-real bench-apc-real \
        engine-build engine-clean engine-bundle dmg-arm64 dmg-x86_64 \
        release-dmg-arm64 release-dmg-x86_64 release-preflight test-release \
        build-inferlets stamp-inferlets verify-inferlets verify-inferlets-inputs \
        test-stamp test-inferlets test-inferlets-gated

help: ## Show available targets
	@awk 'BEGIN {FS = ":.*##"} /^[a-zA-Z0-9_-]+:.*##/ {printf "  %-18s %s\n", $$1, $$2}' $(MAKEFILE_LIST)

genproject: ## Regenerate RatioThink.xcodeproj from project.yml
	Scripts/genproject.sh

build: genproject ## xcodebuild Debug build of Rational app + helper
	xcodebuild -project RatioThink.xcodeproj -scheme RatioThink \
	  -destination 'platform=macOS,arch=arm64' \
	  -configuration Debug ENABLE_CODE_COVERAGE=NO build

build-static: genproject ## Compile/type-check Rational app + helper without building the Rust pie engine (CI v2 local/manual gate)
	PIE_SKIP_ENGINE_BUILD=1 xcodebuild -project RatioThink.xcodeproj -scheme RatioThink \
	  -destination 'platform=macOS,arch=arm64' \
	  -configuration Debug ENABLE_CODE_COVERAGE=NO build

check-vendor-pin: ## Fail-closed guard: Vendor/pie gitlink must be reachable from its .gitmodules tracking branch (catches pin/branch drift)
	Scripts/check-vendor-pie-pin.sh

ci-pr: lint check-vendor-pin test-ci-v2-static-gate test-lint-gui-only-testing test-assert-gui-tests-executed verify-app-icon-assets test-app-icon-assets verify-docs-icons test-docs-icons test-menubar-icon-template test-landing-page build-static test-unit test-install-guards test-collect-diagnostics test-sanitizer-canary test-release ## Lightweight local/manual gate: static/lint/provenance + compile/type + deterministic unit/contracts including release scripts

local-pre-merge: ci-pr build-tests test-app-unit test-scenario test-smoke test-e2e-http test-real-pie-driver-contract test-gmake-recipe-canary test-harsh-load-selftest test-matrix-aggregator ## Mandatory local pre-merge parity for runtime/heavy checks kept out of the lightweight manual workflow

local-gui-gate: test-gui-script test-gui ## Mandatory local GUI parity gate for UI changes; requires seated session + Automation/Accessibility TCC

local-e2e-gate: test-e2e-engine test-e2e-models test-e2e-chat test-e2e-tot test-e2e-budget-sweep test-e2e-full test-gui-history test-gui-stream-cancel test-gui-chat-retry test-gui-load-default test-gui-first-launch-package test-e2e-package test-helper-respawn test-helper-recovery test-quit-structured ## Operator-gated integration/E2E parity; requires documented models, engine, signing, TCC, or live services

release-gate: local-pre-merge test-curated-hf test-dmg-layout test-package-dmg-staging ## Release readiness gate; additionally run release-preflight with ARTIFACT=<built .app|.dmg> after packaging/notarization

install-app: ## Signed install into /Applications, verified end-to-end (Helper+engine+chat). Override DEVELOPMENT_TEAM / CODE_SIGN_IDENTITY per machine.
	Scripts/install-app.sh

build-tests: genproject ## Compile every xcodebuild target + the SPM probe (review v5 F2)
	hc testlease run xcode-build --label "build-tests-app" -- \
	xcodebuild -project RatioThink.xcodeproj -scheme RatioThink \
	  -destination 'platform=macOS,arch=arm64' \
	  -configuration Debug ENABLE_CODE_COVERAGE=NO build-for-testing
	hc testlease run xcode-build --label "build-tests-gui" -- \
	xcodebuild -project RatioThink.xcodeproj -scheme RatioThinkGUITests \
	  -destination 'platform=macOS,arch=arm64' \
	  -configuration Debug ENABLE_CODE_COVERAGE=NO build-for-testing
	hc testlease run xcode-build --label "build-tests-helper" -- \
	xcodebuild -project RatioThink.xcodeproj -scheme RatioThinkHelperTests \
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
	  . Scripts/lib/sandbox-diagnostics.sh; \
	  sandbox_diag_require_xcodebuild_caches "test-xcode-chat-scaffold" || exit 2; \
	  xcodebuild -project RatioThink.xcodeproj -scheme RatioThink \
	    -destination 'platform=macOS,arch=arm64' \
	    -configuration Debug \
	    -parallel-testing-enabled NO \
	    -only-testing:RatioThinkTests/ChatScaffoldModelSelectionTests \
	    ENABLE_CODE_COVERAGE=NO PIE_SKIP_ENGINE_BUILD=1 \
	    test 2>&1 | tee $$LOG | tail -40; \
	  status=$${PIPESTATUS[0]}; \
	  echo "log: $$LOG"; \
	  if [ "$$status" -ne 0 ]; then sandbox_diag_report_from_log "test-xcode-chat-scaffold" "$$LOG"; exit "$$status"; fi; \
	  if ! grep -Eq "Test Suite 'ChatScaffoldModelSelectionTests' passed" $$LOG; then \
	    echo "FAIL: ChatScaffoldModelSelectionTests did not execute (filter may have matched zero tests)"; \
	    exit 1; \
	  fi; \
	  if ! grep -Eq 'Executed [1-9][0-9]* tests, with 0 failures' $$LOG; then \
	    echo "FAIL: expected XCTest executed-test summary for ChatScaffoldModelSelectionTests"; \
	    exit 1; \
	  fi

test-app-unit: genproject $(LOGDIR) ## App-tier unit bundle (xcodebuild RatioThinkTests): #420 deep-link/login-item guards, ChatScaffold, ZeroState, snapshots — deterministic, headless (local tier; CI only compiles it via build-tests)
	@# RatioThinkTests is the app-hosted xcodebuild unit bundle. CI does NOT
	@# run it (CI-scope policy: app-tier suites are a local responsibility);
	@# build-tests only COMPILES it there. This target runs the whole bundle
	@# so the #420 CFBundleURLTypes scheme-drop guard (SettingsDeepLinkBundleTests)
	@# and the menuBarPersistenceSummary copy guard (LoginItemPersistenceSummaryTests)
	@# actually assert. Headless (unit, not GUI) — no seated session needed.
	@set +e +o pipefail; \
	  LOG=$(LOGDIR)/test-$$(date +%Y%m%d-%H%M%S)-app-unit.log; \
	  . Scripts/lib/sandbox-diagnostics.sh; \
	  sandbox_diag_require_xcodebuild_caches "test-app-unit" || exit 2; \
	  xcodebuild -project RatioThink.xcodeproj -scheme RatioThink \
	    -destination 'platform=macOS,arch=arm64' \
	    -configuration Debug \
	    -parallel-testing-enabled NO \
	    -only-testing:RatioThinkTests \
	    ENABLE_CODE_COVERAGE=NO PIE_SKIP_ENGINE_BUILD=1 \
	    test 2>&1 | tee $$LOG | tail -40; \
	  status=$${PIPESTATUS[0]}; \
	  echo "log: $$LOG"; \
	  if [ "$$status" -ne 0 ]; then sandbox_diag_report_from_log "test-app-unit" "$$LOG"; exit "$$status"; fi; \
	  if ! grep -Eq 'Executed [1-9][0-9]* tests, with 0 failures' $$LOG; then \
	    echo "FAIL: RatioThinkTests bundle did not report an executed-test summary (zero-test guard — filter matched nothing or the bundle did not run)"; \
	    exit 1; \
	  fi

test-xcode-helper: genproject $(LOGDIR) ## Run Helper-executable unit tests (#440 deep-link delivery) with zero-test guard
	@set +e +o pipefail; \
	  LOG=$(LOGDIR)/test-$$(date +%Y%m%d-%H%M%S)-xcode-helper.log; \
	  . Scripts/lib/sandbox-diagnostics.sh; \
	  sandbox_diag_require_xcodebuild_caches "test-xcode-helper" || exit 2; \
	  xcodebuild -project RatioThink.xcodeproj -scheme RatioThinkHelperTests \
	    -destination 'platform=macOS,arch=arm64' \
	    -configuration Debug \
	    -parallel-testing-enabled NO \
	    ENABLE_CODE_COVERAGE=NO \
	    test 2>&1 | tee $$LOG | tail -40; \
	  status=$${PIPESTATUS[0]}; \
	  echo "log: $$LOG"; \
	  if [ "$$status" -ne 0 ]; then sandbox_diag_report_from_log "test-xcode-helper" "$$LOG"; exit "$$status"; fi; \
	  if ! grep -Eq "Test Suite 'RatioThinkHelperTests.xctest' passed" $$LOG; then \
	    echo "FAIL: RatioThinkHelperTests did not execute (host may have booted instead of skipping)"; \
	    exit 1; \
	  fi; \
	  if ! grep -Eq 'Executed [1-9][0-9]* tests, with 0 failures' $$LOG; then \
	    echo "FAIL: expected XCTest executed-test summary for RatioThinkHelperTests"; \
	    exit 1; \
	  fi

engine-build: ## Build pie engine binary (host arch, no triple) — used by test-smoke
	Scripts/run-engine-build.sh

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
dmg-arm64 dmg-x86_64: genproject ## Build Rational-<arch>.dmg (release; SIGN_IDENTITY/DEVELOPMENT_TEAM team-signs, else auto-detect Apple Development, else ad-hoc)
	Scripts/package-dmg.sh --arch $(ARCH)

release-dmg-arm64: ARCH := arm64
release-dmg-x86_64: ARCH := x86_64
release-dmg-arm64 release-dmg-x86_64: genproject ## Signed+notarized+stapled Rational-<arch>.dmg (needs Developer ID + notarytool creds; see Scripts/notarize.sh)
	Scripts/package-dmg.sh --arch $(ARCH) --notarize

release-preflight: ## Assess a built artifact for Gatekeeper readiness (ARTIFACT=path/to/.app|.dmg)
	@test -n "$(ARTIFACT)" || { echo "usage: make release-preflight ARTIFACT=build/dmg/Rational-arm64.dmg" >&2; exit 64; }
	Scripts/release-preflight.sh "$(ARTIFACT)"

test-release: ## Real-tool contract tests for the notarize + preflight scripts (CI-safe)
	Scripts/test-release-preflight.sh
	Scripts/test-notarize.sh

test-landing-page: ## Published GitHub Pages landing page copy/nav regression guard
	Scripts/test-landing-page.sh

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

test-inferlets: ## Run chat-apc Rust unit tests (native cargo test --lib; production gate)
	cd Inferlets/chat-apc && cargo test --lib

test-inferlets-gated: ## chat-apc Rust unit tests with the #458 exec-strategies feature (gated path)
	cd Inferlets/chat-apc && cargo test --lib --features exec-strategies

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

test-curated-hf: $(LOGDIR) ## Live-HF existence audit of the curated catalog (PIE_TEST_REAL_HF=1; network). Hard-fails on a phantom/nonexistent curated file or a silent skip (#427). Used by the scheduled curated-catalog-audit CI job + as a release/local gate.
	@set +e +o pipefail; \
	  LOG=$(LOGDIR)/test-$$(date +%Y%m%d-%H%M%S)-curated-hf.log; \
	  PIE_TEST_REAL_HF=1 Scripts/run-swift-test.sh --filter 'CuratedModelCatalogLiveHFTests' 2>&1 | tee $$LOG | tail -40; \
	  status=$${PIPESTATUS[0]}; \
	  echo "log: $$LOG"; \
	  if [ "$$status" -ne 0 ]; then \
	    echo "FAIL: curated-catalog live-HF audit failed — a curated (repo,file) does not exist on HF, is published only as split shards, or has no positive published size; see $$LOG"; \
	    exit "$$status"; \
	  fi; \
	  if grep -Eq 'Test Case .* skipped' $$LOG; then \
	    echo "FAIL: live-HF audit was SKIPPED — PIE_TEST_REAL_HF was not honored; the existence guard must not silently no-op"; \
	    exit 1; \
	  fi; \
	  if ! grep -Eq 'Executed [1-9][0-9]* tests?, with 0 failures' $$LOG; then \
	    echo "FAIL: expected 'Executed N tests, with 0 failures' (N>=1) — filter matched zero tests (renamed class? stale bundle?)"; \
	    exit 1; \
	  fi; \
	  if ! grep -q 'LIVE-HF: ' $$LOG; then \
	    echo "FAIL: no 'LIVE-HF:' success line — the audit ran but validated zero curated entries against HF"; \
	    exit 1; \
	  fi; \
	  echo "curated-hf-audit: $$(grep -c 'LIVE-HF: ' $$LOG) curated entries verified to exist on HF"

test-install-guards: ## Install-time launchd-safety regression guards (stubbed, deterministic — runs anywhere)
	Scripts/test-proc-acceptance.sh
	Scripts/test-source-closed.sh
	Scripts/test-sandbox-diagnostics.sh

test-sandbox-diagnostics: ## Regression-test sandbox/cache/IPC recovery guidance for test wrappers
	Scripts/test-sandbox-diagnostics.sh

test-ci-v2-static-gate: ## Regression-test the CI v2 manual/static gate taxonomy (#456)
	Scripts/test-ci-v2-static-gate.sh

test-sanitizer-canary: ## Env-sanitizer canary with zero-test guard (deterministic contract; CI v2 lightweight)
	@set +e +o pipefail; \
	  LOG=$$(mktemp); \
	  SPAWN_SANITIZER_CANARY=1 \
	  PIE_SANITIZER_CANARY=canary \
	  RUST_SANITIZER_CANARY=canary \
	  MTL_SANITIZER_CANARY=canary \
	  XCTestSanitizerCanary=canary \
	  XCTEST_SANITIZER_CANARY=canary \
	  __XCODE_SANITIZER_CANARY=canary \
	  OS_ACTIVITY_SANITIZER_CANARY=canary \
	  OBJC_SANITIZER_CANARY=canary \
	  NSZombieEnabled=canary \
	  PIESURVIVES_CANARY=canary \
	  MallocCanarySurvives=canary \
	  xcrun swift test --filter SpawnEnvSanitizerCanaryTests 2>&1 | tee $$LOG; \
	  status=$${PIPESTATUS[0]}; \
	  if [ "$$status" -ne 0 ]; then rm -f $$LOG; exit "$$status"; fi; \
	  if ! grep -Eq 'Executed [3-9][0-9]* tests, with 0 failures' $$LOG; then \
	    echo "FAIL: expected SpawnEnvSanitizerCanaryTests to execute N>=3 tests; filter may have matched zero tests"; \
	    rm -f $$LOG; exit 1; \
	  fi; \
	  rm -f $$LOG

test-real-pie-driver-contract: engine-bundle $(LOGDIR) ## Local heavy real-binary driver-list contract kept out of lightweight manual CI
	@set +e +o pipefail; \
	  LOG=$(LOGDIR)/test-$$(date +%Y%m%d-%H%M%S)-real-pie-driver-contract.log; \
	  PIE_TEST_REAL_PIE_BIN="$(PWD)/build/pie-engine/$(ARCH)/pie" Scripts/run-swift-test.sh --filter 'test_realPie_driverList_subcommand_exists_and_reports_portable' 2>&1 | tee $$LOG | tail -40; \
	  status=$${PIPESTATUS[0]}; \
	  echo "log: $$LOG"; \
	  if [ "$$status" -ne 0 ]; then exit "$$status"; fi; \
	  if grep -q 'Test skipped' $$LOG; then \
	    echo "FAIL: real pie driver-list contract was skipped; PIE_TEST_REAL_PIE_BIN must point at the worktree-built pie binary"; \
	    exit 1; \
	  fi; \
	  if ! grep -Eq 'Executed [1-9][0-9]* tests?, with 0 failures' $$LOG; then \
	    echo "FAIL: expected real pie driver-list contract to execute N>=1 tests"; \
	    exit 1; \
	  fi

test-gmake-recipe-canary: $(LOGDIR) ## Local gmake 4.x recipe guard kept out of lightweight manual CI (requires Homebrew gmake)
	@set -e; \
	  gmake_bin="$$(command -v gmake || true)"; \
	  if [ -z "$$gmake_bin" ] && [ -x "$$(brew --prefix 2>/dev/null)/opt/make/libexec/gnubin/make" ]; then \
	    gmake_bin="$$(brew --prefix)/opt/make/libexec/gnubin/make"; \
	  fi; \
	  if [ -z "$$gmake_bin" ]; then \
	    echo "FAIL: gmake not found; install with 'brew install make' before running make test-gmake-recipe-canary"; \
	    exit 69; \
	  fi; \
	  LOG=$(LOGDIR)/test-$$(date +%Y%m%d-%H%M%S)-gmake-canary.log; \
	  set +e; \
	  PIE_SANITY_FAIL_INJECTION=1 "$$gmake_bin" test-unit > $$LOG 2>&1; \
	  status=$$?; \
	  set -e; \
	  tail -60 $$LOG; \
	  echo "log: $$LOG"; \
	  if [ "$$status" -eq 0 ]; then \
	    echo "FAIL: expected sanity-fail injection to make gmake test-unit exit nonzero"; \
	    exit 1; \
	  fi; \
	  if ! grep -Fq 'PIE_SANITY_FAIL_INJECTION_FIRED_v1' $$LOG; then \
	    echo "FAIL: sanity-fail sentinel not found; recipe failed for an unrelated reason"; \
	    exit 1; \
	  fi; \
	  if ! grep -Eq '^log: ' $$LOG || ! grep -Eq 'Executed [0-9]+ tests' $$LOG; then \
	    echo "FAIL: gmake recipe did not preserve log line and executed-test evidence"; \
	    exit 1; \
	  fi

test-readme-harness: ## README screenshot harness canned copy branding guard
	Scripts/test-readme-screenshot-harness.sh

test-e2e-http: $(LOGDIR) ## HTTP API stress + tool-call contract E2E (dummy driver; self-bootstraps pie+wasm; needs uv + Qwen3-0.6B config/tokenizer in HF cache)
	@set +e +o pipefail; \
	  LOG=$(LOGDIR)/test-$$(date +%Y%m%d-%H%M%S)-http-e2e.log; \
	  Scripts/run-http-e2e.sh 2>&1 | tee $$LOG | tail -50; \
	  status=$${PIPESTATUS[0]}; \
	  echo "log: $$LOG"; \
	  exit $$status

test-tot-real-smoke-unit: ## Pure unit guards for the real ToT smoke scorer gates
	uv run --project Vendor/pie/client/python --with httpx python -m unittest Inferlets/chat-apc/tot_real_smoke_test.py

test-tot-real-smoke: test-tot-real-smoke-unit $(LOGDIR) ## Real-model Tree-of-Thought diversity + scorer smoke (#523; portable Metal driver + staged Qwen3-0.6B GGUF; gated, NOT CI)
	@set +e +o pipefail; \
	  LOG=$(LOGDIR)/test-$$(date +%Y%m%d-%H%M%S)-tot-real-smoke.log; \
	  Scripts/run-tot-real-smoke.sh 2>&1 | tee $$LOG | tail -60; \
	  status=$${PIPESTATUS[0]}; \
	  echo "log: $$LOG"; \
	  exit $$status

test-harsh-load-selftest: ## Engine-free guard for the harsh-load generation assertion (#467 F1): an all-400-normalizing corpus must report FAIL, not a hollow PASS. Deterministic, CI-safe.
	uv run --project Vendor/pie/client/python --with httpx \
	  python Inferlets/chat-apc/harsh_load_real.py --self-test

test-apc-bench-selftest: ## Engine-free unit guard for the APC real-continuation benchmark parser/report helpers. Deterministic, CI-safe.
	python3 Inferlets/chat-apc/apc_bench_real_test.py

test-matrix-aggregator: ## Engine-free guard for the #473 matrix verdict aggregator (review F1 fail-closed): an all-PASS cell log + non-zero swift-test exit must record FAIL, not a hollow PASS. Deterministic, CI-safe.
	Scripts/test-matrix-aggregator.sh

test-e2e-harsh-load: $(LOGDIR) ## REAL-engine harsh LOAD eval (#467): concurrent agent-replay vs portable-Metal Qwen3-0.6B. Real-weights/GPU tier, NOT CI — SKIPs cleanly without weights. SMOKE uses the committed openclaw fixture; set PIE_TEST_REPLAY_CORPUS=/path/to/capture.jsonl for the HEAVY concurrent hermes replay.
	@set +e +o pipefail; \
	  LOG=$(LOGDIR)/test-$$(date +%Y%m%d-%H%M%S)-harsh-load.log; \
	  Scripts/run-harsh-load-e2e.sh 2>&1 | tee $$LOG | tail -60; \
	  status=$${PIPESTATUS[0]}; \
	  echo "log: $$LOG"; \
	  exit $$status

test-e2e-cache-real: $(LOGDIR) ## REAL-engine APC prefix-cache smoke (#529): actual save/open KV reuse + turn-2 hit against portable-Metal Qwen3-0.6B. Operator-gated, NOT CI; needs real weights.
	@set +e +o pipefail; \
	  LOG=$(LOGDIR)/test-$$(date +%Y%m%d-%H%M%S)-cache-real.log; \
	  Scripts/run-cache-smoke-real-e2e.sh 2>&1 | tee $$LOG | tail -60; \
	  status=$${PIPESTATUS[0]}; \
	  echo "log: $$LOG"; \
	  exit $$status

bench-apc-real: $(LOGDIR) ## BENCHMARK: real-engine APC cold/miss vs warm/hit chat continuations; writes JSON+Markdown artifacts. Operator-gated, NOT CI; needs real weights.
	@set +e +o pipefail; \
	  OUT=$(LOGDIR)/apc-bench-$$(date +%Y%m%d-%H%M%S).json; \
	  LOG=$${OUT%.json}.log; \
	  uv run --project Vendor/pie/client/python --with httpx \
	    python Inferlets/chat-apc/apc_bench_real.py --output $$OUT 2>&1 | tee $$LOG | tail -80; \
	  status=$${PIPESTATUS[0]}; \
	  echo "log: $$LOG"; \
	  [ -f "$$OUT" ] && echo "artifact: $$OUT"; \
	  [ -f "$${OUT%.json}.md" ] && echo "summary: $${OUT%.json}.md"; \
	  exit $$status

test-spec-smoke: $(LOGDIR) ## Repeat Boost real-model correctness smoke (opt-in, portable Metal, needs uv + real Qwen3-0.6B weights). Short-window greedy spec==plain (64 tok; #592) + ≥1 accepted draft + forced-tool gate.
	@set +e +o pipefail; \
	  LOG=$(LOGDIR)/test-$$(date +%Y%m%d-%H%M%S)-spec-smoke.log; \
	  SMOKE_ONLY=1 Scripts/run-spec-bench.sh 2>&1 | tee $$LOG | tail -40; \
	  status=$${PIPESTATUS[0]}; \
	  echo "log: $$LOG"; \
	  exit $$status

test-spec-bench: $(LOGDIR) ## Repeat Boost vs baseline measurement harness (opt-in, portable Metal, needs uv + real weights). Latency + draft-acceptance metrics → JSON artifact. Knobs: MODEL, MAX_TOKENS, REPS, BENCH_OUT.
	@set +e +o pipefail; \
	  LOG=$(LOGDIR)/test-$$(date +%Y%m%d-%H%M%S)-spec-bench.log; \
	  Scripts/run-spec-bench.sh 2>&1 | tee $$LOG | tail -60; \
	  status=$${PIPESTATUS[0]}; \
	  echo "log: $$LOG"; \
	  exit $$status

test-spec-matrix-selftest: ## Engine-free unit guard for the spec-decode MATRIX harness helpers (#652): histogram-sum, greedy-equivalence, /no_think switch, excluded columns. Deterministic, CI-safe.
	uv run --project Vendor/pie/client/python --with httpx \
	  python Inferlets/chat-apc/spec_matrix_real_test.py

bench-datasets-prep: ## Materialize every PUBLIC pinned dataset row of the spec-decode matrix (#652) → Scripts/benchmark/datasets.lock. Needs uv + network. data/ is gitignored.
	Scripts/benchmark/prep_all.sh

bench-datasets-verify: ## Reproducibility guard (#652 no-cherrypick): re-emit every locked dataset and fail on any count/hash drift. Needs uv + network; NOT CI.
	uv run --quiet --with "datasets>=2.18" python Scripts/benchmark/prep_datasets.py verify

bench-spec-matrix: $(LOGDIR) ## Spec-decode benefit MATRIX: method × workload over PUBLIC pinned datasets (#652, extends #510). Opt-in, portable Metal, needs uv + real 7-14B weights. Knobs: MODEL, MAX_TOKENS, MAX_PROMPTS, DATASETS, MATRIX_OUT.
	@set +e +o pipefail; \
	  LOG=$(LOGDIR)/test-$$(date +%Y%m%d-%H%M%S)-spec-matrix.log; \
	  Scripts/run-spec-matrix.sh 2>&1 | tee $$LOG | tail -80; \
	  status=$${PIPESTATUS[0]}; \
	  echo "log: $$LOG"; \
	  exit $$status

test-gui-script: ## Fast preflight regressions for GUI/E2E wrapper scripts
	Scripts/test-run-stage-test-model.sh
	Scripts/test-run-chat-gui-e2e.sh
	Scripts/test-run-ticket326-resolve.sh
	Scripts/test-run-cache-smoke-real-e2e.sh
	Scripts/test-run-large-model-e2e.sh
	Scripts/test-run-resume-gui-history-e2e.sh
	Scripts/test-run-stream-cancel-gui-e2e.sh
	Scripts/test-run-chat-retry-gui-e2e.sh
	Scripts/test-run-load-default-gui-e2e.sh
	Scripts/test-run-copy-gui-e2e.sh
	Scripts/test-run-first-launch-package-e2e.sh
	Scripts/test-run-first-launch-package-model-download-e2e.sh
	Scripts/test-gui-testmanagerd-hint.sh
	Scripts/test-gui-testmanagerd-wiring.sh

test-gui-history: genproject ## Deterministic  GUI history/resume E2E — needs seated session
	Scripts/run-resume-gui-history-e2e.sh

test-gui-stream-cancel: genproject ## #507 deterministic GUI stream-continuity E2E (stream survives chat switch + row indicator) — needs seated session
	Scripts/run-stream-cancel-gui-e2e.sh

test-gui-copy: genproject ## #515 deterministic GUI copy E2E (Copy button → pasteboard == canonical multi-section Markdown) — needs seated session
	Scripts/run-copy-gui-e2e.sh

test-gui-select: genproject ## #636/GH#158 deterministic GUI drag-selection E2E (one drag spans paragraphs → Copy yields multi-paragraph span) — needs seated session
	Scripts/run-select-gui-e2e.sh

test-gui-chat-retry: genproject ## #513 deterministic GUI retry-from-a-prior-turn E2E (truncation confirm + regenerate) — needs seated session
	Scripts/run-chat-retry-gui-e2e.sh


test-gui-load-default: genproject ## #381 deterministic GUI no-model → Load-default follow-through E2E — needs seated session
	Scripts/run-load-default-gui-e2e.sh

test-gui-first-launch-package: ## Package-backed  first-launch E2E — needs seated session
	Scripts/run-first-launch-package-e2e.sh

lint: verify-tot-docs ## Static checks for helper-side-effect, GUITests -only-testing wiring (#666), and ToT docs/example invariants
	@Scripts/lint-helper-side-effects.sh
	@Scripts/lint-gui-only-testing.sh

test-lint-gui-only-testing: ## Mutation-proven self-test for the GUITests -only-testing guard (#666)
	@Scripts/test-lint-gui-only-testing.sh

test-assert-gui-tests-executed: ## Mutation-proven self-test for the gui_suite_run zero-tests-executed backstop (#680)
	@Scripts/test-assert-gui-tests-executed.sh

verify-tot-docs: ## Verify Tree-of-Thought docs/example beam-search semantics
	python3 Scripts/verify-tot-docs.py

verify-app-icon-assets: ## Verify committed app-icon source, generated PNGs, and XcodeGen wiring
	Scripts/verify-app-icon-assets.sh

test-app-icon-assets: ## Regression-test the app-icon verifier failure modes
	Scripts/test-verify-app-icon-assets.sh

verify-docs-icons: ## Verify committed docs/landing web icons match Scripts/docs-icons.sha256
	Scripts/verify-docs-icons.sh

test-docs-icons: ## Reproducibility + failure-mode tests for the docs web-icon guard
	Scripts/test-verify-docs-icons.sh

test-dmg-layout: ## Regression-test the DMG drag-install layout verifier (hdiutil + codesign, no xcodebuild)
	Scripts/test-verify-dmg-layout.sh

test-package-dmg-staging: ## Regression-test package-dmg.sh stale-staging clean (stubbed xcodebuild, no build)
	Scripts/test-package-dmg-staging.sh

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
	  . Scripts/lib/sandbox-diagnostics.sh; \
	  sandbox_diag_require_xcodebuild_caches "test-gui" || exit 2; \
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
	  hc testlease run gui-seat --label "test-gui" -- \
	  xcodebuild -project RatioThink.xcodeproj -scheme RatioThinkGUITests \
	    -destination 'platform=macOS,arch=arm64' \
	    -parallel-testing-enabled NO \
	    test 2>&1 | tee $$LOG | tail -30; \
	  status=$${PIPESTATUS[0]}; \
	  if [ $$status -ne 0 ]; then Scripts/gui-testmanagerd-hint.sh "$$LOG"; fi; \
	  rm -rf $(GUI_TMP_HOMES) 2>/dev/null || true; \
	  echo "log: $$LOG"; \
	  if [ "$$status" -ne 0 ]; then sandbox_diag_report_from_log "test-gui" "$$LOG"; fi; \
	  exit $$status

# --- Focused GUI suites by product area (xcodebuild -only-testing) ----------
# Engine-free / mock GUI suites; need a seated session + TCC. Run the area you
# touched for fast, attributable signal instead of the whole `test-gui` matrix.
test-gui-shell: genproject $(LOGDIR) ## GUI area: app window shell + Settings 4 tabs + ratiothink://settings deep link (S5/S420)
	$(call gui_suite_run,shell,-only-testing:RatioThinkGUITests/S5_AppWindowShellGUITests -only-testing:RatioThinkGUITests/S420_SettingsDeepLinkGUITests)

test-gui-first-launch: genproject $(LOGDIR) ## GUI area: first-launch wizard, fast/mock (S7)
	$(call gui_suite_run,first-launch,-only-testing:RatioThinkGUITests/S7_FirstLaunchWizardGUITests)

test-gui-helper: genproject $(LOGDIR) ## GUI area: menu-bar helper + engine startup (S4)
	$(call gui_suite_run,helper,-only-testing:RatioThinkGUITests/S4_HelperMenuBarGUITests)

test-menubar-icon-template: ## Unit-style renderer contract: status icon uses native template semantics
	@swiftc -parse-as-library Helper/MenuBarBrandIcon.swift Scripts/test-menubar-icon-template.swift -o /tmp/test-menubar-icon-template
	@/tmp/test-menubar-icon-template

render-menubar-icon: ## Render the #424 branded menu-bar icon (4 states x light/dark) to a PNG for eyeballing
	@swiftc -parse-as-library Helper/MenuBarBrandIcon.swift Scripts/render-menubar-icon.swift -o /tmp/render-menubar-icon
	@/tmp/render-menubar-icon
	@open /tmp/menubar-icon-preview.png 2>/dev/null || true

test-gui-chat: genproject $(LOGDIR) ## GUI area: engine-free chat surfaces — recovery, zero-state, send-gate, gate-non-modal, fresh-install download gate, sampling popover, pinned/resident mismatch confirm, composer auto-grow, profile-swap keep-current, model-menu no-resident confirm, unverified model mark, helper-overlay removal, chat-list geometry, chat lifecycle prune/auto-title, sidebar search (S279/S285/S286/S326/S421/S446/S459/S486/S496/S511/S512/S527/S586/S669/S678)
	$(call gui_suite_run,chat,-only-testing:RatioThinkGUITests/S279_LifecycleRecoveryGUITests -only-testing:RatioThinkGUITests/S285_ZeroStateGUITests -only-testing:RatioThinkGUITests/S286_NoModelSendGateGUITests -only-testing:RatioThinkGUITests/S326_FreshInstallModelDownloadGUITests -only-testing:RatioThinkGUITests/S421_SamplingPopoverGUITests -only-testing:RatioThinkGUITests/S446_ComposerAutoGrowGUITests -only-testing:RatioThinkGUITests/S459_ProfileSwapKeepCurrentGUITests -only-testing:RatioThinkGUITests/S486_ModelMenuNoResidentConfirmGUITests -only-testing:RatioThinkGUITests/S496_HelperOverlayRemovedGUITests -only-testing:RatioThinkGUITests/S511_ChatListGeometryGUITests -only-testing:RatioThinkGUITests/S512_ChatLifecycleGUITests -only-testing:RatioThinkGUITests/S527_PinnedResidentMismatchGUITests -only-testing:RatioThinkGUITests/S586_SidebarSearchGUITests -only-testing:RatioThinkGUITests/S669_NoModelGateNonModalGUITests -only-testing:RatioThinkGUITests/S678_UnverifiedModelMarkGUITests)

test-gui-sidebar-search: genproject $(LOGDIR) ## GUI area: #586 sidebar Search — Search section opens a detail-column panel over chat titles + bodies; find-and-open switches the main view (S586)
	$(call gui_suite_run,sidebar-search,-only-testing:RatioThinkGUITests/S586_SidebarSearchGUITests)

test-gui-chat-geometry: genproject $(LOGDIR) ## GUI area: #511 chat-list row geometry guard — rows non-overlapping, text contained (S511)
	$(call gui_suite_run,chat-geometry,-only-testing:RatioThinkGUITests/S511_ChatListGeometryGUITests)

test-gui-chat-lifecycle: genproject $(LOGDIR) ## GUI area: #512 chat lifecycle — empty-draft prune + auto-title (S512)
	$(call gui_suite_run,chat-lifecycle,-only-testing:RatioThinkGUITests/S512_ChatLifecycleGUITests)

test-gui-helper-recovery: genproject $(LOGDIR) ## GUI area: #496 helper unreachable — window stays interactive, no recovery overlay (S496)
	$(call gui_suite_run,helper-recovery,-only-testing:RatioThinkGUITests/S496_HelperOverlayRemovedGUITests)

test-gui-chat-switch: genproject $(LOGDIR) ## GUI area: #530 rapid chat-switching main-thread responsiveness guard — seeded long transcripts + stall watchdog (S530)
	$(call gui_suite_run,chat-switch,-only-testing:RatioThinkGUITests/S530_RapidChatSwitchGUITests)

test-gui-local-api: genproject $(LOGDIR) ## GUI area: #654/#663 Local API panel — seeded profile tabs + streaming toggle, same-model switch keeps engine and per-profile 'Running' badge (S654)
	$(call gui_suite_run,local-api,-only-testing:RatioThinkGUITests/S654_LocalAPIPanelGUITests)

test-gui-menu: genproject $(LOGDIR) ## GUI area: #411 App menu — "Check for Updates…" present, orphaned New Chat/New Window commands removed (S411)
	$(call gui_suite_run,menu,-only-testing:RatioThinkGUITests/S411_AppMenuUpdateGUITests)

test-gui-engine-status: genproject $(LOGDIR) ## GUI area: toolbar engine-status pip — popover survives 1 Hz poll ticks; memory-row + error-banner best-effort (S327)
	$(call gui_suite_run,engine-status,-only-testing:RatioThinkGUITests/S327_EngineStatusIndicatorGUITests)

test-gui-model-download: genproject $(LOGDIR) ## GUI area: #218 model-download cancel — inline Keep/Discard confirm via the fake downloader (S218)
	$(call gui_suite_run,model-download,-only-testing:RatioThinkGUITests/S218_CancelAffordancesGUITests)

# --- E2E wrappers by product area ------------------------------------------
# Operator-gated (seated session + TCC; real engine/model or deterministic
# harness). Each wrapper fails loud with an exact fix command when a human
# gate is unmet — these targets only make every wrapper discoverable via
# `make help` instead of rotting as undocumented orphan scripts (GUI/E2E audit).
test-e2e-engine: ## E2E area: real Helper-hosted engine launch + inference (RealEngineLaunchE2ETests)
	Scripts/run-engine-e2e.sh

test-e2e-large-model: ## E2E area: manual real Helper-hosted launch + inference for representative ~9GB curated large GGUF (not PR CI)
	Scripts/run-large-model-e2e.sh

test-e2e-models: ## E2E area: model discovery/download/verify + unverified badge (S204 acquisition/badge, live HF)
	Scripts/run-gui-e2e.sh
	Scripts/run-unverified-badge-e2e.sh
	Scripts/run-real-model-acquisition.sh

test-e2e-chat: ## E2E area: real small-model chat send streams + persists (S258, real Qwen3-0.6B)
	Scripts/run-chat-gui-e2e.sh

test-e2e-tot: ## E2E area: real-engine tree-of-thought APP path completes (#413 stall guard; depth>1, real Qwen3-0.6B-GGUF)
	Scripts/run-tot-e2e.sh

test-e2e-tot-batched: ## E2E area: real-engine BATCHED ToT (exec=phased_concurrent) tree shape/status (#458; real Qwen3-0.6B-GGUF)
	Scripts/run-tot-batched-e2e.sh

test-e2e-budget-sweep: ## E2E area: real-engine memory-budget sweep — N tracks the configured budget across the App-guardrail + pie-KV-pages knobs; harsh-low trips a captured structured load failure (#475; small model, ~5 boots, operator-gated, NOT CI)
	PIE_TEST_E2E_BUDGET_SWEEP=1 \
	PIE_TEST_E2E_FILTER="RealEngineLaunchE2ETests/test_realEngine_memoryBudgetSweep" \
	PIE_TEST_E2E_REPO="Qwen/Qwen2.5-0.5B-Instruct-GGUF" \
	PIE_TEST_E2E_FILE="qwen2.5-0.5b-instruct-q4_k_m.gguf" \
	  Scripts/run-engine-e2e.sh

test-e2e-matrix: ## E2E area: FULL real-engine matrix — 9 curated models × {chat,tree-of-thought,fast-think,ceiling} (#473/#475; ~36GB, hours, operator-gated, NOT CI). Opt in with RUN_MATRIX=1.
	@if [ "$(RUN_MATRIX)" != "1" ]; then \
	  echo "test-e2e-matrix runs the FULL real-engine matrix: 9 curated models × 4 profiles,"; \
	  echo "downloading ~36GB (incl. two ~9GB 14B models) and booting the real Metal engine per model."; \
	  echo "It is operator-gated and never runs in CI. Opt in explicitly:"; \
	  echo "    RUN_MATRIX=1 make test-e2e-matrix"; \
	  echo "Subset for iteration, e.g.:"; \
	  echo "    RUN_MATRIX=1 PIE_TEST_E2E_PROFILES=chat PIE_TEST_E2E_MATRIX_MODELS=Qwen3-0.6B make test-e2e-matrix"; \
	  exit 2; \
	fi
	PIE_TEST_E2E_MATRIX=1 Scripts/run-matrix-e2e.sh

bench-tot: ## Benchmark: ToT batched-vs-sequential strategies on real portable Metal — wall-clock + tok/s (#458)
	Scripts/run-tot-bench.sh

test-e2e-full: ## E2E area (operator-gated): 3-layer real-model proof — GUI download → engine boot → chat persist (S204). Heaviest GUI E2E (large instruct GGUF); run on-demand, not on the per-change hot path — the send+persist mechanics are already covered by test-e2e-chat (S258) and the download chain by S326FreshInstallDownloadE2ETests.
	Scripts/run-full-e2e.sh

test-e2e-package: ## E2E area: packaged first-launch → model download → chat uses persisted default (S7 packaged model-download, #379)
	Scripts/run-first-launch-package-model-download-e2e.sh

test-helper-respawn: ## Acceptance: live launchd Helper auto-respawn (needs signed/registered install)
	Scripts/verify-helper-respawn.sh

test-helper-recovery: ## Acceptance: App-side runtime helper recovery #412 (needs signed install + Rational.app running)
	Scripts/verify-helper-recovery.sh

test-quit-structured: ## Acceptance: #448 structured quit — idle engine persists + ratiothink://quit leaves nothing (needs signed install + engine running)
	Scripts/verify-structured-quit.sh

test-ssh: test-menubar-icon-template test-unit test-scenario test-smoke test-install-guards ## Everything runnable under SSH (no GUI; SPM-only, no xcodebuild app build)

test-all: test-ssh test-app-unit test-gui ## Everything (app-unit bundle + GUI; GUI tests skip if no seated session)

clean: ## Remove build outputs
	rm -rf .build RatioThink.xcodeproj DerivedData $(LOGDIR)
