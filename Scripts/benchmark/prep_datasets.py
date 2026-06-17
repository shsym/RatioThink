"""Pinned PUBLIC dataset materializer for the spec-decode benefit matrix (#652).

This is the *no-cherrypick guard* for the method×workload matrix. Each row of
the matrix is a real public dataset, pinned by HuggingFace **revision hash**,
emitted as the FULL canonical split (no sampling, no hand subsetting, no
seed-based pick). For every dataset we:

  1. ``datasets.load_dataset(repo, config, split, revision=<pinned sha>)`` — the
     revision pin makes the bytes reproducible across machines and time.
  2. Build the prompt list in the dataset's own canonical order (never shuffled).
  3. Write ``Scripts/benchmark/data/<key>.jsonl`` — one ``{"id","prompt",
     "category","think"}`` record per line, UTF-8, ``\n``-terminated, keys in a
     fixed order so the bytes are deterministic.
  4. Hash the emitted file (sha256) and record ``count`` + ``content_sha256`` +
     provenance (repo, revision, split, license, citation, bound rationale) into
     ``Scripts/benchmark/datasets.lock``.

The emitted ``data/`` prompt sets are **gitignored** — they are regenerated on
demand from the pinned revision; only ``datasets.lock`` is committed, and its
``content_sha256`` is the proof that a re-emission reproduced the identical set.

Reproducibility contract (the ticket's verify): re-running a prep script
reproduces the same ``count`` + ``content_sha256``. ``verify`` re-emits every
locked dataset and fails loudly on any drift.

Usage::

    uv run --with "datasets>=2.18" python Scripts/benchmark/prep_datasets.py emit <key>
    uv run --with "datasets>=2.18" python Scripts/benchmark/prep_datasets.py emit-all
    uv run --with "datasets>=2.18" python Scripts/benchmark/prep_datasets.py verify
"""
from __future__ import annotations

import ast
import hashlib
import json
import sys
from pathlib import Path
from typing import Callable

HERE = Path(__file__).resolve().parent
DATA_DIR = HERE / "data"
LOCK_PATH = HERE / "datasets.lock"


# --- prompt builders -------------------------------------------------------
# Each builder maps one raw dataset record to a single greedy-decodable user
# prompt string (or None to skip a malformed row — never used to subsample).


def _mtbench_prompt(rec: dict) -> str:
    # `prompt` is a stringified list of multi-turn user messages. The matrix is
    # a single-turn decode benchmark, so we take TURN 1 (the first user turn);
    # recorded in the lock. ast.literal_eval, not eval — the field is data.
    turns = rec["prompt"]
    if isinstance(turns, str):
        turns = ast.literal_eval(turns)
    return str(turns[0]).strip()


def _humaneval_prompt(rec: dict) -> str:
    # Code completion: the function signature + docstring is the prompt; the
    # model continues the body. This is the row where n-gram drafting can WIN.
    return (
        "Complete the following Python function. Output only the function body.\n\n"
        + rec["prompt"]
    )


def _mbpp_prompt(rec: dict) -> str:
    # NL spec + the assert(s) that pin the function name/signature, the standard
    # MBPP prompting form.
    tests = rec["test_list"]
    if isinstance(tests, str):
        tests = ast.literal_eval(tests)
    asserts = "\n".join(tests)
    return (
        f"{rec['text']}\n"
        "Write a single self-contained Python function that passes these tests:\n"
        f"{asserts}\n"
        "Output only the function definition."
    )


def _gsm8k_prompt(rec: dict) -> str:
    # Grade-school math word problem; Qwen3 thinking is left ON (see `think`).
    return rec["question"].strip()


def _cnndm_prompt(rec: dict) -> str:
    # Abstractive summarization — copies spans from the source, so n-gram
    # drafting is expected to do relatively well (RAG/summarize row).
    return (
        "Summarize the following news article in three sentences.\n\n"
        + rec["article"].strip()
    )


def _jsonschema_prompt(rec: dict) -> str:
    # Structured generation: emit a JSON instance that validates against a real
    # JSON Schema. Braces/keys repeat, so n-gram drafting may help.
    return (
        "Generate a single minimal JSON object that validates against this JSON "
        "Schema. Output only the JSON, no prose.\n\n"
        + rec["json_schema"].strip()
    )


# --- dataset registry ------------------------------------------------------
# `splits` lists every split concatenated, in order, to form the emitted set.
# For MBPP the four `full`-config splits sum to the ticket's 974 (the whole
# dataset); for the others it is the single canonical evaluation split.

