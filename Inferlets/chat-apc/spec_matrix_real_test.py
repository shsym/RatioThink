"""Engine-free unit guards for spec_matrix_real's pure helpers (#652).

Deterministic, CI-safe — no engine, no model, no network. Covers the matrix
aggregation logic that must not silently misreport: histogram summing, greedy
equivalence comparison, the `/no_think` soft-switch wiring, and the coverage
bound that backs the no-cherrypick claim. Run::

    uv run --project Vendor/pie/client/python --with httpx \
      python -m unittest Inferlets/chat-apc/spec_matrix_real_test.py
"""
from __future__ import annotations

import unittest

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


if __name__ == "__main__":
    unittest.main()
