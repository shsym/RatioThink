//! The chat inferlet: a thin shell over `gen-core`.
//!
//! Owns nothing but the transport binding — deserialize the request, wire a
//! `SessionSink`, run the generation, return the neutral result. No HTTP, no
//! SSE, no ids, no timestamps.

use gen_core::{GenError, schema::ChatRequest};
use ratio_wire::{Envelope, Event, EventSink, GenResult, RunInput};
use std::cell::{Cell, RefCell};

/// Emits envelopes over `session::send`.
///
/// `session::send` is synchronous and infallible (no return, no error), which
/// is why `EventSink::emit` needs no error channel and why `&self` suffices —
/// concurrent branch futures will be able to share one of these unlocked when
/// tree search lands.
struct SessionSink {
    seq: Cell<u32>,
    /// The cancel channel. Created ONCE and reused: each `session::receive()`
    /// mints a fresh future waiting on the same per-process topic, so calling
    /// it per poll would race several consumers for one message.
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

    /// Non-blocking cancel check, polled once per decode step.
    ///
    /// Phase 1 found that `.get()` inside a `wstd::task::sleep` loop never
    /// observed the signal. The decode loop is a different situation: it calls
    /// this immediately after `step.execute().await`, and awaiting a real
    /// forward-pass pollable yields to the host, which is what lets the
    /// messaging task resolve this future. So the check is free here — no
    /// extra await, no blocking — where it was useless in a sleep loop.
    fn cancelled(&self) -> bool {
        let mut slot = self.signal.borrow_mut();
        let fut = slot.get_or_insert_with(inferlet::session::receive);
        fut.get().is_some()
    }
}

fn fail(sink: &SessionSink, e: GenError) -> String {
    sink.emit(e.into_event());
    serde_json::to_string(&GenResult::default()).unwrap_or_else(|_| "{}".into())
}

#[inferlet::main]
async fn main(input: RunInput) -> inferlet::Result<String> {
    let sink = SessionSink::new();

    // Fails closed on an unsupported major version (doc §5.3 rule 6).
    if input.v != ratio_wire::envelope::ENVELOPE_VERSION {
        return Ok(fail(
            &sink,
            GenError::new(
                "unsupported_envelope_version",
                format!("v={} not supported", input.v),
            ),
        ));
    }

    // `gen-core` owns request semantics; the gateway forwarded the body
    // untouched, so anything it did not understand still arrives here.
    let req: ChatRequest = match serde_json::from_value(input.request) {
        Ok(r) => r,
        Err(e) => {
            return Ok(fail(
                &sink,
                GenError::new("invalid_request", e.to_string()),
            ));
        }
    };

    match gen_core::run_chat(&req, &sink).await {
        Ok(result) => Ok(serde_json::to_string(&result).unwrap_or_else(|_| "{}".into())),
        Err(e) => Ok(fail(&sink, e)),
    }
}
