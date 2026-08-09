"""#746 — tools/search_docs.py: the coder's LOCAL offline docset lookup.

Proves the four load-bearing properties: DORMANT by default (no index consulted),
FAIL-CLOSED when the index is absent, the deterministic-first ladder over a real
built index (exact + error-symbol + floor-gated search + STOP), and ZERO egress by
construction. Reuses BlarAI's ``shared.research`` (the single source of truth for the
ladder) to build a tiny hash-pinned FIXTURE index in ``tmp_path`` — never the real
staged corpus, never any network.

Run with BlarAI's venv pytest (it carries the deps):
  BLARAI_REPO=C:/Users/mrbla/blarai \
  <blarai>/.venv/Scripts/python -m pytest tools/tests/test_search_docs.py
"""

from __future__ import annotations

import ast
import hashlib
import json
import os
import sys
from pathlib import Path

import pytest

_TOOLS_DIR = Path(__file__).resolve().parents[1]
if str(_TOOLS_DIR) not in sys.path:
    sys.path.insert(0, str(_TOOLS_DIR))

import search_docs  # noqa: E402 — after the sys.path insert


# ---------------------------------------------------------------------------
# BlarAI shared.research (SSOT) — used to BUILD the fixture index
# ---------------------------------------------------------------------------


def _blarai_repo() -> Path:
    return Path(os.environ.get("BLARAI_REPO", "").strip() or r"C:\Users\mrbla\blarai")


def _import_research():
    repo = _blarai_repo()
    if not (repo / "shared" / "research" / "__init__.py").is_file():
        pytest.skip(f"BlarAI shared.research not found under {repo} (set BLARAI_REPO)")
    if str(repo) not in sys.path:
        sys.path.insert(0, str(repo))
    import shared.research as research  # noqa: WPS433

    return research


_JSON_PAGE_HTML = (
    "<h1>json — JSON encoder and decoder</h1>"
    "<p>Serialization of python objects to JSON.</p>"
    '<dl><dt id="json.dumps"><code>json.dumps(obj, indent=None)</code></dt>'
    "<dd>Serialize obj to a JSON formatted str using this conversion table.</dd></dl>"
)
_EXC_PAGE_HTML = (
    "<h1>Built-in Exceptions</h1>"
    '<dl><dt id="ValueError"><code>exception ValueError</code></dt>'
    "<dd>Raised when an operation receives an argument of the right type but an "
    "inappropriate value.</dd></dl>"
)


@pytest.fixture(scope="module")
def fixture_index(tmp_path_factory):
    """Build a tiny DevDocs-only docset index (json.dumps + ValueError) and yield
    (index_dir, corpus_dir) for the CLI env overrides."""
    research = _import_research()
    di = research.docset_index
    root = tmp_path_factory.mktemp("search_docs_fixture")
    corpus = root / "docsets"
    dd = corpus / "devdocs" / "python~3.11"
    dd.mkdir(parents=True)
    entries = [
        {"name": "json.dumps()", "path": "library/json#json.dumps", "type": "Data"},
        {"name": "json", "path": "library/json", "type": "Data"},
        {"name": "ValueError", "path": "library/exceptions#ValueError", "type": "Exc"},
    ]
    (dd / "index.json").write_text(json.dumps({"entries": entries}), encoding="utf-8")
    (dd / "db.json").write_text(
        json.dumps(
            {"library/json": _JSON_PAGE_HTML, "library/exceptions": _EXC_PAGE_HTML}
        ),
        encoding="utf-8",
    )

    def _sha(rel: str) -> str:
        return hashlib.sha256((corpus / rel).read_bytes()).hexdigest()

    files = [
        ("dd-index", "devdocs/python~3.11/index.json"),
        ("dd-db", "devdocs/python~3.11/db.json"),
    ]
    artifacts = [
        {"name": n, "file": r, "sha256": _sha(r), "bytes": (corpus / r).stat().st_size}
        for n, r in files
    ]
    (corpus / di.CORPUS_MANIFEST_NAME).write_text(
        json.dumps({"schema": "blarai-docset-manifest/v1", "artifacts": artifacts}),
        encoding="utf-8",
    )
    index_dir = root / "index"
    di.build_index(corpus_dir=corpus, index_dir=index_dir)
    return index_dir, corpus


