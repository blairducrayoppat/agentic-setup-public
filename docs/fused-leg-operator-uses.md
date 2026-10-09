# Fused coder leg: every operator-side use of a path the coder can write

Under `containment = restricted_account` the coder (account `blarai-coder`) has Modify on the worktree base
and on the coder-leg root (`queue\`, `prompts\`, `results\`, `logs\`) and nowhere else; on the projects folder
(every source repo, `.git` included) it has READ only, so it cannot commit: the operator funnel is the only
committer (see "The ACL stage" below). Anything the operator account later
reads, writes, deletes, copies or runs there is a use of coder-controlled state. Each kind has ONE funnel;
`scripts/verify-coder-fused-seam.ps1` (section "Operator-side uses: one funnel per kind...") fails when a new
use skips it, and its mutation harness proves the funnels are what the tests exercise.

| Kind of use | Funnel | What it enforces |
|---|---|---|
| git against a worktree after the coder | `git @(Get-WtGit $wt) ...` | no record: the historical `-C` argv; with a record: identity + no link + `.git` pointer + gitdir fingerprint (config, hooks, attributes) re-verified, throws before git starts, then `Get-HardenedGitArgs` (pinned git-dir/work-tree, hooks off, fsmonitor off, no optional locks, no pager, ssh/ext off) |
| run a command in a worktree (`Invoke-WithTimeout`) | `Assert-OperatorWorktree` at entry | same re-verification; a swapped worktree never runs a command |
| write, copy over or delete a file inside a worktree | `Get-OperatorWorktreePath` | re-verifies the worktree, refuses a relative path that leaves it or crosses a link |
| remove a worktree (`git worktree remove`) | `Remove-WorktreeSafe` | for a recorded worktree: a link at the path, or inside the tree, is deleted as a link first; the record is dropped |
| gate entry after the coder | `Assert-OperatorWorktree -Path $wt` in `Invoke-CandidateBuild` | the worktree is still the object recorded before the coder ran |
| result file | `Wait-CoderLegResult -ExpectedOwnerSid -NotBefore` | one handle denying writers/renames/deletes; owner from the handle; bytes from the handle |
| transcript copy | `Copy-CoderTranscript` | one held handle; not a link, one hard link; bytes from the handle |
| prompt / job write, staging cleanup | `Assert-FusedPathIntact` before, `Test-FusedDirIntact` before every delete | a swapped staging dir is never written or deleted through |
| the coder still running | `Assert-CoderLegTaskIdle` after the result | the task is not running (stopped if it is) before any check or use |
| paths the coder returns | none are used | `LogPath` and `workdir` come from what the operator recorded |

## Call-site audit (fleet-lib.ps1, new-agent-task.ps1, coder-leg-queue.ps1)

| Call site | Guarded? |
|---|---|
| `Invoke-CandidateBuild`: reset, clean, status, rev-list, checkout, add, diff, commit, rev-parse | yes, `Get-WtGit` |
| `Invoke-CandidateBuild` gate entry | yes, `Assert-OperatorWorktree` |
| `Get-WorktreeDigest`, `Restore-WorktreeToHead`, `Get-CandidateTestPartition` (git) | yes, `Get-WtGit` |
| `Invoke-WithTimeout` (every gate command: build, tests, verify) | yes, `Assert-OperatorWorktree` |
| `Write-SmokePin` (blarai-smoke.json), nuget.config seeding, red scratch-test delete, hypothesis stats file | yes, `Get-OperatorWorktreePath` |
| new-agent-task: winner restore (`reset --hard`, `clean`), review diff/stat, visual-fix loop (reset, status, rev-list, add, commit, rev-parse) | yes, `Get-WtGit` (the visual-fix loop was NOT covered before this change) |
| new-agent-task: worktree/branch cleanup (`worktree remove`, 7 sites) | yes, `Remove-WorktreeSafe` |
| new-agent-task: seed commits (scaffold, oracle) and `$codeBase` rev-parse, 5 lines | no, by design: they run before the coder exists; the lint allowlists exactly these 5 |
| new-agent-task / fleet-lib: `Test-Path` / `Get-ChildItem` reads of the worktree after the gate entry (project detection, csproj scan, public dir) | read-only, behind the gate-entry assertion; the coder task is confirmed idle first |
| `Invoke-FusedCoderRun` (queue, prompts, results, logs) | yes, see the table above; lint: every `Remove-Item` behind `Test-FusedDirIntact`, no `Copy-Item`/`Move-Item` |
| `Wait-CoderLegResult`, `Add-CoderLegJob` | handle-bound read; the job write follows the queue-dir identity check |
| `Get-NextCoderLegJob`, `Write-CoderLegResult`, `coder-leg-run.ps1` | coder side: they run as the coder and gain no operator right |

Not covered here: other scripts under `scripts/` that open a worktree after a dispatch (critic, website review,
battery harness helpers) were not audited in this change; the funnels above are what they should call.
Git for Windows' handling of a junction inside a tree during `worktree remove` is not relied on: links are
deleted first.

## Round-3 additions

### The swap window (N1)

**Elevation of run-fleet is UNVERIFIED (read the AO process token live before the flip).** `shared/fleet/dispatch.py`
launches `run-fleet.ps1` as `pwsh -NoProfile -NonInteractive -File ...` with no `RunAs`: that proves only that dispatch
does not ADD elevation, so run-fleet inherits whatever token the Assistant Orchestrator has. The launcher requests
elevation at start (`launcher/__main__.py`, `launcher/vm_manager.py` `request_elevation`) and de-elevates only the
WinUI surface, so an AO started by the launcher in host mode is probably ELEVATED, and so is run-fleet. An earlier
revision of this document called the orchestrator non-elevated; that was an assumption, not a measurement, and is
withdrawn. Both configurations are designed for and described below:

- **Elevated orchestrator:** `Stop-CoderProcessesConfirmed` enumerates every coder-SID process and ends their trees;
  that also catches a process that escaped the job (see the residual below).
- **Non-elevated orchestrator:** the operator cannot enumerate or end another account's processes; the job object, the
  runner's report, the task state and the pin carry the control, with the residual below.

Controls, in order of reliance:

1. **Primary, operator side: the pin.** `Lock-FusedWorktree` holds a directory handle (identity and resolved path
   checked from the handle) plus a share-Read handle on the worktree's `.git` pointer file, which is what stops a
   rename, replace or delete of the root or any ancestor (a handle on the directory alone does not; measured). git
   is handed the handle-resolved path. ACL half (#1686, applied by the LA-run ACL stage, action
   `worktree-root-deny`, see "The ACL stage" below): deny the coder `(DC)` on the worktree base and
   `(CI)(IO)(NP)(DE)` on the roots. It binds a STANDARD account only: measured 2026-10-06, an ELEVATED token of the
   same user renames and deletes a folder carrying both denies; a de-elevated token cannot.
2. **Primary, coder side: a job object the coder kills itself.** `coder-leg-run.ps1` (running AS the coder) creates a
   Windows job object with `KILL_ON_JOB_CLOSE` and no breakaway rights and starts the ACP client INSIDE it
   (`Start-ProcessInJob`: created suspended, assigned, resumed, so nothing runs outside it). Every descendant
   (opencode, node, builds) is born in the job. After the run the runner terminates what is left and queries the job
   until it is empty, and writes `job_zero_confirmed` (a strict boolean) and `job_active` into the result. If the
   runner exits or is killed first (Stop-ScheduledTask ends it), its job handle closes and Windows kills the tree.
   Measured: assigning the runner ITSELF to a job does NOT capture its later children, so that design is not used.
**Trust boundary (stated plainly).** `job_zero_confirmed` is written by the coder's own runner. It is NOT independent
proof: a compromised runner can write `true`, and the field adds no trust beyond the owner/SID binding of the file
that carries it. The gates are operator-side facts: the task state read after Stop-ScheduledTask plus a bounded
wait, and, for an elevated operator, an enumeration that finds nothing; the field never overrides either (tested:
a result claiming zero is refused when the enumeration finds a survivor or the task still reads Running). The
asymmetry is deliberate: bad news from the runner (false, missing, mistyped) is believed and quarantines; good news
is accepted only together with the operator-side stop confirmation, as the best a non-elevated operator has. On a
failure path a self-attested zero excludes survivors only if the operator also confirmed the stop.

3. **Operator side, no elevation:** the task is not Running after Stop-ScheduledTask and a bounded wait
   (`Assert-CoderLegTaskIdle`), and a dispatch result must carry `job_zero_confirmed=true`; a missing, false or
   mistyped value quarantines the worktree. On failure and timeout paths where the runner cannot report, the
   operator cannot exclude survivors: the worktree is QUARANTINED and refused by every route until a human runs
   `Clear-FusedQuarantine -ClearedBy <name>` (the marker lives in the operator-only directory; removing the
   worktree, a retry or a re-recording never clears it; each clearing is appended to `quarantine-cleared.log`).
4. **Elevated operator:** `Stop-CoderProcessesConfirmed` enumerates processes by coder SID (CIM `GetOwnerSid`), ends
   their trees and confirms none remain. This is the only control that catches a process the coder started OUTSIDE
   the job (WMI, scheduled task). Non-elevated it returns "not applicable" and is not a failure.

**Non-elevated residual (reproduced by the round-4 review, not fixed here).**
- A coder process created through WMI `Win32_Process.Create` is a child of WmiPrvSE, not of the job: it ESCAPES the
  job and survives closing it. A standard user can call it. A task created through the Schedule service would escape the
  same way (not run in the review).
- `job_zero_confirmed` counts only the job's own processes, so it can be reported honestly while such a process lives;
  a non-elevated operator cannot enumerate it.
- The pin stops a rename, delete or swap of the worktree root or any ancestor (the redirect of operator git into
  another repository is closed). It does NOT stop an escaped process editing FILE CONTENTS inside the pinned worktree
  (or in `C:\blarai-fleet`) between the gate and the merge. On this path that in-place edit is not provably excluded.
- Network egress by such a process is the accepted Bitdefender gap (#1682).

What Task Scheduler guarantees (not verified here): Task Scheduler runs a task's action in a job object, and stopping
or time-limiting a task ends the action's process tree. That behaviour was NOT tested: it needs a registered task, and
the task was not to be run or created in this work. VERIFY LIVE in the supervised session: start the coder-leg
task with a job that spawns a harmless child and a grandchild, `Stop-ScheduledTask`, and confirm both are gone.
The job object above does not depend on that guarantee.

Residual risk, stated plainly: if the runner dies in the window between the ACP client being resumed and the job
handle closing, the kernel closes the handle at process exit and the tree dies, so a survivor needs the job object
itself to fail (a kernel bug) or the runner never to have started the client in it (it does not start the coder if
the job cannot be created). A result forged by another local account is not a survivor report: the result owner and
SID binding refuse it, and the ACL provisioning (#1686) is what removes that class. (Derived, not measured:) survivors that live in a
different job-less process the coder spawned through something other than a descendant relationship (a scheduled
task it registers, a service) cannot exist for a Users-only account without rights it lacks. None of this is proven
against the live task: the real-mode `verify-coder-containment.ps1` and the watched fused dispatch are where it is.

### Routes that can reach the same worktree (sibling-route parity)

| Route | Gate it passes |
|---|---|
| `new-agent-task.ps1` sequential candidates | `Invoke-CandidateBuild`: `Assert-OperatorWorktree`, `Get-WtGit` |
| concurrent candidates (Start-Job children) | same functions; records and quarantine are operator-side files shared across processes |
| retry (`Invoke-BuildWithRetry -ResetWorktree`) | `Clear-WorktreeUntracked`, `Get-WtGit` |
| winner restore, review diff (`Resolve-CriticRange`) | `Get-WtGit` (the diff range helper was a raw `git -C` before this change) |
| visual-fix loop, critique (`Invoke-CritiquePass`) | `Get-WtGit`, `Assert-OperatorWorktree` (new-agent-task and the pass itself) |
| `critic-run.ps1` | `Assert-OperatorWorktree`, `Get-WtGit` |
| a later job reusing the worktree | `Invoke-FusedCoderRun` refuses a quarantined path; `Register-FusedWorktree` throws on one; only `Clear-FusedQuarantine` (a human) lifts it |
| removal / recreation | `Remove-WorktreeSafe`; removing or recreating a worktree does NOT clear a quarantine |
| `run-battery-night.ps1` stale cleanup | operates on `state\worktrees` only, never the fused base; allowlisted in the lint |
| capture-app / check-design-structural | children of the critique pass, which asserts first and holds the pin |
| BlarAI-side consumers (swap driver, dispatch cleanup) | NOT covered here: a separate repository |

Every route above is exercised against a quarantined worktree by the suite (section "Sibling routes"), with a
sentinel untracked file and a dirty edit that must survive. The quarantine and the pre-run records live in the
operator-side state directory, which the fused leg refuses to use if it sits inside a coder-writable root and
runs through the same ACL gate as the queue directories. A quarantine counts on its own (deleting the record does
not shed it) and a later recording cannot clear it.

### Strict, shared parsing

`coder-leg-queue.ps1` has ONE JSON parser (`BlarStrictJson`, via `ConvertFrom-StrictJsonBytes`) and typed schemas
for the job, the result and the dispatch envelope. Both sides use it: the runner for jobs and probe output, the
operator for results. It refuses a byte order mark other than UTF-8's, invalid UTF-8, NUL, comments, trailing
commas, trailing data, duplicate keys (case-insensitively), unknown keys, keys of the wrong case, wrong types
(a string where a boolean or integer is required), a job whose id is not its file name, and a dispatch job
missing a field. The PowerShell objects are built from that one parse, never re-parsed. A validator error is a
refusal. No `ConvertFrom-Json` remains in the queue library or the runner (a lint asserts it).

### Differential: what the strict parser and schema changed (d026f5c, 39dc7e9, 00eede2 against HEAD)

Same 36 inputs through `Wait-CoderLegResult`, `Add-CoderLegJob` and `Get-NextCoderLegJob` from each tree: no input
is accepted by HEAD that an older tree refused (one probe row reads inverted: it asks "is the planted target left
untouched", where d026f5c answered no and every later tree yes). Tightened since d026f5c: hard-linked results and
jobs, duplicate keys, UTF-16, string booleans, minimal objects, unknown kinds and keys, ids that are not the file
name, path-traversal ids, writes onto an existing name. One input was accepted by EVERY tree and is fixed here: a
result whose creation time is dated in the future (an owner can set its own timestamps); it is now refused.

### Job fields are input

The job file sits in a coder-writable directory, so the values the runner later uses as paths or arguments are
constrained, not just typed: absolute drive paths with no wildcard, control or UNC characters, a `local/<name>` model,
bounded integers; and before anything starts the runner requires `prompt_file` and `log_path` to be exactly
`<prompts|logs>\<job id>.<ext>` in the coder-leg root and `workdir` to resolve, link-free, under the worktree base.
The job-object wrapper is compiled in memory from scripts the coder can only read (Read+Execute grants), the
operator-side process killer is the System32 `taskkill.exe` by absolute path, and the task action is the `pwsh`
resolved at registration.

### State drift

A missing, stale or garbled gate record never means allow for a worktree a fused run recorded: a garbled, empty or
incomplete record refuses; a record from an earlier worktree at the same path refuses (identity); a quarantine is
remembered in the process as well as in its marker, the marker write is read back, and a marker that cannot be
persisted throws; a result file already present for a new job id refuses the trigger; a result dated in the future
refuses; the elevation decision is read on every call. Absence of any record for a path no fused run touched is the
historical unfused path by design.

### Flip blockers (recorded verbatim from the round-4 review)

0. **Measure the AO's real token elevation** (one live read). It decides which half of N1 applies: elevated means the coder-SID enumeration catches WMI-escaped processes; non-elevated means item 1 is open.
1. **Residual N1 on the non-elevated path:** a WMI/schtasks-escaped coder process is not counted by `job_zero_confirmed` and cannot be enumerated non-elevated. Options: run the coder-leg task with an elevated confirmer that enumerates the coder SID, deny the coder WMI/Task-Scheduler process-create (per-user WMI namespace ACL / `Deny` on schtasks), or keep the pin held through merge and re-verify the tree digest immediately before merge.
2. #1686: the ACL stage closes `C:\blarai-fleet` (today Authenticated Users Modify); built and self-tested on a temp tree, NOT yet run on the machine -- until the LA runs it the leg refuses to run (fail-closed).
3. #1678: the same stage narrows the coder from Modify to READ on `C:\Users\mrbla\projects`; same status (built, not run). The new real-account checks 5-14 of `verify-coder-containment.ps1` are what prove it.
4. Plan step 4: coder's own opencode config, read grants, `:8099` probe.
5. #1682 persistent egress filters, so `Assert-CoderEgressContained` throws instead of logging the accepted gap.
6. LA-run provisioning, real-mode `verify-coder-containment.ps1 -AcceptedEgressGap` green, one watched fused dispatch, then the LA-present flip.
7. N6/N7 notes (optional hardening).

### Notes N6 and N7

- **N6 (fixed):** unpaired surrogate escapes (`\ud800`, `\udc00`) in a JSON value or key were accepted; the strict parser now
  refuses them, a correctly paired escape still passes (test plus a mutant).
- **N7 (documented, not changed):** the result `NotBefore` check compares the file's creation time with the enqueue time
  on ONE clock. A machine-wide skew moves both together; a result pre-created in the same second is caught by the
  owner, id and kind binding, not by time. Time is a secondary signal. The only time input that came from a second
  source was a future-dated creation time, which is refused separately.

## The ACL stage (#1678 narrow, #1686 close the fleet root, #1692 protect the model folders)

Decision (LA 2026-10-05, #1678 c.3892): NARROW. The coder's Modify on `C:\Users\mrbla\projects` is replaced by an
inheritable READ-and-run entry; Modify stays only on the worktree base and the coder-leg job folders. A repo created
later (`create_project`) inherits the read entry and nothing else, so no re-provisioning is needed per project.

One stage, run by the LA: `scripts/provision-coder-acls.ps1` (the same code `provision-coder-account.ps1` calls).

| Command | What it does |
|---|---|
| `provision-coder-acls.ps1` or `-DryRun` | read-only; per folder prints WHAT, BEFORE, AFTER (computed), the exact commands, the UNDO listing, links inside the trees, and anything it REFUSES, then a PLAN DIGEST (hash of what it printed) and the size of the tree walks. Changes nothing. No elevation needed. |
| `-Apply -ExpectPlan <digest>` | elevated; plans again and REFUSES, printing a diff, unless the digest of that plan equals the one passed (the one the operator read); refuses if the coder-leg task is Running; saves every access list it will touch (`state\acl-backup\<time>\`: `manifest.json`, `plan.json`, one `.jsonl` per folder), applies, reads each folder back and compares it with the printed AFTER, then walks the whole projects tree for any write entry the coder still holds. Exit non-zero on any difference. Rolls nothing back by itself. |
| `-Rollback [-From <folder>]` | elevated; runs the saved undo lists last action first (newest backup unless `-From`). Re-opens #1678/#1686/#1692. |
| `-RestoreFrom <folder>` | elevated; puts back the saved access lists byte for byte (the only exact undo; the entry of a deleted account cannot be re-added any other way). |

What it changes, in order: (1) projects: remove the coder's explicit entries on every folder and file, then one
inheritable `(OI)(CI)RX` entry on the root; (2) `C:\blarai-fleet`: stop inheriting from `C:\` (Authenticated Users Modify,
Users read), remove the coder's Modify, keep SYSTEM/Administrators/the operator, give the coder READ on the root folder
itself; (3) Modify for the coder on `worktrees\` and `coder-leg\` only; (4) the worktree-root deny; (5) an entry for a
deleted account on the profile folder named in #1686; (6) each model folder: write entries of every account except the
operator, SYSTEM, Administrators removed and READ kept for the accounts that had it, inheritance off so the parent's
write grant cannot return. A model folder that does not exist is reported as SKIPPED, never silently ignored.

Refuses (before any change, for the whole stage): a relative path, a wildcard, `..`, a drive root, a system folder or the
profile root, a path that does not exist, a path that is a link or sits below one, the same SID for coder and operator.
Links INSIDE the trees are listed and never entered.

Measured while building it (temp trees, 2026-10-06), each a reason for a design choice:

- `icacls /T` follows a DIRECTORY SYMLINK inside the tree even with `/L`: files behind the link lost their explicit
  entries. A junction is not followed. The old provisioning grant used `/T`; the stage does not use `/T` anywhere. A tree
  operation is an own walk (`Invoke-NoFollowWalk`) that lists a link and never enters or touches it; the backup and the
  restore walk the same way. A control in the suite shows `icacls /T /L` still reaches through the symlink, so the
  link test could have failed.
- `icacls` cannot remove or add an entry for an account that no longer exists (exit 1332); those removals are done directly.
- An ELEVATED token bypasses explicit Delete / Delete-child denies on a folder it owns; a de-elevated token does not.
  The coder is a standard account. The self-test runs its stand-in coder de-elevated (a restricted standard-user token and a hidden process, `Invoke-HiddenProcess -DeElevate`; the earlier runas route opened visible console windows and is gone).

### Who commits: the operator funnel

With READ only, the coder cannot write the source repo's `.git` (the index, refs and objects of a linked worktree live
there), so `git add`/`git commit` by the coder fails; the operator funnel (`new-agent-task.ps1`/`Invoke-CandidateBuild`:
stage, secret scan, commit, merge) is the only committer. What changed, all on the restricted path only:

- `Invoke-FusedCoderRun` puts a RESTRICTED ACCOUNT NOTICE in front of the staged prompt (do not commit, do not write
  outside the working folder, the operator commits).
- `Get-CoderAgentsRulesText -Containment restricted_account` renders `configs/AGENTS.md` without the "git add -A / git commit"
  rule (the file itself is byte-identical; with `off` the rendering is the file). It is not yet read by a coder-owned
  opencode config (plan step 4 creates that config): until then the notice in the prompt is what tells the coder.
- `coder-leg-run.ps1` sets `GIT_OPTIONAL_LOCKS=0`, `GIT_TERMINAL_PROMPT=0`, `core.fsmonitor=false` and `safe.directory` for the
  one worktree in the runner's environment (`Get-CoderLegGitEnv`). `acp_coder.build_env` (BlarAI repo, #1694) passes the
  opencode child a fixed whitelist of variables and names these seven (`GIT_SAFETY_ENV_VARS`), so they reach opencode's
  shell. The two lists are kept by hand: a name added to `Get-CoderLegGitEnv` must be added there too, or every git
  command in the coder's shell fails (a key count without its key). Not verified on the real account.

Containment OFF is unchanged: `verify-coder-off-differential.ps1` compares the base commit with this tree over 25 manifest
shapes x 2 answers (50 runs): `Invoke-CoderDriver` traces, results, thrown messages, configs and worktree bases are identical;
the only function changed in `fleet-lib.ps1` is `Invoke-FusedCoderRun`; `configs/AGENTS.md`, `fleet-driver.json` and
`opencode.json` are byte-identical.

### Checks added to `verify-coder-containment.ps1` (5-14, hard-required, `-SkipNarrowing` is the only opt-out)

After provisioning the script creates a scratch repo under the projects folder (`.blarai-verify-*`, assets/README.txt,
one commit, a linked worktree under the worktree base: a `create_project(seed_assets=True)` analogue), runs the probe as
the coder, and removes the scratch folders. 5 no coder write entry anywhere in projects (operator-side scan); 6 the coder
cannot create a file in an existing sibling repo; 7 nor in the new repo; 8 nor `.git/refs/heads/x` or `.git/objects/xx`;
9 `git add`/`commit` in its worktree fails for a permission reason (with a git-status read control and HEAD unchanged);
10 it reads `assets/README.txt`; 11 it writes in its own worktree; 12 the new repo carries the INHERITED read entry; 13 the
operator funnel commits what the coder wrote; 14 the branch merges to main. A probe result that lacks a check fails it.

Self-test: `verify-coder-narrowing.ps1` (temp tree, the current user de-elevated as the stand-in coder; includes the toggle
test: restore the Modify grant and checks 5-9 fail; `-Mutations` for the mutation run). REAL-ACCOUNT-ONLY: the distinct
blarai-coder token, Windows resolving another account's inherited entries, the scheduled-task path, the real `C:\`/`B:\`
access lists, a real operator SID, Bitdefender, and checks 5-14 themselves.

### Review round 5 (X1-X6): what changed in the stage and what is still open

- **X1** The help text that credited an icacls flag with keeping links out of a tree walk is corrected; a scan over the help and documents fails on that claim (with a planted-sentence toggle).
- **X2** Every REMOVAL, backup read and restore write goes through ONE checked handle (grants, denies and inheritance changes are icacls calls by path made while a checked handle is held on the folder, see round 6 X6) (`Open-AclHandle`): the object is opened as itself (`FILE_FLAG_OPEN_REPARSE_POINT`, no `FILE_SHARE_DELETE`), the open handle is checked for "not a link, expected kind", its resolved path (`GetFinalPathNameByHandle`) must lie under the walk root, and the access list is read and written through that same handle (`GetSecurityInfo`/`SetSecurityInfo`). Hook-driven tests swap a folder for a junction after the listing (refused: the entry is a link), swap a PARENT folder for a junction (refused: resolves outside the tree), and move a folder out of the tree while its handle is open (refused: resolves outside); the restore skips an entry that became a link. In none of them was anything outside the tree modified. RESIDUAL, stated plainly: (1) the listing classifies by path, so a folder swapped between listing and open is caught at the open, not at the listing; (2) a handle opened with READ_CONTROL only did not hold its folder or its ancestors (measured: they could be renamed); the open now also requests READ_DATA with no share-delete, and then neither the object nor its ancestors can be renamed while the handle is held (measured), so the old microsecond window is closed by the OS, with a path re-check after icacls as a second layer (tested through a seam, because the real move is blocked); (3) an object swapped for another real object of the same kind INSIDE the tree is changed (harmless: in scope); (4) a hard link to a file outside the tree is not detected (a hard link shares the file's security descriptor); (5) the walk root itself is gated once by `Test-AclTargetSafe`.
- **X3** `-DryRun` prints a PLAN DIGEST; `-Apply` requires `-ExpectPlan <digest>`, plans again and refuses (with a printed diff against the stored plan text) if the digest differs. A tree changed between the two is refused and nothing is written, not even the backup. `provision-coder-account.ps1` shows the plan and stops (exit 3) unless it is given `-AclPlanDigest`.
- **X4** Targets are normalised before the forbidden-folder gate: trailing dots and spaces, `.` segments, 8.3 short names (`GetLongPathName`), case; `\?\`, `\.\`, UNC, a colon after the drive and reserved device names are refused. Tested with each variant against the system and profile folders.
- **X5** In a model folder each account's entries are put back ONE BY ONE with their own flags (a write entry cut down to its read bits; a separate read entry as it was), never one entry's flags on another. A read entry already covered by an `(OI)(CI)` read entry is left out, and the simulator merges this-folder + subfolders-only entries the way Windows does (measured), so the computed AFTER equals the real one.
- **X6** The rollback removes the operator Modify entry the stage added (fleet root and model folders) unless the operator already held an explicit entry there; the undo note says which.

## The coder's tool-chain setup (#775 plan step 4)

Files: `configs/coder-toolchain.json` (the manifest, the one place that names the operator-side folders the coder needs),
`scripts/coder-setup-lib.ps1` (pure helpers and the install/verify functions), `scripts/provision-coder-setup.ps1` (the
stage: dry run by default, `-Apply` and `-Rollback` elevated; also called by `provision-coder-account.ps1` step 7b and by its
`-Rollback`), probe checks in `scripts/coder-containment-probe.ps1`, checks 15-24 in `scripts/verify-coder-containment.ps1`,
the offline suite `scripts/verify-coder-setup.ps1` (`-Mutations` for the mutation run).

**Read grants (read-and-run, never write).** The opencode package folder and the fleet `tools` and offline docset folders
are inheritable; the folder that holds the opencode shim (the operator's npm folder) is granted THIS FOLDER ONLY, so the
coder can list the shim names and reads nothing else in the operator's npm tree. The coder gets `<shim folder>` on its PATH
for a dispatch job (`coder-leg-run.ps1`, appended so a machine-wide tool wins). Node, git, git-bash and python are
machine-wide installs: nothing is granted for them, check 18 runs each one as the coder. Each target is gated (exists, a real
folder, not a link, no link above it), and the entry is read back: a coder entry with any write right fails the stage. The
targeted undo removes the coder's entry (the no-follow walk for an inheritable grant, the single object for the shim folder).

**The coder-owned opencode configuration** is rendered from the repo (`configs/opencode.json` minus the `mcp` block, the
restricted rendering of `configs/AGENTS.md`, the two fleet plugins, an offline-docs tool wrapper, a pinned `package.json`)
into `<coder profile>\.config\opencode`; nothing is copied from the operator's profile and `Test-CoderOpencodeConfigSafe` is
the single verdict (no mcp, no plugin declaration, loopback providers only, no credential, every non-allow permission entry
of the operator config present with the same value). Protection: every file and the folders `.config`, `opencode`, `plugin`,
`tool` and `git` carry an explicit protected list (Administrators, SYSTEM, operator full; coder read-and-run) and are OWNED by
Administrators, so the coder cannot create, replace, rename or delete anything in them; `opencode\node_modules` is the one
folder the coder can write. `Test-CoderOpencodeConfigInstalled` (check 22) re-reads content, the file set, the lists and the
owners. A folder that lets the account delete a protected file fails check 20 (measured: file entries alone do not stop it).

**Research log.** The lookup tool writes its usage log where `BLARAI_RESEARCH_USAGE_LOG` says (default: the operator state
folder). The ACP client hands opencode a fixed environment, so the coder's tool wrapper sets the variable itself, to
`<coder profile>\.local\share\blarai-coder\research-usage.jsonl`. No grant on the operator state folder exists or is needed
(a failed log write never changes a lookup result). The file is in the coder's profile, not in `state\research-usage.jsonl`.

**Git trust.** Operator-side git on a coder-run worktree always uses the explicit `--git-dir`/`--work-tree` form
(`Get-WtGit` / `Get-HardenedGitArgs`); git does not ownership-check an explicit git dir (measured with a worktree owned by
SYSTEM, git 2.55), so no operator-side trust setting is needed and none is added; `verify-coder-setup.ps1` section H locks
that the plain `-C` form WOULD be refused. The coder side: the leg runner sets `safe.directory` for the one worktree
(`Get-CoderLegGitEnv`), and the coder's own `~/.config/git/config` carries `safe.directory = <worktree base>/*` (a prefix
entry, git 2.46+) for opencode's shell, which gets no git variables. Never `*`.

**Checks 15-24** (hard-required in both modes; a probe result that lacks one fails it): 15 the coder reaches the repair proxy
named by the opencode config on loopback; 16 it cannot read the operator opencode config, `.ssh` or `%LOCALAPPDATA%\BlarAI`;
17 `git status` runs in its worktree under the scoped trust, from the runner environment and from its own git config alone;
18 opencode, node, git, git-bash and python start (15 s wait each); 19 its config parses with no mcp block and the permission
block kept; 20 it cannot write, delete, rename or add to its config; 21 it writes its research log under its own profile;
22 the installed config equals the render and carries no coder write entry or coder ownership; 23 it cannot write in the
fleet root, the fleet scripts, the operator state folder or the BlarAI `shared` folder; 24 every folder of the installed
config (`~/.config`, `opencode`, `plugin`, `tool`, `git`) is still a real folder (no link) owned by Administrators. Together with the existing check 6/7
(sibling repo and new repo under the projects folder) these are the "cannot write outside its worktree" evidence.

**The config install holds a verified chain of handles; the rename of `~/.config` is detected, not prevented (#1713).** The
coder owns its profile root, so NTFS lets it rename the protected `~/.config` away through the parent's delete-child right
whatever the folder's own list says, and put a junction in its place at any time. What the install and the probe do about it:
(1) `Set-CoderSecurityByHandle` applies owner and a protected DACL with `SetSecurityInfo` to an open handle (`CreateFileW`
with `FILE_FLAG_OPEN_REPARSE_POINT` and `FILE_FLAG_BACKUP_SEMANTICS`; a reparse point is refused through
`GetFileInformationByHandleEx(FileAttributeTagInfo)`), so a swap after the open cannot redirect the stamp. The hazard this
removes is a link-FOLLOWING open or create; the link checks before and after the stamp stay and name the target.
(2) A handle on the final component does not say where its ancestors lead, so `Install-CoderOpencodeConfig` opens the
profile root and then every config folder, parents first, into one chain (`Add-CoderHeldDir`): each open refuses a link and
must resolve (`GetFinalPathNameByHandle`) to exactly the parent's resolved path plus the folder name; every handle is held
without sharing delete (the OS then refuses to rename or remove a held folder, and any folder that has a held child);
`Assert-CoderHeldChain` re-resolves every held handle before each create, each file write and the final stamping and
refuses when one moved. Each folder is stamped through its own held handle. A folder not yet opened can still be swapped;
its own open refuses it. Tests swap the ancestor `~/.config` before the run, between verification and the next create
(with the OS hold defeated by a test hook, to exercise the re-resolve check on its own), and a held folder right before a
file write, and assert the victim tree is byte-for-byte untouched (no entry, list, owner or inherited entry) and the run
throws. (3) Check 24 is a DETECTOR for what the install cannot hold: once the install has finished, nothing holds the
folders, so the coder can still rename `~/.config` away; the replacement it makes is owned by the coder, is a link, or is
missing, and the probe fails on any of those. It cannot be a prohibition, because the rename needs no right on the folder
itself. Until the next probe or `Test-CoderOpencodeConfigInstalled` run the replacement stands, and the operator-side apply
and undo refuse a link. RESIDUAL: the chain starts at the profile root, which is checked only to be a real folder resolving
to its own path (the folders above it are the operator's); the profile-root path itself must not contain a link or 8.3
short-name form (the install refuses rather than guessing); the hold-defeat hook (`$script:CoderHoldAllowsDelete`) exists
for tests only.

**Not verifiable offline** (needs the real coder token, and the LA-run dry run then a supervised apply): the coder really
reading and running the granted folders and the machine-wide tools; opencode's first start in the coder profile (it fills
`node_modules`, which needs the package registry or a seeded copy, and may want to write a file in the config folder root,
which the protection refuses by design); the real `:8099` proxy as the coder; the profile of `blarai-coder` existing at all
(created at the account's first logon, until then the config step is PENDING and provisioning exits 3).

## Removing the NginxGateway service and its boot items (#1695): LA-run

**Why.** `C:\nginx` and `nginx.exe` are writable by every signed-in account, the `NginxGateway` service runs that file as
LocalSystem at every boot, and two ENABLED boot tasks (`NginxGatewayWatchdog` as SYSTEM, `WslAgentBoot` as the operator,
elevated) read scripts from `C:\nginx\bin`. A contained coder could become SYSTEM. Nothing in BlarAI uses it (read-only
investigation: `blarai-research-data\ideation\nginx-gateway-removal-readonly-20261008.md`). The LA ruled 2026-10-08: remove
the service. The script below also covers the tasks, the firewall rules and the folder, and decides none of them for you.

**What it can touch** (an exact list compiled into `scripts\remove-nginx-gateway.ps1`, never a pattern; a name that is not on
it is refused again right before every action): the service `NginxGateway`; twelve tasks in the root task folder
(`NginxGatewayWatchdog`, `WslAgentBoot`, `NginxGateway`, `nginx-background`, `NginxAtBoot`, `NginxReload`, `NginxReloadNow`,
`NginxReopenLogsNow`, `NginxQuitNow`, `NginxLogRotateWeekly`, `GatewayNginxMonthlyBackup`, `GatewayNginxPruneMonthly`);
three inbound firewall rules (`nginx.exe HTTPS (App)`, `nginx HTTPS 443 (Port)`, `TEMP-Allow-HTTPS`); the folder `C:\nginx`.

**Step 1: look first (changes nothing, writes no file, needs no elevation).** From the agentic-setup folder:

    pwsh -File scripts\remove-nginx-gateway.ps1

It prints the service, each of the twelve tasks (enabled or not, who runs it, what it runs), each firewall rule, the folder
(file and folder counts, size, the NAMES of the private-key files and how many, `.pem` count, any links inside, which are
listed and never entered), where the folder would go, and whether the preconditions hold. Exit 0 = it would run; exit 2 = it
would refuse, with the reason.

**Step 2: the three decisions (yours; the script's default is all of them).**
1. Remove the twelve scheduled tasks? Removing only the service leaves the two enabled boot tasks running scripts from the
   writable folder. (`-Scope` without `Tasks` keeps them. The script refuses to move the folder while a task or the service
   that points into it remains: any user could re-create `C:\nginx` and the entry would run it.)
2. Remove the three firewall rules? They allow inbound 443 and nothing listens there, so they are inert holes.
   (`-Scope` without `FirewallRules` keeps them.)
3. What happens to the folder (251 files in 66 folders plus 3 links: 7 private-key files, a 145 MB git bundle of an old project, scripts whose
   contents nobody has read)? Default: KEPT, locked to SYSTEM and Administrators, in `C:\ProgramData\nginx-quarantine\nginx`.
   Add `-DeleteQuarantine` to delete it permanently in the same run (the `nginx.conf` copy stays either way).

**Step 3: run it** from an elevated PowerShell (Run as administrator), in `agentic-setup`:

    pwsh -File scripts\remove-nginx-gateway.ps1 -Execute
    pwsh -File scripts\remove-nginx-gateway.ps1 -Execute -DeleteQuarantine       # also delete the quarantined copy for good
    pwsh -File scripts\remove-nginx-gateway.ps1 -Execute -Scope Service,Tasks     # narrower: keep rules and folder

Every rule carrying one of the three named display names is removed (by design; the names are the allowlist).

Order: precondition check (nothing is changed if any fails) -> copy `nginx.conf` (never overwrites; a different existing copy
gets a timestamped name) -> take ownership of every object and lock the folder to SYSTEM + Administrators, verified object by
object -> stop and delete the service -> unregister the tasks -> remove the rules -> move the folder into the admin-only
quarantine and verify -> (only with `-DeleteQuarantine`) delete it. The delete never follows a link: a junction or symlink
inside is removed as the link itself and its target is left alone (tested with a junction, a folder symlink and a file symlink);
read-only entries (files, folders, links) are cleared first. A link given as the delete ROOT is refused, and the quarantine root
and the copy are re-proved admin-only (not a link, not re-opened) immediately before the delete or it stops with exit 3. Every step is logged to
`blarai-research-data\ideation\nginx-removal-<time>.log` and checks its own result; the first failure stops the run (exit 3).
It refuses while an nginx process runs or anything listens on 443 or 8081. It never kills a process. A re-run after a partial
run continues: finished steps print `already done`. After a service delete, a reboot clears a "marked for deletion" state.

**Step 4: prove it.** Re-run `scripts\verify-coder-containment.ps1` as usual; check 25 (below) must report 0 offenders.

**Check 25 (`verify-coder-containment.ps1`, hard-required in both modes, an absent result fails it).**
`scripts\coder-boot-surface-lib.ps1` (loaded only there; the containment=off path never names it) lists every Automatic or
Delayed-start service running as LocalSystem, LocalService or NetworkService, and every enabled task running as SYSTEM, a
service account, the Administrators group or one of its members (or a principal it cannot resolve), whose executable, script
named in the arguments (`-File x`, `"x.ps1"`), folder or any ancestor folder can be written by Everyone, Authenticated Users,
Users, Guests, Power Users, Interactive, Batch, Network, the coder or a group it belongs to, or is owned by one of them. An
unquoted service path with spaces is checked at every earlier name Windows would try. An entry flagged inherit-only does not
count against the folder that carries it. A list that cannot be read, a path that cannot be resolved, a sweep that saw no
services or no tasks, and any sweep error (for example the Administrators membership could not be read) all FAIL.
Also judged: the working folder of a task whose program is an interpreter or whose arguments name a relative script or a file
that exists there; the arguments of a service image path and of a task (the command word after `/c`, whatever its extension;
redirect targets and folders are data, not code); a named service account that is an Administrators member (or cannot be
resolved); and a program whose file AND folder no longer exist, judged on the nearest folder that does, because anyone who may
create that folder decides what runs.
A program's OWN folder is judged with the add-subdirectory right included (a `<program>.local` folder beside it redirects its
DLL loads); folders ABOVE it are judged without it, so the default add-subdirectory right on `C:\` is not a finding unless the
program lives directly in `C:\`.
Not covered (stated): the working folder of a plain, non-interpreter program whose arguments name nothing relative (judging every
exe there flags only the Firefox Background Update task: an admin-member account, `firefox.exe` in Program Files, working folder
`ProgramData\Mozilla-*\updates\<id>` where Users have full control; Firefox removes the working folder from its DLL search, so
check 25 does not certify that case); DLLs a binary loads from elsewhere; who may re-configure a service (its control DACL and registry key);
Manual-start services, drivers, Run keys; COM-handler task actions; a Deny entry is ignored (this can only over-report).
Read-only run on this machine before the removal (2026-10-08): 6 findings, all `NginxGateway`, `NginxGatewayWatchdog` and
`WslAgentBoot` under `C:\nginx`; no other service or task.

**Not verifiable offline:** that Windows accepts the real `sc.exe delete`, `Unregister-ScheduledTask` and
`Remove-NetFirewallRule` calls on the real objects, `takeown.exe` on files whose access list nobody can read (e.g.
`gateway-watchdog.ps1`), and the move of a folder that holds symlinks under `C:\nginx\conf\sites-enabled` (three are listed
by the dry run; they move with the folder and are never followed). The offline suite `verify-nginx-removal.ps1` runs the
script's real code against fakes for the system calls and a real temp tree (real junction, real `takeown.exe`, real access
lists); `-Mutations` shows each control being turned off. The first `-Execute` is the first run against the real objects.
