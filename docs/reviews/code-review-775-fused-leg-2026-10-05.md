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


---

# Round 3: fix/1691-fused-leg-flip-blockers at 6905e03 (9 commits off d026f5c)

Tested HEAD **6905e03** in worktree `C:/Users/mrbla/agentic-wt-1691-m1`. Constraints were unchanged: no real task, account, ACL, firewall or provisioning changes, pwsh 7, temp roots only. Probe scripts are in the scratchpad: `offdiff2.ps1`, `r3acl.ps1`, `r3race.ps1`, `r3det.ps1`, `r3mut.ps1`; the random mutant pick is in `r3-pick.txt`.

## Verdict

- **Merge to agentic-setup main with containment `off`: MERGE-READY.**
  - The off path matches main: offdiff2 shows 0 differing lines between d026f5c and 6905e03, across 15 manifest shapes, with the ACP interpreter both available and unavailable.
  - With no fused record, the funnels give the historical argv: `Get-WtGit` returns `-C <path>`, `Get-OperatorWorktreePath` is a plain Join-Path, `Remove-WorktreeSafe` runs the same `git -C $Repo worktree remove --force`.
  - No `state\fused-worktrees` folder exists in the live tree.
  - The 12 dispatch-path verifies are green.
  - The one change in off mode is a fix: a scratch-test delete now uses `-LiteralPath`.
- **Ready for the flip: NO.** N1 (below) plus the LA-run and provisioning items.

## M-findings re-verified

- **M1: FIXED for every check-time and pre-call swap, with one residual (N1).**
  - The swap-before-the-call control is REFUSED (`r3race.ps1`).
  - The builder's suite covers hooks and config planted while the coder runs, `.git` repointed, a cloned-pointer swap and a swapped root. Its hook/fsmonitor control proves plain `git -C` really executes the plant.
  - Hardened argv: `core.hooksPath=NUL`, fsmonitor off, sshCommand, ext, pager.
- **M2: FIXED.**
  - The transcript and the result are read from one held handle; a link or a multi-link file is refused.
  - The prompt is created exclusively; deletes sit behind `Test-FusedDirIntact`.
  - My mutation `R-transcript-links-off` was KILLED.
- **M3: FIXED** (`r3acl.ps1`). Inherit-only GENERIC_ALL and GENERIC_WRITE are now REFUSED, owners are checked, and the parent `C:\blarai-fleet` is in the checked set. The remainder is in N3.
- **M4: FIXED.**
  - `Stop-CoderLegTask` returns False when both the stop and the state query fail (reproduced).
  - Cancellation is polled in the mutex wait and in the Running wait (suite lines 896-897; mutants killed).
  - Provisioning writes the marker at step 8 and rollback removes it (code read; the offline test passes 35/0 against a temp path).
- **L8: DOCUMENTED** (`docs/fused-leg-budgets.md`). It is still not registered in BlarAI; the doc names the registration path.

## New findings

### N1 — BLOCKS THE FLIP: check-then-use on a path string; a coder process that outlives the leg can still swap the worktree
- `Get-WtGit` verifies the worktree, then returns a path string, and git opens that path later. `Assert-CoderLegTaskIdle` proves only that the scheduled task is not Running. It does not prove that no process owned by the coder account is alive.
- A process the coder started in the background and that outlives the task's action process is not covered. Whether such a process survives the task's exit or stop is a hypothesis: I could not run the real task.
- Reproduced (`r3det.ps1`, temp sandbox): verify, then swap the worktree for a junction, then run `git <hardened args> add -A`. The victim's file lands in the agent worktree's INDEX (`victim-file.txt = True`). The victim repo itself is untouched.
- Consequence: files from any folder the operator can read get staged and committed into the agent branch, which the fleet can then merge.
- A random 35 s flip race produced 31 passed calls and 391 refused, with no leak. The window is small but real.
- Fix:
  - after the leg, terminate and confirm the absence of every process owned by the coder SID, or run the leg in a job object with kill-on-close
  - and/or give the coder no DELETE on the worktree root or FILE_DELETE_CHILD on the base, so the swap itself is impossible
  - optionally, verify the work-tree identity again from inside git's own handle.