@pytest.fixture(autouse=True)
def _isolate_usage_log(tmp_path: Path, monkeypatch: pytest.MonkeyPatch) -> None:
    """Every enabled-path test exercises run_lookup's ALWAYS-ON usage logging as a
    side effect. Without this, a test run appends real-looking records to the
    operator's actual state/research-usage.jsonl (found 2026-07-24: synthetic
    hit/miss/unavailable records from a pytest run were briefly mistaken for a
    live-dispatch anomaly). Redirect to a throwaway per-test path instead."""
    monkeypatch.setenv("BLARAI_RESEARCH_USAGE_LOG", str(tmp_path / "test-research-usage.jsonl"))


class _Absent:
    """Sentinel: write NO research_docs key at all (distinct from writing null)."""

    def __repr__(self) -> str:  # pragma: no cover - debugging aid
        return "<absent>"


_ABSENT = _Absent()


def _write_manifest(tmp_path: Path, research_docs, *, name: str = "fleet-driver.json") -> Path:
    """Write a fleet-driver manifest and return its path. ``research_docs`` is written
    verbatim, so a test can plant a string/int/absent value and watch it be refused."""
    body: dict = {"driver": "stdin", "containment": "off", "acp": {}}
    if research_docs is not _ABSENT:
        body["research_docs"] = research_docs
    path = tmp_path / name
    path.write_text(json.dumps(body), encoding="utf-8")
    return path


def _point_at_manifest(monkeypatch, path: Path) -> None:
    """Arming is resolved from the manifest ON DISK, never from an inherited variable, so
    the tests aim the real resolver at a real file exactly the way production does."""
    monkeypatch.setenv("BLARAI_FLEET_DRIVER_CONFIG", str(path))
    monkeypatch.delenv("BLARAI_RESEARCH_DOCS", raising=False)


def _enable(monkeypatch, index_dir: Path, corpus: Path, tmp_path: Path) -> None:
    _point_at_manifest(monkeypatch, _write_manifest(tmp_path, True))
    monkeypatch.setenv("BLARAI_REPO", str(_blarai_repo()))
    monkeypatch.setenv("BLARAI_DOCSET_INDEX_DIR", str(index_dir))
    monkeypatch.setenv("BLARAI_DOCSET_CORPUS_DIR", str(corpus))


def _run_json(argv: list[str]) -> tuple[int, dict]:
    """Run main(argv) and parse the JSON printed to stdout."""
    import io
    import contextlib

    buf = io.StringIO()
    with contextlib.redirect_stdout(buf):
        code = search_docs.main(argv)
    return code, json.loads(buf.getvalue().strip())


# ---------------------------------------------------------------------------
# DORMANT by default
# ---------------------------------------------------------------------------


def test_dormant_manifest_consults_no_index(monkeypatch, tmp_path):
    """research_docs=false => dormant result, exit 0, and the index is NEVER opened
    (a bogus index dir proves the short-circuit — no fail-closed error)."""
    _point_at_manifest(monkeypatch, _write_manifest(tmp_path, False))
    monkeypatch.setenv("BLARAI_DOCSET_INDEX_DIR", r"Z:\does\not\exist")
    code, result = _run_json(["--json", "json.dumps"])
    assert code == search_docs.EXIT_OK
    assert result["available"] is False and result["reason"] == search_docs.DORMANT


@pytest.mark.parametrize("planted", [False, _ABSENT, "true", "1", 1, 0, None, "yes", [], {}])
def test_only_the_json_boolean_true_arms_it(monkeypatch, tmp_path, planted):
    """DENY-BY-DEFAULT truth table. A string "true", a 1, a null, a missing key — every
    near-miss spelling of yes is dormant. `1 == True` in Python, so this also pins that
    the check is identity, not truthiness."""
    _point_at_manifest(monkeypatch, _write_manifest(tmp_path, planted))
    state, reason = search_docs.resolve_arming()
    assert state == search_docs.DORMANT, f"{planted!r} must not arm the tool ({reason})"
    assert search_docs.is_enabled() is False


def test_the_json_boolean_true_arms_it(monkeypatch, tmp_path):
    _point_at_manifest(monkeypatch, _write_manifest(tmp_path, True))
    state, reason = search_docs.resolve_arming()
    assert state == search_docs.ARMED and "research_docs=true" in reason
    assert search_docs.is_enabled() is True


# ---------------------------------------------------------------------------
# DURABILITY — the answer comes off disk, not out of the parent process
# ---------------------------------------------------------------------------


