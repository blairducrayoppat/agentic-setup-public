#requires -Version 5.1
<#
.SYNOPSIS
  Verify the fleet's stage->commit CAPTURE step is FAIL-LOUD (#1074): a failed git
  add/commit is reported as an ERRORED task carrying git's own message, and can
  never be laundered into "the coder produced nothing."

.DESCRIPTION
  Background (plain English):
    Invoke-CandidateBuild captures a coder's work with `git add -A` then
    `git commit`, and used to send BOTH error channels to Out-Null with no
    exit-code check. A locked index, a rejecting hook, a full disk or a
    sparse-checkout rule therefore produced the SAME report as an honest no-op:
    `CHANGES: none made / RESULT: Nothing to merge.` The reading then skipped the
    test + verify steps, so the candidate could never win the gate and best-of-N
    resampled a fault it could not see.

    This sits inside the INSTRUMENT that measures coder capability -- 40 of 488
    reports read `CHANGES: none made`, and nothing could tell a real no-op from a
    swallowed git error. That is a security_by_design principle 11 (FAIL-LOUD)
    violation in the dispatch quality path, which is why it is fixed here rather
    than worked around.

    The DISCRIMINATION is the hard part and is what most of this file tests:
    `git commit` legitimately exits non-zero on the honest "nothing to commit",
    so the exit code alone cannot separate the two, and matching git's English
    would be locale- and version-fragile. The pipeline therefore reads the INDEX
    and only ATTEMPTS a commit when something is staged; with content staged, a
    non-zero commit can only mean a real failure.

  This script proves the behaviour four ways:

    1. UNIT TESTS    (always; pure) - the REAL Resolve-CommitCapture truth table,
       the policy functions that consume its verdict, and the Start-Job
       deserialisation boundary the concurrent path crosses.
    2. DRY HARNESS   (always; no model) - the REAL Invoke-CandidateBuild entry
       point against throwaway git repos with REAL injected git failures
       (a held index.lock, a sparse-checkout rule, a rejecting pre-commit hook)
       and, critically, the REAL honest no-op and the REAL healthy build, so the
       discrimination is proven in both directions.
    3. TOGGLE-OFF    (always) - the PRE-#1074 swallow, replayed verbatim on the
       same fixture, is shown to report NO error and hasChanges=false. The
       harness above is RED against that behaviour; if the fix were reverted the
       D-case assertions could not pass.
    4. REPORT/WIRING - the SHIPPED report expressions (extracted from
       new-agent-task.ps1's own source, not a copy) are evaluated across every
       outcome to prove NO path renders `CHANGES: none made` for a non-empty
       worktree, and the swallow patterns are asserted GONE from fleet-lib.

  Exit code 0 if everything passed, 1 if any check failed. Run it normally
  ( .\verify-git-capture-honesty.ps1 ) - do NOT dot-source it.
#>
param()
$ErrorActionPreference = 'Stop'
. "$PSScriptRoot\fleet-lib.ps1"

# ----------------------------------------------------------------------------
# Tiny zero-dependency test framework (no Pester needed - matches verify-retry.ps1)
# ----------------------------------------------------------------------------
$script:Pass = 0
$script:Fail = 0
$script:Failures = New-Object System.Collections.ArrayList

function Section($t) { Write-Host ''; Write-Host "== $t ==" -ForegroundColor Cyan }
function _pass($m)   { $script:Pass++; Write-Host "  [PASS] $m" -ForegroundColor Green }
function _fail($m)   { $script:Fail++; [void]$script:Failures.Add($m); Write-Host "  [FAIL] $m" -ForegroundColor Red }

function Assert-Eq($Expected, $Actual, $Msg) {
    if ([string]$Expected -ceq [string]$Actual) { _pass $Msg }
    else { _fail "$Msg (expected '$Expected', got '$Actual')" }
}
function Assert-True($Cond, $Msg) {
    if ($Cond) { _pass $Msg } else { _fail "$Msg (expected True, got False)" }
}
function Assert-False($Cond, $Msg) {
    if (-not $Cond) { _pass $Msg } else { _fail "$Msg (expected False, got True)" }
}
function Assert-Match($Haystack, $Pattern, $Msg) {
    if ("$Haystack" -match $Pattern) { _pass $Msg } else { _fail "$Msg (no match for '$Pattern' in: $("$Haystack" -replace "`r?`n", ' / '))" }
}
function Assert-NotMatch($Haystack, $Pattern, $Msg) {
    if ("$Haystack" -notmatch $Pattern) { _pass $Msg } else { _fail "$Msg (unexpected match for '$Pattern')" }
}

# ----------------------------------------------------------------------------
# U1: Resolve-CommitCapture - the classification truth table (pure)
# ----------------------------------------------------------------------------
Section 'Unit tests: capture classification (Resolve-CommitCapture)'

# --- The HEALTHY paths: nothing is flagged. ---
$r = Resolve-CommitCapture -AddExitCode 0 -StagedCount 1 -CommitExitCode 0 -CommitCount 1 -WorktreeDirtyCount 0
Assert-False $r.Failed      'U1a staged + committed + clean tree -> healthy'
Assert-True  $r.HasChanges  'U1a healthy commit -> HasChanges'
Assert-Eq '' $r.Reason      'U1a healthy -> no reason'

# THE DISCRIMINATION, stated as a test: an honest no-op reaches this classifier with the
# commit NEVER ATTEMPTED ($CommitExitCode $null), because nothing was staged. It must be a
# clean no-op, not an error -- getting THIS right is what makes the fault detection usable.
$r = Resolve-CommitCapture -AddExitCode 0 -StagedCount 0 -CommitExitCode $null -CommitCount 0 -WorktreeDirtyCount 0
Assert-False $r.Failed      'U1b HONEST NO-OP (nothing staged, commit not attempted, clean tree) -> NOT an error'
Assert-False $r.HasChanges  'U1b honest no-op -> honestly no changes'
Assert-Eq '' $r.Reason      'U1b honest no-op -> no fault reason'

# --- Detector 1: EXIT CODES, each carrying git's own message. ---
$r = Resolve-CommitCapture -AddExitCode 128 -AddOutput "fatal: Unable to create '.../index.lock': File exists." -WorktreeDirtyCount 1
Assert-True  $r.Failed                       'U1c git add non-zero -> FAILED'
Assert-Eq 'add-failed' $r.Reason             'U1c reason names the failing step'
Assert-Match $r.Error 'index\.lock'          'U1c the error carries git''s ACTUAL message, not a paraphrase'
Assert-Match $r.Error 'git exit 128'         'U1c the error carries git''s exit code'

$r = Resolve-CommitCapture -AddExitCode 0 -StagedReadExitCode 129 -StagedReadOutput 'fatal: bad index' -WorktreeDirtyCount 1
Assert-True  $r.Failed                       'U1d unreadable index -> FAILED (we cannot tell staged from unstaged, so we refuse to guess)'
Assert-Eq 'index-unreadable' $r.Reason       'U1d reason names the failing step'

$r = Resolve-CommitCapture -AddExitCode 0 -StagedCount 2 -CommitExitCode 1 -CommitOutput 'pre-commit hook: refusing' -CommitCount 0 -WorktreeDirtyCount 2
Assert-True  $r.Failed                       'U1e commit non-zero WITH staged content -> FAILED'
Assert-Eq 'commit-failed' $r.Reason          'U1e reason names the failing step'
Assert-Match $r.Error 'pre-commit hook'      'U1e the error carries git''s ACTUAL message'
Assert-Match $r.Error 'NOT an empty-commit refusal' 'U1e the error states WHY this cannot be the honest no-op (2 paths were staged)'

# F2: the THIRD swallowed channel. rev-list feeds BOTH HasChanges and the invariant, so an
# unreadable count must refuse to guess -- defaulting it to 0 reports a branch that HOLDS the
# coder's commit as "none made", which is the same laundering by a different route.
$r = Resolve-CommitCapture -AddExitCode 0 -StagedCount 1 -CommitExitCode 0 -CommitCountReadExitCode 128 -CommitCountRaw '' -CommitCountReadOutput "fatal: ambiguous argument 'deadbee..HEAD': unknown revision"
Assert-True  $r.Failed                        'U1m rev-list non-zero -> FAILED (the commit count is not knowable, so it is not assumed)'
Assert-Eq 'revlist-unreadable' $r.Reason      'U1m reason names the failing step'
Assert-Match $r.Error 'unknown revision'      'U1m the error carries git''s ACTUAL message'
$r = Resolve-CommitCapture -AddExitCode 0 -StagedCount 1 -CommitExitCode 0 -CommitCountReadExitCode 0 -CommitCountRaw 'not-a-number' -CommitCountReadOutput 'garbage'
Assert-True  $r.Failed                        'U1n a NON-NUMERIC rev-list answer at exit 0 is also FAILED (the exit code alone was never enough)'
Assert-Match $r.Error "answered 'not-a-number'" 'U1n ...and the error quotes what it actually answered'
$r = Resolve-CommitCapture -AddExitCode 0 -StagedCount 1 -CommitExitCode 0 -CommitCount 1 -CommitCountRaw '1' -WorktreeDirtyCount 0
Assert-False $r.Failed                        'U1o a healthy numeric count is unaffected'

# ORDERING (load-bearing). A never-created workspace returns 128 from EVERY git read including
# rev-list. `revlist-unreadable` runs LAST among the exit-code detectors so the operator keeps the
# cause that actually names it. A fault that stays loud but lies about WHY is close to the original
# defect wearing a new label, in an instrument whose entire job is honest attribution.
$r = Resolve-CommitCapture -AddExitCode 128 -AddOutput "fatal: cannot change to '...': No such file or directory" `
        -CommitCountReadExitCode 128 -CommitCountRaw '' -CommitCountReadOutput 'fatal: cannot change to' `
        -StatusReadExitCode 128 -StatusReadOutput 'fatal: cannot change to' -BaseResolvable $false
Assert-Eq 'add-failed' $r.Reason 'U1p ORDER: when EVERY git read fails at once, the cause reported is add-failed - not revlist-unreadable, not status-unreadable, not base-unresolvable'

# AN UNRESOLVABLE BASE IS NOT A CAPTURE FAULT. $CodeBase is not guaranteed to be a SHA (the caller
# falls back to a branch NAME), so a healthy repo on `trunk` with a fallback name of `main` fails
# rev-list while HEAD is fine and the tree is clean - MEASURED. Faulting on that would turn every
# healthy build in that repo into a permanent silent ERRORED: the widen-the-fault inverse of the
# defect this whole change exists to fix.
$r = Resolve-CommitCapture -AddExitCode 0 -StagedCount 0 -CommitExitCode $null -CommitCountReadExitCode 128 `
        -CommitCountRaw '' -CommitCountReadOutput "fatal: ambiguous argument 'main..HEAD': unknown revision" `
        -WorktreeDirtyCount 0 -BaseResolvable $false -BaseRef 'main'
Assert-False $r.Failed                      'U1q a healthy NO-OP whose baseline name does not resolve is NOT a capture fault (the inverse regression stays shut)'
Assert-Eq 'base-unresolvable' $r.Reason     'U1q ...and gets its OWN reason, so the operator is told the truth about the cause'
Assert-Match $r.Error 'CONFIGURATION'       'U1q ...naming it a dispatch-config problem'
Assert-Match $r.Error "'main'"              'U1q ...and quoting the baseline ref that failed to resolve'
Assert-False $r.HasChanges                  'U1q ...an honest no-op still reads as no changes'
# ...but a HEALTHY BUILD with a mis-set base must not report "none made" either: with no resolvable
# baseline the count is meaningless, so the fallback is the only thing still knowable - did OUR
# commit succeed. Reporting a landed commit as "none made" is this ticket's laundering by another road.
$r = Resolve-CommitCapture -AddExitCode 0 -StagedCount 2 -CommitExitCode 0 -CommitCountReadExitCode 128 `
        -CommitCountRaw '' -WorktreeDirtyCount 0 -BaseResolvable $false -BaseRef 'main'
Assert-False $r.Failed      'U1r a healthy BUILD with an unresolvable base is not a fault either'
Assert-True  $r.HasChanges  'U1r ...and its landed commit is NOT laundered into "none made" - HasChanges falls back to the commit outcome'
# The real capture fault: the base RESOLVES and rev-list still fails -> unreadable history.
$r = Resolve-CommitCapture -AddExitCode 0 -StagedCount 1 -CommitExitCode 0 -CommitCountReadExitCode 128 `
        -CommitCountRaw '' -CommitCountReadOutput 'fatal: bad object' -BaseResolvable $true -BaseRef 'abc1234'
Assert-True  $r.Failed                       'U1s base RESOLVES but rev-list fails -> the real capture fault'
Assert-Eq 'revlist-unreadable' $r.Reason     'U1s ...classified as unreadable history, not as a config problem'
Assert-Match $r.Error 'RESOLVABLE'           'U1s ...and the message says the base was fine, so the operator does not chase the config'

$r = Resolve-CommitCapture -AddExitCode 0 -StagedCount 0 -CommitExitCode $null -StatusReadExitCode 128 -StatusReadOutput 'fatal: not a git repository'
Assert-True  $r.Failed                       'U1f unreadable status -> FAILED (the invariant below cannot be checked, so we do not pretend it passed)'
Assert-Eq 'status-unreadable' $r.Reason      'U1f reason names the failing step'

# --- Detector 2: the STATE INVARIANT (the backstop for causes we cannot enumerate --
# the measured B4 add-card instance, where every git step reported success). ---
$r = Resolve-CommitCapture -AddExitCode 0 -StagedCount 0 -CommitExitCode $null -CommitCount 0 -WorktreeDirtyCount 3
Assert-True  $r.Failed                       'U1g dirty worktree + ZERO commits -> FAILED even with every exit code 0 (the B4 shape)'
Assert-Eq 'uncommitted-work' $r.Reason       'U1g reason names the invariant, not a command'
Assert-Match $r.Error '3 uncommitted change' 'U1g the error counts the work that was lost'
Assert-Match $r.Error 'upstream of the exit codes' 'U1g the error tells the operator the cause is NOT a git exit code'

# The ONE sanctioned dirty-with-no-commit state: a secret block deliberately unstages and parks.
$r = Resolve-CommitCapture -AddExitCode 0 -StagedCount 2 -SecretBlocked $true -CommitExitCode $null -CommitCount 0 -WorktreeDirtyCount 2
Assert-False $r.Failed                       'U1h secret block: the deliberate dirty-with-no-commit park is NOT a capture fault'
Assert-Eq 'secret-blocked' $r.Reason         'U1h secret block is classified, not silently ignored'

# HasChanges stays HONEST on a fault (a prior commit still exists); Failed is what blocks the merge.
$r = Resolve-CommitCapture -AddExitCode 128 -AddOutput 'fatal: boom' -CommitCount 1 -WorktreeDirtyCount 1
Assert-True  $r.Failed                       'U1i a fault on a lap that already had a commit is still FAILED'
Assert-True  $r.HasChanges                   'U1i ...and HasChanges stays honest (a commit does exist) - Failed is what blocks the merge'

# A dirty tree WITH a landed commit is not flagged: a straggling tooling write after a good
# commit is the #694 quiesce class, handled there, and flagging it here would park good work.
$r = Resolve-CommitCapture -AddExitCode 0 -StagedCount 1 -CommitExitCode 0 -CommitCount 1 -WorktreeDirtyCount 1
Assert-False $r.Failed                       'U1j dirty tree but the commit LANDED -> not a capture fault (the work is captured; strays are #694''s job)'

# Message bounding: git can print a wall of hints; the report line stays readable.
$r = Resolve-CommitCapture -AddExitCode 1 -AddOutput ('x' * 5000) -MaxDetailChars 100
Assert-True ($r.Error.Length -lt 300) 'U1k a huge git message is bounded for the report line'
Assert-Match $r.Error 'truncated'     'U1k ...and the truncation is declared, never silent'
$r = Resolve-CommitCapture -AddExitCode 1 -AddOutput ''
Assert-Match $r.Error 'git printed no message' 'U1l a silent git failure still produces a loud, non-empty error line'

# ----------------------------------------------------------------------------
# U2: the policy functions consume the verdict (and stay byte-identical without it)
# ----------------------------------------------------------------------------
Section 'Unit tests: the capture fault reaches every gate decision'

Assert-False (Test-IsCandidateGreen -VerifyResult 'pass' -TestResult 'pass' -HasChanges $true -GitFailed $true) 'U2a a capture-faulted candidate is NEVER a winner, even with green gate signals'
Assert-True  (Test-IsCandidateGreen -VerifyResult 'pass' -TestResult 'pass' -HasChanges $true)                  'U2b -GitFailed omitted -> byte-identical legacy (a green candidate still wins)'

Assert-False (Test-ShouldMerge -HasChanges $true -SecretBlocked $false -AgentTimedOut $false -LoopSuspected $false -TestResult 'pass' -VerifyResult 'pass' -Verdict 'MERGE' -GitFailed $true).Merge 'U2c a capture fault HARD-blocks the merge (a part-way add can leave a partial commit)'
Assert-True  (Test-ShouldMerge -HasChanges $true -SecretBlocked $false -AgentTimedOut $false -LoopSuspected $false -TestResult 'pass' -VerifyResult 'pass' -Verdict 'MERGE').Merge                  'U2d -GitFailed omitted -> byte-identical legacy (green work still merges)'

# A capture fault is DELIBERATELY NOT terminal for sampling: it is per-CANDIDATE and often a
# per-candidate slip (a candidate whose worktree was never created faults EVERY git read), so making
# it terminal would let one bad workspace stop the whole run - a quality regression, not a safety
# gain. Assert the parameter's ABSENCE: an argument that were silently ignored would let the policy
# change while a value-based test still looked green.
Assert-False ([bool]((Get-Command Test-IsSamplingTerminal).Parameters.ContainsKey('GitFailed'))) 'U2e a capture fault is DELIBERATELY NOT terminal - Test-IsSamplingTerminal has no -GitFailed at all, so it cannot be re-added by accident (the loudness comes from the other four routes)'
Assert-False (Test-IsSamplingTerminal -TimedOut $false -SecretBlocked $false)                   'U2f a clean run is not terminal (byte-identical legacy)'
Assert-True  (Test-IsSamplingTerminal -TimedOut $false -SecretBlocked $true)                    'U2f2 a secret block is STILL terminal (the pre-existing posture is untouched by #1074)'
Assert-False (Test-IsSamplingTerminal -TimedOut $true -TimeoutReason 'idle' -SecretBlocked $false) 'U2f3 an idle stall is STILL resample-eligible (the carve-out a capture fault now matches)'

$rankOk    = Get-CandidateRank -VerifyResult 'none' -TestResult 'none' -HasChanges $false
$rankFault = Get-CandidateRank -VerifyResult 'pass' -TestResult 'pass' -HasChanges $true -GitFailed $true
$rankSecret= Get-CandidateRank -VerifyResult 'pass' -TestResult 'pass' -HasChanges $true -SecretBlocked $true
Assert-True ($rankFault -lt $rankOk)     'U2g a capture-faulted candidate ranks BELOW even a no-op real attempt (its gate signals describe a build the box never captured)'
Assert-True ($rankFault -gt $rankSecret) 'U2h ...but ABOVE a secret block, so an all-faulted run still selects one and the operator gets git''s message'
Assert-Eq (Get-CandidateRank -VerifyResult 'pass' -TestResult 'pass' -HasChanges $true) (Get-CandidateRank -VerifyResult 'pass' -TestResult 'pass' -HasChanges $true -GitFailed $false) 'U2i -GitFailed $false == omitted (byte-identical legacy score)'

# ----------------------------------------------------------------------------
# U3: the fault MUST survive the Start-Job boundary, or the CONCURRENT path
# silently re-opens the swallow (the sequential path would be fixed alone).
# ----------------------------------------------------------------------------
Section 'Unit tests: the fault survives the concurrent Start-Job deserialisation boundary'
$raw = @{ VerifyResult='none'; TestResult='none'; HasChanges=$false; TimedOut=$false; SecretBlocked=$false; LoopSuspected=$false
          GitFailed=$true; GitError="git add -A failed (git exit 128): fatal: Unable to create index.lock"; GitFaultReason='add-failed'
          SHA=''; BuildAttempts=1; TestError=''; VerifyDetail=''; VerifyError=''; AgentLog=''
          Run=@{ ExitCode=0 }; Secret=@{ status='skipped' }; Anomaly=@{ Anomalies=@(); LoopSuspected=$false } }
$c = ConvertTo-CandidateResult -Raw $raw -Index 2 -Worktree 'C:\wt-c2' -Branch 'agent/t-c2'
Assert-True  $c.GitFailed                    'U3a GitFailed crosses the boundary'
Assert-Match $c.GitError 'index\.lock'       'U3b git''s message crosses the boundary intact'
Assert-Eq 'add-failed' $c.GitFaultReason     'U3c the fault reason crosses the boundary'
$c0 = ConvertTo-CandidateResult -Raw $null -Index 1
Assert-False $c0.GitFailed                   'U3d a dead job is NOT reported as a capture fault (its own VerifyError names it)'
$cLegacy = ConvertTo-CandidateResult -Raw @{ VerifyResult='pass'; TestResult='pass'; HasChanges=$true } -Index 1
Assert-False $cLegacy.GitFailed              'U3e a raw result without the field -> $false (shape-stable, fail-safe toward "no fault")'

# ----------------------------------------------------------------------------
# D: DRY HARNESS - the REAL Invoke-CandidateBuild entry point against REAL git
# failures. No model, no mocked git: a scripted stand-in replaces only the coder
# driver (defined AFTER the dot-source, so name resolution picks it up), and the
# faults are injected the way they actually happen on the box.
# ----------------------------------------------------------------------------
Section 'Dry harness: REAL Invoke-CandidateBuild against REAL injected git failures'

$scratch = Join-Path ([IO.Path]::GetTempPath()) ("gitcapture-harness-" + [guid]::NewGuid())
New-Item -ItemType Directory -Force $scratch | Out-Null

function New-FixtureRepo {
    # A throwaway git repo with ONE baseline commit, returned with its baseline SHA.
    param([string]$Name)
    $repo = Join-Path $scratch $Name
    New-Item -ItemType Directory -Force $repo | Out-Null
    git -C $repo init -b main 2>&1 | Out-Null
    New-Item -ItemType Directory -Force (Join-Path $repo 'keep') | Out-Null
    Set-Content (Join-Path $repo 'keep\README.md') 'fixture repo for the capture-honesty harness' -Encoding ascii
    git -C $repo add -A 2>&1 | Out-Null
    git -C $repo -c user.email='test@local' -c user.name='capture-test' commit -m 'init' 2>&1 | Out-Null
    @{ Repo = $repo; Base = "$(git -C $repo rev-parse HEAD)".Trim() }
}

# The stand-in coder. $script:CoderWrites decides what it produces; $script:CoderSabotage
# injects the git fault AFTER the work exists -- exactly the real ordering (the coder
# succeeds, the capture step fails). Deliberately writes NO test_*.py so the #790 scratch
# partition stays empty and the harness never launches pytest.
$script:CoderCalls = 0
$script:CoderWrites = $true
$script:CoderSabotage = { param($WorkDir) }
function Invoke-CoderDriver {
    param([string]$WorkDir, [string]$Model, [string]$Prompt, [string]$LogPath,
          [int]$TimeoutSec, [int]$IdleTimeoutSec, [string]$ScriptRoot)
    $script:CoderCalls++
    Set-Content $LogPath "coder leg $($script:CoderCalls): wrote the requested module`n"
    if ($script:CoderWrites) {
        New-Item -ItemType Directory -Force (Join-Path $WorkDir 'app') | Out-Null
        Set-Content (Join-Path $WorkDir 'app\card_entry.py') "def add_card(name):`n    return {'name': name}`n" -Encoding ascii
    }
    & $script:CoderSabotage $WorkDir
    return @{ TimedOut = $false; ExitCode = 0; TimeoutReason = ''; Capped = $false; CappedReason = ''; Seconds = 1; Error = '' }
}

function Invoke-HarnessCandidate {
    param([hashtable]$Fx, [string]$Task)
    Invoke-CandidateBuild -ScriptRoot $PSScriptRoot -Worktree $Fx.Repo -Model 'local/fake' -CodeBase $Fx.Base `
        -AttemptPrompt 'Add an add_card function' -LogPath (Join-Path $scratch "$Task.agent.log") `
        -Task $Task -MaxBuildAttempts 1
}

# --- D1: `git add` fails because the index is LOCKED (another git process, or a stale
# lock after a crash). This is the exact laundering shape: the coder's files ARE on disk,
# `git status --porcelain` sees them, and `rev-list` does not. ---
$fx1 = New-FixtureRepo 'lockfail'
$script:CoderCalls = 0; $script:CoderWrites = $true
$script:CoderSabotage = { param($WorkDir) Set-Content (Join-Path $WorkDir '.git\index.lock') '' }
$d1 = Invoke-HarnessCandidate -Fx $fx1 -Task 'capture-d1-addfail'
Assert-True  ((@(git -C $fx1.Repo status --porcelain 2>$null)).Count -gt 0) 'D1a the trap is REAL: the coder''s work IS in the worktree when the capture step runs'
Assert-True  $d1.GitFailed                      'D1b a locked index is reported as a CAPTURE FAULT'
Assert-Eq 'add-failed' $d1.GitFaultReason       'D1c the fault names the failing git step'
Assert-Match $d1.GitError 'index\.lock'         'D1d the fault carries git''s ACTUAL stderr, not a paraphrase'
Assert-False $d1.HasChanges                     'D1e nothing was captured, so HasChanges is honestly false'
Assert-Eq 'none' $d1.TestResult                 'D1f the test step did not run over a build we could not capture'
Assert-Eq 'none' $d1.VerifyResult               'D1g the verify step did not run either'
Assert-Eq 'skipped' "$($d1.Secret.status)"      'D1h the secret scan was NOT run and does not report "clean" over an unscanned index (fail-closed)'
Remove-Item (Join-Path $fx1.Repo '.git\index.lock') -Force -ErrorAction SilentlyContinue

# --- D2: an INDEPENDENT second cause of the same step failing -- a sparse-checkout rule
# that makes `git add` refuse the coder's path. Proves the detector is on the exit code,
# not on one cause's message. ---
$fx2 = New-FixtureRepo 'sparsefail'
git -C $fx2.Repo sparse-checkout init --cone 2>&1 | Out-Null
git -C $fx2.Repo sparse-checkout set keep 2>&1 | Out-Null
$script:CoderCalls = 0; $script:CoderSabotage = { param($WorkDir) }
$d2 = Invoke-HarnessCandidate -Fx $fx2 -Task 'capture-d2-sparse'
Assert-True  $d2.GitFailed                      'D2a a sparse-checkout refusal is reported as a CAPTURE FAULT (a DIFFERENT cause, same detector)'
Assert-Eq 'add-failed' $d2.GitFaultReason       'D2b classified on the exit code, not on one cause''s wording'
Assert-Match $d2.GitError 'sparse-checkout'     'D2c the fault carries git''s own explanation of THIS cause'
Assert-False $d2.HasChanges                     'D2d nothing captured -> honestly false'

# --- D3: `git commit` fails with content STAGED (a rejecting pre-commit hook). This is
# the case the honest "nothing to commit" exit code is indistinguishable from -- and the
# staged-set read is what tells them apart. ---
$fx3 = New-FixtureRepo 'commitfail'
Set-Content (Join-Path $fx3.Repo '.git\hooks\pre-commit') "#!/bin/sh`necho 'pre-commit hook: refusing this commit (injected fault)' 1>&2`nexit 1`n" -Encoding ascii -NoNewline
$script:CoderCalls = 0; $script:CoderSabotage = { param($WorkDir) }
$d3 = Invoke-HarnessCandidate -Fx $fx3 -Task 'capture-d3-commitfail'
Assert-True  $d3.GitFailed                      'D3a a rejected commit is reported as a CAPTURE FAULT'
Assert-Eq 'commit-failed' $d3.GitFaultReason    'D3b the fault names the commit step'
Assert-Match $d3.GitError 'pre-commit hook'     'D3c the fault carries the hook''s ACTUAL stderr'
Assert-Match $d3.GitError 'NOT an empty-commit refusal' 'D3d the fault states why this cannot be the honest no-op'
Assert-False $d3.HasChanges                     'D3e nothing was committed -> honestly false'
Assert-True  ((@(git -C $fx3.Repo status --porcelain 2>$null)).Count -gt 0) 'D3f the coder''s work is still in the worktree for the operator to inspect (never destroyed)'

# --- D4: the HONEST NO-OP through the same real pipeline. The coder writes nothing; the
# tree is clean; nothing is staged. This MUST come back a clean no-op, NOT an error --
# without this the fix would just move the laundering in the other direction. ---
$fx4 = New-FixtureRepo 'honestnoop'
$script:CoderCalls = 0; $script:CoderWrites = $false; $script:CoderSabotage = { param($WorkDir) }
$d4 = Invoke-HarnessCandidate -Fx $fx4 -Task 'capture-d4-honest-noop'
Assert-False $d4.GitFailed                      'D4a an HONEST no-op is NOT an error (git commit''s non-zero "nothing to commit" never enters the failure channel)'
Assert-Eq '' $d4.GitFaultReason                 'D4b honest no-op -> no fault reason'
Assert-Eq '' $d4.GitError                       'D4c honest no-op -> no error text'
Assert-False $d4.HasChanges                     'D4d honest no-op -> honestly no changes'
Assert-Eq 0 (@(git -C $fx4.Repo status --porcelain 2>$null)).Count 'D4e ...and the worktree really was empty (the no-op reading is TRUE here)'

# --- D4b: the honest no-op again, in a repo that makes git CHATTY on stderr (core.autocrlf with
# LF-only content). The staged-set and status reads are COUNTED, so if git's warnings were merged
# into those streams a diagnostic line would count as a staged path or a dirty entry and this honest
# no-op would come back a FALSE capture fault -- #1074's own defect pointed the other way. ---
$fx4b = New-FixtureRepo 'noisy-noop'
git -C $fx4b.Repo config core.autocrlf true 2>&1 | Out-Null
[IO.File]::WriteAllText((Join-Path $fx4b.Repo 'lf_only.txt'), "one`ntwo`nthree`n")
git -C $fx4b.Repo add -A 2>&1 | Out-Null
git -C $fx4b.Repo -c user.email='test@local' -c user.name='capture-test' commit -m 'lf content' 2>&1 | Out-Null
$fx4b.Base = "$(git -C $fx4b.Repo rev-parse HEAD)".Trim()
$script:CoderCalls = 0; $script:CoderWrites = $false; $script:CoderSabotage = { param($WorkDir) }
$d4b = Invoke-HarnessCandidate -Fx $fx4b -Task 'capture-d4b-noisy-noop'
Assert-False $d4b.GitFailed  'D4f a CHATTY repo (git warning on stderr) + an honest no-op is STILL not a fault - git''s diagnostics are never counted as staged paths or dirty entries'
Assert-False $d4b.HasChanges 'D4g ...and the no-op reading stays honest'

# --- D4h-D4l: the candidate whose WORKSPACE WAS NEVER CREATED. `git worktree add` is swallowed upstream
# (new-agent-task's -RunBatch loop; #1076 makes that call loud separately), so today a candidate can
# run this whole pipeline against a directory that does not exist. Every git read then returns 128.
# It must be a LOUD capture fault -- and it must NOT be terminal for sampling, because it is exactly
# the per-candidate slip best-of-N exists to route around: the sibling candidates' workspaces are
# fine, and stopping the run would park work they are about to produce. ---
$fxMissing = @{ Repo = (Join-Path $scratch 'never-created'); Base = '0000000000000000000000000000000000000000' }
$script:CoderCalls = 0; $script:CoderWrites = $false; $script:CoderSabotage = { param($WorkDir) }
$d4c = Invoke-HarnessCandidate -Fx $fxMissing -Task 'capture-d4c-missing-worktree'
Assert-False (Test-Path $fxMissing.Repo) 'D4h the trap is REAL: the candidate workspace genuinely does not exist'
Assert-True  $d4c.GitFailed              'D4i a candidate built against a never-created workspace is a LOUD capture fault, not an empty build'
Assert-Match $d4c.GitError 'cannot change to|No such file'  'D4j ...carrying git''s ACTUAL "cannot change to" message'
# THE ORDERING CHECK, end to end. Every git read here returns 128, including rev-list and status.
# The reported cause must remain the one that actually names it. If a later change moves the
# revlist detector earlier, this is the assertion that catches it.
Assert-Eq 'add-failed' $d4c.GitFaultReason 'D4j2 ORDER (end to end): a never-created workspace is reported as add-failed, NOT revlist-unreadable or status-unreadable - the fault must not stay loud while lying about why'
Assert-False $d4c.HasChanges             'D4k ...and nothing is claimed to have been captured'
Assert-False (Test-IsSamplingTerminal -TimedOut $false -SecretBlocked $false) 'D4l ...and sampling is NOT stopped by it: best-of-N routes around this candidate to its siblings, whose workspaces are fine'

# --- D4d/D4e: the MIS-SET BASELINE, end to end on a REAL repo. `$CodeBase` is not guaranteed to be
# a SHA (new-agent-task falls back to a branch NAME), so a healthy repo whose branch is `trunk` while
# the fallback names `main` fails rev-list with HEAD fine and the tree clean. Faulting on that would
# make every healthy build in that repo a permanent silent ERRORED. Driven through the REAL pipeline
# in BOTH directions - the no-op and the build - because the build direction is where a wrong answer
# would launder a landed commit into "none made". ---
$fxBase = New-FixtureRepo 'misset-base'
git -C $fxBase.Repo branch -m trunk 2>&1 | Out-Null       # the repo is entirely healthy...
$fxBase.Base = 'main'                                      # ...but the dispatch hands it the wrong base NAME
$script:CoderCalls = 0; $script:CoderWrites = $false; $script:CoderSabotage = { param($WorkDir) }
$dBaseNoop = Invoke-HarnessCandidate -Fx $fxBase -Task 'capture-d4d-misset-base-noop'
Assert-False $dBaseNoop.GitFailed            'D4m a HEALTHY no-op with an unresolvable baseline name is NOT ERRORED (the inverse regression, driven end to end)'
Assert-Eq 'base-unresolvable' $dBaseNoop.GitFaultReason 'D4n ...and is reported as a dispatch-config problem, named honestly'
Assert-False $dBaseNoop.HasChanges           'D4o ...with the honest no-op reading intact'
$script:CoderWrites = $true
$dBaseBuild = Invoke-HarnessCandidate -Fx $fxBase -Task 'capture-d4e-misset-base-build'
Assert-False $dBaseBuild.GitFailed           'D4p a HEALTHY build with the same mis-set baseline is not ERRORED either'
Assert-True  $dBaseBuild.HasChanges          'D4q ...and its REAL landed commit is not laundered into "none made" just because the baseline name was wrong'
Assert-True  ($dBaseBuild.SHA -match '^[0-9a-f]{40}$') 'D4r ...the commit genuinely landed (real SHA)'

# --- D5: a HEALTHY build through the same real pipeline: real add, real commit, real SHA. ---
$fx5 = New-FixtureRepo 'healthy'
$script:CoderCalls = 0; $script:CoderWrites = $true; $script:CoderSabotage = { param($WorkDir) }
$d5 = Invoke-HarnessCandidate -Fx $fx5 -Task 'capture-d5-healthy'
Assert-False $d5.GitFailed                      'D5a a healthy capture reports no fault'
Assert-True  $d5.HasChanges                     'D5b the work was captured'
Assert-True  ($d5.SHA -match '^[0-9a-f]{40}$')  'D5c a real commit SHA came back'
Assert-Match (git -C $fx5.Repo show --stat --oneline HEAD 2>$null) 'card_entry\.py' 'D5d the coder''s file is IN the commit (the capture actually captured)'
Assert-Eq 0 (@(git -C $fx5.Repo diff --name-only HEAD 2>$null)).Count 'D5e no tracked work was left uncommitted by a healthy capture (the invariant the backstop watches, measured at the same moment the pipeline measures it)'
# NOTE for a future change: the [3/5] verify step runs AFTER the capture and litters the tree
# (a python check leaves app/__pycache__/), so `git status --porcelain` is legitimately dirty by
# the END of the pipeline. The invariant read must therefore stay where it is -- immediately after
# the commit. Moving it later would turn every healthy python build into a false capture fault.
Assert-Match (git -C $fx5.Repo status --porcelain 2>$null) '__pycache__' 'D5f (guard) post-capture litter IS present at the end of the pipeline - proof that the invariant read must stay at capture time, not report time'

# --- D6: the STATE INVARIANT read from a REAL repo. Its cause class is by definition the
# one we could not enumerate (the B4 instance: every git step reported success), so it is
# driven by putting a real repo into the dirty-with-no-commit state and classifying the
# facts read by the SAME git commands the pipeline uses. ---
$fx6 = New-FixtureRepo 'invariant'
Set-Content (Join-Path $fx6.Repo 'app_left_behind.py') 'print("work that never reached a commit")' -Encoding ascii
$i_dirty = (@(git -C $fx6.Repo status --porcelain 2>$null)).Count; $i_statusRc = $LASTEXITCODE
$i_rl = "$(git -C $fx6.Repo rev-list --count "$($fx6.Base)..HEAD" 2>$null)".Trim()
$d6 = Resolve-CommitCapture -AddExitCode 0 -StagedCount 0 -CommitExitCode $null `
        -CommitCount ([int]$i_rl) -StatusReadExitCode $i_statusRc -WorktreeDirtyCount $i_dirty
Assert-True  ($i_dirty -gt 0)                   'D6a real repo really is dirty'
Assert-Eq '0' $i_rl                             'D6b real repo really has no commit past the baseline'
Assert-True  $d6.Failed                         'D6c real dirty-with-no-commit facts classify as a CAPTURE FAULT'
Assert-Eq 'uncommitted-work' $d6.Reason         'D6d ...named as the invariant, not as a git command'

# --- D7: MULTI-CANDIDATE. The lead's reproduction: candidate 1 an honest no-op, candidate 2 a real
# capture fault. Driven through the REAL Invoke-BestOfN with the REAL policy predicates, because the
# defect lives in SELECTION, not in the capture step. The faulted candidate correctly LOSES (a real
# attempt outranks it), and the fault must survive that loss. ---
Section 'Multi-candidate: a fault must not vanish because a better candidate won selection'
$fx7a = New-FixtureRepo 'multi-noop'
$fx7b = New-FixtureRepo 'multi-fault'
New-Item -ItemType Directory -Force (Join-Path $fx7b.Repo 'app') | Out-Null
Set-Content (Join-Path $fx7b.Repo 'app\card_entry.py') "def add_card(n):`n    return n`n" -Encoding ascii
Set-Content (Join-Path $fx7b.Repo '.git\index.lock') ''
$script:CoderCalls = 0; $script:CoderWrites = $false; $script:CoderSabotage = { param($WorkDir) }
$c1 = Invoke-HarnessCandidate -Fx $fx7a -Task 'capture-d7-c1'; $c1.Index = 1
$c2 = Invoke-HarnessCandidate -Fx $fx7b -Task 'capture-d7-c2'; $c2.Index = 2
Remove-Item (Join-Path $fx7b.Repo '.git\index.lock') -Force -ErrorAction SilentlyContinue
Assert-False $c1.GitFailed 'D7a candidate 1 is a clean honest no-op'
Assert-True  $c2.GitFailed 'D7b candidate 2 really did fault'
$__q = New-Object System.Collections.Queue
$__q.Enqueue($c1); $__q.Enqueue($c2)
$bon7 = Invoke-BestOfN -MaxCandidates 2 `
    -RunCandidate { param($k, $n) $__q.Dequeue() } `
    -IsWinner { param($c) Test-IsCandidateGreen -VerifyResult $c.VerifyResult -TestResult $c.TestResult -HasChanges $c.HasChanges -TimedOut $c.TimedOut -SecretBlocked $c.SecretBlocked -GitFailed ([bool]$c.GitFailed) } `
    -StopSampling { param($c) Test-IsSamplingTerminal -SecretBlocked $c.SecretBlocked -TimedOut $c.TimedOut -TimeoutReason "$($c.Run.TimeoutReason)" -NoChangeDeclared ([bool]$c.NoChangeDeclared) } `
    -ScoreCandidate { param($c) Get-CandidateRank -VerifyResult $c.VerifyResult -TestResult $c.TestResult -HasChanges $c.HasChanges -TimedOut $c.TimedOut -SecretBlocked $c.SecretBlocked -LoopSuspected $c.LoopSuspected -GitFailed ([bool]$c.GitFailed) }
Assert-Eq 2 $bon7.Count             'D7c both candidates ran - a fault did NOT stop sampling (the 7a9a87a correction)'
Assert-False ([bool]$bon7.Selected.GitFailed) 'D7d the faulted candidate LOST selection to the real no-op - correct ranking, deliberately unchanged'
# ...and THIS is the F1 defect: reading only the selection loses the fault entirely.
$sel7Only = [bool]$bon7.Selected.GitFailed
$agg7 = @($bon7.Candidates | Where-Object { $_ -and [bool]$_.GitFailed })
Assert-False $sel7Only              'D7e reading ONLY the selected candidate reports NO fault - this is the defect F1 names'
Assert-Eq 1 $agg7.Count             'D7f the AGGREGATE over all candidates still sees it - the fix'
Assert-Match $agg7[0].GitError 'index\.lock' 'D7g ...with the faulted candidate''s git message intact for the report'

# ----------------------------------------------------------------------------
# TOGGLE-OFF: replay the PRE-#1074 statements VERBATIM against BOTH a real git
# failure and a real honest no-op, and show the two are INDISTINGUISHABLE -- the
# defect stated as a measurement, not an opinion. The D-cases above are RED
# against this behaviour: with the swallow in place, D1b/D1d/D3a/D3c cannot pass
# and D4 cannot be told apart from D1.
#
# A revert-flag is deliberately NOT shipped for this: a switch that restores a
# swallowed error channel is a defect wearing a config key (security_by_design
# principle 4 -- structural absence beats a flag), so the toggle-off is proven by
# REPLAYING the old statements here rather than by leaving them reachable.
# ----------------------------------------------------------------------------
Section 'TOGGLE-OFF: the pre-#1074 swallow makes a real failure indistinguishable from a real no-op'

function Invoke-LegacyCapture {
    # The EXACT pre-#1074 statements (fleet-lib.ps1 :2484 / :2494 / :2496), verbatim.
    # Everything a caller could observe from them is returned; that is the point.
    param([string]$wtL, [string]$CodeBaseL)
    git -C $wtL add -A 2>&1 | Out-Null
    git -C $wtL -c user.email='agent@local' -c user.name='coding-agent' commit -m "agent: legacy" 2>&1 | Out-Null
    $hc = (git -C $wtL rev-list --count "$CodeBaseL..HEAD" 2>$null) -gt 0
    return @{ HasChanges = [bool]$hc }
}

# Fixture A: a REAL failure -- the coder's work is on disk and the index is locked.
$fxLa = New-FixtureRepo 'legacy-failure'
New-Item -ItemType Directory -Force (Join-Path $fxLa.Repo 'app') | Out-Null
Set-Content (Join-Path $fxLa.Repo 'app\card_entry.py') "def add_card(name):`n    return {'name': name}`n" -Encoding ascii
Set-Content (Join-Path $fxLa.Repo '.git\index.lock') ''
$dirtyA = (@(git -C $fxLa.Repo status --porcelain 2>$null)).Count
$legacyA = Invoke-LegacyCapture -wtL $fxLa.Repo -CodeBaseL $fxLa.Base

# Fixture B: a REAL honest no-op -- the coder produced nothing at all.
$fxLb = New-FixtureRepo 'legacy-noop'
$dirtyB = (@(git -C $fxLb.Repo status --porcelain 2>$null)).Count
$legacyB = Invoke-LegacyCapture -wtL $fxLb.Repo -CodeBaseL $fxLb.Base

Assert-True  ($dirtyA -gt 0)   'L1 fixture A really is the failure case: the coder''s work IS on disk with the index locked'
Assert-Eq 0 $dirtyB            'L2 fixture B really is the honest no-op: nothing on disk'
Assert-False $legacyA.HasChanges 'L3 [toggle-off RED] pre-#1074, the FAILURE reports "no changes"'
Assert-False $legacyB.HasChanges 'L4 pre-#1074, the honest NO-OP reports "no changes"'
Assert-Eq ([string]$legacyB.HasChanges) ([string]$legacyA.HasChanges) 'L5 [toggle-off RED] the two are BYTE-IDENTICAL to the caller - the pre-#1074 code cannot tell a swallowed git error from an honest no-op, which is the defect'

# The SAME facts through the SHIPPED classifier: the only thing that changed is the fix.
$addOutA = (git -C $fxLa.Repo add -A 2>&1 | Out-String); $addRcA = $LASTEXITCODE
$fixedA = Resolve-CommitCapture -AddExitCode $addRcA -AddOutput $addOutA -CommitCount 0 -WorktreeDirtyCount $dirtyA
$fixedB = Resolve-CommitCapture -AddExitCode 0 -StagedCount 0 -CommitExitCode $null -CommitCount 0 -WorktreeDirtyCount $dirtyB
Assert-True  $fixedA.Failed              'L6 the SHIPPED classifier reports a FAULT on the identical failure facts'
Assert-False $fixedB.Failed              'L7 ...and a clean no-op on the identical no-op facts'
Assert-True  ($fixedA.Reason -ne $fixedB.Reason) 'L8 the two are now DISTINGUISHABLE - the whole delta of #1074'
Assert-Match $fixedA.Error 'index\.lock' 'L9 ...and the fault carries the git message the legacy code discarded'
Remove-Item (Join-Path $fxLa.Repo '.git\index.lock') -Force -ErrorAction SilentlyContinue

# cleanup (throwaway scratch; evidence lives in this script's output)
Remove-Item -Recurse -Force -LiteralPath $scratch -ErrorAction SilentlyContinue

# ----------------------------------------------------------------------------
# R: THE OPERATOR-FACING PREDICATE - evaluate the SHIPPED report expressions
# (extracted from new-agent-task.ps1's own source, so this cannot drift from a
# copy) across every outcome, and assert NO path renders `CHANGES: none made`
# while the worktree holds work.
# ----------------------------------------------------------------------------
Section 'Report: no path renders "CHANGES: none made" for a non-empty worktree'

$natRaw = Get-Content "$PSScriptRoot\new-agent-task.ps1" -Raw
$changesLine = ([regex]::Match($natRaw, '(?m)^CHANGES: .*$')).Value
$resultLine  = ([regex]::Match($natRaw, '(?m)^RESULT: .*$')).Value
Assert-True ($changesLine.Length -gt 0) 'R0a the shipped CHANGES line was located in new-agent-task.ps1'
Assert-True ($resultLine.Length -gt 0)  'R0b the shipped RESULT line was located in new-agent-task.ps1'

# Build a scriptblock that expands the EXACT shipped line under a given outcome. The line
# is wrapped in a double-quoted HERE-string so its own single AND double quotes survive
# verbatim, while `$(...)` subexpressions expand exactly as they do in the real report.
function New-LineRenderer([string]$Line) {
    $q = [char]34
    $code = "param(`$gitFailed, `$gitFaultReason, `$gitError, `$secretBlocked, `$hasChanges, `$noChangeDeclared, `$noChangeEvidence, `$merged, `$mergedVia, `$wt, `$branch, `$captureFaultNote)`n" +
            "@$q`n$Line`n$q@"
    [scriptblock]::Create($code)
}
$renderChanges = New-LineRenderer $changesLine
$renderResult  = New-LineRenderer $resultLine

