//! Transport-neutral wire vocabulary shared by the gateway (host) and the
//! inferlets (wasm32-wasip2).
//!
//! Dependency hygiene is a hard constraint: only `serde` and `serde_json`.
//! Anything that pulls in `wstd`, the `inferlet` SDK, or `tokio` breaks one of
//! the two build targets.

pub mod envelope;
pub mod event;
pub mod render;

pub use envelope::{Envelope, ProtocolError, SeqChecker};
pub use event::{
    Channel, Event, EventSink, FinishReason, GenResult, NodeView, Pick, ToolCallDraft, VecSink,
};
pub use render::{MetricsCounts, OpenAiSse, UsageCounts};

/// What the gateway hands an inferlet via `launch_process`.
///
/// The client's HTTP body rides in `request` untouched — the gateway parses
/// only routing fields, so an inferlet-specific field it has never heard of
/// still arrives intact (doc §7.1).
#[derive(Debug, Clone, serde::Serialize, serde::Deserialize)]
pub struct RunInput {
    pub v: u32,
    pub request_id: String,
    #[serde(default)]
    pub stream: bool,
    pub request: serde_json::Value,
}
