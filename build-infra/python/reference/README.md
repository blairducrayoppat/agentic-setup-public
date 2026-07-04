# Python project skeleton (BlarAI dispatch fleet)

A minimal, clean, **offline** Python project the fleet seeds into a fresh Python target.
**Extend it** -- add modules under `app/` and matching tests under `tests/`; keep
`pyproject.toml`. Don't create loose top-level scripts.

| Path | What it is |
|---|---|
| `app/` | The package (importable as `app`). Put logic in modules like `app/core.py`. |
| `tests/` | pytest tests (`from app.core import ...`). |
| `pyproject.toml` | Project metadata + setuptools config (packages scoped to `app*`, so a root helper never trips the flat-layout error) + pytest `testpaths`. |

Zero third-party dependencies, so it builds and tests with no network. Run tests with
`pytest -q` (the fleet runs `pytest` with the project root on `PYTHONPATH`).
