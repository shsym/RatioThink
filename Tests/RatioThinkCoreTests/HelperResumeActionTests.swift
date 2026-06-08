import XCTest
import Foundation
@testable import RatioThinkCore

/// Unit tests for `HelperResumeAction` — the pure-Swift policy half
/// of the menu-bar Resume button. Drives the action directly so
/// `RatioThinkCoreTests` covers the resolve-and-start sequence without
/// AppKit / NSStatusBar.
final class HelperResumeActionTests: XCTestCase {

  private var tempDir: URL!
  private var logURL: URL!

  override func setUpWithError() throws {
    try super.setUpWithError()
    let uuid = UUID().uuidString.prefix(8).lowercased()
    let dir = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
      .appendingPathComponent("pie-resume-\(uuid)", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    tempDir = dir
    logURL  = dir.appendingPathComponent("engine.log", isDirectory: false)
  }

  override func tearDownWithError() throws {
    if let tempDir { try? FileManager.default.removeItem(at: tempDir) }
    tempDir = nil
    logURL = nil
    try super.tearDownWithError()
  }

  // MARK: - guards

  func test_supervisor_missing_returns_supervisorMissing() {
    let outcome = HelperResumeAction.run(
      engineHost: nil,
      profileStore: nil,
      resolver: nil
    )
    XCTAssertEqual(outcome, .supervisorMissing,
                   "supervisor guard must fire before any other check so a degraded boot does not touch ProfileStore")
  }

  func test_profileStore_missing_returns_profileStoreMissing() {
    let outcome = HelperResumeAction.run(
      engineHost: makeEngineHost(),
      profileStore: nil,
      resolver: { _, _ in .success(self.makeSpec(profileID: "chat")) }
    )
    XCTAssertEqual(outcome, .profileStoreMissing)
  }

  func test_resolver_missing_returns_resolverMissing() throws {
    let store = try makeStoreWithChatProfile(active: "chat")
    defer { store.stop() }
    let outcome = HelperResumeAction.run(
      engineHost: makeEngineHost(),
      profileStore: store,
      resolver: nil
    )
    XCTAssertEqual(outcome, .resolverMissing)
  }

  // MARK: - no active profile

  func test_no_active_profile_logs_and_drops_without_calling_supervisor_start() throws {
    let store = try makeStoreWithChatProfile(active: nil)
    defer { store.stop() }
    let engineHost = makeEngineHost()

    // Track whether the injected resolver fires — if the guard works,
    // it never should because we return before resolve().
    let resolverCalls = AtomicCounter()
    let outcome = HelperResumeAction.run(
      engineHost: engineHost,
      profileStore: store,
      resolver: { _, _ in
        resolverCalls.increment()
        return .success(self.makeSpec(profileID: "chat"))
      }
    )
    XCTAssertEqual(outcome, .noActiveProfile(afterRetry: false))
    XCTAssertEqual(resolverCalls.value, 0,
                   "no-active-profile guard must short-circuit before resolver is invoked")
    // engineHost must remain in .stopped; .start was never queued.
    XCTAssertEqual(engineHost.status, .stopped,
                   "engineHost must not transition when Resume drops on noActiveProfile")
  }

  func test_dangling_active_id_routes_to_resolver_and_returns_resolverFailed() throws {
    // Profile dir has `chat`, active id is `ghost` (no matching
    // entry). The two-step lookup (review cycle 149/150 F2) MUST
    // hand `ghost` to the resolver — which returns
    // `.profileMissing` — instead of collapsing the dangling-id
    // case into `.noActiveProfile`. Test asserts the resolver IS
    // called and the dangling case is distinguishable in the
    // helper log.
    let store = try makeStoreWithChatProfile(active: "ghost")
    defer { store.stop() }
    let resolverCalls = AtomicCounter()
    let resolver: HelperExportedAPI.LaunchSpecResolver = { id, _ in
      resolverCalls.increment()
      return .failure(EngineError(code: .profileMissing,
                                  message: "no profile with id=\(id)"))
    }
    let outcome = HelperResumeAction.run(
      engineHost: makeEngineHost(),
      profileStore: store,
      resolver: resolver
    )
    XCTAssertEqual(resolverCalls.value, 1,
                   "dangling-id path must invoke the resolver — that's how the helper distinguishes 'never set' from 'stale id'")
    if case .resolverFailed(let err) = outcome {
      XCTAssertEqual(err.code, .profileMissing,
                     "resolver's profileMissing must propagate as-is so log lines name the actual id")
    } else {
      XCTFail("expected .resolverFailed(.profileMissing), got \(outcome)")
    }
  }

  func test_unreadable_marker_routes_to_activeProfileUnreadable_not_noActiveProfile() throws {
    // Review v3 F1 + v5 F2: when the on-disk marker exists but cannot
    // be read (perms / dir-at-path / decode), ProfileStore surfaces
    // `lastActiveProfileError`. HelperResumeAction must promote that
    // to a structured `.activeProfileUnreadable*` variant instead of
    // collapsing the case into `.noActiveProfile`.
    //
    // Post-v5: the retry path (F3) runs whenever lastActiveProfileError
    // is set, so a stable broken marker now routes through retry and
    // surfaces `.activeProfileUnreadableAfterRetry`. The v3 invariant
    // (distinct from `.noActiveProfile`) is preserved by the new
    // variant — the test pins the structured-vs-collapsed shape, not
    // the specific arm.
    let tempProfilesDir = tempDir.appendingPathComponent("profiles", isDirectory: true)
    try FileManager.default.createDirectory(at: tempProfilesDir,
                                            withIntermediateDirectories: true)
    let toml = """
    id = "chat"
    name = "Chat"
    model = "m"
    inferlet = "chat-apc"
    """
    try toml.write(to: tempProfilesDir.appendingPathComponent("chat.toml"),
                   atomically: true, encoding: .utf8)
    // Plant a directory at the marker path — read fails with a
    // structured ProfileStoreError, NOT an absent-file nil.
    let activeURL = tempDir.appendingPathComponent("active-profile",
                                                   isDirectory: false)
    try FileManager.default.createDirectory(at: activeURL,
                                            withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: activeURL) }
    let store = ProfileStore(directory: tempProfilesDir,
                             activeProfileURL: activeURL)
    try store.start()
    defer { store.stop() }
    XCTAssertNil(store.activeProfileID, "sanity: unreadable marker -> nil id")
    XCTAssertNotNil(store.lastActiveProfileError,
                    "sanity: store must carry the structured read error")

    let outcome = HelperResumeAction.run(
      engineHost: makeEngineHost(),
      profileStore: store,
      resolver: { _, _ in .success(self.makeSpec(profileID: "chat")) }
    )
    if case .activeProfileUnreadableAfterRetry(let err) = outcome {
      if case .activeProfileReadFailed = err {
        // expected
      } else {
        XCTFail("expected wrapped .activeProfileReadFailed, got \(err)")
      }
    } else {
      XCTFail("expected .activeProfileUnreadableAfterRetry (post-v5 F2), got \(outcome)")
    }
  }

