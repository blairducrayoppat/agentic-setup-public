"""Configuration for the fleet lesson-candidate miner (#793 M3, Learning Loop 2 C1).

One immutable dataclass holds every knob the miner reads, plus a resolver that
locates the fleet-repo surfaces from a repo root. Nothing here reads the clock,
the network, or the model — pure data, so the whole config is testable and the
defaults are auditable in one place.

The miner is REPORT-ONLY: it reads the campaign machinery's outputs and writes
one candidates file. Every path below is either a read source or the single
write destination (`candidates_out_dir`); there is no other write surface.
"""

from __future__ import annotations

from dataclasses import dataclass, field, replace
from pathlib import Path

# The OVMS OpenAI-compatible endpoint the Everyday 14B is served on (loopback
# only; scripts/start-llm.ps1 qwen3-14b). The real mining pass is the
# coordinator's to run in a GPU window — this is where OvmsGrammarClient posts.
DEFAULT_ENDPOINT = "http://127.0.0.1:8000/v3"

# The forbidden-class lint list (plan §3.3 / D-5 harness step 3). A candidate whose
# failure shape OR proposed delta touches one of these self-modification-sensitive
# controls is DROPPED and reported as dropped — the miner must never propose
# weakening the machinery that keeps the fleet honest. Building this in from day one
# means M4's ADR-022 landing gate inherits the lint rather than retrofitting it.
DEFAULT_FORBIDDEN_KEYWORDS: tuple[str, ...] = (
    "verify gate",
    "verify-gate",
    "verification gate",
    "secret scan",
    "secret-scan",
    "gitleaks",
    "false-done",
    "false done",
    "falsedone",
    "acceptance oracle",
    "oracle protection",
    "protected test",
    "protected oracle",
    "morning review",
    "human review gate",
    "human-review gate",
    "kill switch",
    "kill-switch",
    "merge gate",
    "merge-gate",
)

# Negation markers the removals-as-removals lint watches for on ADDED delta lines
# (plan §2.2a, LA-approved). A proposed AGENTS.md delta must express a removal as a
# line DELETION; an appended "stop doing X" that negates a still-present rule is the
# accretion anti-pattern and is dropped.
DEFAULT_NEGATION_MARKERS: tuple[str, ...] = (
    "stop doing",
    "stop using",
    "no longer",
    "do not ",
    "don't ",
    "dont ",
    "never ",
    "avoid ",
    "refrain from",
    "instead of following",
    "ignore the rule",
    "disregard",
)


@dataclass(frozen=True)
class MinerConfig:
    """Every miner knob + resolved surface path. Immutable; build via :meth:`for_repo`."""

    # --- read sources -------------------------------------------------------
    fleet_runs_dir: Path
    swap_state_path: Path
    campaign_path: Path
    lessons_path: Path
    agents_path: Path
    # --- the single write destination ---------------------------------------
    candidates_out_dir: Path

    # --- deterministic ruler thresholds (plan §3.3) -------------------------
    recurrence_n: int = 3            # ≥N independent failure rows to mint a candidate
    diversity_min: int = 2           # ≥2 distinct jobs/eras
    novelty_overlap_threshold: float = 0.6   # keyword overlap ≥ this vs an existing lesson => not novel

    # --- surfacing posture (D-5 / D-6) --------------------------------------
    # DORMANT until the golden-set quality gate is proven. When True (default),
    # candidates are WRITTEN to the file but NOT surfaced to the operator channel
    # (no Vikunja pointer comment posted). The single auditable flip to False is
    # the C12-pattern go-live, made by the coordinator/LA after the gate passes.
    surfacing_dormant: bool = True
    campaign_ticket_id: int = 0      # the Vikunja ticket the D-6 pointer targets (0 = unset)

    # --- model seam (real pass only; never touched by tests) ----------------
    endpoint: str = DEFAULT_ENDPOINT
    model_temperature: float = 0.0   # deterministic (BlarAI coding standard)
    model_top_p: float = 1.0
    # Per-batch generation budget. Lowered from 4096: candidates are small (a handful of
    # short quotes + a one-line delta each), and every generated token is time on a
    # throttled 14B — 4096 was mostly headroom that directly multiplied the per-batch
    # wall clock. 2048 still fits several candidates; raise via --max-tokens if a batch's
    # grammar-constrained JSON is truncated (the resume cache makes a retry cheap).
    model_max_tokens: int = 2048
    # Per-request (socket read) timeout. Raised from 300 s: the first real pass timed out
    # at ~28 min because a single batch — a ~10k-token prefill + grammar-constrained
    # generation on a THERMALLY-THROTTLED Arc 140V 14B — legitimately took longer than 5
    # min. 6-10+ min per batch is normal under throttling; 20 min is a generous ceiling
    # that still catches a genuinely hung request. Override with --request-timeout.
    model_timeout_s: int = 1200

    # --- corpus chunking (the whole ~113-run bundle overflows the 14B context and
    # 400s; mine in batches that provably fit, then merge candidates across batches
    # BEFORE the ruler so recurrence/diversity count across the WHOLE corpus) -------
    # 0 => auto-derive the per-batch evidence-bundle budget from the served context:
    #   budget = (probed_or_default_context_tokens - reserved_headroom_tokens).
    # A positive value pins the budget directly (the coordinator's --batch-tokens knob,
    # to dial down if a live 400 shows the real ceiling is lower than assumed).
    batch_token_budget: int = 0
    # The context length assumed when a live probe of /v3/models yields nothing.
    # Deliberately conservative (Qwen3-14B is larger, but a probe RAISES this when it
    # can; guessing high is what caused the 400, so the fallback guesses low).
    default_context_tokens: int = 16384
    # Reserved out of the context for the system prompt + the json_schema block + the
    # model's own output (model_max_tokens) + margin — never spent on evidence.
    reserved_headroom_tokens: int = 6000
    # Char/token ratio for the cheap, tokenizer-free length estimate. Low = pessimistic
    # (over-counts tokens => smaller, safer batches). English prose ~4; logs/code ~3.5.
    chars_per_token: float = 3.5

    forbidden_keywords: tuple[str, ...] = DEFAULT_FORBIDDEN_KEYWORDS
    negation_markers: tuple[str, ...] = DEFAULT_NEGATION_MARKERS

    @staticmethod
    def for_repo(repo_root: Path, **overrides: object) -> "MinerConfig":
        """Resolve every surface from an agentic-setup checkout root.

        ``candidates_out_dir`` is ``state/lesson-candidates/`` — inside the
        gitignored ``state/`` tree because a candidates file is generated output,
        never source. Keyword *overrides* replace any resolved field (used by the
        golden set to point at fixture dirs and to flip the dormancy flag).
        """
        root = Path(repo_root)
        base = MinerConfig(
            fleet_runs_dir=root / "state" / "fleet-runs",
            swap_state_path=root / "state" / "fleet-swap" / "current.json",
            campaign_path=root / "state" / "battery-campaign.json",
            lessons_path=root / "docs" / "LESSONS-LEARNED.md",
            agents_path=root / "configs" / "AGENTS.md",
            candidates_out_dir=root / "state" / "lesson-candidates",
        )
        return replace(base, **overrides) if overrides else base
