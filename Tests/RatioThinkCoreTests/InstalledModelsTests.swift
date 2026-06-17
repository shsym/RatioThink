import XCTest
@testable import RatioThinkCore

/// Unit tests for `InstalledModels.scan` + `formattedSize`. Pure
/// directory scan — uses scratch dirs under `NSTemporaryDirectory()`
/// so no `PIE_HOME` override is needed.
final class InstalledModelsTests: XCTestCase {

  // MARK: - scan

  func test_scan_empty_dir_returns_empty_array() throws {
    try withTempDir { dir in
      let rows = try InstalledModels.scan(dir)
      XCTAssertEqual(rows, [])
    }
  }

  func test_scan_picks_up_gguf_and_ignores_other_files() throws {
    try withTempDir { dir in
      try writeFile("alpha.gguf", bytes: 1234, in: dir, modified: Date(timeIntervalSince1970: 2_000))
      try writeFile("beta.txt",   bytes: 99,   in: dir, modified: Date(timeIntervalSince1970: 3_000))
      try writeFile("gamma.GGUF", bytes: 4567, in: dir, modified: Date(timeIntervalSince1970: 1_000))

      let rows = try InstalledModels.scan(dir)
      XCTAssertEqual(rows.map(\.filename), ["alpha.gguf", "gamma.GGUF"],
                     "expected only .gguf rows, sorted by descending mtime")
      XCTAssertEqual(rows.first?.sizeBytes, 1234)
      XCTAssertEqual(rows.first?.isPartial, false)
    }
  }

  func test_scan_flags_partial_sibling() throws {
    try withTempDir { dir in
      try writeFile("model.gguf",         bytes: 100, in: dir)
      try writeFile("model.gguf.partial", bytes: 50,  in: dir)
      let rows = try InstalledModels.scan(dir)
      XCTAssertEqual(rows.count, 1, "the .partial sibling should not surface as its own row")
      XCTAssertEqual(rows[0].filename, "model.gguf")
      XCTAssertTrue(rows[0].isPartial,
                    "row should be marked partial when <name>.partial exists alongside")
    }
  }

  //  F10: durable unverified marker.
  func test_scan_flags_unverified_sidecar() throws {
    try withTempDir { dir in
      try writeFile("model.gguf",            bytes: 100, in: dir)
      try writeFile("model.gguf.unverified", bytes: 0,   in: dir)
      let rows = try InstalledModels.scan(dir)
      XCTAssertEqual(rows.count, 1, "the .unverified sidecar should not surface as its own row")
      XCTAssertEqual(rows[0].filename, "model.gguf")
      XCTAssertTrue(rows[0].isUnverified,
                    "row should be flagged unverified when <name>.unverified exists alongside")
    }
  }

  func test_scan_clean_gguf_is_not_unverified() throws {
    try withTempDir { dir in
      try writeFile("model.gguf", bytes: 100, in: dir)
      let rows = try InstalledModels.scan(dir)
      XCTAssertEqual(rows.count, 1)
      XCTAssertFalse(rows[0].isUnverified,
                     "a GGUF with no .unverified sidecar must read as verified/clean")
    }
  }

  func test_scan_sorts_descending_by_modification_time() throws {
    try withTempDir { dir in
      try writeFile("old.gguf", bytes: 1, in: dir, modified: Date(timeIntervalSince1970: 1_000))
      try writeFile("new.gguf", bytes: 1, in: dir, modified: Date(timeIntervalSince1970: 9_999))
      let rows = try InstalledModels.scan(dir)
      XCTAssertEqual(rows.map(\.filename), ["new.gguf", "old.gguf"])
    }
  }

  ///  review v2 F1: curated downloads land nested at
  /// `<modelsRoot>/<repo>/<file>`. The scan must recurse so they appear
  /// in the installed list, with the resolvable `<repo>/<file>` slug as
  /// the row identity and the friendly leaf as `displayName`.
  func test_scan_recurses_into_nested_curated_download_layout() throws {
    try withTempDir { dir in
      let nested = dir.appendingPathComponent("Qwen/Qwen3-0.6B-GGUF", isDirectory: true)
      try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
      try Data("gguf".utf8).write(to: nested.appendingPathComponent("Qwen3-0.6B-Q8_0.gguf"))

      let rows = try InstalledModels.scan(dir)
      let row = try XCTUnwrap(
        rows.first { $0.filename == "Qwen/Qwen3-0.6B-GGUF/Qwen3-0.6B-Q8_0.gguf" },
        "nested curated download must appear with its `<repo>/<file>` slug as the row id")
      XCTAssertEqual(row.displayName, "Qwen3-0.6B-Q8_0.gguf",
                     "display must be the friendly leaf, not the raw slug")
    }
  }