### N2 — should-fix: the lint certifies more than it tests
I applied these mutants in a temp copy, with a control that passed:
- `git -C "$wt"` (quoted): **SURVIVED**
- `git -C $Repo` inside `Restore-WorktreeToHead` / `Get-WorktreeDigest`, whose parameter is named `$Repo` but holds a worktree: **SURVIVED**
- `Remove-Item -LiteralPath $wtOrig -Recurse -Force` in place of `Remove-WorktreeSafe`: **SURVIVED**
- the plain raw `git -C $wt`: KILLED
- an unguarded delete inside the fused function: KILLED

The suite's claim "fails on a new unguarded use" holds only for the exact spellings `$wt`, `$wt_k`, `$Worktree`, `$wtOrig`, `$cand.Worktree`, `$__stale` written without quotes.

### N3 — should-fix: fingerprint coverage is not locked
- Removing `config.worktree` or `info\attributes` from `Get-GitDirFingerprint`: both **SURVIVED**.
- Impact is low: `config.worktree` is read only when `extensions.worktreeConfig` is set in a fingerprinted config, and attributes can only select drivers that already exist. The global config does define `filter.lfs` (required), so attributes the coder controls can make operator-side `git add` run git-lfs on coder content. That is the trusted git-lfs binary, not arbitrary code, and it applies equally in off mode.
- Separately, loose ACLs on FILES already inside the checked dirs are not examined (`child-file-loose` PASSED). Operator files are created exclusively, so this is a note.

### N4 — note: `core.hooksPath=NUL` disables a control nobody uses today
- No target repo under `C:\Users\mrbla\projects`, and agentic-setup itself, has a non-sample hook. BlarAI has a `post-commit` hook, but BlarAI is not a fleet target.
- No `init.templateDir` is set, and gitleaks runs explicitly through `secret-scan.ps1` before the commit. So nothing live is lost.
- But `install-gitleaks.ps1` recommends a gitleaks hook through `core.hooksPath`. If that is ever adopted, fused worktrees would skip it silently. Keep the explicit scan as the control of record.

### N5 — note: unaudited consumers
The doc says it plainly: critic, website review and battery helpers that open a worktree after a dispatch were not audited and do not call the funnels.

## Mutation harness
- Random 25 of the 110 non-probe mutants, picked with `System.Random(775)` (list in `r3-pick.txt`): **25/25 KILLED**, control passed, exit 0.
- My own mutants of controls: transcript-links KILLED; fingerprint `config.worktree` and `info\attributes` SURVIVED (N3).
- The builder's complete 117-mutant run was not repeated in full.

## Suites at 6905e03 (pwsh 7, run by me)
- verify-coder-fused-seam 614/0
- verify-coder-provisioning 35/0
- verify-git-capture-honesty 181 passed
- verify-bestofn-concurrent 133/0
- verify-bestofn 91/0
- verify-breaker-reason 36/0
- verify-stop-contract 29/0
- verify-nochange-outcome 73
- verify-coder-leg-quiesce 21/0
- verify-coder-leg-wiring 12/0
- verify-fleet-driver 37/0
- verify-retry 52
- verify-worktree-add-fail-loud passed

## What still blocks the flip
1. N1: no coder-SID process may survive the leg (kill and confirm, or a job object), and/or no DELETE on the worktree root for the coder.
2. #1686: provisioning tightens `C:\blarai-fleet` (today Authenticated Users have Modify and the owner is Administrators). With the current ACL the leg refuses to run, which fails closed.
3. #1678: the coder holds Modify on all of `C:\Users\mrbla\projects`, which includes the main repos' `.git` (refs, objects, config). Fingerprinting catches config and hooks but not refs or objects.
4. Plan step 4: the coder's own opencode config, read grants, and the `:8099` probe.
5. Egress: the #1682 persistent filter set, so `Assert-CoderEgressContained` throws instead of logging the accepted gap.
6. LA-run provisioning, a real-mode `verify-coder-containment.ps1 -AcceptedEgressGap` green, one watched fused dispatch, then the LA-present flip.
7. N2 and N3 lock gaps (should-fix), and N5 consumers audited before any of them runs against a fused worktree.


---

# Round 4: fix/1691-n1-n3-n5 at HEAD (off agentic-setup main 39dc7e9)

Tested the branch worktree `C:/Users/mrbla/agentic-wt-1691-n1`, HEAD = commit "the audit-log test reports a missing log as a failure". Constraints unchanged: no real task/account/ACL/firewall/provisioning changes; temp roots; pwsh 7 and 5.1; I spawned only my own harmless child processes (powershell, ping) for the job-object test, and created NO scheduled tasks. Probes in the scratchpad: `r4job.ps1`, `r4parser.ps1`, `r4race.ps1`, `r4det.ps1`, `r4-pick.txt`.

