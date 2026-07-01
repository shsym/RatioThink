//! `POST /v1/inferlet` — internal/raw inferlet-dispatch endpoint.
//!
//! Body schema (per design doc §7):
//!
//! ```text
//! {
//!   "inferlet": "<name>",          // required
//!   "input": { ... },              // inferlet-defined, opaque
//!   "stream": true | false,        // default false
//!   "messages": [ ... ],           // optional — chat-shape sugar
//!   ...                            // passthrough into the named inferlet
//! }
//! ```
//!
//! **V1 narrow:** retained for internal/control/raw callers. Normal
//! app/profile sends for `"tree-of-thought"` and `"best-of-n"` should use
//! `/v1/chat/completions`, which routes to the same dispatch arms. This raw
//! endpoint still accepts `"chat-apc"`, `"tree-of-thought"`, and `"best-of-n"`;
//! the chat-apc arm rebuilds a `ChatCompletionsRequest` by merging `messages`
//! (top-level chat sugar) with optional sampling fields from `input` (the
//! inferlet-specific payload). Unknown names → 404 `inferlet_not_found`.
//!
//! True dynamic dispatch (load arbitrary wasm by name from
//! `--inferlet-dir`) requires pie-side host changes and is tracked
//! as a follow-up. The endpoint exists in v1 so the Swift
//! `EngineClient.dispatchInferlet` surface has somewhere to land —
//! adding more names later is a pure-inferlet edit.

use serde::Deserialize;
use wstd::http::Request;
use wstd::http::body::IncomingBody;
use wstd::http::server::{Finished, Responder};

use super::completions::{self, ChatCompletionsRequest, ChatMessage, SpecRequest, ToolSchema};
use crate::sse;

#[derive(Deserialize)]
struct InferletDispatch {
    inferlet: String,
    #[serde(default)]
    input: Option<serde_json::Value>,
    #[serde(default)]
    messages: Option<Vec<ChatMessage>>,
    #[serde(default)]
    stream: bool,
}

#[derive(Deserialize, Default)]
struct ChatApcInput {
    model: Option<String>,
    messages: Option<Vec<ChatMessage>>,
    temperature: Option<f32>,
    top_p: Option<f32>,
    max_tokens: Option<usize>,
    tools: Option<Vec<ToolSchema>>,
    tool_choice: Option<serde_json::Value>,
    speculation: Option<SpecRequest>,
    /// #522 cross-request KV prefix-cache directive (see
    /// [`super::prefix_cache`]). Optional on the dispatch surface too.
    cache: Option<super::prefix_cache::CacheDirective>,
}

pub async fn handle(req: Request<IncomingBody>, res: Responder) -> Finished {
    let (_parts, mut body) = req.into_parts();
    let mut body_bytes = Vec::new();
    if let Err(e) = sse::read_body(&mut body, &mut body_bytes, sse::DISPATCH_MAX_BODY).await {
        return res.respond(sse::body_error_response(e)).await;
    }
    let dispatch: InferletDispatch = match serde_json::from_slice(&body_bytes) {
        Ok(r) => r,
        Err(e) => {
            return res
                .respond(sse::json_error(
                    400,
                    "invalid_request",
                    &format!("Invalid JSON: {e}"),
                ))
                .await;
        }
    };

    match dispatch.inferlet.as_str() {
        "chat-apc" => dispatch_chat_apc(dispatch, res).await,
        "tree-of-thought" => {
            crate::tot::dispatch(dispatch.input, dispatch.messages, dispatch.stream, res).await
        }
        "best-of-n" => {
            crate::bestofn::dispatch(dispatch.input, dispatch.messages, dispatch.stream, res).await
        }
        other => {
            res.respond(sse::json_error(
                404,
                "inferlet_not_found",
                &format!(
                    "Inferlet '{other}' not available. V1 supports 'chat-apc', 'tree-of-thought', \
                     and 'best-of-n'."
                ),
            ))
            .await
        }
    }
}

async fn dispatch_chat_apc(dispatch: InferletDispatch, res: Responder) -> Finished {
    // `input` carries chat-apc's inferlet-specific payload. Be
    // permissive: missing → empty defaults; malformed → 400.
    let input: ChatApcInput = match dispatch.input {
        Some(v) => match serde_json::from_value(v) {
            Ok(p) => p,
            Err(e) => {
                return res
                    .respond(sse::json_error(
                        400,
                        "invalid_request",
                        &format!("Invalid `input` payload for chat-apc: {e}"),
                    ))
                    .await;
            }
        },
        None => ChatApcInput::default(),
    };

    // Top-level `messages` is the chat-shape sugar; inferlet-specific
    // `input.messages` wins on overlap (lets advanced callers stage a
    // multi-turn replay in `input` while still using the top-level
    // surface for the current turn).
    //
    // F12: explicit 400 when both sources are absent, naming both
    // options. Falling through to `unwrap_or_default()` lands in the
    // downstream `messages: vec![]` check inside `handle_parsed`,
    // which only mentions `messages` — callers hitting the dispatch
    // surface would search the dispatch payload for the field
    // (correctly empty in their request) and miss the `input.messages`
    // alternative.
    let messages = match (input.messages, dispatch.messages) {
        (Some(m), _) => m,
        (None, Some(m)) => m,
        (None, None) => {
            return res
                .respond(sse::json_error(
                    400,
                    "invalid_request",
                    "Provide either top-level `messages` or `input.messages` (the dispatch surface accepts both; `input.messages` wins on overlap).",
                ))
                .await;
        }
    };
    let model = match input.model {
        Some(m) => m,
        None => {
            // Default to the engine's single registered model. This
            // mirrors the Swift-side `pie-verify` fixture, which
            // assumes a 1:1 profile-to-model mapping in v1.
            match inferlet::runtime::models().into_iter().next() {
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
            }
        }
    };

    let request = ChatCompletionsRequest {
        inferlet: None,
        input: None,
        model,
        messages,
        stream: dispatch.stream,
        temperature: input.temperature,
        top_p: input.top_p,
        max_tokens: input.max_tokens,
        max_completion_tokens: None,
        tools: input.tools,
        tool_choice: input.tool_choice,
        speculation: input.speculation,
        cache: input.cache,
        // Tree-of-thought drives its own constrained scoring grammar and
        // never asks for JSON-mode answer decoding (#572) — keep this
        // dispatch path unconstrained so ToT is unaffected.
        response_format: None,
        stream_options: None,
    };
    completions::handle_parsed(request, res).await
}
