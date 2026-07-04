# Fleet builder brief — review/merge robustness: a clean WinUI app must MERGE, not park on a clobbered verdict

**Audience:** a Claude session in `C:\Users\mrbla\agentic-setup` (fleet PowerShell + the LIVE OpenCode config). FLEET-side; do NOT touch `~/BlarAI`.
**Tracking:** #670 (fleet review/merge robustness; follow-up after the winui-smoke WinUI proof).
**Authored:** 2026-06-23, by the dispatch LA, from a 7-agent ultracode root-cause (trace → adversarial-verify → synthesize); every line-ref below was independently re-derived by execution AND spot-confirmed by the LA.
**Severity:** this is WHY a correct, building WinUI app PARKED instead of merging — the operator's visible blocker for the rocket-calc. FIX B + FIX C are the unblock; FIX A is the upstream robustness.

---

## 0. Why — the live failure (root-caused in code, not assumed)

In dispatch run `20260623-152205-bd`, the `create-main-window` task produced a **correct, building WinUI app** (`VERIFY: pass` — `[pass] dotnet:build`, `[pass] eco:language`, `CHANGES: yes`, `SECRETS: clean`, `ANOMALIES: none`) and **still PARKED** on `REVIEW VERDICT: UNCLEAR`. Two compounding defects:

- **DEFECT 1 — the timeout override erases a parsed verdict.** The reviewer DID emit `## VERDICT: FIX FIRST` and the parser caught it (`new-agent-task.ps1:204-205`). Then **`:208` `if ($rv.TimedOut) { $verdict = 'UNCLEAR'; … }` runs UNCONDITIONALLY after the parse and clobbers it to `UNCLEAR`.** The timeout came from the read-only reviewer, *after* its verdict, looping: it malformed a `todowrite` call (`SchemaError: Expected array, got` a Python-dict literal — the same small-model tool-call brittleness as the qwen-proxy arc) and re-ran `dotnet build` ~8× (all 0/0) until the wall clock — the review path passes **no `-JsonStepCap`**, so it has neither the turn-cap nor the spin-detector the build path gets (`fleet-lib.ps1:196-235`), only the 10-min wall clock.
- **DEFECT 2 — the merge gate hinges entirely on the LLM verdict, with no build-only fallback.** `:213` merges only when `$verdict -eq 'MERGE'`; `UNCLEAR`/`FIX FIRST` both PARK (`:233`). For a **build-only ecosystem** (.NET/WinUI: `verify-project.ps1:112-119` runs `dotnet build` only; the `[2/5]` step at `:146-168` is npm/pytest only, so a WinUI task always lands `testResult='none'`), the merge of a clean app rides entirely on a single brittle verdict the reviewer can't even fully form (it can't launch the GUI).

This brief was produced by a multi-agent root-cause whose **adversarial pass knocked down two of its own first-draft fixes** — read §1 and the per-fix CORRECTIONS; they are load-bearing.

## 1. Ground rules

- **Edit the LIVE config, not the git mirror.** OpenCode reads `~/.config/opencode/agents/review.md` + `~/.config/opencode/opencode.json`; `agentic-setup/configs/...` is the mirror and `sync-harness.ps1` reconciles **LIVE → git** (`:8-25`). FIX A edits the LIVE `review.md`; the mirror updates on next sync. **Confirm live==git hashes before and after** so the change lands where OpenCode actually reads.
- **Fleet scripts are LIVE on merge** (there is no dormancy flag for `new-agent-task.ps1`). The LA independently gates before any merge; ship on a feature branch.
- **Do NOT touch** the spin-detector / `Get-RunAnomalies` (`fleet-lib.ps1`) or the secret-scan — all working as intended. Do NOT touch `~/BlarAI`.
- Offline, deterministic.

## 2. FIX B — a timeout must not erase a verdict the reviewer already emitted

