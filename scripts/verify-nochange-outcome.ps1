#requires -Version 5.1
<#
.SYNOPSIS
  Verify and validate the fleet's "NO CHANGE NEEDED" honest-outcome capability (#1049 candidate b).

.DESCRIPTION
  Background (plain English):
    When a build attempt changes nothing, the fleet retries it - and a retry that
    implicitly DEMANDS a diff will get one. The measured incidents (the 2026-07-14
    seed run, docs/quality/dispatch-quality-ledger.md in the BlarAI repo): one wave
    scribbled a comment into the protected oracle file and another committed a scratch
    script then deleted it, both solely to satisfy the produced-changes detector.
    This change makes "no change needed" a FIRST-CLASS honest outcome:
      - the RETRY prompt (attempt 2+) explicitly permits replying
        "NO CHANGE NEEDED: <evidence>" and stopping without an edit;
      - a verified no-diff attempt carrying that declaration ENDS the retry loop
        (Invoke-BuildWithRetry) AND best-of-N sampling (Test-IsSamplingTerminal) -
        the answer was given; re-asking manufactures junk;
      - the report records the declaration honestly (NO-CHANGE DECLARED line + a
        fixed-vocabulary RESULT that still classifies NOTHING driver-side).
    Kill-switch: BLARAI_NO_CHANGE_ESCAPE=0/false/no/off restores the byte-identical
    legacy behaviour (the toggle-off proof below drives exactly that).

  This script proves the behaviour two ways, mirroring verify-retry.ps1:

    1. UNIT TESTS   (always run; no model / no OVMS; ~seconds) - drive the REAL
       policy functions with deterministic scripted fakes.
    2. DRY HARNESS  (always run; no model) - drive the REAL Invoke-CandidateBuild
       entry point against a throwaway git repo with a scripted stand-in for the
       coder driver, proving the escape prompt appears only on retries, the
       declaration terminates the loop, and the kill-switch restores legacy
       byte-identical control flow.

  Exit code 0 if everything passed, 1 if any check failed. Run it normally
  ( .\verify-nochange-outcome.ps1 ) - do NOT dot-source it.
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
    if ("$Haystack" -match $Pattern) { _pass $Msg } else { _fail "$Msg (no match for '$Pattern')" }
}
function Assert-NotMatch($Haystack, $Pattern, $Msg) {
    if ("$Haystack" -notmatch $Pattern) { _pass $Msg } else { _fail "$Msg (unexpected match for '$Pattern')" }
}

# ----------------------------------------------------------------------------
# U1: Test-NoChangeEscapeEnabled - the kill-switch resolution (pure)
# ----------------------------------------------------------------------------
Section 'Unit tests: kill-switch resolution (Test-NoChangeEscapeEnabled)'
Assert-True  (Test-NoChangeEscapeEnabled)                    'U1a unset/omitted -> ON (the shipped default)'
Assert-True  (Test-NoChangeEscapeEnabled -EnvValue '')       'U1b empty -> ON'
Assert-True  (Test-NoChangeEscapeEnabled -EnvValue '1')      'U1c "1" -> ON'
Assert-True  (Test-NoChangeEscapeEnabled -EnvValue 'banana') 'U1d unknown value -> ON (only the explicit off-words disable)'
Assert-False (Test-NoChangeEscapeEnabled -EnvValue '0')      'U1e "0" -> OFF'
Assert-False (Test-NoChangeEscapeEnabled -EnvValue 'false')  'U1f "false" -> OFF'
Assert-False (Test-NoChangeEscapeEnabled -EnvValue ' Off ')  'U1g " Off " (case/space) -> OFF'
Assert-False (Test-NoChangeEscapeEnabled -EnvValue 'no')     'U1h "no" -> OFF'

# ----------------------------------------------------------------------------
# U2: Add-NoChangeEscape - the retry-prompt escape block (pure)
# ----------------------------------------------------------------------------
Section 'Unit tests: escape prompt (Add-NoChangeEscape)'
$p0 = "Build the about section.`nKeep it offline."
$p1 = Add-NoChangeEscape -Prompt $p0
Assert-True ($p1.StartsWith($p0)) 'U2a original prompt preserved VERBATIM as the prefix (appended, never replaced)'
Assert-Match $p1 'NO CHANGE NEEDED:' 'U2b escape block names the exact declaration marker'
Assert-Match $p1 'WITHOUT editing any file' 'U2c escape block forbids manufactured edits'
Assert-Match $p1 '<one line of evidence' 'U2d escape block shows the evidence placeholder (the echo-guard anchor)'

