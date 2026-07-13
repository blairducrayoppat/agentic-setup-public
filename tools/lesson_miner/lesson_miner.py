#!/usr/bin/env python3
"""Fleet lesson-candidate miner — CLI entrypoint (#793 M3, Learning Loop 2 Stage C1).

REPORT-ONLY. Post-pass. Nothing self-modifies. One command, four modes:

    python lesson_miner.py --check
        Run the golden-set quality gate (the D-5 substrate). No GPU, no network.
        Exit 0 iff the seeded kills fire and the good candidate survives. This is
        what scripts/verify-lesson-miner.ps1 runs, and the gate the dormancy flag
        watches.

    python lesson_miner.py
        A DRY mining pass: guard -> ingest -> (no model) -> emit an empty candidates
        file. Safe to run any time in a post-pass window; proposes nothing because
        the model is not invoked (the GPU is reserved). Proves the corridor end to end.

    python lesson_miner.py --replay <envelope.json>
        Mine using a RECORDED model proposal (offline). Exercises the full harness +
        emit over real ingested runs without touching the 14B — the coordinator's
        way to reproduce or debug a pass.

    python lesson_miner.py --real
        The REAL pass — invoke the local 14B (grammar-constrained) over the ingested
        runs. THE COORDINATOR'S to run, in a scheduled GPU window (14B restored,
        post-swap). Refuses if a dispatch is live or no model is loaded.

Surfacing (the D-6 Vikunja pointer) stays DORMANT until the quality gate is proven
and the flag is flipped — a candidates file is always written; the operator channel
is not touched while dormant.
"""

from __future__ import annotations

import argparse
import json
import os
import sys
from datetime import date as _date
from pathlib import Path

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))  # sibling-module imports

from lm_batch import build_evidence_bundle, chunk_runs, mine_corpus, resolve_bundle_budget
from lm_config import MinerConfig
from lm_emit import emit
from lm_golden import run_golden_gate
from lm_guard import dispatch_status
from lm_harness import Harness, HarnessResult
from lm_ingest import ingest_runs, load_campaign_eras
from lm_model import ModelClient, OvmsGrammarClient, RecordedModelClient


def _repo_root() -> Path:
    """The agentic-setup checkout root (this file lives at <root>/tools/lesson_miner/)."""
    return Path(__file__).resolve().parents[2]


def _safe_probe_context(client: ModelClient) -> int | None:
    """Probe the served model's context length, tolerating any client/probe failure."""
    fn = getattr(client, "context_length", None)
    if fn is None:
        return None
    try:
        return fn()
    except Exception:  # noqa: BLE001 — a failed probe just falls back to the config default
        return None


def _read_text(path: Path) -> str:
    try:
        return path.read_text(encoding="utf-8", errors="replace")
    except OSError:
        return ""


def _read_prior_candidates(out_dir: Path) -> str:
    """Concatenate prior candidate files so novelty dedups against earlier passes."""
    if not out_dir.is_dir():
        return ""
    return "\n".join(_read_text(p) for p in sorted(out_dir.glob("*.md")))


def _select_model(args: argparse.Namespace, config: MinerConfig) -> ModelClient | None:
    """Pick the model layer for this pass, or None for a dry (no-model) pass."""
    if args.replay:
        envelope = json.loads(Path(args.replay).read_text(encoding="utf-8"))
        return RecordedModelClient.from_envelope(envelope)
    if args.real:
        return OvmsGrammarClient(
            config.endpoint,
            temperature=config.model_temperature,
            top_p=config.model_top_p,
            max_tokens=config.model_max_tokens,
            timeout_s=config.model_timeout_s,
        )
    return None


