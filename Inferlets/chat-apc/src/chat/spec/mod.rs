//! Cacheback-style linear speculative drafter for chat-apc.
//!
//! Wraps the pure [`cache::NgramCache`] in an [`inferlet::Speculator`]:
//! seeds the dynamic table from the prompt, drafts a linear chain of up
//! to `draft_len` followers, records accepted tokens, and tracks
//! acceptance metrics. Greedy-only: the Generator's accepted tokens are
//! the model's own per-position samples, so a matched draft is
//! token-identical to non-speculative greedy decode (verified against
//! `Vendor/pie/sdk/rust/inferlet/src/generation.rs`).
//!
//! `rollback` is a no-op: the cache grows only from *accepted* tokens,
//! and the SDK truncates rejected-draft KV itself, so there is nothing
//! to undo. The cursor advances by `accepted.len()` each step, which
//! tracks `seq_len + n_pending` because only the last accepted token is
//! re-fed as the next anchor.
//!
//! v1 = dynamic-table-only + linear chain. Frozen offline table + tree
//! drafting + stochastic verify are the full-Cacheback follow-up
//! (arXiv:2511.21699). See
//! `docs/plans/2026-06-03-cacheback-speculative-decoding.md`.

pub mod cache;

use std::sync::{Arc, Mutex};

use cache::NgramCache;

/// Paper-grounded defaults (arXiv:2511.21699): Leader Length 1,
/// Follower Length 3.
#[derive(Clone, Debug)]
pub struct SpecConfig {
    pub enabled: bool,
    pub leader_len: usize,
    pub draft_len: usize,
    pub leader_cap: usize,
    pub follower_cap: usize,
}

impl Default for SpecConfig {
    fn default() -> Self {
        Self {
            enabled: false,
            leader_len: 1,
            draft_len: 3,
            // 65536 leaders: the paper's LC=2^20 scaled down for a
            // single chat turn; bounded so a long turn can't grow it
            // without limit.
            leader_cap: 1 << 16,
            // Linear drafting only ever reads the most-recent follower;
            // a small list is enough to absorb churn.
            follower_cap: 8,
        }
    }
}

/// Acceptance accounting for one generation. Shared via `Arc<Mutex<_>>`
/// because `Generator::speculator` takes ownership of the drafter, so the
/// transport loop reads the final counts through a cloned handle.
#[derive(Clone, Copy, Debug, Default)]
pub struct SpecMetrics {
    /// Draft tokens proposed across all steps.
    pub proposed: usize,
    /// Draft tokens the verifier accepted.
    pub accepted: usize,
    /// Draft tokens the verifier rejected (`proposed - accepted`).
    pub rejected: usize,
    /// Decode steps (forward passes / accept calls).
    pub steps: usize,
    /// Tokens committed (free picks + accepted drafts).
    pub generated: usize,
}

pub struct CachebackDrafter {
    cache: NgramCache,
    cfg: SpecConfig,
    /// Last `leader_len` committed tokens — the current leader.
    recent: Vec<u32>,
    /// Next draft KV position; tracks `seq_len + n_pending`.
    cursor: u32,
    start_cursor: u32,
    /// Drafts proposed in the most recent `draft()`; read by `accept`.
    last_proposed: usize,
    metrics: Arc<Mutex<SpecMetrics>>,
}

impl CachebackDrafter {
    pub fn new(cfg: SpecConfig, start_cursor: u32) -> Self {
        let cache = NgramCache::new(cfg.leader_len, cfg.leader_cap, cfg.follower_cap);
        Self {
            cache,
            cfg,
            recent: Vec::new(),
            cursor: start_cursor,
            start_cursor,
            last_proposed: 0,
            metrics: Arc::new(Mutex::new(SpecMetrics::default())),
        }
    }

    /// Clone the shared metrics handle. Call before moving the drafter
    /// into `Generator::speculator` so the loop can read final counts.
    pub fn metrics_handle(&self) -> Arc<Mutex<SpecMetrics>> {
        Arc::clone(&self.metrics)
    }

    /// Snapshot of current metrics.
    pub fn metrics(&self) -> SpecMetrics {
        *self.metrics.lock().unwrap()
    }

    pub fn cursor(&self) -> u32 {
        self.cursor
    }

