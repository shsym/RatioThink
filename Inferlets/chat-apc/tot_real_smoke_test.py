#!/usr/bin/env python3
"""Pure unit tests for the real ToT smoke harness gates."""
from __future__ import annotations

import sys
import unittest
from pathlib import Path

_HERE = Path(__file__).resolve().parent
if str(_HERE) not in sys.path:
    sys.path.insert(0, str(_HERE))

import tot_real_smoke as smoke  # noqa: E402


class PlanningScorerGateTests(unittest.TestCase):
    def test_requires_a_parsed_score_for_each_planning_prompt(self):
        evidence = smoke.PlanningEvidence(label="surprise-party", sims=[0.2], scores=[])

        failures = smoke.validate_planning_evidence(evidence)

        self.assertEqual(
            failures,
            ["surprise-party: scorer parsed zero integer scores for this planning prompt — pruning would fall back to input order"],
        )

    def test_global_or_would_miss_a_prompt_level_scorer_collapse(self):
        evidences = [
            smoke.PlanningEvidence(label="surprise-party", sims=[0.2], scores=[]),
            smoke.PlanningEvidence(label="weekend-trip", sims=[0.2], scores=[7]),
        ]

        failures = smoke.validate_planning_evidences(evidences, require_non_tied=False)

        self.assertEqual(len(failures), 1)
        self.assertIn("surprise-party: scorer parsed zero", failures[0])

    def test_full_run_requires_some_planning_prompt_to_discriminate_scores(self):
        tied = [
            smoke.PlanningEvidence(label="surprise-party", sims=[0.2], scores=[5, 5, 5, 5, 5]),
            smoke.PlanningEvidence(label="weekend-trip", sims=[0.2], scores=[4, 4, 4]),
        ]

        failures = smoke.validate_planning_evidences(tied, require_non_tied=True)

        self.assertEqual(
            failures,
            ["planning scorer did not discriminate any prompt: every prompt with 2+ parsed sibling scores was tied"],
        )

    def test_full_run_accepts_at_least_one_non_tied_planning_prompt(self):
        mixed = [
            smoke.PlanningEvidence(label="surprise-party", sims=[0.2], scores=[5, 5, 5, 5, 5]),
            smoke.PlanningEvidence(label="weekend-trip", sims=[0.2], scores=[3, 7, 6]),
        ]

        failures = smoke.validate_planning_evidences(mixed, require_non_tied=True)

        self.assertEqual(failures, [])


if __name__ == "__main__":
    unittest.main()
