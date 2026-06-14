import json
import unittest

import apc_bench_real as bench


class ApcBenchRealTests(unittest.TestCase):
    def test_parse_sse_frames_extracts_content_metrics_and_cache_diag(self):
        raw = (
            b'data: {"event":"model_ready"}\n\n'
            b'data: {"object":"chat.completion.chunk","choices":[{"delta":{"role":"assistant"},"finish_reason":null}]}\n\n'
            b'data: {"object":"chat.completion.chunk","choices":[{"delta":{"content":"Paris"},"finish_reason":null}]}\n\n'
            b'data: {"event":"generation_metrics","output_tokens":7,"elapsed_s":0.5,"tokens_per_sec":14.0}\n\n'
            b'data: {"event":"cache","outcome":"hit","key":"chat-a","base_boundary":26,"appended":9,"save_result":"saved"}\n\n'
            b'data: [DONE]\n\n'
        )

        frames = list(bench.parse_sse_frames(raw.splitlines(keepends=True)))
        summary = bench.summarize_stream_frames(frames)

        self.assertEqual(summary.content, "Paris")
        self.assertEqual(summary.output_tokens, 7)
        self.assertEqual(summary.tokens_per_sec, 14.0)
        self.assertEqual(summary.cache_diag["outcome"], "hit")
        self.assertTrue(summary.done)

    def test_compare_turns_reports_saved_ttft_wall_and_kv_delta(self):
        cold = bench.TurnMeasurement(
            label="cold_miss",
            status_code=200,
            wall_time_s=4.0,
            ttft_s=1.2,
            content="cold",
            cache_diag={"outcome": "miss", "save_result": "saved", "base_boundary": 0, "appended": 32},
            output_tokens=10,
            tokens_per_sec=5.0,
            kv_pages_before=100,
            kv_pages_after=140,
            rss_bytes_before=1_000,
            rss_bytes_after=1_300,
        )
        warm = bench.TurnMeasurement(
            label="warm_hit",
            status_code=200,
            wall_time_s=2.5,
            ttft_s=0.4,
            content="warm",
            cache_diag={"outcome": "hit", "prefix_hash": "abc", "base_boundary": 26, "appended": 6},
            output_tokens=10,
            tokens_per_sec=6.0,
            kv_pages_before=140,
            kv_pages_after=152,
            rss_bytes_before=1_300,
            rss_bytes_after=1_360,
        )

        comparison = bench.compare_pair(cold, warm)

        self.assertEqual(comparison["cold_outcome"], "miss")
        self.assertEqual(comparison["warm_outcome"], "hit")
        self.assertAlmostEqual(comparison["ttft_saved_s"], 0.8)
        self.assertAlmostEqual(comparison["wall_saved_s"], 1.5)
        self.assertAlmostEqual(comparison["ttft_speedup"], 3.0)
        self.assertEqual(comparison["cold_kv_pages_delta"], 40)
        self.assertEqual(comparison["warm_kv_pages_delta"], 12)
        self.assertEqual(comparison["warm_reused_prefix_tokens"], 26)

    def test_markdown_summary_includes_artifact_and_correctness_status(self):
        artifact = {
            "created_at": "2026-06-12T00:00:00Z",
            "model": "Qwen/Qwen3-0.6B",
            "comparisons": [{
                "scenario": "short_qa",
                "cold_outcome": "miss",
                "warm_outcome": "hit",
                "ttft_saved_s": 0.8,
                "wall_saved_s": 1.5,
                "warm_reused_prefix_tokens": 26,
            }],
            "correctness": {"passed": True, "failures": []},
            "output_path": "artifacts/apc.json",
        }

        md = bench.render_markdown_summary(artifact)

        self.assertIn("Qwen/Qwen3-0.6B", md)
        self.assertIn("short_qa", md)
        self.assertIn("PASS", md)
        self.assertIn("artifacts/apc.json", md)
        self.assertIn("0.800", md)

    def test_benchmark_tempdir_keeps_pie_home_under_aux_socket_budget(self):
        with bench.benchmark_tempdir() as tmp:
            pie_home = tmp / "home"

            self.assertEqual(tmp.parent.as_posix(), "/tmp")
            self.assertLessEqual(
                len(str(pie_home).encode("utf-8")),
                bench.MAX_SAFE_PIE_HOME_BYTES,
            )

    def test_default_scenarios_request_visible_answers_for_thinking_models(self):
        user_turns = [
            m["content"]
            for scenario in bench.default_scenarios(max_tokens=32)
            for m in [*scenario.messages_turn1, {"role": "user", "content": scenario.continuation_user}]
            if m["role"] == "user"
        ]

        self.assertTrue(user_turns)
        self.assertTrue(all("/no_think" in content for content in user_turns))


if __name__ == "__main__":
    unittest.main()
