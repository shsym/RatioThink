# KV Usage Tracking Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build authoritative global KV usage snapshots from pie `model_status`, surface them through Helper/XPC to the App, and add honest request-local per-chat attribution state.

**Architecture:** Global pages come from pie's existing WebSocket control-plane `query(subject: "model_status")`, parsed into typed `KVUsageSnapshot` rows and bridged Helper → App over XPC. Per-chat attribution is an in-memory request-local tracker wired into `ChatSendController`; it marks active/destroyed request-local records but never claims inactive resident KV pages.

**Tech Stack:** Swift 5.10, SwiftPM/XCTest, Foundation JSON/XPC, SwiftData chat models, existing `PieControlClient`, `PieEngineHost`, `HelperExportedAPI`, and `ChatSendController`.

---

## File structure

- Create `Shared/Engine/KVUsageSnapshot.swift`
  - Owns `KVUsageSnapshot`, `KVUsageSource`, `KVUsageModelStatusParser`, and parser error types.
- Create `Tests/RatioThinkCoreTests/KVUsageSnapshotTests.swift`
  - Pure parser tests for `model_status` JSON.
- Modify `Shared/Engine/PieEngineHost.swift`
  - Extend `EngineSession` with `modelStatusJSON() async throws -> String?` defaulting to nil.
  - Add `kvUsageSnapshots(now:) async throws -> [KVUsageSnapshot]` that gates on `.running`, queries the session, parses, and stamps a generation.
- Modify `Shared/Engine/PieControlLauncher.swift`
  - Implement `LaunchedSession.modelStatusJSON()` using the retained `controlWSURL`, `PieControlClient.authIdentify`, and `PieControlClient.query(subject: "model_status")`.
- Create `Tests/RatioThinkCoreTests/PieEngineHostKVUsageTests.swift`
  - Fake-session tests for running/stopped, parser propagation, and generation increment.
- Modify `Shared/XPC/PieHelperXPC.swift`
  - Add selector `kvUsage(reply:)` and `PieHelperXPCWire.replyKVUsage/decodeKVUsageReply` helpers.
- Modify `Shared/XPC/HelperExportedAPI.swift`
  - Implement the selector by calling `engineHost.kvUsageSnapshots()` and replying with typed result.
  - Implement degraded/no-host behavior explicitly.
- Modify `Shared/XPC/AppXPCClient.swift`
  - Add `kvUsageSnapshots() async throws -> [KVUsageSnapshot]` to `AppXPCClient` and `HelperXPCClient`.
- Modify `Tests/Unit/XPCProtocolTests.swift`
  - Pin the new Objective-C selector and wire helper round trips.
- Create `Tests/RatioThinkCoreTests/HelperExportedAPIKVUsageTests.swift`
  - Drive the helper selector using fake sessions.
- Create `Shared/Engine/ContextUsageRecord.swift`
  - Owns `ContextUsageRecord`, `ContextUsageID`, `ContextResidency`, `ContextPageUsage`, and `ContextUsageTracker`.
- Create `Tests/RatioThinkCoreTests/ContextUsageTrackerTests.swift`
  - Pure tests for active/destroyed/stale identity behavior.
- Modify `Shared/Persistence/ChatSendController.swift`
  - Add optional tracker injection to `send`, generate a request ID, and mark request-local active/destroyed transitions on finish/cancel/error/supersede.
- Modify `Tests/RatioThinkCoreTests/ChatSendControllerTests.swift`
  - Verify per-chat attribution state transitions without adding any resident-page claim.

---

### Task 1: Typed `model_status` parser

**Files:**
- Create: `Shared/Engine/KVUsageSnapshot.swift`
- Create: `Tests/RatioThinkCoreTests/KVUsageSnapshotTests.swift`

- [ ] **Step 1: Write failing parser tests**

Add `Tests/RatioThinkCoreTests/KVUsageSnapshotTests.swift`:

```swift
import XCTest
@testable import RatioThinkCore

final class KVUsageSnapshotTests: XCTestCase {
  func test_parseModelStatus_decodesKVRowsAndIgnoresInferenceCounters() throws {
    let json = #"{"default.kv_pages_used":3,"default.kv_pages_total":256,"default.total_batches":9}"#
    let snapshots = try KVUsageModelStatusParser.parse(
      json,
      observedAt: Date(timeIntervalSince1970: 10),
      generation: 7
    )
    XCTAssertEqual(snapshots, [
      KVUsageSnapshot(
        modelID: "default",
        pagesUsed: 3,
        pagesTotal: 256,
        observedAt: Date(timeIntervalSince1970: 10),
        generation: 7,
        source: .pieModelStatus
      )
    ])
  }

  func test_parseModelStatus_handlesModelIDsContainingDotsBySuffixMatching() throws {
    let json = #"{"org.model.v1.kv_pages_used":11,"org.model.v1.kv_pages_total":1024}"#
    let snapshots = try KVUsageModelStatusParser.parse(
      json,
      observedAt: Date(timeIntervalSince1970: 20),
      generation: 2
    )
    XCTAssertEqual(snapshots.map(\.modelID), ["org.model.v1"])
    XCTAssertEqual(snapshots.first?.pagesUsed, 11)
    XCTAssertEqual(snapshots.first?.pagesTotal, 1024)
  }

  func test_parseModelStatus_missingTotalDoesNotFabricateZero() throws {
    let json = #"{"default.kv_pages_used":5}"#
    let snapshots = try KVUsageModelStatusParser.parse(
      json,
      observedAt: Date(timeIntervalSince1970: 30),
      generation: 1
    )
    XCTAssertTrue(snapshots.isEmpty, "incomplete rows must be omitted, not decoded as total=0")
  }

  func test_parseModelStatus_rejectsNegativeAndWrongTypeValues() {
    XCTAssertThrowsError(try KVUsageModelStatusParser.parse(
      #"{"default.kv_pages_used":-1,"default.kv_pages_total":256}"#,
      observedAt: Date(),
      generation: 1
    ))
    XCTAssertThrowsError(try KVUsageModelStatusParser.parse(
      #"{"default.kv_pages_used":"1","default.kv_pages_total":256}"#,
      observedAt: Date(),
      generation: 1
    ))
  }

  func test_parseModelStatus_rejectsNonJSONObject() {
    XCTAssertThrowsError(try KVUsageModelStatusParser.parse(
      #"["not", "an", "object"]"#,
      observedAt: Date(),
      generation: 1
    ))
  }
}
```

