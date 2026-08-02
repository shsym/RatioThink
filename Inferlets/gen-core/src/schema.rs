//! Request schema. Ported from `chat-apc/src/chat/completions.rs:160-441`.
//!
//! `gen-core` owns request semantics; the gateway parses only `model`,
//! `stream`, `stream_options` and routing fields (doc §3). Duplicating this
//! host-side would recreate the drift the refactor exists to remove.

use serde::{Deserialize, Serialize};

/// Which trailing cue opens the assistant turn.
/// Ported verbatim from `completions.rs:234-239`.
#[derive(Copy, Clone, Debug, PartialEq, Eq)]
pub enum CueMode {
    /// No cue — tree-of-thought defers it to each forked branch.
    None,
    Generic,
    Thinking,
}

pub type RequestToolCall = serde_json::Value;

#[derive(Debug, Clone, Deserialize, Serialize)]
pub struct ChatMessage {
    pub role: String,
    #[serde(default, deserialize_with = "deserialize_message_content")]
    pub content: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub tool_call_id: Option<serde_json::Value>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub tool_calls: Option<serde_json::Value>,
}

impl ChatMessage {
    /// `completions.rs`: a null/absent content becomes `""`, never an error.
    pub fn content_str(&self) -> Option<&str> {
        self.content.as_deref()
    }
}

#[derive(Deserialize)]
#[serde(untagged)]
enum ContentInput {
    Text(String),
    Parts(Vec<ContentPart>),
    Null,
}

#[derive(Deserialize)]
struct ContentPart {
    #[serde(default)]
    text: Option<String>,
}

/// Accepts the plain-string form OR OpenAI's multi-part array.
///
/// PARITY: parts are concatenated with **no separator** (`join("")`). Adding
/// one would change the prompt bytes and therefore the generated text.
pub fn deserialize_message_content<'de, D>(d: D) -> Result<Option<String>, D::Error>
where
    D: serde::Deserializer<'de>,
{
    use serde::Deserialize as _;
    Ok(match Option::<ContentInput>::deserialize(d)? {
        None | Some(ContentInput::Null) => None,
        Some(ContentInput::Text(s)) => Some(s),
        Some(ContentInput::Parts(parts)) => Some(
            parts
                .iter()
                .filter_map(|p| p.text.as_deref())
                .collect::<Vec<_>>()
                .join(""),
        ),
    })
}

#[derive(Debug, Clone, Deserialize)]
pub struct ChatRequest {
    pub model: String,
    pub messages: Vec<ChatMessage>,
    #[serde(default)]
    pub stream: bool,
    #[serde(default)]
    pub temperature: Option<f32>,
    #[serde(default)]
    pub top_p: Option<f32>,
    #[serde(default)]
    pub max_tokens: Option<usize>,
    #[serde(default)]
    pub max_completion_tokens: Option<usize>,
    /// chat-apc extension: selects `CueMode::Thinking`.
    #[serde(default)]
    pub thinking: bool,
    /// Accepted but not honored in this slice — warned, not rejected, so the
    /// app's Repeat Boost toggle keeps working (doc §8.1).
    #[serde(default)]
    pub speculation: Option<serde_json::Value>,
    /// Same: accepted, warned, deferred.
    #[serde(default)]
    pub cache: Option<serde_json::Value>,
    /// Conversation identity + caching policy. Client-supplied: the gateway
    /// cannot derive conversation identity from `messages`, so this must ride
    /// the request. Absent → no reuse, which is the pre-boundary behaviour.
    #[serde(default)]
    pub boundary: Option<crate::boundary::BoundaryDirective>,
}

pub const DEFAULT_TEMPERATURE: f32 = 0.7;
pub const DEFAULT_TOP_P: f32 = 1.0;
pub const DEFAULT_MAX_TOKENS: usize = 1024;

impl ChatRequest {
    pub fn cue_mode(&self) -> CueMode {
        if self.thinking { CueMode::Thinking } else { CueMode::Generic }
    }

    pub fn temperature_or_default(&self) -> f32 {
        self.temperature.unwrap_or(DEFAULT_TEMPERATURE)
    }

    pub fn top_p_or_default(&self) -> f32 {
        self.top_p.unwrap_or(DEFAULT_TOP_P)
    }

