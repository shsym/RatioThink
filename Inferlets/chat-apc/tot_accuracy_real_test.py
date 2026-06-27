"""Engine-free unit guards for the #657 deterministic graders (grade.py).

Deterministic, CI-safe — no engine, no model, no network. For each dataset a
correct answer scores True, a wrong one False, and an unparseable/empty one None
(held out of the accuracy denominator, NOT scored wrong). HumanEval/MBPP exec
trusted fixture code in a subprocess; jsonschema validates against a fixture
schema. The arm orchestration / aggregation is covered by tot_arms_test.py; the
BFS controller by tot_search_test.py; the baselines by baselines_test.py.

Run::

    uv run --project Vendor/pie/client/python --with httpx --with jsonschema \
      python Inferlets/chat-apc/tot_accuracy_real_test.py
"""
from __future__ import annotations

import json
import os
import sys
import tempfile
from pathlib import Path
import unittest
from unittest import mock

import grade as g

BENCHMARK_DIR = Path(__file__).resolve().parents[2] / "Scripts" / "benchmark"
if str(BENCHMARK_DIR) not in sys.path:
    sys.path.insert(0, str(BENCHMARK_DIR))
import prep_datasets as prep  # noqa: E402
import tot_accuracy_real as real  # noqa: E402

_HAS_SANDBOX = os.path.exists(g._SANDBOX_EXEC)


@unittest.skipUnless(_HAS_SANDBOX, "macOS sandbox-exec required")
class SandboxIsolation(unittest.TestCase):
    """The code graders execute MODEL-GENERATED code; prove the Seatbelt sandbox
    blocks DESTRUCTIVE behaviour (file writes/deletes outside the work dir,
    network) while ordinary compute still runs and a runaway is killed."""

    def test_ordinary_compute_passes(self):
        passed, _ = g.run_program("assert 6 * 7 == 42\n")
        self.assertIs(passed, True)

    def test_home_write_is_blocked(self):
        target = os.path.expanduser("~/.sbtest_home_write_probe")
        try:
            g.run_program(f"open({target!r}, 'w').write('pwned')\n")
            self.assertFalse(os.path.exists(target), "candidate wrote to HOME — sandbox leak!")
        finally:
            if os.path.exists(target):
                os.remove(target)

    def test_rm_of_existing_file_is_blocked(self):
        decoy = os.path.expanduser("~/.sbtest_decoy_keepme")
        with open(decoy, "w") as f:
            f.write("keep")
        try:
            g.run_program(f"import os; os.system('rm -f {decoy}')\n")
            self.assertTrue(os.path.exists(decoy), "candidate deleted a HOME file — sandbox leak!")
        finally:
            if os.path.exists(decoy):
                os.remove(decoy)

    def test_workdir_write_is_allowed(self):
        # writing a RELATIVE file (into the throwaway cwd) must succeed.
        passed, _ = g.run_program("open('scratch.txt','w').write('ok'); assert True\n")
        self.assertIs(passed, True)

    def test_infinite_loop_times_out_fast(self):
        passed, detail = g.run_program("while True: pass\n", timeout=2)
        self.assertIs(passed, False)
        self.assertIn("timeout", detail)


# --- extraction helpers ----------------------------------------------------


class Extraction(unittest.TestCase):
    def test_extract_code_prefers_first_fenced_block(self):
        text = "blah\n```python\nx = 1\n```\nmore\n```\ny = 2\n```"
        self.assertEqual(g.extract_code(text), "x = 1\n")

    def test_extract_code_falls_back_to_raw(self):
        self.assertEqual(g.extract_code("def f(): pass"), "def f(): pass")

    def test_last_number_takes_final_strips_commas(self):
        self.assertEqual(g.last_number("first 7 then 1,024 dollars"), "1024")
        self.assertEqual(g.last_number("the answer is -3.5."), "-3.5")
        self.assertIsNone(g.last_number("no digits here"))

    def test_extract_json_returns_first_balanced_object(self):
        self.assertEqual(g.extract_json('here: {"x": {"y": 1}}. done'), '{"x": {"y": 1}}')

    def test_extract_json_ignores_braces_inside_strings(self):
        self.assertEqual(g.extract_json('{"s": "a}b"}'), '{"s": "a}b"}')

    def test_extract_json_none_when_absent(self):
        self.assertIsNone(g.extract_json("plain prose, no json"))


