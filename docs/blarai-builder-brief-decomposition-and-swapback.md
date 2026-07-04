# BlarAI Builder Brief — Fix Decomposition Granularity (then Swap-Back Teardown)

**Date:** 2026-06-22
**Audience:** the Claude agent building the headless-coding feature *inside* `C:\Users\mrbla\blarai`.
**Companion docs:** architecture in `agentic-setup/docs/blarai-headless-coding-agent-brief.md`
(the canonical brief; its §10 is the dated running log). Read that first for the dispatch design.

---

## 0. Ground rules (non-negotiable)

- **Commit dormant.** `[fleet_dispatch].enabled` stays **false** on every commit. The operator flips it
  for shakedowns; you never flip it.
- **Scope to the dispatch/planner layer only.** No system-wide or OS-level changes (no firewall rules,
  no global env, no machine-wide installs). Harden the agent layer, not the machine.
- **Verify, don't assert. Tests must be mutation-resistant.** For every fix, write a test that *fails*
  when the fix is reverted/disabled, and show it failing. A single green run proves nothing.
- **The 14B's decomposition is the product, not a convenience.** The operator is a non-developer who
  cannot decompose or drive a coder himself. The NL→decompose→execute pipeline IS the deliverable. Never
  "just use the raw coder" as a substitute — improving decomposition *is* the job.
- **The fleet still refuses repos under `~/BlarAI` and `~/.openclaw`.** Don't weaken that fence.

---

## 1. Why now — status

The headless round-trip **works end-to-end** (proven on-hardware 2026-06-22): the 14B decomposes a goal,
BlarAI steps the embedded 14B aside, the 30B loads (GPU handoff \~24.4 GiB), the headless fleet runs the
tasks, and **real code is written and merged to `main`** (leap-year + a document-function task both
landed). The old "generates tokens but writes no files" blocker is **resolved**.

Two characterized issues remain. They are tuning/teardown, not showstoppers — but #1 is the gate to the
whole product being *usable*, so it comes first.

---

## 2. PROBLEM 1 (PRIORITY) — Over-decomposition

### Evidence (live, 2026-06-22)
The goal **"write an `is_leap_year` function"** — a one-liner — was exploded into **\~7–9 fleet tasks**:
`define-is-leap-year-function`, `implement-leap-year-logic`, `test-is-leap-year-2024`,
`test-is-leap-year-1900`, `test-is-leap-year-2000`, `verify-edge-cases`, `acceptance-tests`
(+ a `create-file` task). Each got its **own git worktree and its own model-swap cycle**; total \~33+ min
for one line of code. Aimed at a real goal ("build an ecommerce site") this same behavior yields
*hundreds* of redundant micro-tasks → unusable.

### Root cause (confirm in code, then fix)
The decompose step has **no right-sizing, no depth limit, and the deterministic ruler is not collapsing
redundant/atomic-split subtasks.** The 14B free-associates one task per sub-thought (a task per test
case, a task per "step"). Locate:
- the **planner / decompose** module and the **exact prompt/schema** the 14B is given to break a goal into
  tasks (search BlarAI for the dispatch/AO-PA/planner code and the task-list JSON schema);
- the **existing deterministic "ruler"** that post-filters proposed tasks (the operator confirms one
  exists — find it and see why it lets atomic splits through);
- the **bridge to the fleet**: how a planned task becomes a fleet task
  (`agentic-setup/scripts/add-fleet-task.ps1` → `state/fleet-queue.json` → `run-fleet.ps1`).

### The fix (design it SDD-aligned so it is not throwaway)
Target behavior: **a small goal stays ONE task; a large goal decomposes into the fewest *coherent units*,
never one-line-/one-test-per-task.** Build it as the foundation for the eventual
Clarify → Spec → recursive-Decompose → Approve → Execute flow.

1. **Leaf / stop-condition gate ("is this already small enough?").** A task is a *leaf* (do not split
   further) when it is **one coherent unit a coder implements in a single pass** — e.g. *one function plus
   its tests is ONE task*, not six. Define the criteria explicitly and deterministically (e.g. estimated
   ≤ \~1 file / ≤ \~a few dozen LOC / single responsibility). The model *proposes* a split; a deterministic
   check *disposes*.
2. **Hard depth limit on recursion** (e.g. 2–3 levels). Fail-safe: if a node is still "too big" at max
   depth, keep it as a single flagged task rather than explode it.
3. **Strengthen the ruler to DROP redundant subtasks**: dedupe by intent; collapse per-test-case tasks
   into their parent; reject any task that is a sub-step of another (e.g. "define-function" +
   "implement-logic" → one task). Model proposes, ruler + operator dispose.
