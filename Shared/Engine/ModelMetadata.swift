import Foundation

/// Architecture dims needed to size the KV-cache token budget (#438).
///
/// Modeled as uniform-across-layers — correct for Qwen / Llama / Phi /
/// Mistral and the curated catalog. Gemma-3/4 use per-layer dims (sliding
/// vs full layers); they are NOT modeled here, so the reader returns
/// `nil` for them and the launcher omits the ceiling, falling back to the
/// engine default (the conservative, down-only contract).
public struct ModelArchMetadata: Equatable, Sendable {
  public let numLayers: Int
  public let numKVHeads: Int
  public let headDim: Int
  public let contextLength: Int

  public init(numLayers: Int, numKVHeads: Int, headDim: Int, contextLength: Int) {
    self.numLayers = numLayers
    self.numKVHeads = numKVHeads
    self.headDim = headDim
    self.contextLength = contextLength
  }

  /// Returns the metadata only when every dim is positive — a missing or
  /// zero field means we cannot size KV safely, so the caller omits the
  /// ceiling rather than guessing.
  public static func validated(numLayers: Int, numKVHeads: Int,
                               headDim: Int, contextLength: Int) -> ModelArchMetadata? {
    guard numLayers > 0, numKVHeads > 0, headDim > 0, contextLength > 0 else { return nil }
    return ModelArchMetadata(numLayers: numLayers, numKVHeads: numKVHeads,
                             headDim: headDim, contextLength: contextLength)
  }

  /// Bytes of KV cache one token occupies, mirroring the portable driver
  /// exactly: `2(K+V) * n_layers * n_kv_heads * head_dim * 2 (F16)`. The
  /// KV cache dtype is hardcoded F16 in pie (driver/portable forward.cpp),
  /// so `dtype_bytes = 2` regardless of the weight quant.
  public var kvBytesPerToken: Int64 {
    Int64(4) * Int64(numLayers) * Int64(numKVHeads) * Int64(headDim)
  }

  /// Architectures whose KV geometry is not uniform across all layers.
  /// The generic `ModelArchMetadata` shape cannot represent them safely,
  /// so callers must omit the memory-derived ceiling until per-layer
  /// accounting is implemented.
  static func requiresPerLayerKVAccounting(_ architecture: String) -> Bool {
    let normalized = architecture.lowercased()
    return normalized == "gemma3" || normalized == "gemma3_text"
      || normalized == "gemma4" || normalized == "gemma4_text"
  }

  /// Read from a resolved model path: a `.gguf` FILE → GGUF header; a
  /// directory (HF snapshot) → `config.json`. `nil` when unreadable or
  /// unsupported (caller then omits the ceiling).
  public static func read(resolvedModelURL: URL,
                          fileManager: FileManager = .default) -> ModelArchMetadata? {
    var isDir: ObjCBool = false
    guard fileManager.fileExists(atPath: resolvedModelURL.path, isDirectory: &isDir) else {
      return nil
    }
    if isDir.boolValue {
      return HFConfigMetadata.read(snapshotDirectory: resolvedModelURL, fileManager: fileManager)
    }
    if resolvedModelURL.pathExtension.lowercased() == "gguf" {
      return GGUFMetadata.read(fileURL: resolvedModelURL)
    }
    return nil
  }
}

// =============================================================================
// HF config.json (safetensors snapshots)
// =============================================================================

/// Reads arch dims from an HF `config.json`. Field names match the
/// transformers config and pie's safetensors path.
enum HFConfigMetadata {
  static func read(snapshotDirectory: URL, fileManager: FileManager = .default) -> ModelArchMetadata? {
    let configURL = snapshotDirectory.appendingPathComponent("config.json", isDirectory: false)
    guard let data = try? Data(contentsOf: configURL),
          let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
      return nil
    }
    func int(_ key: String) -> Int? {
      if let n = obj[key] as? Int { return n }
      if let n = obj[key] as? NSNumber { return n.intValue }
      return nil
    }
    if let modelType = obj["model_type"] as? String,
       ModelArchMetadata.requiresPerLayerKVAccounting(modelType) {
      return nil
    }
    let numLayers = int("num_hidden_layers") ?? 0
    let numHeads = int("num_attention_heads") ?? 0
    // GQA: defaults to num_attention_heads when absent (MHA).
    let numKVHeads = int("num_key_value_heads") ?? numHeads
    // head_dim explicit, else hidden_size / num_attention_heads.
    let headDim: Int
    if let hd = int("head_dim") {
      headDim = hd
    } else if let hidden = int("hidden_size"), numHeads > 0 {
      headDim = hidden / numHeads
    } else {
      headDim = 0
    }
    let contextLength = int("max_position_embeddings") ?? 0
    return ModelArchMetadata.validated(
      numLayers: numLayers, numKVHeads: numKVHeads,
      headDim: headDim, contextLength: contextLength
    )
  }
}

// =============================================================================
// GGUF header (single-file quantized models)
// =============================================================================

/// Minimal GGUF metadata reader: parses the header + metadata KV block
/// (NOT tensor data) to extract arch dims. Keys mirror pie's portable
/// driver `gguf_hparams.cpp` exactly: `<arch>.block_count`,
/// `<arch>.attention.head_count[_kv]`, `<arch>.attention.key_length`,
/// `<arch>.embedding_length`, `<arch>.context_length`, where `<arch>` is
/// the `general.architecture` string.
enum GGUFMetadata {
  /// GGUF metadata value type tags (llama.cpp gguf.h).
  private enum ValueType: UInt32 {
    case uint8 = 0, int8 = 1, uint16 = 2, int16 = 3, uint32 = 4, int32 = 5
    case float32 = 6, bool = 7, string = 8, array = 9, uint64 = 10, int64 = 11, float64 = 12
  }