  func test_resume_retries_marker_read_when_lastActiveProfileError_is_set() throws {
    // Review v4 F3: a user-initiated Resume click acts as an
    // implicit retry of a previously-broken marker. If
    // store.lastActiveProfileError is set, HelperResumeAction.run
    // calls store.reloadActiveProfile() before consulting
    // activeProfileID. Setup: plant a dir at marker path before
    // start (so start surfaces .activeProfileReadFailed), then
    // repair externally, then run resume — outcome must reflect
    // the repaired state (no longer .activeProfileUnreadable).
    let tempProfilesDir = tempDir.appendingPathComponent("profiles", isDirectory: true)
    try FileManager.default.createDirectory(at: tempProfilesDir,
                                            withIntermediateDirectories: true)
    let toml = """
    id = "chat"
    name = "Chat"
    model = "m"
    inferlet = "chat-apc"
    """
    try toml.write(to: tempProfilesDir.appendingPathComponent("chat.toml"),
                   atomically: true, encoding: .utf8)
    let activeURL = tempDir.appendingPathComponent("active-profile",
                                                   isDirectory: false)
    try FileManager.default.createDirectory(at: activeURL,
                                            withIntermediateDirectories: true)
    let store = ProfileStore(directory: tempProfilesDir,
                             activeProfileURL: activeURL)
    try store.start()
    defer { store.stop() }
    XCTAssertNotNil(store.lastActiveProfileError,
                    "sanity: broken marker at start")

    // Operator repairs externally.
    try FileManager.default.removeItem(at: activeURL)
    try "chat".write(to: activeURL, atomically: true, encoding: .utf8)

    let fakeBin = try writeFakePie(port: 52525)
    let engineHost = makeEngineHost()
    defer { engineHost.stop() }
    let resolver: HelperExportedAPI.LaunchSpecResolver = { id, _ in
      .success(self.makeSpec(profileID: id))
    }
    let outcome = HelperResumeAction.run(
      engineHost: engineHost,
      profileStore: store,
      resolver: resolver
    )
    XCTAssertEqual(outcome, .started(profileID: "chat"),
                   "Resume click must retry the marker and recover after operator repair (review v4 F3); got \(outcome)")
  }

