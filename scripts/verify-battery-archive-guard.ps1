<#
.SYNOPSIS
  Locks shut the permanent-wedge class in the archive guard's journal scan (#1380).

.DESCRIPTION
  THE DEFECT THIS LOCKS SHUT
  ==========================
  LOCK 2 of the battery's archive guard refuses to archive a job's sandbox while a prior
  fleet run still owns it. It decides ownership from the run's journal: more TASK-START
  than TASK-END means "a dispatch is still building there".

  That predicate is a PROPERTY OF A FILE NOBODY REWRITES. A run killed mid-task never
  writes its last TASK-END, so its journal stays unbalanced forever and the guard blocks
  every later night on that repo -- permanently, because the scan looks at the newest 12
  run directories and only the battery creates new ones. The guard blocks the only thing
  that could clear it.

  Measured twice:
    * 2026-08-11 -- run 20260810-230238-bd, 8 TASK-START / 7 TASK-END after an unclean
      shutdown. Cleared BY HAND (journal renamed, REAPED.txt written).
    * 2026-08-12 -- run 20260811-232102-bd, 5 TASK-START / 4 TASK-END after a forced
      Windows Update restart at 03:29 killed it mid-task. NOT cleared by hand, because
      nobody was watching. It stood the battery down on 08-12, 08-13 and 08-14 and would
      have stood down every night after.

  #1360 had already added one escape: swap-progress.log containing "14B is back", the
  swap driver's terminal record. That escape asks the dying run to testify to its own
  death, so it is unavailable in exactly the deaths that leave no testimony -- power loss,
  a forced restart, a hard reset. It cleared the budget-kill case it was written against
  and could never have cleared either case above.

  THE FIX THIS TESTS
  ==================
  A second exculpation that does not depend on the run being well enough to speak: if the
  MACHINE BOOTED after the run last wrote anything, every process of that run is gone, and
  none has written since. A reboot is proof of death that survives the death.

  This is BETTER EVIDENCE, NOT A LOOSER GUARD, and the toggles below are what make that
  claim checkable rather than asserted: every case that clears is paired with a case that
  BLOCKS on the same fixture with the new evidence withheld.

  HOW IT TESTS
  ============
  Get-BlockingRunOwner is extracted from run-battery-night.ps1 BY AST and run in an
  isolated scope, so these assertions exercise the shipped text rather than a paraphrase
  of it. Fixtures are real directories with real files and real mtimes under a temp root;
  boot times are injected as a parameter, which is the only reason the reboot case can be
  tested at all on a box that has not just rebooted.

  Section R additionally drives the function against the REAL state/fleet-runs tree, so a
  green result here is not only a statement about fixtures.

  Run it normally ( .\verify-battery-archive-guard.ps1 ) - do NOT dot-source it.
  Exit 0 iff every check passed.
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

# ---- extract the shipped function by AST -------------------------------------------
$src = Join-Path $PSScriptRoot 'run-battery-night.ps1'
if (-not (Test-Path $src)) { Write-Host "run-battery-night.ps1 not found beside this script" -ForegroundColor Red; exit 1 }
$errors = $null; $tokens = $null
$ast = [System.Management.Automation.Language.Parser]::ParseFile($src, [ref]$tokens, [ref]$errors)
if ($errors -and $errors.Count -gt 0) {
    Write-Host "run-battery-night.ps1 does not parse ($($errors.Count) error(s)) - refusing to test a broken file" -ForegroundColor Red
    exit 1
}
$fn = $ast.FindAll({ param($n)
    $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'Get-BlockingRunOwner'
}, $true) | Select-Object -First 1
if (-not $fn) {
    Write-Host "Get-BlockingRunOwner is GONE from run-battery-night.ps1 - the lock this file tests no longer exists" -ForegroundColor Red
    exit 1
}

# Write-Log is a dependency of the extracted function. A capturing stub lets the tests
# assert on WHICH exculpation fired, not merely that something cleared -- two different
# reasons reaching the same verdict is exactly how a guard rots into a rubber stamp.
$script:LogLines = New-Object System.Collections.Generic.List[string]
function Write-Log([string]$msg) { $script:LogLines.Add($msg) | Out-Null }
. ([scriptblock]::Create($fn.Extent.Text))

