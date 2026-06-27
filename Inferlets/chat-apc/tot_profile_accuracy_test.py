"""Engine-free guards for the shipped ToT profile accuracy slice (#852).

This test module intentionally avoids booting pie.  It pins the pure reporting
contract for the real harness: parse product-surface responses, disclose ToT
node errors, hold non-graded items out of denominators, and keep multi-model
results separate.

Run:

    uv run --project Vendor/pie/client/python --with httpx --with jsonschema \
      python Inferlets/chat-apc/tot_profile_accuracy_test.py
"""
from __future__ import annotations

import json
import unittest
import asyncio
import os
import tempfile
from pathlib import Path
from unittest import mock

import tot_profile_accuracy as h


def _sse(*payloads: dict | str) -> str:
    lines = []
    for payload in payloads:
        if isinstance(payload, str):
            lines.append(f"data: {payload}")
        else:
            lines.append(f"data: {json.dumps(payload)}")
        lines.append("")
    return "\n".join(lines)


class ResponseParsing(unittest.TestCase):
    def test_single_pass_uses_usage_completion_tokens_when_available(self):
        parsed = h.parse_single_pass_response(
            {
                "choices": [{"message": {"content": "We compute it. #### 18"}}],
                "usage": {"completion_tokens": 7},
            },
            fallback_count=lambda text: 999,
        )

        self.assertEqual(parsed.answer, "We compute it. #### 18")
        self.assertEqual(parsed.tokens, 7)
        self.assertIsNone(parsed.error)
        self.assertEqual(parsed.token_source, "usage.completion_tokens")

    def test_single_pass_falls_back_to_token_counter_when_usage_missing(self):
        parsed = h.parse_single_pass_response(
            {"choices": [{"message": {"content": "#### 42"}}]},
            fallback_count=lambda text: len(text.split()),
        )

        self.assertEqual(parsed.tokens, 2)
        self.assertEqual(parsed.token_source, "tokenizer_fallback")

    def test_tot_stream_extracts_answer_metrics_and_node_errors(self):
        parsed = h.parse_tot_stream(
            _sse(
                {"event": "tree_start", "breadth": 2, "depth": 2, "beam_width": 1},
                {
                    "event": "node_complete",
                    "node": {
                        "id": "n1",
                        "depth": 1,
                        "status": "error",
                        "error": "forward_pass_starved",
                    },
                },
                {
                    "event": "node_complete",
                    "node": {
                        "id": "n2",
                        "depth": 1,
                        "status": "ok",
                        "score_error": "score unavailable",
                        "content": "try 18",
                    },
                },
                {"event": "tree_complete", "selected_node_id": "n2", "final_answer": "#### 18"},
                {
                    "event": "generation_metrics",
                    "output_tokens": 33,
                    "elapsed_s": 4.5,
                    "tokens_per_sec": 7.3,
                },
                "[DONE]",
            )
        )

        self.assertEqual(parsed.answer, "#### 18")
        self.assertEqual(parsed.tokens, 33)
        self.assertEqual(parsed.token_source, "generation_metrics.output_tokens")
        self.assertIsNone(parsed.error)
        self.assertEqual(len(parsed.node_errors), 2)
        self.assertEqual(parsed.node_errors[0]["status"], "error")
        self.assertEqual(parsed.node_errors[1]["score_error"], "score unavailable")


class DatasetSelection(unittest.TestCase):
    def test_default_datasets_exclude_jsonschema_but_include_target_generalization_set(self):
        with mock.patch.dict(os.environ, {}, clear=True):
            self.assertEqual(h._datasets_from_env(), ["gsm8k", "humaneval", "mbpp", "mmlu"])

    def test_explicit_jsonschema_remains_selectable_through_allowlist(self):
        with mock.patch.dict(os.environ, {"DATASETS": "jsonschema"}, clear=True), \
             mock.patch.object(h.base, "_which_datasets", return_value=["jsonschema"]) as which:
            self.assertEqual(h._datasets_from_env(), ["jsonschema"])
            which.assert_called_once_with()

    def test_datasets_from_env_preserves_comma_allowlist(self):
        with mock.patch.dict(os.environ, {"DATASETS": "humaneval,mbpp"}, clear=True), \
             mock.patch.object(h.base, "_which_datasets", return_value=["humaneval", "mbpp"]):
            self.assertEqual(h._datasets_from_env(), ["humaneval", "mbpp"])

    def test_collect_dataset_rows_keeps_one_row_per_dataset_in_order(self):
        calls = []

        async def run_one_dataset(model, dataset):
            calls.append((model, dataset))
            return {
                "model": model,
                "dataset": dataset,
                "single": {"n_graded": 1},
                "tot": {"n_graded": 1},
                "items": [],
            }

        rows = asyncio.run(
            h.collect_dataset_rows("model-a", ["humaneval", "mbpp"], run_one_dataset)
        )

        self.assertEqual(calls, [("model-a", "humaneval"), ("model-a", "mbpp")])
        self.assertEqual([row["dataset"] for row in rows], ["humaneval", "mbpp"])
        self.assertTrue(all(row["model"] == "model-a" for row in rows))


