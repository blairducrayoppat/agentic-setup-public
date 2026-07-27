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


def _enable(monkeypatch, index_dir: Path, corpus: Path) -> None:
    monkeypatch.setenv("BLARAI_RESEARCH_DOCS", "1")
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


def test_dormant_by_default_consults_no_index(monkeypatch):
    """Unset BLARAI_RESEARCH_DOCS => dormant result, exit 0, and the index is NEVER
    opened (a bogus index dir proves the short-circuit — no fail-closed error)."""
    monkeypatch.delenv("BLARAI_RESEARCH_DOCS", raising=False)
    monkeypatch.setenv("BLARAI_DOCSET_INDEX_DIR", r"Z:\does\not\exist")
    code, result = _run_json(["--json", "json.dumps"])
    assert code == search_docs.EXIT_OK
    assert result["available"] is False and result["reason"] == "dormant"


@pytest.mark.parametrize("val", ["", "0", "false", "no", "off", "nope"])
def test_is_enabled_false_values(monkeypatch, val):
    monkeypatch.setenv("BLARAI_RESEARCH_DOCS", val)
    assert search_docs.is_enabled() is False


@pytest.mark.parametrize("val", ["1", "true", "TRUE", "yes", "On"])
def test_is_enabled_true_values(monkeypatch, val):
    monkeypatch.setenv("BLARAI_RESEARCH_DOCS", val)
    assert search_docs.is_enabled() is True


# ---------------------------------------------------------------------------
# FAIL-CLOSED when the index is absent
# ---------------------------------------------------------------------------


def test_enabled_but_index_absent_fails_closed(monkeypatch, tmp_path):
    """Enabled but no built index => available:false, reason index_unavailable,
    non-zero exit, and the message names BlarAI's stager. Never a fabricated hit."""
    monkeypatch.setenv("BLARAI_RESEARCH_DOCS", "1")
    monkeypatch.setenv("BLARAI_REPO", str(_blarai_repo()))
    monkeypatch.setenv("BLARAI_DOCSET_INDEX_DIR", str(tmp_path / "never_built"))
    monkeypatch.setenv("BLARAI_DOCSET_CORPUS_DIR", str(tmp_path / "absent"))
    code, result = _run_json(["--json", "json.dumps"])
    assert code == search_docs.EXIT_UNAVAILABLE
    assert result["available"] is False and result["reason"] == "index_unavailable"


def test_enabled_but_blarai_repo_missing_fails_closed(monkeypatch, tmp_path):
    monkeypatch.setenv("BLARAI_RESEARCH_DOCS", "1")
    monkeypatch.setenv("BLARAI_REPO", str(tmp_path / "not-blarai"))
    code, result = _run_json(["--json", "json.dumps"])
    assert code == search_docs.EXIT_UNAVAILABLE
    assert result["available"] is False and result["reason"] == "index_unavailable"


# ---------------------------------------------------------------------------
# Deterministic-first ladder over a real built index
# ---------------------------------------------------------------------------


def test_exact_symbol_hit(monkeypatch, fixture_index):
    index_dir, corpus = fixture_index
    _enable(monkeypatch, index_dir, corpus)
    code, result = _run_json(["--json", "json.dumps"])
    assert code == search_docs.EXIT_OK
    assert result["available"] is True and result["hits_found"] is True
    assert result["exact"], "an exact symbol must resolve deterministically"
    top = result["exact"][0]
    assert top["path"] == "library/json#json.dumps" and top["score"] == 1.0


def test_error_line_resolves_the_exception_symbol(monkeypatch, fixture_index):
    index_dir, corpus = fixture_index
    _enable(monkeypatch, index_dir, corpus)
    code, result = _run_json(
        ["--json", "ValueError: invalid literal for int() with base 10: 'x'"]
    )
    assert code == search_docs.EXIT_OK
    assert any(h["title"] == "ValueError" for h in result["exact"])


def test_search_floor_stops_junk_query(monkeypatch, fixture_index):
    """A query the corpus cannot answer above the relevance floor => hits_found False
    and the honest 'proceed without it' message (pull-not-push STOP)."""
    index_dir, corpus = fixture_index
    _enable(monkeypatch, index_dir, corpus)
    code, result = _run_json(["--json", "qqxjz wvvbnq zzptk purple elephant birthday"])
    assert code == search_docs.EXIT_OK
    assert result["hits_found"] is False
    assert result["exact"] == [] and result["search"] == []
    assert "proceed without" in result["message"]


def test_human_output_is_produced_without_json_flag(monkeypatch, fixture_index):
    import io
    import contextlib

    index_dir, corpus = fixture_index
    _enable(monkeypatch, index_dir, corpus)
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
