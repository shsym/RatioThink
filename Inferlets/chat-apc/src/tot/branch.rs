//! Shared single-candidate generation surface (#690).
//!
//! Tree-of-thought search factors the generation of one forked candidate —
//! fork → per-branch directive → cue → demuxed `<think>`/answer generation →
//! bounded no-think starvation retry — behind one concrete entry point,
//! [`generate_branch`], that is independent of the beam-search loop, the
//! value scorer, and the synthesis stage. The interactive Best-of-N module
//! (`crate::bestofn`) reuses that exact primitive to stream N forked
//! candidates without auto-selecting, so both modules share one source of
//! truth for how a candidate is forked, generated, streamed (per-node
//! `node_delta` via [`super::stream::BranchSink`]), and — for thinking
//! models — retried.
//!
//! ## Why this is a re-export, not a relocation
//!
//! The reusable boundary is the *single* entry point [`generate_branch`]
//! (it builds its own engine-`Context` driver internally) plus its result
//! type [`Demux`]. The generation core is genuinely decoupled from search.
//! Its supporting helpers, however, are interleaved through `search.rs` and
//! several are shared with scoring and synthesis (answer sanitization,
//! think-delimiter stripping, prompt-echo detection, the demuxer itself).
//! Physically carving them out would split that shared web across two
//! modules for no behavioral gain and would not be a mechanical move. So
//! the shared module exposes the stable surface and the helpers stay where
//! they are used — `search.rs` remains the owner of single-candidate
//! generation; this module is its cross-module access point.
pub(crate) use super::search::{generate_branch, Demux, DemuxKind};
pub(crate) use super::stream::{emit_level, emit_tree_start, BranchSink};
pub(crate) use super::tree::{Node, NodeStatus};

use super::schema::{ExecStrategy, TotParams};

/// Build the generation params that drive [`generate_branch`] for one
/// Best-of-N round (#690). N sibling candidates at a single level
/// (`depth = 1`, so every candidate is a polished, standalone answer the
/// user can accept on any round — the "next level" deepening comes from
/// resuming the picked candidate's context next round, not from a deeper
/// directive arm). The beam-search-only knobs (`beam_width`, `exec`) are
/// pinned to inert defaults: Best-of-N never prunes or auto-selects, so they
/// never take effect. `thinking` is threaded through but the dispatch
/// defaults it off, so a round does not ride the open thinking-ON ToT crash
/// path (#679).
pub(crate) fn round_params(
    n: usize,
    max_tokens_per_candidate: usize,
    max_reasoning_tokens: usize,
    temperature: f32,
    top_p: f32,
    thinking: bool,
) -> TotParams {
    TotParams {
        breadth: n,
        depth: 1,
        beam_width: 1,
        max_tokens_per_node: max_tokens_per_candidate,
        max_reasoning_tokens,
        temperature,
        top_p,
        thinking,
        exec: ExecStrategy::default(),
    }
}
