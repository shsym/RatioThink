import XCTest
@testable import RatioThinkCore

final class ModelDisplayNameTests: XCTestCase {
  func test_leaf_of_repo_file_slug_is_the_file_name() {
    XCTAssertEqual(
      ModelDisplayName.leaf("Qwen/Qwen3-0.6B-GGUF/Qwen3-0.6B-Q8_0.gguf"),
      "Qwen3-0.6B-Q8_0.gguf")
  }

  func test_bare_name_passes_through() {
    XCTAssertEqual(ModelDisplayName.leaf("model.gguf"), "model.gguf")
  }

  func test_trailing_slash_does_not_yield_empty() {
    XCTAssertEqual(ModelDisplayName.leaf("repo/file.gguf/"), "file.gguf")
  }

  func test_empty_string_passes_through() {
    XCTAssertEqual(ModelDisplayName.leaf(""), "")
  }
}

/// `ModelNameParts` parses a stored model slug/filename into structured
/// identity — a prettified base name, a GGUF quantization token, and a
/// container format — so every surface renders the same friendly name
/// (#580). It is the single derivation reused by chat dropdown, Settings
/// table, and profile picker.
///
/// Fail-soft contract: only the well-formed GGUF `Q<n>…` quant family is
/// recognized. A name with no such token — a safetensors dir-slug, or an
/// exotic quant the parser doesn't enumerate (`IQ4_XS`, `f16`, `BF16`) —
/// falls back to the raw leaf as the base with no quant/format, exactly
/// preserving today's leaf rendering rather than mangling it.
final class ModelNamePartsTests: XCTestCase {
  func test_gguf_repo_file_slug_splits_into_base_quant_format() {
    let parts = ModelNameParts.parse("Qwen/Qwen3-0.6B-GGUF/Qwen3-0.6B-Q8_0.gguf")
    XCTAssertEqual(parts.base, "Qwen3 0.6B")
    XCTAssertEqual(parts.quant, "Q8_0")
    XCTAssertEqual(parts.format, "GGUF")
    XCTAssertEqual(parts.raw, "Qwen3-0.6B-Q8_0.gguf")
  }

  func test_compound_quant_token_is_kept_whole() {
    let parts = ModelNameParts.parse("bartowski/Llama-3.2-1B-Instruct-GGUF/Llama-3.2-1B-Instruct-Q4_K_M.gguf")
    XCTAssertEqual(parts.base, "Llama 3.2 1B Instruct")
    XCTAssertEqual(parts.quant, "Q4_K_M")
    XCTAssertEqual(parts.format, "GGUF")
  }

  func test_lowercase_quant_is_canonicalized_uppercase() {
    let parts = ModelNameParts.parse("Qwen/Qwen2.5-0.5B-Instruct-GGUF/qwen2.5-0.5b-instruct-q4_k_m.gguf")
    XCTAssertEqual(parts.quant, "Q4_K_M", "quant token canonicalizes to uppercase for consistent tags")
    XCTAssertEqual(parts.base, "qwen2.5 0.5b instruct", "base keeps the file's own casing — no risky title-casing")
    XCTAssertEqual(parts.format, "GGUF")
  }

  // MARK: - fail-soft fallbacks (base = raw leaf, no quant/format)

  func test_safetensors_dir_slug_falls_back_to_raw_leaf() {
    let parts = ModelNameParts.parse("Qwen/Qwen3-0.6B")
    XCTAssertEqual(parts.base, "Qwen3-0.6B", "no quant token → raw leaf is the base, untouched")
    XCTAssertNil(parts.quant)
    XCTAssertNil(parts.format)
    XCTAssertEqual(parts.raw, "Qwen3-0.6B")
  }

  func test_unknown_exotic_quant_is_not_extracted_as_a_tag() {
    // IQ4_XS / f16 / BF16 are real quants but deliberately NOT enumerated;
    // they must NOT be mis-split into a quant tag. They stay inside the
    // base name; the `.gguf` still becomes a format tag (consistent with a
    // plain no-quant `.gguf`), so nothing is mangled.
    for (leaf, stem) in [("Model-IQ4_XS.gguf", "Model-IQ4_XS"),
                         ("Model-f16.gguf", "Model-f16"),
                         ("Model-BF16.gguf", "Model-BF16")] {
      let parts = ModelNameParts.parse(leaf)
      XCTAssertNil(parts.quant, "\(leaf): exotic quant must not be extracted")
      XCTAssertEqual(parts.base, stem, "\(leaf): exotic quant stays in the base")
      XCTAssertEqual(parts.format, "GGUF")
    }
  }

  func test_bare_gguf_without_quant_keeps_format_drops_quant() {
    let parts = ModelNameParts.parse("model.gguf")
    XCTAssertNil(parts.quant)
    XCTAssertEqual(parts.base, "model", "extension is stripped from the base even with no quant")
    XCTAssertEqual(parts.format, "GGUF")
  }

  func test_empty_passes_through() {
    let parts = ModelNameParts.parse("")
    XCTAssertEqual(parts.base, "")
    XCTAssertNil(parts.quant)
    XCTAssertNil(parts.format)
  }

  // MARK: - structured identity (dedup/group key, #580 Q1)

  func test_identity_collapses_app_and_hf_copies_of_same_file() {
    // An app-managed copy and an HF-cache copy of the same file carry
    // different slugs but the SAME structured identity → one row.
    let app = ModelNameParts.parse("Qwen3-0.6B-Q8_0.gguf")
    let hf = ModelNameParts.parse("Qwen/Qwen3-0.6B-GGUF/Qwen3-0.6B-Q8_0.gguf")
    XCTAssertEqual(app.identity, hf.identity)
  }

  func test_identity_keeps_distinct_quants_apart() {
    let q4 = ModelNameParts.parse("Llama-3.2-1B-Instruct-Q4_K_M.gguf")
    let q8 = ModelNameParts.parse("Llama-3.2-1B-Instruct-Q8_0.gguf")
    XCTAssertNotEqual(q4.identity, q8.identity, "Q4 and Q8 are distinct loadable models")
  }

  func test_identity_of_unparseable_name_is_stable_across_equal_leaves() {
    // `identity` is an opaque key (not a display string). Two slugs whose
    // leaves are the same unparseable name share one identity; a different
    // leaf does not collide.
    let a = ModelNameParts.parse("Qwen/Qwen3-0.6B")
    let b = ModelNameParts.parse("mirror/Qwen3-0.6B")
    let other = ModelNameParts.parse("Qwen/Qwen3-1.7B")
    XCTAssertEqual(a.identity, b.identity)
    XCTAssertNotEqual(a.identity, other.identity)
  }
}
