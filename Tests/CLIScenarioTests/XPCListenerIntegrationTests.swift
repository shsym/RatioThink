import XCTest
import Foundation
@testable import RatioThinkCore

/// Integration test for Phase 2.1: stand up a real `HelperXPCListener`,
/// open an `NSXPCConnection` to its endpoint, call `engineStatus()`,
/// assert the decoded `EngineStatus` is `.stopped`.
///
/// Cross-process scope (originally: "spawn helper subprocess,
/// connect, call engineStatus()") is **not** reachable from SPM:
///   · `NSXPCConnection` only consumes mach-service names or live
///     `NSXPCListenerEndpoint` instances.
///   · A mach-service name not registered with launchd cannot be
///     resolved by a peer process (`bootstrap_look_up` returns "No
///     such process") — confirmed empirically. Production helpers
///     register via SMAppService.loginItem at install time; SPM tests
///     run under `PIE_TEST_MODE=1`, which gates SMAppService off.
///   · `NSXPCListenerEndpoint` conforms to `NSSecureCoding` only via
///     `NSXPCCoder`. `NSKeyedArchiver` raises
///     "This class may only be encoded by an NSXPCCoder" — so the
///     endpoint cannot be serialized to disk, env, or stdout for a
///     child to read.
///
/// The cross-process subprocess test belongs in RatioThinkGUITests (Phase 8 /
/// installer) where SMAppService.loginItem can stand up a real mach
/// service. This test exercises the full XPC pipeline — listener
/// delegate, identity-bypass under test mode, exported interface +
/// object, `engineStatus` selector, reply data round-trip — in-process,
/// which is the largest credible scope under `swift test`.
///
/// Inherits `IsolatedTestCase` so `HelperConfig.assertStartupContract`
/// in `startAnonymous()` runs against a fresh
/// `(PIE_XPC_SERVICE=com.ratiothink.helper.test.<uuid>, testMode=true)` pair
/// per test.
final class XPCListenerIntegrationTests: IsolatedTestCase {
  func testEngineStatusRoundtrip() async throws {
    let listenerOwner = HelperXPCListener.startAnonymous()
    let endpoint = listenerOwner.endpoint
    let connection = NSXPCConnection(listenerEndpoint: endpoint)
    connection.remoteObjectInterface = PieHelperXPCInterface.make()
    connection.resume()
    defer { connection.invalidate() }

    let proxy = connection.remoteObjectProxyWithErrorHandler { err in
      XCTFail("xpc proxy error: \(err)")
    }
    guard let api = proxy as? PieHelperXPC else {
      XCTFail("remote object proxy does not conform to PieHelperXPC")
      return
    }

    let replyData = try await callEngineStatus(api: api, timeout: 5)
    let status = try XPCPayload.decode(EngineStatus.self, from: replyData)
    XCTAssertEqual(status, .stopped,
                   "Phase 2.1 helper should reply `.stopped` until PieSupervisor lands in Phase 2.2")
  }

  /// Identity check is bypassed under `PIE_TEST_MODE=1`. Assert the
  /// bypass reason carries the test-mode marker rather than the DEBUG
  /// fallback — protects against a future refactor that accidentally
  /// reorders the checks and lets DEBUG suppression mask a broken
  /// test-mode path.
  func testIdentityBypassReasonUnderTestMode() {
    XCTAssertEqual(CallerIdentity.bypassReason(), "PIE_TEST_MODE=1")
  }

  /// `HelperXPCListener.invalidate()` tears the underlying
  /// `NSXPCListener` down so a peer that opens a fresh connection
  /// AFTER the invalidate sees a `errorHandler` callback (not a
  /// reply, not a timeout). Invalidate IS observable as the
  /// connection-invalidation NSCocoaError — treating a 3s timeout as
  /// success let a no-op-invalidate regression coincide with CI load
  /// and still pass (review v3 F2). A 30s window is generous for any
  /// genuine latency; timeout here is unambiguously a regression.
  func testInvalidateTearsDownListener() async throws {
    let listenerOwner = HelperXPCListener.startAnonymous()
    let endpoint = listenerOwner.endpoint
    listenerOwner.invalidate()

    let connection = NSXPCConnection(listenerEndpoint: endpoint)
    connection.remoteObjectInterface = PieHelperXPCInterface.make()
    connection.resume()
    defer { connection.invalidate() }

    let outcome = try await withCheckedThrowingContinuation {
      (cont: CheckedContinuation<InvalidateOutcome, Error>) in
      let resumed = ResumedOnceFlag()
      let timer = DispatchSource.makeTimerSource(queue: .global())
      timer.schedule(deadline: .now() + 30)
      timer.setEventHandler {
        if resumed.markIfPending() {
          cont.resume(returning: .timedOut)
        }
      }
      timer.resume()
      let proxy = connection.remoteObjectProxyWithErrorHandler { _ in
        timer.cancel()
        if resumed.markIfPending() { cont.resume(returning: .errored) }
      }
      (proxy as? PieHelperXPC)?.engineStatus { _ in
        timer.cancel()
        if resumed.markIfPending() { cont.resume(returning: .replied) }
      }
    }
    // Timeout is a regression — invalidate must produce an
    // error callback within the window. Reply means invalidate is a
    // no-op. Only .errored is healthy.
    XCTAssertEqual(outcome, .errored,
                   "invalidated listener must fire errorHandler within 30s — got \(outcome)")
  }

