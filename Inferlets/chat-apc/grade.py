"""Deterministic per-dataset graders for the ToT accuracy matrix (#657).

The #652 spec-decode matrix measured throughput only. #657 adds a graded
CORRECTNESS axis: for each prompt, does the model's final answer actually solve
the task? The datasets here are chosen precisely because they are gradable
WITHOUT a judge model — every verdict is a deterministic function of the model
output and the dataset's own ground truth (the `reference` field emitted by
`Scripts/benchmark/prep_datasets.py`), so the accuracy numbers are reproducible
and free of LLM-as-judge noise:

  * gsm8k_numeric      — numeric exact-match of the final number vs the gold
                         `#### N` answer.
  * humaneval_exec     — pass@1 by executing the shipped `check(entry_point)`.
  * mbpp_exec          — pass@1 by running the shipped assert(s) after setup.
  * jsonschema_validate — the emitted JSON validates against the gold schema.
  * mcq_numeric        — numeric choice exact-match for multiple-choice tasks.

CODE EXECUTION WARNING: `humaneval_exec`/`mbpp_exec` execute model-generated
Python in a subprocess with a wall-clock timeout. This is intrinsic to code
benchmarks (the reference HumanEval/MBPP harnesses do the same) and is why the
accuracy bench is operator-gated, never CI. The CI self-test only ever execs the
trusted fixtures in `tot_accuracy_real_test.py`.

Each grader returns a `GradeResult(passed, detail)`; `passed is None` marks an
ungradable/measurement error (e.g. empty model output), which the harness keeps
separate from a genuine wrong answer so accuracy isn't silently deflated.
"""
from __future__ import annotations

import json
import os
import re
import resource
import signal
import subprocess
import sys
import tempfile
from dataclasses import dataclass
from pathlib import Path
from typing import Callable

# Per-task wall-clock cap for executed candidate code (s). Generous enough for
# the trivial HumanEval/MBPP solutions, short enough that a hung/inf-loop
# candidate is graded as a fail rather than wedging the run.
EXEC_TIMEOUT_S = float(os.environ.get("EXEC_TIMEOUT_S", "6"))
# Hard caps for a single candidate process (defence in depth — these graders
# execute MODEL-GENERATED code). CPU seconds bound a busy loop even if wall-clock
# timing is contended; RLIMIT_AS caps address space (a runaway allocation);
# RLIMIT_NPROC caps processes per uid (a fork bomb). All best-effort: a platform
# that rejects a limit (macOS sometimes ENOSYS on RLIMIT_AS) skips it.
EXEC_CPU_SECONDS = int(os.environ.get("EXEC_CPU_SECONDS", "10"))
EXEC_ADDRSPACE_BYTES = int(os.environ.get("EXEC_ADDRSPACE_BYTES", str(2 * 1024**3)))
EXEC_MAX_PROCS = int(os.environ.get("EXEC_MAX_PROCS", "64"))


@dataclass
class GradeResult:
    passed: bool | None  # True=correct, False=wrong, None=ungradable (not a wrong answer)
    detail: str


# --- text extraction -------------------------------------------------------

_FENCE_RE = re.compile(r"```(?:[a-zA-Z0-9_+-]*)\n(.*?)```", re.DOTALL)
# A signed integer or decimal, optionally with thousands separators ("1,024").
_NUMBER_RE = re.compile(r"-?\d[\d,]*(?:\.\d+)?")


def extract_code(text: str) -> str:
    """Return the code to run: the first fenced block if the model fenced its
    answer, else the raw text (many models emit bare code on a code prompt)."""
    blocks = _FENCE_RE.findall(text)
    if blocks:
        # Prefer the first block; greedy concatenation would glue prose between
        # multiple blocks into the program.
        return blocks[0]
    return text


def last_number(text: str) -> str | None:
    """The final numeric token in the text, comma-separators stripped. GSM8K
    answers put the result last ("… so the answer is 18"), so the last number is
    the convention used by the reference eval."""
    matches = _NUMBER_RE.findall(text)
    if not matches:
        return None
    return matches[-1].replace(",", "")


def extract_json(text: str) -> str | None:
    """Best-effort: the first balanced JSON object/array in the text. Strips a
    code fence first, then scans for the first `{`/`[` and returns through its
    matching close, so trailing prose ("Here is the JSON: {…}. Hope it helps!")
    does not break parsing."""
    candidate = extract_code(text).strip()
    start = min(
        (i for i in (candidate.find("{"), candidate.find("[")) if i != -1),
        default=-1,
    )
    if start == -1:
        return None
    open_ch = candidate[start]
    close_ch = "}" if open_ch == "{" else "]"
    depth = 0
    in_str = False
    esc = False
    for i in range(start, len(candidate)):
        ch = candidate[i]
        if in_str:
            if esc:
                esc = False
            elif ch == "\\":
                esc = True
            elif ch == '"':
                in_str = False
            continue
        if ch == '"':
            in_str = True
        elif ch == open_ch:
            depth += 1
        elif ch == close_ch:
            depth -= 1
            if depth == 0:
                return candidate[start:i + 1]
    return None


