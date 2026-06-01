import Foundation

/// The App-side bridge that lets `ChatSendController` classify a
/// chat-stream failure as an engine-death event and wait for the
/// helper's auto-relaunch ladder to bring the engine back before
/// retrying the in-flight turn.
///
/// Kept narrow on purpose: only the three questions the retry path
/// actually needs to ask. The production conformance lives on
/// `EngineStatusStore`; unit tests inject a closure-backed fake so
/// `ChatSendController` retry semantics can be exercised without
/// standing up the XPC poll loop.
@MainActor
public protocol ChatRecoveryGate: AnyObject {
  /// True iff the engine has fallen out of `.running` and into the
  /// `.failed(.engineGone)` state. The retry path uses this to filter
  /// "real engine death" from unrelated transport flakes — only the
  /// engine-gone case retries. Checked against the most-recent cached
  /// status; call `refreshStatus` first to force an out-of-cadence
  /// helper poll when classifying a fresh fault.
  var isEngineGone: Bool { get }

  /// Force one immediate helper poll so the cache reflects state
  /// changes that happened between the previous tick and now. The
  /// 1Hz background poll on `EngineStatusStore` is too coarse to
  /// classify a sub-second engine death + auto-relaunch cycle.
  func refreshStatus() async

  /// Block until either the engine is `.running` again or `timeout`
  /// elapses. Returns `true` when the engine recovered inside the
  /// budget. `ChatSendController` retries the chat turn iff `true`.
  /// Cancellation-aware so a fresher `send()` cancels the wait.
  func waitUntilRunning(timeout: TimeInterval) async -> Bool
}

@MainActor
extension EngineStatusStore: ChatRecoveryGate {
  /// `.failed(.engineGone)` is the post-launch engine-death code.
  /// `.stopped` deliberately does NOT count: that's the user-paused
  /// state, not an engine death — retrying on user-pause would silently
  /// override the user's "off" click.
  public var isEngineGone: Bool {
    if case .failed(.engineGone, _) = status { return true }
    return false
  }

  public func refreshStatus() async {
    // Swallow XPC errors here: the chat retry path only needs a
    // best-effort poll; a transport failure leaves the cached
    // `.failed(.engineGone)` (or whatever) visible to `isEngineGone`
    // and the retry surfaces normally if classification can't be
    // resolved.
    _ = try? await refresh()
  }

  public func waitUntilRunning(timeout: TimeInterval) async -> Bool {
    if case .running = status { return true }
    let deadline = Date().addingTimeInterval(timeout)
    // Poll the published status rather than installing a fresh
    // Combine sink — keeps the wait inside the XPC cadence we
    // already own and avoids an out-of-band observation surface
    // the store doesn't currently expose.
    while Date() < deadline {
      if Task.isCancelled { return false }
      if case .running = status { return true }
      let remaining = deadline.timeIntervalSinceNow
      let step = max(0.05, min(0.2, remaining))
      try? await Task.sleep(nanoseconds: UInt64(step * 1_000_000_000))
    }
    if case .running = status { return true }
    return false
  }
}
