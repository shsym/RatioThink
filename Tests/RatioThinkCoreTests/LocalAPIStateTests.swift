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
    XCTAssertEqual(s.statusLabel, "Starting…")
  }

  func test_stopping_is_off_and_disabled() {
    let s = LocalAPIState.make(status: .stopping, hasActiveProfile: true)
    XCTAssertFalse(s.toggleOn)
    XCTAssertFalse(s.toggleEnabled)
    XCTAssertEqual(s.statusLabel, "Stopping…")
  }

  func test_stopped_with_profile_can_be_turned_on() {
    let s = LocalAPIState.make(status: .stopped, hasActiveProfile: true)
    XCTAssertFalse(s.isServing)
    XCTAssertFalse(s.toggleOn)
    XCTAssertTrue(s.toggleEnabled, "a selected model means we can start the engine")
    XCTAssertEqual(s.statusLabel, "Off")
    XCTAssertEqual(s.detail, "Turn on to serve OpenAI-compatible requests on 127.0.0.1.")
  }

  func test_stopped_without_profile_is_disabled_with_guidance() {
    let s = LocalAPIState.make(status: .stopped, hasActiveProfile: false)
    XCTAssertFalse(s.toggleEnabled, "nothing to serve → can't turn on")
    XCTAssertEqual(s.detail, "Select a model in Settings → Models to enable the local API.")
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

  func test_posture_matches_real_engine_launch_config() {
    // The view's read-only "Security" rows claim loopback-only + no-auth.
    // Those claims are only honest if the app actually launches the engine
    // that way. Pin them to `renderConfigBody`'s preamble so a future TOML
    // change can't silently make the UI lie.
    let body = PieControlLauncher.renderConfigBody(modelConfig: .dummy)

    XCTAssertEqual(EngineHTTPPosture.loopbackOnly, true)
    XCTAssertTrue(body.contains("host = \"127.0.0.1\""),
                  "EngineHTTPPosture.loopbackOnly claims 127.0.0.1 — config must bind there")

    XCTAssertEqual(EngineHTTPPosture.authenticated, false)
    XCTAssertTrue(body.contains("[auth]\nenabled = false"),
                  "EngineHTTPPosture.authenticated=false claims no auth — config must disable it")
  }
}