@pytest.mark.parametrize("val", ["1", "true", "TRUE", "yes", "On", "anything"])
def test_the_environment_can_never_arm_it(monkeypatch, tmp_path, val):
    """The old contract's arming variable. A truthy BLARAI_RESEARCH_DOCS against a dormant
    manifest must NOT arm the tool — otherwise a shell profile, a stale parent, or a
    developer's $env: silently grants a build-time capability nobody committed."""
    _point_at_manifest(monkeypatch, _write_manifest(tmp_path, False))
    monkeypatch.setenv("BLARAI_RESEARCH_DOCS", val)
    assert search_docs.resolve_arming()[0] == search_docs.DORMANT
    assert search_docs.is_enabled() is False


@pytest.mark.parametrize("val", ["0", "false", "no", "off", "  OFF  "])
def test_the_environment_can_always_disarm_it(monkeypatch, tmp_path, val):
    """The emergency stop, which is the one direction an environment variable is allowed
    to move: an explicitly falsy value forces dormant even against an ARMED manifest, so a
    running process can be killed without editing a committed file."""
    _point_at_manifest(monkeypatch, _write_manifest(tmp_path, True))
    monkeypatch.setenv("BLARAI_RESEARCH_DOCS", val)
    state, reason = search_docs.resolve_arming()
    assert state == search_docs.DORMANT and "emergency stop" in reason


def test_an_unreadable_manifest_is_unresolved_not_dormant(monkeypatch, tmp_path):
    """"Switched off" and "I could not find out" are different facts. A missing or corrupt
    manifest DENIES (fail-closed) but reports UNRESOLVED with a non-zero exit — reporting
    it as `dormant` would dress a broken configuration up as a decision."""
    _point_at_manifest(monkeypatch, tmp_path / "no-such-manifest.json")
    code, result = _run_json(["--json", "json.dumps"])
    assert code == search_docs.EXIT_UNAVAILABLE
    assert result["reason"] == search_docs.UNRESOLVED
    assert result["available"] is False
    assert "NOT a 'switched off' answer" in result["message"]

    corrupt = tmp_path / "corrupt.json"
    corrupt.write_text("{ not json at all", encoding="utf-8")
    _point_at_manifest(monkeypatch, corrupt)
    code, result = _run_json(["--json", "json.dumps"])
    assert code == search_docs.EXIT_UNAVAILABLE and result["reason"] == search_docs.UNRESOLVED


def test_unresolved_is_recorded_in_the_usage_ledger(monkeypatch, tmp_path):
    """An unreadable manifest is an anomaly someone must be able to find later, so it
    lands in the durable usage record rather than only on a transient stdout."""
    log = tmp_path / "usage.jsonl"
    monkeypatch.setenv("BLARAI_RESEARCH_USAGE_LOG", str(log))
    _point_at_manifest(monkeypatch, tmp_path / "gone.json")
    _run_json(["--json", "json.dumps"])
    records = [json.loads(line) for line in log.read_text(encoding="utf-8").splitlines() if line.strip()]
    assert any(r["outcome"] == search_docs.UNRESOLVED for r in records), records


def test_manifest_resolves_from_the_tool_not_the_cwd_or_env(monkeypatch):
    """The default manifest path is derived from THIS FILE's location. That is what makes
    the setting survive a reboot, a different working directory, and a process nobody
    configured: there is no ambient state to lose."""
    monkeypatch.delenv("BLARAI_FLEET_DRIVER_CONFIG", raising=False)
    resolved = search_docs.manifest_path()
    assert resolved == _TOOLS_DIR.parent / "configs" / "fleet-driver.json"
    assert resolved.is_file(), f"the committed manifest must exist at {resolved}"


def test_the_shipped_manifest_matches_the_recorded_go_live(monkeypatch):
    """The shipped-state lock, asserted against the file that actually ships.

    WAS "is_dormant" until 2026-08-06, when the LA armed the capability in person
    (#1206, agentic-setup b13344d) after it had sat installed-but-unused since
    2026-07-24. This test FIRED on that change, which is exactly what it is for: nobody
    moves this switch silently in either direction.

    The purpose is unchanged and the assertion simply tracks the recorded decision -- it
    now fails if someone DISARMS without a decision, which is the live risk today.
    Note what this does NOT assert: that the environment can arm anything. It cannot, and
    the hostile-parent test below proves that independently of whatever ships here."""
    monkeypatch.delenv("BLARAI_FLEET_DRIVER_CONFIG", raising=False)
    monkeypatch.delenv("BLARAI_RESEARCH_DOCS", raising=False)
    state, reason = search_docs.resolve_arming()
    assert state != search_docs.DORMANT, (
        f"configs/fleet-driver.json ships DORMANT again: {reason}. If that was deliberate, "
        "record the decision on #1206 and update this test; if it was not, restore it."
    )


