"""The golden mining test set — the D-5 quality-gate substrate (plan §3.4 item 4).

Seeded scorecard fixtures with KNOWN-CORRECT outcomes, plus a recorded 14B proposal
whose candidates are engineered to exercise every harness stage. This is the substrate
the dormancy flag (D-5) gates on: the miner does not surface candidates to the operator
until this gate measures acceptable. It is deliberately hermetic — the fixtures are
materialised from the constants below into a temp dir at gate time, so the byte-match
check runs against exactly the bytes the recorded quotes were drawn from (no file/quote
drift), and the gate needs no GPU and no network.

The five required seeded kills (spec §3.4 + the LA's negate-by-append addition) all fire
here: a non-recurrent candidate (dies at recurrence), a forbidden-class candidate (dies at
the forbidden lint, reported as dropped), a paraphrase-drift candidate (dies at the
byte-match check), a negate-by-append candidate (dies at the removals lint), plus a
non-novel and a schema-malformed candidate for coverage — against one genuinely-good
candidate that must SURVIVE.
"""

from __future__ import annotations

import json
import tempfile
from dataclasses import dataclass
from pathlib import Path
from typing import Any

from lm_config import MinerConfig
from lm_harness import (
    Harness, HarnessResult, STAGE_BYTE_MATCH, STAGE_FORBIDDEN, STAGE_NOVELTY,
    STAGE_RECURRENCE, STAGE_REMOVALS, STAGE_SCHEMA,
)
from lm_ingest import ingest_runs

# --- seeded evidence lines (the single source of truth for both files + quotes) -------
# file-at-root failure (the SURVIVOR's evidence) — one verbatim line per run G1/G2/G3.
EV_ROOT_G1 = "slugify-phrase.js was created at the project root; the src/ entrypoint import could not resolve it"
EV_ROOT_G2 = "unit-converter.js landed in the repo root instead of src/, so the entrypoint import failed"
EV_ROOT_G3 = "password-generator.js was written to the project top level, not the src/ folder the contract named"

# blocking-foreground-server failure (NON-RECURRENT candidate's evidence) — only 2 runs.
EV_BLOCK_G4 = "the build stalled waiting on a foreground server command that never returned"
EV_BLOCK_G5 = "a blocking start command ran in the foreground and the whole run timed out"

# whole-file-rewrite failure (NEGATE-BY-APPEND candidate's evidence) — 3 runs.
EV_REWRITE_G1 = "the coder rewrote the entire file to change one line, producing a 300-line diff"
EV_REWRITE_G2 = "a full-module rewrite replaced five lines and churned 280 unrelated ones"
EV_REWRITE_G3 = "instead of a small edit the model re-emitted the whole module verbatim"

# self-report failure (NON-NOVEL candidate's evidence — duplicates LESSONS §1) — 3 runs.
EV_SELF_G1 = "the model claimed the tests passed but no test command was ever run"
EV_SELF_G2 = "it reported the edit applied though the file was unchanged on disk"
EV_SELF_G3 = "a compliance claim was made without any measurement to back it"

# transient-flake failure (FORBIDDEN candidate's evidence — its DELTA touches the secret scan) — 3 runs.
EV_FLAKE_G1 = "a first-attempt failure cleared cleanly on a single re-run with no code change"
EV_FLAKE_G2 = "the same task passed on retry after a transient tool no-op on the first pass"
EV_FLAKE_G3 = "an intermittent step error resolved itself when the wave was re-run once"


def _scorecard(run_id: str, repo: str, verdict: str, attribution: str, goal: str) -> dict[str, Any]:
    return {
        "schema": "m2-scorecard/v1",
        "run_id": run_id,
        "plan_id": run_id,
        "goal": goal,
        "repo": repo,
        "verdict": verdict,
        "attribution": attribution,
        "cancelled": False,
        "degraded": False,
        "tasks": [{"id": "t1", "status": "merged", "result": "MERGED"}],
        "waves": [{"wave": 1, "status": "passed", "evidence": "verify=pass; tests=pass"}],
    }


# run_id -> (repo, verdict, attribution, [journal evidence lines])
_FIXTURE_RUNS: dict[str, tuple[str, str, str, list[str]]] = {
    "20260701-000001-gd": ("battery-alpha", "PARKED-HONEST", "BUILD",
                            [EV_ROOT_G1, EV_REWRITE_G1, EV_SELF_G1, EV_FLAKE_G1]),
    "20260702-000002-gd": ("battery-bravo", "GREEN", "BUILD",
                            [EV_ROOT_G2, EV_REWRITE_G2, EV_SELF_G2, EV_FLAKE_G2]),
    "20260703-000003-gd": ("battery-charlie", "PARKED-HONEST", "SPEC",
                            [EV_ROOT_G3, EV_REWRITE_G3, EV_SELF_G3, EV_FLAKE_G3]),
    "20260704-000004-gd": ("battery-alpha", "PARKED-HONEST", "BUILD", [EV_BLOCK_G4]),
    "20260705-000005-gd": ("battery-delta", "GREEN", "BUILD", [EV_BLOCK_G5]),
}


