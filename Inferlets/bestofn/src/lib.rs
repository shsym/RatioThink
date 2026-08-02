//! The Best-of-N inferlet: a thin shell over `bestofn-core`.
//!
//! Same shape as `chat` and `tot` — deserialize, wire a `SessionSink`, run,
//! return the neutral result. The only difference is that not every request
//! generates: commit and release emit no events and return JSON, which the
//! gateway's tree-v1 driver handles by not opening a stream for them.

use bestofn_core::schema::BestOfNInput;
use gen_core::GenError;
use ratio_wire::{Envelope, Event, EventSink, RunInput};
use std::cell::{Cell, RefCell};

struct SessionSink {
    seq: Cell<u32>,
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
    // caller may post the body at the top level. Accept both.
    let body = match input.request.get("input") {
        Some(inner) => inner.clone(),
        None => input.request.clone(),
    };
    let req: BestOfNInput = match serde_json::from_value(body) {
        Ok(r) => r,
        Err(e) => return Ok(fail(&sink, GenError::new("invalid_request", e.to_string()))),
    };

    match bestofn_core::run(req, &sink).await {
        Ok(out) => Ok(serde_json::to_string(&out).unwrap_or_else(|_| "{}".into())),
        Err(e) => Ok(fail(&sink, e)),
    }
}
