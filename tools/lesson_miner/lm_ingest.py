"""Read-only ingest over the campaign machinery's per-run outputs (plan §3.1).

Each ``state/fleet-runs/<run_id>/`` directory is one dispatch's evidence: the
``scorecard.json`` (schema ``m2-scorecard/v1`` — verdict + attribution vocabulary,
per-task/per-wave results, the job-acceptance oracle result), the advisory
``guest-oracle.json`` (guest certificate), and the human-facing ``SUMMARY.txt`` /
``JOB_SUMMARY.txt`` / ``journal.log``. This layer reads them, parses the structured
facts, and — critically — RETAINS the raw text of every artifact keyed by name, so
the harness can byte-match a model's cited evidence quote against its actual source.

Nothing here writes, and nothing here runs during a live dispatch — the caller
gates on :mod:`lm_guard` first. Ingest is deliberately fail-soft per file (a
missing or unparseable artifact is skipped, not fatal): the campaign machinery
grows new artifact kinds over time and a miner that hard-fails on the first
unexpected file is a miner that never runs.
"""

from __future__ import annotations

import json
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any

# The plain-text artifacts whose bytes we keep for quote verification, alongside
# the JSON ones. A cited quote may come from any of these OR from a string field
# inside scorecard.json / guest-oracle.json (the raw JSON text is retained too).
_TEXT_ARTIFACTS = ("SUMMARY.txt", "JOB_SUMMARY.txt", "journal.log", "swap-progress.log")
_JSON_ARTIFACTS = ("scorecard.json", "guest-oracle.json", "acceptance.json")


@dataclass(frozen=True)
class RunRecord:
    """One dispatch's evidence: parsed facts + the raw source text of each artifact."""

    run_id: str
    date: str                        # YYYY-MM-DD parsed from the run_id prefix ("" if unparseable)
    verdict: str
    attribution: str
    repo: str
    goal: str
    degraded: bool
    cancelled: bool
    scorecard: dict[str, Any]        # the full parsed scorecard.json (or {} if absent)
    guest_oracle: dict[str, Any]     # the full parsed guest-oracle.json (or {} if absent)
    sources: dict[str, str] = field(default_factory=dict)   # artifact-name -> raw text

    def source_text(self, artifact: str) -> str | None:
        """The raw text of a named artifact, or None if it was not present/read.

        This is the byte-match verifier's lookup: an evidence quote is verbatim iff
        it is a substring of ``source_text(artifact)`` for its cited run.
        """
        return self.sources.get(artifact)


def _parse_date(run_id: str) -> str:
    """Best-effort YYYY-MM-DD from a ``YYYYMMDD-HHMMSS[-bd]`` run id ("" if it doesn't fit)."""
    head = run_id[:8]
    if len(head) == 8 and head.isdigit():
        return f"{head[0:4]}-{head[4:6]}-{head[6:8]}"
    return ""


def _read_text(path: Path) -> str | None:
    """Read a file as UTF-8 text, or None on any error (fail-soft, per-file)."""
    try:
        return path.read_text(encoding="utf-8", errors="replace")
    except OSError:
        return None


def _load_json(path: Path) -> dict[str, Any]:
    """Parse a JSON object, or {} if absent/unreadable/non-object (fail-soft)."""
    raw = _read_text(path)
    if raw is None:
        return {}
    try:
        obj = json.loads(raw)
    except (ValueError, TypeError):
        return {}
    return obj if isinstance(obj, dict) else {}


def load_run(run_dir: Path) -> RunRecord | None:
    """Ingest a single ``fleet-runs/<run_id>/`` directory into a :class:`RunRecord`.

    Returns None only if the directory has NO scorecard AND no summary — i.e. it is
    not an evidence-bearing run (an empty/partial dir). A run with a scorecard but a
    novel extra file still ingests: unknown files are simply not retained.
    """
    if not run_dir.is_dir():
        return None
    run_id = run_dir.name

    scorecard = _load_json(run_dir / "scorecard.json")
    guest = _load_json(run_dir / "guest-oracle.json")

    sources: dict[str, str] = {}
    for name in _TEXT_ARTIFACTS:
        text = _read_text(run_dir / name)
        if text is not None:
            sources[name] = text
    # Retain the raw JSON text too — a model may (legitimately) quote a string field
    # out of scorecard.json / guest-oracle.json, and the byte-match check needs the
    # exact on-disk bytes to compare against, not the re-serialised parse.
    for name in _JSON_ARTIFACTS:
        text = _read_text(run_dir / name)
        if text is not None:
            sources[name] = text

    if not scorecard and "SUMMARY.txt" not in sources:
        return None

    return RunRecord(
        run_id=run_id,
        date=_parse_date(run_id),
        verdict=str(scorecard.get("verdict", "")),
        attribution=str(scorecard.get("attribution", "")),
        repo=str(scorecard.get("repo", "")),
        goal=str(scorecard.get("goal", "")),
        degraded=bool(scorecard.get("degraded", False)),
        cancelled=bool(scorecard.get("cancelled", False)),
        scorecard=scorecard,
        guest_oracle=guest,
        sources=sources,
    )


def ingest_runs(fleet_runs_dir: Path) -> list[RunRecord]:
    """Ingest every evidence-bearing run under *fleet_runs_dir*, sorted by run id.

    Sorting by run id is chronological (the ids are timestamp-prefixed), which keeps
    the emitted candidates file and the era annotations stable across passes.
    """
    if not fleet_runs_dir.is_dir():
        return []
    records: list[RunRecord] = []
    for child in sorted(fleet_runs_dir.iterdir()):
        rec = load_run(child)
        if rec is not None:
            records.append(rec)
    return records


def load_campaign_eras(campaign_path: Path) -> dict[str, Any]:
    """Read ``battery-campaign.json`` for the campaign name + era annotations.

    Returns {} if absent — the miner still annotates each run with its calendar date
    (a coarse era); the campaign name, when present, sharpens the era label.
    """
    return _load_json(campaign_path)
