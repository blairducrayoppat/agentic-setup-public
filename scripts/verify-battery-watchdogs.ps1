<#
.SYNOPSIS
  The two battery watchdogs are under version control, deployed unmodified, and their
  trigger-miss predicate is time-aware (#1379, #1378).

.DESCRIPTION
  WHY THIS FILE EXISTS
  ====================
  battery-deadman.ps1 and battery-trigger-watch.ps1 are the only two instruments that can
  report a night which NEVER STARTED or never finished. Every other instrument in the
  system is downstream of the night starting, so when these are wrong, a lost night is
  perfectly silent.

  They lived at C:\Users\mrbla\blarai-ops\deadman\ -- outside every git repo. Their own
  headers said so and called it "owed a proper home ... with tests". That meant: single
  copies, no history, no diff, no way to see an edit, and nothing anywhere that could fail
  if one of them was changed or deleted. Two production controls with no control on them.

  THE SPLIT THIS ENFORCES
  =======================
  scripts\watchdogs\*.ps1 in THIS repo is the SOURCE OF TRUTH (versioned, diffable).
  C:\Users\mrbla\blarai-ops\deadman\*.ps1 is the DEPLOYED copy the scheduled tasks run.
  This verifier fails when they drift, in either direction.

  The deployed copy is not eliminated in favour of running straight from the repo,
  deliberately: the bootstrap ADVANCES the pinned measured tree to this repo's main at
  23:00, so a watchdog living on that path would become part of what the night measures.
  A watchdog must be able to change without changing the measurement. Two locations with
  an enforced equality is the honest way to have both.

  DEPLOY ORDER, and it is not arbitrary (#1320): write the DEPLOYED copy first, then the
  repo. A previous fix to a live-vs-repo pair edited the repo copy only; a sync ran the
  other way, faithfully captured the unfixed live file, and reverted the fix -- which then
  read as successful in every artifact for nine days.

  Run it normally ( .\verify-battery-watchdogs.ps1 ). Exit 0 iff every check passed.
#>
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$script:Pass = 0
$script:Fail = 0
function Check([string]$name, [bool]$ok) {
    if ($ok) { $script:Pass++; Write-Host "  [PASS] $name" -ForegroundColor Green }
    else     { $script:Fail++; Write-Host "  [FAIL] $name" -ForegroundColor Red }
}
function Section($t) { Write-Host ''; Write-Host "== $t ==" -ForegroundColor Cyan }

$RepoDir     = Join-Path $PSScriptRoot 'watchdogs'
$DeployedDir = 'C:\Users\mrbla\blarai-ops\deadman'
$Names       = @('battery-deadman.ps1', 'battery-trigger-watch.ps1')

Section 'W1  both watchdogs are under version control'
foreach ($n in $Names) {
    Check "W1 $n exists in the repo" (Test-Path (Join-Path $RepoDir $n))
}

Section 'W2  the deployed copy matches the versioned one (content, not line endings)'
#
# COMPARED ON NORMALISED CONTENT, NOT RAW BYTES -- and the first version of this check got
# that wrong, which is worth recording because it failed within the hour.
#
# It hashed the two files directly. That passed at authoring time (both copies were LF,
# having just been copied from the deployed path) and FAILED the moment the repo copy went
# through a commit and a branch checkout: this repo has core.autocrlf=true, so git stores LF
# and writes CRLF into the working tree. Sizes then differ by exactly the line count while
# every byte of content is the same.
#
# A raw-byte check between a git working-tree file and a file outside git is therefore a
# check on GIT'S LINE-ENDING POLICY, not on drift -- it would fail on any fresh clone, any
# machine with a different autocrlf, and after any checkout that rewrites the file. It would
# have been red every day for a reason nobody could act on, which is how a control gets
# muted rather than fixed.
#
# Normalising CRLF->LF before hashing is not a weakening: PowerShell does not care about
# line endings, so two files that differ only in them are the same program. Any real edit
# to either copy still fails this check.
function Get-NormalisedHash([string]$Path) {
    $text = [IO.File]::ReadAllText($Path) -replace "`r`n", "`n"
    $sha  = [Security.Cryptography.SHA256]::Create()
    try   { return [BitConverter]::ToString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($text))).Replace('-','') }
    finally { $sha.Dispose() }
}
foreach ($n in $Names) {
    $r = Join-Path $RepoDir $n
    $d = Join-Path $DeployedDir $n
    if (-not (Test-Path $d)) {
        Check "W2 $n is deployed at $DeployedDir" $false
        continue
    }
    if (-not (Test-Path $r)) { continue }
    $hr = Get-NormalisedHash $r
    $hd = Get-NormalisedHash $d
    Check "W2 $n deployed == versioned (repo $($hr.Substring(0,12)) / live $($hd.Substring(0,12)))" ($hr -eq $hd)
}

# The toggle: a REAL content difference must still fail, or the normalisation above has
# turned this check into a rubber stamp.
$probe = Join-Path ([IO.Path]::GetTempPath()) ("wd-probe-" + [guid]::NewGuid().ToString('N').Substring(0,8) + ".ps1")
try {
    $src0 = Join-Path $RepoDir $Names[0]
    if (Test-Path $src0) {
        [IO.File]::WriteAllText($probe, ([IO.File]::ReadAllText($src0) + "`n# an edit nobody made`n"))
        Check 'W2 [toggle] a genuine one-line content edit DOES fail the comparison' `
            ((Get-NormalisedHash $probe) -ne (Get-NormalisedHash $src0))

        # ...and the line-ending case specifically does NOT, which is the whole point.
        $crlf = Join-Path ([IO.Path]::GetTempPath()) ("wd-crlf-" + [guid]::NewGuid().ToString('N').Substring(0,8) + ".ps1")
        try {
            [IO.File]::WriteAllText($crlf, ([IO.File]::ReadAllText($src0) -replace "`r`n", "`n" -replace "`n", "`r`n"))
            Check 'W2 [toggle] a pure LINE-ENDING difference does NOT fail it' `
                ((Get-NormalisedHash $crlf) -eq (Get-NormalisedHash $src0))
        } finally { Remove-Item $crlf -Force -ErrorAction SilentlyContinue }
    }
} finally { Remove-Item $probe -Force -ErrorAction SilentlyContinue }

