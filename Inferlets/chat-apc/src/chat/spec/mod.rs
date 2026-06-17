//! Cacheback-style linear speculative drafter for chat-apc.
//!
//! Wraps the pure [`cache::NgramCache`] in an [`inferlet::Speculator`]:
//! seeds the dynamic table from the prompt, drafts a linear chain of up
//! to `draft_len` followers, records accepted tokens, and tracks
//! acceptance metrics. Greedy-only: the Generator's accepted tokens are
//! the model's own per-position samples, so a matched draft reproduces
//! non-speculative greedy decode *as computed by the verify forward*
//! (logic verified against
//! `Vendor/pie/sdk/rust/inferlet/src/generation.rs`).
//!
//! SHORT-WINDOW guarantee, not unconditional byte-identity (#592): the
//! verify is a batched multi-position forward (`kernel_mul_mm`) whose FP
//! reduction order differs from single-token plain decode
//! (`kernel_mul_mv`). At a near-tie logit those round differently and
//! argmax flips, so on the portable Metal backend the spec trajectory
//! drifts off plain greedy past a short window (~80-150 tok on
//! Qwen3-0.6B) — staying a valid, self-consistent greedy continuation,
//! just not token-for-token equal to plain. `spec_smoke_real.py` gates
//! identity only inside the short window; `spec_bench_real.py` records
//! the long-window drift with a baseline-determinism control.
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
pub mod sidecar;

use std::sync::{Arc, Mutex};

use cache::NgramCache;

/// Drafting parameters (the "how", not the "whether" — that is the
/// caller's [`super::generate::DecodeStrategy`] choice). Paper-grounded
/// defaults (arXiv:2511.21699): Leader Length 1, Follower Length 3.
#[derive(Clone, Debug)]
pub struct SpecConfig {
    pub leader_len: usize,
    pub draft_len: usize,
    pub leader_cap: usize,
    pub follower_cap: usize,
}

