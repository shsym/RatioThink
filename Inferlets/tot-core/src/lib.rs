//! Transport-independent tree search.
//!
//! Ported from `chat-apc/src/tot/`, which was 8,421 lines across six files
//! with the HTTP server, the SSE emitter and the search loop interleaved. What
//! changes here is the transport and the ownership of identity; the search
//! semantics are ported faithfully, and the reference's unit tests come across
//! unchanged so divergence shows up as a test failure rather than a subtly
//! different answer.
//!
//! ## What the gateway owns now
//!
//! * **The tree id.** chat-apc minted `tot-0` from a process-global counter.
//!   A wasm instance is per-request, so that counter restarts every time —
//!   which is exactly the `bon-0` collision bug. Node ids stay guest-side
//!   (they route `node_delta` frames within one run) but come from a run-owned
//!   [`tree::NodeIds`] rather than a static.
//! * **HTTP status.** Every `sse::json_error(status, ...)` site becomes a
//!   `GenError { code, message }`; mapping a code to a status is the gateway's
//!   job (doc §5.1).
//! * **The `[DONE]` sentinel and frame rendering.**
//!
//! ## Module layout
//!
//! `diversity` and `tree` are pure and host-testable. `search` is the wasm-only
//! generation path. The reference collapsed all of it into `search.rs`
//! (5,530 lines) with scoring, pruning and synthesis interleaved through the
//! beam loop; splitting them is the one structural change, and it is why
//! `branch`'s primitive is public — chat-apc's Best-of-N is built on the same
//! `generate_branch` (`chat-apc/src/tot/branch.rs:1-29`), so milestone C needs
//! it exported rather than buried.

pub mod diversity;
pub mod schema;
pub mod search;
pub mod stream;
pub mod tree;

use gen_core::boundary;
use gen_core::{GenError, classify_engine_error};
use inferlet::{model::Model, runtime};
use ratio_wire::EventSink;
use schema::TotInput;
use tree::{GenerationMetrics, TreeResult};

