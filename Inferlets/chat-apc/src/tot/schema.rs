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
/// Cap on the per-node REASONING budget (#413/#434). With thinking enabled
/// a node generates in two phases — reasoning up to this many tokens, then
/// the answer up to `max_tokens_per_node` — so the answer is never starved
/// by an over-long thought (the #434 truncation). Bounds compute against a
/// runaway thinker.
pub const MAX_REASONING_TOKENS: usize = 4096;
/// Cap on total candidate nodes generated across all levels. Guards
/// local compute against `breadth × depth × beam_width` blow-up.
pub const MAX_NODES: usize = 64;

// ── Defaults ──────────────────────────────────────────────────────────
pub const DEFAULT_BREADTH: usize = 3;
pub const DEFAULT_DEPTH: usize = 2;
pub const DEFAULT_BEAM_WIDTH: usize = 2;
pub const DEFAULT_MAX_TOKENS_PER_NODE: usize = 256;
/// Default reasoning budget — generous so a small thinking model finishes its
/// `<think>` block before the answer phase begins. Qwen3-0.6B can exceed 1024
/// on short deterministic ToT turns after the extra synthesis cue, so default
/// to the next power-of-two tier rather than silently surfacing
/// `final_answer_unavailable`.
pub const DEFAULT_MAX_REASONING_TOKENS: usize = 2048;
/// Branch-generation temperature. Sibling diversity now has two
/// sources — per-branch strategy directives (`search.rs`
/// `strategy_directive`) plus sampling temperature — but temperature
/// still has to carry within-strategy variation, so the default is
/// justified by measurement, not assumption.
///
/// MEASURED, portable Metal + Qwen3-0.6B-Q8_0,
/// `Scripts/run-tot-diversity-probe.sh` (2026-06-10, log
/// `test-20260610-230258-tot-diversity-probe.log`) — taken on the
/// temperature-ONLY baseline (before the strategy directives landed),
/// i.e. the worst case for this knob: depth-1 searches at
/// `DEFAULT_BREADTH`, thinking on, short-factual / math / open-ended
/// prompts, 2 repeats per cell. At 0.7: zero byte-identical sibling
/// pairs in every cell; the diversity-sensitive open-ended prompt
/// produced 3/3 distinct 8-word prefixes both repeats (mean pairwise
/// word-Jaccard 0.21). Raising to 1.0/1.3 increased divergence
/// monotonically (open-ended Jaccard 0.19/0.10) but fixed nothing that
/// was broken, and 1.3 produced the sweep's only branch failure (a
/// math cell at 2/3 answered). 0.7 already gave healthy divergence
/// with no quality cliff even WITHOUT the directives; with them
/// stacked on top there is even less reason to raise it.
pub const DEFAULT_TEMPERATURE: f32 = 0.7;
pub const DEFAULT_TOP_P: f32 = 0.95;
/// Reasoning is the POINT of a tree-of-thought search, so thinking is ON by
/// default (#413). Set `thinking:false` to append `/no_think` and run nodes
/// as concise non-reasoning candidates.
pub const DEFAULT_THINKING: bool = true;

