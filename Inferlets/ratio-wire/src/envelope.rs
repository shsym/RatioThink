//! The `session::send` envelope and its sequence contract (§5.2, §5.3).

use crate::event::Event;
use serde::{Deserialize, Serialize};

pub const ENVELOPE_VERSION: u32 = 1;

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct Envelope {
    pub v: u32,
    pub seq: u32,
    /// Raw so an unknown `t` cannot fail the decode. A derived
    /// internally-tagged enum WOULD error here — that is the trap §5.2 warns
    /// about, and `decode_event` handles it explicitly instead.
    pub e: serde_json::Value,
}

impl Envelope {
    pub fn new(seq: u32, ev: &Event) -> Self {
        Self {
            v: ENVELOPE_VERSION,
            seq,
            e: serde_json::to_value(ev).expect("event serializes"),
        }
    }

    pub fn to_line(&self) -> String {
        serde_json::to_string(self).expect("envelope serializes")
    }

    pub fn tag(&self) -> Option<&str> {
        self.e.get("t").and_then(serde_json::Value::as_str)
    }

    /// Tags this build knows. A tag in this list that fails to deserialize is
    /// a PROTOCOL ERROR, not a future event to ignore — conflating the two
    /// silently swallows a producer bug (a renamed field, a wrong type).
    const KNOWN_TAGS: &'static [&'static str] = &[
        "ready",
        "warning",
        "error",
        "usage",
        "generation_metrics",
        "finish",
        "content_delta",
        "reasoning_delta",
        "tree_start",
        "node_start",
        "node_delta",
        "node_scoring",
        "node_complete",
        "level_pruned",
        "final_delta",
        "tree_complete",
        "awaiting_selection",
    ];

    /// `Ok(Some(ev))` for a known event, `Ok(None)` for an unknown tag we are
    /// meant to ignore (§5.3 rule 5), `Err` for a malformed payload — including
    /// a KNOWN tag that fails to deserialize.
    pub fn decode_event(&self) -> Result<Option<Event>, ProtocolError> {
        let Some(tag) = self.tag() else {
            return Err(ProtocolError::Malformed("event has no `t` tag".into()));
        };
        match serde_json::from_value::<Event>(self.e.clone()) {
            Ok(ev) => Ok(Some(ev)),
            Err(e) if Self::KNOWN_TAGS.contains(&tag) => Err(ProtocolError::Malformed(format!(
                "event `{tag}` is known but failed to decode: {e}"
            ))),
            // Genuinely unknown tag — a newer producer. Ignore it.
            Err(_) => Ok(None),
        }
    }
}

#[derive(Debug, PartialEq)]
pub enum ProtocolError {
    Malformed(String),
    /// Fails closed — graceful degradation applies to tags, not versions.
    UnsupportedVersion(u32),
    /// `session::send` silently discards delivery failures (§2.4), so a gap
    /// is the only evidence that something was lost.
    SequenceGap { expected: u32, got: u32 },
}

impl std::fmt::Display for ProtocolError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            Self::Malformed(s) => write!(f, "malformed envelope: {s}"),
            Self::UnsupportedVersion(v) => write!(
                f,
                "unsupported envelope version {v} (expected {ENVELOPE_VERSION})"
            ),
            Self::SequenceGap { expected, got } => {
                write!(f, "event sequence gap: expected seq {expected}, got {got}")
            }
        }
    }
}

impl std::error::Error for ProtocolError {}

#[derive(Default)]
pub struct SeqChecker {
    next: u32,
}

impl SeqChecker {
    pub fn accept(&mut self, raw: &str) -> Result<Envelope, ProtocolError> {
        let env: Envelope =
            serde_json::from_str(raw).map_err(|e| ProtocolError::Malformed(e.to_string()))?;
        if env.v != ENVELOPE_VERSION {
            return Err(ProtocolError::UnsupportedVersion(env.v));
        }
        if env.seq != self.next {
            return Err(ProtocolError::SequenceGap {
                expected: self.next,
                got: env.seq,
            });
        }
        self.next += 1;
        Ok(env)
    }
}
