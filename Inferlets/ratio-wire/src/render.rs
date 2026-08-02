//! OpenAI SSE renderer (doc/chat-refactor.md §6, §7).
//!
//! Owns everything the guest must not: ids, timestamps, the OpenAI object
//! shapes, and the `event`-keyed meta-frames the Swift app demuxes on.
//!
//! Every shape here was transcribed from real captured chat-apc streams in
//! `tests/fixtures/`, and the golden tests assert byte equality against them.
//! Field declaration order is therefore load-bearing.

use crate::event::{Channel, Event, FinishReason, NodeView, Pick};
use serde::Serialize;

/// `data:` payloads, without the `data: ` prefix or the trailing blank line.
pub type Frames = Vec<String>;

// ---------------------------------------------------------------------------
// OpenAI chunk shapes — field order matches the wire.
// ---------------------------------------------------------------------------

#[derive(Serialize)]
struct Chunk<'a> {
    id: &'a str,
    object: &'static str,
    created: i64,
    model: &'a str,
    choices: Vec<Choice>,
    #[serde(skip_serializing_if = "Option::is_none")]
    usage: Option<Usage>,
}

#[derive(Serialize)]
struct Choice {
    index: u32,
    delta: Delta,
    /// Absent (not null) on non-terminal chunks — chat-apc uses
    /// `skip_serializing_if`, and the app distinguishes the two.
    #[serde(skip_serializing_if = "Option::is_none")]
    finish_reason: Option<&'static str>,
}

#[derive(Serialize, Default)]
struct Delta {
    #[serde(skip_serializing_if = "Option::is_none")]
    role: Option<&'static str>,
    #[serde(skip_serializing_if = "Option::is_none")]
    content: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    reasoning_content: Option<String>,
}

#[derive(Serialize)]
struct Usage {
    prompt_tokens: u32,
    completion_tokens: u32,
    total_tokens: u32,
}

// ---------------------------------------------------------------------------
// Meta-frames. The app keys on `event` and silently skips unknown values.
// ---------------------------------------------------------------------------

#[derive(Serialize)]
struct MetaReady {
    event: &'static str,
}

#[derive(Serialize)]
struct MetaCodeMsg<'a> {
    event: &'static str,
    code: &'a str,
    message: &'a str,
}

#[derive(Serialize)]
struct MetaUsage {
    event: &'static str,
    prompt_tokens: u32,
    completion_tokens: u32,
    total_tokens: u32,
    #[serde(skip_serializing_if = "Option::is_none")]
    context_window: Option<u32>,
}

#[derive(Serialize)]
struct MetaGenMetrics {
    event: &'static str,
    output_tokens: u32,
    elapsed_s: f64,
    tokens_per_sec: f64,
}

#[derive(Serialize)]
struct MetaTreeStart<'a> {
    event: &'static str,
    id: &'a str,
    model: &'a str,
    breadth: u32,
    depth: u32,
    beam_width: u32,
}

#[derive(Serialize)]
struct MetaNodeStart<'a> {
    event: &'static str,
    id: &'a str,
    parent_id: &'a str,
    depth: u32,
    branch_index: u32,
}

#[derive(Serialize)]
struct MetaNodeDelta<'a> {
    event: &'static str,
    id: &'a str,
    kind: &'static str,
    text: &'a str,
}

#[derive(Serialize)]
struct MetaNodeScoring<'a> {
    event: &'static str,
    id: &'a str,
}

#[derive(Serialize)]
struct MetaNodeComplete<'a> {
    event: &'static str,
    node: &'a NodeView,
}

#[derive(Serialize)]
struct MetaLevelPruned<'a> {
    event: &'static str,
    level: u32,
    kept: &'a [String],
}

#[derive(Serialize)]
struct MetaFinalDelta<'a> {
    event: &'static str,
    text: &'a str,
}

#[derive(Serialize)]
struct MetaTreeComplete<'a> {
    event: &'static str,
    #[serde(skip_serializing_if = "Option::is_none")]
    selected_node_id: Option<&'a str>,
    #[serde(skip_serializing_if = "Option::is_none")]
    final_answer: Option<&'a str>,
    synthesized: bool,
}

#[derive(Serialize)]
struct MetaAwaiting<'a> {
    event: &'static str,
    level: u32,
    candidates: &'a [Pick],
}

// ---------------------------------------------------------------------------