# ----------------------------------------------------------------------------
# U3: Get-NoChangeDeclaration - transcript detection (fail-closed)
# ----------------------------------------------------------------------------
Section 'Unit tests: declaration detection (Get-NoChangeDeclaration)'
$tmpLog = Join-Path ([IO.Path]::GetTempPath()) ("nochange-verify-" + [guid]::NewGuid() + ".log")

$d = Get-NoChangeDeclaration -LogPath (Join-Path ([IO.Path]::GetTempPath()) 'no-such-file.log')
Assert-False $d.Declared 'U3a missing log -> NOT declared (fail-closed)'
$d = Get-NoChangeDeclaration -LogPath ''
Assert-False $d.Declared 'U3b empty path -> NOT declared'

Set-Content $tmpLog "reading files...`nNO CHANGE NEEDED: README.md already contains the requested section (verified lines 3-12)`n"
$d = Get-NoChangeDeclaration -LogPath $tmpLog
Assert-True $d.Declared 'U3c genuine declaration line -> declared'
Assert-Eq 'README.md already contains the requested section (verified lines 3-12)' $d.Evidence 'U3d evidence extracted verbatim'

# The transcript often ECHOES the prompt, whose instruction line contains the marker
# followed by the '<...>' placeholder - that alone must NEVER read as a declaration.
Set-Content $tmpLog (Add-NoChangeEscape -Prompt 'Build the about section.')
$d = Get-NoChangeDeclaration -LogPath $tmpLog
Assert-False $d.Declared 'U3e instruction echo alone (placeholder evidence) -> NOT declared'

Set-Content $tmpLog ((Add-NoChangeEscape -Prompt 'Build the about section.') + "`nthinking...`nNO CHANGE NEEDED: the about section exists in public/index.html`n")
$d = Get-NoChangeDeclaration -LogPath $tmpLog
Assert-True $d.Declared 'U3f echo + genuine line -> declared'
Assert-Eq 'the about section exists in public/index.html' $d.Evidence 'U3g the genuine evidence wins over the echo'

Set-Content $tmpLog "NO CHANGE NEEDED:`nNO CHANGE NEEDED:    `n"
$d = Get-NoChangeDeclaration -LogPath $tmpLog
Assert-False $d.Declared 'U3h marker with EMPTY evidence -> NOT declared (an evidence-free claim is refused)'

Set-Content $tmpLog "NO CHANGE NEEDED: first check`nlater...`nNO CHANGE NEEDED: final answer after full inspection`n"
$d = Get-NoChangeDeclaration -LogPath $tmpLog
Assert-Eq 'final answer after full inspection' $d.Evidence 'U3i LAST matching line wins (final reply outranks a mid-session mention)'

Set-Content $tmpLog ("> NO CHANGE NEEDED: quoted-reply form still counts`n")
$d = Get-NoChangeDeclaration -LogPath $tmpLog
Assert-True $d.Declared 'U3j "> "-quoted declaration line -> declared'

Set-Content $tmpLog ("NO CHANGE NEEDED: " + ('x' * 400) + "`n")
$d = Get-NoChangeDeclaration -LogPath $tmpLog
Assert-Eq 240 $d.Evidence.Length 'U3k evidence bounded to 240 chars (one report line)'

