import Foundation
import os

/// App-side, async wrapper around `NSXPCConnection` to the helper's
/// `PieHelperXPC` interface. Exposes the selectors the GUI drives:
/// `engineStatus()` (derives `HTTPEngineClient.baseURL`), `stopEngine()`
/// (Unload), and `startEngine(profileID:)` (#326 fresh-install
/// auto-start). The remaining `PieHelperXPC` selectors (loadModel,
/// downloadModel, …) are still reached via direct `NSXPCConnection` use
/// in their own subsystems; they get folded behind this client only when
/// a GUI caller needs them, keeping the surface narrow.
///
/// Two construction modes mirror `HelperXPCListener`:
///   · `.machService(name)` — production. Default name comes from
///     `HelperConfig.xpcServiceName` so dev/test overrides flow
///     through automatically.
///   · `.listenerEndpoint(endpoint)` — same-process integration tests.
///     Pairs with `HelperXPCListener.startAnonymous()` for an
///     SPM-runnable XPC round-trip without launchd.
///
/// The connection is created lazily on first call and re-created on
/// invalidation/interruption. Each `engineStatus()` call resumes a
/// `CheckedContinuation` from exactly one of two paths — the proxy's
/// `errorHandler` or the reply block — guarded by an unfair-lock
/// "once" flag because `NSXPCConnection` may legally fire the
/// errorHandler AFTER a successful reply when the peer tears down
/// (the same pattern `HelperMain.verifyMachServicePublished` uses).
public protocol AppXPCClient: Sendable {
  func helperProtocolVersion() async throws -> Int
  func engineStatus() async throws -> EngineStatus
  /// Stop the running engine ( Unload). Resolves on acceptance;
  /// throws the helper-side `EngineError` when the stop is rejected, or
  /// an `AppXPCClientError` on transport failure.
  func stopEngine() async throws
  /// Resident memory of the running engine, or nil when not running /
  /// unavailable. Read on demand while the status popover is open; never
  /// polled into a published field.
  func engineMemory() async throws -> EngineMemorySample?
  /// Start (resolve + launch) the engine on `profileID`. Resolves on a
  /// successful launch handshake; throws the helper-side `EngineError`
  /// when the start is rejected (e.g. `.modelMissing`, `.profileMissing`),
  /// or an `AppXPCClientError` on transport failure. Driven by #326's
  /// fresh-install auto-start.
  func startEngine(profileID: String) async throws
  /// Strict restart for active-profile default-model changes. Unlike
  /// `startEngine(profileID:)`, `.alreadyRunning` is a failure signal:
  /// the helper did not complete a stop→start registry rebuild.
  func restartEngine(profileID: String) async throws
  /// #448: ask the helper to stop the engine and terminate itself as the
  /// final step of a coordinated full-product quit. Resolves on acceptance;
  /// throws the helper-side `EngineError` on refusal or an
  /// `AppXPCClientError` on transport failure. The helper may exit before
  /// the reply flushes, so a post-call connection invalidation is normal —
  /// the App-side coordinator treats any outcome as "helper is quitting" and
  /// proceeds to terminate.
  func quitHelper() async throws
}

public extension AppXPCClient {
  /// Default: memory unavailable. Test stubs that don't model the
  /// engineMemory selector inherit nil and need no change.
  func engineMemory() async throws -> EngineMemorySample? { nil }

  /// Default: no helper to quit. Test stubs and the helperless DEBUG
  /// harness inherit this no-op; only the production `HelperXPCClient`
  /// drives the real `quitHelper` selector.
  func quitHelper() async throws {}
}

public enum HelperProtocolCompatibility {
  /// Version 1: pre-capability helpers. Version 2: helper exports the
  /// strict `restartEngine(profileID:)` selector required by active
  /// default-model changes.
  public static let currentVersion = 2

  public static func isCompatible(client: any AppXPCClient) async -> Bool {
    do {
      return try await client.helperProtocolVersion() >= currentVersion
    } catch {
      return false
    }
  }
}

