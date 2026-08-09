//! Guarded snapshot release.
//!
//! This is the only place in the system where a guest destroys durable state on
//! client instruction, so it is the only place where getting validation wrong
//! costs data rather than latency.
//!
//! ## What chat-apc did
//!
//! ```ignore
//! fn delete_snapshot(&mut self, name: &str) -> bool {
//!     Context::delete(self.model, name).is_ok()   // release.rs:75-80
//! }
//! ```
//!
//! Every name in the request, unvalidated. And pie authorizes snapshots by
//! `(username, name)` with no launching program in the key
//! (`runtime/src/api/context.rs`), so there is no engine-side guard either: a
//! request naming `conv/<other chat>/...` would have deleted another
//! conversation's KV boundary. The plan's rule — *never delete an arbitrary
//! client-supplied snapshot name* — has no enforcement point but this one.
//!
//! ## The guard
//!
//! [`ratio_names::may_delete`] requires the name to PARSE as a digest-named
//! candidate and to carry this round's tag. A refused name is counted, never
//! deleted, and never aborts the operation — a single bad entry must not strand
//! the rest of the round's snapshots, which is the drop-completeness property
//! chat-apc's `release_all` had and is worth keeping.
//!
//! Legacy `bon/bon-0/...` names are refused. They cannot be authorized: that
//! round segment is the literal `bon-0` for every round of every chat, because
//! chat-apc minted it from a counter that restarts with each wasm instance. A
//! guard that accepted them would authorize a mass delete while reading as
//! protection. Pre-port snapshots leak once and age out.

use ratio_names::{DeleteRefusal, may_delete};
use serde::{Deserialize, Serialize};

/// Accounting a client can reconcile against what it asked for.
///
/// `released + absent + refused == requested` always.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default, Serialize, Deserialize)]
pub struct ReleaseReport {
    pub requested: usize,
    /// Existed and was freed.
    pub released: usize,
    /// Well formed and ours, but already gone — a re-release, or an eviction.
    pub absent: usize,
    /// REFUSED by the guard. Distinct from `absent` on purpose: absent is
    /// benign, refused means the client asked us to delete something it could
    /// not prove it owned, and that deserves to be visible rather than folded
    /// into a count that looks like normal cleanup.
    pub refused: usize,
}

/// The engine op, abstracted so the guard logic is unit-testable with no live
/// engine. Mirrors chat-apc's `ReleaseOps` seam.
pub trait ReleaseOps {
    /// `true` when the snapshot existed and was freed; `false` when it was
    /// already absent (`delete` errors on a missing snapshot).
    fn delete_snapshot(&mut self, name: &str) -> bool;
}

/// Delete every name that passes the guard, counting each outcome.
///
/// EVERY name is attempted — no early return — so one refused or missing entry
/// cannot leave the rest of the round leaked.
pub fn release_all<O: ReleaseOps>(ops: &mut O, names: &[String], round_id: &str) -> ReleaseReport {
    let mut r = ReleaseReport { requested: names.len(), ..Default::default() };
    for name in names {
        match may_delete(name, round_id) {
            Err(why) => {
                r.refused += 1;
                // Loud: a refusal is either a client bug or an attempt to free
                // something that is not this round's to free.
                let why = match why {
                    DeleteRefusal::Unparseable => "not a digest-named candidate",
                    DeleteRefusal::WrongRound => "belongs to a different round",
                };
                eprintln!("[bestofn] refusing to delete {name:?}: {why}");
            }
            Ok(()) => {
                if ops.delete_snapshot(name) {
                    r.released += 1;
                } else {
                    r.absent += 1;
                }
            }
        }
    }
    r
}

#[cfg(test)]
mod tests {
    use super::*;
    use ratio_names::SnapshotName;
    use std::collections::HashSet;

    #[derive(Default)]
    struct Mock {
        present: HashSet<String>,
        deleted: Vec<String>,
    }