  func test_retry_healed_to_absent_marker_returns_noActiveProfile_afterRetry_true() throws {
    // Review v6 F3: broken marker at start primes the F3 retry path.
    // Operator's "repair" between start and the Resume click is to
    // DELETE the marker (not write a valid id). Post-retry the
    // snapshot is `.absent` (id nil, error nil). Pre-v6 this
    // collapsed into `.noActiveProfile` indistinguishably from "user
    // never picked one"; post-v6 the new payload signals
    // "retried, healed to absent" so helper.log shows the breadcrumb.
    let tempProfilesDir = tempDir.appendingPathComponent("profiles", isDirectory: true)
    try FileManager.default.createDirectory(at: tempProfilesDir,
                                            withIntermediateDirectories: true)
    let toml = """
    id = "chat"
    name = "Chat"
    model = "m"
    inferlet = "chat-apc"
    """
    try toml.write(to: tempProfilesDir.appendingPathComponent("chat.toml"),
                   atomically: true, encoding: .utf8)
    let activeURL = tempDir.appendingPathComponent("active-profile",
                                                   isDirectory: false)
    // Plant a directory at start so lastActiveProfileError is set.
    try FileManager.default.createDirectory(at: activeURL,
                                            withIntermediateDirectories: true)
    let store = ProfileStore(directory: tempProfilesDir,
                             activeProfileURL: activeURL)
    try store.start()
    defer { store.stop() }
    XCTAssertNotNil(store.lastActiveProfileError,
                    "sanity: broken marker at start primes retry")

    // Operator deletes the marker (the .absent repair shape).
    try FileManager.default.removeItem(at: activeURL)

    let engineHost = makeEngineHost()
    defer { engineHost.stop() }
    let resolver: HelperExportedAPI.LaunchSpecResolver = { _, _ in
      XCTFail("resolver must not be invoked when retry heals to absent")
      return .failure(EngineError(code: .profileMissing, message: "unreachable"))
    }
    let outcome = HelperResumeAction.run(
      engineHost: engineHost,
      profileStore: store,
      resolver: resolver
    )
    XCTAssertEqual(outcome, .noActiveProfile(afterRetry: true),
                   "retry-healed-to-absent must distinguish from never-selected (review v6 F3); got \(outcome)")
  }

  // MARK: - happy path

