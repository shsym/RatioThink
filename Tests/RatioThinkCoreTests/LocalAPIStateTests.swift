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

  func test_curl_snippet_reflects_selected_profile_request_shape() throws {
    let repeatBoost = try Profile.parse(toml: """
    id = "repeat-boost"
    name = "Repeat Boost"
    model = "m"
    inferlet = "chat-apc"

    [sampling]
    temperature = 0.0
    top_p = 0.9
    max_tokens = 2048

    [speculation]
    enabled = true
    leader_len = 2
    draft_len = 4
    """)
    let repeatCurl = LocalAPICurl.chatCompletions(
      baseURL: "http://127.0.0.1:8123",
      model: "m",
      streaming: true,
      profile: repeatBoost)

    XCTAssertTrue(
      repeatCurl.contains("\"temperature\": 0"),
      "Repeat Boost examples must show the greedy sampling that makes speculation engage; curl=\(repeatCurl)"
    )
    XCTAssertTrue(repeatCurl.contains("\"top_p\": 0.9"))
    XCTAssertTrue(repeatCurl.contains("\"max_tokens\": 2048"))
    XCTAssertTrue(repeatCurl.contains("\"speculation\""),
                  "enabled [speculation] must be visible in the copyable request body")
    XCTAssertTrue(repeatCurl.contains("\"enabled\": true"))
    XCTAssertTrue(repeatCurl.contains("\"leader_len\": 2"))
    XCTAssertTrue(repeatCurl.contains("\"draft_len\": 4"))
    XCTAssertTrue(repeatCurl.contains("\"profile_id\": \"repeat-boost\""))

    let jsonThink = try Profile.parse(toml: """
    id = "json-think"
    name = "JSON Think"
    model = "m"
    inferlet = "chat-apc"

    [constraint]
    response_format = "json_object"
    """)
    let jsonCurl = LocalAPICurl.chatCompletions(
      baseURL: "http://127.0.0.1:8123",
      model: "m",
      streaming: false,
      profile: jsonThink)

    XCTAssertTrue(jsonCurl.contains("\"response_format\""),
                  "JSON Think examples must include the OpenAI response_format knob")
    XCTAssertTrue(jsonCurl.contains("\"type\": \"json_object\""))
    XCTAssertTrue(jsonCurl.contains("\"stream\": false"))
    XCTAssertFalse(jsonCurl.contains("\"speculation\""))
  }

  func test_curl_snippet_for_speculation_profiles_shows_forced_greedy_temperature() throws {
    let customSpeculation = try Profile.parse(toml: """
    id = "custom-spec"
    name = "Custom Speculation"
    model = "m"
    inferlet = "chat-apc"

    [sampling]
    temperature = 0.7
    top_p = 0.8
    max_tokens = 512

    [speculation]
    enabled = true
    leader_len = 3
    draft_len = 5
    """)

    let curl = LocalAPICurl.chatCompletions(
      baseURL: "http://127.0.0.1:8123",
      model: "m",
      streaming: true,
      profile: customSpeculation)

    XCTAssertTrue(
      curl.contains("\"temperature\": 0"),
      "Speculation examples must mirror the app send path's forced greedy sampling; curl=\(curl)"
    )
    XCTAssertFalse(curl.contains("\"temperature\": 0.7"))
    XCTAssertTrue(curl.contains("\"top_p\": 0.8"))
    XCTAssertTrue(curl.contains("\"max_tokens\": 512"))
    XCTAssertTrue(curl.contains("\"speculation\""))
    XCTAssertTrue(curl.contains("\"enabled\": true"))
    XCTAssertTrue(curl.contains("\"profile_id\": \"custom-spec\""))
    XCTAssertTrue(curl.contains("\"leader_len\": 3"))
    XCTAssertTrue(curl.contains("\"draft_len\": 5"))
  }

  func test_curl_snippet_replaces_non_finite_profile_numbers_with_defaults() {
    let corruptProfile = Profile(
      id: "corrupt",
      name: "Corrupt",
      model: "m",
      inferlet: "chat-apc",
      sampling: Sampling(temperature: .nan, topP: .infinity, maxTokens: 512))

    let curl = LocalAPICurl.request(
      baseURL: "http://127.0.0.1:8123",
      model: "m",
      streaming: true,
      profile: corruptProfile)

    XCTAssertTrue(curl.contains("\"temperature\": 0.7"), curl)
    XCTAssertTrue(curl.contains("\"top_p\": 0.9"), curl)
    XCTAssertFalse(curl.contains("nan"), curl)
    XCTAssertFalse(curl.contains("inf"), curl)
  }

  func test_profile_entrypoint_uses_inferlet_for_tree_of_thought_and_best_of_n() throws {
    let treeOfThought = try Profile.parse(toml: """
    id = "tree-of-thought"
    name = "Tree of Thought"
    model = "m"
    inferlet = "chat-apc"

    [sampling]
    temperature = 0.7
    top_p = 0.9
    max_tokens = 2048

    [inferlet_args]
    mode = "tree-of-thought"
    breadth = 3
    depth = 2
    beam_width = 2
    max_tokens_per_node = 256
    """)
    let totRoutes = LocalAPIRoute.clientFacing(streaming: true, profile: treeOfThought)
    XCTAssertEqual(totRoutes.first?.path, "/v1/inferlet")
    XCTAssertEqual(totRoutes.first?.summary, "Tree of Thought inferlet dispatch (SSE streaming)")

    let totCurl = LocalAPICurl.request(baseURL: "http://127.0.0.1:8123",
                                       model: "m",
                                       streaming: true,
                                       profile: treeOfThought)
    XCTAssertTrue(totCurl.contains("http://127.0.0.1:8123/v1/inferlet"))
    XCTAssertTrue(totCurl.contains("\"inferlet\": \"tree-of-thought\""))
    XCTAssertTrue(totCurl.contains("\"stream\": true"))
    XCTAssertTrue(totCurl.contains("\"input\""))
    XCTAssertTrue(totCurl.contains("\"breadth\": 3"))
    XCTAssertTrue(totCurl.contains("\"depth\": 2"))
    XCTAssertTrue(totCurl.contains("\"beam_width\": 2"))
    XCTAssertTrue(totCurl.contains("\"max_tokens_per_node\": 256"))
    XCTAssertTrue(totCurl.contains("\"temperature\": 0.7"))
    XCTAssertTrue(totCurl.contains("\"top_p\": 0.9"))
    XCTAssertFalse(totCurl.contains("/v1/chat/completions"))

    let bestOfN = try Profile.parse(toml: """
    id = "best-of-n"
    name = "Best of N"
    model = "m"
    inferlet = "chat-apc"

    [sampling]
    temperature = 0.8
    top_p = 0.95
    max_tokens = 2048

    [inferlet_args]
    mode = "best-of-n"
    n = 3
    max_tokens_per_candidate = 256
    thinking = true
    """)
    let bonRoutes = LocalAPIRoute.clientFacing(streaming: false, profile: bestOfN)
    XCTAssertEqual(bonRoutes.first?.path, "/v1/inferlet")
    XCTAssertEqual(bonRoutes.first?.summary, "Best of N inferlet dispatch (single JSON response)")

    let bonCurl = LocalAPICurl.request(baseURL: "http://127.0.0.1:8123",
                                       model: "m",
                                       streaming: false,
                                       profile: bestOfN)
    XCTAssertTrue(bonCurl.contains("http://127.0.0.1:8123/v1/inferlet"))
    XCTAssertTrue(bonCurl.contains("\"inferlet\": \"best-of-n\""))
    XCTAssertTrue(bonCurl.contains("\"stream\": false"))
    XCTAssertTrue(bonCurl.contains("\"n\": 3"))
    XCTAssertTrue(bonCurl.contains("\"max_tokens_per_candidate\": 256"))
    XCTAssertTrue(bonCurl.contains("\"thinking\": true"))
    XCTAssertTrue(bonCurl.contains("\"temperature\": 0.8"))
    XCTAssertTrue(bonCurl.contains("\"top_p\": 0.95"))
    XCTAssertFalse(bonCurl.contains("/v1/chat/completions"))
  }

  func test_profile_entrypoint_uses_text_completion_shape_for_text_completion_profiles() throws {
    let textCompletion = try Profile.parse(toml: """
    id = "plain-text"
    name = "Plain Text"
    model = "m"
    inferlet = "text-completion"
    system_prompt = "Complete the user's text."

    [sampling]
    temperature = 0.6
    top_p = 0.95
    max_tokens = 256
    """)

    let routes = LocalAPIRoute.clientFacing(streaming: false, profile: textCompletion)
    XCTAssertEqual(routes.first?.path, "/v1/inferlet")
    XCTAssertEqual(routes.first?.summary, "Text completion inferlet dispatch (single JSON response)")

    let curl = LocalAPICurl.request(baseURL: "http://127.0.0.1:8123",
                                   model: "m",
                                   streaming: false,
                                   profile: textCompletion)
    XCTAssertTrue(curl.contains("http://127.0.0.1:8123/v1/inferlet"))
    XCTAssertTrue(curl.contains("\"inferlet\": \"text-completion\""))
    XCTAssertTrue(curl.contains("\"stream\": false"))
    XCTAssertTrue(curl.contains("\"input\""))
    XCTAssertTrue(curl.contains("\"prompt\": \"Hello\""))
    XCTAssertTrue(curl.contains("\"max_tokens\": 256"))
    XCTAssertTrue(curl.contains("\"system\": \"Complete the user's text.\""))
    XCTAssertTrue(curl.contains("\"temperature\": 0.6"))
    XCTAssertTrue(curl.contains("\"top_p\": 0.95"))
    XCTAssertFalse(curl.contains("\"messages\""))
    XCTAssertFalse(curl.contains("/v1/chat/completions"))
  }

  // #654: the streaming toggle drives the example's `stream` field — the engine
  // serves both modes, so the snippet must show how to request each.
  func test_curl_snippet_reflects_streaming_toggle() {
    let streaming = LocalAPICurl.chatCompletions(
      baseURL: "http://127.0.0.1:8123", model: "m", streaming: true)
    XCTAssertTrue(streaming.contains("\"stream\": true"))

    let nonStreaming = LocalAPICurl.chatCompletions(
      baseURL: "http://127.0.0.1:8123", model: "m", streaming: false)
    XCTAssertTrue(nonStreaming.contains("\"stream\": false"),
                  "stream:false must produce a non-streaming example (single JSON body)")
    XCTAssertFalse(nonStreaming.contains("\"stream\": true"))
  }

  // MARK: - routes

  func test_clientFacing_routes_match_chat_apc_contract() {
    let ids = LocalAPIRoute.clientFacing().map(\.id)
    XCTAssertEqual(ids, [
      "POST /v1/chat/completions",
      "GET /v1/models",
      "GET /healthz",
    ])
  }

  // #654: the chat-completions route summary reflects the streaming choice so
  // the endpoints list and the curl example agree on the mode.
  func test_chat_completions_route_summary_reflects_streaming_toggle() {
    let streaming = LocalAPIRoute.clientFacing(streaming: true).first { $0.path == "/v1/chat/completions" }
    XCTAssertEqual(streaming?.summary, "Chat completions (SSE streaming)")

    let nonStreaming = LocalAPIRoute.clientFacing(streaming: false).first { $0.path == "/v1/chat/completions" }
    XCTAssertEqual(nonStreaming?.summary, "Chat completions (single JSON response)")
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

  /// #654 ROOT-CAUSE LOCK: switching between two profiles that serve the SAME
  /// model must NOT relaunch the engine. The pre-#654 gate relaunched on any
  /// profile-id change — the observed "switching profiles restarts the engine"
  /// defect. This fails (returns `.restart`) against that old behavior.
  func test_same_model_profile_switch_does_not_relaunch_the_engine() {
    let state = runningState(profileID: "chat", servedModel: modelY)
    var restartInFlight = false

    let outcome = LocalAPIProfileSwitchGate.decide(
      selectedProfileID: "repeat-boost",
      selectedModelID: modelY,          // same model as the running engine
      runtimeProfileID: "chat",
      runtimeModelID: modelY,
      state: state,
      restartInFlight: &restartInFlight
    )

    XCTAssertEqual(outcome, .selectOnly,
                   "a same-model profile switch is a marker-only change — the engine binds only the model at boot, so it must stay up")
    XCTAssertFalse(restartInFlight,
                   "no relaunch fires, so the in-flight guard must NOT be armed")
  }

  /// A switch to a profile that serves a DIFFERENT model is a genuine engine
  /// lifecycle event (v1 pie binds the model at boot, no runtime swap).
  func test_different_model_profile_switch_relaunches_the_engine() {
    let state = runningState(profileID: "chat", servedModel: modelY)
    var restartInFlight = false

    let outcome = LocalAPIProfileSwitchGate.decide(
      selectedProfileID: "big",
      selectedModelID: modelX,          // different model
      runtimeProfileID: "chat",
      runtimeModelID: modelY,
      state: state,
      restartInFlight: &restartInFlight
    )

    XCTAssertEqual(outcome, .restart)
    XCTAssertTrue(restartInFlight,
                  "a model-changing switch must synchronously arm the in-flight guard before the async stop/start")
  }

  /// Re-selecting the already-running profile, or selecting while the engine is
  /// not running, is a marker-only change with no engine action.
  func test_reselecting_running_profile_or_idle_engine_takes_no_engine_action() {
    let running = runningState(profileID: "chat", servedModel: modelY)
    var inFlight = false
    XCTAssertEqual(
      LocalAPIProfileSwitchGate.decide(
        selectedProfileID: "chat", selectedModelID: modelY,
        runtimeProfileID: "chat", runtimeModelID: modelY,
        state: running, restartInFlight: &inFlight),
      .selectOnly)
    XCTAssertFalse(inFlight)

    let stopped = LocalAPIState.make(status: .stopped, hasActiveProfile: true)
    XCTAssertEqual(
      LocalAPIProfileSwitchGate.decide(
        selectedProfileID: "repeat-boost", selectedModelID: modelY,
        runtimeProfileID: nil, runtimeModelID: nil,
        state: stopped, restartInFlight: &inFlight),
      .selectOnly,
      "nothing is running, so there is nothing to relaunch")
  }

  func test_profile_switch_gate_rejects_second_selection_while_restart_in_flight() {
    let state = runningState(profileID: "chat", servedModel: modelY)
    var restartInFlight = false

    XCTAssertEqual(LocalAPIProfileSwitchGate.decide(
      selectedProfileID: "big",
      selectedModelID: modelX,
      runtimeProfileID: "chat",
      runtimeModelID: modelY,
      state: state,
      restartInFlight: &restartInFlight
    ), .restart)
    XCTAssertTrue(restartInFlight,
                  "the first profile switch must synchronously mark a restart in flight before spawning async stop/start")

    XCTAssertEqual(LocalAPIProfileSwitchGate.decide(
      selectedProfileID: "bigger",
      selectedModelID: "Qwen/another.gguf",
      runtimeProfileID: "chat",
      runtimeModelID: modelY,
      state: state,
      restartInFlight: &restartInFlight
    ), .reject,
    "a second switch while a restart is in flight must be rejected")
    XCTAssertTrue(restartInFlight)
  }

  // MARK: - #654 helpers

  private let modelX = "Qwen/Qwen3-0.6B-GGUF/Qwen3-0.6B-Q8_0.gguf"
  private let modelY = "Qwen/Qwen3-1.7B-GGUF/Qwen3-1.7B-Q8_0.gguf"

  private func runningState(profileID: String, servedModel: String) -> LocalAPIState {
    LocalAPIState.make(
      status: .running(EngineSessionSnapshot(port: 8123, profileID: profileID, servedModelID: servedModel)),
      hasActiveProfile: true)
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
    name = "Repeat Boost"
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
    XCTAssertEqual(options.map(\.title), ["Chat", "Repeat Boost"])
    XCTAssertEqual(options.map(\.modelDisplayName), ["Qwen3-0.6B-Q8_0.gguf", "Qwen3-0.6B-Q8_0.gguf"])
    // No served model passed → only the booted profile is "served live". This
    // also pins the boot-id arm that keeps the badge for a legacy snapshot
    // whose servedModelID is empty.
    XCTAssertEqual(options.map(\.isServedLive), [false, true])
  }

  /// #663: after a SAME-MODEL switch the engine stays up bound to the same
  /// model (#654 `.selectOnly`), so a sibling profile that serves the running
  /// model is "served live" even though it is NOT the profile the engine
  /// booted with — the "Running" badge must follow the served MODEL, not the
  /// boot profile id. Mutation guard: drop the model-match arm in
  /// `LocalAPIProfileOption.make` and `chat` flips to `false` here.
  func test_same_model_sibling_is_served_live_after_select_only_switch() throws {
    let chat = try Profile.parse(toml: """
    id = "chat"
    name = "Chat"
    model = "\(modelX)"
    inferlet = "chat-apc"
    """)
    let fast = try Profile.parse(toml: """
    id = "fast-think"
    name = "Repeat Boost"
    model = "\(modelX)"
    inferlet = "chat-apc"
    """)

    // Engine booted on `fast-think` and serves modelX; the user switched to
    // `chat` (same model), a marker-only `.selectOnly` change.
    let options = LocalAPIProfileOption.make(
      entries: [
        ProfileLoadResult(url: URL(fileURLWithPath: "/profiles/chat.toml"),
                          profile: chat, error: nil, warnings: []),
        ProfileLoadResult(url: URL(fileURLWithPath: "/profiles/fast-think.toml"),
                          profile: fast, error: nil, warnings: []),
      ],
      runtimeProfileID: "fast-think",
      runtimeServedModelID: modelX
    )

    XCTAssertEqual(options.map(\.id), ["chat", "fast-think"])
    XCTAssertEqual(options.map(\.isServedLive), [true, true],
                   "both same-model profiles must read as served live: the engine serves modelX")
  }

  /// A profile that serves a DIFFERENT model than the running engine is not
  /// served live — selecting it would relaunch (`.restart`), so the badge must
  /// stay off until the engine actually rebinds.
  func test_different_model_profile_is_not_served_live() throws {
    let chat = try Profile.parse(toml: """
    id = "chat"
    name = "Chat"
    model = "\(modelX)"
    inferlet = "chat-apc"
    """)
    let big = try Profile.parse(toml: """
    id = "big"
    name = "Big"
    model = "\(modelY)"
    inferlet = "chat-apc"
    """)

    // Engine booted on `chat` and serves modelX; `big` serves modelY.
    let options = LocalAPIProfileOption.make(
      entries: [
        ProfileLoadResult(url: URL(fileURLWithPath: "/profiles/chat.toml"),
                          profile: chat, error: nil, warnings: []),
        ProfileLoadResult(url: URL(fileURLWithPath: "/profiles/big.toml"),
                          profile: big, error: nil, warnings: []),
      ],
      runtimeProfileID: "chat",
      runtimeServedModelID: modelX
    )

    XCTAssertEqual(options.map(\.id), ["chat", "big"])
    XCTAssertEqual(options.map(\.isServedLive), [true, false],
                   "a profile serving a different model than the engine must not read as served live")
  }
}
