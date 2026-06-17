//! Best-of-N candidate divergence (#690) — owned by this module, independent
//! of tree-of-thought.
//!
//! Best-of-N and ToT diverge their N sibling candidates for DIFFERENT reasons,
//! so they must not share a directive set. ToT steers each sibling toward a
//! distinct *increment* a value scorer then rates and prunes against a beam
//! (`tot::search::branch_directive`, the #523/#555 focus rotation +
//! path-advancement framing). Best-of-N instead produces N *complete,
//! standalone replies* the USER chooses among — there is no scorer, no beam,
//! no pruning — so its divergence steers each sibling toward a different
//! ANSWER STANCE (direct / thorough / alternative angle / caveats / reframed),
//! not a different search step. This module is that stance set; it imports
//! nothing from `tot::diversity` or the ToT directive helpers.
//!
//! ## Two independent divergence axes
//!
//! 1. **Directive (this module):** each sibling gets a textually distinct
//!    stance prefix, so even a greedy decode would not collapse all N to the
//!    same continuation, and the first forward pass carries real new tokens.
//! 2. **Per-fork sampling seed (engine-level):** the candidates are separate
//!    forked contexts sampled with `Sampler::TopP { temperature > 0 }`, which
//!    carries NO seed — so the engine assigns each fork an independent PCG32
//!    stream (`default_rng_seed()` is a process-global atomic counter, xored
//!    with the per-fork slot; verified #683). Best-of-N inherits that for free;
//!    the only precondition it owns is that sampling stay stochastic
//!    (`temperature > 0`), which [`requires_stochastic_sampling`] guards. A
//!    greedy (`temperature == 0`) round would make the seed axis inert and the
//!    candidates would diverge by directive alone.

/// The per-sibling answer stances. `n` is capped at
/// [`super::schema::MAX_N`] (5), so the five stances cover every sibling
/// without repeating; `branch_index % len` keeps it total for any `n`.
const STANCES: [&str; 5] = [
    "Give the most direct, concise answer — lead with the bottom line.",
    "Give a more thorough, well-explained answer that walks through the reasoning.",
    "Take a different angle or approach than the obvious one; surface an option a quick answer would miss.",
    "Emphasize the caveats, edge cases, and conditions under which the answer changes.",
    "Reframe the problem and answer from a fresh perspective the literal reading overlooks.",
];

/// Build the per-branch directive for Best-of-N candidate `branch_index`.
/// Distinct per sibling (the divergence axis this module owns) and
/// user-facing — it asks for a complete reply in a particular stance, never
/// mentioning the option machinery, so a small model cannot copy search
/// scaffolding into the answer. `/no_think` is appended when `thinking` is off
/// (#679 default), keyed off Best-of-N's own knob — not ToT's `with_thinking`.
pub(crate) fn candidate_directive(branch_index: usize, thinking: bool) -> String {
    let stance = STANCES[branch_index % STANCES.len()];
    let body = format!(
        "Reply to the user now with a complete, correct, standalone answer. {stance} \
         Answer every part of the request. Do not mention that this is one of several options or \
         refer to the other answers. Write only the reply; do not start with a heading."
    );
    with_no_think(&body, thinking)
}

/// Append `/no_think` when this round runs with thinking off (#679 default).
/// Best-of-N's own knob — deliberately not ToT's `with_thinking`, so the two
/// modules' thinking policies stay independent.
fn with_no_think(base: &str, thinking: bool) -> String {
    if thinking {
        base.to_string()
    } else {
        format!("{base} /no_think")
    }
}

/// The bounded no-think starvation-retry directive for candidate
/// `branch_index` (used only if a future caller enables thinking and a sibling
/// reasons past its budget without answering; the default thinking-off round
/// never reaches it). Answer-first, same stance, always `/no_think`.
pub(crate) fn candidate_retry_directive(branch_index: usize) -> String {
    format!(
        "Answer the user now. Keep it concise. Write only the answer.\n\n{}",
        candidate_directive(branch_index, false)
    )
}

/// Whether the candidate-generation sampling is stochastic enough for the
/// per-fork seed axis to actually diverge the candidates. At `temperature ==
/// 0` every fork decodes the same argmax regardless of its independent seed,
/// so divergence would rest on the directive alone. Best-of-N's default
/// temperature is well above 0; this is the guard that keeps a caller from
/// silently collapsing the seed axis.
pub(crate) fn requires_stochastic_sampling(temperature: f32) -> bool {
    temperature > 0.0
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::bestofn::schema::{DEFAULT_N, MAX_N};

    /// The directive divergence axis: every sibling in a full round gets a
    /// textually distinct directive, so candidates do not collapse even before
    /// the per-fork seed axis is applied.
    #[test]
    fn directives_are_distinct_across_siblings() {
        let n = MAX_N;
        let directives: Vec<String> = (0..n).map(|b| candidate_directive(b, false)).collect();
        for i in 0..n {
            for j in (i + 1)..n {
                assert_ne!(
                    directives[i], directives[j],
                    "siblings {i} and {j} must get distinct directives"
                );
            }
        }
    }

    /// The default round (N=5) assigns each sibling a unique stance — the
    /// stance set is sized to the cap so none repeat.
    #[test]
    fn default_round_uses_all_distinct_stances() {
        let stances_used: std::collections::HashSet<&str> =
            (0..DEFAULT_N).map(|b| STANCES[b % STANCES.len()]).collect();
        assert_eq!(stances_used.len(), DEFAULT_N, "every default sibling is a distinct stance");
    }

    /// Best-of-N owns its thinking knob: `/no_think` is appended when thinking
    /// is off and absent when on, independent of ToT's `with_thinking`.
    #[test]
    fn thinking_knob_is_honored() {
        assert!(candidate_directive(0, false).contains("/no_think"));
        assert!(candidate_directive(3, false).contains("/no_think"));
        assert!(!candidate_directive(0, true).contains("/no_think"));
        assert!(!candidate_directive(3, true).contains("/no_think"));
        // The retry directive is always no-think (it is the starvation escape).
        assert!(candidate_retry_directive(0).contains("/no_think"));
    }

    /// Decoupling guard: none of Best-of-N's directives carry the
    /// tree-of-thought focus-rotation strings (`tot::search::branch_directive`)
    /// — if a refactor ever re-coupled the two paths, these would leak in.
    #[test]
    fn no_tot_focus_strings_leak_into_bestofn_directives() {
        let tot_focus_markers = [
            "Prefer names, totals, or the main tactic.",
            "Prefer a second useful detail.",
            "Prefer a quick check of numbers or names.",
            "Prefer a concrete practical detail.",
            "Option 1 of",
            "Author, Total, or Tactic",
        ];
        for b in 0..MAX_N {
            let d = candidate_directive(b, false);
            let r = candidate_retry_directive(b);
            for marker in tot_focus_markers {
                assert!(!d.contains(marker), "bestofn directive leaked ToT marker {marker:?}");
                assert!(!r.contains(marker), "bestofn retry leaked ToT marker {marker:?}");
            }
        }
    }

    /// The seed axis precondition Best-of-N owns: stochastic sampling. The
    /// default temperature keeps the per-fork PCG32 independence (#683) live;
    /// a greedy round would make it inert.
    #[test]
    fn stochastic_sampling_guard_tracks_temperature() {
        assert!(requires_stochastic_sampling(super::super::schema::resolve(
            &super::super::schema::BestOfNInput::default()
        ).unwrap().temperature),
            "the default round must sample stochastically so per-fork seeds diverge candidates");
        assert!(requires_stochastic_sampling(0.7));
        assert!(!requires_stochastic_sampling(0.0));
    }
}