  func test_active_profile_resolves_and_calls_supervisor_start() throws {
    let store = try makeStoreWithChatProfile(active: "chat")
    defer { store.stop() }

    let fakeBin = try writeFakePie(port: 47474)
    let engineHost = makeEngineHost()
    defer { engineHost.stop() }

    let resolverCalls = AtomicCounter()
    let resolver: HelperExportedAPI.LaunchSpecResolver = { id, _ in
      resolverCalls.increment()
      return .success(self.makeSpec(profileID: id))
    }
    let outcome = HelperResumeAction.run(
      engineHost: engineHost,
      profileStore: store,
      resolver: resolver
    )
    XCTAssertEqual(outcome, .started(profileID: "chat"))
    XCTAssertEqual(resolverCalls.value, 1,
                   "resolver must be called exactly once per Resume click")

    // supervisor.start was actually invoked: wait for handshake so we
    // confirm the fake pie was spawned (not just .starting).
    waitForRunning(engineHost, timeout: 5)
    if case .running(let port, let profileID) = engineHost.status {
      XCTAssertEqual(port, 47474)
      XCTAssertEqual(profileID, "chat")
    } else {
      XCTFail("expected engineHost to reach .running after Resume, got \(engineHost.status)")
    }
  }

  // MARK: - #469: Resume honors the durable active-model marker

  func test_resume_passes_activeModel_marker_to_resolver() throws {
    // The user's last pick lives in the durable active-model marker. A
    // stopped-engine Resume must boot THAT model (as the resolver's explicit
    // override), not silently revert to the profile default.
    let store = try makeStoreWithChatProfile(active: "chat")
    defer { store.stop() }
    try store.setActiveModelID("Org/Repo/picked.gguf")

    let captured = CapturedModel()
    let resolver: HelperExportedAPI.LaunchSpecResolver = { id, model in
      captured.value = model
      captured.wasNil = (model == nil)
      return .success(self.makeSpec(profileID: id))
    }
    let engineHost = makeEngineHost()
    defer { engineHost.stop() }
    let outcome = HelperResumeAction.run(
      engineHost: engineHost, profileStore: store, resolver: resolver)

    XCTAssertEqual(outcome, .started(profileID: "chat"))
    XCTAssertEqual(captured.value, "Org/Repo/picked.gguf",
                   "Resume must pass the active-model marker as the resolver's explicit boot model")
  }

  func test_resume_passes_nil_when_no_activeModel_marker() throws {
    // Never launched → no marker → the resolver falls back to the profile
    // default (it receives a nil override).
    let store = try makeStoreWithChatProfile(active: "chat")
    defer { store.stop() }

    let captured = CapturedModel()
    let resolver: HelperExportedAPI.LaunchSpecResolver = { id, model in
      captured.value = model
      captured.wasNil = (model == nil)
      return .success(self.makeSpec(profileID: id))
    }
    let engineHost = makeEngineHost()
    defer { engineHost.stop() }
    _ = HelperResumeAction.run(
      engineHost: engineHost, profileStore: store, resolver: resolver)

    XCTAssertTrue(captured.wasNil,
                  "with no active-model marker the resolver must receive nil → profile default")
  }

  // MARK: - #469 F1: stale active-model marker falls back to the profile default

  func test_resume_stale_marker_modelMissing_retries_profile_default() throws {
    // The marker names a model deleted/evicted out from under it. The
    // marker-driven resolve fails modelMissing; Resume must retry the profile
    // default (which is still valid) rather than dead-end on the missing pick.
    let store = try makeStoreWithChatProfile(active: "chat")
    defer { store.stop() }
    try store.setActiveModelID("Org/Deleted/gone.gguf")

    let captured = CapturedModel()
    let resolver: HelperExportedAPI.LaunchSpecResolver = { id, model in
      captured.value = model      // last call's override
      captured.wasNil = (model == nil)
      if model == "Org/Deleted/gone.gguf" {
        return .failure(EngineError(code: .modelMissing, message: "model gone"))
      }
      return .success(self.makeSpec(profileID: id))   // nil (profile default) resolves
    }
    let engineHost = makeEngineHost()
    defer { engineHost.stop() }
    let outcome = HelperResumeAction.run(
      engineHost: engineHost, profileStore: store, resolver: resolver)

    XCTAssertEqual(outcome, .started(profileID: "chat"),
                   "a stale marker (modelMissing) must retry the profile default, not dead-end; got \(outcome)")
    XCTAssertTrue(captured.wasNil, "the retry must resolve with the profile default (nil override)")
  }

