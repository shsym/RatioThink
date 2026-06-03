import Foundation
import Combine
import os

/// `@MainActor ObservableObject` mirror of the helper's
/// `engineStatus()` selector. Owns a poll loop against an
/// `AppXPCClient` and republishes the most recent `EngineStatus` so
/// SwiftUI views can branch on it and `HTTPEngineClient.baseURLProvider`
/// can resolve the loopback URL synchronously per request.
///
/// Why poll rather than push? `PieHelperXPC` exposes only a one-shot
/// reply selector — there is no streaming `subscribeEngineStatus` yet.
/// Polling at 1 Hz is well within the helper's idle budget (selector
/// is a property read on the supervisor's state queue) and keeps the
/// GUI's "engine reachable?" signal current without standing up a
/// second XPC surface.
///
/// Initial status is `.starting` (not `.stopped`) because the helper's
/// reachability is genuinely unknown until the first reply lands —
/// `.stopped` would be a load-bearing claim that the supervisor said
/// "engine off," which we have no evidence for yet (and the surfaced
/// UI would say "Engine is stopped, click Resume" instead of the
/// truthful "Engine starting…" placeholder).
@MainActor
public final class EngineStatusStore: ObservableObject {
  /// Last status reported by the helper (or the initial `.starting`
  /// placeholder before the first poll completes).
  @Published public private(set) var status: EngineStatus

  /// Most recent error string from a failed `engineStatus()` poll.
  /// `nil` after a successful poll. Surfaces helper-down vs
  /// supervisor-running-but-still-starting in the UI without forcing
  /// the caller to introspect `EngineStatus` for a `.failed` case.
  @Published public private(set) var lastError: String?

  /// Number of `engineStatus()` polls that have returned (success or
  /// failure). Test seam — lets tests `await` a transition without
  /// polling `status` in a tight loop.
  ///
  /// Deliberately NOT `@Published`: the poll loop bumps this every tick,
  /// and publishing it would re-render every observer (incl. the toolbar
  /// that hosts the engine-status popover) once per second and dismiss
  /// the popover. Real state changes ride `status`/`lastError`, which
  /// are `@Published` and change-guarded; tests observe those.
  public private(set) var pollCount: UInt64 = 0

  /// Signature of the engine failure the user has dismissed from the
  /// in-window error banner. The banner shows only while a failure is
  /// live AND its signature differs from this — so a Dismiss hides the
  /// current failure, and the banner reappears only on a DIFFERENT one
  /// (mirrors `PersistenceStatus.acknowledgeLastError`). `nil` ⇒ nothing
  /// acknowledged yet.
  ///
  /// `@Published` is safe here (it is NOT a per-second churn source): it
  /// changes only on a user Dismiss — never on the 1 Hz poll — and the
  /// banner must re-render to hide itself when it flips.
  @Published public private(set) var acknowledgedEngineFailureSignature: String?

  /// `URL(string: "http://127.0.0.1:<port>")` while running, else
  /// `nil`. Computed live off `status` so the SwiftUI dependency
  /// graph re-evaluates dependent views when status flips.
  public var baseURL: URL? {
    if case .running(let port, _) = status {
      return URL(string: "http://127.0.0.1:\(port)")
    }
    return nil
  }

  private let client: any AppXPCClient
  private let pollInterval: TimeInterval
  private var task: Task<Void, Never>?
  private nonisolated static let log = Logger(subsystem: "com.ratiothink.app", category: "engine-status")

  public init(
    client: any AppXPCClient,
    pollInterval: TimeInterval = 1.0,
    initialStatus: EngineStatus = .starting
  ) {
    self.client = client
    self.pollInterval = pollInterval
    self.status = initialStatus
  }

  /// Begin the background poll loop. Idempotent — re-entry while a
  /// task is already running is a no-op so `RatioThinkApp.init` can safely
  /// `start()` without tracking a "did we already start" flag.
  public func start() {
    guard task == nil else { return }
    let client = self.client
    let interval = self.pollInterval
    Self.log.info("starting engine-status poll loop (interval=\(interval, privacy: .public)s)")
    task = Task { [weak self] in
      while !Task.isCancelled {
        await self?.refreshOnce(client: client)
        if Task.isCancelled { return }
        // `Task.sleep` is the cancellation-aware sleep; an
        // intermediate `cancel()` wakes us with `CancellationError`
        // which we swallow because the outer loop checks the flag.
        try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
      }
    }
  }

  /// Cancel the poll loop. Idempotent. After `stop()` the published
  /// `status` retains its last value — the helper may have torn down,
  /// but the GUI's last view of the world is still actionable.
  public func stop() {
    task?.cancel()
    task = nil
  }

