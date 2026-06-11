//! Request-thread scoped Cacheback n-gram sidecars.
//!
//! A sidecar is deliberately narrower than a process-global n-gram pool:
//! it is keyed by a caller supplied request-thread id plus compatibility
//! dimensions that affect token identity, and it is reused only when the
//! previous prompt lineage is a prefix of the current prompt lineage.

use std::collections::HashMap;
use std::sync::{Arc, Mutex};
use std::time::Duration;

use super::cache::NgramCache;

/// Request-thread local identity for a persisted Cacheback table.
#[derive(Clone, Debug, Eq, Hash, PartialEq)]
pub struct SidecarKey {
    thread_id: String,
    model: String,
    profile_id: Option<String>,
    tools_digest: u64,
    leader_len: usize,
    draft_len: usize,
}

impl SidecarKey {
    pub fn new(
        thread_id: impl Into<String>,
        model: impl Into<String>,
        profile_id: Option<&str>,
        tools_digest: u64,
        leader_len: usize,
        draft_len: usize,
    ) -> Self {
        Self {
            thread_id: thread_id.into(),
            model: model.into(),
            profile_id: profile_id.map(str::to_string),
            tools_digest,
            leader_len,
            draft_len,
        }
    }
}

/// Canonical prompt lineage used to decide whether a thread continued
/// from the same APC/prefix history or forked/invalidated.
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct Lineage(Vec<LineageTurn>);

#[derive(Clone, Debug, Eq, PartialEq)]
struct LineageTurn {
    role: String,
    content: String,
}

impl Lineage {
    pub fn from_turns(turns: &[(&str, &str)]) -> Self {
        Self(
            turns
                .iter()
                .map(|(role, content)| LineageTurn {
                    role: (*role).to_string(),
                    content: (*content).to_string(),
                })
                .collect(),
        )
    }

    pub fn is_continuation_of(&self, prior: &Self) -> bool {
        self.0.starts_with(&prior.0)
    }
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum SidecarStatus {
    Fresh,
    Reused,
}

pub struct SidecarCheckout {
    pub cache: Arc<Mutex<NgramCache>>,
    pub status: SidecarStatus,
    pub expired: usize,
    pub ngram_leaders: usize,
}

struct SidecarEntry {
    lineage: Lineage,
    last_used_ms: u64,
    cache: Arc<Mutex<NgramCache>>,
}

pub struct SidecarStore {
    ttl_ms: u64,
    entries: HashMap<SidecarKey, SidecarEntry>,
}

impl SidecarStore {
    pub fn new(ttl: Duration) -> Self {
        Self {
            ttl_ms: ttl.as_millis().try_into().unwrap_or(u64::MAX),
            entries: HashMap::new(),
        }
    }

    pub fn checkout(&mut self, now_ms: u64, key: SidecarKey, lineage: Lineage) -> SidecarCheckout {
        let expired = self.prune_expired(now_ms);
        if let Some(entry) = self.entries.get_mut(&key) {
            if lineage.is_continuation_of(&entry.lineage) {
                entry.lineage = lineage;
                entry.last_used_ms = now_ms;
                let ngram_leaders = entry.cache.lock().unwrap().len();
                return SidecarCheckout {
                    cache: Arc::clone(&entry.cache),
                    status: SidecarStatus::Reused,
                    expired,
                    ngram_leaders,
                };
            }
        }

        let cache = Arc::new(Mutex::new(NgramCache::new(key.leader_len, 1 << 16, 8)));
        self.entries.insert(
            key,
            SidecarEntry {
                lineage,
                last_used_ms: now_ms,
                cache: Arc::clone(&cache),
            },
        );
        SidecarCheckout {
            cache,
            status: SidecarStatus::Fresh,
            expired,
            ngram_leaders: 0,
        }
    }

    fn prune_expired(&mut self, now_ms: u64) -> usize {
        let before = self.entries.len();
        let ttl_ms = self.ttl_ms;
        self.entries
            .retain(|_, entry| now_ms.saturating_sub(entry.last_used_ms) <= ttl_ms);
        before - self.entries.len()
    }
}
