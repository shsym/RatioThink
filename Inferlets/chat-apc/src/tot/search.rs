//! Tree-of-Thought BFS beam search orchestration (Yao et al. 2023).
//!
//! For each of `depth` levels: every frontier node forks `breadth`
//! children from its common prefix (KV-cache sharing), each child
//! generates a candidate continuation, and a value evaluator scores it
//! 1–10. The top `beam_width` candidates by score survive as the next
//! frontier. The best-scoring leaf at the deepest level that produced a
//! surviving (beam-kept) candidate is the final answer — earlier levels
//! are preserved when a later level fully fails (see `fold_level` / F7).
//!
//! ## Batched sibling decoding + parallel scoring (#458 — investigated, NOT a win)
//!
//! A level's branches are sibling forks of one shared, flushed, cue-free
//! prefix. There is **no multi-context forward-pass primitive** — the WIT
//! `forward-pass` binds a single `context`, so the only way to put N siblings
//! on one GPU forward pass is to have N decode steps *in flight at the same
//! time* and let the engine's per-device batch scheduler coalesce them. The
//! idiomatic attempt is `futures::future::join_all` over the sibling decode
//! loops (the pattern Pie's own `parallel-generation` / `tree-of-thought`
//! examples use).
//!
//! **It does not pay off from inside a single inferlet** — verified by code
//! + instrumentation, not wall-clock alone (#458):
//!
//! - Concurrency buys ~0%. The SDK *does* have an async surface — `execute()`
//!   returns a `future-output` and `ForwardPassExt::execute_async` awaits its
//!   pollable — and the wstd reactor + `join_all` would submit every sibling
//!   before blocking. But the engine host resolves `execute()` **eagerly**:
//!   its host impl (`Vendor/pie/runtime/src/api/inference.rs:324`) is an
//!   `async fn` that `inference::submit(...).await`s the forward pass to
//!   completion and returns an already-done `FutureOutput { done: true }`
//!   (ibid. ~447, 506) — the deferred `rx`/`done:false` path on `FutureOutput`
//!   (ibid. 45–75) is left unused. A wasm guest is a single execution stack,
//!   so an async host call suspends the *whole* guest: `join_all` cannot
//!   advance a sibling past its `execute()` until the current pass finishes.
//!   Forward passes from one inferlet therefore reach the per-device batch
//!   scheduler **strictly serially** — measured with a scheduler probe over
//!   1503 passes at 25 concurrent forks (breadth 5, depth 2, beam 5): every
//!   cycle was `recv → batch_len=1 → fire size=1`, with the non-blocking drain
//!   never once finding a second request, and the portable driver logging
//!   `contexts=1` for every pass. Batch size is structurally 1 regardless of
//!   breadth — this is the precise form of #413's "engine batches forks only
//!   weakly", and it is NOT small-breadth economics (25 ≫ a level's nodes
//!   still never co-batched).
//! - A phased generate-then-score barrier buys ~0% and **regresses 2–3×**
//!   under high KV residency: holding every sibling context plus its
//!   score-fork resident spikes KV-page use past the eviction threshold, so
//!   each pass then pays suspend/restore.
//!
//! So the default [`ExecStrategy`](super::schema::ExecStrategy) is
//! `CoupledSequential` — generate-then-score one node at a time, the
//! memory-frugal pre-#458 / #413 shape, fastest-or-tied at every shape. The
//! knob still exposes two axes —
//! - **generation** concurrent (engine-*would*-batch, if the host deferred
//!   `execute()`) vs sequential;
//! - **scoring** phased (barrier, all `Answered` nodes scored in one
//!   concurrent batch) vs coupled (each branch generates then scores) —
//! so the non-default variants remain as the reproducible measurement
//! apparatus, never the production path. They never change the returned tree.
//!
//! **Upstream blocker (real capability gap):** batched sibling decode needs
//! the engine host to make `forward-pass.execute()` genuinely deferred —
//! enqueue the pass to the scheduler and return a pending `FutureOutput`
//! (`rx: Some`, `done: false`) immediately, resolving it via the pollable —
//! so a single guest can hold several passes in flight and the scheduler can
//! coalesce them. (The `FutureOutput` deferral path already exists; only
//! `execute()` short-circuits it.) Phased scoring additionally needs enough
//! KV headroom to keep a level's contexts resident. The apparatus lets a
//! future session re-run `make bench-tot` once that host change lands.
//!
//! ### Streaming constraint (#413)
//!
//! On the streaming path generation is forced **sequential** regardless of
//! `exec`: a single SSE [`Emitter`] cannot be shared across concurrent
//! branch futures, so per-node `node_delta` chunks would have no exclusive
//! writer. Scoring never streams, so it still phases + batches there — a
//! streamed search keeps #413's one-node-at-a-time live fill while its
//! per-level scoring runs as a coalesced batch. Both paths emit a
//! byte-identical final tree.
//!
//! The WIT-backed engine calls (`Context`/`generate`/`fork`) live in
//! [`run`], [`resolve_level`], [`generate_branch`], [`expand`], and
//! [`score_node`] and are exercised by the real-engine e2e. The
//! Context-free bookkeeping — node classification, materialization,
//! pruning, the empty-frontier break, and final-answer selection — is split
//! into the pure helpers [`classify`], [`materialize_level`],
//! [`fold_level`], and [`finalize`], which are unit-tested natively via
//! `cargo test --lib`.

use futures::future::join_all;
use inferlet::Context;
use inferlet::model::Model;
use inferlet::sample::Sampler;
use inferlet::{chat, reasoning};
use std::future::Future;
use std::pin::Pin;

use crate::sse::Emitter;

use super::schema::TotParams;
use super::stream;
use super::tree::{
    Candidate, Node, NodeStatus, assemble, best_leaf, error_leaf, new_node_id, parse_score,
    select_beam_diverse,
};

/// Per-branch directive appended to each forked child before it generates
/// (#523). The branch index makes every sibling's prompt textually distinct
/// — breaking the prior collapse where all `breadth` children shared one
/// prompt and diverged only by sampling temperature — and instructs ONE
/// mutually-exclusive, *named* strategy that differs by primary objective or
/// tradeoff, not wording. Level 1 proposes a fresh strategy directly; deeper
/// levels critique the parent then refine along a distinct axis (this
/// replaces the old single shared `REFINE_INSTRUCTION`, which was flushed
/// identically into every sibling and so could not diversify them).
///
/// Reasoning-aware (#413/#437): a node may generate a `<think>` block then
/// an answer, which [`generate_demuxed`] splits apart — reasoning IS the
/// point of a tree-of-thought search, so the candidate keeps its thought
/// trace while the beam and scorer see only the clean answer. The directive
/// is wrapped in [`with_thinking`], which appends `/no_think` only when the
/// search runs with `thinking:false`. Pure → unit-tested.
fn branch_directive(level: usize, branch_index: usize, breadth: usize, thinking: bool) -> String {
    let n = branch_index + 1;
    let body = if level <= 1 {
        format!(
            "Explore solution path {n} of {breadth} for the user's request. Commit to ONE \
             specific strategy that differs from the other paths by its primary objective or key \
             tradeoff — not just by wording. Name your strategy in a short phrase, then answer the \
             request fully using only that strategy. Be concrete and specific."
        )
    } else {
        format!(
            "Critique your previous answer, then continue along refinement path {n} of {breadth}: \
             pick ONE distinct improvement focus that differs from the sibling paths by primary \
             objective or tradeoff. Name the focus in a short phrase, then give an improved, \
             concrete answer committed to it."
        )
    };
    with_thinking(&body, thinking)
}

/// Value-evaluator prompt (independent per-node scoring). The node already
/// did its reasoning; the scorer is a value HEAD that rates the resulting
/// ANSWER (#437), so it always runs with `/no_think` appended (see
/// [`score_node`]) to emit a bare integer cheaply — a thinking scorer burns
/// its budget restating the problem and lands no parseable integer at deeper
/// levels (observed: depth-2 scores all null → input-order pruning, and ~2×
/// slower). This is orthogonal to the node-generation `thinking` knob, which
/// stays on. The directive is inert on a non-reasoning model, and the score
/// output is demuxed regardless so a stray empty think block can't swallow
/// the integer.
const SCORE_PROMPT: &str = "Rate the assistant's latest answer from 1 to 10 on how well it \
     actually satisfies the user's original request. Judge task relevance, factual and semantic \
     correctness, specificity, and concrete usefulness. Use the full scale: 1-3 for irrelevant \
     or mostly off-task answers, 4-6 for partial/generic answers, 7-8 for useful answers with \
     gaps, and 9-10 for directly actionable answers. A fluent, polished, brief, or polite \
     answer that does not directly address what was asked is a LOW score (1-3); do not reward \
     style, brevity, or acknowledgment over substance. Avoid defaulting to 5: separate siblings \
     by task fit when one answer is more relevant or useful. Respond with only a single integer \
     from 1 to 10.";

/// Token budget for a scoring generation — enough for a suppressed empty
/// `<think></think>` plus the integer. The scorer is NOT demuxed (see
/// [`score_node`]), so this is the whole budget.
const SCORE_MAX_TOKENS: usize = 32;

/// Temperature for the final-answer synthesis (#523 Part A). Deliberately
/// LOW and fixed, independent of the candidate-generation temperature
/// (`TotParams.temperature`, which can run high for branch diversity) and
/// of the scorer (greedy `0.0`): synthesis must be a coherent, faithful
/// answer, so it never inherits the exploration entropy. The three roles —
/// generation (tunable, high) / scoring (greedy) / synthesis (low) — are
/// the temperature split; only generation is exposed on the wire, because
/// a tunable scorer or synthesis temperature would trade away deterministic
/// pruning and answer coherence for no benefit.
const SYNTHESIS_TEMPERATURE: f32 = 0.3;
const SYNTHESIS_TOP_P: f32 = 0.9;

/// Reasoning budget for the synthesis generation. Synthesis runs
/// `/no_think` (it produces the answer, not a thought trace), so this only
/// needs to absorb a suppressed empty `<think></think>` before the answer.
const SYNTHESIS_REASONING_TOKENS: usize = 32;

/// Reasoning budget for the bounded branch retry after a thinking attempt
/// starves before answer content. The retry appends `/no_think`, so this is
/// not a second full-thinking budget; it only allows a template that emits an
/// empty `<think></think>` prelude to close before the answer. If a model
/// ignores `/no_think` and keeps thinking, the retry is intentionally cut off
/// quickly and the node remains `Incomplete` rather than consuming another
/// production-sized reasoning budget.
const NO_THINK_RETRY_REASONING_TOKENS: usize = 32;