def _run_in_a_clean_process(tool: Path, tmp_path: Path) -> dict:
    """Run *tool* in a FRESH process carrying NO inherited arming state — the state a
    process is in after a reboot, a crash relaunch, or a hand start.

    Every BLARAI_* variable is stripped from the child. Two are then set back
    deliberately and neither can influence the arming decision: BLARAI_REPO is pointed at
    a nonexistent directory to keep the child away from the operator's real index, and
    the usage log is redirected so a test can never append to the real ledger.
    """
    import subprocess

    env = {
        k: v for k, v in os.environ.items()
        if not k.startswith("BLARAI_") and k.upper() not in {"PYTHONPATH", "PYTHONHOME"}
    }
    env["BLARAI_REPO"] = str(tmp_path / "no-such-blarai")
    env["BLARAI_RESEARCH_USAGE_LOG"] = str(tmp_path / "clean-process-usage.jsonl")
    proc = subprocess.run(
        [sys.executable, str(tool), "--json", "json.dumps"],
        capture_output=True, text=True, env=env, timeout=120,
    )
    payload = (proc.stdout or "").strip()
    assert payload, f"no JSON on stdout (rc={proc.returncode}): {proc.stderr!r}"
    return json.loads(payload)


def test_a_clean_process_still_reads_the_shipped_armed_state(tmp_path):
    """THE DURABILITY TEST, against the SHIPPED state (armed since 2026-08-06, #1206).

    Nothing set by hand, nothing inherited: a process that carries no BLARAI_* state at
    all -- after a reboot, a crash relaunch, or a hand start -- must still read what the
    manifest says. That is the whole reason arming lives in a committed file rather than
    an exported variable: otherwise this would be indistinguishable from a machine where
    someone simply forgot to export it, and only whoever was spawned by the right parent
    would be armed."""
    result = _run_in_a_clean_process(_TOOLS_DIR / "search_docs.py", tmp_path)
    assert result["reason"] != search_docs.DORMANT, result


def test_a_clean_process_still_reads_an_armed_manifest(tmp_path):
    """THE DURABILITY TEST (armed half). A repo whose committed manifest says true arms a
    process that inherited nothing at all — which is what makes the setting survive a
    reboot rather than needing a human to re-export it.

    The assertion is on `reason`, not on hits: anything other than dormant/unresolved
    means the gate opened. (Here it then fail-closes on the deliberately absent index,
    which is the correct next refusal.)"""
    repo = tmp_path / "repo"
    (repo / "tools").mkdir(parents=True)
    (repo / "configs").mkdir(parents=True)
    (repo / "tools" / "search_docs.py").write_bytes((_TOOLS_DIR / "search_docs.py").read_bytes())
    (repo / "configs" / "fleet-driver.json").write_text(
        json.dumps({"driver": "stdin", "research_docs": True, "acp": {}}), encoding="utf-8"
    )
    result = _run_in_a_clean_process(repo / "tools" / "search_docs.py", tmp_path)
    assert result["reason"] not in (search_docs.DORMANT, search_docs.UNRESOLVED), result
    assert result["reason"] == "index_unavailable", result


def test_a_clean_process_cannot_be_armed_by_a_hostile_parent(tmp_path):
    """The already-running-process failure, from the other side: a parent that exports a
    truthy BLARAI_RESEARCH_DOCS cannot arm a child whose committed manifest says false.

    DECOUPLED FROM THE SHIPPED VALUE on 2026-08-06. This test used to lean on
    configs/fleet-driver.json happening to ship dormant, so arming the capability (#1206)
    broke it -- and a SECURITY property that breaks when an unrelated config flips was
    never really testing the property. It now plants its own explicit `research_docs:
    false` manifest, so it proves the same thing whatever ships, and it will keep proving
    it after the next go-live too."""
    import subprocess

    manifest = _write_manifest(tmp_path, False)          # EXPLICITLY dormant, ours
    env = {k: v for k, v in os.environ.items() if not k.startswith("BLARAI_")}
    env["BLARAI_RESEARCH_DOCS"] = "1"          # the old arming variable, set by a parent
    env["BLARAI_FLEET_DRIVER_CONFIG"] = str(manifest)
    env["BLARAI_REPO"] = str(tmp_path / "no-such-blarai")
    env["BLARAI_RESEARCH_USAGE_LOG"] = str(tmp_path / "hostile-usage.jsonl")
    proc = subprocess.run(
        [sys.executable, str(_TOOLS_DIR / "search_docs.py"), "--json", "json.dumps"],
        capture_output=True, text=True, env=env, timeout=120,
    )
    result = json.loads((proc.stdout or "").strip())
    assert result["reason"] == search_docs.DORMANT, result