# ---- fixture helper ----------------------------------------------------------------
$root = Join-Path ([IO.Path]::GetTempPath()) ("archive-guard-" + [guid]::NewGuid().ToString('N').Substring(0,8))
New-Item -ItemType Directory -Force $root | Out-Null
$REPO = 'C:\Users\mrbla\projects\battery-b9-pottery-site'

function New-RunFixture {
    param(
        [Parameter(Mandatory)][string]$FleetRuns,
        [Parameter(Mandatory)][string]$RunId,
        [int]$Starts = 1,
        [int]$Ends = 1,
        [string]$RepoInJournal = $REPO,
        [switch]$SwapBack,
        [datetime]$WrittenAt = (Get-Date)
    )
    $d = Join-Path $FleetRuns $RunId
    New-Item -ItemType Directory -Force $d | Out-Null
    $lines = @()
    for ($i = 0; $i -lt $Starts; $i++) { $lines += "TASK-START task$i repo=$RepoInJournal" }
    for ($i = 0; $i -lt $Ends;   $i++) { $lines += "TASK-END task$i outcome=processed" }
    $jl = Join-Path $d 'journal.log'
    Set-Content -LiteralPath $jl -Value ($lines -join "`n") -Encoding utf8
    if ($SwapBack) {
        Set-Content -LiteralPath (Join-Path $d 'swap-progress.log') -Value "swap complete; the 14B is back" -Encoding utf8
    }
    # mtimes are the subject of the boot predicate, so they are set explicitly rather than
    # inherited from however long the test took to run.
    Get-ChildItem $d -File -Recurse | ForEach-Object { $_.LastWriteTime = $WrittenAt }
    return $d
}
function New-FleetRoot([string]$name) {
    $p = Join-Path $root $name
    New-Item -ItemType Directory -Force $p | Out-Null
    return $p
}

$LONG_AGO   = (Get-Date).AddDays(-3)
$BOOT_AFTER = (Get-Date).AddDays(-1)   # boot AFTER the run wrote  -> provably dead
$BOOT_BEFORE= (Get-Date).AddDays(-5)   # boot BEFORE the run wrote -> no reboot evidence