4. **Rewrite the decompose prompt** to demand the **fewest coherent tasks**, with explicit anti-patterns:
   *"Do NOT create a separate task per test case, per file, or per step. A function and its tests are one
   task. Prefer one task unless the goal genuinely spans independent units."*
5. **(Design-only now, build later)** keep the plan in **`.md` spec files**, not the 14B's small context,
   so right-sizing later anchors to a reviewed spec (the SDD anchor that also prevents drift).

### Acceptance criteria (mutation-resistant)
- `"write an is_leap_year function"` → **exactly 1 task** (at most 1 implement + 1 test task), end-to-end
  in a few minutes, code correct (1900=False, 2000=True, 2024=True).
- A medium goal (e.g. *"a CLI todo app: add / list / done"*) → a **single-digit** count of coherent
  tasks, NOT one per verb/file/line.
- **Add a decomposition eval** (extend `agentic-setup/evals/` and/or BlarAI's tests): feed N goals of
  known size; assert the **task count** is in range AND that **no task is an atomic-split of another**
  (dedupe/sub-step check). **Mutation test:** disable the right-sizing gate / ruler and show the eval
  **fails** (task count explodes) — proving the eval has teeth.
- The human **Approve gate** still shows the plan before any execution.

---

## 3. PROBLEM 2 — Swap-back hang (teardown never fires)

### Evidence
Across **two** 15–20 min watchers, after the 30B finished its tasks the swap-**back** tail never ran: the
30B stayed resident, the embedded 14B never returned, RAM stayed pinned (\~3.7 GB free). The box had to be
torn down **manually**.

### The manual teardown that worked (this is the correct sequence — encode it)
1. **Disarm the watchdog FIRST** — remove `agentic-setup\state\server-should-run.txt`. (If OVMS is stopped
   while this sentinel exists, the watchdog respawns it and RAM never frees.)
2. Kill the run tree: `swap_ops` → `run-fleet.ps1` → headless `opencode.exe` → the **playwright MCP
   node** (the playwright browser MCP is a known fleet-hanger — it should not be in the headless tool set
   at all; consider disabling it for fleet runs).
3. `Stop-Process -Force` the `ovms` process (the 30B).
4. Reload the embedded 14B. Result: RAM 3.74 → 24.9 GB.

### The fix (in `shared/fleet/swap_ops.py` — confirm the path)
- **Wrap the whole run in `try/finally` so the swap-BACK ALWAYS executes** — on success, on a failed/
  parked task, on exception, and on timeout. This is the **"never end at zero"** invariant: the 14B must
  be restored no matter how the run ends.
- **Detect run-fleet completion correctly.** Await the subprocess; do **not** block on a pipe read that
  can deadlock (there was a prior pipe-deadlock fix — make sure this path uses it). Add an **overall run
  timeout** so a stuck/over-long run still triggers teardown instead of hanging forever.
- **Enforce ordering:** disarm sentinel **before** stopping OVMS.
- **Coherence smoke-check** after the 14B reloads (a trivial prompt/response) before reporting success.
- **Fail loud:** log each teardown step; if any step fails, surface it — never silently leave the 30B
  resident.

### Acceptance criteria
- A full round-trip on a 1-task goal ends, **unattended**, with: OVMS down, sentinel removed, 14B
  reloaded + smoke-check passed, RAM recovered — observed end-to-end.
- **Fault injection:** make a task fail the verify gate (and separately, kill `run-fleet` mid-run) → the
  14B is **still** restored. **Mutation test:** remove the `finally` and show the test catches a stuck
  30B / unrestored 14B.

---

## 4. Hygiene (fold in while you're here)

- **Swap queue written fresh, not appended.** The swap spec/queue was observed appended 3× (dup entries);
  write-replace it each dispatch.
- **Worktree sweep on run end/kill.** The fleet leaves a `git worktree` per task; a finished or killed
  run must `git worktree remove` its task worktrees (8 had to be removed by hand this time). Add this to
  the teardown / run-cleanup path.

---

## 5. Out of scope (next brief, not now)

The SDD layers — the **Clarify** step (14B reads goal + attached files, asks the operator coverage-based
questions to fill gaps) and **Spec.md authoring** — are the *next* brief. **Design Problem 1 to be
compatible with them** (plan-in-files, a stop-condition that can later read a spec), but do not build them
yet.

---

## 6. Suggested order of work

1. **Problem 1** — right-sizing gate + depth limit + ruler hardening + prompt rewrite (the foundation).
2. **Problem 2** — swap-back `try/finally` + run timeout + ordered teardown + smoke-check.
3. **Hygiene** — write-fresh swap queue + worktree sweep.

Each step lands with its **mutation-resistant test green AND shown failing when reverted** before you move
on. Keep `enabled=false`. Report results against the acceptance criteria above, not "it ran once."
