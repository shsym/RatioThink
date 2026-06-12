import Foundation

/// Process-level evidence of one engine death, captured WITHOUT any chat
/// content. The single source of truth for #447's "distinguish the cause"
/// requirement. Pure + `Equatable` so the classifier is table-testable and
/// the breadcrumb fields are a fixed, auditable allowlist.
///
/// Privacy contract: every field is a process-level scalar (a cause label,
/// a signal number/name, an exit code, a memory figure). There is no
/// free-form prose channel that could carry a prompt, generated text, an
/// SSE token, or a request/response body. The engine's stdout/stderr tail
/// (`pie serve --debug` tracing) is captured separately, bounded, and
/// token-redacted — never the chat stream, which rides HTTP/WS and never
/// touches the engine's stdio (established in #358).
public struct EngineTermination: Equatable, Sendable {
  /// The distinguishable death classes the acceptance enumerates.
  public enum Cause: String, Sendable {
    case cleanExit          // .exit, status 0
    case nonzeroExit        // .exit, status != 0
    case crash              // uncaught fault signal (SIGABRT/SIGILL/SIGFPE/…)
    case segfault           // SIGSEGV / SIGBUS
    case killed             // SIGKILL we did NOT send, below the guardrail
    case oom                // SIGKILL we did NOT send + RSS >= guardrail (LIKELY)
    case userStop           // operator paused / unloaded
    case helperShutdown     // helper process terminating (graceful)
    case livenessFailure    // process alive but control-plane unreachable
    case handshakeTimeout   // never handshaked; WE killed an alive-but-silent engine
    case unknown
  }

  /// WHO ended the engine — taken from the call site that DETECTED the death,
  /// never inferred from a post-kill signal. Our own SIGINT/SIGKILL and a
  /// jetsam SIGKILL are indistinguishable in `terminationStatus`, so the
  /// initiator is the only reliable user-stop-vs-fault discriminator
  /// (insight:40 / PieSupervisor reaper race).
  public enum Initiator: String, Sendable {
    case user      // operator pause / unload (XPC stopEngine)
    case helper    // helper process graceful termination
    case liveness  // post-handshake liveness monitor, control-plane hang
    case launch    // failure before the launch handshake completed
    case engine    // engine exited on its own (self-death); OOM keeps this
    case unknown
  }

  public var cause: Cause
  public var initiator: Initiator
  public var signal: Int32?
  public var signalName: String?
  public var exitCode: Int32?
  public var rssBytes: UInt64?
  public var guardrailBytes: Int64?

  public init(cause: Cause, initiator: Initiator, signal: Int32? = nil,
              signalName: String? = nil, exitCode: Int32? = nil,
              rssBytes: UInt64? = nil, guardrailBytes: Int64? = nil) {
    self.cause = cause
    self.initiator = initiator
    self.signal = signal
    self.signalName = signalName
    self.exitCode = exitCode
    self.rssBytes = rssBytes
    self.guardrailBytes = guardrailBytes
  }

  /// Pure classifier. `reason`/`status` are nil only for the control-plane
  /// hang (the process is still running, so there is no exit to read). The
  /// `initiator` short-circuits the cases where WE sent the signal — those
  /// are not faults and must not be read as crash/oom even though the
  /// underlying signal is a SIGINT/SIGKILL we delivered. OOM is heuristic:
  /// a SIGKILL we did NOT send plus a last-sampled RSS at/above the #328
  /// guardrail — labelled "likely OOM" because macOS surfaces a jetsam kill
  /// indistinguishably from any external SIGKILL.
  public static func classify(reason: Process.TerminationReason?,
                              status: Int32?,
                              initiator: Initiator,
                              lastRSSBytes: UInt64?,
                              guardrailBytes: Int64?) -> EngineTermination {
    let sig: Int32? = (reason == .uncaughtSignal) ? status : nil
    let code: Int32? = (reason == .exit) ? status : nil
    let name = sig.map(signalName(_:))

    func make(_ c: Cause) -> EngineTermination {
      EngineTermination(cause: c, initiator: initiator, signal: sig,
                        signalName: name, exitCode: code,
                        rssBytes: lastRSSBytes, guardrailBytes: guardrailBytes)
    }

    // We initiated the stop — the signal is our SIGINT/SIGKILL, not a fault.
    switch initiator {
    case .user:   return make(.userStop)
    case .helper: return make(.helperShutdown)
    default:      break   // .launch / .engine / .liveness classify by reason
    }

    // No exit to read → only the post-handshake liveness monitor reaches here
    // with a still-alive process (control-plane hang). Any other initiator
    // arriving without a reason is an indeterminate state, not a hang.
    guard let reason else {
      return make(initiator == .liveness ? .livenessFailure : .unknown)
    }

    switch reason {
    case .exit:
      return make(status == 0 ? .cleanExit : .nonzeroExit)
    case .uncaughtSignal:
      switch status {
      case SIGSEGV, SIGBUS:
        return make(.segfault)
      case SIGKILL:
        if let rss = lastRSSBytes, let cap = guardrailBytes, cap > 0,
           rss >= UInt64(cap) { return make(.oom) }
        return make(.killed)
      default:
        return make(.crash)
      }
    @unknown default:
      return make(.unknown)
    }
  }

  /// Minimal libc-signal → name map for the signals an engine death can
  /// plausibly carry. Unknown numbers render as `signal-<N>` so the field
  /// is always populated.
  public static func signalName(_ s: Int32) -> String {
    switch s {
    case SIGILL:  return "SIGILL"
    case SIGABRT: return "SIGABRT"
    case SIGFPE:  return "SIGFPE"
    case SIGBUS:  return "SIGBUS"
    case SIGSEGV: return "SIGSEGV"
    case SIGKILL: return "SIGKILL"
    case SIGTERM: return "SIGTERM"
    case SIGINT:  return "SIGINT"
    default:      return "signal-\(s)"
    }
  }

  /// Breadcrumb fields — process-level scalars ONLY (auditable allowlist:
  /// cause, initiator, signal, name, code, rss_mb, guardrail_mb). No
  /// free-form prose channel that could carry chat content.
  public var diagnosticFields: [(String, String)] {
    var f: [(String, String)] = [("cause", cause.rawValue),
                                  ("initiator", initiator.rawValue)]
    if let signal { f.append(("signal", String(signal))) }
    if let signalName { f.append(("name", signalName)) }
    if let exitCode { f.append(("code", String(exitCode))) }
    if let rssBytes { f.append(("rss_mb", String(rssBytes / (1024 * 1024)))) }
    if let guardrailBytes { f.append(("guardrail_mb", String(guardrailBytes / (1024 * 1024)))) }
    return f
  }
}
