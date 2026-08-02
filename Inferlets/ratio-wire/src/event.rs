//! The complete event vocabulary (doc/chat-refactor.md §5.1).
//!
//! Every variant is declared NOW, including the tree/interactive ones that no
//! inferlet emits yet. That is the anti-rewrite lever: when ToT and Best-of-N
//! are ported, they add a producer, not a protocol change.
//!
//! Variants own their data (`String`, not `&'a str`) because a sink that
//! crosses a serialization boundary cannot borrow.

use serde::{Deserialize, Serialize};

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum FinishReason {
    Stop,
    Length,
    ToolCalls,
    Error,
    Cancelled,
}

impl FinishReason {
    /// The OpenAI wire spelling.
    pub fn as_wire(self) -> &'static str {
        match self {
            Self::Stop => "stop",
            Self::Length => "length",
            Self::ToolCalls => "tool_calls",
            Self::Error => "error",
            Self::Cancelled => "cancelled",
        }
    }
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct ToolCallDraft {
    pub name: String,
    pub arguments: String,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum Channel {
    Reasoning,
    Answer,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(tag = "t", rename_all = "snake_case")]
pub enum Event {
    // ---- lifecycle ----
    /// Commit signal. Prompt is built; generation is about to start.
    Ready,
    Warning {
        code: String,
        message: String,
    },
    /// No `http_status`: mapping a guest code to an HTTP status is the
    /// gateway's job (§5.1). The guest reports semantics only.
    Error {
        code: String,
        message: String,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        param: Option<String>,
    },
    Usage {
        prompt_tokens: u32,
        completion_tokens: u32,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        context_window: Option<u32>,
    },
    GenerationMetrics {
        output_tokens: u32,
        elapsed_s: f64,
        tokens_per_sec: f64,
    },
    Finish {
        reason: FinishReason,
    },

    // ---- linear generation (slice 1) ----
    ContentDelta {
        text: String,
    },
    ReasoningDelta {
        text: String,
    },

    // ---- tree generation: declared now, produced in a later phase ----
    //
    // Shapes lifted from real captured chat-apc streams (tests/fixtures), not
    // from reading the source. Note what is ABSENT: `TreeStart` carries no
    // tree id and no model name. On the wire those are `"id":"tot-0"` /
    // `"bon-0"` and `"model":"qwen"`, but both are gateway-owned (§3) — and
    // guest-minted tree ids are exactly the `bon-0` collision bug, since a
    // per-request wasm instance restarts its counter every time.
    TreeStart {
        breadth: u32,
        depth: u32,
        beam_width: u32,
    },
    NodeStart {
        id: String,
        parent_id: String,
        depth: u32,
        branch_index: u32,
    },
    NodeDelta {
        id: String,
        /// Serializes as `kind` on the wire.
        #[serde(rename = "kind")]
        channel: Channel,
        text: String,
    },
    NodeScoring {
        id: String,
    },
    /// The wire nests this under a `node` key.
    NodeComplete {
        node: NodeView,
    },
    LevelPruned {
        level: u32,
        kept: Vec<String>,
    },
    /// Synthesis text for the final answer, streamed after the beam settles.
    FinalDelta {
        text: String,
    },
    TreeComplete {
        #[serde(default, skip_serializing_if = "Option::is_none")]
        selected_node_id: Option<String>,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        final_answer: Option<String>,
        synthesized: bool,
    },

    // ---- interactive (Best-of-N) ----
    AwaitingSelection {
        level: u32,
        candidates: Vec<Pick>,
    },
}

/// Mirrors `chat-apc`'s `tot::stream::NodeView` field for field, in the same
/// declaration order and with the same skip rules. `serde_json` emits fields
/// in declaration order, so this ordering is load-bearing for the byte
/// equality the golden tests assert.
///
/// The golden test caught two mistakes here that source-reading alone had not:
/// `score` is `u8` (renders `7`, not `7.0`), and `reasoning` / `error` /
/// `score_error` exist but are skipped when empty, so a clean capture never
/// shows them.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct NodeView {
    pub id: String,
    /// `None` serializes as `null` — not skipped, matching the source.
    pub parent_id: Option<String>,
    pub depth: u32,
    pub branch_index: Option<u32>,
    pub content: String,
    #[serde(default, skip_serializing_if = "String::is_empty")]
    pub reasoning: String,
    /// 1-10, or `null` for Best-of-N, which does not score.
    pub score: Option<u8>,
    pub status: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub error: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub score_error: Option<String>,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct Pick {
    pub id: String,
    pub branch_index: u32,
    pub snapshot_name: String,
}

/// The transport-neutral terminal value returned by an inferlet.
///
/// Deliberately NOT an OpenAI object: no ids, no timestamps, no `chatcmpl-`.
/// The gateway assembles the OpenAI response from this (§3.1).
#[derive(Debug, Clone, Default, PartialEq, Serialize, Deserialize)]
pub struct GenResult {
    pub content: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub reasoning: Option<String>,
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub tool_calls: Vec<ToolCallDraft>,
    pub finish_reason: Option<FinishReason>,
    pub prompt_tokens: u32,
    pub completion_tokens: u32,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub context_window: Option<u32>,
    /// KV reuse diagnostics. `found` alone is not a hit: eviction SUSPENDS
    /// rather than deletes, so an evicted boundary opens successfully and
    /// replays. Until pie reports residency, `reused_tokens` is the best
    /// available signal and a silent replay is still invisible.
    #[serde(default)]
    pub boundary_found: bool,
    #[serde(default)]
    pub reused_tokens: u32,
}

/// Sink for generation events. Infallible by construction: `session::send`
/// has no error channel, so there is nothing to report (§6).
///
/// `&self`, not `&mut self` — that is what lets concurrent branch futures
/// share one handle with no lock when ToT lands.
pub trait EventSink {
    fn emit(&self, ev: Event);
    fn cancelled(&self) -> bool {
        false
    }
}

/// Host-side test sink.
#[derive(Default)]
pub struct VecSink {
    events: std::cell::RefCell<Vec<Event>>,
}

impl VecSink {
    pub fn take(&self) -> Vec<Event> {
        self.events.borrow().clone()
    }
}

impl EventSink for VecSink {
    fn emit(&self, ev: Event) {
        self.events.borrow_mut().push(ev);
    }
}