# outcome vectors: name, gitFailed, secretBlocked, hasChanges, noChangeDeclared, worktree-holds-work,
# note = the aggregate capture-fault note (non-empty whenever ANY candidate faulted, selected or not)
$__noteAdd = '  - candidate 2 [add-failed]: fatal: Unable to create index.lock: File exists'
$vectors = @(
    @{ n='capture fault (add)';   gf=$true;  sb=$false; hc=$false; nc=$false; dirty=$true;  note=$__noteAdd },
    @{ n='capture fault (commit)';gf=$true;  sb=$false; hc=$false; nc=$false; dirty=$true;  note=$__noteAdd },
    @{ n='secret blocked';        gf=$false; sb=$true;  hc=$false; nc=$false; dirty=$true;  note='' },
    @{ n='parked (not merged)';   gf=$false; sb=$false; hc=$true;  nc=$false; dirty=$false; note='' },
    @{ n='honest no-op';          gf=$false; sb=$false; hc=$false; nc=$false; dirty=$false; note='' },
    @{ n='declared no-change';    gf=$false; sb=$false; hc=$false; nc=$true;  dirty=$false; note='' },
    # F1: the selected candidate is an honest no-op, but a SIBLING candidate faulted and lost
    # selection to it. The selected reading is true of the selected candidate and useless as a
    # measurement of the run -- so the bare "none made" must not survive.
    @{ n='sibling candidate faulted'; gf=$false; sb=$false; hc=$false; nc=$false; dirty=$true; note=$__noteAdd }
)
foreach ($v in $vectors) {
    $ch = & $renderChanges $v.gf 'add-failed' 'fatal: Unable to create index.lock: File exists' $v.sb $v.hc $v.nc 'already satisfied' $false '' 'C:\wt' 'agent/t' $v.note
    $rs = & $renderResult  $v.gf 'add-failed' 'fatal: Unable to create index.lock: File exists' $v.sb $v.hc $v.nc 'already satisfied' $false '' 'C:\wt' 'agent/t' $v.note
    if ($v.dirty) {
        # Anchored to the BARE verdict, not the substring. The claim being locked is "no clean
        # no-op reading survives when work exists", and a QUALIFIED line that happens to contain
        # the phrase ("none made BY THE SELECTED CANDIDATE - but another candidate FAULTED...")
        # satisfies that claim. A substring check would have forced the honest qualifier out of
        # the report to keep the test green - the test dictating a worse report.
        Assert-NotMatch $ch '(?m)^CHANGES: none made\s*$'      "R1 [$($v.n)] work exists in this run -> the report NEVER carries the bare 'none made' verdict"
        Assert-NotMatch $rs '(?m)^RESULT: Nothing to merge\.\s*$' "R2 [$($v.n)] work exists in this run -> the RESULT is never the bare no-change verdict"
    }
    if ($v.gf) {
        Assert-Match $ch 'CAPTURE FAULT'                 "R3 [$($v.n)] the report carries a CAPTURE FAULT line"
        Assert-Match $ch 'Unable to create index\.lock'  "R4 [$($v.n)] ...carrying git's ACTUAL message"
        Assert-Match $ch 'says NOTHING about the model'  "R5 [$($v.n)] ...and tells the reader this is not a capability datapoint"
        Assert-Match $rs 'ERRORED'                       "R6 [$($v.n)] the RESULT classifies the task as ERRORED"
        Assert-NotMatch $rs 'BLOCKED'                    "R7 [$($v.n)] ...and does not collide with the secret-block vocabulary the trend parser checks first"
    }
}
$chNoop = & $renderChanges $false '' '' $false $false $false '' $false '' 'C:\wt' 'agent/t' ''
Assert-Match $chNoop 'none made' 'R8 an HONEST no-op still reports "none made" (the honest reading is preserved, not replaced)'
Assert-NotMatch $chNoop 'CAPTURE FAULT' 'R8b ...with no fault noise when nothing faulted'

