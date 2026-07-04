# BlarAI builder brief — never strand the 30B on an empty-workspace test grind; stop the single-GUI-app over-split

**Audience:** a Claude session in `C:\Users\mrbla\BlarAI` (BlarAI runtime code). Author-side from the fleet repo; the changes land in **BlarAI**.
**Tracking:** #670 (dispatch right-sizing + acceptance-task gating; follow-up after the winui-smoke WinUI proof).
**Authored:** 2026-06-23, by the dispatch LA, from a 7-agent ultracode root-cause (trace → adversarial-verify → synthesize). Every line-ref was re-derived by execution; the LA spot-confirmed the `swap_driver.py` insertion point.
**Severity:** FIX (b) is the **highest-priority** fix in the whole #670 follow-up — it is the exact, smallest-blast-radius guarantee that a parked-feature run can never again strand the resident 30B on a \~24-minute empty-workspace grind (the waste the operator caught on the rocket-calc dispatch). FIX Part-1 reduces the over-split at the source.

---

## 0. Why — the live failure (root-caused in code, not assumed)

In dispatch run `20260623-152205-bd`, the operator's plain goal *"a tiny app for Windows with one window that has two number boxes, an 'Add' button, and a label that shows their sum"* over-split into **three** tasks (`create-main-window`, `implement-add-functionality`, `acceptance-tests`). Two distinct defects:

- **Empty-workspace grind (FIX b).** The feature tasks **parked** (the review-agent defect — separate fleet brief — left them on `agent/<task>`, not merged to `main`). The appended `acceptance-tests` task then ran in a worktree **branched from `main` (README only)** and the resident 30B ground for \~24 min (\~2,150 s CPU) writing tests for code that wasn't there, until the 3600 s per-task cap. Traced end-to-end: `acceptance.py:compile_prompts:343-355` appends the dedicated test task for ≥2 features (its own docstring even names this failure mode); `swap_driver.py:_run_phases` CODE loop (`:523-530`, **LA-confirmed**) iterates `self._tasks` and calls `run_task` unconditionally — only `cancel_requested`/`stop_requested` break it, **no merge-dependency or feature-presence gate**; the task's worktree defaults to base `main` (`new-agent-task.ps1:12,67`), and a PARK leaves `main` unchanged.
- **The over-split itself (FIX Part-1).** Executing `decompose.py`'s ruler on the real slugs: `_classify('create-main-window')→feature`, `_classify('implement-add-functionality')→feature`, `_collapse(...)` KEEPS both (they're sibling-distinct: different verb, disjoint object tokens), and there is no heuristic that a single small app's UI + its behavior are one unit. The `_DECOMPOSE_TEMPLATE` (`:64-80`) actively invites a feature-split. The ≥2-feature count is exactly what manufactured the spurious `acceptance-tests` sibling (`compile_prompts` folds tests into a *single* feature; ≥2 → a dedicated task).

**Note the layering:** once FIX (b) lands, an over-split that still happens no longer strands the 30B — so FIX (b) is the safety net and FIX Part-1 is a fidelity improvement, not the unblock.

## 1. Ground rules

- **Ships dormant.** All of this is dispatch machinery behind `[fleet_dispatch].enabled` (default false). **Preserve the operator's uncommitted working-tree changes** — the `enabled=true` flip in `default.toml` and the `MainWindow.xaml.cs` edit. **Never `git add -A`**; surgical commits only.
- **Dev env (worktree-venv rule):** a worktree doesn't carry `.venv`; use `C:\Users\mrbla\BlarAI\.venv\Scripts\python.exe` with `PYTHONPATH=<worktree-root>`.
- Offline, deterministic, fail-closed. Append a `BUILD_JOURNAL` fragment.

## 2. FIX (b) — PRIMARY: skip the acceptance task when the feature work didn't merge

In `shared/fleet/swap_driver.py`, the `_run_phases` CODE loop (`~:523-530`). Before calling `run_task` on the task whose `name == acceptance.ACCEPTANCE_TASK_SLUG`, inspect the `outcomes` already collected this run: **if NOT every preceding FEATURE outcome has `result == 'MERGED'`, SKIP it** and append a synthetic `TaskOutcome(result='SKIPPED', detail="acceptance tests skipped: feature task(s) <names> parked/did not merge — no merged code to test")`.

**Why this is exact (verify-confirmed):** a parked feature classifies `PARKED` (run-fleet writes "NOT merged … parked" → `dispatch._classify_result` "not merged" branch → `PARKED`), `MERGED` only on a real merge — so "skip unless all preceding features == `MERGED`" is precise. The driver already holds `self._tasks` (the compiled list, so it has the slug) and the per-task `outcomes` (so it has the results). This is the smallest correct change.

**Must NOT break (all verified no-ops):** the single-feature **fold** path appends no acceptance task (`compile_prompts:343-348`), so the guard never fires there; the existing exact-call-list tests (`test_swap_driver.py:68,155` use task names `'a'/'b'`, never the slug) stay **byte-identical**; the **never-zero teardown** lives in `run()`'s `finally`→`_teardown` and a CODE-loop guard cannot reach it; an all-MERGED multi-feature run still runs every task.

