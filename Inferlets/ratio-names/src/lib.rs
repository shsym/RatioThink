//! Durable snapshot names: the registry, the digest, and the opaque name type.
//!
//! Two namespaces matter to more than one crate, so the naming lives here
//! rather than in any single inferlet:
//!
//! * `conv/` — the **mode-neutral canonical boundary**. Content-addressed, so a
//!   chat turn and a ToT turn representing the same history compute the same
//!   name with no coordination. That is the entire cross-mode reuse mechanism.
//! * `tot/`, `bon/` — per-mode ephemeral scratch, deleted at terminal.
//!
//! ## What this crate is NOT
//!
//! It is **not a security boundary**. pie authorizes snapshots by
//! `(username, name)` with no launching program in the key
//! (`runtime/src/api/context.rs`), so any inferlet in the engine can open or
//! delete any name. These types make the *correct* thing easy and the incorrect
//! thing obvious; they cannot make it impossible. Genuine drop-in third-party
//! inferlets would need pie-side per-program prefix ACLs.

use sha2::{Digest, Sha256};

/// What to do when `save` hits an existing name.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Collision {
    /// Content-addressed: an existing name holds identical KV by construction,
    /// so "already exists" is success.
    AcceptExisting,
    /// Positional: the name encodes a slot, not its contents, so the old KV
    /// must be removed before writing.
    ReplaceBeforeSave,
}

/// The registry. A prefix absent from this table is a hard error, so a new
/// durable namespace cannot be introduced by accident.
pub const NAMESPACES: &[(&str, Collision)] = &[
    ("conv/", Collision::AcceptExisting),
    ("tot/", Collision::ReplaceBeforeSave),
    ("bon/", Collision::ReplaceBeforeSave),
];

pub fn collision_for(name: &str) -> Option<Collision> {
    NAMESPACES
        .iter()
        .find(|(p, _)| name.starts_with(p))
        .map(|(_, c)| *c)
}

// ---------------------------------------------------------------------------
// Digest
// ---------------------------------------------------------------------------

/// Bumped whenever prompt construction changes in a way that invalidates KV.
///
/// Shared deliberately. chat-apc folds `concat!("chat-apc-", CARGO_PKG_VERSION)`
/// into its names, which is per-crate — two crates can then never agree on a
/// name even for identical tokens, making cross-inferlet reuse structurally
/// impossible. One constant, one namespace.
pub const PROMPT_MARKER: &str = "prompt-v1";

/// Length-delimited SHA-256 over the fields that determine KV identity.
///
/// Length delimiting matters: concatenating variable-length fields lets
/// `("ab", "c")` and `("a", "bc")` collide, and a collision here means serving
/// **the wrong conversation's KV**, not merely a cache miss. That is also why
/// this is SHA-256 rather than the reference implementation's paired FNV.
pub fn content_digest(model_id: &str, marker: &str, prefix_tokens: &[u32]) -> String {
    let mut h = Sha256::new();
    for field in [model_id.as_bytes(), marker.as_bytes()] {
        h.update((field.len() as u64).to_le_bytes());
        h.update(field);
    }
    h.update((prefix_tokens.len() as u64).to_le_bytes());
    for t in prefix_tokens {
        h.update(t.to_le_bytes());
    }
    hex(&h.finalize())
}

/// Digest of arbitrary client-supplied text, for use as a name *segment*.
///
/// Client strings are never interpolated raw: a `chat_key` containing `/`
/// would forge namespace structure, and an unbounded one would produce an
/// unbounded name.
pub fn tag(s: &str) -> String {
    let mut h = Sha256::new();
    h.update((s.len() as u64).to_le_bytes());
    h.update(s.as_bytes());
    hex(&h.finalize())[..32].to_string()
}

fn hex(bytes: &[u8]) -> String {
    let mut s = String::with_capacity(bytes.len() * 2);
    for b in bytes {
        s.push_str(&format!("{b:02x}"));
    }
    s
}

// ---------------------------------------------------------------------------
// The opaque name
// ---------------------------------------------------------------------------

/// A durable snapshot name. Constructible only through the associated
/// functions, so every name carries a known namespace and collision policy.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct SnapshotName {
    raw: String,
    policy: Collision,
}

impl SnapshotName {
    /// The mode-neutral canonical boundary.
    pub fn conv(chat_key: &str, compat: &str, model_id: &str, prefix_tokens: &[u32]) -> Self {
        let compat = if compat.is_empty() { "0" } else { compat };
        Self {
            raw: format!(
                "conv/{}/{}/{}",
                tag(chat_key),
                tag(compat),
                content_digest(model_id, PROMPT_MARKER, prefix_tokens)
            ),
            policy: Collision::AcceptExisting,
        }
    }