# F1 in the report: a fault on a NON-SELECTED candidate must still reach the operator, and must
# strip the bare no-op reading. Without this the fault is dropped whenever any better candidate
# exists - which is #1074's own defect surviving one level up, at multi-candidate scope.
$chSib = & $renderChanges $false '' '' $false $false $false '' $false '' 'C:\wt' 'agent/t' $__noteAdd
Assert-NotMatch $chSib '^CHANGES: none made$'      'R11 a sibling fault removes the bare "none made" reading'
Assert-Match    $chSib 'BY THE SELECTED CANDIDATE' 'R12 ...and scopes the no-op claim to the candidate it is actually true of'
Assert-Match    $chSib 'CAPTURE FAULT'             'R13 ...and carries the fault line even though the task did not error'
Assert-Match    $chSib 'index\.lock'               'R14 ...carrying the faulted candidate''s git message'
Assert-Match    $chSib 'non-selected candidate'    'R15 ...and says plainly that the selected result still stands'
$rsSib = & $renderResult $false '' '' $false $true $false '' $false '' 'C:\wt' 'agent/t' $__noteAdd
Assert-NotMatch $rsSib 'ERRORED' 'R16 a sibling fault does NOT error the task - the selected candidate is a real result and its RESULT verdict is unchanged'
$rsSibNoop = & $renderResult $false '' '' $false $false $false '' $false '' 'C:\wt' 'agent/t' $__noteAdd
Assert-NotMatch $rsSibNoop '(?m)^RESULT: Nothing to merge\.\s*$' 'R17 a sibling fault strips the BARE no-change verdict from RESULT too'
Assert-Match    $rsSibNoop 'another candidate FAULTED' 'R18 ...and says why, so the trend line is not read as a clean coder no-op'
Assert-NotMatch $rsSibNoop 'ERRORED' 'R19 ...while still not claiming the task errored (it did not)'
Assert-Match    $rsSibNoop 'Nothing to merge' 'R20 ...and stays classifiable as a no-merge outcome by fleet-report (the CAPTURE FAULT counter carries the fault signal)'

