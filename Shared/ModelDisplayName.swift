import Foundation

/// Friendly display labels for model identifiers ( review v2 F1).
///
/// A model's stored identity is the resolvable `<repo>/<file>` slug
/// (e.g. `Qwen/Qwen3-0.6B-GGUF/Qwen3-0.6B-Q8_0.gguf`) — the form
/// `ModelDownloader` writes and `LaunchSpecResolver.joinModelPath`
/// resolves. UI must render a friendly name instead of that raw slug:
/// the leaf (last path component). Bare names pass through unchanged.
public enum ModelDisplayName {
  public static func leaf(_ id: String) -> String {
    id.split(separator: "/", omittingEmptySubsequences: true).last.map(String.init) ?? id
  }
}

/// Structured identity parsed from a model slug/filename (#580): a
/// prettified `base` name, an optional GGUF `quant` token, and an optional
/// container `format`. One derivation reused by every surface that lists a
/// model (chat dropdown, Settings table, profile picker), matching the
/// single-derivation convention `ModelTarget` set.
///
/// Fail-soft: only the well-formed GGUF `Q<n>…` quant family is recognized
/// (`Q8_0`, `Q4_K_M`, `Q6_K`, …). A leaf with no such trailing token — a
/// safetensors dir-slug (`Qwen/Qwen3-0.6B`) or an exotic quant the parser
/// does not enumerate (`IQ4_XS`, `f16`, `BF16`) — falls back to the raw
/// leaf as the `base` with `quant`/`format` nil, exactly preserving the
/// pre-#580 leaf rendering instead of risking a mangled split.
public struct ModelNameParts: Equatable, Sendable {
  /// Prettified product name (`Qwen3 0.6B`), or the raw leaf when the name
  /// can't be confidently split.
  public let base: String
  /// Canonical (uppercase) GGUF quant token (`Q8_0`, `Q4_K_M`), or nil.
  public let quant: String?
  /// Container format derived from the file extension (`GGUF`), or nil for
  /// a safetensors dir-slug / extension-less leaf.
  public let format: String?
  /// The raw leaf (last path component) — stable fallback + display source.
  public let raw: String
  /// The full resolvable slug this was parsed from (`<repo>/<file>` or a bare
  /// filename) — the dedup key (PR #174 review v2 F2).
  public let slug: String

  public init(base: String, quant: String?, format: String?, raw: String, slug: String) {
    self.base = base
    self.quant = quant
    self.format = format
    self.raw = raw
    self.slug = slug
  }

  /// Dedup key: the FULL resolvable slug, NOT the leaf-derived base (review
  /// v2 F2). Two entries collapse only when they name the same resolvable
  /// file — an app-managed download and an HF-cache copy of the same
  /// `<repo>/<file>` slug. Distinct files that merely share a leaf (different
  /// repos, an app-bare copy vs a repo-qualified one, or `Model_A` vs
  /// `Model-A` that the display prettifier would fold together) stay apart,
  /// matching origin/main's full-filename dedup. Quant distinctness (Q4 vs
  /// Q8) falls out for free since the quant is part of the slug. Grouping and
  /// display still use the prettified leaf `base`/`groupKey`.
  public var identity: String { slug }

  /// Group key (#580 #4): the base name alone, so all quants of one family
  /// cluster under a single section header.
  public var groupKey: String { base }

  /// Full friendly label replacing the raw leaf everywhere a single model
  /// is named: `Qwen3 0.6B Q8_0`. Falls back to the raw leaf when there is
  /// no clean quant (a safetensors dir, a split GGUF) so such a row keeps
  /// its only stable identifier rather than a `.gguf`-stripped stem.
  public var display: String {
    guard let quant else { return raw }
    return "\(base) \(quant)"
  }

  /// The within-a-base-section distinguisher: the quant tag, or the raw
  /// leaf when there is none. Used by grouped surfaces where the section
  /// header already shows the base.
  public var quantOrLeaf: String { quant ?? raw }

  /// Format to render as a chip, or nil when it adds nothing (Q3:
  /// "dropped when redundant"). `GGUF` is the universal v1 container, so a
  /// `GGUF` tag is pure noise on every row — suppress it. A non-GGUF
  /// format (should one ever appear) still surfaces, keeping the tag
  /// honest rather than hard-coding it away.
  public var formatTag: String? {
    guard let format, format != "GGUF" else { return nil }
    return format
  }