def materialize_fixtures(root: Path) -> Path:
    """Write the seeded run dirs under ``root/state/fleet-runs`` and return that dir."""
    runs_dir = root / "state" / "fleet-runs"
    for run_id, (repo, verdict, attribution, ev_lines) in _FIXTURE_RUNS.items():
        run_dir = runs_dir / run_id
        run_dir.mkdir(parents=True, exist_ok=True)
        goal = f"seeded golden fixture goal for {repo}"
        (run_dir / "scorecard.json").write_text(
            json.dumps(_scorecard(run_id, repo, verdict, attribution, goal), indent=2),
            encoding="utf-8",
        )
        journal = "JOURNAL " + run_id + "\n" + "\n".join(ev_lines) + "\n"
        (run_dir / "journal.log").write_text(journal, encoding="utf-8")
        (run_dir / "JOB_SUMMARY.txt").write_text(
            f"JOB {run_id} — {goal}\nverdict: {verdict} (attribution: {attribution})\n",
            encoding="utf-8",
        )
    return runs_dir


def _ev(run_id: str, quote: str, artifact: str = "journal.log") -> dict[str, str]:
    return {"run_id": run_id, "artifact": artifact, "quote": quote}


# The recorded 14B proposal. Each candidate is engineered to land at a known stage.
RECORDED_CANDIDATES: list[dict[str, Any]] = [
    # C1 — SURVIVOR: recurring file-at-root failure across 3 distinct jobs/eras, verbatim
    # quotes, novel, no forbidden term, delta expressed as a pure addition (no negation).
    {
        "failure_shape": "The coder writes created source files to the project top level instead of the src/ path the contract names, so the entrypoint's src/ import fails to resolve.",
        "evidence": [
            _ev("20260701-000001-gd", EV_ROOT_G1),
            _ev("20260702-000002-gd", EV_ROOT_G2),
            _ev("20260703-000003-gd", EV_ROOT_G3),
        ],
        "proposed_delta": (
            "--- a/AGENTS.md\n+++ b/AGENTS.md\n@@ rules @@\n"
            "+ - Create each source file at the path the task contract names (e.g. `src/NAME.js`) "
            "so the entrypoint's `src/` import resolves; a file placed at the project top level "
            "will fail to import."
        ),
        "rationale": "Three independent battery jobs parked on an entrypoint that imports from src/ while the coder wrote the file to the top level.",
    },
    # C2 — NON-RECURRENT: only 2 distinct runs -> dies at recurrence.
    {
        "failure_shape": "The coder runs a blocking foreground server command and the run stalls until it is killed.",
        "evidence": [
            _ev("20260704-000004-gd", EV_BLOCK_G4),
            _ev("20260705-000005-gd", EV_BLOCK_G5),
        ],
        "proposed_delta": "--- a/AGENTS.md\n+++ b/AGENTS.md\n@@ rules @@\n+ - Never block on a foreground server; tell the user the command to run.",
        "rationale": "Two runs stalled on a foreground server.",
    },
    # C3 — FORBIDDEN-CLASS: the DELTA proposes weakening the secret scan -> dies at forbidden.
    {
        "failure_shape": "Transient first-attempt flakes fail a wave that a single re-run would clear, wasting a whole pass.",
        "evidence": [
            _ev("20260701-000001-gd", EV_FLAKE_G1),
            _ev("20260702-000002-gd", EV_FLAKE_G2),
            _ev("20260703-000003-gd", EV_FLAKE_G3),
        ],
        "proposed_delta": "--- a/AGENTS.md\n+++ b/AGENTS.md\n@@ rules @@\n+ - Skip the secret scan when the diff only touches test fixtures, to avoid transient blocks.",
        "rationale": "Re-runs cleared these; but the proposed fix would weaken a security control.",
    },
    # C4 — PARAPHRASE-DRIFT: the quote is altered ("at"->"in", "src/ entrypoint"->"entrypoint") -> byte-match kill.
    {
        "failure_shape": "The coder writes files to the wrong directory.",
        "evidence": [
            _ev("20260701-000001-gd", "slugify-phrase.js was created in the project root; the entrypoint import could not resolve it"),
            _ev("20260702-000002-gd", EV_ROOT_G2),
            _ev("20260703-000003-gd", EV_ROOT_G3),
        ],
        "proposed_delta": "--- a/AGENTS.md\n+++ b/AGENTS.md\n@@ rules @@\n+ - Put files where the contract says.",
        "rationale": "Paraphrased evidence — this one is not verbatim.",
    },
    # C5 — NEGATE-BY-APPEND: the delta appends a negation of an existing rule with no deletion -> removals lint.
    {
        "failure_shape": "The coder rewrites whole modules for a one-line change, producing large noisy diffs that are hard to review.",
        "evidence": [
            _ev("20260701-000001-gd", EV_REWRITE_G1),
            _ev("20260702-000002-gd", EV_REWRITE_G2),
            _ev("20260703-000003-gd", EV_REWRITE_G3),
        ],
        "proposed_delta": "--- a/AGENTS.md\n+++ b/AGENTS.md\n@@ rules @@\n+ - Do not prefer edit over rewriting whole files any longer; just rewrite the file each time.",
        "rationale": "Rewrites produce noisy diffs — but this proposal negates a standing rule by appending instead of deleting it.",
    },
    # C6 — NON-NOVEL: duplicates LESSONS §1 (never trust a self-report) -> novelty kill.
    {
        "failure_shape": "Never trust the local model's self-report — verify the artifact with an objective tool every time, because it claims tests passed and edits applied when they did not.",
        "evidence": [
            _ev("20260701-000001-gd", EV_SELF_G1),
            _ev("20260702-000002-gd", EV_SELF_G2),
            _ev("20260703-000003-gd", EV_SELF_G3),
        ],
        "proposed_delta": "--- a/AGENTS.md\n+++ b/AGENTS.md\n@@ rules @@\n+ - Verify every self-reported claim against the artifact.",
        "rationale": "Already a canonical lesson.",
    },
    # C7 — SCHEMA-MALFORMED: no evidence array -> schema kill.
    {
        "failure_shape": "A candidate with no evidence at all.",
        "proposed_delta": "--- a/AGENTS.md\n+++ b/AGENTS.md\n@@ rules @@\n+ - This will never be applied.",
    },
]