# The trend the operator reads must not fold box faults into the no-op column.
$frp = Get-Content "$PSScriptRoot\fleet-report.ps1" -Raw
Assert-True ([regex]::IsMatch($frp, "(?m)^\s*\`$outcome = if \(\`$result -match 'ERRORED'\) \{ 'errored' \}")) 'R9 fleet-report classifies ERRORED FIRST, so a box fault never inflates the "no change made" trend'
Assert-True ([regex]::IsMatch($frp, "ERRORED \(box\)")) 'R10 the trend report shows the ERRORED count to the operator'

# ----------------------------------------------------------------------------
# W: WIRING - the swallow is GONE and the new pieces are reachable from the
# production pipeline (a substring in a comment must not pass).
# ----------------------------------------------------------------------------
Section 'Wiring: the swallow is gone and the fault reaches every consumer'
$lib = Get-Content "$PSScriptRoot\fleet-lib.ps1" -Raw
$nat = $natRaw

Assert-False ([regex]::IsMatch($lib, '(?m)^\s*git -C \$wt add -A 2>&1 \| Out-Null')) 'W1 [kill] the swallowed `git add -A ... | Out-Null` is GONE from the capture step'
# SINGLE-quoted, like every other pattern in this file. It was double-quoted, so PowerShell
# interpolated `$wt` to empty and the pattern could not match the code it was meant to kill -- the
# assert passed against a file that still contained the commit swallow. A lock that passes against
# the bug is worse than no lock, and shipping one inside THIS ticket would have been the joke
# writing itself. Guarded below by W2b, which proves the pattern still matches the real thing.
Assert-False ([regex]::IsMatch($lib, '(?m)^\s*git -C \$wt -c user\.email=''agent@local''.*commit -m .* \| Out-Null')) 'W2 [kill] the swallowed `git commit ... | Out-Null` is GONE'
$w2Specimen = "        git -C `$wt -c user.email='agent@local' -c user.name='coding-agent' commit -m `"agent: `$Task`" 2>&1 | Out-Null"
Assert-True ([regex]::IsMatch($w2Specimen, '(?m)^\s*git -C \$wt -c user\.email=''agent@local''.*commit -m .* \| Out-Null')) 'W2b [meta] W2''s pattern DOES match the literal pre-#1074 commit swallow - proving W2 is a live assertion and not a vacuous one'
# W3 previously claimed "the unchecked rev-list-only assignment is GONE". Only the ASSIGNMENT moved;
# the unchecked-ness did not - the read still had no exit-code check. A lock asserting something
# untrue is worse than an absent lock, so it now asserts the property it was pretending to.
Assert-False ([regex]::IsMatch($lib, '\$hasChanges = \(git -C \$wt rev-list --count')) 'W3 [kill] $hasChanges is no longer assigned straight from rev-list (it is Resolve-CommitCapture''s verdict)'
Assert-True  ([regex]::IsMatch($lib, '(?m)^\s*\$rlRc = \$LASTEXITCODE')) 'W3b the rev-list read CHECKS its exit code (the third swallowed channel the ticket names)'
Assert-True  ([regex]::IsMatch($lib, '-CommitCountReadExitCode \$rlRc')) 'W3c ...and that exit code reaches the classifier'
Assert-True  ([regex]::IsMatch($lib, '(?m)^\s*\$addOut = \(git -C \$wt add -A 2>&1 \| Out-String\); \$addRc = \$LASTEXITCODE')) 'W4 the add step CAPTURES git''s output and CHECKS its exit code'
Assert-True  ([regex]::IsMatch($lib, '\$commitRc = \$LASTEXITCODE')) 'W5 the commit step checks its exit code'
Assert-True  ([regex]::IsMatch($lib, '(?m)^\s*if \(@\(\$stagedOut\)\.Count -gt 0\) \{')) 'W6 the commit is only ATTEMPTED with content staged -- the discrimination, wired in the real pipeline'
Assert-True  ([regex]::IsMatch($lib, '(?m)^\s*\$capture = Resolve-CommitCapture -AddExitCode \$addRc')) 'W7 Invoke-CandidateBuild classifies through the real Resolve-CommitCapture'
Assert-True  ([regex]::IsMatch($lib, 'GitFailed = \[bool\]\$gitFailed; GitError = "\$gitError"')) 'W8 the candidate result carries the fault + git''s message'
Assert-True  ([regex]::IsMatch($lib, 'GitFailed = \[bool\]\$Raw\.GitFailed')) 'W9 ConvertTo-CandidateResult re-hydrates it across the Start-Job boundary (the concurrent path)'
Assert-True  ([regex]::IsMatch($lib, '\$hasChanges -and -not \$cancelled -and -not \$gitFailed')) 'W10 the test + verify steps refuse to grade a build the box could not capture'
Assert-True  (([regex]::Matches($nat, '(?m)^\s*-StopSampling \{ [^\r\n]*-GitFailed')).Count -eq 0) 'W11 [kill] NEITHER best-of-N path passes a capture fault to the terminal classifier - one bad candidate workspace must not stop the whole run (the fault stays loud via IsWinner/rank/merge/review/report)'
Assert-True  (([regex]::Matches($nat, '(?m)^\s*-IsWinner \{ [^\r\n]*-GitFailed \(\[bool\]\$c\.GitFailed\)')).Count -eq 2)     'W12 BOTH paths refuse a capture-faulted candidate as a winner'
Assert-True  (([regex]::Matches($nat, '(?m)^\s*-ScoreCandidate \{ [^\r\n]*-GitFailed \(\[bool\]\$c\.GitFailed\)')).Count -eq 2) 'W13 BOTH paths sink a capture-faulted candidate in the rank'
Assert-True  ([regex]::IsMatch($nat, '-Ecosystems \(Get-ProjectEcosystem \$wt\) -GitFailed \$gitFailed')) 'W14 the merge decision receives the fault (hard block)'
Assert-True  ([regex]::IsMatch($nat, '(?m)^while \(\$hasChanges -and -not \$dispatchCancelled -and -not \$gitFailed')) 'W15 the review-FIX loop does not run over an uncaptured tree'
Assert-True  ([regex]::IsMatch($nat, '\$faultedCandidates = @\(\$bon\.Candidates \| Where-Object \{ \$_ -and \[bool\]\$_\.GitFailed \}\)')) 'W16 the report AGGREGATES faults over ALL candidates, not just the selected one (a fault must not vanish because a better candidate existed)'
Assert-True  ([regex]::IsMatch($nat, '(?m)^CHANGES: .*\$captureFaultNote')) 'W17 the aggregate note reaches the CHANGES line'
Assert-False ([regex]::IsMatch($lib, 'if \(\$GitFailed\)\s*\{ \$score \+= ')) 'W18 [kill] the aggregate did NOT come from raising a faulted candidate''s rank - a real attempt beating a faulted one is correct selection'

# ----------------------------------------------------------------------------
# RESULT
# ----------------------------------------------------------------------------
Section 'Result'
Write-Host ("  Passed: {0}" -f $script:Pass) -ForegroundColor Green
if ($script:Fail) {
    Write-Host ("  Failed: {0}" -f $script:Fail) -ForegroundColor Red
    Write-Host ''
    Write-Host '  GIT CAPTURE HONESTY: NOT VALIDATED - see the [FAIL] lines above:' -ForegroundColor Red
    $script:Failures | ForEach-Object { Write-Host "    - $_" -ForegroundColor Red }
    exit 1
} else {
    Write-Host ''
    Write-Host '  GIT CAPTURE HONESTY: VALIDATED. A failed git capture is an ERRORED task carrying git''s own message, never "the coder produced nothing."' -ForegroundColor Green
    exit 0
}
