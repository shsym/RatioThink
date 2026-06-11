#!/usr/bin/env python3
"""Pure-unit coverage for the gated ToT real-model smoke assertions."""

from __future__ import annotations

import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import tot_real_smoke as smoke


class PlanningScorerGateTests(unittest.TestCase):
    def test_requires_a_parsed_score_for_each_planning_prompt(self) -> None:
        evidence = [
            smoke.PlanningPromptEvidence(label="p0", sims=[0.1], scores=[7]),
            smoke.PlanningPromptEvidence(label="p1", sims=[0.1], scores=[]),
            smoke.PlanningPromptEvidence(label="p2", sims=[0.1], scores=[]),
        ]

        summary = smoke.evaluate_planning_evidence(evidence)

        self.assertEqual(summary.parsed_score_prompts, 1)
        self.assertIn("p1: scorer parsed zero integer scores", summary.failures)
        self.assertIn("p2: scorer parsed zero integer scores", summary.failures)

    def test_rejects_run_when_all_scored_prompts_are_ties(self) -> None:
        evidence = [
            smoke.PlanningPromptEvidence(label="p0", sims=[0.1], scores=[5, 5, 5]),
            smoke.PlanningPromptEvidence(label="p1", sims=[0.2], scores=[6, 6]),
        ]

        summary = smoke.evaluate_planning_evidence(evidence)

        self.assertEqual(summary.discriminating_score_prompts, 0)
        self.assertIn(
            "scorer did not discriminate among any planning prompt siblings "
            "(every scored prompt was an all-score tie)",
            summary.failures,
        )

    def test_tolerates_a_tied_prompt_when_another_prompt_discriminates(self) -> None:
        evidence = [
            smoke.PlanningPromptEvidence(label="surprise-party", sims=[0.1], scores=[5, 5, 5]),
            smoke.PlanningPromptEvidence(label="weekend-trip", sims=[0.2], scores=[4, 7, 6]),
        ]

        summary = smoke.evaluate_planning_evidence(evidence)

        self.assertEqual(summary.parsed_score_prompts, 2)
        self.assertEqual(summary.discriminating_score_prompts, 1)
        self.assertEqual(summary.failures, [])


if __name__ == "__main__":
    unittest.main(verbosity=2)