`new-agent-task.ps1:208`. Today the timeout override is unconditional. **Resolved policy (a real decision the root-cause surfaced — do not re-open):** on timeout, treat the verdict as **LOW-TRUST and force `UNCLEAR`** (a verdict emitted while the agent was looping/malforming tools is not trustworthy), then let **FIX C** merge a clean build-only app on `UNCLEAR`. Do **NOT** ship the alternative "honor the parsed `FIX FIRST` on timeout" framing — it conflicts with FIX C (this run's parsed verdict was `FIX FIRST`; honoring it would still PARK, and FIX C keeps an explicit `FIX FIRST` a hard block). Force-`UNCLEAR`-on-timeout is both simpler and more correct.

So `:208` stays `force UNCLEAR on timeout` **but** must (a) still append the `(review agent timed out)` note, and (b) the *non-timeout* path must correctly carry the parsed verdict (it already does). The remaining bug FIX B fixes is purely that a timed-out review currently can't benefit from FIX C — which it now will, because UNCLEAR is the build-only-merge trigger. **Caveat from verify:** if you add any "honor a parsed verdict on timeout" logic later, gate it on a *"was any verdict parsed at all"* flag, **not** `$vm.Count` — the `:206-207` fallback path sets `$verdict` from `$reviewTail` without touching `$vm`.

Pair with a **shorter review wall clock** (`MaxReviewMinutes` default 4–5): a review that hasn't concluded in a few minutes is looping.

## 3. FIX A — harden the reviewer tool surface so it stops timing out

Edit the **LIVE** `~/.config/opencode/agents/review.md` frontmatter. **CORRECTION from the adversarial verify — target the right tools:** the log proves `write`/`edit` are ALREADY denied by the existing `edit: deny` (the model's `write` call was *"Model tried to call unavailable tool write"* — rejected instantly, ~no time). What actually burned the 10 minutes was (1) the malformed **`todowrite`** (the `SchemaError`) and (2) ~8 repeated **`bash` `dotnet build`** re-runs. So deny **`todowrite`** and **`bash`** (or restrict bash to a read-only `git diff`); a pure reviewer needs only `read`/`grep`/`glob`/`list`/`git diff`.

**Mechanism correction:** agent-level `tools:` is **deprecated** (`research/maturity/opencode-harness.md:12`); use the per-agent **`permission:`** block, where `todowrite` takes an action string (`deny`), not an object. Add to `review.md` frontmatter:
```
permission:
  edit: deny
  todowrite: deny
  bash: deny        # or a read-only allowance scoped to `git diff` only
```
Plus prose: *"Output ONLY your findings then the single VERDICT line; do NOT call any edit/todo tool; do NOT re-run the build."* Removing `todowrite` eliminates the `SchemaError`; removing/limiting `bash` stops the `dotnet build` churn.

## 4. FIX C — a build-only merge fallback so a clean app doesn't hinge on a flaky verdict

`new-agent-task.ps1` step `[5/5]` — add a SECOND merge predicate **OR-ed** with `:213`, gated to build-only ecosystems. Allow merge when:
`hasChanges AND NOT secretBlocked AND NOT agentTimedOut(build) AND NOT anomaly.LoopSuspected AND testResult != 'fail' AND verifyResult == 'pass'` (**strictly `'pass'`, not merely "not fail"**, so a `none`/`skip` can't sneak through) `AND $buildOnly AND` the verdict is not an explicit `FIX FIRST` with real blockers (with the resolved policy, a timed-out review is `UNCLEAR`, so a clean 0/0 build merges on `UNCLEAR`).

Derive `$buildOnly = ((Get-ProjectEcosystem $wt) -contains 'dotnet') -and (no .NET test framework present)` — define "no test framework" carefully: a dotnet project with a `tests/` dir mis-routes into the pytest branch (`:151`), so do **not** key off directory name alone. **Record in the report** that it merged via the build-only gate, so the operator knows the LLM review was inconclusive.

**Safety (verify-confirmed — this does NOT weaken security):** the secret-scan (`:131-140`) runs BEFORE commit independent of the verdict; `eco:language` fails closed; anomaly/loop/build-timeout still block; **Python/Node return `python`/`node` ecosystems, never `dotnet`, so they NEVER enter this path** — there the LLM verdict + real tests stay required. What we give up is only the LLM's subjective "is this good code" opinion for a build-only GUI it can't run anyway — which the operator's launch-and-eyeball was always the real check for. **SCOPE GUARD: do NOT extend FIX C to Python/Node.** Keep an explicit reviewer `FIX FIRST` a hard block (only an *inconclusive* review is bypassed, never a clear negative).

## 5. Verification (mutation-resistant + the live proof)

- **FIX B:** unit-assert the `:204` regex against the ACTUAL `winui-smoke-create-main-window-…review.log` fixture (captures `FIX FIRST`). Oracle: with `$rv.TimedOut=$true` + a parsed verdict, the result is `UNCLEAR` (the resolved policy); revert `:208` and confirm the test changes — prove the clobber is what we intend, not an accident.
- **FIX A:** drive a review run on a fixture diff; confirm the reviewer's effective surface **denies `todowrite` and `bash`** (the `SchemaError`-class call and any `dotnet build` re-run are refused) and the run terminates **on its verdict, not the wall clock**. Mutation: re-enable `todowrite` in a test copy and confirm the churn/timeout reproduces — proving the deny is load-bearing.
- **FIX C:** table-driven over `(ecosystem, testResult, verifyResult, verdict, secret, anomaly, timeout)`: assert MERGE **only** for build-only dotnet with `verifyResult=='pass'` + `UNCLEAR` + clean gates; assert NON-merge for every adversarial mutant (`verifyResult=='none'/'skip'` must NOT merge; secret/anomaly/build-timeout must NOT merge; a `python` ecosystem with the same shape must NOT take the fallback).
- **THE LIVE PROOF:** reconstruct THIS run's exact end-state (`VERIFY: pass`, `dotnet:build pass`, `eco:language pass`, review forced-`UNCLEAR`, `CHANGES: yes`, clean) and assert it **now MERGES** — that is the regression that proves the operator's rocket-calc no longer parks. Re-run `verify-ecosystem.ps1` + `verify-retry.ps1` to confirm no regression. Confirm live==git hashes for `opencode.json` + `review.md`.

## 6. Process

Feature branch off main (never commit to main). **Open with a comprehension gate**: your understanding of the two defects + the three fixes + the **resolved force-`UNCLEAR`-on-timeout policy** (confirm by reading `new-agent-task.ps1:204-213` + the review.log fixture). Wait for LA confirmation. Surgical commit (named files: `new-agent-task.ps1`, the LIVE `review.md`, the tests). Append a `BUILD_JOURNAL`/lessons note. One package before merge: the diff, the mutation-resistant test output, and the reconstructed-run-now-merges proof. The LA independently gates ("ultracode" → multi-agent adversarial review) before any merge.
