# Fleet builder brief — merge-unblock: make $testResult robust to a packaging-build failure

**Audience:** a Claude session in `C:\Users\mrbla\agentic-setup` (fleet PowerShell). FLEET-side; do NOT touch `~/BlarAI`.
**Tracking:** #670 (fleet limb, follow-up to the ecosystem-adherence merge).
**Authored:** 2026-06-23, after the 2nd on-hardware shakedown.
**Severity:** this is the operator's blocker-to-everything — a CORRECT dispatch currently PARKS instead of merging. Fix is one token; the verification (a live dispatch that actually MERGES) is the real deliverable.

---

## 0. Why — the live failure (confirmed + reproduced by 3 independent reviewers)

The 2nd live dispatch (run `20260623-111949-bd`, `is_palindrome` on `fleet-shakedown`, AFTER all #670 fixes merged) PROVED B1 (1 task), A1 (Python not JS), A2 eco-gate (passed), B2 (clean swap-back) — but the task **PARKED despite an all-green gate AND a `REVIEW VERDICT: MERGE`.** Root cause, reproduced byte-for-byte:

- The `[2/5]` pytest step (`new-agent-task.ps1:161`) runs `uv run --with pytest pytest -x -q` **without `--no-project`**. Bare `uv run` first **builds + editable-installs the project**. `fleet-shakedown` has two top-level modules (`leap_year.py` + `palindrome.py`) → setuptools flat-layout auto-discovery refuses (`error: Multiple top-level modules discovered in a flat-layout`) → `uv` exits 1 **before pytest ever runs** → `$testResult='fail'` (`:162` maps any nonzero≠5 to `'fail'`).
- `$testResult='fail'` is the **SOLE blocking term** in the merge condition (`new-agent-task.ps1:213`: `... -and $testResult -ne 'fail' -and $verifyResult -ne 'fail' -and $verdict -eq 'MERGE'`). Every other term was satisfied (CHANGES:yes, SECRETS:clean, not timed-out, ANOMALIES:none, VERIFY:pass, VERDICT:MERGE). → parked.
- **The tests are CORRECT.** The same suite returns `8 passed` the instant the build is skipped — `verify-project.ps1`'s `py:test` (which already uses `--no-project` / `python -m pytest`, lines 79/96) reported `[pass] py:test`. So `TESTS: fail` is a FALSE-fail of the `[2/5]` step's *install*, not of the code.
- **The spin-detector is INNOCENT** (report `ANOMALIES: none`; the spin-cap `Capped` is NOT in the merge condition; `Get-RunAnomalies` did not flag a loop). **Do NOT touch it.**
- **Secondary symptom, same root cause:** `$testResult='fail'` also drives `Test-ShouldResample` (`:189` / `fleet-lib.ps1:268`) → the correct all-green worktree is discarded and the model re-run up to 3× against an unchanging *deterministic* packaging fault. Wasteful; the fix below kills this too.

---

## 1. The fix (one token)

In **`scripts/new-agent-task.ps1:161`**, change:
```
uv run --with pytest pytest -x -q
```
to:
```
uv run --no-project --with pytest pytest -x -q
```

`--no-project` stops `uv` building/editable-installing the project, so setuptools flat-layout discovery is never invoked; pytest runs in-place via the already-set `$env:PYTHONPATH = $wt` (`:158`) — exactly how `verify-project.ps1`'s `py:test` already behaves.

**Why it's correct AND does not weaken the gate (reviewers verified all three):**
- A genuinely failing test still makes pytest RUN and exit nonzero → `$testResult='fail'` → merge blocked (`:213`). (Verified with broken code: `1 failed`, exit 1 → `fail`.)
- The "no tests" path (exit 5 → `'none'`) is preserved — the exit-code mapping at `:162` is untouched.
- It mirrors the build-skipping invocation `verify-project.ps1:79/96` already trusts.
- It also fixes the resample-waste automatically (a correct build no longer false-fails → no needless 3× resample).

**Boundaries / do-NOT:**
- Do NOT touch the spin-detector (`fleet-lib.ps1:206-247`) or `Get-RunAnomalies` (`:449-482`) — both working as intended, not implicated.
- Do NOT drop the `[2/5]` step or merge it into verify's `py:test`. (Reviewers split on whether it's redundant; it has independent `-x` fail-fast + `$testResult`/`Test-ShouldResample` semantics. Consolidating the two pytest steps is a SEPARATE possible cleanup — **deferred, not part of this fix.** The one-token change is the minimal, lowest-blast-radius unblock.)

---

## 2. Optional belt-and-suspenders (recommended, cheap)

Add to **`C:\Users\mrbla\projects\fleet-shakedown\pyproject.toml`**:
```
[tool.setuptools]
py-modules = []
```
This disables flat-layout auto-discovery, so even a path that *does* build the repo won't choke on multiple top-level modules. The `--no-project` fleet fix SUBSUMES this (no build attempted), but it's a cheap guard for any other tool that builds the repo. **Use `py-modules = []`, not an explicit list** — modules grow each dispatch, so a static list is brittle. (This is the operator's throwaway test repo, not fleet code.)

---

## 3. Verification (mutation-resistant + the live proof — the real deliverable)

1. **Reproduce first:** in a 2-top-level-module repo, `uv run --with pytest pytest -x -q` → exit 1 "Multiple top-level modules"; `uv run --no-project --with pytest pytest -x -q` → `passed`, exit 0. Capture both.
2. **Regression (gate not weakened):** with deliberately-broken code under the fixed invocation → pytest runs, `1 failed`, exit 1 → `$testResult='fail'` → still parks. And confirm a no-test repo → exit 5 → `'none'`. green→revert→red where applicable, real terminal output.
3. **THE LIVE PROOF (this is "fixed and working"):** the operator re-runs `/dispatch fleet-shakedown | write an is_palindrome function` end-to-end → confirm it now **MERGES** (the work lands on `fleet-shakedown` `main`; the per-task worktree is swept) instead of parking. The operator's `/dispatch` (which brings up OVMS via the swap) is the end-to-end proof; if you need a coder-server-independent check, a direct `new-agent-task.ps1` against a 2-module repo proves the merge path.
4. **No regression:** re-run `verify-ecosystem.ps1` (72) + `verify-retry.ps1` (45) — confirm still green (the change is outside their scope; confirm anyway).

---

## 4. Process

Feature branch off main (never commit to main). Open with a comprehension gate. Surgical commit (the 1-line `new-agent-task.ps1` change + optionally the `fleet-shakedown` pyproject). One self-contained package before merge: the diff, the reproduce→fixed terminal output, the regression proof (a real failing test still parks), and the live re-dispatch result (MERGED, work on `fleet-shakedown` main). The LA independent-gates before any merge.
