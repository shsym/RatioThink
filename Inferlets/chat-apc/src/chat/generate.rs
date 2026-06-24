//! Decode-strategy seam for the chat data plane.
//!
//! Isolates the one axis that differs between decode modes — how the
//! [`Generator`] is constructed — behind [`DecodeStrategy`], so the SSE
//! and JSON transport loops in [`super::completions`] stay generic over
//! plain vs speculative decode. Tree-of-thought is a sibling mode that
//! ships as an advanced-profile dispatch arm behind `/v1/chat/completions`
//! (and the retained internal `/v1/inferlet` raw path)
//! ([`super::dispatch`] → [`crate::tot`]) rather than a `DecodeStrategy`,
//! so it bypasses these transport loops entirely.
//!
//! - [`DecodeStrategy::Plain`] — the default token-by-token decode.
//! - [`DecodeStrategy::Speculative`] — attaches a [`CachebackDrafter`]
//!   (linear LRU n-gram speculation) seeded from the prompt. Greedy-only:
//!   the caller gates this to `temperature == 0` so output stays a valid
//!   greedy continuation. Identity with plain decode is a SHORT-WINDOW
//!   guarantee only: the batched verify forward rounds differently from
//!   single-token decode and can flip a near-tie argmax, so the spec
//!   trajectory drifts off plain past a short window on the portable
//!   Metal backend (#592, see `super::spec`).

use std::sync::{Arc, Mutex};

use inferlet::Context;
use inferlet::Generator;
use inferlet::sample::Sampler;

use super::spec::cache::NgramCache;
use super::spec::{CachebackDrafter, SpecConfig, SpecMetrics};

/// Map request sampling params to an SDK sampler. `temperature == 0`
/// resolves to the explicit greedy [`Sampler::Argmax`]; the host encodes
/// `temperature == 0` as argmax anyway, and speculation requires this
/// greedy path.
pub fn resolve_sampler(temperature: f32, top_p: f32) -> Sampler {
    if temperature <= 0.0 {
        Sampler::Argmax
    } else {
        Sampler::TopP {
            temperature,
            p: top_p,
        }
    }
}

/// Which decode mode to run.
pub enum DecodeStrategy {
    Plain,
    Speculative(SpecConfig),
}

/// A constructed generator plus, for speculative mode, the shared metrics
/// handle the transport loop reads after generation completes.
pub struct GenSession<'c> {
    pub generator: Generator<'c>,
    pub metrics: Option<Arc<Mutex<SpecMetrics>>>,
}

/// Build the generator for `strategy`. For speculative mode, the drafter
/// is seeded from `seed_tokens` (a stand-alone tokenization of the prompt
/// — exact chat-template alignment isn't required; accepted tokens grow
/// the cache as generation proceeds) and its cursor anchored at
/// `seq_len + buffer.len()` so draft KV positions line up with the
/// pending anchor each step.
pub fn start<'c>(
    ctx: &'c mut Context,
    sampler: Sampler,
    max_tokens: usize,
    stop: &[u32],
    strategy: DecodeStrategy,
    seed_tokens: &[u32],
    sidecar_cache: Option<Arc<Mutex<NgramCache>>>,
) -> GenSession<'c> {
    match strategy {
        DecodeStrategy::Plain => GenSession {
            generator: ctx.generate(sampler).max_tokens(max_tokens).stop(stop),
            metrics: None,
        },
        DecodeStrategy::Speculative(cfg) => {
            let start_cursor = ctx.seq_len() + ctx.buffer().len() as u32;
            let mut drafter = match sidecar_cache {
                Some(cache) => CachebackDrafter::with_cache(cfg, start_cursor, cache),
                None => CachebackDrafter::new(cfg, start_cursor),
            };
            drafter.seed(seed_tokens);
            let metrics = Some(drafter.metrics_handle());
            let generator = ctx
                .generate(sampler)
                .max_tokens(max_tokens)
                .stop(stop)
                .speculator(drafter);
            GenSession { generator, metrics }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn temp_zero_resolves_to_argmax() {
        assert!(matches!(resolve_sampler(0.0, 1.0), Sampler::Argmax));
    }

    #[test]
    fn negative_temp_resolves_to_argmax() {
        assert!(matches!(resolve_sampler(-1.0, 1.0), Sampler::Argmax));
    }

    #[test]
    fn positive_temp_resolves_to_topp() {
        assert!(matches!(resolve_sampler(0.7, 0.9), Sampler::TopP { .. }));
    }
}