    impl ReleaseOps for Mock {
        fn delete_snapshot(&mut self, name: &str) -> bool {
            self.deleted.push(name.to_string());
            self.present.remove(name)
        }
    }

    fn candidate(round: &str, idx: u32, answer: &str) -> String {
        SnapshotName::bon_candidate(round, 1, idx, "qwen", &[1, 2, 3], answer)
            .as_str()
            .to_string()
    }

    #[test]
    fn this_rounds_names_are_freed_and_counted() {
        let names: Vec<String> = (0..3).map(|i| candidate("r1", i, "a")).collect();
        let mut m = Mock { present: names.iter().cloned().collect(), ..Default::default() };
        let r = release_all(&mut m, &names, "r1");
        assert_eq!(r, ReleaseReport { requested: 3, released: 3, absent: 0, refused: 0 });
    }

    #[test]
    fn an_already_absent_name_is_benign() {
        let names = vec![candidate("r1", 0, "a")];
        let mut m = Mock::default();
        let r = release_all(&mut m, &names, "r1");
        assert_eq!(r, ReleaseReport { requested: 1, released: 0, absent: 1, refused: 0 });
    }

    /// The finding this module exists for: chat-apc would have deleted this.
    #[test]
    fn a_conv_boundary_never_reaches_delete() {
        let victim = SnapshotName::conv("someone-elses-chat", "1", "qwen", &[9, 9])
            .as_str()
            .to_string();
        let mut m = Mock { present: [victim.clone()].into_iter().collect(), ..Default::default() };
        let r = release_all(&mut m, &[victim.clone()], "r1");
        assert_eq!(r.refused, 1);
        assert_eq!(r.released, 0);
        assert!(m.deleted.is_empty(), "delete must not even be attempted");
        assert!(m.present.contains(&victim), "the victim must survive");
    }

    #[test]
    fn another_rounds_candidate_is_refused() {
        let theirs = candidate("their-round", 0, "a");
        let mut m = Mock { present: [theirs.clone()].into_iter().collect(), ..Default::default() };
        let r = release_all(&mut m, &[theirs.clone()], "my-round");
        assert_eq!(r.refused, 1);
        assert!(m.deleted.is_empty());
        assert!(m.present.contains(&theirs));
    }

    /// Legacy names are unauthorizable, so they are refused rather than
    /// mass-deleted. Recorded as a known one-time leak.
    #[test]
    fn legacy_positional_names_are_refused() {
        let mut m = Mock::default();
        let r = release_all(&mut m, &["bon/bon-0/1/0".to_string()], "r1");
        assert_eq!(r.refused, 1);
        assert!(m.deleted.is_empty());
    }

    /// Drop-completeness: one bad entry must not strand the rest.
    #[test]
    fn a_refused_name_does_not_abort_the_rest() {
        let mine: Vec<String> = (0..2).map(|i| candidate("r1", i, "a")).collect();
        let mut names = vec!["conv/x/y/z".to_string()];
        names.extend(mine.iter().cloned());
        let mut m = Mock { present: mine.iter().cloned().collect(), ..Default::default() };
        let r = release_all(&mut m, &names, "r1");
        assert_eq!(r, ReleaseReport { requested: 3, released: 2, absent: 0, refused: 1 });
    }

    #[test]
    fn the_accounting_always_reconciles() {
        let mut names = vec!["bon/bon-0/1/0".to_string(), "conv/a/b/c".to_string()];
        names.push(candidate("r1", 0, "a")); // present
        names.push(candidate("r1", 1, "b")); // absent
        let mut m = Mock {
            present: [candidate("r1", 0, "a")].into_iter().collect(),
            ..Default::default()
        };
        let r = release_all(&mut m, &names, "r1");
        assert_eq!(r.released + r.absent + r.refused, r.requested);
        assert_eq!((r.released, r.absent, r.refused), (1, 1, 2));
    }
}
