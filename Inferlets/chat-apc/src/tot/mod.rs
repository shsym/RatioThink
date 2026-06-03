//! `tree-of-thought` mode of the chat-apc inferlet. **EXPERIMENTAL.**
//!
//! Dispatched via `POST /v1/inferlet` with `inferlet:"tree-of-thought"`.
//! Runs a bounded Tree-of-Thought BFS beam search (Yao et al. 2023,
//! "Tree of Thoughts", NeurIPS): from the conversation root, generate
//! `breadth` candidate continuations per frontier node, score each 1–10
//! with a value evaluator, keep the top `beam_width` per level, repeat
//! for `depth` levels, and return the full generated tree as JSON for
//! UI/agent inspection. The best-scoring leaf is the final answer.
//!
//! ## Request (`input`)
//!
//! ```json
//! {
//!   "inferlet": "tree-of-thought",
//!   "stream": false,
//!   "input": {
//!     "model": "<slug>",                 // optional; defaults to the engine's model
//!     "messages": [{ "role": "user", "content": "..." }],
//!     "breadth": 3,                      // [1,5]  branches per node
//!     "depth": 2,                        // [1,4]  search levels
//!     "beam_width": 2,                   // [1,5]  states kept per level
//!     "max_tokens_per_node": 256,        // [1,1024]
//!     "temperature": 0.7,                // [0.0,2.0]
//!     "top_p": 0.95                      // (0.0,1.0]
//!   }
//! }
//! ```
//!
//! `messages` may also ride at the top level of the dispatch envelope;
//! `input.messages` wins on overlap. Total candidate nodes
//! `= breadth + (depth-1)·beam_width·breadth` are bounded by `MAX_NODES`
//! (64) — an over-budget request is rejected with 400.
//!
//! ## Response (200)
//!
//! A structured tree. Each node carries a stable `id`, `parent_id`,
//! `depth`, `branch_index`, `content`, `score` (1–10 or `null`),
//! `status` (`"root" | "ok" | "error"`), an optional per-node `error`
//! (partial-failure diagnostic), and nested `children`. The envelope adds
//! `selected_node_id` + `final_answer` (the best-scoring leaf). A node
//! that was generated but pruned still appears in the tree (childless);
//! a node with children was kept in the beam.
//!
//! Validation / model-resolution / pre-generation failures use the same
//! OpenAI-shape `{error:{...}}` envelope as `/v1/chat/completions`
//! (`crate::sse::json_error`). Per-node generation failures are
//! represented on the node (`status:"error"` + `error`) while the rest
//! of the tree still returns.
//!
//! ## Scope (v1)
//!
//! Non-streaming only — `stream:true` is rejected with 400. The live
//! tree-search UI + a ToT streaming wire format are tracked separately
//! (ticket #413). The `tree-of-thought` dispatch *name* is the stable
//! wire seam: a future move to a dynamically-loaded or separate inferlet
//! requires no client change.
//!
//! ## Scoring caveat (v1)
//!
//! The value evaluator asks the model for a single 1–10 integer and
//! parses the first in-range integer it emits. **Reasoning models**
//! (e.g. Qwen3, which wraps output in `<think>…</think>`) tend to
//! restate the problem before answering, so the first integer is often
//! out of range and the score parses to `null`. A `null` score ranks
//! lowest, so the beam falls back to deterministic (input-order)
//! selection — the search still runs and returns a well-formed tree,
//! but pruning is not quality-driven. Real score-driven pruning needs a
//! non-reasoning model, a `/no_think`-style directive, or reasoning-tag
//! stripping + a larger score budget (future work).
//!
//! ## Future
//!
//! - **Profile mapping:** `breadth`/`depth`/`beam_width` presets → named
//!   profiles (kept explicit on the wire for v1).
//! - Reasoning-aware scoring (strip `<think>` / raise the score budget),
//!   vote-based evaluator + multi-sample value averaging; DFS+backtrack;
//!   `max_tokens` status granularity; per-node partial content on error;
//!   streaming (#413).

mod schema;
mod search;
mod tree;

use crate::chat::completions::{self, ChatMessage};
use crate::sse;
use wstd::http::server::{Finished, Responder};
use wstd::http::{IntoBody, Response};

