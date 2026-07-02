import contextlib
import io
import json
import sys
import tempfile
import unittest
from pathlib import Path
from unittest import mock

sys.path.insert(0, str(Path(__file__).resolve().parent))

import analyze_tree_dump as a  # noqa: E402


class _Verdict:
    passed = False


class AnalyzeTreeDumpTest(unittest.TestCase):
    def test_analyze_record_reports_correct_in_tree_and_answer_histogram(self):
        record = {
            "index": 16,
            "grader": "mcq_numeric",
            "reference": {"final_answer": "2", "choice_count": 4},
            "final_verdict": "fail",
            "selected": "wrong-a",
            "nodes": [
                {
                    "id": "wrong-a",
                    "depth": 2,
                    "parent_id": "p1",
                    "branch_index": 0,
                    "status": "ok",
                    "content": "Final answer: 3",
                    "score": 9,
                },
                {
                    "id": "right-b",
                    "depth": 2,
                    "parent_id": "p1",
                    "branch_index": 1,
                    "status": "ok",
                    "content": "Both statements are false, so answer 2.",
                    "score": 5,
                },
                {
                    "id": "thinking-only",
                    "depth": 1,
                    "parent_id": "root",
                    "branch_index": 1,
                    "status": "incomplete",
                    "content": "",
                    "score": None,
                },
            ],
        }

        summary = a.analyze_record(record)

        self.assertTrue(summary["correct_in_tree"])
        self.assertEqual(summary["n_correct_nodes"], 1)
        self.assertFalse(summary["selected_node_ok"])
        self.assertEqual(summary["loss_kind"], "selection_synthesis")
        self.assertEqual(summary["answer_histogram"], {"2": 1, "3": 1})
        self.assertEqual(summary["node_answer_grades"]["right-b"]["answer"], "2")

    def test_branch_variation_groups_siblings_by_parent_id(self):
        record = {
            "index": 1,
            "grader": "gsm8k_numeric",
            "reference": {"final_answer": "999"},
            "final_verdict": "fail",
            "selected": "a1",
            "nodes": [
                {"id": "p1", "depth": 1, "parent_id": "root", "content": "parent one", "score": 1},
                {"id": "p2", "depth": 1, "parent_id": "root", "content": "parent two", "score": 1},
                {"id": "a1", "depth": 2, "parent_id": "p1", "content": "dup", "score": 1},
                {"id": "a2", "depth": 2, "parent_id": "p1", "content": "dup", "score": 1},
                {"id": "b1", "depth": 2, "parent_id": "p2", "content": "left", "score": 1},
                {"id": "b2", "depth": 2, "parent_id": "p2", "content": "right", "score": 1},
            ],
        }
        with tempfile.TemporaryDirectory() as td:
            path = Path(td) / "dump.jsonl"
            path.write_text(json.dumps(record) + "\n")
            out = io.StringIO()
            with mock.patch.object(a.g, "grade", return_value=_Verdict()), \
                    contextlib.redirect_stdout(out):
                a.analyze(str(path))
        self.assertIn("0.83 over 3 sibling-groups", out.getvalue())

    def test_err_and_ungradable_are_excluded_from_failure_decomposition(self):
        records = [
            {
                "index": 1,
                "grader": "gsm8k_numeric",
                "reference": {"final_answer": "1"},
                "final_verdict": "ERR",
                "selected": "e1",
                "nodes": [{"id": "e1", "depth": 1, "content": "infra broke", "score": 1}],
            },
            {
                "index": 2,
                "grader": "gsm8k_numeric",
                "reference": {"final_answer": "2"},
                "final_verdict": "ungradable",
                "selected": "u1",
                "nodes": [{"id": "u1", "depth": 1, "content": "no final number", "score": 1}],
            },
            {
                "index": 3,
                "grader": "gsm8k_numeric",
                "reference": {"final_answer": "3"},
                "final_verdict": "fail",
                "selected": "f1",
                "nodes": [{"id": "f1", "depth": 1, "content": "wrong 4", "score": 1}],
            },
        ]
        with tempfile.TemporaryDirectory() as td:
            path = Path(td) / "dump.jsonl"
            path.write_text("".join(json.dumps(r) + "\n" for r in records))
            out = io.StringIO()
            with mock.patch.object(a.g, "grade", return_value=_Verdict()), \
                    contextlib.redirect_stdout(out):
                a.analyze(str(path))

        text = out.getvalue()
        self.assertIn("final PASS: 0 | final FAIL: 1 | ERR: 1 | ungradable: 1", text)
        self.assertIn("GENERATION loss (no correct node anywhere):                  1/1", text)
        self.assertIn("1: ERR", text)
        self.assertNotIn("1: FAIL", text)
        self.assertIn("2: ungradable", text)
        self.assertIn("3: FAIL", text)


if __name__ == "__main__":
    unittest.main()
