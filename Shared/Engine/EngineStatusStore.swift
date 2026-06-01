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
  @Published public private(set) var pollCount: UInt64 = 0

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

  ///  Unload: ask the helper to stop the running engine, freeing the
  /// resident model's RAM. Throws on rejection / transport failure so
  /// the caller keeps the resident-model state when the stop did not
  /// actually happen. The next status poll reflects the stopped engine.
  public func stopEngine() async throws {
    try await client.stopEngine()
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
  }
}
