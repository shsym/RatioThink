//! Request-thread scoped Cacheback n-gram sidecars.
//!
//! A sidecar is deliberately narrower than a process-global n-gram pool:
//! it is keyed by a caller supplied request-thread id plus compatibility
//! dimensions that affect token identity, and it is reused only when the
//! previous prompt lineage is a prefix of the current prompt lineage.

use std::collections::HashMap;
use std::collections::hash_map::DefaultHasher;
use std::hash::{Hash, Hasher};
use std::sync::{Arc, Mutex};
use std::time::Duration;

use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};

use super::SpecConfig;
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

    pub fn blob_name(&self) -> String {
        let mut hasher = DefaultHasher::new();
        self.hash(&mut hasher);
        format!("chat-apc/cacheback/v1/{:016x}", hasher.finish())
    }
}

/// Canonical prompt lineage used to decide whether a thread continued
/// from the same APC/prefix history or forked/invalidated.
#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
pub struct Lineage(Vec<LineageTurn>);

#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
struct LineageTurn {
    role: String,
    content_sha256: String,
}

impl Lineage {
    pub fn from_turns(turns: &[(&str, &str)]) -> Self {
        Self(
            turns
                .iter()
                .map(|(role, content)| LineageTurn {
                    role: (*role).to_string(),
                    content_sha256: sha256_hex(content.as_bytes()),
                })
                .collect(),
        )
    }

    pub fn with_turn(&self, role: &str, content: &str) -> Self {
        let mut turns = self.0.clone();
        turns.push(LineageTurn {
            role: role.to_string(),
            content_sha256: sha256_hex(content.as_bytes()),
        });
        Self(turns)
    }

    pub fn is_continuation_of(&self, prior: &Self) -> bool {
        self.0.starts_with(&prior.0)
    }
}

