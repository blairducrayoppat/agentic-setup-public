# Fleet builder brief — ecosystem adherence (coder language-pinning + gate hard-fail)

**Audience:** a Claude session working in `C:\Users\mrbla\agentic-setup` (the fleet PowerShell
scripts). This is FLEET-side work — do NOT inspect or edit `~/BlarAI`.
**Tracking:** #670 (the BlarAI headless-coding-dispatch program; this is the fleet-side limb).
**Authored:** 2026-06-23, after the first live shakedown of the dispatch pipeline.
**Status on commit:** N/A (the fleet has no dormancy flag) — but it MUST stay backward-compatible
(an unknown/empty ecosystem = today's behavior, never a new false-fail).

---

## 0. Why this exists — the live failure (don't re-derive)

The first live dispatch — `/dispatch fleet-shakedown | write an is_palindrome function`, run
`20260623-060248-bd` — **parked instead of merging.** Root cause, pinned by reading the parked
branch `agent/implement-is-palindrome` in `fleet-shakedown`:

**The 30B coder wrote the function in JAVASCRIPT** (`palindrome.js`, `test_palindrome.js`,
`debug_palindrome.js`, a `README.md`) **into a PYTHON repo** (`fleet-shakedown` has `pyproject.toml`
+ `leap_year.py`). The JS logic was correct — but it is the wrong language for the project. Two
fleet defects combined to let this happen and nearly let it merge:

1. **The coder ignored the target ecosystem.** `new-agent-task.ps1` passes the task prompt straight
   to the coder (`Invoke-AgentRun -Prompt $Prompt`, ~line 98) with NO language constraint. A
   language-neutral "is_palindrome" let the 30B default to JavaScript (a classic JS exercise).

2. **The verify gate is blind to a wrong-language deliverable.** In `verify-project.ps1`:
   - `py:compile` ran `compileall .` and **PASSED on the pre-existing `leap_year.py`** (line 77) —
     it never saw the task's actual output.
   - `py:test` only fires if a `test_*.py` exists (lines 84-88); the agent wrote `test_palindrome.js`,
     so it did not run.
   - the Node gate only fires with `package.json` + `node_modules` (lines 48-63), both absent for
     loose `.js` files — so the JS was checked by nothing.
   - Aggregate = `pass` (lines 116-121) because one *unrelated* `.py` compiled.

   So the deterministic gate — the guard auto-merge is supposed to trust — **never checked the
   task's deliverable.** The ONLY thing that blocked the merge was the LLM review returning
   `FIX FIRST` (`new-agent-task.ps1` requires `verdict -eq 'MERGE'`, ~line 199). Had the review been
   lenient, wrong-language code would have merged.

**Goal of this brief: make the DETERMINISTIC gate the reliable guard (not the LLM review), and stop
the coder writing the wrong language in the first place.**

---

## 1. Ground rules / boundaries

- agentic-setup PowerShell scripts only. Do NOT inspect or edit BlarAI source.
- Keep the verify gate **high-precision + forgiving** — its stated design (`verify-project.ps1:1-10`):
  only ever return `fail` on a genuine problem so auto-merge stays trustworthy. The new check MUST
  NOT false-fail on doc-only changes or genuinely polyglot repos.
- Backward-compatible: an unknown/empty ecosystem (no recognizable manifest) = today's behavior.
- Do NOT weaken the `~/BlarAI` / `~/.openclaw` repo fence (`new-agent-task.ps1:25-27`).
- Offline + deterministic (the gate runs with no network).

---

## 2. Do this FIRST — the shared helper `Get-ProjectEcosystem` (fleet-lib.ps1)

One function, the single source of truth for "what language IS this project," used by BOTH fixes:

- **Input:** a repo/worktree path.
- **Output:** the set of *declared* ecosystems from MANIFESTS — `python` (`pyproject.toml` or
  `setup.py`), `node` (`package.json`), `dotnet` (`*.csproj`/`*.sln`). May be multiple (polyglot)
  or empty.
- Key distinction: this is the project's DECLARED identity (its manifest), NOT "what file
  extensions happen to exist in the tree." Manifests are the truth; that is what makes
  "a `.js` file with no `package.json`" detectable as a foreign deliverable.

Refactor `verify-project.ps1`'s existing inline detection to call this helper too, so there is ONE
detector.

---

## 3. Fix A1 — pin the language in the coder prompt (`new-agent-task.ps1`)

Before the coder runs (~line 98, the `Invoke-AgentRun` inside `Invoke-BuildWithRetry`), compute
`Get-ProjectEcosystem $wt` and **PREPEND** a hard constraint to `$Prompt`. Example for a Python repo:

> "TARGET PROJECT LANGUAGE: Python. Write your solution as Python (`.py`) files in this repo, and
> add at least one `pytest` test named `test_*.py` that exercises the behavior. Do NOT use
> JavaScript, TypeScript, or any other language — this is a Python project."

- Build the constraint from the detected ecosystem (python → above; node → "TypeScript/JavaScript +
  a test"; dotnet → "C# + a test project"; empty/unknown → no constraint = current behavior).
- Keep the original task text intact; the constraint is a PREFIX, not a replacement.

**Acceptance:** a Python repo + a language-neutral goal → the coder writes `.py` + a `test_*.py`.
Verify by re-running the `is_palindrome` dispatch on `fleet-shakedown` (or a direct
`new-agent-task.ps1 -Repo ...fleet-shakedown -Task ... -Prompt "write an is_palindrome function"`)
→ the deliverable is now Python.

---

## 4. Fix A2 — the gate hard-fails a language-mismatch deliverable (`verify-project.ps1`)

Add a deterministic, high-precision check (a new gate result, e.g. `eco:language`):

- Compute `Get-ProjectEcosystem $Path` (the declared ecosystem set).
- Compute the languages of the files the TASK changed: `git diff --name-only <base>..HEAD`, mapped
  to language by extension (`.py`→python, `.js/.jsx/.ts/.tsx`→node, `.cs`→dotnet, …). NOTE:
  `verify-project.ps1` currently takes only `-Path` — it needs the base ref. Either add a
  `-BaseBranch` param, or compute the changed-file set in `new-agent-task.ps1` (which already knows
  `$BaseBranch`) and pass it in. Pick the cleanest wiring and state it at the comprehension gate.
- **FAIL when:** the changed CODE files are ALL in language(s) that are NONE of the declared
  ecosystems, AND the task did not add the matching manifest (e.g. added `.js` but no
  `package.json`). 
- **Do NOT fail** on: doc/config-only changes (`.md`, `.txt`, `.gitignore`, `.toml` unless it is a
  new manifest); a changed language that IS in the declared set (polyglot); a task that legitimately
  introduces a new ecosystem *with* its manifest.

This makes `overall='fail'` for the JS-in-Python case → blocks the merge at `new-agent-task.ps1`
(~line 199) **deterministically, independent of the review verdict.**

**Optional secondary (ESCALATE, do not silently add):** also failing when an *implementation* task
produces no executed test in the target language ("no tests ran" + zero `test_*.py` added). This is
more opinionated and risks false-fails on non-code tasks. RECOMMEND scoping it narrowly or deferring;
the language-mismatch catch is the primary, high-precision fix. Raise it as a decision, don't bake it
in.

**Acceptance:** the recorded JS-in-Python case → `eco:language: fail` → `overall: fail` → parked
even if the review says MERGE; a correct `.py` deliverable → pass; a doc-only change → pass (no
false-fail).

---

## 5. Verification (mutation-resistant — the operator's bar)

- Extract the language-adherence DECISION as a pure function (declared-ecosystems +
  changed-file-languages → pass/fail) and unit-test it. `scripts\verify-retry.ps1` is the precedent
  for unit-testing a pure fleet decision with no model. Cover: JS-in-Python (fail), correct Python
  (pass), polyglot Python+JS where the repo declares both (pass), doc-only change (pass), added `.js`
  WITH a new `package.json` (pass).
- **green → revert → red:** revert the new check → the JS-in-Python case passes again. Show real
  terminal output, BOTH directions (the LA wants the output, not the claim).
- **Live proof:** re-run the `is_palindrome` dispatch (or a direct `new-agent-task.ps1`) on
  `fleet-shakedown` end-to-end → A1 makes the coder write Python; if it still slips, A2 fails loudly
  on language rather than vacuously passing. Capture the run dir + the report.

---

## 6. Process + review package

Open with a **comprehension gate**: your understanding of the two defects + your plan, and confirm
the exact wiring you'll use (especially how the gate receives the base ref for the diff). Wait for LA
confirmation. Build on a feature branch (never commit to main). Deliver ONE self-contained package
before merge: the diff, the pure-decision unit tests + the green→revert→red output, the live re-run
evidence, and a one-line summary. The LA does an independent gate before any merge.

**Order of work:** the shared helper → A1 → A2 → tests → live re-run. A1 and A2 are complementary:
A1 stops the coder erring; A2 catches it deterministically if it errs anyway. Ship both.