- [ ] **Step 2: Run test to verify RED**

Run:

```bash
swift test --filter KVUsageSnapshotTests
```

Expected: compile fails because `KVUsageSnapshot` and `KVUsageModelStatusParser` do not exist.

- [ ] **Step 3: Implement minimal parser**

Create `Shared/Engine/KVUsageSnapshot.swift`:

```swift
import Foundation

public struct KVUsageSnapshot: Codable, Equatable, Sendable {
  public let modelID: String
  public let pagesUsed: UInt64
  public let pagesTotal: UInt64
  public let observedAt: Date
  public let generation: UInt64
  public let source: KVUsageSource

  public init(modelID: String,
              pagesUsed: UInt64,
              pagesTotal: UInt64,
              observedAt: Date,
              generation: UInt64,
              source: KVUsageSource) {
    self.modelID = modelID
    self.pagesUsed = pagesUsed
    self.pagesTotal = pagesTotal
    self.observedAt = observedAt
    self.generation = generation
    self.source = source
  }
}

public enum KVUsageSource: String, Codable, Equatable, Sendable {
  case pieModelStatus
}

public enum KVUsageModelStatusParser {
  public enum ParseError: Error, Equatable, Sendable, CustomStringConvertible {
    case notJSONObject
    case invalidCounter(key: String)

    public var description: String {
      switch self {
      case .notJSONObject:
        return "model_status result was not a JSON object"
      case .invalidCounter(let key):
        return "model_status counter '\(key)' was not a non-negative integer"
      }
    }
  }

  private struct PartialRow {
    var used: UInt64?
    var total: UInt64?
  }

  public static func parse(_ json: String,
                           observedAt: Date,
                           generation: UInt64) throws -> [KVUsageSnapshot] {
    let data = Data(json.utf8)
    let object = try JSONSerialization.jsonObject(with: data)
    guard let map = object as? [String: Any] else {
      throw ParseError.notJSONObject
    }

    var rows: [String: PartialRow] = [:]
    for (key, value) in map {
      if key.hasSuffix(".kv_pages_used") {
        let model = String(key.dropLast(".kv_pages_used".count))
        var row = rows[model, default: PartialRow()]
        row.used = try uint64(value, key: key)
        rows[model] = row
      } else if key.hasSuffix(".kv_pages_total") {
        let model = String(key.dropLast(".kv_pages_total".count))
        var row = rows[model, default: PartialRow()]
        row.total = try uint64(value, key: key)
        rows[model] = row
      }
    }

    return rows.compactMap { modelID, row in
      guard let used = row.used, let total = row.total else { return nil }
      return KVUsageSnapshot(
        modelID: modelID,
        pagesUsed: used,
        pagesTotal: total,
        observedAt: observedAt,
        generation: generation,
        source: .pieModelStatus
      )
    }
    .sorted { $0.modelID < $1.modelID }
  }

  private static func uint64(_ value: Any, key: String) throws -> UInt64 {
    if let number = value as? NSNumber {
      let double = number.doubleValue
      guard double >= 0,
            double.rounded(.towardZero) == double,
            double <= Double(UInt64.max) else {
        throw ParseError.invalidCounter(key: key)
      }
      return number.uint64Value
    }
    throw ParseError.invalidCounter(key: key)
  }
}
```

- [ ] **Step 4: Run parser tests for GREEN**

Run:

```bash
swift test --filter KVUsageSnapshotTests
```

Expected: all `KVUsageSnapshotTests` pass.

- [ ] **Step 5: Commit parser**

```bash
git add Shared/Engine/KVUsageSnapshot.swift Tests/RatioThinkCoreTests/KVUsageSnapshotTests.swift
git commit -m "Add KV usage model_status parser"
```

---

### Task 2: Query model_status through the running engine session

**Files:**
- Modify: `Shared/Engine/PieEngineHost.swift`
- Modify: `Shared/Engine/PieControlLauncher.swift`
- Create: `Tests/RatioThinkCoreTests/PieEngineHostKVUsageTests.swift`

- [ ] **Step 1: Write failing host/session tests**

Create `Tests/RatioThinkCoreTests/PieEngineHostKVUsageTests.swift`:

