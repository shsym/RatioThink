//! Reasoning + tool-use streaming-decoder wrappers for the chat loop.
//!
//! [`super::completions`] runs both decoders alongside `chat::Decoder`
//! on every generation loop iteration: reasoning fires
//! `reasoning_content` SSE deltas, tool-use terminates the loop with
//! a complete `Event::Call` that becomes an OpenAI `tool_calls`
//! delta on the terminal chunk. The wrappers exist so swapping out
//! the SDK surface (or adding APC-specific bookkeeping) is one-edit
//! local rather than scattered across `completions.rs`.
//!
//! TODO(mcp::client): when the chat loop grows server-side tool
//! execution, plumb `inferlet::mcp` here so a single APC turn can
//! pull tool results from an MCP server and feed them back into the
//! generator via [`super::completions`]. Today the wire matches
//! OpenAI's client-side execution model — pie emits the call, the
//! caller runs the tool and resubmits the result on the next turn.

use inferlet::Result;
use inferlet::model::Model;
use inferlet::reasoning::Event as ReasoningEvent;

// =============================================================================
// Tool-use decoder — wraps `inferlet::tools::Decoder`.
// =============================================================================

/// Streaming detector for tool-call events inside generated text.
///
/// The chat loop feeds this alongside `chat::Decoder` every iteration; a
/// complete `Event::Call` terminates the loop and becomes the OpenAI
/// `tool_calls` delta on the terminal chunk (see [`super::completions`]).
pub struct ToolUseDecoder {
    inner: inferlet::tools::Decoder,
}

impl ToolUseDecoder {
    pub fn new(model: &Model) -> Self {
        Self {
            inner: inferlet::tools::Decoder::new(model),
        }
    }

    pub fn feed(&mut self, tokens: &[u32]) -> Result<inferlet::tools::Event> {
        self.inner.feed(tokens)
    }

    #[allow(dead_code)]
    pub fn reset(&mut self) {
        self.inner.reset();
    }
}

// =============================================================================
// Reasoning decoder — wraps `inferlet::reasoning::Decoder`.
// =============================================================================

/// Streaming detector for thinking-block events (`<think>...`, plus Gemma 4's
/// `<|channel>thought ... <channel|>` channel when the host decoder lacks it).
///
/// The chat loop feeds this every iteration; its events surface as
/// OpenAI-shape `reasoning_content` deltas (see [`super::completions`]).
pub struct ReasoningDecoder {
    inner: inferlet::reasoning::Decoder,
    gemma: Option<GemmaChannelDecoder>,
}

impl ReasoningDecoder {
    pub fn new(model: &Model) -> Self {
        Self {
            inner: inferlet::reasoning::Decoder::new(model),
            gemma: GemmaChannelDecoder::for_model(model),
        }
    }

    pub fn feed(&mut self, tokens: &[u32]) -> Result<ReasoningEvent> {
        let host = self.inner.feed(tokens)?;
        if !matches!(host, ReasoningEvent::Idle) {
            return Ok(host);
        }
        Ok(self
            .gemma
            .as_mut()
            .map(|d| d.feed(tokens))
            .unwrap_or(ReasoningEvent::Idle))
    }

    /// True when the Gemma fallback has consumed a prefix of
    /// `<|channel>thought` but has not yet seen the complete marker. The chat
    /// decoder may already have text for that prefix; callers must hold it out
    /// of the visible answer until the marker either completes or fails.
    pub fn suppress_content_for_pending_marker(&self) -> bool {
        self.gemma
            .as_ref()
            .is_some_and(GemmaChannelDecoder::is_start_pending)
    }

    /// Text for the trailing Gemma thought-channel marker prefix matched so far
    /// on this batch, if any. The chat decoder may have surfaced it inside the
    /// same delta as visible answer text; callers should withhold exactly this
    /// suffix, not the whole delta.
    pub fn pending_start_marker_text(&self) -> Option<String> {
        self.gemma
            .as_ref()
            .and_then(GemmaChannelDecoder::pending_start_marker_text)
    }

    /// Text for a Gemma thought-channel opener that completed on this batch, if
    /// any. This lets callers discard a previously buffered partial opener and
    /// recover any visible text that preceded a complete marker in the same
    /// chat delta.
    pub fn completed_start_marker_text(&self) -> Option<String> {
        self.gemma
            .as_ref()
            .and_then(GemmaChannelDecoder::completed_start_marker_text)
    }