# ---------------------------------------------------------------------------
# FAIL-CLOSED when the index is absent
# ---------------------------------------------------------------------------


def test_armed_but_index_absent_fails_closed(monkeypatch, tmp_path):
    """Armed but no built index => available:false, reason index_unavailable,
    non-zero exit, and the message names BlarAI's stager. Never a fabricated hit."""
    _point_at_manifest(monkeypatch, _write_manifest(tmp_path, True))
    monkeypatch.setenv("BLARAI_REPO", str(_blarai_repo()))
    monkeypatch.setenv("BLARAI_DOCSET_INDEX_DIR", str(tmp_path / "never_built"))
    monkeypatch.setenv("BLARAI_DOCSET_CORPUS_DIR", str(tmp_path / "absent"))
    code, result = _run_json(["--json", "json.dumps"])
    assert code == search_docs.EXIT_UNAVAILABLE
    assert result["available"] is False and result["reason"] == "index_unavailable"


def test_armed_but_blarai_repo_missing_fails_closed(monkeypatch, tmp_path):
    _point_at_manifest(monkeypatch, _write_manifest(tmp_path, True))
    monkeypatch.setenv("BLARAI_REPO", str(tmp_path / "not-blarai"))
    code, result = _run_json(["--json", "json.dumps"])
    assert code == search_docs.EXIT_UNAVAILABLE
    assert result["available"] is False and result["reason"] == "index_unavailable"


# ---------------------------------------------------------------------------
# Deterministic-first ladder over a real built index
# ---------------------------------------------------------------------------


def test_exact_symbol_hit(monkeypatch, fixture_index, tmp_path):
    index_dir, corpus = fixture_index
    _enable(monkeypatch, index_dir, corpus, tmp_path)
    code, result = _run_json(["--json", "json.dumps"])
    assert code == search_docs.EXIT_OK
    assert result["available"] is True and result["hits_found"] is True
    assert result["exact"], "an exact symbol must resolve deterministically"
    top = result["exact"][0]
    assert top["path"] == "library/json#json.dumps" and top["score"] == 1.0


def test_error_line_resolves_the_exception_symbol(monkeypatch, fixture_index, tmp_path):
    index_dir, corpus = fixture_index
    _enable(monkeypatch, index_dir, corpus, tmp_path)
    code, result = _run_json(
        ["--json", "ValueError: invalid literal for int() with base 10: 'x'"]
    )
    assert code == search_docs.EXIT_OK
    assert any(h["title"] == "ValueError" for h in result["exact"])


#: A query whose terms EXIST in the fixture corpus but match it only weakly.
#: Measured 2026-07-30 against this exact fixture: normalized BM25 0.2794 on
#: ``library/exceptions`` -- comfortably under RELEVANCE_FLOOR (0.35) yet far above
#: zero, so it is the floor and nothing else that stops it. Re-measure (and re-pick)
#: if the fixture pages change: test_search_floor_admits_the_weak_match_when_lowered
#: fails loudly rather than silently if this drifts out of the band.
_WEAK_MATCH_QUERY = "an operation received an argument"

#: A floor low enough to admit :data:`_WEAK_MATCH_QUERY`'s measured score.
_LOWERED_FLOOR = 0.20


def test_unknown_terms_return_nothing(monkeypatch, fixture_index, tmp_path):
    """Terms the corpus has NEVER SEEN => hits_found False and the honest 'proceed
    without it' message (pull-not-push STOP).

    NOTE what this does and does not prove. Every term here is absent from the fixture,
    so BM25 accumulates no score at all and the result is empty at ANY floor -- this test
    passes identically with RELEVANCE_FLOOR = 0.0. It covers the unknown-vocabulary path,
    NOT the relevance gate. The floor itself is under test in
    :func:`test_search_floor_stops_weak_match` + its toggle (found 2026-07-30: this test
    was named for the floor, and a ``RELEVANCE_FLOOR 0.35 -> 0.0`` mutation SURVIVED it)."""
    index_dir, corpus = fixture_index
    _enable(monkeypatch, index_dir, corpus, tmp_path)
    code, result = _run_json(["--json", "qqxjz wvvbnq zzptk purple elephant birthday"])
    assert code == search_docs.EXIT_OK
    assert result["hits_found"] is False
    assert result["exact"] == [] and result["search"] == []
    assert "proceed without" in result["message"]


