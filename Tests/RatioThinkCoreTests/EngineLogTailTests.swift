import XCTest
@testable import RatioThinkCore
import Foundation

/// #447 — the durable engine.log failure-tail writer. Uses the `directory:`
/// injection seam so the test never writes the real
/// `~/Library/Application Support/RatioThink/logs` (same isolation contract
/// as DiagnosticLog).
final class EngineLogTailTests: XCTestCase {

  private func tmpDir() -> URL {
    let d = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
      .appendingPathComponent("engine-log-tail-\(UUID().uuidString)")
    return d
  }

  func test_append_writesEngineLog_boundedToMaxLines() throws {
    let dir = tmpDir()
    defer { try? FileManager.default.removeItem(at: dir) }
    let lines = (1...40).map { "trace line \($0)" }
    EngineLogTail.append(lines, directory: dir)

    let url = dir.appendingPathComponent("engine.log")
    let body = try String(contentsOf: url, encoding: .utf8)
    // Only the last `maxLines` are persisted.
    XCTAssertTrue(body.contains("trace line 40"), body)
    XCTAssertTrue(body.contains("trace line 9"), body)   // 40-32+1 = 9
    XCTAssertFalse(body.contains("trace line 8"), body)  // dropped by the bound
    XCTAssertTrue(body.contains("[engine-terminated]"), body)
  }

  func test_append_appendsToExisting_doesNotTruncate() throws {
    let dir = tmpDir()
    defer { try? FileManager.default.removeItem(at: dir) }
    EngineLogTail.append(["first death"], directory: dir)
    EngineLogTail.append(["second death"], directory: dir)
    let body = try String(contentsOf: dir.appendingPathComponent("engine.log"), encoding: .utf8)
    XCTAssertTrue(body.contains("first death"), body)
    XCTAssertTrue(body.contains("second death"), body)
  }

  func test_append_emptyLines_writesNothing() {
    let dir = tmpDir()
    defer { try? FileManager.default.removeItem(at: dir) }
    EngineLogTail.append([], directory: dir)
    XCTAssertFalse(FileManager.default.fileExists(
      atPath: dir.appendingPathComponent("engine.log").path))
  }

  func test_append_persistsRedactedLineVerbatim_noChatReinjection() throws {
    // The writer persists exactly the (already token-redacted) lines it is
    // handed — it must not re-expand a redaction or invent content.
    let dir = tmpDir()
    defer { try? FileManager.default.removeItem(at: dir) }
    EngineLogTail.append(["internal token: <REDACTED>", "panicked at foo.rs:1"],
                         directory: dir)
    let body = try String(contentsOf: dir.appendingPathComponent("engine.log"), encoding: .utf8)
    XCTAssertTrue(body.contains("internal token: <REDACTED>"), body)
    XCTAssertTrue(body.contains("panicked at foo.rs:1"), body)
  }
}