```swift
import XCTest
@testable import RatioThinkCore

final class PieEngineHostKVUsageTests: XCTestCase {
  final class KVSession: PieEngineHost.EngineSession, @unchecked Sendable {
    let json: String?
    init(json: String?) { self.json = json }
    func shutdown() async {}
    func modelStatusJSON() async throws -> String? { json }
  }

  private func makeSpec(profileID: String = "chat") -> PieControlLauncher.LaunchSpec {
    let tmp = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
    return try! PieControlLauncher.LaunchSpec(
      pieBinary: tmp.appendingPathComponent("ignored-pie"),
      wasmURL: tmp.appendingPathComponent("ignored.wasm"),
      manifestURL: tmp.appendingPathComponent("ignored.toml"),
      subprocessEnvironment: [:],
      pieHome: tmp.appendingPathComponent("home"),
      shmemName: "/pie_test_\(UUID().uuidString.prefix(8))",
      profileID: profileID,
      modelConfig: .dummy
    )
  }

  func test_kvUsageSnapshots_returnsEmptyWhenStopped() async throws {
    let host = PieEngineHost(launcher: { _ in (port: EnginePort(1), session: KVSession(json: nil)) })
    let snapshots = try await host.kvUsageSnapshots(now: { Date(timeIntervalSince1970: 1) })
    XCTAssertEqual(snapshots, [])
  }

  func test_kvUsageSnapshots_queriesRunningSessionAndStampsGeneration() async throws {
    let session = KVSession(json: #"{"default.kv_pages_used":2,"default.kv_pages_total":256}"#)
    let host = PieEngineHost(launcher: { _ in (port: EnginePort(45678), session: session) })
    let running = expectation(description: "running")
    let token = host.observe { status, _ in
      if case .running = status { running.fulfill() }
    }
    _ = host.start(makeSpec())
    await fulfillment(of: [running], timeout: 2)

    let first = try await host.kvUsageSnapshots(now: { Date(timeIntervalSince1970: 100) })
    let second = try await host.kvUsageSnapshots(now: { Date(timeIntervalSince1970: 101) })

    XCTAssertEqual(first.first?.modelID, "default")
    XCTAssertEqual(first.first?.pagesUsed, 2)
    XCTAssertEqual(first.first?.pagesTotal, 256)
    XCTAssertEqual(first.first?.observedAt, Date(timeIntervalSince1970: 100))
    XCTAssertEqual(first.first?.generation, 1)
    XCTAssertEqual(second.first?.generation, 2)
    token.cancel()
  }
}
```

- [ ] **Step 2: Run test to verify RED**

```bash
swift test --filter PieEngineHostKVUsageTests
```

Expected: compile fails because `modelStatusJSON()` and `kvUsageSnapshots(now:)` do not exist.

- [ ] **Step 3: Extend `EngineSession` and `PieEngineHost`**

Modify `Shared/Engine/PieEngineHost.swift`:

1. In `EngineSession`, add:

```swift
func modelStatusJSON() async throws -> String?
```

2. Near other host state, add:

```swift
private let kvUsageGeneration = OSAllocatedUnfairLock<UInt64>(initialState: 0)
```

3. Add a public host method:

```swift
public func kvUsageSnapshots(now: @Sendable () -> Date = Date.init) async throws -> [KVUsageSnapshot] {
  let session: (any EngineSession)? = stateQueue.sync {
    guard case .running(_, _, let session) = self._state else { return nil }
    return session
  }
  guard let session, let json = try await session.modelStatusJSON() else { return [] }
  let generation = kvUsageGeneration.withLock { value -> UInt64 in
    value &+= 1
    return value
  }
  return try KVUsageModelStatusParser.parse(json, observedAt: now(), generation: generation)
}
```

4. In the `PieEngineHost.EngineSession` extension at the bottom, add:

```swift
func modelStatusJSON() async throws -> String? { nil }
```

- [ ] **Step 4: Implement `LaunchedSession.modelStatusJSON()`**

Modify `Shared/Engine/PieControlLauncher.swift` inside `LaunchedSession`:

```swift
public func modelStatusJSON() async throws -> String? {
  guard process.isRunning else { return nil }
  guard let controlWSURL else { return nil }
  let config = URLSessionConfiguration.ephemeral
  config.timeoutIntervalForRequest = Self.livenessProbeTimeout
  config.timeoutIntervalForResource = Self.livenessProbeTimeout
  let client = PieControlClient(url: controlWSURL, session: URLSession(configuration: config))
  do {
    try await client.connect()
    try await client.authIdentify("pie-mac-kv-usage")
    let json = try await client.query(subject: "model_status", record: "")
    await client.close()
    return json
  } catch {
    await client.close()
    throw error
  }
}
```

- [ ] **Step 5: Run host/session tests for GREEN**

```bash
swift test --filter PieEngineHostKVUsageTests
```

Expected: tests pass.

- [ ] **Step 6: Commit host/session path**

```bash
git add Shared/Engine/PieEngineHost.swift Shared/Engine/PieControlLauncher.swift Tests/RatioThinkCoreTests/PieEngineHostKVUsageTests.swift
git commit -m "Query KV usage from running pie session"
```

---

### Task 3: Helper/XPC global KV usage refresh path

**Files:**
- Modify: `Shared/XPC/PieHelperXPC.swift`
- Modify: `Shared/XPC/HelperExportedAPI.swift`
- Modify: `Shared/XPC/AppXPCClient.swift`
- Modify: `Tests/Unit/XPCProtocolTests.swift`
- Create: `Tests/RatioThinkCoreTests/HelperExportedAPIKVUsageTests.swift`

