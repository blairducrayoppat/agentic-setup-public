#!/usr/bin/env python3
"""Golden-set + unit tests for the fleet lesson-candidate miner (#793 M3).

Stdlib ``unittest`` (no external dependency — the fleet box is offline-first), so it
runs under either ``python -m unittest`` or ``pytest``. The centrepiece is the golden
gate (:func:`lm_golden.run_golden_gate`), the D-5 quality-gate substrate; the rest are
focused unit tests that pin each harness stage and the post-pass guard so a regression
names the exact broken control.
"""

from __future__ import annotations

import json
import os
import sys
import tempfile
import unittest
import unittest.mock
from pathlib import Path

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from lm_batch import build_run_block, chunk_runs, mine_corpus, resolve_bundle_budget
from lm_config import MinerConfig
from lm_guard import dispatch_status
from lm_golden import (
    EXPECTED_DROP_STAGES, RECORDED_CANDIDATES, materialize_fixtures, run_golden_gate,
)
from lm_harness import (
    Harness, STAGE_BYTE_MATCH, STAGE_FORBIDDEN, STAGE_NOVELTY, STAGE_RECURRENCE,
    STAGE_REMOVALS, STAGE_SCHEMA,
)
from lm_ingest import RunRecord, ingest_runs
from lm_model import OvmsGrammarClient, QueuedModelClient

_REPO_ROOT = Path(__file__).resolve().parents[2]
_LESSONS = (_REPO_ROOT / "docs" / "LESSONS-LEARNED.md").read_text(encoding="utf-8", errors="replace")
_AGENTS = (_REPO_ROOT / "configs" / "AGENTS.md").read_text(encoding="utf-8", errors="replace")


class GoldenGateTest(unittest.TestCase):
    """The D-5 quality gate: the seeded kills fire and the good candidate survives."""

    def test_golden_gate_passes(self) -> None:
        gate = run_golden_gate(lessons_text=_LESSONS, agents_text=_AGENTS)
        failed = [msg for ok, msg in gate.checks if not ok]
        self.assertTrue(gate.ok, "golden gate failed checks:\n  " + "\n  ".join(failed))

    def test_every_required_kill_is_covered(self) -> None:
        # The three spec-required kills + the LA's negate-by-append must all be asserted.
        stages = set(EXPECTED_DROP_STAGES.values())
        for required in (STAGE_RECURRENCE, STAGE_FORBIDDEN, STAGE_BYTE_MATCH, STAGE_REMOVALS):
            self.assertIn(required, stages)