    #[allow(dead_code)]
    pub fn reset(&mut self) {
        self.inner.reset();
        if let Some(gemma) = &mut self.gemma {
            gemma.reset();
        }
    }
}

pub fn has_gemma_channel_markers(model: &Model) -> bool {
    let tokenizer = model.tokenizer();
    tokenizer_has_gemma_channel_markers(&tokenizer)
}

pub fn gemma_thinking_cue_tokens(model: &Model) -> Option<Vec<u32>> {
    has_gemma_channel_markers(model).then(|| model.tokenizer().encode(GEMMA_THINKING_CUE))
}

const GEMMA_THINKING_CUE: &str = "<|turn>model\n";
const GEMMA_THOUGHT_OPEN_PREFIX: &str = "<|channel>";
const GEMMA_THOUGHT_OPEN_NAME: &str = "thought";
const GEMMA_THOUGHT_CLOSE: &str = "<channel|>";

fn tokenizer_has_gemma_channel_markers(tokenizer: &inferlet::model::Tokenizer) -> bool {
    let (_ids, tokens) = tokenizer.special_tokens();
    let specials = tokens
        .iter()
        .filter_map(|bytes| std::str::from_utf8(bytes).ok())
        .collect::<std::collections::HashSet<_>>();
    specials.contains("<|turn>")
        && specials.contains("<turn|>")
        && specials.contains(GEMMA_THOUGHT_OPEN_PREFIX)
        && specials.contains(GEMMA_THOUGHT_CLOSE)
}

struct GemmaChannelDecoder {
    start_ids: Vec<u32>,
    end_ids: Vec<u32>,
    inside: bool,
    token_buf: Vec<u32>,
    text_emitted: usize,
    match_pos: usize,
    completed_start_marker_text: Option<String>,
    detokenize: Box<dyn Fn(&[u32]) -> String + Send>,
}

impl GemmaChannelDecoder {
    fn for_model(model: &Model) -> Option<Self> {
        let tokenizer = model.tokenizer();
        if !tokenizer_has_gemma_channel_markers(&tokenizer) {
            return None;
        }
        let mut start_ids = tokenizer.encode(GEMMA_THOUGHT_OPEN_PREFIX);
        start_ids.extend(tokenizer.encode(GEMMA_THOUGHT_OPEN_NAME));
        let end_ids = tokenizer.encode(GEMMA_THOUGHT_CLOSE);
        if start_ids.is_empty() || end_ids.is_empty() {
            return None;
        }
        let decode_tokenizer = model.tokenizer();
        Some(Self::new_with_state(start_ids, end_ids, move |tokens| {
            decode_tokenizer.decode(tokens).unwrap_or_default()
        }))
    }

    #[cfg(test)]
    fn new(
        start_ids: Vec<u32>,
        end_ids: Vec<u32>,
        detokenize: impl Fn(&[u32]) -> String + Send + 'static,
    ) -> Self {
        Self::new_with_state(start_ids, end_ids, detokenize)
    }

    fn new_with_state(
        start_ids: Vec<u32>,
        end_ids: Vec<u32>,
        detokenize: impl Fn(&[u32]) -> String + Send + 'static,
    ) -> Self {
        Self {
            start_ids,
            end_ids,
            inside: false,
            token_buf: Vec::new(),
            text_emitted: 0,
            match_pos: 0,
            completed_start_marker_text: None,
            detokenize: Box::new(detokenize),
        }
    }

    #[cfg(test)]
    fn new_for_testing(
        start_ids: Vec<u32>,
        end_ids: Vec<u32>,
        detokenize: impl Fn(&[u32]) -> String + Send + 'static,
    ) -> Self {
        Self::new(start_ids, end_ids, detokenize)
    }