  /// Recognized GGUF quant token: `Q<digits>` optionally followed by
  /// `_<alnum>` segments (`Q8_0`, `Q4_K_M`, `Q6_K`, `Q5_K_S`). Anchored to
  /// a full path segment so it matches the trailing quant token only.
  private static let quantPattern = "^Q[0-9]+(_[0-9A-Z]+)*$"

  public static func parse(_ id: String) -> ModelNameParts {
    let raw = ModelDisplayName.leaf(id)

    // Split off a known file extension → format. A safetensors dir-slug or
    // a bare token has none.
    let (stem, format) = splitFormat(raw)

    // Recognize a trailing GGUF quant token as the last `-`-delimited
    // segment of the stem. Anything else (exotic quant, no quant) fails
    // soft to the raw leaf as the base.
    let segments = stem.split(separator: "-", omittingEmptySubsequences: true).map(String.init)
    if let last = segments.last,
       isQuantToken(last),
       segments.count >= 2 {
      let baseSegments = segments.dropLast()
      let base = prettify(baseSegments.joined(separator: "-"))
      return ModelNameParts(base: base, quant: last.uppercased(), format: format, raw: raw, slug: id)
    }

    // Fail-soft: no recognized quant.
    //   · `.gguf` with no quant → strip the extension, keep the format tag.
    //   · everything else (safetensors dir-slug, extension-less) → the raw
    //     leaf verbatim, no format.
    if format != nil {
      return ModelNameParts(base: stem, quant: nil, format: format, raw: raw, slug: id)
    }
    return ModelNameParts(base: raw, quant: nil, format: nil, raw: raw, slug: id)
  }

  /// Split a leaf into (stem-without-extension, FORMAT) for known model
  /// container extensions; returns (leaf, nil) when there is no such
  /// extension (a safetensors snapshot dir-slug has none on its leaf).
  private static func splitFormat(_ leaf: String) -> (String, String?) {
    if leaf.lowercased().hasSuffix(".gguf") {
      return (String(leaf.dropLast(".gguf".count)), "GGUF")
    }
    return (leaf, nil)
  }

  private static func isQuantToken(_ token: String) -> Bool {
    token.range(of: quantPattern, options: [.regularExpression, .caseInsensitive]) != nil
  }

  // MARK: authoritative GGUF quant (#667)
  //
  // `quant` above is parsed from the FILENAME — a heuristic that a renamed
  // or mislabeled file can defeat (`…4bit` over a Q8_0 file). The GGUF
  // header's `general.file_type` is authoritative; callers read it
  // (`GGUFMetadata.quant`) at scan time and pass it here. These pure helpers
  // are the single place every surface (chat dropdown, Settings inventory)
  // decides what quant to show and whether the name is lying.

  /// The quant to display: the authoritative header quant when known, else
  /// the filename-parsed token, else nil (a safetensors dir-slug or an
  /// exotic name with neither).
  public func effectiveQuant(fileQuant: String?) -> String? {
    fileQuant ?? quant
  }

  /// The quant claim the FILENAME makes, for mismatch reporting: the
  /// canonical GGUF token when present, else a non-canonical bit-width token
  /// (`4bit`, `int4`, `fp16`) the loose `quant` parser ignores. Nil when the
  /// name advertises no quant at all.
  public var nameQuantClaim: String? { quant ?? nonCanonicalBitToken }

  /// True when the filename's quant claim disagrees with the authoritative
  /// header quant. Two comparison modes:
  ///   · canonical filename token (`Q4_K_M`) — exact match against the header
  ///     (preserves the original sanity check; `Q4_K_M` ≠ `Q8_0`).
  ///   · non-canonical bit-width token (`4bit`, `int4`, `fp16`) — compared by
  ///     BIT-WIDTH FAMILY, since the ticket's real mislabels are names like
  ///     `…4bit` over a Q8_0 file (`4bit` vs `Q8_0` → mismatch; `8bit` vs
  ///     `Q8_0` → agree; `4bit` vs any `Q4_*`/`IQ4_*` → agree).
  /// A missing header quant or a name with no quant claim is an absence, not
  /// a contradiction.
  public func quantMismatch(fileQuant: String?) -> Bool {
    guard let fileQuant else { return false }
    if let quant {
      return fileQuant.uppercased() != quant.uppercased()
    }
    guard let token = nonCanonicalBitToken,
          let nameFamily = Self.bitWidthFamily(token),
          let headerFamily = Self.bitWidthFamily(fileQuant) else { return false }
    return nameFamily != headerFamily
  }

