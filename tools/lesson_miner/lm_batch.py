"""Chunked mining — split the corpus into batches that fit the 14B context (#793 fix).

The first real pass 400'd: one user message carrying the whole ~113-run corpus overflows
the served model's context. The fix is to mine in BATCHES that provably fit, one model
call per batch, and then MERGE candidates across batches *before* the ruler runs — so
recurrence (≥N) and diversity (≥2 jobs/eras) are counted across the WHOLE corpus, not
per batch (a shape appearing twice in batch 1 and twice in batch 3 is recurrence 4;
per-batch counting would silently kill it). The merge itself lives in the harness
(:meth:`Harness.merge_verified`); this module owns the packing.

Token accounting is tokenizer-free (the box is offline; no guarantee of a matching
tokenizer) — a conservative chars/token estimate that OVER-counts, so batches come out
smaller than the true ceiling. The budget is derived from a live context probe when
available and a deliberately-low default otherwise (guessing the ceiling too HIGH is
what caused the 400). If a SINGLE run's evidence exceeds the whole budget it is
TRUNCATED-with-log, never dropped silently (the no-silent-caps rule) — and because the
kept text is a prefix of the real source, any quote the model draws from it still
byte-matches.
"""

from __future__ import annotations

import hashlib
import json
import math
import os
import time
from pathlib import Path
from typing import Any, Callable

from lm_config import MinerConfig
from lm_harness import Harness, HarnessResult
from lm_ingest import RunRecord
from lm_model import ModelClient


def build_run_block(rec: RunRecord) -> str:
    """The per-run evidence text the model reads — labelled so quotes cite (run, artifact).

    Composed from the retained raw artifact bytes, so a verbatim quote from this block is
    by construction a verbatim substring of the source the byte-match verifier checks.
    """
    lines: list[str] = [
        f"=== RUN {rec.run_id} (date {rec.date or '?'}, repo {rec.repo or '?'}, "
        f"verdict {rec.verdict or '?'}, attribution {rec.attribution or '?'}) ==="
    ]
    for artifact, text in rec.sources.items():
        lines.append(f"--- {rec.run_id} :: {artifact} ---")
        lines.append(text.rstrip("\n"))
    return "\n".join(lines)


def build_evidence_bundle(runs: list[RunRecord]) -> str:
    """The whole-corpus bundle (used for small corpora / offline debugging)."""
    return "\n\n".join(build_run_block(r) for r in runs)


def estimate_tokens(text: str, chars_per_token: float) -> int:
    """A cheap, deliberately-pessimistic token estimate (over-counts => safer batches)."""
    return max(1, math.ceil(len(text) / max(1.0, chars_per_token)))


def resolve_bundle_budget(config: MinerConfig, probed_context: int | None = None) -> int:
    """The per-batch evidence-bundle token budget.

    A pinned ``batch_token_budget`` wins (the coordinator's --batch-tokens override). Else
    derive it from the served context (a live probe when available, the conservative
    ``default_context_tokens`` otherwise) minus the reserved headroom, floored so a
    pathological config can never produce a zero/negative budget.
    """
    if config.batch_token_budget > 0:
        return config.batch_token_budget
    ctx = probed_context if (probed_context and probed_context > 0) else config.default_context_tokens
    return max(2048, ctx - config.reserved_headroom_tokens)


def chunk_runs(
    runs: list[RunRecord], *, bundle_budget: int, chars_per_token: float
) -> tuple[list[str], list[str]]:
    """Pack run blocks into bundle strings each ≤ *bundle_budget* tokens; return (bundles, notes).

    Greedy first-fit by run order (chronological). A run whose own block exceeds the whole
    budget is TRUNCATED to a prefix that fits and gets a note (never dropped) — quotes from
    the kept prefix still byte-match the full source. Every truncation is logged; there are
    no silent caps.
    """
    bundles: list[str] = []
    notes: list[str] = []
    cur: list[str] = []
    cur_tokens = 0

    def flush() -> None:
        nonlocal cur, cur_tokens
        if cur:
            bundles.append("\n\n".join(cur))
            cur = []
            cur_tokens = 0

    for rec in runs:
        block = build_run_block(rec)
        tokens = estimate_tokens(block, chars_per_token)

        if tokens > bundle_budget:
            flush()  # oversized run stands alone, truncated
            max_chars = int(bundle_budget * chars_per_token)
            truncated = block[:max_chars].rstrip() + (
                f"\n[... TRUNCATED: run {rec.run_id} evidence (~{tokens} tok) exceeded the "
                f"{bundle_budget}-token batch budget; the kept prefix is verbatim ...]"
            )
            bundles.append(truncated)
            notes.append(
                f"run {rec.run_id}: evidence (~{tokens} tok) exceeded the {bundle_budget}-token "
                f"batch budget and was TRUNCATED to ~{bundle_budget} tok. Quotes from the kept "
                f"prefix still byte-match; nothing was dropped silently."
            )
            continue

        if cur and cur_tokens + tokens > bundle_budget:
            flush()
        cur.append(block)
        cur_tokens += tokens

    flush()
    return bundles, notes