# --- F1: -Anchor scopes the probe to the CURRENT attempt on a SHARED transcript ---
# The live ACP driver (acp_coder.py) APPENDS every attempt into one $LogPath; the stdin
# driver TRUNCATES per attempt. The anchor (length + prefix SHA-256) tells the two apart.
Set-Content $tmpLog "attempt 1 chatter...`nNO CHANGE NEEDED: spontaneous attempt-1 marker`n"
$a1 = Get-TranscriptAnchor -LogPath $tmpLog
Add-Content $tmpLog "attempt 2 output with no declaration`n"
$d = Get-NoChangeDeclaration -LogPath $tmpLog -Anchor $a1
Assert-False $d.Declared 'U3l append shape: a marker BEFORE the anchor (attempt 1) is invisible to the scoped probe'
Add-Content $tmpLog "NO CHANGE NEEDED: attempt-2 declaration`n"
$d = Get-NoChangeDeclaration -LogPath $tmpLog -Anchor $a1
Assert-True $d.Declared 'U3m append shape: a declaration AFTER the anchor is seen'
Assert-Eq 'attempt-2 declaration' $d.Evidence 'U3m the scoped evidence is attempt 2''s, never attempt 1''s marker'
# Truncate shapes: (i) new content SHORTER than the anchor; (ii) new content LONGER than the
# anchor with the declaration inside the first anchor-length chars -- the case a naive length-
# only offset gets WRONG (it would slice mid-line into the current attempt's own text; the
# prefix HASH mismatch is what routes both shapes to whole-file scope).
Set-Content $tmpLog "NO CHANGE NEEDED: short fresh file`n"
$d = Get-NoChangeDeclaration -LogPath $tmpLog -Anchor $a1
Assert-True $d.Declared 'U3n truncate shape (shorter): whole file scoped - the declaration is found'
Set-Content $tmpLog ("NO CHANGE NEEDED: early declaration in a longer rewrite`n" + ("filler line`n" * 20))
$d = Get-NoChangeDeclaration -LogPath $tmpLog -Anchor $a1
Assert-True $d.Declared 'U3o truncate shape (LONGER rewrite): prefix-hash mismatch -> whole file scoped - the early declaration is found'
$d = Get-NoChangeDeclaration -LogPath $tmpLog
Assert-True $d.Declared 'U3p no anchor (default): whole-file behaviour unchanged (back-compat)'
Remove-Item $tmpLog -Force -ErrorAction SilentlyContinue

# ----------------------------------------------------------------------------
# U4: Test-IsSamplingTerminal - a declaration ends best-of-N sampling
# ----------------------------------------------------------------------------
Section 'Unit tests: sampling terminality (Test-IsSamplingTerminal -NoChangeDeclared)'
Assert-True  (Test-IsSamplingTerminal -TimedOut $false -SecretBlocked $false -NoChangeDeclared $true)  'U4a declared -> TERMINAL (a fresh candidate would re-ask an answered question)'
Assert-True  (Test-IsSamplingTerminal -TimedOut $true -TimeoutReason 'idle' -SecretBlocked $false -NoChangeDeclared $true) 'U4b declared dominates an idle timeout -> TERMINAL'
Assert-False (Test-IsSamplingTerminal -TimedOut $false -SecretBlocked $false -NoChangeDeclared $false) 'U4c not declared, clean run -> NOT terminal (legacy)'
Assert-False (Test-IsSamplingTerminal -TimedOut $true -TimeoutReason 'idle' -SecretBlocked $false)     'U4d param omitted -> byte-identical legacy (idle stays resample-eligible)'
Assert-True  (Test-IsSamplingTerminal -TimedOut $true -TimeoutReason 'ceiling' -SecretBlocked $false)  'U4e legacy ceiling timeout unchanged -> TERMINAL'
Assert-True  (Test-IsSamplingTerminal -TimedOut $false -SecretBlocked $true -NoChangeDeclared $false)  'U4f legacy secret unchanged -> TERMINAL'

# ----------------------------------------------------------------------------
# U5: Invoke-BuildWithRetry -NoChangeDeclared - the retry-policy change
# (scripted fakes; mirrors verify-retry.ps1's New-RetryFake pattern)
# ----------------------------------------------------------------------------
Section 'Unit tests: retry policy honours the declaration (Invoke-BuildWithRetry)'

function New-DeclFake {
    # $Plan: one entry per planned attempt: @{ Changed=[bool]; Declares=[bool] }.
    # Over-run tripwire like verify-retry's fake: more attempts than planned THROWS.
    param([object[]]$Plan, [System.Collections.ArrayList]$Probes)
    $state = [pscustomobject]@{ I = 0 }
    $RunAgent = {
        if ($state.I -ge $Plan.Count) { throw "over-ran: attempt $($state.I + 1) beyond the $($Plan.Count) planned" }
        @{ TimedOut = $false; ExitCode = 0 }
    }.GetNewClosure()
    $ProducedChanges = {
        $a = $Plan[$state.I]; $state.I++
        [bool]$a.Changed
    }.GetNewClosure()
    $NoChangeDeclared = {
        [void]$Probes.Add($state.I)   # record WHICH attempt was probed (1-based, post-increment)
        [bool]$Plan[$state.I - 1].Declares
    }.GetNewClosure()
    @{ RunAgent = $RunAgent; ProducedChanges = $ProducedChanges; NoChangeDeclared = $NoChangeDeclared }
}