class Aggregation(unittest.TestCase):
    def test_aggregate_holds_ungradable_and_errors_out_and_reports_cost_delta(self):
        items = [
            h.ItemResult(
                dataset="gsm8k",
                index=1,
                prompt_id="gsm8k:1",
                reference={"final_answer": "18"},
                single=h.ArmResult(answer="#### 18", tokens=10, latency_s=1.0),
                tot=h.ArmResult(answer="#### 17", tokens=25, latency_s=3.0),
            ),
            h.ItemResult(
                dataset="gsm8k",
                index=2,
                prompt_id="gsm8k:2",
                reference={"final_answer": "9"},
                single=h.ArmResult(answer="no number", tokens=4, latency_s=0.5),
                tot=h.ArmResult(answer="#### 9", tokens=20, latency_s=2.0),
            ),
            h.ItemResult(
                dataset="gsm8k",
                index=3,
                prompt_id="gsm8k:3",
                reference={"final_answer": "5"},
                single=h.ArmResult(answer=None, tokens=0, latency_s=0.2, error="500"),
                tot=h.ArmResult(answer=None, tokens=6, latency_s=1.2, error="terminal error"),
            ),
        ]

        summary = h.summarize_model("Qwen/Qwen3-8B", items, "gsm8k_numeric")

        self.assertEqual(summary["model"], "Qwen/Qwen3-8B")
        self.assertEqual(summary["single"]["n_correct"], 1)
        self.assertEqual(summary["single"]["n_ungradable"], 1)
        self.assertEqual(summary["single"]["n_error"], 1)
        self.assertEqual(summary["single"]["accuracy"], 1.0)
        self.assertEqual(summary["tot"]["n_correct"], 1)
        self.assertEqual(summary["tot"]["n_wrong"], 1)
        self.assertEqual(summary["tot"]["n_error"], 1)
        self.assertEqual(summary["tot"]["accuracy"], 0.5)
        self.assertEqual(summary["accuracy_delta_tot_minus_single"], -0.5)
        self.assertEqual(summary["mean_token_delta_tot_minus_single"], 15.5)
        self.assertEqual(summary["mean_latency_delta_s_tot_minus_single"], 1.75)
        self.assertEqual(summary["single"]["mean_tokens_per_second"], 10.0)
        self.assertAlmostEqual(summary["tot"]["mean_tokens_per_second"], 9.1666666667)
        self.assertAlmostEqual(
            summary["mean_tokens_per_second_delta_tot_minus_single"],
            0.1666666667,
        )


    def test_run_model_dataset_scores_existing_code_datasets_with_grade_oracle(self):
        records_by_dataset = {
            "humaneval": [
                {
                    "id": "HumanEval/0",
                    "prompt": "Complete add_one",
                    "reference": {
                        "entry_point": "add_one",
                        "canonical_prompt": "def add_one(x):\n",
                        "test": "def check(candidate):\n    assert candidate(1) == 2",
                    },
                }
            ],
            "mbpp": [
                {
                    "id": "1",
                    "prompt": "Write f",
                    "reference": {
                        "test_setup_code": "",
                        "test_list": ["assert f(1) == 2"],
                    },
                }
            ],
        }
        answers = {
            "humaneval": "    return x + 1\n",
            "mbpp": "def f(a):\n    return a + 1\n",
        }

        async def fake_once(http_c, base_url, model, prompt, count):
            dataset = "humaneval" if "add_one" in prompt else "mbpp"
            return h.ArmResult(answer=answers[dataset], tokens=3, latency_s=0.01)

        def fake_load_prompts(dataset):
            return records_by_dataset[dataset], len(records_by_dataset[dataset])

        with mock.patch.object(h.base, "_load_prompts", side_effect=fake_load_prompts), \
             mock.patch.object(h, "_single_once", side_effect=fake_once), \
             mock.patch.object(h, "_tot_once", side_effect=fake_once):
            rows = asyncio.run(
                h._run_model(
                    "http://local", "model-a", ["humaneval", "mbpp"],
                    lambda text: len(text.split()),
                )
            )

        self.assertEqual([row["dataset"] for row in rows], ["humaneval", "mbpp"])
        for row in rows:
            self.assertEqual(row["single"]["accuracy"], 1.0, row)
            self.assertEqual(row["tot"]["accuracy"], 1.0, row)
            self.assertEqual(row["coverage"], {"measured": 1, "total": 1})

    def test_artifact_keeps_multiple_models_in_priority_order(self):
        artifact = h.build_artifact(
            models=[
                {"model": "Qwen/Qwen3-14B-GGUF", "items": [], "single": {}, "tot": {}},
                {"model": "Qwen/Qwen3-0.6B", "items": [], "single": {}, "tot": {}},
            ],
            settings={"dataset": "gsm8k", "breadth": 2},
        )

        self.assertEqual(
            [row["model"] for row in artifact["models"]],
            ["Qwen/Qwen3-14B-GGUF", "Qwen/Qwen3-0.6B"],
        )
        self.assertEqual(artifact["settings"]["dataset"], "gsm8k")

    def test_default_models_start_with_cheap_model_before_heavy_models(self):
        self.assertEqual(h.DEFAULT_MODELS[0], "Qwen/Qwen3-0.6B")
        self.assertIn("Qwen/Qwen3-14B-GGUF", h.DEFAULT_MODELS[-1])

    def test_all_ungraded_artifact_is_measurement_failure(self):
        artifact = h.build_artifact(
            models=[
                {
                    "model": "m",
                    "single": {"n_graded": 0},
                    "tot": {"n_graded": 0},
                    "items": [],
                }
            ],
            settings={"dataset": "gsm8k"},
        )

        self.assertFalse(h.has_any_graded_item(artifact))

    def test_any_graded_cell_is_measurement_success(self):
        artifact = h.build_artifact(
            models=[
                {
                    "model": "m",
                    "single": {"n_graded": 0},
                    "tot": {"n_graded": 1},
                    "items": [],
                }
            ],
            settings={"dataset": "gsm8k"},
        )

        self.assertTrue(h.has_any_graded_item(artifact))

    def test_boot_failure_records_dataset_rows_continues_and_snapshots_rows(self):
        async def run_one(index, model):
            if model == "bad":
                raise h.ModelBootError(RuntimeError("handshake timeout"))
            return [
                h.summarize_model(
                    model,
                    [
                        h.ItemResult(
                            dataset="gsm8k",
                            index=1,
                            prompt_id="gsm8k:1",
                            reference={"final_answer": "18"},
                            single=h.ArmResult(answer="#### 18", tokens=1, latency_s=0.1),
                            tot=h.ArmResult(answer="#### 18", tokens=2, latency_s=0.2),
                        )
                    ],
                    "gsm8k_numeric",
                )
            ]

        snapshots = []
        rows = asyncio.run(
            h.collect_model_rows(
                ["bad", "good"],
                ["gsm8k", "mmlu"],
                run_one,
                write_partial=lambda current: snapshots.append(
                    [(r["model"], r["dataset"]) for r in current]
                ),
            )
        )

        self.assertEqual(
            [(r["model"], r["dataset"]) for r in rows],
            [("bad", "gsm8k"), ("bad", "mmlu"), ("good", "gsm8k")],
        )
        self.assertEqual(rows[0]["boot_error"], "RuntimeError: handshake timeout")
        self.assertEqual(rows[0]["single"]["n_graded"], 0)
        self.assertEqual(rows[1]["dataset"], "mmlu")
        self.assertEqual(rows[2]["single"]["n_graded"], 1)
        self.assertEqual(
            snapshots,
            [[("bad", "gsm8k"), ("bad", "mmlu")],
             [("bad", "gsm8k"), ("bad", "mmlu"), ("good", "gsm8k")]],
        )

    def test_mid_run_failure_propagates_instead_of_becoming_boot_error(self):
        async def run_one(index, model):
            raise RuntimeError("grader exploded")

        with self.assertRaisesRegex(RuntimeError, "grader exploded"):
            asyncio.run(h.collect_model_rows(["model"], ["gsm8k"], run_one))

    def test_atomic_write_json_replaces_complete_temp_file(self):
        with tempfile.TemporaryDirectory() as tmp:
            out = Path(tmp) / "artifact.json"
            out.write_text('{"previous": true}')
            replacements = []
            real_replace = os.replace

            def capturing_replace(src, dst):
                replacements.append((Path(src), Path(dst), Path(src).read_text()))
                real_replace(src, dst)

            with mock.patch.object(h.os, "replace", side_effect=capturing_replace):
                h.atomic_write_json(out, {"models": [{"model": "m"}]})

            self.assertEqual(json.loads(out.read_text()), {"models": [{"model": "m"}]})
            self.assertEqual(replacements[0][1], out)
            self.assertEqual(json.loads(replacements[0][2]), {"models": [{"model": "m"}]})
            self.assertFalse(replacements[0][0].exists())

    def test_shmem_name_is_unique_per_model_boot(self):
        self.assertNotEqual(h.shmem_name(1), h.shmem_name(2))
        self.assertTrue(h.shmem_name(2).endswith("_2"))


if __name__ == "__main__":
    unittest.main()