  func test_resume_marker_and_default_both_missing_surfaces_modelMissing() throws {
    // Marker missing AND the profile default also missing → the single retry
    // also fails → surface the original modelMissing (no dead-loop, real error).
    let store = try makeStoreWithChatProfile(active: "chat")
    defer { store.stop() }
    try store.setActiveModelID("Org/Deleted/gone.gguf")
    let err = EngineError(code: .modelMissing, message: "nothing resolves")
    let engineHost = makeEngineHost()
    let outcome = HelperResumeAction.run(
      engineHost: engineHost, profileStore: store,
      resolver: { _, _ in .failure(err) })   // both marker and default fail
    XCTAssertEqual(outcome, .resolverFailed(err),
                   "when both the marker and the profile default are missing, the real error must surface")
  }

  func test_resume_marker_non_modelMissing_failure_does_not_retry() throws {
    // A non-modelMissing marker failure (e.g. memoryRisk) must NOT retry the
    // default — the model is present but unsafe; retrying would not help and
    // the reason must surface as-is.
    let store = try makeStoreWithChatProfile(active: "chat")
    defer { store.stop() }
    try store.setActiveModelID("Org/Big/huge.gguf")
    let calls = AtomicCounter()
    let err = EngineError(code: .memoryRisk, message: "too large")
    let engineHost = makeEngineHost()
    let outcome = HelperResumeAction.run(
      engineHost: engineHost, profileStore: store,
      resolver: { _, _ in calls.increment(); return .failure(err) })
    XCTAssertEqual(outcome, .resolverFailed(err))
    XCTAssertEqual(calls.value, 1, "a non-modelMissing marker failure must not trigger the default retry")
  }

  // MARK: - resolver failure

  func test_resolver_failure_surfaces_as_resolverFailed() throws {
    let store = try makeStoreWithChatProfile(active: "chat")
    defer { store.stop() }
    let engineHost = makeEngineHost()
    let err = EngineError(code: .spawnFailed, message: "pie binary missing")
    let outcome = HelperResumeAction.run(
      engineHost: engineHost,
      profileStore: store,
      resolver: { _, _ in .failure(err) }
    )
    XCTAssertEqual(outcome, .resolverFailed(err))
    XCTAssertEqual(engineHost.status, .failed(code: .spawnFailed, message: err.message),
                   "every resolver failure (not just memoryRisk) must publish .failed so the App surfaces the reason")
  }

  func test_modelMissing_resolver_failure_publishes_failed_status_for_menu() throws {
    // The  follow-up: a missing model must stop being a silent
    // `.stopped` defer. The resolver failure now publishes `.failed`
    // through the engine host so the App menu/chat surface the reason
    // and (via `invitesResumeRetry`) keep a working retry.
    let store = try makeStoreWithChatProfile(active: "chat")
    defer { store.stop() }
    let engineHost = makeEngineHost()
    let err = EngineError(code: .modelMissing,
                          message: "no model at <path>; not in HF cache")

    let outcome = HelperResumeAction.run(
      engineHost: engineHost,
      profileStore: store,
      resolver: { _, _ in .failure(err) }
    )

    XCTAssertEqual(outcome, .resolverFailed(err))
    XCTAssertEqual(engineHost.status, .failed(code: .modelMissing, message: err.message),
                   "resolver-level modelMissing must become observable to the menu/status layer")
  }

  func test_memoryRisk_resolver_failure_publishes_failed_status_for_menu() throws {
    let store = try makeStoreWithChatProfile(active: "chat")
    defer { store.stop() }
    let engineHost = makeEngineHost()
    let err = EngineError(code: .memoryRisk,
                          message: "memory risk: oversized model; choose a smaller model")

    let outcome = HelperResumeAction.run(
      engineHost: engineHost,
      profileStore: store,
      resolver: { _, _ in .failure(err) }
    )

    XCTAssertEqual(outcome, .resolverFailed(err))
    XCTAssertEqual(engineHost.status, .failed(code: .memoryRisk, message: err.message),
                   "resolver-level memoryRisk must become observable to the menu/status layer")
  }

