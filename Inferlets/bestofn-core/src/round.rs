//! One Best-of-N round: N candidates, no scoring, no auto-select.
//!
//! Ported from `chat-apc/src/bestofn/mod.rs::run_round` (:333-520). Generation
//! is `tot_core::search::generate_branch` — the same primitive tree search
//! uses, exactly as chat-apc did — with Best-of-N's own per-candidate stance
//! directives from [`crate::divergence`]. What differs from ToT is everything
//! AFTER generation: no value scorer, no beam pruning, no synthesis. The user
//! is the selector, which is the point of the mode.
//!
//! It rides the tree wire so the app renders it in the existing tree view:
//! `tree_start` (with the inert `depth = 1`, `beam_width = 1` bounds), one
//! `node_start`/`node_delta`/`node_complete` per candidate, `level_pruned` with
//! every saved candidate kept, and the `awaiting_selection` terminal.

use gen_core::boundary::{self, BoundaryDirective, OpenOutcome};
use gen_core::schema::ChatMessage;
use gen_core::{GenError, classify_engine_error};
use inferlet::{Context, model::Model};
use ratio_names::SnapshotName;
use ratio_wire::event::Pick;
use ratio_wire::{Event, EventSink};
use serde::{Deserialize, Serialize};
use tot_core::search::{DemuxKind, generate_branch};
use tot_core::stream;
use tot_core::tree::{Node, NodeStatus};

use crate::divergence;
use crate::resume::{ResumeBase, ResumeKind};
use crate::schema::BestOfNParams;

/// What `bestofn.wasm` returns for a generative round.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct RoundResult {
    pub model: String,
    pub level: usize,
    pub n: usize,
    /// Candidates that generated AND saved a resumable snapshot.
    pub pickable: usize,
    /// KV reuse on ENTRY — round 1 only. Without this a Best-of-N path that
    /// cold-starts every turn is indistinguishable from one that reuses.
    #[serde(default)]
    pub boundary_found: bool,
    #[serde(default)]
    pub reused_tokens: u32,
    /// Resume diagnostics — absent on round 1.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub resume: Option<ResumeInfo>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ResumeInfo {
    /// `warm` | `cold_evicted` | `cold_mismatch`.
    pub kind: String,
    /// Whether the picked snapshot was provably the candidate whose text the
    /// client sent. False means we rebuilt rather than trusting it.
    pub validated: bool,
    pub freed: usize,
    /// Names the guard refused — a client bug, or an attempt to free something
    /// this round does not own.
    pub refused: usize,
}

impl ResumeInfo {
    pub fn of(b: &ResumeBase) -> Self {
        Self {
            kind: match b.kind {
                ResumeKind::Warm => "warm",
                ResumeKind::ColdEvicted => "cold_evicted",
                ResumeKind::ColdMismatch => "cold_mismatch",
            }
            .to_string(),
            validated: matches!(b.kind, ResumeKind::Warm | ResumeKind::ColdEvicted),
            freed: b.deleted,
            refused: b.refused,
        }
    }
}

const ROOT_ID: &str = "root";

/// Build round 1's base: the canonical conversation prefix, flushed, cue-free.
///
/// Goes through `open_canonical`, so a Best-of-N round ENTERS on whatever
/// boundary a previous chat or ToT turn left — the same entry half those modes
/// have. chat-apc built this with `Context::new` + fill + flush every time, so
/// it never reused anything.
pub async fn cold_base(
    model: &Model,
    model_id: &str,
    directive: &BoundaryDirective,
    messages: &[ChatMessage],
) -> Result<(Context, Vec<u32>, OpenOutcome), GenError> {
    let canonical = boundary::open_canonical(model, model_id, directive, messages).await?;
    // Fork so the round's per-candidate mutations never touch the canonical
    // context — the rule ToT follows, and what lets a Best-of-N turn and a chat
    // turn agree on a `conv/` name for the same history.
    let base = canonical
        .ctx
        .fork()
        .map_err(|e| GenError::new(classify_engine_error(&e), e))?;
    Ok((base, canonical.tokens, canonical.outcome))
}