    pub fn cache_len(&self) -> usize {
        self.cache.len()
    }

    /// Seed the dynamic table from prompt tokens. Does NOT advance the
    /// cursor — the prompt KV is already committed by the caller's flush.
    pub fn seed(&mut self, tokens: &[u32]) {
        for &t in tokens {
            self.ingest(t);
        }
    }

    /// Record one committed token into the cache and roll the leader
    /// window forward.
    fn ingest(&mut self, t: u32) {
        if self.recent.len() == self.cfg.leader_len {
            self.cache.record(&self.recent, t);
        }
        self.recent.push(t);
        while self.recent.len() > self.cfg.leader_len {
            self.recent.remove(0);
        }
    }
}

impl inferlet::Speculator for CachebackDrafter {
    fn draft(&mut self) -> (Vec<u32>, Vec<u32>) {
        if self.recent.len() < self.cfg.leader_len {
            self.last_proposed = 0;
            return (Vec::new(), Vec::new());
        }
        let mut drafts = Vec::with_capacity(self.cfg.draft_len);
        let mut leader = self.recent.clone();
        for _ in 0..self.cfg.draft_len {
            match self.cache.get(&leader) {
                Some(f) => {
                    drafts.push(f);
                    leader.remove(0);
                    leader.push(f);
                }
                None => break,
            }
        }
        self.last_proposed = drafts.len();
        let positions: Vec<u32> = (self.cursor..self.cursor + drafts.len() as u32).collect();
        (drafts, positions)
    }

    fn accept(&mut self, accepted: &[u32]) {
        if accepted.is_empty() {
            self.last_proposed = 0;
            return;
        }
        // accepted[0] is the anchor's free pick; accepted[1..] are
        // accepted drafts (capped by how many we actually proposed).
        let hits = accepted.len().saturating_sub(1).min(self.last_proposed);
        {
            let mut m = self.metrics.lock().unwrap();
            m.proposed += self.last_proposed;
            m.accepted += hits;
            m.rejected += self.last_proposed - hits;
            m.steps += 1;
            m.generated += accepted.len();
        }
        self.last_proposed = 0;
        for &t in accepted {
            self.ingest(t);
        }
        self.cursor += accepted.len() as u32;
    }

    fn rollback(&mut self, _n: u32) {
        // No-op: the cache grows only from accepted tokens (never from
        // proposed drafts), and the SDK truncates rejected-draft KV
        // itself. The cursor was advanced by `accepted.len()` only, so
        // nothing here needs undoing.
    }