def test_search_floor_stops_weak_match(monkeypatch, fixture_index, tmp_path):
    """A query the corpus CAN score, but only weakly => stopped BY THE FLOOR.

    Unlike the unknown-terms case above, every term here appears in the fixture, so BM25
    produces a real non-zero score (0.2794 measured). It is dropped solely because it sits
    under RELEVANCE_FLOOR. Paired with the toggle below, this distinguishes a working gate
    from an absent one."""
    index_dir, corpus = fixture_index
    _enable(monkeypatch, index_dir, corpus, tmp_path)
    code, result = _run_json(["--json", _WEAK_MATCH_QUERY])
    assert code == search_docs.EXIT_OK
    assert result["hits_found"] is False
    assert result["exact"] == [] and result["search"] == []
    assert "proceed without" in result["message"]


def test_search_floor_admits_the_weak_match_when_lowered(monkeypatch, fixture_index, tmp_path):
    """THE TOGGLE: drop the floor under the SAME query's measured score and the SAME query
    now returns a hit.

    Without this half, :func:`test_search_floor_stops_weak_match` cannot tell "the floor
    rejected it" from "retrieval is broken and returns nothing for anything". The admitted
    hit's score is asserted to sit strictly inside the band [_LOWERED_FLOOR,
    RELEVANCE_FLOOR) -- so a fixture edit that moves the query out of the weak band fails
    HERE, instead of quietly making the pair vacuous again."""
    research = _import_research()
    index_dir, corpus = fixture_index
    _enable(monkeypatch, index_dir, corpus, tmp_path)
    live_floor = research.lookup.RELEVANCE_FLOOR  # read BEFORE the patch replaces it
    monkeypatch.setattr(research.lookup, "RELEVANCE_FLOOR", _LOWERED_FLOOR)
    code, result = _run_json(["--json", _WEAK_MATCH_QUERY])
    assert code == search_docs.EXIT_OK
    assert result["hits_found"] is True, (
        f"{_WEAK_MATCH_QUERY!r} must be retrievable once the floor drops to "
        f"{_LOWERED_FLOOR} -- if not, the STOP above proves nothing about the floor"
    )
    assert result["search"], "the weak match must arrive on the SEARCH rung, not EXACT"
    score = result["search"][0]["score"]
    assert _LOWERED_FLOOR <= score < live_floor, (
        f"{_WEAK_MATCH_QUERY!r} scored {score}, outside the weak band "
        f"[{_LOWERED_FLOOR}, {live_floor}) -- either the fixture moved (re-measure and "
        f"re-pick the query) or the live floor no longer stops it"
    )


def test_human_output_is_produced_without_json_flag(monkeypatch, fixture_index, tmp_path):
    import io
    import contextlib

    index_dir, corpus = fixture_index
    _enable(monkeypatch, index_dir, corpus, tmp_path)
    buf = io.StringIO()
    with contextlib.redirect_stdout(buf):
        code = search_docs.main(["json.dumps"])
    out = buf.getvalue()
    assert code == search_docs.EXIT_OK
    assert "[research]" in out and "json.dumps" in out


# ---------------------------------------------------------------------------
# ZERO EGRESS by construction
# ---------------------------------------------------------------------------

_FORBIDDEN_NETWORK_MODULES = frozenset(
    {
        "urllib", "requests", "socket", "http", "httpx", "aiohttp", "urllib3",
        "websocket", "websockets", "ftplib", "smtplib", "poplib", "imaplib",
        "telnetlib", "nntplib", "ssl", "asyncio",
    }
)


def test_search_docs_imports_no_network_machinery():
    """tools/search_docs.py must be incapable of egress BY CONSTRUCTION — no
    urllib/requests/socket/http/... imports anywhere (the runtime privacy mandate)."""
    source = (_TOOLS_DIR / "search_docs.py").read_text(encoding="utf-8")
    tree = ast.parse(source)
    for node in ast.walk(tree):
        names: list[str] = []
        if isinstance(node, ast.Import):
            names = [a.name for a in node.names]
        elif isinstance(node, ast.ImportFrom) and node.module and node.level == 0:
            names = [node.module]
        for name in names:
            assert name.split(".")[0] not in _FORBIDDEN_NETWORK_MODULES, (
                f"search_docs.py imports {name!r} — the local research tool is "
                f"zero-egress (#746)"
            )
