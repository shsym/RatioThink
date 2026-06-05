import XCTest
@testable import RatioThinkCore

/// #438 — model arch-dim readers (GGUF header + HF config.json). The GGUF
/// cases build a synthetic header in-memory so they don't depend on a
/// cached model; an optional real-cache case asserts plausibility.
final class ModelMetadataTests: XCTestCase {

  // MARK: GGUF binary encoders (little-endian, llama.cpp gguf.h layout)

  private func u32(_ v: UInt32) -> Data { withUnsafeBytes(of: v.littleEndian) { Data($0) } }
  private func u64(_ v: UInt64) -> Data { withUnsafeBytes(of: v.littleEndian) { Data($0) } }
  private func gstr(_ s: String) -> Data { let b = Data(s.utf8); return u64(UInt64(b.count)) + b }
  private func kvStr(_ k: String, _ v: String) -> Data { gstr(k) + u32(8) + gstr(v) }
  private func kvU32(_ k: String, _ v: UInt32) -> Data { gstr(k) + u32(4) + u32(v) }
  /// A string array KV (type 9, elem type 8) — exercises array-skip.
  private func kvStrArray(_ k: String, _ vs: [String]) -> Data {
    var d = gstr(k) + u32(9) + u32(8) + u64(UInt64(vs.count))
    for s in vs { d += gstr(s) }
    return d
  }

  private func writeGGUF(kvs: [Data]) throws -> URL {
    var body = Data("GGUF".utf8) + u32(3) /*version*/ + u64(0) /*tensor_count*/ + u64(UInt64(kvs.count))
    for kv in kvs { body += kv }
    let url = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
      .appendingPathComponent("meta-\(UUID().uuidString.prefix(8)).gguf")
    try body.write(to: url)
    return url
  }

  func test_gguf_reads_dims_with_explicit_key_length() throws {
    let url = try writeGGUF(kvs: [
      kvStr("general.architecture", "testarch"),
      kvStrArray("tokenizer.ggml.tokens", ["a", "b", "c"]),  // skipped
      kvU32("testarch.block_count", 12),
      kvU32("testarch.attention.head_count", 16),
      kvU32("testarch.attention.head_count_kv", 4),
      kvU32("testarch.attention.key_length", 64),
      kvU32("testarch.context_length", 8192),
    ])
    defer { try? FileManager.default.removeItem(at: url) }
    let m = ModelArchMetadata.read(resolvedModelURL: url)
    XCTAssertEqual(m, ModelArchMetadata(numLayers: 12, numKVHeads: 4, headDim: 64, contextLength: 8192))
    XCTAssertEqual(m?.kvBytesPerToken, 4 * 12 * 4 * 64)
  }

  func test_gguf_derives_head_dim_and_kv_heads_from_fallbacks() throws {
    // No key_length → head_dim = embedding_length / head_count. No
    // head_count_kv → = head_count (MHA).
    let url = try writeGGUF(kvs: [
      kvStr("general.architecture", "llama"),
      kvU32("llama.block_count", 32),
      kvU32("llama.attention.head_count", 32),
      kvU32("llama.embedding_length", 4096),
      kvU32("llama.context_length", 4096),
    ])
    defer { try? FileManager.default.removeItem(at: url) }
    let m = ModelArchMetadata.read(resolvedModelURL: url)
    XCTAssertEqual(m, ModelArchMetadata(numLayers: 32, numKVHeads: 32, headDim: 128, contextLength: 4096))
  }

  func test_gguf_missing_required_dim_returns_nil() throws {
    let url = try writeGGUF(kvs: [
      kvStr("general.architecture", "x"),
      kvU32("x.block_count", 0),  // zero → invalid
      kvU32("x.attention.head_count", 8),
      kvU32("x.context_length", 4096),
    ])
    defer { try? FileManager.default.removeItem(at: url) }
    XCTAssertNil(ModelArchMetadata.read(resolvedModelURL: url))
  }