fn sha256_hex(bytes: &[u8]) -> String {
    let digest = Sha256::digest(bytes);
    let mut out = String::with_capacity(digest.len() * 2);
    for byte in digest {
        use std::fmt::Write as _;
        let _ = write!(out, "{byte:02x}");
    }
    out
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum SidecarStatus {
    Fresh,
    Reused,
    DecodeFailed,
    LineageForked,
}

pub struct SidecarCheckout {
    pub cache: Arc<Mutex<NgramCache>>,
    pub status: SidecarStatus,
    pub expired: usize,
    pub ngram_leaders: usize,
    pub delete_persisted: bool,
    pub diagnostic: Option<String>,
}

#[derive(Deserialize, Serialize)]
struct SerializedSidecar {
    lineage: Lineage,
    cache: super::cache::NgramCacheSnapshot,
}

pub fn encode_sidecar_blob(lineage: &Lineage, cache: &NgramCache) -> serde_json::Result<Vec<u8>> {
    serde_json::to_vec(&SerializedSidecar {
        lineage: lineage.clone(),
        cache: cache.snapshot(),
    })
}

pub fn decode_sidecar_blob(bytes: &[u8]) -> serde_json::Result<(Lineage, NgramCache)> {
    let blob: SerializedSidecar = serde_json::from_slice(bytes)?;
    Ok((blob.lineage, NgramCache::from_snapshot(blob.cache)))
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

    #[cfg(test)]
    pub fn checkout(&mut self, now_ms: u64, key: SidecarKey, lineage: Lineage) -> SidecarCheckout {
        self.checkout_with_persisted(now_ms, key, lineage, None)
    }

    pub fn checkout_with_persisted(
        &mut self,
        now_ms: u64,
        key: SidecarKey,
        lineage: Lineage,
        persisted: Option<Vec<u8>>,
    ) -> SidecarCheckout {
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
                    delete_persisted: false,
                    diagnostic: None,
                };
            }
        }

        let mut non_reuse_status = SidecarStatus::Fresh;
        let mut delete_persisted = false;
        let mut diagnostic = None;
        if let Some(bytes) = persisted {
            match decode_sidecar_blob(&bytes) {
                Ok((prior_lineage, persisted_cache)) => {
                    if lineage.is_continuation_of(&prior_lineage) {
                        let ngram_leaders = persisted_cache.len();
                        let cache = Arc::new(Mutex::new(persisted_cache));
                        self.entries.insert(
                            key,
                            SidecarEntry {
                                lineage,
                                last_used_ms: now_ms,
                                cache: Arc::clone(&cache),
                            },
                        );
                        return SidecarCheckout {
                            cache,
                            status: SidecarStatus::Reused,
                            expired,
                            ngram_leaders,
                            delete_persisted: false,
                            diagnostic: None,
                        };
                    }
                    non_reuse_status = SidecarStatus::LineageForked;
                    diagnostic =
                        Some("persisted lineage is not a prefix of request lineage".to_string());
                }
                Err(e) => {
                    non_reuse_status = SidecarStatus::DecodeFailed;
                    delete_persisted = true;
                    diagnostic = Some(e.to_string());
                }
            }
        }

        // Caps mirror `SpecConfig::default()` (the key carries only
        // leader_len/draft_len, not caps); reference the single source so
        // the two can't drift.
        let caps = SpecConfig::default();
        let cache = Arc::new(Mutex::new(NgramCache::new(
            key.leader_len,
            caps.leader_cap,
            caps.follower_cap,
        )));
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
            status: non_reuse_status,
            expired,
            ngram_leaders: 0,
            delete_persisted,
            diagnostic,
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

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn hydrates_persisted_blob_when_lineage_continues() {
        let key = SidecarKey::new("chat-a", "model-a", Some("profile"), 7, 1, 3);
        let prior_lineage = Lineage::from_turns(&[("user", "hello")]);
        let next_lineage =
            Lineage::from_turns(&[("user", "hello"), ("assistant", "hi"), ("user", "continue")]);
        let mut cache = NgramCache::new(1, 16, 8);
        cache.record(&[10], 20);
        let bytes = encode_sidecar_blob(&prior_lineage, &cache).unwrap();

        let mut store = SidecarStore::new(Duration::from_millis(1_000));
        let checkout = store.checkout_with_persisted(10, key, next_lineage, Some(bytes));

        assert_eq!(checkout.status, SidecarStatus::Reused);
        assert_eq!(checkout.ngram_leaders, 1);
        assert_eq!(checkout.cache.lock().unwrap().get(&[10]), Some(20));
    }

    #[test]
    fn ignores_persisted_blob_when_lineage_forks() {
        let key = SidecarKey::new("chat-a", "model-a", None, 7, 1, 3);
        let prior_lineage = Lineage::from_turns(&[("user", "hello")]);
        let forked_lineage = Lineage::from_turns(&[("user", "edited")]);
        let mut cache = NgramCache::new(1, 16, 8);
        cache.record(&[10], 20);
        let bytes = encode_sidecar_blob(&prior_lineage, &cache).unwrap();

        let mut store = SidecarStore::new(Duration::from_millis(1_000));
        let checkout = store.checkout_with_persisted(10, key, forked_lineage, Some(bytes));

        assert_eq!(checkout.status, SidecarStatus::LineageForked);
        assert_eq!(checkout.ngram_leaders, 0);
        assert_eq!(checkout.cache.lock().unwrap().get(&[10]), None);
    }

    #[test]
    fn blob_name_changes_with_key_dimensions() {
        let a = SidecarKey::new("chat-a", "model-a", None, 7, 1, 3);
        let b = SidecarKey::new("chat-a", "model-a", None, 7, 1, 4);

        assert_ne!(a.blob_name(), b.blob_name());
        assert!(a.blob_name().starts_with("chat-apc/cacheback/v1/"));
    }

    #[test]
    fn persisted_lineage_can_include_generated_assistant_output_to_detect_forks() {
        let key = SidecarKey::new("chat-a", "model-a", None, 7, 1, 3);
        let pre_response = Lineage::from_turns(&[("user", "hello")]);
        let assistant_a = pre_response.with_turn("assistant", "answer A");
        let forked_after_b = Lineage::from_turns(&[
            ("user", "hello"),
            ("assistant", "answer B"),
            ("user", "continue"),
        ]);
        let mut cache = NgramCache::new(1, 16, 8);
        cache.record(&[10], 20);
        let bytes = encode_sidecar_blob(&assistant_a, &cache).unwrap();

        let mut store = SidecarStore::new(Duration::from_millis(1_000));
        let checkout = store.checkout_with_persisted(10, key, forked_after_b, Some(bytes));

        assert_eq!(checkout.status, SidecarStatus::LineageForked);
        assert_eq!(checkout.ngram_leaders, 0);
        assert!(!checkout.delete_persisted);
        assert_eq!(checkout.cache.lock().unwrap().get(&[10]), None);
    }

    #[test]
    fn corrupt_persisted_blob_reports_decode_failed_and_requests_delete() {
        let key = SidecarKey::new("chat-a", "model-a", None, 7, 1, 3);
        let lineage = Lineage::from_turns(&[("user", "hello")]);

        let mut store = SidecarStore::new(Duration::from_millis(1_000));
        let checkout = store.checkout_with_persisted(10, key, lineage, Some(b"{not json".to_vec()));

        assert_eq!(checkout.status, SidecarStatus::DecodeFailed);
        assert!(checkout.delete_persisted);
        assert!(checkout.diagnostic.is_some());
    }

    #[test]
    fn mismatched_persisted_blob_reports_lineage_forked() {
        let key = SidecarKey::new("chat-a", "model-a", None, 7, 1, 3);
        let prior_lineage = Lineage::from_turns(&[("user", "hello")]);
        let forked_lineage = Lineage::from_turns(&[("user", "edited")]);
        let cache = NgramCache::new(1, 16, 8);
        let bytes = encode_sidecar_blob(&prior_lineage, &cache).unwrap();

        let mut store = SidecarStore::new(Duration::from_millis(1_000));
        let checkout = store.checkout_with_persisted(10, key, forked_lineage, Some(bytes));

        assert_eq!(checkout.status, SidecarStatus::LineageForked);
        assert!(!checkout.delete_persisted);
        assert!(checkout.diagnostic.is_some());
    }

    #[test]
    fn serialized_lineage_hashes_prompt_content_without_plaintext() {
        let secret = "sentinel-secret-please-do-not-persist";
        let lineage = Lineage::from_turns(&[("user", secret)]);
        let continued = Lineage::from_turns(&[("user", secret), ("assistant", "ok")]);
        let forked = Lineage::from_turns(&[("user", "different")]);
        let cache = NgramCache::new(1, 16, 8);
        let bytes = encode_sidecar_blob(&lineage, &cache).unwrap();

        assert!(!String::from_utf8_lossy(&bytes).contains(secret));
        let (decoded, _) = decode_sidecar_blob(&bytes).unwrap();
        assert!(continued.is_continuation_of(&decoded));
        assert!(!forked.is_continuation_of(&decoded));
    }
}