/// Handle a `inferlet:"tree-of-thought"` dispatch. `input` is the
/// inferlet-specific payload; `messages` is the optional top-level
/// chat-sugar; `stream` is the dispatch-envelope flag.
pub async fn dispatch(
    input: Option<serde_json::Value>,
    messages: Option<Vec<ChatMessage>>,
    stream: bool,
    res: Responder,
) -> Finished {
    // v1 has no streaming. Reject explicitly rather than silently
    // ignoring the flag (Swift's dispatchInferlet defaults stream:true).
    if stream {
        return res
            .respond(sse::json_error(
                400,
                "invalid_request",
                "tree-of-thought has no streaming in v1; set stream:false",
            ))
            .await;
    }

    let input: schema::TotInput = match input {
        Some(v) => match serde_json::from_value(v) {
            Ok(p) => p,
            Err(e) => {
                return res
                    .respond(sse::json_error(
                        400,
                        "invalid_request",
                        &format!("Invalid `input` payload for tree-of-thought: {e}"),
                    ))
                    .await;
            }
        },
        None => schema::TotInput::default(),
    };

    // `input.messages` wins over top-level chat-sugar (mirrors
    // dispatch_chat_apc).
    let messages = match (input.messages.clone(), messages) {
        (Some(m), _) => m,
        (None, Some(m)) => m,
        (None, None) => {
            return res
                .respond(sse::json_error(
                    400,
                    "invalid_request",
                    "Provide either top-level `messages` or `input.messages` (the dispatch \
                     surface accepts both; `input.messages` wins on overlap).",
                ))
                .await;
        }
    };
    if messages.is_empty() {
        return res
            .respond(completions::json_error_param(
                400,
                "invalid_request",
                "messages must be a non-empty list",
                "messages",
            ))
            .await;
    }
    if let Some((i, _)) = messages
        .iter()
        .enumerate()
        .find(|(_, m)| m.content.trim().is_empty())
    {
        return res
            .respond(sse::json_error(
                400,
                "invalid_request",
                &format!("messages[{i}].content must be a non-empty, non-whitespace string"),
            ))
            .await;
    }

    let params = match schema::resolve(&input) {
        Ok(p) => p,
        Err((field, msg)) => {
            return res
                .respond(completions::json_error_param(400, "invalid_request", &msg, field))
                .await;
        }
    };

    // Resolve the model (default to the engine's single registered model).
    let model_id = match input.model {
        Some(m) if !m.trim().is_empty() => m,
        _ => match inferlet::runtime::models().into_iter().next() {
            Some(m) => m,
            None => {
                return res
                    .respond(sse::json_error(
                        500,
                        "no_model_registered",
                        "Engine has no models registered; check pie config.",
                    ))
                    .await;
            }
        },
    };
    if !inferlet::runtime::models().iter().any(|m| m == &model_id) {
        return res
            .respond(sse::json_error(
                404,
                "model_not_found",
                &format!("Model '{model_id}' not registered with this engine"),
            ))
            .await;
    }

    // Build + fill the root context. Pre-generation failures are
    // whole-request errors → JSON 500 envelope (per-node failures are
    // represented on the node inside the search).
    let model = match inferlet::model::Model::load(&model_id) {
        Ok(m) => m,
        Err(e) => {
            return res
                .respond(sse::json_error(
                    500,
                    "model_load_failed",
                    &format!("Failed to load model: {e}"),
                ))
                .await;
        }
    };
    let mut root_ctx = match inferlet::Context::new(&model) {
        Ok(c) => c,
        Err(e) => {
            return res
                .respond(sse::json_error(
                    500,
                    "context_create_failed",
                    &format!("Failed to create context: {e}"),
                ))
                .await;
        }
    };
    // cue:false — the assistant turn is opened per branch in `search`
    // (each fork re-cues), so the shared prefix stays cue-free and KV
    // pages are shared across branches.
    if let Err((code, msg)) = completions::fill_context(&mut root_ctx, &model, &messages, None, false)
    {
        return res.respond(sse::json_error(500, code, &msg)).await;
    }
    if let Err(e) = root_ctx.flush().await {
        return res
            .respond(sse::json_error(
                500,
                "context_flush_failed",
                &format!("Failed to flush root context: {e}"),
            ))
            .await;
    }

    let outcome = search::run(root_ctx, &params).await;

    let response_body = tree::TreeResponse {
        id: tree::new_tree_id(),
        object: "tree_of_thought",
        model: model_id,
        breadth: params.breadth,
        depth: params.depth,
        beam_width: params.beam_width,
        root: outcome.root,
        selected_node_id: outcome.selected_node_id,
        final_answer: outcome.final_answer,
    };
    let body = match serde_json::to_string(&response_body) {
        Ok(s) => s,
        Err(e) => {
            return res
                .respond(sse::json_error(
                    500,
                    "serialize_failed",
                    &format!("Failed to serialize tree: {e}"),
                ))
                .await;
        }
    };
    let response = Response::builder()
        .status(200)
        .header("Content-Type", "application/json")
        .body(body.into_body())
        .unwrap();
    res.respond(response).await
}
