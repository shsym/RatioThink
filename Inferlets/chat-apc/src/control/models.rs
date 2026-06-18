//! `GET /v1/models` — OpenAI-shape model list, driven by
//! `inferlet::runtime::models()`.

use inferlet::model::Model;
use inferlet::Context;
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
    /// chat-apc extension (#711 follow-up): KV tokens-per-page for this
    /// model — a model-indexed engine constant, set at model spawn and
    /// readable from a bare context with NO forward pass (page size does
    /// not depend on a driver, unlike `budget-page-count`). The App
    /// multiplies it by the model's `kv_pages_total` (from its live
    /// `model_status` poll) to show the engine-true context window the
    /// instant a model loads — `0 / window` before the first turn, without
    /// waiting for a turn's `usage` frame. `0` when unreadable (the App
    /// then treats the window as unknown).
    tokens_per_page: u32,
}

/// KV tokens-per-page for `model_id`, read from a fresh bare context. This
/// is a control-only metadata read: `Context::new` allocates no KV pages and
/// runs no forward pass, and `page_size` resolves from the model-indexed page
/// size cached at model spawn.
///
/// A load/open failure degrades to `0` for the client (the App reads `0` as
/// "window unknown" and falls back to the post-turn `usage` frame), but the
/// failure is NOT swallowed silently: it is logged to the chat-apc stderr seam
/// with the `model_id` so a broken page-size read on an advertised runtime
/// model is observable (F5) instead of hiding behind a valid `/v1/models`
/// response. (Per the `emit_done_logged` doc, this stderr is operator-visible
/// under `pie run` / CLI; daemon-stderr surfacing is the standing pie-side
/// follow-up shared by every chat-apc diagnostic.)
fn tokens_per_page(model_id: &str) -> u32 {
    let model = match Model::load(model_id) {
        Ok(model) => model,
        Err(e) => {
            eprintln!("[chat-apc] tokens_per_page: Model::load({model_id}) failed: {e}");
            return 0;
        }
    };
    match Context::new(&model) {
        Ok(ctx) => ctx.page_size(),
        Err(e) => {
            eprintln!("[chat-apc] tokens_per_page: Context::new for {model_id} failed: {e}");
            0
        }
    }
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
        .map(|id| {
            let tokens_per_page = tokens_per_page(&id);
            ModelObject {
                id,
                object: "model",
                owned_by: "pie",
                max_output_tokens,
                tokens_per_page,
            }
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
