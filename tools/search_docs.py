#!/usr/bin/env python3
"""search_docs — the coding fleet's LOCAL, offline documentation lookup (#746).

The reactive research point for the 30B coder: on a CONCRETE named gap — an unknown
symbol, an exact error line, a specific "how does X work" question — the coder calls
this to consult the LOCAL, air-gapped docset that BlarAI stages and hash-verifies.
PULL not PUSH: nothing here fires unprompted, and a query the corpus cannot answer
above the relevance floor returns "no high-value match — proceed" rather than noise.

Deterministic-FIRST (the #746 golden rule, the gate-is-judge philosophy): the query
is matched EXACTLY first (symbol or the exception name inside an error line — no model,
no fuzz); only if that misses does floor-gated lexical BM25 retrieval run. This reuses
BlarAI's PROVEN, zero-egress ``shared.research`` package as the single source of truth
for the ladder + relevance floor + prompt-safe excerpting — it does NOT re-implement
retrieval, so the coder and the 14B planner consult the SAME index the SAME way.

ZERO EGRESS (the runtime privacy mandate is absolute): every byte read comes from the
local index file on disk. This module imports NO network machinery; ``shared.research``
is itself locked incapable of egress. There is no fetch, ever.

DORMANT + OPT-IN (double-gated): this tool does nothing until ``BLARAI_RESEARCH_DOCS``
is set to a truthy value (``1``/``true``/``yes``/``on``). Unset (the default) => a clean
"dormant" result and the index is never even opened. This is the deliberate "research
arm switch" for the reliability campaign; it is flipped on only at an explicit
night-boundary once the corpus is staged + the before/after battery has measured it.
(The OpenCode tool wrapper that exposes this to the coder is ALSO staged-not-installed —
see ``configs/opencode-tools/``.)

FAIL-CLOSED: if the docset index is not staged/built, this refuses with a clear message
naming BlarAI's stager (``scripts/stage_docsets.py``) and a non-zero exit — a missing
corpus is an operator problem, never a fabricated "answer".

Environment:
  BLARAI_RESEARCH_DOCS      truthy => enabled; unset/false => dormant (default OFF).
  BLARAI_REPO               BlarAI repo root (default C:\\Users\\mrbla\\blarai) — where
                            ``shared.research`` + the staged docset index live.
  BLARAI_DOCSET_INDEX_DIR   override the index dir (default: <repo>/models/docsets/index).
  BLARAI_DOCSET_CORPUS_DIR  override the corpus dir (default: <repo>/models/docsets) —
                            used only for the staleness check.

Usage:
  python tools/search_docs.py "json.dumps"
  python tools/search_docs.py --json "ValueError: invalid literal for int()"
  python tools/search_docs.py -k 5 "how do pytest fixtures scope"
"""

from __future__ import annotations

import argparse
import json
import os
import sys
import time
from pathlib import Path

#: Default BlarAI repo root (holds shared.research + the staged docset index).
_DEFAULT_BLARAI_REPO = r"C:\Users\mrbla\blarai"

#: Truthy spellings for the dormant gate.
_TRUTHY = frozenset({"1", "true", "yes", "on"})

#: Result excerpt cap for tool output (below shared.research's 800 — a coder tool
#: wants a tight interface card, not a paragraph).
_TOOL_EXCERPT_MAX = 480

#: Exit codes (distinct so the wrapper/coder can tell dormant from fail-closed).
EXIT_OK = 0
EXIT_UNAVAILABLE = 3  # substrate/index not available (fail-closed)
EXIT_BAD_ARGS = 2

#: ALWAYS-ON usage evidence (#746 maturation) -- every real lookup call (dormant
#: calls excluded, they never reach the index) appends one JSONL record here, so
#: hit rate / query text / outcome are observable without a debug env flag.
#: Override via BLARAI_RESEARCH_USAGE_LOG. Best-effort + fail-soft: a logging
#: failure must never affect the coder's build.
_DEFAULT_USAGE_LOG = Path(r"C:\Users\mrbla\agentic-setup\state\research-usage.jsonl")