class HarnessStageTest(unittest.TestCase):
    """Each stage fires in isolation, against the seeded fixtures + real curated text."""

    def setUp(self) -> None:
        self._tmp = tempfile.TemporaryDirectory(prefix="lm-stage-")
        root = Path(self._tmp.name)
        runs_dir = materialize_fixtures(root)
        self.runs = ingest_runs(runs_dir)
        self.config = MinerConfig.for_repo(root)
        self.harness = Harness(self.config, self.runs, lessons_text=_LESSONS,
                               prior_candidates_text="", agents_text=_AGENTS)

    def tearDown(self) -> None:
        self._tmp.cleanup()

    def _run_one(self, cand: dict) -> object:
        return self.harness.run([cand])

    def test_survivor_survives_alone(self) -> None:
        res = self._run_one(RECORDED_CANDIDATES[0])
        self.assertEqual(len(res.verified), 1)
        self.assertEqual(res.verified[0].recurrence_count, 3)
        self.assertEqual(res.verified[0].distinct_jobs, 3)

    def test_byte_match_kills_paraphrase(self) -> None:
        # C4 is the paraphrase-drift candidate — must die at byte-match, not later.
        res = self._run_one(RECORDED_CANDIDATES[3])
        self.assertEqual(len(res.verified), 0)
        self.assertEqual(res.dropped[0].stage, STAGE_BYTE_MATCH)

    def test_recurrence_kills_two_run_candidate(self) -> None:
        res = self._run_one(RECORDED_CANDIDATES[1])
        self.assertEqual(res.dropped[0].stage, STAGE_RECURRENCE)

    def test_forbidden_class_is_reported_as_dropped(self) -> None:
        res = self._run_one(RECORDED_CANDIDATES[2])
        self.assertEqual(len(res.verified), 0)
        self.assertEqual(res.dropped[0].stage, STAGE_FORBIDDEN)
        self.assertIn("secret scan", res.dropped[0].reason.lower())

    def test_removals_lint_kills_negate_by_append(self) -> None:
        res = self._run_one(RECORDED_CANDIDATES[4])
        self.assertEqual(res.dropped[0].stage, STAGE_REMOVALS)

    def test_novelty_kills_duplicate_lesson(self) -> None:
        res = self._run_one(RECORDED_CANDIDATES[5])
        self.assertEqual(res.dropped[0].stage, STAGE_NOVELTY)

    def test_schema_kills_malformed(self) -> None:
        res = self._run_one(RECORDED_CANDIDATES[6])
        self.assertEqual(res.dropped[0].stage, STAGE_SCHEMA)

    def test_no_silent_caps(self) -> None:
        # Every non-survivor across the whole set is recorded as a drop.
        res = self.harness.run(RECORDED_CANDIDATES)
        self.assertEqual(len(res.verified) + len(res.dropped), len(RECORDED_CANDIDATES))

    def test_removals_lint_allows_genuine_deletion(self) -> None:
        # A delta that DELETES the rule it changes (a '-' line) must NOT trip the lint.
        cand = dict(RECORDED_CANDIDATES[4])
        cand["proposed_delta"] = (
            "--- a/AGENTS.md\n+++ b/AGENTS.md\n@@ rules @@\n"
            "- Prefer edit over rewriting whole files.\n"
            "+ - Rewrite the whole file when a change touches most of it."
        )
        res = self._run_one(cand)
        # It should now survive the removals lint (it may still pass everything -> verified).
        self.assertTrue(all(d.stage != STAGE_REMOVALS for d in res.dropped),
                        "genuine deletion wrongly flagged by removals lint")


class GuardTest(unittest.TestCase):
    """The post-pass guard refuses during a live dispatch and permits a post-pass window."""

    def _write(self, obj: object) -> Path:
        d = tempfile.mkdtemp(prefix="lm-guard-")
        p = Path(d) / "current.json"
        p.write_text(json.dumps(obj), encoding="utf-8")
        return p

    def test_missing_file_is_not_live(self) -> None:
        p = Path(tempfile.mkdtemp(prefix="lm-guard-")) / "absent.json"
        self.assertFalse(dispatch_status(p).live)

    def test_recovered_phase_is_post_pass(self) -> None:
        p = self._write({"run_id": "r1", "phase": "RECOVERED", "driver_pid": 0})
        self.assertFalse(dispatch_status(p).live)

    def test_active_phase_is_live(self) -> None:
        p = self._write({"run_id": "r1", "phase": "CODE", "driver_pid": 0})
        self.assertTrue(dispatch_status(p).live)

    def test_failed_phase_is_not_live(self) -> None:
        p = self._write({"run_id": "r1", "phase": "FAILED", "driver_pid": 0})
        self.assertFalse(dispatch_status(p).live)

    def test_unparseable_state_refuses(self) -> None:
        d = tempfile.mkdtemp(prefix="lm-guard-")
        p = Path(d) / "current.json"
        p.write_text("{ not json", encoding="utf-8")
        self.assertTrue(dispatch_status(p).live)

    def test_no_run_id_is_not_live(self) -> None:
        p = self._write({"phase": "CODE"})
        self.assertFalse(dispatch_status(p).live)


def _mk_run(run_id: str, date: str, repo: str, journal: str) -> RunRecord:
    return RunRecord(
        run_id=run_id, date=date, verdict="GREEN", attribution="BUILD", repo=repo,
        goal="g", degraded=False, cancelled=False, scorecard={}, guest_oracle={},
        sources={"journal.log": journal},
    )


