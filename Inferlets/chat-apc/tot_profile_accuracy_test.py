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


if __name__ == "__main__":
    unittest.main()