- [ ] **Step 1: Write failing protocol and helper tests**

In `Tests/Unit/XPCProtocolTests.swift`, add `"kvUsageWithReply:"` to the `expected` selector list in `test_protocol_declares_each_required_selector`.

Also add this round-trip test near other wire helper tests:

```swift
func test_kvUsage_reply_success_encodes_snapshots_only() throws {
  let snapshots = [KVUsageSnapshot(
    modelID: "default",
    pagesUsed: 1,
    pagesTotal: 256,
    observedAt: Date(timeIntervalSince1970: 5),
    generation: 1,
    source: .pieModelStatus
  )]
  var captured: (Data?, Data?)?
  PieHelperXPCWire.replyKVUsage(.success(snapshots)) { captured = ($0, $1) }
  let tuple = try XCTUnwrap(captured)
  XCTAssertNotNil(tuple.0)
  XCTAssertNil(tuple.1)
  XCTAssertEqual(try PieHelperXPCWire.decodeKVUsageReply(successData: tuple.0, errorData: tuple.1).get(), snapshots)
}
```

Create `Tests/RatioThinkCoreTests/HelperExportedAPIKVUsageTests.swift`:

```swift
import XCTest
@testable import RatioThinkCore

final class HelperExportedAPIKVUsageTests: XCTestCase {
  final class KVSession: PieEngineHost.EngineSession, @unchecked Sendable {
    let json: String?
    init(json: String?) { self.json = json }
    func shutdown() async {}
    func modelStatusJSON() async throws -> String? { json }
  }

  private func makeSpec() -> PieControlLauncher.LaunchSpec {
    let tmp = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
    return try! PieControlLauncher.LaunchSpec(
      pieBinary: tmp.appendingPathComponent("ignored-pie"),
      wasmURL: tmp.appendingPathComponent("ignored.wasm"),
      manifestURL: tmp.appendingPathComponent("ignored.toml"),
      subprocessEnvironment: [:],
      pieHome: tmp.appendingPathComponent("home"),
      shmemName: "/pie_test_\(UUID().uuidString.prefix(8))",
      profileID: "chat",
      modelConfig: .dummy
    )
  }

  func test_kvUsage_noHostReturnsEmptySnapshotList() async throws {
    let api = HelperExportedAPI()
    let result = await kvUsage(api)
    XCTAssertEqual(try result.get(), [])
  }

  func test_kvUsage_runningHostReturnsParsedSnapshots() async throws {
    let session = KVSession(json: #"{"default.kv_pages_used":4,"default.kv_pages_total":256}"#)
    let host = PieEngineHost(launcher: { _ in (port: EnginePort(45678), session: session) })
    let running = expectation(description: "running")
    let token = host.observe { status, _ in
      if case .running = status { running.fulfill() }
    }
    _ = host.start(makeSpec())
    await fulfillment(of: [running], timeout: 2)

    let api = HelperExportedAPI(engineHost: host, launchSpecResolver: nil)
    let snapshots = try await kvUsage(api).get()
    XCTAssertEqual(snapshots.first?.modelID, "default")
    XCTAssertEqual(snapshots.first?.pagesUsed, 4)
    XCTAssertEqual(snapshots.first?.pagesTotal, 256)
    token.cancel()
  }

  private func kvUsage(_ api: PieHelperXPC) async -> Result<[KVUsageSnapshot], EngineError> {
    await withCheckedContinuation { cont in
      api.kvUsage { successData, errorData in
        do {
          cont.resume(returning: try PieHelperXPCWire.decodeKVUsageReply(successData: successData, errorData: errorData))
        } catch let err as EngineError {
          cont.resume(returning: .failure(err))
        } catch {
          cont.resume(returning: .failure(EngineError(code: .wireContractViolation, message: "decode failed: \(error)")))
        }
      }
    }
  }
}
```

- [ ] **Step 2: Run tests to verify RED**

```bash
swift test --filter XPCProtocolTests/test_protocol_declares_each_required_selector
swift test --filter HelperExportedAPIKVUsageTests
```

Expected: compile/protocol failures because `kvUsage` and wire helpers do not exist.

- [ ] **Step 3: Add XPC selector and wire helpers**

Modify `Shared/XPC/PieHelperXPC.swift`:

1. Add to `PieHelperXPC` protocol:

```swift
/// Reply is `XPCPayload.encode([KVUsageSnapshot])` on success or
/// `XPCPayload.encode(EngineError)` on failure. Exactly one slot is non-nil.
func kvUsage(reply: @escaping (_ successData: Data?, _ errorData: Data?) -> Void)
```

2. Add to `PieHelperXPCWire`:

```swift
public static func replyKVUsage(
  _ result: Result<[KVUsageSnapshot], EngineError>,
  via reply: (Data?, Data?) -> Void
) {
  _replyHandleOrError(
    result, via: reply,
    encode: defaultEncode,
    onEncodeFailure: { PieHelperXPCLog.encodeFailure($0, site: "replyKVUsage") }
  )
}

public static func decodeKVUsageReply(
  successData: Data?,
  errorData: Data?
) throws -> Result<[KVUsageSnapshot], EngineError> {
  try decodeHandleOrErrorReply(
    [KVUsageSnapshot].self,
    successData: successData,
    errorData: errorData,
    slot: "kvUsage"
  )
}
```