/// Run one tree-of-thought turn.
///
/// ## Ordering, and why it is not the obvious one (plan §6.1)
///
/// 1. Build the canonical root ONCE — cue-free, `/no_think`-free — and keep it.
/// 2. Search on a **fork**. Every branch directive, cue and `/no_think` lands
///    after that fork, never on the canonical context.
/// 3. Complete BOTH boundary saves, then emit the terminal event.
///
/// Step 2 is what makes cross-mode reuse possible at all. ToT mutates the last
/// user message with a per-branch directive and chat does not, so if either
/// mutation reached the canonical tokens the two modes would hash to different
/// `conv/` names for the same history and never share KV. Step 3 matters
/// because a client that sees `tree_complete` may issue its next request
/// immediately and race the save.
///
/// Reconstructing the boundary after the search — the natural shape — is what
/// this avoids: it would fold cue, reasoning and branch tokens into a snapshot
/// whose name claims to be the clean prompt.
///
/// ## NOT implemented: cooperative cancellation
///
/// The search never checks `EventSink::cancelled()`. Neither did chat-apc's —
/// it relied on the HTTP connection dropping — so this is not a regression, but
/// it IS a gap worth naming, because a tree search is the most expensive thing
/// in the system to leave running: `breadth x beam_width` branches per level
/// plus a ~160-token scorer generation for every answered node.
///
/// What bounds it today is the gateway, not the guest: on client disconnect the
/// driver signals cancel, waits `cancel_grace`, then calls
/// `terminate_process` — which is authoritative, since dropping the client only
/// detaches. Measured at 251 ms from disconnect to terminate.
///
/// Closing the gap is not a matter of adding a `cancelled()` call. Phase 1 and
/// phase 5 both measured that polling the signal future with `.get()` never
/// resolves — the host completes it only when its pollable is actually polled —
/// so the fix is to RACE the forward pass against the cancel pollable, the way
/// `gen_core::run_chat` does. That needs the pollable plumbed through
/// `EventSink`, which is a trait change, so it is deliberately not smuggled in
/// here.
pub async fn run_tot(input: TotInput, sink: &dyn EventSink) -> Result<TreeResult, GenError> {
    // ---- pre-commit: nothing emitted yet, so every failure is an HTTP status ----
    let messages = input.messages.clone().unwrap_or_default();
    if messages.is_empty() {
        return Err(GenError::new("invalid_request", "messages must not be empty")
            .with_param("messages"));
    }
    // Role validation before anything expensive. chat-apc also rejected
    // assistant `tool_calls` / `role:"tool"` / `tool_call_id` here; this port
    // carries gen-core's role gate, which refuses `tool` with its own code
    // rather than silently prefilling it as an empty turn.
    for (i, m) in messages.iter().enumerate() {
        if let Some(code) = gen_core::prompt::role_error_code(&m.role) {
            return Err(GenError::new(
                code,
                gen_core::prompt::role_error_message(i, &m.role, code),
            )
            .with_param(format!("messages[{i}].role")));
        }
    }

    // The RESOLVED id is what gets hashed into the boundary name, so it must be
    // the same string chat digests. chat requires an explicit model and checks
    // exact membership; ToT allows omission and default-fills, so resolve first
    // and membership-check the result — a trim or case difference here would
    // orphan the boundary with no error anywhere, just a permanently cold turn.
    let models = runtime::models();
    let requested = input.model.clone().unwrap_or_default().trim().to_string();
    let model_id = if requested.is_empty() {
        models
            .first()
            .cloned()
            .ok_or_else(|| GenError::new("model_not_found", "engine serves no models"))?
    } else {
        requested
    };
    if !models.iter().any(|m| m == &model_id) {
        return Err(GenError::new(
            "model_not_found",
            format!("model {model_id:?} is not served by this engine"),
        )
        .with_param("model"));
    }
    let model = Model::load(&model_id).map_err(|e| GenError::new("model_load_failed", e))?;

    let params = schema::resolve(&input)
        .map_err(|(field, msg)| GenError::new("invalid_request", msg).with_param(field))?;

    let directive = input.boundary.clone().unwrap_or_default();
    let canonical =
        boundary::open_canonical(&model, &model_id, &directive, &messages).await?;

    // The search root. `open_canonical` already flushed, so this fork inherits
    // materialized pages instead of replaying the prompt — and `save_boundary`'s
    // own fork+flush later degrades to a no-op rather than a second prefill.
    //
    // `classify_engine_error` keeps a capacity failure retryable (`server_busy`
    // → 503 + Retry-After). Forking is the likeliest way a ToT turn fails under
    // KV pressure, and a flat 500 would bypass the app's retry ladder for the
    // one mode that most needs it.
    let search_root = canonical
        .ctx
        .fork()
        .map_err(|e| GenError::new(classify_engine_error(&e), e))?;

    // ---- commit ----
    let started = inferlet::wstd::time::Instant::now();
    stream::tree_start(sink, params.breadth, params.depth, params.beam_width);

    let outcome = search::run(search_root, &params, &model, Some(sink)).await;

    // Exit half, BEFORE the terminal event. Best-effort, never `?`: a failed
    // save costs the next turn a re-prefill; propagating it here would make a
    // cache-write fault replace `tree_complete` with an error terminal and
    // discard a completed multi-branch search. Fork/flush faults are likeliest
    // under exactly the KV pressure a 15-21-context search creates.
    if let Some(answer) = outcome.final_answer.as_deref() {
        if let Err(e) =
            boundary::save_boundary(&canonical, &model, &model_id, &directive, answer).await
        {
            eprintln!("[tot] boundary save failed ({}): {}", e.code, e.message);
        }
    }

    // `wstd`'s clock is the one that works in wasip2; `GenerationMetrics`
    // takes a std Duration, so convert rather than plumb a second time type.
    let elapsed = std::time::Duration::from_nanos(started.elapsed().as_nanos() as u64);
    let metrics = GenerationMetrics::build(outcome.total_generated_tokens, elapsed);
    if let Some(m) = &metrics {
        stream::generation_metrics(sink, m);
    }

    // F1: a search that selected no ok leaf, or selected an inspection node
    // with no final answer, terminates with `error` — NOT a `tree_complete`
    // carrying nulls, which the client would render as a blank successful turn.
    match stream::terminal_error(&outcome.selected_node_id, &outcome.final_answer) {
        Some((code, message)) => {
            sink.emit(ratio_wire::Event::Error {
                code: code.to_string(),
                message: message.to_string(),
                param: None,
            });
        }
        None => stream::tree_complete(
            sink,
            outcome.selected_node_id.clone(),
            outcome.final_answer.clone(),
            outcome.synthesized,
        ),
    }

    Ok(TreeResult {
        model: model_id,
        breadth: params.breadth,
        depth: params.depth,
        beam_width: params.beam_width,
        root: outcome.root,
        selected_node_id: outcome.selected_node_id,
        final_answer: outcome.final_answer,
        synthesized: outcome.synthesized,
        generation_metrics: metrics,
        boundary_found: canonical.outcome.found,
        reused_tokens: canonical.outcome.reused_tokens as u32,
    })
}

