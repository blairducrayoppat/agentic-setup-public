# Code review: #775 fused coder leg, 2026-10-05

Reviewer: independent adversarial review (did not write the code, did not fix anything).
Tested: agentic-setup worktree `C:/Users/mrbla/agentic-wt-775-fused`, branch `feat/775-fused-coder-leg`, HEAD **a03a9c0** (off main c9cfba7). The tree did not move during the review.
Constraints observed: provisioning, verify-coder-containment.ps1, the real `\BlarAI\BlarAI-Coder-Leg` task, accounts, ACLs, firewall, WFP, GPU and models were not touched. Every restricted-mode probe ran against temp queue roots with doubles for Get-LocalUser, Get-ScheduledTask(Info), Start-ScheduledTask, Invoke-AcpCoderRun and Invoke-AgentRun. Scripts: scratchpad `offdiff.ps1`, `restricted.ps1`, `mymut.ps1`, `mymut2.ps1`.

## Verdict for merging with containment staying `off`

**MERGE-READY.** With `off`, behaviour matches main for every manifest shape tested. The only differences are deliberate: an unrecognised containment value now refuses, where main ran the coder as the operator. Nothing in the fused leg can run while the flag is `off`. Seventeen suites passed (list below). The findings below are about the restricted path. L1–L4 **block the containment flip, not this merge.**

## Findings

### L1 — should-fix before the flip (blocks the flip): the result's SID check only checks a field the result writes about itself, so a forged result is accepted
- `scripts/fleet-lib.ps1` Invoke-FusedCoderRun step 6 compares `$res.ran_as_sid` to the coder's SID. That value is plain text inside the result file. Anyone who can write `results\` can supply it: Authenticated Users (Modify, inherited from `C:\`; read-only `Get-Acl C:\blarai-fleet` confirmed it today) and any process the coder starts.
- Reproduced (`restricted.ps1`, branch tree). The task double ran no coder. A third party listed the queue, read the job id and wrote `<id>.result.json` with the coder's SID. Output: `mode=forge ACCEPTED result: ExitCode=0 TimedOut=False Seconds=1`.
- The same run showed three looser checks, all accepted:
  - a result whose `id` field names another job (`idmismatch ACCEPTED`)
  - a top-level `ok=false` with an `error` set (`toplevelfalse ACCEPTED`)
  - an inner `Ok` given as the string `"false"` (`okstring ACCEPTED`)
- Cost: the dispatch believes a coder ran when none did. The gate still tests the worktree on its own, so a forged result alone cannot merge code. The gate does, however, run as the operator on whatever is in an all-users-writable worktree (L3).
- Recommended:
  - require `res.id -eq $jobId`, `res.kind -eq 'dispatch'`, `[bool]` typed `ok`/`Ok`, and `res.ok`
  - document that the SID check only catches a mis-registered task principal; it does not prove who wrote the file
  - get authenticity from the ACLs (L3), not from the file's contents.