  /// Force one immediate poll. Returns the resolved status (or throws
  /// the XPC failure). Public so tests can drive deterministic
  /// transitions without sleeping for the poll interval — production
  /// callers should not need this.
  ///
  /// Asymmetry vs the poll loop (review v1 F2): on success this
  /// updates `status` and clears `lastError`; on failure it RE-THROWS
  /// and does NOT write `lastError`. Only the poll loop's
  /// `refreshOnce(...)` records failures into `lastError`, because
  /// only the loop has a "no human waiting" path where the error
  /// would otherwise be silently dropped. `refresh()`'s caller
  /// already gets the error via `throw`, so re-publishing it would
  /// flicker a `lastError` value the loop will immediately overwrite
  /// on the next tick. Tests pin this behavior in
  /// `test_refresh_propagates_xpc_failures`.
  @discardableResult
  public func refresh() async throws -> EngineStatus {
    let next = try await client.engineStatus()
    apply(next: next, error: nil)
    return next
  }

  /// Force one poll, recording BOTH outcomes into `status`/`lastError` (unlike
  /// `refresh()`, which rethrows on failure WITHOUT recording — see its
  /// asymmetry note). Used by `ChatRecoveryGate.refreshStatus()` so the chat
  /// classifier's `isHelperUnreachable`/`isEngineGone` reflect the forced
  /// probe, catching a sub-second mid-stream helper/engine death the 1Hz
  /// background loop missed (#393). Also feeds the helper-health ladder via
  /// `onPollOutcome` (a forced-poll failure is a real reachability signal).
  func pollRecordingOutcome() async {
    do {
      apply(next: try await client.engineStatus(), error: nil)
    } catch {
      apply(next: nil, error: String(describing: error))
    }
  }

  ///  Unload: ask the helper to stop the running engine, freeing the
  /// resident model's RAM. Throws on rejection / transport failure so
  /// the caller keeps the resident-model state when the stop did not
  /// actually happen. The next status poll reflects the stopped engine.
  public func stopEngine() async throws {
    try await client.stopEngine()
  }

  /// Test seam: invoked with the human-readable cause whenever a
  /// memory-poll transport error is swallowed to nil. Default routes to
  /// the os.Logger, mirroring `refreshOnce`; tests inject a spy to prove
  /// a wedged engine is RECORDED even though the UI value is nil.
  /// Not `@Published`; never touched on the hot status-poll path.
  var onMemoryPollError: (String) -> Void = { message in
    EngineStatusStore.log.error("engineMemory poll failed: \(message, privacy: .public)")
  }

  /// #412: invoked once per `engineStatus()` poll resolution with the
  /// outcome — `true` when the XPC call returned a value (helper reachable),
  /// `false` when it threw a transport error. The App wires this to
  /// `HelperHealthController.ingestPollOutcome` so the helper-restart ladder
  /// is driven by the SAME poll the status mirror already runs — no second
  /// XPC surface. Default no-op (mirrors `onMemoryPollError`). Not
  /// `@Published`: it is an effect hook fired from `apply` on the main actor,
  /// never a SwiftUI dependency. `@MainActor` so the wired closure can call
  /// the `@MainActor` controller synchronously.
  @MainActor public var onPollOutcome: (Bool) -> Void = { _ in }

  /// #412 review F1: source of the App's helper-restart ladder state, so the
  /// chat recovery wait can be bounded by the LADDER OUTCOME (`.unreachable`
  /// ⇒ give up now) rather than a fixed timeout chosen out of sync with the
  /// ladder cadence. Wired by RatioThinkApp to read `HelperHealthController`;
  /// the default `nil` keeps the engine-gone path + tests on prior behavior.
  /// `@MainActor` so `helperRecoveryGaveUp` can read it synchronously from the
  /// main-actor recovery wait.
  @MainActor public var helperHealthProvider: () -> HelperHealth? = { nil }

  /// On-demand engine resident-memory readout for the status popover.
  /// Forwards to the XPC client; on a transport error it returns nil to
  /// the UI (a quiet, optional readout just hides the row — never
  /// surfaces an error path or flips status) but FIRST logs the cause via
  /// `onMemoryPollError`. Without that log a wedged engine that times out
  /// this selector would be byte-identical to a healthy "engine not
  /// running" and leave no diagnostic trace; `replyTimeout` / `proxyError`
  /// are transport faults, NOT evidence the engine stopped.
  /// Deliberately NOT a `@Published` field: RSS drifts every sample, so
  /// publishing it would re-render every observer (incl. the toolbar
  /// hosting the popover) and dismiss the popover. Callers read this
  /// while the popover is open and store the result in local view state.
  public func engineMemory() async -> EngineMemorySample? {
    do {
      return try await client.engineMemory()
    } catch {
      onMemoryPollError(String(describing: error))
      return nil
    }
  }

  /// Acknowledge (dismiss) the engine failure currently surfaced by the
  /// in-window error banner. Records the failure's `signature` so the
  /// banner suppresses THIS failure but re-shows on a different one.
  /// Idempotent: re-dismissing the same signature is a no-op.
  public func acknowledgeEngineFailure(_ signature: String) {
    guard acknowledgedEngineFailureSignature != signature else { return }
    acknowledgedEngineFailureSignature = signature
  }

