# No-op-build diagnosis — the 2026-07-03 landing-site runs

**Date:** 2026-07-05 · **Author:** M2/W7 hardening sweep (Vikunja #740) · **Scope:** the three
`meridian-cafe` landing-site dispatch runs of 2026-07-03 that the M2 plan (§2.2) flagged as "two
produced no-op builds before one MERGED."

## TL;DR

The two no-op runs were **not** caused by the mechanisms the plan hypothesized (not a "model prints a
tool-call as text / writes to a denied path" case, not a "retry-on-no-op budget under C=3" bug, not a
prompt/scaffold defect). The actual mechanism, confirmed from the transcripts and `fleet-lib.ps1`:

1. **Primary (coder/serving behaviour — not an agent-layer defect):** the coder-30b did a little
   read-only exploration (a `glob` + one or two `read`s) and then **went completely silent — it stopped
   emitting steps/edits before making the first edit.** The progress-aware idle breaker (#682, 240 s)
   correctly killed it as "genuinely stuck," having made zero changes. It is non-deterministic: run 3
   (same task) engaged and merged.
2. **Secondary (deliberate policy — a DECISION, not a defect):** a timed-out candidate (idle *or*
   wall-clock) is by explicit design **never resampled and stops best-of-N**. So candidate 1's idle
   stall collapsed the N=3 budget to N=1 — candidates 2 and 3 never ran. This is *why the whole run
   no-op'd* instead of routing around the stall with a fresh sample (which run 3 shows can work).
3. **A genuine DEFECT, found and FIXED here:** the report **mislabelled the fast idle stall as a 60-min
   wall-clock timeout** (`BUILD: STOPPED by circuit breaker after 60 min` + `ANOMALIES: agent hit the
   wall-clock timeout`). That mislabel is exactly what sent the plan's own hypothesis chasing a
   wall-clock / retry-budget cause. Fixed (doc-honesty, zero pipeline-behaviour change) + regression-locked.

## Evidence, per run

Runs are under `state/fleet-runs/`; coder transcripts under `state/reports/`.

### Run 1 — `20260703-211337-bd` → NO-OP
- Task `build-a-polished-modern-single-page-landing-site`, repo `meridian-cafe`, model `coder-30b`.
- `journal.log`: `TASK-START 21:17:40` → `TASK-END 21:23:10` (**5 min 30 s**), `RESULT: Nothing to merge.`
- `run-fleet-*.log`: `[1/5] Building candidate 1 of 3 in isolated workspace` (**sequential path, C=1** — the
  message is the sequential `-RunCandidate` line; the concurrent path prints "…CONCURRENTLY…"). Then
  `CIRCUIT BREAKER: agent went idle (no new step/edit for 240s) -- genuinely stuck and was stopped.`
- Coder transcript (`…211740.c1.agent.log`, 12 KB): exactly **3 read-only steps** in ~17 s — `glob **`
  (17 files), `read public/index.html`, `read public/app.js` — then the transcript **ends**. No edit,
  no further step. Silent stall → idle kill at 240 s.
- Report `.txt`: `CHANGES: none made`, `TESTS: none`, `VERIFY: none`, and (the defect)
  `BUILD: STOPPED by circuit breaker after 60 min` / `ANOMALIES: agent hit the wall-clock timeout and
  was stopped` — **false**: the wall clock was ~5.5 min and the kill was the *idle* breaker.

### Run 2 — `20260703-213231-bd` → NO-OP
- Task `build-a-clean-elegant-single-page-landing-site-f` (single-file variant).
- `journal.log`: `21:34:19` → `21:40:06` (**5 min 47 s**), `RESULT: Nothing to merge.`
- Same `[1/5] Building candidate 1 of 3` + `agent went idle … genuinely stuck`.
- Coder transcript (`…213419.c1.agent.log`, 7.5 KB): **2 steps only** — `glob`, then one `read`, then
  silence. Same read-then-stall shape, even earlier.
- Same mislabelled report (`60 min` / `wall-clock timeout`).

### Run 3 — `20260703-214951-bd` → MERGED (then a second no-op + a RESTART-AO failure)
- Same task name. `journal.log`: `21:51:38` → `22:21:52` (**30 min**), `RESULT: MERGED`.
- Coder transcript (`…215139.c1.agent.log`, **98 KB**): this time the coder engaged, wrote the site,
  `TESTS: pass`, `VERIFY: pass` → merged. The size contrast (98 KB vs 12/7.5 KB) is the tell: the
  no-op runs died before doing any work.
- The follow-on `design-fix-1` task and the three VLM auto-fix passes then **each stalled the same way**
  (`FIX #1/#2/#3: coder timed out on the FIX pass; kept the prior merged version`) — a *second and third*
  instance of the same read/think-then-stall variance, reinforcing that the coder-stall is the primary
  cause, not a pipeline bug.
- `swap-progress.log` ends with `The 14B did NOT restart after retries — restart BlarAI to recover.` —
  this is the separate **RESTART-AO / `SWAP_FAILED → RECOVERED`** issue (plan risk R5), *not* the no-op;
  out of scope for this item, tracked for the W7 RESTART-AO robustness line.

## Why the run no-op'd instead of recovering — the code path

The idle stall sets a single `TimedOut` flag, and every layer treats a timed-out candidate as terminal:

- `fleet-lib.ps1` `Invoke-AgentRun` doc (≈L138–144): idle and ceiling *"both map to TimedOut (never
  resampled; see Test-ShouldResample)."* `Resolve-RunStopDecision` returns `Reason='idle'` for the stall.
- `Invoke-BuildWithRetry` (≈L1129): the inner no-op retry loop condition is
  `while (-not $changed -and -not $run.TimedOut -and …)` → a timed-out attempt gets **no** inner retry.
- `Test-IsCandidateGreen` (≈L1210): `(-not $HasChanges) -or … -or $TimedOut` → never green.
- `new-agent-task.ps1` best-of-N wiring: `-StopSampling { … -or ([bool]$c.TimedOut) }` → a timed-out
  candidate **breaks the best-of-N loop**, so candidates 2 and 3 are never sampled.

So the design is *consistent and intentional*: "do not resample a timed-out coder." That rule was written
for the **expensive wall-clock** case (resampling a genuinely-productive-but-too-slow coder 3× could cost
3 × 60 min). It also catches the **cheap idle** case (a ~4-min stall that made no changes) — and that is
the debatable part (see the recommendation).

## The plan's hypotheses vs. the evidence

| Plan hypothesis (§2.2 / §5 W7) | Verdict | Evidence |
|---|---|---|
| "model prints a tool-call as text / writes to a denied path" (`Invoke-BuildWithRetry` should catch) | **Not this** | The coder made *real* `glob`/`read` tool calls, then stalled *silently* before editing — no text-form tool call, no denied write in the transcripts. |
| "retry-on-no-op budget under **C=3**" | **Not this** | Both runs used the **sequential C=1** path (`Building candidate 1 of 3`, single `.c1` log). The N-budget collapse was `StopSampling`-on-timeout, not a retry-accounting error. |
| prompt / scaffold issue | **Not this** | The `web` scaffold seeded 10 files cleanly; the language pin + offline-web hints fired; the prompt was well-formed. Run 3 proves the same prompt/scaffold builds. |

## What was fixed here (clear defect — doc-honesty, zero behaviour change)

The circuit-breaker *reason* (`idle` vs `ceiling`) was already captured (`Resolve-RunStopDecision` →
`Invoke-AgentRun` `TimeoutReason` → threaded onto the candidate's `Run`), but the operator-facing report
ignored it and hard-coded the wall-clock wording. Fixed:

- New pure helper **`Get-TimeoutStopText`** (`fleet-lib.ps1`) — renders an honest BUILD line: an idle stall
  now reads *"STOPPED early: the coder went idle for 240s (no new step or edit — genuinely stuck)…"*
  instead of *"STOPPED … after 60 min."* Unknown/empty reason falls back to the ceiling phrasing
  (back-compat).
- **`Get-RunAnomalies`** gained a `-TimeoutReason` param; an idle stall now reports *"agent went idle …
  genuinely stuck"* instead of *"agent hit the wall-clock timeout."* `LoopSuspected` is unchanged (still
  set on any timeout — the merge-gate soft-signal is byte-identical), so **no pipeline behaviour changes.**
- `new-agent-task.ps1`'s `BUILD:` line now calls `Get-TimeoutStopText`; `Invoke-CandidateBuild` passes the
  reason through.
- **Regression lock:** `verify-runtimeout.ps1` grew a *Honest timeout labelling* section (14 assertions,
  T1–T8) asserting idle-vs-ceiling text in both helpers and the back-compat fallback. Full suite
  **45/45**; `verify-bestofn` 68/0, `verify-bestofn-concurrent` 108/0, `verify-struct` 50/0 (the
  `Get-RunAnomalies` signature change is regression-clean).

## Recommendation (a DECISION for the LA — not changed here)

**Make an *idle*-reason timeout resample-eligible in best-of-N, while keeping the *wall-clock ceiling*
terminal.** Rationale: the idle stall is cheap to detect (~4 min, zero changes) and is precisely the
"stuck coder" that best-of-N's fresh independent samples are designed to route around — run 3 (same task)
proves a fresh attempt can succeed. Today a single early idle stall on candidate 1 silently burns the
entire dispatch cycle (the operator re-queued the task twice before it landed).

- **Shape:** split the `StopSampling` / `Test-ShouldResample` predicate so `TimeoutReason='idle'` is
  resample-eligible but `'ceiling'` (and secret-block) stay terminal. Bound it with the existing N budget
  so worst case is N × (idle timeout), not unbounded.
- **Trade-off (why it's a DECISION):** it changes runtime behaviour and the cost profile — an idle-prone
  coder would now spend up to N idle timeouts per task instead of one. If the stall is *correlated*
  (OVMS wedged, model degraded) the resamples may all stall too. Worth pairing with the RESTART-AO
  robustness work (R5) since both surface as "the coder/backend stopped responding."
- This is escalate-only per the defect-vs-decision boundary: it lowers/raises no security posture but it
  does change what the fleet *does*, so the LA weighs the time-cost trade-off.

**Secondary observation (coder reliability, not fixable via fleet flags):** the read-then-stall variance
on these web tasks is the same class as the Part C "tool-call reliability tax." The `coder-30b`'s
`MOE_USE_MICRO_GEMM_PREFILL=0` mitigation (long-prompt MoE-INT4 accuracy) is already set; whether the
stall correlates with prompt length or is a serving-side streaming stall would need an A/B on the real
14B/30B — out of scope for W7, a natural probe for W8's live residency.