# --- graders ---------------------------------------------------------------


class GSM8KGrader(unittest.TestCase):
    REF = {"final_answer": "18"}

    def test_correct_final_number(self):
        self.assertTrue(g.gsm8k_numeric("So the total is 18 apples.", self.REF).passed)

    def test_correct_with_decimal_equivalence(self):
        self.assertTrue(g.gsm8k_numeric("answer: 18.0", self.REF).passed)

    def test_wrong_number(self):
        self.assertIs(g.gsm8k_numeric("the answer is 17", self.REF).passed, False)

    def test_no_number_is_ungradable_not_wrong(self):
        self.assertIsNone(g.gsm8k_numeric("I cannot tell", self.REF).passed)

    def test_empty_is_ungradable(self):
        self.assertIsNone(g.gsm8k_numeric("", self.REF).passed)


class MMLUPrep(unittest.TestCase):
    def test_prompt_maps_letter_choices_to_numeric_answer_contract(self):
        rec = {
            "subject": "abstract_algebra",
            "question": "Which structure has an identity element?",
            "choices": ["Magma", "Monoid", "Graph", "Field extension"],
            "answer": 1,
        }

        prompt = prep._mmlu_prompt(rec)
        ref = prep._mmlu_reference(rec)

        self.assertIn("1. Magma", prompt)
        self.assertIn("2. Monoid", prompt)
        self.assertIn("Answer with only the number", prompt)
        self.assertEqual(ref, {"final_answer": "2", "choice_count": 4})

    def test_mmlu_registry_is_graded_and_locked_allowlist_visible(self):
        self.assertEqual(prep.REGISTRY["mmlu"]["grader"], "mcq_numeric")
        self.assertEqual(prep.REGISTRY["mmlu"]["ref_builder"], prep._mmlu_reference)

        with tempfile.TemporaryDirectory() as tmp, \
             mock.patch.object(real, "LOCK_PATH", Path(tmp) / "datasets.lock"), \
             mock.patch.dict(os.environ, {"DATASETS": "mmlu"}, clear=False):
            real.LOCK_PATH.write_text(json.dumps({
                "datasets": {
                    "gsm8k": {"grader": "gsm8k_numeric"},
                    "mmlu": {"grader": "mcq_numeric"},
                    "mtbench": {},
                }
            }))
            self.assertEqual(real._which_datasets(), ["mmlu"])


class ConfigToml(unittest.TestCase):
    def test_gguf_model_slug_resolves_to_cached_file_path(self):
        with tempfile.TemporaryDirectory() as tmp, \
             mock.patch.dict(os.environ, {"HF_HOME": tmp}, clear=False):
            gguf = (
                Path(tmp)
                / "hub"
                / "models--Qwen--Qwen3-14B-GGUF"
                / "snapshots"
                / "abc123"
                / "Qwen3-14B-Q4_K_M.gguf"
            )
            gguf.parent.mkdir(parents=True)
            gguf.write_text("fake gguf bytes")

            cfg = real.config_toml("Qwen/Qwen3-14B-GGUF")

        self.assertIn('name = "Qwen/Qwen3-14B-GGUF"', cfg)
        self.assertIn(f'hf_repo = "{gguf}"', cfg)

    def test_non_gguf_model_slug_stays_as_repo_id(self):
        cfg = real.config_toml("Qwen/Qwen3-8B")

        self.assertIn('name = "Qwen/Qwen3-8B"', cfg)
        self.assertIn('hf_repo = "Qwen/Qwen3-8B"', cfg)


