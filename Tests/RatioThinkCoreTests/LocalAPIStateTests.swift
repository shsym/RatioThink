import XCTest
@testable import RatioThinkCore

/// Pure-reducer coverage for the "Local API" surface (#422): every engine
/// status → view-state mapping, the on/off enable rules, the curl snippet
/// wire shape, and a drift guard pinning the read-only security posture to
/// the real `pie serve` config the app launches with.
final class LocalAPIStateTests: XCTestCase {

  // MARK: - phase mapping

  func test_running_isServing_with_live_port() {
    let s = LocalAPIState.make(status: .running(EngineSessionSnapshot(port: 8123, profileID: "chat")),
                               hasActiveProfile: true)
    XCTAssertTrue(s.isServing)
    XCTAssertEqual(s.port, 8123)
    XCTAssertTrue(s.toggleOn)
    XCTAssertTrue(s.toggleEnabled)
    XCTAssertEqual(s.statusLabel, "Running")
    XCTAssertNil(s.detail)
  }

  func test_starting_is_on_but_disabled_and_not_serving() {
    let s = LocalAPIState.make(status: .starting, hasActiveProfile: true)
    XCTAssertFalse(s.isServing)
    XCTAssertNil(s.port)
    XCTAssertTrue(s.toggleOn, "show 'on' while coming up so the control doesn't flicker")
    XCTAssertFalse(s.toggleEnabled, "no flipping mid-transition")
    XCTAssertFalse(s.externalAccessToggleEnabled,
                   "security posture changes must not persist while an external-bound daemon may still be starting")
    XCTAssertFalse(s.profileSelectionEnabled,
                   "profile picker must be disabled during in-flight restarts so a selection is not silently lost")
    XCTAssertEqual(s.statusLabel, "Starting…")
  }

  func test_stopping_is_off_and_disabled() {
    let s = LocalAPIState.make(status: .stopping, hasActiveProfile: true)
    XCTAssertFalse(s.toggleOn)
    XCTAssertFalse(s.toggleEnabled)
    XCTAssertFalse(s.externalAccessToggleEnabled,
                   "security posture changes must not persist while an exposed daemon may still be stopping")
    XCTAssertFalse(s.profileSelectionEnabled,
                   "profile picker must be disabled during in-flight restarts so a selection is not silently lost")
    XCTAssertEqual(s.statusLabel, "Stopping…")
  }

  func test_stopped_with_profile_can_be_turned_on() {
    let s = LocalAPIState.make(status: .stopped, hasActiveProfile: true)
    XCTAssertFalse(s.isServing)
    XCTAssertFalse(s.toggleOn)
    XCTAssertTrue(s.toggleEnabled, "a selected model means we can start the engine")
    XCTAssertTrue(s.externalAccessToggleEnabled)
    XCTAssertTrue(s.profileSelectionEnabled)
    XCTAssertEqual(s.statusLabel, "Off")
    XCTAssertEqual(s.detail, "Turn on to start the engine and serve requests on 127.0.0.1.")
  }

  func test_bind_modes_carry_explicit_daemon_hosts() {
    XCTAssertEqual(EngineHTTPBindMode.loopback.daemonHost, "127.0.0.1")
    XCTAssertEqual(EngineHTTPBindMode.external.daemonHost, "0.0.0.0")
    XCTAssertEqual(EngineHTTPBindMode.loopback.baseURLHost, "127.0.0.1")
    XCTAssertEqual(EngineHTTPBindMode.external.baseURLHost, "0.0.0.0")
  }

  func test_stopped_without_profile_is_disabled_with_guidance() {
    let s = LocalAPIState.make(status: .stopped, hasActiveProfile: false)
    XCTAssertFalse(s.toggleEnabled, "nothing to serve → can't turn on")
    XCTAssertEqual(s.detail, "Choose a profile in the chat toolbar to enable the local API.")
  }