/// Generate, stream and persist one round. Returns how many candidates are
/// pickable.
///
/// `base_tokens` are the canonical tokens the candidate names digest over, so a
/// later resume can recompute them.
#[allow(clippy::too_many_arguments)]
pub async fn run(
    base_ctx: Context,
    base_tokens: &[u32],
    params: &BestOfNParams,
    model: &Model,
    model_id: &str,
    round_id: &str,
    level: usize,
    sink: &dyn EventSink,
) -> usize {
    // Inert ToT bounds: Best-of-N never prunes or auto-selects.
    let gen_params = tot_core::schema::TotParams {
        breadth: params.n,
        depth: 1,
        beam_width: 1,
        max_tokens_per_node: params.max_tokens_per_candidate,
        max_reasoning_tokens: params.max_reasoning_tokens,
        temperature: params.temperature,
        top_p: params.top_p,
        thinking: params.thinking,
        exec: Default::default(),
        task: Default::default(),
        // Best-of-N's only divergence lever is the per-candidate directive
        // pair; it does not use ToT's cross-sibling token penalty.
        sibling_penalty: 0.0,
    };

    stream::tree_start(sink, params.n, 1, 1);

    if !divergence::requires_stochastic_sampling(params.temperature) {
        eprintln!(
            "[bestofn] temperature is 0 — candidates diverge by directive only; \
             per-fork seed independence is inert at greedy decode"
        );
    }

    // Fork n candidate contexts off the shared, flushed, cue-free base.
    let mut metas: Vec<(String, usize)> = Vec::with_capacity(params.n);
    let mut ctxs: Vec<Context> = Vec::with_capacity(params.n);
    let mut fork_errors: Vec<(String, usize, String)> = Vec::new();
    for idx in 0..params.n {
        let node_id = format!("bon-n{}", idx + 1);
        match base_ctx.fork() {
            Ok(c) => {
                ctxs.push(c);
                metas.push((node_id, idx));
            }
            Err(e) => fork_errors.push((
                node_id,
                idx,
                format!("fork failed ({}): {e}", classify_engine_error(&e.to_string())),
            )),
        }
    }

    let directives: Vec<(String, String)> = metas
        .iter()
        .map(|(_, idx)| {
            (
                divergence::candidate_directive(*idx, params.thinking),
                divergence::candidate_retry_directive(*idx),
            )
        })
        .collect();

    // All siblings decode in flight so the engine co-batches their forward
    // passes; their node_delta frames interleave on the one stream, each routed
    // by node id. No lock: the sink is `&self` and synchronous.
    let gens = futures::future::join_all(
        metas
            .iter()
            .zip(ctxs)
            .zip(directives.iter())
            .map(|(((node_id, idx), c), (first, retry))| {
                generate_branch(
                    c, model, &gen_params, Some(sink), node_id, ROOT_ID, level, *idx, &[], first,
                    retry,
                )
            }),
    )
    .await;

    // Persist each answered candidate under a CONTENT-ADDRESSED name, so a
    // later resume can prove the pair it is handed is coherent.
    let mut nodes: Vec<Node> = Vec::with_capacity(params.n);
    let mut picks: Vec<Pick> = Vec::new();
    let mut kept: Vec<String> = Vec::new();
    for ((_gen_ctx, demux), (node_id, idx)) in gens.into_iter().zip(metas.iter()) {
        let node = match demux.kind {
            DemuxKind::Answered => {
                let name = SnapshotName::bon_candidate(
                    round_id,
                    level as u32,
                    *idx as u32,
                    model_id,
                    base_tokens,
                    &demux.answer,
                );
                if save_candidate(model, &base_ctx, &demux.answer, name.as_str()).await {
                    kept.push(node_id.clone());
                    picks.push(Pick {
                        id: node_id.clone(),
                        branch_index: *idx as u32,
                        snapshot_name: name.as_str().to_string(),
                    });
                    node_of(node_id, *idx, level, NodeStatus::Ok, demux.answer, demux.reasoning, None)
                } else {
                    // Answered but unsaveable → not pickable, so it must not
                    // appear in the pick list.
                    node_of(
                        node_id, *idx, level, NodeStatus::Error, String::new(), demux.reasoning,
                        Some("candidate KV could not be saved for resume".into()),
                    )
                }
            }
            DemuxKind::Incomplete => node_of(
                node_id, *idx, level, NodeStatus::Incomplete, String::new(), demux.reasoning,
                Some("candidate produced no usable answer".into()),
            ),
            DemuxKind::Aborted(msg) => node_of(
                node_id, *idx, level, NodeStatus::Error, String::new(), demux.reasoning, Some(msg),
            ),
        };
        nodes.push(node);
    }
    for (node_id, idx, err) in &fork_errors {
        nodes.push(node_of(
            node_id, *idx, level, NodeStatus::Error, String::new(), String::new(),
            Some(err.clone()),
        ));
    }
    nodes.sort_by_key(|n| n.branch_index.unwrap_or(0));

    stream::emit_level(sink, level, &nodes, &kept);

    if picks.is_empty() {
        // A round with nothing pickable is a FAILED round and must terminate as
        // an error, not an empty `awaiting_selection` — the same F1 rule ToT
        // follows. An empty pick list renders as a round with nothing to choose,
        // which reads as success.
        sink.emit(Event::Error {
            code: "no_candidates".into(),
            message: "best-of-n produced no pickable candidate".into(),
            param: None,
        });
        return 0;
    }

    let n = picks.len();
    sink.emit(Event::AwaitingSelection { level: level as u32, candidates: picks });
    n
}

