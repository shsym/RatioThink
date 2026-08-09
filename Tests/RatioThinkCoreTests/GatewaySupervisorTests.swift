import Darwin
import Foundation
import XCTest
@testable import RatioThinkCore

final class GatewaySupervisorTests: XCTestCase {
  private struct Fixture {
    let root: URL
    let binary: URL

    func spec(timeout: TimeInterval = 2) -> GatewaySupervisor.Spec {
      GatewaySupervisor.Spec(
        binary: binary,
        inferlets: root,
        pieURL: "ws://127.0.0.1:1",
        pieToken: "test",
        readinessTimeout: timeout)
    }
  }

  private func fixture() throws -> Fixture {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("gateway-supervisor-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let binary = root.appendingPathComponent("fake-gateway.py")
    try fakeGateway.write(to: binary, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: binary.path)
    return Fixture(root: root, binary: binary)
  }

  func test_cleanShutdownRemovesPortFileAndIsIdempotent() async throws {
    let fixture = try fixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let supervisor = GatewaySupervisor()
    _ = try await supervisor.start(spec: fixture.spec())
    let discoveredPortFile = await supervisor.portFileForTesting()
    let portFile = try XCTUnwrap(discoveredPortFile)
    XCTAssertTrue(FileManager.default.fileExists(atPath: portFile.path))

    async let first = supervisor.shutdown(reason: "test")
    async let second = supervisor.shutdown(reason: "test")
    let results = await [first, second]
    XCTAssertEqual(results, [.reaped, .reaped])
    XCTAssertFalse(FileManager.default.fileExists(atPath: portFile.path))
  }

  func test_crashRecoversOnPublishedPort() async throws {
    let fixture = try fixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let supervisor = GatewaySupervisor()
    let port = try await supervisor.start(spec: fixture.spec())
    let discoveredPID = await supervisor.processIdentifierForTesting()
    let firstPID = try XCTUnwrap(discoveredPID)
    XCTAssertEqual(kill(firstPID, SIGKILL), 0)

    let recoveryFailure = await supervisor.recoverIfNeeded()
    let healthFailure = await supervisor.health()
    let recoveredPID = await supervisor.processIdentifierForTesting()
    XCTAssertNil(recoveryFailure)
    XCTAssertNil(healthFailure)
    XCTAssertNotEqual(recoveredPID, firstPID)
    let body = try await URLSession.shared.data(
      from: URL(string: "http://127.0.0.1:\(port)/healthz")!).0
    XCTAssertEqual(String(decoding: body, as: UTF8.self), "ok")
    let shutdownResult = await supervisor.shutdown(reason: "test")
    XCTAssertTrue(shutdownResult.reaped)
  }

  func test_unresponsiveHealthProbeRecoversOnPublishedPort() async throws {
    let fixture = try fixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let supervisor = GatewaySupervisor()
    let port = try await supervisor.start(spec: fixture.spec())
    try Data().write(to: fixture.root.appendingPathComponent("wedge"))

    let recoveryFailure = await supervisor.recoverIfNeeded()
    XCTAssertNil(recoveryFailure)
    let body = try await URLSession.shared.data(
      from: URL(string: "http://127.0.0.1:\(port)/healthz")!).0
    XCTAssertEqual(String(decoding: body, as: UTF8.self), "ok")
    let shutdownResult = await supervisor.shutdown(reason: "test")
    XCTAssertTrue(shutdownResult.reaped)
  }

  func test_missingBinaryAndStartupFailuresFailLoud() async throws {
    let fixture = try fixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }

    do {
      _ = try await GatewaySupervisor().start(
        spec: GatewaySupervisor.Spec(
          binary: fixture.root.appendingPathComponent("missing"),
          inferlets: fixture.root,
          pieURL: "ws://127.0.0.1:1",
          pieToken: "test"))
      XCTFail("missing binary unexpectedly started")
    } catch let error as GatewaySupervisor.SupervisorError {
      guard case .binaryMissing = error else { return XCTFail("unexpected error: \(error)") }
    }

    try Data().write(to: fixture.root.appendingPathComponent("exit-early"))
    do {
      _ = try await GatewaySupervisor().start(spec: fixture.spec())
      XCTFail("early exit unexpectedly started")
    } catch let error as GatewaySupervisor.SupervisorError {
      guard case .exitedEarly = error else { return XCTFail("unexpected error: \(error)") }
    }
    try FileManager.default.removeItem(at: fixture.root.appendingPathComponent("exit-early"))

    try Data().write(to: fixture.root.appendingPathComponent("timeout"))
    do {
      _ = try await GatewaySupervisor().start(spec: fixture.spec(timeout: 0.2))
      XCTFail("unready gateway unexpectedly started")
    } catch let error as GatewaySupervisor.SupervisorError {
      guard case .readinessTimeout = error else { return XCTFail("unexpected error: \(error)") }
    }
  }

  private let fakeGateway = #"""
#!/usr/bin/env python3
import argparse, http.server, os, pathlib, sys, threading, time

p = argparse.ArgumentParser()
p.add_argument("--listen")
p.add_argument("--pie-url")
p.add_argument("--pie-token")
p.add_argument("--inferlet-dir")
p.add_argument("--port-file")
p.add_argument("--exit-on-stdin-eof", action="store_true")
a = p.parse_args()
root = pathlib.Path(a.inferlet_dir)
port_file = pathlib.Path(a.port_file)
if (root / "exit-early").exists():
    sys.exit(7)
if (root / "timeout").exists():
    sys.stdin.buffer.read()
    sys.exit(0)

host, port = a.listen.rsplit(":", 1)
class Handler(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        if (root / "wedge").exists():
            (root / "wedge").unlink()
            time.sleep(4)
        self.send_response(200 if self.path == "/healthz" else 404)
        self.end_headers()
        if self.path == "/healthz": self.wfile.write(b"ok")
    def log_message(self, *args): pass

server = http.server.ThreadingHTTPServer((host, int(port)), Handler)
port_file.write_text(str(server.server_address[1]))
def lifetime():
    sys.stdin.buffer.read()
    try: port_file.unlink()
    except FileNotFoundError: pass
    os._exit(0)
threading.Thread(target=lifetime, daemon=True).start()
server.serve_forever()
"""#
}
