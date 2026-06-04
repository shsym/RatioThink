//! Request schema, bounds, and validation for the tree-of-thought mode.
//!
//! Pure logic — unit-tested natively via `cargo test --lib`.

use serde::Deserialize;

use crate::chat::completions::ChatMessage;

// ── Bounds (server-enforced) ──────────────────────────────────────────
pub const MAX_BREADTH: usize = 5;
pub const MAX_DEPTH: usize = 4;
pub const MAX_BEAM_WIDTH: usize = 5;
pub const MAX_TOKENS_PER_NODE: usize = 1024;
/// Cap on total candidate nodes generated across all levels. Guards
/// local compute against `breadth × depth × beam_width` blow-up.
pub const MAX_NODES: usize = 64;

// ── Defaults ──────────────────────────────────────────────────────────
pub const DEFAULT_BREADTH: usize = 3;
pub const DEFAULT_DEPTH: usize = 2;
pub const DEFAULT_BEAM_WIDTH: usize = 2;
pub const DEFAULT_MAX_TOKENS_PER_NODE: usize = 256;
pub const DEFAULT_TEMPERATURE: f32 = 0.7;
pub const DEFAULT_TOP_P: f32 = 0.95;

/// Raw `input` payload for `inferlet:"tree-of-thought"`. Every field is
/// optional; missing fields take the defaults above. `messages` may also
/// be supplied at the top level of the dispatch envelope (handled by the
/// caller; `input.messages` wins on overlap).
#[derive(Deserialize, Default)]
pub struct TotInput {
    pub model: Option<String>,
    pub messages: Option<Vec<ChatMessage>>,
    pub breadth: Option<usize>,
    pub depth: Option<usize>,
    pub beam_width: Option<usize>,
    pub max_tokens_per_node: Option<usize>,
    pub temperature: Option<f32>,
    pub top_p: Option<f32>,
}

/// Validated, defaulted search parameters.
#[derive(Debug)]
pub struct TotParams {
    pub breadth: usize,
    pub depth: usize,
    pub beam_width: usize,
    pub max_tokens_per_node: usize,
    pub temperature: f32,
    pub top_p: f32,
}

/// Total candidate nodes generated across all levels:
/// `breadth` at level 1, then `beam_width × breadth` at each deeper level.
pub fn total_candidates(breadth: usize, depth: usize, beam_width: usize) -> usize {
    if depth == 0 {
        return 0;
    }
    breadth + (depth - 1) * beam_width * breadth
}

/// Validate + apply defaults. `Err` is `(field, message)` where `field`
/// names the offending JSON key for the OpenAI-shape `param`.
pub fn resolve(input: &TotInput) -> Result<TotParams, (&'static str, String)> {
    let breadth = input.breadth.unwrap_or(DEFAULT_BREADTH);
    let depth = input.depth.unwrap_or(DEFAULT_DEPTH);
    let beam_width = input.beam_width.unwrap_or(DEFAULT_BEAM_WIDTH);
    let max_tokens_per_node = input
        .max_tokens_per_node
        .unwrap_or(DEFAULT_MAX_TOKENS_PER_NODE);
    let temperature = input.temperature.unwrap_or(DEFAULT_TEMPERATURE);
    let top_p = input.top_p.unwrap_or(DEFAULT_TOP_P);

    if !(1..=MAX_BREADTH).contains(&breadth) {
        return Err(("breadth", format!("breadth must be in [1, {MAX_BREADTH}]")));
    }
    if !(1..=MAX_DEPTH).contains(&depth) {
        return Err(("depth", format!("depth must be in [1, {MAX_DEPTH}]")));
    }
    if !(1..=MAX_BEAM_WIDTH).contains(&beam_width) {
        return Err((
            "beam_width",
            format!("beam_width must be in [1, {MAX_BEAM_WIDTH}]"),
        ));
    }
    if !(1..=MAX_TOKENS_PER_NODE).contains(&max_tokens_per_node) {
        return Err((
            "max_tokens_per_node",
            format!("max_tokens_per_node must be in [1, {MAX_TOKENS_PER_NODE}]"),
        ));
    }
    if !(temperature.is_finite() && (0.0..=2.0).contains(&temperature)) {
        return Err(("temperature", "temperature must be in [0.0, 2.0]".to_string()));
    }
    if !(top_p.is_finite() && top_p > 0.0 && top_p <= 1.0) {
        return Err(("top_p", "top_p must be in (0.0, 1.0]".to_string()));
    }

    let total = total_candidates(breadth, depth, beam_width);
    if total > MAX_NODES {
        return Err((
            "breadth",
            format!(
                "breadth/depth/beam_width would generate {total} nodes (max {MAX_NODES}); \
                 reduce breadth, depth, or beam_width"
            ),
        ));
    }

    Ok(TotParams {
        breadth,
        depth,
        beam_width,
        max_tokens_per_node,
        temperature,
        top_p,
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    fn input() -> TotInput {
        TotInput::default()
    }

    #[test]
    fn total_candidates_formula() {
        assert_eq!(total_candidates(3, 2, 2), 3 + 2 * 3); // 9
        assert_eq!(total_candidates(3, 3, 3), 3 + 2 * 3 * 3); // 21
        assert_eq!(total_candidates(3, 1, 5), 3); // depth 1 ignores beam
        assert_eq!(total_candidates(5, 4, 5), 5 + 3 * 5 * 5); // 80
    }

    #[test]
    fn defaults_resolve() {
        let p = resolve(&input()).unwrap();
        assert_eq!((p.breadth, p.depth, p.beam_width), (3, 2, 2));
        assert_eq!(p.max_tokens_per_node, 256);
    }

    #[test]
    fn rejects_zero_breadth() {
        let mut i = input();
        i.breadth = Some(0);
        assert_eq!(resolve(&i).unwrap_err().0, "breadth");
    }

    #[test]
    fn rejects_over_max_depth() {
        let mut i = input();
        i.depth = Some(5);
        assert_eq!(resolve(&i).unwrap_err().0, "depth");
    }

    #[test]
    fn rejects_node_explosion() {
        let mut i = input();
        i.breadth = Some(5);
        i.depth = Some(4);
        i.beam_width = Some(5); // 80 > 64
        assert_eq!(resolve(&i).unwrap_err().0, "breadth");
    }

    #[test]
    fn accepts_largest_under_cap() {
        let mut i = input();
        i.breadth = Some(4);
        i.depth = Some(3);
        i.beam_width = Some(3); // 4 + 2*9 = 22 <= 64
        assert!(resolve(&i).is_ok());
    }

    #[test]
    fn rejects_out_of_range_top_p() {
        let mut i = input();
        i.top_p = Some(0.0);
        assert_eq!(resolve(&i).unwrap_err().0, "top_p");
        i.top_p = Some(1.5);
        assert_eq!(resolve(&i).unwrap_err().0, "top_p");
    }

    #[test]
    fn rejects_out_of_range_temperature() {
        let mut i = input();
        i.temperature = Some(2.5);
        assert_eq!(resolve(&i).unwrap_err().0, "temperature");
    }

    #[test]
    fn rejects_zero_max_tokens() {
        let mut i = input();
        i.max_tokens_per_node = Some(0);
        assert_eq!(resolve(&i).unwrap_err().0, "max_tokens_per_node");
    }
}