  /// The single assembly point for a name/file mismatch warning, reused by
  /// every surface (chat dropdown, Settings inventory) so the logic lives in
  /// exactly one place. Nil when there is no mismatch or no name claim.
  public func mismatchWarning(fileQuant: String?) -> String? {
    guard let fileQuant, quantMismatch(fileQuant: fileQuant),
          let nameQuant = nameQuantClaim else { return nil }
    return Self.quantMismatchNote(fileQuant: fileQuant, nameQuant: nameQuant)
  }

  /// Human-readable warning for a name/file quant disagreement, naming both
  /// the real (header) quant and the filename's claim.
  public static func quantMismatchNote(fileQuant: String, nameQuant: String) -> String {
    "File is \(fileQuant); the name says \(nameQuant)"
  }

  /// A non-canonical bit-width token in the name (`4bit`, `int4`, `fp16`) —
  /// the trailing-`Q` parser does not recognize these, so they are found by
  /// scanning the stem's `-`-segments. Canonical `Q…` tokens are excluded
  /// (handled by `quant`). Nil when no such token is present.
  ///
  /// Scanned in REVERSE so the LAST quant-shaped segment wins, mirroring the
  /// canonical `quant` parser's trailing-token discipline (`parse` uses
  /// `segments.last`). Otherwise a leading name fragment like `F5` in
  /// `F5-TTS-8bit` would shadow the real trailing `8bit` claim (PR #293 F4).
  private var nonCanonicalBitToken: String? {
    let (stem, _) = Self.splitFormat(raw)
    for segment in stem.split(separator: "-", omittingEmptySubsequences: true).map(String.init).reversed()
    where !Self.isQuantToken(segment) {
      if Self.bitWidthFamily(segment) != nil { return segment }
    }
    return nil
  }

  /// Bit-width family of a quant label or a non-canonical token, e.g.
  /// `Q8_0`/`8bit`/`int8` → 8, `Q4_K_M`/`IQ4_XS`/`4bit` → 4,
  /// `BF16`/`fp16`/`f16` → 16, `F32` → 32. Nil for anything not quant-shaped,
  /// so an unrelated name segment never registers as a quant claim.
  ///
  /// The lone-`f` float form is restricted to the only real GGUF float widths
  /// (`f16`/`f32`); a bare `f<n>` like `F5` (the F5-TTS family) is NOT a quant
  /// and must return nil (PR #293 F4). Prefixed forms (`fp`/`bf`/`mxfp`/
  /// `nvfp`) keep arbitrary digits.
  static func bitWidthFamily(_ raw: String) -> Int? {
    let s = raw.lowercased()
    if let n = captureFirstInt(s, "^([0-9]+)bit$") { return n }          // 4bit, 8bit
    if let n = captureFirstInt(s, "^u?int([0-9]+)$") { return n }        // int4, uint8
    if let n = captureFirstInt(s, "^(?:bf|mx?fp|nv?fp|fp)([0-9]+)$") { return n }  // fp16, bf16, mxfp4, nvfp4
    if let n = captureFirstInt(s, "^f(16|32)$") { return n }             // f16, f32 only — NOT f5/f1
    if let n = captureFirstInt(s, "^[it]?q([0-9]+)") { return n }        // Q8_0, Q4_K_M, IQ4_XS, TQ1_0
    return nil
  }

  private static func captureFirstInt(_ s: String, _ pattern: String) -> Int? {
    guard let re = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return nil }
    let range = NSRange(s.startIndex..., in: s)
    guard let m = re.firstMatch(in: s, range: range), m.numberOfRanges >= 2,
          let r = Range(m.range(at: 1), in: s) else { return nil }
    return Int(s[r])
  }

  /// Replace `-`/`_` separators with spaces and collapse runs, so a
  /// `Llama-3.2-1B-Instruct` stem reads `Llama 3.2 1B Instruct`. Casing is
  /// left untouched — title-casing would corrupt names like `Qwen3`.
  private static func prettify(_ stem: String) -> String {
    stem
      .replacingOccurrences(of: "_", with: " ")
      .replacingOccurrences(of: "-", with: " ")
      .split(separator: " ", omittingEmptySubsequences: true)
      .joined(separator: " ")
  }
}
