//! Best-of-N snapshot lifecycle release (#690) — terminal KV cleanup.
//!
//! A round saves one named KV snapshot per pickable candidate so a later
//! think-more round can resume from the user's pick. Think-more frees the
//! prior round itself (it deletes the unpicked siblings and the picked
//! snapshot through the resume path). But the **no-next-round** terminals —
//! stop/commit (the user accepts a reply, whose text is persisted, so its KV
//! snapshot is dead weight) and abandon (the user moves on without picking) —
//! happen App-side with no further generation request, so nothing would free
//! those snapshots. Over a long session that orphaned KV accumulates and
//! pressures the page store.
//!
//! This module is the explicit cleanup path: a `release` request names the
//! snapshots to drop and runs NO generation. Each delete frees the snapshot's
//! GPU/CPU pages in the runtime context manager (`delete_snapshot_key` releases
//! committed hashes + frees working pages), so a release deterministically
//! returns the round's KV pages.
//!
//! It is owned entirely by `bestofn` — it imports nothing from `tot`.

use serde::Serialize;

use inferlet::Context;
use inferlet::model::Model;

use crate::sse;
use wstd::http::server::{Finished, Responder};
use wstd::http::{IntoBody, Response};

/// Engine op a release needs, abstracted so the drop-all logic is unit-testable
/// without a live engine (the real impl deletes via [`Context::delete`]; the
/// test uses a mock with a known present/absent set). Mirrors the
/// [`ResumeOps`](super::ResumeOps) seam.
pub(crate) trait ReleaseOps {
    /// Delete one saved snapshot. `true` when it existed and was freed,
    /// `false` when it was already absent (a re-release, or an earlier
    /// eviction) — the runtime `delete` errors on a missing snapshot.
    fn delete_snapshot(&mut self, name: &str) -> bool;
}

/// Outcome of releasing a set of snapshots: how many existed and were freed vs
/// were already gone. `released + absent == requested` always, so a caller can
/// prove the round's snapshots were actually dropped (a second release of the
/// same names reports them all `absent`).
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize)]
pub(crate) struct ReleaseReport {
    pub(crate) requested: usize,
    pub(crate) released: usize,
    pub(crate) absent: usize,
}

/// Delete every named snapshot, counting freed vs already-absent. EVERY name is
/// attempted — no early return — so a single missing sibling cannot leave the
/// rest of the round's snapshots leaked (drop-completeness). Pure over
/// [`ReleaseOps`] → unit-tested.
pub(crate) fn release_all<O: ReleaseOps>(ops: &mut O, names: &[String]) -> ReleaseReport {
    let mut released = 0usize;
    for name in names {
        if ops.delete_snapshot(name) {
            released += 1;
        }
    }
    ReleaseReport {
        requested: names.len(),
        released,
        absent: names.len() - released,
    }
}

/// Real [`ReleaseOps`] over the inferlet engine `Context`.
struct InferletReleaseOps<'a> {
    model: &'a Model,
}

impl ReleaseOps for InferletReleaseOps<'_> {
    fn delete_snapshot(&mut self, name: &str) -> bool {
        // `delete` errors only when the snapshot is absent; a successful delete
        // frees its GPU/CPU pages in the runtime context manager.
        Context::delete(self.model, name).is_ok()
    }
}

/// Free a set of named snapshots over the live engine `Context` and report the
/// accounting. Shares the [`InferletReleaseOps`] + [`release_all`] path with
/// [`dispatch_release`] so the app-driven terminal release and the engine-side
/// disconnect cleanup (#703 F5) delete through one code path. Used by
/// [`run_round`](super::run_round) when the terminal `awaiting_selection` emit
/// fails: the client never received the pick list, so the round's just-saved
/// candidate snapshots can never be picked or app-released — free them now
/// rather than leak them until engine teardown.
pub(crate) fn release_snapshots(model: &Model, names: &[String]) -> ReleaseReport {
    let mut ops = InferletReleaseOps { model };
    release_all(&mut ops, names)
}

#[derive(Serialize)]
struct ReleaseAck {
    object: &'static str,
    requested: usize,
    released: usize,
    absent: usize,
}