# A recurring shape whose evidence is split ACROSS batches. Novel vs LESSONS, no forbidden
# term, delta is a pure addition — so it survives IF the merge counts recurrence corpus-wide.
_EV = {
    "r1": "the CLI printed its usage help to stderr, so a pipe captured nothing",
    "r2": "help text went to stderr again; redirecting stdout produced an empty file",
    "r3": "usage was emitted on stderr, breaking the shell pipeline that read stdout",
    "r4": "the tool wrote its help banner to stderr rather than stdout once more",
}
_SHAPE = ("The generated command-line tool prints its usage/help text to stderr instead "
          "of stdout, so piping or capturing the output loses it.")
_DELTA = ("--- a/AGENTS.md\n+++ b/AGENTS.md\n@@ rules @@\n"
          "+ - Print usage/help text to stdout so it can be piped and captured.")


def _shape_candidate(quotes: dict[str, str]) -> dict:
    return {
        "failure_shape": _SHAPE,
        "evidence": [{"run_id": rid, "artifact": "journal.log", "quote": q}
                     for rid, q in quotes.items()],
        "proposed_delta": _DELTA,
        "rationale": "help-to-stderr recurs across the corpus.",
    }


class ChunkedMiningTest(unittest.TestCase):
    """The #793 fix: recurrence/diversity count ACROSS batches, not per batch."""

    def setUp(self) -> None:
        self.runs = [
            _mk_run("20260701-000001-cd", "2026-07-01", "proj-a", f"J1\n{_EV['r1']}\n"),
            _mk_run("20260702-000002-cd", "2026-07-02", "proj-b", f"J2\n{_EV['r2']}\n"),
            _mk_run("20260703-000003-cd", "2026-07-03", "proj-c", f"J3\n{_EV['r3']}\n"),
            _mk_run("20260704-000004-cd", "2026-07-04", "proj-d", f"J4\n{_EV['r4']}\n"),
        ]
        self.config = MinerConfig.for_repo(Path("/nonexistent"))
        self.harness = Harness(self.config, self.runs, lessons_text=_LESSONS,
                               prior_candidates_text="", agents_text=_AGENTS)

    def test_cross_batch_recurrence_merges(self) -> None:
        # Batch 1 sees runs r1,r2; batch 3 sees r3,r4 — each proposes the SAME shape citing
        # only its two runs. Merged, that is recurrence 4; per-batch it would be 2 and 2.
        batch1 = [_shape_candidate({"20260701-000001-cd": _EV["r1"], "20260702-000002-cd": _EV["r2"]})]
        batch2 = [_shape_candidate({"20260703-000003-cd": _EV["r3"], "20260704-000004-cd": _EV["r4"]})]
        client = QueuedModelClient([batch1, batch2])
        result = mine_corpus(self.harness, client, self.runs, self.config,
                             bundles=["<batch 1 text>", "<batch 2 text>"])
        self.assertEqual(client.calls, 2, "one model call per batch")
        self.assertEqual(len(result.verified), 1, "the two half-proposals merged into one")
        self.assertEqual(result.verified[0].recurrence_count, 4, "recurrence counted across batches")

    def test_per_batch_alone_would_be_killed(self) -> None:
        # Proof the merge is load-bearing: either half alone recurs only twice -> dropped.
        half = _shape_candidate({"20260701-000001-cd": _EV["r1"], "20260702-000002-cd": _EV["r2"]})
        res = self.harness.run([half])
        self.assertEqual(len(res.verified), 0)
        self.assertEqual(res.dropped[0].stage, STAGE_RECURRENCE)