## Verdict

- **Merge into agentic-setup main with containment `off`: MERGE-READY.**
- **Ready for the flip: NO** (list at the end; item 0 decides what N1 still needs).
  - Off matches main: offdiff2 shows 0 differing lines between 39dc7e9 and HEAD across 15 manifest shapes, both ACP states.
  - The job object, the pin, the quarantine and the strict parser are all reached only under `restricted_account`; `off` runs the historical path and no `state\fused-worktrees` folder exists in the live tree.
  - 12 dispatch-path verifies green under pwsh 7; wiring green under 5.1.

## The elevation story (NOT verified; the premise is probably wrong)
- `shared/fleet/dispatch.py:394/440` launches run-fleet as `pwsh -NoProfile -NonInteractive -File` with no RunAs. That proves only that dispatch does not ADD elevation: run-fleet inherits whatever token the Assistant Orchestrator has.
- The launcher requests elevation at start (`launcher/__main__.py:6`, `launcher/vm_manager.py:60 request_elevation`), and the only child it de-elevates is the WinUI surface (`launcher/orphan_guard.py:5`, `launcher/process_launch.py`). If the AO is a launcher child in host mode, it, and so run-fleet, probably runs ELEVATED.
- I could not measure it: no launcher or AO process was running during this review. My own shell is elevated, so I could not test the non-elevated view directly either.
- Consequence: the builder's stated premise "the AO launches run-fleet non-elevated" is unverified, and the code points the other way. That is not a fail-open: if run-fleet is elevated, the elevated defence-in-depth (`Stop-CoderProcessesConfirmed`, which enumerates every coder-SID process) runs, and that catches the WMI escape below. But the design doc and the suite's "non-elevated" framing describe a configuration that may not be the real one. Settle it with one live read of the AO process's token elevation before the flip.
- Reasoned, not run: a non-elevated operator token cannot open another account's processes, so `GetOwnerSid` and termination fail. The code handles this by returning `$null` and leaning on the job object.