  // MARK: - start rejected

  func test_start_rejected_when_supervisor_already_running() throws {
    let store = try makeStoreWithChatProfile(active: "chat")
    defer { store.stop() }
    let fakeBin = try writeFakePie(port: 51515)
    let engineHost = makeEngineHost()
    defer { engineHost.stop() }

    let resolver: HelperExportedAPI.LaunchSpecResolver = { id, _ in
      .success(self.makeSpec(profileID: id))
    }
    // First resume drives supervisor to .running.
    XCTAssertEqual(
      HelperResumeAction.run(engineHost: engineHost, profileStore: store, resolver: resolver),
      .started(profileID: "chat")
    )
    waitForRunning(engineHost, timeout: 5)

    // Second resume must be refused by the supervisor (already
    // running) and surface as `.startRejected`. Caller can log the
    // benign duplicate without crashing.
    let second = HelperResumeAction.run(engineHost: engineHost, profileStore: store, resolver: resolver)
    if case .startRejected(let err) = second {
      XCTAssertEqual(err.code, .alreadyRunning,
                     "double-resume against a running supervisor must surface .alreadyRunning")
    } else {
      XCTFail("expected .startRejected, got \(second)")
    }
  }

  // MARK: - helpers

  // MARK: - #3: active-profile marker is authoritative for the menu-icon start

  /// : the menu-bar (menu-icon) Resume start resolves from the GLOBAL
  /// active-profile marker (`store.activeProfileID`). A profile swap persists
  /// the selection via `ProfileStore.setActiveProfileID`, so updating the
  /// marker MUST redirect which profile the helper starts — otherwise a
  /// swap-while-stopped leaves the marker on the old profile and the menu-icon
  /// start launches the OLD model. Pins that the marker write a swap makes is
  /// honored end-to-end.
  func test_active_profile_marker_redirects_menu_icon_start_after_swap() throws {
    let store = try makeStoreWithChatProfile(active: "chat")
    defer { store.stop() }

    // The resolver echoes whatever profile id the marker hands it, so the
    // `.started(profileID:)` outcome reflects the resolved selection.
    let before = HelperResumeAction.run(
      engineHost: makeEngineHost(), profileStore: store,
      resolver: { id, _ in .success(self.makeSpec(profileID: id)) }
    )
    XCTAssertEqual(before, .started(profileID: "chat"),
                   "Resume must start the active-profile marker (chat)")

    // Simulate a profile swap persisting the new selection — the #3 fix's
    // `ChatScaffoldView.onChange → setActiveProfileID(new)` write.
    try store.setActiveProfileID("beta")

    let after = HelperResumeAction.run(
      engineHost: makeEngineHost(), profileStore: store,
      resolver: { id, _ in .success(self.makeSpec(profileID: id)) }
    )
    XCTAssertEqual(after, .started(profileID: "beta"),
                   "after a swap updates the active-profile marker, the menu-icon start must launch the NEW profile, not the old one")
  }

  private func makeStoreWithChatProfile(active: String?) throws -> ProfileStore {
    let profiles = tempDir.appendingPathComponent("profiles", isDirectory: true)
    try FileManager.default.createDirectory(at: profiles, withIntermediateDirectories: true)
    let toml = """
    id = "chat"
    name = "Chat"
    model = "ignored-by-fake-pie.gguf"
    inferlet = "chat-apc"
    """
    try toml.write(to: profiles.appendingPathComponent("chat.toml"),
                   atomically: true, encoding: .utf8)
    let activeURL = tempDir.appendingPathComponent("active-profile", isDirectory: false)
    let store = ProfileStore(directory: profiles, activeProfileURL: activeURL)
    try store.start()
    if let active { try store.setActiveProfileID(active) }
    return store
  }

