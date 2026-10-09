# Independent pre-merge review: the ACL provisioning stage (#1678, #1686, #1692)

Branch `feat/1678-narrow-projects-provisioning` @ `06c56d6` (agentic-setup), base main `3097116`. Reviewer: an
independent session that did not write the code. Approved by the LA as a defensive review (#1678 c.3907). Run
2026-10-06 03:31-04:05 (-04:00), elevated, on this machine (Windows 11, pwsh 7.6.3 MSI at the top level, children
through PATH pwsh 7.6.6; Windows PowerShell 5.1.26100). Nothing below was fixed by the reviewer.

**Safety boundary kept.** Every run of the builder's scripts used throwaway trees under `%TEMP%\rv1678-*` (all
removed afterwards). The real `C:\Users\mrbla\projects`, `C:\blarai-fleet`, `B:\models`, `C:\models`,
`C:\Users\mrbla\BlarAI` were only READ (icacls/Get-Acl/enumeration, no builder code). No account, group, firewall
rule, scheduled task or service was created or changed; no git worktree created. Every child ran hidden; at the end
`Get-Process | ? MainWindowHandle -ne 0` showed only the LA's Windows Terminal (started 2026-10-04).

**Fixture fidelity.** The main fixture copies the real access lists read today: a parent with the DACL of `C:\` (minus one AppContainer read entry)
(holding the fleet folder with explicit operator + coder Modify), one with the exact DACL of `B:\` (holding
`models`), one with the profile DACL (holding `projects` with the coder `(OI)(CI)M` entry and `BlarAI` with the
orphan `(RX,W)` entry). The coder stand-in SID is Guests (S-1-5-32-546); the operator is the real user SID.

## Findings

| # | Severity | Where | What |
|---|---|---|---|
| X1 | should-fix | coder-acl-lib.ps1:456-472, 848-868, 1297-1302; verify-coder-containment.ps1:193 | The "no write access left for the coder" read-back and check 5 look only for entries naming the coder SID; write granted through a group (Users, Authenticated Users, Everyone, BATCH) or through owning the object is invisible |
| X2 | should-fix (blocks closing #1692, not the merge) | provision-coder-acls.ps1:53; coder-acl-lib.ps1:578 | `C:\models` (the folder the coder's own model server loads `coder-30b` and `ov_cache` from) is writable by Authenticated Users and is not a model root of the stage |
| X3 | should-fix | coder-acl-lib.ps1:1124-1130; provision-coder-acls.ps1:86 | `-Rollback` picks the newest backup; after a second `-Apply` that backup's undo list no longer contains the model-folder and orphan actions, and the rollback reports success without undoing them |
| X4 | should-fix (on main before this branch; line touched here) | verify-coder-containment.ps1:177-184 | `-Credential` mode passes each list as ONE literal string through `-File`: check 2 then passes with nothing read (fail-open); checks 5-14 can never pass |
| X5 | should-fix | hidden-process-lib.ps1:124-146 | The no-window lint misses 12 of 13 ordinary visible-launch idioms |
| X6 | note (prose overclaim, low reach) | coder-acl-lib.ps1:825-828; fused-leg-operator-uses.md:282 | "Every change goes through ONE checked handle" is true for removals, backup and restore only; grants, denies and inheritance changes are `icacls` by path, and one of them followed a directory symlink planted after the gate |
| X7 | note | coder-acl-lib.ps1:490-494, 537; help text provision-coder-acls.ps1:27-29; fused-leg-operator-uses.md:227 | The forbidden-folder gate is exact-match: a folder BELOW `C:\Windows`, `C:\Program Files` or the profile root passes |
| X8 | note (stale prose) | docs/fused-leg-operator-uses.md:240 | Says the self-test de-elevates with `runas /trustlevel:0x20000`; D13/N6 replaced that (it opened the visible windows) |
| X9 | note | coder-acl-lib.ps1:824, provision-coder-acls.ps1:90-94 | A failure part-way through `-Apply` ends in a raw exception with no "restore with -RestoreFrom <dir>" line |
| X10 | note | coder-acl-lib.ps1:181-184 | The simulator does not model an added Modify being absorbed by an existing explicit Full control with the same flags: a false MISMATCH (exit 1) after the change was made |
| X11 | note | provision-coder-acls.ps1:96; coder-acl-lib.ps1:815-818 | The inheritance-off report is depth 1 only (12 protected `.pytest_cache` folders at depth 2 in the real projects are not listed); the dry run prints `icacls /remove:g` for removals that are done through the handle instead |
| X12 | note | coder-acl-lib.ps1:275 | Under pwsh 7 the walk cannot open a path of about 250 characters or more (win32 error 3); the stage then stops part-way (fail-closed). Works under 5.1 |
| O1 | out of scope, LA-relevant before the flip | machine | Service `NginxGateway` (LocalSystem, Auto start) runs `C:\nginx\nginx.exe`, which Authenticated Users can modify: any local account, a contained coder included, can become SYSTEM at the next start |

### X1 - the read-back proves "no coder-SID entry", not "the coder cannot write"

Cost when it fires: `-Apply` prints `APPLY COMPLETE ... the read-back found no remaining write access` and exits 0
while the coder can still write repos (and their `.git`) under projects; check 5 of the real verify passes the same way.
Checks 6-8 of the real verify probe real writes, but only in one sibling repo and the new scratch repo.

Reproduced (fixture, real entry point `provision-coder-acls.ps1 -DryRun` then `-Apply -ExpectPlan`): explicit
`Users:(OI)(CI)M` on `repoB` and `Authenticated Users:(OI)(CI)M` on `repoA`, then the stage:

```
dry run mentions Users/AuthUsers on repos: False
apply exit=0
=== APPLY COMPLETE: every changed folder matches its printed AFTER, and the read-back found no remaining write access ===
...\projects\repoB\.git\refs\heads BUILTIN\Users:(I)(OI)(CI)(M)  BUILTIN\Guests:(I)(OI)(CI)(RX) ...
...\projects\repoA\.git\objects     NT AUTHORITY\Authenticated Users:(I)(OI)(CI)(M) ...
```

The same blindness covers ownership: an object the coder owns keeps the owner's implicit right to change its own
access list. Incidence on the real machine today (read-only scan, 6,214 objects under projects): 0 group write
entries, 0 objects owned by blarai-coder, 0 links. Zero incidence is why this is not blocking; the predicate is still
narrower than the question the output answers.

### X2 - `C:\models` is outside #1692's protection

`scripts/start-llm.ps1:69` serves `coder-30b` from `C:\models\coder-30b` (and `:100` lists `C:\models\qwen3-14b` first
for the 14B). Read-only, today:

```
C:\models BUILTIN\Administrators:(I)(OI)(CI)(F)  NT AUTHORITY\SYSTEM:(I)(OI)(CI)(F)  BUILTIN\Users:(I)(OI)(CI)(RX)
          NT AUTHORITY\Authenticated Users:(I)(M)  NT AUTHORITY\Authenticated Users:(I)(OI)(CI)(IO)(M)