/// Append the `/no_think` directive when reasoning is disabled for this
/// search (`thinking:false`). On a Qwen3-style model this suppresses the
/// `<think>` block; on a non-reasoning model it is an inert token.
fn with_thinking(base: &str, thinking: bool) -> String {
    if thinking {
        base.to_string()
    } else {
        format!("{base} /no_think")
    }
}

/// Retry only the specific starvation mode #544 cares about: a thinking
/// branch produced reasoning but no answer. Normal answered branches keep
/// their useful reasoning; explicit `thinking:false` requests already use the
/// safe no-think policy; infrastructure aborts stay errors rather than being
/// disguised by a retry.
fn should_retry_reasoning_starved(thinking: bool, demux: &Demux) -> bool {
    thinking && matches!(demux.kind, DemuxKind::Incomplete)
}

/// Fold a bounded `/no_think` retry back into the node result. If the retry
/// answers, the node becomes `Ok` with the retry answer while preserving the
/// useful reasoning trace from the first attempt. If the retry also starves
/// (or aborts), its terminal kind stands, so the node remains non-selectable.
fn merge_no_think_retry(first: Demux, retry: Demux) -> Demux {
    let generated_tokens = first.generated_tokens + retry.generated_tokens;
    let mut reasoning = first.reasoning;
    let retry_reasoning = retry.reasoning.trim();
    if !retry_reasoning.is_empty() {
        if !reasoning.trim().is_empty() {
            reasoning.push_str("\n\nRetry reasoning:\n");
        }
        reasoning.push_str(retry_reasoning);
    }
    Demux {
        reasoning,
        answer: retry.answer,
        kind: retry.kind,
        generated_tokens,
    }
}

/// Stricter branch directive for the bounded no-think retry. It keeps the
/// same sibling path/focus as the original directive but adds explicit
/// recovery wording so a model that spent the first attempt inside `<think>`
/// gets a fresh, answer-first instruction.
fn retry_branch_directive(level: usize, branch_index: usize, breadth: usize) -> String {
    format!(
        "The previous attempt spent its budget in hidden reasoning without producing an answer. \
         Retry now with no hidden reasoning: produce the answer directly and concisely.\n\n{}",
        branch_directive(level, branch_index, breadth, false)
    )
}

fn retry_fork_failed(first: Demux, err: String) -> Demux {
    Demux {
        reasoning: first.reasoning,
        answer: String::new(),
        kind: DemuxKind::Aborted(format!("no-think retry fork failed: {err}")),
        generated_tokens: first.generated_tokens,
    }
}

type DemuxFuture<'a> = Pin<Box<dyn Future<Output = Demux> + 'a>>;

struct BranchGenerateRequest<'a> {
    directive: &'a str,
    reasoning_budget: usize,
    answer_budget: usize,
    sink_node_id: &'a str,
}

trait BranchDriver<C> {
    fn fork_retry_base(&mut self, ctx: &C) -> Result<C, String>;
    fn push_user(&mut self, ctx: &mut C, directive: &str);
    fn cue(&mut self, ctx: &mut C);
    fn generate<'a>(
        &'a mut self,
        ctx: &'a mut C,
        request: BranchGenerateRequest<'a>,
    ) -> DemuxFuture<'a>;
}

/// Build the synthesis user-turn (#523 Part A): the instruction appended to
/// a fork of the ORIGINAL conversation that turns the best search leaf into
/// the final answer. It embeds the chosen candidate (and its reasoning, when
/// present) and directs a thorough, faithful answer to the user's request —
/// not an echo of the candidate or a restatement of the strategy. Pure →
/// unit-tested. (`/no_think` + the low synthesis temperature are applied by
/// [`synthesize`].)
fn build_synthesis_directive(best_content: &str, best_reasoning: &str) -> String {
    let mut s = String::from(
        "An internal tree-of-thought search explored several strategies and selected the most \
         promising one. Its result:\n\n",
    );
    s.push_str(best_content.trim());
    let r = best_reasoning.trim();
    if !r.is_empty() {
        s.push_str("\n\nThe reasoning behind it:\n\n");
        s.push_str(r);
    }
    s.push_str(
        "\n\nUsing this as your foundation, write the final, complete answer to my original \
         request. Directly and fully address what I asked, be accurate and thorough, and resolve \
         any gaps. Do not merely echo the result above, name the strategy, or restate the \
         question — give the actual answer.",
    );
    s
}

/// A generated batch is visible answer content only when it lands entirely
/// outside a reasoning block (mirrors `chat::completions::content_visible`):
/// the reasoning decoder reported `Idle` for it AND we were not already
/// inside a `<think>` block before this batch — so the closing `</think>`
/// delimiter (which the chat decoder still surfaces as a Delta on the End
/// batch) stays off the answer channel.
fn content_visible(reason_idle: bool, was_in_reasoning: bool) -> bool {
    reason_idle && !was_in_reasoning
}

/// How [`generate_demuxed`] resolved one assistant-turn generation.
enum DemuxKind {
    /// A non-empty answer was produced (after any reasoning).
    Answered,
    /// Reasoning ran but no usable answer followed — truncated mid-thought
    /// (the reasoning budget elapsed before `</think>`) or an empty/closed
    /// think block with nothing after it (#434).
    Incomplete,
    /// The generator or a decoder failed mid-generation.
    Aborted(String),
}

/// One generation, demuxed into its reasoning trace and its answer.
struct Demux {
    reasoning: String,
    answer: String,
    kind: DemuxKind,
    /// All model-generated decode tokens consumed by this generation,
    /// including reasoning delimiters/hidden thinking and visible answer
    /// tokens. Prompt/input tokens are never counted here (#542).
    generated_tokens: usize,
}

/// Where [`generate_demuxed`]'s streamed deltas go. `Node` tags a tree
/// node id and streams both the reasoning and answer channels as
/// `node_delta` (#413). `Final` streams only the answer as `final_delta`
/// (#523 Part A) — the post-search synthesis surfaces an answer, not a
/// thought trace, so its reasoning channel is not emitted.
#[derive(Clone, Copy)]
enum DeltaSink<'a> {
    Node(&'a str),
    Final,
}

/// Generate one assistant turn with two-phase budgeting and `<think>` demux.
///
/// Phase 1 (reasoning) runs until the model closes its think block or
/// `reasoning_budget` tokens elapse; phase 2 (answer) then runs until the
/// chat template completes or `answer_budget` tokens elapse — so an
/// over-long thought can never starve the answer (#434), because the answer
/// always gets its own budget once reasoning has closed. Reasoning text is
/// collected from the reasoning decoder; the answer is the chat-decoder
/// content that falls outside any think block (#437 — the beam and scorer
/// see only this clean answer, never the thought trace). The caller owns
/// `cue`/forking/scoring; this only drives `generate`.
async fn generate_demuxed(
    ctx: &mut Context,
    model: &Model,
    sampler: Sampler,
    reasoning_budget: usize,
    answer_budget: usize,
    stops: &[u32],
    mut emitter: Option<&mut Emitter>,
    sink: DeltaSink<'_>,
) -> Demux {
    let mut reason_dec = reasoning::Decoder::new(model);
    let mut chat_dec = chat::Decoder::new(model);
    let mut generator = ctx
        .generate(sampler)
        .max_tokens(reasoning_budget + answer_budget)
        .stop(stops);

    let mut reasoning = String::new();
    let mut answer = String::new();
    let mut in_reasoning = false;
    let mut reasoning_done = false;
    let mut reasoning_tokens = 0usize;
    let mut answer_tokens = 0usize;
    let mut generated_tokens = 0usize;

    let kind = loop {
        let step = match generator.next() {
            Ok(None) => break DemuxKind::Answered, // max-tokens; reclassified by answer below
            Ok(Some(s)) => s,
            Err(e) => break DemuxKind::Aborted(format!("forward pass failed: {e}")),
        };
        let out = match step.execute().await {
            Ok(o) => o,
            Err(e) => break DemuxKind::Aborted(format!("forward pass failed: {e}")),
        };
        generated_tokens += out.tokens.len();

        // Capture the gate state BEFORE feeding the reasoning decoder: `feed`
        // flips `in_reasoning` as it consumes a boundary token, but the chat
        // decoder must be gated on this batch's channel, not the post-flip
        // state (the canonical chat-completions demux).
        let was_in_reasoning = in_reasoning;
        let mut reason_idle = false;
        match reason_dec.feed(&out.tokens) {
            Ok(reasoning::Event::Start) => in_reasoning = true,
            Ok(reasoning::Event::Delta(s)) => {
                in_reasoning = true;
                reasoning.push_str(&s);
                // #413 token stream: live-fill this node's reasoning channel.
                // The `Final` synthesis sink surfaces only the answer.
                if let (Some(em), DeltaSink::Node(id)) = (emitter.as_deref_mut(), sink) {
                    let _ = stream::emit_node_delta(em, id, stream::DELTA_REASONING, &s).await;
                }
            }
            Ok(reasoning::Event::End(_)) => {
                in_reasoning = false;
                reasoning_done = true;
            }
            Ok(reasoning::Event::Idle) => reason_idle = true,
            Err(e) => break DemuxKind::Aborted(format!("reasoning decode failed: {e}")),
        }
        match chat_dec.feed(&out.tokens) {
            Ok(chat::Event::Delta(s)) if content_visible(reason_idle, was_in_reasoning) => {
                answer.push_str(&s);
                // #413 token stream: live-fill the answer channel — a tree
                // node's `node_delta` or, for synthesis, `final_delta` (#523).
                if let Some(em) = emitter.as_deref_mut() {
                    let _ = match sink {
                        DeltaSink::Node(id) => {
                            stream::emit_node_delta(em, id, stream::DELTA_ANSWER, &s).await
                        }
                        DeltaSink::Final => stream::emit_final_delta(em, &s).await,
                    };
                }
            }
            Ok(chat::Event::Delta(_)) | Ok(chat::Event::Idle) => {}
            Ok(chat::Event::Done(_)) => break DemuxKind::Answered,
            Ok(chat::Event::Interrupt(_)) => {
                break DemuxKind::Aborted("chat template interrupt".to_string());
            }
            Err(e) => break DemuxKind::Aborted(format!("chat decode failed: {e}")),
        }

        // Phase accounting: a batch is answer-phase once reasoning has closed
        // (or the model never opened a think block and is already emitting
        // visible content). Reasoning that overruns its budget before closing
        // ends the node Incomplete — there is no answer phase to enter.
        let answering =
            reasoning_done || (!in_reasoning && !was_in_reasoning && !answer.is_empty());
        if answering {
            answer_tokens += out.tokens.len();
            if answer_tokens >= answer_budget {
                break DemuxKind::Answered;
            }
        } else {
            reasoning_tokens += out.tokens.len();
            if reasoning_tokens >= reasoning_budget && !reasoning_done {
                break DemuxKind::Incomplete;
            }
        }
    };

    // A clean stop (chat Done / max-tokens) that produced no answer text is
    // still Incomplete: an empty or closed-but-unanswered think block (#434).
    let kind = match kind {
        DemuxKind::Answered if answer.trim().is_empty() => DemuxKind::Incomplete,
        other => other,
    };
    Demux {
        reasoning,
        answer,
        kind,
        generated_tokens,
    }
}

