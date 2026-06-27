import XCTest
@testable import RatioThinkCore

/// #473 — the real-engine matrix wrapper (`Scripts/run-matrix-e2e.sh`) is
/// bash, so it cannot call into `CuratedModelCatalog`; it hardcodes the
/// curated model coordinates. This test is the anti-drift guard: it parses
/// the wrapper's `MATRIX_MODELS` block and asserts it is exactly the curated
/// catalog — same (repo, file), same published size used as the download
/// floor, and the right capability flags. A catalog entry added, removed,
/// re-coordinated, resized, or re-capability-tagged without updating the
/// wrapper (or vice versa) fails here in `make test-unit`, before the
/// silent-skip / phantom-model failure mode (#427) or a false-green partial
/// download (#122) can ship.
final class MatrixModelCatalogSyncTests: XCTestCase {
  private struct Row: Equatable {
    let repo: String
    let file: String
    let minBytes: Int64
    let thinking: Bool
    let semantic: Bool
    let reasonsInChat: Bool
  }

  func test_matrixWrapperModelsMatchCuratedCatalog() throws {
    let script = try readRepoFile("Scripts/run-matrix-e2e.sh")
    let wrapperRows = try parseMatrixModels(script)

    // The wrapper must enumerate every curated model exactly once.
    let catalogRows: [Row] = CuratedModelCatalog.all.map { m in
      Row(repo: m.huggingFaceRepo,
          file: m.huggingFaceFile,
          minBytes: m.approximateSizeBytes,
          // Thinking rows assert reasoning-content. The catalog has no
          // explicit flag, so derive it the same way the wrapper's
          // `thinking=1` rows must: Qwen3 repos, plus the operator-confirmed
          // Gemma 4 31B seated matrix cell.
          thinking: m.huggingFaceRepo.contains("Qwen3")
            || m.id == "gemma-4-31b-it-q4_k_m",
          // The weak semantic floor (#484) is capability-gated to the larger
          // tier; the small 0.5–1B models stay contract-level. Derive it from
          // the catalog param count the same way the wrapper's `semantic=1`
          // rows must: anything above the 1B small tier.
          semantic: m.parameterCountBillions > 1.0,
          // Plain-chat reasoning is model-specific. Qwen3-style rows emit a
          // default chat scratchpad; Gemma 4 requires explicit thinking and is
          // therefore verified by the thinking-profile assertion, not chat.
          reasonsInChat: m.huggingFaceRepo.contains("Qwen3"))
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
                     + "(check minBytes = approximateSizeBytes, thinking, semantic, and reasons-in-chat flags)")
    }

    // Full matrix must include every curated entry (operator-confirmed scope).
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

  func test_gemma4_31b_matrix_row_is_all_profile_and_kv_bounded() throws {
    let script = try readRepoFile("Scripts/run-matrix-e2e.sh")
    let slug = "unsloth/gemma-4-31B-it-GGUF/gemma-4-31B-it-Q4_K_M.gguf"
    XCTAssertTrue(
      script.contains("\"unsloth/gemma-4-31B-it-GGUF|gemma-4-31B-it-Q4_K_M.gguf|18323731456|1|1|0\""),
      "Gemma 4 31B must have a matrix row with thinking=1, semantic=1, reasonsInChat=0")
    let gemmaGuard = "if [ \"$slug\" = \"\(slug)\" ]; then"
    let guardSlice = try scriptSlice(script, from: gemmaGuard, throughNextLineEqualTo: "fi")
    XCTAssertTrue(guardSlice.contains("PIE_TEST_E2E_MAX_KV_PAGES=256"),
                  "Gemma 4 31B all-profile matrix run must shrink the KV page pool inside the exact slug guard")
    XCTAssertTrue(guardSlice.contains("PIE_TEST_E2E_DEFAULT_TOKEN_LIMIT=4096"),
                  "Gemma 4 31B all-profile matrix run must bound per-request output tokens inside the exact slug guard")
    XCTAssertTrue(script.contains("PIE_TEST_E2E_PROFILES:-$ALL_PROFILES"),
                  "matrix default must continue exercising chat/tree-of-thought/fast-think/ceiling")
  }

  /// Parse the `MATRIX_MODELS=( "repo|file|minBytes|thinking|semantic|reasonsInChat" ... )` array
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
      guard parts.count == 6, let minBytes = Int64(parts[2]),
            parts[3] == "0" || parts[3] == "1",
            parts[4] == "0" || parts[4] == "1",
            parts[5] == "0" || parts[5] == "1" else {
        XCTFail("malformed MATRIX_MODELS row: \(raw)")
        continue
      }
      rows.append(Row(repo: parts[0], file: parts[1], minBytes: minBytes,
                      thinking: parts[3] == "1", semantic: parts[4] == "1",
                      reasonsInChat: parts[5] == "1"))
    }
    XCTAssertFalse(rows.isEmpty, "parsed zero MATRIX_MODELS rows — parser or block drifted")
    return rows
  }

  /// Return the line-bounded slice from a required start marker through the
  /// next line whose trimmed content equals `endLine`. This is intentionally
  /// strict: if the Gemma-specific cap guard is renamed, removed, or
  /// reformatted away from a shell `if ...; then` / `fi` block, the anti-drift
  /// test should fail rather than quietly searching the whole script.
  private func scriptSlice(
    _ script: String,
    from startMarker: String,
    throughNextLineEqualTo endLine: String,
    file: StaticString = #filePath,
    line: UInt = #line
  ) throws -> String {
    let lines = script.components(separatedBy: .newlines)
    guard let start = lines.firstIndex(where: { $0.contains(startMarker) }) else {
      XCTFail("script slice start not found: \(startMarker)", file: file, line: line)
      throw XCTSkip("script slice start not found")
    }
    guard let end = lines[(start + 1)...].firstIndex(where: { $0.trimmingCharacters(in: .whitespaces) == endLine }) else {
      XCTFail("script slice end not found after: \(startMarker)", file: file, line: line)
      throw XCTSkip("script slice end not found")
    }
    return lines[start...end].joined(separator: "\n")
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
