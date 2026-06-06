import Foundation

/// Shared Helper-side quit policy for both the XPC `quitHelper` selector and
/// the App-absent menu-bar "Quit RatioThink" fallback. The first phase waits
/// for the real terminal/reaped status. If that deadline expires, callers get
/// an observable timeout callback, then a second bounded grace window starts.
/// The Helper terminates when either the engine reaches terminal during that
/// second stage OR the second watchdog expires, so a wedged reap cannot leave
/// the Helper running indefinitely after the App has gone away.
public enum HelperQuitTeardown {
  public static let timeoutTerminationGrace: TimeInterval = 2

  public static func stopThenTerminate(
    engineHost: PieEngineHost,
    initialTimeout: TimeInterval,
    timeoutTerminationGrace: TimeInterval = Self.timeoutTerminationGrace,
    onTerminalBeforeTimeout: @escaping @Sendable (StopAndWaitResult) -> Void = { _ in },
    onTimeout: @escaping @Sendable (StopAndWaitResult) -> Void = { _ in },
    onFinalTimeout: @escaping @Sendable (StopAndWaitResult) -> Void = { _ in },
    terminate: @escaping @Sendable () -> Void
  ) {
    engineHost.stopAndWait(timeout: initialTimeout) { [weak engineHost] firstResult in
      guard !firstResult.reachedTerminal else {
        onTerminalBeforeTimeout(firstResult)
        terminate()
        return
      }

      onTimeout(firstResult)
      guard let engineHost else {
        terminate()
        return
      }

      engineHost.stopAndWait(timeout: timeoutTerminationGrace) { secondResult in
        if !secondResult.reachedTerminal {
          onFinalTimeout(secondResult)
        }
        terminate()
      }
    }
  }
}