/// Outcome of the value evaluator for one node. Distinguishes the three
/// classes the old bare `Option<u8>` collapsed together: a parsed score,
/// a benign unparseable result (the model emitted no in-range integer —
/// common for reasoning models), and an infra failure (the scoring fork
/// or generation itself failed). Only the last surfaces as a node
/// `score_error`, so an infra scorer collapse is no longer mistaken for a
/// benign null and the silent degradation to input-order pruning becomes
/// observable.
enum ScoreOutcome {
    Scored(u8),
    Unparseable,
    Failed(String),
}

/// Value-evaluator result plus the generated-token count spent producing it
/// (#542). A scorer infra failure can still have consumed tokens before the
/// failure; those tokens are part of total ToT work.
struct ScoreResult {
    outcome: ScoreOutcome,
    generated_tokens: usize,
}

impl ScoreOutcome {
    /// Split into a node's `(score, score_error)`. Pure → unit-tested.
    fn into_parts(self) -> (Option<u8>, Option<String>) {
        match self {
            ScoreOutcome::Scored(v) => (Some(v), None),
            ScoreOutcome::Unparseable => (None, None),
            ScoreOutcome::Failed(msg) => (None, Some(msg)),
        }
    }
}

/// Context-free result of expanding one forked branch — everything
/// [`materialize_level`] needs to build a [`Node`], with no engine handle.
/// [`expand`] returns this paired with the moved-back [`Context`] so a
/// surviving node can be expanded at the next level.
#[derive(Clone, Debug)]
struct NodeOutcome {
    status: NodeStatus,
    /// The clean answer (empty for `Error`/`Incomplete`).
    content: String,
    /// The demuxed `<think>` trace (present for a thinking `Ok` node and for
    /// an `Incomplete` node that thought but never answered).
    reasoning: String,
    score: Option<u8>,
    score_error: Option<String>,
    /// Per-node diagnostic for a non-`Ok` node (`None` for `Ok`).
    error: Option<String>,
    /// Total generated tokens spent for this branch: node generation plus
    /// scorer generation when the node answered. Input/prompt tokens excluded.
    generated_tokens: usize,
}

/// One forked branch ready to materialize: its caller-assigned id + tree
/// position + Context-free outcome.
struct Branch {
    id: String,
    parent_id: String,
    branch_index: usize,
    outcome: NodeOutcome,
}

/// Pure materialization of one search level: the tree nodes to append,
/// the scored candidates, and the beam (surviving node ids).
struct LevelMaterialized {
    nodes: Vec<Node>,
    candidates: Vec<Candidate>,
    keep: Vec<String>,
    generated_tokens: usize,
}

/// A live frontier entry: a context ready to expand + its tree-node id.
struct Frontier {
    ctx: Context,
    node_id: String,
}

pub struct SearchOutcome {
    pub root: Node,
    pub selected_node_id: Option<String>,
    pub final_answer: Option<String>,
    /// `true` when the post-search synthesis produced `final_answer`; `false`
    /// when the raw best-leaf content finalize() set stood (synthesis was
    /// skipped or failed) — the fail-safe path. Carried onto the wire
    /// (`tree_complete.synthesized` / `TreeResponse.synthesized`) so a
    /// silently dead synthesizer is observable rather than masked by an
    /// always-renderable best-leaf answer (#523 Part A F1).
    pub synthesized: bool,
    /// Total model-generated decode tokens spent by the whole successful or
    /// failed search (node reasoning/answers, scorer generations, synthesis
    /// attempt if any), excluding prompt/input tokens (#542).
    pub total_generated_tokens: usize,
}

/// Run the beam search. `root_ctx` must already be filled (system +
/// messages) **and flushed, but NOT cued** — the assistant turn is
/// opened per branch in [`expand`]. A cue committed into the shared
/// prefix would be duplicated across every fork and waste the zero-token
/// forward pass that the level-1 spin fix removed.
///
/// When `emitter` is `Some`, the search streams (#413): each node emits a
/// `node_start`, then its reasoning + answer stream live as `node_delta`
/// chunks while it generates ([`generate_demuxed`]), then the level's nodes
/// are emitted as `node_complete` frames (full node + score) followed by the
/// `level_pruned` beam selection — the single source of search orchestration
/// drives both the non-streaming response and the streamed one, so they can
/// never diverge (the non-stream path simply passes `None` and emits no
/// deltas, ending at a byte-identical tree). Emit errors are deliberately
/// swallowed: a peer disconnect (the common case) just means no one is
/// listening, and the bounded search (≤ `MAX_NODES`) finishes either way; the
/// returned [`SearchOutcome`] is identical regardless of whether anyone
/// received the frames.
pub async fn run(
    root_ctx: Context,
    params: &TotParams,
    model: &Model,
    mut emitter: Option<&mut Emitter>,
) -> SearchOutcome {
    // #523 Part A: preserve a fork of the original conversation (system +
    // user turns, flushed, cue-free) BEFORE the search consumes `root_ctx`.
    // The final-answer synthesis grounds on this, so it works regardless of
    // which level the best leaf came from (the leaf's own context may have
    // been dropped by an earlier-level F7 fallback). `None` if the fork
    // fails → synthesis is skipped and the best-leaf content stands.
    let synth_base: Option<Context> = root_ctx.fork().ok();

    let mut flat: Vec<Node> = vec![Node::root()];
    let mut frontier: Vec<Frontier> = vec![Frontier {
        ctx: root_ctx,
        node_id: "root".to_string(),
    }];
    // Candidates at the deepest level that produced a surviving leaf — the
    // pool the final answer is chosen from. Carried across levels by
    // `fold_level` so a late all-fail level can't null an answer that
    // earlier levels legitimately produced (F7).
    let mut last_level: Vec<Candidate> = Vec::new();
    let mut total_generated_tokens = 0usize;

    for level in 1..=params.depth {
        // Index into `flat` of this level's first node. Every node appended
        // below — refine-flush error leaves, fork error leaves, and the
        // materialized candidates — lands in `flat[level_start..]`, the
        // exact slice the streaming sink replays as `node_complete` frames.
        let level_start = flat.len();

        // Per-branch diversity (#523): the refinement instruction is no
        // longer flushed once into the shared parent prefix (which made
        // every sibling identical). Instead each forked child appends its
        // OWN `branch_directive` in `generate_branch` — distinct per branch
        // index, steering each sibling to a different strategy — so the
        // parent prefix stays shared (KV-cache reuse) while the siblings
        // diverge. At levels > 1 the directive carries the critique-then-
        // refine framing the shared flush used to provide.

        // Fork every child. A fork failure has no context to carry → record
        // it as an inline error leaf (shared with the refine-flush path); a
        // successful fork's context is expanded (generate + score)
        // concurrently below.
        let mut metas: Vec<(String, String, usize)> = Vec::new(); // (id, parent_id, branch_index)
        let mut ctxs: Vec<Context> = Vec::new();
        for f in frontier.iter() {
            for b in 0..params.breadth {
                match f.ctx.fork() {
                    Ok(child) => {
                        metas.push((new_node_id(), f.node_id.clone(), b));
                        ctxs.push(child);
                    }
                    Err(e) => flat.push(error_leaf(
                        &f.node_id,
                        level,
                        b,
                        format!("fork failed: {e}"),
                    )),
                }
            }
        }

        // Generate + score this level's branches per the execution strategy
        // (#458). Default is coupled-sequential (one node at a time); the
        // concurrent / phased variants are the measurement apparatus (no
        // measured win — see the module docs). Generation is always
        // sequential when an emitter is present (#413 streaming). `results` is
        // in `metas` order regardless (join_all and the sequential loop both
        // preserve it), so the tree shape is identical across strategies.
        let results: Vec<(Context, NodeOutcome)> =
            resolve_level(&metas, ctxs, params, model, emitter.as_deref_mut(), level).await;

        // Pair each expansion with its meta: keep the moved-back context as
        // a potential survivor, and hand the Context-free outcome to the
        // pure materializer.
        let mut survivors: Vec<Frontier> = Vec::with_capacity(metas.len());
        let mut branches: Vec<Branch> = Vec::with_capacity(metas.len());
        for ((id, parent_id, branch_index), (ctx, outcome)) in metas.into_iter().zip(results) {
            survivors.push(Frontier {
                ctx,
                node_id: id.clone(),
            });
            branches.push(Branch {
                id,
                parent_id,
                branch_index,
                outcome,
            });
        }

        let LevelMaterialized {
            nodes,
            candidates,
            keep,
            generated_tokens,
        } = materialize_level(level, branches, params.beam_width);
        total_generated_tokens += generated_tokens;
        flat.extend(nodes);

        // Carry only the beam survivors (ok-only) as the next frontier; a
        // failed branch never survives to be re-expanded, and its
        // partially-advanced context is dropped here.
        frontier = survivors
            .into_iter()
            .filter(|f| keep.contains(&f.node_id))
            .collect();

        // F7: update the final-answer pool only when this level survived,
        // and stop early on an empty frontier — there is nothing left to
        // expand, and overwriting with the empty/all-error level would
        // null an answer earlier levels produced.
        let (pool, stop) = fold_level(last_level, candidates, &keep);
        last_level = pool;

        // #413: stream this level (all of its nodes, then the beam) once
        // it is fully resolved. Emitted before the `stop` break so a
        // search-ending final level still streams its nodes + empty beam.
        if let Some(em) = emitter.as_deref_mut() {
            let _ = stream::emit_level(em, level, &flat[level_start..], &keep).await;
        }

        if stop {
            break;
        }
    }

    // #523 Part A: capture the best leaf's answer + reasoning (before
    // `finalize` consumes `flat`), assemble the outcome, then run ONE
    // grounded synthesis as the final answer. `best` is `Some` exactly when
    // an ok leaf exists (so honest-null is preserved: no leaf → no synthesis,
    // `final_answer` stays null). Synthesis streams as `final_delta`; on any
    // failure it returns `None` and the raw best-leaf content stands.
    let best = best_leaf(&last_level)
        .and_then(|id| flat.iter().find(|n| n.id == id))
        .map(|n| (n.content.clone(), n.reasoning.clone()));
    let mut outcome = finalize(flat, &last_level);
    // Attempt synthesis only when an ok leaf exists AND its grounding fork
    // survived; on any skip/failure emit a one-shot host diagnostic with the
    // reason so a dead synthesizer is visible in production (#523 Part A F1),
    // then fall through with `None` so the raw best-leaf content stands.
    let synth: Option<String> = match (best, synth_base) {
        (Some((content, reasoning)), Some(base)) => match synthesize(
            base,
            model,
            &content,
            &reasoning,
            params.max_tokens_per_node,
            emitter,
        )
        .await
        {
            Ok((answer, generated_tokens)) => {
                total_generated_tokens += generated_tokens;
                Some(answer)
            }
            Err((reason, generated_tokens)) => {
                total_generated_tokens += generated_tokens;
                eprintln!("[chat-apc] tot synthesis fell back to best leaf: {reason}");
                None
            }
        },
        (Some(_), None) => {
            eprintln!("[chat-apc] tot synthesis skipped: fork_failed");
            None
        }
        // No ok leaf → honest-null: no synthesis is attempted and
        // finalize()'s null `final_answer` stands (no diagnostic — a total
        // failure is already surfaced by the `error` terminal).
        (None, _) => None,
    };
    reconcile_synthesis(&mut outcome, synth);
    outcome.total_generated_tokens = total_generated_tokens;
    outcome
}

