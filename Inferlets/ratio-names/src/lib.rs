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
    ///
    /// A prefix test only. Use [`may_delete`] for anything destructive: this
    /// accepts any string under the round prefix, including one a client
    /// invented, because it never checks that the name is even well formed.
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


// ---------------------------------------------------------------------------
// Parsing and the delete guard
// ---------------------------------------------------------------------------

/// A parsed `bon/` candidate name.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct BonCandidateRef<'a> {
    pub round_tag: &'a str,
    pub level: u32,
    pub idx: u32,
    pub digest: &'a str,
}

fn is_hex(s: &str, len: usize) -> bool {
    s.len() == len && s.bytes().all(|b| b.is_ascii_hexdigit())
}

/// Strict parse of `bon/{32-hex round tag}/{level}/{idx}/{32-hex digest}`.
///
/// Deliberately rejects chat-apc's positional `bon/bon-0/1/0` (four segments,
/// non-hex round tag). Those names carry no content binding at all, and their
/// round segment is the literal `bon-0` for EVERY round of EVERY chat, because
/// the counter it came from restarts with each wasm instance.
pub fn parse_bon_candidate(name: &str) -> Option<BonCandidateRef<'_>> {
    let rest = name.strip_prefix("bon/")?;
    let mut parts = rest.split('/');
    let round_tag = parts.next()?;
    let level = parts.next()?;
    let idx = parts.next()?;
    let digest = parts.next()?;
    if parts.next().is_some() {
        return None;
    }
    if !is_hex(round_tag, 32) || !is_hex(digest, 32) {
        return None;
    }
    Some(BonCandidateRef {
        round_tag,
        level: level.parse().ok()?,
        idx: idx.parse().ok()?,
        digest,
    })
}

/// Why a delete was refused, for the accounting a client sees.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum DeleteRefusal {
    /// Not a well-formed digest-named candidate (includes every legacy
    /// `bon/bon-0/...` name).
    Unparseable,
    /// Well formed, but minted by a different round.
    WrongRound,
}

/// THE destructive-operation guard. `Ok(())` means this name may be passed to
/// `Context::delete`; anything else must be refused and counted.
///
/// This is the only thing standing between a client-supplied string and
/// permanent data loss. pie authorizes snapshots by `(username, name)` with no
/// program in the key (`runtime/src/api/context.rs`), so the engine will
/// happily delete `conv/...` — another conversation's KV boundary — if a guest
/// asks. chat-apc's release path did exactly that: it called
/// `Context::delete(model, name)` on every name in the request with no
/// validation whatsoever (`bestofn/release.rs:53-68,75-80`).
///
/// Two rules, both necessary:
///
/// * **The name must PARSE as a digest-named candidate.** A prefix test alone
///   would accept `bon/<anything>`, which a client can trivially construct.
/// * **Its round tag must match the round doing the deleting.** Note the guard
///   takes a `round_id` and tags it here rather than accepting a pre-tagged
///   prefix, so a caller cannot pass the name's own round back in and have it
///   authorize itself.
///
/// There is deliberately NO fallback for legacy names. Accepting them would
/// mean accepting `bon/bon-0/...`, which is every pre-port round of every chat
/// — a guard that authorizes a mass delete is worse than no guard, because it
/// reads as protection. Pre-port snapshots leak once and age out.
pub fn may_delete(name: &str, round_id: &str) -> Result<(), DeleteRefusal> {
    let parsed = parse_bon_candidate(name).ok_or(DeleteRefusal::Unparseable)?;
    if parsed.round_tag != tag(round_id) {
        return Err(DeleteRefusal::WrongRound);
    }
    Ok(())
}

