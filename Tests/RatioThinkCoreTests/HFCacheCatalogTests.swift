import XCTest
@testable import RatioThinkCore

/// Unit tests for `HFCacheCatalog.scan`: enumerate the shared HF cache,
/// list only complete repos (weight present), decode slugs that
/// round-trip through `HFCacheResolver`, and skip partial / non-model
/// entries.
final class HFCacheCatalogTests: XCTestCase {
  private var tempDir: URL!

  override func setUpWithError() throws {
    tempDir = URL(fileURLWithPath: NSTemporaryDirectory())
      .appendingPathComponent("hfcat-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
  }

  override func tearDownWithError() throws {
    try? FileManager.default.removeItem(at: tempDir)
  }

  // MARK: - repoID decoding

  func test_repoID_decodes_two_segment_repo() {
    XCTAssertEqual(HFCacheCatalog.repoID(fromCacheDirName: "models--Qwen--Qwen3-0.6B"),
                   "Qwen/Qwen3-0.6B")
  }

  func test_repoID_rejects_non_model_caches() {
    XCTAssertNil(HFCacheCatalog.repoID(fromCacheDirName: "datasets--foo--bar"))
    XCTAssertNil(HFCacheCatalog.repoID(fromCacheDirName: ".locks"))
    XCTAssertNil(HFCacheCatalog.repoID(fromCacheDirName: "version.txt"))
  }

  func test_repoID_rejects_single_segment_repo() {
    // Single-name repos (e.g. `gpt2`) aren't resolvable by HFCacheResolver
    // either; both require <org>/<name>.
    XCTAssertNil(HFCacheCatalog.repoID(fromCacheDirName: "models--gpt2"))
  }

  // MARK: - scan

  func test_scan_lists_complete_safetensors_repo_with_resolvable_slug() throws {
    let hfHome = tempDir.appendingPathComponent("hf", isDirectory: true)
    try writeHFCacheSnapshot(hfHome: hfHome, repo: "Qwen/Qwen3-0.6B", files: [
      "config.json": "{}",
      "tokenizer.json": "{}",
      "model.safetensors": "weights-bytes",
    ])

    let rows = HFCacheCatalog.scan(hfHome: hfHome)
    XCTAssertEqual(rows.map(\.filename), ["Qwen/Qwen3-0.6B"])
    let row = try XCTUnwrap(rows.first)
    XCTAssertEqual(row.source, .huggingFaceCache)
    XCTAssertGreaterThan(row.sizeBytes, 0)
    XCTAssertFalse(row.isPartial)

    // The listed slug must round-trip through the resolver the launch
    // path uses — otherwise it would not be selectable.
    guard case .hit = HFCacheResolver(hfHome: hfHome).resolve(repo: row.filename) else {
      return XCTFail("listed slug \(row.filename) must resolve back to a cache hit")
    }
  }

  // A cached GGUF repo must list the .gguf FILE as a 3-segment slug (so
  // the resolver writes the file path to hf_repo, not the snapshot dir),
  // sized to that file alone.
  func test_scan_lists_gguf_repo_as_per_file_slug() throws {
    let hfHome = tempDir.appendingPathComponent("hf", isDirectory: true)
    try writeHFCacheSnapshot(hfHome: hfHome, repo: "Qwen/Qwen3-0.6B-GGUF", files: [
      "config.json": "{}",
      "tokenizer.json": "{}",
      "Qwen3-0.6B-Q8_0.gguf": String(repeating: "w", count: 5000),
    ])
    let rows = HFCacheCatalog.scan(hfHome: hfHome)
    XCTAssertEqual(rows.map(\.filename), ["Qwen/Qwen3-0.6B-GGUF/Qwen3-0.6B-Q8_0.gguf"],
                   "GGUF repo must list the .gguf file (3-segment slug), not the snapshot dir")
    let row = try XCTUnwrap(rows.first)
    XCTAssertEqual(row.sizeBytes, 5000, "GGUF row size must be the .gguf file, not the snapshot sum")
    XCTAssertTrue(row.url.lastPathComponent.hasSuffix(".gguf"))
  }

  // Each quant in a multi-GGUF repo is its own option, each sized to just
  // that quant.
  func test_scan_lists_each_gguf_quant_separately() throws {
    let hfHome = tempDir.appendingPathComponent("hf", isDirectory: true)
    try writeHFCacheSnapshot(hfHome: hfHome, repo: "Qwen/Qwen3-0.6B-GGUF", files: [
      "config.json": "{}",
      "tokenizer.json": "{}",
      "Qwen3-0.6B-Q8_0.gguf": String(repeating: "a", count: 8000),
      "Qwen3-0.6B-Q4_K_M.gguf": String(repeating: "b", count: 4000),
    ])
    let rows = HFCacheCatalog.scan(hfHome: hfHome)
    XCTAssertEqual(Set(rows.map(\.filename)),
                   ["Qwen/Qwen3-0.6B-GGUF/Qwen3-0.6B-Q8_0.gguf",
                    "Qwen/Qwen3-0.6B-GGUF/Qwen3-0.6B-Q4_K_M.gguf"])
    let q8 = try XCTUnwrap(rows.first { $0.filename.hasSuffix("Q8_0.gguf") })
    let q4 = try XCTUnwrap(rows.first { $0.filename.hasSuffix("Q4_K_M.gguf") })
    XCTAssertEqual(q8.sizeBytes, 8000)
    XCTAssertEqual(q4.sizeBytes, 4000, "each quant sized independently, never the sum")
  }

  // A repo shipping BOTH safetensors and gguf must surface the
  // directory-loaded safetensors variant (2-segment slug) ALONGSIDE the
  // per-file gguf rows — neither silently drops the other. pie's portable
  // driver loads a snapshot directory as safetensors and never consults
  // stray .gguf siblings (driver/portable/src/model.cpp), so the 2-segment
  // dir slug is a valid, distinct choice.
  func test_scan_emits_safetensors_dir_row_alongside_gguf_when_repo_has_both() throws {
    let hfHome = tempDir.appendingPathComponent("hf", isDirectory: true)
    try writeHFCacheSnapshot(hfHome: hfHome, repo: "Qwen/Qwen3-0.6B", files: [
      "config.json": "{}",
      "tokenizer.json": "{}",
      "model.safetensors": String(repeating: "s", count: 3000),
      "Qwen3-0.6B-Q8_0.gguf": String(repeating: "g", count: 5000),
    ])
    let rows = HFCacheCatalog.scan(hfHome: hfHome)
    XCTAssertEqual(Set(rows.map(\.filename)),
                   ["Qwen/Qwen3-0.6B",
                    "Qwen/Qwen3-0.6B/Qwen3-0.6B-Q8_0.gguf"],
                   "a mixed repo must list BOTH the safetensors snapshot-dir slug and the per-file gguf slug")

    // The safetensors variant is the 2-segment slug → must resolve to the
    // snapshot DIRECTORY (what the portable driver loads as safetensors).
    let dirRow = try XCTUnwrap(rows.first { $0.filename == "Qwen/Qwen3-0.6B" })
    XCTAssertEqual(dirRow.source, .huggingFaceCache)
    guard case .hit(let resolved) = HFCacheResolver(hfHome: hfHome).resolve(repo: dirRow.filename) else {
      return XCTFail("safetensors dir slug \(dirRow.filename) must resolve back to a cache hit")
    }
    var isDir: ObjCBool = false
    XCTAssertTrue(
      FileManager.default.fileExists(atPath: resolved.path, isDirectory: &isDir) && isDir.boolValue,
      "the 2-segment slug must resolve to the snapshot directory")
    // Dir-row size is the whole-snapshot sum (incl. the gguf bytes), matching
    // ModelMemoryGuardrail.summarizeDirectory's load-time gate so the picker's
    // over-limit badge agrees with what the gate will enforce.
    XCTAssertGreaterThanOrEqual(dirRow.sizeBytes, 8000,
                                "dir row sizes the whole snapshot, consistent with the load-time guardrail")

    // The gguf variant stays a per-file slug sized to just that quant.
    let ggufRow = try XCTUnwrap(rows.first { $0.filename.hasSuffix(".gguf") })
    XCTAssertEqual(ggufRow.sizeBytes, 5000, "gguf row sized to the .gguf file alone")
    XCTAssertTrue(ggufRow.url.lastPathComponent.hasSuffix(".gguf"))
  }

  // A single GGUF model split across `…-NNNNN-of-MMMMM.gguf` shards must
  // collapse into ONE option, not N single-shard rows. pie's portable
  // driver loads a single .gguf file (no split auto-discovery), so the
  // option points at the FIRST shard — the llama.cpp split entry-point
  // convention — and is sized to the sum.
  func test_scan_collapses_sharded_gguf_into_one_option() throws {
    let hfHome = tempDir.appendingPathComponent("hf", isDirectory: true)
    try writeHFCacheSnapshot(hfHome: hfHome, repo: "unsloth/DeepSeek-R1-GGUF", files: [
      "config.json": "{}",
      "tokenizer.json": "{}",
      "DeepSeek-R1-Q4_K_M-00001-of-00003.gguf": String(repeating: "a", count: 1000),
      "DeepSeek-R1-Q4_K_M-00002-of-00003.gguf": String(repeating: "b", count: 2000),
      "DeepSeek-R1-Q4_K_M-00003-of-00003.gguf": String(repeating: "c", count: 3000),
    ])
    let rows = HFCacheCatalog.scan(hfHome: hfHome)
    XCTAssertEqual(rows.map(\.filename),
                   ["unsloth/DeepSeek-R1-GGUF/DeepSeek-R1-Q4_K_M-00001-of-00003.gguf"],
                   "a sharded GGUF must collapse to one row at the first shard, not N rows")
    let row = try XCTUnwrap(rows.first)
    XCTAssertEqual(row.sizeBytes, 6000, "collapsed shard row is sized to the sum of all shards")
    XCTAssertTrue(row.url.lastPathComponent.hasSuffix("-00001-of-00003.gguf"),
                  "the collapsed row's url points at the first shard")
    XCTAssertNotNil(row.unsupportedReason,
                    "a collapsed sharded row must be marked UNLAUNCHABLE — pie can't load a split GGUF")
  }

  // Two distinct sharded quants in one repo stay two options — collapse
  // must key on the quant, not lump every shard together.
  func test_scan_keeps_distinct_sharded_quants_separate() throws {
    let hfHome = tempDir.appendingPathComponent("hf", isDirectory: true)
    try writeHFCacheSnapshot(hfHome: hfHome, repo: "unsloth/Big-GGUF", files: [
      "config.json": "{}",
      "tokenizer.json": "{}",
      "Big-Q8_0-00001-of-00002.gguf": String(repeating: "a", count: 1000),
      "Big-Q8_0-00002-of-00002.gguf": String(repeating: "a", count: 1000),
      "Big-Q4_K_M-00001-of-00003.gguf": String(repeating: "b", count: 500),
      "Big-Q4_K_M-00002-of-00003.gguf": String(repeating: "b", count: 500),
      "Big-Q4_K_M-00003-of-00003.gguf": String(repeating: "b", count: 500),
    ])
    let rows = HFCacheCatalog.scan(hfHome: hfHome)
    XCTAssertEqual(Set(rows.map(\.filename)),
                   ["unsloth/Big-GGUF/Big-Q8_0-00001-of-00002.gguf",
                    "unsloth/Big-GGUF/Big-Q4_K_M-00001-of-00003.gguf"],
                   "each sharded quant collapses to its own first-shard option")
    let q8 = try XCTUnwrap(rows.first { $0.filename.contains("Q8_0") })
    let q4 = try XCTUnwrap(rows.first { $0.filename.contains("Q4_K_M") })
    XCTAssertEqual(q8.sizeBytes, 2000, "Q8_0 sized to its own two shards")
    XCTAssertEqual(q4.sizeBytes, 1500, "Q4_K_M sized to its own three shards")
    XCTAssertNotNil(q8.unsupportedReason, "each collapsed sharded quant is unlaunchable")
    XCTAssertNotNil(q4.unsupportedReason, "each collapsed sharded quant is unlaunchable")
  }

  // A sharded set alongside an unsharded standalone .gguf — the standalone
  // is not folded into the shard set.
  func test_scan_keeps_sharded_and_unsharded_gguf_distinct() throws {
    let hfHome = tempDir.appendingPathComponent("hf", isDirectory: true)
    try writeHFCacheSnapshot(hfHome: hfHome, repo: "vendor/Mixed-GGUF", files: [
      "config.json": "{}",
      "tokenizer.json": "{}",
      "Mixed-Q4_K_M-00001-of-00002.gguf": String(repeating: "a", count: 1000),
      "Mixed-Q4_K_M-00002-of-00002.gguf": String(repeating: "a", count: 1000),
      "Mixed-Q8_0.gguf": String(repeating: "b", count: 777),
    ])
    let rows = HFCacheCatalog.scan(hfHome: hfHome)
    XCTAssertEqual(Set(rows.map(\.filename)),
                   ["vendor/Mixed-GGUF/Mixed-Q4_K_M-00001-of-00002.gguf",
                    "vendor/Mixed-GGUF/Mixed-Q8_0.gguf"],
                   "the standalone quant stays its own row, separate from the shard set")
    let sharded = try XCTUnwrap(rows.first { $0.filename.contains("-00001-of-") })
    let standalone = try XCTUnwrap(rows.first { $0.filename.hasSuffix("Mixed-Q8_0.gguf") })
    XCTAssertEqual(sharded.sizeBytes, 2000, "shard set sized to its two shards")
    XCTAssertEqual(standalone.sizeBytes, 777, "standalone sized to itself alone")
    XCTAssertNotNil(sharded.unsupportedReason, "the collapsed shard set is unlaunchable")
    XCTAssertNil(standalone.unsupportedReason, "the standalone single-file quant stays launchable")
  }

  func test_scan_skips_partial_repo_without_weights() throws {
    let hfHome = tempDir.appendingPathComponent("hf", isDirectory: true)
    // Metadata present but no weight artifact — an interrupted pull.
    try writeHFCacheSnapshot(hfHome: hfHome, repo: "Qwen/Qwen3-0.6B", files: [
      "config.json": "{}",
      "tokenizer.json": "{}",
    ])
    XCTAssertEqual(HFCacheCatalog.scan(hfHome: hfHome), [],
                   "a snapshot without a resolved weight is not a selectable model")
  }

  func test_scan_skips_non_model_directories() throws {
    let hfHome = tempDir.appendingPathComponent("hf", isDirectory: true)
    try writeHFCacheSnapshot(hfHome: hfHome, repo: "Qwen/Qwen3-0.6B", files: [
      "config.json": "{}",
      "tokenizer.json": "{}",
      "model.safetensors": "weights",
    ])
    // A dataset cache + a stray lock dir must be ignored.
    let hub = hfHome.appendingPathComponent("hub", isDirectory: true)
    try FileManager.default.createDirectory(
      at: hub.appendingPathComponent("datasets--foo--bar", isDirectory: true),
      withIntermediateDirectories: true)
    try FileManager.default.createDirectory(
      at: hub.appendingPathComponent(".locks", isDirectory: true),
      withIntermediateDirectories: true)

    XCTAssertEqual(HFCacheCatalog.scan(hfHome: hfHome).map(\.filename), ["Qwen/Qwen3-0.6B"])
  }

  func test_scan_lists_multiple_repos() throws {
    let hfHome = tempDir.appendingPathComponent("hf", isDirectory: true)
    for repo in ["Qwen/Qwen3-0.6B", "meta-llama/Llama-3.2-1B"] {
      try writeHFCacheSnapshot(hfHome: hfHome, repo: repo, files: [
        "config.json": "{}",
        "tokenizer.json": "{}",
        "model.safetensors": "weights",
      ])
    }
    XCTAssertEqual(Set(HFCacheCatalog.scan(hfHome: hfHome).map(\.filename)),
                   ["Qwen/Qwen3-0.6B", "meta-llama/Llama-3.2-1B"])
  }

  func test_scan_missing_cache_returns_empty() {
    let hfHome = tempDir.appendingPathComponent("does-not-exist", isDirectory: true)
    XCTAssertEqual(HFCacheCatalog.scan(hfHome: hfHome), [])
  }

  // MARK: - shard-pattern primitive

  // `isSplitShardFilename` (and the `shardComponents` parser behind it)
  // is the load-bearing primitive for BOTH the catalog collapse and the
  // resolver guard. Pin its boundary: it must match ONLY the zero-padded
  // 5-digit lowercase `…-NNNNN-of-MMMMM.gguf` convention, and degrade to
  // false on every near-miss (false = per-file row, no merge / no guard).
  func test_isSplitShardFilename_matches_only_the_canonical_split_suffix() {
    // Canonical split shards (any member, not just the first).
    XCTAssertTrue(HFCacheCatalog.isSplitShardFilename("Qwen3-235B-Q4_K_M-00001-of-00003.gguf"))
    XCTAssertTrue(HFCacheCatalog.isSplitShardFilename("m-00002-of-00002.gguf"))

    // Near-misses must NOT match.
    XCTAssertFalse(HFCacheCatalog.isSplitShardFilename("m-0001-of-0003.gguf"),
                   "4-digit index is not the gguf-split convention")
    XCTAssertFalse(HFCacheCatalog.isSplitShardFilename("m-00001-OF-00003.GGUF"),
                   "uppercase -OF- token must not match (lowercase token only; safe per-file degrade)")
    XCTAssertFalse(HFCacheCatalog.isSplitShardFilename("m-00001-of.gguf"),
                   "truncated suffix is not a shard")
    XCTAssertFalse(HFCacheCatalog.isSplitShardFilename("-00001-of-00003.gguf"),
                   "empty base (stem == suffix) must not match")

    // A plain single-file quant is launchable, not a shard.
    XCTAssertFalse(HFCacheCatalog.isSplitShardFilename("Qwen3-0.6B-Q8_0.gguf"))
    XCTAssertFalse(HFCacheCatalog.isSplitShardFilename("model.safetensors"))
  }

  // MARK: - fixtures

  @discardableResult
  private func writeHFCacheSnapshot(
    hfHome: URL,
    repo: String,
    revision: String = "0123456789abcdef0123456789abcdef01234567",
    files: [String: String]
  ) throws -> URL {
    let repoDir = hfHome
      .appendingPathComponent("hub", isDirectory: true)
      .appendingPathComponent("models--\(repo.replacingOccurrences(of: "/", with: "--"))",
                              isDirectory: true)
    let refsDir = repoDir.appendingPathComponent("refs", isDirectory: true)
    let snapshot = repoDir
      .appendingPathComponent("snapshots", isDirectory: true)
      .appendingPathComponent(revision, isDirectory: true)
    try FileManager.default.createDirectory(at: refsDir, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: snapshot, withIntermediateDirectories: true)
    try revision.write(to: refsDir.appendingPathComponent("main"),
                       atomically: true, encoding: .utf8)
    for (relativePath, contents) in files {
      let url = snapshot.appendingPathComponent(relativePath, isDirectory: false)
      try FileManager.default.createDirectory(
        at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
      try contents.write(to: url, atomically: true, encoding: .utf8)
    }
    return snapshot
  }
}