children: coder-30b, openvino_ir_test, ov_cache
```

#1692 says "read the ACLs of every model root (B:\models, C:\Users\mrbla\BlarAI\models, any other drive/location the
runtime or evals load from)". The stage's default model roots are the first two only. Once containment is on, the
coder account (a member of Authenticated Users) can rewrite the weights, tokenizer or chat template of the model it
talks to over loopback, and the compiled-model cache. Not a hazard of running `-Apply`; a gap in what the plan claims to
close.

### X3 - `-Rollback` after a second `-Apply` is partial and says it succeeded

Reproduced (fixture): Apply, Apply again (the idempotence run), then `-Rollback` with no `-From`:

```
backup 20261006-034626: plan.json actions = projects-narrow, fleet-root, fleet-worktrees, fleet-coder-leg, worktree-root-deny, orphan-blarai, models-...-B-models
backup 20261006-034633: plan.json actions = projects-narrow, fleet-root, fleet-worktrees, fleet-coder-leg, worktree-root-deny
rollback exit=0
rolling back from ...\acl-backup\20261006-034633
B\models back to its original access list: False
```

The second backup is an earlier-goal neighbour: same shape, planned from the already-narrowed state, so the model and
orphan undos are absent and the fleet-root undo keeps the operator entry (the operator "already had" it, because the
first run added it). The help text says "Re-opens #1678, #1686 and #1692"; after a re-run it does not re-open #1692.
`-RestoreFrom <first backup>` is exact (below).

### X4 - `-Credential` mode: check 2 passes on a mangled path list

`$secretArg = ($SecretPaths | % { "'$_'" }) -join ','` is appended to a `-File` command line, where PowerShell does not
evaluate it: the probe receives one parameter value `'a','b'`. Reproduced with the exact line-building code, run as the
current user (hidden), two readable "secret" files:

```
check2 secret_reads_denied pass=True  per_path={"'C:\\...\\s1.txt','C:\\...\\s2.txt'":"absent (nothing to read)"}
read_files_ok pass=False
control: the same two secret files are readable by this token: True
```

The default `SecretPaths` list has several entries, so check 2 in this mode certifies nothing. The new narrowing lists
take the same route and fail (closed), so this mode can never pass checks 5-14. The decisions record lists the mode as
"not verified", which is honest; the fail-open in check 2 is not listed. The scheduled-task mode (the default path)
passes real arrays through the job JSON and is not affected.

### X5 - the visible-launch lint is narrower than D14 says

`Find-VisibleLaunches` on one-line samples (pwsh 7):

```
control: Start-Process visible  flagged=True     control: & pwsh          flagged=True
alias start                     flagged=False    alias saps               flagged=False
bare cmd /c                     flagged=False    bare pwsh -File          flagged=False
bare python                     flagged=False    & 'cmd.exe' (quoted)     flagged=False
& "C:\...\pwsh.exe" (quoted)    flagged=False    [Diagnostics.Process]::Start("pwsh.exe", ...)  flagged=False
Invoke-CimMethod Win32_Process Create  flagged=False   & $exe          flagged=False
Invoke-Item .\run.cmd           flagged=False    Start-Process pwsh # -WindowStyle Hidden (comment)  flagged=False
-WindowStyle:Hidden (legitimate) flagged=True
```

Quoted strings are blanked before matching, so every quoted call-operator path passes; bare-word invocation, the
most common PowerShell idiom, is not looked for. Incidence in the branch's files today: 0 (searched). The lint's toggle
test plants the two shapes it already catches. The run-end window check is the real control; the lint is not the
guarantee the decisions record describes.

### X6 - additions are by path, not through the checked handle

Reproduced with the action's own output callback as the hook (between `Test-AclTargetSafe` and the `icacls` call):

```
> icacls ...\fleet\worktrees /grant:r *S-1-5-32-546:(OI)(CI)(M)
  [hook] worktrees swapped for a SYMLINK to outside\secret after the gate, before icacls
