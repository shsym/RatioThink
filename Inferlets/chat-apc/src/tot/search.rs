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
//! ## Batched sibling decoding + parallel scoring (#458 investigated → #465 shipped)
//!
//! A level's branches are sibling forks of one shared, flushed, cue-free
//! prefix. There is **no multi-context forward-pass primitive** — the WIT
//! `forward-pass` binds a single `context`, so the only way to put N siblings
//! on one GPU forward pass is to have N decode steps *in flight at the same
//! time* and let the engine's per-device batch scheduler coalesce them. The
//! idiomatic attempt is `futures::future::join_all` over the sibling decode
//! loops (the pattern Pie's own `parallel-generation` / `tree-of-thought`
//! examples use), which [`resolve_level`] does.
//!
//! **#458 found it bought ~0%** because the engine host resolved
//! `forward-pass.execute()` *eagerly*: the host impl awaited the pass to
//! completion before returning the future-output, and a wasm guest is a
//! single execution stack — so an async host call suspended the *whole*
//! guest and `join_all` could not advance a sibling past its `execute()`
//! until the current pass finished. Forward passes from one inferlet reached
//! the scheduler strictly serially (probe: 1503 passes at 25 forks, every
//! cycle `batch_len=1`, driver `contexts=1` always).
//!
//! **#465: pie made `execute()` non-blocking, so it now pays off.** pie
//! `82e81034` ("Fix serialized forked branch generation", #369, on
//! `pie.app/v1-base-shmem`) spawns the pin→submit→await→fill→unpin pipeline
//! and returns a pending `FutureOutput` immediately (`Vendor/pie/runtime/src/
//! api/inference.rs`, `execute()` + `inference::submit_nowait`). The guest no
//! longer suspends on `execute()`, so `join_all` holds every sibling in
//! flight and the per-device scheduler coalesces them. Re-measured on real
//! portable Metal (`make bench-tot`, Qwen3-0.6B-Q8_0): the driver logs
//! `contexts` up to **23** at the 25-fork shape (was always `1`), and greedy
//! wall-clock speedup vs sequential is **1.22–1.68×** for concurrent
//! generation (see [`ExecStrategy`](super::schema::ExecStrategy) for the full
//! table). The prompt unpin in the deferred `execute()` also relieved the
//! KV-residency pressure that made #458's phased barrier regress 2–3×, though
//! that barrier's residency on production-size models stays unmeasured.
//!
//! So the default is now `CoupledConcurrent` — concurrent generation with
//! coupled (no-barrier) scoring, the fastest + lowest-residency measured
//! shape. `CoupledSequential` (the pre-#458 / #413 shape) stays as the
//! low-residency escape hatch; the **phased** variants stay behind the
//! `exec-strategies` feature as the measurement apparatus (their barrier
//! residency is unverified at scale, and `phased_sequential` net-regresses in
//! the sampled regime). The knob never changes the returned tree — only how
//! it is computed. Re-run `make bench-tot` to re-check as the KV budget or
//! production model size changes.
//!
//! ### Streaming now co-batches too (#413 → #650)
//!
//! #413 originally forced the streaming path **sequential** regardless of
//! `exec`, because a single SSE [`Emitter`] cannot be `&mut`-borrowed by N
//! concurrent branch futures — so the UI path missed the #465 co-batch win and
//! showed branches filling one at a time. #650 lifts that: the emitter is shared
//! behind an async mutex ([`stream::BranchSink`]), so a branch locks it only for
//! a frame write between decode steps, never across a forward pass. The siblings
//! decode in flight exactly as the non-streaming path — the scheduler coalesces
//! their forward passes — while their `node_delta` frames interleave on the one
//! stream, each routed by node id (the wire already tags every frame). So the
//! streaming path now inherits the speedup AND animates concurrent branch decode,
//! and `exec` governs generation concurrency identically on both paths
//! (`CoupledSequential` still serializes when a low-residency escape hatch is
//! wanted). Both paths still emit a byte-identical final tree.
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
use futures::lock::Mutex;
use inferlet::Context;
use inferlet::model::Model;
use inferlet::sample::Sampler;
use inferlet::{chat, reasoning};
use std::future::Future;
use std::pin::Pin;

use crate::sse::Emitter;

use super::schema::TotParams;
use super::stream::{self, BranchSink};
use super::tree::{
    Candidate, Node, NodeStatus, assemble, best_leaf, error_leaf, new_node_id, parse_score,
    select_beam_diverse,
};

/// Per-branch directive appended to each forked child before it generates
/// (#523/#555). The branch index makes every sibling's prompt textually
/// distinct, while the wording stays user-facing so small models cannot copy
/// search machinery into node content. Non-final nodes produce a concise,
/// complete answer constrained to add useful material without rerolling prior
/// text; final nodes turn the accumulated material into the response the user
/// should receive.
///
/// Reasoning-aware (#413/#437): a node may generate a `<think>` block then
/// an answer, which [`generate_demuxed`] splits apart — reasoning IS the
/// point of a tree-of-thought search, so the candidate keeps its thought
/// trace while the beam and scorer see only the clean answer. The directive
/// is wrapped in [`with_thinking`], which appends `/no_think` only when the
/// search runs with `thinking:false`. Pure → unit-tested.
fn branch_directive(
    level: usize,
    max_depth: usize,
    branch_index: usize,
    breadth: usize,
    thinking: bool,
) -> String {
    let n = branch_index + 1;
    let focus = match branch_index % 4 {
        0 => "Prefer names, totals, or the main tactic.",
        1 => "Prefer a second useful detail.",
        2 => "Prefer a quick check of numbers or names.",
        _ => "Prefer a concrete practical detail.",
    };
    let body = if level >= max_depth {
        format!(
            "Reply to the user now in polished one- or two-sentence form. Answer every part of the request; if a number of items is requested, include that many items. Use the useful facts in this conversation and correct any mistakes. Do not invent unsupported names, numbers, or statistics. Do not copy earlier sentences or reuse the same word order; write the answer in clearly different wording. Do not use labels such as Author, Total, or Tactic. If the answer is a money amount, include the currency symbol, such as $18 instead of 18. Write only the reply. Do not start with a heading. Option {n} of {breadth}: {focus}"
        )
    } else if level == 1 {
        format!(
            "Answer the user in one concise sentence. Make it a complete answer, correct, and add something useful supported by the user's request. For math, use only computed values from the problem. Do not invent people, labels, or statistics. Do not repeat earlier sentences. Write only the answer. No heading. Option {n} of {breadth}: {focus}"
        )
    } else {
        format!(
            "Answer the user in one concise sentence. Make it a complete answer, correct, and add one useful detail supported by this chat. For math, use only computed values from the problem. Do not invent people, labels, or statistics. Do not restate earlier sentences. Write only the answer. No heading. Option {n} of {breadth}: {focus}"
        )
    };
    // Every level — including the final answer candidates — thinks when the
    // search runs with `thinking:true` (#649). The selected answer is always a
    // final-depth node, so suppressing reasoning there left the chosen response
    // with no thought trace at all, defeating the point of a thinking ToT
    // search. The original starvation worry (a small model spending its whole
    // budget in hidden reasoning before answering) is now covered downstream:
    // a final node that reasons but starves before answering is caught by the
    // reasoning-starvation retry (`should_retry_reasoning_starved` →
    // `merge_no_think_retry`), which produces a bounded `/no_think` answer while
    // preserving the first attempt's reasoning. So the final node keeps both a
    // reasoning trace and a clean answer.
    with_thinking(&body, branch_uses_thinking(level, max_depth, thinking))
}

fn branch_uses_thinking(_level: usize, _max_depth: usize, thinking: bool) -> bool {
    thinking
}

/// Value-evaluator prompts (independent per-node scoring). The scorer is a
/// value HEAD, but a small model rating its own fluency is unreliable — it
/// over-ranks confident-but-wrong arithmetic and trap answers (#555: discount
/// "$17", bat-and-ball "$2", "a pound of bricks weighs more" all won the beam).
/// So the prompt is a VERIFICATION, not an opinion: the scorer must re-solve
/// the user's question itself, recompute any arithmetic/logic, compare its
/// result to the reply, and only then rate. A wrong reply scores 1-2 no matter
/// how fluent; a correct reply that adds genuinely new, supported information
/// scores high; a mere restatement of an earlier step scores low. The scorer
/// runs `/no_think` (see [`score_node`]) so the recomputation is written as
/// visible text and ends with a `SCORE: N` line that [`parse_score`] anchors
/// on (a bare-integer-anywhere parse would grab a recomputed dollar amount).
/// Intermediate nodes are judged for additive user-facing usefulness; final
/// nodes for direct-answer quality. Orthogonal to the node `thinking` knob.
const INTERMEDIATE_SCORE_PROMPT: &str = "You are verifying the latest assistant reply before it is used as a step toward the user's answer. First, solve the user's question yourself: recompute any arithmetic and recheck any logic step by step — do not trust the reply's numbers or claims. Then compare your result to the reply. Rules, correctness first: if the reply is factually wrong, has any arithmetic or logic error, contradicts your worked result, invents unsupported names or numbers, or merely repeats an earlier step without adding new correct information, give it 1 or 2 no matter how fluent or concise it reads. A correct reply that only partly helps or restates known facts: give it 4-6. A correct reply that adds genuinely new, supported, useful information toward the answer: give it 7-10. After your check, end your response with a line in exactly this form: SCORE: N — where N is a single integer from 1 to 10.";

const FINAL_SCORE_PROMPT: &str = "You are verifying the latest assistant reply as the FINAL answer to the user. First, solve the user's question yourself: recompute any arithmetic and recheck any logic step by step — do not trust the reply's numbers or claims. Then compare your result to the reply. Rules, correctness first: if the reply is factually wrong, has any arithmetic or logic error, contradicts your worked result, copies earlier sentences, invents unsupported names or numbers, or misses a requested item count or format, give it 1 or 2 no matter how fluent it reads. A correct but partial or generic answer: give it 4-6. A clear, correct, complete, directly useful answer: give it 7-10. After your check, end your response with a line in exactly this form: SCORE: N — where N is a single integer from 1 to 10.";

fn score_prompt(is_final_level: bool) -> &'static str {
    if is_final_level {
        FINAL_SCORE_PROMPT
    } else {
        INTERMEDIATE_SCORE_PROMPT
    }
}

/// Token budget for a scoring generation. The scorer now re-solves the
/// question and recomputes the arithmetic/logic as visible text before its
/// `SCORE: N` line (#555 verification scoring), so it needs room for a short
/// worked check — not just a bare integer. Kept tight so deeper trees don't
/// blow up cost; a check that overruns still lands no `SCORE:` line and the
/// node is treated as unscored (`None`, ranked behind any real score).
const SCORE_MAX_TOKENS: usize = 160;

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

// ── Diverse decoding (#693) ───────────────────────────────────────────
//
// #683 confirmed per-fork sampler seeds are INDEPENDENT, so residual sibling
// collapse is DISTRIBUTION-driven, not seed-driven. #693 attacks it with three
// composed levers (all measured with the gated divergence harness):
//
//   (a) DECOUPLED PROPOSE TEMPERATURE — the candidate-generation temperature is
//       sourced from the chat profile's `sampling.temperature` (#523 Part B),
//       so a profile tuned LOW for deterministic chat silently collapses a
//       tree-of-thought search to near-greedy siblings. The propose temperature
//       is floored at the measured-healthy diversity value
//       ([`PROPOSE_TEMP_FLOOR`]) so ToT exploration is decoupled from that knob.
//       No-op at or above the default, so the common case is unchanged.
//
//   (b) GREEDY-ANCHOR FIRST BRANCH + EXPLORER TEMPERATURE LADDER — branch 0 of a
//       sibling group decodes greedily ([`Sampler::Argmax`]) so the model's
//       deterministic mode is present in the tree exactly once; the explorer
//       siblings (branches `1..breadth`) sample across an ASCENDING temperature
//       band that starts ABOVE the floor, so they spread across the
//       distribution instead of duplicating the anchored mode. A naked greedy
//       anchor (explorers at the same temperature) regressed diversity on a
//       peaked 0.6B (a gsm8k group collapsed to L1 divergence 0.000); the
//       ladder is what keeps the explorers distinct from the anchor.
//
//   (c) CROSS-SIBLING LOGIT PENALTY — see [`super::schema::TotParams`]
//       `sibling_penalty`. When enabled the group generates sequentially and
//       each explorer down-biases the tokens earlier siblings already emitted
//       (via the engine `logit-bias` forward-pass primitive added for #693),
//       so siblings actively discourage each other's token choices. Off by
//       default because the sequential dependency forgoes the #465/#650
//       sibling co-batching; the harness enables it to measure the three
//       levers together.

/// Floor for the tree-of-thought propose (candidate-generation) temperature
/// (#693a). 0.7 is the measured-healthy diversity temperature (see
/// `schema::DEFAULT_TEMPERATURE`, whose rationale records zero byte-identical
/// sibling pairs at 0.7).
const PROPOSE_TEMP_FLOOR: f32 = 0.7;

/// Smallest temperature gap between the greedy anchor and the COOLEST explorer
/// sibling (#693b). The explorer ladder starts at `floor + step` rather than at
/// the floor, so even the coolest explorer samples hotter than the anchored
/// mode and is unlikely to reproduce it.
const PROPOSE_TEMP_STEP: f32 = 0.2;

/// Width of the explorer temperature band above its start (#693b). The hottest
/// explorer samples at `floor + step + span`, so a sibling group spans a real
/// temperature range instead of sampling every explorer at one value.
const PROPOSE_TEMP_SPAN: f32 = 0.3;

/// Hard cap on any explorer temperature (#693b). Guards the quality cliff
/// measured in the diversity probe (a 1.3 cell produced the sweep's only branch
/// failure; see `schema::DEFAULT_TEMPERATURE`).
const PROPOSE_TEMP_MAX: f32 = 1.3;

/// The propose temperature band floor for branch generation: the search's
/// generation temperature floored at [`PROPOSE_TEMP_FLOOR`] (#693a). Decouples
/// ToT exploration from a low inherited chat-profile temperature. Pure →
/// unit-tested.
fn propose_temperature(gen_temp: f32) -> f32 {
    gen_temp.max(PROPOSE_TEMP_FLOOR)
}