class ChunkPackingTest(unittest.TestCase):
    """chunk_runs packs to a token budget and truncates-with-log an oversized run."""

    def test_splits_into_multiple_batches(self) -> None:
        # Each run's block is small (~50 tok) and fits the budget individually; five of
        # them cannot share one batch, so they pack into >=2 batches with NO truncation.
        runs = [_mk_run(f"2026070{i}-00000{i}-cd", f"2026-07-0{i}", f"p{i}",
                        "J\nshort evidence line for this run.\n") for i in range(1, 6)]
        bundles, notes = chunk_runs(runs, bundle_budget=120, chars_per_token=3.5)
        self.assertGreaterEqual(len(bundles), 2)
        self.assertEqual(notes, [], "runs that fit individually must not be truncated")

    def test_oversized_single_run_truncated_with_log(self) -> None:
        big = _mk_run("20260701-000009-cd", "2026-07-01", "big", "J\n" + ("x" * 20000) + "\n")
        bundles, notes = chunk_runs([big], bundle_budget=200, chars_per_token=3.5)
        self.assertEqual(len(bundles), 1)
        self.assertIn("TRUNCATED", bundles[0])
        self.assertEqual(len(notes), 1)
        self.assertIn("20260701-000009-cd", notes[0])
        self.assertIn("nothing was dropped silently", notes[0])

    def test_budget_resolution_prefers_pin_then_probe_then_default(self) -> None:
        pinned = MinerConfig.for_repo(Path("/x"), batch_token_budget=5000)
        self.assertEqual(resolve_bundle_budget(pinned, probed_context=40000), 5000)
        auto = MinerConfig.for_repo(Path("/x"))
        self.assertEqual(resolve_bundle_budget(auto, probed_context=40000),
                         40000 - auto.reserved_headroom_tokens)
        self.assertEqual(resolve_bundle_budget(auto, probed_context=None),
                         auto.default_context_tokens - auto.reserved_headroom_tokens)


class _BundleMapClient:
    """A fake mapping bundle text -> candidates (call-order-independent, unlike a queue).

    Needed for resume tests: when cached batches are skipped, the model is called out of
    index order, so a queue would desync — a map keyed by bundle content does not.
    """

    def __init__(self, mapping: dict, raise_on: set | None = None) -> None:
        self.mapping = mapping
        self.raise_on = raise_on or set()
        self.calls = 0

    def propose(self, bundle: str) -> list:
        self.calls += 1
        if bundle in self.raise_on:
            raise TimeoutError("simulated socket read timeout")
        return list(self.mapping.get(bundle, []))


class _FailIfCalledClient:
    def propose(self, bundle: str) -> list:
        raise AssertionError("the model must not be called when every batch is cached")


class ResumeResilienceTest(unittest.TestCase):
    """Batch-level resume + per-batch failure isolation + progress (the timeout fix)."""

    def setUp(self) -> None:
        self.runs = [
            _mk_run("20260701-000001-cd", "2026-07-01", "proj-a", f"J1\n{_EV['r1']}\n"),
            _mk_run("20260702-000002-cd", "2026-07-02", "proj-b", f"J2\n{_EV['r2']}\n"),
            _mk_run("20260703-000003-cd", "2026-07-03", "proj-c", f"J3\n{_EV['r3']}\n"),
            _mk_run("20260704-000004-cd", "2026-07-04", "proj-d", f"J4\n{_EV['r4']}\n"),
        ]
        self.config = MinerConfig.for_repo(Path("/nonexistent"))
        self.harness = Harness(self.config, self.runs, lessons_text=_LESSONS,
                               prior_candidates_text="", agents_text=_AGENTS)
        self.mapping = {
            "B1": [_shape_candidate({"20260701-000001-cd": _EV["r1"], "20260702-000002-cd": _EV["r2"]})],
            "B2": [_shape_candidate({"20260703-000003-cd": _EV["r3"], "20260704-000004-cd": _EV["r4"]})],
        }
        self._tmp = tempfile.TemporaryDirectory(prefix="lm-resume-")
        self.work = Path(self._tmp.name) / ".work" / "2026-07-10"

    def tearDown(self) -> None:
        self._tmp.cleanup()

    def test_completed_batches_persist_and_resume_skips_the_model(self) -> None:
        run1 = mine_corpus(self.harness, _BundleMapClient(self.mapping), self.runs, self.config,
                           bundles=["B1", "B2"], work_dir=self.work)
        self.assertEqual(len(run1.verified), 1)
        self.assertEqual(run1.verified[0].recurrence_count, 4)
        self.assertTrue((self.work / "batch-00.json").exists())
        self.assertTrue((self.work / "batch-01.json").exists())
        # Rerun with a client that raises if called — proves both batches came from cache.
        run2 = mine_corpus(self.harness, _FailIfCalledClient(), self.runs, self.config,
                           bundles=["B1", "B2"], work_dir=self.work)
        self.assertEqual(run2.verified[0].recurrence_count, 4)

    def test_failed_batch_is_skipped_noted_and_retried_on_rerun(self) -> None:
        # Batch B2 times out: B1 completes+caches, B2 is skipped with a note (not cached).
        client = _BundleMapClient(self.mapping, raise_on={"B2"})
        run1 = mine_corpus(self.harness, client, self.runs, self.config,
                           bundles=["B1", "B2"], work_dir=self.work)
        self.assertTrue((self.work / "batch-00.json").exists())
        self.assertFalse((self.work / "batch-01.json").exists(), "a failed batch must not be cached")
        self.assertTrue(any("FAILED" in n and "retries" in n for n in run1.notes))
        self.assertEqual(len(run1.verified), 0, "only B1 completed -> recurrence 2 -> no survivor")
        # Rerun: B1 from cache (skipped), B2 now succeeds -> the shape reaches recurrence 4.
        client2 = _BundleMapClient(self.mapping)
        run2 = mine_corpus(self.harness, client2, self.runs, self.config,
                           bundles=["B1", "B2"], work_dir=self.work)
        self.assertEqual(client2.calls, 1, "only the previously-failed batch is recomputed")
        self.assertEqual(run2.verified[0].recurrence_count, 4)

    def test_stale_cache_is_ignored(self) -> None:
        # A cache file whose bundle_sha is for a DIFFERENT bundle must be recomputed.
        self.work.mkdir(parents=True, exist_ok=True)
        (self.work / "batch-00.json").write_text(
            json.dumps({"bundle_sha": "deadbeef", "candidates": []}), encoding="utf-8")
        client = _BundleMapClient(self.mapping)
        result = mine_corpus(self.harness, client, self.runs, self.config,
                             bundles=["B1", "B2"], work_dir=self.work)
        self.assertEqual(client.calls, 2, "the stale batch-00 must be recomputed, not trusted")
        self.assertEqual(result.verified[0].recurrence_count, 4)

    def test_progress_line_per_batch(self) -> None:
        msgs: list[str] = []
        mine_corpus(self.harness, _BundleMapClient(self.mapping), self.runs, self.config,
                    bundles=["B1", "B2"], work_dir=self.work, progress=msgs.append)
        self.assertEqual(len(msgs), 2, "one progress line per batch")
        self.assertTrue(all("batch" in m for m in msgs))