def _bundle_sha(bundle: str) -> str:
    return hashlib.sha256(bundle.encode("utf-8")).hexdigest()


def _batch_cache_path(work_dir: Path, i: int) -> Path:
    return work_dir / f"batch-{i:02d}.json"


def load_batch_cache(work_dir: Path, i: int, bundle: str) -> list[dict[str, Any]] | None:
    """Return a completed batch's cached candidates iff present AND still for THIS bundle.

    The stored ``bundle_sha`` guards against corpus/budget drift between runs — if the
    bundle at index *i* changed (new runs landed, --batch-tokens changed), the cache is
    stale and ignored (the batch recomputes), so resume can never merge yesterday's
    evidence into today's shapes.
    """
    path = _batch_cache_path(work_dir, i)
    try:
        data = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, ValueError):
        return None
    if not isinstance(data, dict) or data.get("bundle_sha") != _bundle_sha(bundle):
        return None
    cands = data.get("candidates")
    return list(cands) if isinstance(cands, list) else None


def save_batch_cache(work_dir: Path, i: int, bundle: str, candidates: list[dict[str, Any]]) -> None:
    """Persist a completed batch's raw candidates atomically (write-ahead for resume)."""
    work_dir.mkdir(parents=True, exist_ok=True)
    path = _batch_cache_path(work_dir, i)
    tmp = path.with_suffix(".json.tmp")
    tmp.write_text(json.dumps({"bundle_sha": _bundle_sha(bundle), "candidates": candidates},
                              indent=2), encoding="utf-8")
    os.replace(tmp, path)


def mine_corpus(
    harness: Harness,
    model: ModelClient,
    runs: list[RunRecord],
    config: MinerConfig,
    *,
    probed_context: int | None = None,
    bundles: list[str] | None = None,
    work_dir: Path | None = None,
    progress: Callable[[str], None] | None = None,
) -> HarnessResult:
    """Chunk the corpus, propose per batch (RESUMABLE), then verify+merge+rule across all.

    ``bundles`` may be supplied directly (tests inject explicit batches to drive the
    cross-batch merge deterministically); otherwise they are packed by :func:`chunk_runs`.

    Resilience for a long multi-batch pass on a throttled 14B:
    * **Resume** — when *work_dir* is given, each completed batch's raw output is persisted
      to ``batch-NN.json`` as it finishes; a rerun loads those and skips the model call, so
      a 26-batch pass never restarts from zero because batch 7 timed out.
    * **Per-batch isolation** — a batch that raises (timeout, non-JSON, …) is logged as a
      note and SKIPPED, not cached; the pass continues and the merge runs over whatever
      completed. The failed batch retries on the next run. No silent caps.
    * **Progress** — *progress* is called with a line per batch (liveness for a supervisor
      watching a 20-minute-per-batch pass).
    """
    def _say(msg: str) -> None:
        if progress is not None:
            progress(msg)

    notes: list[str] = []
    if bundles is None:
        budget = resolve_bundle_budget(config, probed_context)
        bundles, notes = chunk_runs(runs, bundle_budget=budget,
                                    chars_per_token=config.chars_per_token)
    if not bundles:
        bundles = [""]  # nothing to mine, but still make a (single, empty) pass

    total = len(bundles)
    candidate_batches: list[list[Any]] = []
    for i, bundle in enumerate(bundles):
        if work_dir is not None:
            cached = load_batch_cache(work_dir, i, bundle)
            if cached is not None:
                candidate_batches.append(cached)
                _say(f"batch {i + 1}/{total}: resumed from cache ({len(cached)} candidate(s))")
                continue
        try:
            t0 = time.monotonic()
            raw = model.propose(bundle)
            dt = time.monotonic() - t0
        except Exception as exc:  # noqa: BLE001 — one bad batch must not lose the whole pass
            notes.append(
                f"batch {i + 1}/{total} FAILED and was skipped ({exc}); not cached — it "
                f"retries on the next run. Merge ran over the completed batches only."
            )
            _say(f"batch {i + 1}/{total}: FAILED ({exc}) — skipped, will retry on rerun")
            continue
        if work_dir is not None:
            save_batch_cache(work_dir, i, bundle, raw)
        candidate_batches.append(raw)
        _say(f"batch {i + 1}/{total}: {len(raw)} candidate(s) in {dt:.0f}s"
             + (" [saved]" if work_dir is not None else ""))

    result = harness.process_batches(candidate_batches)
    return HarnessResult(verified=result.verified, dropped=result.dropped, notes=notes)