- [ ] **Step 4: Implement helper selector**

Modify `Shared/XPC/HelperExportedAPI.swift` before `engineMemory`:

```swift
public func kvUsage(reply: @escaping (Data?, Data?) -> Void) {
  guard let engineHost else {
    PieHelperXPCWire.replyKVUsage(.success([]), via: reply)
    return
  }
  Task {
    do {
      let snapshots = try await engineHost.kvUsageSnapshots()
      PieHelperXPCWire.replyKVUsage(.success(snapshots), via: reply)
    } catch {
      PieHelperXPCWire.replyKVUsage(
        .failure(EngineError(code: .engineGone, message: "KV usage refresh failed: \(error)")),
        via: reply
      )
    }
  }
}
```

Modify `DegradedHelperAPI` in the same file to add:

```swift
public func kvUsage(reply: @escaping (Data?, Data?) -> Void) {
  reply(nil, degradedErrorData)
}
```

- [ ] **Step 5: Implement App XPC client method**

Modify `Shared/XPC/AppXPCClient.swift`:

1. Add to `AppXPCClient` protocol:

```swift
func kvUsageSnapshots() async throws -> [KVUsageSnapshot]
```

2. Add default implementation:

```swift
func kvUsageSnapshots() async throws -> [KVUsageSnapshot] { [] }
```

3. Add to `HelperXPCClient`:

```swift
public func kvUsageSnapshots() async throws -> [KVUsageSnapshot] {
  let connection = ensureConnection()
  do {
    return try await kvUsageSnapshots(on: connection)
  } catch let error as AppXPCClientError {
    if case .replyTimeout = error { invalidateIfCurrent(connection) }
    throw error
  }
}

private func kvUsageSnapshots(on connection: NSXPCConnection) async throws -> [KVUsageSnapshot] {
  let timeout = replyTimeout
  return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<[KVUsageSnapshot], Error>) in
    let resumed = OSAllocatedUnfairLock<Bool>(initialState: false)
    func resumeOnce(_ result: Result<[KVUsageSnapshot], Error>) {
      let shouldResume = resumed.withLock { fired -> Bool in
        if fired { return false }
        fired = true
        return true
      }
      guard shouldResume else { return }
      switch result {
      case .success(let snapshots): continuation.resume(returning: snapshots)
      case .failure(let error): continuation.resume(throwing: error)
      }
    }
    if timeout > 0 {
      DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + timeout) {
        resumeOnce(.failure(AppXPCClientError.replyTimeout(selector: "kvUsage", timeout: timeout)))
      }
    }
    let proxy = connection.remoteObjectProxyWithErrorHandler { err in
      resumeOnce(.failure(AppXPCClientError.proxyError(err as NSError)))
    }
    guard let api = proxy as? PieHelperXPC else {
      resumeOnce(.failure(AppXPCClientError.proxyTypeMismatch))
      return
    }
    api.kvUsage { successData, errorData in
      do {
        switch try PieHelperXPCWire.decodeKVUsageReply(successData: successData, errorData: errorData) {
        case .success(let snapshots): resumeOnce(.success(snapshots))
        case .failure(let engineError): resumeOnce(.failure(engineError))
        }
      } catch {
        resumeOnce(.failure(error))
      }
    }
  }
}
```

- [ ] **Step 6: Run XPC tests for GREEN**

```bash
swift test --filter XPCProtocolTests/test_protocol_declares_each_required_selector
swift test --filter XPCProtocolTests/test_kvUsage_reply_success_encodes_snapshots_only
swift test --filter HelperExportedAPIKVUsageTests
```

Expected: tests pass.

- [ ] **Step 7: Commit XPC path**

```bash
git add Shared/XPC/PieHelperXPC.swift Shared/XPC/HelperExportedAPI.swift Shared/XPC/AppXPCClient.swift Tests/Unit/XPCProtocolTests.swift Tests/RatioThinkCoreTests/HelperExportedAPIKVUsageTests.swift
git commit -m "Expose KV usage snapshots over helper XPC"
```

---

### Task 4: Per-chat context usage attribution state

**Files:**
- Create: `Shared/Engine/ContextUsageRecord.swift`
- Create: `Tests/RatioThinkCoreTests/ContextUsageTrackerTests.swift`

- [ ] **Step 1: Write failing tracker tests**

Create `Tests/RatioThinkCoreTests/ContextUsageTrackerTests.swift`:

```swift
import XCTest
@testable import RatioThinkCore

@MainActor
final class ContextUsageTrackerTests: XCTestCase {
  func test_requestLifecycle_recordsActiveThenDestroyedWithoutUsageGuess() {
    let tracker = ContextUsageTracker(now: { Date(timeIntervalSince1970: 10) })
    let chatID = UUID()

    tracker.markRequestStarted(chatID: chatID, modelID: "m", requestID: "r1")
    var record = tracker.records.first
    XCTAssertEqual(record?.chatID, chatID)
    XCTAssertEqual(record?.modelID, "m")
    XCTAssertEqual(record?.requestID, "r1")
    XCTAssertEqual(record?.residency, .requestLocalActive)
    XCTAssertNil(record?.usage, "v1 has no page frame yet; do not estimate")

    tracker.markRequestFinished(chatID: chatID, modelID: "m", requestID: "r1")
    record = tracker.records.first
    XCTAssertEqual(record?.residency, .requestLocalDestroyed)
    XCTAssertNil(record?.usage)
  }

  func test_staleFinishForOldRequestIDIsIgnored() {
    var now = Date(timeIntervalSince1970: 1)
    let tracker = ContextUsageTracker(now: { now })
    let chatID = UUID()

    tracker.markRequestStarted(chatID: chatID, modelID: "m", requestID: "new")
    now = Date(timeIntervalSince1970: 2)
    tracker.markRequestFinished(chatID: chatID, modelID: "m", requestID: "old")

    XCTAssertEqual(tracker.records.first?.requestID, "new")
    XCTAssertEqual(tracker.records.first?.residency, .requestLocalActive)
    XCTAssertEqual(tracker.records.first?.lastUsedAt, Date(timeIntervalSince1970: 1))
  }

  func test_modelSwitchCreatesDistinctRecordKey() {
    let chatID = UUID()
    let tracker = ContextUsageTracker(now: { Date(timeIntervalSince1970: 1) })
    tracker.markRequestStarted(chatID: chatID, modelID: "a", requestID: "ra")
    tracker.markRequestStarted(chatID: chatID, modelID: "b", requestID: "rb")

    XCTAssertEqual(Set(tracker.records.map(\.modelID)), ["a", "b"])
  }
}
```

- [ ] **Step 2: Run tests to verify RED**

```bash
swift test --filter ContextUsageTrackerTests
```

Expected: compile fails because `ContextUsageTracker` and record types do not exist.

- [ ] **Step 3: Implement record and tracker**

Create `Shared/Engine/ContextUsageRecord.swift`:

```swift
import Combine
import Foundation

public struct ContextUsageID: Codable, Equatable, Hashable, Sendable {
  public let chatID: UUID
  public let modelID: String

  public init(chatID: UUID, modelID: String) {
    self.chatID = chatID
    self.modelID = modelID
  }
}

public enum ContextResidency: String, Codable, Equatable, Sendable {
  case unknown
  case requestLocalActive
  case requestLocalDestroyed
  case persistentActive
  case persistentSuspended
  case persistentSnapshotBacked
  case destroyed
}

public struct ContextPageUsage: Codable, Equatable, Sendable {
  public let tokensPerPage: UInt32
  public let committedPages: UInt32
  public let workingPages: UInt32
  public let workingTokens: UInt32
  public let checkpoint: String
  public let observedAt: Date

  public init(tokensPerPage: UInt32,
              committedPages: UInt32,
              workingPages: UInt32,
              workingTokens: UInt32,
              checkpoint: String,
              observedAt: Date) {
    self.tokensPerPage = tokensPerPage
    self.committedPages = committedPages
    self.workingPages = workingPages
    self.workingTokens = workingTokens
    self.checkpoint = checkpoint
    self.observedAt = observedAt
  }
}

public struct ContextUsageRecord: Codable, Equatable, Identifiable, Sendable {
  public let id: ContextUsageID
  public var chatID: UUID { id.chatID }
  public var modelID: String { id.modelID }
  public var requestID: String?
  public var lastUsedAt: Date
  public var residency: ContextResidency
  public var usage: ContextPageUsage?

  public init(id: ContextUsageID,
              requestID: String?,
              lastUsedAt: Date,
              residency: ContextResidency,
              usage: ContextPageUsage?) {
    self.id = id
    self.requestID = requestID
    self.lastUsedAt = lastUsedAt
    self.residency = residency
    self.usage = usage
  }
}

@MainActor
public final class ContextUsageTracker: ObservableObject {
  @Published public private(set) var records: [ContextUsageRecord] = []

  private var byID: [ContextUsageID: ContextUsageRecord] = [:]
  private let now: () -> Date

  public init(now: @escaping () -> Date = Date.init) {
    self.now = now
  }

  public func markRequestStarted(chatID: UUID, modelID: String, requestID: String) {
    let id = ContextUsageID(chatID: chatID, modelID: modelID)
    byID[id] = ContextUsageRecord(
      id: id,
      requestID: requestID,
      lastUsedAt: now(),
      residency: .requestLocalActive,
      usage: nil
    )
    publish()
  }

  public func markRequestFinished(chatID: UUID, modelID: String, requestID: String) {
    let id = ContextUsageID(chatID: chatID, modelID: modelID)
    guard var record = byID[id], record.requestID == requestID else { return }
    record.lastUsedAt = now()
    record.residency = .requestLocalDestroyed
    byID[id] = record
    publish()
  }

  private func publish() {
    records = byID.values.sorted {
      if $0.lastUsedAt == $1.lastUsedAt { return $0.modelID < $1.modelID }
      return $0.lastUsedAt > $1.lastUsedAt
    }
  }
}
```

- [ ] **Step 4: Run tracker tests for GREEN**

```bash
swift test --filter ContextUsageTrackerTests
```

Expected: tests pass.

- [ ] **Step 5: Commit tracker**

```bash
git add Shared/Engine/ContextUsageRecord.swift Tests/RatioThinkCoreTests/ContextUsageTrackerTests.swift
git commit -m "Add request-local context usage tracker"
```

---

### Task 5: Wire per-chat attribution into `ChatSendController`