def _import_lines(prompt: str) -> str:
    """Leading `import`/`from … import` lines of a HumanEval prompt, so a model
    that re-emitted a standalone function still gets the prompt's imports."""
    out = []
    for line in prompt.splitlines():
        s = line.strip()
        if s.startswith("import ") or s.startswith("from "):
            out.append(line)
    return "\n".join(out)


# --- code execution --------------------------------------------------------
#
# These graders execute MODEL-GENERATED code. Isolation is layered:
#   1. macOS Seatbelt (`sandbox-exec`): deny-by-default, allow file-READS (the
#      stdlib + interpreter), allow file-WRITES ONLY under the throwaway work
#      dir, and DENY network. This is what stops a destructive candidate —
#      `rm -rf ~`, writing system files, network exfil — none of which can touch
#      anything outside the work dir. Verified: a candidate's `rm`/HOME-write is
#      EPERM'd while ordinary compute runs.
#   2. Its own process GROUP (setsid) so a timeout kills the candidate AND any
#      grandchildren it forked (plain subprocess timeout leaks them).
#   3. setrlimit CPU / address-space / nproc — a busy loop, runaway allocation,
#      or fork bomb is bounded even within the wall-clock window.
#   4. `-I` isolated interpreter + a throwaway cwd.
# If `sandbox-exec` is unavailable the candidate is NOT run unsandboxed by
# default — it is reported ungradable (None) — unless EXEC_ALLOW_UNSANDBOXED=1
# is set for a known-trusted context.

_SANDBOX_EXEC = "/usr/bin/sandbox-exec"


def _sandbox_profile(workdir_real: str) -> str:
    """Seatbelt: deny default; allow reads + interpreter exec; writes ONLY in the
    work dir; no network. workdir must be the REAL path (/private/tmp/…) — macOS
    resolves symlinks before matching, so a /tmp subpath would never match."""
    return (
        "(version 1)\n"
        "(deny default)\n"
        "(allow process-fork)\n"
        "(allow process-exec*)\n"
        "(allow signal (target self))\n"
        "(allow sysctl-read)\n"
        "(allow mach-lookup)\n"
        "(allow file-read*)\n"
        f'(allow file-write* (subpath "{workdir_real}") (literal "/dev/null"))\n'
        "(deny network*)\n"
    )


def _rlimits():
    """Child-side hard caps (best-effort; a platform that rejects one skips it),
    plus its own session/process-group so a timeout reaps the whole subtree."""
    os.setsid()
    for res, val in ((resource.RLIMIT_CPU, EXEC_CPU_SECONDS),
                     (resource.RLIMIT_AS, EXEC_ADDRSPACE_BYTES),
                     (getattr(resource, "RLIMIT_NPROC", None), EXEC_MAX_PROCS)):
        if res is None:
            continue
        try:
            resource.setrlimit(res, (val, val))
        except (ValueError, OSError):
            pass


def run_program(program: str, timeout: float = EXEC_TIMEOUT_S) -> tuple[bool | None, str]:
    """Execute MODEL-GENERATED `program` under Seatbelt + a process group +
    rlimits (see module note). Returns (passed, detail): True on clean exit 0; an
    assertion failure / exception / timeout is a graded FAIL (False, as the
    reference benchmarks score it); a harness/sandbox problem is None
    (ungradable — never scored as a wrong answer)."""
    sandboxed = os.path.exists(_SANDBOX_EXEC)
    if not sandboxed and os.environ.get("EXEC_ALLOW_UNSANDBOXED") != "1":
        return None, "sandbox-exec unavailable; refusing to run untrusted code"
    workdir = Path(tempfile.mkdtemp(prefix="codeexec-")).resolve()
    path = workdir / "candidate.py"
    path.write_text(program, encoding="utf-8")
    if sandboxed:
        cmd = [_SANDBOX_EXEC, "-p", _sandbox_profile(str(workdir)),
               sys.executable, "-I", str(path)]
    else:
        cmd = [sys.executable, "-I", str(path)]
    proc = None
    try:
        proc = subprocess.Popen(
            cmd, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True,
            cwd=str(workdir), preexec_fn=_rlimits,
        )
        try:
            out, err = proc.communicate(timeout=timeout)
        except subprocess.TimeoutExpired:
            _kill_group(proc)
            return False, f"timeout >{timeout}s"
        if proc.returncode == 0:
            return True, "exit 0"
        tail = (err or out or "").strip().splitlines()
        return False, (tail[-1] if tail else f"exit {proc.returncode}")
    except Exception as e:  # noqa: BLE001
        if proc is not None:
            _kill_group(proc)
        return None, f"exec error: {e}"
    finally:
        import shutil
        shutil.rmtree(workdir, ignore_errors=True)