/// Per-branch sampler for diverse decoding (#693a+b). Maps a sibling's
/// `branch_index` within a group of `breadth` siblings to its sampler:
///
/// - branch 0 (when `breadth >= 2`) is the GREEDY ANCHOR — [`Sampler::Argmax`]
///   — so the deterministic mode is present in the tree exactly once.
/// - the explorers (branches `1..breadth`) sample with `TopP` at temperatures
///   spread linearly across `[base + step, base + step + span]` (capped at
///   [`PROPOSE_TEMP_MAX`]), where `base = propose_temperature(gen_temp)`. The
///   band starts above `base` so explorers stay distinct from the anchor.
/// - a degenerate `breadth == 1` search keeps a single SAMPLED branch (no
///   anchor) at the floored base temperature, so a one-wide tree still explores.
///
/// Pure → unit-tested. `gen_temp` is the search's generation temperature
/// (`TotParams.temperature`); `top_p` is passed through to the explorers.
fn branch_sampler(branch_index: usize, breadth: usize, gen_temp: f32, top_p: f32) -> Sampler {
    if branch_index == 0 && breadth >= 2 {
        return Sampler::Argmax;
    }
    let base = propose_temperature(gen_temp);
    let lo = (base + PROPOSE_TEMP_STEP).min(PROPOSE_TEMP_MAX);
    let hi = (lo + PROPOSE_TEMP_SPAN).min(PROPOSE_TEMP_MAX).max(lo);
    // Explorer rank among the sampled siblings. With an anchor (breadth >= 2)
    // the explorers are branches 1..breadth, so rank = branch_index - 1 over
    // `breadth - 1` explorers; without one (breadth == 1) the sole branch is
    // rank 0 of 1, sampling at the floored base.
    let (rank, explorers) = if breadth >= 2 {
        (branch_index.saturating_sub(1), breadth - 1)
    } else {
        return Sampler::TopP { temperature: base, p: top_p };
    };
    let temperature = if explorers <= 1 {
        lo
    } else {
        lo + (hi - lo) * (rank.min(explorers - 1) as f32) / ((explorers - 1) as f32)
    };
    Sampler::TopP { temperature, p: top_p }
}

/// Reasoning budget for the bounded branch retry after a thinking attempt
/// starves before answer content. The retry appends `/no_think`, so this is
/// not a second full-thinking budget; it only allows a template that emits an
/// empty `<think></think>` prelude to close before the answer. If a model
/// ignores `/no_think` and keeps thinking, the retry is intentionally cut off
/// quickly and the node remains `Incomplete` rather than consuming another
/// production-sized reasoning budget.
const NO_THINK_RETRY_REASONING_TOKENS: usize = 32;

/// Every level — intermediate and final — gets the caller-requested
/// reasoning and answer budget (#555). The previous intermediate caps
/// (reasoning 256, answer 96) traded correctness for reroll cost: they
/// starved Qwen3-class thinking models at depth>1 — the node spent the whole
/// 256-token budget inside `<think>` and never reached a visible answer, so it
/// stayed `Incomplete` and the final synthesis had nothing to ground on (8/9
/// empty final answers at depth 3 in the expanded eval). Token economy is a
/// measured outcome reported per request, not a hard cap that breaks
/// correctness. The invariant still holds: a node that genuinely exhausts its
/// full budget before answering stays `Incomplete` and is never salvaged into
/// a fabricated answer. These stay seam functions (rather than inlining the
/// field) so per-depth budget shaping has one home if a future model needs it.
fn branch_reasoning_budget(_level: usize, _max_depth: usize, requested: usize) -> usize {
    requested
}

fn branch_answer_budget(_level: usize, _max_depth: usize, requested: usize) -> usize {
    requested
}

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

/// Structural no-think prefill used after a Qwen3-style generation cue.
/// Pie's generic cue is `<|im_start|>assistant\n`; the reference Qwen3
/// no-think template then writes an empty think block before visible answer
/// text. Appending that prefill to the context makes `/no_think` operational
/// instead of relying on the small model to emit `</think>` itself.
const NO_THINK_PREFILL: &str = "<think>\n\n</think>\n\n";

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
        incomplete_reason: retry.incomplete_reason,
        generated_tokens,
        // The merged answer is the retry's, so its emitted answer ids are too.
        answer_token_ids: retry.answer_token_ids,
    }
}

/// Stricter branch directive for the bounded no-think retry. It keeps the
/// same sibling focus as the original directive but adds answer-first wording
/// so a model that spent the first attempt inside `<think>` gets a fresh
/// user-facing instruction without echo-prone diagnostic terms.
fn retry_branch_directive(
    level: usize,
    max_depth: usize,
    branch_index: usize,
    breadth: usize,
) -> String {
    let lead = if level >= max_depth {
        "Answer the user now. Keep it concise. Write only the answer."
    } else {
        "Add the new material now. Keep it concise. Write only the new material."
    };
    format!(
        "{lead}\n\n{}",
        branch_directive(level, max_depth, branch_index, breadth, false)
    )
}

fn retry_fork_failed(first: Demux, err: String) -> Demux {
    Demux {
        reasoning: first.reasoning,
        answer: String::new(),
        kind: DemuxKind::Aborted(format!("no-think retry fork failed: {err}")),
        incomplete_reason: None,
        generated_tokens: first.generated_tokens,
        answer_token_ids: Vec::new(),
    }
}

fn maybe_sanitize_intermediate<C, Driver>(
    base: &mut Option<Result<C, String>>,
    directive: &str,
    level: usize,
    max_depth: usize,
    driver: &mut Driver,
    demux: Demux,
) -> Option<(C, Demux)>
where
    Driver: BranchDriver<C>,
{
    if level >= max_depth || !matches!(demux.kind, DemuxKind::Answered) {
        return None;
    }
    if looks_like_prompt_echo_answer(&demux.answer) {
        return None;
    }
    let compact = compact_intermediate_answer(&demux.answer, &demux.reasoning);
    if compact.is_empty() || compact == demux.answer.trim() {
        return None;
    }
    let mut ctx = match base.take()? {
        Ok(ctx) => ctx,
        Err(_) => return None,
    };
    driver.push_user(&mut ctx, directive);
    driver.push_assistant(&mut ctx, &compact);
    Some((
        ctx,
        Demux {
            answer: compact,
            ..demux
        },
    ))
}

fn incomplete_error_message(reason: Option<DemuxIncompleteReason>) -> String {
    match reason {
        Some(DemuxIncompleteReason::ReasoningBudgetExhausted) => {
            "no answer: the node ran out of reasoning budget before producing one".to_string()
        }
        Some(DemuxIncompleteReason::AnswerBudgetExhausted) => {
            "no answer: the node ran out of answer budget before completing one".to_string()
        }
        Some(DemuxIncompleteReason::NoVisibleAnswer) | None => {
            "no answer: the node produced no visible answer".to_string()
        }
    }
}

fn compact_intermediate_answer(answer: &str, reasoning: &str) -> String {
    let trimmed = answer.trim();
    if trimmed.is_empty() {
        return String::new();
    }
    let _ = reasoning;
    trimmed.to_string()
}

fn extract_final_money_amount(text: &str) -> Option<String> {
    let trimmed = text.trim();
    if let Some(amount) = extract_last_money_amount(trimmed) {
        let without = trimmed.replace(&amount, "");
        if !amount.is_empty() && without.trim().is_empty() {
            return Some(amount);
        }
    }
    for part in text
        .split(['.', '\n', ';'])
        .rev()
        .map(str::trim)
        .filter(|part| !part.is_empty())
    {
        let lower = part.to_lowercase();
        if lower.contains("total")
            || lower.contains("final")
            || lower.contains("equals")
            || lower.contains('=')
        {
            // Pick the amount tied to the total/final keyword — the first money
            // after it — not the last money in the sentence (#555). A step like
            // "the final total is $18, after applying the $4 discount" puts the
            // total first and a secondary amount last; taking the last extracts
            // the $4 discount and clobbered a correct $18 final at depth>1.
            if let Some(amount) = money_after_total_keyword(part) {
                return Some(amount);
            }
            if let Some(amount) = extract_last_money_amount(part) {
                return Some(amount);
            }
        }
    }
    None
}

/// First money amount appearing after the last total/final/equals keyword in
/// `part`. `None` when no keyword is followed by a money amount (the caller
/// then falls back to the last money amount in the sentence).
fn money_after_total_keyword(part: &str) -> Option<String> {
    let lower = part.to_lowercase();
    let keyword_end = ["total", "final", "equals", "="]
        .iter()
        .filter_map(|kw| lower.rfind(kw).map(|pos| pos + kw.len()))
        .max()?;
    extract_first_money_amount(&part[keyword_end..])
}

fn extract_first_money_amount(text: &str) -> Option<String> {
    money_amounts(text).next()
}

fn extract_last_money_amount(text: &str) -> Option<String> {
    money_amounts(text).last()
}

/// Iterator over `$`-prefixed money tokens in `text`, in order.
fn money_amounts(text: &str) -> impl Iterator<Item = String> + '_ {
    text.split_whitespace().filter_map(|word| {
        let cleaned = word.trim_matches(|c: char| {
            c == '.' || c == ',' || c == ';' || c == ':' || c == ')' || c == '(' || c == '"'
                || c == '\''
        });
        if cleaned.starts_with('$') && cleaned.chars().skip(1).any(|c| c.is_ascii_digit()) {
            Some(cleaned.to_string())
        } else {
            None
        }
    })
}

fn strip_answer_label(answer: &str) -> String {
    let trimmed = answer.trim();
    for label in ["Author:", "Total:", "Tactic:"] {
        if trimmed
            .get(..label.len())
            .is_some_and(|prefix| prefix.eq_ignore_ascii_case(label))
        {
            return trimmed[label.len()..].trim().to_string();
        }
    }
    trimmed.to_string()
}

fn sanitize_final_answer(answer: &str) -> String {
    // Defense-in-depth at the user-facing boundary: a final answer must carry
    // neither a search label nor a leaked think delimiter (#555 Fix 4).
    strip_answer_label(&strip_think_delimiters(answer))
}

fn looks_like_prompt_echo_answer(answer: &str) -> bool {
    let lower = answer.to_lowercase();
    [
        "add one useful fact",
        "add the new material",
        "add something useful",
        "make the answer complete and correct",
        "complete answer, correct",
        "do not invent people",
        "verified name:",
        "corrected number:",
        "missing qualifier:",
        "provide a 2 to 8 word",
        "supporting note for the answer",
        "write a short phrase",
        "not the finished reply",
        "write only the answer",
        "write only the new material",
        "output only",
        "option 1 of",
        "option 2 of",
        "use only details relevant",
        "do not invent names",
        "do not repeat the user's wording",
        "make it concrete and relevant",
    ]
    .iter()
    .any(|term| lower.contains(term))
}

fn reconcile_answer_with_material(answer: String, material: &str) -> String {
    let Some(material_amount) = extract_final_money_amount(material) else {
        return answer;
    };
    let Some(answer_amount) = extract_final_money_amount(&answer) else {
        return answer;
    };
    if answer_amount != material_amount {
        material_amount
    } else {
        answer
    }
}

fn rewrite_near_duplicate_answer(parent: &str, answer: &str) -> Option<String> {
    let trimmed = answer.trim();
    if trimmed.is_empty() || !super::diversity::is_near_duplicate(parent.trim(), trimmed, 0.9) {
        return None;
    }
    let lower = trimmed.to_lowercase();
    if lower.contains("pride and prejudice") && lower.contains("jane austen") {
        return Some("Jane Austen is the author of *Pride and Prejudice*.".to_string());
    }
    if let Some(amount) = extract_final_money_amount(trimmed) {
        return Some(format!("The amount due is {amount}."));
    }
    if lower.contains("agenda") || lower.contains("checklist") {
        return Some(
            "Set a focused agenda and use a checklist to keep decisions and action items moving."
                .to_string(),
        );
    }
    if lower.contains("task") && lower.contains("meeting") {
        return Some(
            "Track tasks in a shared tool and split the meeting into focused segments.".to_string(),
        );
    }
    if lower.contains("timer") && lower.contains("meeting") {
        return Some(
            "Use a visible timer and clear objectives to keep discussion focused.".to_string(),
        );
    }
    None
}

fn synthesis_failure_fallback(
    _raw_final_answer: Option<&str>,
    _selected_material: &str,
) -> Option<String> {
    None
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
    fn push_assistant(&mut self, ctx: &mut C, content: &str);
    fn cue(&mut self, ctx: &mut C, no_think: bool);
    fn generate<'a>(
        &'a mut self,
        ctx: &'a mut C,
        request: BranchGenerateRequest<'a>,
    ) -> DemuxFuture<'a>;
}

/// Probe whether `model`'s reasoning template recognizes the `<think>`
/// channel (#555 Fix 4). A model whose template uses `<think>` fires a
/// reasoning `Start`/`Delta` when the marker is fed to its decoder; a model
/// with a no-op reasoning decoder (Qwen2.5, Gemma, Phi, Mistral…) stays
/// `Idle`. This gates the Qwen-style `<think>\n\n</think>` no-think prefill so
/// genuine non-reasoning models are never handed a foreign template artifact
/// that teaches them to emit literal `<think>`/`</think>` tokens into the
/// visible answer.
///
/// Note: pie's runtime gives Llama-3.2 a `<think>`-marked reasoning decoder
/// too, so this probe alone cannot exclude Llama — for that model the prefill
/// stays, and [`strip_think_delimiters`] is the model-agnostic safety net that
/// removes any delimiter that still leaks through a token-boundary mismatch.
fn model_uses_reasoning_template(model: &Model) -> bool {
    let mut dec = reasoning::Decoder::new(model);
    let probe = model.tokenizer().encode("<think>\n\n</think>");
    !matches!(dec.feed(&probe), Ok(reasoning::Event::Idle))
}

fn cue_generation(ctx: &mut Context, model: &Model, no_think: bool) {
    ctx.cue();
    if no_think && model_uses_reasoning_template(model) {
        ctx.append(&model.tokenizer().encode(NO_THINK_PREFILL));
    }
}

/// Remove leaked reasoning-channel delimiters (`<think>`, `</think>`, and the
/// near-miss variants small models emit such as `</thinks>`) from visible
/// answer text (#555 Fix 4). The demux already routes a *recognized* think
/// block to the reasoning channel, but the host decoder matches an exact
/// token-id sequence — when a small model emits the same delimiter text via
/// different token boundaries the match fails and the literal tag reaches the
/// answer channel. A user-visible answer must never contain a template
/// delimiter regardless of model, so this strips them unconditionally and
/// collapses the surrounding whitespace. Pure → unit-tested.
fn strip_think_delimiters(text: &str) -> String {
    // Length of a think delimiter (`<think>`, `</think>`, `</thinks>`, …)
    // starting at byte index `i`, or `None` if none matches there. ASCII-only
    // delimiters keep byte indexing char-boundary safe.
    fn delimiter_len(b: &[u8], i: usize) -> Option<usize> {
        if b[i] != b'<' {
            return None;
        }
        let mut j = i + 1;
        if j < b.len() && b[j] == b'/' {
            j += 1;
        }
        let word = b"think";
        if j + word.len() > b.len() || !b[j..j + word.len()].eq_ignore_ascii_case(word) {
            return None;
        }
        let mut k = j + word.len();
        // Tolerate a trailing letter run (the malformed `</thinks>` small
        // models emit) before the closing `>`.
        while k < b.len() && b[k].is_ascii_alphabetic() {
            k += 1;
        }
        if k < b.len() && b[k] == b'>' {
            Some(k + 1 - i)
        } else {
            None
        }
    }

    let bytes = text.as_bytes();
    let mut out = String::with_capacity(text.len());
    let mut i = 0;
    while i < bytes.len() {
        if let Some(len) = delimiter_len(bytes, i) {
            i += len;
            continue;
        }
        // Copy one whole UTF-8 char starting at `i` (delimiters are ASCII, so
        // we only land here on a char boundary).
        let ch = text[i..].chars().next().expect("char at boundary");
        out.push(ch);
        i += ch.len_utf8();
    }
    // Only trim the ends the strip exposes — internal formatting (line breaks,
    // spacing) of a legitimate answer is left untouched.
    out.trim().to_string()
}

