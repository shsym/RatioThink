import Foundation
import XCTest
@testable import RatioThinkCore

final class BundledResourceLookupTests: XCTestCase {
  private var tempDir: URL!

  override func setUpWithError() throws {
    try super.setUpWithError()
    tempDir = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
      .appendingPathComponent("pie-bundle-lookup-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
  }

  override func tearDownWithError() throws {
    if let tempDir { try? FileManager.default.removeItem(at: tempDir) }
    tempDir = nil
    try super.tearDownWithError()
  }

  func test_bundledPieBinary_resolves_sibling_pieApp_when_helper_runs_standalone_under_xcode() throws {
    let helper = try makeAppBundle(named: "RationalHelper", bundleID: "com.ratiothink.app.helper")
    let pie = try makeAppBundle(named: "Rational", bundleID: "com.ratiothink.app")
    let binary = pie
      .appendingPathComponent("Contents/Resources/pie-engine/pie", isDirectory: false)
    try FileManager.default.createDirectory(
      at: binary.deletingLastPathComponent(),
      withIntermediateDirectories: true
    )
    XCTAssertTrue(FileManager.default.createFile(atPath: binary.path,
                                                 contents: Data("#!/bin/sh\n".utf8)))
    try FileManager.default.setAttributes([.posixPermissions: 0o755],
                                          ofItemAtPath: binary.path)

    let helperBundle = try XCTUnwrap(Bundle(url: helper))

    XCTAssertEqual(try LaunchSpecResolver.bundledPieBinary(in: helperBundle), binary)
  }

  func test_inferletResources_resolve_sibling_pieApp_when_helper_runs_standalone_under_xcode() throws {
    let helper = try makeAppBundle(named: "RationalHelper", bundleID: "com.ratiothink.app.helper")
    let pie = try makeAppBundle(named: "Rational", bundleID: "com.ratiothink.app")
    let inferletDir = pie
      .appendingPathComponent("Contents/Resources/Inferlets/chat-apc", isDirectory: true)
    try FileManager.default.createDirectory(at: inferletDir, withIntermediateDirectories: true)
    let wasm = inferletDir.appendingPathComponent("chat-apc.wasm", isDirectory: false)
    let manifest = inferletDir.appendingPathComponent("Pie.toml", isDirectory: false)
    try Data([0x00, 0x61, 0x73, 0x6d]).write(to: wasm)
    try Data("name = \"chat-apc\"\nversion = \"0.1.0\"\n".utf8).write(to: manifest)

    let helperBundle = try XCTUnwrap(Bundle(url: helper))
    let resolved = try InferletResources.pieControl(in: helperBundle)

    XCTAssertEqual(resolved.wasm, wasm)
    XCTAssertEqual(resolved.manifest, manifest)
  }

  private func makeAppBundle(named name: String, bundleID: String) throws -> URL {
    let app = tempDir.appendingPathComponent("\(name).app", isDirectory: true)
    let contents = app.appendingPathComponent("Contents", isDirectory: true)
    try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
    let plist = """
    <?xml version="1.0" encoding="UTF-8"?>
    <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
    <plist version="1.0">
    <dict>
      <key>CFBundleIdentifier</key>
      <string>\(bundleID)</string>
      <key>CFBundleName</key>
      <string>\(name)</string>
      <key>CFBundlePackageType</key>
      <string>APPL</string>
    </dict>
    </plist>
    """
    try plist.write(to: contents.appendingPathComponent("Info.plist", isDirectory: false),
                    atomically: true,
                    encoding: .utf8)
    return app
  }
}