    fn reset(&mut self) {
        self.cache = NgramCache::new(
            self.cfg.leader_len,
            self.cfg.leader_cap,
            self.cfg.follower_cap,
        );
        self.recent.clear();
        self.cursor = self.start_cursor;
        self.last_proposed = 0;
        *self.metrics.lock().unwrap() = SpecMetrics::default();
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use inferlet::Speculator;

    fn cfg() -> SpecConfig {
        SpecConfig {
            enabled: true,
            leader_len: 1,
            draft_len: 3,
            ..SpecConfig::default()
        }
    }

    /// Simulate one Generator step against a deterministic model:
    /// `draft()` -> verify each draft against the model's own sample ->
    /// `accept(accepted)` -> `rollback(rejected)`. Mirrors the SDK's
    /// acceptance walk in `generation.rs::GenStep::execute`.
    fn step(d: &mut CachebackDrafter, model: &dyn Fn(&[u32]) -> u32, ctx: &mut Vec<u32>) -> Vec<u32> {
        let (drafts, positions) = d.draft();
        assert_eq!(drafts.len(), positions.len());
        let free = model(ctx);
        let mut accepted = vec![free];
        let mut prefix = ctx.clone();
        prefix.push(free);
        for &dr in &drafts {
            let picked = *accepted.last().unwrap();
            if dr != picked {
                break;
            }
            let next = model(&prefix);
            accepted.push(next);
            prefix.push(next);
        }
        let n_rejected = (drafts.len() as u32).saturating_sub(accepted.len() as u32 - 1);
        for &t in &accepted {
            ctx.push(t);
        }
        d.accept(&accepted);
        d.rollback(n_rejected);
        accepted
    }

    #[test]
    fn draft_empty_when_cold() {
        let mut d = CachebackDrafter::new(cfg(), 0);
        assert_eq!(d.draft(), (Vec::new(), Vec::new()));
    }

    #[test]
    fn draft_chains_followers_linearly() {
        let mut d = CachebackDrafter::new(cfg(), 0);
        // a,b,c repeating so 3->1, 1->2, 2->3 chain after seeding.
        d.seed(&[1, 2, 3, 1, 2, 3]);
        let (drafts, positions) = d.draft();
        assert_eq!(drafts, vec![1, 2, 3]);
        // cursor seeded at 0, seed does not advance it.
        assert_eq!(positions, vec![0, 1, 2]);
    }

    #[test]
    fn accept_accounts_hits_and_rejects() {
        let mut d = CachebackDrafter::new(cfg(), 0);
        d.last_proposed = 3; // pretend 3 drafted
        d.accept(&[100, 200, 201]); // free + 2 hits
        let m = d.metrics();
        assert_eq!(m.proposed, 3);
        assert_eq!(m.accepted, 2);
        assert_eq!(m.rejected, 1);
        assert_eq!(m.steps, 1);
        assert_eq!(m.generated, 3);
    }

    #[test]
    fn rollback_is_noop_for_state() {
        let mut d = CachebackDrafter::new(cfg(), 0);
        d.seed(&[1, 2]);
        let cursor_before = d.cursor();
        let cache_before = d.cache_len();
        d.rollback(2);
        assert_eq!(d.cursor(), cursor_before);
        assert_eq!(d.cache_len(), cache_before);
    }

    #[test]
    fn reset_clears_everything() {
        let mut d = CachebackDrafter::new(cfg(), 5);
        d.seed(&[1, 2, 3]);
        d.last_proposed = 1;
        d.accept(&[3, 4]);
        d.reset();
        assert_eq!(d.cache_len(), 0);
        assert_eq!(d.cursor(), 5);
        assert_eq!(d.metrics().steps, 0);
        assert_eq!(d.draft(), (Vec::new(), Vec::new()));
    }

    #[test]
    fn deterministic_accounting_repeating_corpus() {
        let mut d = CachebackDrafter::new(cfg(), 0);
        let period = [1u32, 2, 3, 4];
        let mut ctx: Vec<u32> = period.iter().cloned().cycle().take(8).collect();
        d.seed(&ctx);
        let model = |c: &[u32]| -> u32 {
            let last = *c.last().unwrap();
            let idx = period.iter().position(|&x| x == last).unwrap();
            period[(idx + 1) % period.len()]
        };
        for _ in 0..5 {
            let _ = step(&mut d, &model, &mut ctx);
        }
        let m = d.metrics();
        assert_eq!(m.steps, 5);
        assert!(m.accepted > 0);
        // periodic stream + warm cache => every proposed draft accepted.
        assert_eq!(m.proposed, m.accepted);
        assert_eq!(m.rejected, 0);
    }

    #[test]
    fn greedy_spec_matches_plain_token_stream() {
        // The decisive equivalence check: a spec-driven decode and a
        // plain (1 token/step) decode over the same deterministic model
        // + seed must produce the identical token stream.
        let period = [5u32, 6, 7];
        let model = |c: &[u32]| -> u32 {
            let last = *c.last().unwrap();
            let idx = period.iter().position(|&x| x == last).unwrap();
            period[(idx + 1) % period.len()]
        };
        let seed: Vec<u32> = period.iter().cloned().cycle().take(6).collect();

        // Plain decode: 8 tokens, one per step.
        let mut plain_ctx = seed.clone();
        let mut plain_out = Vec::new();
        for _ in 0..8 {
            let t = model(&plain_ctx);
            plain_out.push(t);
            plain_ctx.push(t);
        }

        // Spec decode: drive the drafter until 8 tokens are produced.
        let mut d = CachebackDrafter::new(cfg(), 0);
        d.seed(&seed);
        let mut spec_ctx = seed.clone();
        let mut spec_out = Vec::new();
        while spec_out.len() < 8 {
            let before = spec_ctx.len();
            let _ = step(&mut d, &model, &mut spec_ctx);
            spec_out.extend_from_slice(&spec_ctx[before..]);
        }
        spec_out.truncate(8);

        assert_eq!(spec_out, plain_out);
    }
}