### L2 — should-fix before the flip: queue and prompts can be written by other accounts, so another local account can make the coder run its job or prompt
- `Invoke-FusedCoderRun` checks for a stale queue, then enqueues and triggers the task. `Get-NextCoderLegJob` (coder side) claims the **oldest by CreationTime**. A file's owner can set its CreationTime.
- A job planted after the stale-queue check is claimed first. The orchestrator then times out, which fails closed. Meanwhile the planted `dispatch` job runs a prompt chosen by the attacker, with tools, **as blarai-coder**. Today that account holds Modify on all of `C:\Users\mrbla\projects` (#1678) and its egress is unfiltered (the accepted gap).
- `prompts\<id>.prompt.txt` sits in the same writable tree. It can be read or rewritten between `Set-Content` and the moment the coder reads it.
- Reproduced? Hypothesis. I reasoned it from the code and did not race it. The check-then-use window and the ordering by CreationTime are both visible in the code.
- Incidence depends on whether any other local account exists. Most exposure goes away once the coder-leg root's ACL is fixed (plan step 4).
- Recommended:
  - Invoke-FusedCoderRun should **refuse to run** when the coder-leg root or the worktree base grants write to anyone other than the operator, blarai-coder, SYSTEM and Administrators. That turns the provisioning gap into a fail-closed lock in code.
  - Split the rights: the coder gets read on `queue\` and `prompts\` and write on `results\` and `logs\` only.

### L3 — should-fix before the flip: the workdir check compares strings and never resolves links; the worktree base is writable by all users
- `$wdFull.StartsWith($wtBase)` runs on `GetFullPath`, which only rewrites the text and never follows links. Probes: `..` escapes, a sibling prefix (`worktrees2`) and a `\\?\` path are refused; `c:/BLARAI-FLEET/worktrees/x` and the short name `C:\BLARAI~1\...` are accepted, but both point to the same folder.
- A directory junction inside `C:\blarai-fleet\worktrees` would pass the check and point elsewhere. Reproduced? Hypothesis; I did not create links.
- A junction cannot give the coder rights its ACLs do not already grant. The exposure is on the operator side: the gate, git and merge run as the operator in a tree any local account can modify.
- Recommended:
  - resolve the final path (open the folder and read its real path, or reject any link point along the path), then compare
  - create each worktree in its own subfolder with explicit ACLs
  - add the same ACL refusal as L2.

### L4 — should-fix before the flip: no cancel, and the coder keeps running after the orchestrator gives up
- Invoke-FusedCoderRun never calls `Stop-ScheduledTask` and never checks `Test-DispatchCancelled`. I found 0 matches inside the function.
- Reproduced (`restricted.ps1`, mode `silent`): the result-wait timeout throws and no stop is issued.
- Under the fused leg the coder runs under Task Scheduler, outside the run-fleet process tree. Neither `/dispatch stop` (the #771 stop contract) nor a killed Start-Job candidate can reach it.
- Consequences: an orphaned coder keeps editing a worktree the orchestrator has abandoned, and the next candidate waits up to QueueWaitSec on `State=Running`.
- Recommended: on any throw after the task starts, and on cancellation, stop the task and wait for it to stop. Poll the cancel sentinel inside the waits.

### L5 — should-fix: the mutation harness cannot report a mutant that survives
- `verify-coder-fused-seam.ps1 -Mutations` copies only 3 files. The suite reads `verify-coder-containment.ps1` at line 331 under `$ErrorActionPreference='Stop'`, so every mutant copy crashes there and exits non-zero. Non-zero is counted as KILLED, and there is no unmutated control run in the same layout.
- Reproduced: I added a mutant known to survive (ReleaseMutex removed) to a temp copy of the harness. Output: `[KILLED] REVIEWER-known-survivor <- ` with an empty reason, then `MUTATIONS: 22 of 22 killed`.
- The builder's 21 kills are real: each carried a genuine `[FAIL]` line. The harness simply cannot show a survivor.
- Recommended: copy every file the suite reads, run an unmutated control first and require it to pass, and count a mutant as killed only when a `[FAIL]` line appears.

### L6 — should-fix: two lock gaps, one a lock that cannot fail
I mutated 4 controls in temp copies, with an unmutated control (157/0 passed):
- **ReleaseMutex removed: SURVIVED** (157/0). The lock "mutex released after a failure: a later candidate is not locked out" cannot fail. Both calls run on the same thread, and a .NET Mutex can be re-entered by the thread that owns it.
- **Default `ResultWaitSec` changed to 1 s: SURVIVED.** Every test passes `-Options`, so the shipped defaults (StartWaitSec 20, QueueWaitSec 2T+300, ResultWaitSec T+360) are never exercised.
- **Shared-log cleanup removed: SURVIVED.** If transcripts stay in an all-users-readable folder, no test notices.
- **Abandoned-mutex catch changed to refuse: KILLED**, but only by accident: the earlier Stop-Job holder leaves an abandoned mutex behind. No test targets this case explicitly.

### L7 — should-fix before the flip; pre-existing on main: a garbled or missing manifest still runs the coder uncontained
- Reproduced with `offdiff.ps1` on main and on the branch:
  - `garbled-json` whose intended value was restricted_account → `STDIN` as the operator, on both
  - `missing-file` → `STDIN`
  - `"containment": null` or the key absent → `off`
- The branch refuses only a value that is present and unrecognised.
- Today this changes nothing, because with `off` the coder runs as the operator anyway. After the flip it is a silent failure that leaves the coder running uncontained.
- The fleet-driver.json note now says "any other containment value is refused". That overclaims for null, missing and unreadable manifests.
- Recommended: keep the coercion to `off` for the other readers, but add `containment_unresolved` (unreadable, missing or null) on the `research_docs` pattern. Have Invoke-CoderDriver refuse it once a sentinel such as `"containment_required": true`, or a machine marker written at provisioning, says containment is expected. Note that a missing manifest also downgrades `driver` from acp to stdin today.

### L8 — note: hard-coded budgets missing from the registry and the nesting test
- StartWaitSec 20, QueueWaitSec 2T+300 and ResultWaitSec T+360 are literals in the code.
- agentic-setup keeps no registry of its own. The convention (BlarAI `shared/timeout_registry.py`, which already registers agentic-setup windows such as the battery ceiling) is to register budgets that sit inside BlarAI's watchdogs, and `test_watchdog_windows_nest.py` checks that each outer window is larger than the inner one.
- A candidate can now take up to roughly 3T+660 s. Nothing checks that against the per-card or battery budget.
- The stall monitor's CPU check looks for coder processes by name across the whole machine. Whether it can read the CPU of another account's processes is unmeasured (hypothesis). The OVMS log timestamp probably keeps the run looking alive.

### L9 — note: prose that outlived its code
- `coder-leg-run.ps1` header:
  - still says "[fleet_dispatch].containment"; the setting lives in fleet-driver.json
  - claims the per-SID firewall block covers the coder tree; that block is inert (c.1653)
- The `Invoke-CoderDriver` docstring (fleet-lib.ps1 ~990) still describes only the driver and the stdin fallback. It does not mention the containment branch, which has no fallback.
- `coder-leg-run.ps1` has no BOM. It contains 11 non-ASCII bytes and does not parse under PowerShell 5.1 (4 parse errors). As a result, `verify-coder-leg-wiring.ps1` fails under 5.1 at a03a9c0. The task runs pwsh 7, so production is unaffected, but the BOM sweep skipped the one script the task actually executes.

### L10 — note: attacker-controlled strings are printed to the operator's console
`Write-Host` prints `$leg.Reason` and `ran_as_user` from the result file without filtering, which allows console escape sequences to be injected into logs. Low severity.

## Verified clean
- **`off` matches main** (`offdiff.ps1`): off+acp, off+stdin, key absent, null, garbled JSON and missing file all produce the same calls, arguments and result keys and values, with the ACP interpreter both available and unavailable. The only differences are the intended refusals of `restricted-account` and `1`. `Restricted_Account` (different case) is taken as restricted, which fails closed.
- **Fail-closed in restricted mode:** account missing, task missing, task never started (0x41303 diagnosis), result timeout, wrong SID written, leg refusal, empty or unusable result, workdir outside the base (`..`, sibling prefix, `\\?\`), driver not acp, queue contract not loaded, stale queue, task already Running. None of these runs Invoke-AcpCoderRun or Invoke-AgentRun as the operator.
- **Abandoned mutex:** the process holding it exits; the next call proceeds, and so does the call after.
- **Code injection on the operator side:** the prompt travels as a file, and the model and workdir travel as JSON. The operator side never builds a command line from them. On the coder side, `Start-Process -ArgumentList` with model and workdir taken from the job runs as the coder and gains no rights; it is pre-existing.
- **Restricted mode does not execute model-written code as the operator inside the fused function.** It parses JSON and copies the transcript. The gate that runs afterwards does execute model-written code as the operator, by design ("move ONLY the coder step", c.3862).
- **BOMs:** all 4 scripts change only `23 72 65` → `ef bb bf` at the start. `verify-coder-leg-wiring.ps1` is a pure BOM add: SHA-256 of the remainder equals main's (`288c8364…`). The other three also carry the intended content changes. All parse with 0 errors under pwsh 7 and 5.1. fleet-lib.ps1 gains no non-ASCII bytes; its 7 predate this branch.
- **Loading `coder-leg-queue.ps1` from fleet-lib** collides with nothing (grep across scripts). `verify-coder-leg-wiring` sets the root override before loading.

## Suites run at a03a9c0, by me
pwsh 7, worktree:
- verify-coder-fused-seam 157/0; `-Mutations` 21/21 (but see L5)
- verify-bestofn-concurrent 133/0
- verify-bestofn 91/0
- verify-breaker-reason 0 failed
- verify-stop-contract 29/0
- verify-nochange-outcome 73 passed
- verify-coder-leg-quiesce 21/0
- verify-coder-leg-wiring 12/0
- verify-fleet-driver 27/0
- verify-retry 52 passed

PowerShell 5.1:
- verify-fleet-driver 27/0
- verify-coder-fused-seam 157/0
- verify-coder-leg-wiring FAILS (L9, pre-existing)

Plus the reviewer probes `offdiff.ps1` (main vs branch), `restricted.ps1` and `mymut2.ps1`.

---

# Round 2: re-verification at 2b38999

Tested HEAD **2b38999**, on top of a03a9c0. Constraints were unchanged: the real task, account, ACLs and firewall were not touched. All probes ran with pwsh 7 against temp roots. Those roots had protected ACLs (operator, SYSTEM and Administrators only) because `%TEMP%` itself carries an orphan-SID Write ACE. The ACL gate correctly refused the unprotected roots. Scripts are in the scratchpad: `r2.ps1`, `r2acl.ps1`, `offdiff2.ps1`, `r2mut.ps1`, `r2mut2.ps1`.

## Verdict

- **Merge to main with containment `off`: MERGE-READY.**
  - Off plus a readable manifest still matches main exactly (offdiff2: off-acp, off-stdin, key absent and null value show identical calls and results).
  - Intended change: an unreadable manifest now refuses to run the coder on this machine, because the real `\BlarAI\BlarAI-Coder-Leg` task is registered. Main ran the coder as the operator through stdin in that case (garbled, missing, empty, scalar or array manifest, or a UTF-16 manifest). This is the L7 fix doing its job. Its cost: if fleet-driver.json is ever corrupted, dispatch stops loudly instead of running uncontained.
- **Ready for the containment flip: NO.** M1 blocks it, M2 to M4 should be fixed first, and L2's provisioning half (#1686) and the LA-run steps remain.

## Previous findings, re-checked

- **L1 FIXED**, verified with `r2.ps1` using a real owner check. The legitimate control is accepted. Each of these is refused and the task is stopped:
  - the wrong job id, or the id in different case
  - `ok` given as the string "true" or "false"
  - the inner `Ok` given as the string "True"
  - a top-level `ok=false`
  - `kind=probe`
  - a result file created before the job was queued
  - a `ran_as_sid` that is not the coder's
  - a file owned by another SID (the owner is read with `Get-Acl`)
  - `OK` spelled with different case is accepted; that is correct, since PowerShell property names ignore case.
  - Remaining: the file could be replaced between the owner check and the read. Only the coder, which owns the file anyway, could do that, and only once the ACLs are tight (M3).
- **L2 PARTLY FIXED, wrong spare (M3).** `Assert-CoderQueueAclTight` refuses:
  - Authenticated Users with Modify, and Users with WriteData or AppendData
  - an effective GENERIC_WRITE ACE
  - an orphan SID
  - Users CreateFiles alongside CREATOR OWNER
  - an allow ACE even when a deny ACE is present
  - a missing path (fails closed).

  It PASSES an inherit-only GENERIC_ALL or GENERIC_WRITE ACE for Everyone, a parent's DeleteSubdirectoriesAndFiles, and loose ACLs on files inside the tree. It does not check owners.
- **L3 FIXED at check time; post-check swap open (M1).** Real links were refused:
  - a junction as the workdir, or as one of its ancestors
  - a symlink as the workdir
  - the worktree base itself a junction
  - the queue dir a junction
  - `\?\` paths
  - a missing workdir.

  8.3 short names and different case resolve to the same folder and are accepted, which is correct (.NET expands short names).
- **L4 FIXED, with a gap.** The task is stopped on a result timeout and on cancellation while the coder runs. If the task refuses to stop, the error names it. Gaps:
  - cancellation is not honoured during the mutex wait: it ran the full QueueWaitSec, which is 4420 s in production at T=1800 (`r2.ps1`)
  - `Stop-CoderLegTask` reports success when the stop and the state query both fail (`r2acl.ps1`).
- **L5 FIXED.** `-ProveHarness` classifies the known survivor as SURVIVED, the crasher as ERROR and the real kill as KILLED. My own survivor (`R-equivalent-noop`) reported SURVIVED with exit 1. Full sweep: 56 of 56 killed, the control passed, exit 0.
- **L6 FIXED.**
  - Of my re-mutations of the 3 previously unnoticed controls: the result budget set to 1 s, the log cleanup removed, the reparse check off, the owner check off, NotBefore off and the stop not called were all KILLED.
  - Removing ReleaseMutex while keeping Dispose still SURVIVES. This is acceptable: the next holder takes an abandoned mutex and `AbandonedMutexException` is handled.
- **L7 FIXED for pwsh 7.** Under PowerShell 5.1, `verify-fleet-driver` fails 2 of 37: manifests of just `42` or `"text"` are not marked unresolved, because `-isnot [pscustomobject]` is true for any wrapped object in 5.1. Production uses pwsh (`dispatch.py:146` falls back to `powershell` only if pwsh is absent), so this is a note.
- **L8 PARTLY FIXED.** The budgets are derived in one place and the nesting is asserted inside agentic-setup. Registration in BlarAI's `shared/timeout_registry.py` is still not done, and the deferral names no ticket.
- **L9 FIXED.** The `coder-leg-run.ps1` change is the BOM plus header prose only: the code body's SHA-256 matches a03a9c0 (`272d68df…`). `verify-coder-leg-wiring` now passes 12/0 under PS 5.1.
- **L10 FIXED.** C0 and C1 control characters are stripped, including ESC and BEL. U+202E (bidirectional override) passes through, which is a note.

## New findings

### M1 — BLOCKS THE FLIP: a link swapped in after the check makes the operator's git run in another repository
- `Resolve-CoderFinalPath` checks the workdir once, before the trigger. The coder has Modify on the worktree base, so it can delete its workdir and put a junction to any directory in its place. Nothing re-checks the workdir after the coder returns.
- The operator side then runs `git -C $wt add -A` and commits (fleet-lib.ps1:4450, new-agent-task.ps1:229/251).
- Reproduced (`r2.ps1`, mode `swapjunction`, temp roots). After the run, the workdir is a junction to `victim-repo`. `git -C <workdir> rev-parse --show-toplevel` reports the victim repo, and `add -A` staged `secret.txt` there.
- Consequence: model-written code running as blarai-coder can steer the operator's own git commands into any repository, for example the main BlarAI checkout. That reverses what containment is for.
- Fix:
  - re-run `Resolve-CoderFinalPath` on the workdir immediately before every operator-side use after the coder returns, and refuse a link
  - better: open the workdir handle without following links and keep it open, or verify the inode/file-id is unchanged
  - and/or grant the coder Modify on the worktree's contents but not DELETE on the worktree folder itself (and FILE_DELETE_CHILD not on the base).

### M2 — should-fix before the flip: the other check-then-use gaps are covered only by the ACL gate
- **Confused deputy:**
  - the operator creates the prompt file in, and later deletes the prompt, log, `.claimed` and result files from, folders the coder can write
  - `Copy-Item` copies the coder-controlled shared log to the operator's LogPath without checking for links.
- Bounded today:
  - every operator write or delete targets a name containing a random job id
  - a symlink to an arbitrary file needs SeCreateSymbolicLinkPrivilege, and developer mode is off (registry 0)
  - a hard link to a secret needs a handle the secret ACLs deny.
- What remains: the coder can junction `prompts\` or `logs\` after the check, so the operator writes or deletes one file with a random name under any folder. Severity is low. This is a hypothesis; I did not race it.
- Fix:
  - create per-job folders owned by the operator, with explicit ACLs
  - before copying, refuse a shared log that is a link or has more than one hard link.

### M3 — should-fix (wrong spare): the ACL gate misses generic inherit-only rights, owners and parents
- Reproduced (`r2acl.ps1`). An inherit-only `(A;OICIIO;GA;;;WD)` ACE PASSES, so every new job and result file grants Everyone full control. A third party could then rewrite a coder-owned result and the owner check would still pass.
- A parent's DeleteSubdirectoriesAndFiles PASSES. `C:\blarai-fleet` itself is not among the checked paths.
- Dir owners are not checked. A dir the coder owns (prompts and logs may be created by the coder side first) can have its DACL loosened after the check. Today the owners of the existing dirs are Administrators, which is fine.
- Fix: map the generic bits to specific rights (or test GA/GW/GE directly), check the parent `C:\blarai-fleet` for FILE_DELETE_CHILD, and require the owner to be the operator, Administrators or SYSTEM.

### M4 — should-fix: two quiet failure modes
- (a) `Test-CoderContainmentExpected` relies only on the task, because nothing writes the provisioning marker (grep: only fleet-lib's default path and the suite mention it). An unregistered task plus an unreadable manifest falls through to running as the operator. Unregistering the task takes admin rights, so this is a note, but the marker is a dead half.
- (b) `Stop-CoderLegTask` returns `$true` when the stop and the state query both throw (reproduced).
- (c) The `Global\BlarAI-Coder-Leg-Dispatch` mutex name can be taken by any local account. That fails closed, so the cost is denial of service only.
- (d) Cancellation is not checked during the mutex or Running waits (L4).

## Suites at 2b38999, run by me
pwsh 7:
- verify-coder-fused-seam 367/0; `-ProveHarness` passed; `-Mutations` 56/56 killed with a passing control
- verify-bestofn-concurrent 133/0
- verify-bestofn 91/0
- verify-breaker-reason 36/0
- verify-stop-contract 29/0
- verify-nochange-outcome 73
- verify-coder-leg-quiesce 21/0
- verify-coder-leg-wiring 12/0
- verify-fleet-driver 37/0
- verify-retry 52

PowerShell 5.1:
- verify-coder-leg-wiring 12/0
- verify-fleet-driver 35/2 (L7 note)

## Could not break
Result binding (id, kind, booleans, owner, creation time); link refusal at check time for junctions, symlinks, base and queue dirs; `\\?\`, UNC and missing components; the `off` path matching main; no operator-account or stdin fallback on any restricted-mode failure; the stop-on-failure path; and the mutation harness's own classification.