public enum AppXPCClientError: Error, Sendable, CustomStringConvertible {
  /// `remoteObjectProxyWithErrorHandler` returned an object the
  /// runtime did not bridge to `PieHelperXPC`. Indicates a serious
  /// interface drift, not a transient network failure.
  case proxyTypeMismatch
  /// `NSXPCConnection.errorHandler` fired. Carries the underlying
  /// `NSError` so the caller can route on `NSXPCConnectionInvalid` /
  /// `NSXPCConnectionInterrupted` if it cares.
  case proxyError(NSError)
  /// `XPCPayload.decode(EngineStatus.self, …)` threw. Helper-side
  /// `wireContractViolation` bytes land here, as does any forward-
  /// incompatible wire shape.
  case decode(NSError)
  /// The helper accepted the selector but did not invoke the reply
  /// block before the app-side deadline. The client invalidates the
  /// connection after this error so polling can reopen a fresh one.
  case replyTimeout(selector: String, timeout: TimeInterval)

  public var description: String {
    switch self {
    case .proxyTypeMismatch:
      return "remoteObjectProxy did not conform to PieHelperXPC"
    case .proxyError(let err):
      return "NSXPCConnection error: \(err)"
    case .decode(let err):
      return "XPC reply decode failed: \(err)"
    case .replyTimeout(let selector, let timeout):
      return "\(selector) timed out after \(timeout)s"
    }
  }
}

public final class HelperXPCClient: AppXPCClient, @unchecked Sendable {
  public enum Endpoint {
    case machService(String)
    case listenerEndpoint(NSXPCListenerEndpoint)
  }

  private let endpoint: Endpoint
  private let interface: NSXPCInterface
  private let replyTimeout: TimeInterval
  private let restartReplyTimeout: TimeInterval
  /// Persistent connection. `nil` means "not yet opened" or "torn
  /// down by invalidation/interruption — recreate on next call."
  private let connectionLock = OSAllocatedUnfairLock<NSXPCConnection?>(initialState: nil)
  private static let log = Logger(subsystem: "com.ratiothink.app", category: "xpc.client")

  public init(endpoint: Endpoint,
              replyTimeout: TimeInterval = 2.0,
              restartReplyTimeout: TimeInterval = 85.0) {
    self.endpoint = endpoint
    self.interface = PieHelperXPCInterface.make()
    self.replyTimeout = replyTimeout
    self.restartReplyTimeout = restartReplyTimeout
  }

  /// Default-construct against the helper's resolved mach service.
  /// Convenience for `RatioThinkApp.init` so the call site does not need to
  /// know about `HelperConfig` plumbing.
  public convenience init() {
    self.init(endpoint: .machService(HelperConfig.xpcServiceName))
  }

  public func engineStatus() async throws -> EngineStatus {
    let connection = ensureConnection()
    do {
      return try await engineStatus(on: connection)
    } catch let error as AppXPCClientError {
      if case .replyTimeout = error {
        invalidateIfCurrent(connection)
      }
      throw error
    }
  }

  public func helperIdentity() async throws -> HelperIdentity {
    let connection = ensureConnection()
    do {
      return try await helperIdentity(on: connection)
    } catch let error as AppXPCClientError {
      if case .replyTimeout = error {
        invalidateIfCurrent(connection)
      }
      throw error
    }
  }