class ConfigDefaultsTest(unittest.TestCase):
    """The timeout/max-tokens defaults + override wiring (the timeout fix knobs)."""

    def test_generous_timeout_and_lower_max_tokens_defaults(self) -> None:
        cfg = MinerConfig.for_repo(Path("/x"))
        self.assertGreaterEqual(cfg.model_timeout_s, 900, "per-batch timeout must be generous")
        self.assertLessEqual(cfg.model_max_tokens, 2048, "max_tokens lowered to cut generation time")

    def test_overrides_apply(self) -> None:
        cfg = MinerConfig.for_repo(Path("/x"), model_timeout_s=3600, model_max_tokens=4096)
        self.assertEqual(cfg.model_timeout_s, 3600)
        self.assertEqual(cfg.model_max_tokens, 4096)


class ErrorBodyTest(unittest.TestCase):
    """The OVMS client surfaces the HTTP response BODY (the real 400 cause)."""

    def test_http_error_body_is_surfaced(self) -> None:
        import io
        import urllib.error
        import urllib.request

        body = b'{"error":"prompt exceeds max context length"}'
        err = urllib.error.HTTPError(
            "http://127.0.0.1:8000/v3/chat/completions", 400, "Bad Request", {},
            io.BytesIO(body),
        )

        def fake_urlopen(target, timeout=None):  # noqa: ANN001
            url = getattr(target, "full_url", target)
            if str(url).endswith("/models"):
                return io.BytesIO(json.dumps({"data": [{"id": "qwen3-14b"}]}).encode())
            raise err

        client = OvmsGrammarClient("http://127.0.0.1:8000/v3")
        with unittest.mock.patch("urllib.request.urlopen", fake_urlopen):
            with self.assertRaises(RuntimeError) as ctx:
                client.propose("some bundle")
        msg = str(ctx.exception)
        self.assertIn("400", msg)
        self.assertIn("max context length", msg, "the response body must be surfaced, not swallowed")


if __name__ == "__main__":
    unittest.main(verbosity=2)