# U5a: declared on attempt 2 -> stops at 2 of 3; the declaration is surfaced.
$probes = New-Object System.Collections.ArrayList
$f = New-DeclFake -Plan @(@{ Changed = $false; Declares = $false }, @{ Changed = $false; Declares = $true }) -Probes $probes
$r = Invoke-BuildWithRetry -RunAgent $f.RunAgent -ProducedChanges $f.ProducedChanges -NoChangeDeclared $f.NoChangeDeclared -MaxBuildAttempts 3
Assert-Eq 2 $r.Attempts             'U5a declared on attempt 2 -> loop STOPS at 2 (of max 3)'
Assert-True $r.NoChangeDeclared      'U5a declared -> surfaced in the result'
Assert-False $r.ProducedChanges      'U5a declared -> still honestly no changes'

# U5b: TOGGLE-OFF at the policy level - same plan, probe forced $false -> the legacy
# loop runs to the cap and the probe "fails" (NoChangeDeclared False). This is the
# revert proof: with the behaviour off, the U5a assertions above CANNOT pass.
$f2 = New-DeclFake -Plan @(@{ Changed = $false; Declares = $true }, @{ Changed = $false; Declares = $true }, @{ Changed = $false; Declares = $true }) -Probes (New-Object System.Collections.ArrayList)
$r2 = Invoke-BuildWithRetry -RunAgent $f2.RunAgent -ProducedChanges $f2.ProducedChanges -NoChangeDeclared { $false } -MaxBuildAttempts 3
Assert-Eq 3 $r2.Attempts            'U5b toggle-off (probe {$false}): runs to the cap - legacy control flow'
Assert-False $r2.NoChangeDeclared    'U5b toggle-off: no declaration surfaced'

# U5c: param OMITTED entirely -> byte-identical legacy default.
$f3 = New-DeclFake -Plan @(@{ Changed = $false; Declares = $true }, @{ Changed = $false; Declares = $true }, @{ Changed = $false; Declares = $true }) -Probes (New-Object System.Collections.ArrayList)
$r3 = Invoke-BuildWithRetry -RunAgent $f3.RunAgent -ProducedChanges $f3.ProducedChanges -MaxBuildAttempts 3
Assert-Eq 3 $r3.Attempts            'U5c param omitted: runs to the cap (byte-identical legacy)'
Assert-False $r3.NoChangeDeclared    'U5c param omitted: result still carries NoChangeDeclared=False (shape-stable)'

# U5d: a CHANGED attempt never consults the probe (a diff is graded normally).
$probes4 = New-Object System.Collections.ArrayList
$f4 = New-DeclFake -Plan @(@{ Changed = $true; Declares = $true }) -Probes $probes4
$r4 = Invoke-BuildWithRetry -RunAgent $f4.RunAgent -ProducedChanges $f4.ProducedChanges -NoChangeDeclared $f4.NoChangeDeclared -MaxBuildAttempts 3
Assert-Eq 1 $r4.Attempts            'U5d changed attempt -> one attempt, done'
Assert-Eq 0 $probes4.Count          'U5d changed attempt -> the declaration probe is NEVER consulted'
Assert-False $r4.NoChangeDeclared    'U5d changed attempt -> not a no-change outcome'

# U5e: declared on the FINAL attempt still surfaces (no extra attempt exists to stop).
$f5 = New-DeclFake -Plan @(@{ Changed = $false; Declares = $false }, @{ Changed = $false; Declares = $true }) -Probes (New-Object System.Collections.ArrayList)
$r5 = Invoke-BuildWithRetry -RunAgent $f5.RunAgent -ProducedChanges $f5.ProducedChanges -NoChangeDeclared $f5.NoChangeDeclared -MaxBuildAttempts 2
Assert-Eq 2 $r5.Attempts            'U5e declared at the cap: attempts = cap'
Assert-True $r5.NoChangeDeclared     'U5e declared at the cap: declaration still surfaced'