/// Save one candidate's resumable KV.
///
/// Reconstructed from `base.fork()` + a clean assistant turn rather than saved
/// from the raw generation context: that context also holds the per-candidate
/// stance directive and its cue, which must never be part of what a resume
/// continues from.
async fn save_candidate(model: &Model, base: &Context, answer: &str, name: &str) -> bool {
    // Content-addressed, so an existing name holds identical KV by
    // construction. chat-apc had to delete-before-save because its names were
    // POSITIONAL: the same name could hold a different candidate's KV, and
    // resuming it would silently answer from the previous round's branch
    // (`bestofn/mod.rs:596-615`). The digest removes that hazard, so
    // "already exists" is simply success and no destructive pre-step is needed.
    let mut snap = match base.fork() {
        Ok(c) => c,
        Err(e) => {
            eprintln!("[bestofn] fork for snapshot {name} failed: {e}");
            return false;
        }
    };
    snap.append(&inferlet::chat::assistant(model, answer));
    if let Err(e) = snap.flush().await {
        eprintln!("[bestofn] flush for snapshot {name} failed: {e}");
        return false;
    }
    match snap.save(name) {
        Ok(()) => true,
        Err(e) => {
            let msg = e.to_string();
            if msg.contains("already exists") {
                return true;
            }
            eprintln!("[bestofn] save of snapshot {name} failed: {msg}");
            false
        }
    }
}

#[allow(clippy::too_many_arguments)]
fn node_of(
    id: &str,
    idx: usize,
    level: usize,
    status: NodeStatus,
    content: String,
    reasoning: String,
    error: Option<String>,
) -> Node {
    Node {
        id: id.to_string(),
        parent_id: Some(ROOT_ID.to_string()),
        depth: level,
        branch_index: Some(idx),
        content,
        reasoning,
        // Best-of-N does not score — the user is the selector. `null` is what
        // the captured stream carries.
        score: None,
        status,
        error,
        score_error: None,
        children: Vec::new(),
    }
}
