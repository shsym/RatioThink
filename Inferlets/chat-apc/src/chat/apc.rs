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

/// Streaming detector for thinking-block events (`<think>...`).
///
/// The chat loop feeds this every iteration; its events surface as
/// OpenAI-shape `reasoning_content` deltas (see [`super::completions`]).
pub struct ReasoningDecoder {
    inner: inferlet::reasoning::Decoder,
}

impl ReasoningDecoder {
    pub fn new(model: &Model) -> Self {
        Self {
            inner: inferlet::reasoning::Decoder::new(model),
        }
    }

    pub fn feed(&mut self, tokens: &[u32]) -> Result<inferlet::reasoning::Event> {
        self.inner.feed(tokens)
    }

    #[allow(dead_code)]
    pub fn reset(&mut self) {
        self.inner.reset();
    }
}