    /// A Best-of-N candidate.
    ///
    /// The digest binds the name to the candidate's *content*, so a resume can
    /// recompute it and refuse a stale or mismatched `resume_from`/`picked_text`
    /// pair. A gateway-minted round id alone removes the `bon-0` collision but
    /// still lets a mismatched pair open one candidate while the UI believes it
    /// picked another.
    pub fn bon_candidate(
        round_id: &str,
        level: u32,
        idx: u32,
        model_id: &str,
        base_tokens: &[u32],
        answer: &str,
    ) -> Self {
        let mut h = Sha256::new();
        h.update((base_tokens.len() as u64).to_le_bytes());
        for t in base_tokens {
            h.update(t.to_le_bytes());
        }
        h.update((answer.len() as u64).to_le_bytes());
        h.update(answer.as_bytes());
        h.update((model_id.len() as u64).to_le_bytes());
        h.update(model_id.as_bytes());
        let d = &hex(&h.finalize())[..32];
        Self {
            raw: format!("bon/{}/{level}/{idx}/{d}", tag(round_id)),
            policy: Collision::ReplaceBeforeSave,
        }
    }

    /// True when `name` belongs to this round — the guard that stops a client
    /// from asking us to delete an arbitrary snapshot.
    pub fn is_in_bon_round(name: &str, round_id: &str) -> bool {
        name.starts_with(&format!("bon/{}/", tag(round_id)))
    }

    pub fn as_str(&self) -> &str {
        &self.raw
    }

    pub fn policy(&self) -> Collision {
        self.policy
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn every_constructed_name_has_a_registered_policy() {
        let c = SnapshotName::conv("k", "1", "m", &[1, 2, 3]);
        assert_eq!(collision_for(c.as_str()), Some(Collision::AcceptExisting));
        let b = SnapshotName::bon_candidate("r", 1, 0, "m", &[1], "a");
        assert_eq!(collision_for(b.as_str()), Some(Collision::ReplaceBeforeSave));
    }

    #[test]
    fn unregistered_prefix_is_rejected() {
        assert_eq!(collision_for("rogue/whatever"), None);
    }

    /// The property the whole design rests on: two crates, same history, same
    /// name. Guaranteed only because PROMPT_MARKER is shared rather than
    /// per-crate.
    #[test]
    fn same_tokens_same_name_regardless_of_caller() {
        let a = SnapshotName::conv("chat-1", "0", "qwen", &[10, 20, 30]);
        let b = SnapshotName::conv("chat-1", "0", "qwen", &[10, 20, 30]);
        assert_eq!(a, b);
    }

    #[test]
    fn different_tokens_differ() {
        let a = SnapshotName::conv("c", "0", "m", &[1, 2, 3]);
        let b = SnapshotName::conv("c", "0", "m", &[1, 2, 4]);
        assert_ne!(a, b);
    }

    #[test]
    fn different_model_differs() {
        let a = SnapshotName::conv("c", "0", "qwen", &[1]);
        let b = SnapshotName::conv("c", "0", "llama", &[1]);
        assert_ne!(a, b);
    }

    /// Length delimiting: without it these two field splits would collide, and
    /// a collision here serves the wrong conversation's KV.
    #[test]
    fn field_boundaries_cannot_be_confused() {
        assert_ne!(
            content_digest("ab", "c", &[1]),
            content_digest("a", "bc", &[1])
        );
    }

    /// A client key containing `/` must not be able to forge namespace levels.
    #[test]
    fn client_strings_cannot_forge_structure() {
        let evil = SnapshotName::conv("../../conv/x/y", "0", "m", &[1]);
        assert_eq!(
            evil.as_str().matches('/').count(),
            3,
            "conv/<key>/<compat>/<digest> is exactly 3 slashes; got {}",
            evil.as_str()
        );
    }

    #[test]
    fn bon_candidate_binds_to_its_answer() {
        let a = SnapshotName::bon_candidate("r", 1, 0, "m", &[1, 2], "answer one");
        let b = SnapshotName::bon_candidate("r", 1, 0, "m", &[1, 2], "answer two");
        assert_ne!(a, b, "a stale pick must not resolve to a live snapshot");
    }

    #[test]
    fn bon_round_membership_guards_deletes() {
        let n = SnapshotName::bon_candidate("round-a", 1, 0, "m", &[1], "x");
        assert!(SnapshotName::is_in_bon_round(n.as_str(), "round-a"));
        assert!(!SnapshotName::is_in_bon_round(n.as_str(), "round-b"));
        assert!(!SnapshotName::is_in_bon_round("conv/a/b/c", "round-a"));
    }
}
