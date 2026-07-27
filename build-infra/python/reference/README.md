# Python project skeleton (BlarAI dispatch fleet)

A minimal, clean, **offline** Python project the fleet seeds into a fresh Python target.
**Extend it** -- add the task's modules under `app/` and matching tests under `tests/`;
keep `pyproject.toml`. Don't create loose top-level scripts.

| Path | What it is |
|---|---|
| `app/` | The package (importable as `app`). Put the task's real logic in modules here. |
| `tests/` | pytest tests. `tests/test_smoke.py` is the neutral toolchain proof -- keep it; add the real tests beside it. |
| `pyproject.toml` | Project metadata + setuptools config (packages scoped to `app*`, so a root helper never trips the flat-layout error) + pytest `testpaths`/`pythonpath`. |

The seed is deliberately **neutral**: it proves the toolchain (imports, pytest,
tmp_path) and asserts nothing about the product. Nothing seeded here needs deleting
later -- every function in the shipped tree should be one the task asked for.

Zero third-party dependencies, so it builds and tests with no network. Run tests with
`pytest -q` (the fleet runs `pytest` with the project root on `PYTHONPATH`).

## House rules for the code and tests you add

**1. Interactive entry points take their I/O as a parameter.** Never bury `input()`
inside logic; inject it, so tests drive the loop with a stub instead of a tty:

```python
# app/quiz.py -- the interactive loop takes its input source as a parameter
def run_quiz(cards, answer_fn):
    """answer_fn(prompt) -> str. The cli passes input; tests pass a stub."""
    score = 0
    for question, answer in cards:
        if answer_fn(question).strip() == answer:
            score += 1
    return score

# app/cli.py -- only the thin entry point touches real stdin
from app.quiz import run_quiz

def main():
    print(run_quiz([("2+2?", "4")], answer_fn=input))

# tests/test_quiz.py -- no tty needed: pass the stub
from app.quiz import run_quiz

def test_run_quiz_scores_answers():
    answers = iter(["4"])
    assert run_quiz([("2+2?", "4")], answer_fn=lambda prompt: next(answers)) == 1
```

**2. Test data lives under pytest's `tmp_path`, never at the repo root.** A test that
reads or writes a shared repo-root data file leaks state between tests and runs;
`tests/test_smoke.py` models the pattern. A test leaves the working tree
byte-identical after it runs.