/// Sibling execution strategy (#458). Controls *how* a level's branches are
/// generated and scored, on two independent axes:
///
/// - **generation**: concurrent (all siblings in flight at once, so their
///   per-step forward passes coalesce into one batched GPU pass via the
///   engine's per-device scheduler — there is no multi-context forward-pass
///   primitive, `join_all` IS the batched-decode API) vs sequential (one
///   node at a time).
/// - **scoring**: phased (a barrier — every branch finishes generating, then
///   all `Answered` nodes are scored in one concurrent batch) vs coupled
///   (each branch generates then immediately scores, so scoring overlaps the
///   next branch's generation under concurrency — the pre-#458 shape).
///
/// The chosen strategy NEVER changes the returned tree (same nodes, scores,
/// statuses, order) — only how it is computed. So this is an additive,
/// optional execution hint, not a wire contract. The variants exist to
/// benchmark the two axes on one warm engine (`tot_bench.py`).
///
/// On the **streaming** path generation is always sequential regardless of
/// this knob (a single SSE emitter cannot be shared across concurrent branch
/// futures, so node deltas would have no exclusive writer).
///
/// ## Why the default is `CoupledConcurrent` (#465, RE-MEASURED)
///
/// #458 measured concurrent ≈ sequential and made `CoupledSequential` the
/// default, because the engine host resolved `forward-pass.execute()`
/// **eagerly** — an async host call suspended the whole single-stack wasm
/// guest, so `join_all` could never put two sibling decode steps in flight
/// (probe: batch size 1, driver `contexts=1` always). That bottleneck is
/// gone: pie `82e81034` ("Fix serialized forked branch generation", #369,
/// on `pie.app/v1-base-shmem`) made `execute()` non-blocking — it spawns the
/// pin→submit→await→fill→unpin pipeline and returns a pending `FutureOutput`
/// immediately, so siblings stay in flight and the per-device scheduler
/// coalesces them. (See `search` module docs for the host `execute()` shape.)
///
/// Re-measured on real portable Metal (`make bench-tot`, Qwen3-0.6B-Q8_0,
/// 3 trials) at the current `Vendor/pie` pin, sibling decode now co-batches —
/// the driver logs `contexts` up to **23** at the 25-fork shape (was always
/// `1` at the #458 pin). Greedy (wall-comparable) speedup vs `coupled_sequential`:
///
/// | shape          | coupled_concurrent | phased_concurrent | phased_sequential |
/// |----------------|--------------------|-------------------|-------------------|
/// | b4·d1          | 1.45×              | 1.47×             | 1.21×             |
/// | b3·d2 (default)| 1.22×              | 1.18×             | 1.02×             |
/// | b5·d1          | 1.51×              | 1.56×             | 1.28×             |
/// | b5·d2 (25-fork)| 1.68×              | 1.70×             | 1.34×             |
///
/// In the sampled (t=0.7) regime siblings desync, so wall-clock is not
/// comparable across trials (the bench measures tokens/s there): by tok/s
/// `coupled_concurrent` is 1.07–1.27× and `phased_concurrent` 1.08–1.43×.
/// The strategy never changes the returned tree — only how it is computed.
///
/// `CoupledConcurrent` is the default: it wins monotonically in the
/// wall-comparable greedy regime, never net-regresses by tok/s, and carries
/// the **lowest KV residency** of the concurrent variants — it has no phase
/// barrier, so a branch's score overlaps the next branch's generation and
/// only a few contexts are resident at once. The phased variants add a
/// barrier that holds every sibling context *plus* its score-fork resident
/// simultaneously; #458 saw that spike past the eviction threshold and
/// regress 2–3× under KV pressure. The prompt unpin in pie's deferred
/// `execute()` relieved that enough that phasing did NOT regress here on a
/// 0.6B model, but the headroom on production-size models is unmeasured —
/// so the phased variants stay behind the `exec-strategies` feature as the
/// benchmark apparatus, not a production path. `phased_sequential` also
/// net-regresses in the sampled regime (tok/s ≤ 1.0× at b4·d1 / b3·d2).
#[derive(Deserialize, Debug, Clone, Copy, PartialEq, Eq, Default)]
#[serde(rename_all = "snake_case")]
pub enum ExecStrategy {
    /// Default (#465, re-measured optimal): concurrent generation — siblings
    /// decode in flight so the engine batches their forward passes — with
    /// scoring coupled per branch (no phase barrier → lowest KV residency).
    #[default]
    CoupledConcurrent,
    /// Sequential generation, scoring coupled per node — the pre-#458 / #413
    /// shape. Lowest concurrency; the explicit low-residency escape hatch.
    CoupledSequential,
    /// Sequential generation, phased concurrent scoring — isolates the phase
    /// barrier (and batched scoring). Benchmark apparatus only: net-regresses
    /// in the sampled regime and holds high KV residency.
    PhasedSequential,
    /// Concurrent generation + phased concurrent scoring — the "fully batched"
    /// variant. Wins on a 0.6B model but the phase barrier's KV residency is
    /// unmeasured on production-size models. Benchmark apparatus only.
    PhasedConcurrent,
}

impl ExecStrategy {
    /// Whether sibling generation runs concurrently (engine-batched). The
    /// streaming path forces this false regardless (see [`ExecStrategy`]).
    pub fn concurrent_gen(self) -> bool {
        matches!(self, Self::PhasedConcurrent | Self::CoupledConcurrent)
    }

