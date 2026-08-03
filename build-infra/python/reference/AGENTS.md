# Build rules for this project (BlarAI dispatch fleet)

<!-- BLARAI-AGENTS-SENTINEL-1142: if this line never appears in a coder transcript or
     context pack, the coder is NOT reading this file, and house rules 1 and 2 below
     have been silently lost by moving them out of README.md. That would trade a
     documentation-surface defect for a real build-quality regression. Verify the
     convention against a live run before trusting it. -->

**This file is instructions to YOU, the coder. It is not part of the delivered
product.** `README.md` is the operator's documentation — it ships to a person who
wanted the thing you are building. Rewrite it to describe what you actually built;
do not leave it describing a starter project.

You are extending a minimal, clean, **offline** Python project the fleet seeds into a
fresh Python target. **Extend it** -- add the task's modules under `app/` and matching
tests under `tests/`; keep `pyproject.toml`. Don't create loose top-level scripts.

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

**3. Ship a discoverable way to RUN it.** The person who asked for this is not a
programmer. A package they can only use by opening a Python prompt and writing import
statements is not a finished deliverable, however correct the code is. Every project
gets an entry point someone can find without reading the source:

```python
# app/__main__.py -- `python -m app` now works
import sys
from app.report import build_report

def main() -> None:
    print(build_report(sys.stdin.read()))

if __name__ == "__main__":
    main()
```

`app/__main__.py` is the preferred shape because it satisfies this rule AND the
"don't create loose top-level scripts" rule above at the same time -- it lives inside
the package, not as a stray file at the repo root. `app/cli.py` or `app/demo.py` are
equally acceptable, as is a declared console-script in `pyproject.toml`.

What does NOT count: a bare `if __name__ == "__main__":` block buried inside a logic
module. Nobody can find it, so it does not make the project runnable for the person who
asked for it.

Keep the entry point thin, exactly as rule 1's `app/cli.py` example does -- it reads
input and calls into `app/`; the logic stays in testable functions.

**4. Secrets are read from the environment, never typed into the source.** An API key,
password, token, private key block, or a database connection string with the password
inside it, written as a literal, ships to whoever gets this project and stays in its
history. Read it at the point of use, check it is there before any work starts, and say
so in `README.md`:

```python
# app/config.py -- the value lives in the environment, the NAME lives in the code
import os

def api_key() -> str:
    """Return the key, raising if the environment does not have it."""
    key = os.environ.get("BUDGET_API_KEY")
    if not key:
        raise RuntimeError("set BUDGET_API_KEY before running (see README.md)")
    return key

def check_environment() -> None:
    """Called by the entry point BEFORE any work begins, so a missing key stops the
    program immediately with a readable message instead of halfway through a request."""
    api_key()
```

```python
# app/__main__.py -- rule 3's entry point, with the check as its first act
import sys
from app.config import check_environment
from app.report import build_report

def main() -> None:
    check_environment()
    print(build_report(sys.stdin.read()))

if __name__ == "__main__":
    main()
```

The `if __name__ == "__main__":` line is not decoration: without it `python -m app`
imports the file, defines `main`, calls nothing, and exits silently -- rule 3's runnable
entry point is gone and the startup check above never runs.

"Fails at startup" is a property of WHERE THE FUNCTION IS CALLED, not of the function.
`api_key()` raises whenever it runs, so if its only caller is a request handler then it
fails mid-request -- which is the thing an early check is meant to avoid. The call in
the entry point is what actually makes the failure early; do not claim it without it.

What does NOT count: a key you made up for a demo, a "temporary" password, or a real
value moved into a `config.py` constant. Those are all hardcoded secrets. If the project
needs a value to run, ship a `.env.example` with the name and an EMPTY value.

**A long random-looking literal counts as a secret whatever you named it.** The
automatic check reads the SHAPE of the text, not the variable name: any quoted run of 24
or more characters made of letters and digits only -- no spaces, no dashes, no dots --
and containing at least one letter and at least one digit is reported. A pasted-in hash,
a sample response id, a base32 constant and a session token all match that shape, so
renaming the variable does not clear it. Work out the value instead of pasting it
(`hashlib.sha256(data).hexdigest()` inside the test that needs it), generate it when the
program runs (`secrets.token_hex(16)`), or read it from the environment as above. A
fixed value that genuinely has to be written down belongs in a file under `tests/`,
where it reads as a test fixture rather than as a live credential.

**5. Check input where it arrives, and never build code or queries by pasting text
together.** Anything from outside your own source -- a command-line argument, a form
field, a parsed file, a save file you wrote yourself last run -- is unchecked until you
check it. Check the type, check the value, reject what fails, and then let the database
driver bind the values; string-built queries are the classic way data gets stolen:

```python
# app/entries.py -- validate first, then bind with placeholders
import math

def add_entry(conn, category: str, amount: str) -> None:
    if not isinstance(category, str) or not category.strip():
        # The type hint is a note to a reader, not a check the program runs: without the
        # isinstance, category=None raises AttributeError instead of this message.
        raise ValueError("category is required")
    try:
        value = float(amount)
    except (TypeError, ValueError):
        raise ValueError(f"amount must be a number, got {amount!r}") from None
    if not math.isfinite(value):
        # "inf", "-inf", "nan" and "1e400" are all accepted by float(). They are not
        # amounts, and round() raises OverflowError on them -- which "except ValueError"
        # does NOT catch, so the check has to be here rather than in the try block.
        raise ValueError(f"amount must be a real number, got {amount!r}")
    if abs(value) >= 1e9:
        raise ValueError(f"amount is out of range: {amount!r}")
    cents = round(value * 100)
    # The ? placeholder is bound by the driver -- a category of "'; DROP TABLE" is DATA.
    conn.execute("INSERT INTO entries (category, cents) VALUES (?, ?)", (category, cents))
```

Checking the type is only half of checking the input. `float()` accepting the text is
the first half; `math.isfinite` and the range check are the half that catches the values
which are technically numbers and still wrong. Whenever a conversion can raise more than
one kind of error, catch every kind you can actually get, or rule the bad values out
before the conversion happens.

All four ways of assembling a query are the same mistake: never
`f"SELECT ... WHERE id = {user_id}"`, never `"SELECT ... " + user_id`, never
`"SELECT ... WHERE id = %s" % user_id`, never `"SELECT ... WHERE id = {}".format(user_id)`.

Watch the `%` case especially, because the correct form looks almost identical. With
PostgreSQL drivers the placeholder IS `%s`, so `cur.execute("... WHERE id = %s",
(user_id,))` is the RIGHT answer -- the driver binds it, and the comma is the whole
difference. `"... WHERE id = %s" % user_id` builds the string yourself before the driver
ever sees it. Same characters, opposite meaning: pass the values as the second argument.

And never
`eval`, `exec`, `compile`, `os.system`, `os.popen`, or `subprocess(..., shell=True)`
**anywhere in what you ship** -- nor, in any JavaScript that goes with it, `eval`,
`new Function`, or `child_process.exec`.

This is NOT scoped to text a person typed; it applies just as much to a fixed string you
wrote yourself. The automatic check reports `os.system("cls")` with its harmless fixed
argument for the same reason it reports the dangerous version: a reader cannot tell from
the call which strings will stay fixed once the project grows. To run another program,
pass an argument LIST (`subprocess.run(["git", "status"])`), never a command string; to
clear the screen or format output, use the language's own facilities rather than handing
a line to the shell.

**Placeholders bind VALUES, not names.** A `?` cannot stand in for a table name, a
column name, or `ASC`/`DESC` -- there is nothing for the driver to bind. That is not a
licence to paste the name in. Choose from a fixed set you wrote yourself and reject
anything that is not in it:

```python
# app/entries.py -- the sort order is CHOSEN from queries you wrote, never assembled
_ORDERED_QUERIES = {
    ("date", "asc"): "SELECT category, cents FROM entries ORDER BY date ASC",
    ("date", "desc"): "SELECT category, cents FROM entries ORDER BY date DESC",
    ("cents", "asc"): "SELECT category, cents FROM entries ORDER BY cents ASC",
    ("cents", "desc"): "SELECT category, cents FROM entries ORDER BY cents DESC",
}

def list_entries(conn, sort_by: str = "date", order: str = "asc") -> list:
    try:
        query = _ORDERED_QUERIES[(sort_by, order)]
    except KeyError:
        raise ValueError(f"cannot sort by {sort_by!r} {order!r}") from None
    return conn.execute(query).fetchall()
```

What does NOT count: an allowlist you check and then ignore, or one you build out of the
same input you are meant to be checking. Pasting a column name into the query AFTER
checking it against a fixed set is also safe in principle -- but the automatic check
cannot tell that apart from the unsafe version and reports it either way, so the
whole-query form above is both the safer habit and the one that reads clean.

**6. If your project produces a web page, text from a person is text, not markup.**
Every value that reaches the page is escaped on its way there -- either by the language's
escape function, or by setting the TEXT of a node you built. An escaped value inside a
string of markup you wrote is fine; a raw one is not:

```python
# app/report.py -- every value is escaped, and a link's scheme is checked before it is one
import html

def safe_href(link: str) -> str:
    """Only real http(s) links and site-relative paths become links. Anything else --
    `javascript:`, `data:`, and the network-relative `//host` and `/\\host` -- is '#'.

    The two normalisations first are not tidying, they are the check: a browser strips
    tabs and newlines out of a URL before using it (so `java<TAB>script:` becomes
    `javascript:`) and reads a backslash in `/\\host` as a slash (so it means `//host`,
    another site). Comparing the raw text would pass both straight through.
    """
    cleaned = link.strip().replace("\t", "").replace("\n", "").replace("\r", "")
    if cleaned[:7].lower() == "http://" or cleaned[:8].lower() == "https://":
        return cleaned
    if cleaned.startswith("/") and cleaned[1:2] not in ("/", "\\"):
        return cleaned
    return "#"

def row(category: str, amount: str, link: str) -> str:
    return (f'<li><a href="{html.escape(safe_href(link), quote=True)}">'
            f'{html.escape(category)}</a>: {html.escape(amount)}</li>')
```

Escaping covers less ground than it looks. `html.escape` is enough for text BETWEEN tags
and for an attribute you wrapped in quotes. It is NOT enough in three places, so do not
put a value in them at all:

* **An unquoted attribute.** `<div class={value}>` lets a space in the value start a
  whole new attribute, escaped or not. Always write the quotes: `<div class="{value}">`.
* **A URL attribute** (`href`, `src`, `action`). Escaping `javascript:alert(1)` leaves
  it a working `javascript:` link -- there is nothing in it for `html.escape` to change.
  Check the scheme first, the way `safe_href` above does.
* **Inside a `<script>` or `<style>` block.** HTML escaping means nothing in there, and
  a `</script>` inside the value ends the block early. Put the data in a quoted `data-`
  attribute instead and read it in JavaScript with `element.dataset.name`.

In any JavaScript you ship, `element.textContent = value` is safe. These six read their
input as markup and run whatever it contains, so no value may reach one: `innerHTML`,
`outerHTML`, `insertAdjacentHTML`, `document.write`, jQuery's `.html(...)`, and React's
`dangerouslySetInnerHTML`. Build the node instead --
`const li = document.createElement("li"); li.textContent = value;` -- or in React write
`{value}` in the JSX, which escapes it for you.

What does NOT count: escaping a value once when it is saved and then trusting it forever
(escape at the moment it becomes part of the page, every time), or escaping most of the
values in a template and missing one. One unescaped value is the whole hole.

**7. Saved files are read back with a data format, never with a code format.** A project
that saves and reloads its own state reaches for the shortest thing that works, and in
Python that is `pickle`. Loading a pickle does not read data -- it EXECUTES instructions
taken from the file, so anyone who can swap that file out can run whatever they like as
your program. `json` cannot do that, needs no extra package, and is readable if the
person ever opens the file:

```python
# app/store.py -- json rebuilds DATA; pickle rebuilds OBJECTS, which means it runs code
import json
from pathlib import Path

def save(entries: list[dict], path: Path) -> None:
    path.write_text(json.dumps(entries, indent=2), encoding="utf-8")

def load(path: Path) -> list[dict]:
    data = json.loads(path.read_text(encoding="utf-8"))
    if not isinstance(data, list):
        # A file you wrote last run is still input -- rule 5 applies to it too.
        raise ValueError(f"{path.name} is not a list of entries")
    return data
```

Never `pickle.load` or `pickle.loads`, never `marshal.load` or `marshal.loads`. If the
task genuinely calls for YAML, the reader is `yaml.safe_load` -- plain `yaml.load` builds
arbitrary Python objects the same way pickle does. A table of numbers can use `csv`;
anything nested uses `json`.

What does NOT count: "this file is one we wrote ourselves, so it is trusted." It sits on
a disk your program does not control, and a save file is exactly the thing a person
copies between machines, restores from a backup, or is sent by someone else.

**8. A test that cannot fail is not a test. Every test you write must be able to go red.**
You are writing the exam you will be marked on. A test that passes no matter what the code
does still reports `PASSED`, and everyone downstream reads that as evidence the behaviour
is correct. It is worse than no test, because no test is visibly absent and a hollow one
looks like coverage.

Three ways a test quietly becomes unfailable, all of them measured in real deliveries from
this fleet:

```python
# tests/test_store.py

def test_default_path():
    """NOT a test -- no assert. It passes unless the call raises."""
    save_cards([{"q": "a"}], None)
    # "if we got here without error, the default path works" is not evidence.

def test_default_path_fixed(tmp_path):
    """A test. It states what should be true, so it can be wrong."""
    target = tmp_path / "cards.json"
    save_cards([{"q": "a"}], target)
    assert json.loads(target.read_text())[0]["q"] == "a"
```

**Never widen an assertion to make it pass.** If you compute the expected value, assert
that value. A range is legitimate only for genuine floating-point tolerance, and then the
number you expect must sit at its centre, not merely inside it:

```python
# WRONG -- the comment knows the answer the assertion refuses to require
result = convert(1, "gram", "ounce")
# should be ~0.0353, but we'll accept a reasonable range
assert 0.01 <= result <= 0.1        # 0.05 passes. So does a 2.5x error.

# RIGHT -- tolerance around the value you actually expect
assert result == pytest.approx(0.0353, rel=1e-3)
```

If your code does not produce the value you expected, **the code is wrong, not the
assertion.** Fix the code, or say plainly in your report that you could not.

And if you write a property-based test, make sure it runs. A `@given` function defined
*inside* another test is collected as the outer function, which merely defines it and
returns — it passes in microseconds having generated nothing:

```python
# WRONG -- nested, never called: pytest collects the outer function, which does nothing
def test_roundtrip():
    @given(st.text())
    def prop(s):
        assert decode(encode(s)) == s

# RIGHT -- the decorated function IS the test
@given(st.text())
def test_roundtrip(s):
    assert decode(encode(s)) == s
```

What does NOT count: importing `hypothesis` without a property test that can execute; a
test whose only assertion is `assert True`; asserting on something other than the thing
the test is named for. Each of those has shipped from this fleet and been counted as a
passing exam.