REGISTRY: dict[str, dict] = {
    "mtbench": {
        "hf_repo": "HuggingFaceH4/mt_bench_prompts",
        "revision": "e3a795c5e9a82ee40611c416b8a7786c73198991",
        "config": None,
        "splits": ["train"],
        "category": "chat",
        "license": "apache-2.0",
        "citation": "Zheng et al., MT-Bench / LMSYS (NeurIPS 2023). 80 questions.",
        "bound": "full",
        "bound_rationale": "Full 80-question set; turn-1 user prompt per question.",
        "think": False,
        "id_field": "prompt_id",
        "builder": _mtbench_prompt,
    },
    "humaneval": {
        "hf_repo": "openai/openai_humaneval",
        "revision": "7dce6050a7d6d172f3cc5c32aa97f52fa1a2e544",
        "config": None,
        "splits": ["test"],
        "category": "code",
        "license": "mit",
        "citation": "Chen et al., Evaluating LLMs Trained on Code (2021). 164 problems.",
        "bound": "full",
        "bound_rationale": "Full canonical 164-problem test split.",
        "think": False,
        "id_field": "task_id",
        "builder": _humaneval_prompt,
    },
    "mbpp": {
        "hf_repo": "google-research-datasets/mbpp",
        "revision": "4bb6404fdc6cacfda99d4ac4205087b89d32030c",
        "config": "full",
        "splits": ["train", "test", "validation", "prompt"],
        "category": "code",
        "license": "cc-by-4.0",
        "citation": "Austin et al., Program Synthesis with Large Language Models (2021).",
        "bound": "full",
        "bound_rationale": (
            "All four `full`-config splits concatenated in task_id order = 974, "
            "the whole MBPP dataset (the ticket's count). No subsetting."
        ),
        "think": False,
        "id_field": "task_id",
        "builder": _mbpp_prompt,
    },
    "gsm8k": {
        "hf_repo": "openai/gsm8k",
        "revision": "740312add88f781978c0658806c59bc2815b9866",
        "config": "main",
        "splits": ["test"],
        "category": "reasoning",
        "license": "mit",
        "citation": "Cobbe et al., Training Verifiers to Solve Math Word Problems (2021).",
        "bound": "full",
        "bound_rationale": "Full canonical 1319-problem test split; Qwen3 thinking ON.",
        "think": True,
        "id_field": None,
        "builder": _gsm8k_prompt,
    },
    "cnndm": {
        "hf_repo": "abisee/cnn_dailymail",
        "revision": "96df5e686bee6baa90b8bee7c28b81fa3fa6223d",
        "config": "3.0.0",
        "splits": ["test"],
        "category": "summarize",
        "license": "apache-2.0",
        "citation": "Hermann et al. (2015) / See et al. (2017). CNN/DailyMail 3.0.0.",
        "bound": "full",
        "bound_rationale": (
            "Full 11490-article 3.0.0 test split emitted. No published smaller "
            "standard subset exists, so the FULL split is the prompt set; runtime "
            "coverage is bounded+disclosed by the harness MAX_PROMPTS cap, not by "
            "a prep-time pick."
        ),
        "think": False,
        "id_field": "id",
        "builder": _cnndm_prompt,
    },
    "jsonschema": {
        "hf_repo": "epfl-dlab/JSONSchemaBench",
        "revision": "5bd0f4640badc6f3f02df796421d21cb0ca0b141",
        "config": "default",
        "splits": ["test"],
        "category": "structured",
        "license": "mit",
        "citation": "Geng et al., JSONSchemaBench (2025). default config, test split.",
        "bound": "full",
        "bound_rationale": "Full `default`-config test split.",
        "think": False,
        "id_field": "unique_id",
        "builder": _jsonschema_prompt,
    },
}


def _records(key: str) -> list[dict]:
    """Materialize the canonical-ordered prompt records for one dataset."""
    from datasets import load_dataset  # imported lazily so --self-test needs no net

    spec = REGISTRY[key]
    builder: Callable[[dict], str] = spec["builder"]
    id_field = spec["id_field"]
    out: list[dict] = []
    seq = 0
    for split in spec["splits"]:
        ds = load_dataset(
            spec["hf_repo"], spec["config"], split=split, revision=spec["revision"]
        )
        for row in ds:
            prompt = builder(row)
            if not prompt:
                # A structurally empty prompt is a data bug to surface, never a
                # silent skip that would change the count.
                raise ValueError(f"{key}: empty prompt at split={split} seq={seq}")
            rid = str(row[id_field]) if id_field else f"{split}-{seq}"
            out.append(
                {
                    "id": rid,
                    "prompt": prompt,
                    "category": spec["category"],
                    "think": spec["think"],
                }
            )
            seq += 1
    return out


