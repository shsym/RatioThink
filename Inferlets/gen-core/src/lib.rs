//! Transport-independent chat generation.
//!
//! Emits `ratio_wire::Event`s through an `EventSink` and returns a neutral
//! `GenResult`. It constructs no OpenAI objects, no ids, no timestamps and no
//! HTTP statuses — those belong to the gateway (doc §3).
//!
//! ONE loop serves both streaming and buffered responses: the core always
//! emits events AND always returns the assembled result, so the caller
//! chooses. That collapses chat-apc's `handle_streaming` (910 lines) and
//! `handle_non_streaming` (745 lines), which could previously drift.

pub mod boundary;
pub mod demux;
pub mod prompt;
pub mod schema;

use demux::{Outcome, STARVED_CODE, STARVED_MESSAGE, visible_content};
use inferlet::{
    chat,
    inference::SlotOutput,
    model::Model,
    runtime,
    sample::Sampler,
};
use ratio_wire::{Event, EventSink, GenResult};
use schema::ChatRequest;

/// A failure that happened before the commit point. The caller turns the code
/// into an HTTP status; `gen-core` never chooses one.
#[derive(Debug, Clone)]
pub struct GenError {
    pub code: String,
    pub message: String,
}

impl GenError {
    fn new(code: impl Into<String>, message: impl Into<String>) -> Self {
        Self { code: code.into(), message: message.into() }
    }

    pub fn into_event(self) -> Event {
        Event::Error { code: self.code, message: self.message, param: None }
    }
}

/// Maps an engine error string to a stable code. `server_busy` is the one the
/// app treats as retryable, so it must not be flattened into a generic code.
pub fn classify_engine_error(msg: &str) -> &'static str {
    let m = msg.to_ascii_lowercase();
    if m.contains("server_busy") || m.contains("over capacity") || m.contains("no capacity") {
        "server_busy"
    } else {
        "context_failed"
    }
}

/// PARITY: `temperature <= 0.0` resolves to explicit greedy. Ported from
/// `chat-apc/src/chat/generate.rs:35-44`.
pub fn resolve_sampler(temperature: f32, top_p: f32) -> Sampler {
    if temperature <= 0.0 {
        Sampler::Argmax
    } else {
        Sampler::TopP { temperature, p: top_p }
    }
}

/// PARITY: reads the raw host slots, NOT `out.tokens`. The SDK truncates stop
/// tokens out of `tokens`, so on a natural stop `tokens` can be empty while
/// `slots` still carries `Token(stop)` — checking `tokens` would abort every
/// natural stop as starvation.
fn forward_pass_starved(slots: &[SlotOutput]) -> bool {
    !slots.iter().any(|s| matches!(s, SlotOutput::Token(_)))
}

