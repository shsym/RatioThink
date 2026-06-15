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

  /// True iff the most recent helper poll's transport itself failed — the
  /// background HELPER is unreachable (it died mid-stream, vs the engine
  /// reporting `.failed(.engineGone)` over a live helper). The App-side
  /// helper-restart ladder will bring it back, so this is ALSO a
  /// wait-and-retry fault, not a surface-now one (#393/#412). `refreshStatus`
  /// records the forced poll's outcome, so this is fresh right after it.
  var isHelperUnreachable: Bool { get }

  /// True once the App's helper-restart ladder has DEFINITIVELY given up
  /// (`HelperHealth == .unreachable`). Distinct from `isHelperUnreachable`
  /// (one failed poll): this is the ladder's terminal verdict. The recovery
  /// wait early-exits on it so a helper that can't be restarted surfaces the
  /// turn in lockstep with the escalation banner instead of burning the rest
  /// of its budget (#412 review F1). Default-false for gates with no
  /// helper-health source (the engine-gone path + test fakes).
  var helperRecoveryGaveUp: Bool { get }

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

  /// `lastError` is non-nil exactly when the most recent poll's XPC transport
  /// failed — the discriminator for "the helper itself is unreachable" vs
  /// "the helper is up and reported an engine state". `refreshStatus()`
  /// records the forced poll's outcome into `lastError`, so this reflects the
  /// fresh probe, not a stale 1Hz tick.
  public var isHelperUnreachable: Bool { lastError != nil }

  /// Reads the App's helper-restart ladder state via `helperHealthProvider`
  /// (wired by RatioThinkApp to `HelperHealthController`). Nil provider — the
  /// engine-gone path and tests — reports `false`, preserving prior behavior.
  public var helperRecoveryGaveUp: Bool {
    guard let health = helperHealthProvider() else { return false }
    if case .unreachable = health { return true }
    return false
  }

  public func refreshStatus() async {
    // Record BOTH outcomes of the forced poll (unlike `refresh()`, which
    // rethrows without writing `lastError`). The chat classifier reads
    // `isEngineGone` / `isHelperUnreachable` immediately after this, and the
    // 1Hz background loop is too coarse to catch a sub-second mid-stream
    // death (#393) — so the forced poll must update both signals itself.
    await pollRecordingOutcome()
  }

  public func waitUntilRunning(timeout: TimeInterval) async -> Bool {
    if case .running = status { return true }
    // Route the deadline AND the inter-poll sleep through the store's
    // injected clock seam (`now` / `sleepFor`), so a unit test drives this
    // wait on a virtual clock with zero real wall-clock budget instead of an
    // elapsed-time assertion that flakes under scheduler load. Production
    // defaults to `Date()` + `Task.sleep`, so behaviour is unchanged.
    let deadline = now().addingTimeInterval(timeout)
    // Poll the published status rather than installing a fresh
    // Combine sink — keeps the wait inside the XPC cadence we
    // already own and avoids an out-of-band observation surface
    // the store doesn't currently expose.
    while now() < deadline {
      if Task.isCancelled { return false }
      if case .running = status { return true }
      // F1: the App's helper-restart ladder definitively gave up
      // (`.unreachable`). Recovery isn't coming — surface the turn NOW
      // rather than burn the rest of the (helper-sized) budget; the
      // escalation banner already explains it. The engine-gone path has no
      // helper-health source, so this never fires there.
      if helperRecoveryGaveUp { return false }
      let remaining = deadline.timeIntervalSince(now())
      let step = max(0.05, min(0.2, remaining))
      await sleepFor(step)
    }
    if case .running = status { return true }
    return false
  }
}