def _emit_bytes(records: list[dict]) -> bytes:
    """Deterministic JSONL bytes: fixed key order, no trailing whitespace."""
    lines = []
    for r in records:
        lines.append(
            json.dumps(
                {
                    "id": r["id"],
                    "prompt": r["prompt"],
                    "category": r["category"],
                    "think": r["think"],
                },
                ensure_ascii=True,
                separators=(",", ":"),
                sort_keys=True,
            )
        )
    return ("\n".join(lines) + "\n").encode("utf-8")


def _load_lock() -> dict:
    if LOCK_PATH.exists():
        return json.loads(LOCK_PATH.read_text())
    return {
        "_about": (
            "Pinned PUBLIC datasets for the spec-decode benefit matrix (#652). "
            "Regenerate with Scripts/benchmark/prep_<key>.sh. content_sha256 is "
            "the no-cherrypick proof: re-emission of the pinned revision must "
            "reproduce count + hash."
        ),
        "datasets": {},
    }


def _write_lock(lock: dict) -> None:
    LOCK_PATH.write_text(json.dumps(lock, indent=2, sort_keys=True) + "\n")


def emit(key: str) -> dict:
    """Materialize + hash one dataset, updating the lock. Returns its entry."""
    if key not in REGISTRY:
        raise SystemExit(f"unknown dataset {key!r}; known: {sorted(REGISTRY)}")
    spec = REGISTRY[key]
    records = _records(key)
    DATA_DIR.mkdir(parents=True, exist_ok=True)
    blob = _emit_bytes(records)
    (DATA_DIR / f"{key}.jsonl").write_bytes(blob)
    entry = {
        "hf_repo": spec["hf_repo"],
        "revision": spec["revision"],
        "config": spec["config"],
        "splits": spec["splits"],
        "category": spec["category"],
        "license": spec["license"],
        "citation": spec["citation"],
        "bound": spec["bound"],
        "bound_rationale": spec["bound_rationale"],
        "think": spec["think"],
        "count": len(records),
        "content_sha256": hashlib.sha256(blob).hexdigest(),
    }
    lock = _load_lock()
    lock["datasets"][key] = entry
    _write_lock(lock)
    print(
        f"[prep] {key}: {entry['count']} prompts -> data/{key}.jsonl "
        f"sha256={entry['content_sha256'][:16]}… (locked)"
    )
    return entry


def verify() -> int:
    """Re-emit every locked dataset; fail on any count/hash drift."""
    lock = _load_lock()
    locked = lock.get("datasets", {})
    if not locked:
        print("[verify] no datasets locked yet — run prep first.", file=sys.stderr)
        return 2
    bad = []
    for key, want in sorted(locked.items()):
        records = _records(key)
        blob = _emit_bytes(records)
        got_sha = hashlib.sha256(blob).hexdigest()
        ok = len(records) == want["count"] and got_sha == want["content_sha256"]
        flag = "OK" if ok else "DRIFT"
        print(
            f"[verify] {key}: count={len(records)} (want {want['count']}) "
            f"sha256={got_sha[:16]}… (want {want['content_sha256'][:16]}…) {flag}"
        )
        if not ok:
            bad.append(key)
    if bad:
        print(f"[verify] FAIL: reproduction drift for {bad}", file=sys.stderr)
        return 1
    print(f"[verify] PASS: {len(locked)} datasets reproduce count + hash.")
    return 0


def _main(argv: list[str]) -> int:
    if len(argv) < 2:
        print(__doc__)
        return 2
    cmd = argv[1]
    if cmd == "emit":
        if len(argv) != 3:
            raise SystemExit("usage: prep_datasets.py emit <key>")
        emit(argv[2])
        return 0
    if cmd == "emit-all":
        for key in REGISTRY:
            emit(key)
        return 0
    if cmd == "verify":
        return verify()
    if cmd == "keys":
        print(" ".join(REGISTRY))
        return 0
    raise SystemExit(f"unknown command {cmd!r}")


if __name__ == "__main__":
    sys.exit(_main(sys.argv))