    /// PARITY: `max_tokens` then the `max_completion_tokens` alias, then the
    /// default. The value reaching the decode loop is already effective —
    /// passing a raw request value changes the `length` cutoff.
    pub fn effective_max_tokens(&self, ceiling: usize) -> usize {
        let want = self
            .max_tokens
            .or(self.max_completion_tokens)
            .unwrap_or(DEFAULT_MAX_TOKENS);
        if ceiling > 0 { want.min(ceiling) } else { want }
    }
}

/// Semantic sampling validation, ported from chat-apc. Without it a request
/// like `max_tokens: 0` or `temperature: 5` commits the SSE stream and only
/// then misbehaves, instead of failing as a clean 400.
pub fn validate_sampling(req: &ChatRequest) -> Result<(), (&'static str, String)> {
    if let Some(t) = req.temperature {
        if !(0.0..=2.0).contains(&t) || !t.is_finite() {
            return Err((
                "invalid_request",
                format!("temperature must be in [0.0, 2.0]; got {t}"),
            ));
        }
    }
    if let Some(p) = req.top_p {
        if !p.is_finite() || p <= 0.0 || p > 1.0 {
            return Err((
                "invalid_request",
                format!("top_p must be in (0.0, 1.0]; got {p}"),
            ));
        }
    }
    for (name, v) in [("max_tokens", req.max_tokens), ("max_completion_tokens", req.max_completion_tokens)] {
        if let Some(v) = v {
            if v == 0 {
                return Err(("invalid_request", format!("{name} must be >= 1; got 0")));
            }
        }
    }
    if req.messages.is_empty() {
        return Err(("invalid_request", "messages must be a non-empty array".into()));
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn multipart_content_joins_without_separator() {
        let m: ChatMessage = serde_json::from_value(serde_json::json!({
            "role": "user",
            "content": [{"type":"text","text":"a"},{"type":"text","text":"b"}]
        }))
        .unwrap();
        assert_eq!(m.content_str(), Some("ab"), "a separator would change prompt bytes");
    }

    #[test]
    fn plain_string_content() {
        let m: ChatMessage =
            serde_json::from_value(serde_json::json!({"role":"user","content":"hi"})).unwrap();
        assert_eq!(m.content_str(), Some("hi"));
    }

    #[test]
    fn absent_content_is_none_not_error() {
        let m: ChatMessage =
            serde_json::from_value(serde_json::json!({"role":"assistant"})).unwrap();
        assert_eq!(m.content_str(), None);
    }

    #[test]
    fn max_completion_tokens_is_an_alias() {
        let r: ChatRequest = serde_json::from_value(serde_json::json!({
            "model":"m","messages":[],"max_completion_tokens":7
        }))
        .unwrap();
        assert_eq!(r.effective_max_tokens(0), 7);
    }

    #[test]
    fn max_tokens_wins_over_alias() {
        let r: ChatRequest = serde_json::from_value(serde_json::json!({
            "model":"m","messages":[],"max_tokens":5,"max_completion_tokens":7
        }))
        .unwrap();
        assert_eq!(r.effective_max_tokens(0), 5);
    }

    fn req(v: serde_json::Value) -> ChatRequest {
        serde_json::from_value(v).unwrap()
    }

    #[test]
    fn rejects_zero_max_tokens() {
        let r = req(serde_json::json!({"model":"m","messages":[{"role":"user"}],"max_tokens":0}));
        assert!(validate_sampling(&r).is_err(), "max_tokens 0 must not reach the sampler");
    }

    #[test]
    fn rejects_out_of_range_sampling() {
        for bad in [serde_json::json!({"temperature":5.0}), serde_json::json!({"top_p":0.0}),
                    serde_json::json!({"top_p":1.5})] {
            let mut v = serde_json::json!({"model":"m","messages":[{"role":"user"}]});
            for (k, x) in bad.as_object().unwrap() { v[k] = x.clone(); }
            assert!(validate_sampling(&req(v.clone())).is_err(), "{v} should be rejected");
        }
    }

    #[test]
    fn accepts_valid_sampling() {
        let r = req(serde_json::json!({"model":"m","messages":[{"role":"user"}],
                                       "temperature":0.0,"top_p":1.0,"max_tokens":16}));
        assert!(validate_sampling(&r).is_ok());
    }

    #[test]
    fn rejects_empty_messages() {
        assert!(validate_sampling(&req(serde_json::json!({"model":"m","messages":[]}))).is_err());
    }

    #[test]
    fn ceiling_clamps() {
        let r: ChatRequest =
            serde_json::from_value(serde_json::json!({"model":"m","messages":[]})).unwrap();
        assert_eq!(r.effective_max_tokens(64), 64);
    }
}
