# BlarAI builder brief — decomposition right-sizing (P3) + swap-back polish

**Audience:** a Claude session in `C:\Users\mrbla\BlarAI`. Authored on the agentic-setup side (the
author did not inspect BlarAI source) — start with a diagnosis pass to confirm the exact code.
**Tracking:** #670. **Ships DORMANT** (`[fleet_dispatch].enabled=false`).
**Authored:** 2026-06-23, after the first live shakedown.
**Companion brief (separate, FLEET-side):** `fleet-builder-brief-ecosystem-adherence.md` — the
wrong-language / non-merging coder defects are FLEET defects (agentic-setup), NOT in scope here.

---

## 0. Context — the first live shakedown (don't re-derive)

The first live dispatch (run `20260623-060248-bd`, `is_palindrome` on `fleet-shakedown`) **PROVED
the Problem-2 swap-back fix**: the teardown fired on its own, the 14B was restored unattended, the
swap-state phase ended `RECOVERED`, and the worktree sweep ran AFTER the restore. The round-trip's
swap overhead (step-aside + 30B load + teardown) was ~3.7 min.

It also surfaced **two BlarAI-side refinements** (below). Both ship dormant; both run through the
same gated process as Problems 1 & 2. (The run's other problems — the coder wrote JavaScript in a
Python repo, and nothing merged — are FLEET defects; see the companion brief.)

---

## 1. Boundaries (unchanged from P1/P2)

- **Dormant on commit** (`[fleet_dispatch].enabled=false`). The operator's UNCOMMITTED working-tree
  `enabled=true` flip + `services/ui_winui/MainWindow.xaml.cs` edit must be PRESERVED — commit
  surgically (named files only; never `git add -A`/`git add .`).
- **Live swap-back is the operator's on-hardware step.** Build + headless-unit-test with injected
  ops only; do not fire a real swap.
- **Dev env:** run tests with `C:\Users\mrbla\BlarAI\.venv\Scripts\python.exe` and
  `PYTHONPATH=<worktree-root>` (a worktree's bare python lacks the deps).
- **Mutation-resistant verification** (green → revert → red → restore, with REAL terminal output).
- Isolated worktree off `main`; BUILD_JOURNAL fragment when shipping; comprehension gate first.

---

## 2. Refinement B1 — decomposition right-sizing: the lone-test sibling

**Symptom (live):** `write an is_palindrome function` decomposed into **2 tasks** —
`implement-is-palindrome` + `acceptance-tests` — when it should be **1**. (Big improvement over the
old ~9, but not yet 1.) The spurious `acceptance-tests` task then ran ~24 min FAILING, because it
was a separate fleet task with its own worktree and the implementation wasn't in it.

**Where:** `shared/fleet/decompose.py` — the Problem-1 right-sizing ruler (`_classify`, `_collapse`,
the sibling-relative collapse) + the never-zero-tests floor in `shared/fleet/acceptance.py`
(`collapsed_test_intent` → smoke criterion).

**Diagnose FIRST (report at the gate):** why did the sibling-relative collapse NOT fold the lone
`acceptance-tests` task into the `implement-is-palindrome` feature? Confirm the cause against the
code + a unit repro. Candidates: the collapse may require ≥2 feature siblings; the live slug
`acceptance-tests` may not match the test-structural taxonomy (`_TEST_VERBS` etc.); or a guard skips
collapse when there are only 2 tasks. Pin the real reason before changing anything.

**Fix:** make **`[1 feature + 1 test/acceptance-style task] → 1 feature task`**. The test intent
becomes a *criterion* (the never-zero-tests floor already injects a smoke criterion when
`collapsed_test_intent`), NOT a separate fleet task that spins its own worktree + swap-cycle. Do not
over-correct: a goal that genuinely asks for multiple distinct features must keep them.

**Acceptance:** single-function goals (`is_palindrome`, `leap_year`, `slugify`) → **exactly 1 task**
carrying a test criterion. Add these as cases to the eval corpus
(`tests/integration/test_decompose_eval.py` + its corpus). Mutation-resistant: revert the collapse →
the new case over-splits → red. The existing red-team corpus (multi-feature goals) MUST still pass —
prove you didn't trade over-splitting for under-splitting.

---

## 3. Refinement B2 — verify-the-stop false alarm

**Symptom (live):** the swap-back fired correctly, but the verify-the-stop wrote a
`SWAP_FAILED_<run>.txt` ("OVMS still resident after a forced stop") even though OVMS *did* unload
moments later (the boot reconciler converged it; the operator saw phase `RECOVERED`, 14B up, OVMS
gone). Cause: a ~15 GB OVMS unload is SLOWER than the verify-the-stop's check-then-one-fast-retry
window, so it cried wolf. The fail-loud MECHANISM is correct; the TIMING is too eager.

**Where:** `shared/fleet/swap_driver.py` — the teardown verify step (`_verify_ovms_stopped` and the
`real_ovms_alive` / `stop_ovms` injected ops in `shared/fleet/swap_ops.py`).

**Fix:** **POLL** `ovms_alive` with a timeout (~30–60 s, a few polls on an injected clock) before
escalating to the forced retry + `signal_failure`. Only after the poll window STILL shows OVMS
resident → forced retry → if still resident → signal. Give the big-model unload time to finish.

**Hard constraint — NEVER-ZERO is untouchable:** the 14B restart stays UNCONDITIONAL and on the same
path it is today. B2 changes ONLY when/whether the failure SIGNAL fires; it must not add any new way
for the restore to be skipped or delayed materially. Mirror the existing injected-clock pattern used
elsewhere in the driver so the poll is unit-testable with no real sleep.

**Acceptance:**
- injected ops where OVMS exits at T+Ns (N < timeout) → **no** `SWAP_FAILED`, clean `RECOVERED`.
- OVMS never exits → `SWAP_FAILED` fires AFTER the timeout (genuine, not premature).
- a test asserting the 14B restore still runs on EVERY path (never-zero unchanged).
- Mutation-resistant: revert the poll → the slow-exit case false-fails again (red).

---

## 4. Process + review package

Open with a **comprehension gate**: your understanding of B1 + B2, plus the CONFIRMED B1 root cause
from a quick diagnosis pass. Wait for LA confirmation. Build on an isolated worktree off `main`,
dormant on commit, surgical commits (named files; preserve the operator's `enabled=true` +
`MainWindow.xaml.cs`). Append a BUILD_JOURNAL fragment (`docs/journal_fragments/YYYY-MM-DD_<slug>.md`),
track under Vikunja #670. Deliver ONE self-contained review package before merge: the full diff +
`git show --stat` proving only intended files changed and `enabled=false`; the green→revert→red
mutation output (both directions, real terminal text) for each fix; the eval-corpus additions for B1.
The LA does an independent gate before any merge.

**Order:** B1 (right-sizing — higher value: fewer doomed tasks, faster runs) → B2 (verify-the-stop
polish — lowest stakes; the swap already works, this only silences a false alarm).
