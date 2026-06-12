//! Pure LRU n-gram cache for Cacheback-style speculative drafting.
//!
//! Dynamic table only (no frozen/offline table): maps a *leader* (the
//! last `leader_len` tokens) to a recency-ordered list of *followers*
//! (tokens observed to follow that leader). Both the leader table and
//! each follower list are LRU-bounded. [`NgramCache::get`] returns the
//! most-recent follower — the linear-chain draft pick.
//!
//! No `inferlet` dependency, so this module host-unit-tests directly via
//! `cargo test`. Deviation from the paper (arXiv:2511.21699): recency is
//! updated on both `record` (write) and `get` (read); we keep a small
//! follower list per leader and always draft the most-recent follower
//! (linear, not tree). LL/FL/capacities are configurable; paper-optimal
//! defaults LL=1, FL=3 live in [`super::SpecConfig`].

use std::collections::HashMap;

use serde::{Deserialize, Serialize};

/// Bounded LRU map: leader (n-gram) -> recency-ordered followers.
pub struct NgramCache {
    leader_len: usize,
    leader_cap: usize,
    follower_cap: usize,
    map: HashMap<Vec<u32>, LeaderEntry>,
    /// Monotonic logical clock driving LRU eviction.
    tick: u64,
}

struct LeaderEntry {
    /// Recency-ordered; last element is the most-recent follower.
    followers: Vec<u32>,
    last_used: u64,
}

#[derive(Clone, Debug, Deserialize, Serialize)]
pub struct NgramCacheSnapshot {
    leader_len: usize,
    leader_cap: usize,
    follower_cap: usize,
    tick: u64,
    entries: Vec<NgramCacheSnapshotEntry>,
}

#[derive(Clone, Debug, Deserialize, Serialize)]
struct NgramCacheSnapshotEntry {
    leader: Vec<u32>,
    followers: Vec<u32>,
    last_used: u64,
}

impl NgramCache {
    pub fn new(leader_len: usize, leader_cap: usize, follower_cap: usize) -> Self {
        Self {
            leader_len: leader_len.max(1),
            leader_cap: leader_cap.max(1),
            follower_cap: follower_cap.max(1),
            map: HashMap::new(),
            tick: 0,
        }
    }

    /// Distinct leaders currently held — the cache size. Grows as
    /// generation observes new n-grams; surfaced as the `cache_size` spec
    /// metric so the bench can see cache growth alongside hit rate.
    #[allow(clippy::len_without_is_empty)] // cache size, not a collection API
    pub fn len(&self) -> usize {
        self.map.len()
    }

    pub fn snapshot(&self) -> NgramCacheSnapshot {
        NgramCacheSnapshot {
            leader_len: self.leader_len,
            leader_cap: self.leader_cap,
            follower_cap: self.follower_cap,
            tick: self.tick,
            entries: self
                .map
                .iter()
                .map(|(leader, entry)| NgramCacheSnapshotEntry {
                    leader: leader.clone(),
                    followers: entry.followers.clone(),
                    last_used: entry.last_used,
                })
                .collect(),
        }
    }

    pub fn from_snapshot(snapshot: NgramCacheSnapshot) -> Self {
        let mut cache = Self {
            leader_len: snapshot.leader_len.max(1),
            leader_cap: snapshot.leader_cap.max(1),
            follower_cap: snapshot.follower_cap.max(1),
            map: HashMap::new(),
            tick: snapshot.tick,
        };
        let mut entries = snapshot.entries;
        entries.sort_by_key(|entry| entry.last_used);
        for entry in entries {
            if entry.leader.len() != cache.leader_len {
                continue;
            }
            if cache.map.len() >= cache.leader_cap {
                cache.evict_lru_leader();
            }
            let mut followers = entry.followers;
            if followers.len() > cache.follower_cap {
                followers = followers[followers.len() - cache.follower_cap..].to_vec();
            }
            cache.map.insert(
                entry.leader,
                LeaderEntry {
                    followers,
                    last_used: entry.last_used,
                },
            );
        }
        cache
    }

    fn next_tick(&mut self) -> u64 {
        self.tick += 1;
        self.tick
    }