/// Serve a release request: drop the named snapshots and ack the accounting.
/// No SSE, no generation — a plain JSON response (the app fires it
/// best-effort on a terminal outcome). `names` must be non-empty (the
/// dispatcher only routes here when `release` is set and non-empty).
pub(crate) async fn dispatch_release(model: &Model, names: &[String], res: Responder) -> Finished {
    let mut ops = InferletReleaseOps { model };
    let report = release_all(&mut ops, names);
    let ack = ReleaseAck {
        object: "best_of_n.release",
        requested: report.requested,
        released: report.released,
        absent: report.absent,
    };
    let body = match serde_json::to_string(&ack) {
        Ok(s) => s,
        Err(e) => {
            return res
                .respond(sse::json_error(
                    500,
                    "serialize_failed",
                    &format!("Failed to serialize release ack: {e}"),
                ))
                .await;
        }
    };
    let response = Response::builder()
        .status(200)
        .header("Content-Type", "application/json")
        .body(body.into_body())
        .unwrap();
    res.respond(response).await
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::collections::HashSet;

    /// Mock that "owns" a set of present snapshots; deleting a present one
    /// frees it (and reports true), deleting an absent one reports false.
    struct MockOps {
        present: HashSet<String>,
        deleted: Vec<String>,
    }

    impl ReleaseOps for MockOps {
        fn delete_snapshot(&mut self, name: &str) -> bool {
            self.deleted.push(name.to_string());
            self.present.remove(name)
        }
    }

    fn names(v: &[&str]) -> Vec<String> {
        v.iter().map(|s| s.to_string()).collect()
    }

    #[test]
    fn release_all_drops_every_present_snapshot() {
        let mut ops = MockOps {
            present: ["a", "b", "c"].iter().map(|s| s.to_string()).collect(),
            deleted: Vec::new(),
        };
        let report = release_all(&mut ops, &names(&["a", "b", "c"]));
        assert_eq!(
            report,
            ReleaseReport {
                requested: 3,
                released: 3,
                absent: 0
            }
        );
        // Drop-completeness: every name attempted, none left behind.
        assert_eq!(ops.deleted, names(&["a", "b", "c"]));
        assert!(ops.present.is_empty(), "all snapshots freed");
    }

    #[test]
    fn re_release_reports_all_absent_proving_the_first_freed_them() {
        let mut ops = MockOps {
            present: ["a", "b"].iter().map(|s| s.to_string()).collect(),
            deleted: Vec::new(),
        };
        let first = release_all(&mut ops, &names(&["a", "b"]));
        assert_eq!(
            first,
            ReleaseReport {
                requested: 2,
                released: 2,
                absent: 0
            }
        );
        // Re-releasing the same names now finds them all gone — the accounting
        // proof that the first release actually deleted them (and freed pages).
        let second = release_all(&mut ops, &names(&["a", "b"]));
        assert_eq!(
            second,
            ReleaseReport {
                requested: 2,
                released: 0,
                absent: 2
            }
        );
    }

    #[test]
    fn release_continues_past_an_absent_sibling_no_leak() {
        // A round where one sibling was already evicted: the rest must still be
        // freed (no early return on the missing one).
        let mut ops = MockOps {
            present: ["a", "c"].iter().map(|s| s.to_string()).collect(),
            deleted: Vec::new(),
        };
        let report = release_all(&mut ops, &names(&["a", "b", "c"]));
        assert_eq!(
            report,
            ReleaseReport {
                requested: 3,
                released: 2,
                absent: 1
            }
        );
        assert_eq!(ops.deleted, names(&["a", "b", "c"]), "every name attempted");
        assert!(ops.present.is_empty(), "no present snapshot left behind");
    }

    /// #703 F5 contract (widened by review F2): the emit-failure cleanup frees
    /// EXACTLY the saved picks' snapshot names. `run_round` runs this on ANY
    /// `emit_awaiting_selection` error — both `EmitError::Disconnected` and
    /// `EmitError::Serialize` — because the orphan condition is identical
    /// (the client never received the pick list either way); the freed name set
    /// is therefore variant-independent, which is exactly what this locks. The
    /// mapping (each `Pick`'s `snapshot_name` handed to `release_snapshots`)
    /// rides the same `release_all` path, so an orphaned round leaves nothing
    /// behind. The live-`Context` wrapper [`release_snapshots`] is exercised
    /// end-to-end by the real-engine e2e; here we prove the name set + accounting.
    #[test]
    fn emit_failure_cleanup_frees_exactly_the_saved_pick_snapshots() {
        use super::super::stream::Pick;
        let picks = vec![
            Pick {
                id: "n0".to_string(),
                branch_index: 0,
                snapshot_name: "bon/r/1/0".to_string(),
            },
            Pick {
                id: "n1".to_string(),
                branch_index: 1,
                snapshot_name: "bon/r/1/1".to_string(),
            },
        ];
        // Exactly the expression `run_round` uses on the disconnect branch.
        let to_free: Vec<String> = picks.iter().map(|p| p.snapshot_name.clone()).collect();
        let mut ops = MockOps {
            present: to_free.iter().cloned().collect(),
            deleted: Vec::new(),
        };
        let report = release_all(&mut ops, &to_free);
        assert_eq!(
            report,
            ReleaseReport {
                requested: 2,
                released: 2,
                absent: 0
            }
        );
        assert_eq!(ops.deleted, to_free, "every saved pick snapshot attempted");
        assert!(
            ops.present.is_empty(),
            "no orphaned snapshot survives the disconnect cleanup"
        );
    }
}
