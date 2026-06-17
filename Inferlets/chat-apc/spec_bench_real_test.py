"""Unit tests for spec_bench_real's pure formatting helpers (#591).

Guards the n-gram cache-effectiveness printer's MISSING-vs-'--' contract:
an absent wire field (a dropped/renamed key — a regression to investigate)
must render distinctly from a present-but-empty value (a genuinely cold or
zero-lookup turn). Run::

    uv run --project Vendor/pie/client/python --with httpx \
      python -m unittest Inferlets/chat-apc/spec_bench_real_test.py
"""
from __future__ import annotations

import unittest

import spec_bench_real as b


class CacheCellFormatting(unittest.TestCase):
    def test_absent_key_renders_missing_not_dash(self):
        # speculation dict with every cache_* key omitted — e.g. an engine
        # that dropped/renamed the wire fields.
        spc = {"proposed_draft_tokens": 0, "accepted_draft_tokens": 0}
        for key in (
            "cache_hits",
            "cache_misses",
            "cache_hit_rate",
            "cache_size",
            "accepted_prefix_len_histogram",
        ):
            cell = b._cache_cell(spc, key)
            self.assertEqual(cell, "MISSING", f"{key} absent -> {cell!r}")
            self.assertNotEqual(cell, "--")

    def test_present_but_empty_or_none_renders_dash(self):
        spc = {
            "cache_hits": None,
            "cache_misses": None,
            "cache_hit_rate": None,
            "cache_size": None,
            "accepted_prefix_len_histogram": [],
        }
        for key in spc:
            self.assertEqual(b._cache_cell(spc, key), "--", key)

    def test_present_values_render(self):
        spc = {
            "cache_hits": 0,  # a real zero, not missing
            "cache_misses": 15,
            "cache_hit_rate": 0.0,
            "cache_size": 18,
            "accepted_prefix_len_histogram": [16, 2, 1],
        }
        self.assertEqual(b._cache_cell(spc, "cache_hits"), "0")
        self.assertEqual(b._cache_cell(spc, "cache_misses"), "15")
        self.assertEqual(b._cache_cell(spc, "cache_hit_rate"), "0.00")
        self.assertEqual(b._cache_cell(spc, "cache_size"), "18")
        self.assertEqual(
            b._cache_cell(spc, "accepted_prefix_len_histogram"), "16,2,1"
        )


class CrossRequestReuseGuard(unittest.TestCase):
    """#596 F4: the ordering-neutrality guard must flag a fast_think run that
    inherited drafting state from a prior request (would warm fast_think),
    and stay silent for the expected cold-decode statuses."""

    def _rec(self, status):
        sm = {"proposed_draft_tokens": 0, "accepted_draft_tokens": 0}
        if status is not None:
            sm["ngram_sidecar_status"] = status
        return {"spec_metrics": sm}

    def test_reused_status_is_violation(self):
        for bad in ("reused", "lineage_forked"):
            err = b._cross_request_reuse("primes", "fast_think", self._rec(bad))
            self.assertIsNotNone(err, bad)
            self.assertIn(bad, err)

    def test_cold_statuses_are_clean(self):
        # absent field (no thread_id -> sidecar disabled) and an explicit
        # `fresh` both mean no cross-request state carried over.
        for ok in (None, "fresh"):
            self.assertIsNone(
                b._cross_request_reuse("primes", "fast_think", self._rec(ok)), ok
            )

    def test_missing_spec_metrics_is_clean(self):
        # a missing spec_metrics frame is a separate contract failure caught
        # by _check_run; the reuse guard must not also trip on it.
        self.assertIsNone(b._cross_request_reuse("primes", "baseline", {}))


def _healthy_rec() -> dict:
    """A run that passes every _check_run check: 200, no error frame, all
    required spec keys, a non-empty decode, consistent accounting (4 == 2 + 2),
    no cross-request reuse."""
    return {
        "status": 200,
        "content": "ok",
        "reasoning": "",
        "error_frame": None,
        "spec_metrics": {
            "generated_tokens": 10,
            "proposed_draft_tokens": 4,
            "accepted_draft_tokens": 2,
            "rejected_draft_tokens": 2,
        },
    }


class CheckRunFailClosed(unittest.TestCase):
    """#664 F2: an accounting-inconsistent or reuse-contaminated run rides a 200
    with present spec_metrics, but its totals are unusable. Since the verdict is
    load-bearing for the matrix cell() aggregates, _check_run must return False
    (fail closed), not append-and-fall-through to True."""

    def test_healthy_run_is_usable(self):
        # positive control: the well-formed run still passes.
        failures: list[str] = []
        self.assertTrue(b._check_run("ngram", "s", _healthy_rec(), failures))
        self.assertEqual(failures, [])

    def test_inconsistent_accounting_run_is_unusable(self):
        # proposed=4 but accepted+rejected=4+2=6 — alpha would be poisoned.
        rec = _healthy_rec()
        rec["spec_metrics"]["accepted_draft_tokens"] = 4
        rec["spec_metrics"]["rejected_draft_tokens"] = 2
        failures: list[str] = []
        self.assertFalse(b._check_run("ngram", "s", rec, failures))
        self.assertTrue(
            any("accounting inconsistent" in f for f in failures), failures
        )

    def test_cross_request_reuse_run_is_unusable(self):
        # a reused n-gram cache breaks ordering neutrality — exclude it too.
        rec = _healthy_rec()
        rec["spec_metrics"]["ngram_sidecar_status"] = "reused"
        failures: list[str] = []
        self.assertFalse(b._check_run("ngram", "s", rec, failures))
        self.assertTrue(any("reuse detected" in f for f in failures), failures)


if __name__ == "__main__":
    unittest.main()