  // MARK: - served model id (exact-id guidance must be authoritative)

  /// The reducer takes no profile-model input at all, so the served id can
  /// only ever come from the running snapshot — a profile fallback is
  /// impossible by construction. This pins the snapshot pass-through for a
  /// model that intentionally differs from any plausible profile default.
  func test_running_servedModelID_comes_from_snapshot_only() {
    let s = LocalAPIState.make(
      status: .running(EngineSessionSnapshot(port: 8123, profileID: "chat",
                                             servedModelID: "org/override-model.gguf")),
      hasActiveProfile: true)
    XCTAssertEqual(s.servedModelID, "org/override-model.gguf")
  }

  /// A legacy snapshot carries `servedModelID = ""` — the exact-id row and
  /// curl example must fail closed (hidden), never guess a substitute.
  func test_running_empty_snapshot_servedModelID_fails_closed_to_nil() {
    let s = LocalAPIState.make(
      status: .running(EngineSessionSnapshot(port: 8123, profileID: "chat")),
      hasActiveProfile: true)
    XCTAssertNil(s.servedModelID)
  }

  func test_non_running_states_have_no_servedModelID() {
    for status: EngineStatus in [.starting, .stopping, .stopped,
                                 .failed(code: .modelMissing, message: "x")] {
      XCTAssertNil(LocalAPIState.make(status: status, hasActiveProfile: true).servedModelID)
    }
  }

  // MARK: - failure mapping

  func test_failed_recoverable_with_profile_allows_retry() {
    let s = LocalAPIState.make(status: .failed(code: .modelMissing, message: "model not found"),
                               hasActiveProfile: true)
    XCTAssertEqual(s.statusLabel, "Engine failed")
    XCTAssertTrue(s.toggleEnabled, "modelMissing invites a resume retry")
    // #477: the raw status message is a diagnostic — the card shows the
    // taxonomy's curated copy.
    XCTAssertEqual(s.detail,
                   "The selected model isn’t downloaded. Download it in Settings → Models, or pick another model.")
  }

  func test_failed_memoryRisk_is_not_retryable() {
    let s = LocalAPIState.make(status: .failed(code: .memoryRisk, message: "too big"),
                               hasActiveProfile: true)
    XCTAssertFalse(s.toggleEnabled, "memoryRisk re-rejects on a plain start")
    XCTAssertEqual(s.detail,
                   "This model exceeds this Mac’s safe memory limit. Pick a smaller model.")
  }

  func test_failed_modelUnsupported_is_not_retryable() {
    let s = LocalAPIState.make(status: .failed(code: .modelUnsupported, message: "unsupported format"),
                               hasActiveProfile: true)
    XCTAssertFalse(s.toggleEnabled, "modelUnsupported would retry the same unloadable artifact")
    XCTAssertEqual(
      s.detail,
      "The selected model is unsupported or not loadable. Choose a curated model, remove or fix the cached repo, or install a supported artifact."
    )
  }

  func test_failed_without_profile_is_never_retryable() {
    let s = LocalAPIState.make(status: .failed(code: .spawnFailed, message: "boom"),
                               hasActiveProfile: false)
    XCTAssertFalse(s.toggleEnabled)
  }

  func test_failureReason_is_curated_taxonomy_copy() {
    // #477: same copy whether the raw diagnostic is present or empty —
    // the message never feeds primary copy.
    for raw in ["", "memory risk: model is 9.0 GB at /Users/x/big.gguf"] {
      XCTAssertEqual(
        LocalAPIState.failureReason(code: .memoryRisk, message: raw),
        "This model exceeds this Mac’s safe memory limit. Pick a smaller model.")
    }
    XCTAssertEqual(
      LocalAPIState.failureReason(code: .engineGone, message: ""),
      "The engine process exited. Restart the engine to continue.")
    XCTAssertEqual(
      LocalAPIState.failureReason(code: .spawnFailed, message: ""),
      "The engine failed to start. Try restarting it.")
  }

