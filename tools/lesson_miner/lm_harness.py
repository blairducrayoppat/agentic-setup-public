"""The verification harness — model proposes, the ruler disposes (plan §3.4 D-5).

A small-model consolidator is the exposed case in the drift literature (study §4.3,
Memory Contagion: weaker models propagate bias cross-temporally). So the 14B's output
is not trusted — it is run through a fixed pipeline, in order, and anything that fails
any stage is DROPPED and RECORDED (no silent caps — every filtered item carries its
reason):

1. **schema** — the candidate matches :data:`CANDIDATE_RESPONSE_SCHEMA` (harness step 1).
2. **byte-match** — every cited evidence quote is a VERBATIM substring of its cited
   source artifact (harness step 2 — the deterministic kill for paraphrase drift).
3. the deterministic RULER pre-filters, on byte-verified candidates only (harness step 3):
   **recurrence** (≥N distinct runs), **diversity** (≥2 distinct jobs/eras),
   **novelty** (not already in LESSONS-LEARNED.md or a prior candidate),
   **forbidden-class lint** (never propose weakening the verify gate / secret scan /
   FALSE-DONE cross-check), and **removals-as-removals lint** (a proposed AGENTS.md
   delta must delete lines, never append a "stop doing X" negation of a still-present
   rule).

Recurrence, diversity, and the era annotation are COMPUTED here from the verified
evidence — never read from the model. That is the whole point: the model may select and
count evidence, the ruler decides what counts.
"""

from __future__ import annotations

import re
from dataclasses import dataclass, field
from typing import Any

from lm_config import MinerConfig
from lm_ingest import RunRecord
from lm_schema import SchemaError, validate_candidate

# Filter-stage names (stable — the emitted report and the tests key off these).
STAGE_SCHEMA = "schema"
STAGE_BYTE_MATCH = "byte-match"
STAGE_RECURRENCE = "recurrence"
STAGE_DIVERSITY = "diversity"
STAGE_NOVELTY = "novelty"
STAGE_FORBIDDEN = "forbidden-class"
STAGE_REMOVALS = "removals-lint"

# Below this many meaningful (non-space) characters a "quote" is not evidence — it is a
# trivial substring that would pass byte-match by accident. Killed at the byte-match stage.
_MIN_QUOTE_CHARS = 8

# Token-overlap thresholds. Novelty: a candidate whose significant tokens overlap an
# existing lesson at/above this fraction is NOT new. Topic-match (removals lint): how
# much an added negation line must overlap an existing rule to be "about" that rule.
_TOPIC_THRESHOLD = 0.4

# Two candidates from DIFFERENT batches naming the same failure shape must MERGE (their
# evidence unions) BEFORE the ruler counts recurrence — otherwise a shape that appears
# twice in batch 1 and twice in batch 3 is counted as 2+2 separate recurrences and both
# are silently killed at the ≥3 gate. Bidirectional overlap (both directions ≥ this) so
# a short shape is not swallowed by a long one; set high so only genuine same-shape
# proposals merge. This is the correctness heart of chunked mining.
_MERGE_THRESHOLD = 0.6

_STOPWORDS = frozenset(
    """the a an and or but of to in on at for with without from into over under
    is are was were be been being it its this that these those you your we our they
    their them then than as by if so not no do does did done doing use used using
    can could should would will shall may might must have has had when while which who
    what where why how each any all one two three more most less least own via per
    run runs task tasks job jobs test tests case cases file files line lines""".split()
)

_WORD_RE = re.compile(r"[a-z0-9][a-z0-9_-]{2,}")


def _significant_tokens(text: str) -> set[str]:
    """Lowercase content tokens (len ≥ 3, not a stopword) — the keyword-match unit."""
    return {t for t in _WORD_RE.findall(text.lower()) if t not in _STOPWORDS}


def _overlap(a: set[str], b: set[str]) -> float:
    """Fraction of *a* covered by *b* (0.0 when *a* is empty)."""
    return (len(a & b) / len(a)) if a else 0.0


@dataclass(frozen=True)
class EvidenceRef:
    """A single byte-verified evidence citation, enriched from the run it points at."""

    run_id: str
    artifact: str
    quote: str
    date: str
    repo: str


