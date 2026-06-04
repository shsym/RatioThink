import XCTest
import Foundation
@testable import RatioThinkCore

/// Integration coverage for `EngineStatusStore` driving a real
/// `HelperXPCClient` against a same-process `HelperXPCListener`
/// anonymous endpoint. Pairs with the unit coverage in
/// `EngineStatusStoreTests` — those drive transitions through a stub
/// XPC client; this one exercises the wire path including
/// `XPCPayload.decode(EngineStatus.self, …)`.
///
/// Cross-process scope (real helper subprocess registered via launchd)
/// is **not** reachable here — see the long comment on
/// `XPCListenerIntegrationTests` for why. `NSXPCListenerEndpoint`
/// cannot cross process boundaries via any public API, so the
/// anonymous-listener pattern is the largest credible scope under
/// `swift test`.
///
/// Inherits `IsolatedTestCase` so `HelperConfig.assertStartupContract`
/// in `startAnonymous()` resolves against a fresh
/// `(PIE_XPC_SERVICE=com.ratiothink.helper.test.<uuid>, testMode=true)` pair.
final class EngineStatusStoreIntegrationTests: IsolatedTestCase {

  /// Plugs `HelperXPCClient` straight into the anonymous endpoint
  /// `HelperXPCListener.startAnonymous` publishes — same code path
  /// the production app uses with `.machService(name)`, just bound
  /// in-process.
  func test_engineStatusStore_observes_running_after_helper_signals_running() async throws {
    // Single mutable exported object — connection identity is sticky
    // (see `HelperXPCListener.setExportedObject` doc), so the live
    // store's connection retains its initial reference. Mutating the
    // exported object's ivar is the path that mirrors the production
    // helper, where `PieSupervisor` flips its internal state and the
    // same `HelperExportedAPI` instance reflects the new value.
    let exported = FixedStatusExportedObject(initial: .stopped)
    let listenerOwner = HelperXPCListener.startAnonymous(exportedObject: exported)
    defer { listenerOwner.invalidate() }

    let client = HelperXPCClient(
      endpoint: .listenerEndpoint(listenerOwner.endpoint)
    )

    let store = await MainActor.run { EngineStatusStore(client: client) }
    let initial = try await store.refresh()
    XCTAssertEqual(initial, .stopped)
    let baseURLBefore = await MainActor.run { store.baseURL }
    XCTAssertNil(baseURLBefore,
                 ".stopped must not synthesize a baseURL")

    // Helper transitions to running; the store's next refresh picks
    // it up via the same connection.
    exported.setStatus(.running(port: 51234, profileID: "chat"))
    let next = try await store.refresh()
    XCTAssertEqual(next, .running(port: 51234, profileID: "chat"))
    let baseURLAfter = await MainActor.run { store.baseURL }
    XCTAssertEqual(baseURLAfter, URL(string: "http://127.0.0.1:51234"))
  }

  /// Confirms `HelperXPCClient.engineStatus()` decodes the same wire
  /// shape the helper-side encoder produces. A drift between the
  /// `XPCPayload` config used by `HelperExportedAPI` and the one the
  /// client uses would surface here as `.decode(...)` rather than the
  /// expected `.running` reply.
  func test_helperXPCClient_decodes_running_status() async throws {
    let listenerOwner = HelperXPCListener.startAnonymous(
      exportedObject: FixedStatusExportedObject(
        initial: .running(port: 65535, profileID: "default")
      )
    )
    defer { listenerOwner.invalidate() }

    let client = HelperXPCClient(
      endpoint: .listenerEndpoint(listenerOwner.endpoint)
    )
    let status = try await client.engineStatus()
    XCTAssertEqual(status, .running(port: 65535, profileID: "default"))
  }

  func test_helperXPCClient_engineStatus_timesOut_when_helper_never_replies() async throws {
    let listenerOwner = HelperXPCListener.startAnonymous(
      exportedObject: NeverReplyStatusExportedObject()
    )
    defer { listenerOwner.invalidate() }

    let client = HelperXPCClient(
      endpoint: .listenerEndpoint(listenerOwner.endpoint),
      replyTimeout: 0.05
    )

    let start = Date()
    do {
      _ = try await client.engineStatus()
      XCTFail("expected engineStatus timeout")
    } catch AppXPCClientError.replyTimeout(let selector, let timeout) {
      XCTAssertEqual(selector, "engineStatus")
      XCTAssertEqual(timeout, 0.05, accuracy: 0.001)
      XCTAssertLessThan(Date().timeIntervalSince(start), 1.0)
    } catch {
      XCTFail("expected replyTimeout, got \(error)")
    }
  }

