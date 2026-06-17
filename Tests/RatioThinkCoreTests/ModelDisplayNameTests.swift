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

  // MARK: - format tag (Q3: dropped when redundant)

  func test_gguf_format_tag_is_suppressed_as_redundant() {
    let parts = ModelNameParts.parse("Qwen3-0.6B-Q8_0.gguf")
    XCTAssertEqual(parts.format, "GGUF", "format is still parsed for the formatTag chip")
    XCTAssertNil(parts.formatTag, "a GGUF tag is noise on every row — dropped")
  }

  func test_no_format_has_no_tag() {
    XCTAssertNil(ModelNameParts.parse("Qwen/Qwen3-0.6B").formatTag)
  }

  // MARK: - dedup identity = full resolvable slug (review v2 F2)

  func test_identity_is_the_full_slug_so_only_the_same_file_collapses() {
    // The SAME resolvable `<repo>/<file>` slug (an app-managed download and
    // an HF-cache copy) collapses to one identity; an app-BARE copy of the
    // same leaf is a distinct file and stays apart — restoring main's
    // full-filename dedup, not the leaf-only collapse.
    let full = ModelNameParts.parse("Qwen/Qwen3-0.6B-GGUF/Qwen3-0.6B-Q8_0.gguf")
    let fullCopy = ModelNameParts.parse("Qwen/Qwen3-0.6B-GGUF/Qwen3-0.6B-Q8_0.gguf")
    let bare = ModelNameParts.parse("Qwen3-0.6B-Q8_0.gguf")
    XCTAssertEqual(full.identity, fullCopy.identity, "same resolvable slug → one identity")
    XCTAssertNotEqual(full.identity, bare.identity, "repo-qualified vs bare are distinct files")
  }

  func test_identity_keeps_distinct_quants_apart() {
    let q4 = ModelNameParts.parse("Llama-3.2-1B-Instruct-Q4_K_M.gguf")
    let q8 = ModelNameParts.parse("Llama-3.2-1B-Instruct-Q8_0.gguf")
    XCTAssertNotEqual(q4.identity, q8.identity, "Q4 and Q8 are distinct loadable models")
  }

  func test_identity_distinguishes_same_leaf_across_repos() {
    // F2 regression: two different repos that share a leaf are different
    // files — main kept both visible; the leaf-only key wrongly dropped one.
    let a = ModelNameParts.parse("Qwen/Qwen3-0.6B")
    let b = ModelNameParts.parse("mirror/Qwen3-0.6B")
    XCTAssertNotEqual(a.identity, b.identity, "same leaf, different repo → distinct")
  }

  func test_identity_does_not_over_normalize_underscore_vs_hyphen() {
    // F2: the display prettifier folds `_` and `-` to spaces, so a leaf-base
    // key collided `Model_A` with `Model-A`. The full-slug key keeps them apart.
    let underscore = ModelNameParts.parse("Model_A-Q4_K_M.gguf")
    let hyphen = ModelNameParts.parse("Model-A-Q4_K_M.gguf")
    XCTAssertNotEqual(underscore.identity, hyphen.identity, "underscore vs hyphen are distinct files")
  }

  // MARK: authoritative quant + name/file mismatch (#667)

  func test_effectiveQuant_prefers_header_over_filename() {
    // The header is authoritative: a `…4bit`-named file that is actually
    // Q8_0 inside must display the real quant, not the filename's claim.
    let parts = ModelNameParts.parse("Qwen3-0.6B-4bit.gguf")
    XCTAssertEqual(parts.effectiveQuant(fileQuant: "Q8_0"), "Q8_0")
  }

  func test_effectiveQuant_falls_back_to_filename_when_header_absent() {
    // An older GGUF without general.file_type keeps the prior behavior:
    // the filename quant is the only honest signal available.
    let parts = ModelNameParts.parse("Qwen3-0.6B-Q8_0.gguf")
    XCTAssertEqual(parts.effectiveQuant(fileQuant: nil), "Q8_0")
  }

  func test_effectiveQuant_nil_when_neither_source_has_one() {
    let parts = ModelNameParts.parse("Qwen/Qwen3-0.6B")  // safetensors dir-slug
    XCTAssertNil(parts.effectiveQuant(fileQuant: nil))
  }

  func test_quantMismatch_true_when_header_disagrees_with_filename() {
    // A filename that carries a quant token contradicting the header is the
    // real mismatch case the dropdown/inventory must flag.
    let lying = ModelNameParts.parse("Qwen3-0.6B-Q4_K_M.gguf")
    XCTAssertTrue(lying.quantMismatch(fileQuant: "Q8_0"),
                  "filename says Q4_K_M but the file is Q8_0 → mismatch")
  }

  func test_quantMismatch_false_when_they_agree_or_one_side_missing() {
    let agree = ModelNameParts.parse("Qwen3-0.6B-Q8_0.gguf")
    XCTAssertFalse(agree.quantMismatch(fileQuant: "q8_0"), "case-insensitive agreement is not a mismatch")
    XCTAssertFalse(agree.quantMismatch(fileQuant: nil), "no header quant → cannot mismatch")
    let noQuantAtAll = ModelNameParts.parse("Qwen/Qwen3-0.6B")  // safetensors dir-slug
    XCTAssertFalse(noQuantAtAll.quantMismatch(fileQuant: "Q8_0"),
                   "name advertises no quant claim → nothing to contradict")
    let billions = ModelNameParts.parse("Llama-3.2-1B.gguf")  // `1B` is params, not a quant
    XCTAssertFalse(billions.quantMismatch(fileQuant: "Q8_0"),
                   "a parameter-count segment is not a quant claim")
  }

  // F1: the ticket's own observed case — a non-canonical bit-width name token
  // (4bit/8bit/int4/fp16) the loose Q-parser ignores — must still be compared
  // against the header by bit-width FAMILY so the warning actually fires.
  func test_quantMismatch_noncanonical_bitwidth_token_vs_header() {
    XCTAssertTrue(ModelNameParts.parse("Qwen3-0.6B-4bit.gguf").quantMismatch(fileQuant: "Q8_0"),
                  "name '4bit' over a Q8_0 file → mismatch (4 ≠ 8)")
    XCTAssertTrue(ModelNameParts.parse("Model-int4.gguf").quantMismatch(fileQuant: "Q8_0"),
                  "name 'int4' over Q8_0 → mismatch")
    XCTAssertFalse(ModelNameParts.parse("Model-8bit.gguf").quantMismatch(fileQuant: "Q8_0"),
                   "name '8bit' matches Q8_0's 8-bit family → no mismatch")
    XCTAssertFalse(ModelNameParts.parse("Model-4bit.gguf").quantMismatch(fileQuant: "Q4_K_M"),
                   "name '4bit' matches any Q4_* family → no mismatch")
    XCTAssertFalse(ModelNameParts.parse("Model-4bit.gguf").quantMismatch(fileQuant: "IQ4_XS"),
                   "name '4bit' matches IQ4_* family → no mismatch")
    XCTAssertFalse(ModelNameParts.parse("Model-fp16.gguf").quantMismatch(fileQuant: "F16"),
                   "name 'fp16' matches an F16 header → no mismatch")
  }

  func test_bitWidthFamily_maps_canonical_and_noncanonical_tokens() {
    XCTAssertEqual(ModelNameParts.bitWidthFamily("Q8_0"), 8)
    XCTAssertEqual(ModelNameParts.bitWidthFamily("Q4_K_M"), 4)
    XCTAssertEqual(ModelNameParts.bitWidthFamily("IQ4_XS"), 4)
    XCTAssertEqual(ModelNameParts.bitWidthFamily("BF16"), 16)
    XCTAssertEqual(ModelNameParts.bitWidthFamily("F32"), 32)
    XCTAssertEqual(ModelNameParts.bitWidthFamily("F16"), 16)
    XCTAssertEqual(ModelNameParts.bitWidthFamily("4bit"), 4)
    XCTAssertEqual(ModelNameParts.bitWidthFamily("8bit"), 8)
    XCTAssertEqual(ModelNameParts.bitWidthFamily("int4"), 4)
    XCTAssertEqual(ModelNameParts.bitWidthFamily("fp16"), 16)
    XCTAssertEqual(ModelNameParts.bitWidthFamily("mxfp4"), 4)
    XCTAssertNil(ModelNameParts.bitWidthFamily("1B"), "param count is not a quant")
    XCTAssertNil(ModelNameParts.bitWidthFamily("Instruct"))
    // F4: a bare `f<n>` like F5 (the F5-TTS family) is a NAME fragment, not a
    // float quant; only the real GGUF float widths f16/f32 count.
    XCTAssertNil(ModelNameParts.bitWidthFamily("F5"), "F5 (F5-TTS) is not a quant")
    XCTAssertNil(ModelNameParts.bitWidthFamily("f1"))
    XCTAssertNil(ModelNameParts.bitWidthFamily("f8"))
  }

  // F4: a leading name fragment (`F5`) must not shadow the real trailing quant
  // claim, and a bare `f<n>` must not register as a float quant. `F5-TTS-8bit`
  // over a Q8_0 header is HONEST (trailing 8bit agrees) — no warning.
  func test_quantMismatch_leading_name_fragment_does_not_cry_wolf() {
    XCTAssertFalse(ModelNameParts.parse("F5-TTS-8bit.gguf").quantMismatch(fileQuant: "Q8_0"),
                   "trailing 8bit agrees with Q8_0; leading F5 must not shadow it")
    XCTAssertFalse(ModelNameParts.parse("F5-TTS.gguf").quantMismatch(fileQuant: "Q8_0"),
                   "F5-TTS advertises no quant claim → no mismatch")
    XCTAssertNil(ModelNameParts.parse("F5-TTS-8bit.gguf").mismatchWarning(fileQuant: "Q8_0"),
                 "no bogus warning on an honest F5-TTS name")
    // The real trailing claim still wins when it genuinely disagrees.
    XCTAssertTrue(ModelNameParts.parse("F5-TTS-4bit.gguf").quantMismatch(fileQuant: "Q8_0"),
                  "trailing 4bit over a Q8_0 file is a real mismatch")
  }

  func test_mismatchWarning_single_source_fires_for_noncanonical_name() {
    let parts = ModelNameParts.parse("Qwen3-0.6B-4bit.gguf")
    let note = try! XCTUnwrap(parts.mismatchWarning(fileQuant: "Q8_0"))
    XCTAssertTrue(note.contains("Q8_0"), "names the real file quant")
    XCTAssertTrue(note.contains("4bit"), "names the filename's bit-width claim")
    XCTAssertNil(ModelNameParts.parse("Qwen3-0.6B-Q8_0.gguf").mismatchWarning(fileQuant: "Q8_0"),
                 "agreement → no warning")
  }

  func test_quantMismatchNote_names_both_quants() {
    let note = ModelNameParts.quantMismatchNote(fileQuant: "Q8_0", nameQuant: "Q4_K_M")
    XCTAssertTrue(note.contains("Q8_0"), "names the real file quant")
    XCTAssertTrue(note.contains("Q4_K_M"), "names the filename's claimed quant")
  }
}
