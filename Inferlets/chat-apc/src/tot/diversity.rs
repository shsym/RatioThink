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
    if union == 0.0 { 1.0 } else { inter / union }
}

/// Whether two continuations are near-duplicates at `threshold`.
pub fn is_near_duplicate(a: &str, b: &str, threshold: f32) -> bool {
    similarity(a, b) >= threshold
}

/// Words used to fingerprint a continuation's opening for the
/// `distinct_prefixes` diversity signal. `breadth` distinct prefixes means
/// every sibling diverged from (about) the first token — the healthy case.
const PREFIX_WORDS: usize = 8;

/// First-`PREFIX_WORDS` lowercased words of `text`, space-joined. Empty when
/// `text` is empty.
fn prefix_key(text: &str) -> String {
    text.split_whitespace()
        .take(PREFIX_WORDS)
        .map(|w| w.to_lowercase())
        .collect::<Vec<_>>()
        .join(" ")
}

/// Per-level branch-diversity summary across a level's `breadth` candidate
/// continuations. MEASUREMENT ONLY (#683): read off the logs to see whether
/// sibling forks actually diverge. It never feeds beam selection — pruning
/// stays with [`super::tree::select_beam_diverse`] — so computing it is a
/// pure observation with no behavior change.
#[derive(Debug, Clone, PartialEq)]
pub struct LevelDivergence {
    /// Number of texts measured (the answered siblings at this level).
    pub n: usize,
    /// Mean pairwise Jaccard similarity in `[0, 1]`; `None` when `n < 2`
    /// (no pair to compare). Lower = more diverse.
    pub mean_similarity: Option<f32>,
    /// Max pairwise Jaccard similarity (the closest sibling pair); `None`
    /// when `n < 2`. A high max with a low mean flags one near-duplicate
    /// pair hiding inside an otherwise diverse beam.
    pub max_similarity: Option<f32>,
    /// Count of byte-identical sibling pairs — the hardest collapse signal.
    pub identical_pairs: usize,
    /// Number of distinct opening prefixes (see [`PREFIX_WORDS`]). Equal to
    /// `n` when every sibling opens differently.
    pub distinct_prefixes: usize,
}

/// Summarize how much a level's sibling continuations diverge. `texts` is the
/// answered branches' visible content; pass the full breadth (pre-pruning) so
/// the metric reflects what the forks produced, not what survived selection.
pub fn level_divergence(texts: &[&str]) -> LevelDivergence {
    let n = texts.len();
    let mut sims: Vec<f32> = Vec::new();
    let mut identical_pairs = 0usize;
    for i in 0..n {
        for j in (i + 1)..n {
            sims.push(similarity(texts[i], texts[j]));
            if texts[i] == texts[j] {
                identical_pairs += 1;
            }
        }
    }
    let mean_similarity = if sims.is_empty() {
        None
    } else {
        Some(sims.iter().sum::<f32>() / sims.len() as f32)
    };
    // Similarities are in [0, 1] (no NaN), so `f32::max` is a total reduce.
    let max_similarity = sims.iter().copied().reduce(f32::max);
    let distinct_prefixes = {
        let mut seen = HashSet::new();
        for t in texts {
            seen.insert(prefix_key(t));
        }
        seen.len()
    };
    LevelDivergence {
        n,
        mean_similarity,
        max_similarity,
        identical_pairs,
        distinct_prefixes,
    }
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

    #[test]
    fn level_divergence_single_text_has_no_pairs() {
        let d = level_divergence(&["only one branch"]);
        assert_eq!(d.n, 1);
        assert_eq!(d.mean_similarity, None);
        assert_eq!(d.max_similarity, None);
        assert_eq!(d.identical_pairs, 0);
        assert_eq!(d.distinct_prefixes, 1);
    }

    #[test]
    fn level_divergence_distinct_branches_are_diverse() {
        let texts = [
            "venue first secure a private room that fits the guest list",
            "budget first set a spending cap then allocate per category",
            "theme first pick a motif and let it drive every choice",
        ];
        let d = level_divergence(&texts);
        assert_eq!(d.n, 3);
        assert_eq!(d.identical_pairs, 0);
        assert_eq!(d.distinct_prefixes, 3); // every sibling opens differently
        // Genuinely different strategies share few words → low similarity.
        assert!(d.mean_similarity.unwrap() < 0.3);
        assert!(d.max_similarity.unwrap() < DUP_THRESHOLD);
    }

    #[test]
    fn level_divergence_flags_identical_collapse() {
        let texts = ["same answer here", "same answer here", "same answer here"];
        let d = level_divergence(&texts);
        assert_eq!(d.n, 3);
        assert_eq!(d.identical_pairs, 3); // C(3,2) = 3 identical pairs
        assert_eq!(d.distinct_prefixes, 1); // collapsed to one opening
        assert_eq!(d.mean_similarity, Some(1.0));
        assert_eq!(d.max_similarity, Some(1.0));
    }

    #[test]
    fn level_divergence_catches_one_near_duplicate_pair() {
        // Two paraphrases + one distinct branch: mean stays moderate but the
        // max pins the near-duplicate pair.
        let texts = [
            "choose a date plan the party decorate food games",
            "choose the date plan a party decorate food and games",
            "rent a venue hire a caterer and send invitations early",
        ];
        let d = level_divergence(&texts);
        assert_eq!(d.identical_pairs, 0);
        assert_eq!(d.distinct_prefixes, 3);
        assert!(d.max_similarity.unwrap() >= DUP_THRESHOLD);
        assert!(d.mean_similarity.unwrap() < d.max_similarity.unwrap());
    }
}