def _kill_group(proc) -> None:
    """SIGKILL the candidate's whole process group (it called setsid), reaping
    any grandchildren it forked, then reap the zombie."""
    try:
        os.killpg(os.getpgid(proc.pid), signal.SIGKILL)
    except (ProcessLookupError, PermissionError):
        pass
    try:
        proc.wait(timeout=5)
    except Exception:  # noqa: BLE001
        pass


# --- graders ---------------------------------------------------------------


def gsm8k_numeric(output: str, reference: dict) -> GradeResult:
    gold = reference["final_answer"]
    got = last_number(output or "")
    if got is None:
        return GradeResult(None, "no number in model output")
    try:
        ok = abs(float(got) - float(gold)) < 1e-6
    except ValueError:
        ok = got.strip() == str(gold).strip()
    return GradeResult(ok, f"got={got!r} gold={gold!r}")


def _answer_tail(text: str) -> str:
    """Prefer the answer text after a think block when present; otherwise use text."""
    marker = "</think>"
    if marker in text:
        return text.rsplit(marker, 1)[-1]
    return text


def mcq_numeric(output: str, reference: dict) -> GradeResult:
    gold = str(reference["final_answer"]).strip()
    choice_count = int(reference.get("choice_count", 4))
    tail = _answer_tail(output or "")
    got = last_number(tail)
    if got is None:
        return GradeResult(None, "no numeric choice in model output")
    try:
        choice = int(got)
    except ValueError:
        return GradeResult(None, f"non-integer numeric choice got={got!r}")
    if choice < 1 or choice > choice_count:
        return GradeResult(
            None, f"numeric choice got={got!r} outside 1..{choice_count}"
        )
    ok = str(choice) == gold
    return GradeResult(ok, f"got={got!r} gold={gold!r}")


def humaneval_exec(output: str, reference: dict) -> GradeResult:
    if not (output or "").strip():
        return GradeResult(None, "empty model output")
    code = extract_code(output)
    entry = reference["entry_point"]
    canonical = reference["canonical_prompt"]
    if f"def {entry}" in code:
        # Model re-emitted the whole function; keep the prompt's imports.
        body = f"{_import_lines(canonical)}\n{code}"
    else:
        # Model emitted just the body; continue the prompt's signature.
        body = f"{canonical}{code}"
    program = f"{body}\n\n{reference['test']}\n\ncheck({entry})\n"
    passed, detail = run_program(program)
    return GradeResult(passed, detail)


def mbpp_exec(output: str, reference: dict) -> GradeResult:
    if not (output or "").strip():
        return GradeResult(None, "empty model output")
    code = extract_code(output)
    setup = reference.get("test_setup_code") or ""
    asserts = "\n".join(reference["test_list"])
    program = f"{code}\n\n{setup}\n\n{asserts}\n"
    passed, detail = run_program(program)
    return GradeResult(passed, detail)


def jsonschema_validate(output: str, reference: dict) -> GradeResult:
    raw = extract_json(output or "")
    if raw is None:
        return GradeResult(None, "no JSON object/array in model output")
    try:
        instance = json.loads(raw)
    except json.JSONDecodeError as e:
        return GradeResult(False, f"invalid JSON: {e}")
    try:
        schema = json.loads(reference["json_schema"])
    except json.JSONDecodeError as e:
        # A malformed gold schema is a measurement error, not a wrong answer.
        return GradeResult(None, f"gold schema unparseable: {e}")
    try:
        import jsonschema
        from jsonschema.validators import validator_for
    except ImportError as e:  # noqa: BLE001
        return GradeResult(None, f"jsonschema unavailable: {e}")
    try:
        cls = validator_for(schema)
        cls.check_schema(schema)
        cls(schema).validate(instance)
    except jsonschema.exceptions.SchemaError as e:
        return GradeResult(None, f"gold schema invalid: {e.message}")
    except jsonschema.exceptions.ValidationError as e:
        return GradeResult(False, f"does not validate: {e.message}")
    return GradeResult(True, "validates")


GRADERS: dict[str, Callable[[str, dict], GradeResult]] = {
    "gsm8k_numeric": gsm8k_numeric,
    "mcq_numeric": mcq_numeric,
    "humaneval_exec": humaneval_exec,
    "mbpp_exec": mbpp_exec,
    "jsonschema_validate": jsonschema_validate,
}


def grade(grader: str, output: str, reference: dict) -> GradeResult:
    """Dispatch to the named grader. Unknown grader is a hard error (a typo in
    the lock must not silently score everything as wrong)."""
    if grader not in GRADERS:
        raise KeyError(f"unknown grader {grader!r}; known: {sorted(GRADERS)}")
    return GRADERS[grader](output, reference)