action returned (no refusal)
...\outside\secret          BUILTIN\Guests:(OI)(CI)(M)
...\outside\secret\keep.txt BUILTIN\Guests:(I)(M)
```

With a junction instead, icacls did not follow. Reach is low on this machine: a directory symlink needs an elevated
actor (Developer Mode is off, `AllowDevelopmentWithoutDevLicense=0`), and by the time the worktree grant runs the
fleet-root action has already removed every other account's write on `C:\blarai-fleet`. The finding is the prose:
"Every change ... goes through ONE checked handle" (fused-leg-operator-uses.md:282, decisions X2) covers the removing
direction only; the granting direction - the dangerous one - is not covered by the hook tests.

### X7 - the forbidden-folder gate refuses six folders, not "a system folder"

Reproduced with `USERPROFILE` pointed at a temp stand-in (the list includes the profile root): the root is refused in
every spelling (`\prof`, `\prof\`, `\prof.`, `\PROF`); `\prof\AppData`, `\prof\AppData\Roaming`, `\prof\projects` pass.
By the same rule `C:\Windows\System32` or `C:\Program Files\X` would pass. Only a mistaken parameter reaches this (the
defaults are fixed), but a model-root mistake would be serious: every SID outside the keep set is a "foreign writer",
TrustedInstaller included. The decisions record states "the same six folders"; the help text and operator doc say "a
system folder".

### X8 - stale de-elevation sentence

`docs/fused-leg-operator-uses.md:240`: "The self-test runs its stand-in coder de-elevated (`runas /trustlevel:0x20000`)."
The code uses `CreateRestrictedToken` + `CreateProcessAsUser` (hidden-process-lib.ps1:59-80); `runas /trustlevel` was
removed because it opened the windows. The X1 stale-claim scan does not look for this sentence.

### X9 - mid-apply failure message

Reproduced in-process with the stage's output hook: a coder-leg result file held open exclusively once the fleet-root
action starts.

```
STAGE THREW: the tree walk under '...\C\fleet' had 1 error(s); first: ...\job-1.result.json : refusing ...: cannot open (win32 error 32)
objects changed before the failure: 25
fleet root now: SYSTEM (F), Administrators (F), operator (M)       <- coder has no access: fail-safe
rollback Ok=True; after rollback 6 objects differ from the original (inherited-vs-explicit, by design)
restore Ok=True; after restore, objects differing from original: 0
```

The state is recoverable and fail-safe; the LA sees a red exception and the backup folder only in the earlier
"APPLY: backing up to" line. The help-text promise "Exits non-zero ... Rolls nothing back" holds.

### X10 - simulator gap: added Modify absorbed by an existing Full control

On the first fixture (under `%TEMP%`, whose parent grants the operator F), the brain-model and fleet actions reported
`MISMATCH ... expected but absent: Allow|<operator>|M|(OI)(CI)` after the change: `/inheritance:d` turned the inherited
operator F into an explicit F and the added M was merged into it. On the real machine the brain-model folder inherits
the operator's F from the profile, so this would fire the day that folder has a foreign writer; today it has none (the
orphan is excluded), so incidence 0. Fails loud, after changing.

### X11, X12

Real projects (read-only): 12 `.pytest_cache` folders at depth 2 with inheritance off (SYSTEM, Administrators,
OWNER RIGHTS F, the coder `(OI)(CI)M`); none owned by the coder. `Find-ProtectedChildren -Depth 1` does not list them.
Long paths: a 302-character tree under pwsh 7.6.3 and 7.6.6 -> `walk visited=11 changed=11 errors=1 ... cannot open
(win32 error 3)`; under 5.1 `visited=14 changed=13 errors=0`. Longest path in the real projects today: 124
characters.

### O1 - not this branch, but true of the machine the flip contains

```
Get-CimInstance Win32_Service: NginxGateway  LocalSystem  Stopped  C:\nginx\nginx.exe -p C:\nginx -c conf\nginx.conf  (StartMode Auto)
C:\nginx\nginx.exe  BUILTIN\Users:(I)(RX)  NT AUTHORITY\Authenticated Users:(I)(M)
```

23 top-level folders of `C:\` give a broad group (Authenticated Users/Users/Everyone) a write right (e.g. `C:\nssm`,
`C:\svc`, `C:\certs`, `C:\models`).
Any account, the contained coder included, can replace a binary that a SYSTEM service starts at boot.

## Verified clean (ran it, could not break it)

- **Propagation does not follow links.** `icacls <root> /grant ...(OI)(CI)` without `/T`, and a `SetSecurityInfo`
  through `Invoke-AclHandleEdit`, on a tree holding a directory symlink, a junction and a file symlink to outside
  folders: nothing outside gained an entry (8 outside objects checked per variant).
- **Dry run and default.** SDDL snapshot hash of every fixture object identical before, after `-DryRun`, after no switch
  (`72F239E971779D51` x3); same digest from both.
- **Dry run prints what Apply runs.** The commands listed under "COMMANDS THAT WILL RUN" equal the applied `>` lines, same
  order (the only extra lines are the UNDO listings).
- **Plan binding.** Root-level drift after the dry run: `REFUSED ... digest c23619c0c3e973cc, you passed 8a038334403c258c`,
  diff printed, 0 objects changed, no new backup folder. Digest identical elevated vs de-elevated (`ef65459e87ed88f2`) and
  pwsh 7 vs 5.1 (`ca8816eef6f191fd`). Drift INSIDE the tree (a new explicit coder entry) does not change the digest, as
  the decisions record says; the walk removed it anyway.
- **Real-shape apply.** On the fixture with the real `C:\`/`B:\`/profile access lists: `APPLY COMPLETE`, exit 0, in pwsh 7
  and in 5.1; the B:\models shape (generic-right split entries) produced no mismatch.
- **Idempotence.** Second dry run + apply: exit 0, no SDDL differs from the first apply.
- **Backup/restore.** `-RestoreFrom` after apply, after a mid-apply failure, and after a rollback: 0 objects differ from
  the original in each case (pwsh 7 and 5.1).
- **Fail-closed before change.** A file held exclusively before `-Apply`: the backup walk refuses, 0 objects changed.
- **Hidden launcher arguments.** 13 arguments (spaces, quotes, trailing backslashes, `& | ; $x backtick`, newline, empty,
  `%PATH%`, `^`, a 20,000-character argument) round-tripped exactly through `Invoke-HiddenProcess`, plain and `-DeElevate`
  (Python argv as the receiver). No secret appears on any command line the branch builds.
- **Containment-off differential** vs `3097116` with 5 added shapes (padded `" off "`, `containment` as an array, `"OFF"`,
  a decoy `containment` nested under `acp`, trailing garbage): `60 runs (30 manifest shapes x 2 ...) produce IDENTICAL`;
  structural: only `Invoke-FusedCoderRun` changed in fleet-lib.ps1; AGENTS.md, fleet-driver.json, opencode.json
  byte-identical.
- **Mutants.** Seeded sample, `Get-Random -Count 25 -SetSeed 20261006` over the 83 named mutants (harness probes excluded):
  `MUTATIONS: 25 killed, 0 survived, 0 error, of 25`.
- **Checks 5-14 can fail.** Each verdict input false fails exactly its check; the toggle (Modify restored) fails 5-9; a
  probe result missing the narrowing keys fails. In the real verify an unregistered task, a non-start, or no result
  throws (exit non-zero).
- **Walk size.** 1.2 ms/object (10,241 objects, depth 2) to 2.2 ms/object (5,110, depth 8); the real projects folder has
  6,214 objects, so the projects walk is seconds, not hours.

## Suites run (reviewer, at `06c56d6`, elevated, one at a time)

narrowing 288/0 (154 s); off-differential 12/0; provisioning 49/0 under pwsh 7 and 49/0 under 5.1; fused-seam 993/0;
leg-wiring 14/0 under pwsh 7 and 14/0 under 5.1; fleet-driver 37/0. All match the builder's figures.

## What I could NOT verify

The real blarai-coder token (checks 5-14 live, the scheduled-task path); the real fleet funnel (`new-agent-task.ps1`)
committing what a read-only coder leaves; opencode under a read-only projects folder; `-Credential` with a real
credential; a hostile real-time racer (only hooks); the apply time on the real BlarAI tree (the orphan removal
propagates over the whole repo, size not measured); Bitdefender interaction.

## On the decisions record's verified / real-account-only split

Mostly honest: every real-account item it lists is real-account-only, and it states its own residuals (ancestor rename,
hard links, digest scope, six-folder list). It over-states in three places: X2/X6 (the handle covers removals only), X5
"the way Windows does" (it is the merged view .NET reports; icacls shows the two raw entries unmerged), and the
"-Credential mode not verified" line, which omits that check 2 fails open there (X4).

## Merge read

MERGE-READY with containment off. Nothing found changes behaviour with containment off (differential), and nothing
found makes running `-Apply` on today's machine do harm: the X1/X6/X11/X12 shapes have zero incidence on the real
folders read today, and every failure observed was fail-closed or fail-loud. Not ready to close #1692 (X2). X3 and X4
need either a fix or an operator instruction before they are used.

## Must be true before the LA runs `-Apply` for real

1. No dispatch in flight: pause the fleet; the stage checks only the coder-leg task state, and with containment off a
   dispatch runs as the operator in the same folders.
2. Nothing holds a file open under `projects`, `C:\blarai-fleet` or the model folders (editors, test runs): the stage
   refuses or stops part-way.
3. `-DryRun` and `-Apply -ExpectPlan` back to back; the LA reads the plan, including the model-folder actions.
4. A decision on `C:\models` (X2): add it as a model root, or record that #1692 stays open for it.
5. Keep the FIRST backup folder's path. To undo, use `-RestoreFrom <that folder>` (exact) or `-Rollback -From <that
   folder>`; never a bare `-Rollback` after a second `-Apply` (X3).
6. Afterwards, `verify-coder-containment.ps1 -AcceptedEgressGap` in scheduled-task mode, never `-Credential` mode (X4).
7. Separately from this stage, before the containment flip: O1 (a SYSTEM service binary writable by every account).

---

## Round 2 - re-verification at `acd4c3b` (2026-10-06 06:55-07:41 -04:00)

Same boundary and conditions as round 1 (temp trees only, the real-shape fixture, the Guests SID as the coder for
ACL operations, the current user de-elevated where a token matters; all `%TEMP%\rv1678-*` removed; afterwards
`Get-Process | ? MainWindowHandle -ne 0` showed only the LA's Windows Terminal from 2026-10-04). Each round-1
reproduction was re-run unchanged against the new HEAD.

### Each fix, re-reproduced

| # | Result at acd4c3b | Evidence |
|---|---|---|
| X1 | FIXED for the groups it lists; residual R2-1 | Users / Authenticated Users Modify on two repos: `apply exit=1`, `FINDING: the coder can still write through a group entry ... S-1-5-11` (round 1: exit 0, APPLY COMPLETE) |
| X2 | FIXED | `C:\models` is in the defaults of the script, the plan and the stage. On a `C:\models` analogue under the real `C:\` DACL: `apply Ok=True mismatches=0 findings=0`; after: Authenticated Users `(RX)` + `(OI)(CI)(IO)(RX)`, Users `(OI)(CI)(RX)`, operator `(OI)(CI)(M)`; a weights file inherits Users/AU read and operator Modify. The model server runs as the operator (start-llm launches it; no service), so it keeps read and write |
| X3 | FIXED | Apply, Apply, bare `-Rollback`: `rollback exit=1` (refused); B\models untouched |
| X4 | FIXED | the `-ParamsFile` route, run as a de-elevated child: two readable files -> check 2 `pass=False`; zero existing paths -> `pass=False` ("read ZERO existing secret paths"); one denied + one absent -> `pass=True`; every list arrives as an array (2 keys per list) |
| X5 | FIXED for all 14 round-1 shapes; residual R2-4 | all 14 flagged; 10 legitimate lines (Hidden, NoNewWindow, `-WindowStyle:Hidden`, Invoke-HiddenProcess, `& git`, `& icacls`, comments, strings, `$start` variables) pass |
| X6 | FIXED | the same hook (directory symlink swapped in after the gate, before the grant): `action threw: refusing ...worktrees: the entry is a link`, nothing outside changed. Held handle, 5 of 5 tries: renaming the folder itself and its ancestor from another process is blocked |
| X7 | FIXED | refused: `C:\Windows\System32`, `C:\windows\system32\drivers`, `C:\PROGRA~1\X`, `C:\ProgramData\Microsoft`, `C:\Users\Public`, `C:\Users\Default\x`, profile `AppData\Roaming\x`, `.ssh`, `AppData\LocalLow\x`; the round-1 temp stand-in now refuses `\prof\AppData` and `\prof\AppData\Roaming`. Allowed: projects, BlarAI\models, `C:\models`, `B:\models`, the fleet folder, `%LOCALAPPDATA%\Temp\*` (carve-out, R2-5) |
| X8 | FIXED | doc line 240 now names the restricted-token launch |
| X9 | FIXED | planted open failure in the fleet walk: `APPLY FAILED PART-WAY at ...`, `The original access lists are saved in: ...\run1`, `Put everything back exactly with: provision-coder-acls.ps1 -RestoreFrom "...\run1"`; restore: 0 objects differ from the original |
| X10 | FIXED | foreign writer on a model folder whose operator inherits Full control: `APPLY COMPLETE`, no MISMATCH (round 1: MISMATCH) |
| X11 | FIXED when elevated; residual R2-2 | a protected folder at depth 3 is listed; removal lines now say "done directly through a checked handle" |
| X12 | FIXED | a 302-character tree under projects: `walked 33 objects, ... errors: 0` (round 1: error 3) |
| Checklist | present | `OPERATOR CHECKLIST (before -Apply)`, five items, printed by the dry run and at the start of every apply |

### New findings (introduced or exposed by the fixes)

| # | Severity | Where | What |
|---|---|---|---|
| R2-1 | should-fix | coder-acl-lib.ps1 `Get-CoderGroupSids` | The group list is a hand list. `NT AUTHORITY\Local account` (S-1-5-113) and `This Organization` (S-1-5-15) are in every local account's token (this machine's `whoami /groups` shows both) and are not on it. Modify for either on a repo: `apply exit=0`, `APPLY COMPLETE ... no remaining write access` (reproduced for both). Incidence today: 0 (read-only scan of the real projects for S-1-5-113, S-1-5-15, S-1-5-64-10, S-1-2-1). The group lookup also swallows every error (`catch { }`) and silently falls back to the hand list (no error today: 23 groups read, coder in Users only). |
| R2-2 | should-fix | coder-acl-lib.ps1, dry-run sections `WARNING - WRITE ACCESS ...` and `FOLDERS WITH INHERITANCE SWITCHED OFF` | Both new sections ignore walk errors. The dry run is documented as needing no elevation; run de-elevated over a folder only Administrators can read that carries a coder-group (BATCH) write entry, it prints no warning and no inheritance-off line (`warn: (none)`, `prot: (none)`; the only trace is `unreadable: 1` in the size line), while the elevated run prints both. The digest is identical (`4b9c2544c258aec8` both), so the LA approves a plan without the warning and `-Apply` then ends `exit=1` with the finding, after changing. Real incidence: 4 `.pytest_cache` folders under projects are owned by Administrators with no operator entry; a non-elevated dry run would leave them out of the inheritance-off list (no group write on them). |
| R2-3 | note | verify-coder-containment.ps1:182-184 | The `-Credential` params file is written into the coder-leg results folder (the coder can modify it) and is never deleted. The probe runs as the coder, so a coder process could already falsify its own result; the leftover `verify-*.params.json` files are the new part. |
| R2-4 | note | hidden-process-lib.ps1 `Find-VisibleLaunches` | Still missed: `& (Get-Command pwsh).Source`, `& $PSHOME\pwsh.exe`, `& $env:ComSpec /c`, `.\build.cmd`, `python3.12 x.py`, `[Process]::new()` + `.Start()`, `-WindowStyle Hiddenx`. The disposition names "launches built from variables" as the residual; a bare `.cmd` and a versioned interpreter are not variables. Incidence in the branch: 0. |
| R2-5 | note | coder-acl-lib.ps1 `Get-AclForbiddenRules` | The production gate carries a carve-out for `%LOCALAPPDATA%\Temp` (for test trees); system folders are matched on `C:` only. |

Observed, not a stage defect: in 4 runs a file opened by another program with `FileAccess.Read, FileShare.None` did
NOT stop the stage's open (the walk went on with 0 errors); with `ReadWrite, None` it was refused (error 32). Checklist
item 2 ("the stage stops on a file held exclusively") describes some locks, not all; harmless either way.

### Suites and samples at acd4c3b (reviewer, elevated, one at a time)

narrowing 391/0; off-differential 12/0; provisioning 49/0 (pwsh 7) and 49/0 (5.1); fused-seam 993/0; leg-wiring
14/0 (pwsh 7) and 14/0 (5.1); fleet-driver 37/0. Off-differential with my 5 extra shapes vs `3097116`: 60 runs (30
shapes x 2) identical, 12/0. Mutants: `Get-Random -Count 25 -SetSeed 20261006` over the new population of 109 (7 of
the 25 are round-6 mutants, e.g. `icacls-handle-not-held`, `secret-zero-read-passes`, `probe-paramsfile-ignored`,
`model-roots-without-c-models`): `MUTATIONS: 25 killed, 0 survived, 0 error, of 25`.

### Round 2 merge read

MERGE-READY with containment off. Every round-1 finding reproduces as fixed; containment-off behaviour is unchanged.
R2-1 and R2-2 have zero (R2-1) or harmless (R2-2, inheritance-off list only) incidence on today's folders and fail loud
at `-Apply`, but only after the change. Fix them before the stage is trusted as a general instrument: R2-1 by
computing access from the coder's real token groups (or an access check), R2-2 by failing or warning loudly when a
dry-run section could not read something, or by requiring the dry run to be elevated.

### Before the LA runs `-Apply` (revised)

1. Run the dry run ELEVATED, in the same elevated window as `-Apply` (R2-2); check the size line says `unreadable: 0`.
2. Pause the fleet (no dispatch), stop the model server reading `C:\models`, close editors and test runs under
   projects, the fleet folder and the model folders.
3. `-DryRun`, read it (the model-folder actions including `C:\models`, and any WARNING block), then
   `-Apply -ExpectPlan <digest>` straight after.
4. Keep the FIRST backup folder's path; undo only with `-RestoreFrom <that folder>` or `-Rollback -From <that folder>`.
5. Afterwards `verify-coder-containment.ps1 -AcceptedEgressGap` in scheduled-task mode.
6. Before the containment flip, separately: #1695 (the SYSTEM service whose binary every account can modify).