/// Renders a stream of neutral [`Event`]s into the SSE dialect Rational.app
/// expects. Stateful: it owns the request id, the clock, and the role-chunk
/// latch, none of which the guest is allowed to know about.
pub struct OpenAiSse {
    id: String,
    model: String,
    created: i64,
    role_emitted: bool,
    include_usage: bool,
    prompt_tokens: u32,
    completion_tokens: u32,
}

impl OpenAiSse {
    pub fn new(id: impl Into<String>, model: impl Into<String>, created: i64) -> Self {
        Self {
            id: id.into(),
            model: model.into(),
            created,
            role_emitted: false,
            include_usage: false,
            prompt_tokens: 0,
            completion_tokens: 0,
        }
    }

    pub fn with_usage_chunk(mut self, yes: bool) -> Self {
        self.include_usage = yes;
        self
    }

    fn chunk(&self, delta: Delta, finish: Option<&'static str>) -> String {
        let c = Chunk {
            id: &self.id,
            object: "chat.completion.chunk",
            created: self.created,
            model: &self.model,
            choices: vec![Choice { index: 0, delta, finish_reason: finish }],
            usage: None,
        };
        serde_json::to_string(&c).expect("chunk serializes")
    }

    /// Zero or more `data:` payloads for one event.
    ///
    /// The single non-1:1 mapping is `Ready`, which renders TWO frames:
    /// `model_ready` then the role chunk. That fusion is what preserves the
    /// app's contract without teaching the generation core about OpenAI.
    pub fn render(&mut self, ev: &Event) -> Frames {
        match ev {
            Event::Ready => {
                self.role_emitted = true;
                vec![
                    serde_json::to_string(&MetaReady { event: "model_ready" }).unwrap(),
                    self.chunk(
                        Delta { role: Some("assistant"), ..Default::default() },
                        None,
                    ),
                ]
            }
            Event::ContentDelta { text } => vec![self.chunk(
                Delta { content: Some(text.clone()), ..Default::default() },
                None,
            )],
            Event::ReasoningDelta { text } => vec![self.chunk(
                Delta { reasoning_content: Some(text.clone()), ..Default::default() },
                None,
            )],
            // Finish is NOT rendered here — the terminal sequence has a
            // fixed order that depends on values arriving after it (token
            // counts, elapsed time), so `terminal()` owns it. Rendering it
            // inline produced finish → metrics → usage-meta → usage-chunk,
            // which is a different stream from chat-apc's.
            Event::Finish { .. } => Vec::new(),
            Event::Warning { code, message } => {
                vec![serde_json::to_string(&MetaCodeMsg {
                    event: "warning",
                    code,
                    message,
                })
                .unwrap()]
            }
            Event::Error { code, message, .. } => {
                vec![serde_json::to_string(&MetaCodeMsg { event: "error", code, message }).unwrap()]
            }
            // Recorded, not rendered: the usage meta-frame's position in the
            // terminal sequence is fixed, so `terminal()` emits it.
            Event::Usage { prompt_tokens, completion_tokens, .. } => {
                self.prompt_tokens = *prompt_tokens;
                self.completion_tokens = *completion_tokens;
                Vec::new()
            }
            // Also terminal-sequence owned; the gateway supplies elapsed time.
            Event::GenerationMetrics { .. } => Vec::new(),

            // ---- tree frames: pass through, with gateway-owned id/model ----
            Event::TreeStart { breadth, depth, beam_width } => {
                vec![serde_json::to_string(&MetaTreeStart {
                    event: "tree_start",
                    id: &self.id,
                    model: &self.model,
                    breadth: *breadth,
                    depth: *depth,
                    beam_width: *beam_width,
                })
                .unwrap()]
            }
            Event::NodeStart { id, parent_id, depth, branch_index } => {
                vec![serde_json::to_string(&MetaNodeStart {
                    event: "node_start",
                    id,
                    parent_id,
                    depth: *depth,
                    branch_index: *branch_index,
                })
                .unwrap()]
            }
            Event::NodeDelta { id, channel, text } => {
                vec![serde_json::to_string(&MetaNodeDelta {
                    event: "node_delta",
                    id,
                    kind: match channel {
                        Channel::Reasoning => "reasoning",
                        Channel::Answer => "answer",
                    },
                    text,
                })
                .unwrap()]
            }
            Event::NodeScoring { id } => {
                vec![serde_json::to_string(&MetaNodeScoring { event: "node_scoring", id }).unwrap()]
            }
            Event::NodeComplete { node } => {
                vec![serde_json::to_string(&MetaNodeComplete { event: "node_complete", node })
                    .unwrap()]
            }
            Event::LevelPruned { level, kept } => {
                vec![serde_json::to_string(&MetaLevelPruned {
                    event: "level_pruned",
                    level: *level,
                    kept,
                })
                .unwrap()]
            }
            Event::FinalDelta { text } => {
                vec![serde_json::to_string(&MetaFinalDelta { event: "final_delta", text }).unwrap()]
            }
            Event::TreeComplete { selected_node_id, final_answer, synthesized } => {
                vec![serde_json::to_string(&MetaTreeComplete {
                    event: "tree_complete",
                    selected_node_id: selected_node_id.as_deref(),
                    final_answer: final_answer.as_deref(),
                    synthesized: *synthesized,
                })
                .unwrap()]
            }
            Event::AwaitingSelection { level, candidates } => {
                vec![serde_json::to_string(&MetaAwaiting {
                    event: "awaiting_selection",
                    level: *level,
                    candidates,
                })
                .unwrap()]
            }
        }
    }

