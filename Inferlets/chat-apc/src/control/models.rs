//! `GET /v1/models` — OpenAI-shape model list, driven by
//! `inferlet::runtime::models()`.

use serde::Serialize;
use wstd::http::server::{Finished, Responder};
use wstd::http::{IntoBody, Response};

#[derive(Serialize)]
struct ModelObject {
    id: String,
    object: &'static str,
    owned_by: &'static str,
    /// chat-apc extension (#474): the effective per-request `max_tokens`
    /// ceiling the engine will accept for this model — the runtime's
    /// `max-output-tokens` (configured scheduler `default_token_limit`
    /// capped by raw KV capacity, memory-aware via #438). The App reads
    /// this to clamp/sync its profile `max_tokens` down to the launched
    /// engine ceiling instead of sending a blind value that the engine
    /// would reject with a clean 400. Engine-global (the minimum across
    /// registered models), so every entry carries the same value.
    max_output_tokens: u32,
}

#[derive(Serialize)]
struct ModelList {
    object: &'static str,
    data: Vec<ModelObject>,
}

pub async fn handle(res: Responder) -> Finished {
    // The effective output-token ceiling is engine-global (min across
    // registered models); attach it to each entry so an OpenAI-shape
    // client can read it per model without a separate capabilities call.
    let max_output_tokens = inferlet::runtime::max_output_tokens();
    let data: Vec<ModelObject> = inferlet::runtime::models()
        .into_iter()
        .map(|id| ModelObject {
            id,
            object: "model",
            owned_by: "pie",
            max_output_tokens,
        })
        .collect();
    let list = ModelList {
        object: "list",
        data,
    };
    // `ModelList` is `{object: &'static str, data: Vec<ModelObject{String,
    // &'static str, &'static str}>}` — no field can fail to serialize.
    // A silent `"{}"` fallback here would ship 200 with `body.object`
    // undefined, breaking OpenAI-shape clients without any HTTP signal.
    // Surface the invariant violation instead.
    let body = serde_json::to_string(&list).expect("ModelList must serialize");
    let response = Response::builder()
        .header("Content-Type", "application/json")
        .body(body.into_body())
        .unwrap();
    res.respond(response).await
}