**Files:**
- Modify: `Shared/Persistence/ChatSendController.swift`
- Modify: `Tests/RatioThinkCoreTests/ChatSendControllerTests.swift`

- [ ] **Step 1: Write failing controller tests**

Add to `Tests/RatioThinkCoreTests/ChatSendControllerTests.swift`:

```swift
func test_send_marksContextUsageRequestLocalActiveAndDestroyedOnFinish() async throws {
  let container = try RatioThinkModelContainer.makeInMemory()
  let context = ModelContext(container)
  let chat = Chat()
  context.insert(chat)
  chat.messages.append(Message(role: "user", content: "hello", ts: Date(timeIntervalSinceReferenceDate: 1)))
  try context.save()

  let engine = ImmediateChatEngine(events: [.modelReady, .finish(reason: .stop)])
  let tracker = ContextUsageTracker(now: { Date(timeIntervalSince1970: 1) })
  let controller = ChatSendController()

  controller.send(
    chat: chat,
    context: context,
    engine: engine,
    modelLoadCenter: ModelLoadCenter(),
    persistenceStatus: PersistenceStatus(),
    options: ChatSendRequestOptions(modelID: "m"),
    contextUsageTracker: tracker
  )

  try await waitUntil("usage record destroyed") {
    tracker.records.first?.residency == .requestLocalDestroyed
  }
  let record = try XCTUnwrap(tracker.records.first)
  XCTAssertEqual(record.chatID, chat.id)
  XCTAssertEqual(record.modelID, "m")
  XCTAssertNotNil(record.requestID)
  XCTAssertNil(record.usage, "no context_usage frame exists yet, so usage must stay unknown")
}

func test_cancel_marksContextUsageDestroyed() async throws {
  let container = try RatioThinkModelContainer.makeInMemory()
  let context = ModelContext(container)
  let chat = Chat()
  context.insert(chat)
  chat.messages.append(Message(role: "user", content: "hello", ts: Date(timeIntervalSinceReferenceDate: 1)))
  try context.save()

  let engine = ManualChatEngine()
  let tracker = ContextUsageTracker(now: { Date(timeIntervalSince1970: 1) })
  let controller = ChatSendController()

  controller.send(
    chat: chat,
    context: context,
    engine: engine,
    modelLoadCenter: ModelLoadCenter(),
    persistenceStatus: PersistenceStatus(),
    options: ChatSendRequestOptions(modelID: "m"),
    contextUsageTracker: tracker
  )
  try await waitUntil("usage active") { tracker.records.first?.residency == .requestLocalActive }

  controller.cancel()

  XCTAssertEqual(tracker.records.first?.residency, .requestLocalDestroyed)
}
```

- [ ] **Step 2: Run tests to verify RED**

```bash
swift test --filter ChatSendControllerTests/test_send_marksContextUsageRequestLocalActiveAndDestroyedOnFinish
swift test --filter ChatSendControllerTests/test_cancel_marksContextUsageDestroyed
```

Expected: compile fails because `send(... contextUsageTracker:)` does not exist.

- [ ] **Step 3: Add optional tracker parameter and active identity storage**

Modify `Shared/Persistence/ChatSendController.swift`:

1. Add private state:

```swift
private var activeUsageIdentity: (tracker: ContextUsageTracker, chatID: UUID, modelID: String, requestID: String)?
```

2. Extend `send` signature by adding the final defaulted parameter:

```swift
contextUsageTracker: ContextUsageTracker? = nil
```

3. After `let request = Self.makeRequest(chat: chat, options: options)`, add:

```swift
let usageRequestID = UUID().uuidString
contextUsageTracker?.markRequestStarted(
  chatID: chat.id,
  modelID: options.modelID,
  requestID: usageRequestID
)
self.activeUsageIdentity = contextUsageTracker.map {
  (tracker: $0, chatID: chat.id, modelID: options.modelID, requestID: usageRequestID)
}
```

4. In the task `defer`, before clearing fields, add:

```swift
if self.generation == myGeneration,
   let usage = self.activeUsageIdentity,
   usage.requestID == usageRequestID {
  usage.tracker.markRequestFinished(
    chatID: usage.chatID,
    modelID: usage.modelID,
    requestID: usage.requestID
  )
  self.activeUsageIdentity = nil
}
```

5. In `cancel()`, before clearing fields, add:

```swift
if let usage = activeUsageIdentity {
  usage.tracker.markRequestFinished(
    chatID: usage.chatID,
    modelID: usage.modelID,
    requestID: usage.requestID
  )
}
activeUsageIdentity = nil
```

- [ ] **Step 4: Run controller tests for GREEN**

```bash
swift test --filter ChatSendControllerTests/test_send_marksContextUsageRequestLocalActiveAndDestroyedOnFinish
swift test --filter ChatSendControllerTests/test_cancel_marksContextUsageDestroyed
```

Expected: both tests pass.

- [ ] **Step 5: Run existing chat-send suite**

```bash
swift test --filter ChatSendControllerTests
```

Expected: existing chat send tests still pass.

- [ ] **Step 6: Commit attribution wiring**

```bash
git add Shared/Persistence/ChatSendController.swift Tests/RatioThinkCoreTests/ChatSendControllerTests.swift
git commit -m "Track request-local chat context usage"
```

---

### Task 6: Live diagnostic coverage for `model_status`

**Files:**
- Create: `Tests/CLIScenarioTests/KVUsageModelStatusLiveTests.swift`
- Modify: `TEST.md`

