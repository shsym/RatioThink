import XCTest
@testable import RatioThinkCore

/// Unit tests for `DiagnosticLog` — the durable, best-effort, append-only
/// lifecycle breadcrumb logger. Tests inject an explicit `directory` so they
/// never depend on `PieDirs.$homeOverride` propagating across the writer's
/// GCD queue (a `DispatchQueue.async` block is not a structured child task and
/// would not inherit the @TaskLocal), and never touch real app state.
final class DiagnosticLogTests: XCTestCase {

  // MARK: - line format

  func test_event_appends_iso8601_proc_event_and_ordered_fields() throws {
    try withTempDir { dir in
      let log = DiagnosticLog(.app, directory: dir)
      log.event("app.launch", [("version", "0.1.0"), ("build", "1")])
      log.flush()

      let line = try firstLine(dir, "app.log")
      let parts = line.split(separator: " ", maxSplits: 2).map(String.init)
      XCTAssertEqual(parts.count, 3, "expected '<ts> <proc> <rest>': \(line)")
      XCTAssertNotNil(ISO8601DateFormatter().date(from: parts[0]),
                      "timestamp not ISO8601: \(parts[0])")
      XCTAssertEqual(parts[1], "app")
      XCTAssertEqual(parts[2], "app.launch version=0.1.0 build=1",
                     "event + ordered fields wrong: \(line)")
    }
  }

  func test_event_without_fields_has_no_trailing_space() throws {
    try withTempDir { dir in
      let log = DiagnosticLog(.helper, directory: dir)
      log.event("helper.launch")
      log.flush()

      let line = try firstLine(dir, "helper.log")
      XCTAssertTrue(line.hasSuffix("helper.launch"), "got: \(line)")
      XCTAssertFalse(line.hasSuffix(" "), "no trailing space when fieldless")
    }
  }

  // MARK: - redaction (pure)

  func test_redactHome_collapses_home_prefix_only() {
    let home = NSHomeDirectory()
    XCTAssertEqual(DiagnosticLog.redactHome(home + "/Library/x"), "~/Library/x")
    XCTAssertEqual(DiagnosticLog.redactHome("/Applications/RatioThink.app"),
                   "/Applications/RatioThink.app")
  }

  // MARK: - thread-safety

  func test_concurrent_events_keep_every_line_intact() throws {
    try withTempDir { dir in
      let log = DiagnosticLog(.app, directory: dir)
      let n = 200
      DispatchQueue.concurrentPerform(iterations: n) { i in
        log.event("e", [("i", String(i))])
      }
      log.flush()

      let body = try contents(dir, "app.log")
      let lines = body.split(separator: "\n").filter { !$0.isEmpty }
      XCTAssertEqual(lines.count, n, "every concurrent write must land as one line")
      for l in lines {
        XCTAssertTrue(l.contains(" app e i="), "malformed interleaved line: \(l)")
      }
    }
  }

  // MARK: - best-effort: never throws / crashes on an unwritable target

  func test_event_on_unwritable_directory_is_silent_noop() throws {
    let unwritable = URL(fileURLWithPath: "/System/ratiothink-diag-cannot-create")
    let log = DiagnosticLog(.app, directory: unwritable)
    log.event("app.launch")        // must not throw or crash
    log.flush()
    XCTAssertFalse(FileManager.default.fileExists(
      atPath: unwritable.appendingPathComponent("app.log").path))
  }

  // MARK: - bounded growth

  func test_rotation_moves_active_to_dot1_backup_when_cap_exceeded() throws {
    try withTempDir { dir in
      let log = DiagnosticLog(.app, directory: dir, rotateByteCap: 200)
      for i in 0..<100 { log.event("e", [("i", String(i))]) }
      log.flush()

      let active = dir.appendingPathComponent("app.log")
      let backup = dir.appendingPathComponent("app.log.1")
      XCTAssertTrue(FileManager.default.fileExists(atPath: backup.path),
                    "exceeding the cap must produce a .1 backup")
      let activeSize = (try FileManager.default
        .attributesOfItem(atPath: active.path)[.size] as? Int) ?? 0
      XCTAssertLessThanOrEqual(activeSize, 200 + 64,
                               "active file should be fresh after rotation")
    }
  }

  // MARK: - helpers

  private func withTempDir(_ body: (URL) throws -> Void) throws {
    let dir = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
      .appendingPathComponent("diaglog-test-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    var thrown: Error?
    do { try body(dir) } catch { thrown = error }
    try? FileManager.default.removeItem(at: dir)
    if let thrown { throw thrown }
  }

  private func contents(_ dir: URL, _ name: String) throws -> String {
    try String(contentsOf: dir.appendingPathComponent(name), encoding: .utf8)
  }

  private func firstLine(_ dir: URL, _ name: String) throws -> String {
    let body = try contents(dir, name)
    let line = body.split(separator: "\n", maxSplits: 1).first.map(String.init) ?? ""
    XCTAssertFalse(line.isEmpty, "expected at least one line in \(name)")
    return line
  }
}