  /// Whether `signature` matches the most recently dismissed failure —
  /// the banner reads this to decide whether to stay hidden.
  public func isEngineFailureAcknowledged(_ signature: String) -> Bool {
    acknowledgedEngineFailureSignature == signature
  }

  /// #326: kick the helper to (re)start the engine on `profileID` —
  /// used after a fresh-install model download lands so the engine boots
  /// with the now-present model. The poll loop surfaces the live
  /// `.starting` → `.running`/`.failed` transition; this call only needs
  /// to trigger the start and report a fast refusal.
  ///
  /// The helper replies to `startEngine` only AFTER the launch handshake
  /// (which includes the model load at engine boot), so a slow start
  /// trips the App-side reply timeout. That is not a failure — the start
  /// is in flight — so `.replyTimeout` is swallowed. A real helper
  /// `EngineError` (resolver rejected, still `.modelMissing`, etc.)
  /// propagates so the UI can surface the reason.
  public func startEngine(profileID: String) async throws {
    do {
      try await client.startEngine(profileID: profileID)
    } catch let error as AppXPCClientError {
      if case .replyTimeout = error {
        Self.log.notice("startEngine(profileID=\(profileID, privacy: .public)) reply timed out — start in flight; status poll will surface the outcome")
        return
      }
      throw error
    } catch let error as EngineError where error.code == .alreadyRunning {
      // A concurrent start found the engine already starting/running.
      // For a "kick the start" caller that IS the desired end state —
      // #326's no-model prompt and failed(modelMissing) banner can both
      // fire startEngine on the same completed download, and the loser
      // must not surface a user-facing error. Idempotent no-op.
      Self.log.notice("startEngine(profileID=\(profileID, privacy: .public)) → alreadyRunning; engine already coming up (idempotent)")
      return
    }
  }

  /// Synchronous accessor for `HTTPEngineClient.baseURLProvider`.
  /// Throws `HTTPEngineError.engineNotReady` when the engine is not
  /// `.running` — the discriminator the HTTP client uses to surface
  /// "Engine starting…" rather than a generic network error. Must
  /// run on the main actor because it reads the published `status`.
  ///
  /// When the helper has reported `.failed(.engineGone, _)` (the
  /// post-launch death signal), the provider throws `.engineGone`
  /// instead of `.engineNotReady` — a semantic 503-Retry-After at the
  /// boundary. `ChatSendController` keys its recovery retry on that
  /// discrete case rather than parsing the `engineNotReady` detail.
  public func requireBaseURL() throws -> URL {
    if case .running(let port, _) = status {
      // Force-unwrap is safe: `EnginePort` (UInt16) interpolates into
      // a valid IPv4 loopback URL by construction, and the `running`
      // decoder already rejects `port == 0`.
      return URL(string: "http://127.0.0.1:\(port)")!
    }
    if case .failed(.engineGone, _) = status {
      throw HTTPEngineError.engineGone(detail: detailForStatus())
    }
    throw HTTPEngineError.engineNotReady(detail: detailForStatus())
  }

  /// One-line, human-readable summary of `status`. Used in the
  /// `engineNotReady` detail field so the UI's "Engine starting…"
  /// placeholder can carry a useful sub-line ("Helper unreachable"
  /// vs "Engine failed: spawnFailed — …").
  public var statusDetail: String { detailForStatus() }

  private func detailForStatus() -> String {
    if let lastError {
      return "Helper unreachable: \(lastError)"
    }
    switch status {
    case .stopped:
      return "Engine stopped"
    case .starting:
      return "Engine starting…"
    case .running:
      return "Engine running"
    case .stopping:
      return "Engine stopping…"
    case .failed(.memoryRisk, let message):
      return "Memory risk: \(message)"
    case .failed(.engineGone, let message):
      return "Engine stopped unexpectedly: \(message)"
    case .failed(let code, let message):
      return "Engine failed (\(code.rawValue)): \(message)"
    }
  }

  private nonisolated func refreshOnce(client: any AppXPCClient) async {
    do {
      let next = try await client.engineStatus()
      await MainActor.run { [weak self] in
        self?.apply(next: next, error: nil)
      }
    } catch {
      let message = String(describing: error)
      Self.log.error("engineStatus poll failed: \(message, privacy: .public)")
      await MainActor.run { [weak self] in
        self?.apply(next: nil, error: message)
      }
    }
  }

  private func apply(next: EngineStatus?, error: String?) {
    if let next, self.status != next {
      self.status = next
    } else if next == nil, error != nil, case .running = self.status {
      self.status = .starting
    }
    if self.lastError != error {
      self.lastError = error
    }
    pollCount &+= 1
    // #412: feed the helper-health ladder. `error == nil` ⟺ the poll
    // returned an EngineStatus (helper reachable); a non-nil error is a
    // transport failure (helper unreachable). Both the background loop's
    // success and failure paths flow through `apply`, so the ladder sees
    // every tick. Fired last so observers of `status`/`lastError` settle
    // first.
    onPollOutcome(error == nil)
  }
}
