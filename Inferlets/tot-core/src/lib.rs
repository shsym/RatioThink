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
pub mod tree;
