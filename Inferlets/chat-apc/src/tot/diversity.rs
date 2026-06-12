//! Near-duplicate detection for tree-of-thought sibling branches (#523).
//!
//! Pure, language-agnostic, and cheap (`n ≤ MAX_NODES`): a candidate
//! continuation is reduced to its lowercased word set and two candidates
//! are "near-duplicates" when their word-set Jaccard similarity meets a
//! threshold. This is deliberately conservative — a HIGH threshold so only
//! genuine paraphrases (near-identical vocabulary) are flagged, never two
//! genuinely different strategies that merely share domain words
//! ("party", "plan"). Under-flagging is the safe failure mode: it costs a
//! little diversity, while over-flagging would *suppress* real diversity.
//!
//! Used by [`super::tree::select_beam_diverse`] to keep one paraphrase out
//! of a beam slot in favor of a distinct branch. Unit-tested natively via
//! `cargo test --lib`.

use std::collections::HashSet;

/// Default similarity at/above which two continuations count as
/// near-duplicates. Strict so only true paraphrases trip it.
pub const DUP_THRESHOLD: f32 = 0.8;

/// Lowercased alphanumeric word set of `text`. Punctuation and case are
/// dropped so paraphrases that differ only in surface form collapse
/// together.
fn word_set(text: &str) -> HashSet<String> {
    text.split(|c: char| !c.is_alphanumeric())
        .filter(|w| !w.is_empty())
        .map(|w| w.to_lowercase())
        .collect()
}

/// Jaccard similarity of two texts' word sets in `[0.0, 1.0]`. Two empty
/// texts are treated as fully similar (1.0): neither carries distinguishing
/// content, so they should not both occupy diverse beam slots.
pub fn similarity(a: &str, b: &str) -> f32 {
    let sa = word_set(a);
    let sb = word_set(b);
    if sa.is_empty() && sb.is_empty() {
        return 1.0;
    }
    let inter = sa.intersection(&sb).count() as f32;
    let union = sa.union(&sb).count() as f32;
    if union == 0.0 {
        1.0
    } else {
        inter / union
    }
}

/// Whether two continuations are near-duplicates at `threshold`.
pub fn is_near_duplicate(a: &str, b: &str, threshold: f32) -> bool {
    similarity(a, b) >= threshold
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn identical_text_is_fully_similar() {
        assert_eq!(similarity("plan the party", "plan the party"), 1.0);
    }

    #[test]
    fn paraphrase_with_shared_vocab_is_near_duplicate() {
        // Same plan shape, reworded → high overlap → flagged.
        let a = "choose a date plan the party decorate food games";
        let b = "choose the date plan a party decorate food and games";
        assert!(similarity(a, b) >= DUP_THRESHOLD);
        assert!(is_near_duplicate(a, b, DUP_THRESHOLD));
    }

    #[test]
    fn distinct_strategies_are_not_near_duplicates() {
        // Genuinely different approaches share few words → not flagged,
        // even though both are about the same task.
        let a = "venue first: secure a private room that fits the guest list";
        let b = "budget first: set a spending cap then allocate per category";
        assert!(similarity(a, b) < DUP_THRESHOLD);
        assert!(!is_near_duplicate(a, b, DUP_THRESHOLD));
    }

    #[test]
    fn case_and_punctuation_are_ignored() {
        assert_eq!(similarity("Plan, the PARTY!", "plan the party"), 1.0);
    }

    #[test]
    fn empty_texts_are_similar() {
        // Two empty continuations shouldn't both take diverse slots.
        assert_eq!(similarity("", ""), 1.0);
        assert!(is_near_duplicate("", "", DUP_THRESHOLD));
    }

    #[test]
    fn disjoint_text_is_zero_similarity() {
        assert_eq!(similarity("alpha beta", "gamma delta"), 0.0);
    }
}