  /// : PieEngineHost replaces PieSupervisor on the
  /// HelperResumeAction surface. The launcher seam returns a
  /// synthetic `(port, FakeSession)` tuple so unit tests do not
  /// need a real `pie` subprocess. Tests that previously asserted
  /// `.running(port: 47474)` now pin a deterministic port the
  /// launcher closure was configured with.
  private func makeEngineHost(handshakePort: EnginePort = 47474) -> PieEngineHost {
    PieEngineHost(launcher: { _ in
      return (port: handshakePort, session: FakeSession())
    })
  }

  /// Returns a `PieControlLauncher.LaunchSpec` whose binary +
  /// resource paths are not touched by `FakeSession`. Profile id
  /// is the only field the host downstreams into `.running`.
  private func makeSpec(profileID: String) -> PieControlLauncher.LaunchSpec {
    try! PieControlLauncher.LaunchSpec(
      pieBinary: tempDir.appendingPathComponent("ignored-binary"),
      wasmURL: tempDir.appendingPathComponent("ignored.wasm"),
      manifestURL: tempDir.appendingPathComponent("ignored.toml"),
      subprocessEnvironment: [:],
      pieHome: tempDir.appendingPathComponent("home"),
      shmemName: "/pie_test_\(UUID().uuidString.prefix(8))",
      profileID: profileID,
      modelConfig: .dummy
    )
  }

  /// Retained API for tests that previously seeded a fake `pie`
  /// shell script. Under PieEngineHost the launcher closure is the
  /// substitute, but the call site still wants a `URL`-shaped
  /// `fakeBin` to thread through the resolver — return a path
  /// inside `tempDir` so the test reads end-to-end the same.
  private func writeFakePie(port: UInt16) throws -> URL {
    tempDir.appendingPathComponent("ignored-pie")
  }

  private func waitForRunning(_ host: PieEngineHost, timeout: TimeInterval) {
    let exp = expectation(description: "engineHost reaches .running")
    let lock = NSLock()
    var fired = false
    let token = host.observe { status, _ in
      if case .running = status {
        lock.lock(); defer { lock.unlock() }
        if !fired { fired = true; exp.fulfill() }
      }
    }
    wait(for: [exp], timeout: timeout)
    token.cancel()
  }

  // MARK: - Review v3 N3: shouldCommitAutoRelaunch veto

  /// The main-async block in `HelperMain.swift`'s relauncher closure
  /// calls this helper to decide whether the deferred
  /// `HelperResumeAction.run` should fire. Pinning the table here
  /// closes the SPM-untestable boundary that hid the v1 F1 blocker:
  /// deleting the production guard would now fail these tests.

  func test_shouldCommitAutoRelaunch_commits_on_failed_engineGone() {
    // The scheduler that triggers the closure ONLY fires on
    // `.failed(.engineGone)`, so this is the production-realistic
    // commit case: state is still `.failed` at the deferred main-
    // queue commit, meaning no user Pause has won the race.
    XCTAssertTrue(HelperResumeAction.shouldCommitAutoRelaunch(
      status: .failed(code: .engineGone, message: "engine process exited (status 9)")
    ))
  }

  func test_shouldCommitAutoRelaunch_commits_on_failed_any_code() {
    // The veto keys on `.failed` as a category, not on `.engineGone`
    // specifically — auto-relaunch into a fresh `.failed` of any
    // code is still recovery intent. Pin so a future narrowing
    // doesn't silently drop legitimate retries.
    for code: EngineErrorCode in [.engineGone, .spawnFailed, .handshakeTimeout, .memoryRisk] {
      XCTAssertTrue(HelperResumeAction.shouldCommitAutoRelaunch(
        status: .failed(code: code, message: "synthetic")
      ), "\(code) must still commit; veto only fires on non-.failed states")
    }
  }

  func test_shouldCommitAutoRelaunch_vetoes_on_stopped() {
    // Review v2 R1: `stopLocked`'s `.failed(.engineGone)` arm
    // transitions state to `.stopped` on a user Pause. A `.stopped`
    // read here means Pause won the deferred-hop race; abort.
    XCTAssertFalse(HelperResumeAction.shouldCommitAutoRelaunch(status: .stopped))
  }