/// Run one chat turn. Emits events as it goes; returns the assembled result.
pub async fn run_chat(
    req: &ChatRequest,
    sink: &dyn EventSink,
) -> Result<GenResult, GenError> {
    // ---- pre-commit: nothing has been emitted yet ----
    let models = runtime::models();
    if !models.iter().any(|m| m == &req.model) {
        return Err(GenError::new(
            "model_not_found",
            format!("model {:?} is not served by this engine", req.model),
        ));
    }
    schema::validate_sampling(req).map_err(|(c, m)| GenError::new(c, m))?;
    let model = Model::load(&req.model).map_err(|e| GenError::new("model_load_failed", e))?;

    // §6.1: keep the canonical (cue-free) context, generate on a FORK of it,
    // and save from the untouched original. Reconstructing the boundary after
    // generation risks folding cue/reasoning tokens into it.
    let directive = req.boundary.clone().unwrap_or_default();
    // `&req.model` is the membership-checked id from the loop above, and it is
    // what gets hashed into the boundary name. Every other mode must digest
    // this same resolved string or it computes a different name for the same
    // history and silently orphans the boundary.
    let canonical =
        boundary::open_canonical(&model, &req.model, &directive, &req.messages).await?;
    let mut ctx = canonical
        .ctx
        .fork()
        .map_err(|e| GenError::new(classify_engine_error(&e), e))?;
    // The cue is mode-specific, so it goes on the fork — never into the shared
    // boundary, or ToT and chat could never agree on a name.
    ctx.append(&prompt::generation_cue(&model, req.cue_mode()));

    // PARITY: read BEFORE the generator runs. `Generator::next` takes the
    // buffer, so after the first step this expression yields a different
    // number.
    let prompt_tokens = ctx.seq_len() + ctx.buffer().len() as u32;

    let max_tokens = req.effective_max_tokens(runtime::max_output_tokens() as usize);

    // Accepted-but-deferred features warn rather than 400, so the app's
    // toggles keep working while degraded (doc §8.1).
    if req.speculation.is_some() {
        sink.emit(Event::Warning {
            code: "feature_unavailable".into(),
            message: "speculative decoding is not implemented in this build; ignoring".into(),
        });
    }
    if req.cache.is_some() {
        sink.emit(Event::Warning {
            code: "feature_unavailable".into(),
            message: "prefix cache is not implemented in this build; ignoring".into(),
        });
    }

    // ---- commit ----
    sink.emit(Event::Ready);

    let stop_tokens = chat::stop_tokens(&model);
    let mut stream = ctx
        .generate(resolve_sampler(req.temperature_or_default(), req.top_p_or_default()))
        .max_tokens(max_tokens)
        .stop(&stop_tokens);

    // Cooperative cancellation. Created ONCE — each `session::receive()` mints
    // a fresh consumer of the same per-process topic, so per-iteration calls
    // would race each other for the single cancel message.
    //
    // Polling `.get()` does NOT work: measured twice (a sleep loop in phase 1,
    // and once per decode step in phase 5) and the future never resolved. The
    // host only completes it when its pollable is actually polled, so the
    // forward pass must be RACED against it rather than interleaved with it.
    let cancel_signal = inferlet::session::receive();

    let mut decoder = chat::Decoder::new(&model);
    let mut in_reasoning = false;
    let mut reasoning_streamed = String::new();
    let mut content = String::new();

    let (outcome, error_diag): (Outcome, Option<(&str, String)>) = loop {
        let step = match stream.next() {
            // PARITY: distinguish the max_tokens cap from a natural stop using
            // the GENERATOR's counter, not the locally accumulated one — they
            // can diverge, and the local one can flip `length` into `stop`.
            Ok(None) => {
                let reason = if stream.tokens_generated() >= max_tokens {
                    Outcome::MaxTokens
                } else {
                    Outcome::Natural
                };
                break (reason, None);
            }
            Ok(Some(s)) => s,
            Err(e) => break (Outcome::Aborted, Some((classify_engine_error(&e.to_string()), e.to_string()))),
        };
        // Race the forward pass against the cancel signal. Whichever resolves
        // first wins; if cancel wins we drop the in-flight execute future — the
        // pass is already submitted host-side and we are aborting regardless.
        // No diagnostic on cancel: a disconnect is not a fault.
        let exec = core::pin::pin!(step.execute());
        let cancel = core::pin::pin!(
            inferlet::wstd::io::AsyncPollable::new(cancel_signal.pollable()).wait_for()
        );
        let out = match futures::future::select(exec, cancel).await {
            futures::future::Either::Left((Ok(o), _)) => o,
            futures::future::Either::Left((Err(e), _)) => {
                break (
                    Outcome::Aborted,
                    Some((classify_engine_error(&e.to_string()), e.to_string())),
                );
            }
            futures::future::Either::Right(((), _)) => break (Outcome::Cancelled, None),
        };
        if forward_pass_starved(&out.raw().slots) {
            break (Outcome::Aborted, Some((STARVED_CODE, STARVED_MESSAGE.to_string())));
        }
        // NOTE: no local token accumulator. `stream.tokens_generated()` is
        // authoritative for both the `length` cutoff and the usage block;
        // a second counter can diverge and flip `length` into `stop`.

        // PARITY: snapshot the gate BEFORE feeding the reasoning decoder —
        // `feed` flips `in_reasoning` as a side effect of consuming the
        // boundary token. This ordering is the documented original bug.
        let was_in_reasoning = in_reasoning;
        let mut reason_idle = false;
        let mut reason_ended = false;
        match reasoning_feed(&model, &out.tokens, &mut in_reasoning) {
            Ok(ReasonEvent::Start) => {}
            Ok(ReasonEvent::Delta(s)) => {
                reasoning_streamed.push_str(&s);
                sink.emit(Event::ReasoningDelta { text: s });
            }
            Ok(ReasonEvent::End(s)) => {
                reason_ended = true;
                // #466: a multi-token batch can carry the reasoning text AND
                // the closing boundary in one feed, reported only via End(s)
                // with no prior Delta. Emit the un-streamed suffix. When
                // End(s) disagrees with the streamed deltas, trust the deltas.
                if let Some(residual) = s.strip_prefix(reasoning_streamed.as_str()) {
                    if !residual.is_empty() {
                        reasoning_streamed.push_str(residual);
                        sink.emit(Event::ReasoningDelta { text: residual.to_string() });
                    }
                }
            }
            Ok(ReasonEvent::Idle) => reason_idle = true,
            Err(e) => break (Outcome::Aborted, Some(("reasoning_decode_failed", e))),
        }

        match decoder.feed(&out.tokens) {
            Ok(chat::Event::Delta(s)) => {
                let visible = visible_content(&s, reason_idle, was_in_reasoning, reason_ended);
                // PARITY: the guard keeps zero-byte frames off the wire.
                // Dropping it changes the emitted frame count.
                if !visible.is_empty() {
                    content.push_str(visible);
                    sink.emit(Event::ContentDelta { text: visible.to_string() });
                }
            }
            // PARITY: the payload is DELIBERATELY discarded. `Done(s)` carries
            // the whole turn INCLUDING the <think> span, because the chat
            // decoder runs alongside — not downstream of — the reasoning
            // decoder. Using it would leak reasoning into visible content.
            Ok(chat::Event::Done(_)) => break (Outcome::Natural, None),
            Ok(chat::Event::Interrupt(id)) => {
                break (
                    Outcome::Aborted,
                    Some((
                        "chat_template_interrupt",
                        format!("control token {id} from chat template"),
                    )),
                );
            }
            Ok(chat::Event::Idle) => continue,
            Err(e) => break (Outcome::Aborted, Some(("decode_failed", e.to_string()))),
        }
    };

    // PARITY: `context_window` is read only after the generator releases its
    // borrow on ctx; 0 means "unknown" and must become None so the UI falls
    // back instead of dividing by zero.
    let usage_completion = stream.tokens_generated() as u32;
    drop(stream);
    let window = ctx.max_tokens();
    let context_window = (window > 0).then_some(window);

    if let Some((code, message)) = &error_diag {
        sink.emit(Event::Error {
            code: (*code).to_string(),
            message: message.clone(),
            param: None,
        });
    }
    sink.emit(Event::Finish { reason: outcome.finish_reason() });
    sink.emit(Event::Usage {
        prompt_tokens,
        completion_tokens: usage_completion,
        context_window,
    });

    // ORDERING: complete the save BEFORE the caller emits its terminal event,
    // or the next request can race it and miss.
    //
    // BEST-EFFORT, never `?`. A failed save costs the NEXT turn a re-prefill; it
    // does not make this turn wrong. Propagating it would send `run_chat`'s
    // caller down the failure path, which emits an Error event and returns
    // `GenResult::default()` — discarding the content, token counts and finish
    // reason of a turn that already completed and already streamed. On the
    // buffered path that is a blank response. Fork/flush faults are most likely
    // under exactly the KV pressure that makes saving valuable, so this is not
    // a hypothetical ordering.
    if matches!(outcome, Outcome::Natural | Outcome::MaxTokens) && !content.is_empty() {
        if let Err(e) =
            boundary::save_boundary(&canonical, &model, &req.model, &directive, &content).await
        {
            eprintln!("[gen-core] boundary save failed ({}): {}", e.code, e.message);
        }
    }

    Ok(GenResult {
        content,
        reasoning: (!reasoning_streamed.is_empty()).then_some(reasoning_streamed),
        tool_calls: Vec::new(),
        finish_reason: Some(outcome.finish_reason()),
        prompt_tokens,
        completion_tokens: usage_completion,
        context_window,
        boundary_found: canonical.outcome.found,
        reused_tokens: canonical.outcome.reused_tokens as u32,
    })
}

