//! Transport conformance target for phase 1.
//!
//! Deliberately does NO model work. The first `session::send` happens on the
//! very first line so the emit lands as early as possible relative to the
//! client's post-response channel registration — that is precisely the window
//! where `client.rs:604` drops orphan events (doc/chat-refactor.md §2.5).
//!
//! Input  : {"count": u32, "hold_ms": u64}
//! Emits  : count events, `{"v":1,"seq":i,"e":{"t":"echo","i":i}}`
//! Returns: {"emitted":N,"cancelled":bool}

use inferlet::Result;
use serde::Deserialize;

#[derive(Deserialize)]
struct Input {
    #[serde(default = "default_count")]
    count: u32,
    /// Stay alive this long after emitting, polling for a cancel signal.
    #[serde(default)]
    hold_ms: u64,
}

fn default_count() -> u32 {
    4
}

fn emit(seq: u32, body: &str) {
    inferlet::session::send(&format!(r#"{{"v":1,"seq":{seq},"e":{body}}}"#));
}

#[inferlet::main]
async fn main(input: Input) -> Result<String> {
    // Emit immediately — before any other work — to maximise the race window.
    for i in 0..input.count {
        emit(i, &format!(r#"{{"t":"echo","i":{i}}}"#));
    }

    // Block on the signal future rather than polling `get()`: a WASI future is
    // resolved by the host, and awaiting its pollable is the documented way to
    // observe that (`FutureStringExt::wait_async`). Polling `get()` in a sleep
    // loop never advances it, which is what made the first cancel test fail.
    let mut cancelled = false;
    if input.hold_ms > 0 {
        use inferlet::FutureStringExt;
        if inferlet::session::receive().wait_async().await.is_some() {
            cancelled = true;
        }
    }

    emit(
        input.count,
        &format!(r#"{{"t":"finish","cancelled":{cancelled}}}"#),
    );

    Ok(format!(
        r#"{{"emitted":{},"cancelled":{}}}"#,
        input.count + 1,
        cancelled
    ))
}
