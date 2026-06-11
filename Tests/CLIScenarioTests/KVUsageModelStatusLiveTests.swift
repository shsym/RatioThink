import XCTest
import Foundation
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
    var session: LaunchedSession?
    do {
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
      let (_, launchedSession) = try await PieControlLauncher.launch(spec: spec)
      session = launchedSession

      let raw = try await launchedSession.modelStatusJSON()
      let json = try XCTUnwrap(raw)
      let snapshots = try KVUsageModelStatusParser.parse(
        json,
        observedAt: Date(timeIntervalSince1970: 1),
        generation: 1
      )
      let snapshot = try XCTUnwrap(snapshots.first { $0.modelID == "default" })
      XCTAssertEqual(snapshot.pagesUsed, 0)
      XCTAssertGreaterThan(snapshot.pagesTotal, 0)
    } catch {
      if let session {
        await session.shutdown()
      }
      try? FileManager.default.removeItem(at: tmp)
      throw error
    }

    if let session {
      await session.shutdown()
    }
    try? FileManager.default.removeItem(at: tmp)
  }
}