  func test_gguf_gemma3_text_returns_nil_until_per_layer_kv_is_supported() throws {
    let url = try writeGGUF(kvs: [
      kvStr("general.architecture", "gemma3_text"),
      kvU32("gemma3_text.block_count", 26),
      kvU32("gemma3_text.attention.head_count", 8),
      kvU32("gemma3_text.attention.head_count_kv", 4),
      kvU32("gemma3_text.attention.key_length", 256),
      kvU32("gemma3_text.context_length", 131072),
    ])
    defer { try? FileManager.default.removeItem(at: url) }

    XCTAssertNil(
      ModelArchMetadata.read(resolvedModelURL: url),
      "Gemma-3/4 style architectures need per-layer KV accounting; generic uniform metadata must fail closed."
    )
  }

  func test_gguf_bad_magic_returns_nil() throws {
    let url = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
      .appendingPathComponent("bad-\(UUID().uuidString.prefix(8)).gguf")
    try Data("NOPExxxxxxxx".utf8).write(to: url)
    defer { try? FileManager.default.removeItem(at: url) }
    XCTAssertNil(ModelArchMetadata.read(resolvedModelURL: url))
  }

  // MARK: HF config.json

  func test_hf_config_reads_dims() throws {
    let dir = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
      .appendingPathComponent("snap-\(UUID().uuidString.prefix(8))", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    let json = """
    {"num_hidden_layers": 28, "num_attention_heads": 16, "num_key_value_heads": 8,
     "head_dim": 128, "hidden_size": 1024, "max_position_embeddings": 40960}
    """
    try Data(json.utf8).write(to: dir.appendingPathComponent("config.json"))
    let m = ModelArchMetadata.read(resolvedModelURL: dir)
    XCTAssertEqual(m, ModelArchMetadata(numLayers: 28, numKVHeads: 8, headDim: 128, contextLength: 40960))
  }

  func test_hf_config_derives_head_dim_from_hidden_over_heads() throws {
    let dir = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
      .appendingPathComponent("snap-\(UUID().uuidString.prefix(8))", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    // No head_dim, no num_key_value_heads → headDim = 4096/32 = 128, kvHeads = 32.
    let json = """
    {"num_hidden_layers": 32, "num_attention_heads": 32, "hidden_size": 4096,
     "max_position_embeddings": 8192}
    """
    try Data(json.utf8).write(to: dir.appendingPathComponent("config.json"))
    let m = ModelArchMetadata.read(resolvedModelURL: dir)
    XCTAssertEqual(m, ModelArchMetadata(numLayers: 32, numKVHeads: 32, headDim: 128, contextLength: 8192))
  }

  func test_hf_config_gemma3_text_returns_nil_until_per_layer_kv_is_supported() throws {
    let dir = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
      .appendingPathComponent("snap-\(UUID().uuidString.prefix(8))", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    let json = """
    {"model_type": "gemma3_text", "num_hidden_layers": 26, "num_attention_heads": 8,
     "num_key_value_heads": 4, "head_dim": 256, "hidden_size": 2048,
     "max_position_embeddings": 131072}
    """
    try Data(json.utf8).write(to: dir.appendingPathComponent("config.json"))

    XCTAssertNil(
      ModelArchMetadata.read(resolvedModelURL: dir),
      "Gemma-3/4 style configs need per-layer KV accounting; generic uniform metadata must fail closed."
    )
  }

  // MARK: optional real cached GGUF

  func test_real_cached_gguf_parses_plausibly() throws {
    let hub = ("~/.cache/huggingface/hub" as NSString).expandingTildeInPath
    let base = "\(hub)/models--Qwen--Qwen3-0.6B-GGUF/snapshots"
    guard let snap = try? FileManager.default.contentsOfDirectory(atPath: base).first,
          let gguf = try? FileManager.default.contentsOfDirectory(atPath: "\(base)/\(snap)")
            .first(where: { $0.hasSuffix(".gguf") }) else {
      throw XCTSkip("no cached Qwen3-0.6B GGUF")
    }
    let url = URL(fileURLWithPath: "\(base)/\(snap)/\(gguf)")
    let m = ModelArchMetadata.read(resolvedModelURL: url)
    XCTAssertNotNil(m, "real GGUF header must parse")
    if let m {
      XCTAssertGreaterThan(m.numLayers, 0)
      XCTAssertGreaterThan(m.numKVHeads, 0)
      XCTAssertGreaterThan(m.headDim, 0)
      XCTAssertGreaterThan(m.contextLength, 0)
      XCTAssertGreaterThan(m.kvBytesPerToken, 0)
    }
  }
}
