//! Prompt construction — the single most parity-critical code in the port.
//!
//! Ported VERBATIM from `chat-apc/src/chat/completions.rs:5268-5400`.
//!
//! Two things make this load-bearing beyond "same reply text":
//!
//! 1. It does NOT use `Context`'s fluent chat fillers (`ctx.system()`,
//!    `ctx.user()`, `ctx.cue()`). It builds one token vector and does a single
//!    `ctx.append(&tokens)`. Switching to the fluent API is the obvious
//!    "cleanup" and it would change the prefill bytes.
//! 2. When the prefix cache returns, snapshot keys content-address the exact
//!    prefix token sequence, so drift here does not merely change replies —
//!    it can mis-reuse another conversation's KV.
//!
//! SCOPE: the no-tools path. `tools` / `tool` role handling is deliberately
//! omitted for this slice; an incoming `tool` role is rejected rather than
//! silently mistreated.

use crate::schema::{ChatMessage, CueMode};
use inferlet::{Context, chat, model::Model};

/// Roles this slice accepts. `tool` is listed in chat-apc's
/// `SUPPORTED_ROLES` but needs the tool-replay path, so it is refused here
/// with its own code rather than mishandled.
const SUPPORTED_ROLES: [&str; 3] = ["system", "user", "assistant"];

pub fn role_error_code(role: &str) -> Option<&'static str> {
    if SUPPORTED_ROLES.contains(&role) {
        None
    } else if role == "tool" {
        Some("tool_role_unsupported")
    } else {
        Some("unsupported_role")
    }
}

pub fn role_error_message(index: usize, role: &str, _code: &str) -> String {
    format!(
        "messages[{index}].role must be one of {:?}; got {role:?}",
        SUPPORTED_ROLES
    )
}

/// Maps a prompt-build error code to 400-vs-500 for the caller.
/// Ported from `completions.rs:2886-2893`.
pub fn is_role_error_code(code: &str) -> bool {
    matches!(code, "unsupported_role" | "tool_role_unsupported")
}

/// Tokenize the prompt. The one source of prefill bytes.
pub fn build_prompt_tokens(
    model: &Model,
    messages: &[ChatMessage],
    cue_mode: CueMode,
) -> Result<Vec<u32>, (&'static str, String)> {
    let mut out = Vec::new();
    for (i, msg) in messages.iter().enumerate() {
        match msg.role.as_str() {
            "system" => out.extend(chat::system(model, msg.content_str().unwrap_or(""))),
            "assistant" => {
                // No-tools slice: `assistant_replay_content` degenerates to
                // the plain content, so it is inlined here.
                out.extend(chat::assistant(model, msg.content_str().unwrap_or("")));
            }
            // PARITY, and the subtlest line in the file. The first message of
            // a fresh prompt must open with the model's BOS: `first_user`
            // prepends it, plain `user` does not. A preceding `system` turn
            // already emitted BOS, hence the branch on whether anything has
            // been buffered yet. Omitting BOS is benign for BOS-agnostic
            // templates (qwen/ChatML) but degenerates BOS-sensitive ones
            // (gemma: looping / channel salad).
            "user" => {
                let content = msg.content_str().unwrap_or("");
                if out.is_empty() {
                    out.extend(chat::first_user(model, content));
                } else {
                    out.extend(chat::user(model, content));
                }
            }
            other => {
                let code = role_error_code(other).unwrap_or("unsupported_role");
                return Err((code, role_error_message(i, other, code)));
            }
        }
    }
    // The trailing cue opens the assistant turn the generator fills.
    out.extend(generation_cue(model, cue_mode));
    Ok(out)
}

pub fn generation_cue(model: &Model, cue_mode: CueMode) -> Vec<u32> {
    match cue_mode {
        CueMode::None => Vec::new(),
        // `Thinking` needs the Gemma channel-marker probe from chat-apc's
        // `apc.rs`; until that ports, fall back to the generic cue, which is
        // what chat-apc itself does on non-Gemma tokenizers.
        CueMode::Generic | CueMode::Thinking => chat::cue(model),
    }
}

/// Apply the prompt to `ctx`. One `append`, not the fluent fillers.
pub fn fill_context(
    ctx: &mut Context,
    model: &Model,
    messages: &[ChatMessage],
    cue_mode: CueMode,
) -> Result<(), (&'static str, String)> {
    let tokens = build_prompt_tokens(model, messages, cue_mode)?;
    ctx.append(&tokens);
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn known_roles_accepted() {
        for r in ["system", "user", "assistant"] {
            assert_eq!(role_error_code(r), None, "{r} should be accepted");
        }
    }

    #[test]
    fn tool_role_has_its_own_code() {
        assert_eq!(role_error_code("tool"), Some("tool_role_unsupported"));
        assert!(is_role_error_code("tool_role_unsupported"));
    }

    #[test]
    fn unknown_role_rejected_not_demoted() {
        // #468: an unknown role must error, never be silently demoted to user.
        assert_eq!(role_error_code("developer"), Some("unsupported_role"));
        assert!(is_role_error_code("unsupported_role"));
    }

    #[test]
    fn non_role_codes_are_not_role_errors() {
        assert!(!is_role_error_code("server_busy"));
    }
}