  /// Defensive caps so a malformed/hostile header can't make us read a
  /// huge file or loop unboundedly.
  private static let maxMetadataBytes = 16 * 1024 * 1024
  private static let maxKVCount = 1_000_000

  static func read(fileURL: URL) -> ModelArchMetadata? {
    guard let handle = try? FileHandle(forReadingFrom: fileURL) else { return nil }
    defer { try? handle.close() }
    var cursor = Cursor(handle: handle, budget: maxMetadataBytes)

    guard let magic = cursor.read(4), magic == Data([0x47, 0x47, 0x55, 0x46]), // "GGUF"
          let _version = cursor.readU32(),
          cursor.readU64() != nil,            // tensor_count (unused)
          let kvCount = cursor.readU64(),
          kvCount <= UInt64(maxKVCount) else {
      return nil
    }
    _ = _version

    var strings: [String: String] = [:]
    var ints: [String: Int64] = [:]
    for _ in 0..<kvCount {
      guard let key = cursor.readString(),
            let rawType = cursor.readU32(),
            let type = ValueType(rawValue: rawType) else { return nil }
      switch type {
      case .string:
        guard let s = cursor.readString() else { return nil }
        strings[key] = s
      case .uint8, .int8, .uint16, .int16, .uint32, .int32, .uint64, .int64:
        guard let v = cursor.readScalarInt(type) else { return nil }
        ints[key] = v
      case .float32: guard cursor.skip(4) else { return nil }
      case .float64: guard cursor.skip(8) else { return nil }
      case .bool:    guard cursor.skip(1) else { return nil }
      case .array:   guard cursor.skipArray() else { return nil }
      }
    }

    guard let arch = strings["general.architecture"], !arch.isEmpty,
          !ModelArchMetadata.requiresPerLayerKVAccounting(arch) else { return nil }
    func num(_ suffix: String) -> Int? { ints["\(arch).\(suffix)"].map(Int.init) }

    let numLayers = num("block_count") ?? 0
    let numHeads = num("attention.head_count") ?? 0
    let numKVHeads = num("attention.head_count_kv") ?? numHeads
    let headDim: Int
    if let kl = num("attention.key_length"), kl > 0 {
      headDim = kl
    } else if let embd = num("embedding_length"), numHeads > 0 {
      headDim = embd / numHeads
    } else {
      headDim = 0
    }
    let contextLength = num("context_length") ?? 0
    return ModelArchMetadata.validated(
      numLayers: numLayers, numKVHeads: numKVHeads,
      headDim: headDim, contextLength: contextLength
    )
  }

  /// Sequential little-endian reader over a `FileHandle` with a byte
  /// budget. Returns nil on EOF / budget exhaustion so a truncated or
  /// malformed file fails closed.
  private struct Cursor {
    let handle: FileHandle
    var budget: Int

    mutating func read(_ n: Int) -> Data? {
      guard n >= 0, n <= budget, let d = try? handle.read(upToCount: n), d.count == n else {
        return nil
      }
      budget -= n
      return d
    }

    mutating func skip(_ n: Int) -> Bool { read(n) != nil }

    mutating func readU32() -> UInt32? {
      guard let d = read(4) else { return nil }
      return d.withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }.littleEndian
    }

    mutating func readU64() -> UInt64? {
      guard let d = read(8) else { return nil }
      return d.withUnsafeBytes { $0.loadUnaligned(as: UInt64.self) }.littleEndian
    }

    mutating func readString() -> String? {
      guard let len = readU64(), len <= UInt64(budget), let d = read(Int(len)) else { return nil }
      return String(data: d, encoding: .utf8)
    }

    /// Read an integer-typed scalar, widened to Int64.
    mutating func readScalarInt(_ type: ValueType) -> Int64? {
      switch type {
      case .uint8:  return read(1).map { Int64($0[$0.startIndex]) }
      case .int8:   return read(1).map { Int64(Int8(bitPattern: $0[$0.startIndex])) }
      case .uint16: return read(2).map { Int64($0.withUnsafeBytes { $0.loadUnaligned(as: UInt16.self) }.littleEndian) }
      case .int16:  return read(2).map { Int64(Int16(bitPattern: $0.withUnsafeBytes { $0.loadUnaligned(as: UInt16.self) }.littleEndian)) }
      case .uint32: return readU32().map { Int64($0) }
      case .int32:  return readU32().map { Int64(Int32(bitPattern: $0)) }
      case .uint64: return readU64().flatMap { $0 <= UInt64(Int64.max) ? Int64($0) : nil }
      case .int64:  return readU64().map { Int64(bitPattern: $0) }
      default:      return nil
      }
    }

    /// Consume (without decoding) an array value: elem-type + count + elems.
    mutating func skipArray() -> Bool {
      guard let rawElem = readU32(), let elem = ValueType(rawValue: rawElem),
            let count = readU64(), count <= UInt64(budget) else { return false }
      let n = Int(count)
      switch elem {
      case .uint8, .int8, .bool: return skip(n)
      case .uint16, .int16:      return skip(n * 2)
      case .uint32, .int32, .float32: return skip(n * 4)
      case .uint64, .int64, .float64: return skip(n * 8)
      case .string:
        for _ in 0..<n { if readString() == nil { return false } }
        return true
      case .array:
        // Nested arrays are not used by the keys we read; refuse rather
        // than risk misalignment.
        return false
      }
    }
  }
}