def run_pass(args: argparse.Namespace) -> int:
    """Execute one mining pass (dry / replay / real). Returns a process exit code."""
    root = Path(args.repo_root) if args.repo_root else _repo_root()
    overrides: dict[str, object] = {}
    if args.recurrence is not None:
        overrides["recurrence_n"] = args.recurrence
    if args.batch_tokens is not None:
        overrides["batch_token_budget"] = args.batch_tokens
    if args.request_timeout is not None:
        overrides["model_timeout_s"] = args.request_timeout
    if args.max_tokens is not None:
        overrides["model_max_tokens"] = args.max_tokens
    config = MinerConfig.for_repo(root, **overrides)
    day = args.out_date or _date.today().isoformat()

    # POST-PASS WINDOW GUARD — the miner MUST NOT run during a live dispatch.
    status = dispatch_status(config.swap_state_path)
    if status.live and not args.allow_live:
        print(f"[lesson-miner] REFUSING: {status.reason}", file=sys.stderr)
        print("[lesson-miner] The miner runs only in a post-pass window "
              "(pass --allow-live only to override deliberately).", file=sys.stderr)
        return 2
    dispatch_note = f"Post-pass guard: {status.reason}."

    runs = ingest_runs(config.fleet_runs_dir)
    load_campaign_eras(config.campaign_path)  # read for future era sharpening; annotation is date-based today
    if not runs:
        print(f"[lesson-miner] no evidence-bearing runs under {config.fleet_runs_dir}", file=sys.stderr)

    harness = Harness(
        config, runs,
        lessons_text=_read_text(config.lessons_path),
        prior_candidates_text=_read_prior_candidates(config.candidates_out_dir),
        agents_text=_read_text(config.agents_path),
    )

    client = _select_model(args, config)
    if client is None:
        # DRY pass — the model is not invoked (the GPU is reserved); proves the corridor.
        result: HarnessResult = harness.run([])
        print("[lesson-miner] DRY pass (model not invoked — GPU reserved). "
              "Use --replay <file> to mine a recorded proposal, or --real in a GPU window.")
    elif args.real:
        # REAL pass — CHUNKED + RESUMABLE: the whole-corpus bundle overflows the 14B
        # context (400); each batch on a throttled 14B can take many minutes, so persist
        # per-batch results and print a progress line as each completes.
        probed = _safe_probe_context(client)
        budget = resolve_bundle_budget(config, probed)
        bundles, _ = chunk_runs(runs, bundle_budget=budget, chars_per_token=config.chars_per_token)
        ctx_note = f"probed {probed}" if probed else f"default {config.default_context_tokens}"
        work_dir = config.candidates_out_dir / ".work" / day
        print(f"[lesson-miner] REAL pass: context {ctx_note} tok; batch budget {budget} tok; "
              f"max_tokens {config.model_max_tokens}; request timeout {config.model_timeout_s}s; "
              f"{len(bundles)} batch(es) over {len(runs)} run(s).")
        print(f"[lesson-miner] resume cache: {work_dir} (completed batches are skipped on rerun).")

        def _progress(msg: str) -> None:
            print(f"[lesson-miner] {msg}", flush=True)

        result = mine_corpus(harness, client, runs, config, probed_context=probed,
                             work_dir=work_dir, progress=_progress)
    else:
        # REPLAY — a recorded whole-corpus proposal (offline); no chunking needed.
        proposed = client.propose(build_evidence_bundle(runs))
        print(f"[lesson-miner] REPLAY: model proposed {len(proposed)} candidate(s).")
        result = harness.run(proposed)

    emitted = emit(config, result, run_count=len(runs), dispatch_note=dispatch_note,
                   pass_date=day)
    print(f"[lesson-miner] wrote {emitted.path}")
    print(f"[lesson-miner]   surviving candidates: {len(result.verified)}; dropped: {len(result.dropped)}")
    for note in result.notes:
        print(f"[lesson-miner]   note: {note}")
    for d in result.dropped:
        print(f"[lesson-miner]   dropped [{d.stage}] {d.title[:60]}: {d.reason[:80]}")
    if config.surfacing_dormant:
        print("[lesson-miner]   surfacing DORMANT — Vikunja pointer withheld (built, not posted).")
        print(f"[lesson-miner]   (pointer would read) {emitted.pointer_comment}")
    elif emitted.surfaced:
        print("[lesson-miner]   surfacing LIVE — Vikunja pointer posted.")
    return 0


def run_check(args: argparse.Namespace) -> int:
    """Run the golden-set quality gate. Exit 0 iff every check passes."""
    root = Path(args.repo_root) if args.repo_root else _repo_root()
    config = MinerConfig.for_repo(root)
    gate = run_golden_gate(
        lessons_text=_read_text(config.lessons_path),
        agents_text=_read_text(config.agents_path),
    )
    print("== lesson-miner golden gate ==")
    for passed, msg in gate.checks:
        print(("  PASS " if passed else "  FAIL ") + msg)
    print(f"\nGOLDEN GATE: {'PASS' if gate.ok else 'FAIL'} "
          f"({sum(1 for p, _ in gate.checks if p)}/{len(gate.checks)} checks)")
    return 0 if gate.ok else 1


def build_parser() -> argparse.ArgumentParser:
    p = argparse.ArgumentParser(description="Fleet lesson-candidate miner (report-only, post-pass).")
    p.add_argument("--check", action="store_true", help="run the golden-set quality gate and exit")
    p.add_argument("--real", action="store_true", help="invoke the local 14B (coordinator's GPU-window pass)")
    p.add_argument("--replay", metavar="FILE", help="mine a recorded model-output envelope (offline)")
    p.add_argument("--repo-root", metavar="DIR", help="agentic-setup checkout root (default: auto)")
    p.add_argument("--recurrence", type=int, metavar="N", help="override the recurrence threshold (default 3)")
    p.add_argument("--batch-tokens", type=int, metavar="N",
                   help="pin the per-batch evidence-bundle token budget (default: auto from probed context)")
    p.add_argument("--request-timeout", type=int, metavar="S",
                   help="per-batch model request timeout in seconds (default 1200; raise for a throttled 14B)")
    p.add_argument("--max-tokens", type=int, metavar="N",
                   help="per-batch generation cap (default 2048; raise if a batch's JSON is truncated)")
    p.add_argument("--out-date", metavar="YYYY-MM-DD", help="override the candidates filename date")
    p.add_argument("--allow-live", action="store_true", help="override the post-pass guard (deliberate use only)")
    return p


def main(argv: list[str] | None = None) -> int:
    # The emitted file is UTF-8; console prints may carry the same em-dashes/·. On a
    # legacy Windows codepage that would raise UnicodeEncodeError mid-pass — reconfigure
    # to a replace policy so a cosmetic glyph never crashes a mining run.
    for stream in (sys.stdout, sys.stderr):
        try:
            stream.reconfigure(encoding="utf-8", errors="replace")  # type: ignore[union-attr]
        except (AttributeError, ValueError):
            pass
    args = build_parser().parse_args(argv)
    if args.check:
        return run_check(args)
    return run_pass(args)


if __name__ == "__main__":
    raise SystemExit(main())
