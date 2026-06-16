//! Best-of-N request schema + validation (#690).
//!
//! Mirrors `tot::schema` conventions: a permissive `Deserialize` input with
//! all-optional fields, resolved into a validated `BestOfNParams` with
//! defaults and bounds applied. Invalid values fail fast with an OpenAI-shape
//! `(field, message)` 400 rather than being silently clamped.

use serde::Deserialize;

use crate::chat::completions::ChatMessage;

/// Default number of candidate continuations generated per round.
pub const DEFAULT_N: usize = 5;
/// Hard cap on N (mirrors the tree-of-thought `breadth` cap of 5).
pub const MAX_N: usize = 5;

const DEFAULT_MAX_TOKENS: usize = 256;
const MAX_MAX_TOKENS: usize = 1024;
const DEFAULT_MAX_REASONING_TOKENS: usize = 2048;
const MAX_MAX_REASONING_TOKENS: usize = 4096;
const DEFAULT_TEMPERATURE: f32 = 0.7;
const DEFAULT_TOP_P: f32 = 0.95;

/// Raw best-of-n request payload (`input` of a `/v1/inferlet` dispatch).
#[derive(Clone, Deserialize, Default)]
pub struct BestOfNInput {
    pub model: Option<String>,
    pub messages: Option<Vec<ChatMessage>>,
    /// Candidates generated per round (default [`DEFAULT_N`], cap [`MAX_N`]).
    pub n: Option<usize>,
    pub max_tokens_per_candidate: Option<usize>,
    pub max_reasoning_tokens: Option<usize>,
    pub temperature: Option<f32>,
    pub top_p: Option<f32>,
    /// Defaults OFF (#679): a round does not ride the thinking-ON ToT crash
    /// path. A caller may opt in once that bug is resolved.
    pub thinking: Option<bool>,

    // ── Round / resume state ────────────────────────────────────────────
    // Round 1 leaves these unset. The pick/think-more round (Phase 1b) opens
    // `resume_from`, drops the `unpicked` snapshots, and advances `level`.
    /// Snapshot name of the picked candidate to expand from next round.
    pub resume_from: Option<String>,
    /// The picked candidate's text. Required with `resume_from`: it re-prefills
    /// the base if the snapshot was LRU-evicted during the pick.
    pub picked_text: Option<String>,
    /// Snapshot names of the unpicked siblings to delete (deterministic free).
    pub unpicked: Option<Vec<String>>,
    /// Current depth: round 1 = 1; think-more increments.
    pub level: Option<usize>,

    // ── Lifecycle release (terminal cleanup) ────────────────────────────
    /// Snapshot names to release (delete) without generating. Set by the app
    /// on a terminal outcome that has NO further round — stop/commit (the
    /// chosen reply's text is persisted, so its KV snapshot is no longer
    /// needed) or abandon (the user moved on without picking). A release
    /// request carries no `messages` and produces no candidates: it just frees
    /// the round's KV pages so a long session cannot accumulate orphaned
    /// snapshots. Think-more frees its prior round through the resume path
    /// instead, so this is only for the no-next-round terminals.
    pub release: Option<Vec<String>>,
}

/// Validated, defaulted best-of-n parameters for one round.
#[derive(Debug, Clone, PartialEq)]
pub struct BestOfNParams {
    pub n: usize,
    pub max_tokens_per_candidate: usize,
    pub max_reasoning_tokens: usize,
    pub temperature: f32,
    pub top_p: f32,
    pub thinking: bool,
    pub level: usize,
}