    /// Whether scoring is a phase after all generation (`true`) or coupled
    /// to each branch's generation (`false`).
    pub fn phased_score(self) -> bool {
        matches!(self, Self::PhasedConcurrent | Self::PhasedSequential)
    }
}

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
    pub max_reasoning_tokens: Option<usize>,
    pub temperature: Option<f32>,
    pub top_p: Option<f32>,
    pub thinking: Option<bool>,
    /// Sibling execution strategy (#458). Optional execution hint; defaults
    /// to the production [`ExecStrategy`]. Does not change the returned tree.
    pub exec: Option<ExecStrategy>,
}

/// Validated, defaulted search parameters.
#[derive(Debug)]
pub struct TotParams {
    pub breadth: usize,
    pub depth: usize,
    pub beam_width: usize,
    /// Answer-phase token budget per node.
    pub max_tokens_per_node: usize,
    /// Reasoning-phase token budget per node (only spent when `thinking`).
    pub max_reasoning_tokens: usize,
    /// Candidate-**generation** temperature (#523 Part B). This is the only
    /// client-tunable temperature axis and may run high for branch diversity
    /// headroom; the scorer is fixed greedy (`0.0`) for deterministic pruning
    /// and the final synthesis is a fixed low temperature for a coherent
    /// answer — neither is exposed here. Sourced from the app profile's
    /// `sampling.temperature` for a tree-of-thought profile.
    pub temperature: f32,
    pub top_p: f32,
    /// When true, nodes generate a `<think>` reasoning block before the
    /// answer (demuxed apart); when false, `/no_think` suppresses it.
    pub thinking: bool,
    /// Sibling execution strategy (#458) — how branches are generated/scored.
    /// Production default; never changes the returned tree.
    pub exec: ExecStrategy,
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
    let max_reasoning_tokens = input
        .max_reasoning_tokens
        .unwrap_or(DEFAULT_MAX_REASONING_TOKENS);
    let temperature = input.temperature.unwrap_or(DEFAULT_TEMPERATURE);
    let top_p = input.top_p.unwrap_or(DEFAULT_TOP_P);
    let thinking = input.thinking.unwrap_or(DEFAULT_THINKING);
    let exec = input.exec.unwrap_or_default();
    // #465 gate: production builds (feature off) support the two *coupled*
    // strategies — `coupled_concurrent` (the re-measured default) and
    // `coupled_sequential` (the low-residency escape hatch) — and REJECT the
    // *phased* variants, whose phase barrier holds high KV residency that is
    // unmeasured on production-size models (and which net-regress in the
    // sampled regime). Rejecting rather than silently coercing keeps the
    // client from unknowingly getting a different path. The benchmark /
    // strategy e2e build with `--features exec-strategies` to drive every
    // variant. See [`ExecStrategy`] for the measurement.
    #[cfg(not(feature = "exec-strategies"))]
    if exec.phased_score() {
        return Err((
            "exec",
            "phased exec strategies are benchmark-only on this build; use \
             `coupled_concurrent` (the default) or `coupled_sequential`"
                .to_string(),
        ));
    }

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
    if !(1..=MAX_REASONING_TOKENS).contains(&max_reasoning_tokens) {
        return Err((
            "max_reasoning_tokens",
            format!("max_reasoning_tokens must be in [1, {MAX_REASONING_TOKENS}]"),
        ));
    }
    if !(temperature.is_finite() && (0.0..=2.0).contains(&temperature)) {
        return Err((
            "temperature",
            "temperature must be in [0.0, 2.0]".to_string(),
        ));
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
        max_reasoning_tokens,
        temperature,
        top_p,
        thinking,
        exec,
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
        // #413: thinking ON by default, with a generous reasoning budget.
        assert!(p.thinking);
        assert_eq!(p.max_reasoning_tokens, 2048);
        // Branch-generation sampling defaults. 0.7 is measurement-backed
        // (see DEFAULT_TEMPERATURE docs) — a silent default change would
        // invalidate the recorded sibling-diversity justification.
        assert_eq!(p.temperature, DEFAULT_TEMPERATURE);
        assert_eq!(p.temperature, 0.7);
        assert_eq!(p.top_p, DEFAULT_TOP_P);
    }

    #[test]
    fn thinking_knob_round_trips() {
        let mut i = input();
        i.thinking = Some(false);
        assert!(!resolve(&i).unwrap().thinking);
    }

