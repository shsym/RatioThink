import XCTest
@testable import RatioThinkCore

/// #473 — the real-engine matrix wrapper (`Scripts/run-matrix-e2e.sh`) is
/// bash, so it cannot call into `CuratedModelCatalog`; it hardcodes the 10
/// curated model coordinates. This test is the anti-drift guard: it parses
/// the wrapper's `MATRIX_MODELS` block and asserts it is exactly the curated
/// catalog — same (repo, file), same published size used as the download
/// floor, and the right `thinking` flag. A catalog entry added, removed,
/// re-coordinated, or resized without updating the wrapper (or vice versa)
/// fails here in `make test-unit`, before the silent-skip / phantom-model
/// failure mode (#427) or a false-green partial download (#122) can ship.
final class MatrixModelCatalogSyncTests: XCTestCase {
  private struct Row: Equatable {
    let repo: String
    let file: String
    let minBytes: Int64
    let thinking: Bool
    let semantic: Bool
  }

  func test_matrixWrapperModelsMatchCuratedCatalog() throws {
    let script = try readRepoFile("Scripts/run-matrix-e2e.sh")
    let wrapperRows = try parseMatrixModels(script)

    // The wrapper must enumerate every curated model exactly once.
    let catalogRows: [Row] = CuratedModelCatalog.all.map { m in
      Row(repo: m.huggingFaceRepo,
          file: m.huggingFaceFile,
          minBytes: m.approximateSizeBytes,
          // Thinking models are the Qwen3 family (they emit `<think>`
          // scratchpads). The catalog has no explicit flag, so derive it
          // the same way the wrapper's `thinking=1` rows must: a Qwen3 repo.
          thinking: m.huggingFaceRepo.contains("Qwen3"),
          // The weak semantic floor (#484) is capability-gated to the larger
          // tier; the small 0.5–1B models stay contract-level. Derive it from
          // the catalog param count the same way the wrapper's `semantic=1`
          // rows must: anything above the 1B small tier.
          semantic: m.parameterCountBillions > 1.0)
    }

    // Order-independent: compare as sets keyed by slug so a reordering of
    // either list is not a spurious failure, but a content mismatch is.
    let wrapperBySlug = Dictionary(uniqueKeysWithValues: wrapperRows.map { ("\($0.repo)/\($0.file)", $0) })
    let catalogBySlug = Dictionary(uniqueKeysWithValues: catalogRows.map { ("\($0.repo)/\($0.file)", $0) })

    let wrapperSlugs = Set(wrapperBySlug.keys)
    let catalogSlugs = Set(catalogBySlug.keys)

    XCTAssertEqual(
      wrapperSlugs, catalogSlugs,
      "run-matrix-e2e.sh MATRIX_MODELS drifted from CuratedModelCatalog.all.\n"
      + "  only in wrapper: \(wrapperSlugs.subtracting(catalogSlugs).sorted())\n"
      + "  only in catalog: \(catalogSlugs.subtracting(wrapperSlugs).sorted())")

    for slug in catalogSlugs.intersection(wrapperSlugs).sorted() {
      XCTAssertEqual(wrapperBySlug[slug], catalogBySlug[slug],
                     "matrix wrapper row for \(slug) does not match the catalog "
                     + "(check minBytes = approximateSizeBytes, the thinking flag, and the semantic flag)")
    }

    // Full matrix must be all 10 curated entries (operator-confirmed scope).
    XCTAssertEqual(wrapperRows.count, CuratedModelCatalog.all.count,
                   "matrix must cover every curated model exactly once")
  }

  /// Negative guard: when the `MATRIX_MODELS=(` anchor is absent (renamed,
  /// reformatted, or removed), the parser must record a test FAILURE, never
  /// skip — otherwise drift ships green. `XCTExpectFailure` asserts a failure
  /// is recorded inside the closure and itself fails if none is.
  func test_driftGuard_failsNotSkips_whenAnchorMissing() {
    XCTExpectFailure("a missing MATRIX_MODELS anchor must be a hard failure, not a skip") {
      // Anchor deliberately renamed — `firstIndex(contains:)` won't match.
      _ = try? parseMatrixModels("#!/usr/bin/env bash\nMODELS=(\n  \"a/b.gguf|b.gguf|1|0\"\n)\n")
    }
  }

  /// Parse the `MATRIX_MODELS=( "repo|file|minBytes|thinking" ... )` array
  /// literal out of the wrapper. Tolerant of leading whitespace and the
  /// surrounding quotes; stops at the closing paren.
  private func parseMatrixModels(_ script: String) throws -> [Row] {
    let lines = script.components(separatedBy: .newlines)
    guard let start = lines.firstIndex(where: { $0.contains("MATRIX_MODELS=(") }) else {
      // This guard IS the anti-drift deliverable: if it cannot find its
      // anchor (array renamed, reformatted, or moved) it must FAIL, not skip
      // — a skip would let the wrapper and catalog diverge while make
      // test-unit stays green (the #427 silent-skip failure mode).
      XCTFail("MATRIX_MODELS=( … ) block not found in run-matrix-e2e.sh — drift guard cannot run")
      return []
    }
    var rows: [Row] = []
    for raw in lines[(start + 1)...] {
      let line = raw.trimmingCharacters(in: .whitespaces)
      if line == ")" { break }
      guard line.hasPrefix("\"") else { continue }
      let body = line.trimmingCharacters(in: CharacterSet(charactersIn: "\""))
      let parts = body.components(separatedBy: "|")
      guard parts.count == 5, let minBytes = Int64(parts[2]),
            parts[3] == "0" || parts[3] == "1",
            parts[4] == "0" || parts[4] == "1" else {
        XCTFail("malformed MATRIX_MODELS row: \(raw)")
        continue
      }
      rows.append(Row(repo: parts[0], file: parts[1], minBytes: minBytes,
                      thinking: parts[3] == "1", semantic: parts[4] == "1"))
    }
    XCTAssertFalse(rows.isEmpty, "parsed zero MATRIX_MODELS rows — parser or block drifted")
    return rows
  }

  private func readRepoFile(_ relativePath: String,
                            file: StaticString = #filePath,
                            line: UInt = #line) throws -> String {
    var url = URL(fileURLWithPath: "\(file)", isDirectory: false).deletingLastPathComponent()
    let fm = FileManager.default
    while url.path != "/" {
      if fm.fileExists(atPath: url.appendingPathComponent("Package.swift").path) {
        return try String(contentsOf: url.appendingPathComponent(relativePath), encoding: .utf8)
      }
      url.deleteLastPathComponent()
    }
    XCTFail("could not locate repository root from \(file)", file: file, line: line)
    throw CocoaError(.fileNoSuchFile)
  }
}