  // MARK: - curl snippet

  func test_curl_snippet_uses_served_model_id_and_no_auth_header() {
    let curl = LocalAPICurl.chatCompletions(
      baseURL: "http://127.0.0.1:8123",
      model: "Qwen/Qwen3-0.6B")
    XCTAssertTrue(curl.contains("http://127.0.0.1:8123/v1/chat/completions"))
    XCTAssertTrue(curl.contains("\"model\": \"Qwen/Qwen3-0.6B\""),
                  "request model MUST equal the served id /v1/models advertises")
    XCTAssertTrue(curl.contains("\"stream\": true"))
    XCTAssertFalse(curl.contains("Authorization"),
                   "engine runs with [auth] enabled=false — no bearer header")
  }

  // MARK: - routes

  func test_clientFacing_routes_match_chat_apc_contract() {
    let ids = LocalAPIRoute.clientFacing.map(\.id)
    XCTAssertEqual(ids, [
      "POST /v1/chat/completions",
      "GET /v1/models",
      "GET /healthz",
    ])
  }

  // MARK: - posture drift guard (binds UI claims to the real launch config)

  func test_loopback_posture_matches_default_daemon_launch_contract() {
    // The view's default "Security" rows claim loopback-only + no-auth.
    // Those claims are only honest if the app actually launches the daemon
    // that way. Pin them to the typed launch default and the config preamble
    // so a future drift can't silently make the UI lie.
    let body = PieControlLauncher.renderConfigBody(modelConfig: .dummy)
    let posture = EngineHTTPPosture.make(bindMode: .loopback)

    XCTAssertEqual(posture.loopbackOnly, true)
    XCTAssertEqual(PieControlLauncher.LaunchSpec.defaultDaemonBindHost, .loopback)
    XCTAssertTrue(body.contains("host = \"127.0.0.1\""),
                  "pie control websocket remains loopback-only; the OpenAI daemon host is configured separately")

    XCTAssertEqual(posture.authenticated, false)
    XCTAssertTrue(body.contains("[auth]\nenabled = false"),
                  "EngineHTTPPosture.authenticated=false claims no auth — config must disable it")
  }

  func test_external_posture_warns_about_lan_exposure() {
    let posture = EngineHTTPPosture.make(bindMode: .external)

    XCTAssertFalse(posture.loopbackOnly)
    XCTAssertEqual(posture.networkSummary, "External access enabled (0.0.0.0). Other devices on reachable networks can connect to this Mac’s local API port.")
    XCTAssertEqual(posture.warningTitle, "Network exposure risk")
    XCTAssertEqual(posture.warningDetail?.contains("unauthenticated"), true)
  }

  func test_bind_mode_change_does_not_clear_external_preference_when_stop_fails() async {
    var preferenceEnabled = true
    var stopCalls = 0
    var startCalls = 0

    do {
      try await LocalAPIBindModeChange.apply(
        enabled: false,
        phase: .serving(port: 8123),
        profileID: "chat",
        setPreference: { preferenceEnabled = $0 },
        stopEngine: {
          stopCalls += 1
          throw EngineError(code: .killRejected, message: "still running")
        },
        startEngine: { _ in startCalls += 1 }
      )
      XCTFail("disabling external access must throw when the exposed daemon could not be stopped")
    } catch let error as EngineError {
      XCTAssertEqual(error.code, .killRejected)
    } catch {
      XCTFail("unexpected error: \(error)")
    }

    XCTAssertTrue(preferenceEnabled,
                  "preference/warning must stay external while a 0.0.0.0 daemon may still be running")
    XCTAssertEqual(stopCalls, 1)
    XCTAssertEqual(startCalls, 0)
  }