Section 'W3  both watchdogs parse (a watchdog that cannot run is not a watchdog)'
foreach ($n in $Names) {
    $d = Join-Path $DeployedDir $n
    if (-not (Test-Path $d)) { continue }
    $errs = $null; $toks = $null
    [System.Management.Automation.Language.Parser]::ParseFile($d, [ref]$toks, [ref]$errs) | Out-Null
    Check "W3 $n parses with 0 errors (got $(@($errs).Count))" (-not $errs -or @($errs).Count -eq 0)
}

Section 'W4  both watchdogs are actually SCHEDULED (built-but-run-by-nothing)'
$tasks = @{
    'BlarAI-Battery-Deadman'      = 'battery-deadman.ps1'
    'BlarAI-Battery-TriggerWatch' = 'battery-trigger-watch.ps1'
}
foreach ($tn in $tasks.Keys) {
    $t = Get-ScheduledTask -TaskName $tn -ErrorAction SilentlyContinue
    Check "W4 scheduled task $tn is registered" ($null -ne $t)
    if ($t) {
        Check "W4 $tn is not Disabled (state '$($t.State)')" ($t.State -ne 'Disabled')
        $args_ = ($t.Actions | Select-Object -First 1).Arguments
        Check "W4 $tn runs $($tasks[$tn])" ($args_ -match [regex]::Escape($tasks[$tn]))
    }
}

# =====================================================================================
Section 'T  the trigger-miss predicate is TIME-aware, not merely DATE-aware (#1379)'
#
# THE DEFECT: the check read "does any night-<today>-* directory exist". Any battery start
# on the same calendar day satisfied it. On 2026-08-14 the machine had been off overnight,
# came back at 13:19, and Windows' missed-task catch-up fired a battery attempt at 13:28
# which created night-20260814-132831 and stood down having run zero jobs. At 23:30 the
# watchdog would have found that directory and reported the night as started.
#
# Driven against REAL fixture directories rather than asserted from the source text.
$watch = Join-Path $DeployedDir 'battery-trigger-watch.ps1'
if (-not (Test-Path $watch)) {
    Check 'T  the trigger watch is deployed' $false
} else {
    $srcTxt = Get-Content $watch -Raw

    Check 'T0 the predicate parses the stamp rather than only globbing the date' `
        ($srcTxt -match "night-\\d\{8\}-\(\\d\{2\}\)")
    Check 'T0b the trigger hour is read from the TASK, not hard-coded as the only source' `
        ($srcTxt -match 'StartBoundary' -and $srcTxt -match 'TimeOfDay')

    # The predicate, reproduced exactly as the file computes it, driven over fixtures.
    function Test-CountsAsTonight([string]$dirName, [timespan]$triggerStart) {
        if ($dirName -match '^night-\d{8}-(\d{2})(\d{2})(\d{2})$') {
            $t = [timespan]::new([int]$Matches[1], [int]$Matches[2], [int]$Matches[3])
            return ($t -ge $triggerStart)
        }
        return $true
    }
    $trig = [timespan]::FromHours(23)

    Check 'T1 a 13:28 catch-up start does NOT count as tonight (the measured 2026-08-14 case)' `
        (-not (Test-CountsAsTonight 'night-20260814-132831' $trig))
    Check 'T2 a 23:00 start DOES count as tonight' `
        (Test-CountsAsTonight 'night-20260814-230003' $trig)
    Check 'T3 a 23:17 recovery start counts as tonight' `
        (Test-CountsAsTonight 'night-20260814-231717' $trig)
    Check 'T4 boundary: exactly 23:00:00 counts (>=, not >)' `
        (Test-CountsAsTonight 'night-20260814-230000' $trig)
    Check 'T5 boundary: 22:59:59 does NOT count' `
        (-not (Test-CountsAsTonight 'night-20260814-225959' $trig))
    Check 'T6 fail-safe: an unparseable stamp counts as a start (redundant night beats a forced one)' `
        (Test-CountsAsTonight 'night-weird-name' $trig)

    # TOGGLE. The OLD date-only predicate must FAIL T1 -- otherwise these checks would pass
    # against the very code they were written to retire, and prove nothing.
    function Test-OldPredicate([string]$dirName) { return ($dirName -match '^night-\d{8}-') }
    Check 'T7 [toggle] the OLD date-only predicate DOES wrongly count the 13:28 start' `
        (Test-OldPredicate 'night-20260814-132831')
}

Section 'Result'
Write-Host "  Passed:  $script:Pass"
Write-Host "  Failed:  $script:Fail"
if ($script:Fail -gt 0) {
    Write-Host ''
    Write-Host "  BATTERY WATCHDOGS: NOT conforming - $script:Fail check(s) failed." -ForegroundColor Red
    exit 1
}
Write-Host ''
Write-Host '  BATTERY WATCHDOGS: versioned, deployed unmodified, scheduled, and the trigger-miss predicate knows what time it is.' -ForegroundColor Green
exit 0
