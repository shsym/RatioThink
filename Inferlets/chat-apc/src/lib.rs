//! chat-apc: HTTP API inferlet — chat-completions data plane +
//! engine-control plane in one wasm.
//!
//! Exports `wasi:http/incoming-handler@0.2.4`. A launcher process
//! installs this component, then calls `launch_daemon(inferlet_id, port)`
//! over WS; the pie host binds the listener and routes each request here.
//!
//! Routes:
//!   * `GET    /healthz`             -> `control::health`
//!   * `GET    /v1/models`           -> `control::models`
//!   * `POST   /v1/chat/completions` -> `chat::completions`
//!   * `POST   /v1/inferlet`         -> `chat::dispatch`
//!         (`inferlet:"chat-apc"` | `inferlet:"tree-of-thought"`)
//!
//! #469: there is NO `/v1/models/load`. pie binds the served model at
//! `pie serve` boot, so the served model is fixed by the boot config and
//! readable from `GET /v1/models`; switching it is an engine relaunch, not a
//! runtime load. The dead pre-warm endpoint (and the App-side load progress /
//! Cancel UI) were removed.
//!
//! Module split:
//!   * `control/` — touches only `inferlet::runtime` + `pie:core/model`.
//!   * `chat/`    — sole user of `instruct::chat`, `instruct::tool-use`,
//!                  `instruct::reasoning`, `mcp::client`.
//!   * `sse`      — shared SSE wire helpers used by both planes.
//!
//! Architecture note: the original v1 plan put these routes inside an
//! axum listener in the pie engine on the `pie.app/v1-base` branch.
//! The revised plan consolidates them into this inferlet — pie
//! already hosts `wasi:http/incoming-handler` (`runtime/src/daemon.rs`)
//! and the inferlet SDK already exposes Model/Tokenizer/Context/
//! Sampler/chat-templating/Generator. Keeping everything WASM-side
//! means no pie-side commits on `pie.app/v1-base` for the v1 cut.

mod chat;
mod control;
mod sse;
mod tot;

use wstd::http::body::IncomingBody;
use wstd::http::server::{Finished, Responder};
use wstd::http::{Method, Request};

#[wstd::http_server]
async fn main(req: Request<IncomingBody>, res: Responder) -> Finished {
    let method = req.method().clone();
    let path = req.uri().path().to_string();

    match (method.clone(), path.as_str()) {
        (Method::GET, "/healthz") => control::health::handle(res).await,
        (Method::GET, "/v1/models") => control::models::handle(res).await,
        (Method::POST, "/v1/chat/completions") => chat::completions::handle(req, res).await,
        (Method::POST, "/v1/inferlet") => chat::dispatch::handle(req, res).await,
        _ => not_found(res, &method, &path).await,
    }
}

// F11: every other error path emits `{error:{type,code,message,...}}`
// JSON; the unknown-route fallthrough used to return bare
// `"404 Not Found\n"` (text/plain), which makes OpenAI-compatible
// clients doing `JSON.parse(body)` on non-2xx throw and obscure the
// real cause (wrong path). Match the envelope shape + include
// method+path so operators can grep traffic.
async fn not_found(res: Responder, method: &Method, path: &str) -> Finished {
    res.respond(sse::json_error(
        404,
        "endpoint_not_found",
        &format!("No handler for {method} {path}"),
    ))
    .await
}