# ----------------------------------------------------------------------------
# D: DRY HARNESS - the REAL Invoke-CandidateBuild entry point, no model.
# A scripted stand-in replaces Invoke-CoderDriver (defined AFTER the dot-source,
# so name resolution picks it up); a throwaway git repo is the worktree.
# ----------------------------------------------------------------------------
Section 'Dry harness: REAL Invoke-CandidateBuild (fixture repo, scripted coder, no model)'

$scratch = Join-Path ([IO.Path]::GetTempPath()) ("nochange-harness-" + [guid]::NewGuid())
New-Item -ItemType Directory -Force $scratch | Out-Null
$repo = Join-Path $scratch 'fixture'
New-Item -ItemType Directory -Force $repo | Out-Null
git -C $repo init -b main 2>&1 | Out-Null
Set-Content (Join-Path $repo 'README.md') 'fixture repo for the no-change harness' -Encoding ascii
git -C $repo add -A 2>&1 | Out-Null
git -C $repo -c user.email='test@local' -c user.name='nochange-test' commit -m 'init' 2>&1 | Out-Null
$codeBase = "$(git -C $repo rev-parse HEAD)".Trim()

$script:CoderCalls = New-Object System.Collections.ArrayList
function Invoke-CoderDriver {
    # Scripted stand-in for the REAL coder driver (shadowing the dot-sourced definition;
    # Invoke-CandidateBuild resolves the name at call time). Makes NO changes; writes a
    # transcript that carries the declaration from call 2 onward - exactly the honest
    # already-satisfied shape the escape exists for.
    param([string]$WorkDir, [string]$Model, [string]$Prompt, [string]$LogPath,
          [int]$TimeoutSec, [int]$IdleTimeoutSec, [string]$ScriptRoot)
    [void]$script:CoderCalls.Add(@{ Prompt = $Prompt; LogPath = $LogPath })
    if ($script:CoderCalls.Count -ge 2) {
        Set-Content $LogPath "inspected the tree.`nNO CHANGE NEEDED: README.md already satisfies the task (verified against the request)`n"
    } else {
        Set-Content $LogPath "attempt finished without edits (printed a malformed tool call)`n"
    }
    return @{ TimedOut = $false; ExitCode = 0; TimeoutReason = ''; Capped = $false; CappedReason = ''; Seconds = 1; Error = '' }
}

# --- Case A: escape ON (default env) -> declaration terminates at attempt 2 ---
Remove-Item Env:\BLARAI_NO_CHANGE_ESCAPE -ErrorAction SilentlyContinue
$logA = Join-Path $scratch 'caseA.agent.log'
$resA = Invoke-CandidateBuild -ScriptRoot $PSScriptRoot -Worktree $repo -Model 'local/fake' -CodeBase $codeBase `
    -AttemptPrompt 'Add an about section to README.md' -LogPath $logA -Task 'nochange-caseA' -MaxBuildAttempts 3
Assert-Eq 2 $resA.BuildAttempts      'A1 declaration on the retry ends the loop at attempt 2 (of max 3) - one GPU attempt saved'
Assert-True $resA.NoChangeDeclared    'A2 result carries NoChangeDeclared=True'
Assert-Match $resA.NoChangeEvidence 'README\.md already satisfies' 'A3 result carries the coder''s evidence line'
Assert-False $resA.HasChanges         'A4 honestly no changes (nothing manufactured, nothing merged)'
Assert-Eq 2 $script:CoderCalls.Count 'A5 the coder ran exactly twice'
Assert-NotMatch $script:CoderCalls[0].Prompt 'NO CHANGE NEEDED' 'A6 attempt 1 prompt is BYTE-IDENTICAL legacy (no escape offered)'
Assert-Match $script:CoderCalls[1].Prompt 'NO CHANGE NEEDED:' 'A7 attempt 2 (retry) prompt OFFERS the escape'

# --- Case B: TOGGLE-OFF (BLARAI_NO_CHANGE_ESCAPE=0) -> byte-identical legacy ---
# The stand-in still writes the declaration into the transcript from call 2 onward,
# so this also proves the detector is GATED on the escape being offered - a marker
# in the log can never terminate a run whose prompt never offered the vocabulary.
$script:CoderCalls.Clear()
$env:BLARAI_NO_CHANGE_ESCAPE = '0'
try {
    $logB = Join-Path $scratch 'caseB.agent.log'
    $resB = Invoke-CandidateBuild -ScriptRoot $PSScriptRoot -Worktree $repo -Model 'local/fake' -CodeBase $codeBase `
        -AttemptPrompt 'Add an about section to README.md' -LogPath $logB -Task 'nochange-caseB' -MaxBuildAttempts 3
    Assert-Eq 3 $resB.BuildAttempts  'B1 toggle-off: the legacy loop runs to the cap (3 attempts) - the #1049 probe FAILS with the lock off'
    Assert-False $resB.NoChangeDeclared 'B2 toggle-off: no declaration honoured (despite the marker in the transcript)'
    Assert-Eq 3 $script:CoderCalls.Count 'B3 toggle-off: the coder ran all 3 times'
    Assert-NotMatch $script:CoderCalls[1].Prompt 'NO CHANGE NEEDED' 'B4 toggle-off: the retry prompt never offers the escape'
} finally {
    Remove-Item Env:\BLARAI_NO_CHANGE_ESCAPE -ErrorAction SilentlyContinue
}