    fn feed(&mut self, tokens: &[u32]) -> ReasoningEvent {
        self.completed_start_marker_text = None;
        if !self.inside {
            for &t in tokens {
                if self.match_pos < self.start_ids.len() && t == self.start_ids[self.match_pos] {
                    self.match_pos += 1;
                    if self.match_pos == self.start_ids.len() {
                        self.completed_start_marker_text = Some((self.detokenize)(&self.start_ids));
                        self.inside = true;
                        self.match_pos = 0;
                        self.token_buf.clear();
                        self.text_emitted = 0;
                        return ReasoningEvent::Start;
                    }
                } else {
                    self.match_pos = 0;
                }
            }
            ReasoningEvent::Idle
        } else {
            for &t in tokens {
                if self.match_pos < self.end_ids.len() && t == self.end_ids[self.match_pos] {
                    self.match_pos += 1;
                    if self.match_pos == self.end_ids.len() {
                        let full = (self.detokenize)(&self.token_buf);
                        self.inside = false;
                        self.match_pos = 0;
                        self.token_buf.clear();
                        self.text_emitted = 0;
                        return ReasoningEvent::End(full);
                    }
                } else {
                    self.match_pos = 0;
                }
                self.token_buf.push(t);
            }
            let full = (self.detokenize)(&self.token_buf);
            let safe_end = safe_emit_end(&full);
            let delta = if safe_end > self.text_emitted {
                full[self.text_emitted..safe_end].to_string()
            } else {
                String::new()
            };
            self.text_emitted = safe_end;
            if delta.is_empty() {
                ReasoningEvent::Idle
            } else {
                ReasoningEvent::Delta(delta)
            }
        }
    }

    fn reset(&mut self) {
        self.inside = false;
        self.token_buf.clear();
        self.text_emitted = 0;
        self.match_pos = 0;
        self.completed_start_marker_text = None;
    }

    fn is_start_pending(&self) -> bool {
        !self.inside && self.match_pos > 0
    }

    fn pending_start_marker_text(&self) -> Option<String> {
        self.is_start_pending()
            .then(|| (self.detokenize)(&self.start_ids[..self.match_pos]))
    }

    fn completed_start_marker_text(&self) -> Option<String> {
        self.completed_start_marker_text.clone()
    }
}

fn safe_emit_end(s: &str) -> usize {
    for (i, c) in s.char_indices().rev() {
        if c != '\u{FFFD}' {
            return i + c.len_utf8();
        }
    }
    0
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn gemma_channel_decoder_demuxes_thought_channel() {
        let mut dec =
            GemmaChannelDecoder::new_for_testing(vec![100, 42], vec![101], |tokens| match tokens {
                [7] => "reason".to_string(),
                [8] => "answer".to_string(),
                other => format!("{other:?}"),
            });

        assert!(matches!(dec.feed(&[100, 42]), ReasoningEvent::Start));
        match dec.feed(&[7]) {
            ReasoningEvent::Delta(s) => assert_eq!(s, "reason"),
            other => panic!("expected reasoning delta, got {other:?}"),
        }
        match dec.feed(&[101]) {
            ReasoningEvent::End(s) => assert_eq!(s, "reason"),
            other => panic!("expected reasoning end, got {other:?}"),
        }
        assert!(
            matches!(dec.feed(&[8]), ReasoningEvent::Idle),
            "answer tokens stay outside reasoning"
        );
    }

    #[test]
    fn gemma_channel_decoder_reports_pending_and_completed_start_marker_text() {
        let mut dec =
            GemmaChannelDecoder::new_for_testing(vec![100, 42], vec![101], |tokens| match tokens {
                [100] => "<|channel>".to_string(),
                [100, 42] => "<|channel>thought".to_string(),
                other => format!("{other:?}"),
            });

        assert!(matches!(dec.feed(&[100]), ReasoningEvent::Idle));
        assert!(
            dec.is_start_pending(),
            "partial Gemma marker must suppress visible content"
        );
        assert_eq!(
            dec.pending_start_marker_text().as_deref(),
            Some("<|channel>")
        );
        assert!(dec.completed_start_marker_text().is_none());

        assert!(matches!(dec.feed(&[42]), ReasoningEvent::Start));
        assert!(!dec.is_start_pending());
        assert!(dec.pending_start_marker_text().is_none());
        assert_eq!(
            dec.completed_start_marker_text().as_deref(),
            Some("<|channel>thought")
        );
    }

    #[test]
    fn gemma_thinking_cue_opens_thought_channel_without_closing_it() {
        assert_eq!(GEMMA_THINKING_CUE, "<|turn>model\n");
        assert!(!GEMMA_THINKING_CUE.contains(GEMMA_THOUGHT_OPEN_PREFIX));
        assert!(!GEMMA_THINKING_CUE.contains(GEMMA_THOUGHT_CLOSE));
    }
}
