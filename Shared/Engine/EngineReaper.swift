import Darwin
import Foundation

/// — OS-enforced single-owner teardown for the `pie` engine process.
///
/// INVARIANT: no `pie` process may outlive its owning Helper. The Helper spawns
/// `pie` as a plain `Process` child; on a clean quit `applicationWillTerminate`
/// reaps it, but SIGKILL / fatal-signal crashes / `exit(_:)` skip that hook and
/// — because `pie` is a plain child, not a launchd-tracked job member — the
/// launchd agent does NOT reap it (it reparents to launchd and survives). That
/// is the orphan class this type closes BY CONSTRUCTION rather than by a
/// startup kill-all sweep:
///
///  · `own(pid:pgid:)` records the live engine in a signal-safe slot the moment
///    it is spawned, and persists it to a durable file (`engine.pid`).
///  · `install()` arms `atexit` + fatal-signal handlers so EVERY catchable exit
///    path (crash, `exit`, abort) reaps the recorded engine before the Helper
///    dies — the PRIMARY reap-on-exit mechanism.
///  · `reapStaleOwnedProcess()` is the BACKSTOP for the one uncatchable case,
///    SIGKILL: the next Helper launch reads `engine.pid` and, after verifying
///    the pid still maps to the `pie` binary (so a recycled pid is never an
///    innocent victim), kills it. Targeted — never a blanket "kill all pies".
///  · `release()` clears both slots on a clean reap so neither path double-kills.
///
/// The signal-safe state is two file-scope `Int32`s touched only by an aligned
/// load + `kill`/`killpg` (both async-signal-safe). `install()` writes them once
/// up front so no handler ever triggers Swift's lazy global initialization.
public enum EngineReaper {

  // MARK: - signal-safe owned-process slots

  /// Owned engine pid (0 = none). Plain aligned `Int32`: the handler does a
  /// single load + `kill`, both async-signal-safe.
  nonisolated(unsafe) static var ownedPID: Int32 = 0
  /// Owned engine process-group id (0 = none / not its own group). Non-zero
  /// ONLY when `setpgid` made `pie` its own group leader, so `killpg` can never
  /// hit the Helper's group.
  nonisolated(unsafe) static var ownedPGID: Int32 = 0

  // MARK: - durable owner record

  /// `<applicationSupport>/engine.pid` — survives a Helper crash so the next
  /// launch's backstop can find and reap a SIGKILL-orphaned engine.
  public static func pidFileURL() -> URL? {
    (try? PieDirs.applicationSupport())?.appendingPathComponent("engine.pid")
  }

  // MARK: - ownership transitions

  /// Record `pid` (and its own process group, if `setpgid` succeeded) as the
  /// owned engine. Called by the launcher immediately after spawn. Writes the
  /// signal-safe slots first (so a fatal signal during persistence still
  /// reaps), then the durable file.
  public static func own(pid: Int32, pgid: Int32, binaryPath: String) {
    ownedPID = pid
    ownedPGID = pgid
    guard let url = pidFileURL() else { return }
    // "pid pgid binaryPath" — binaryPath lets the backstop verify identity
    // before killing a possibly-recycled pid.
    let line = "\(pid) \(pgid) \(binaryPath)\n"
    try? line.data(using: .utf8)?.write(to: url, options: .atomic)
  }

  /// Clear ownership on a clean reap so neither the exit handler nor the
  /// next-launch backstop kills an already-dead (or recycled) pid.
  public static func release() {
    ownedPID = 0
    ownedPGID = 0
    if let url = pidFileURL() { try? FileManager.default.removeItem(at: url) }
  }

  // MARK: - reap primitives

  /// Reap the currently-owned engine NOW (group first, then pid). Async-signal
  /// safe: only `killpg`/`kill`. Used by the fatal-signal/atexit handlers.
  static func reapOwnedNow() {
    let pgid = ownedPGID
    if pgid > 0 { _ = killpg(pgid, SIGKILL) }
    let pid = ownedPID
    if pid > 0 { _ = kill(pid, SIGKILL) }
  }

  // MARK: - install (Helper startup)

  nonisolated(unsafe) private static var installed = false

  /// Arm the reap-on-exit handlers. Idempotent; call once at Helper startup.
  /// Eagerly writes the signal-safe slots so the handlers never lazy-init a
  /// Swift global. Fatal-signal handlers chain to the default disposition after
  /// reaping so the Helper still crashes with its true signal (correct exit
  /// status, crash report intact).
  public static func install() {
    guard !installed else { return }
    installed = true
    // Force eager initialization of the slots before any handler can fire — a
    // read triggers Swift's one-time global init, so the handler never does.
    _ = ownedPID
    _ = ownedPGID

    atexit { EngineReaper.reapOwnedNow() }

    // Catchable fatal signals: reap, then re-raise with the default handler so
    // the process dies with its real signal. SIGKILL/SIGSTOP are intentionally
    // absent (uncatchable) — the next-launch backstop covers SIGKILL.
    for sig in [SIGTERM, SIGINT, SIGHUP, SIGQUIT, SIGSEGV, SIGABRT, SIGILL, SIGBUS, SIGFPE] {
      signal(sig) { received in
        EngineReaper.reapOwnedNow()
        signal(received, SIG_DFL)
        raise(received)
      }
    }
  }

  // MARK: - backstop (next launch)

  /// BACKSTOP: read the durable `engine.pid` and reap a SIGKILL-orphaned engine
  /// from a prior Helper incarnation, BUT only after confirming the pid still
  /// maps to `expectedBinaryPath` (guards against pid reuse). Returns the pid it
  /// reaped, or nil. Targeted — it kills exactly the one recorded pid, never a
  /// scan of all `pie` processes.
  @discardableResult
  public static func reapStaleOwnedProcess(
    expectedBinaryPath: String? = nil,
    isAlive: (Int32) -> Bool = EngineReaper.processIsAlive,
    pathOf: (Int32) -> String? = EngineReaper.executablePath
  ) -> Int32? {
    guard let url = pidFileURL(),
          let raw = try? String(contentsOf: url, encoding: .utf8) else { return nil }
    let fields = raw.split(separator: " ", maxSplits: 2).map(String.init)
    guard let first = fields.first, let pid = Int32(first), pid > 0 else {
      try? FileManager.default.removeItem(at: url)
      return nil
    }
    let pgid = fields.count > 1 ? Int32(fields[1]) ?? 0 : 0
    let recordedPath = fields.count > 2
      ? fields[2].trimmingCharacters(in: .whitespacesAndNewlines) : nil

    defer { try? FileManager.default.removeItem(at: url) }

    guard isAlive(pid) else { return nil }
    // Identity gate: the live pid must still be the pie binary we recorded.
    // A recycled pid (different executable) is left untouched.
    let expected = expectedBinaryPath ?? recordedPath
    if let expected, let actual = pathOf(pid), actual != expected { return nil }

    if pgid > 0 { _ = killpg(pgid, SIGKILL) }
    _ = kill(pid, SIGKILL)
    return pid
  }

  // MARK: - identity helpers

  /// True if `pid` names a live process (signal 0 probe).
  public static func processIsAlive(_ pid: Int32) -> Bool {
    kill(pid, 0) == 0 || errno == EPERM
  }

  /// Absolute executable path of `pid`, or nil if it cannot be resolved.
  public static func executablePath(_ pid: Int32) -> String? {
    var buf = [CChar](repeating: 0, count: Int(MAXPATHLEN))
    let n = proc_pidpath(pid, &buf, UInt32(buf.count))
    return n > 0 ? String(cString: buf) : nil
  }
}
