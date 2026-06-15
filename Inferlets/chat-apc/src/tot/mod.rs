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
//! `status` (`"root" | "ok" | "error" | "incomplete"`), an optional per-node `error`
//! (generation-failure diagnostic), an optional per-node `score_error`
//! (value-evaluator infra failure — see the scoring caveat), and nested
//! `children`. The envelope adds `selected_node_id` + `final_answer` (the
//! best-scoring leaf). A node that was generated but pruned still appears
//! in the tree (childless); a node with children was kept in the beam.
//!
//! Validation / model-resolution / pre-generation failures use the same
//! OpenAI-shape `{error:{...}}` envelope as `/v1/chat/completions`
//! (`crate::sse::json_error`). Per-node generation failures are
//! represented on the node (`status:"error"` + `error`) while the rest
//! of the tree still returns.
//!
//! ## Streaming (`stream:true`, #413)
//!
//! `stream:true` returns an SSE stream that surfaces the search live —
//! `tree_start`, then per level a `node_complete` for every generated node
//! followed by a `level_pruned` beam selection, then ONE terminal:
//! `tree_complete` when a final answer was produced, or `error` when the
//! search could not produce one (F1 — either no selected leaf or a retained
//! inspection node with no synthesized final answer; see
//! [`stream::terminal_error`]). Non-streaming is symmetric: a search with a
//! final answer returns the 200 `TreeResponse`; a terminal failure returns the
//! same JSON `error` envelope. The wire format + frame schema live in
//! [`stream`]; the same [`search::run`] orchestration drives both the
//! streamed and non-streamed responses (it just takes an optional
//! [`Emitter`]), so the two can never diverge. Pre-stream failures
//! (validation, model resolution, context build) still return the JSON
//! 4xx/5xx envelope — the SSE response is opened only once the root
//! context is built and flushed, so a doomed request never emits a
//! misleading `tree_start`. The `tree-of-thought` dispatch *name* is the
//! stable wire seam: a future move to a dynamically-loaded or separate
//! inferlet requires no client change.
//!
//! ## Diversity + scoring (#523)
//!
//! Sibling branches do not rely on sampling temperature alone: each fork
//! gets a distinct per-branch directive (a named, mutually-exclusive
//! strategy that differs by primary objective/tradeoff; critique-then-
//! refine at deeper levels — see `search::branch_directive`), and beam
//! selection demotes a paraphrase of an already-kept sibling so a distinct
//! branch takes the slot (`tree::select_beam_diverse`). The value evaluator
//! scores for task relevance, correctness, specificity, and usefulness —
//! not fluency or brevity — so a polished generic acknowledgment can no
//! longer outrank a candidate that actually addresses the request.
//!
//! The scorer is a `/no_think` value head reading the clean (demuxed)
//! answer; it parses the first in-range 1–10 integer. A `null` score (the
//! model emitted no in-range integer) ranks lowest and falls back to
//! input-order, and is distinct from a scorer-*infrastructure* failure
//! (the value-evaluator fork or generation itself failed), which surfaces
//! as a per-node `score_error` so an infra collapse is observable rather
//! than indistinguishable from a benign `null`. Real-model evidence:
//! `Scripts/run-tot-real-smoke.sh` (gated, NOT CI).
//!
//! ## Future
//!
//! - **Profile mapping:** `breadth`/`depth`/`beam_width` presets → named
//!   profiles (kept explicit on the wire for v1).
//! - Reasoning-aware scoring (strip `<think>` / raise the score budget),
//!   vote-based evaluator + multi-sample value averaging; DFS+backtrack;
//!   `max_tokens` status granularity; per-node partial content on error;
//!   streaming (#413).

mod diversity;
mod schema;
mod search;
mod stream;
mod tree;

use crate::chat::completions::{self, ChatMessage};
use crate::sse::{self, Emitter};
use std::time::Instant;
use wstd::http::server::{Finished, Responder};
use wstd::http::{IntoBody, Response};