def _log_usage(*, query: str, outcome: str, exact_hits: int, search_hits: int) -> None:
    try:
        log_path = Path(os.environ.get("BLARAI_RESEARCH_USAGE_LOG", "").strip() or _DEFAULT_USAGE_LOG)
        log_path.parent.mkdir(parents=True, exist_ok=True)
        record = {
            "ts": time.time(),
            "caller": "search_docs_cli",
            "query": query[:200],  # cap: this is a usage log, not a transcript
            "outcome": outcome,  # "unavailable" | "no_match" | "hit"
            "exact_hits": exact_hits,
            "search_hits": search_hits,
        }
        with open(log_path, "a", encoding="utf-8") as fh:
            fh.write(json.dumps(record, ensure_ascii=False) + "\n")
    except Exception:  # noqa: BLE001 -- a usage-log failure must never affect the coder
        pass


class ResearchUnavailable(RuntimeError):
    """The local research substrate cannot be consulted (fail-closed)."""


def is_enabled() -> bool:
    """The DORMANT gate: ``BLARAI_RESEARCH_DOCS`` truthy. Default OFF."""
    return os.environ.get("BLARAI_RESEARCH_DOCS", "").strip().lower() in _TRUTHY


def _blarai_repo() -> Path:
    return Path(os.environ.get("BLARAI_REPO", "").strip() or _DEFAULT_BLARAI_REPO)


def _load_research():
    """Import BlarAI's zero-egress ``shared.research`` package (SSOT for the ladder).

    Adds the BlarAI repo root to ``sys.path`` so ``shared.research`` resolves. Raises
    :class:`ResearchUnavailable` (fail-closed) when the repo/package is not present."""
    repo = _blarai_repo()
    if not (repo / "shared" / "research" / "__init__.py").is_file():
        raise ResearchUnavailable(
            f"BlarAI research package not found under {repo} — set BLARAI_REPO to the "
            f"BlarAI repo root. The local docset substrate lives there (#746)."
        )
    repo_str = str(repo)
    if repo_str not in sys.path:
        sys.path.insert(0, repo_str)
    try:
        import shared.research as research  # noqa: WPS433 (deliberate lazy import)
    except Exception as exc:  # noqa: BLE001 — any import failure is fail-closed
        raise ResearchUnavailable(
            f"could not import shared.research from {repo}: {exc}"
        ) from exc
    return research


def _open_index(research):
    """Open the persisted docset index READ-ONLY (never build — a coder run must not
    trigger a tens-of-seconds index build). Fail-closed with the stager named."""
    index_dir = os.environ.get("BLARAI_DOCSET_INDEX_DIR", "").strip() or None
    corpus_dir = os.environ.get("BLARAI_DOCSET_CORPUS_DIR", "").strip() or None
    try:
        return research.load_index(
            index_dir=Path(index_dir) if index_dir else None,
            corpus_dir=Path(corpus_dir) if corpus_dir else None,
        )
    except research.ResearchIndexError as exc:
        # IndexNotBuilt / CorpusMissing / Stale — all fail-closed, message already
        # names scripts/stage_docsets.py where relevant.
        raise ResearchUnavailable(str(exc)) from exc


def _hit_to_dict(hit) -> dict:
    excerpt = (hit.excerpt or "")[:_TOOL_EXCERPT_MAX]
    return {
        "source": hit.source,
        "title": hit.title,
        "path": hit.path,
        "score": round(float(hit.score), 4),
        "excerpt": excerpt,
    }


