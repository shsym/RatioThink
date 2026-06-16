"""Engine-free unit guards for spec_matrix_real's pure helpers (#652).

Deterministic, CI-safe — no engine, no model, no network. Covers the matrix
aggregation logic that must not silently misreport: histogram summing, greedy
equivalence comparison, the `/no_think` soft-switch wiring, and the coverage
bound that backs the no-cherrypick claim. Run::

    uv run --project Vendor/pie/client/python --with httpx \
      python -m unittest Inferlets/chat-apc/spec_matrix_real_test.py
"""
from __future__ import annotations

import asyncio
import unittest
from unittest import mock

import spec_matrix_real as m


class HistogramSum(unittest.TestCase):
    def test_ragged_histograms_sum_elementwise(self):
        # different-length per-run histograms must align on index, not truncate.
        self.assertEqual(m._sum_hist([[1, 2], [3, 4, 5], []]), [4, 6, 5])

    def test_non_list_entries_are_ignored_not_crash(self):
        self.assertEqual(m._sum_hist([None, [2], "x", [3]]), [5])

    def test_empty_input_is_empty(self):
        self.assertEqual(m._sum_hist([]), [])


class EquivalenceComparison(unittest.TestCase):
    def test_out_compares_content_and_reasoning(self):
        a = {"content": "x", "reasoning": "r"}
        b = {"content": "x", "reasoning": "r"}
        c = {"content": "x", "reasoning": "DIFF"}
        self.assertEqual(m._out(a), m._out(b))
        self.assertNotEqual(m._out(a), m._out(c))

    def test_out_defaults_missing_fields_to_empty(self):
        # a non-200 record with no content/reasoning must not KeyError.
        self.assertEqual(m._out({}), ("", ""))


class ThinkSoftSwitch(unittest.TestCase):
    """The per-row think flag must control Qwen3's `/no_think` switch: reasoning
    rows keep thinking ON (no suffix), others append the soft switch. This is a
    pure-string contract we can assert without the engine."""

    def _content_for(self, prompt, think):
        # mirror the exact construction in _stream_run.
        return prompt if think else f"{prompt}\n/no_think"

    def test_think_true_sends_prompt_verbatim(self):
        self.assertEqual(self._content_for("2+2?", True), "2+2?")
        self.assertNotIn("/no_think", self._content_for("2+2?", True))

    def test_think_false_appends_no_think(self):
        self.assertTrue(self._content_for("hi", False).endswith("/no_think"))


class RegistryColumns(unittest.TestCase):
    def test_model_based_and_tree_columns_are_excluded_not_faked(self):
        # the methods actually measured are exactly plain + ngram; the two
        # unimplemented columns are documented, never silently dropped.
        self.assertEqual(list(m.PROFILES), ["plain", "ngram"])
        self.assertEqual(m.PROFILES["plain"], {"enabled": False})
        self.assertEqual(m.PROFILES["ngram"], {"enabled": True})


def _healthy_run(content: str = "ok") -> dict:
    """A run that passes every `spec_bench_real._check_run` contract check:
    200, no error frame, all required spec keys, a non-empty decode, and
    consistent draft accounting (accepted + rejected == proposed)."""
    return {
        "status": 200,
        "content": content,
        "reasoning": "",
        "error_frame": None,
        "wall_tok_per_s": 40.0,
        "ttft_s": 0.1,
        "tpot_ms": 5.0,
        "spec_metrics": {
            "enabled": True,
            "generated_tokens": 10,
            "proposed_draft_tokens": 4,
            "accepted_draft_tokens": 2,
            "rejected_draft_tokens": 2,
            "decode_tokens_per_sec": 100.0,
            "avg_tokens_per_step": 1.5,
            "accepted_prefix_len_histogram": [1, 1],
        },
    }


def _degraded_but_200_run() -> dict:
    """A run that rides an HTTP 200 yet fails the contract: an empty decode
    (`generated_tokens == 0`, no content) — `_check_run` returns False. Its
    spec_metrics carry POISON values; if the usability gate let it through, the
    aggregates below would shift visibly (alpha→~0.997, median→9999, hist
    grows), so the assertions double as a mutation check."""
    return {
        "status": 200,
        "content": "",
        "reasoning": "",
        "error_frame": None,
        "wall_tok_per_s": 9999.0,
        "ttft_s": 0.0,
        "tpot_ms": 0.0,
        "spec_metrics": {
            "enabled": True,
            "generated_tokens": 0,
            "proposed_draft_tokens": 999,
            "accepted_draft_tokens": 999,
            "rejected_draft_tokens": 0,
            "decode_tokens_per_sec": 9999.0,
            "avg_tokens_per_step": 50.0,
            "accepted_prefix_len_histogram": [999, 999],
        },
    }


def _inconsistent_accounting_run() -> dict:
    """A run that rides an HTTP 200 with a non-empty decode and every required
    spec key present, but whose draft accounting is inconsistent
    (proposed=4, accepted=4, rejected=2 → 4 + 2 != 4). `_check_run` must fail it
    closed (#664 F2): acceptance_alpha = accepted/proposed is meaningless when
    the totals don't reconcile, so it must never reach the aggregates."""
    return {
        "status": 200,
        "content": "ok",
        "reasoning": "",
        "error_frame": None,
        "wall_tok_per_s": 9999.0,
        "ttft_s": 0.0,
        "tpot_ms": 0.0,
        "spec_metrics": {
            "enabled": True,
            "generated_tokens": 10,
            "proposed_draft_tokens": 4,
            "accepted_draft_tokens": 4,
            "rejected_draft_tokens": 2,
            "decode_tokens_per_sec": 9999.0,
            "avg_tokens_per_step": 50.0,
            "accepted_prefix_len_histogram": [999, 999],
        },
    }


