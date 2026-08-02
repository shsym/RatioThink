//! Outcome classification and the reasoning/content demux.
//!
//! Ported VERBATIM from `chat-apc/src/chat/completions.rs:1535-1723`. These
//! functions carry the entire behavioral contract of the decode loop and are
//! pure, so they are unit-tested on the host with no engine.

use ratio_wire::FinishReason;

#[derive(Copy, Clone, Debug, Eq, PartialEq)]
pub enum Outcome {
    /// Decoder reported `Done` — natural end-of-turn.
    Natural,
    /// `max_tokens` cap reached before the model emitted a stop.
    MaxTokens,
    /// Runtime / decoder / chat-template error.
    Aborted,
    /// The client went away and the guest observed the cooperative cancel
    /// signal. Distinct from `Aborted`: nothing failed, so reporting
    /// `finish_reason: "error"` would misattribute a normal disconnect.
    Cancelled,
}

impl Outcome {
    pub fn finish_reason(self) -> FinishReason {
        match self {
            Outcome::Natural => FinishReason::Stop,
            Outcome::MaxTokens => FinishReason::Length,
            Outcome::Aborted => FinishReason::Error,
            Outcome::Cancelled => FinishReason::Cancelled,
        }
    }
}

pub const STARVED_CODE: &str = "forward_pass_starved";
pub const STARVED_MESSAGE: &str =
    "engine produced no tokens for a decode step (device failure, per-batch \
     timeout, or KV eviction); generation cannot continue";

/// PARITY: gated on the reasoning state captured BEFORE `reason_dec.feed()`.
/// `feed` flips `in_reasoning` as a side effect of consuming the boundary
/// token; gating on the post-feed value re-opens the content channel exactly
/// in time for the literal `</think>` to leak into `content`.
pub fn content_visible(reason_idle: bool, was_in_reasoning: bool) -> bool {
    reason_idle && !was_in_reasoning
}

const THINK_CLOSE: &str = "</think>";

/// Recover the visible answer that followed `</think>` inside the chat delta
/// of the batch where the reasoning block closed (the speculative straddle).
///
/// PARITY: splits on the FIRST occurrence, and trims ONLY leading `\n`
/// (`trim_start_matches('\n')`, not `trim_start()`) — using `trim_start()`
/// would eat leading spaces the current code preserves.
pub fn answer_after_close(chat_delta: &str) -> Option<&str> {
    chat_delta
        .split_once(THINK_CLOSE)
        .map(|(_, answer)| answer.trim_start_matches('\n'))
        .filter(|answer| !answer.is_empty())
}

/// The single demux decision shared by every decode path. `""` means suppress.
pub fn visible_content<'a>(
    chat_delta: &'a str,
    reason_idle: bool,
    was_in_reasoning: bool,
    reason_ended: bool,
) -> &'a str {
    if content_visible(reason_idle, was_in_reasoning) {
        chat_delta
    } else if reason_ended {
        answer_after_close(chat_delta).unwrap_or("")
    } else {
        ""
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn outside_reasoning_is_visible() {
        assert_eq!(visible_content("hello", true, false, false), "hello");
    }

    #[test]
    fn inside_reasoning_is_suppressed() {
        assert_eq!(visible_content("thinking", false, true, false), "");
    }

    /// The original leak: gating on post-feed state let `</think>` through.
    #[test]
    fn closing_delimiter_alone_is_suppressed() {
        assert_eq!(visible_content("</think>", false, true, true), "");
    }

    /// #600 straddle: answer-head sharing the close batch must be recovered.
    #[test]
    fn answer_head_after_close_is_recovered() {
        assert_eq!(
            visible_content("tail</think>\nThe answer", false, true, true),
            "The answer"
        );
    }

    #[test]
    fn only_newlines_are_trimmed_not_spaces() {
        assert_eq!(answer_after_close("x</think>\n  spaced"), Some("  spaced"));
    }

    #[test]
    fn splits_on_first_close_so_answer_may_mention_the_tag() {
        assert_eq!(
            answer_after_close("r</think>see </think> literal"),
            Some("see </think> literal")
        );
    }

    #[test]
    fn bare_close_yields_none() {
        assert_eq!(answer_after_close("</think>"), None);
    }

    #[test]
    fn finish_reasons_map_to_wire() {
        assert_eq!(Outcome::Natural.finish_reason().as_wire(), "stop");
        assert_eq!(Outcome::MaxTokens.finish_reason().as_wire(), "length");
        assert_eq!(Outcome::Aborted.finish_reason().as_wire(), "error");
        assert_eq!(Outcome::Cancelled.finish_reason().as_wire(), "cancelled");
    }
}