**Reporting — SCOPED DOWN (the root-cause's adversarial pass dropped an over-edit):** do **NOT** touch `criterion_status`. A skipped acceptance task yields `tests=='none'`, and `criterion_status` (`acceptance.py:399-408`) **already** maps anything-not-pass to `UNVERIFIED` and never returns `FAILED` without an explicit `tests=='fail'` (which a skip never produces) — so the honest-report / anti-false-pass invariant holds with **zero** `criterion_status` change. The only reporting work needed is surfacing the `SKIPPED` line in the per-task summary. (If you choose to round-trip a `SKIPPED` `RESULT:` line through `SUMMARY.txt`, add a `'skipped'→SKIPPED` branch to `dispatch._classify_result` **after** the existing `'not merged'→PARKED` precedence + a `_format_report` icon — optional, not on the driver's in-memory path.)

## 3. FIX Part-1 — stop the 14B splitting one small app's UI from its behavior

In `shared/fleet/decompose.py` `_DECOMPOSE_TEMPLATE` (`~:69-78`), add a rule (keep it tight; it's the model-side lever):
> *"A single small GUI app — ONE window/screen/dialog and the behavior of the controls ON it (a button's click, a field's validation, a label that updates) — is ONE task. Do NOT split the window/UI from its button/handler/logic. Split into separate tasks ONLY for genuinely independent user-invoked units: separate top-level commands (add / list / done), separate pages/screens, or separate services."*

This counters the UI/logic seam the 14B split on while leaving genuine separate-commands / separate-pages splits untouched.

## 4. LA DECISION on the deterministic backstop (Part-2) — DEFERRED, with the trade-off named

The root-cause's adversarial pass **refuted the proposed deterministic ruler backstop ("Part-2") as written** — proven by execution: `_UI_SHELL_NOUNS` contained the token `mainwindow`, but the real slug tokenizes to `{main, window}`, so `is_ui_shell('create-main-window')` is **False** and the merge **never fires on its own target**. And a *corrected* Part-2 (admitting `main`) **over-collapses genuine multi-feature single-screen apps** (it fires on `create-form + implement-pdf-generator` and `create-form + add-csv-export`, which the eval corpus deliberately keeps at 2) — making it a **capability/quality decision**, not a clean defect fix.

**LA decision (the trade-off, on the record):** ship **Part-1 only** for now; **DEFER Part-2.** Rationale: once FIX (b) lands, an over-split no longer *strands* the 30B (the acceptance task is skipped on parked features) — so over-splitting drops from a *failure* to a *fidelity/efficiency* issue, which makes a risky deterministic backstop **not worth its false-collapse risk right now**. The path not taken: a narrow Part-2 (option (ii)) that fires at exactly 2 features, admits a small `_UI_MODIFIERS` allow-set (`{main, settings, login, home, primary}`) so `create-main-window` qualifies as the shell, AND disqualifies the behavior side when its object carries a deployable head-noun from the existing `_ARTIFACT_FEATURE_NOUNS` set (`{generator, exporter, service, endpoint, dashboard, parser}` — this is what protects the pdf-generator / csv-export pairs), accepting that two genuinely-independent behaviors on one screen collapse to one worktree. **Do NOT build Part-2 in this brief.** If a future pass wants the deterministic backstop, it's option (ii), unit-tested directly on `create-main-window` + the `must_survive` boundary cases below.

*(The optional fleet-side floor — short-circuit a test-slug task whose worktree has no feature artifacts, in `new-agent-task.ps1` — is also deferred; FIX (b) is the exact fix and lives in BlarAI.)*

## 5. Verification (mutation-resistant)

- **FIX (b):** add the regression the suite is MISSING (every existing fixture is feature-only or all-MERGED): a 3-task list `[feature-a MERGED, feature-b PARKED, acceptance-tests]` must **SKIP** `run_task` for the acceptance slug and append a `SKIPPED` outcome. **Mutation:** revert the guard → confirm `run_task` IS called on the empty-workspace acceptance task (the grind reproduces). Assert the single-feature fold path and the all-MERGED multi-feature path still call `run_task` for every task (true no-op), and re-run `test_swap_driver.py:68,155` to confirm the exact-call-lists are byte-identical. Assert `criterion_status` is unchanged and a skipped acceptance renders its criteria `UNVERIFIED` (with a `tests=='fail'` mutant proving `FAILED` only ever comes from an explicit fail).
- **FIX Part-1:** re-run `tests/integration/test_decompose_eval.py` (**must stay 69+ passing**) to prove the prompt change broke no eval. Add a `must_collapse` corpus case for the winui goal slugs → exactly 1, and a `must_survive` two-window guard (`'an app with a settings window and a main window'` → 2) to lock the boundary the prompt targets. (The prompt itself can't be deterministically unit-asserted — that's exactly why Part-2 was the proposed backstop, and why deferring it is a recorded decision, not an oversight.)

## 6. Process

Feature branch off main (never commit to main). **Open with a comprehension gate:** your understanding of FIX (b) (confirm the `swap_driver.py:523-530` insertion point + that `outcomes`/`ACCEPTANCE_TASK_SLUG` are in hand) + FIX Part-1 + the **deferred-Part-2 decision** (don't build it). Wait for LA confirmation. Surgical commit (named files: `swap_driver.py`, `decompose.py`, the tests/corpus; **preserve the operator's `enabled=true` + `MainWindow.xaml.cs`**). `BUILD_JOURNAL` fragment. One package before merge: the diff, the mutation-resistant test output (skip-fires + byte-identical no-op proof), and the eval still 69+. Ships dormant. The LA independently gates ("ultracode" → multi-agent adversarial review) before any merge.