    /// The complete terminal sequence, in the one order the wire contract
    /// allows (verified against captured chat-apc streams):
    ///
    /// ```text
    /// finish chunk
    /// [OpenAI usage chunk]      — only under stream_options.include_usage
    /// [generation_metrics]      — only when finite and positive
    /// [usage meta-frame]
    /// [DONE]
    /// ```
    ///
    /// Taking all three at once is deliberate: the usage chunk needs token
    /// counts that arrive AFTER `Finish`, and `generation_metrics` needs an
    /// elapsed time only the gateway knows. Rendering them as they arrive
    /// cannot produce this order.
    pub fn terminal(
        &mut self,
        finish: FinishReason,
        usage: Option<UsageCounts>,
        metrics: Option<MetricsCounts>,
        error: Option<(String, String)>,
    ) -> Frames {
        let mut out = vec![self.chunk(Delta::default(), Some(finish_wire(finish)))];

        if let Some(u) = usage {
            self.prompt_tokens = u.prompt_tokens;
            self.completion_tokens = u.completion_tokens;
        }
        if self.include_usage {
            let c = Chunk {
                id: &self.id,
                object: "chat.completion.chunk",
                created: self.created,
                model: &self.model,
                choices: vec![],
                usage: Some(Usage {
                    prompt_tokens: self.prompt_tokens,
                    completion_tokens: self.completion_tokens,
                    total_tokens: self.prompt_tokens.saturating_add(self.completion_tokens),
                }),
            };
            out.push(serde_json::to_string(&c).expect("usage chunk serializes"));
        }
        // An in-band error rides after the terminal chunk, matching chat-apc.
        if let Some((code, message)) = &error {
            out.push(
                serde_json::to_string(&MetaCodeMsg { event: "error", code, message }).unwrap(),
            );
        }
        if let Some(m) = metrics {
            // Suppressed unless it would pass the app's strict decode.
            if m.output_tokens > 0 && m.elapsed_s.is_finite() && m.elapsed_s > 0.0 {
                out.push(
                    serde_json::to_string(&MetaGenMetrics {
                        event: "generation_metrics",
                        output_tokens: m.output_tokens,
                        elapsed_s: m.elapsed_s,
                        tokens_per_sec: m.output_tokens as f64 / m.elapsed_s,
                    })
                    .unwrap(),
                );
            }
        }
        if let Some(u) = usage {
            out.push(
                serde_json::to_string(&MetaUsage {
                    event: "usage",
                    prompt_tokens: u.prompt_tokens,
                    completion_tokens: u.completion_tokens,
                    total_tokens: u.prompt_tokens.saturating_add(u.completion_tokens),
                    context_window: u.context_window,
                })
                .unwrap(),
            );
        }
        out.push("[DONE]".into());
        out
    }
}

#[derive(Debug, Clone, Copy)]
pub struct UsageCounts {
    pub prompt_tokens: u32,
    pub completion_tokens: u32,
    pub context_window: Option<u32>,
}

#[derive(Debug, Clone, Copy)]
pub struct MetricsCounts {
    pub output_tokens: u32,
    pub elapsed_s: f64,
}

fn finish_wire(r: FinishReason) -> &'static str {
    r.as_wire()
}
