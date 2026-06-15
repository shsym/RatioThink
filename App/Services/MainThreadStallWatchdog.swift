import Foundation
import QuartzCore
import SwiftUI

/// DEBUG-only main-thread responsiveness probe for GUI stress tests (#530).
///
/// A repeating timer scheduled on the **main** run loop in `.common` modes
/// records, on every fire, how late it ran relative to its nominal interval —
/// i.e. how long the main thread was busy and unable to service the run loop.
/// The worst gap observed is the published `maxStallMilliseconds` and is mirrored
/// to a probe file the GUI guard reads.
///
/// This is the instrument behind the rapid-chat-switching guard: the pre-#521
/// transcript pattern (sort `chat.messages` several times per body evaluation +
/// render `@Model Message` rows directly in the SwiftUI identity/layout hot
/// path) stalls the main thread while a long transcript lays out, so a storm of
/// chat switches produces a large `maxStallMilliseconds`. The post-#521 snapshot
/// path keeps each switch cheap, so the worst stall stays near normal frame
/// pacing.
///
/// The probe is reported through a file (`PIE_TEST_STALL_WATCHDOG_FILE`) rather
/// than the accessibility tree because a deliberately-invisible SwiftUI element
/// is pruned from the AX hierarchy by AppKit, while a file read is deterministic
/// and exactly mirrors how the deterministic GUI suites already exchange data
/// with the app under test (e.g. the resume request log).
///
/// The timer itself does no main-thread I/O and touches only an in-memory `Int`,
/// so it does not perturb the measurement it takes — the file write happens off
/// the main thread and only on the rare frames where a new worst stall is seen.
/// The whole type compiles into DEBUG builds only; a shipped Release app never
/// schedules it.
@MainActor
final class MainThreadStallWatchdog: ObservableObject {
  /// Worst observed main-thread scheduling delay, in milliseconds, since
  /// `start()`. Monotonically non-decreasing.
  @Published private(set) var maxStallMilliseconds: Int = 0
  /// Cumulative main-thread stall time (ms) — the sum of every frame's overrun
  /// beyond one nominal interval. Unlike `max`, this captures *sustained*
  /// churn: a pattern that pays a little extra on every switch (the #521 repeated
  /// @Model sort / identity work) diverges here even when no single frame
  /// produces a record-worst stall.
  private(set) var totalStallMilliseconds: Int = 0
  /// Number of frames whose overrun exceeded `stallCountThresholdMs` — a count
  /// of "janky" frames, robust to outliers in either tail.
  private(set) var stallCount: Int = 0
  private static let stallCountThresholdMs = 50

  private let interval: TimeInterval
  private let fileURL: URL?
  private var timer: Timer?
  private var lastFire: CFTimeInterval = 0

  /// `interval` is the nominal main-loop sampling period; 60 Hz matches the
  /// display refresh so a frame that lands on time records a ~0 ms gap and only
  /// a genuinely overrun frame registers a stall. The probe file path comes from
  /// `PIE_TEST_STALL_WATCHDOG_FILE`.
  init(interval: TimeInterval = 1.0 / 60.0) {
    self.interval = interval
    if let path = ProcessInfo.processInfo.environment["PIE_TEST_STALL_WATCHDOG_FILE"],
       !path.isEmpty {
      self.fileURL = URL(fileURLWithPath: path)
    } else {
      self.fileURL = nil
    }
  }

  /// Begin sampling. Idempotent — a second call is a no-op so a re-`onAppear`
  /// (e.g. a window re-key) never installs a second timer. Writes the initial
  /// `0` so the guard always finds the file even if no stall ever registers.
  func start() {
    guard timer == nil else { return }
    writeProbe()
    lastFire = CACurrentMediaTime()
    // `.common` modes so the timer keeps firing during scroll/menu tracking
    // run-loop modes — exactly the windows where a layout stall would hide
    // from a default-mode-only timer.
    let timer = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
      MainActor.assumeIsolated { self?.tick() }
    }
    RunLoop.main.add(timer, forMode: .common)
    self.timer = timer
  }

  func stop() {
    timer?.invalidate()
    timer = nil
  }

  private func tick() {
    let now = CACurrentMediaTime()
    // How much later than scheduled this fire ran: total elapsed minus the one
    // nominal interval we expected. A blocked main thread defers the fire, so
    // the overshoot is the stall duration.
    let stallSeconds = (now - lastFire) - interval
    lastFire = now
    guard stallSeconds > 0 else { return }
    let stallMs = Int((stallSeconds * 1000).rounded())
    totalStallMilliseconds += stallMs
    var changed = false
    if stallMs > maxStallMilliseconds {
      maxStallMilliseconds = stallMs
      changed = true
    }
    if stallMs >= Self.stallCountThresholdMs {
      stallCount += 1
      changed = true
    }
    // Total always grows; flush at most ~10×/s to bound write churn.
    if changed || now - lastWrite > 0.1 {
      lastWrite = now
      writeProbe()
    }
  }

  private var lastWrite: CFTimeInterval = 0

  /// Mirror the three metrics to the probe file off the main thread as
  /// `max,total,count` so the write never perturbs the measurement.
  private func writeProbe() {
    guard let fileURL else { return }
    let payload = "\(maxStallMilliseconds),\(totalStallMilliseconds),\(stallCount)"
    DispatchQueue.global(qos: .utility).async {
      try? payload.write(to: fileURL, atomically: true, encoding: .utf8)
    }
  }
}

#if DEBUG
/// DEBUG-only zero-footprint view that starts the watchdog when
/// `PIE_TEST_STALL_WATCHDOG=1`. The worst stall is reported through the probe
/// file (see `MainThreadStallWatchdog`), not the view, so this renders nothing.
struct StallWatchdogIndicator: View {
  @ObservedObject var watchdog: MainThreadStallWatchdog

  private static let enabled =
    ProcessInfo.processInfo.environment["PIE_TEST_STALL_WATCHDOG"] == "1"

  var body: some View {
    Color.clear
      .frame(width: 0, height: 0)
      .onAppear { if Self.enabled { watchdog.start() } }
  }
}
#endif