/// The content digest a candidate name embeds. Split out of
/// [`SnapshotName::bon_candidate`] so a resume can RECOMPUTE it from
/// `(base_tokens, answer)` and compare, rather than trusting the name.
pub fn bon_digest(model_id: &str, base_tokens: &[u32], answer: &str) -> String {
    let mut h = Sha256::new();
    h.update((base_tokens.len() as u64).to_le_bytes());
    for t in base_tokens {
        h.update(t.to_le_bytes());
    }
    h.update((answer.len() as u64).to_le_bytes());
    h.update(answer.as_bytes());
    h.update((model_id.len() as u64).to_le_bytes());
    h.update(model_id.as_bytes());
    hex(&h.finalize())[..32].to_string()
}

#[cfg(test)]
mod guard_tests {
    use super::*;

    fn a_name() -> String {
        SnapshotName::bon_candidate("round-a", 1, 0, "qwen", &[1, 2, 3], "the answer")
            .as_str()
            .to_string()
    }

    #[test]
    fn a_real_name_parses_into_its_parts() {
        let n = a_name();
        let p = parse_bon_candidate(&n).expect("must parse");
        assert_eq!((p.level, p.idx), (1, 0));
        assert_eq!(p.round_tag, tag("round-a"));
        assert_eq!(p.digest.len(), 32);
    }

    /// `bon_candidate` must be the only place the name is built, so a resume
    /// recomputing the digest gets the same bytes.
    #[test]
    fn bon_digest_matches_the_name_it_is_extracted_from() {
        let n = a_name();
        let p = parse_bon_candidate(&n).unwrap();
        assert_eq!(p.digest, bon_digest("qwen", &[1, 2, 3], "the answer"));
    }

    #[test]
    fn a_different_answer_yields_a_different_digest() {
        assert_ne!(
            bon_digest("qwen", &[1, 2, 3], "the answer"),
            bon_digest("qwen", &[1, 2, 3], "another answer")
        );
    }

    /// The legacy positional shape carries no content binding and its round
    /// segment is `bon-0` for every round of every chat.
    #[test]
    fn legacy_positional_names_do_not_parse() {
        assert!(parse_bon_candidate("bon/bon-0/1/0").is_none());
        assert!(parse_bon_candidate("bon/bon-0/1/0/notahexdigest").is_none());
    }

    #[test]
    fn other_namespaces_do_not_parse() {
        assert!(parse_bon_candidate("conv/aaa/bbb/ccc").is_none());
        assert!(parse_bon_candidate("tot/x/1/0/y").is_none());
    }

    #[test]
    fn a_name_from_this_round_may_be_deleted() {
        assert_eq!(may_delete(&a_name(), "round-a"), Ok(()));
    }

    /// The whole point: another round's snapshot is not ours to free.
    #[test]
    fn a_name_from_another_round_is_refused() {
        assert_eq!(may_delete(&a_name(), "round-b"), Err(DeleteRefusal::WrongRound));
    }

    /// The finding that made this guard strict: chat-apc deleted whatever it
    /// was handed, and pie has no program in the authorization key — so a
    /// `conv/` name would have destroyed another conversation's KV boundary.
    #[test]
    fn a_conv_boundary_can_never_be_deleted_through_this_path() {
        let victim = SnapshotName::conv("someone-elses-chat", "1", "qwen", &[1, 2, 3]);
        assert_eq!(
            may_delete(victim.as_str(), "round-a"),
            Err(DeleteRefusal::Unparseable)
        );
    }

    /// A guard that accepted `bon/<anything>` would be trivially defeated.
    #[test]
    fn an_invented_name_under_the_round_prefix_is_still_refused() {
        let forged = format!("bon/{}/1/0/notahexvalue", tag("round-a"));
        assert_eq!(may_delete(&forged, "round-a"), Err(DeleteRefusal::Unparseable));
        // ...even though the prefix test says otherwise.
        assert!(SnapshotName::is_in_bon_round(&forged, "round-a"));
    }

    #[test]
    fn legacy_names_are_refused_rather_than_mass_deleted() {
        // `bon-0` is every pre-port round of every chat. Accepting these would
        // make the guard authorize a mass delete.
        assert_eq!(may_delete("bon/bon-0/1/0", "round-a"), Err(DeleteRefusal::Unparseable));
    }
}