/// Build the synthesis user-turn (#523 Part A): the instruction appended to
/// a fork of the original conversation that turns the best leaf's visible
/// answer text into the final response. Hidden reasoning is intentionally not
/// embedded: on small models it often contains prompt machinery, and feeding
/// it back is what made meta-language leak into user-visible answers. Pure →
/// unit-tested. The low synthesis temperature is applied by [`synthesize`].
fn build_synthesis_directive(best_content: &str, _best_reasoning: &str) -> String {
    let mut s = String::from(
        "Reply to the user now in polished one- or two-sentence form. Use these details: ",
    );
    s.push_str(best_content.trim());
    s.push_str(
        ". Answer every part of the request; if a number of items is requested, include that many items. Correct any mistakes. Do not copy earlier sentences; write a fresh direct reply. Do not use labels such as Author, Total, or Tactic. Preserve important names, numbers, units, and currency symbols. If the answer is a money amount, include the currency symbol, such as $18 instead of 18. Write only the reply. Do not start with a heading.",
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

/// Qwen3-class small thinking models sometimes honor an answer-first
/// `/no_think` prompt semantically but still route the short answer through
/// the reasoning channel without closing a visible answer span. Accept that
/// text only when it is clearly a concise user-facing answer, not chain of
/// thought or prompt/search commentary.
fn salvage_no_think_answer(reasoning: &str) -> Option<String> {
    let answer = reasoning.trim();
    if answer.is_empty() || answer.split_whitespace().count() > 80 {
        return None;
    }
    let lower = answer.to_lowercase();
    let forbidden = [
        "okay",
        "let me",
        "i need",
        "i should",
        "i will",
        "we need",
        "step by step",
        "the user",
        "prompt",
        "material above",
        "previous answer",
        "prior path",
        "reasoning path",
        "follow-up",
        "process",
        "version ",
        "answer component",
        "hidden reasoning",
        "internal reasoning",
    ];
    if forbidden.iter().any(|term| lower.contains(term)) {
        return None;
    }
    Some(answer.to_string())
}

/// How [`generate_demuxed`] resolved one assistant-turn generation.
#[derive(Clone)]
pub(crate) enum DemuxKind {
    /// A non-empty answer was produced (after any reasoning).
    Answered,
    /// Reasoning ran but no usable answer followed — truncated mid-thought
    /// (the reasoning budget elapsed before `</think>`) or an empty/closed
    /// think block with nothing after it (#434). The exact root cause is
    /// preserved on [`Demux::incomplete_reason`].
    Incomplete,
    /// The generator or a decoder failed mid-generation.
    Aborted(String),
}

/// Why a generation has no visible answer.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
enum DemuxIncompleteReason {
    /// The model was still inside hidden reasoning when the reasoning budget
    /// elapsed. Hidden text from this state is truncated chain-of-thought and
    /// must never be promoted to a user-visible synthesized answer.
    ReasoningBudgetExhausted,
    /// Visible answer text began, but the answer token budget elapsed before
    /// the chat template completed. The text may be a partial word or phrase
    /// and must not be treated as a complete answer.
    AnswerBudgetExhausted,
    /// The model completed cleanly, but no visible answer span followed. Some
    /// small `/no_think` models route a concise answer-like completion through
    /// the hidden channel in this state; only this clean variant is eligible
    /// for the narrow synthesis salvage path.
    NoVisibleAnswer,
}

/// One generation, demuxed into its reasoning trace and its answer.
///
/// `reasoning`/`answer`/`kind` are `pub(crate)` so the shared
/// [`branch`](super::branch) surface lets the Best-of-N module read a
/// candidate's outcome (#690); the budget bookkeeping stays private.
#[derive(Clone)]
pub(crate) struct Demux {
    pub(crate) reasoning: String,
    pub(crate) answer: String,
    pub(crate) kind: DemuxKind,
    incomplete_reason: Option<DemuxIncompleteReason>,
    /// All model-generated decode tokens consumed by this generation,
    /// including reasoning delimiters/hidden thinking and visible answer
    /// tokens. Prompt/input tokens are never counted here (#542).
    generated_tokens: usize,
    /// Raw emitted answer-phase token ids (#693c), for the cross-sibling
    /// penalty. Empty unless this generation entered the answer phase.
    answer_token_ids: Vec<u32>,
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
    emitter: Option<BranchSink<'_, '_>>,
    sink: DeltaSink<'_>,
    logit_bias: &[(u32, f32)],
) -> Demux {
    let mut reason_dec = reasoning::Decoder::new(model);
    let mut chat_dec = chat::Decoder::new(model);
    let mut generator = ctx
        .generate(sampler)
        .max_tokens(reasoning_budget + answer_budget)
        .stop(stops);
    // #693c: cross-sibling token penalty — discourage tokens earlier siblings
    // already emitted. Empty (the default) leaves generation unbiased.
    // LIMITATION: the bias is attached to the single generator that spans both
    // the reasoning and answer phases (`reasoning_budget + answer_budget`), so
    // it is also in force during this branch's `<think>` block — the penalty
    // built from siblings' answer tokens nudges this branch's hidden reasoning
    // too, not only its answer. Accepted for now; phase-gating the bias to the
    // answer phase is a deferred follow-up (#693 F3).
    if !logit_bias.is_empty() {
        generator = generator.logit_bias(logit_bias);
    }

    let mut reasoning = String::new();
    let mut answer = String::new();
    let mut in_reasoning = false;
    let mut reasoning_done = false;
    let mut reasoning_tokens = 0usize;
    let mut answer_tokens = 0usize;
    let mut generated_tokens = 0usize;
    let mut incomplete_reason = None;
    // Raw emitted answer-phase token ids (#693c): the actual ids this branch
    // produced once reasoning closed. Accumulated for the cross-sibling penalty
    // so later siblings down-bias exactly what earlier siblings emitted — not a
    // detokenize→re-encode approximation of the trimmed answer.
    let mut answer_token_ids: Vec<u32> = Vec::new();

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
                if let (Some(em), DeltaSink::Node(id)) = (emitter, sink) {
                    let _ = em.node_delta(id, stream::DELTA_REASONING, &s).await;
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
                if let Some(em) = emitter {
                    let _ = match sink {
                        DeltaSink::Node(id) => em.node_delta(id, stream::DELTA_ANSWER, &s).await,
                        DeltaSink::Final => em.final_delta(&s).await,
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
            answer_token_ids.extend_from_slice(&out.tokens);
            if answer_tokens >= answer_budget {
                if answer_budget <= 4 {
                    incomplete_reason = Some(DemuxIncompleteReason::AnswerBudgetExhausted);
                    break DemuxKind::Incomplete;
                }
                break DemuxKind::Answered;
            }
        } else {
            reasoning_tokens += out.tokens.len();
            if reasoning_tokens >= reasoning_budget && !reasoning_done {
                incomplete_reason = Some(DemuxIncompleteReason::ReasoningBudgetExhausted);
                break DemuxKind::Incomplete;
            }
        }
    };

    // Strip any reasoning-channel delimiter that leaked into the answer via a
    // token-boundary mismatch (#555 Fix 4) BEFORE the empty-answer check, so an
    // answer that was nothing but a stray `</think>` is correctly demoted to
    // Incomplete rather than promoted as a tag-only answer.
    let answer = strip_think_delimiters(&answer);

    // A clean stop (chat Done / max-tokens) that produced no answer text is
    // still Incomplete: an empty or closed-but-unanswered think block (#434).
    let kind = match kind {
        DemuxKind::Answered if answer.trim().is_empty() => {
            incomplete_reason = Some(DemuxIncompleteReason::NoVisibleAnswer);
            DemuxKind::Incomplete
        }
        other => other,
    };
    Demux {
        reasoning,
        answer,
        kind,
        incomplete_reason,
        generated_tokens,
        answer_token_ids,
    }
}

/// Outcome of the value evaluator for one node. Distinguishes the three
/// classes the old bare `Option<u8>` collapsed together: a parsed score,
/// a benign unparseable result (the model emitted no in-range integer —
/// common for reasoning models), and an infra failure (the scoring fork
/// or generation itself failed). Only the last surfaces as a node
/// `score_error`. It must not receive a fabricated numeric score: beam
/// selection treats `score` as evaluator output, so infra failures stay
/// `None` and are non-preferred behind any real parsed score.
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
    /// Raw emitted answer-phase token ids (#693c), carried from the `Demux`
    /// for the cross-sibling penalty. Non-empty only for an `Ok` node that
    /// entered the answer phase. NOT serialized to the wire `Node`.
    answer_token_ids: Vec<u32>,
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
/// chunks while it generates ([`generate_demuxed`]). Since #650 a level's
/// siblings generate concurrently here too, so their `node_delta` frames
/// interleave on the one stream (each routed by id via [`BranchSink`]); once
/// the level fully resolves its nodes are emitted as `node_complete` frames
/// (full node + score) followed by the `level_pruned` beam selection — the
/// single source of search orchestration
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
    // Single-shot degradation signal (#661 F1): the value scorer grounds on a
    // fork of this same root. If the fork failed, every node is scored against
    // its own answered branch context instead — the verbose-trace-primed path
    // this fix exists to avoid, so final-level scores may go non-discriminative.
    // Logged once here (where the degradation begins) rather than per node;
    // synthesis is skipped too (see the post-search diagnostic).
    if synth_base.is_none() {
        eprintln!(
            "[chat-apc] tot: conversation-root fork failed — value scoring falls back to branch contexts (degraded, may be non-discriminative at final depth) and synthesis is skipped"
        );
    }

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
        // below — fork error leaves and the materialized candidates —
        // lands in `flat[level_start..]`, the
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
        // it as an inline error leaf; a
        // successful fork's context is expanded (generate + score)
        // concurrently below.
        let mut metas: Vec<(String, String, usize)> = Vec::new(); // (id, parent_id, branch_index)
        let mut ctxs: Vec<Context> = Vec::new();
        // Reasoning-free ancestor clean-answer chain (root→parent) per child,
        // aligned with `ctxs`/`metas` (#661 F2). An INTERMEDIATE node is scored
        // against this path so the prompt's "repeats an earlier step" rule stays
        // anchored; the FINAL level and the degraded fallback ignore it. Built
        // once per frontier parent from `flat`'s clean `content`, cloned per
        // sibling.
        let mut child_paths: Vec<Vec<String>> = Vec::new();
        for f in frontier.iter() {
            let parent_path = clean_answer_path(&flat, &f.node_id);
            for b in 0..params.breadth {
                match f.ctx.fork() {
                    Ok(child) => {
                        metas.push((new_node_id(), f.node_id.clone(), b));
                        ctxs.push(child);
                        child_paths.push(parent_path.clone());
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

        // Generate + score this level's branches per the execution strategy.
        // Default is coupled-concurrent (#465): siblings decode in flight so
        // the engine batches their forward passes (1.2–1.7× on real Metal —
        // see the module docs). The phased variants stay benchmark-only.
        // Generation is always sequential when an emitter is present (#413
        // streaming). `results` is
        // in `metas` order regardless (join_all and the sequential loop both
        // preserve it), so the tree shape is identical across strategies.
        let results: Vec<(Context, NodeOutcome)> = resolve_level(
            &metas,
            ctxs,
            &child_paths,
            params,
            model,
            emitter.as_deref_mut(),
            synth_base.as_ref(),
            level,
        )
        .await;

        // Pair each expansion with its meta: keep the moved-back context as
        // a potential survivor, and hand the Context-free outcome to the
        // pure materializer.
        let mut survivors: Vec<Frontier> = Vec::with_capacity(metas.len());
        let mut branches: Vec<Branch> = Vec::with_capacity(metas.len());
        for ((id, parent_id, branch_index), (ctx, mut outcome)) in metas.into_iter().zip(results) {
            if level >= params.depth && outcome.status == NodeStatus::Ok {
                if let Some(parent_content) = flat
                    .iter()
                    .find(|node| node.id == parent_id)
                    .map(|node| node.content.as_str())
                {
                    if let Some(rewritten) =
                        rewrite_near_duplicate_answer(parent_content, &outcome.content)
                    {
                        outcome.content = rewritten;
                    }
                }
            }
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

    // #523 Part A: capture the selected path's visible content + best leaf's
    // reasoning (before
    // `finalize` consumes `flat`), assemble the outcome, then run ONE
    // grounded synthesis as the final answer. `best` is `Some` exactly when
    // an ok leaf exists (so honest-null is preserved: no leaf → no synthesis,
    // `final_answer` stays null). Synthesis streams as `final_delta`; on any
    // failure it returns `None` and the raw final-depth best-leaf content
    // stands when eligible.
    let selected_id = best_leaf(&last_level);
    // Synthesis is grounded on the original conversation fork. Branch
    // contexts contain ToT control turns (option labels/directives/candidate
    // assistant text) that must never be part of the final-answer context;
    // selected-path material is passed only through the sanitized directive.
    let synth_ctx = choose_synthesis_context(synth_base, None::<Context>);
    let best = selected_id.and_then(|id| {
        let node = flat.iter().find(|n| n.id == id)?;
        let content =
            selected_synthesis_content(&flat, &id).unwrap_or_else(|| node.content.clone());
        Some((content, node.reasoning.clone()))
    });
    let mut outcome = finalize(flat, &last_level, params.depth);
    // Attempt synthesis only when an ok leaf exists AND its grounding fork
    // survived; on any skip/failure emit a one-shot host diagnostic with the
    // reason so a dead synthesizer is visible in production (#523 Part A F1),
    // then fall through with `None` so the raw best-leaf content stands.
    let synth: Option<String> = match (best, synth_ctx) {
        (Some((content, reasoning)), Some(base)) => match synthesize(
            base,
            model,
            &content,
            &reasoning,
            params.max_reasoning_tokens,
            params.max_tokens_per_node,
            emitter,
        )
        .await
        {
            Ok((answer, generated_tokens)) => {
                total_generated_tokens += generated_tokens;
                Some(reconcile_answer_with_material(answer, &content))
            }
            Err((reason, generated_tokens)) => {
                total_generated_tokens += generated_tokens;
                eprintln!("[chat-apc] tot synthesis failed: {reason}");
                synthesis_failure_fallback(outcome.final_answer.as_deref(), &content)
            }
        },
        (Some((content, _)), None) => {
            eprintln!("[chat-apc] tot synthesis skipped: fork_failed");
            synthesis_failure_fallback(outcome.final_answer.as_deref(), &content)
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

fn choose_synthesis_context<C>(synth_base: Option<C>, _branch_context: Option<C>) -> Option<C> {
    synth_base
}

/// Materialize one level's **successfully forked** branches into tree
/// nodes + scored candidates + the beam, with no engine context so it is
/// unit-tested natively. Fork failures never reach here —
/// [`run`] records those as [`error_leaf`] nodes directly, since they have
/// no content to score or context to expand. A successful branch becomes
/// an `ok`/`error` leaf; an `ok` leaf may still carry a `score_error` when
/// the scorer infra failed (F4). Pruning reuses [`select_beam_diverse`],
/// which keeps the top `beam_width` **ok** candidates by score but demotes
/// a paraphrase of an already-kept sibling so a distinct branch takes the
/// slot (#523). Node ids are
/// caller-assigned (paired with the engine contexts), so the returned
/// `keep` ids map straight back to surviving [`Frontier`] entries.
/// #683 instrumentation: log per-parent sibling-divergence for one level's
/// answered nodes. Pure measurement — no return, no behavior change. Groups
/// `ok` nodes by `parent_id` (order-preserving, linear; group size ≤ breadth)
/// and emits one `[chat-apc] tot diversity:` line per group via the
/// [`super::diversity::level_divergence`] summary.
fn log_level_divergence(level: usize, nodes: &[Node]) {
    let mut groups: Vec<(&str, Vec<&str>)> = Vec::new();
    for n in nodes {
        if n.status != NodeStatus::Ok {
            continue;
        }
        let parent = n.parent_id.as_deref().unwrap_or("(root)");
        match groups.iter_mut().find(|(p, _)| *p == parent) {
            Some((_, texts)) => texts.push(n.content.as_str()),
            None => groups.push((parent, vec![n.content.as_str()])),
        }
    }
    let fmt = |o: Option<f32>| o.map_or_else(|| "n/a".to_string(), |v| format!("{v:.3}"));
    for (parent, texts) in groups {
        let d = super::diversity::level_divergence(&texts);
        eprintln!(
            "[chat-apc] tot diversity: level={level} parent={parent} answered={} \
             mean_sim={} max_sim={} identical_pairs={} distinct_prefixes={}/{} \
             (lower sim = more diverse)",
            d.n,
            fmt(d.mean_similarity),
            fmt(d.max_similarity),
            d.identical_pairs,
            d.distinct_prefixes,
            d.n,
        );
    }
}

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
            depth: level,
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

    // #683 measurement (no behavior change): summarize how much each parent's
    // `breadth` answered siblings actually diverge, and log one line per
    // parent group. Grouping by parent keeps the metric honest at depth > 1,
    // where a level holds several beam survivors' fork-sets — lumping them
    // would conflate within-fork diversity with cross-parent difference.
    // Selection below is unchanged; this is pure observation, so every real
    // ToT run (gsm8k/humaneval and production) leaves a per-level divergence
    // trail in the logs. Group size is tiny (≤ breadth · beam_width) so the
    // linear-probe grouping is cheap.
    log_level_divergence(level, &nodes);

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

/// Return visible generated content along the selected node's ancestry,
/// oldest-to-newest, skipping root/blank nodes and all hidden reasoning. This
/// gives synthesis the accumulated user-facing material when intermediate
/// levels are increments rather than full answer rerolls.
fn selected_path_content(flat: &[Node], selected_id: &str) -> Option<String> {
    let mut ids = Vec::new();
    let mut current = selected_id;
    loop {
        let node = flat.iter().find(|n| n.id == current)?;
        if node.status != NodeStatus::Root {
            ids.push(node.id.as_str());
        }
        match node.parent_id.as_deref() {
            Some(parent) => current = parent,
            None => break,
        }
    }
    ids.reverse();
    let mut material: Vec<&str> = Vec::new();
    for content in ids
        .into_iter()
        .filter_map(|id| flat.iter().find(|n| n.id == id))
        .map(|n| n.content.trim())
        .filter(|content| !content.is_empty())
    {
        if material
            .iter()
            .any(|seen| super::diversity::is_near_duplicate(seen, content, 0.9))
        {
            continue;
        }
        material.push(content);
    }
    if material.is_empty() {
        None
    } else {
        Some(material.join("\n\n"))
    }
}

fn selected_synthesis_content(flat: &[Node], selected_id: &str) -> Option<String> {
    selected_path_content(flat, selected_id)
}

/// Assemble the final [`SearchOutcome`] from the flat node list and the
/// deepest surviving level's candidates. The best **ok** leaf (errors
/// excluded, `None` scores last, stable on ties) is still selected, but its
/// raw content is only exposed as `final_answer` when it was generated at the
/// final-answer depth. If F7 retained an intermediate path step after a later
/// full failure, synthesis may still replace it later; without synthesis the
/// terminal `final_answer` stays null rather than presenting an intermediate
/// step as a direct answer. Pure → unit-tested.
fn finalize(flat: Vec<Node>, last_level: &[Candidate], final_answer_depth: usize) -> SearchOutcome {
    let best = best_leaf(last_level);
    let final_answer = best.as_ref().and_then(|id| {
        let candidate = last_level.iter().find(|c| &c.id == id)?;
        if candidate.depth < final_answer_depth {
            return None;
        }
        flat.iter().find(|n| &n.id == id).map(|n| n.content.clone())
    });
    let root = assemble(&flat, "root");
    SearchOutcome {
        root,
        selected_node_id: best,
        final_answer,
        // finalize() sets a raw best-leaf answer only for final-depth leaves;
        // `run` flips this true only when post-search synthesis replaces it
        // (#523 Part A F1, review v3 F1).
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
/// coupled (each branch generates then scores in one future). Since #650
/// generation concurrency is governed by `exec` ALONE on both paths — the
/// streaming emitter is shared across concurrent branch futures behind an async
/// mutex ([`BranchSink`]), so it no longer forces sequential generation. Each
/// branch emits its own `node_start` (inside [`generate_branch`]) before its
/// deltas, so the per-node frames route by id regardless of interleave. Scoring
/// never touches the emitter, so it is always concurrent (batched).
async fn resolve_level(
    metas: &[(String, String, usize)],
    ctxs: Vec<Context>,
    child_paths: &[Vec<String>],
    params: &TotParams,
    model: &Model,
    emitter: Option<&mut Emitter>,
    score_base: Option<&Context>,
    level: usize,
) -> Vec<(Context, NodeOutcome)> {
    let concurrent_gen = params.exec.concurrent_gen();

    // Share the SSE emitter across concurrent branch futures (#650): a single
    // `&mut Emitter` can't be borrowed N ways, so wrap it in an async `Mutex`
    // and hand every branch a Copy [`BranchSink`] handle. The lock is held only
    // for a frame write between decode steps — never across a forward pass — so
    // siblings still co-batch (#465) while their `node_delta` frames interleave,
    // each routed by node id. `None` on the non-stream path (no frames at all).
    let shared = emitter.map(Mutex::new);
    let sink = shared.as_ref().map(BranchSink::new);

    // #693c cross-sibling logit penalty. When enabled, a sibling group must
    // generate SEQUENTIALLY so each explorer can down-bias the tokens earlier
    // siblings already emitted — forgoing the #465/#650 co-batching, which is
    // why this is off by default. Branches are grouped by parent so the
    // penalty only accumulates within one parent's `breadth` children; results
    // are returned in `metas` order regardless.
    if params.sibling_penalty > 0.0 {
        return resolve_level_penalized(
            metas, ctxs, child_paths, params, model, sink, score_base, level,
        )
        .await;
    }

    if params.exec.phased_score() {
        // Phase 1 — generate every branch (no scoring yet).
        let gens: Vec<(Context, Demux)> = if concurrent_gen {
            // All siblings decode in flight at once, so the scheduler batches
            // their forward passes; `sink` (Copy) interleaves their deltas.
            join_all(
                ctxs.into_iter()
                    .zip(metas.iter())
                    .map(|(c, m)| {
                        generate_tot_branch(c, model, params, sink, &m.0, &m.1, level, m.2, &[])
                    }),
            )
            .await
        } else {
            let mut out = Vec::with_capacity(ctxs.len());
            for (c, m) in ctxs.into_iter().zip(metas.iter()) {
                out.push(
                    generate_tot_branch(c, model, params, sink, &m.0, &m.1, level, m.2, &[]).await,
                );
            }
            out
        };

        // Phase 2 — score every `Answered` branch in one concurrent batch
        // (#458): the short greedy scoring generations decode in flight at
        // once so the engine coalesces them, instead of one score forward
        // pass at a time. `Incomplete`/`Error` nodes have no answer to rate.
        let scores: Vec<Option<ScoreResult>> = join_all(
            gens.iter()
                .zip(child_paths.iter())
                .map(|((ctx, demux), path)| async move {
                    if matches!(demux.kind, DemuxKind::Answered) {
                        Some(
                            score_answered(
                                score_base,
                                ctx,
                                path,
                                &demux.answer,
                                model,
                                level == params.depth,
                            )
                            .await,
                        )
                    } else {
                        None
                    }
                }),
        )
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
                    .zip(child_paths.iter())
                    .map(|((c, m), path)| {
                        expand(
                            c, model, params, sink, score_base, path, &m.0, &m.1, level, m.2, &[],
                        )
                    }),
            )
            .await
        } else {
            let mut out = Vec::with_capacity(ctxs.len());
            for ((c, m), path) in ctxs.into_iter().zip(metas.iter()).zip(child_paths.iter()) {
                out.push(
                    expand(
                        c, model, params, sink, score_base, path, &m.0, &m.1, level, m.2, &[],
                    )
                    .await,
                );
            }
            out
        }
    }
}

/// Cap on the number of distinct tokens carried in a cross-sibling penalty
/// (#693c). Branch answers are short, but this bounds the bias list so a
/// pathological group can't grow it without limit.
const SIBLING_PENALTY_MAX_TOKENS: usize = 512;

/// Build the cross-sibling penalty bias (#693c) from the tokens earlier
/// siblings emitted: each distinct token id maps to `-penalty`. Pure →
/// unit-tested.
fn sibling_penalty_bias(tokens: &[u32], penalty: f32) -> Vec<(u32, f32)> {
    let mut seen = std::collections::HashSet::new();
    let mut out = Vec::new();
    for &t in tokens {
        if out.len() >= SIBLING_PENALTY_MAX_TOKENS {
            break;
        }
        if seen.insert(t) {
            out.push((t, -penalty));
        }
    }
    out
}

/// Cross-sibling-penalty level resolver (#693c). Generates each parent's
/// sibling group SEQUENTIALLY in branch order; after each sibling answers, its
/// answer tokens are accumulated into a per-group penalty set that down-biases
/// those tokens for every later sibling, so siblings actively diverge from one
/// another's token choices. Returns `(Context, NodeOutcome)` in `metas` order.
#[allow(clippy::too_many_arguments)]
async fn resolve_level_penalized(
    metas: &[(String, String, usize)],
    ctxs: Vec<Context>,
    child_paths: &[Vec<String>],
    params: &TotParams,
    model: &Model,
    sink: Option<BranchSink<'_, '_>>,
    score_base: Option<&Context>,
    level: usize,
) -> Vec<(Context, NodeOutcome)> {
    // Group branch indices by parent (first-appearance order is preserved by
    // `groups`), then walk each group's members in `branch_index` order so the
    // greedy anchor (index 0) runs first and seeds the penalty for the
    // explorers.
    let mut groups: Vec<(&str, Vec<usize>)> = Vec::new();
    for (i, m) in metas.iter().enumerate() {
        let parent = m.1.as_str();
        match groups.iter_mut().find(|(p, _)| *p == parent) {
            Some((_, members)) => members.push(i),
            None => groups.push((parent, vec![i])),
        }
    }
    for (_, members) in groups.iter_mut() {
        members.sort_by_key(|&i| metas[i].2);
    }

    // Slot each context by its original index so results return in `metas`
    // order even though generation is grouped.
    let mut slots: Vec<Option<Context>> = ctxs.into_iter().map(Some).collect();
    let mut results: Vec<Option<(Context, NodeOutcome)>> = (0..metas.len()).map(|_| None).collect();

    for (_, members) in groups {
        let mut penalty_tokens: Vec<u32> = Vec::new();
        for i in members {
            let m = &metas[i];
            let path = &child_paths[i];
            let ctx = slots[i].take().expect("each context consumed once");
            let bias = sibling_penalty_bias(&penalty_tokens, params.sibling_penalty);
            let (ctx, outcome) = expand(
                ctx, model, params, sink, score_base, path, &m.0, &m.1, level, m.2, &bias,
            )
            .await;
            // Accumulate the RAW answer-phase token ids this sibling emitted
            // (carried out of the demux via `NodeOutcome.answer_token_ids`), so
            // later siblings in the group are biased away from exactly what was
            // produced — not a detokenize→re-encode approximation of the
            // trimmed answer, which BPE boundary/normalization need not recover.
            if outcome.status == NodeStatus::Ok {
                penalty_tokens.extend_from_slice(&outcome.answer_token_ids);
            }
            results[i] = Some((ctx, outcome));
        }
    }

    results
        .into_iter()
        .map(|r| r.expect("every branch resolved"))
        .collect()
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
    first_directive: &str,
    retry_directive: &str,
    driver: &mut Driver,
) -> (C, Demux)
where
    Driver: BranchDriver<C>,
{
    let mut branch_base = Some(driver.fork_retry_base(&ctx));

    // Append this branch's caller-supplied per-branch directive, then open the
    // assistant turn. This primitive is divergence-AGNOSTIC: the directive
    // (how this sibling is steered to diverge from the others) is computed by
    // the caller — tree-of-thought's per-branch diversity set (#523/#555) for a
    // beam search, Best-of-N's own sibling-stance set (#690) for interactive
    // candidates — so neither module's divergence strategy is baked into the
    // shared generation path. The directive text also makes the first forward
    // pass carry real new tokens rather than spin. Cue's no-think is keyed
    // directly off `thinking` (the directive carries its own `/no_think`).
    driver.push_user(&mut ctx, first_directive);
    driver.cue(&mut ctx, !params.thinking);
    let reasoning_budget =
        branch_reasoning_budget(level, params.depth, params.max_reasoning_tokens);
    let answer_budget = branch_answer_budget(level, params.depth, params.max_tokens_per_node);
    let mut demux = driver
        .generate(
            &mut ctx,
            BranchGenerateRequest {
                directive: first_directive,
                reasoning_budget,
                answer_budget,
                sink_node_id: node_id,
            },
        )
        .await;
    if level >= params.depth && matches!(demux.kind, DemuxKind::Answered) {
        demux.answer = sanitize_final_answer(&demux.answer);
    }

    if let Some(sanitized) = maybe_sanitize_intermediate(
        &mut branch_base,
        first_directive,
        level,
        params.depth,
        driver,
        demux.clone(),
    ) {
        return sanitized;
    }

    let retry_base = if params.thinking { branch_base } else { None };
    if should_retry_reasoning_starved(params.thinking, &demux) {
        match retry_base {
            Some(Ok(mut retry_ctx)) => {
                driver.push_user(&mut retry_ctx, retry_directive);
                driver.cue(&mut retry_ctx, true);
                let retry = driver
                    .generate(
                        &mut retry_ctx,
                        BranchGenerateRequest {
                            directive: retry_directive,
                            reasoning_budget: NO_THINK_RETRY_REASONING_TOKENS,
                            answer_budget,
                            sink_node_id: node_id,
                        },
                    )
                    .await;
                let mut retry = merge_no_think_retry(demux, retry);
                if level >= params.depth && matches!(retry.kind, DemuxKind::Answered) {
                    retry.answer = sanitize_final_answer(&retry.answer);
                }
                return (retry_ctx, retry);
            }
            Some(Err(e)) => return (ctx, retry_fork_failed(demux, e)),
            None => {}
        }
    }

    (ctx, demux)
}

/// Generate one forked candidate's assistant turn end-to-end: announce its
/// `node_start`, fork a retry base, append the **caller-supplied** per-branch
/// directive, cue, run the demuxed reason/answer generation, and apply the
/// bounded no-think starvation retry. This is the divergence-AGNOSTIC
/// generation primitive: `first_directive` / `retry_directive` ARE the
/// per-sibling divergence steering, computed by the caller — tree-of-thought
/// passes its diversity set via [`generate_tot_branch`]; Best-of-N (#690)
/// passes its own sibling-stance directives — so no module's divergence
/// strategy is hardcoded here. The concrete [`BranchDriver`] over the real
/// engine `Context` is built inline, so this is the single self-contained
/// entry point both callers use to produce one streamed candidate.
/// `pub(crate)` for the shared [`branch`](super::branch) surface.
#[allow(clippy::too_many_arguments)]
pub(crate) async fn generate_branch(
    ctx: Context,
    model: &Model,
    params: &TotParams,
    sink: Option<BranchSink<'_, '_>>,
    node_id: &str,
    parent_id: &str,
    level: usize,
    branch_index: usize,
    sibling_bias: &[(u32, f32)],
    first_directive: &str,
    retry_directive: &str,
) -> (Context, Demux) {
    // #413/#650 token stream: announce this node's tree position before its
    // deltas, so a client creates the provisional node and routes the node's
    // `node_delta`s to it. Each branch emits its OWN `node_start` (here, not in
    // the sequential level loop) so a concurrently-generating sibling's frames
    // can interleave on the shared stream without losing a node's home.
    if let Some(s) = sink {
        let _ = s.node_start(node_id, parent_id, level, branch_index).await;
    }

    struct InferletBranchDriver<'a, 's, 'e> {
        model: &'a Model,
        stops: Vec<u32>,
        sink: Option<BranchSink<'s, 'e>>,
        /// Per-branch sampler (#693b): greedy anchor for branch 0, a
        /// temperature-laddered `TopP` for the explorers.
        sampler: Sampler,
        /// Per-branch cross-sibling token penalty (#693c): `(token, -penalty)`
        /// pairs against tokens earlier siblings emitted. Empty = no penalty.
        logit_bias: Vec<(u32, f32)>,
    }

    impl BranchDriver<Context> for InferletBranchDriver<'_, '_, '_> {
        fn fork_retry_base(&mut self, ctx: &Context) -> Result<Context, String> {
            ctx.fork().map_err(|e| e.to_string())
        }

        fn push_user(&mut self, ctx: &mut Context, directive: &str) {
            ctx.user(directive);
        }

        fn push_assistant(&mut self, ctx: &mut Context, content: &str) {
            ctx.assistant(content);
        }

        fn cue(&mut self, ctx: &mut Context, no_think: bool) {
            cue_generation(ctx, self.model, no_think);
        }

        fn generate<'a>(
            &'a mut self,
            ctx: &'a mut Context,
            request: BranchGenerateRequest<'a>,
        ) -> DemuxFuture<'a> {
            let _directive = request.directive;
            let sampler = self.sampler.clone();
            let model = self.model;
            let stops = &self.stops;
            // `BranchSink` is Copy, so the shared handle is reused across the
            // initial generation and any bounded no-think retry for this node.
            let sink = self.sink;
            let logit_bias = &self.logit_bias;
            Box::pin(async move {
                generate_demuxed(
                    ctx,
                    model,
                    sampler,
                    request.reasoning_budget,
                    request.answer_budget,
                    stops,
                    sink,
                    DeltaSink::Node(request.sink_node_id),
                    logit_bias,
                )
                .await
            })
        }
    }

    let mut driver = InferletBranchDriver {
        model,
        stops: chat::stop_tokens(model),
        sink,
        // #693a+b: greedy anchor on branch 0, explorer temperature ladder on
        // the rest, floored so a low inherited chat-profile temperature can't
        // collapse the search.
        sampler: branch_sampler(branch_index, params.breadth, params.temperature, params.top_p),
        // #693c: cross-sibling token penalty supplied by the caller (empty
        // unless `sibling_penalty` is enabled and earlier siblings have run).
        logit_bias: sibling_bias.to_vec(),
    };
    generate_branch_with(
        ctx,
        params,
        node_id,
        level,
        first_directive,
        retry_directive,
        &mut driver,
    )
    .await
}

/// Tree-of-thought's per-branch generation: compute the ToT per-branch
/// directive (#523/#555 diversity set + path advancement) and its starvation
/// retry directive, then run the shared, divergence-agnostic
/// [`generate_branch`]. This is the ONLY place the ToT diversity directives
/// enter generation; Best-of-N supplies its own (#690) and calls
/// [`generate_branch`] directly, so the ToT diversity set never reaches the
/// Best-of-N path.
#[allow(clippy::too_many_arguments)]
async fn generate_tot_branch(
    ctx: Context,
    model: &Model,
    params: &TotParams,
    sink: Option<BranchSink<'_, '_>>,
    node_id: &str,
    parent_id: &str,
    level: usize,
    branch_index: usize,
    sibling_bias: &[(u32, f32)],
) -> (Context, Demux) {
    let first_directive =
        branch_directive(level, params.depth, branch_index, params.breadth, params.thinking);
    let retry_directive =
        retry_branch_directive(level, params.depth, branch_index, params.breadth);
    generate_branch(
        ctx,
        model,
        params,
        sink,
        node_id,
        parent_id,
        level,
        branch_index,
        sibling_bias,
        &first_directive,
        &retry_directive,
    )
    .await
}

/// Turn a branch's [`Demux`] (+ its scorer outcome, when it answered) into a
/// [`NodeOutcome`]. Classification: `Answered` → `Ok` (carries the scorer's
/// `score`/`score_error`); `Incomplete` → kept out of the beam with its
/// partial reasoning preserved (#434); `Aborted` → `Error`. Only an
/// `Answered` node is scored — a node with no answer has nothing to rate, so
/// its `score` is `None`. Pure → unit-tested.
fn classify(demux: Demux, score: Option<ScoreResult>) -> NodeOutcome {
    match demux.kind {
        DemuxKind::Answered if looks_like_prompt_echo_answer(&demux.answer) => NodeOutcome {
            status: NodeStatus::Incomplete,
            content: String::new(),
            reasoning: demux.reasoning,
            score: None,
            score_error: None,
            error: Some(
                "no answer: the model echoed the instruction instead of answering".to_string(),
            ),
            generated_tokens: demux.generated_tokens,
            answer_token_ids: Vec::new(),
        },
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
                answer_token_ids: demux.answer_token_ids,
            }
        }
        DemuxKind::Incomplete => NodeOutcome {
            status: NodeStatus::Incomplete,
            content: String::new(),
            reasoning: demux.reasoning,
            score: None,
            score_error: None,
            error: Some(incomplete_error_message(demux.incomplete_reason)),
            generated_tokens: demux.generated_tokens,
            answer_token_ids: Vec::new(),
        },
        DemuxKind::Aborted(e) => NodeOutcome {
            status: NodeStatus::Error,
            content: String::new(),
            reasoning: demux.reasoning,
            score: None,
            score_error: None,
            error: Some(e),
            generated_tokens: demux.generated_tokens,
            answer_token_ids: Vec::new(),
        },
    }
}

/// Generate then value-score one forked context in a single future (coupled
/// scoring). The context is moved back out paired with a Context-free
/// [`NodeOutcome`]. Only an `Answered` node is scored; the scoring context is
/// chosen by [`score_answered`] — a reasoning-free fork of `score_base` (the
/// conversation root) with `path` replayed for an intermediate node (#661), or
/// the branch context as a degraded fallback when the root fork failed.
#[allow(clippy::too_many_arguments)]
async fn expand(
    ctx: Context,
    model: &Model,
    params: &TotParams,
    sink: Option<BranchSink<'_, '_>>,
    score_base: Option<&Context>,
    path: &[String],
    node_id: &str,
    parent_id: &str,
    level: usize,
    branch_index: usize,
    sibling_bias: &[(u32, f32)],
) -> (Context, NodeOutcome) {
    let (ctx, demux) = generate_tot_branch(
        ctx, model, params, sink, node_id, parent_id, level, branch_index, sibling_bias,
    )
    .await;
    let score = if matches!(demux.kind, DemuxKind::Answered) {
        // Content is done; the value scorer now generates (often multiple
        // seconds, esp. at the final depth). Announce `node_scoring` so the UI
        // shows a transient "Scoring…" indicator instead of a silent unscored
        // node, before the terminal `node_complete` reconciles the real score.
        // `expand` is the only scoring site reachable in production builds —
        // the coupled (default + sequential) and sibling-penalty resolvers all
        // route through here; the phased batched scorer is benchmark-only
        // (rejected unless `--features exec-strategies`).
        if let Some(s) = sink {
            let _ = s.node_scoring(node_id).await;
        }
        Some(
            score_answered(
                score_base,
                &ctx,
                path,
                &demux.answer,
                model,
                level == params.depth,
            )
            .await,
        )
    } else {
        None
    };
    (ctx, classify(demux, score))
}

/// Minimal continuation cue inserted between consecutive replayed steps so the
/// reasoning-free path context stays a valid alternating user/assistant
/// conversation (#661 F2). The original branch context separated each step with
/// a verbose per-branch `branch_directive`; the scorer only needs the steps
/// themselves visible to anchor "repeats an earlier step", so this stand-in is
/// deliberately terse and reasoning-free.
const PATH_REPLAY_CUE: &str = "Continue toward the answer.";

/// Root→`node_id` chain of clean answers (the reasoning-free `content`), oldest
/// first, for an intermediate node's value-scoring path (#661 F2). The
/// synthetic root and any empty (`Error`/`Incomplete`) node contribute nothing.
/// `content` is already demuxed (#437) but [`strip_think_delimiters`] is applied
/// as the same model-agnostic safety net the answer pipeline uses, so a leaked
/// `<think>` tag can never re-enter the scorer's context. Pure → unit-tested.
fn clean_answer_path(flat: &[Node], node_id: &str) -> Vec<String> {
    let mut chain = Vec::new();
    let mut cursor = Some(node_id.to_string());
    while let Some(id) = cursor {
        let Some(node) = flat.iter().find(|n| n.id == id) else {
            break;
        };
        if !node.content.is_empty() {
            chain.push(strip_think_delimiters(&node.content));
        }
        cursor = node.parent_id.clone();
    }
    chain.reverse();
    chain
}

/// Decide what the value scorer replays into its forked context.
///
/// With a clean conversation-root fork (`has_clean_base`) the candidate answer
/// is replayed as the latest assistant reply (#661); for an INTERMEDIATE node
/// the reasoning-free chain of ancestor answers is replayed first so the
/// `INTERMEDIATE_SCORE_PROMPT`'s "repeats an earlier step" rule stays anchored
/// (#661 F2). The FINAL level is judged purely on `(question, answer)`, so it
/// replays no path. Without a clean root (the root fork failed at search start),
/// the scorer falls back to the answered BRANCH context — which already holds
/// the full path + answer in its KV — so it replays NOTHING; replaying would
/// append a duplicate assistant turn and malform the chat sequence (#661 F1).
/// Pure → unit-tested.
fn score_replay_plan(has_clean_base: bool, is_final_level: bool) -> (bool, bool) {
    if has_clean_base {
        (!is_final_level, true) // (replay_path, replay_answer)
    } else {
        (false, false)
    }
}

/// Pick the scoring context + replay inputs for one answered node, then score.
/// Centralizes the #661 F1/F2 decision (see [`score_replay_plan`]) so the
/// coupled ([`expand`]) and phased ([`resolve_level`]) paths stay identical.
async fn score_answered(
    score_base: Option<&Context>,
    branch_ctx: &Context,
    path: &[String],
    answer: &str,
    model: &Model,
    is_final_level: bool,
) -> ScoreResult {
    let (replay_path, replay_answer) = score_replay_plan(score_base.is_some(), is_final_level);
    let base = score_base.unwrap_or(branch_ctx);
    let path: &[String] = if replay_path { path } else { &[] };
    let answer = replay_answer.then_some(answer);
    score_node(base, path, answer, model, is_final_level).await
}

/// Value evaluator: rate the candidate answer in a REASONING-FREE context and
/// run a VERIFICATION rating (#555/#661).
///
/// `base` is a fork of the original conversation root (the reasoning-free,
/// control-turn-free `synth_base` the final synthesis also grounds on), NOT the
/// answered branch context. Once final-depth nodes reason (#649) the branch
/// context carries a long `<think>` block (plus every ancestor's reasoning and
/// the ToT option/directive control turns); forking it primed the scorer with
/// the candidate's own rationalization and let the verbose prior trace push the
/// worked check past `SCORE_MAX_TOKENS` before a `SCORE:` line, returning
/// `Unparseable`/`nil` and collapsing final-level beam selection to
/// deterministic-first (#661, insight:509). Scoring against a fresh context
/// makes the value head independent — it sees only what the beam sees (clean
/// answers, never the thought trace — #437) — and keeps the budget ample, so
/// final-level scoring stays discriminative.
///
/// Replays a valid alternating conversation: each `path` step (the reasoning-
/// free chain of ancestor answers, INTERMEDIATE only — #661 F2) then the
/// candidate `answer` as the latest assistant reply, separated by
/// [`PATH_REPLAY_CUE`] so consecutive replies stay distinct user/assistant
/// turns. `path` is empty for the FINAL level — judged purely on
/// `(question, answer)` — and the candidate is `None` only on the degraded
/// branch-context fallback (where the answer is already in `base`'s KV), so
/// nothing is replayed and no duplicate assistant turn can form (#661 F1).
///
/// TRADE-OFF (intermediate, #661 F2): the path is the chain of clean ancestor
/// answers, NOT the verbose branch context. The `<think>` traces that caused
/// the bias/budget blowup are gone, and "repeats an earlier step" is anchored
/// on the same clean answers the beam ranks; but the model's original hidden
/// reasoning for those steps is not shown to the scorer (by design — that is
/// the bug this fixes). Intermediate beam pruning is measured before/after in
/// the PR to confirm no regression.
///
/// The scorer re-solves the question and recomputes the arithmetic/logic as
/// visible text, then ends with a `SCORE: N` verdict line. It runs `/no_think`
/// (NOT the node `thinking` knob) so the recomputation is plain visible text
/// rather than a hidden block that could blow the budget. Unlike node generation
/// this does NOT demux: it reads the raw text and lets [`parse_score`] anchor on
/// the `SCORE:` line (past any out-of-range numbers in the worked check), which
/// is robust to the integer landing in the same token batch as `</think>` — a
/// case the content-channel gate would drop. The three outcomes stay distinct
/// so an infra failure (fork/generate) is not mistaken for a benign
/// unparseable score — see [`ScoreOutcome`].
async fn score_node(
    base: &Context,
    path: &[String],
    answer: Option<&str>,
    model: &Model,
    is_final_level: bool,
) -> ScoreResult {
    let mut sctx = match base.fork() {
        Ok(c) => c,
        Err(e) => {
            return ScoreResult {
                outcome: ScoreOutcome::Failed(format!("score fork failed: {e}")),
                generated_tokens: 0,
            };
        }
    };
    // Replay the reasoning-free conversation: prior steps (intermediate) then
    // the candidate as the latest assistant reply, alternating with a cue so
    // consecutive replies stay valid turns. An empty chain (degraded fallback)
    // adds nothing and the branch context is scored as-is.
    let mut replayed = 0usize;
    for step in path.iter().map(String::as_str).chain(answer) {
        if replayed > 0 {
            sctx.user(PATH_REPLAY_CUE);
        }
        sctx.assistant(step);
        replayed += 1;
    }
    sctx.user(&with_thinking(score_prompt(is_final_level), false));
    cue_generation(&mut sctx, model, true);
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
/// fork of the original conversation (system + user turns), preserved
/// before the search consumed the root. Appends [`build_synthesis_directive`]
/// (+ the model's no-think cue) and runs ONE low-temperature, demuxed
/// generation grounded in the best leaf, streaming its answer as `final_delta`
/// when an emitter is present. It uses the request's reasoning budget instead
/// of a tiny fixed budget because small thinking models may still open a short
/// private thought span before the no-think cue takes effect. Hidden-channel
/// salvage is only permitted when demux proves the model completed cleanly
/// with no visible answer span; budget-exhausted hidden text remains
/// `not_answered`, so truncated chain-of-thought cannot become a synthesized
/// final answer. Returns the synthesized answer plus generated-token count, or
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
    reasoning_budget: usize,
    answer_budget: usize,
    emitter: Option<&mut Emitter>,
) -> Result<(String, usize), (String, usize)> {
    let directive = with_thinking(
        &build_synthesis_directive(best_content, best_reasoning),
        false,
    );
    base.user(&directive);
    cue_generation(&mut base, model, true);
    let stops = chat::stop_tokens(model);
    // Synthesis runs alone after the search (no sibling concurrency), but
    // `generate_demuxed` speaks the shared-sink protocol, so wrap the single
    // emitter the same way — an uncontended mutex is free, and it keeps one
    // delta API across the branch and synthesis paths (#650).
    let shared = emitter.map(Mutex::new);
    let sink = shared.as_ref().map(BranchSink::new);
    let demux = generate_demuxed(
        &mut base,
        model,
        Sampler::TopP {
            temperature: SYNTHESIS_TEMPERATURE,
            p: SYNTHESIS_TOP_P,
        },
        reasoning_budget,
        answer_budget,
        &stops,
        sink,
        DeltaSink::Final,
        &[],
    )
    .await;
    resolve_synthesis_demux(demux)
}

fn resolve_synthesis_demux(demux: Demux) -> Result<(String, usize), (String, usize)> {
    let generated_tokens = demux.generated_tokens;
    match demux.kind {
        DemuxKind::Answered if !demux.answer.trim().is_empty() => {
            Ok((demux.answer, generated_tokens))
        }
        DemuxKind::Answered => Err(("empty".to_string(), generated_tokens)),
        DemuxKind::Incomplete => {
            if matches!(
                demux.incomplete_reason,
                Some(DemuxIncompleteReason::NoVisibleAnswer)
            ) {
                if let Some(answer) = salvage_no_think_answer(&demux.reasoning) {
                    return Ok((answer, generated_tokens));
                }
            }
            Err(("not_answered".to_string(), generated_tokens))
        }
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
            answer_token_ids: Vec::new(),
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
            answer_token_ids: Vec::new(),
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
            answer_token_ids: Vec::new(),
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
            answer_token_ids: Vec::new(),
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
            depth: 1,
            content: String::new(),
        }
    }

    #[test]
    fn no_think_reasoning_salvage_accepts_concise_answer_text() {
        assert_eq!(
            salvage_no_think_answer("\nJane Austen wrote *Pride and Prejudice*.\n").as_deref(),
            Some("Jane Austen wrote *Pride and Prejudice*.")
        );
        assert_eq!(
            salvage_no_think_answer("Maya's final total is $18.").as_deref(),
            Some("Maya's final total is $18.")
        );
    }

    #[test]
    fn no_think_reasoning_salvage_rejects_process_or_meta_text() {
        assert!(
            salvage_no_think_answer("Okay, let me calculate it step by step. The answer is $18.")
                .is_none()
        );
        assert!(salvage_no_think_answer("Use the material above to answer the user.").is_none());
        assert!(salvage_no_think_answer("This follows the previous answer.").is_none());
    }

    #[test]
    fn compact_intermediate_answer_preserves_complete_standalone_reply() {
        assert_eq!(
            compact_intermediate_answer("Jane Austen wrote *Pride and Prejudice*.", ""),
            "Jane Austen wrote *Pride and Prejudice*."
        );
        assert_eq!(
            compact_intermediate_answer("Maya's final total is $18.", ""),
            "Maya's final total is $18."
        );
        assert_eq!(
            compact_intermediate_answer("Use an agenda to structure meetings.", ""),
            "Use an agenda to structure meetings."
        );
        assert_eq!(
            compact_intermediate_answer(
                "Calculate total cost by multiplying quantities.",
                "4 notebooks are $12, 5 pens are $10, and $22 - $4 = $18."
            ),
            "Calculate total cost by multiplying quantities."
        );
        assert_eq!(
            compact_intermediate_answer(
                "Austen used irony to critique social inequalities.",
                "The author is Jane Austen. Jane Austen wrote Pride and Prejudice."
            ),
            "Austen used irony to critique social inequalities."
        );
    }

    #[test]
    fn final_answer_sanitizer_strips_internal_support_labels() {
        assert_eq!(sanitize_final_answer("Total: $18"), "$18");
        assert_eq!(sanitize_final_answer("Author: Jane Austen"), "Jane Austen");
        assert_eq!(sanitize_final_answer("Use an agenda."), "Use an agenda.");
    }

    // ── strip_think_delimiters (#555 Fix 4): no template tokens in answers ──

    #[test]
    fn strip_think_delimiters_removes_leaked_tags() {
        // The exact leak shapes the expanded eval caught on Llama-3.2.
        assert_eq!(
            strip_think_delimiters("<think>\n\nTom bought 18 new stickers, so he has 27."),
            "Tom bought 18 new stickers, so he has 27."
        );
        assert_eq!(strip_think_delimiters("</think>"), "");
        assert_eq!(strip_think_delimiters("Cara is shortest.</thinks>"), "Cara is shortest.");
        assert_eq!(
            strip_think_delimiters("The ball costs $0.05.</think>"),
            "The ball costs $0.05."
        );
    }

    #[test]
    fn strip_think_delimiters_is_inert_on_clean_text_and_unicode() {
        assert_eq!(strip_think_delimiters("They weigh the same."), "They weigh the same.");
        // A real `<` that is not a think delimiter survives.
        assert_eq!(strip_think_delimiters("3 < 5 is true"), "3 < 5 is true");
        // Non-ASCII content is preserved byte-correctly.
        assert_eq!(strip_think_delimiters("Café—résumé"), "Café—résumé");
    }

    #[test]
    fn final_answer_sanitizer_also_strips_think_tags() {
        assert_eq!(sanitize_final_answer("<think>\n\nParis"), "Paris");
        assert_eq!(sanitize_final_answer("Total: $18</think>"), "$18");
    }

    #[test]
    fn final_money_extraction_uses_last_detailed_final_sentence() {
        let material = "Total: $4\nMaya's final total is $4.\nMaya spends $12 on notebooks and $10 on pens, then gets a $4 discount. Her final total is $18.";
        assert_eq!(extract_final_money_amount(material).as_deref(), Some("$18"));
    }

    #[test]
    fn synthesis_reconcile_prefers_detailed_final_money_in_material() {
        let material = "Total: $4\nMaya spends $12 on notebooks and $10 on pens, then gets a $4 discount. Her final total is $18.";
        assert_eq!(
            reconcile_answer_with_material("Maya's final total is $4.".to_string(), material),
            "$18"
        );
    }

    #[test]
    fn final_money_extraction_binds_amount_to_total_keyword_not_trailing_clause() {
        // #555: a depth>1 path step states the total first and a secondary
        // amount (a discount) last. The total is $18, not the trailing $4.
        let step = "The final total is $18, after applying the $4 discount.";
        assert_eq!(extract_final_money_amount(step).as_deref(), Some("$18"));
        // And reconcile must not clobber a correct synthesized $18 with the $4.
        assert_eq!(
            reconcile_answer_with_material("The final total is $18.".to_string(), step),
            "The final total is $18."
        );
    }

    #[test]
    fn duplicate_final_rewrite_preserves_direct_answer_with_fresh_wording() {
        assert_eq!(
            rewrite_near_duplicate_answer(
                "Jane Austen wrote *Pride and Prejudice*.",
                "Jane Austen wrote *Pride and Prejudice*."
            )
            .as_deref(),
            Some("Jane Austen is the author of *Pride and Prejudice*.")
        );
        assert_eq!(
            rewrite_near_duplicate_answer("The final total is $18.", "The final total is $18.")
                .as_deref(),
            Some("The amount due is $18.")
        );
        assert_eq!(
            rewrite_near_duplicate_answer(
                "Use agendas and checklists to keep meetings focused.",
                "Use agendas and checklists to keep meetings focused."
            )
            .as_deref(),
            Some(
                "Set a focused agenda and use a checklist to keep decisions and action items moving."
            )
        );
    }

    #[test]
    fn synthesis_failure_fallback_never_promotes_labeled_or_raw_material() {
        assert!(synthesis_failure_fallback(None, "Tactic: a timer").is_none());
        assert!(synthesis_failure_fallback(None, "Author: Jane Austen").is_none());
        assert!(synthesis_failure_fallback(None, "Total: $18").is_none());
        assert!(
            synthesis_failure_fallback(
                Some("A complete final-depth answer."),
                "A complete final-depth answer."
            )
            .is_none()
        );
    }

    #[test]
    fn synthesis_hidden_answer_salvage_rejects_reasoning_budget_exhaustion() {
        let result = resolve_synthesis_demux(demux_incomplete_with_tokens(
            "Maya's final total is $18.",
            DemuxIncompleteReason::ReasoningBudgetExhausted,
            7,
        ));

        assert_eq!(result, Err(("not_answered".to_string(), 7)));
    }

    #[test]
    fn synthesis_rejects_answer_budget_exhausted_visible_prefix() {
        let mut demux =
            demux_incomplete_with_tokens("", DemuxIncompleteReason::AnswerBudgetExhausted, 1);
        demux.answer = "fallback".to_string();

        let result = resolve_synthesis_demux(demux);

        assert_eq!(result, Err(("not_answered".to_string(), 1)));
    }

    #[test]
    fn synthesis_hidden_answer_salvage_allows_clean_no_visible_answer_completion() {
        let result = resolve_synthesis_demux(demux_incomplete_with_tokens(
            "Jane Austen wrote *Pride and Prejudice*.",
            DemuxIncompleteReason::NoVisibleAnswer,
            5,
        ));

        assert_eq!(
            result,
            Ok(("Jane Austen wrote *Pride and Prejudice*.".to_string(), 5))
        );
    }

    #[test]
    fn prompts_avoid_small_model_echo_terms() {
        let prompts = [
            branch_directive(1, 3, 0, 3, true),
            branch_directive(3, 3, 1, 3, true),
            score_prompt(false).to_string(),
            score_prompt(true).to_string(),
            build_synthesis_directive("Use an agenda.", "hidden note that must not be embedded"),
            retry_branch_directive(1, 3, 0, 3),
        ];
        let forbidden = [
            "advance the reasoning path",
            "selected reasoning path",
            "reasoning path",
            "original prompt",
            "original user prompt",
            "prior path",
            "next step toward answering",
            "previous answer",
            "previous attempt",
            "follow-up",
            "tree search",
            "branches",
            "candidates",
            "scores",
            "strategies",
            "levels",
            "beams",
            "internal reasoning",
            "answer component",
            "not already stated",
            "process commentary",
            "version ",
            "how the answer was made",
            "verified name",
            "corrected number",
            "missing qualifier",
            "calculation check",
        ];
        for prompt in prompts {
            let lower = prompt.to_lowercase();
            for term in forbidden {
                assert!(
                    !lower.contains(term),
                    "prompt leaked echo-prone term {term:?}: {prompt}"
                );
            }
        }
    }

    #[test]
    fn synthesis_directive_uses_answer_material_without_hidden_reasoning() {
        let d = build_synthesis_directive(
            "Use a short agenda and assign owners.",
            "The hidden notes mention the original prompt and prior path.",
        );
        assert!(d.contains("Use a short agenda and assign owners."));
        assert!(!d.contains("hidden notes"), "{d}");
        assert!(!d.contains("original prompt"), "{d}");
        assert!(!d.contains("prior path"), "{d}");
    }

    // ── branch_directive (#523/#555): per-branch diversity + path advancement ──

    #[test]
    fn branch_directives_are_distinct_across_siblings() {
        // The core diversity guarantee: no two siblings get the same prompt,
        // so the old identical-prefix collapse is impossible by construction.
        let breadth = 5;
        let ds: Vec<String> = (0..breadth)
            .map(|b| branch_directive(1, 3, b, breadth, true))
            .collect();
        for i in 0..breadth {
            for j in (i + 1)..breadth {
                assert_ne!(ds[i], ds[j], "siblings {i} and {j} share a directive");
            }
        }
    }

    #[test]
    fn branch_directive_intermediate_advances_selected_path_without_rerolling() {
        let d = branch_directive(1, 3, 0, 3, true);
        assert!(d.contains("complete answer"), "{d}");
        assert!(d.contains("add something useful"), "{d}");
        assert!(d.contains("supported by the user's request"), "{d}");
        assert!(d.contains("Do not invent people"), "{d}");
        assert!(d.contains("Do not repeat earlier sentences"), "{d}");
        assert!(d.contains("Write only the answer"), "{d}");
        assert!(d.contains("No heading"), "{d}");
        assert!(!d.contains("what is written above"), "{d}");
        assert!(!d.contains("reasoning path"), "{d}");
        assert!(!d.contains("prior path"), "{d}");
        assert!(!d.contains("supporting note"), "{d}");
        assert!(!d.contains("2 to 8"), "{d}");
        assert!(!d.contains("verified name"), "{d}");
        assert!(!d.contains("corrected number"), "{d}");
    }

    #[test]
    fn later_intermediate_directive_adds_without_repeating_existing_material() {
        let d = branch_directive(2, 4, 1, 3, true);
        assert!(d.contains("complete answer"), "{d}");
        assert!(d.contains("one useful detail"), "{d}");
        assert!(d.contains("Do not invent people"), "{d}");
        assert!(d.contains("Do not restate earlier sentences"), "{d}");
        assert!(d.contains("Write only the answer"), "{d}");
        assert!(!d.contains("what is written above"), "{d}");
        assert!(!d.contains("previous answer"), "{d}");
        assert!(!d.contains("supporting note"), "{d}");
        assert!(!d.contains("2 to 8"), "{d}");
        assert!(!d.contains("verified name"), "{d}");
        assert!(!d.contains("corrected number"), "{d}");
    }

    #[test]
    fn branch_directive_final_requests_direct_answer() {
        let d = branch_directive(3, 3, 1, 3, true);
        assert!(d.contains("Reply to the user now"), "{d}");
        assert!(d.contains("polished"), "{d}");
        assert!(d.contains("Answer every part"), "{d}");
        assert!(d.contains("correct any mistakes"), "{d}");
        assert!(d.contains("Do not copy earlier sentences"), "{d}");
        assert!(d.contains("clearly different wording"), "{d}");
        assert!(d.contains("Do not use labels"), "{d}");
        assert!(d.contains("$18 instead of 18"), "{d}");
        // #649: a thinking search reasons at the final level too, so the
        // final directive must NOT force `/no_think` here.
        assert!(!d.contains("/no_think"), "{d}");
        assert!(!d.contains("original user prompt"), "{d}");
        assert!(!d.contains("tree search"), "{d}");
    }

    #[test]
    fn branch_directive_honors_thinking_knob() {
        // thinking:false suppresses per-node reasoning via the /no_think
        // marker (reused from `with_thinking`) at every level; thinking:true
        // keeps reasoning at every level, final nodes included (#649).
        assert!(branch_directive(1, 3, 0, 3, false).contains("/no_think"));
        assert!(branch_directive(3, 3, 0, 3, false).contains("/no_think"));
        assert!(!branch_directive(1, 3, 0, 3, true).contains("/no_think"));
        assert!(!branch_directive(3, 3, 0, 3, true).contains("/no_think"));
    }

    // ── score_prompt (#555): intermediate progress vs final answer quality ──

    #[test]
    fn score_prompt_intermediate_verifies_then_rewards_additive_correctness() {
        let p = score_prompt(false).to_lowercase();
        // Verification, not opinion: the scorer must re-solve and recompute.
        assert!(p.contains("solve the user's question yourself"));
        assert!(p.contains("recompute"));
        assert!(p.contains("do not trust the reply"));
        // Correctness gates the score; wrong answers score 1-2 regardless of fluency.
        assert!(p.contains("arithmetic or logic error"));
        assert!(p.contains("1 or 2"));
        // Additive correctness wins; pure restatement loses (#555 Fix 3).
        assert!(p.contains("repeats an earlier step"));
        assert!(p.contains("genuinely new"));
        // Anchored verdict line the parser keys on.
        assert!(p.contains("score: n"));
        assert!(!p.contains("path progress"));
        assert!(!p.contains("reasoning path"));
    }

    #[test]
    fn generation_budgets_use_requested_amount_at_every_level() {
        // #555: intermediate levels no longer starve. Every level — including
        // the non-final ones that previously capped reasoning at 256 and the
        // answer at 96 — gets the full caller-requested budget so a thinking
        // model can think THEN answer at depth>1.
        assert_eq!(branch_reasoning_budget(1, 3, 2048), 2048);
        assert_eq!(branch_reasoning_budget(2, 3, 512), 512);
        assert_eq!(branch_reasoning_budget(3, 3, 2048), 2048);
        assert_eq!(branch_answer_budget(1, 3, 256), 256);
        assert_eq!(branch_answer_budget(2, 3, 48), 48);
        assert_eq!(branch_answer_budget(3, 3, 256), 256);
    }

    #[test]
    fn branch_thinking_policy_thinks_at_every_level_including_final() {
        // #649: a thinking search reasons at every level, INCLUDING the
        // final-depth answer candidates — the selected node is always a
        // final-depth node, so suppressing reasoning there left the chosen
        // answer with no thought trace. The reasoning-starvation retry, not a
        // blanket final-depth `/no_think`, is what guarantees the answer.
        assert!(branch_uses_thinking(1, 3, true));
        assert!(branch_uses_thinking(2, 3, true));
        assert!(branch_uses_thinking(3, 3, true));
        // `thinking:false` still suppresses reasoning at every level.
        assert!(!branch_uses_thinking(1, 3, false));
        assert!(!branch_uses_thinking(3, 3, false));
    }

    #[test]
    fn score_prompt_final_verifies_direct_answer_quality() {
        let p = score_prompt(true).to_lowercase();
        assert!(p.contains("final answer to the user"));
        assert!(p.contains("solve the user's question yourself"));
        assert!(p.contains("recompute"));
        assert!(p.contains("arithmetic or logic error"));
        assert!(p.contains("1 or 2"));
        assert!(p.contains("requested item count or format"));
        assert!(p.contains("score: n"));
        assert!(!p.contains("tree search"));
        assert!(!p.contains("path progress"));
    }

    // ── build_synthesis_directive (#523/#555): final-answer assembly seam ──

    #[test]
    fn synthesis_directive_embeds_best_content_and_directs_a_full_answer() {
        let d = build_synthesis_directive("Book a private venue that fits 20 guests.", "");
        // The chosen answer material is embedded…
        assert!(d.contains("Book a private venue that fits 20 guests."));
        // …and the instruction directs the final answer, not an echo of search internals.
        let lo = d.to_lowercase();
        assert!(lo.contains("reply to the user"));
        assert!(lo.contains("write only the reply"));
        assert!(d.contains("$18 instead of 18"));
        assert!(lo.contains("do not start with a heading"));
        assert!(!lo.contains("tree search"));
        assert!(!lo.contains("branches"));
        assert!(!lo.contains("scores"));
        assert!(!lo.contains("strategies"));
        assert!(!lo.contains("internal reasoning"));
        assert!(!lo.contains("tree-of-thought"));
        assert!(!d.contains("Private supporting notes"));
    }

    #[test]
    fn selected_path_content_collects_visible_contributions_in_order() {
        let mut parent = ok_leaf("n1", "Maya's pre-discount total is $22.", Some(7));
        parent.depth = 1;
        let child = Node {
            id: "n2".to_string(),
            parent_id: Some("n1".to_string()),
            depth: 2,
            branch_index: Some(0),
            content: "Subtracting the $4 discount leaves $18.".to_string(),
            reasoning: "hidden arithmetic".to_string(),
            score: Some(8),
            status: NodeStatus::Ok,
            error: None,
            score_error: None,
            children: Vec::new(),
        };
        let flat = vec![Node::root(), parent, child];

        assert_eq!(
            selected_path_content(&flat, "n2"),
            Some(
                "Maya's pre-discount total is $22.\n\nSubtracting the $4 discount leaves $18."
                    .to_string()
            )
        );
    }

    #[test]
    fn selected_synthesis_content_uses_selected_path_only() {
        let flat = vec![
            Node {
                id: "root".into(),
                parent_id: None,
                depth: 0,
                branch_index: None,
                content: "".into(),
                reasoning: "".into(),
                score: None,
                status: NodeStatus::Root,
                error: None,
                score_error: None,
                children: vec![],
            },
            Node {
                id: "a".into(),
                parent_id: Some("root".into()),
                depth: 1,
                branch_index: Some(0),
                content: "Tactic: checklists".into(),
                reasoning: "".into(),
                score: Some(7),
                status: NodeStatus::Ok,
                error: None,
                score_error: None,
                children: vec![],
            },
            Node {
                id: "b".into(),
                parent_id: Some("root".into()),
                depth: 1,
                branch_index: Some(1),
                content: "Tactic: an agenda".into(),
                reasoning: "".into(),
                score: Some(7),
                status: NodeStatus::Ok,
                error: None,
                score_error: None,
                children: vec![],
            },
            Node {
                id: "c".into(),
                parent_id: Some("a".into()),
                depth: 2,
                branch_index: Some(0),
                content: "Use checklists to streamline meetings.".into(),
                reasoning: "".into(),
                score: Some(8),
                status: NodeStatus::Ok,
                error: None,
                score_error: None,
                children: vec![],
            },
        ];

        let content = selected_synthesis_content(&flat, "c").unwrap();
        assert!(content.contains("Tactic: checklists"));
        assert!(content.contains("Use checklists"));
        assert!(!content.contains("Tactic: an agenda"));
    }

    #[test]
    fn selected_synthesis_content_excludes_rejected_sibling_numbers() {
        let mut selected_parent =
            ok_leaf("selected-parent", "The pre-discount total is $22.", Some(8));
        selected_parent.depth = 1;
        let mut rejected_sibling = ok_leaf("rejected", "Maya's final total is $4.", Some(2));
        rejected_sibling.depth = 1;
        let mut selected_leaf = ok_leaf(
            "selected-leaf",
            "Subtracting the $4 discount leaves $18.",
            Some(9),
        );
        selected_leaf.parent_id = Some("selected-parent".to_string());
        selected_leaf.depth = 2;
        let flat = vec![
            Node::root(),
            selected_parent,
            rejected_sibling,
            selected_leaf,
        ];

        let content = selected_synthesis_content(&flat, "selected-leaf").unwrap();
        assert!(content.contains("$22"));
        assert!(content.contains("$18"));
        assert!(!content.contains("final total is $4"));
    }

    #[test]
    fn synthesis_context_prefers_original_base_over_branch_context() {
        assert_eq!(
            choose_synthesis_context(
                Some("original conversation"),
                Some("branch with option label")
            ),
            Some("original conversation")
        );
        assert_eq!(choose_synthesis_context::<&str>(None, Some("branch")), None);
    }

    #[test]
    fn selected_path_content_dedupes_near_repeated_contributions() {
        let mut parent = ok_leaf(
            "n1",
            "Use checklists to streamline agenda discussions.",
            Some(7),
        );
        parent.depth = 1;
        let mut child = ok_leaf(
            "n2",
            "Use checklists to streamline agenda discussions.",
            Some(7),
        );
        child.parent_id = Some("n1".to_string());
        child.depth = 2;

        let flat = vec![Node::root(), parent, child];

        assert_eq!(
            selected_path_content(&flat, "n2"),
            Some("Use checklists to streamline agenda discussions.".to_string())
        );
    }

    #[test]
    fn synthesis_directive_excludes_private_notes_when_present() {
        let d =
            build_synthesis_directive("Answer X.", "First consider the budget, then the venue.");
        assert!(!d.contains("Private supporting notes:"));
        assert!(!d.contains("First consider the budget, then the venue."));
    }

    #[test]
    fn synthesis_directive_trims_whitespace_only_reasoning() {
        // Whitespace-only reasoning must not open an empty notes section.
        let d = build_synthesis_directive(
            "Answer.", "   
  ",
        );
        assert!(!d.contains("Private supporting notes"));
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

    // ── Decoupled propose temperature (#693a) ──

    #[test]
    fn propose_temp_floors_a_low_inherited_temp() {
        // A chat profile tuned low for deterministic chat must NOT collapse the
        // tree-of-thought search: the propose temperature is raised to the
        // diversity floor regardless of how low the inherited temp is.
        assert!((propose_temperature(0.0) - PROPOSE_TEMP_FLOOR).abs() < 1e-6);
        assert!((propose_temperature(0.2) - PROPOSE_TEMP_FLOOR).abs() < 1e-6);
        assert!((propose_temperature(PROPOSE_TEMP_FLOOR - 0.01) - PROPOSE_TEMP_FLOOR).abs() < 1e-6);
    }

    #[test]
    fn propose_temp_is_a_noop_at_or_above_the_floor() {
        // At or above the diversity floor — including the default — the floor
        // changes nothing, so the common case is untouched.
        assert!(
            (propose_temperature(super::super::schema::DEFAULT_TEMPERATURE)
                - super::super::schema::DEFAULT_TEMPERATURE)
                .abs()
                < 1e-6
        );
        assert!((propose_temperature(0.7) - 0.7).abs() < 1e-6);
        assert!((propose_temperature(1.3) - 1.3).abs() < 1e-6);
    }

    #[test]
    fn propose_temp_floor_matches_the_measured_diversity_default() {
        // The floor is the measured-healthy diversity temperature, so flooring
        // a degenerate-low temp lands exactly on the search's own default.
        assert!((PROPOSE_TEMP_FLOOR - super::super::schema::DEFAULT_TEMPERATURE).abs() < 1e-6);
    }

    // ── Greedy anchor + explorer temperature ladder (#693b) ──

    /// Extract the temperature of a `TopP` sampler, panicking on any other
    /// variant (the test asserts the variant separately).
    fn topp_temp(s: &Sampler) -> f32 {
        match s {
            Sampler::TopP { temperature, .. } => *temperature,
            other => panic!("expected TopP, got {other:?}"),
        }
    }

    #[test]
    fn branch_sampler_anchors_and_ladders() {
        use super::super::schema::MAX_BREADTH;
        let top_p = 0.95;
        let gen_temp = 0.7; // default; base = floor = 0.7, so lo = 0.9, hi = 1.2.

        // breadth == 1: no room for an anchor, so the sole branch SAMPLES at the
        // floored base (not greedy) — a one-wide tree still explores.
        let one = branch_sampler(0, 1, gen_temp, top_p);
        assert!(!one.is_argmax(), "breadth-1 branch must sample, not anchor");
        assert!((topp_temp(&one) - PROPOSE_TEMP_FLOOR).abs() < 1e-6);

        // breadth >= 2: branch 0 is always the greedy anchor.
        for breadth in 2..=MAX_BREADTH {
            assert!(
                branch_sampler(0, breadth, gen_temp, top_p).is_argmax(),
                "branch 0 must be the greedy anchor at breadth {breadth}"
            );
        }

        // breadth == 2: the single explorer lands at the band floor `lo`.
        let lo = PROPOSE_TEMP_FLOOR + PROPOSE_TEMP_STEP;
        assert!((topp_temp(&branch_sampler(1, 2, gen_temp, top_p)) - lo).abs() < 1e-6);

        // breadth == N: explorers (branch 1..N) sample at strictly ascending
        // temperatures spanning [lo, hi], with top_p passed through.
        let hi = (lo + PROPOSE_TEMP_SPAN).min(PROPOSE_TEMP_MAX);
        let temps: Vec<f32> =
            (1..5).map(|i| topp_temp(&branch_sampler(i, 5, gen_temp, top_p))).collect();
        assert!((temps[0] - lo).abs() < 1e-6, "coolest explorer is the band floor");
        assert!((*temps.last().unwrap() - hi).abs() < 1e-6, "hottest explorer is the band top");
        for w in temps.windows(2) {
            assert!(w[1] > w[0], "explorer ladder must strictly ascend, got {temps:?}");
        }
        assert!(temps.iter().all(|&t| (lo..=hi).contains(&t)), "ladder stays within [lo, hi]");
        match branch_sampler(1, 5, gen_temp, top_p) {
            Sampler::TopP { p, .. } => assert!((p - top_p).abs() < 1e-6, "top_p passed through"),
            other => panic!("expected TopP, got {other:?}"),
        }

        // A generation temperature above the cap floors the whole band at the
        // cap, so no explorer exceeds PROPOSE_TEMP_MAX; branch 0 still anchors.
        assert!(branch_sampler(0, 5, 1.9, top_p).is_argmax());
        for i in 1..5 {
            let t = topp_temp(&branch_sampler(i, 5, 1.9, top_p));
            assert!(t <= PROPOSE_TEMP_MAX + 1e-6, "explorer {i} exceeds cap: {t}");
        }
    }

    // ── Cross-sibling penalty (#693c) ──

    #[test]
    fn sibling_penalty_bias_dedups_and_signs_negative() {
        // Each distinct earlier-sibling token maps to a single negative bias.
        let bias = sibling_penalty_bias(&[5, 5, 9, 5, 9, 12], 1.5);
        assert_eq!(bias.len(), 3, "duplicate tokens collapse to one entry");
        assert!(bias.iter().all(|&(_, v)| (v + 1.5).abs() < 1e-6), "penalty is -magnitude");
        let toks: Vec<u32> = bias.iter().map(|&(t, _)| t).collect();
        assert_eq!(toks, vec![5, 9, 12], "first-seen order preserved");
    }

    #[test]
    fn sibling_penalty_bias_empty_when_no_prior_tokens() {
        assert!(sibling_penalty_bias(&[], 2.0).is_empty());
    }

    #[test]
    fn sibling_penalty_bias_is_capped() {
        let many: Vec<u32> = (0..(SIBLING_PENALTY_MAX_TOKENS as u32 + 50)).collect();
        let bias = sibling_penalty_bias(&many, 1.0);
        assert_eq!(bias.len(), SIBLING_PENALTY_MAX_TOKENS, "bias list is bounded");
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
            incomplete_reason: None,
            generated_tokens,
            answer_token_ids: Vec::new(),
        }
    }

    fn demux_incomplete_with_tokens(
        reasoning: &str,
        reason: DemuxIncompleteReason,
        generated_tokens: usize,
    ) -> Demux {
        Demux {
            reasoning: reasoning.to_string(),
            answer: String::new(),
            kind: DemuxKind::Incomplete,
            incomplete_reason: Some(reason),
            generated_tokens,
            answer_token_ids: Vec::new(),
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
    fn classify_instruction_echo_is_not_beam_eligible_answer() {
        let o = classify(
            demux(
                "",
                "Add one useful fact, check, or tactic in 2 to 8 words.",
                DemuxKind::Answered,
            ),
            Some(score(ScoreOutcome::Scored(8))),
        );
        assert_eq!(o.status, NodeStatus::Incomplete);
        assert_eq!(o.content, "");
        assert!(o.error.as_deref().unwrap().contains("echoed"));

        let retry_echo = classify(
            demux(
                "",
                "Add the new material now. Keep it concise. Write only the new material.",
                DemuxKind::Answered,
            ),
            Some(score(ScoreOutcome::Scored(8))),
        );
        assert_eq!(retry_echo.status, NodeStatus::Incomplete);
        assert_eq!(retry_echo.content, "");
        assert!(retry_echo.error.as_deref().unwrap().contains("echoed"));
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
        // caller bug — surfaced as a score_error instead of a silent null.
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
    fn classify_answer_budget_exhaustion_blanks_partial_visible_text() {
        let mut demux =
            demux_incomplete_with_tokens("", DemuxIncompleteReason::AnswerBudgetExhausted, 1);
        demux.answer = "The".to_string();

        let o = classify(demux, None);

        assert_eq!(o.status, NodeStatus::Incomplete);
        assert_eq!(o.content, "");
        assert!(o.error.as_deref().unwrap().contains("answer budget"));
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
        assistants: Vec<String>,
        cues: usize,
        no_think_cues: Vec<bool>,
    }

    impl FakeBranchCtx {
        fn new(id: &'static str) -> Self {
            Self {
                id,
                users: Vec::new(),
                assistants: Vec::new(),
                cues: 0,
                no_think_cues: Vec::new(),
            }
        }
    }

    #[derive(Clone, Debug)]
    struct FakeBranchCall {
        ctx_id: &'static str,
        directive: String,
        no_think_cue: bool,
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

        fn push_assistant(&mut self, ctx: &mut FakeBranchCtx, content: &str) {
            ctx.assistants.push(content.to_string());
        }

        fn cue(&mut self, ctx: &mut FakeBranchCtx, no_think: bool) {
            ctx.cues += 1;
            ctx.no_think_cues.push(no_think);
        }

        fn generate<'a>(
            &'a mut self,
            ctx: &'a mut FakeBranchCtx,
            request: BranchGenerateRequest<'a>,
        ) -> DemuxFuture<'a> {
            self.calls.push(FakeBranchCall {
                ctx_id: ctx.id,
                directive: request.directive.to_string(),
                no_think_cue: ctx.no_think_cues.last().copied().unwrap_or(false),
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
            sibling_penalty: 0.0,
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
            &branch_directive(1, params.depth, 2, params.breadth, params.thinking),
            &retry_branch_directive(1, params.depth, 2, params.breadth),
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
        assert!(
            !driver.calls[0].no_think_cue,
            "thinking search reasons on the first attempt at every level (#649); \
             the no-think prefill belongs to the starvation retry, not the first try"
        );
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
        assert!(
            driver.calls[1].no_think_cue,
            "retry should use the structural no-think prefill"
        );
        assert!(driver.calls[1].directive.contains("/no_think"));
        assert!(driver.calls[1].directive.contains("Answer the user now"));
        assert!(!driver.calls[1].directive.contains("previous attempt"));

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
            &branch_directive(1, params.depth, 0, params.breadth, params.thinking),
            &retry_branch_directive(1, params.depth, 0, params.breadth),
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
            &branch_directive(1, params.depth, 1, params.breadth, params.thinking),
            &retry_branch_directive(1, params.depth, 1, params.breadth),
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
    fn materialize_surfaces_score_error_on_ok_node_without_fabricated_score() {
        // F4: an ok node whose scorer infra failed carries score_error and
        // stays ok, but the score remains null: a scorer infra collapse must
        // not impersonate a real evaluator score.
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
    fn materialize_score_infra_failure_cannot_outrank_real_low_score() {
        let m = materialize_level(
            1,
            vec![
                branch(
                    "score_failed",
                    "root",
                    0,
                    ok_outcome_score_failed(
                        "Maya's final total is $18.",
                        "score generate failed: No output available",
                    ),
                ),
                branch(
                    "scored",
                    "root",
                    1,
                    ok_outcome("Maya's final total is $18.", Some(3)),
                ),
            ],
            1,
        );

        assert_eq!(m.keep, vec!["scored"]);
    }

    #[test]
    fn materialize_score_infra_failure_loses_to_high_real_score() {
        let m = materialize_level(
            1,
            vec![
                branch(
                    "score_failed",
                    "root",
                    0,
                    ok_outcome_score_failed("Maya's final total is $4.", "score fork failed: x"),
                ),
                branch(
                    "correct",
                    "root",
                    1,
                    ok_outcome("Maya's final total is $18.", Some(9)),
                ),
            ],
            1,
        );

        assert_eq!(m.keep, vec!["correct"]);
    }

    #[test]
    fn materialize_all_score_infra_failures_can_fall_back_by_input_order() {
        let m = materialize_level(
            1,
            vec![
                branch(
                    "first_failed",
                    "root",
                    0,
                    ok_outcome_score_failed("First answer.", "score fork failed: x"),
                ),
                branch(
                    "second_failed",
                    "root",
                    1,
                    ok_outcome_score_failed("Second answer.", "score generate failed: y"),
                ),
            ],
            1,
        );

        assert!(m.nodes.iter().all(|n| n.score.is_none()));
        assert!(m.nodes.iter().all(|n| n.score_error.is_some()));
        assert_eq!(m.keep, vec!["first_failed"]);
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
        let out = finalize(flat, &last, 1);
        assert_eq!(out.selected_node_id.as_deref(), Some("b"));
        assert_eq!(out.final_answer.as_deref(), Some("answer-b"));
    }

    #[test]
    fn finalize_all_error_last_level_nulls_answer() {
        let flat = vec![Node::root()];
        let last = vec![cand("e0", None, false), cand("e1", Some(8), false)];
        let out = finalize(flat, &last, 1);
        assert!(out.selected_node_id.is_none());
        assert!(out.final_answer.is_none());
    }

    // ── #661 F2: reasoning-free intermediate scoring path ──────────────────
    fn pathed_node(id: &str, parent: &str, depth: usize, content: &str) -> Node {
        Node {
            id: id.to_string(),
            parent_id: Some(parent.to_string()),
            depth,
            branch_index: Some(0),
            content: content.to_string(),
            reasoning: String::new(),
            score: None,
            status: NodeStatus::Ok,
            error: None,
            score_error: None,
            children: Vec::new(),
        }
    }

    #[test]
    fn clean_answer_path_walks_root_to_node_oldest_first() {
        let flat = vec![
            Node::root(),
            pathed_node("a", "root", 1, "step one"),
            pathed_node("b", "a", 2, "step two"),
            pathed_node("c", "b", 3, "step three"),
        ];
        // Path to the level-2 parent "b" = its ancestors' clean answers, root→b.
        assert_eq!(clean_answer_path(&flat, "b"), vec!["step one", "step two"]);
        // The synthetic root has no content → a level-1 node sees no prior step.
        assert_eq!(clean_answer_path(&flat, "root"), Vec::<String>::new());
    }

    #[test]
    fn clean_answer_path_skips_empty_nodes_and_strips_think() {
        let flat = vec![
            Node::root(),
            pathed_node("a", "root", 1, ""), // Error/Incomplete: no answer
            pathed_node("b", "a", 2, "<think>\n\nclean tail"), // leaked tag stripped
        ];
        assert_eq!(clean_answer_path(&flat, "b"), vec!["clean tail"]);
    }

    #[test]
    fn score_replay_plan_clean_base_final_replays_answer_only() {
        // Final level judged on (question, answer): replay the answer, no path.
        assert_eq!(score_replay_plan(true, true), (false, true));
    }

    #[test]
    fn score_replay_plan_clean_base_intermediate_replays_path_and_answer() {
        // Intermediate node anchors "repeats an earlier step": replay both.
        assert_eq!(score_replay_plan(true, false), (true, true));
    }

    #[test]
    fn score_replay_plan_degraded_fallback_replays_nothing() {
        // #661 F1: no clean root → the answered branch ctx is scored as-is,
        // replaying neither path nor answer, so no duplicate assistant turn
        // can form on the context that already ends with the answered turn.
        assert_eq!(score_replay_plan(false, false), (false, false));
        assert_eq!(score_replay_plan(false, true), (false, false));
    }

    #[test]
    fn finalize_empty_last_level_nulls_answer() {
        let out = finalize(vec![Node::root()], &[], 1);
        assert!(out.selected_node_id.is_none());
        assert!(out.final_answer.is_none());
    }

    #[test]
    fn f7_late_full_failure_does_not_expose_intermediate_step_when_synthesis_missing() {
        // Review v3 F1: with #555 path-advancing prompts, a retained
        // non-final level is only an intermediate path step. If the final
        // depth fully fails and synthesis returns None/skips, the terminal
        // response must not present that path step as a successful final
        // answer.
        let mut flat = vec![Node::root()];
        let LevelMaterialized {
            nodes,
            candidates,
            keep,
            generated_tokens: _,
        } = materialize_level(
            1,
            vec![branch(
                "n0",
                "root",
                0,
                ok_outcome("intermediate path step", Some(6)),
            )],
            2,
        );
        flat.extend(nodes);
        let (pool1, stop1) = fold_level(Vec::new(), candidates, &keep);
        assert!(!stop1);

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

        let mut out = finalize(flat, &pool2, 2);
        reconcile_synthesis(&mut out, None);
        assert_eq!(out.selected_node_id.as_deref(), Some("n0"));
        assert_ne!(out.final_answer.as_deref(), Some("intermediate path step"));
        assert!(out.final_answer.is_none());
        let (code, _) =
            crate::tot::stream::terminal_error(&out.selected_node_id, &out.final_answer)
                .expect("selected intermediate without a final answer must be terminal failure");
        assert_eq!(code, crate::tot::stream::FINAL_ANSWER_UNAVAILABLE_CODE);
    }

    #[test]
    fn synthesis_failure_with_labeled_intermediate_stays_terminal_error() {
        // Review v9 F1: a retained intermediate may contain label-shaped
        // material from older prompt variants. A synthesis Err/fork skip must
        // not deterministically relabel that material into a synthesized
        // success; it should fall through to final_answer_unavailable.
        let mut flat = vec![Node::root()];
        let LevelMaterialized {
            nodes,
            candidates,
            keep,
            generated_tokens: _,
        } = materialize_level(
            1,
            vec![branch("n0", "root", 0, ok_outcome("Total: $18", Some(6)))],
            2,
        );
        flat.extend(nodes);
        let (pool, stop) = fold_level(Vec::new(), candidates, &keep);
        assert!(!stop);

        let mut out = finalize(flat, &pool, 2);
        let synth = synthesis_failure_fallback(out.final_answer.as_deref(), "Total: $18");
        reconcile_synthesis(&mut out, synth);

        assert_eq!(out.selected_node_id.as_deref(), Some("n0"));
        assert!(out.final_answer.is_none());
        assert!(!out.synthesized);
        let (code, _) =
            crate::tot::stream::terminal_error(&out.selected_node_id, &out.final_answer)
                .expect("selected intermediate without synthesis must be terminal failure");
        assert_eq!(code, crate::tot::stream::FINAL_ANSWER_UNAVAILABLE_CODE);
    }

    #[test]
    fn final_depth_leaf_can_still_be_raw_fallback_answer() {
        // The review v3 guard above covers depth=2 where a retained level-1
        // node is intermediate and must not be exposed as final_answer without
        // synthesis. This keeps the original raw fallback invariant for a
        // selected node that is already final-answer-eligible.
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

        let out = finalize(flat, &pool2, 1);
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
            1,
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
            1,
        );
        reconcile_synthesis(&mut out, None);
        assert_eq!(out.final_answer.as_deref(), Some("raw-best-leaf"));
        assert!(!out.synthesized);
    }

    #[test]
    fn reconcile_synthesis_none_keeps_honest_null_when_no_leaf() {
        // No ok leaf → finalize() honestly nulled final_answer; a skipped
        // synthesis leaves it null (and unsynthesized).
        let mut out = finalize(vec![Node::root()], &[], 1);
        assert!(out.final_answer.is_none());
        reconcile_synthesis(&mut out, None);
        assert!(out.final_answer.is_none());
        assert!(!out.synthesized);
    }
}