/// Thin wrapper over the SDK reasoning decoder so the loop reads uniformly.
enum ReasonEvent {
    Start,
    Delta(String),
    End(String),
    Idle,
}

fn reasoning_feed(
    model: &Model,
    tokens: &[u32],
    in_reasoning: &mut bool,
) -> Result<ReasonEvent, String> {
    use inferlet::reasoning;
    // A fresh decoder per batch would lose cross-batch state, so it is
    // cached in a thread-local for the lifetime of this (single-threaded,
    // per-request) wasm instance.
    thread_local! {
        static DEC: std::cell::RefCell<Option<reasoning::Decoder>> =
            const { std::cell::RefCell::new(None) };
    }
    DEC.with(|d| {
        let mut d = d.borrow_mut();
        let dec = d.get_or_insert_with(|| reasoning::Decoder::new(model));
        match dec.feed(tokens).map_err(|e| e.to_string())? {
            reasoning::Event::Start => {
                *in_reasoning = true;
                Ok(ReasonEvent::Start)
            }
            reasoning::Event::Delta(s) => {
                *in_reasoning = true;
                Ok(ReasonEvent::Delta(s))
            }
            reasoning::Event::End(s) => {
                *in_reasoning = false;
                Ok(ReasonEvent::End(s))
            }
            reasoning::Event::Idle => Ok(ReasonEvent::Idle),
        }
    })
}