  func test_helperXPCClient_recovers_after_timeout_by_reopening_connection() async throws {
    let listenerOwner = HelperXPCListener.startAnonymous(
      exportedObject: NeverReplyStatusExportedObject()
    )
    defer { listenerOwner.invalidate() }

    let client = HelperXPCClient(
      endpoint: .listenerEndpoint(listenerOwner.endpoint),
      replyTimeout: 0.05
    )

    do {
      _ = try await client.engineStatus()
      XCTFail("expected initial timeout")
    } catch AppXPCClientError.replyTimeout {
      // expected
    } catch {
      XCTFail("expected replyTimeout, got \(error)")
    }

    listenerOwner.setExportedObject(FixedStatusExportedObject(
      initial: .running(port: 51235, profileID: "chat")
    ))

    let recovered = try await client.engineStatus()
    XCTAssertEqual(recovered, .running(port: 51235, profileID: "chat"))
  }
}

/// Minimal `PieHelperXPC` that swaps a `currentStatus` ivar atomically
/// and replies with the encoded value on every `engineStatus` call.
/// All other selectors return `wireContractViolation` to avoid
/// accidental coverage of selectors out of scope for this suite.
private final class FixedStatusExportedObject: NSObject, PieHelperXPC, @unchecked Sendable {
  private let lock = NSLock()
  private var currentStatus: EngineStatus

  init(initial: EngineStatus) {
    self.currentStatus = initial
    super.init()
  }

  func setStatus(_ s: EngineStatus) { lock.withLock { currentStatus = s } }

  func engineStatus(reply: @escaping (Data) -> Void) {
    let s = lock.withLock { currentStatus }
    do {
      reply(try XPCPayload.encode(s))
    } catch {
      reply(PieHelperXPCWire.fallbackReplyEncodeFailureData)
    }
  }

  func engineMemory(reply: @escaping (Data) -> Void) {
    reply((try? XPCPayload.encode(Optional<EngineMemorySample>.none)) ?? Data("null".utf8))
  }

  func startEngine(profileID: String,
                   reply: @escaping (Data?, Data?) -> Void) {
    PieHelperXPCWire.replyStartEngine(
      .failure(EngineError(code: .wireContractViolation,
                           message: "FixedStatusExportedObject is read-only")),
      via: reply
    )
  }

  func stopEngine(reply: @escaping (Data?) -> Void) { reply(nil) }

  func loadModel(modelID: String,
                 reply: @escaping (Data?, Data?) -> Void) {
    PieHelperXPCWire.replyLoadModel(
      .failure(EngineError(code: .wireContractViolation,
                           message: "FixedStatusExportedObject is read-only")),
      via: reply
    )
  }

  func cancelLoad(handle: Data, reply: @escaping (Data?) -> Void) { reply(nil) }

  func downloadModel(repo: String, file: String,
                     reply: @escaping (Data?, Data?) -> Void) {
    PieHelperXPCWire.replyDownloadModel(
      .failure(EngineError(code: .wireContractViolation,
                           message: "FixedStatusExportedObject is read-only")),
      via: reply
    )
  }

  func cancelDownload(handle: Data, reply: @escaping (Data?) -> Void) { reply(nil) }

  func listProfiles(reply: @escaping (Data) -> Void) {
    let empty: [String] = []
    reply((try? XPCPayload.encode(empty)) ?? Data("[]".utf8))
  }

  func reloadProfiles(reply: @escaping (Data?) -> Void) { reply(nil) }

  func tailLog(stream: String,
               reply: @escaping (FileHandle?, Data?) -> Void) {
    PieHelperXPCWire.replyTailLog(
      .failure(EngineError(code: .wireContractViolation,
                           message: "FixedStatusExportedObject does not vend logs")),
      via: reply
    )
  }

  func clearKillRejected(reply: @escaping (Data?) -> Void) { reply(nil) }
}

private final class NeverReplyStatusExportedObject: NSObject, PieHelperXPC, @unchecked Sendable {
  func engineStatus(reply: @escaping (Data) -> Void) {
    // Intentionally do not call reply. This simulates a helper that accepted
    // the XPC message but wedged before producing a response.
  }

  func engineMemory(reply: @escaping (Data) -> Void) {
    // Wedged: intentionally never replies, like engineStatus above.
  }

  func startEngine(profileID: String,
                   reply: @escaping (Data?, Data?) -> Void) {}

  func stopEngine(reply: @escaping (Data?) -> Void) {}

  func loadModel(modelID: String,
                 reply: @escaping (Data?, Data?) -> Void) {}

  func cancelLoad(handle: Data, reply: @escaping (Data?) -> Void) {}

  func downloadModel(repo: String, file: String,
                     reply: @escaping (Data?, Data?) -> Void) {}

  func cancelDownload(handle: Data, reply: @escaping (Data?) -> Void) {}

  func listProfiles(reply: @escaping (Data) -> Void) {}

  func reloadProfiles(reply: @escaping (Data?) -> Void) {}

  func tailLog(stream: String,
               reply: @escaping (FileHandle?, Data?) -> Void) {}

  func clearKillRejected(reply: @escaping (Data?) -> Void) {}
}