    #[test]
    fn generation_temperature_defaults_then_passes_through() {
        // #523 Part B: the generation temperature defaults to 0.7 and
        // otherwise comes straight from the request (sourced app-side from
        // the profile's sampling.temperature) — including the high end of
        // the range, for branch-diversity headroom.
        assert_eq!(resolve(&input()).unwrap().temperature, DEFAULT_TEMPERATURE);
        let mut i = input();
        i.temperature = Some(1.4);
        assert_eq!(resolve(&i).unwrap().temperature, 1.4);
    }

    #[test]
    fn exec_defaults_to_coupled_concurrent() {
        // #465 (RE-MEASURED): with pie's deferred `execute()` (#369) siblings
        // co-batch, so concurrent generation + coupled scoring is the fastest
        // (and lowest-residency) measured strategy and is now the default. An
        // unset `exec` resolves to it.
        assert_eq!(
            resolve(&input()).unwrap().exec,
            ExecStrategy::CoupledConcurrent
        );
        assert_eq!(ExecStrategy::default(), ExecStrategy::CoupledConcurrent);
    }

    // Both coupled strategies resolve on either build (#465): concurrent is
    // the production default, sequential the low-residency escape hatch.
    #[test]
    fn exec_coupled_variants_always_accepted() {
        for s in [
            ExecStrategy::CoupledConcurrent,
            ExecStrategy::CoupledSequential,
        ] {
            let mut i = input();
            i.exec = Some(s);
            assert_eq!(resolve(&i).unwrap().exec, s);
        }
    }

    // Production build (feature off): the phased variants are benchmark-only
    // and REJECTED with a param-tagged error, never silently coerced (#465).
    #[cfg(not(feature = "exec-strategies"))]
    #[test]
    fn exec_phased_rejected_without_feature() {
        for s in [
            ExecStrategy::PhasedSequential,
            ExecStrategy::PhasedConcurrent,
        ] {
            let mut i = input();
            i.exec = Some(s);
            assert_eq!(resolve(&i).unwrap_err().0, "exec", "{s:?} must be rejected");
        }
    }

    // Gated build (feature on): every variant resolves to itself (the
    // benchmark / strategy-e2e path).
    #[cfg(feature = "exec-strategies")]
    #[test]
    fn exec_all_variants_resolve_with_feature() {
        for s in [
            ExecStrategy::CoupledSequential,
            ExecStrategy::CoupledConcurrent,
            ExecStrategy::PhasedSequential,
            ExecStrategy::PhasedConcurrent,
        ] {
            let mut i = input();
            i.exec = Some(s);
            assert_eq!(resolve(&i).unwrap().exec, s);
        }
    }

    #[test]
    fn exec_axes_map_to_bools() {
        // Two independent axes: generation concurrency × scoring phase.
        assert!(ExecStrategy::PhasedConcurrent.concurrent_gen());
        assert!(ExecStrategy::PhasedConcurrent.phased_score());
        assert!(!ExecStrategy::CoupledSequential.concurrent_gen());
        assert!(!ExecStrategy::CoupledSequential.phased_score());
        assert!(ExecStrategy::CoupledConcurrent.concurrent_gen());
        assert!(!ExecStrategy::CoupledConcurrent.phased_score());
        assert!(!ExecStrategy::PhasedSequential.concurrent_gen());
        assert!(ExecStrategy::PhasedSequential.phased_score());
    }

    // snake_case wire parse of a non-default variant — only reachable on a
    // gated build (production rejects it; see exec_nondefault_rejected...).
    #[cfg(feature = "exec-strategies")]
    #[test]
    fn exec_deserializes_snake_case() {
        let i: TotInput = serde_json::from_str(r#"{"exec":"coupled_concurrent"}"#).unwrap();
        assert_eq!(resolve(&i).unwrap().exec, ExecStrategy::CoupledConcurrent);
    }

    #[test]
    fn rejects_zero_max_reasoning_tokens() {
        let mut i = input();
        i.max_reasoning_tokens = Some(0);
        assert_eq!(resolve(&i).unwrap_err().0, "max_reasoning_tokens");
    }

    #[test]
    fn rejects_over_max_reasoning_tokens() {
        let mut i = input();
        i.max_reasoning_tokens = Some(MAX_REASONING_TOKENS + 1);
        assert_eq!(resolve(&i).unwrap_err().0, "max_reasoning_tokens");
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
