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

DORMANT BY DEFAULT, AND THE ANSWER IS READ FROM DISK (#1206). Whether this tool is armed
is decided by ONE committed line — ``research_docs`` in ``configs/fleet-driver.json`` —
which this module resolves relative to its OWN location and reads AT THE POINT OF USE,
on every invocation. It does not learn its state by environment inheritance, because a
capability that arrives only through the environment is armed for whoever happened to be
spawned by the right parent and silently dormant for everyone else: an already-running
session, a crash-recovery relaunch, a hand-started process, anything after a reboot. A
setting that has to be re-exported to survive a restart is not a setting.

Only the literal JSON boolean ``true`` arms it. A string ``"true"``, a ``1``, a typo, or
a missing key all mean dormant. Flipping it is a deliberate go-live, not a shell command.

THREE STATES, never two — "off" and "cannot tell" are different answers and this reports
them differently (both DENY; see :func:`resolve_arming`):
  armed       the manifest says true.
  dormant     the manifest says otherwise, or an operator forced it off (see below).
  unresolved  the manifest could not be read. Refused fail-closed AND reported as
              unknown, never silently downgraded to a confident "switched off".

FAIL-CLOSED: if the docset index is not staged/built, this refuses with a clear message
naming BlarAI's stager (``scripts/stage_docsets.py``) and a non-zero exit — a missing
corpus is an operator problem, never a fabricated "answer".

Environment. This block previously opened "none of these can ARM the tool", which was
FALSE and had already propagated into a ticket record and two review messages before an
adversarial check caught it (2026-07-30). ``BLARAI_RESEARCH_DOCS`` cannot arm — that is
real and toggle-tested. ``BLARAI_FLEET_DRIVER_CONFIG`` CAN, by pointing the reader at a
different manifest, and nothing tested that it could not. Stated exactly, per variable:
  BLARAI_RESEARCH_DOCS      CANNOT ARM. Emergency stop only: a falsy value (``0``/``false``/
                            ``no``/``off``) forces dormant without editing a committed file
                            — useful to kill the capability in a running process. A truthy
                            value has NO effect; the manifest is the authority.
  BLARAI_FLEET_DRIVER_CONFIG  CAN ARM, by overriding which manifest is read: aimed at an
                            armed manifest it arms the tool from any parent process, and it
                            redirects the PowerShell side too, so both halves agree while
                            both point somewhere unintended. Intended for verify suites and
                            tests; production leaves it unset, but nothing ENFORCES that.
                            Whether it should be gated in production is an operator posture
                            decision, tracked on #1206 — do not restate it as settled here.
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

#: Falsy spellings recognised by the BLARAI_RESEARCH_DOCS emergency stop.
_FALSY = frozenset({"0", "false", "no", "off"})

#: The three arming states. "dormant" and "unresolved" both DENY; they are distinct
#: because "switched off" and "I could not find out" are different facts, and reporting
#: the second as the first is how a broken configuration comes to look like a decision.
ARMED = "armed"
DORMANT = "dormant"
UNRESOLVED = "unresolved"

#: The committed manifest that owns the arming decision, resolved from THIS FILE's
#: location so it survives any cwd, any parent process, and any reboot. Overridable by
#: path (not by value) for verify suites via BLARAI_FLEET_DRIVER_CONFIG.
_MANIFEST_RELATIVE = ("configs", "fleet-driver.json")
_MANIFEST_KEY = "research_docs"

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
        # WHO ASKED (#1206). Until 2026-08-06 every record was a bare
        # caller="search_docs_cli", so a coder's lookup and a developer's diagnostic
        # probe were INDISTINGUISHABLE. That is not cosmetic: #1206's acceptance
        # predicate is "this ledger gains records whose caller is the CLI", and on
        # 2026-08-06 a hand-run probe from a dev session landed in it mid-battery and
        # was very nearly read as the coder finally using the tool -- the opposite of
        # the truth. The ledger has to answer "who asked", or it cannot answer the
        # only question it exists for.
        #
        # cwd is the discriminator that costs nothing: the coder always runs inside
        # its task worktree (state\worktrees\<job>-<task>), a dev probe never does.
        cwd = ""
        try:
            cwd = str(Path.cwd())
        except Exception:  # noqa: BLE001 -- a deleted cwd must not break the log
            cwd = "<unavailable>"
        record = {
            "ts": time.time(),
            "caller": "search_docs_cli",
            "query": query[:200],  # cap: this is a usage log, not a transcript
            "outcome": outcome,  # "unavailable" | "no_match" | "hit"
            "exact_hits": exact_hits,
            "search_hits": search_hits,
            "cwd": cwd[:300],
            # Set by the fleet when it spawns a coder; absent for anything else. Read
            # from the environment rather than inferred, so "I do not know" stays
            # distinguishable from "not a coder".
            "fleet_task": os.environ.get("BLARAI_FLEET_TASK", "") or "",
        }
        with open(log_path, "a", encoding="utf-8") as fh:
            fh.write(json.dumps(record, ensure_ascii=False) + "\n")
    except Exception:  # noqa: BLE001 -- a usage-log failure must never affect the coder
        pass


class ResearchUnavailable(RuntimeError):
    """The local research substrate cannot be consulted (fail-closed)."""


def manifest_path() -> Path:
    """The manifest this process will consult, resolved from THIS FILE, not from cwd,
    not from an inherited variable. ``<repo>/tools/search_docs.py`` ->
    ``<repo>/configs/fleet-driver.json``."""
    override = os.environ.get("BLARAI_FLEET_DRIVER_CONFIG", "").strip()
    if override:
        return Path(override)
    return Path(__file__).resolve().parent.parent.joinpath(*_MANIFEST_RELATIVE)


def resolve_arming() -> "tuple[str, str]":
    """Read the arming decision off disk, right now. Returns ``(state, reason)`` where
    state is :data:`ARMED`, :data:`DORMANT` or :data:`UNRESOLVED`.

    This is the durability contract. Every caller — dispatched by the fleet, started by
    hand, relaunched after a crash, first run after a reboot — resolves the SAME answer
    from the SAME committed file, because nothing here depends on what the parent process
    happened to export. The environment can only ever take the capability AWAY.
    """
    forced = os.environ.get("BLARAI_RESEARCH_DOCS")
    if forced is not None and forced.strip().lower() in _FALSY:
        return DORMANT, (
            f"forced off by BLARAI_RESEARCH_DOCS={forced.strip()!r} (operator emergency "
            f"stop; the manifest was not consulted)"
        )

    path = manifest_path()
    try:
        raw = path.read_text(encoding="utf-8")
    except FileNotFoundError:
        return UNRESOLVED, f"arming manifest not found at {path}"
    except OSError as exc:  # unreadable / permissions / device error
        return UNRESOLVED, f"arming manifest at {path} could not be read: {exc}"
    try:
        data = json.loads(raw)
    except ValueError as exc:
        return UNRESOLVED, f"arming manifest at {path} is not valid JSON: {exc}"
    if not isinstance(data, dict):
        return UNRESOLVED, f"arming manifest at {path} is not a JSON object"

    value = data.get(_MANIFEST_KEY)
    # `is True` and not truthiness: JSON 1 and "true" are NOT an arming decision, and
    # `1 == True` in Python would quietly accept one of them.
    if value is True:
        return ARMED, f"armed by {path} {_MANIFEST_KEY}=true"
    if _MANIFEST_KEY not in data:
        return DORMANT, f"{path} has no {_MANIFEST_KEY} key (deny-by-default)"
    return DORMANT, (
        f"{path} {_MANIFEST_KEY}={value!r} — only the JSON boolean true arms it"
    )


def is_enabled() -> bool:
    """True only when the manifest arms this tool. Convenience over
    :func:`resolve_arming`; callers that need to tell "off" from "cannot tell" must use
    :func:`resolve_arming` instead, because both answer False here."""
    return resolve_arming()[0] == ARMED


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

    # ARMING gate — resolved off disk on every call, never inherited. The index is not
    # opened unless the manifest armed us.
    state, why = resolve_arming()
    if state is not ARMED:
        if state == UNRESOLVED:
            # NOT "switched off". We could not find out, so we deny AND say so — a
            # broken configuration must never be reported as a decision (#1206).
            result = {
                "available": False,
                "reason": UNRESOLVED,
                "message": f"could not determine whether the local research substrate is "
                           f"armed: {why}. Refusing fail-closed. This is an unreadable "
                           f"configuration, NOT a 'switched off' answer — fix the "
                           f"manifest rather than assuming either state.",
            }
            _log_usage(query=args.query or "", outcome=UNRESOLVED, exact_hits=0, search_hits=0)
            print(json.dumps(result) if args.json else _render_human(result))
            return EXIT_UNAVAILABLE
        result = {
            "available": False,
            "reason": DORMANT,
            "message": f"local research substrate is DORMANT ({why}). Arm it by setting "
                       f"{_MANIFEST_KEY}=true in the fleet manifest (#1206). No index "
                       f"was consulted.",
        }
        print(json.dumps(result) if args.json else _render_human(result))
        return EXIT_OK  # a deliberate dormant is a clean no-op, not an error

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