- [ ] **Step 1: Add gated live test**

Create `Tests/CLIScenarioTests/KVUsageModelStatusLiveTests.swift`:

```swift
import XCTest
@testable import RatioThinkCore

final class KVUsageModelStatusLiveTests: XCTestCase {
  func test_dummyPie_modelStatus_reportsAuthoritativeKVPages() async throws {
    guard let pieBin = ProcessInfo.processInfo.environment["PIE_TEST_REAL_PIE_BIN"], !pieBin.isEmpty else {
      throw XCTSkip("set PIE_TEST_REAL_PIE_BIN to run live model_status check")
    }
    guard let wasm = ProcessInfo.processInfo.environment["PIE_TEST_REAL_CHATAPC_WASM"], !wasm.isEmpty,
          let manifest = ProcessInfo.processInfo.environment["PIE_TEST_REAL_CHATAPC_MANIFEST"], !manifest.isEmpty else {
      throw XCTSkip("set PIE_TEST_REAL_CHATAPC_WASM and PIE_TEST_REAL_CHATAPC_MANIFEST")
    }

    let tmp = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
      .appendingPathComponent("kvusage-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    let spec = try PieControlLauncher.LaunchSpec(
      pieBinary: URL(fileURLWithPath: pieBin),
      wasmURL: URL(fileURLWithPath: wasm),
      manifestURL: URL(fileURLWithPath: manifest),
      subprocessEnvironment: [:],
      pieHome: tmp.appendingPathComponent("pie-home"),
      shmemName: "/pie_kvusage_\(UUID().uuidString.prefix(8))",
      profileID: "chat",
      modelConfig: .dummy
    )
    let (_, session) = try await PieControlLauncher.launch(spec: spec)
    defer { Task { await session.shutdown() } }

    let raw = try await session.modelStatusJSON()
    let json = try XCTUnwrap(raw)
    let snapshots = try KVUsageModelStatusParser.parse(
      json,
      observedAt: Date(timeIntervalSince1970: 1),
      generation: 1
    )
    let snapshot = try XCTUnwrap(snapshots.first { $0.modelID == "default" })
    XCTAssertEqual(snapshot.pagesUsed, 0)
    XCTAssertGreaterThan(snapshot.pagesTotal, 0)
  }
}
```

- [ ] **Step 2: Run gated test without env to verify skip**

```bash
swift test --filter KVUsageModelStatusLiveTests
```

Expected: test is skipped when live env vars are absent.

- [ ] **Step 3: If local binary/resources are available, run live test**

```bash
PIE_TEST_REAL_PIE_BIN="$PWD/Vendor/pie/target/debug/pie" \
PIE_TEST_REAL_CHATAPC_WASM="$PWD/Inferlets/chat-apc/prebuilt/chat-apc.wasm" \
PIE_TEST_REAL_CHATAPC_MANIFEST="$PWD/Inferlets/chat-apc/Pie.toml" \
swift test --filter KVUsageModelStatusLiveTests
```

Expected: test passes and observes `pagesTotal > 0`.

- [ ] **Step 4: Document diagnostic test**

Add to `TEST.md` under scenario/live tests:

```markdown
### KV usage model_status diagnostic

`KVUsageModelStatusLiveTests` is gated behind:

- `PIE_TEST_REAL_PIE_BIN`
- `PIE_TEST_REAL_CHATAPC_WASM`
- `PIE_TEST_REAL_CHATAPC_MANIFEST`

It launches dummy pie, queries the existing control-plane `model_status` endpoint, parses `kv_pages_used/total`, and confirms the App parser sees the runtime-reported totals.
```

- [ ] **Step 5: Commit live diagnostic**

```bash
git add Tests/CLIScenarioTests/KVUsageModelStatusLiveTests.swift TEST.md
git commit -m "Add KV usage model_status diagnostic"
```

---

### Task 7: Final verification and ticket handoff

**Files:**
- No production files unless verification reveals a defect.

- [ ] **Step 1: Run targeted unit suites**

```bash
swift test --filter KVUsageSnapshotTests
swift test --filter PieEngineHostKVUsageTests
swift test --filter HelperExportedAPIKVUsageTests
swift test --filter ContextUsageTrackerTests
swift test --filter ChatSendControllerTests
swift test --filter PieControlClientTests
```

Expected: all pass.

- [ ] **Step 2: Run broader local verification required for this ticket**

Run the project's normal local gates that are practical in this environment:

```bash
swift test
```

Expected: pass, or document any pre-existing unrelated failure with exact failing test names and logs.

If GUI/e2e suites are required by the current ticket gate and local environment is seated/healthy, run the project scripts documented in `TEST.md`. If they require unavailable hardware/TCC/RunPod, record the blocker in ticket #517 immediately.

- [ ] **Step 3: Update ticket #517**

Use `hc ticket update 517 --memo` with:

- Parser status and tests.
- XPC refresh path status and tests.
- Per-chat attribution status and tests.
- Live diagnostic result or skip reason.
- Any known limitations: no persistent chat contexts, no tail truncation, no UI warning thresholds from estimates.

- [ ] **Step 4: Final commit if verification fixes were needed**

If Step 2 required fixes:

```bash
git add <changed-files>
git commit -m "Stabilize KV usage tracking verification"
```

Expected: clean working tree after commit.