fn validate_tot_messages(
    messages: &[ChatMessage],
) -> Result<(), completions::MessageValidationError> {
    completions::validate_messages(messages)?;

    for (i, msg) in messages.iter().enumerate() {
        if msg.has_tool_calls() {
            return Err(completions::MessageValidationError::new(
                "tool_continuation_unsupported",
                "tree-of-thought does not support assistant tool_call continuation history",
                format!("messages[{i}].tool_calls"),
            ));
        }
        if msg.role == "tool" {
            return Err(completions::MessageValidationError::new(
                "tool_continuation_unsupported",
                "tree-of-thought does not support role=\"tool\" messages",
                format!("messages[{i}].role"),
            ));
        }
        if msg.tool_call_id.is_some() {
            return Err(completions::MessageValidationError::new(
                "tool_continuation_unsupported",
                "tree-of-thought does not support tool_call_id continuation fields",
                format!("messages[{i}].tool_call_id"),
            ));
        }
    }

    Ok(())
}

/// Handle a `inferlet:"tree-of-thought"` dispatch. `input` is the
/// inferlet-specific payload; `messages` is the optional top-level
/// chat-sugar; `stream` is the dispatch-envelope flag.
pub async fn dispatch(
    input: Option<serde_json::Value>,
    messages: Option<Vec<ChatMessage>>,
    stream: bool,
    res: Responder,
) -> Finished {
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
    let mut messages = match (input.messages.clone(), messages) {
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
    if let Err(err) = validate_tot_messages(&messages) {
        return res
            .respond(completions::json_error_param(
                400,
                err.code,
                &err.message,
                &err.param,
            ))
            .await;
    }
    if let Some((i, _)) = messages.iter().enumerate().find(|(_, m)| {
        m.content_str()
            .is_none_or(|content| content.trim().is_empty())
    }) {
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
                .respond(completions::json_error_param(
                    400,
                    "invalid_request",
                    &msg,
                    field,
                ))
                .await;
        }
    };

    // #413/#437: tree-of-thought THINKS by default — the `<think>` reasoning
    // is the point of the search, demuxed apart from the answer per node (see
    // `search::generate_demuxed`). Only when the caller disables it
    // (`thinking:false`) do we append the `/no_think` directive to the last
    // user turn (Qwen3 keys thinking off it); deeper levels + the scorer carry
    // it via `with_thinking(REFINE_INSTRUCTION/SCORE_PROMPT)`. The directive is
    // an inert token on a non-reasoning model.
    if !params.thinking {
        if let Some(last) = messages.iter_mut().rev().find(|m| m.role == "user") {
            if let Some(content) = last.content.as_mut() {
                content.push_str(" /no_think");
            }
        }
    }

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
    if let Err((code, msg)) =
        completions::fill_context(&mut root_ctx, &model, &messages, None, false)
    {
        // #468: an unknown role is a client error (400, same envelope as
        // the completions path); other fill_context failures (e.g.
        // tool_equip_failed) stay 500.
        let status = if completions::is_role_error_code(code) {
            400
        } else {
            500
        };
        return res.respond(sse::json_error(status, code, &msg)).await;
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

    // Generated once so the streaming `tree_start` id and the non-streaming
    // envelope id come from the same source.
    let tree_id = tree::new_tree_id();

    // #413: the root context is now built + flushed, so a `stream:true`
    // request can safely commit SSE headers — every failure that warranted
    // a JSON 4xx/5xx envelope has already returned above.
    if stream {
        return dispatch_streaming(root_ctx, &params, &model, &tree_id, &model_id, res).await;
    }

    let started = Instant::now();
    let outcome = search::run(root_ctx, &params, &model, None).await;

    // F1/review v4: terminal success requires an actual final answer, not
    // merely a selected inspection node. A retained intermediate candidate
    // after a later full failure can be useful for tree inspection, but if
    // synthesis did not produce a final answer, do not publish a 200
    // success-shaped tree with `final_answer:null`.
    if let Some((code, message)) =
        stream::terminal_error(&outcome.selected_node_id, &outcome.final_answer)
    {
        return res.respond(sse::json_error(500, code, message)).await;
    }

    let response_body = tree::TreeResponse {
        id: tree_id,
        object: "tree_of_thought",
        model: model_id,
        breadth: params.breadth,
        depth: params.depth,
        beam_width: params.beam_width,
        root: outcome.root,
        selected_node_id: outcome.selected_node_id,
        final_answer: outcome.final_answer,
        synthesized: outcome.synthesized,
        generation_metrics: tree::GenerationMetrics::build(
            outcome.total_generated_tokens,
            started.elapsed(),
        ),
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

/// SSE streaming variant (#413). `Emitter::start` commits the response
/// headers, so from here every exit path finishes through the emitter —
/// all pre-stream failures (validation, model resolution, context build)
/// were already returned as JSON envelopes by [`dispatch`] before this is
/// reached, exactly like `chat-apc`'s `handle_streaming`.
///
/// Frame order: `tree_start` → (`node_complete`* `level_pruned`)\* per
/// level (emitted inside [`search::run`]) → one terminal `tree_complete`
/// (a final answer was produced) OR `error` (F1: no final answer)
/// → `[DONE]`. The streamed `node_complete` frames carry the (error) tree
/// regardless, so an `error` terminal still leaves the client a renderable
/// tree plus a surfaced failure. A client that disconnects before the
/// first frame ends the stream immediately; mid-stream disconnects are
/// swallowed by `run` and the terminal emits below (the search still
/// completes, just unobserved).
async fn dispatch_streaming(
    root_ctx: inferlet::Context,
    params: &schema::TotParams,
    model: &inferlet::model::Model,
    tree_id: &str,
    model_id: &str,
    res: Responder,
) -> Finished {
    let mut em = Emitter::start(res);
    if stream::emit_tree_start(&mut em, tree_id, model_id, params)
        .await
        .is_err()
    {
        return em.finish();
    }
    let started = Instant::now();
    let outcome = search::run(root_ctx, params, model, Some(&mut em)).await;
    if let Some((code, message)) =
        stream::terminal_error(&outcome.selected_node_id, &outcome.final_answer)
    {
        // F1/review v4: terminal failure — emit the documented terminal
        // `error` frame (the client's catch marks the turn failed) instead
        // of a success-shaped `tree_complete` without a final answer.
        let _ = em.emit_json(&sse::SseError::new(code, message)).await;
    } else {
        if let Some(metrics) =
            tree::GenerationMetrics::build(outcome.total_generated_tokens, started.elapsed())
        {
            if stream::emit_generation_metrics(&mut em, &metrics)
                .await
                .is_ok()
            {
                let _ = stream::emit_tree_complete(
                    &mut em,
                    outcome.selected_node_id.as_deref(),
                    outcome.final_answer.as_deref(),
                    outcome.synthesized,
                )
                .await;
            }
        } else {
            let _ = em
                .emit_json(&sse::SseError::new(
                    stream::METRICS_UNAVAILABLE_CODE,
                    stream::METRICS_UNAVAILABLE_MESSAGE,
                ))
                .await;
        }
    }
    sse::emit_done_logged(&mut em, "tot_terminal").await;
    em.finish()
}

#[cfg(test)]
mod tests {
    use super::*;

    fn messages(json: &str) -> Vec<ChatMessage> {
        serde_json::from_str(json).expect("messages should deserialize")
    }

    #[test]
    fn tot_rejects_malformed_tool_continuations_before_context_fill() {
        let malformed = messages(
            r#"[{
                "role":"assistant",
                "content":null,
                "tool_calls":[{
                    "id":123,
                    "type":"function",
                    "function":{"name":"calculator","arguments":"{}"}
                }]
            }]"#,
        );
        let err = validate_tot_messages(&malformed)
            .expect_err("malformed assistant tool_calls should fail before fill_context");
        assert_eq!(err.code, "malformed_tool_calls");
        assert_eq!(err.param, "messages[0].tool_calls[0].id");

        let non_assistant = messages(
            r#"[{
                "role":"user",
                "content":"hi",
                "tool_calls":[{
                    "id":"call_x",
                    "type":"function",
                    "function":{"name":"calculator","arguments":"{}"}
                }]
            }]"#,
        );
        let err = validate_tot_messages(&non_assistant)
            .expect_err("tool_calls on non-assistant roles should fail before fill_context");
        assert_eq!(err.code, "malformed_tool_calls");
        assert_eq!(err.param, "messages[0].tool_calls");
    }
}