  /// `invalidate()` is idempotent — a second call must not crash.
  func testInvalidateIsIdempotent() {
    let listenerOwner = HelperXPCListener.startAnonymous()
    listenerOwner.invalidate()
    listenerOwner.invalidate()
  }

  /// `setExportedObject` swaps the per-listener exported object so
  /// future connections see the new shape (review v3 F1 + F3). Two
  /// connections opened sequentially before and after the swap
  /// observe the matching exported object — proves the swap is
  /// effective on the live listener WITHOUT a mach-service rebind.
  /// This is the supported `transitionToDegraded` mechanism.
  func testExportedObjectSwapAffectsNewConnections() async throws {
    let listenerOwner = HelperXPCListener.startAnonymous()
    let endpoint = listenerOwner.endpoint

    func engineStatus(via owner: HelperXPCListener) async throws -> EngineStatus {
      let connection = NSXPCConnection(listenerEndpoint: endpoint)
      connection.remoteObjectInterface = PieHelperXPCInterface.make()
      connection.resume()
      defer { connection.invalidate() }
      let proxy = connection.remoteObjectProxyWithErrorHandler { err in
        XCTFail("proxy error: \(err)")
      }
      guard let api = proxy as? PieHelperXPC else {
        throw IntegrationError.unexpectedReply
      }
      let data = try await callEngineStatus(api: api, timeout: 5)
      return try XPCPayload.decode(EngineStatus.self, from: data)
    }

    let pre = try await engineStatus(via: listenerOwner)
    XCTAssertEqual(pre, .stopped, "default exported object should reply .stopped")

    let reasonMessage = "test: swap to degraded"
    listenerOwner.setExportedObject(DegradedHelperAPI(reasonMessage: reasonMessage))

    let post = try await engineStatus(via: listenerOwner)
    switch post {
    case let .failed(code, message):
      XCTAssertEqual(code, .degraded, "swap must take effect — expected .degraded, got code=\(code)")
      XCTAssertTrue(message.contains(reasonMessage),
                    "swap reason must propagate to peer — got message=\(message)")
    default:
      XCTFail("post-swap connection must observe DegradedHelperAPI's .failed(.degraded, …); got \(post)")
    }
  }

  /// Force the listener to skip the captured-bypass and run the live
  /// identity check (review v1 F14). Same-process peer in an
  /// ad-hoc-signed test bundle has no Team Identifier, so the
  /// `teamIDAbsent` rejection path fires and the proxy errors with a
  /// connection-invalidated NSCocoaError instead of returning a
  /// reply. Verifies the production rejection branch is reachable —
  /// not only the bypass branch the happy-path test covers.
  func testProductionIdentityRejectsAdhocSignedPeer() async throws {
    let listenerOwner = HelperXPCListener._startAnonymousForcingIdentityCheck()
    let endpoint = listenerOwner.endpoint
    let connection = NSXPCConnection(listenerEndpoint: endpoint)
    connection.remoteObjectInterface = PieHelperXPCInterface.make()
    connection.resume()
    defer { connection.invalidate() }

    let proxyError = try await withCheckedThrowingContinuation {
      (cont: CheckedContinuation<Error, Error>) in
      let resumed = ResumedOnceFlag()
      let timer = DispatchSource.makeTimerSource(queue: .global())
      timer.schedule(deadline: .now() + 5)
      timer.setEventHandler {
        if resumed.markIfPending() {
          cont.resume(throwing: IntegrationError.replyTimeout(timeout: 5))
        }
      }
      timer.resume()

      let proxy = connection.remoteObjectProxyWithErrorHandler { err in
        timer.cancel()
        if resumed.markIfPending() {
          cont.resume(returning: err)
        }
      }
      // Triggering any selector forces NSXPC to attempt the
      // connection. The rejection happens server-side and surfaces
      // on the client as an invalidation error in `errorHandler`.
      (proxy as? PieHelperXPC)?.engineStatus { _ in
        // Reply path: should NOT fire in the rejection case. If it
        // does, the timer will still race the resumption; the test
        // assertion below catches the wrong-branch outcome.
        timer.cancel()
        if resumed.markIfPending() {
          cont.resume(throwing: IntegrationError.unexpectedReply)
        }
      }
    }
    let nsErr = proxyError as NSError
    XCTAssertEqual(nsErr.domain, NSCocoaErrorDomain,
                   "expected NSCocoaErrorDomain from a server-side rejection, got \(nsErr.domain)")
    // Server-side `shouldAcceptNewConnection: false` surfaces on the
    // client as one of: NSXPCConnectionInvalid (init lookup), or
    // NSXPCConnectionInterrupted (post-accept tear-down). Either is
    // acceptable evidence that the connection did NOT serve a reply.
    let acceptable: Set<Int> = [NSXPCConnectionInvalid, NSXPCConnectionInterrupted]
    XCTAssertTrue(acceptable.contains(nsErr.code),
                  "expected NSXPCConnectionInvalid/Interrupted, got \(nsErr.code) — domain=\(nsErr.domain)")
  }