/// Fold the post-search synthesis result into the finalized outcome. Pure →
/// unit-tested, since [`run`]'s engine-bound [`synthesize`] cannot run
/// natively. A produced answer replaces `final_answer` and marks
/// `synthesized`; `None` (synthesis skipped or failed) leaves both untouched,
/// so the raw best-leaf answer finalize() set is preserved and never nulled —
/// the load-bearing fail-safe + honest-null invariant (#523 Part A F1/F3).
fn reconcile_synthesis(outcome: &mut SearchOutcome, synth: Option<String>) {
    if let Some(answer) = synth {
        outcome.final_answer = Some(answer);
        outcome.synthesized = true;
    }
}

/// Materialize one level's **successfully forked** branches into tree
/// nodes + scored candidates + the beam, with no engine context so it is
/// unit-tested natively. Fork and refine-flush failures never reach here —
/// [`run`] records those as [`error_leaf`] nodes directly, since they have
/// no content to score or context to expand. A successful branch becomes
/// an `ok`/`error` leaf; an `ok` leaf may still carry a `score_error` when
/// the scorer infra failed (F4). Pruning reuses [`select_beam_diverse`],
/// which keeps the top `beam_width` **ok** candidates by score but demotes
/// a paraphrase of an already-kept sibling so a distinct branch takes the
/// slot (#523). Node ids are
/// caller-assigned (paired with the engine contexts), so the returned
/// `keep` ids map straight back to surviving [`Frontier`] entries.
fn materialize_level(level: usize, branches: Vec<Branch>, beam_width: usize) -> LevelMaterialized {
    let mut nodes: Vec<Node> = Vec::with_capacity(branches.len());
    let mut candidates: Vec<Candidate> = Vec::with_capacity(branches.len());
    let mut generated_tokens = 0usize;
    for b in branches {
        generated_tokens += b.outcome.generated_tokens;
        // Only an `Ok` node (a non-empty answer) is beam-eligible; both
        // `Error` (generation failed) and `Incomplete` (reasoned but never
        // answered) are excluded from survival and final-answer selection,
        // so the beam never keeps a node that has no answer — and a
        // think-only candidate can no longer win the search (#437).
        let is_ok = b.outcome.status == NodeStatus::Ok;
        // Diversity dedup compares only ok candidates' answers (non-ok are
        // filtered out in `select_beam_diverse`), so the candidate carries
        // the clean answer; an Error/Incomplete node has empty content.
        candidates.push(Candidate {
            id: b.id.clone(),
            score: b.outcome.score,
            ok: is_ok,
            content: b.outcome.content.clone(),
        });
        nodes.push(Node {
            id: b.id,
            parent_id: Some(b.parent_id),
            depth: level,
            branch_index: Some(b.branch_index),
            content: b.outcome.content,
            reasoning: b.outcome.reasoning,
            score: b.outcome.score,
            status: b.outcome.status,
            error: b.outcome.error,
            score_error: b.outcome.score_error,
            children: Vec::new(),
        });
    }

    let keep = select_beam_diverse(&candidates, beam_width, super::diversity::DUP_THRESHOLD);
    LevelMaterialized {
        nodes,
        candidates,
        keep,
        generated_tokens,
    }
}

/// F7: carry the deepest level that produced a surviving (beam-kept)
/// candidate as the final-answer pool. When a level yields no survivor —
/// every fork failed, or every generation errored, so `keep` is empty —
/// retain the *previous* pool and signal `stop`: there is nothing to
/// expand next level, and overwriting with the empty/all-error level
/// would null a `final_answer` that earlier levels legitimately produced.
/// Pure → unit-tested.
fn fold_level(
    prev: Vec<Candidate>,
    this: Vec<Candidate>,
    keep: &[String],
) -> (Vec<Candidate>, bool) {
    if keep.is_empty() {
        (prev, true) // no survivor → retain prior pool, stop the search
    } else {
        (this, false) // this level advances → it is the new deepest pool
    }
}

/// Assemble the final [`SearchOutcome`] from the flat node list and the
/// deepest surviving level's candidates. The best **ok** leaf (errors
/// excluded, `None` scores last, stable on ties) is the selected node +
/// final answer; both honestly null out when no ok leaf exists. Pure →
/// unit-tested.
fn finalize(flat: Vec<Node>, last_level: &[Candidate]) -> SearchOutcome {
    let best = best_leaf(last_level);
    let final_answer = best
        .as_ref()
        .and_then(|id| flat.iter().find(|n| &n.id == id).map(|n| n.content.clone()));
    let root = assemble(&flat, "root");
    SearchOutcome {
        root,
        selected_node_id: best,
        final_answer,
        // finalize() sets the raw best-leaf answer; `run` flips this true only
        // when the post-search synthesis replaces it (#523 Part A F1).
        synthesized: false,
        // Filled by `run`, which owns the engine-bound token accounting.
        total_generated_tokens: 0,
    }
}

/// Generate + score one level's branches per the [`ExecStrategy`](super::schema::ExecStrategy),
/// returning `(Context, NodeOutcome)` in `metas` order so the moved-back
/// contexts pair straight back to surviving [`Frontier`] entries and the
/// tree shape is identical across strategies.
///
/// Two axes (see the module docs): generation concurrent (batched by the
/// engine scheduler via `join_all`) vs sequential, and scoring phased (a
/// barrier, then all `Answered` nodes scored in one concurrent batch) vs
/// coupled (each branch generates then scores in one future). Generation is
/// forced sequential whenever an [`Emitter`] is present — the single SSE
/// writer can't be shared across concurrent branch futures (#413). Scoring
/// never touches the emitter, so it is always concurrent (batched), even on
/// the streaming path.
async fn resolve_level(
    metas: &[(String, String, usize)],
    ctxs: Vec<Context>,
    params: &TotParams,
    model: &Model,
    mut emitter: Option<&mut Emitter>,
    level: usize,
) -> Vec<(Context, NodeOutcome)> {
    // Streaming forces sequential generation regardless of `exec`.
    let concurrent_gen = params.exec.concurrent_gen() && emitter.is_none();

    if params.exec.phased_score() {
        // Phase 1 — generate every branch (no scoring yet).
        let gens: Vec<(Context, Demux)> = if concurrent_gen {
            // Non-stream only (emitter is None here): all siblings decode in
            // flight at once, so the scheduler batches their forward passes.
            join_all(
                ctxs.into_iter()
                    .zip(metas.iter())
                    .map(|(c, m)| generate_branch(c, model, params, None, &m.0, level, m.2)),
            )
            .await
        } else {
            let mut out = Vec::with_capacity(ctxs.len());
            for (c, m) in ctxs.into_iter().zip(metas.iter()) {
                if let Some(em) = emitter.as_deref_mut() {
                    let _ = stream::emit_node_start(em, &m.0, &m.1, level, m.2).await;
                }
                out.push(
                    generate_branch(c, model, params, emitter.as_deref_mut(), &m.0, level, m.2)
                        .await,
                );
            }
            out
        };

        // Phase 2 — score every `Answered` branch in one concurrent batch
        // (#458): the short greedy scoring generations decode in flight at
        // once so the engine coalesces them, instead of one score forward
        // pass at a time. `Incomplete`/`Error` nodes have no answer to rate.
        let scores: Vec<Option<ScoreResult>> =
            join_all(gens.iter().map(|(ctx, demux)| async move {
                if matches!(demux.kind, DemuxKind::Answered) {
                    Some(score_node(ctx, model).await)
                } else {
                    None
                }
            }))
            .await;

        gens.into_iter()
            .zip(scores)
            .map(|((ctx, demux), score)| (ctx, classify(demux, score)))
            .collect()
    } else {
        // Coupled — each branch generates then scores in one future, so a
        // branch's score overlaps the next branch's generation under
        // concurrency (the pre-#458 shape; benchmark baseline / overlap
        // variant).
        if concurrent_gen {
            join_all(
                ctxs.into_iter()
                    .zip(metas.iter())
                    .map(|(c, m)| expand(c, model, params, None, &m.0, level, m.2)),
            )
            .await
        } else {
            let mut out = Vec::with_capacity(ctxs.len());
            for (c, m) in ctxs.into_iter().zip(metas.iter()) {
                if let Some(em) = emitter.as_deref_mut() {
                    let _ = stream::emit_node_start(em, &m.0, &m.1, level, m.2).await;
                }
                out.push(expand(c, model, params, emitter.as_deref_mut(), &m.0, level, m.2).await);
            }
            out
        }
    }
}