# --- Cases C/D: the ACP ACCUMULATION shape (reviewer F1). The live ACP driver
# (tools/dispatch_harness/acp_coder.py, driver='acp' in configs/fleet-driver.json)
# opens the transcript in APPEND mode and every attempt shares ONE $LogPath -- so a
# spontaneous attempt-1 marker sits in the file when attempt 2's probe runs. The
# stand-in below APPENDS per call, mirroring exactly that writer shape (cases A/B
# mirrored the stdin truncate shape, which is why they could not see F1). ---
$script:CoderPlan = @()
function Invoke-CoderDriver {
    # Append-mode stand-in (replaces the truncate-mode one above for cases C/D).
    param([string]$WorkDir, [string]$Model, [string]$Prompt, [string]$LogPath,
          [int]$TimeoutSec, [int]$IdleTimeoutSec, [string]$ScriptRoot)
    [void]$script:CoderCalls.Add(@{ Prompt = $Prompt; LogPath = $LogPath })
    $i = $script:CoderCalls.Count - 1
    $content = if ($i -lt $script:CoderPlan.Count) { $script:CoderPlan[$i] } else { "attempt $($i + 1) output`n" }
    Add-Content -Path $LogPath -Value $content   # APPEND: the ACP transcript shape
    return @{ TimedOut = $false; ExitCode = 0; TimeoutReason = ''; Capped = $false; CappedReason = ''; Seconds = 1; Error = '' }
}

# Case C: attempt 1 spontaneously emits the marker (its prompt never offered the escape);
# attempts 2-3 declare nothing. The attempt-scoped probe must NOT fire. Pre-F1, the
# accumulated transcript satisfied attempt 2's probe and this run terminated early.
$script:CoderCalls.Clear()
Remove-Item Env:\BLARAI_NO_CHANGE_ESCAPE -ErrorAction SilentlyContinue
$script:CoderPlan = @(
    "attempt 1 chatter...`nNO CHANGE NEEDED: spontaneous attempt-1 marker that must never count`n",
    "attempt 2: inspected, produced nothing, declared nothing`n",
    "attempt 3: still nothing`n"
)
$logC = Join-Path $scratch 'caseC.agent.log'
$resC = Invoke-CandidateBuild -ScriptRoot $PSScriptRoot -Worktree $repo -Model 'local/fake' -CodeBase $codeBase `
    -AttemptPrompt 'Add an about section to README.md' -LogPath $logC -Task 'nochange-caseC' -MaxBuildAttempts 3
Assert-Match (Get-Content $logC -Raw) 'spontaneous attempt-1 marker' 'C1 the trap is REAL: the attempt-1 marker IS in the shared transcript when later probes run'
Assert-Eq 3 $resC.BuildAttempts      'C2 the attempt-scoped probe never fires on it - the loop runs all 3 attempts'
Assert-False $resC.NoChangeDeclared   'C3 no declaration honoured (attempt 1 was never offered the escape)'
Assert-NotMatch $script:CoderCalls[0].Prompt 'NO CHANGE NEEDED' 'C4 attempt 1 prompt indeed never offered the escape (the gating F1 protects)'

# Case D: same accumulation, but attempt 2 (escape offered) LEGITIMATELY declares ->
# still terminates at 2, and the evidence is attempt 2's line, never attempt 1's marker.
$script:CoderCalls.Clear()
$script:CoderPlan = @(
    "attempt 1 chatter...`nNO CHANGE NEEDED: spontaneous attempt-1 marker that must never count`n",
    "attempt 2: verified the request is already met.`nNO CHANGE NEEDED: attempt-2 legitimate declaration after inspection`n"
)
$logD = Join-Path $scratch 'caseD.agent.log'
$resD = Invoke-CandidateBuild -ScriptRoot $PSScriptRoot -Worktree $repo -Model 'local/fake' -CodeBase $codeBase `
    -AttemptPrompt 'Add an about section to README.md' -LogPath $logD -Task 'nochange-caseD' -MaxBuildAttempts 3