impl Default for SpecConfig {
    fn default() -> Self {
        Self {
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
/// Not `Copy`: carries the per-step accepted-prefix-length histogram as a
/// `Vec`. The transport loop reads it via `.clone()` through the shared
/// handle after generation completes.
#[derive(Clone, Debug, Default)]
pub struct SpecMetrics {
    /// Draft tokens proposed across all steps.
    pub proposed: usize,
    /// Draft tokens the verifier accepted.
    pub accepted: usize,
    /// Draft tokens the verifier rejected (`proposed - accepted`).
    pub rejected: usize,
    /// Decode steps (forward passes / accept calls). Drafter-internal
    /// accounting cross-checked in tests; the wire report's `decode_steps`
    /// comes from the transport's own per-forward-pass counter.
    pub steps: usize,
    /// Tokens committed (free picks + accepted drafts). Drafter-internal
    /// accounting cross-checked in tests; the wire report's
    /// `generated_tokens` comes from the transport's own counter.
    pub generated: usize,
    /// `NgramCache::get` lookups in `draft()` that returned a follower.
    pub cache_hits: usize,
    /// `NgramCache::get` lookups in `draft()` that returned empty — a cold
    /// leader (no entry) or a chain that ran dry mid-draft.
    pub cache_misses: usize,
    /// Distinct leaders held after the last committed step — the cache size
    /// (n-gram table growth over the turn).
    pub cache_size: usize,
    /// Accepted-prefix length distribution: `accepted_prefix_hist[k]` is the
    /// number of decode steps that committed exactly `k` accepted draft
    /// tokens (index 0 = free pick only — cold or fully-rejected step).
    /// Exposes the chain-length spread behind `avg_tokens_per_step`.
    pub accepted_prefix_hist: Vec<usize>,
}

pub struct CachebackDrafter {
    cache: Arc<Mutex<NgramCache>>,
    cfg: SpecConfig,
    /// Last `leader_len` committed tokens — the current leader.
    recent: Vec<u32>,
    /// Next draft KV position; tracks `seq_len + n_pending`.
    cursor: u32,
    start_cursor: u32,
    /// Drafts proposed in the most recent `draft()`; read by `accept`.
    last_proposed: usize,
    /// Set once the first `accept` lands. The first generation step
    /// processes the prompt prefill (a large `n_pending` pass); drafting
    /// there would fuse prefill with multi-position speculative samplers
    /// — a shape the SDK warns can drift off the greedy trajectory on
    /// some backends (`inferlets/draft-model-decoding` notes). Suppressing
    /// the prefill-step draft keeps step 1 a plain prefill+1 pass; drafts
    /// engage from the first pure decode step onward.
    prefilled: bool,
    metrics: Arc<Mutex<SpecMetrics>>,
}

impl CachebackDrafter {
    pub fn new(cfg: SpecConfig, start_cursor: u32) -> Self {
        let cache = NgramCache::new(cfg.leader_len, cfg.leader_cap, cfg.follower_cap);
        Self::with_cache(cfg, start_cursor, Arc::new(Mutex::new(cache)))
    }

    pub fn with_cache(cfg: SpecConfig, start_cursor: u32, cache: Arc<Mutex<NgramCache>>) -> Self {
        Self {
            cache,
            cfg,
            recent: Vec::new(),
            cursor: start_cursor,
            start_cursor,
            last_proposed: 0,
            prefilled: false,
            metrics: Arc::new(Mutex::new(SpecMetrics::default())),
        }
    }

    /// Clone the shared metrics handle. Call before moving the drafter
    /// into `Generator::speculator` so the loop can read final counts.
    pub fn metrics_handle(&self) -> Arc<Mutex<SpecMetrics>> {
        Arc::clone(&self.metrics)
    }

    /// Snapshot of current metrics. Test-only; production reads through
    /// the shared [`Self::metrics_handle`] after generation completes.
    #[cfg(test)]
    pub fn metrics(&self) -> SpecMetrics {
        self.metrics.lock().unwrap().clone()
    }

    #[cfg(test)]
    pub fn cursor(&self) -> u32 {
        self.cursor
    }

    #[cfg(test)]
    pub fn cache_len(&self) -> usize {
        self.cache.lock().unwrap().len()
    }

    /// Seed the dynamic table from prompt tokens. Does NOT advance the
    /// cursor — the prompt tokens are still buffered (un-flushed) and are
    /// accounted for by initializing the cursor to `seq_len + buffer.len()`
    /// in `start()`.
    pub fn seed(&mut self, tokens: &[u32]) {
        for &t in tokens {
            self.ingest(t);
        }
    }

    /// Record one committed token into the cache and roll the leader
    /// window forward.
    fn ingest(&mut self, t: u32) {
        if self.recent.len() == self.cfg.leader_len {
            self.cache.lock().unwrap().record(&self.recent, t);
        }
        self.recent.push(t);
        while self.recent.len() > self.cfg.leader_len {
            self.recent.remove(0);
        }
    }
}

impl inferlet::Speculator for CachebackDrafter {
    fn draft(&mut self) -> (Vec<u32>, Vec<u32>) {
        if !self.prefilled || self.recent.len() < self.cfg.leader_len {
            self.last_proposed = 0;
            return (Vec::new(), Vec::new());
        }
        let mut drafts = Vec::with_capacity(self.cfg.draft_len);
        let mut leader = self.recent.clone();
        let mut hits = 0usize;
        let mut misses = 0usize;
        for _ in 0..self.cfg.draft_len {
            match self.cache.lock().unwrap().get(&leader) {
                Some(f) => {
                    hits += 1;
                    drafts.push(f);
                    leader.remove(0);
                    leader.push(f);
                }
                None => {
                    misses += 1;
                    break;
                }
            }
        }
        {
            let mut m = self.metrics.lock().unwrap();
            m.cache_hits += hits;
            m.cache_misses += misses;
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
            // Bucket this step by its accepted-prefix length (= hits).
            if m.accepted_prefix_hist.len() <= hits {
                m.accepted_prefix_hist.resize(hits + 1, 0);
            }
            m.accepted_prefix_hist[hits] += 1;
        }
        self.last_proposed = 0;
        for &t in accepted {
            self.ingest(t);
        }
        self.cursor += accepted.len() as u32;
        // Record cache growth after this step's tokens are ingested; the
        // final accept leaves the end-of-turn cache size.
        self.metrics.lock().unwrap().cache_size = self.cache.lock().unwrap().len();
        // The prefill step's output has now been committed; drafts may
        // engage from the next (pure decode) step.
        self.prefilled = true;
    }

    fn rollback(&mut self, _n: u32) {
        // No-op: the cache grows only from accepted tokens (never from
        // proposed drafts), and the SDK truncates rejected-draft KV
        // itself. The cursor was advanced by `accepted.len()` only, so
        // nothing here needs undoing.
    }

    fn reset(&mut self) {
        *self.cache.lock().unwrap() = NgramCache::new(
            self.cfg.leader_len,
            self.cfg.leader_cap,
            self.cfg.follower_cap,
        );
        self.recent.clear();
        self.cursor = self.start_cursor;
        self.last_proposed = 0;
        self.prefilled = false;
        *self.metrics.lock().unwrap() = SpecMetrics::default();
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use inferlet::Speculator;
    use std::time::Duration;

    fn cfg() -> SpecConfig {
        SpecConfig {
            leader_len: 1,
            draft_len: 3,
            ..SpecConfig::default()
        }
    }

    /// Simulate one Generator step against a deterministic model:
    /// `draft()` -> verify each draft against the model's own sample ->
    /// `accept(accepted)` -> `rollback(rejected)`. Mirrors the SDK's
    /// acceptance walk in `generation.rs::GenStep::execute`.
    fn step(
        d: &mut CachebackDrafter,
        model: &dyn Fn(&[u32]) -> u32,
        ctx: &mut Vec<u32>,
    ) -> Vec<u32> {
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
        d.prefilled = true; // bypass the prefill-step gate for unit test
        let (drafts, positions) = d.draft();
        assert_eq!(drafts, vec![1, 2, 3]);
        // cursor seeded at 0, seed does not advance it.
        assert_eq!(positions, vec![0, 1, 2]);
    }

    #[test]
    fn does_not_draft_on_prefill_step() {
        let mut d = CachebackDrafter::new(cfg(), 0);
        d.seed(&[1, 2, 3, 1, 2, 3]); // cache + recent warm
        // Before any accept (the prefill step), drafting is suppressed.
        assert_eq!(d.draft(), (Vec::new(), Vec::new()));
        // First accept = prefill step output committed.
        d.accept(&[3]);
        let (drafts, _) = d.draft();
        assert!(!drafts.is_empty());
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
        // Drafter-logic equivalence: under a DETERMINISTIC model oracle
        // (no FP, same sample at every position), a spec-driven decode and
        // a plain (1 token/step) decode over the same seed must produce
        // the identical token stream. This pins the drafter's accept/
        // reanchor logic — NOT the engine's mm-vs-mv near-tie behavior,
        // which is the short-window/long-drift axis tracked in #592.
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

    #[test]
    fn step_partial_reject_reanchors_cursor() {
        // F2: integrated reject path. The cache drafts a chain; the model
        // follows the free pick then DIVERGES from the cached follower
        // mid-chain, so the verify breaks partway. Exercises
        // draft() -> partial accept -> cursor advance -> re-anchor
        // end-to-end (previously only the all-accept path had coverage).
        let mut d = CachebackDrafter::new(cfg(), 0);
        // Corpus warms 7->1, 1->2, 2->3 and leaves recent=[7], so a draft
        // from [7] chains to [1, 2, 3].
        d.seed(&[7, 1, 2, 3, 7]);
        d.prefilled = true; // skip the prefill-step gate for this unit test

        let (drafts, positions) = d.draft();
        assert_eq!(drafts, vec![1, 2, 3]);
        assert_eq!(positions, vec![0, 1, 2]);

        // Ground-truth model: after 7 emit 1 (== draft[0] -> the
        // free-pick position matches, so draft[0]'s successor is kept);
        // after 1 emit 7 (!= cached draft[1]=2 -> reject from here on).
        let model = |c: &[u32]| -> u32 {
            match c.last() {
                Some(7) => 1,
                Some(1) => 7,
                _ => 0,
            }
        };
        let mut ctx = vec![7u32, 1, 2, 3, 7];
        let accepted = step(&mut d, &model, &mut ctx);
        assert_eq!(accepted, vec![1, 7]); // free pick + 1 accepted draft

        let m = d.metrics();
        assert!(m.rejected > 0, "{m:?}");
        assert_eq!(m.proposed, m.accepted + m.rejected); // invariant
        assert_eq!((m.proposed, m.accepted, m.rejected), (3, 1, 2));

        // (b) cursor advanced by accepted.len()=2, NOT proposed(3).
        assert_eq!(d.cursor(), 2);

        // (c) the immediately-following draft re-anchors at the
        // post-accept cursor.
        let (next_drafts, next_positions) = d.draft();
        assert!(!next_drafts.is_empty());
        assert_eq!(next_positions[0], d.cursor());
        assert_eq!(next_positions[0], 2);
    }

    #[test]
    fn draft_counts_cache_hits_on_warm_chain() {
        let mut d = CachebackDrafter::new(cfg(), 0);
        // Repeating a,b,c warms 3->1, 1->2, 2->3; recent=[3].
        d.seed(&[1, 2, 3, 1, 2, 3]);
        d.prefilled = true; // bypass the prefill-step gate for the unit test
        let (drafts, _) = d.draft();
        assert_eq!(drafts, vec![1, 2, 3]);
        let m = d.metrics();
        // Full draft_len chain: 3 hits, no terminal miss.
        assert_eq!(m.cache_hits, 3);
        assert_eq!(m.cache_misses, 0);
    }

    #[test]
    fn draft_counts_cache_miss_on_cold_leader() {
        let mut d = CachebackDrafter::new(cfg(), 0);
        // Records only [1]->2, leaving recent=[2] with no entry for [2].
        d.seed(&[1, 2]);
        d.prefilled = true;
        let (drafts, _) = d.draft();
        assert!(drafts.is_empty());
        let m = d.metrics();
        assert_eq!(m.cache_hits, 0);
        assert_eq!(m.cache_misses, 1); // cold leader: one empty lookup
    }

    #[test]
    fn accept_records_prefix_length_histogram() {
        let mut d = CachebackDrafter::new(cfg(), 0);
        d.last_proposed = 3;
        d.accept(&[100, 200, 201]); // free + 2 accepted drafts -> bucket 2
        assert_eq!(d.metrics().accepted_prefix_hist, vec![0, 0, 1]);
        d.last_proposed = 0;
        d.accept(&[5]); // free pick only -> bucket 0
        assert_eq!(d.metrics().accepted_prefix_hist, vec![1, 0, 1]);
    }

    #[test]
    fn accept_tracks_cache_size_growth() {
        let mut d = CachebackDrafter::new(cfg(), 0);
        d.seed(&[1, 2, 3]); // cache {[1]:2, [2]:3}
        d.last_proposed = 0;
        d.accept(&[3, 4]); // ingest grows the table with [3]:{3,4}
        assert_eq!(d.metrics().cache_size, d.cache_len());
        assert_eq!(d.metrics().cache_size, 3);
    }

    #[test]
    fn accept_overshoot_does_not_underflow() {
        // F2: all-accept extra-pick clamp. When the accepted slice is
        // longer than last_proposed + 1 (the post-draft free pick can
        // ride along), `hits` is clamped to last_proposed so
        // `rejected = last_proposed - hits` never underflows.
        let mut d = CachebackDrafter::new(cfg(), 0);
        d.last_proposed = 3;
        d.accept(&[10, 11, 12, 13, 14]); // len 5 = last_proposed + 2
        let m = d.metrics();
        assert_eq!(m.proposed, 3);
        assert_eq!(m.accepted, 3); // clamped: min(len - 1 = 4, 3)
        assert_eq!(m.rejected, 0); // 3 - 3, no underflow panic
        assert_eq!(m.proposed, m.accepted + m.rejected);
    }

    #[test]
    fn sidecar_reuses_same_thread_when_prior_lineage_is_prefix() {
        let mut store = sidecar::SidecarStore::new(Duration::from_millis(1_000));
        let key = sidecar::SidecarKey::new("chat-a", "model-a", Some("fast-think"), 0x10, 1, 3);
        let first_lineage = sidecar::Lineage::from_turns(&[("system", "sys"), ("user", "u1")]);
        let first = store.checkout(0, key.clone(), first_lineage.clone());
        assert_eq!(first.status, sidecar::SidecarStatus::Fresh);
        first.cache.lock().unwrap().record(&[7], 8);

        let continued = sidecar::Lineage::from_turns(&[
            ("system", "sys"),
            ("user", "u1"),
            ("assistant", "a1"),
            ("user", "u2"),
        ]);
        let second = store.checkout(10, key, continued);

        assert_eq!(second.status, sidecar::SidecarStatus::Reused);
        assert_eq!(second.cache.lock().unwrap().get(&[7]), Some(8));
        assert_eq!(second.expired, 0);
    }

    #[test]
    fn sidecar_does_not_leak_across_threads() {
        let mut store = sidecar::SidecarStore::new(Duration::from_millis(1_000));
        let lineage = sidecar::Lineage::from_turns(&[("user", "same prompt")]);
        let a = sidecar::SidecarKey::new("chat-a", "model-a", None, 0, 1, 3);
        let b = sidecar::SidecarKey::new("chat-b", "model-a", None, 0, 1, 3);
        store
            .checkout(0, a, lineage.clone())
            .cache
            .lock()
            .unwrap()
            .record(&[1], 2);

        let checkout = store.checkout(10, b, lineage);

        assert_eq!(checkout.status, sidecar::SidecarStatus::Fresh);
        assert_eq!(checkout.cache.lock().unwrap().get(&[1]), None);
    }

    #[test]
    fn sidecar_invalidates_on_model_profile_or_prefix_fork() {
        let mut store = sidecar::SidecarStore::new(Duration::from_millis(1_000));
        let base = sidecar::Lineage::from_turns(&[("system", "sys"), ("user", "u1")]);
        let key = sidecar::SidecarKey::new("chat-a", "model-a", Some("fast-think"), 0, 1, 3);
        store
            .checkout(0, key.clone(), base.clone())
            .cache
            .lock()
            .unwrap()
            .record(&[1], 2);

        let model_changed =
            sidecar::SidecarKey::new("chat-a", "model-b", Some("fast-think"), 0, 1, 3);
        assert_eq!(
            store.checkout(10, model_changed, base.clone()).status,
            sidecar::SidecarStatus::Fresh
        );

        let profile_changed =
            sidecar::SidecarKey::new("chat-a", "model-a", Some("balanced"), 0, 1, 3);
        assert_eq!(
            store.checkout(20, profile_changed, base.clone()).status,
            sidecar::SidecarStatus::Fresh
        );

        let forked = sidecar::Lineage::from_turns(&[
            ("system", "different sys"),
            ("user", "u1"),
            ("assistant", "a1"),
        ]);
        assert_eq!(
            store.checkout(30, key, forked).status,
            sidecar::SidecarStatus::Fresh
        );
    }

    #[test]
    fn sidecar_prunes_expired_entries_deterministically() {
        let mut store = sidecar::SidecarStore::new(Duration::from_millis(50));
        let key = sidecar::SidecarKey::new("chat-a", "model-a", None, 0, 1, 3);
        let lineage = sidecar::Lineage::from_turns(&[("user", "u1")]);
        store
            .checkout(0, key.clone(), lineage.clone())
            .cache
            .lock()
            .unwrap()
            .record(&[1], 2);

        let checkout = store.checkout(51, key, lineage);

        assert_eq!(checkout.status, sidecar::SidecarStatus::Fresh);
        assert_eq!(checkout.expired, 1);
        assert_eq!(checkout.cache.lock().unwrap().get(&[1]), None);
    }

    #[test]
    fn shared_sidecar_preserves_learned_followers_across_drafters() {
        let shared = Arc::new(Mutex::new(NgramCache::new(1, 16, 8)));
        let model = |c: &[u32]| -> u32 {
            match c.last() {
                Some(7) => 1,
                Some(1) => 2,
                Some(2) => 3,
                Some(3) => 1,
                _ => 7,
            }
        };

        let mut warm = CachebackDrafter::with_cache(cfg(), 0, Arc::clone(&shared));
        warm.seed(&[7]);
        let mut warm_ctx = vec![7];
        while warm_ctx.len() < 6 {
            let _ = step(&mut warm, &model, &mut warm_ctx);
        }

        let mut reused = CachebackDrafter::with_cache(cfg(), 0, Arc::clone(&shared));
        reused.seed(&[7]);
        reused.accept(&[1]); // first pure decode step can now draft from leader [1]
        let (reused_drafts, _) = reused.draft();

        let mut fresh = CachebackDrafter::new(cfg(), 0);
        fresh.seed(&[7]);
        fresh.accept(&[1]);
        let (fresh_drafts, _) = fresh.draft();

        assert_eq!(reused_drafts, vec![2, 3, 1]);
        assert!(
            fresh_drafts.is_empty(),
            "fresh per-request cache should still be cold"
        );
    }
}
