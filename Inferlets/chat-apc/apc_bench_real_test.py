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


def _pair(warm_reused, warm_appended, cold_pages, warm_pages):
    """A cold/warm pair that differs ONLY in the quantities under test.

    Both turns report the outcomes the existing gate wants (`miss` / `hit`), so
    anything these tests catch is caught strictly by the cheapness floors.
    """
    cold = bench.TurnMeasurement(
        label="cold_miss", status_code=200, wall_time_s=4.0, ttft_s=1.2, content="cold",
        cache_diag={"outcome": "miss", "base_boundary": 0, "appended": 400},
        output_tokens=10, tokens_per_sec=5.0,
        kv_pages_before=0, kv_pages_after=cold_pages,
        rss_bytes_before=0, rss_bytes_after=0,
    )
    warm = bench.TurnMeasurement(
        label="warm_hit", status_code=200, wall_time_s=2.5, ttft_s=0.2, content="warm",
        cache_diag={"outcome": "hit", "base_boundary": warm_reused, "appended": warm_appended},
        output_tokens=10, tokens_per_sec=5.0,
        kv_pages_before=0, kv_pages_after=warm_pages,
        rss_bytes_before=0, rss_bytes_after=0,
    )
    return cold, warm


class WarmTurnCheapnessTests(unittest.TestCase):
    """`outcome == "hit"` is a boolean; these floors make it a measurement.

    Both regressions these guard against reported a healthy warm hit while
    doing the cold turn's work.
    """

    def test_a_genuinely_cheap_warm_hit_passes(self):
        failures = []
        cold, warm = _pair(warm_reused=380, warm_appended=20, cold_pages=40, warm_pages=4)
        bench._validate_pair("scenario", 0, cold, warm, failures)
        self.assertEqual(failures, [])

    def test_a_hit_reaching_a_shallow_boundary_fails_the_reuse_floor(self):
        # Graded loss: still a hit, still >0 reused tokens, but most of the
        # history is being re-prefilled — the pre-ladder defect's shape.
        failures = []
        cold, warm = _pair(warm_reused=100, warm_appended=300, cold_pages=40, warm_pages=4)
        bench._validate_pair("scenario", 0, cold, warm, failures)
        self.assertTrue(any("reuse fraction" in f for f in failures), failures)

    def test_a_hit_that_reprefills_fails_the_page_floor(self):
        # The regression introduced while fixing the first bug: the boundary
        # save ran on a separate full-history context, so the warm turn paid a
        # second full forward pass. TTFT was UNCHANGED, which is why every
        # latency assertion passed and only wall time grew.
        failures = []
        cold, warm = _pair(warm_reused=380, warm_appended=20, cold_pages=40, warm_pages=39)
        bench._validate_pair("scenario", 0, cold, warm, failures)
        self.assertTrue(any("prefilling like a miss" in f for f in failures), failures)

    def test_the_floors_are_skipped_when_the_engine_reported_no_pages(self):
        # Absent page accounting must not manufacture a failure.
        failures = []
        cold, warm = _pair(warm_reused=380, warm_appended=20, cold_pages=0, warm_pages=0)
        bench._validate_pair("scenario", 0, cold, warm, failures)
        self.assertEqual(failures, [])

    def test_a_short_exchange_is_exempt_because_the_new_turn_dominates(self):
        # Measured `short_qa`: 35 of 59 prompt tokens reused on 3 vs 2 pages.
        # A perfect warm hit cannot do better — the other 24 tokens ARE the new
        # user message. Flagging it would only train people to ignore the bench.
        failures = []
        cold, warm = _pair(warm_reused=35, warm_appended=24, cold_pages=3, warm_pages=2)
        bench._validate_pair("scenario", 0, cold, warm, failures)
        self.assertEqual(failures, [])

    def test_the_measured_healthy_long_scenario_passes(self):
        # Measured `long_agent_summary`: 1655/1688 reused (0.980), 5 -> 2 pages
        # (0.40). This is the shape both floors are calibrated to protect.
        failures = []
        cold, warm = _pair(warm_reused=1655, warm_appended=33, cold_pages=5, warm_pages=2)
        bench._validate_pair("scenario", 0, cold, warm, failures)
        self.assertEqual(failures, [])


if __name__ == "__main__":
    unittest.main()