/// Generate one forked branch's assistant turn — cue, then a demuxed
/// reasoning+answer generation ([`generate_demuxed`]). No scoring. The
/// context is moved back out paired with its [`Demux`] so a phased scorer
/// (or [`expand`]) can use it and a survivor can expand at the next level.
/// Streams this node's reasoning/answer chunks as `node_delta` frames when
/// an emitter is present (#413 token stream); `None` on the non-stream /
/// concurrent path.
async fn generate_branch_with<C, Driver>(
    mut ctx: C,
    params: &TotParams,
    node_id: &str,
    level: usize,
    branch_index: usize,
    driver: &mut Driver,
) -> (C, Demux)
where
    Driver: BranchDriver<C>,
{
    let retry_base = if params.thinking {
        Some(driver.fork_retry_base(&ctx))
    } else {
        None
    };

    // Append this branch's per-branch directive (#523), then open the
    // assistant turn. The forked context shares a fully-flushed, cue-free
    // prefix; the directive steers this sibling toward a distinct strategy
    // (its text also makes the first forward pass carry real new tokens
    // rather than spin).
    let first_directive = branch_directive(level, branch_index, params.breadth, params.thinking);
    driver.push_user(&mut ctx, &first_directive);
    driver.cue(&mut ctx);
    let demux = driver
        .generate(
            &mut ctx,
            BranchGenerateRequest {
                directive: &first_directive,
                reasoning_budget: params.max_reasoning_tokens,
                answer_budget: params.max_tokens_per_node,
                sink_node_id: node_id,
            },
        )
        .await;

    if should_retry_reasoning_starved(params.thinking, &demux) {
        match retry_base {
            Some(Ok(mut retry_ctx)) => {
                let retry_directive = retry_branch_directive(level, branch_index, params.breadth);
                driver.push_user(&mut retry_ctx, &retry_directive);
                driver.cue(&mut retry_ctx);
                let retry = driver
                    .generate(
                        &mut retry_ctx,
                        BranchGenerateRequest {
                            directive: &retry_directive,
                            reasoning_budget: NO_THINK_RETRY_REASONING_TOKENS,
                            answer_budget: params.max_tokens_per_node,
                            sink_node_id: node_id,
                        },
                    )
                    .await;
                return (retry_ctx, merge_no_think_retry(demux, retry));
            }
            Some(Err(e)) => return (ctx, retry_fork_failed(demux, e)),
            None => {}
        }
    }

    (ctx, demux)
}

async fn generate_branch(
    ctx: Context,
    model: &Model,
    params: &TotParams,
    emitter: Option<&mut Emitter>,
    node_id: &str,
    level: usize,
    branch_index: usize,
) -> (Context, Demux) {
    struct InferletBranchDriver<'a, 'e> {
        model: &'a Model,
        stops: Vec<u32>,
        emitter: Option<&'e mut Emitter>,
        temperature: f32,
        top_p: f32,
    }

    impl BranchDriver<Context> for InferletBranchDriver<'_, '_> {
        fn fork_retry_base(&mut self, ctx: &Context) -> Result<Context, String> {
            ctx.fork().map_err(|e| e.to_string())
        }

        fn push_user(&mut self, ctx: &mut Context, directive: &str) {
            ctx.user(directive);
        }

        fn cue(&mut self, ctx: &mut Context) {
            ctx.cue();
        }

        fn generate<'a>(
            &'a mut self,
            ctx: &'a mut Context,
            request: BranchGenerateRequest<'a>,
        ) -> DemuxFuture<'a> {
            let _directive = request.directive;
            let sampler = Sampler::TopP {
                temperature: self.temperature,
                p: self.top_p,
            };
            let model = self.model;
            let stops = &self.stops;
            let emitter = self.emitter.as_deref_mut();
            Box::pin(async move {
                generate_demuxed(
                    ctx,
                    model,
                    sampler,
                    request.reasoning_budget,
                    request.answer_budget,
                    stops,
                    emitter,
                    DeltaSink::Node(request.sink_node_id),
                )
                .await
            })
        }
    }

    let mut driver = InferletBranchDriver {
        model,
        stops: chat::stop_tokens(model),
        emitter,
        temperature: params.temperature,
        top_p: params.top_p,
    };
    generate_branch_with(ctx, params, node_id, level, branch_index, &mut driver).await
}

/// Turn a branch's [`Demux`] (+ its scorer outcome, when it answered) into a
/// [`NodeOutcome`]. Classification: `Answered` → `Ok` (carries the scorer's
/// `score`/`score_error`); `Incomplete` → kept out of the beam with its
/// partial reasoning preserved (#434); `Aborted` → `Error`. Only an
/// `Answered` node is scored — a node with no answer has nothing to rate, so
/// its `score` is `None`. Pure → unit-tested.
fn classify(demux: Demux, score: Option<ScoreResult>) -> NodeOutcome {
    match demux.kind {
        DemuxKind::Answered => {
            // An `Answered` node is always scored (phased: scored in phase 2;
            // coupled: scored in `expand`). A `None` here would be a caller
            // bug, not a benign unscored node — default it to an infra
            // failure rather than silently dropping the score.
            let node_generated_tokens = demux.generated_tokens;
            let score = score.unwrap_or(ScoreResult {
                outcome: ScoreOutcome::Failed("internal: answered node was not scored".to_string()),
                generated_tokens: 0,
            });
            let generated_tokens = node_generated_tokens + score.generated_tokens;
            let (score, score_error) = score.outcome.into_parts();
            NodeOutcome {
                status: NodeStatus::Ok,
                content: demux.answer,
                reasoning: demux.reasoning,
                score,
                score_error,
                error: None,
                generated_tokens,
            }
        }
        DemuxKind::Incomplete => NodeOutcome {
            status: NodeStatus::Incomplete,
            content: String::new(),
            reasoning: demux.reasoning,
            score: None,
            score_error: None,
            error: Some(
                "no answer: the node ran out of reasoning budget before producing one".to_string(),
            ),
            generated_tokens: demux.generated_tokens,
        },
        DemuxKind::Aborted(e) => NodeOutcome {
            status: NodeStatus::Error,
            content: String::new(),
            reasoning: demux.reasoning,
            score: None,
            score_error: None,
            error: Some(e),
            generated_tokens: demux.generated_tokens,
        },
    }
}

/// Generate then value-score one forked context in a single future (coupled
/// scoring). The context is moved back out paired with a Context-free
/// [`NodeOutcome`]. Only an `Answered` node is scored.
async fn expand(
    ctx: Context,
    model: &Model,
    params: &TotParams,
    emitter: Option<&mut Emitter>,
    node_id: &str,
    level: usize,
    branch_index: usize,
) -> (Context, NodeOutcome) {
    let (ctx, demux) =
        generate_branch(ctx, model, params, emitter, node_id, level, branch_index).await;
    let score = if matches!(demux.kind, DemuxKind::Answered) {
        Some(score_node(&ctx, model).await)
    } else {
        None
    };
    (ctx, classify(demux, score))
}

/// Value evaluator: fork the answered context, ask for a 1–10 rating, and
/// parse the first in-range integer. The node already did its reasoning, so
/// the scorer is a cheap value HEAD — it always runs `/no_think` (NOT the
/// node `thinking` knob) to emit a bare integer rather than re-reasoning the
/// problem; a thinking scorer burns its budget restating the question and
/// lands no parseable integer at deeper levels (→ unscored, input-order
/// pruning, ~2× slower). Unlike node generation this does NOT demux: it reads
/// the raw text and lets [`parse_score`] find the integer anywhere in it
/// (skipping the empty `<think></think>` `/no_think` leaves), which is
/// robust to the integer landing in the same token batch as `</think>` — a
/// case the content-channel gate would drop. The three outcomes stay distinct
/// so an infra failure (fork/generate) is not mistaken for a benign
/// unparseable score — see [`ScoreOutcome`].
async fn score_node(ctx: &Context, model: &Model) -> ScoreResult {
    let mut sctx = match ctx.fork() {
        Ok(c) => c,
        Err(e) => {
            return ScoreResult {
                outcome: ScoreOutcome::Failed(format!("score fork failed: {e}")),
                generated_tokens: 0,
            };
        }
    };
    sctx.user(&with_thinking(SCORE_PROMPT, false));
    sctx.cue();
    let stops = chat::stop_tokens(model);
    let mut generator = sctx
        .generate(Sampler::TopP {
            temperature: 0.0,
            p: 1.0,
        }) // greedy
        .max_tokens(SCORE_MAX_TOKENS)
        .stop(&stops);
    let mut decoder = chat::Decoder::new(model);
    let mut text = String::new();
    let mut generated_tokens = 0usize;
    loop {
        let step = match generator.next() {
            Ok(Some(step)) => step,
            Ok(None) => break,
            Err(e) => {
                return ScoreResult {
                    outcome: ScoreOutcome::Failed(format!("score generate failed: {e}")),
                    generated_tokens,
                };
            }
        };
        let out = match step.execute().await {
            Ok(out) => out,
            Err(e) => {
                return ScoreResult {
                    outcome: ScoreOutcome::Failed(format!("score generate failed: {e}")),
                    generated_tokens,
                };
            }
        };
        generated_tokens += out.tokens.len();
        match decoder.feed(&out.tokens) {
            Ok(chat::Event::Delta(s)) => text.push_str(&s),
            Ok(chat::Event::Done(s)) => {
                text = s;
                break;
            }
            Ok(chat::Event::Idle) | Ok(chat::Event::Interrupt(_)) => {}
            Err(e) => {
                return ScoreResult {
                    outcome: ScoreOutcome::Failed(format!("score decode failed: {e}")),
                    generated_tokens,
                };
            }
        }
    }
    let outcome = match parse_score(&text) {
        Some(v) => ScoreOutcome::Scored(v),
        None => ScoreOutcome::Unparseable,
    };
    ScoreResult {
        outcome,
        generated_tokens,
    }
}

