//! `GET /healthz` — liveness probe.

use serde::Serialize;
use wstd::http::server::{Finished, Responder};
use wstd::http::{IntoBody, Response};

#[derive(Serialize)]
struct Healthz<'a> {
    status: &'a str,
}

pub async fn handle(res: Responder) -> Finished {
    // `Healthz { status: &'static str }` cannot fail to serialize today.
    // If a future field breaks that invariant we want to surface the
    // bug, not ship a 200 with a malformed body that the OpenAI-shape
    // client would treat as `undefined`.
    let body = serde_json::to_string(&Healthz { status: "ok" }).expect("Healthz must serialize");
    let response = Response::builder()
        .header("Content-Type", "application/json")
        .body(body.into_body())
        .unwrap();
    res.respond(response).await
}