  /// Upgrade guard for PR #63 Review v2 F1. An app updated in place can
  /// still be talking to the previous build's helper: `engineStatus`
  /// answers, but the new strict restart selector is absent. The
  /// launch/runtime registration reconcile must not classify that helper
  /// as compatible, or the first active-profile model change strands the
  /// restart path until a manual helper restart.
  func testOldHelperThatAnswersEngineStatusButLacksRestartIsIncompatible() async throws {
    let old = OldHelperXPCListener()
    let client = HelperXPCClient(
      endpoint: .listenerEndpoint(old.endpoint),
      replyTimeout: 0.2,
      restartReplyTimeout: 0.2
    )

    let status = try await client.engineStatus()
    XCTAssertEqual(status, .stopped,
                   "fixture must model the old-but-reachable helper: engineStatus still works")

    let compatible = await HelperProtocolCompatibility.isCompatible(client: client)
    XCTAssertFalse(compatible,
                   "reachable old helper without restartEngine/capability selector must trigger registration repair")
  }

  // MARK: - helpers

  /// Async-bridge over the callback-based `engineStatus(reply:)`. Times
  /// out after `timeout` to keep a wedged helper from blocking the
  /// suite.
  private func callEngineStatus(api: PieHelperXPC, timeout: TimeInterval) async throws -> Data {
    try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Data, Error>) in
      let resumedFlag = ResumedOnceFlag()
      let timer = DispatchSource.makeTimerSource(queue: .global())
      timer.schedule(deadline: .now() + timeout)
      timer.setEventHandler {
        if resumedFlag.markIfPending() {
          cont.resume(throwing: IntegrationError.replyTimeout(timeout: timeout))
        }
      }
      timer.resume()

      api.engineStatus { data in
        timer.cancel()
        if resumedFlag.markIfPending() {
          cont.resume(returning: data)
        }
      }
    }
  }
}

@objc(OldRatioThinkHelperXPCForCompatibilityTest)
private protocol OldRatioThinkHelperXPCForCompatibilityTest {
  func engineStatus(reply: @escaping (Data) -> Void)
}

private final class OldHelperExportedObject: NSObject, OldRatioThinkHelperXPCForCompatibilityTest {
  func engineStatus(reply: @escaping (Data) -> Void) {
    reply((try? XPCPayload.encode(EngineStatus.stopped)) ?? Data())
  }
}

private final class OldHelperXPCListener: NSObject, NSXPCListenerDelegate {
  private let listener: NSXPCListener
  private let exported = OldHelperExportedObject()
  var endpoint: NSXPCListenerEndpoint { listener.endpoint }

  override init() {
    self.listener = .anonymous()
    super.init()
    listener.delegate = self
    listener.resume()
  }

  func listener(_ listener: NSXPCListener,
                shouldAcceptNewConnection newConnection: NSXPCConnection) -> Bool {
    newConnection.exportedInterface = NSXPCInterface(with: OldRatioThinkHelperXPCForCompatibilityTest.self)
    newConnection.exportedObject = exported
    newConnection.resume()
    return true
  }

  deinit { listener.invalidate() }
}

/// One-shot flag so the timer race vs reply race never double-resumes
/// the continuation (which would crash with a CheckedContinuation
/// trap). Lock-based, not atomic — contention is two callers max.
private final class ResumedOnceFlag {
  private var resumed = false
  private let lock = NSLock()
  func markIfPending() -> Bool {
    lock.lock()
    defer { lock.unlock() }
    if resumed { return false }
    resumed = true
    return true
  }
}

private enum InvalidateOutcome: Equatable {
  case replied
  case errored
  case timedOut
}

private enum IntegrationError: Error, CustomStringConvertible {
  case replyTimeout(timeout: TimeInterval)
  case unexpectedReply

  var description: String {
    switch self {
    case let .replyTimeout(timeout):
      return "engineStatus reply did not arrive within \(timeout)s"
    case .unexpectedReply:
      return "engineStatus reply arrived on a path that expected a rejection"
    }
  }
}