  func test_bind_mode_change_commits_preference_after_successful_restart() async throws {
    var preferenceEnabled = false
    var requestedStarts: [EngineHTTPBindMode] = []

    try await LocalAPIBindModeChange.apply(
      enabled: true,
      phase: .serving(port: 8123),
      profileID: "chat",
      setPreference: { preferenceEnabled = $0 },
      stopEngine: {},
      startEngine: { requestedStarts.append($0) }
    )

    XCTAssertTrue(preferenceEnabled)
    XCTAssertEqual(requestedStarts, [.external])
  }

  func test_bind_mode_change_enable_write_failure_does_not_launch_external_daemon() async {
    struct StubError: Error {}
    var stopCalls = 0
    var preferenceWrites: [Bool] = []
    var requestedStarts: [EngineHTTPBindMode] = []

    do {
      try await LocalAPIBindModeChange.apply(
        enabled: true,
        phase: .serving(port: 8123),
        profileID: "chat",
        setPreference: {
          preferenceWrites.append($0)
          throw StubError()
        },
        stopEngine: { stopCalls += 1 },
        startEngine: { requestedStarts.append($0) }
      )
      XCTFail("enabling external access must throw when the helper-visible preference cannot be persisted")
    } catch is StubError {
      // expected
    } catch {
      XCTFail("unexpected error: \(error)")
    }

    XCTAssertEqual(stopCalls, 1)
    XCTAssertEqual(preferenceWrites, [true])
    XCTAssertTrue(requestedStarts.isEmpty,
                  "never launch an external listener while the helper-visible preference still says loopback")
  }

  func test_bind_mode_change_enable_start_failure_rolls_back_preference() async {
    struct StubError: Error {}
    var preferenceEnabled = false
    var preferenceWrites: [Bool] = []
    var requestedStarts: [EngineHTTPBindMode] = []

    do {
      try await LocalAPIBindModeChange.apply(
        enabled: true,
        phase: .serving(port: 8123),
        profileID: "chat",
        setPreference: {
          preferenceEnabled = $0
          preferenceWrites.append($0)
        },
        stopEngine: {},
        startEngine: {
          requestedStarts.append($0)
          throw StubError()
        }
      )
      XCTFail("start failure after enabling external access must surface")
    } catch is StubError {
      // expected
    } catch {
      XCTFail("unexpected error: \(error)")
    }

    XCTAssertFalse(preferenceEnabled,
                   "rollback restores loopback preference when the external daemon did not start")
    XCTAssertEqual(preferenceWrites, [true, false])
    XCTAssertEqual(requestedStarts, [.external])
  }

  func test_bind_mode_change_enable_start_failure_surfaces_rollback_failure() async {
    struct StartError: Error {}
    struct RollbackError: Error {}
    var preferenceWrites: [Bool] = []
    var requestedStarts: [EngineHTTPBindMode] = []

    do {
      try await LocalAPIBindModeChange.apply(
        enabled: true,
        phase: .serving(port: 8123),
        profileID: "chat",
        setPreference: {
          preferenceWrites.append($0)
          if $0 == false { throw RollbackError() }
        },
        stopEngine: {},
        startEngine: {
          requestedStarts.append($0)
          throw StartError()
        }
      )
      XCTFail("rollback write failure must be surfaced when external start fails")
    } catch let error as LocalAPIBindModeRollbackError {
      XCTAssertTrue(error.startError is StartError)
      XCTAssertTrue(error.rollbackError is RollbackError)
      XCTAssertEqual(error.errorDescription?.contains("could not be restored"), true)
    } catch {
      XCTFail("expected rollback composite error, got: \(error)")
    }

    XCTAssertEqual(preferenceWrites, [true, false])
    XCTAssertEqual(requestedStarts, [.external])
  }