/// Final-answer synthesis (#523 Part A). Forks-free: `base` is already a
/// fork of the ORIGINAL conversation (system + user turns), preserved
/// before the search consumed the root. Appends [`build_synthesis_directive`]
/// (+ `/no_think`) and runs ONE low-temperature, demuxed generation grounded
/// in the best leaf, streaming its answer as `final_delta` when an emitter is
/// present. Returns the synthesized answer plus generated-token count, or
/// `Err(reason, generated_tokens)` on any failure / empty result — the reason
/// (`not_answered` / `empty` / `aborted: …`) is surfaced by the caller as a
/// host diagnostic before it falls back to the raw best-leaf content, so a
/// failed synthesis is never lost silently (#523 F1).
/// Search, scoring, and beam selection are untouched — this runs only after a
/// best ok leaf is chosen.
async fn synthesize(
    mut base: Context,
    model: &Model,
    best_content: &str,
    best_reasoning: &str,
    answer_budget: usize,
    emitter: Option<&mut Emitter>,
) -> Result<(String, usize), (String, usize)> {
    let directive = with_thinking(
        &build_synthesis_directive(best_content, best_reasoning),
        false,
    );
    base.user(&directive);
    base.cue();
    let stops = chat::stop_tokens(model);
    let demux = generate_demuxed(
        &mut base,
        model,
        Sampler::TopP {
            temperature: SYNTHESIS_TEMPERATURE,
            p: SYNTHESIS_TOP_P,
        },
        SYNTHESIS_REASONING_TOKENS,
        answer_budget,
        &stops,
        emitter,
        DeltaSink::Final,
    )
    .await;
    let generated_tokens = demux.generated_tokens;
    match demux.kind {
        DemuxKind::Answered if !demux.answer.trim().is_empty() => {
            Ok((demux.answer, generated_tokens))
        }
        DemuxKind::Answered => Err(("empty".to_string(), generated_tokens)),
        DemuxKind::Incomplete => Err(("not_answered".to_string(), generated_tokens)),
        DemuxKind::Aborted(e) => Err((format!("aborted: {e}"), generated_tokens)),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn ok_outcome(content: &str, score: Option<u8>) -> NodeOutcome {
        NodeOutcome {
            status: NodeStatus::Ok,
            content: content.to_string(),
            reasoning: String::new(),
            score,
            score_error: None,
            error: None,
            generated_tokens: 0,
        }
    }

    fn ok_outcome_score_failed(content: &str, err: &str) -> NodeOutcome {
        NodeOutcome {
            status: NodeStatus::Ok,
            content: content.to_string(),
            reasoning: String::new(),
            score: None,
            score_error: Some(err.to_string()),
            error: None,
            generated_tokens: 0,
        }
    }

    fn err_outcome(msg: &str) -> NodeOutcome {
        NodeOutcome {
            status: NodeStatus::Error,
            content: String::new(),
            reasoning: String::new(),
            score: None,
            score_error: None,
            error: Some(msg.to_string()),
            generated_tokens: 0,
        }
    }

    fn incomplete_outcome(reasoning: &str) -> NodeOutcome {
        NodeOutcome {
            status: NodeStatus::Incomplete,
            content: String::new(),
            reasoning: reasoning.to_string(),
            score: None,
            score_error: None,
            error: Some("no answer".to_string()),
            generated_tokens: 0,
        }
    }

    fn branch(id: &str, parent: &str, b: usize, outcome: NodeOutcome) -> Branch {
        Branch {
            id: id.to_string(),
            parent_id: parent.to_string(),
            branch_index: b,
            outcome,
        }
    }

    fn cand(id: &str, score: Option<u8>, ok: bool) -> Candidate {
        Candidate {
            id: id.to_string(),
            score,
            ok,
            content: String::new(),
        }
    }

    // ── branch_directive (#523 A): per-branch diversity ──

    #[test]
    fn branch_directives_are_distinct_across_siblings() {
        // The core diversity guarantee: no two siblings get the same prompt,
        // so the old identical-prefix collapse is impossible by construction.
        let breadth = 5;
        let ds: Vec<String> = (0..breadth)
            .map(|b| branch_directive(1, b, breadth, true))
            .collect();
        for i in 0..breadth {
            for j in (i + 1)..breadth {
                assert_ne!(ds[i], ds[j], "siblings {i} and {j} share a directive");
            }
        }
    }

    #[test]
    fn branch_directive_level1_proposes_a_named_strategy() {
        let d = branch_directive(1, 0, 3, true);
        assert!(d.contains("path 1 of 3"));
        assert!(d.to_lowercase().contains("strategy"));
        // Level 1 proposes fresh; it does not ask to critique a prior answer.
        assert!(!d.to_lowercase().contains("critique"));
    }

    #[test]
    fn branch_directive_deeper_levels_critique_then_refine() {
        let d = branch_directive(2, 1, 3, true);
        assert!(d.contains("path 2 of 3"));
        assert!(d.to_lowercase().contains("critique"));
    }

    #[test]
    fn branch_directive_honors_thinking_knob() {
        // thinking:false suppresses per-node reasoning via the /no_think
        // marker (reused from `with_thinking`); thinking:true keeps it.
        assert!(branch_directive(1, 0, 3, false).contains("/no_think"));
        assert!(!branch_directive(1, 0, 3, true).contains("/no_think"));
    }

    // ── SCORE_PROMPT (#523 B): rubric weights task relevance over style ──

    #[test]
    fn score_prompt_rubric_weights_substance_not_fluency() {
        let p = SCORE_PROMPT.to_lowercase();
        assert!(p.contains("satisf"));
        assert!(p.contains("relevance"));
        assert!(p.contains("correct"));
        assert!(p.contains("specific"));
        // …and explicitly does NOT reward style/brevity/acknowledgment.
        assert!(p.contains("low score"));
        assert!(p.contains("do not reward"));
        assert!(p.contains("1-3"));
        assert!(p.contains("4-6"));
        assert!(p.contains("7-8"));
        assert!(p.contains("9-10"));
        assert!(p.contains("avoid defaulting to 5"));
        assert!(p.contains("single integer"));
    }

    // ── build_synthesis_directive (#523 Part A): final-answer assembly seam ──

    #[test]
    fn synthesis_directive_embeds_best_content_and_directs_a_full_answer() {
        let d = build_synthesis_directive("Book a private venue that fits 20 guests.", "");
        // The chosen candidate is embedded as the grounding…
        assert!(d.contains("Book a private venue that fits 20 guests."));
        // …and the instruction directs the final answer, not an echo.
        let lo = d.to_lowercase();
        assert!(lo.contains("final"));
        assert!(lo.contains("answer to my original request"));
        assert!(lo.contains("do not merely echo"));
        // No reasoning section when reasoning is empty.
        assert!(!d.contains("reasoning behind it"));
    }

    #[test]
    fn synthesis_directive_includes_reasoning_when_present() {
        let d =
            build_synthesis_directive("Answer X.", "First consider the budget, then the venue.");
        assert!(d.contains("The reasoning behind it:"));
        assert!(d.contains("First consider the budget, then the venue."));
    }

    #[test]
    fn synthesis_directive_trims_whitespace_only_reasoning() {
        // Whitespace-only reasoning must not open an empty reasoning section.
        let d = build_synthesis_directive("Answer.", "   \n  ");
        assert!(!d.contains("reasoning behind it"));
    }

    // ── Temperature split (#523 Part B): three roles, three temperatures ──

    #[test]
    fn synthesis_temperature_is_low_and_distinct_from_generation_default() {
        // Synthesis stays coherent (low) regardless of how high candidate
        // generation runs; the scorer is greedy (0.0) — see `score_node`.
        let (synth, gen_default) = (
            SYNTHESIS_TEMPERATURE,
            super::super::schema::DEFAULT_TEMPERATURE,
        );
        assert!(
            synth > 0.0,
            "synthesis temperature must be a real low value"
        );
        assert!(
            synth < gen_default,
            "synthesis must stay below the generation default"
        );
    }

    // ── ScoreOutcome (F4): the three classes the old Option<u8> merged ──

    #[test]
    fn score_outcome_splits_into_score_and_error() {
        assert_eq!(ScoreOutcome::Scored(7).into_parts(), (Some(7), None));
        assert_eq!(ScoreOutcome::Unparseable.into_parts(), (None, None));
        assert_eq!(
            ScoreOutcome::Failed("score fork failed: x".to_string()).into_parts(),
            (None, Some("score fork failed: x".to_string()))
        );
    }

    // ── classify (#458): Demux + scorer outcome → NodeOutcome ──
    //
    // Same mapping the coupled `expand` and the phased scorer feed, so both
    // execution strategies produce identical nodes.

    fn demux(reasoning: &str, answer: &str, kind: DemuxKind) -> Demux {
        demux_with_tokens(reasoning, answer, kind, 0)
    }

    fn demux_with_tokens(
        reasoning: &str,
        answer: &str,
        kind: DemuxKind,
        generated_tokens: usize,
    ) -> Demux {
        Demux {
            reasoning: reasoning.to_string(),
            answer: answer.to_string(),
            kind,
            generated_tokens,
        }
    }

    fn score(outcome: ScoreOutcome) -> ScoreResult {
        ScoreResult {
            outcome,
            generated_tokens: 0,
        }
    }

    fn score_with_tokens(outcome: ScoreOutcome, generated_tokens: usize) -> ScoreResult {
        ScoreResult {
            outcome,
            generated_tokens,
        }
    }

    #[test]
    fn classify_answered_scored_is_ok_with_score() {
        let o = classify(
            demux("r", "a", DemuxKind::Answered),
            Some(score(ScoreOutcome::Scored(7))),
        );
        assert_eq!(o.status, NodeStatus::Ok);
        assert_eq!(o.content, "a");
        assert_eq!(o.reasoning, "r");
        assert_eq!(o.score, Some(7));
        assert_eq!(o.score_error, None);
        assert_eq!(o.error, None);
    }

    #[test]
    fn classify_answered_unparseable_is_ok_null_score_no_error() {
        // Benign unparseable score (reasoning model emits no in-range int):
        // ok + null score, NO score_error — distinct from an infra failure.
        let o = classify(
            demux("", "a", DemuxKind::Answered),
            Some(score(ScoreOutcome::Unparseable)),
        );
        assert_eq!(o.status, NodeStatus::Ok);
        assert_eq!(o.score, None);
        assert_eq!(o.score_error, None);
    }

    #[test]
    fn classify_answered_score_infra_failure_surfaces_score_error() {
        let o = classify(
            demux("", "a", DemuxKind::Answered),
            Some(score(ScoreOutcome::Failed(
                "score fork failed: x".to_string(),
            ))),
        );
        assert_eq!(o.status, NodeStatus::Ok);
        assert_eq!(o.score, None);
        assert_eq!(o.score_error.as_deref(), Some("score fork failed: x"));
    }

    #[test]
    fn classify_answered_missing_score_defaults_to_infra_failure() {
        // Defensive: an Answered node must be scored. A None score is a
        // caller bug — surfaced as a score_error, never a silent null.
        let o = classify(demux("", "a", DemuxKind::Answered), None);
        assert_eq!(o.status, NodeStatus::Ok);
        assert_eq!(o.score, None);
        assert!(o.score_error.as_deref().unwrap().contains("not scored"));
    }

    #[test]
    fn classify_total_generated_tokens_include_reasoning_and_scorer_tokens() {
        let o = classify(
            demux_with_tokens(
                "hidden reasoning",
                "visible answer",
                DemuxKind::Answered,
                11,
            ),
            Some(score_with_tokens(ScoreOutcome::Scored(8), 3)),
        );

        assert_eq!(o.status, NodeStatus::Ok);
        assert_eq!(o.content, "visible answer");
        assert_eq!(o.reasoning, "hidden reasoning");
        assert_eq!(o.score, Some(8));
        assert_eq!(o.generated_tokens, 14);
    }

    #[test]
    fn classify_incomplete_preserves_reasoning_blanks_answer() {
        let o = classify(demux("partial", "", DemuxKind::Incomplete), None);
        assert_eq!(o.status, NodeStatus::Incomplete);
        assert_eq!(o.content, "");
        assert_eq!(o.reasoning, "partial");
        assert!(o.error.as_deref().unwrap().contains("no answer"));
        assert_eq!(o.score, None);
    }

    #[test]
    fn classify_aborted_is_error_with_message() {
        let o = classify(demux("r", "", DemuxKind::Aborted("boom".to_string())), None);
        assert_eq!(o.status, NodeStatus::Error);
        assert_eq!(o.content, "");
        assert_eq!(o.reasoning, "r");
        assert_eq!(o.error.as_deref(), Some("boom"));
    }

    #[test]
    fn retry_policy_only_retries_thinking_starvation() {
        assert!(should_retry_reasoning_starved(
            true,
            &demux("long hidden reasoning", "", DemuxKind::Incomplete)
        ));
        assert!(!should_retry_reasoning_starved(
            false,
            &demux("long hidden reasoning", "", DemuxKind::Incomplete)
        ));
        assert!(!should_retry_reasoning_starved(
            true,
            &demux("useful reasoning", "visible answer", DemuxKind::Answered)
        ));
        assert!(!should_retry_reasoning_starved(
            true,
            &demux(
                "partial",
                "",
                DemuxKind::Aborted("forward failed".to_string())
            )
        ));
    }

    #[test]
    fn no_think_retry_can_recover_reasoning_starved_branch() {
        let recovered = merge_no_think_retry(
            demux(
                "first attempt kept thinking until the budget",
                "",
                DemuxKind::Incomplete,
            ),
            demux("", "42", DemuxKind::Answered),
        );

        assert!(matches!(recovered.kind, DemuxKind::Answered));
        assert_eq!(recovered.answer, "42");
        // Preserve the useful first-pass thought trace even though the
        // survivor context/answer came from the bounded no-think retry.
        assert_eq!(
            recovered.reasoning,
            "first attempt kept thinking until the budget"
        );
    }

    #[test]
    fn no_think_retry_does_not_turn_second_starvation_into_ok() {
        let still_starved = merge_no_think_retry(
            demux("first long thought", "", DemuxKind::Incomplete),
            demux("retry also ignored /no_think", "", DemuxKind::Incomplete),
        );

        assert!(matches!(still_starved.kind, DemuxKind::Incomplete));
        assert!(still_starved.answer.is_empty());
        assert!(still_starved.reasoning.contains("first long thought"));
        assert!(
            still_starved
                .reasoning
                .contains("retry also ignored /no_think")
        );
    }

    #[derive(Clone, Debug, PartialEq, Eq)]
    struct FakeBranchCtx {
        id: &'static str,
        users: Vec<String>,
        cues: usize,
    }

    impl FakeBranchCtx {
        fn new(id: &'static str) -> Self {
            Self {
                id,
                users: Vec::new(),
                cues: 0,
            }
        }
    }

    #[derive(Clone, Debug)]
    struct FakeBranchCall {
        ctx_id: &'static str,
        directive: String,
        reasoning_budget: usize,
        answer_budget: usize,
        sink_node_id: String,
    }

    struct FakeBranchDriver {
        retry_fork: Result<FakeBranchCtx, String>,
        outputs: Vec<Demux>,
        calls: Vec<FakeBranchCall>,
    }

    impl FakeBranchDriver {
        fn new(retry_fork: Result<FakeBranchCtx, String>, outputs: Vec<Demux>) -> Self {
            Self {
                retry_fork,
                outputs,
                calls: Vec::new(),
            }
        }
    }

    impl BranchDriver<FakeBranchCtx> for FakeBranchDriver {
        fn fork_retry_base(&mut self, ctx: &FakeBranchCtx) -> Result<FakeBranchCtx, String> {
            assert_eq!(ctx.id, "first");
            self.retry_fork.clone()
        }

        fn push_user(&mut self, ctx: &mut FakeBranchCtx, directive: &str) {
            ctx.users.push(directive.to_string());
        }

        fn cue(&mut self, ctx: &mut FakeBranchCtx) {
            ctx.cues += 1;
        }

        fn generate<'a>(
            &'a mut self,
            ctx: &'a mut FakeBranchCtx,
            request: BranchGenerateRequest<'a>,
        ) -> DemuxFuture<'a> {
            self.calls.push(FakeBranchCall {
                ctx_id: ctx.id,
                directive: request.directive.to_string(),
                reasoning_budget: request.reasoning_budget,
                answer_budget: request.answer_budget,
                sink_node_id: request.sink_node_id.to_string(),
            });
            Box::pin(std::future::ready(self.outputs.remove(0)))
        }
    }

    fn retry_test_params() -> TotParams {
        TotParams {
            breadth: 3,
            depth: 1,
            beam_width: 1,
            max_tokens_per_node: 64,
            max_reasoning_tokens: 1024,
            temperature: 0.7,
            top_p: 0.9,
            thinking: true,
            exec: super::super::schema::ExecStrategy::CoupledSequential,
        }
    }

    #[test]
    fn branch_retry_flow_answers_from_retry_context_and_is_beam_eligible() {
        let params = retry_test_params();
        let mut driver = FakeBranchDriver::new(
            Ok(FakeBranchCtx::new("retry")),
            vec![
                demux(
                    "first attempt spent the whole budget thinking",
                    "",
                    DemuxKind::Incomplete,
                ),
                demux("", "retry answer", DemuxKind::Answered),
            ],
        );
        let (ctx, demux) = futures::executor::block_on(generate_branch_with(
            FakeBranchCtx::new("first"),
            &params,
            "tot-n1",
            1,
            2,
            &mut driver,
        ));

        assert_eq!(
            ctx.id, "retry",
            "answered retry context must survive for scoring/next-level expansion"
        );
        assert!(matches!(demux.kind, DemuxKind::Answered));
        assert_eq!(demux.answer, "retry answer");
        assert_eq!(driver.calls.len(), 2);
        assert_eq!(driver.calls[0].ctx_id, "first");
        assert_eq!(
            driver.calls[0].reasoning_budget,
            params.max_reasoning_tokens
        );
        assert_eq!(driver.calls[0].answer_budget, params.max_tokens_per_node);
        assert_eq!(driver.calls[1].ctx_id, "retry");
        assert_eq!(
            driver.calls[1].reasoning_budget,
            NO_THINK_RETRY_REASONING_TOKENS
        );
        assert_eq!(driver.calls[1].answer_budget, params.max_tokens_per_node);
        assert_eq!(driver.calls[1].sink_node_id, "tot-n1");
        assert!(driver.calls[1].directive.contains("/no_think"));
        assert!(
            driver.calls[1]
                .directive
                .contains("Retry now with no hidden reasoning")
        );

        let outcome = classify(demux, Some(score(ScoreOutcome::Scored(9))));
        assert_eq!(outcome.status, NodeStatus::Ok);
        let materialized = materialize_level(1, vec![branch("tot-n1", "root", 2, outcome)], 1);
        assert_eq!(
            materialized.keep,
            vec!["tot-n1"],
            "answered retry must be beam-eligible"
        );
    }

    #[test]
    fn branch_retry_flow_double_starvation_remains_non_selectable() {
        let params = retry_test_params();
        let mut driver = FakeBranchDriver::new(
            Ok(FakeBranchCtx::new("retry")),
            vec![
                demux("first thinking", "", DemuxKind::Incomplete),
                demux("still thinking", "", DemuxKind::Incomplete),
            ],
        );
        let (_ctx, demux) = futures::executor::block_on(generate_branch_with(
            FakeBranchCtx::new("first"),
            &params,
            "tot-n2",
            1,
            0,
            &mut driver,
        ));

        assert_eq!(
            driver.calls.len(),
            2,
            "starvation should attempt exactly one bounded retry"
        );
        assert_eq!(
            driver.calls[0].reasoning_budget,
            params.max_reasoning_tokens
        );
        assert_eq!(
            driver.calls[1].reasoning_budget,
            NO_THINK_RETRY_REASONING_TOKENS
        );
        assert!(matches!(demux.kind, DemuxKind::Incomplete));
        let outcome = classify(demux, None);
        assert_eq!(outcome.status, NodeStatus::Incomplete);
        let materialized = materialize_level(1, vec![branch("tot-n2", "root", 0, outcome)], 1);
        assert!(
            materialized.keep.is_empty(),
            "double-starved retry must not survive the beam"
        );
        assert!(!materialized.candidates[0].ok);
    }

    #[test]
    fn branch_retry_flow_surfaces_retry_base_fork_failure() {
        let params = retry_test_params();
        let mut driver = FakeBranchDriver::new(
            Err("snapshot unavailable".to_string()),
            vec![demux("first attempt starved", "", DemuxKind::Incomplete)],
        );
        let (ctx, demux) = futures::executor::block_on(generate_branch_with(
            FakeBranchCtx::new("first"),
            &params,
            "tot-n3",
            1,
            1,
            &mut driver,
        ));

        assert_eq!(
            ctx.id, "first",
            "without a retry fork, the original context is returned"
        );
        assert_eq!(
            driver.calls.len(),
            1,
            "failed retry-base fork must not run an impossible retry"
        );
        assert_eq!(
            driver.calls[0].reasoning_budget,
            params.max_reasoning_tokens
        );
        assert!(matches!(demux.kind, DemuxKind::Aborted(_)));
        let outcome = classify(demux, None);
        assert_eq!(outcome.status, NodeStatus::Error);
        assert_eq!(outcome.reasoning, "first attempt starved");
        assert!(
            outcome
                .error
                .as_deref()
                .unwrap()
                .contains("no-think retry fork failed: snapshot unavailable")
        );
        let materialized = materialize_level(1, vec![branch("tot-n3", "root", 1, outcome)], 1);
        assert!(
            materialized.keep.is_empty(),
            "retry fork failure must stay non-selectable"
        );
        assert!(!materialized.candidates[0].ok);
    }

    // ── materialize_level (F4 + F6) ──

    #[test]
    fn materialize_ok_branches_build_ok_nodes_sorted_beam() {
        let m = materialize_level(
            1,
            vec![
                branch("n0", "root", 0, ok_outcome("a", Some(5))),
                branch("n1", "root", 1, ok_outcome("b", Some(8))),
            ],
            2,
        );
        assert_eq!(m.nodes.len(), 2);
        assert!(m.nodes.iter().all(|n| n.status == NodeStatus::Ok));
        assert_eq!(m.nodes[0].content, "a");
        assert_eq!(m.candidates.iter().filter(|c| c.ok).count(), 2);
        // beam_width 2 keeps both, highest score first.
        assert_eq!(m.keep, vec!["n1", "n0"]);
    }

    #[test]
    fn materialize_generation_error_blanks_content_sets_error_excludes_from_beam() {
        let m = materialize_level(2, vec![branch("n0", "p", 0, err_outcome("boom"))], 2);
        let n = &m.nodes[0];
        assert_eq!(n.status, NodeStatus::Error);
        assert_eq!(n.content, "");
        assert_eq!(n.error.as_deref(), Some("boom"));
        assert_eq!(n.score_error, None);
        assert!(!m.candidates[0].ok);
        assert!(m.keep.is_empty());
    }

    #[test]
    fn materialize_surfaces_score_error_on_ok_node() {
        // F4: an ok node whose scorer infra failed carries score_error and
        // stays ok (eligible, ranked last by its None score) — distinct
        // from a benign unparseable null with no score_error.
        let m = materialize_level(
            1,
            vec![branch(
                "n0",
                "root",
                0,
                ok_outcome_score_failed("ans", "score fork failed: x"),
            )],
            2,
        );
        let n = &m.nodes[0];
        assert_eq!(n.status, NodeStatus::Ok);
        assert_eq!(n.score, None);
        assert_eq!(n.score_error.as_deref(), Some("score fork failed: x"));
        assert!(m.candidates[0].ok);
        assert_eq!(m.keep, vec!["n0"]);
    }

    #[test]
    fn materialize_incomplete_preserves_reasoning_blanks_answer_excludes_from_beam() {
        // #434/#437: a node that reasoned but never answered is kept in the
        // tree (so the UI can show the partial thought) but excluded from the
        // beam — it has no answer to select.
        let m = materialize_level(
            2,
            vec![branch(
                "n0",
                "p",
                0,
                incomplete_outcome("step 1: consider the base case…"),
            )],
            2,
        );
        let n = &m.nodes[0];
        assert_eq!(n.status, NodeStatus::Incomplete);
        assert_eq!(n.content, "");
        assert_eq!(n.reasoning, "step 1: consider the base case…");
        assert_eq!(n.error.as_deref(), Some("no answer"));
        assert!(!m.candidates[0].ok);
        assert!(m.keep.is_empty());
    }

    #[test]
    fn materialize_ok_node_carries_reasoning_and_stays_beam_eligible() {
        let m = materialize_level(
            1,
            vec![{
                let mut o = ok_outcome("the answer", Some(8));
                o.reasoning = "because X then Y".to_string();
                branch("n0", "root", 0, o)
            }],
            2,
        );
        let n = &m.nodes[0];
        assert_eq!(n.status, NodeStatus::Ok);
        assert_eq!(n.content, "the answer");
        assert_eq!(n.reasoning, "because X then Y");
        assert!(m.candidates[0].ok);
        assert_eq!(m.keep, vec!["n0"]);
    }

    #[test]
    fn with_thinking_appends_no_think_only_when_disabled() {
        assert_eq!(with_thinking("rate it", true), "rate it");
        assert_eq!(with_thinking("rate it", false), "rate it /no_think");
    }

    #[test]
    fn content_visible_only_outside_a_reasoning_block() {
        // Idle batch outside reasoning → visible answer content.
        assert!(content_visible(true, false));
        // The closing `</think>` batch: reasoning decoder is NOT Idle and we
        // WERE in reasoning → suppressed.
        assert!(!content_visible(false, true));
        // Inside reasoning (Idle never set there) → suppressed.
        assert!(!content_visible(false, false));
    }

    #[test]
    fn materialize_all_none_scores_keep_input_order() {
        // all-None path: ok nodes with no parseable score fall back to
        // deterministic input-order selection.
        let m = materialize_level(
            1,
            vec![
                branch("n0", "root", 0, ok_outcome("a", None)),
                branch("n1", "root", 1, ok_outcome("b", None)),
            ],
            1,
        );
        assert_eq!(m.keep, vec!["n0"]);
    }

    #[test]
    fn materialize_empty_level_is_empty() {
        // empty path: no forks succeeded (run records any failures as
        // error_leaf nodes directly, not through this helper).
        let m = materialize_level(1, vec![], 2);
        assert!(m.nodes.is_empty());
        assert!(m.candidates.is_empty());
        assert!(m.keep.is_empty());
    }

    // ── fold_level (F7) ──

    #[test]
    fn fold_advances_pool_when_level_has_survivors() {
        let prev = vec![cand("old", Some(1), true)];
        let this = vec![cand("new", Some(9), true)];
        let (pool, stop) = fold_level(prev, this, &["new".to_string()]);
        assert!(!stop);
        assert_eq!(pool.len(), 1);
        assert_eq!(pool[0].id, "new");
    }

    #[test]
    fn fold_empty_frontier_retains_prev_and_stops() {
        // F7: a level where every fork failed (no candidates, empty keep)
        // must NOT overwrite the pool and must stop the search.
        let prev = vec![cand("good", Some(7), true)];
        let (pool, stop) = fold_level(prev, vec![], &[]);
        assert!(stop);
        assert_eq!(pool[0].id, "good");
    }

    #[test]
    fn fold_all_error_level_retains_prev_and_stops() {
        // A level that forked but every generation errored: candidates
        // exist but none ok → keep empty → retain prior pool, stop.
        let prev = vec![cand("good", Some(7), true)];
        let this = vec![cand("e0", None, false), cand("e1", None, false)];
        let (pool, stop) = fold_level(prev, this, &[]);
        assert!(stop);
        assert_eq!(pool[0].id, "good");
    }

    // ── finalize (F6/F7 end to end) ──

    fn ok_leaf(id: &str, content: &str, score: Option<u8>) -> Node {
        Node {
            id: id.to_string(),
            parent_id: Some("root".to_string()),
            depth: 1,
            branch_index: Some(0),
            content: content.to_string(),
            reasoning: String::new(),
            score,
            status: NodeStatus::Ok,
            error: None,
            score_error: None,
            children: Vec::new(),
        }
    }

    #[test]
    fn finalize_picks_best_ok_leaf_content() {
        let flat = vec![
            Node::root(),
            ok_leaf("a", "answer-a", Some(3)),
            ok_leaf("b", "answer-b", Some(9)),
        ];
        let last = vec![cand("a", Some(3), true), cand("b", Some(9), true)];
        let out = finalize(flat, &last);
        assert_eq!(out.selected_node_id.as_deref(), Some("b"));
        assert_eq!(out.final_answer.as_deref(), Some("answer-b"));
    }

    #[test]
    fn finalize_all_error_last_level_nulls_answer() {
        let flat = vec![Node::root()];
        let last = vec![cand("e0", None, false), cand("e1", Some(8), false)];
        let out = finalize(flat, &last);
        assert!(out.selected_node_id.is_none());
        assert!(out.final_answer.is_none());
    }

    #[test]
    fn finalize_empty_last_level_nulls_answer() {
        let out = finalize(vec![Node::root()], &[]);
        assert!(out.selected_node_id.is_none());
        assert!(out.final_answer.is_none());
    }

    #[test]
    fn f7_late_full_failure_keeps_earlier_level_answer() {
        // End-to-end F7 regression: level 1 produces an ok leaf; level 2
        // fully fails (every fork dies → `run` pushes error_leaf nodes and
        // materialize sees no successful branch). The fold keeps level 1 as
        // the pool, so the final answer is level 1's best — not null, even
        // though the deepest *attempted* level had no leaf.
        let mut flat = vec![Node::root()];

        let LevelMaterialized {
            nodes,
            candidates,
            keep,
            generated_tokens: _,
        } = materialize_level(
            1,
            vec![branch("n0", "root", 0, ok_outcome("L1-best", Some(6)))],
            2,
        );
        flat.extend(nodes);
        let (pool1, stop1) = fold_level(Vec::new(), candidates, &keep);
        assert!(!stop1);

        // Level 2: every fork failed → `run` records the failure as an
        // error leaf directly (here via tree::error_leaf), and the
        // materializer sees no successful branch.
        flat.push(error_leaf("n0", 2, 0, "fork failed: gone".to_string()));
        let LevelMaterialized {
            nodes,
            candidates,
            keep,
            generated_tokens: _,
        } = materialize_level(2, vec![], 2);
        flat.extend(nodes);
        let (pool2, stop2) = fold_level(pool1, candidates, &keep);
        assert!(stop2);

        let out = finalize(flat, &pool2);
        assert_eq!(out.selected_node_id.as_deref(), Some("n0"));
        assert_eq!(out.final_answer.as_deref(), Some("L1-best"));
    }

    // ── reconcile_synthesis (run()'s synthesis fold; the engine-bound
    //    synthesize() can't run natively, so the reconciliation is its own
    //    pure seam — #523 Part A F1/F3) ──

    #[test]
    fn reconcile_synthesis_replaces_answer_and_marks_synthesized() {
        // A produced synthesis overrides the raw best-leaf answer and flips
        // the observability flag true.
        let mut out = finalize(
            vec![Node::root(), ok_leaf("a", "raw-best-leaf", Some(9))],
            &[cand("a", Some(9), true)],
        );
        assert_eq!(out.final_answer.as_deref(), Some("raw-best-leaf"));
        assert!(!out.synthesized);

        reconcile_synthesis(&mut out, Some("synthesized-final-answer".to_string()));
        assert_eq!(
            out.final_answer.as_deref(),
            Some("synthesized-final-answer")
        );
        assert!(out.synthesized);
    }

    #[test]
    fn reconcile_synthesis_none_preserves_best_leaf_and_stays_unsynthesized() {
        // The load-bearing fail-safe: a skipped/failed synthesis (`None`) must
        // NOT null the raw best-leaf answer finalize() set, and leaves the
        // flag false so a dead synthesizer is observable, never masked.
        let mut out = finalize(
            vec![Node::root(), ok_leaf("a", "raw-best-leaf", Some(9))],
            &[cand("a", Some(9), true)],
        );
        reconcile_synthesis(&mut out, None);
        assert_eq!(out.final_answer.as_deref(), Some("raw-best-leaf"));
        assert!(!out.synthesized);
    }

    #[test]
    fn reconcile_synthesis_none_keeps_honest_null_when_no_leaf() {
        // No ok leaf → finalize() honestly nulled final_answer; a skipped
        // synthesis leaves it null (and unsynthesized).
        let mut out = finalize(vec![Node::root()], &[]);
        assert!(out.final_answer.is_none());
        reconcile_synthesis(&mut out, None);
        assert!(out.final_answer.is_none());
        assert!(!out.synthesized);
    }
}