class HumanEvalGrader(unittest.TestCase):
    REF = {
        "canonical_prompt": 'from typing import List\n\n\ndef add(a, b):\n    """add"""\n',
        "test": "def check(candidate):\n    assert candidate(1, 2) == 3\n",
        "entry_point": "add",
    }

    def test_body_continuation_passes(self):
        self.assertTrue(g.humaneval_exec("    return a + b\n", self.REF).passed)

    def test_full_function_passes_with_prompt_imports(self):
        # The model re-emitted the WHOLE function and uses `math`, which is only
        # available if the prompt's leading `import math` is carried in — proving
        # _import_lines wires the prompt imports for a standalone definition.
        ref = {
            "canonical_prompt": 'import math\n\n\ndef isqrt4(x):\n    """sqrt"""\n',
            "test": "def check(candidate):\n    assert candidate(16) == 4\n",
            "entry_point": "isqrt4",
        }
        out = "```python\ndef isqrt4(x):\n    return int(math.sqrt(x))\n```"
        self.assertTrue(g.humaneval_exec(out, ref).passed)

    def test_wrong_body_fails(self):
        self.assertIs(g.humaneval_exec("    return a - b\n", self.REF).passed, False)

    def test_empty_is_ungradable(self):
        self.assertIsNone(g.humaneval_exec("   ", self.REF).passed)


class MBPPGrader(unittest.TestCase):
    REF = {"test_setup_code": "", "test_list": ["assert add(1, 2) == 3"]}

    def test_correct_function_passes(self):
        self.assertTrue(g.mbpp_exec("def add(a, b):\n    return a + b\n", self.REF).passed)

    def test_wrong_function_fails(self):
        self.assertIs(g.mbpp_exec("def add(a, b):\n    return a - b\n", self.REF).passed, False)

    def test_setup_code_is_run(self):
        ref = {"test_setup_code": "import math", "test_list": ["assert f() == math.pi"]}
        self.assertTrue(g.mbpp_exec("def f():\n    import math\n    return math.pi\n", ref).passed)

    def test_empty_is_ungradable(self):
        self.assertIsNone(g.mbpp_exec("", self.REF).passed)


class MCQNumericGrader(unittest.TestCase):
    REF = {"final_answer": "2", "choice_count": 4}

    def test_correct_numeric_choice(self):
        self.assertTrue(g.mcq_numeric("The answer is 2.", self.REF).passed)

    def test_verbose_reasoning_tail_can_still_end_in_correct_choice(self):
        out = "I compared 4 options and eliminated choices 1 and 3. Final answer: 2"
        self.assertTrue(g.mcq_numeric(out, self.REF).passed)

    def test_out_of_range_reasoning_number_is_ungradable(self):
        out = "I considered option 2, but there are 7 fields in the distractor."
        result = g.mcq_numeric(out, self.REF)
        self.assertIsNone(result.passed)
        self.assertIn("outside", result.detail)

    def test_wrong_numeric_choice(self):
        self.assertIs(g.mcq_numeric("I choose 3", self.REF).passed, False)

    def test_no_numeric_choice_is_ungradable(self):
        self.assertIsNone(g.mcq_numeric("I choose B", self.REF).passed)

    def test_dispatch_registry_includes_mmlu_grader(self):
        self.assertTrue(g.grade("mcq_numeric", "2", self.REF).passed)


class JSONSchemaGrader(unittest.TestCase):
    REF = {"json_schema": '{"type":"object","required":["x"],'
                          '"properties":{"x":{"type":"integer"}}}'}

    def test_valid_instance_passes(self):
        self.assertTrue(g.jsonschema_validate('{"x": 5}', self.REF).passed)

    def test_invalid_instance_fails(self):
        self.assertIs(g.jsonschema_validate('{"x": "not-int"}', self.REF).passed, False)

    def test_missing_required_fails(self):
        self.assertIs(g.jsonschema_validate('{"y": 1}', self.REF).passed, False)

    def test_non_json_is_ungradable(self):
        self.assertIsNone(g.jsonschema_validate("I cannot produce JSON", self.REF).passed)

    def test_prose_wrapped_json_is_extracted(self):
        self.assertTrue(g.jsonschema_validate('Here it is: {"x": 1}. Enjoy!', self.REF).passed)


class GraderDispatch(unittest.TestCase):
    def test_unknown_grader_is_hard_error(self):
        with self.assertRaises(KeyError):
            g.grade("nope", "x", {})

    def test_registry_names_match_lock_graders(self):
        self.assertEqual(
            sorted(g.GRADERS),
            [
                "gsm8k_numeric",
                "humaneval_exec",
                "jsonschema_validate",
                "mbpp_exec",
                "mcq_numeric",
            ],
        )


if __name__ == "__main__":
    unittest.main()
