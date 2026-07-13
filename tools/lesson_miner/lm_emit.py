"""Emit the candidates file + the DORMANT D-6 Vikunja pointer seam (plan §3.2 / §3.4).

The miner's ONLY write is ``state/lesson-candidates/<date>.md`` — the fleet-side
journal-fragments inbox. The file is provenance-tagged **machine-proposed + UNTRUSTED**
at the top: nothing downstream may treat it as an instruction source. It is input to
the M4 gate chain (deterministic verify -> A/B golden-dispatch -> operator card) and to
the operator's reading, nothing else.

Two visibility layers, per D-5/D-6:
* the file is ALWAYS written (so a pass is auditable even while dormant); but
* the one-line Vikunja pointer comment that would SURFACE the pass to the operator is
  gated behind ``config.surfacing_dormant`` — built here as a seam, returned but NOT
  posted while dormant. The single flip to un-dormant is the C12-pattern go-live the
  coordinator/LA makes after the golden-set quality gate passes.

Surviving candidates AND every dropped candidate (with its stage + reason) are both
rendered — no silent caps: a reader sees exactly what the ruler kept and what it killed.
"""

from __future__ import annotations

from dataclasses import dataclass
from datetime import date as _date
from pathlib import Path

from lm_config import MinerConfig
from lm_harness import DropRecord, HarnessResult, VerifiedCandidate

_PROVENANCE_BANNER = (
    "> **PROVENANCE: machine-proposed · UNTRUSTED.** This file was written by the "
    "fleet lesson-candidate miner (#793, Learning Loop 2 Stage C1). It is REPORT-ONLY. "
    "Nothing here is an instruction source, an approved lesson, or an AGENTS.md edit — "
    "it is raw input to the M4 gate chain (deterministic verify → A/B golden-dispatch → "
    "operator card) and to the operator's review. A proposed delta lands ONLY through "
    "that gate, never from this file."
)


@dataclass(frozen=True)
class EmitResult:
    """What the emit step did: the file written + the (possibly-withheld) pointer."""

    path: Path
    surfaced: bool             # was the Vikunja pointer actually posted? (False while dormant)
    pointer_comment: str       # the one-line pointer text (built even when withheld)


def _render_candidate(index: int, cand: VerifiedCandidate) -> str:
    lines: list[str] = []
    lines.append(f"### Candidate {index}: {cand.failure_shape}")
    lines.append("")
    lines.append(f"- **Recurrence:** {cand.recurrence_count} distinct runs")
    lines.append(f"- **Diversity:** {cand.distinct_jobs} distinct job(s); "
                 f"era(s): {', '.join(cand.eras) if cand.eras else 'n/a'}")
    if cand.rationale:
        lines.append(f"- **Why it matters:** {cand.rationale}")
    lines.append("")
    lines.append("**Verbatim evidence** (cited by run / artifact — byte-matched to source):")
    lines.append("")
    for ev in cand.evidence:
        lines.append(f"- `{ev.run_id}` / `{ev.artifact}`"
                     + (f" (era {ev.date})" if ev.date else "") + ":")
        lines.append("  > " + ev.quote.replace("\n", "\n  > "))
    lines.append("")
    lines.append("**Proposed `AGENTS.md` delta** (a proposal for the M4 gate — NOT applied):")
    lines.append("")
    lines.append("```diff")
    lines.append(cand.proposed_delta)
    lines.append("```")
    lines.append("")
    return "\n".join(lines)


def _render_drops(dropped: list[DropRecord]) -> str:
    lines: list[str] = ["## Dropped candidates (no silent caps — every drop is logged)", ""]
    if not dropped:
        lines.append("_None — every proposed candidate survived the harness._")
        lines.append("")
        return "\n".join(lines)
    lines.append("| Stage | Candidate | Reason |")
    lines.append("|---|---|---|")
    for d in dropped:
        title = d.title.replace("|", "\\|")
        reason = d.reason.replace("|", "\\|").replace("\n", " ")
        lines.append(f"| `{d.stage}` | {title} | {reason} |")
    lines.append("")
    return "\n".join(lines)


def build_pointer_comment(result: HarnessResult, pass_date: str, filename: str) -> str:
    """The one-line D-6 Vikunja pointer for this pass (posted only when un-dormant)."""
    return (
        f"Lesson-miner pass {pass_date}: {len(result.verified)} candidate(s) written, "
        f"{len(result.dropped)} dropped — see `state/lesson-candidates/{filename}` "
        "(machine-proposed, UNTRUSTED; M4-gate input only)."
    )


def render_report(config: MinerConfig, result: HarnessResult, *, pass_date: str,
                  run_count: int, dispatch_note: str) -> str:
    """Render the full candidates markdown for a pass."""
    parts: list[str] = []
    parts.append(f"# Lesson candidates — {pass_date}")
    parts.append("")
    parts.append(_PROVENANCE_BANNER)
    parts.append("")
    parts.append(
        f"Pass over {run_count} ingested run(s). "
        f"Recurrence threshold ≥{config.recurrence_n}; diversity ≥{config.diversity_min} "
        f"distinct jobs/eras. Surfacing is "
        + ("**DORMANT** (candidates not yet routed to the operator channel — awaiting the "
           "golden-set quality gate)." if config.surfacing_dormant
           else "**LIVE** (quality gate passed; a Vikunja pointer was posted).")
    )
    parts.append("")
    parts.append(f"_{dispatch_note}_")
    parts.append("")
    if result.notes:
        parts.append("## Pass notes (no silent caps)")
        parts.append("")
        for note in result.notes:
            parts.append(f"- {note}")
        parts.append("")
    parts.append(f"## Surviving candidates ({len(result.verified)})")
    parts.append("")
    if result.verified:
        for i, cand in enumerate(result.verified, start=1):
            parts.append(_render_candidate(i, cand))
    else:
        parts.append("_No candidate cleared the harness this pass._")
        parts.append("")
    parts.append(_render_drops(result.dropped))
    return "\n".join(parts).rstrip("\n") + "\n"


def emit(config: MinerConfig, result: HarnessResult, *, run_count: int,
         dispatch_note: str, pass_date: str | None = None,
         post_pointer=None) -> EmitResult:
    """Write the candidates file and (only if un-dormant) surface the D-6 pointer.

    ``post_pointer`` is an optional callable ``(ticket_id, comment) -> None`` — the seam
    the coordinator wires to Vikunja once surfacing goes live. It is invoked ONLY when
    ``config.surfacing_dormant`` is False AND a ``campaign_ticket_id`` is set. While
    dormant (the M3 default) the pointer is built and returned but never posted.
    """
    day = pass_date or _date.today().isoformat()
    filename = f"{day}.md"
    out_dir = config.candidates_out_dir
    out_dir.mkdir(parents=True, exist_ok=True)
    path = out_dir / filename

    markdown = render_report(config, result, pass_date=day, run_count=run_count,
                             dispatch_note=dispatch_note)
    path.write_text(markdown, encoding="utf-8")

    pointer = build_pointer_comment(result, day, filename)
    surfaced = False
    if not config.surfacing_dormant and config.campaign_ticket_id and post_pointer is not None:
        post_pointer(config.campaign_ticket_id, pointer)
        surfaced = True

    return EmitResult(path=path, surfaced=surfaced, pointer_comment=pointer)