@dataclass(frozen=True)
class VerifiedCandidate:
    """A candidate that survived every stage, with ruler-computed provenance."""

    failure_shape: str
    proposed_delta: str
    rationale: str
    evidence: list[EvidenceRef]
    recurrence_count: int          # distinct verified run ids
    distinct_jobs: int             # distinct repos among the cited runs
    eras: list[str]                # sorted distinct run dates (the era annotation)


@dataclass(frozen=True)
class VerifiedEvidence:
    """A schema-valid, byte-verified candidate awaiting merge + the ruler.

    The intermediate unit of chunked mining: produced per raw candidate (post
    schema + byte-match), merged across batches by failure shape, THEN ruled.
    """

    failure_shape: str
    proposed_delta: str
    rationale: str
    evidence: list[EvidenceRef]
    merged_from: int = 1           # how many batch proposals merged into this one


@dataclass(frozen=True)
class DropRecord:
    """One dropped candidate: which stage killed it and why (surfaced in the report)."""

    stage: str
    title: str
    reason: str


@dataclass(frozen=True)
class HarnessResult:
    """The outcome of a full mining pass over the model's proposed candidates."""

    verified: list[VerifiedCandidate] = field(default_factory=list)
    dropped: list[DropRecord] = field(default_factory=list)
    notes: list[str] = field(default_factory=list)   # pass-level notes (e.g. truncation logs)


def _title_of(cand: Any) -> str:
    """A short human label for a candidate (for drop records), robust to malformed input."""
    if isinstance(cand, dict):
        fs = cand.get("failure_shape")
        if isinstance(fs, str) and fs.strip():
            return fs.strip()[:80]
    return "<malformed candidate>"


def _split_lesson_corpus(lessons_text: str, prior_candidates_text: str) -> list[set[str]]:
    """Token sets for each existing lesson block + each prior candidate (novelty corpus)."""
    corpus: list[set[str]] = []
    for chunk in re.split(r"\n#{2,3}\s", "\n" + lessons_text):
        toks = _significant_tokens(chunk)
        if toks:
            corpus.append(toks)
    # Prior candidate files mark each candidate with a "### Candidate" header (see lm_emit).
    for chunk in re.split(r"\n#{2,3}\s", "\n" + prior_candidates_text):
        toks = _significant_tokens(chunk)
        if toks:
            corpus.append(toks)
    return corpus


def _existing_agents_rules(agents_text: str) -> list[str]:
    """The instruction lines of AGENTS.md (bullets + prose), for the removals lint."""
    rules: list[str] = []
    for raw in agents_text.splitlines():
        line = raw.strip().lstrip("-*").strip()
        if len(line) >= 12 and not line.startswith("#") and not line.startswith("|"):
            rules.append(line)
    return rules