  func test_bind_mode_change_propagates_preference_write_failure() async {
    struct StubError: Error {}
    let preferenceEnabled = true
    var requestedStarts: [EngineHTTPBindMode] = []

    do {
      try await LocalAPIBindModeChange.apply(
        enabled: false,
        phase: .serving(port: 8123),
        profileID: "chat",
        setPreference: { _ in throw StubError() },
        stopEngine: {},
        startEngine: { requestedStarts.append($0) }
      )
      XCTFail("shared preference write failure must surface to the UI")
    } catch is StubError {
      // expected
    } catch {
      XCTFail("unexpected error: \(error)")
    }

    XCTAssertTrue(preferenceEnabled,
                  "preference state must stay external when the helper-visible write fails")
    XCTAssertEqual(requestedStarts, [.loopback])
  }

  func test_bind_mode_change_does_not_mutate_preference_while_starting() async throws {
    var preferenceEnabled = true
    var stopCalls = 0
    var startCalls: [EngineHTTPBindMode] = []

    try await LocalAPIBindModeChange.apply(
      enabled: false,
      phase: .starting,
      profileID: "chat",
      setPreference: { preferenceEnabled = $0 },
      stopEngine: { stopCalls += 1 },
      startEngine: { startCalls.append($0) }
    )

    XCTAssertTrue(preferenceEnabled,
                  "do not persist loopback posture while an external-bound daemon may still come up")
    XCTAssertEqual(stopCalls, 0)
    XCTAssertTrue(startCalls.isEmpty)
  }

  func test_profile_switch_gate_rejects_second_selection_while_restart_in_flight() {
    let state = LocalAPIState.make(status: .running(EngineSessionSnapshot(port: 8123, profileID: "chat")),
                                   hasActiveProfile: true)
    var restartInFlight = false

    XCTAssertTrue(LocalAPIProfileSwitchGate.acceptSelection(
      selectedProfileID: "beta",
      runtimeProfileID: "chat",
      state: state,
      restartInFlight: &restartInFlight
    ))
    XCTAssertTrue(restartInFlight,
                  "the first profile switch must synchronously mark a restart in flight before spawning async stop/start")

    XCTAssertFalse(LocalAPIProfileSwitchGate.acceptSelection(
      selectedProfileID: "gamma",
      runtimeProfileID: "chat",
      state: state,
      restartInFlight: &restartInFlight
    ))
    XCTAssertTrue(restartInFlight)
  }

  func test_profile_options_ignore_invalid_entries_and_mark_runtime_profile() throws {
    let chat = try Profile.parse(toml: """
    id = "chat"
    name = "Chat"
    model = "Qwen/Qwen3-0.6B-GGUF/Qwen3-0.6B-Q8_0.gguf"
    inferlet = "chat-apc"
    """)
    let fast = try Profile.parse(toml: """
    id = "fast-think"
    name = "Fast Think"
    model = "Qwen/Qwen3-0.6B-GGUF/Qwen3-0.6B-Q8_0.gguf"
    inferlet = "chat-apc"
    """)

    let options = LocalAPIProfileOption.make(
      entries: [
        ProfileLoadResult(url: URL(fileURLWithPath: "/profiles/bad.toml"),
                          profile: nil,
                          error: .missingField("id"),
                          warnings: []),
        ProfileLoadResult(url: URL(fileURLWithPath: "/profiles/chat.toml"),
                          profile: chat,
                          error: nil,
                          warnings: []),
        ProfileLoadResult(url: URL(fileURLWithPath: "/profiles/fast-think.toml"),
                          profile: fast,
                          error: nil,
                          warnings: []),
      ],
      runtimeProfileID: "fast-think"
    )

    XCTAssertEqual(options.map(\.id), ["chat", "fast-think"])
    XCTAssertEqual(options.map(\.title), ["Chat", "Fast Think"])
    XCTAssertEqual(options.map(\.modelDisplayName), ["Qwen3-0.6B-Q8_0.gguf", "Qwen3-0.6B-Q8_0.gguf"])
    XCTAssertEqual(options.map(\.isRuntimeProfile), [false, true])
  }
}