  func test_shouldCommitAutoRelaunch_vetoes_on_running() {
    // Some other caller already drove the engine through `.running`
    // between the host's schedule sync and this main-queue commit
    // (e.g. the user clicked Resume manually). Do not pile a second
    // auto-relaunch on top.
    XCTAssertFalse(HelperResumeAction.shouldCommitAutoRelaunch(
      status: .running(port: 50001, profileID: "chat")
    ))
  }

  func test_shouldCommitAutoRelaunch_vetoes_on_starting_and_stopping() {
    // Transient non-terminal states must also veto so a deferred
    // commit cannot race a fresh launch / shutdown into a double-
    // start or a relaunch under teardown.
    XCTAssertFalse(HelperResumeAction.shouldCommitAutoRelaunch(status: .starting))
    XCTAssertFalse(HelperResumeAction.shouldCommitAutoRelaunch(status: .stopping))
  }

  // MARK: - #395: composeAutoRelaunch (SPM-reachable relauncher seam)

  func test_composeAutoRelaunch_runs_on_failed_and_returns_outcome() {
    // `.failed` is the scheduler-realistic commit case: the seam must
    // invoke `run` exactly once and surface its Outcome. Pinning this
    // here closes the SPM-untestable HelperMain boundary (#395) — the
    // production relauncher now composes through this function.
    let runCount = AtomicCounter()
    let decision = HelperResumeAction.composeAutoRelaunch(
      status: .failed(code: .engineGone, message: "engine process exited")
    ) {
      runCount.increment()
      return .started(profileID: "chat")
    }
    XCTAssertEqual(runCount.value, 1, "a committed decision must invoke `run` exactly once")
    XCTAssertEqual(decision, .ran(.started(profileID: "chat")),
                   "the seam must carry the run Outcome back to the caller for logging")
  }

  func test_composeAutoRelaunch_vetoes_without_running_on_non_failed_states() {
    // A user Pause (`.stopped`), a concurrent start (`.running`), or a
    // transient (`.starting`/`.stopping`) that won the deferred-hop race
    // must VETO — `run` is never invoked, and the observed status rides
    // back in the `.vetoed` payload so HelperMain can log why it skipped.
    let states: [EngineStatus] = [
      .stopped,
      .running(port: 50001, profileID: "chat"),
      .starting,
      .stopping,
    ]
    for status in states {
      let runCount = AtomicCounter()
      let decision = HelperResumeAction.composeAutoRelaunch(status: status) {
        runCount.increment()
        return .started(profileID: "should-not-run")
      }
      XCTAssertEqual(runCount.value, 0, "\(status) must veto: run must NOT fire")
      XCTAssertEqual(decision, .vetoed(status),
                     "\(status) must veto and carry the observed status back for the skip log")
    }
  }

  /// Minimal `EngineSession` for the launcher seam. Records shutdown
  /// invocation count so happy-path tests can verify the host tore
  /// the session down on Pause.
  private final class FakeSession: PieEngineHost.EngineSession, @unchecked Sendable {
    private let count = NSLock()
    private var _value = 0
    var shutdownCount: Int { count.lock(); defer { count.unlock() }; return _value }
    func shutdown() async -> EngineShutdownResult {
      count.lock(); _value += 1; count.unlock()
      return .reaped
    }
  }
}

/// Small thread-safe counter so the resolver-call-count assertion
/// does not race the supervisor's state queue.
private final class AtomicCounter {
  private var _value = 0
  private let lock = NSLock()
  func increment() { lock.lock(); _value += 1; lock.unlock() }
  var value: Int { lock.lock(); defer { lock.unlock() }; return _value }
}

/// Captures the `explicitModel` argument the resolver received (#469). `run`
/// invokes the resolver synchronously before returning, so a plain reference
/// box suffices.
private final class CapturedModel {
  var value: String?
  var wasNil = false
}