class Harness:
    """Runs the fixed verification pipeline over one model proposal set."""

    def __init__(
        self,
        config: MinerConfig,
        runs: list[RunRecord],
        *,
        lessons_text: str = "",
        prior_candidates_text: str = "",
        agents_text: str = "",
    ) -> None:
        self._config = config
        self._runs = {r.run_id: r for r in runs}
        self._novelty_corpus = _split_lesson_corpus(lessons_text, prior_candidates_text)
        self._agents_rules = _existing_agents_rules(agents_text)
        self._agents_rule_tokens = [_significant_tokens(r) for r in self._agents_rules]

    # -- stage 2 -------------------------------------------------------------
    def _verify_evidence(self, cand: dict[str, Any]) -> tuple[list[EvidenceRef] | None, str]:
        """Byte-match every quote; return (refs, "") on success or (None, reason)."""
        refs: list[EvidenceRef] = []
        for ev in cand["evidence"]:
            run_id = ev["run_id"].strip()
            artifact = ev["artifact"].strip()
            quote = ev["quote"]
            if len(quote.strip()) < _MIN_QUOTE_CHARS:
                return None, f"evidence quote for run {run_id} too short to be evidence ({quote.strip()!r})"
            rec = self._runs.get(run_id)
            if rec is None:
                return None, f"cited run '{run_id}' not found in the ingested runs"
            source = rec.source_text(artifact)
            if source is None:
                return None, f"cited artifact '{artifact}' not present for run '{run_id}'"
            if quote not in source:
                return None, (
                    f"quote not verbatim in {run_id}/{artifact} "
                    f"(paraphrase-drift): {quote[:60]!r}"
                )
            refs.append(EvidenceRef(run_id=run_id, artifact=artifact, quote=quote,
                                    date=rec.date, repo=rec.repo))
        return refs, ""

    # -- stage 3 ruler helpers ----------------------------------------------
    def _novelty_reason(self, cand: dict[str, Any]) -> str:
        """"" if the candidate is novel; else why it duplicates an existing lesson."""
        cand_toks = _significant_tokens(cand["failure_shape"] + " " + cand.get("rationale", ""))
        if not cand_toks:
            return ""
        best = 0.0
        for entry in self._novelty_corpus:
            best = max(best, _overlap(cand_toks, entry))
        if best >= self._config.novelty_overlap_threshold:
            return f"already covered by an existing lesson/candidate (keyword overlap {best:.0%})"
        return ""

    def _forbidden_reason(self, cand: dict[str, Any]) -> str:
        """"" unless the failure shape or delta touches a forbidden-class control."""
        haystack = (cand["failure_shape"] + "\n" + cand["proposed_delta"] + "\n"
                    + cand.get("rationale", "")).lower()
        for kw in self._config.forbidden_keywords:
            if kw in haystack:
                return f"touches a forbidden-class control ('{kw}') — never propose weakening it"
        return ""

    def _removals_reason(self, cand: dict[str, Any]) -> str:
        """"" unless the delta negates an existing rule by appending instead of deleting."""
        added: list[str] = []
        removed: list[str] = []
        for raw in cand["proposed_delta"].splitlines():
            if raw.startswith("+++") or raw.startswith("---"):
                continue
            if raw.startswith("+"):
                added.append(raw[1:].strip())
            elif raw.startswith("-"):
                removed.append(raw[1:].strip())
        removed_tokens = [_significant_tokens(r) for r in removed]
        for line in added:
            low = line.lower()
            if not any(m in low for m in self._config.negation_markers):
                continue
            line_toks = _significant_tokens(line)
            if not line_toks:
                continue
            targets_existing = any(
                _overlap(line_toks, rule) >= _TOPIC_THRESHOLD for rule in self._agents_rule_tokens
            )
            paired_with_removal = any(
                _overlap(line_toks, rt) >= _TOPIC_THRESHOLD for rt in removed_tokens
            )
            if targets_existing and not paired_with_removal:
                return (
                    "proposes to negate an existing AGENTS.md rule by APPENDING a "
                    f"negation ('{line[:60]}') with no line deletion — removals must "
                    "delete the rule, not negate it"
                )
        return ""

    # -- stage 1+2: schema then byte-match, per raw candidate ----------------
    def verify_one(self, cand: Any) -> tuple[VerifiedEvidence | None, DropRecord | None]:
        """Schema-validate then byte-verify ONE raw candidate (returns exactly one of the pair)."""
        title = _title_of(cand)
        try:
            validate_candidate(cand)
        except SchemaError as exc:
            return None, DropRecord(STAGE_SCHEMA, title, str(exc))
        refs, reason = self._verify_evidence(cand)
        if refs is None:
            return None, DropRecord(STAGE_BYTE_MATCH, title, reason)
        return VerifiedEvidence(
            failure_shape=cand["failure_shape"].strip(),
            proposed_delta=cand["proposed_delta"].rstrip("\n"),
            rationale=cand.get("rationale", "").strip(),
            evidence=refs,
        ), None

    # -- merge: union same-shape candidates ACROSS batches BEFORE the ruler ---
    def merge_verified(self, items: list[VerifiedEvidence]) -> list[VerifiedEvidence]:
        """Group byte-verified candidates by failure shape and UNION their evidence.

        The recurrence-correctness step: two batches each proposing the same shape (each
        citing only the runs it saw) merge into one candidate whose evidence is the union
        across the whole corpus, so recurrence is counted once, correctly. Same-shape is
        keyword overlap (bidirectional ≥ _MERGE_THRESHOLD); evidence is de-duplicated by
        (run_id, artifact, quote). The first proposal's shape/delta/rationale win.
        """
        groups: list[dict[str, Any]] = []
        for ve in items:
            key = _significant_tokens(ve.failure_shape)
            match = None
            for g in groups:
                gk = g["key"]
                if key and gk and _overlap(key, gk) >= _MERGE_THRESHOLD and _overlap(gk, key) >= _MERGE_THRESHOLD:
                    match = g
                    break
            if match is None:
                groups.append({
                    "key": key, "shape": ve.failure_shape, "delta": ve.proposed_delta,
                    "rationale": ve.rationale, "evidence": list(ve.evidence),
                    "seen": {(e.run_id, e.artifact, e.quote) for e in ve.evidence},
                    "count": 1,
                })
            else:
                match["count"] += 1
                for e in ve.evidence:
                    sig = (e.run_id, e.artifact, e.quote)
                    if sig not in match["seen"]:
                        match["seen"].add(sig)
                        match["evidence"].append(e)
        return [
            VerifiedEvidence(g["shape"], g["delta"], g["rationale"], g["evidence"], g["count"])
            for g in groups
        ]

    # -- stage 3: the deterministic ruler, on merged (whole-corpus) evidence --
    def apply_ruler(self, ve: VerifiedEvidence) -> tuple[VerifiedCandidate | None, DropRecord | None]:
        """Recurrence -> diversity -> novelty -> forbidden -> removals, computed from evidence."""
        title = ve.failure_shape[:80]
        run_ids = {r.run_id for r in ve.evidence}
        repos = {r.repo for r in ve.evidence if r.repo}
        eras = sorted({r.date for r in ve.evidence if r.date})
        recurrence = len(run_ids)
        distinct_jobs = len(repos)
        cand = {"failure_shape": ve.failure_shape, "proposed_delta": ve.proposed_delta,
                "rationale": ve.rationale}

        if recurrence < self._config.recurrence_n:
            return None, DropRecord(
                STAGE_RECURRENCE, title,
                f"recurs across only {recurrence} distinct run(s); need ≥{self._config.recurrence_n}")
        if distinct_jobs < self._config.diversity_min and len(eras) < self._config.diversity_min:
            return None, DropRecord(
                STAGE_DIVERSITY, title,
                f"evidence spans only {distinct_jobs} job(s) / {len(eras)} era(s); "
                f"need ≥{self._config.diversity_min} distinct jobs or eras "
                "(one pathological run cannot mint a lesson)")
        novelty = self._novelty_reason(cand)
        if novelty:
            return None, DropRecord(STAGE_NOVELTY, title, novelty)
        forbidden = self._forbidden_reason(cand)
        if forbidden:
            return None, DropRecord(STAGE_FORBIDDEN, title, forbidden)
        removals = self._removals_reason(cand)
        if removals:
            return None, DropRecord(STAGE_REMOVALS, title, removals)
        return VerifiedCandidate(
            failure_shape=ve.failure_shape, proposed_delta=ve.proposed_delta,
            rationale=ve.rationale, evidence=ve.evidence, recurrence_count=recurrence,
            distinct_jobs=distinct_jobs, eras=eras), None

    # -- orchestration -------------------------------------------------------
    def process_batches(self, candidate_batches: list[list[Any]]) -> HarnessResult:
        """Verify each batch's candidates, MERGE across all batches, then rule. No silent caps."""
        verified_ev: list[VerifiedEvidence] = []
        dropped: list[DropRecord] = []
        for batch in candidate_batches:
            for cand in batch:
                ve, drop = self.verify_one(cand)
                if drop is not None:
                    dropped.append(drop)
                else:
                    assert ve is not None
                    verified_ev.append(ve)

        verified: list[VerifiedCandidate] = []
        for ve in self.merge_verified(verified_ev):
            vc, drop = self.apply_ruler(ve)
            if drop is not None:
                dropped.append(drop)
            else:
                assert vc is not None
                verified.append(vc)
        return HarnessResult(verified=verified, dropped=dropped)

    def run(self, candidates: list[Any]) -> HarnessResult:
        """Single-batch entry (golden set / replay): one list, verify -> merge -> rule."""
        return self.process_batches([list(candidates)])