  ///  review v3 F1: an unreadable nested directory must surface a
  /// `.traversalFailed` error, not silently skip — a model staged under
  /// it must not masquerade as "no models installed".
  func test_scan_surfaces_unreadable_nested_directory() throws {
    try withTempDir { dir in
      let repo = dir.appendingPathComponent("repo", isDirectory: true)
      try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
      try Data("gguf".utf8).write(to: repo.appendingPathComponent("model.gguf"))
      try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: repo.path)
      // Restore before withTempDir's cleanup can remove the tree.
      defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: repo.path) }

      XCTAssertThrowsError(try InstalledModels.scan(dir)) { err in
        guard case InstalledModelsError.traversalFailed = err else {
          XCTFail("expected .traversalFailed for an unreadable nested dir, got \(err)")
          return
        }
      }
    }
  }

  /// A directory named `X.gguf` must not be emitted as a model row —
  /// never a phantom clean row ( v1 F1). This is the deterministic
  /// half of the dir-skip guarantee; the `resourceValues`-throw →
  /// `metadataUnreadable` branch is not reliably reproducible in-tier
  /// (same platform-fragility noted on
  /// `test_installed_model_carries_metadata_unreadable_flag`).
  func test_scan_ignores_directory_named_like_a_model() throws {
    try withTempDir { dir in
      try FileManager.default.createDirectory(
        at: dir.appendingPathComponent("notamodel.gguf", isDirectory: true),
        withIntermediateDirectories: true)
      let rows = try InstalledModels.scan(dir)
      XCTAssertTrue(rows.isEmpty, "a directory with a .gguf name is not an installed model")
    }
  }

  ///  F1: a user-placed symlink whose target is a real `.gguf` blob
  /// must appear in the installed list. The enumerator yields the
  /// unresolved link node, so the old `.isRegularFileKey` guard reported
  /// `isRegularFile == false` and silently dropped it; the `.isDirectoryKey`
  /// guard keeps it.
  func test_scan_includes_symlink_to_real_gguf() throws {
    try withTempDir { dir in
      // Target deliberately lacks the `.gguf` suffix so only the symlink
      // matches the extension filter — isolates the symlink behavior.
      let target = dir.appendingPathComponent("blob.bin")
      try Data("gguf".utf8).write(to: target)
      let link = dir.appendingPathComponent("link.gguf")
      try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)

      let rows = try InstalledModels.scan(dir)
      XCTAssertEqual(rows.map(\.filename), ["link.gguf"],
                     "a .gguf symlink pointing at a real blob must be included")
      XCTAssertFalse(rows[0].metadataUnreadable,
                     "the symlink resolves to a readable file, so it is not metadata-unreadable")
      XCTAssertEqual(rows[0].sizeBytes, 4,
                     "size must reflect the resolved target (\"gguf\" = 4 B), not the link node's path length")
    }
  }

  ///  v2: a dangling `.gguf` symlink (target missing) must NOT surface
  /// as a clean readable row. A direct `resourceValues` read does not
  /// follow the link, so before the resolve-the-target fix it appended a
  /// phantom ~114 B clean row; now the resolved read throws and the row is
  /// flagged `metadataUnreadable` (or absent).
  func test_scan_dangling_symlink_is_not_a_clean_row() throws {
    try withTempDir { dir in
      let dangling = dir.appendingPathComponent("broken.gguf")
      try FileManager.default.createSymbolicLink(
        at: dangling,
        withDestinationURL: dir.appendingPathComponent("does-not-exist"))

      let rows = try InstalledModels.scan(dir)
      XCTAssertFalse(
        rows.contains { $0.filename == "broken.gguf" && !$0.metadataUnreadable },
        "a dangling symlink must never surface as a clean readable model row")
      if let row = rows.first(where: { $0.filename == "broken.gguf" }) {
        XCTAssertTrue(row.metadataUnreadable)
        XCTAssertEqual(row.sizeBytes, 0)
      }
    }
  }

  ///  v2: a `.gguf` symlink whose target is a directory must NOT
  /// surface as a clean model row — the resolved target is a directory, so
  /// it degrades to the dir-skip path (absent) rather than a phantom row.
  func test_scan_symlink_to_directory_is_not_a_clean_row() throws {
    try withTempDir { dir in
      let realDir = dir.appendingPathComponent("real-dir", isDirectory: true)
      try FileManager.default.createDirectory(at: realDir, withIntermediateDirectories: true)
      let link = dir.appendingPathComponent("dirlink.gguf")
      try FileManager.default.createSymbolicLink(at: link, withDestinationURL: realDir)

      let rows = try InstalledModels.scan(dir)
      XCTAssertFalse(
        rows.contains { $0.filename == "dirlink.gguf" && !$0.metadataUnreadable },
        "a symlink-to-directory must never surface as a clean readable model row")
    }
  }

  func test_scan_throws_when_directory_missing() {
    let missing = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
      .appendingPathComponent("pie-test-missing-\(UUID().uuidString)", isDirectory: true)
    XCTAssertThrowsError(try InstalledModels.scan(missing)) { err in
      guard case InstalledModelsError.directoryUnreadable = err else {
        XCTFail("expected .directoryUnreadable, got \(err)")
        return
      }
    }
  }

  /// Pins the `metadataUnreadable` surface (review v2 F4): public
  /// init exposes the field, default is `false`, and the
  /// `InstalledModel` is `Equatable` on it. The actual
  /// resourceValues-throws code path is exercised by hand at the
  /// integration boundary — engineering a reproducible
  /// resourceValues failure under XCTest is platform-fragile
  /// (chmod 000 inside `/tmp` does not always trigger it on dev
  /// machines), so we sub for a direct constructor test here.
  func test_installed_model_carries_metadata_unreadable_flag() {
    let url = URL(fileURLWithPath: "/tmp/example.gguf")
    let healthy = InstalledModel(filename: "example.gguf",
                                 url: url,
                                 sizeBytes: 42,
                                 modifiedAt: Date(timeIntervalSince1970: 1_000),
                                 isPartial: false)
    XCTAssertFalse(healthy.metadataUnreadable,
                   "default should be false to preserve source-compat with callers that don't set it")

    let flagged = InstalledModel(filename: "example.gguf",
                                 url: url,
                                 sizeBytes: 0,
                                 modifiedAt: Date(timeIntervalSince1970: 0),
                                 isPartial: false,
                                 metadataUnreadable: true)
    XCTAssertTrue(flagged.metadataUnreadable)
    XCTAssertNotEqual(healthy, flagged,
                      "metadataUnreadable must participate in Equatable so SwiftUI re-renders on the flag flip")
  }

  // MARK: - formattedSize

  func test_formattedSize_humanizes_bytes_into_units() {
    XCTAssertEqual(InstalledModels.formattedSize(0), "0 B")
    XCTAssertEqual(InstalledModels.formattedSize(512), "512 B")
    XCTAssertEqual(InstalledModels.formattedSize(2048), "2.0 KB")
    XCTAssertEqual(InstalledModels.formattedSize(5 * 1024 * 1024), "5.0 MB")
    // 2.5 GB — picks GB unit, two decimals collapse to one
    let twoAndAHalfGB: Int64 = Int64(2.5 * 1024 * 1024 * 1024)
    XCTAssertEqual(InstalledModels.formattedSize(twoAndAHalfGB), "2.5 GB")
  }

  // MARK: - authoritative GGUF quant (#667)

  func test_scan_reads_authoritative_quant_and_flags_name_mismatch() throws {
    try withTempDir { dir in
      // Filename claims Q4_K_M, but the header `general.file_type` is Q8_0
      // (LLAMA_FTYPE_MOSTLY_Q8_0 = 7) — the exact mislabel #667 is about.
      try writeGGUFFile("Model-Q4_K_M.gguf", fileType: 7, in: dir)
      let rows = try InstalledModels.scan(dir)
      XCTAssertEqual(rows.count, 1)
      XCTAssertEqual(rows[0].fileQuant, "Q8_0", "quant read from the header, not the filename")
      XCTAssertEqual(rows[0].effectiveQuant, "Q8_0", "display prefers the authoritative quant")
      XCTAssertNotNil(rows[0].quantMismatchWarning,
                      "filename says Q4_K_M but the file is Q8_0 → flagged")
    }
  }

  func test_scan_honest_filename_has_quant_but_no_mismatch() throws {
    try withTempDir { dir in
      try writeGGUFFile("Model-Q8_0.gguf", fileType: 7, in: dir)  // both say Q8_0
      let rows = try InstalledModels.scan(dir)
      XCTAssertEqual(rows[0].fileQuant, "Q8_0")
      XCTAssertNil(rows[0].quantMismatchWarning, "name and file agree → no warning")
    }
  }

  // F1: the ticket's literal case — a `…4bit` NAME (non-canonical, ignored by
  // the Q-token parser) over a Q8_0 file must still raise the warning.
  func test_scan_flags_noncanonical_bitwidth_name_mismatch() throws {
    try withTempDir { dir in
      try writeGGUFFile("Qwen3-0.6B-4bit.gguf", fileType: 7, in: dir)  // header Q8_0
      let rows = try InstalledModels.scan(dir)
      XCTAssertEqual(rows[0].fileQuant, "Q8_0")
      XCTAssertEqual(rows[0].effectiveQuant, "Q8_0", "display shows the real quant")
      XCTAssertNotNil(rows[0].quantMismatchWarning,
                      "name '4bit' over a Q8_0 file → warning fires")
    }
  }

  func test_scan_noncanonical_bitwidth_name_that_agrees_has_no_warning() throws {
    try withTempDir { dir in
      try writeGGUFFile("Qwen3-0.6B-8bit.gguf", fileType: 7, in: dir)  // header Q8_0
      let rows = try InstalledModels.scan(dir)
      XCTAssertNil(rows[0].quantMismatchWarning, "name '8bit' matches Q8_0's family → no warning")
    }
  }

  func test_scan_skips_quant_read_for_partial_download() throws {
    try withTempDir { dir in
      try writeGGUFFile("Model-Q8_0.gguf", fileType: 7, in: dir)
      try writeFile("Model-Q8_0.gguf.partial", bytes: 10, in: dir)
      let rows = try InstalledModels.scan(dir)
      XCTAssertEqual(rows.count, 1)
      XCTAssertTrue(rows[0].isPartial)
      XCTAssertNil(rows[0].fileQuant,
                   "an in-progress download's header may be incomplete; quant read is skipped")
    }
  }

  func test_scan_unrecognized_header_leaves_filename_quant() throws {
    try withTempDir { dir in
      // Garbage bytes → bad GGUF magic → no header quant; the filename quant
      // (Q8_0) remains the displayed value, preserving pre-#667 behavior.
      try writeFile("Model-Q8_0.gguf", bytes: 64, in: dir)
      let rows = try InstalledModels.scan(dir)
      XCTAssertNil(rows[0].fileQuant)
      XCTAssertEqual(rows[0].effectiveQuant, "Q8_0", "falls back to the filename quant")
      XCTAssertNil(rows[0].quantMismatchWarning)
    }
  }

  // MARK: - helpers

  /// Write a minimal valid GGUF carrying a single `general.file_type` KV
  /// (UINT32) so the scanner's header probe has something authoritative to
  /// read. Mirrors the llama.cpp gguf.h little-endian layout.
  private func writeGGUFFile(_ name: String, fileType: UInt32, in dir: URL) throws {
    func u32(_ v: UInt32) -> Data { withUnsafeBytes(of: v.littleEndian) { Data($0) } }
    func u64(_ v: UInt64) -> Data { withUnsafeBytes(of: v.littleEndian) { Data($0) } }
    func gstr(_ s: String) -> Data { let b = Data(s.utf8); return u64(UInt64(b.count)) + b }
    let kv = gstr("general.file_type") + u32(4 /* UINT32 */) + u32(fileType)
    var body = Data("GGUF".utf8) + u32(3) /*version*/ + u64(0) /*tensor_count*/ + u64(1) /*kv count*/
    body += kv
    try body.write(to: dir.appendingPathComponent(name), options: .atomic)
  }

  private func withTempDir(_ body: (URL) throws -> Void) throws {
    let dir = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
      .appendingPathComponent("pie-installed-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    var bodyError: Error?
    do { try body(dir) } catch { bodyError = error }
    try FileManager.default.removeItem(at: dir)
    if let bodyError { throw bodyError }
  }

  private func writeFile(_ name: String,
                          bytes: Int,
                          in dir: URL,
                          modified: Date = Date()) throws {
    let url = dir.appendingPathComponent(name)
    let data = Data(repeating: 0x41, count: bytes)
    try data.write(to: url, options: .atomic)
    try FileManager.default.setAttributes([.modificationDate: modified], ofItemAtPath: url.path)
  }
}