/// Apply defaults + bounds. `Err((field, message))` is an OpenAI-shape 400.
pub fn resolve(input: &BestOfNInput) -> Result<BestOfNParams, (&'static str, String)> {
    let n = match input.n {
        None => DEFAULT_N,
        Some(0) => return Err(("n", "n must be >= 1".to_string())),
        Some(v) if v > MAX_N => return Err(("n", format!("n must be <= {MAX_N}"))),
        Some(v) => v,
    };
    let max_tokens_per_candidate = clamp_usize(
        input.max_tokens_per_candidate,
        DEFAULT_MAX_TOKENS,
        MAX_MAX_TOKENS,
        "max_tokens_per_candidate",
    )?;
    let max_reasoning_tokens = clamp_usize(
        input.max_reasoning_tokens,
        DEFAULT_MAX_REASONING_TOKENS,
        MAX_MAX_REASONING_TOKENS,
        "max_reasoning_tokens",
    )?;
    let temperature = match input.temperature {
        None => DEFAULT_TEMPERATURE,
        Some(v) if (0.0..=2.0).contains(&v) => v,
        Some(_) => return Err(("temperature", "temperature must be in [0.0, 2.0]".to_string())),
    };
    let top_p = match input.top_p {
        None => DEFAULT_TOP_P,
        Some(v) if v > 0.0 && v <= 1.0 => v,
        Some(_) => return Err(("top_p", "top_p must be in (0.0, 1.0]".to_string())),
    };
    let thinking = input.thinking.unwrap_or(false);
    let level = input.level.unwrap_or(1).max(1);
    Ok(BestOfNParams {
        n,
        max_tokens_per_candidate,
        max_reasoning_tokens,
        temperature,
        top_p,
        thinking,
        level,
    })
}

fn clamp_usize(
    v: Option<usize>,
    default: usize,
    max: usize,
    field: &'static str,
) -> Result<usize, (&'static str, String)> {
    match v {
        None => Ok(default),
        Some(0) => Err((field, format!("{field} must be >= 1"))),
        Some(v) if v > max => Err((field, format!("{field} must be <= {max}"))),
        Some(v) => Ok(v),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn defaults_apply_when_unset() {
        let p = resolve(&BestOfNInput::default()).expect("defaults resolve");
        assert_eq!(p.n, DEFAULT_N);
        assert_eq!(p.max_tokens_per_candidate, DEFAULT_MAX_TOKENS);
        assert_eq!(p.max_reasoning_tokens, DEFAULT_MAX_REASONING_TOKENS);
        assert_eq!(p.temperature, DEFAULT_TEMPERATURE);
        assert_eq!(p.top_p, DEFAULT_TOP_P);
        assert_eq!(p.level, 1);
        // #679: thinking is off unless explicitly opted in.
        assert!(!p.thinking);
    }

    #[test]
    fn n_is_capped_and_floored() {
        assert_eq!(
            resolve(&BestOfNInput { n: Some(0), ..Default::default() }).unwrap_err().0,
            "n"
        );
        assert_eq!(
            resolve(&BestOfNInput { n: Some(MAX_N + 1), ..Default::default() }).unwrap_err().0,
            "n"
        );
        assert_eq!(
            resolve(&BestOfNInput { n: Some(3), ..Default::default() }).unwrap().n,
            3
        );
    }

    #[test]
    fn token_budgets_reject_zero_and_over_cap() {
        assert_eq!(
            resolve(&BestOfNInput { max_tokens_per_candidate: Some(0), ..Default::default() })
                .unwrap_err()
                .0,
            "max_tokens_per_candidate"
        );
        assert_eq!(
            resolve(&BestOfNInput {
                max_tokens_per_candidate: Some(MAX_MAX_TOKENS + 1),
                ..Default::default()
            })
            .unwrap_err()
            .0,
            "max_tokens_per_candidate"
        );
        assert_eq!(
            resolve(&BestOfNInput {
                max_reasoning_tokens: Some(MAX_MAX_REASONING_TOKENS + 1),
                ..Default::default()
            })
            .unwrap_err()
            .0,
            "max_reasoning_tokens"
        );
    }

    #[test]
    fn sampling_ranges_are_validated() {
        assert_eq!(
            resolve(&BestOfNInput { temperature: Some(2.5), ..Default::default() }).unwrap_err().0,
            "temperature"
        );
        assert_eq!(
            resolve(&BestOfNInput { top_p: Some(0.0), ..Default::default() }).unwrap_err().0,
            "top_p"
        );
        assert_eq!(
            resolve(&BestOfNInput { top_p: Some(1.0), ..Default::default() }).unwrap().top_p,
            1.0
        );
    }

    #[test]
    fn thinking_opt_in_is_honored() {
        let p = resolve(&BestOfNInput { thinking: Some(true), ..Default::default() }).unwrap();
        assert!(p.thinking);
    }

    #[test]
    fn level_defaults_to_one_and_floors() {
        assert_eq!(resolve(&BestOfNInput { level: Some(0), ..Default::default() }).unwrap().level, 1);
        assert_eq!(resolve(&BestOfNInput { level: Some(3), ..Default::default() }).unwrap().level, 3);
    }
}
