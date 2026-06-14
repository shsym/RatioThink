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
