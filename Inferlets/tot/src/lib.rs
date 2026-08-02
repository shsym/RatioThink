//! The tree-of-thought inferlet: a thin shell over `tot-core`.
//!
//! Owns nothing but the transport binding — deserialize, wire a `SessionSink`,
//! run the search, return the neutral result. No HTTP, no SSE, no ids, no
//! timestamps. Structurally identical to `chat`, which is the point: the
//! gateway's `tree-v1` class handles the protocol difference, so the guest side
//! of a new mode stays this small.

use gen_core::GenError;
use ratio_wire::{Envelope, Event, EventSink, RunInput};
use std::cell::{Cell, RefCell};
use tot_core::schema::TotInput;

/// Emits envelopes over `session::send`.
///
/// One instance is shared by every concurrently-generating branch. That works
/// with no lock because `emit` takes `&self` and `session::send` is
/// synchronous and infallible — chat-apc needed a `futures::lock::Mutex` here
/// only because its emitter was `&mut self` and awaited.
///
/// `seq` is a plain `Cell`: the guest is a single cooperative stack, so
/// interleaved branch futures never preempt mid-increment, and the envelope
/// sequence stays gap-free — which matters because a gap is a hard protocol
/// error at the gateway's `SeqChecker`.
struct SessionSink {
    seq: Cell<u32>,
    /// Created ONCE and reused: each `session::receive()` mints a fresh future
    /// on the same per-process topic, so calling it per poll would race several
    /// consumers for one cancel message.
    signal: RefCell<Option<inferlet::types::FutureString>>,
}

impl SessionSink {
    fn new() -> Self {
        Self { seq: Cell::new(0), signal: RefCell::new(None) }
    }
}

impl EventSink for SessionSink {
    fn emit(&self, ev: Event) {
        let seq = self.seq.get();
        self.seq.set(seq + 1);
        inferlet::session::send(&Envelope::new(seq, &ev).to_line());
    }

    fn cancelled(&self) -> bool {
        let mut slot = self.signal.borrow_mut();
        let fut = slot.get_or_insert_with(inferlet::session::receive);
        fut.get().is_some()
    }
}

/// A pre-commit failure. The gateway turns the code into an HTTP status and
/// `param` into the OpenAI `param` field, so a bounds rejection still names the
/// field the client got wrong.
fn fail(sink: &SessionSink, e: GenError) -> String {
    sink.emit(e.into_event());
    "{}".into()
}

#[inferlet::main]
async fn main(input: RunInput) -> inferlet::Result<String> {
    let sink = SessionSink::new();

    if input.v != ratio_wire::envelope::ENVELOPE_VERSION {
        return Ok(fail(
            &sink,
            GenError::new(
                "unsupported_envelope_version",
                format!("v={} not supported", input.v),
            ),
        ));
    }

    // The app dispatches as `{"inferlet": "...", "input": {...}}`; a direct
    // caller may post the ToT body at the top level. Accept both rather than
    // 400 on a shape difference that carries no meaning.
    let body = match input.request.get("input") {
        Some(inner) => inner.clone(),
        None => input.request.clone(),
    };
    let req: TotInput = match serde_json::from_value(body) {
        Ok(r) => r,
        Err(e) => return Ok(fail(&sink, GenError::new("invalid_request", e.to_string()))),
    };

    match tot_core::run_tot(req, &sink).await {
        Ok(result) => Ok(serde_json::to_string(&result).unwrap_or_else(|_| "{}".into())),
        Err(e) => Ok(fail(&sink, e)),
    }
}
