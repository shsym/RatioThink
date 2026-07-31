//! Snapshot-name namespaces and their **collision semantics**.
//!
//! Two modules park KV snapshots under names in ONE shared runtime store, and
//! "this name already exists" means the OPPOSITE thing in each:
//!
//! | prefix | name derived from | already-exists means |
//! |--------|-------------------|----------------------|
//! | `apc/` | content hash of the prefix tokens | the **same** KV is already parked — accept it, it is a valid future hit |
//! | `bon/` | position (`bon/{request_id}/{level}/{idx}`) | a **different** candidate's KV may be parked — replace it, or a resume silently answers from the previous round's branch |
//!
//! Both shipped defects were this table being implicit:
//!
//! - `apc/` names embedded the assistant text **the engine generated**, so a
//!   client that resent *different* text for the same turn (an edited turn, a
//!   regenerate, a reasoning-stripping UI) missed the name and forfeited the
//!   whole history to a full re-prefill. Fixed by the boundary ladder.
//! - `bon/` names are positional, so re-sending an *identical* round collided
//!   on every name; `Context::save` refuses an existing name, so all N branches
//!   became "candidate KV could not be saved for resume" and the round returned
//!   `no_candidates`. Fixed by deleting before saving.
//!
//! Content-named breaks when the resend **differs**. Position-named breaks when
//! the resend is **identical**. Neither could be caught by a forward-only test,
//! because every harness walked turn1 -> turn2 / round1 -> think-more and never
//! sent the same request twice.
//!
//! A third namespace MUST declare which column it is in. [`NAMESPACES`] is the
//! registry, and [`tests::snapshot_persistence_call_site_inventory`] fails when
//! a new save/delete site appears without one.

/// What a save must do when the name it is about to write may already hold a
/// snapshot.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) enum Collision {
    /// The name is content-addressed: an existing snapshot under it holds the
    /// same KV by construction, so a save that reports "already exists" is
    /// benign and the parked snapshot stays a valid hit.
    AcceptExisting,
    /// The name is positional: an existing snapshot under it may hold entirely
    /// different KV, so it MUST be deleted before the save. Accepting it would
    /// resume from the wrong branch; failing on it strands the request.
    ReplaceBeforeSave,
}

/// Every namespace written into the shared snapshot store.
pub(crate) const NAMESPACES: &[(&str, Collision)] = &[
    ("apc/", Collision::AcceptExisting),
    ("bon/", Collision::ReplaceBeforeSave),
];

/// The declared collision policy for `name`, or `None` when its namespace was
/// never registered — an unregistered namespace is a bug, not a default.
pub(crate) fn collision_for(name: &str) -> Option<Collision> {
    NAMESPACES
        .iter()
        .find(|(prefix, _)| name.starts_with(prefix))
        .map(|(_, policy)| *policy)
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::path::{Path, PathBuf};

    fn crate_src() -> PathBuf {
        Path::new(env!("CARGO_MANIFEST_DIR")).join("src")
    }

    fn rust_sources(dir: &Path, out: &mut Vec<PathBuf>) {
        for entry in std::fs::read_dir(dir).expect("readable src dir") {
            let path = entry.expect("readable dir entry").path();
            if path.is_dir() {
                rust_sources(&path, out);
            } else if path.extension().is_some_and(|e| e == "rs") {
                out.push(path);
            }
        }
    }

    /// Strip `#[cfg(test)] mod tests { .. }` so the inventory counts production
    /// call sites only — mock `save`/`delete` impls in test modules are not
    /// writes to the real store.
    fn production_only(body: &str) -> &str {
        match body.find("\nmod tests {") {
            Some(i) => &body[..i],
            None => body,
        }
    }

    #[test]
    fn content_addressed_names_accept_an_existing_snapshot() {
        assert_eq!(
            collision_for("apc/chat-7/v3/deadbeef"),
            Some(Collision::AcceptExisting),
        );
    }

    #[test]
    fn positional_names_must_replace_before_saving() {
        // The regenerate bug: the same request rebuilds this exact name, and
        // the KV behind it is sampled, so it is NOT the same KV.
        assert_eq!(
            collision_for("bon/req-1/2/0"),
            Some(Collision::ReplaceBeforeSave),
        );
    }

    #[test]
    fn an_unregistered_namespace_has_no_default_policy() {
        // Fail closed: a new namespace must be added to NAMESPACES with an
        // explicit column, never silently inherit one.
        assert_eq!(collision_for("scratch/whatever"), None);
        assert_eq!(collision_for(""), None);
    }

    #[test]
    fn every_registered_namespace_is_a_slash_terminated_prefix() {
        for (prefix, _) in NAMESPACES {
            assert!(
                prefix.ends_with('/') && prefix.len() > 1,
                "namespace {prefix:?} must be a non-empty slash-terminated prefix, \
                 else `starts_with` would alias a longer sibling name",
            );
        }
    }

    /// Canary: the number of places that persist or drop a snapshot is fixed.
    ///
    /// A new `.save(` or `Context::delete(` site means a new way for a name to
    /// collide. When this fails, do not just bump the count — decide which
    /// column of the [module table](super) the site's namespace is in, register
    /// it in [`NAMESPACES`], and make the site honor [`collision_for`].
    #[test]
    fn snapshot_persistence_call_site_inventory() {
        let mut files = Vec::new();
        rust_sources(&crate_src(), &mut files);
        files.sort();

        let mut saves = Vec::new();
        let mut deletes = Vec::new();
        for path in &files {
            let body = std::fs::read_to_string(path).expect("readable source");
            let rel = path.strip_prefix(crate_src()).unwrap().to_owned();
            for (n, line) in production_only(&body).lines().enumerate() {
                let code = line.split("//").next().unwrap_or("");
                if code.contains(".save(") {
                    saves.push(format!("{}:{}", rel.display(), n + 1));
                }
                if code.contains("Context::delete(") {
                    deletes.push(format!("{}:{}", rel.display(), n + 1));
                }
            }
        }

        // apc/ client boundary, apc/ generated boundary, bon/ candidate.
        assert_eq!(saves.len(), 3, "snapshot save sites changed: {saves:?}");
        // bon/ candidate replace-before-save, bon/ think-more sibling drop,
        // bon/ terminal release cleanup.
        assert_eq!(
            deletes.len(),
            3,
            "snapshot delete sites changed: {deletes:?}"
        );
    }
}