Assert-Eq 2 $resD.BuildAttempts      'D1 a legitimate attempt-2 declaration still terminates the loop at 2'
Assert-True $resD.NoChangeDeclared    'D2 the declaration is honoured'
Assert-Eq 'attempt-2 legitimate declaration after inspection' $resD.NoChangeEvidence 'D3 the evidence is attempt 2''s line, never the attempt-1 marker'

# cleanup (throwaway scratch)
Remove-Item -Recurse -Force -LiteralPath $scratch -ErrorAction SilentlyContinue

# ----------------------------------------------------------------------------
# W: WIRING - real (non-comment) lines in the production scripts invoke the new
# pieces (a substring in a comment must not pass; mirrors verify-retry U9/V10).
# ----------------------------------------------------------------------------
Section 'Wiring: the production scripts actually invoke the new pieces'
$lib = Get-Content "$PSScriptRoot\fleet-lib.ps1" -Raw
$nat = Get-Content "$PSScriptRoot\new-agent-task.ps1" -Raw
Assert-True ([regex]::IsMatch($lib, '(?m)^\s*-NoChangeDeclared \{ if \(\$escape\.active\)')) 'W1 Invoke-CandidateBuild wires the declaration probe into Invoke-BuildWithRetry (escape-gated)'
Assert-True ([regex]::IsMatch($lib, '(?m)^\s*-RunAgent \{ .*Invoke-CoderDriver .*Add-NoChangeEscape')) 'W2 the retry prompt rides Add-NoChangeEscape inside the RunAgent closure'
Assert-True ([regex]::IsMatch($lib, '(?m)^\s*-RunAgent \{ \$escape\.anchor = Get-TranscriptAnchor')) 'W6 (F1) the transcript anchor is captured BEFORE every attempt, inside the RunAgent closure'
Assert-True ([regex]::IsMatch($lib, '-Anchor \$escape\.anchor\)\.Declared')) 'W7 (F1) the declaration probe is attempt-scoped via the anchor'
Assert-True ([regex]::IsMatch($lib, '-Anchor \$escape\.anchor\)\.Evidence')) 'W8 (F1) the evidence read rides the SAME attempt scope the probe fired on'
Assert-True (([regex]::Matches($nat, '(?m)^\s*-StopSampling \{ [^\r\n]*-NoChangeDeclared \(\[bool\]\$c\.NoChangeDeclared\)')).Count -eq 2) 'W3 BOTH best-of-N paths (sequential + concurrent) pass -NoChangeDeclared to the terminal classifier'
Assert-True ([regex]::IsMatch($nat, '(?m)^RESULT: .*NO CHANGE NEEDED')) 'W4 the RESULT line carries the declared branch (fixed vocabulary; classifies NOTHING driver-side)'
Assert-True ([regex]::IsMatch($nat, 'NO-CHANGE DECLARED')) 'W5 the report carries the NO-CHANGE DECLARED evidence line'

# ----------------------------------------------------------------------------
# RESULT
# ----------------------------------------------------------------------------
Section 'Result'
Write-Host ("  Passed: {0}" -f $script:Pass) -ForegroundColor Green
if ($script:Fail) {
    Write-Host ("  Failed: {0}" -f $script:Fail) -ForegroundColor Red
    Write-Host ''
    Write-Host '  NO-CHANGE OUTCOME: NOT VALIDATED - see the [FAIL] lines above:' -ForegroundColor Red
    $script:Failures | ForEach-Object { Write-Host "    - $_" -ForegroundColor Red }
    exit 1
} else {
    Write-Host ''
    Write-Host '  NO-CHANGE OUTCOME: VALIDATED. "No change needed" is a first-class honest outcome.' -ForegroundColor Green
    exit 0
}
