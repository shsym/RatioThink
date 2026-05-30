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

.PHONY: help genproject build build-tests clean lint \
        verify-app-icon-assets test-app-icon-assets \
        test-xcode-chat-scaffold \
        test-unit test-scenario test-smoke test-gui-script test-gui-history test-gui-first-launch-package test-gui test-ssh test-all \
        engine-build engine-clean engine-bundle dmg-arm64 dmg-x86_64 \
        release-dmg-arm64 release-dmg-x86_64 release-preflight test-release \
        build-inferlets stamp-inferlets verify-inferlets verify-inferlets-inputs \
        test-stamp

help: ## Show available targets
	@awk 'BEGIN {FS = ":.*##"} /^[a-zA-Z_-]+:.*##/ {printf "  %-18s %s\n", $$1, $$2}' $(MAKEFILE_LIST)

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

dmg-arm64: ARCH := arm64
dmg-x86_64: ARCH := x86_64
dmg-arm64 dmg-x86_64: genproject ## Build arch-specific RatioThink-<arch>.dmg (release)
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

test-unit: $(LOGDIR) ## Unit tests (XCTest) via xcrun swift test
	@set +e +o pipefail; \
	  LOG=$(LOGDIR)/test-$$(date +%Y%m%d-%H%M%S)-unit.log; \
	  Scripts/run-swift-test.sh --filter 'RatioThinkCoreTests' 2>&1 | tee $$LOG | tail -20; \
	  status=$${PIPESTATUS[0]}; \
	  echo "log: $$LOG"; \
	  exit $$status

test-scenario: $(LOGDIR) ## Headless scenarios (S1, S2, S3) via CLIRunner
	@set +e +o pipefail; \
	  LOG=$(LOGDIR)/test-$$(date +%Y%m%d-%H%M%S)-scenario.log; \
	  Scripts/run-swift-test.sh --filter 'CLIScenarioTests' 2>&1 | tee $$LOG | tail -30; \
	  status=$${PIPESTATUS[0]}; \
	  echo "log: $$LOG"; \
	  exit $$status

test-smoke: engine-build $(LOGDIR) ## Engine subprocess smoke (depends on built pie)
	@set +e +o pipefail; \
	  LOG=$(LOGDIR)/test-$$(date +%Y%m%d-%H%M%S)-smoke.log; \
	  Scripts/run-swift-test.sh --filter 'S3_EngineSubprocessCLITests' 2>&1 | tee $$LOG | tail -20; \
	  status=$${PIPESTATUS[0]}; \
	  echo "log: $$LOG"; \
	  exit $$status

test-gui-script: ## Fast preflight regressions for GUI E2E wrappers
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

test-gui: genproject $(LOGDIR) ## GUI scenarios (S4, S5) via XCUITest — needs seated session
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
	  echo "log: $$LOG"; \
	  exit $$status

test-ssh: test-unit test-scenario test-smoke ## Everything runnable under SSH (no GUI)

test-all: test-ssh test-gui ## Everything (GUI tests skip if no seated session)

clean: ## Remove build outputs
	rm -rf .build RatioThink.xcodeproj DerivedData $(LOGDIR)
