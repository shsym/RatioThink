import Foundation

/// Shared Helper-side quit policy for both the XPC `quitHelper` selector and
/// the App-absent menu-bar "Quit Rational" fallback. Normal quit terminates
/// the Helper only after the engine reaches a real terminal/reaped status. If
/// that deadline expires, callers get an observable timeout callback and the
/// Helper remains alive so it still owns the engine session for retry or an
/// explicit force-quit path.
public enum HelperQuitTeardown {
  public static func stopThenTerminate(
    engineHost: PieEngineHost,
    initialTimeout: TimeInterval,
    onTerminalBeforeTimeout: @escaping @Sendable (StopAndWaitResult) -> Void = { _ in },
    onTerminalFailure: @escaping @Sendable (StopAndWaitResult) -> Void = { _ in },
    onTimeout: @escaping @Sendable (StopAndWaitResult) -> Void = { _ in },
    terminate: @escaping @Sendable () -> Void
  ) {
    engineHost.stopAndWait(timeout: initialTimeout) { firstResult in
      if firstResult.reachedTerminal {
        onTerminalBeforeTimeout(firstResult)
        terminate()
        return
      }
      if firstResult.failedBeforeReap {
        onTerminalFailure(firstResult)
        return
      }

      onTimeout(firstResult)
    }
  }
}