    /// Record that `follower` followed `leader`. Refreshes recency and
    /// dedups: a repeated follower moves to most-recent rather than
    /// duplicating. Ignores malformed keys (wrong length).
    pub fn record(&mut self, leader: &[u32], follower: u32) {
        if leader.len() != self.leader_len {
            return;
        }
        let t = self.next_tick();
        if let Some(entry) = self.map.get_mut(leader) {
            entry.last_used = t;
            if let Some(pos) = entry.followers.iter().position(|&f| f == follower) {
                entry.followers.remove(pos);
            }
            entry.followers.push(follower);
            if entry.followers.len() > self.follower_cap {
                entry.followers.remove(0);
            }
            return;
        }
        if self.map.len() >= self.leader_cap {
            self.evict_lru_leader();
        }
        self.map.insert(
            leader.to_vec(),
            LeaderEntry {
                followers: vec![follower],
                last_used: t,
            },
        );
    }

    /// Most-recent follower for `leader`, or `None`. Refreshes recency.
    pub fn get(&mut self, leader: &[u32]) -> Option<u32> {
        if leader.len() != self.leader_len {
            return None;
        }
        let t = self.next_tick();
        let entry = self.map.get_mut(leader)?;
        entry.last_used = t;
        entry.followers.last().copied()
    }

    fn evict_lru_leader(&mut self) {
        if let Some(key) = self
            .map
            .iter()
            .min_by_key(|(_, e)| e.last_used)
            .map(|(k, _)| k.clone())
        {
            self.map.remove(&key);
        }
    }

    #[cfg(test)]
    pub fn followers(&self, leader: &[u32]) -> Vec<u32> {
        self.map
            .get(leader)
            .map(|e| e.followers.clone())
            .unwrap_or_default()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn get_returns_most_recent_follower() {
        let mut c = NgramCache::new(1, 16, 8);
        c.record(&[10], 20);
        c.record(&[10], 21);
        assert_eq!(c.get(&[10]), Some(21));
    }

    #[test]
    fn get_misses_on_unseen_leader() {
        let mut c = NgramCache::new(1, 16, 8);
        c.record(&[10], 20);
        assert_eq!(c.get(&[99]), None);
    }

    #[test]
    fn snapshot_round_trips_cache_contents_and_lru_state() {
        let mut c = NgramCache::new(2, 3, 2);
        c.record(&[1, 2], 10);
        c.record(&[1, 2], 11);
        c.record(&[2, 3], 12);
        assert_eq!(c.get(&[1, 2]), Some(11));

        let snapshot = c.snapshot();
        let mut restored = NgramCache::from_snapshot(snapshot);

        assert_eq!(restored.get(&[1, 2]), Some(11));
        assert_eq!(restored.followers(&[1, 2]), vec![10, 11]);
        restored.record(&[3, 4], 13);
        restored.record(&[4, 5], 14);
        assert_eq!(restored.get(&[2, 3]), None);
    }

    #[test]
    fn leader_table_evicts_least_recently_used() {
        let mut c = NgramCache::new(1, 2, 8); // leader_cap = 2
        c.record(&[1], 100);
        c.record(&[2], 200);
        let _ = c.get(&[1]); // touch [1] -> [2] now LRU
        c.record(&[3], 300); // inserts [3], evicts [2]
        assert_eq!(c.get(&[1]), Some(100));
        assert_eq!(c.get(&[2]), None);
        assert_eq!(c.get(&[3]), Some(300));
    }

    #[test]
    fn follower_list_evicts_oldest_when_full() {
        let mut c = NgramCache::new(1, 16, 2); // follower_cap = 2
        c.record(&[5], 1);
        c.record(&[5], 2);
        c.record(&[5], 3); // drops follower 1
        assert_eq!(c.get(&[5]), Some(3));
        assert_eq!(c.followers(&[5]), vec![2, 3]);
    }

    #[test]
    fn duplicate_follower_moves_to_most_recent() {
        let mut c = NgramCache::new(1, 16, 4);
        c.record(&[7], 1);
        c.record(&[7], 2);
        c.record(&[7], 1); // 1 refreshed, not duplicated
        assert_eq!(c.followers(&[7]), vec![2, 1]);
        assert_eq!(c.get(&[7]), Some(1));
    }

    #[test]
    fn leader_len_two_keys_on_pair() {
        let mut c = NgramCache::new(2, 16, 8);
        c.record(&[1, 2], 3);
        assert_eq!(c.get(&[1, 2]), Some(3));
        assert_eq!(c.get(&[2, 1]), None);
    }

    #[test]
    fn malformed_key_length_is_ignored() {
        let mut c = NgramCache::new(2, 16, 8);
        c.record(&[1], 9); // wrong length for LL=2
        assert_eq!(c.len(), 0);
        assert_eq!(c.get(&[1]), None);
    }
}