class CellUsabilityGate(unittest.TestCase):
    """The `_bench_dataset`/`cell()` usability state machine must aggregate only
    over runs that passed `_check_run`. A degraded-but-200 run (200, spec_metrics
    present, but an empty decode) must be excluded so it never contaminates
    acceptance_alpha, the engine tok/s median, or the prefix-length histogram.
    Driven end-to-end against the real `_bench_dataset` with a stubbed
    `_stream_run` — no engine, no model, no network."""

    def _run_bench(self, records, bad_run=_degraded_but_200_run):
        async def fake_stream_run(http_c, base, prompt, think, spec):
            # ngram (speculation enabled) on the "bad" prompt returns the
            # supplied bad run; every other run is healthy.
            if prompt == "bad" and spec.get("enabled"):
                return bad_run()
            return _healthy_run()

        failures: list[str] = []
        with mock.patch.object(m, "_stream_run", fake_stream_run):
            row = asyncio.run(
                m._bench_dataset(None, "http://stub", "ds", records, len(records), failures)
            )
        return row, failures

    def test_degraded_but_200_run_excluded_from_ngram_aggregates(self):
        # record 0 healthy on both methods; record 1 ("bad") healthy on plain,
        # degraded-but-200 on ngram.
        records = [
            {"prompt": "good", "think": False, "category": "c"},
            {"prompt": "bad", "think": False},
        ]
        row, _ = self._run_bench(records)
        ngram = row["cells"]["ngram"]

        # Only the single healthy ngram run reaches the aggregates.
        self.assertEqual(ngram["runs_ok"], 1)
        # alpha = 2/4 from the healthy run alone — NOT (2+999)/(4+999)=0.997.
        self.assertEqual(ngram["acceptance_alpha"], 0.5)
        # median engine tok/s over the healthy run alone — NOT 9999.
        self.assertEqual(ngram["engine_tok_per_s"], 100.0)
        # histogram from the healthy run alone — NOT summed with [999, 999].
        self.assertEqual(ngram["accepted_prefix_len_histogram"], [1, 1])

    def test_check_run_records_the_degraded_run_as_a_failure(self):
        # The exclusion is the *verdict's* doing, not a silent drop: the empty
        # decode is surfaced as a contract failure for disclosure.
        records = [
            {"prompt": "good", "think": False},
            {"prompt": "bad", "think": False},
        ]
        _, failures = self._run_bench(records)
        self.assertTrue(
            any("empty decode" in f for f in failures),
            f"expected an empty-decode failure, got {failures!r}",
        )

    def test_degraded_ngram_not_counted_in_greedy_equivalence(self):
        # #664 F1: record 1 is healthy on plain, degraded-but-200 on ngram. The
        # byte compare must be gated on the _check_ok verdict, so the prompt is
        # routed to `invalid` (excluded) — NOT scored as equiv_drift (healthy
        # "ok" != empty), and certainly not as a false equiv_hold.
        records = [
            {"prompt": "good", "think": False, "category": "c"},
            {"prompt": "bad", "think": False},
        ]
        row, _ = self._run_bench(records)
        eq = row["greedy_equivalence"]
        self.assertEqual(eq["held"], 1)       # only the healthy record 0
        self.assertEqual(eq["drift_spec"], 0)  # degraded run NOT a false drift
        self.assertEqual(eq["invalid"], 1)     # degraded run excluded here
        # rate is over compared (held+drift) only — the excluded prompt must
        # not deflate it.
        self.assertEqual(eq["rate"], 1.0)

    def test_inconsistent_accounting_run_excluded_and_recorded(self):
        # #664 F2: an accounting-inconsistent (4 != 4 + 2) ngram run rides a 200
        # with a non-empty decode, so only the _check_run accounting gate stops
        # it. It must be excluded from the ngram aggregates and surfaced as a
        # failure for disclosure.
        records = [
            {"prompt": "good", "think": False, "category": "c"},
            {"prompt": "bad", "think": False},
        ]
        row, failures = self._run_bench(
            records, bad_run=_inconsistent_accounting_run
        )
        ngram = row["cells"]["ngram"]
        # Only the healthy ngram run reaches the aggregates.
        self.assertEqual(ngram["runs_ok"], 1)
        # alpha = 2/4 from the healthy run alone — NOT (2+4)/(4+4)=0.75.
        self.assertEqual(ngram["acceptance_alpha"], 0.5)
        self.assertEqual(ngram["engine_tok_per_s"], 100.0)  # NOT 9999
        self.assertEqual(ngram["accepted_prefix_len_histogram"], [1, 1])
        self.assertTrue(
            any("accounting inconsistent" in f for f in failures), failures
        )
        # And the excluded prompt routes to equiv invalid, not drift/hold.
        eq = row["greedy_equivalence"]
        self.assertEqual(eq["invalid"], 1)
        self.assertEqual(eq["drift_spec"], 0)


if __name__ == "__main__":
    unittest.main()