# The known-correct outcome: one survivor + each drop at its named stage.
EXPECTED_SURVIVOR_MARKER = "top level instead of the src/ path"
EXPECTED_DROP_STAGES: dict[str, str] = {
    "blocking foreground server": STAGE_RECURRENCE,
    "Transient first-attempt flakes": STAGE_FORBIDDEN,
    "writes files to the wrong directory": STAGE_BYTE_MATCH,
    "rewrites whole modules": STAGE_REMOVALS,
    "Never trust the local model": STAGE_NOVELTY,
    "no evidence at all": STAGE_SCHEMA,
}


@dataclass(frozen=True)
class GoldenResult:
    """The gate outcome: whether it passed + per-check detail lines."""

    ok: bool
    checks: list[tuple[bool, str]]
    harness: HarnessResult

    def summary(self) -> str:
        lines = [("PASS" if ok else "FAIL") + "  " + msg for ok, msg in self.checks]
        return "\n".join(lines)


def run_golden_gate(*, lessons_text: str, agents_text: str) -> GoldenResult:
    """Materialise the fixtures, run the harness over the recorded proposal, and grade.

    Requires the REAL ``LESSONS-LEARNED.md`` + ``AGENTS.md`` text (so the novelty and
    removals-lint checks are graded against the actual curated surfaces, not a toy
    copy) — that is what makes this a genuine quality gate rather than a mock.
    """
    with tempfile.TemporaryDirectory(prefix="lesson-miner-golden-") as tmp:
        root = Path(tmp)
        runs_dir = materialize_fixtures(root)
        runs = ingest_runs(runs_dir)
        config = MinerConfig.for_repo(root)
        harness = Harness(config, runs, lessons_text=lessons_text,
                          prior_candidates_text="", agents_text=agents_text)
        result = harness.run(RECORDED_CANDIDATES)

    checks: list[tuple[bool, str]] = []

    # Exactly one survivor, and it is the file-at-root candidate.
    survived_markers = [c.failure_shape for c in result.verified]
    one_survivor = len(result.verified) == 1 and EXPECTED_SURVIVOR_MARKER in result.verified[0].failure_shape
    checks.append((one_survivor,
                   f"exactly one survivor (the file-at-root candidate); got {len(result.verified)}: {survived_markers}"))

    if one_survivor:
        surv = result.verified[0]
        checks.append((surv.recurrence_count == 3,
                       f"survivor recurrence == 3 (got {surv.recurrence_count})"))
        checks.append((surv.distinct_jobs == 3,
                       f"survivor spans 3 distinct jobs (got {surv.distinct_jobs})"))
        checks.append((len(surv.eras) == 3,
                       f"survivor spans 3 eras (got {surv.eras})"))

    # Each seeded kill landed at its expected stage.
    dropped_by_marker: dict[str, str] = {}
    for d in result.dropped:
        for marker in EXPECTED_DROP_STAGES:
            if marker in d.title or marker in d.reason:
                dropped_by_marker[marker] = d.stage
    for marker, expected_stage in EXPECTED_DROP_STAGES.items():
        got = dropped_by_marker.get(marker)
        checks.append((got == expected_stage,
                       f"'{marker}' dropped at '{expected_stage}' (got '{got}')"))

    # No silent caps: every non-survivor was recorded as a drop.
    checks.append((len(result.dropped) == len(RECORDED_CANDIDATES) - 1,
                   f"every non-survivor logged as a drop ({len(result.dropped)} of {len(RECORDED_CANDIDATES) - 1})"))

    ok = all(passed for passed, _ in checks)
    return GoldenResult(ok=ok, checks=checks, harness=result)