try {
    # ---- A. the lock still BLOCKS what it is for ------------------------------------
    Section 'A  the guard blocks a run that may still be building'

    $fr = New-FleetRoot 'A'
    New-RunFixture -FleetRuns $fr -RunId '20260811-232102-bd' -Starts 5 -Ends 4 -WrittenAt $LONG_AGO | Out-Null
    $r = Get-BlockingRunOwner -FleetRunsDir $fr -RepoPath $REPO -BootTime $BOOT_BEFORE
    Check 'A1 unbalanced journal, no swap-back, no reboot since -> BLOCKS' ($null -ne $r)
    Check 'A2 the descriptor names the blocking run' ($null -ne $r -and $r.RunId -eq '20260811-232102-bd')
    Check 'A3 the descriptor carries the real counts' ($null -ne $r -and $r.Starts -eq 5 -and $r.Ends -eq 4)
    Check 'A4 Why is unbalanced-journal' ($null -ne $r -and $r.Why -eq 'unbalanced-journal')

    $fr = New-FleetRoot 'A2'
    New-RunFixture -FleetRuns $fr -RunId '20260811-232102-bd' -Starts 4 -Ends 4 -WrittenAt $LONG_AGO | Out-Null
    $r = Get-BlockingRunOwner -FleetRunsDir $fr -RepoPath $REPO -BootTime $BOOT_BEFORE
    Check 'A5 [toggle] a BALANCED journal does not block' ($null -eq $r)

    # ---- B. the reboot exculpation, and its toggle -----------------------------------
    Section 'B  the boot predicate (#1380) - clears a provably-dead run, and only that'

    $fr = New-FleetRoot 'B'
    New-RunFixture -FleetRuns $fr -RunId '20260811-232102-bd' -Starts 5 -Ends 4 -WrittenAt $LONG_AGO | Out-Null
    $script:LogLines.Clear()
    $r = Get-BlockingRunOwner -FleetRunsDir $fr -RepoPath $REPO -BootTime $BOOT_AFTER
    Check 'B1 machine booted AFTER the run last wrote -> CLEARS' ($null -eq $r)
    Check 'B2 and it says WHY, naming the reboot' (@($script:LogLines | Where-Object { $_ -match 'BOOTED' }).Count -eq 1)

    $r = Get-BlockingRunOwner -FleetRunsDir $fr -RepoPath $REPO -BootTime $BOOT_BEFORE
    Check 'B3 [toggle] same fixture, boot BEFORE the last write -> BLOCKS' ($null -ne $r)

    $r = Get-BlockingRunOwner -FleetRunsDir $fr -RepoPath $REPO
    Check 'B4 [toggle] an UNKNOWN boot time (default MinValue) clears nothing' ($null -ne $r)

    # The boundary matters: equal timestamps must NOT clear. A run that wrote at the same
    # instant the box booted is not evidence of anything, and `-gt` is the whole predicate.
    $fr = New-FleetRoot 'B5'
    $exact = (Get-Date).AddHours(-6)
    New-RunFixture -FleetRuns $fr -RunId '20260811-232102-bd' -Starts 5 -Ends 4 -WrittenAt $exact | Out-Null
    $r = Get-BlockingRunOwner -FleetRunsDir $fr -RepoPath $REPO -BootTime $exact
    Check 'B5 boundary: boot == last write does NOT clear' ($null -ne $r)

    # ---- C. the #1360 exculpation still works ----------------------------------------
    Section 'C  the swap-back record (#1360) is untouched by this change'

    $fr = New-FleetRoot 'C'
    New-RunFixture -FleetRuns $fr -RunId '20260809-154357-bd' -Starts 4 -Ends 3 -SwapBack -WrittenAt $LONG_AGO | Out-Null
    $script:LogLines.Clear()
    $r = Get-BlockingRunOwner -FleetRunsDir $fr -RepoPath $REPO -BootTime $BOOT_BEFORE
    Check 'C1 unbalanced but swap-back COMPLETED -> CLEARS with no reboot evidence' ($null -eq $r)
    Check 'C2 and it says so, naming the swap-back not the reboot' (@($script:LogLines | Where-Object { $_ -match 'swap-back' }).Count -eq 1)

    $fr = New-FleetRoot 'C3'
    New-RunFixture -FleetRuns $fr -RunId '20260809-154357-bd' -Starts 4 -Ends 3 -WrittenAt $LONG_AGO | Out-Null
    $r = Get-BlockingRunOwner -FleetRunsDir $fr -RepoPath $REPO -BootTime $BOOT_BEFORE
    Check 'C3 [toggle] same fixture WITHOUT the swap-back marker -> BLOCKS' ($null -ne $r)

    # ---- D. scoping: the guard is per-REPO -------------------------------------------
    Section 'D  a run that owns a DIFFERENT repo is not this job''s problem'

    $fr = New-FleetRoot 'D'
    New-RunFixture -FleetRuns $fr -RunId '20260811-232102-bd' -Starts 5 -Ends 4 `
                   -RepoInJournal 'C:\Users\mrbla\projects\battery-b5-habit-web' -WrittenAt $LONG_AGO | Out-Null
    $r = Get-BlockingRunOwner -FleetRunsDir $fr -RepoPath $REPO -BootTime $BOOT_BEFORE
    Check 'D1 journal naming another repo does not block this one' ($null -eq $r)

    $r = Get-BlockingRunOwner -FleetRunsDir $fr -RepoPath 'C:\Users\mrbla\projects\battery-b5-habit-web' -BootTime $BOOT_BEFORE
    Check 'D2 [toggle] the same fixture DOES block the repo it names' ($null -ne $r)

    # ---- E. degenerate inputs never throw --------------------------------------------
    Section 'E  it never throws - a guard that throws inside its own scan is not a guard'

    $threw = $false
    try { $r = Get-BlockingRunOwner -FleetRunsDir (Join-Path $root 'does-not-exist') -RepoPath $REPO -BootTime $BOOT_BEFORE } catch { $threw = $true }
    Check 'E1 a missing fleet-runs dir returns null, does not throw' ((-not $threw) -and $null -eq $r)

    $fr = New-FleetRoot 'E2'
    New-Item -ItemType Directory -Force (Join-Path $fr '20260811-232102-bd') | Out-Null
    $threw = $false
    try { $r = Get-BlockingRunOwner -FleetRunsDir $fr -RepoPath $REPO -BootTime $BOOT_BEFORE } catch { $threw = $true }
    Check 'E2 a run dir with no journal is skipped, does not throw' ((-not $threw) -and $null -eq $r)

    $fr = New-FleetRoot 'E3'
    $d = Join-Path $fr '20260811-232102-bd'
    New-Item -ItemType Directory -Force $d | Out-Null
    # GENUINELY zero bytes. This used `Set-Content -Value '' -Encoding utf8`, which writes a
    # UTF-8 BOM plus a CRLF -- FIVE bytes, measured -- so `Get-Content -Raw` returned "`r`n",
    # `-not $txt` was FALSE, and the empty-journal branch this check is named after was NEVER
    # REACHED. It passed via the repo-mismatch `continue` further down instead: the right
    # verdict for the wrong reason, which is indistinguishable from a real pass in the output.
    [IO.File]::WriteAllBytes((Join-Path $d 'journal.log'), @())
    Check 'E3 the fixture is genuinely zero bytes (the check above was reaching the wrong branch)' `
        ((Get-Item (Join-Path $d 'journal.log')).Length -eq 0)
    $threw = $false
    try { $r = Get-BlockingRunOwner -FleetRunsDir $fr -RepoPath $REPO -BootTime $BOOT_BEFORE } catch { $threw = $true }
    Check 'E3 an EMPTY journal is skipped, does not throw' ((-not $threw) -and $null -eq $r)

    # A NORMAL fixture must not throw either. E1-E3 cover only degenerate inputs, so a
    # regex/parse fault on the ordinary path would surface as an uncaught crash rather than a
    # failed assertion -- and a crash landing after some checks prints a misleading
    # "Passed: n / Failed: 0". The docstring promises "Never throws"; this is the check that
    # holds it to that on the path every real night takes.
    $fr = New-FleetRoot 'E4'
    New-RunFixture -FleetRuns $fr -RunId '20260811-232102-bd' -Starts 5 -Ends 4 -WrittenAt $LONG_AGO | Out-Null
    $threw = $false; $why = ''
    try { $null = Get-BlockingRunOwner -FleetRunsDir $fr -RepoPath $REPO -BootTime $BOOT_BEFORE }
    catch { $threw = $true; $why = $_.Exception.Message }
    Check "E4 a NORMAL fixture does not throw$(if ($threw) { " (threw: $why)" })" (-not $threw)

    # ---- M. the fixture must be able to KILL the two dangerous mutations ---------------
    Section 'M  newest-not-oldest, and recursive - the two mutations the first fixture missed'
    #
    # FOUND IN REVIEW, not by this suite (#1380). Every fixture above stamps all its files
    # with ONE mtime and creates no subdirectories, so two mutations of the production code
    # passed all 22 checks:
    #   * take the OLDEST file instead of the newest
    #   * drop -Recurse
    # Both move the answer in the DANGEROUS direction -- they make the run look like it
    # stopped writing earlier than it did, so a boot time that should NOT clear it does.
    # Uniform mtimes make oldest and newest the same value, and a flat directory makes
    # -Recurse a no-op, so the fixture could not tell a correct implementation from either.
    # The real spread in the three wedged run dirs is 3-8 hours, so this is not academic.
    #
    # This fixture is built so that the correct implementation and each mutation give
    # OPPOSITE verdicts:
    #   journal.log      at T-10h   (oldest, top level)
    #   nested\late.log  at T-1h    (newest, in a SUBDIRECTORY)
    #   BootTime         at T-5h    (between them)
    # correct (newest, recursive): newest T-1h > boot T-5h  -> BLOCKS
    # mutant  (oldest):            oldest T-10h < boot T-5h -> clears   <- caught
    # mutant  (no -Recurse):       newest seen T-10h < boot -> clears   <- caught
    $fr = New-FleetRoot 'M'
    $d  = New-RunFixture -FleetRuns $fr -RunId '20260811-232102-bd' -Starts 5 -Ends 4 -WrittenAt (Get-Date).AddHours(-10)
    New-Item -ItemType Directory -Force (Join-Path $d 'nested') | Out-Null
    $late = Join-Path $d 'nested\late.log'
    Set-Content -LiteralPath $late -Value 'a later write, in a subdirectory' -Encoding utf8
    (Get-Item $late).LastWriteTime = (Get-Date).AddHours(-1)
    $bootMid = (Get-Date).AddHours(-5)

    $r = Get-BlockingRunOwner -FleetRunsDir $fr -RepoPath $REPO -BootTime $bootMid
    Check 'M1 the newest write is in a SUBDIR and is later than boot -> BLOCKS' ($null -ne $r)

    # The kill-tests: reimplement each mutation over the same fixture and prove it gives the
    # OPPOSITE answer. If a mutation agreed with the real function here, this fixture would
    # be as blind as the last one.
    $files = @(Get-ChildItem $d -File -Recurse)
    $newestRec = ($files | Sort-Object LastWriteTime -Descending | Select-Object -First 1).LastWriteTime
    $oldestRec = ($files | Sort-Object LastWriteTime | Select-Object -First 1).LastWriteTime
    $newestFlat = (@(Get-ChildItem $d -File) | Sort-Object LastWriteTime -Descending | Select-Object -First 1).LastWriteTime

    Check 'M2 [kill] the OLDEST-file mutant would CLEAR this fixture (so M1 detects it)' `
        (($bootMid -gt $oldestRec) -and -not ($bootMid -gt $newestRec))
    Check 'M3 [kill] the no--Recurse mutant would CLEAR this fixture (so M1 detects it)' `
        (($bootMid -gt $newestFlat) -and -not ($bootMid -gt $newestRec))
    Check 'M4 the fixture genuinely has a spread (oldest != newest)' ($oldestRec -ne $newestRec)
    Check 'M5 the newest file is genuinely nested (flat scan sees an earlier one)' ($newestFlat -lt $newestRec)

    # ---- F. the scan window ----------------------------------------------------------
    Section 'F  the newest-N window is real, and is why this wedged permanently'

    $fr = New-FleetRoot 'F'
    # One blocking run, then 12 newer harmless ones -> pushed out of the window.
    New-RunFixture -FleetRuns $fr -RunId '20260101-000000-bd' -Starts 5 -Ends 4 -WrittenAt $LONG_AGO | Out-Null
    1..12 | ForEach-Object {
        New-RunFixture -FleetRuns $fr -RunId ("2026020{0}-000000-bd" -f $_) -Starts 1 -Ends 1 -WrittenAt $LONG_AGO | Out-Null
    }
    $r = Get-BlockingRunOwner -FleetRunsDir $fr -RepoPath $REPO -BootTime $BOOT_BEFORE
    Check 'F1 a blocking run outside the newest-12 window is not seen' ($null -eq $r)

    $r = Get-BlockingRunOwner -FleetRunsDir $fr -RepoPath $REPO -BootTime $BOOT_BEFORE -Window 13
    Check 'F2 [toggle] widening the window to 13 finds it again' ($null -ne $r -and $r.RunId -eq '20260101-000000-bd')

    # ---- G. THE SCAN KEEPS LOOKING -----------------------------------------------------
    Section 'G  every `continue` is a promise to keep scanning - one blocker, hidden behind each'
    #
    # FOUND BY MUTATION TESTING (#1380, 2026-08-14). Nine of fourteen mutations survived the
    # 31-check suite, and every survivor was FAIL-OPEN: the guard cleared while a genuinely
    # blocking run existed. The cause was one structural gap, not nine separate oversights.
    #
    # Get-BlockingRunOwner has SIX `continue` statements -- no journal, empty journal, other
    # repo, balanced journal, swap-back exculpation, boot exculpation. Each one is a promise
    # that the scan KEEPS LOOKING at older run dirs. Turning any of them into `return $null`
    # makes the guard stop at the first uninteresting directory and report the tree clean.
    #
    # Every fixture above except F is a SINGLE-DIRECTORY tree, so no `continue` had anywhere
    # to continue TO, and all six promises were vacuous. F is multi-dir but its twelve newer
    # runs are all balanced 1/1, so they exit at the same one. Section R drives the real tree
    # and is order-insensitive only by accident: the wedge is currently the NEWEST directory,
    # so R blocks on iteration 1 -- and that changes meaning the next time the battery creates
    # a run dir, which is to say tomorrow.
    #
    # The shape that kills them: TWO directories, where the NEWEST is exculpated by the
    # mechanism under test and an OLDER one must still block. Correct code walks past the
    # first and blocks on the second; a `return $null` mutant clears.
    function New-TwoDirTree {
        param([Parameter(Mandatory)][string]$Name, [scriptblock]$MakeNewest)
        $fr = New-FleetRoot $Name
        # Names sort descending, so 9-prefixed is scanned FIRST.
        & $MakeNewest $fr
        # The blocker: older, unbalanced, no swap-back, written AFTER the boot time these
        # cases use -- so nothing can exculpate it and the correct answer is always BLOCK.
        New-RunFixture -FleetRuns $fr -RunId '20260101-000001-bd' -Starts 5 -Ends 4 -WrittenAt $LONG_AGO | Out-Null
        return $fr
    }
    $BOOT_G = (Get-Date).AddDays(-5)   # BEFORE $LONG_AGO (-3d), so the blocker is never cleared

    # G1 - newest cleared by the BOOT predicate (kills: exculpation-2 continue -> return)
    $fr = New-TwoDirTree 'G1' { param($p)
        New-RunFixture -FleetRuns $p -RunId '20260901-999999-bd' -Starts 3 -Ends 2 -WrittenAt (Get-Date).AddDays(-9) | Out-Null }
    $r = Get-BlockingRunOwner -FleetRunsDir $fr -RepoPath $REPO -BootTime $BOOT_G
    Check 'G1 newest cleared by REBOOT -> the scan continues and blocks on the older run' `
        ($null -ne $r -and $r.RunId -eq '20260101-000001-bd')

    # G2 - newest cleared by the SWAP-BACK record (kills: exculpation-1 continue -> return)
    $fr = New-TwoDirTree 'G2' { param($p)
        New-RunFixture -FleetRuns $p -RunId '20260901-999999-bd' -Starts 3 -Ends 2 -SwapBack -WrittenAt $LONG_AGO | Out-Null }
    $r = Get-BlockingRunOwner -FleetRunsDir $fr -RepoPath $REPO -BootTime $BOOT_G
    Check 'G2 newest cleared by SWAP-BACK -> the scan continues and blocks on the older run' `
        ($null -ne $r -and $r.RunId -eq '20260101-000001-bd')

    # G3 - newest has NO journal (kills: missing-journal continue -> return)
    $fr = New-TwoDirTree 'G3' { param($p)
        New-Item -ItemType Directory -Force (Join-Path $p '20260901-999999-bd') | Out-Null }
    $r = Get-BlockingRunOwner -FleetRunsDir $fr -RepoPath $REPO -BootTime $BOOT_G
    Check 'G3 newest has NO journal -> the scan continues and blocks on the older run' `
        ($null -ne $r -and $r.RunId -eq '20260101-000001-bd')

    # G4 - newest has a genuinely EMPTY journal (kills: empty-journal continue -> return)
    $fr = New-TwoDirTree 'G4' { param($p)
        $d = Join-Path $p '20260901-999999-bd'
        New-Item -ItemType Directory -Force $d | Out-Null
        [IO.File]::WriteAllBytes((Join-Path $d 'journal.log'), @()) }
    $r = Get-BlockingRunOwner -FleetRunsDir $fr -RepoPath $REPO -BootTime $BOOT_G
    Check 'G4 newest journal is EMPTY -> the scan continues and blocks on the older run' `
        ($null -ne $r -and $r.RunId -eq '20260101-000001-bd')

    # G5 - newest names ANOTHER repo (kills: repo-mismatch continue -> return)
    $fr = New-TwoDirTree 'G5' { param($p)
        New-RunFixture -FleetRuns $p -RunId '20260901-999999-bd' -Starts 3 -Ends 2 `
            -RepoInJournal 'C:\Users\mrbla\projects\battery-b5-habit-web' -WrittenAt $LONG_AGO | Out-Null }
    $r = Get-BlockingRunOwner -FleetRunsDir $fr -RepoPath $REPO -BootTime $BOOT_G
    Check 'G5 newest names ANOTHER repo -> the scan continues and blocks on the older run' `
        ($null -ne $r -and $r.RunId -eq '20260101-000001-bd')

    # G6 - newest is BALANCED (kills: balanced continue -> return; F2 held this alone)
    $fr = New-TwoDirTree 'G6' { param($p)
        New-RunFixture -FleetRuns $p -RunId '20260901-999999-bd' -Starts 3 -Ends 3 -WrittenAt $LONG_AGO | Out-Null }
    $r = Get-BlockingRunOwner -FleetRunsDir $fr -RepoPath $REPO -BootTime $BOOT_G
    Check 'G6 newest is BALANCED -> the scan continues and blocks on the older run' `
        ($null -ne $r -and $r.RunId -eq '20260101-000001-bd')

    # G7 - the WINDOW DEFAULT is 12, and nothing pinned it. F2 passes -Window 13 explicitly
    # and F1 passes under any window that excludes the blocker, so the default was
    # unconstrained all the way down to 1. Here the blocker is directory #2, so a default of
    # 1 would miss it. Called with NO -Window on purpose.
    $fr = New-TwoDirTree 'G7' { param($p)
        New-RunFixture -FleetRuns $p -RunId '20260901-999999-bd' -Starts 3 -Ends 3 -WrittenAt $LONG_AGO | Out-Null }
    $r = Get-BlockingRunOwner -FleetRunsDir $fr -RepoPath $REPO -BootTime $BOOT_G
    Check 'G7 the DEFAULT window reaches at least the 2nd directory (default of 1 would miss it)' `
        ($null -ne $r -and $r.RunId -eq '20260101-000001-bd')

    # G8 - HIDDEN files make $newest $null, and `$BootTime -gt $null` is TRUE.
    # `Get-ChildItem -File -Recurse` without -Force skips hidden files, while Test-Path and
    # Get-Content still read them -- so a run dir can have a readable journal and no visible
    # file at all. Without the `$null -ne $newest` conjunct the boot branch then fires on a
    # null and clears. No other fixture can produce this state.
    $fr = New-FleetRoot 'G8'
    $d8 = New-RunFixture -FleetRuns $fr -RunId '20260811-232102-bd' -Starts 5 -Ends 4 -WrittenAt $LONG_AGO
    Get-ChildItem $d8 -File -Recurse | ForEach-Object { $_.Attributes = $_.Attributes -bor [IO.FileAttributes]::Hidden }
    $visible = @(Get-ChildItem $d8 -File -Recurse).Count
    Check 'G8 the fixture genuinely hides its files from a non--Force enumeration' ($visible -eq 0)
    $r = Get-BlockingRunOwner -FleetRunsDir $fr -RepoPath $REPO -BootTime (Get-Date)
    Check 'G8 an unreadable newest-write does NOT clear the run (null is not "older than boot")' `
        ($null -ne $r)

    # G9 - the swap-back marker means the swap COMPLETED. A log that merely mentions the 14B
    # mid-swap ("stopping the 14B to load the 30B") is an in-progress record, not a terminal
    # one, and must not exculpate. Fixture C's text contains the full marker, so any shortened
    # substring matched it and the terminal-record semantics were pinned by nothing.
    $fr = New-FleetRoot 'G9'
    $d9 = New-RunFixture -FleetRuns $fr -RunId '20260811-232102-bd' -Starts 5 -Ends 4 -WrittenAt $LONG_AGO
    Set-Content -LiteralPath (Join-Path $d9 'swap-progress.log') -Value 'stopping the 14B to load the 30B' -Encoding utf8
    Get-ChildItem $d9 -File -Recurse | ForEach-Object { $_.LastWriteTime = $LONG_AGO }
    $r = Get-BlockingRunOwner -FleetRunsDir $fr -RepoPath $REPO -BootTime $BOOT_G
    Check 'G9 a swap log that MENTIONS the 14B mid-swap does not count as a completed swap-back' `
        ($null -ne $r)

    # ---- N. the CALL SITE's null-safety ------------------------------------------------
    Section 'N  a null boot time must not become an uncaught throw at the call site'
    #
    # FOUND IN REVIEW (#1380), before it ever ran. The call site wraps Get-CimInstance in
    # try/catch, which defends against it THROWING -- not against the instance coming back
    # WITHOUT the property. An absent property reads as $null with no exception, and
    # -BootTime $null then fails PARAMETER BINDING, which is an uncaught throw inside a
    # top-level foreach with no enclosing try. It would exit straight over Write-SkipReport,
    # Write-AdmissionRecord and the LEG A teardown: the exact bare-throw harm this change
    # exists to remove, one line above the fix.
    $threw = $false
    try { $null = Get-BlockingRunOwner -FleetRunsDir $root -RepoPath $REPO -BootTime $null } catch { $threw = $true }
    Check 'N1 the premise holds: -BootTime $null DOES throw (so the guard is load-bearing)' $threw

    $callSite = Get-Content $src -Raw
    Check 'N2 the call site normalises a null boot time before binding it' `
        ($callSite -match '\$null\s+-eq\s+\$bootTime')
    Check 'N3 it normalises to MinValue, which clears nothing (fail-closed)' `
        ($callSite -match '(?s)\$null\s+-eq\s+\$bootTime.{0,400}\[datetime\]::MinValue')
    Check 'N4 the null case is LOGGED, not silently swallowed' `
        ($callSite -match '(?s)\$null\s+-eq\s+\$bootTime.{0,400}Write-Log')

    # ---- R. the REAL tree ------------------------------------------------------------
    Section 'R  driven against the real state\fleet-runs, not only fixtures'

    $realFleet = 'C:\Users\mrbla\agentic-setup\state\fleet-runs'
    if (-not (Test-Path $realFleet)) {
        Write-Host "  [SKIP] R  no real fleet-runs tree on this box" -ForegroundColor Yellow
    } else {
        $realBoot = (Get-CimInstance Win32_OperatingSystem).LastBootUpTime
        $r = Get-BlockingRunOwner -FleetRunsDir $realFleet -RepoPath $REPO -BootTime $realBoot
        Check 'R1 the real tree does not block tonight''s B9 sandbox' ($null -eq $r)

        # THE TOGGLE THAT MATTERS. With the boot evidence withheld, the real tree must
        # still block -- that is what proves R1 was cleared BY THE NEW PREDICATE and not
        # by the wedge having quietly gone away on its own.
        $r = Get-BlockingRunOwner -FleetRunsDir $realFleet -RepoPath $REPO
        Check 'R2 [toggle] with the boot evidence withheld, the real tree BLOCKS' ($null -ne $r)
        if ($null -ne $r) {
            Write-Host "         (the real wedge: run $($r.RunId), $($r.Starts) starts / $($r.Ends) ends)" -ForegroundColor DarkGray
        }
    }
}
finally {
    Remove-Item $root -Recurse -Force -ErrorAction SilentlyContinue
}

Section 'Result'
Write-Host "  Passed:  $script:Pass"
Write-Host "  Failed:  $script:Fail"
if ($script:Fail -gt 0) {
    Write-Host ''
    Write-Host "  ARCHIVE GUARD: NOT conforming - $script:Fail check(s) failed." -ForegroundColor Red
    exit 1
}
Write-Host ''
Write-Host "  ARCHIVE GUARD: the journal scan blocks a live owner, clears a provably-dead one, and says which." -ForegroundColor Green
exit 0