def run_lookup(query: str, k: int, research, index) -> dict:
    """The deterministic-first ladder over the LOCAL index. Returns a result dict.

    1. ``exact_lookup`` — exact symbol / error-token match (score 1.0/0.9).
    2. ``search_docs`` — floor-gated lexical BM25 (only reached if the query still
       needs breadth; nothing above the floor => empty, the pull-not-push STOP).

    ``hits_found`` is False when NEITHER rung yields anything above the floor — the
    honest "no high-value local answer, proceed without" signal."""
    query = (query or "").strip()
    if not query:
        return {"available": True, "query": query, "hits_found": False,
                "exact": [], "search": [], "message": "empty query."}

    exact = [_hit_to_dict(h) for h in research.exact_lookup(query, index=index)]
    searched = [_hit_to_dict(h) for h in research.search_docs(query, k=k, index=index)]
    # De-dup: drop a search hit whose (source, page) an exact hit already covers
    # (an exact path is ``page#fragment`` over the search copy's ``page``).
    exact_pages = {(h["source"], h["path"].partition("#")[0]) for h in exact}
    searched = [h for h in searched if (h["source"], h["path"]) not in exact_pages]

    hits_found = bool(exact or searched)
    message = (
        "local docs found (deterministic-first)."
        if hits_found
        else "no high-value local match above the relevance floor — proceed without "
             "it (do not invent an answer)."
    )
    _log_usage(
        query=query, outcome="hit" if hits_found else "no_match",
        exact_hits=len(exact), search_hits=len(searched),
    )
    return {
        "available": True,
        "query": query,
        "hits_found": hits_found,
        "exact": exact,
        "search": searched,
        "message": message,
    }


def _render_human(result: dict) -> str:
    if not result.get("available", False):
        return f"[research: {result.get('reason', 'unavailable')}] {result.get('message', '')}"
    lines: list[str] = [f"[research] {result['message']}"]
    for label, hits in (("EXACT", result["exact"]), ("SEARCH", result["search"])):
        for h in hits:
            lines.append(f"  ({label} {h['score']:.2f}) [{h['source']}] {h['title']} — {h['path']}")
            if h["excerpt"]:
                lines.append(f"      {h['excerpt']}")
    return "\n".join(lines)


def main(argv: "list[str] | None" = None) -> int:
    parser = argparse.ArgumentParser(
        prog="search_docs",
        description="LOCAL offline docset lookup for the coding fleet (#746). "
                    "Deterministic-first, relevance-gated, zero egress, dormant by default.",
    )
    parser.add_argument("query", nargs="?", default="",
                        help="symbol, error line, or question (a CONCRETE named gap).")
    parser.add_argument("-k", type=int, default=4,
                        help="max lexical-search hits (default 4).")
    parser.add_argument("--json", action="store_true",
                        help="emit a JSON result object instead of human text.")
    args = parser.parse_args(argv)

    # DORMANT gate — never even open the index while off.
    if not is_enabled():
        result = {
            "available": False,
            "reason": "dormant",
            "message": "local research substrate is DORMANT — set BLARAI_RESEARCH_DOCS=1 "
                       "to enable (off by default, #746). No index was consulted.",
        }
        print(json.dumps(result) if args.json else _render_human(result))
        return EXIT_OK  # dormant is a clean no-op, not an error

    if not (args.query or "").strip():
        print("search_docs: a query is required (a concrete symbol/error/question).",
              file=sys.stderr)
        return EXIT_BAD_ARGS

    try:
        research = _load_research()
        index = _open_index(research)
    except ResearchUnavailable as exc:
        result = {"available": False, "reason": "index_unavailable", "message": str(exc)}
        print(json.dumps(result) if args.json else _render_human(result),
              file=sys.stderr if not args.json else sys.stdout)
        return EXIT_UNAVAILABLE

    try:
        result = run_lookup(args.query, max(0, args.k), research, index)
    finally:
        try:
            index.close()
        except Exception:  # noqa: BLE001 — close is best-effort
            pass

    print(json.dumps(result) if args.json else _render_human(result))
    return EXIT_OK


if __name__ == "__main__":
    raise SystemExit(main())