## Job object (my own harness, `r4job.ps1`)
- KILL_ON_JOB_CLOSE (0x2000) is set; no BREAKAWAY bit (0x800/0x1000) is set.
- A process started in the job with a child and a grandchild (`ping -n 60`): the grandchild is IN the job; closing the handle kills the whole tree (survivors = none).
- `Start-Process`/ShellExecute child: joined the job, killed with it.
- **WMI `Win32_Process.Create` ESCAPES the job** — the spawned process is a child of WmiPrvSE, outside the job, and survived `Close-CoderJob`. Reproduced. A standard user (the coder) can call it.
- `schtasks` vector: SKIPPED per instruction (no scheduled tasks created); by the same mechanism (spawned by the Schedule service) it would also escape.
- The "children did not join when the runner assigns ITSELF" finding is real and correctly avoided: the code starts the coder process suspended, assigns it, then resumes, so descendants are born inside the job. Nested jobs (the task's own job on Win8+) are allowed and did not block assignment here.

## What the WMI/schtasks escape means
The runner's `Stop-CoderJobProcesses` queries only the job's own pids, so **`job_zero_confirmed=true` can be reported honestly while a coder process spawned via WMI/schtasks is still alive.** The design does not rest correctness on that field (the builder demoted it to diagnostic). The real N1 lock is the **held directory pin** (`Lock-FusedWorktree`/`Open-PinnedDirectory`): an open handle on the worktree's `.git` with no delete-sharing, kept in `$script:FusedLocks` across every operator-side use. With it held, no process — job-contained or not — can rename, delete or swap the worktree or an ancestor.

## N1 race, re-run against HEAD
- `r4race.ps1` (35 s random flip): 173 git calls passed the check, 0 refused, nothing staged in the victim repo.
- `r4det.ps1` (deterministic swap right after the funnel check): the swap itself is now **Access denied** — the pin blocks it. In round 3 this exact sequence leaked `victim-file.txt` into the agent index; at HEAD it cannot.

## Quarantine (code + suite)
- The marker lives in the operator-only `state\fused-worktrees`, not in coder-writable `C:\blarai-fleet`, so the coder cannot forge or clear it; a write that cannot persist still quarantines in-process and throws (never fails open).
- `Clear-FusedQuarantine` requires a non-blank `-ClearedBy` and appends to `quarantine-cleared.log`; clearing without a name throws.
- The suite proves a quarantined worktree is refused by every sibling route (git, run-command, file write, worktree-remove, re-register, best-of-N sibling), and that re-registering or removing does NOT clear it.

## job_zero_confirmed demotion (suite)
A dispatch result without the fact is refused even for an elevated operator; a result claiming zero while the task is Running, or from the wrong SID, or a survivor the elevated enumeration finds, still quarantines. The field cannot override a live task or a survivor.

## Strict parser (my 20 inputs, `r4parser.ps1`, plus the builder's 36)
18 of my 20 decidable inputs matched the intended verdict; the 2 lone-surrogate cases are a note (N6). Confirmed rejected: nested and case-insensitive duplicate keys, UTF-16 (LE/BE) and UTF-32 BOMs, 1e400 overflow, nesting 40, NUL and literal control chars in strings, leading zero, `+1`, NaN, trailing comma, bare word, overlong/invalid UTF-8. Confirmed accepted: UTF-8 BOM, a 30-digit integer, nesting 30. The builder's 36-input table re-ran clean inside the suite.

## Future-dated result + clock skew
Covered in the suite (a result created after the read-back window / future-dated is refused). I did not find a separate wall-clock-skew knob; the check is creation-time vs the enqueue instant on the same clock, so a machine-wide skew moves both together and does not open a window. Note N7.

## New findings
- **N6 — note:** `\ud800` / `\udc00` lone surrogates in a JSON string are accepted (appended as-is). Bounded text, no code path; worth rejecting unpaired surrogates for completeness.
- **N7 — note:** the result `NotBefore` check compares the file's creation time to the enqueue time on one clock. A coder that pre-creates the result file a moment after its job is enqueued (same second) is caught by the owner+id+kind binding, not by time; time is a secondary signal, which the code acknowledges.

## Residual risk (for the flip, not the merge)
With containment ON, a coder process that escapes the job via WMI/schtasks and outlives the leg can still (a) modify file CONTENTS inside the pinned worktree and in `C:\blarai-fleet`, and (b) use network egress (the accepted Bitdefender gap). The pin stops the dangerous directory/ancestor SWAP (the confused-deputy git redirect), and the quarantine fires whenever the operator cannot positively confirm the tree is drained — but on the non-elevated path "drained" is the job's own count, which a WMI escape evades. So the honest statement is: the swap-to-another-repo escalation is closed; an in-place content edit by a surviving escaped process between the gate and the merge is not provably excluded on the non-elevated path.

## Suites at HEAD (pwsh 7, run by me)
verify-coder-fused-seam 985/0; provisioning 42/0; git-capture-honesty 181; bestofn-concurrent 133/0; bestofn 91/0; breaker-reason 36/0; stop-contract 29/0; nochange-outcome 73; coder-leg-quiesce 21/0; coder-leg-wiring 14/0 (and 14/0 under PS 5.1); fleet-driver 37/0; retry 52; worktree-add-fail-loud passed.
Random 30 mutants, seed `System.Random(1691)` (pool 180; list in `r4-pick.txt`): **30/30 KILLED**, control passed, SURVIVED/ERROR = 0, exit 0.

## Flip-blocker list
0. **Measure the AO's real token elevation** (one live read). It decides which half of N1 applies: elevated means the coder-SID enumeration catches WMI-escaped processes; non-elevated means item 1 is open.
1. **Residual N1 on the non-elevated path:** a WMI/schtasks-escaped coder process is not counted by `job_zero_confirmed` and cannot be enumerated non-elevated. Options: run the coder-leg task with an elevated confirmer that enumerates the coder SID, deny the coder WMI/Task-Scheduler process-create (per-user WMI namespace ACL / `Deny` on schtasks), or keep the pin held through merge and re-verify the tree digest immediately before merge.
2. #1686: provisioning tightens `C:\blarai-fleet` (today Authenticated Users Modify) — until then the leg refuses to run (fail-closed).
3. #1678: the coder holds Modify on all of `C:\Users\mrbla\projects`, including each repo's `.git` refs/objects (fingerprint catches config + hooks, not refs/objects).
4. Plan step 4: coder's own opencode config, read grants, `:8099` probe.
5. #1682 persistent egress filters, so `Assert-CoderEgressContained` throws instead of logging the accepted gap.
6. LA-run provisioning, real-mode `verify-coder-containment.ps1 -AcceptedEgressGap` green, one watched fused dispatch, then the LA-present flip.
7. N6/N7 notes (optional hardening).