  private func helperIdentity(on connection: NSXPCConnection) async throws -> HelperIdentity {
    let timeout = replyTimeout
    return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<HelperIdentity, Error>) in
      let resumed = OSAllocatedUnfairLock<Bool>(initialState: false)
      func resumeOnce(_ result: Result<HelperIdentity, Error>) {
        let shouldResume = resumed.withLock { fired -> Bool in
          if fired { return false }
          fired = true
          return true
        }
        guard shouldResume else { return }
        switch result {
        case .success(let identity): continuation.resume(returning: identity)
        case .failure(let error): continuation.resume(throwing: error)
        }
      }
      if timeout > 0 {
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + timeout) {
          resumeOnce(.failure(AppXPCClientError.replyTimeout(
            selector: "helperIdentity",
            timeout: timeout
          )))
        }
      }
      let proxy = connection.remoteObjectProxyWithErrorHandler { err in
        resumeOnce(.failure(AppXPCClientError.proxyError(err as NSError)))
      }
      guard let api = proxy as? PieHelperXPC else {
        resumeOnce(.failure(AppXPCClientError.proxyTypeMismatch))
        return
      }
      guard let helperIdentity = api.helperIdentity else {
        resumeOnce(.failure(AppXPCClientError.proxyTypeMismatch))
        return
      }
      helperIdentity { data in
        do {
          let identity = try XPCPayload.decode(HelperIdentity.self, from: data)
          resumeOnce(.success(identity))
        } catch {
          resumeOnce(.failure(AppXPCClientError.decode(error as NSError)))
        }
      }
    }
  }

  public func helperProtocolVersion() async throws -> Int {
    let connection = ensureConnection()
    do {
      return try await helperProtocolVersion(on: connection)
    } catch let error as AppXPCClientError {
      if case .replyTimeout = error {
        invalidateIfCurrent(connection)
      }
      throw error
    }
  }

  private func helperProtocolVersion(on connection: NSXPCConnection) async throws -> Int {
    let timeout = replyTimeout
    return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Int, Error>) in
      let resumed = OSAllocatedUnfairLock<Bool>(initialState: false)
      func resumeOnce(_ result: Result<Int, Error>) {
        let shouldResume = resumed.withLock { fired -> Bool in
          if fired { return false }
          fired = true
          return true
        }
        guard shouldResume else { return }
        switch result {
        case .success(let version): continuation.resume(returning: version)
        case .failure(let error): continuation.resume(throwing: error)
        }
      }
      if timeout > 0 {
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + timeout) {
          resumeOnce(.failure(AppXPCClientError.replyTimeout(
            selector: "helperProtocolVersion",
            timeout: timeout
          )))
        }
      }
      let proxy = connection.remoteObjectProxyWithErrorHandler { err in
        resumeOnce(.failure(AppXPCClientError.proxyError(err as NSError)))
      }
      guard let api = proxy as? PieHelperXPC else {
        resumeOnce(.failure(AppXPCClientError.proxyTypeMismatch))
        return
      }
      api.helperProtocolVersion { data in
        do {
          let version = try XPCPayload.decode(Int.self, from: data)
          resumeOnce(.success(version))
        } catch {
          resumeOnce(.failure(AppXPCClientError.decode(error as NSError)))
        }
      }
    }
  }

  private func engineStatus(on connection: NSXPCConnection) async throws -> EngineStatus {
    let timeout = replyTimeout
    return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<EngineStatus, Error>) in
      let resumed = OSAllocatedUnfairLock<Bool>(initialState: false)
      func resumeOnce(_ result: Result<EngineStatus, Error>) {
        let shouldResume = resumed.withLock { fired -> Bool in
          if fired { return false }
          fired = true
          return true
        }
        guard shouldResume else { return }
        switch result {
        case .success(let s): continuation.resume(returning: s)
        case .failure(let e): continuation.resume(throwing: e)
        }
      }
      if timeout > 0 {
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + timeout) {
          resumeOnce(.failure(AppXPCClientError.replyTimeout(
            selector: "engineStatus",
            timeout: timeout
          )))
        }
      }
      let proxy = connection.remoteObjectProxyWithErrorHandler { err in
        resumeOnce(.failure(AppXPCClientError.proxyError(err as NSError)))
      }
      guard let api = proxy as? PieHelperXPC else {
        resumeOnce(.failure(AppXPCClientError.proxyTypeMismatch))
        return
      }
      api.engineStatus { data in
        do {
          let status = try XPCPayload.decode(EngineStatus.self, from: data)
          resumeOnce(.success(status))
        } catch {
          resumeOnce(.failure(AppXPCClientError.decode(error as NSError)))
        }
      }
    }
  }

  public func stopEngine() async throws {
    let connection = ensureConnection()
    do {
      try await stopEngine(on: connection)
    } catch let error as AppXPCClientError {
      if case .replyTimeout = error {
        invalidateIfCurrent(connection)
      }
      throw error
    }
  }

  private func stopEngine(on connection: NSXPCConnection) async throws {
    let timeout = replyTimeout
    try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
      let resumed = OSAllocatedUnfairLock<Bool>(initialState: false)
      func resumeOnce(_ result: Result<Void, Error>) {
        let shouldResume = resumed.withLock { fired -> Bool in
          if fired { return false }
          fired = true
          return true
        }
        guard shouldResume else { return }
        switch result {
        case .success: continuation.resume(returning: ())
        case .failure(let e): continuation.resume(throwing: e)
        }
      }
      if timeout > 0 {
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + timeout) {
          resumeOnce(.failure(AppXPCClientError.replyTimeout(
            selector: "stopEngine",
            timeout: timeout
          )))
        }
      }
      let proxy = connection.remoteObjectProxyWithErrorHandler { err in
        resumeOnce(.failure(AppXPCClientError.proxyError(err as NSError)))
      }
      guard let api = proxy as? PieHelperXPC else {
        resumeOnce(.failure(AppXPCClientError.proxyTypeMismatch))
        return
      }
      api.stopEngine { errorData in
        // Contract (PieHelperXPC): nil = accepted; non-nil decodes to
        // the helper-side EngineError describing why the stop was
        // refused. Surface that error verbatim so the caller can decide
        // whether to keep the resident-model state.
        guard let errorData else {
          resumeOnce(.success(()))
          return
        }
        do {
          let engineError = try XPCPayload.decode(EngineError.self, from: errorData)
          resumeOnce(.failure(engineError))
        } catch {
          resumeOnce(.failure(AppXPCClientError.decode(error as NSError)))
        }
      }
    }
  }

  /// #448: drive the `quitHelper` selector. Uses a dedicated, longer
  /// deadline than the shared 2s `replyTimeout` because the helper stops +
  /// reaps the engine (worst case the `LaunchedSession` SIGINT→SIGKILL
  /// grace) before replying. A healthy engine stops in well under a second;
  /// the bound exists only so a wedged engine can't hang the App's quit.
  static let quitReplyTimeout: TimeInterval =
    HelperExportedAPI.stopReplyDeadline + HelperExportedAPI.replyTimeoutSlack

  public func quitHelper() async throws {
    let connection = ensureConnection()
    do {
      try await quitHelper(on: connection)
    } catch let error as AppXPCClientError {
      if case .replyTimeout = error {
        invalidateIfCurrent(connection)
      }
      throw error
    }
  }

  private func quitHelper(on connection: NSXPCConnection) async throws {
    let timeout = Self.quitReplyTimeout
    try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
      let resumed = OSAllocatedUnfairLock<Bool>(initialState: false)
      func resumeOnce(_ result: Result<Void, Error>) {
        let shouldResume = resumed.withLock { fired -> Bool in
          if fired { return false }
          fired = true
          return true
        }
        guard shouldResume else { return }
        switch result {
        case .success: continuation.resume(returning: ())
        case .failure(let e): continuation.resume(throwing: e)
        }
      }
      if timeout > 0 {
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + timeout) {
          resumeOnce(.failure(AppXPCClientError.replyTimeout(
            selector: "quitHelper",
            timeout: timeout
          )))
        }
      }
      let proxy = connection.remoteObjectProxyWithErrorHandler { err in
        // The helper terminating mid-reply surfaces here as
        // NSXPCConnectionInvalid — for quitHelper that IS the success path
        // (helper exited), but the App-side coordinator ignores the outcome
        // and terminates regardless, so reporting it as proxyError is fine.
        resumeOnce(.failure(AppXPCClientError.proxyError(err as NSError)))
      }
      guard let api = proxy as? PieHelperXPC else {
        resumeOnce(.failure(AppXPCClientError.proxyTypeMismatch))
        return
      }
      api.quitHelper { errorData in
        guard let errorData else {
          resumeOnce(.success(()))
          return
        }
        do {
          let engineError = try XPCPayload.decode(EngineError.self, from: errorData)
          resumeOnce(.failure(engineError))
        } catch {
          resumeOnce(.failure(AppXPCClientError.decode(error as NSError)))
        }
      }
    }
  }

  public func startEngine(profileID: String) async throws {
    let connection = ensureConnection()
    do {
      try await startEngine(profileID: profileID, on: connection)
    } catch let error as AppXPCClientError {
      if case .replyTimeout = error {
        invalidateIfCurrent(connection)
      }
      throw error
    }
  }

  private func startEngine(profileID: String, on connection: NSXPCConnection) async throws {
    let timeout = replyTimeout
    try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
      let resumed = OSAllocatedUnfairLock<Bool>(initialState: false)
      func resumeOnce(_ result: Result<Void, Error>) {
        let shouldResume = resumed.withLock { fired -> Bool in
          if fired { return false }
          fired = true
          return true
        }
        guard shouldResume else { return }
        switch result {
        case .success: continuation.resume(returning: ())
        case .failure(let e): continuation.resume(throwing: e)
        }
      }
      if timeout > 0 {
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + timeout) {
          resumeOnce(.failure(AppXPCClientError.replyTimeout(
            selector: "startEngine",
            timeout: timeout
          )))
        }
      }
      let proxy = connection.remoteObjectProxyWithErrorHandler { err in
        resumeOnce(.failure(AppXPCClientError.proxyError(err as NSError)))
      }
      guard let api = proxy as? PieHelperXPC else {
        resumeOnce(.failure(AppXPCClientError.proxyTypeMismatch))
        return
      }
      api.startEngine(profileID: profileID) { successData, errorData in
        // Contract (PieHelperXPC): exactly one of (successData=EnginePort,
        // errorData=EngineError) is non-nil. We discard the port — the
        // caller relies on the engine-status poll for the live `.running`
        // signal; the wrapper only needs to surface a refusal. A
        // wire-contract violation decodes to EngineError(.wireContractViolation).
        do {
          switch try PieHelperXPCWire.decodeStartEngineReply(
            successData: successData, errorData: errorData
          ) {
          case .success:
            resumeOnce(.success(()))
          case .failure(let engineError):
            resumeOnce(.failure(engineError))
          }
        } catch {
          resumeOnce(.failure(error))
        }
      }
    }
  }

  public func restartEngine(profileID: String) async throws {
    let connection = ensureConnection()
    do {
      try await restartEngine(profileID: profileID, on: connection)
    } catch let error as AppXPCClientError {
      if case .replyTimeout = error {
        invalidateIfCurrent(connection)
      }
      throw error
    }
  }

  private func restartEngine(profileID: String, on connection: NSXPCConnection) async throws {
    let timeout = restartReplyTimeout
    try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
      let resumed = OSAllocatedUnfairLock<Bool>(initialState: false)
      func resumeOnce(_ result: Result<Void, Error>) {
        let shouldResume = resumed.withLock { fired -> Bool in
          if fired { return false }
          fired = true
          return true
        }
        guard shouldResume else { return }
        switch result {
        case .success: continuation.resume(returning: ())
        case .failure(let e): continuation.resume(throwing: e)
        }
      }
      if timeout > 0 {
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + timeout) {
          resumeOnce(.failure(AppXPCClientError.replyTimeout(
            selector: "restartEngine",
            timeout: timeout
          )))
        }
      }
      let proxy = connection.remoteObjectProxyWithErrorHandler { err in
        resumeOnce(.failure(AppXPCClientError.proxyError(err as NSError)))
      }
      guard let api = proxy as? PieHelperXPC else {
        resumeOnce(.failure(AppXPCClientError.proxyTypeMismatch))
        return
      }
      api.restartEngine(profileID: profileID) { successData, errorData in
        do {
          switch try PieHelperXPCWire.decodeStartEngineReply(
            successData: successData, errorData: errorData
          ) {
          case .success:
            resumeOnce(.success(()))
          case .failure(let engineError):
            resumeOnce(.failure(engineError))
          }
        } catch {
          resumeOnce(.failure(error))
        }
      }
    }
  }

  /// Test-only seam: drop the live connection so the next selector
  /// call reopens it. Production code does not need this — the
  /// invalidation/interruption handlers do the same thing reactively.
  public func _resetConnectionForTesting() {
    connectionLock.withLock { conn in
      conn?.invalidate()
      conn = nil
    }
  }

  private func ensureConnection() -> NSXPCConnection {
    connectionLock.withLock { conn in
      if let c = conn { return c }
      let new: NSXPCConnection
      switch endpoint {
      case .machService(let name):
        new = NSXPCConnection(machServiceName: name)
      case .listenerEndpoint(let ep):
        new = NSXPCConnection(listenerEndpoint: ep)
      }
      new.remoteObjectInterface = interface
      new.invalidationHandler = { [weak self] in
        Self.log.info("xpc client: connection invalidated; will reopen on next call")
        self?.connectionLock.withLock { $0 = nil }
      }
      new.interruptionHandler = { [weak self] in
        Self.log.info("xpc client: connection interrupted; will reopen on next call")
        self?.connectionLock.withLock { $0 = nil }
      }
      new.resume()
      conn = new
      return new
    }
  }

  private func invalidateIfCurrent(_ connection: NSXPCConnection) {
    connectionLock.withLock { conn in
      guard conn === connection else { return }
      conn?.invalidate()
      conn = nil
    }
  }

  public func engineMemory() async throws -> EngineMemorySample? {
    let connection = ensureConnection()
    do {
      return try await engineMemory(on: connection)
    } catch let error as AppXPCClientError {
      if case .replyTimeout = error {
        invalidateIfCurrent(connection)
      }
      throw error
    }
  }

  private func engineMemory(on connection: NSXPCConnection) async throws -> EngineMemorySample? {
    let timeout = replyTimeout
    return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<EngineMemorySample?, Error>) in
      let resumed = OSAllocatedUnfairLock<Bool>(initialState: false)
      func resumeOnce(_ result: Result<EngineMemorySample?, Error>) {
        let shouldResume = resumed.withLock { fired -> Bool in
          if fired { return false }
          fired = true
          return true
        }
        guard shouldResume else { return }
        switch result {
        case .success(let s): continuation.resume(returning: s)
        case .failure(let e): continuation.resume(throwing: e)
        }
      }
      if timeout > 0 {
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + timeout) {
          resumeOnce(.failure(AppXPCClientError.replyTimeout(
            selector: "engineMemory",
            timeout: timeout
          )))
        }
      }
      let proxy = connection.remoteObjectProxyWithErrorHandler { err in
        resumeOnce(.failure(AppXPCClientError.proxyError(err as NSError)))
      }
      guard let api = proxy as? PieHelperXPC else {
        resumeOnce(.failure(AppXPCClientError.proxyTypeMismatch))
        return
      }
      api.engineMemory { data in
        do {
          let sample = try XPCPayload.decode(EngineMemorySample?.self, from: data)
          resumeOnce(.success(sample))
        } catch {
          resumeOnce(.failure(AppXPCClientError.decode(error as NSError)))
        }
      }
    }
  }
}
