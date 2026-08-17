#requires -Version 7.0
<#
.SYNOPSIS
  Verify the battery night owns and releases the Assistant Orchestrator (AO) it runs
  on, and that the admission gate it feeds is actually reachable (2026-07-20).

.DESCRIPTION
  THE TWO DEFECTS THIS LOCKS SHUT
  ===============================
  1. AO LEAK. Three paths boot a `python -m launcher` during a night (this launcher's
     Ensure-AoHeadless, the runner's per-job AoReensurer, the swap driver's swap-back
     relaunch after every job) and NOTHING stopped any of them. The 2026-07-19 night's
     last relaunch (PID 3468, 00:13:39) held the resident 14B - 11.63 GB - for 9.5
     hours, orphaned: its spawning driver had already exited.
  2. DEAD ADMISSION GATE. Write-Log used Write-Output (the SUCCESS stream), so a log
     call inside a value-returning function was captured into that function's return
     value. Test-NightAdmission therefore returned @("<log string>", $false) - a
     2-element array, which PowerShell coerces TRUE - so `while (-not
     (Test-NightAdmission))` never entered. The gate, the 30-minute retry and the 04:00
     skip were unreachable, and every `lean preflight:` GiB number was swallowed
     instead of reaching the transcript.

  STRUCTURE (AST + static - the invariants):
    A1  run-battery-night.ps1 dot-sources ao-ownership-lib.ps1 and reaches BOTH legs
        (Invoke-StaleAoOwnerReclaim + Stop-OwnedAo).
    A2  every ownership entry point is inside an `if (-not $Now)` guard - a manual
        daytime run never tears down the operator's assistant.
    A3  the kill is NOT hand-rolled: neither file contains taskkill / Stop-Process
        aimed at a launcher, and the stop is delegated to stop-assistant.ps1.
    A4  ORDERING - the stale-claim reclaim precedes Measure-SwapHeadroom, so the RAM
        it frees counts toward the admission gate it feeds.
    A5  the end-of-night teardown is guarded by the ownership flag and runs AFTER the
        morning report is written.
    A6  Write-Log does NOT use Write-Output (the defect-2 lock, made structural).
    A7  both 04:00 skip paths write a skip report (a skipped night is never silent).

  BEHAVIOR (live - REAL functions from the REAL files, fixture processes only, never
  the real launcher / OVMS / GPU):
    B1  the REAL Write-Log + Measure-SwapHeadroom + Test-NightAdmission, extracted
        from run-battery-night.ps1 by AST and driven in a starved world, return a
        genuine [bool] $false - so `-not` is $true and the retry loop RUNS.
    B2  [kill-test for B1] the same three functions with Write-Log reverted to
        Write-Output return a truthy ARRAY - proving B1 fails if the fix is undone.
    B3  the REAL Stop-OwnedAo tree-kills a confirmed `-m launcher` decoy and clears
        the sentinel (the teardown actually happens).
    B4  [kill-test for B3] the REAL Invoke-StaleAoOwnerReclaim with NO sentinel leaves
        the same decoy ALIVE - the ownership guard blocks an unowned teardown.
    B5  a sentinel naming the CURRENT night is not stale: the decoy survives.
    B6  a sentinel naming an EARLIER night IS stale: the decoy is reclaimed.

  Run it normally ( .\verify-battery-ao-lifecycle.ps1 ) - do NOT dot-source it.
  Exit 0 iff every check passes.
#>
param()
$ErrorActionPreference = 'Stop'

$script:Pass = 0
$script:Fail = 0
function Check([string]$name, [bool]$ok) {
    if ($ok) { $script:Pass++; Write-Host "  [PASS] $name" -ForegroundColor Green }
    else     { $script:Fail++; Write-Host "  [FAIL] $name" -ForegroundColor Red }
}
function Section($t) { Write-Host ''; Write-Host "== $t ==" -ForegroundColor Cyan }

$launcher = Join-Path $PSScriptRoot 'run-battery-night.ps1'
$ownerLib = Join-Path $PSScriptRoot 'ao-ownership-lib.ps1'
$stopAsst = Join-Path $PSScriptRoot 'stop-assistant.ps1'
Check "run-battery-night.ps1 exists" (Test-Path $launcher)
Check "ao-ownership-lib.ps1 exists"  (Test-Path $ownerLib)
Check "stop-assistant.ps1 exists (the audited stop seam this reuses)" (Test-Path $stopAsst)

# A0 - PARSE FIRST. ParseFile is error-TOLERANT: it returns a usable AST even for a
# file PowerShell would refuse to run, so every A-check below can pass green on a
# launcher that dies at startup tonight. This caught a real one during the 2026-07-20
# build: `$Stamp:` in the skip-report heading parsed as a scope qualifier and broke the
# whole file while all 45 other checks still passed. Assert runnability before
# asserting anything about the code's shape.
Section 'A0  the files PowerShell will actually run parse cleanly'
foreach ($f in @(@{n='run-battery-night.ps1'; p=$launcher}, @{n='ao-ownership-lib.ps1'; p=$ownerLib})) {
    $perrs = $null
    [void][System.Management.Automation.Language.Parser]::ParseFile($f.p, [ref]$null, [ref]$perrs)
    $n = @($perrs).Count
    Check "A0 $($f.n) parses with 0 errors (got $n)" ($n -eq 0)
    if ($n -gt 0) { @($perrs) | Select-Object -First 3 | ForEach-Object { Write-Host "        $($_.Extent.StartLineNumber): $($_.Message)" -ForegroundColor DarkRed } }
}

$ast = [System.Management.Automation.Language.Parser]::ParseFile($launcher, [ref]$null, [ref]$null)
$src = Get-Content $launcher -Raw
$libSrc = Get-Content $ownerLib -Raw
$CommandAst = [System.Management.Automation.Language.CommandAst]
$FuncAst    = [System.Management.Automation.Language.FunctionDefinitionAst]
$IfAst      = [System.Management.Automation.Language.IfStatementAst]

function Get-Calls($tree, [string]$name) {
    return @($tree.FindAll({ param($n) $n -is $CommandAst -and $n.GetCommandName() -eq $name }, $true))
}
function Test-InsideNotNowGuard($node) {
    # True iff $node is lexically enclosed by an `if (-not $Now) { ... }` clause body.
    $p = $node.Parent
    while ($p) {
        if ($p -is $IfAst) {
            foreach ($clause in $p.Clauses) {
                if ($clause.Item1.Extent.Text -match '-not\s+\$Now' -and
                    $clause.Item2.Extent.StartOffset -lt $node.Extent.StartOffset -and
                    $clause.Item2.Extent.EndOffset -ge $node.Extent.EndOffset) { return $true }
            }
        }
        $p = $p.Parent
    }
    return $false
}

# ===========================================================================
Section 'A1  both ownership legs are wired into the night'
Check "A1 dot-sources ao-ownership-lib.ps1" ($src -match 'ao-ownership-lib\.ps1')
$reclaimCalls = Get-Calls $ast 'Invoke-AoPreflightReclaim'
$stopCalls    = Get-Calls $ast 'Stop-OwnedAo'
$claimCalls   = Get-Calls $ast 'Set-AoOwner'
Check "A1 LEG B: Invoke-AoPreflightReclaim called exactly once (got $($reclaimCalls.Count))" ($reclaimCalls.Count -eq 1)
Check "A1 the claim (Set-AoOwner) is made exactly once (got $($claimCalls.Count))" ($claimCalls.Count -eq 1)
Check "A1 LEG A: at least one Stop-OwnedAo teardown exists (got $($stopCalls.Count))" ($stopCalls.Count -ge 1)

# ---------------------------------------------------------------------------
# A1p  THE PROPERTY, replacing the arity proxy (#1332, fixed 2026-08-14).
#
# This assertion used to read `$stopCalls.Count -eq 3`, and the note above it recorded
# that the count was a PROXY on its THIRD false alarm. #1380's archive-guard stand-down
# was the FOURTH: a correct edit that adds a legitimate exit path made three assertions
# in this file report a defect, while A7's own arity had been silently WRONG on main for
# some time (it asserted 2 against a real 8) -- the failure mode of a count is that it is
# equally loud when it is right and when it is stale, so nobody can tell which.
#
# What those three assertions were all reaching for is ONE property:
#
#     every path that EXITS the script after the AO could have been claimed must
#       (a) write a skip report   -- else the operator's morning read shows LAST night,
#       (b) record admission      -- else the night leaves no provenance,
#       (c) tear down an owned AO -- else the 14B stays resident (#1045, measured
#           12.33 GB on 2026-08-11 and 11.66 GB on 2026-08-14).
#
# Asserted directly below by walking the AST, so a new stand-down path is checked for
# being CORRECT instead of being counted. Adding a fourth, fifth or tenth exit is now
# free; adding one that forgets its teardown is a failure.
$claimAssign = $ast.FindAll({ param($n)
    $n -is [System.Management.Automation.Language.AssignmentStatementAst] -and
    $n.Left.Extent.Text -eq '$AoOwnedByThisNight' -and $n.Right.Extent.Text -match '\$true'
}, $true) | Select-Object -First 1
Check "A1p the AO claim flag is raised somewhere (the anchor this property hangs on)" ($null -ne $claimAssign)

function Get-PostClaimStandDowns([System.Management.Automation.Language.Ast]$Root, [int]$AfterOffset) {
    # Every `exit 0` after $AfterOffset, paired with the statement block enclosing it.
    $exits = $Root.FindAll({ param($n)
        $n -is [System.Management.Automation.Language.ExitStatementAst]
    }, $true) | Where-Object { $_.Extent.StartOffset -gt $AfterOffset }
    $out = @()
    foreach ($e in $exits) {
        $blk = $e.Parent
        while ($blk -and $blk -isnot [System.Management.Automation.Language.StatementBlockAst]) { $blk = $blk.Parent }
        if ($blk) { $out += [pscustomobject]@{ Line = $e.Extent.StartLineNumber; Text = $blk.Extent.Text } }
    }
    return $out
}

if ($claimAssign) {
    $standDowns = @(Get-PostClaimStandDowns $ast $claimAssign.Extent.EndOffset)
    Check "A1p there is at least one post-claim exit to check (an empty set must never read as a pass)" ($standDowns.Count -ge 1)
    foreach ($sd in $standDowns) {
        $hasSkip  = $sd.Text -match 'Write-SkipReport'
        $hasAdm   = $sd.Text -match 'Write-AdmissionRecord'
        $hasStop  = $sd.Text -match 'Stop-OwnedAo'
        $guarded  = $sd.Text -match '\$AoOwnedByThisNight'
        Check "A1p exit at line $($sd.Line) writes a skip report"            $hasSkip
        Check "A1p exit at line $($sd.Line) records admission provenance"    $hasAdm
        Check "A1p exit at line $($sd.Line) tears down an owned AO"          $hasStop
        Check "A1p exit at line $($sd.Line) guards the teardown on ownership" $guarded
    }

    # TOGGLE. The walker must FAIL a stand-down that forgets an obligation -- otherwise
    # the checks above are a pass that cannot fail, which is the exact defect the coder's
    # own definition-of-done (capability 4) forbids in a delivered exam.
    $bad = [System.Management.Automation.Language.Parser]::ParseInput(@'
$AoOwnedByThisNight = $true
if ($whatever) {
    Write-SkipReport "stood down"
    Write-AdmissionRecord 'skipped-something'
    Stop-Transcript | Out-Null; exit 0
}
'@, [ref]$null, [ref]$null)
    $badClaim = $bad.FindAll({ param($n)
        $n -is [System.Management.Automation.Language.AssignmentStatementAst] -and
        $n.Left.Extent.Text -eq '$AoOwnedByThisNight'
    }, $true) | Select-Object -First 1
    $badSd = @(Get-PostClaimStandDowns $bad $badClaim.Extent.EndOffset)
    Check "A1p [toggle] the walker FINDS a stand-down that omits Stop-OwnedAo" `
        ($badSd.Count -ge 1 -and ($badSd[0].Text -notmatch 'Stop-OwnedAo'))
}

Section 'A2  every ownership entry point is scoped to the scheduled night (-not $Now)'
# The reclaim and the claim are guarded DIRECTLY. Re-wrap each: PowerShell unwraps a
# single-element array on return, so these may be bare CommandAst objects.
foreach ($c in (@($reclaimCalls) + @($claimCalls))) {
    Check "A2 $($c.GetCommandName()) at line $($c.Extent.StartLineNumber) is inside an `if (-not `$Now)` guard" `
        (Test-InsideNotNowGuard $c)
}
# The teardown is guarded TRANSITIVELY: it fires on $AoOwnedByThisNight (asserted by
# A5), and that flag is only ever RAISED inside the -not $Now branch. Assert the whole
# path rather than the call site - a direct -not $Now check on the teardown would fail
# on correct code, and dropping the check entirely would leave the -Now scoping
# unlocked. Every assignment that sets the flag TRUE must be night-scoped; an
# initialiser to $false is safe anywhere.
$AssignAst = [System.Management.Automation.Language.AssignmentStatementAst]
$flagSets = @($ast.FindAll({ param($n) $n -is $AssignAst -and
                             $n.Left.Extent.Text -eq '$AoOwnedByThisNight' }, $true))
Check "A2 the ownership flag is assigned at least twice (a `$false initialiser + the claim)" ($flagSets.Count -ge 2)
foreach ($a in $flagSets) {
    $setsTrue = $a.Right.Extent.Text -match '(?i)\$true'
    if (-not $setsTrue) {
        Check "A2 `$AoOwnedByThisNight = $($a.Right.Extent.Text) at line $($a.Extent.StartLineNumber) is a false-initialiser (safe unguarded)" $true
        continue
    }
    Check "A2 `$AoOwnedByThisNight is RAISED at line $($a.Extent.StartLineNumber) only inside an `if (-not `$Now)` guard" `
        (Test-InsideNotNowGuard $a)
}

Section 'A3  the kill is delegated to the audited seam, never hand-rolled'
foreach ($pair in @(@{n='run-battery-night.ps1'; s=$src}, @{n='ao-ownership-lib.ps1'; s=$libSrc})) {
    Check "A3 $($pair.n) contains no taskkill" (-not ($pair.s -match '(?i)\btaskkill\b'))
    Check "A3 $($pair.n) never kills by the '-m launcher' marker itself" (-not ($pair.s -match "Stop-Process[^\r\n]*launcher"))
}
Check "A3 the stop is delegated to stop-assistant.ps1" (($libSrc -match 'StopAssistantPath') -and ($src -match 'stop-assistant\.ps1'))
Check "A3 ao-ownership-lib.ps1 calls no Stop-Process at all" (-not ($libSrc -match '(?i)\bStop-Process\b'))
# The launcher DOES use Stop-Process - but only to lean firefox/OneDrive, never the AO.
$leanKills = Get-Calls $ast 'Stop-Process'
$leanOk = $true
foreach ($k in $leanKills) {
    $fn = $k.Parent; while ($fn -and -not ($fn -is $FuncAst)) { $fn = $fn.Parent }
    if (-not $fn -or $fn.Name -ne 'Measure-SwapHeadroom') { $leanOk = $false }
}
Check "A3 every Stop-Process in the launcher is the firefox/OneDrive lean (inside Measure-SwapHeadroom)" $leanOk

Section 'A4  ORDERING: the reclaim frees RAM before the gate measures it'
if ($reclaimCalls.Count -eq 1) {
    $firstReclaim = @($reclaimCalls)[0]
    $measureCalls = Get-Calls $ast 'Measure-SwapHeadroom'
    Check "A4 Measure-SwapHeadroom is called (got $($measureCalls.Count) site(s))" ($measureCalls.Count -ge 1)
    $firstMeasure = (@($measureCalls) | Sort-Object { $_.Extent.StartOffset } | Select-Object -First 1)
    Check "A4 the stale-claim reclaim (line $($firstReclaim.Extent.StartLineNumber)) precedes the first Measure-SwapHeadroom (line $($firstMeasure.Extent.StartLineNumber))" `
        ($firstReclaim.Extent.StartOffset -lt $firstMeasure.Extent.StartOffset)
}

Section 'A5  the teardown is ownership-guarded and runs after the morning report'
# The END-OF-NIGHT teardown is the last one in the file; the others are stand-down paths.
#
# `-ge 1`, NOT `-eq 2`. This guard USED to be an equality, and #1334 added a third teardown
# (the live-dispatch stand-down) — which did not fail this section, it SILENTLY SKIPPED it,
# taking both checks below with it and still reporting green. A count used as an assertion
# is a false alarm; a count used as a GATE is silent coverage loss, which is strictly worse
# and is what happened here. Caught only by diffing the total check count against main.
# Selecting the LAST call by offset is what actually identifies the end-of-night teardown,
# and that holds for any number of stand-down paths.
$a5Ran = $false
if ($stopCalls.Count -ge 1) {
    $a5Ran = $true
    $stop = (@($stopCalls) | Sort-Object { $_.Extent.StartOffset } | Select-Object -Last 1)
    $guarded = $false
    $p = $stop.Parent
    while ($p) {
        if ($p -is $IfAst) {
            foreach ($clause in $p.Clauses) {
                if ($clause.Item1.Extent.Text -match '\$AoOwnedByThisNight' -and
                    $clause.Item2.Extent.EndOffset -ge $stop.Extent.EndOffset) { $guarded = $true }
            }
        }
        $p = $p.Parent
    }
    Check "A5 Stop-OwnedAo is guarded by the `$AoOwnedByThisNight ownership flag" $guarded
    $reportIdx = $src.IndexOf('morning report written.')
    Check "A5 the teardown runs AFTER the morning report is written" `
        (($reportIdx -ge 0) -and ($stop.Extent.StartOffset -gt $reportIdx))
}
# THE THIRD ANSWER (lesson 330): "did not run" must not be indistinguishable from "passed".
# A5's checks live behind a conditional, so the section asserts its own execution.
Check "A5 the section actually RAN (a skipped section must never read as a pass)" $a5Ran

Section 'A6  Write-Log cannot pollute a return value (the dead-gate lock)'
$writeLogFn = @($ast.FindAll({ param($n) $n -is $FuncAst -and $n.Name -eq 'Write-Log' }, $true))
Check "A6 Write-Log is defined exactly once (got $($writeLogFn.Count))" ($writeLogFn.Count -eq 1)
if ($writeLogFn.Count -eq 1) {
    $body = @($writeLogFn)[0].Body.Extent.Text
    Check "A6 Write-Log does NOT use Write-Output (it would be captured as a return value)" `
        (-not ($body -match '(?i)\bWrite-Output\b'))
    Check "A6 Write-Log writes to the host stream (Write-Host), which Start-Transcript still captures" `
        ($body -match '(?i)\bWrite-Host\b')
}

Section 'A8  the night records HOW it was admitted and WHO booted the AO'
# The 2026-07-19 hole: Ensure-AoHeadless wrote ao-boot.log only in its boot branch, so a
# probe-admitted night (the probe restores the AO itself) left NO boot log -- while
# FIELD_NOTES tells the reader to check that very file for the night's topology.
$ensureFn = @($ast.FindAll({ param($n) $n -is $FuncAst -and $n.Name -eq 'Ensure-AoHeadless' }, $true))
Check "A8 Ensure-AoHeadless is defined exactly once (got $($ensureFn.Count))" ($ensureFn.Count -eq 1)
if ($ensureFn.Count -eq 1) {
    $efn = @($ensureFn)[0]
    $provCalls = @($efn.FindAll({ param($n) $n -is $CommandAst -and
                                 $n.GetCommandName() -eq 'Write-AoBootProvenance' }, $true))
    Check "A8 Ensure-AoHeadless records provenance on BOTH branches (got $($provCalls.Count), need >= 2)" `
        ($provCalls.Count -ge 2)
    # One inside the `if (-not $aoUp)` boot branch, one in the else -- the else is the leg
    # that was silent. Locate that if-statement and check both clause bodies.
    $aoUpIf = @($efn.FindAll({ param($n) $n -is $IfAst -and $n.Clauses[0].Item1.Extent.Text -match '\$aoUp' }, $true))
    Check "A8 the `$aoUp branch exists (got $($aoUpIf.Count))" ($aoUpIf.Count -eq 1)
    if ($aoUpIf.Count -eq 1) {
        $ifs = @($aoUpIf)[0]
        $inThen = @($ifs.Clauses[0].Item2.FindAll({ param($n) $n -is $CommandAst -and
                        $n.GetCommandName() -eq 'Write-AoBootProvenance' }, $true)).Count
        $inElse = 0
        if ($ifs.ElseClause) {
            $inElse = @($ifs.ElseClause.FindAll({ param($n) $n -is $CommandAst -and
                            $n.GetCommandName() -eq 'Write-AoBootProvenance' }, $true)).Count
        }
        Check "A8 the BOOT branch records provenance (got $inThen)" ($inThen -ge 1)
        Check "A8 the ALREADY-UP else branch records provenance too - the 07-19 hole (got $inElse)" ($inElse -ge 1)
    }
    # The native boot call must not leak stdout into the success stream: Ensure-AoHeadless
    # is called from INSIDE Test-NightAdmission, so a bare `& $Python ...` would poison
    # that function's return value exactly as Write-Output did.
    Check "A8 the boot call is redirected, not bare (no success-stream leak into Test-NightAdmission)" `
        ($efn.Extent.Text -match '(?s)&\s+\$Python\s+-c\s+\$bootPy.{0,120}?(\|\s*\r?\n?\s*ForEach-Object|\|\s*Out-Null)')
}
Check "A8 the post-probe call site is context-tagged (an already-up AO is attributed to the probe restore)" `
    ($src -match "Ensure-AoHeadless\s+-Context\s+'post-probe'")

Section 'A9  admission.json is written on every exit'
$recCalls = Get-Calls $ast 'Write-AdmissionRecord'
# Arity retired in favour of A1p's property walk (#1332). A count of admission records is
# not the thing that matters; "every exit leaves provenance" is, and A1p asserts it per
# exit. What survives here is the floor and the OUTCOME coverage below, which a count
# cannot give: an admission record that never names the memory skip is wrong at any arity.
Check "A9 Write-AdmissionRecord is called at all (got $($recCalls.Count))" ($recCalls.Count -ge 1)
$outcomes = @(@($recCalls) | ForEach-Object { $_.Extent.Text })
Check "A9 one call records the ADMITTED outcome" ([bool](@($outcomes) -match "'admitted'"))
Check "A9 one call records the memory skip" ([bool](@($outcomes) -match "'skipped-memory'"))
Check "A9 one call records the dispatch-busy skip" ([bool](@($outcomes) -match "'skipped-dispatch-busy'"))
# Provenance must survive a mid-run tree-kill (the PT10H class), so the admitted record
# is written BEFORE the runner launches, not after it returns.
$runnerCall = @($ast.FindAll({ param($n) $n -is $CommandAst -and
                    $n.Extent.Text -match 'tools\.dispatch_harness\.battery' }, $true))
# `$recCalls.Count -ge 1`, NOT `-eq 3`. Same defect as A5 above: #1334 added a fourth
# admission record and this check SILENTLY STOPPED RUNNING rather than failing. What
# identifies the admitted record is its own outcome string, which the Where-Object below
# already selects on — the total count was never the thing that mattered.
$a9Ran = $false
$admittedCall = @(@($recCalls) | Where-Object { $_.Extent.Text -match "'admitted'" })[0]
if ($runnerCall.Count -ge 1 -and $admittedCall) {
    $a9Ran = $true
    $firstRunner = (@($runnerCall) | Sort-Object { $_.Extent.StartOffset } | Select-Object -First 1)
    Check "A9 the admitted record is written BEFORE the runner launches (survives a mid-run tree-kill)" `
        ($admittedCall.Extent.StartOffset -lt $firstRunner.Extent.StartOffset)
}
Check "A9 the ordering check actually RAN (a skipped check must never read as a pass)" $a9Ran

Section 'A7  a skipped night is never silent'
$skipCalls = Get-Calls $ast 'Write-SkipReport'
# This asserted `-eq 2` and was RED ON MAIN against a real 8 -- stale for long enough that
# nobody could say when it stopped being true, which is the case against arity assertions
# stated better than any argument (#1332, retired 2026-08-14). Every stand-down's skip
# report is now checked per-exit by A1p above; the floor is what remains useful here.
Check "A7 every stand-down can write a skip report (got $($skipCalls.Count) call sites)" ($skipCalls.Count -ge 2)
Check "A7 the skip report overwrites state\battery\MORNING-REPORT.md (no stale previous night)" `
    ($src -match 'MORNING-REPORT\.md')

# ===========================================================================
# BEHAVIOR - REAL extracted functions + fixture processes
# ===========================================================================
Section 'B1/B2  the admission gate returns a real boolean (drives the REAL functions)'

# Extract the REAL function definitions from run-battery-night.ps1 by AST - so this
# tests the shipped code, not a paraphrase of it (mocks lie: a hand-written copy would
# keep passing after someone reverted Write-Log in the real file).
function Get-FunctionText([string]$name) {
    $f = @($ast.FindAll({ param($n) $n -is $FuncAst -and $n.Name -eq $name }, $true))
    if ($f.Count -ne 1) { return $null }
    return @($f)[0].Extent.Text
}
$fnWriteLog  = Get-FunctionText 'Write-Log'
$fnGetProj   = Get-FunctionText 'Get-ProjectedSwapHeadroomGiB'
$fnMeasure   = Get-FunctionText 'Measure-SwapHeadroom'
$fnAdmission = Get-FunctionText 'Test-NightAdmission'
Check "B1 extracted the 4 real functions from run-battery-night.ps1" `
    ($fnWriteLog -and $fnGetProj -and $fnMeasure -and $fnAdmission)

# A STARVED world (the 2026-07-20 shape exactly: a leaked AO holding the 14B, 5.93 GiB
# available). Shadowing cmdlets with same-named functions works because PowerShell
# resolves functions before cmdlets - so the real code runs untouched against fakes.
# Shadowing cmdlets with same-named functions works because PowerShell resolves
# functions before cmdlets - so the real extracted code runs untouched against fakes.
# $AvailMb selects the scenario; every admission path must return a genuine [bool],
# because ALL of them now carry provenance instrumentation and any stray success-stream
# emission would turn the boolean back into a truthy array.
function New-AdmissionWorld([double]$AvailMb, [bool]$AoUp) {
    $fakeExe = Join-Path ([IO.Path]::GetTempPath()) ("ao-fakeprobe-" + [guid]::NewGuid().ToString('N').Substring(0,8) + ".cmd")
    Set-Content -Path $fakeExe -Value "@echo off`r`nexit /b 0" -Encoding ascii
    return @{
        Text = @"
function Test-NetConnection { param(`$ComputerName, `$Port, `$InformationLevel, `$WarningAction) return `$$($AoUp.ToString().ToLower()) }
function Get-Counter { param(`$Counter, `$ErrorAction)
    return [pscustomobject]@{ CounterSamples = @([pscustomobject]@{ CookedValue = $AvailMb }) } }
function Get-Process { param(`$Name, `$ErrorAction) return `$null }
function Start-Sleep { param(`$Seconds, `$Milliseconds) }
function Push-Location { param(`$Path) }
function Pop-Location { }
# Stubbed: B1 asserts Test-NightAdmission's RETURN TYPE; Ensure-AoHeadless's own
# structure is asserted by A8. Recording its call proves the post-probe path ran.
function Ensure-AoHeadless { param([string]`$Context = 'preflight') `$script:EnsureCalledWith = `$Context }
function Add-AdmissionSample { param(`$Avail, `$Projected, `$AoUp, `$Stage) `$script:Samples = @(`$script:Samples) + 1 }
`$Python = '$($fakeExe -replace '\\','\\')'
`$BlarRoot = 'C:\Users\mrbla\blarai'
`$LEAN_GATE_GIB = 20.5
`$PROBE_FLOOR_GIB = 15.0
`$LEAN_SAFE_PROCS = @('firefox', 'OneDrive')
"@
        Cleanup = $fakeExe
    }
}

function Invoke-AdmissionWorld {
    # Run the REAL functions in a CHILD pwsh so shadowed cmdlets cannot leak into this
    # verifier, and report the returned object's type + truthiness as JSON.
    param([string]$LogFnText, [double]$AvailMb = 6072.32, [bool]$AoUp = $true)
    $world = New-AdmissionWorld $AvailMb $AoUp
    $tail = @'
$r = Test-NightAdmission
$arr = @($r)
[pscustomobject]@{
    TypeName = $r.GetType().FullName
    Count    = $arr.Count
    NotValue = [bool](-not $r)
    Path     = [string]$script:AdmissionPath
    Ensure   = [string]$script:EnsureCalledWith
} | ConvertTo-Json -Compress
'@
    $script = @($world.Text, $LogFnText, $fnGetProj, $fnMeasure, $fnAdmission, $tail) -join "`n"
    $f = Join-Path ([IO.Path]::GetTempPath()) ("ao-adm-" + [guid]::NewGuid().ToString('N').Substring(0,8) + ".ps1")
    Set-Content -Path $f -Value $script -Encoding utf8
    try {
        $out = & pwsh -NoProfile -ExecutionPolicy Bypass -File $f 2>$null
        $json = ($out | Where-Object { $_ -match '^\s*\{' } | Select-Object -Last 1)
        if (-not $json) { return $null }
        return ($json | ConvertFrom-Json)
    } finally {
        Remove-Item $f -Force -ErrorAction SilentlyContinue
        Remove-Item $world.Cleanup -Force -ErrorAction SilentlyContinue
    }
}

if ($fnWriteLog -and $fnGetProj -and $fnMeasure -and $fnAdmission) {
    # B1a - STARVED (the measured 2026-07-20 shape: a leaked AO holding the 14B, 5.93 GiB
    # available). Must REFUSE, and `-not` must be TRUE so the retry loop runs.
    $starved = Invoke-AdmissionWorld -LogFnText $fnWriteLog -AvailMb 6072.32 -AoUp $true
    Check "B1a the REAL Test-NightAdmission returns a value (starved world)" ($null -ne $starved)
    if ($starved) {
        Check "B1a genuine [bool] (got $($starved.TypeName), count $($starved.Count))" `
            (($starved.TypeName -eq 'System.Boolean') -and ($starved.Count -eq 1))
        Check "B1a starved -> `-not` is TRUE, so the 30-min retry loop RUNS (the gate is live)" `
            ([bool]$starved.NotValue)
        Check "B1a path recorded as below-probe-floor (got '$($starved.Path)')" ($starved.Path -eq 'below-probe-floor')
    }

    # B1b - FAST PATH (plenty of memory, AO down): admits, still a genuine bool.
    $fast = Invoke-AdmissionWorld -LogFnText $fnWriteLog -AvailMb 25600 -AoUp $false
    if ($fast) {
        Check "B1b fast path returns a genuine [bool] (got $($fast.TypeName), count $($fast.Count))" `
            (($fast.TypeName -eq 'System.Boolean') -and ($fast.Count -eq 1))
        Check "B1b fast path ADMITS (`-not` is FALSE)" (-not [bool]$fast.NotValue)
        Check "B1b path recorded as fast-path (got '$($fast.Path)')" ($fast.Path -eq 'fast-path')
    } else { Check "B1b fast-path world returned a value" $false }

    # B1c - PROBE BAND (18 GiB: under the 20.5 gate, over the 15.0 floor) with a probe
    # that exits 0. This is the path the 2026-07-19 night actually took, and the one that
    # calls Ensure-AoHeadless from INSIDE the returning function - the leak route for a
    # bare native call. Return type must survive it.
    $probed = Invoke-AdmissionWorld -LogFnText $fnWriteLog -AvailMb 18432 -AoUp $false
    if ($probed) {
        Check "B1c probe path returns a genuine [bool] (got $($probed.TypeName), count $($probed.Count))" `
            (($probed.TypeName -eq 'System.Boolean') -and ($probed.Count -eq 1))
        Check "B1c probe exit 0 ADMITS (`-not` is FALSE)" (-not [bool]$probed.NotValue)
        Check "B1c path recorded as probe-admitted (got '$($probed.Path)')" ($probed.Path -eq 'probe-admitted')
        Check "B1c the post-probe Ensure-AoHeadless was called with -Context 'post-probe' (got '$($probed.Ensure)')" `
            ($probed.Ensure -eq 'post-probe')
    } else { Check "B1c probe-band world returned a value" $false }

    # B2 - the kill-test. Revert ONLY Write-Log to the Write-Output form and prove the
    # gate goes dead again. Without this, B1 cannot distinguish "the fix works" from
    # "this check cannot see the defect".
    $brokenLog = 'function Write-Log([string]$msg) { Write-Output "[x] $msg" }'
    $broken = Invoke-AdmissionWorld -LogFnText $brokenLog -AvailMb 6072.32 -AoUp $true
    Check "B2 [kill-test] the Write-Output logger returns a value" ($null -ne $broken)
    if ($broken) {
        Check "B2 [kill-test] it returns an ARRAY, not a bool (got $($broken.TypeName), count $($broken.Count))" `
            ($broken.Count -gt 1)
        Check "B2 [kill-test] `-not` is FALSE -> the retry loop is UNREACHABLE (the defect B1 locks out)" `
            (-not [bool]$broken.NotValue)
    }
}

# ===========================================================================
Section 'B7  the REAL provenance writers produce a readable night record'
# A8/A9 prove the calls EXIST. B7 proves what they WRITE is actually usable - that a
# future reader asking "what topology did this night run under?" gets an answer from
# the night dir alone. Drives the real extracted writers against a temp night dir.
$fnAddSample = Get-FunctionText 'Add-AdmissionSample'
$fnBootProv  = Get-FunctionText 'Write-AoBootProvenance'
$fnAdmRecord = Get-FunctionText 'Write-AdmissionRecord'
Check "B7 extracted the 3 real provenance writers" ($fnAddSample -and $fnBootProv -and $fnAdmRecord)
if ($fnAddSample -and $fnBootProv -and $fnAdmRecord) {
    $nightDir = Join-Path ([IO.Path]::GetTempPath()) ('ao-prov-' + [guid]::NewGuid().ToString('N').Substring(0,8))
    New-Item -ItemType Directory -Force -Path $nightDir | Out-Null
    # Replay the 2026-07-19 shape: probe-admitted, AO restored by the probe.
    $tail = @"
`$Stamp = '20260719-230001'
`$NightDir = '$nightDir'
`$LEAN_GATE_GIB = 20.5
`$PROBE_FLOOR_GIB = 15.0
`$AoOwnedByThisNight = `$true
`$script:AdmissionPath = 'probe-admitted'
`$script:AdmissionAttempts = 1
`$script:AdmissionSamples = @()
`$script:ProbeRan = `$true
`$script:ProbeExitCode = 0
`$script:ProbeOutcome = '{"outcome":"READY"}'
`$script:AoBootSource = 'probe-restore'
`$script:StaleClaimReclaimed = '20260718-230002'
Add-AdmissionSample 18.0 18.0 `$false 'initial'
Write-AoBootProvenance 'AO ALREADY UP at the post-probe check - not booted by this launcher. Attributed to: probe-restore.'
Write-AdmissionRecord 'admitted'
"@
    $script = @('function Write-Log([string]$msg) { Write-Host $msg }',
                $fnAddSample, $fnBootProv, $fnAdmRecord, $tail) -join "`n"
    $f = Join-Path ([IO.Path]::GetTempPath()) ("ao-prov-" + [guid]::NewGuid().ToString('N').Substring(0,8) + ".ps1")
    Set-Content -Path $f -Value $script -Encoding utf8
    try {
        & pwsh -NoProfile -ExecutionPolicy Bypass -File $f *> $null
        $jsonPath = Join-Path $nightDir 'admission.json'
        $bootPath = Join-Path $nightDir 'ao-boot.log'
        Check "B7 admission.json was written to the night dir" (Test-Path $jsonPath)
        Check "B7 ao-boot.log was written even though this launcher booted nothing (the 07-19 hole)" (Test-Path $bootPath)
        if (Test-Path $jsonPath) {
            $rec = $null
            try { $rec = Get-Content $jsonPath -Raw | ConvertFrom-Json } catch { }
            Check "B7 admission.json is valid JSON" ($null -ne $rec)
            if ($rec) {
                Check "B7 it carries a schema tag (got '$($rec.schema)')" ($rec.schema -eq 'battery-admission/v1')
                Check "B7 it names the night (got '$($rec.night)')" ($rec.night -eq '20260719-230001')
                Check "B7 it names the ADMISSION PATH (got '$($rec.admission_path)')" ($rec.admission_path -eq 'probe-admitted')
                Check "B7 it names WHO BOOTED THE AO (got '$($rec.ao.boot_source)')" ($rec.ao.boot_source -eq 'probe-restore')
                Check "B7 it records the probe exit code (got '$($rec.probe.exit_code)')" ($rec.probe.exit_code -eq 0)
                Check "B7 it records the measured memory sample (got '$(@($rec.samples).Count)' sample(s))" (@($rec.samples).Count -ge 1)
                Check "B7 it records the ownership outcome" ([bool]$rec.ao.owned_by_this_night)
                Check "B7 it records the stale claim reclaimed (got '$($rec.ao.stale_claim_reclaimed)')" `
                    ($rec.ao.stale_claim_reclaimed -eq '20260718-230002')
            }
        }
        if (Test-Path $bootPath) {
            $bootTxt = Get-Content $bootPath -Raw
            Check "B7 ao-boot.log attributes the AO rather than staying silent" ($bootTxt -match 'probe-restore')
            Check "B7 ao-boot.log entries are timestamped" ($bootTxt -match '\[\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}\]')
        }
    } finally {
        Remove-Item $f -Force -ErrorAction SilentlyContinue
        Remove-Item $nightDir -Recurse -Force -ErrorAction SilentlyContinue
    }
}

# ===========================================================================
Section 'B3-B6  the teardown really stops an owned AO, and only an owned one'

. $ownerLib   # drive the REAL ownership functions

function Get-TestPython {
    $candidates = @(
        'C:\Users\mrbla\blarai\.venv\Scripts\python.exe',
        (Get-Command python -ErrorAction SilentlyContinue).Source
    ) | Where-Object { $_ -and (Test-Path $_) }
    if (-not $candidates) { throw 'no python.exe found for the behavior suite' }
    return $candidates[0]
}
function Test-Alive([int]$ProcessId) {
    try { $null = Get-Process -Id $ProcessId -ErrorAction Stop; return $true } catch { return $false }
}
function Wait-Dead([int]$ProcessId, [int]$TimeoutSec = 10) {
    $deadline = (Get-Date).AddSeconds($TimeoutSec)
    while ((Get-Date) -lt $deadline -and (Test-Alive $ProcessId)) { Start-Sleep -Milliseconds 150 }
    return (-not (Test-Alive $ProcessId))
}

$py   = Get-TestPython
$work = Join-Path ([IO.Path]::GetTempPath()) ('ao-lifecycle-verify-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
New-Item -ItemType Directory -Force -Path $work | Out-Null
$fixture = Join-Path $work 'fixture.py'
Set-Content -Path $fixture -Encoding utf8 -Value 'import time; time.sleep(300)'
$spawned = New-Object System.Collections.ArrayList

function Start-LauncherDecoy {
    # Trailing script args land in the CommandLine WITHOUT python treating them as
    # interpreter options - a valid decoy for stop-assistant's '-m launcher' guard.
    $tag = [guid]::NewGuid().ToString('N').Substring(0, 6)
    $inEmpty = Join-Path $work "in-$tag"; Set-Content -Path $inEmpty -Value '' -NoNewline -Encoding ascii
    $p = Start-Process -FilePath $py -ArgumentList @($fixture, '-m', 'launcher') -WorkingDirectory $work `
            -RedirectStandardInput $inEmpty -RedirectStandardOutput "$inEmpty.out" `
            -RedirectStandardError "$inEmpty.err" -NoNewWindow -PassThru
    $null = $p.Handle
    [void]$spawned.Add($p.Id)
    return $p
}
function New-FixtureRoot {
    $root = Join-Path $work ('root-' + [guid]::NewGuid().ToString('N').Substring(0, 6))
    New-Item -ItemType Directory -Force -Path (Join-Path $root 'certs') | Out-Null
    return $root
}
function Set-LockPid([string]$Root, [int]$LockPid) {
    Set-Content -Path (Join-Path $Root 'certs\launcher.lock') -Value $LockPid -NoNewline -Encoding ascii
}

try {
    # --- B3: an OWNED AO is torn down, and the claim is released ----------------
    Write-Host "`nB3 - Stop-OwnedAo tears down the AO the night owns" -ForegroundColor Yellow
    $root3 = New-FixtureRoot
    $dec3  = Start-LauncherDecoy
    Start-Sleep -Milliseconds 500
    Set-LockPid $root3 $dec3.Id
    $sent3 = Join-Path $work 'sentinel3.json'
    $null = Set-AoOwner -SentinelPath $sent3 -Night '20260719-230001' -OwnerPid $PID
    Check "B3 the sentinel was written" (Test-Path $sent3)
    $r3 = Stop-OwnedAo -SentinelPath $sent3 -BlarAiRepo $root3 -StopAssistantPath $stopAsst `
            -Context 'verify B3' -Log { param($m) }
    Check "B3 Stop-OwnedAo reports Stopped" ([bool]$r3.Stopped)
    Check "B3 the owned decoy is DEAD (the teardown actually happened)" (Wait-Dead $dec3.Id 10)
    Check "B3 the ownership claim was released" (-not (Test-Path $sent3))

    # --- B8: THE GAP. An AO nothing owns is STILL reclaimed ---------------------
    # The first cut reclaimed only sentinel-owned AOs, so a hand-run probe restore (or
    # an operator session, or a night that died before claiming) was invisible -- and
    # with the gate resurrected that meant a SKIPPED night, not merely a degraded one.
    Write-Host "`nB8 - an UNOWNED AO holding the slot is reclaimed (the review gap)" -ForegroundColor Yellow
    $root8 = New-FixtureRoot
    $dec8  = Start-LauncherDecoy
    Start-Sleep -Milliseconds 500
    Set-LockPid $root8 $dec8.Id
    $sent8 = Join-Path $work 'sentinel8.json'   # deliberately never created - nothing owns this AO
    $r8 = Invoke-AoPreflightReclaim -SentinelPath $sent8 -CurrentNight '20260720-230000' `
            -AoPresent $true -LiveDispatch $null -BlarAiRepo $root8 -StopAssistantPath $stopAsst -Log { param($m) }
    Check "B8 the reclaim fired on an AO with NO sentinel (got reason '$($r8.Reason)')" ([bool]$r8.Reclaimed)
    Check "B8 the reason names it unowned, not stale-claim" ($r8.Reason -eq 'unowned-ao')
    Check "B8 the UNOWNED decoy is DEAD - the gap is closed" (Wait-Dead $dec8.Id 10)

    # --- B4 [kill-test for B8]: nothing in the slot -> stop NOTHING -------------
    # Toggle the observation off. If the reclaim still killed, it would be firing blind
    # rather than on the observed slot, and B8 could not distinguish the two.
    Write-Host "`nB4 [kill-test] - with the slot observed EMPTY, nothing is stopped" -ForegroundColor Yellow
    $root4 = New-FixtureRoot
    $dec4  = Start-LauncherDecoy
    Start-Sleep -Milliseconds 500
    Set-LockPid $root4 $dec4.Id
    $sent4 = Join-Path $work 'sentinel4.json'
    $r4 = Invoke-AoPreflightReclaim -SentinelPath $sent4 -CurrentNight '20260720-230000' `
            -AoPresent $false -LiveDispatch $null -BlarAiRepo $root4 -StopAssistantPath $stopAsst -Log { param($m) }
    Check "B4 [kill-test] the reclaim reports no-ao" ($r4.Reason -eq 'no-ao')
    Check "B4 [kill-test] the decoy is still ALIVE - the reclaim fires on the OBSERVED slot, not blindly" (Test-Alive $dec4.Id)

    # --- B5: a claim naming the CURRENT night protects a run in progress --------
    # This is the guard that survives the widened trigger: even with an AO present and
    # reclaim now slot-driven, a run already in flight under this stamp is untouchable.
    Write-Host "`nB5 - a sentinel naming THIS night is never reclaimed" -ForegroundColor Yellow
    $root5 = New-FixtureRoot
    $dec5  = Start-LauncherDecoy
    Start-Sleep -Milliseconds 500
    Set-LockPid $root5 $dec5.Id
    $sent5 = Join-Path $work 'sentinel5.json'
    $null = Set-AoOwner -SentinelPath $sent5 -Night '20260720-230000' -OwnerPid $PID
    $r5 = Invoke-AoPreflightReclaim -SentinelPath $sent5 -CurrentNight '20260720-230000' `
            -AoPresent $true -LiveDispatch $null -BlarAiRepo $root5 -StopAssistantPath $stopAsst -Log { param($m) }
    Check "B5 the reclaim reports current-night" ($r5.Reason -eq 'current-night')
    Check "B5 the run-in-progress decoy is still ALIVE even though the slot is held" (Test-Alive $dec5.Id)
    Check "B5 the current night's claim is retained" (Test-Path $sent5)

    # --- B6: a claim from an EARLIER night IS reclaimed -------------------------
    Write-Host "`nB6 - a sentinel from an earlier night reclaims the orphan" -ForegroundColor Yellow
    $root6 = New-FixtureRoot
    $dec6  = Start-LauncherDecoy
    Start-Sleep -Milliseconds 500
    Set-LockPid $root6 $dec6.Id
    $sent6 = Join-Path $work 'sentinel6.json'
    $null = Set-AoOwner -SentinelPath $sent6 -Night '20260719-230001' -OwnerPid $PID
    $r6 = Invoke-AoPreflightReclaim -SentinelPath $sent6 -CurrentNight '20260720-230000' `
            -AoPresent $true -LiveDispatch $null -BlarAiRepo $root6 -StopAssistantPath $stopAsst -Log { param($m) }
    Check "B6 the reclaim fired (Reclaimed)" ([bool]$r6.Reclaimed)
    Check "B6 the reason names it a stale claim, not unowned" ($r6.Reason -eq 'stale-claim')
    Check "B6 it named the stale night" ($r6.ClaimedNight -eq '20260719-230001')
    Check "B6 the ORPHANED decoy is DEAD" (Wait-Dead $dec6.Id 10)
    Check "B6 the stale claim was cleared" (-not (Test-Path $sent6))

    # --- B9: a claim whose AO is already gone is TIDIED, not retried forever -----
    Write-Host "`nB9 - a stale claim with an empty slot is cleared" -ForegroundColor Yellow
    $root9 = New-FixtureRoot
    $sent9 = Join-Path $work 'sentinel9.json'
    $null = Set-AoOwner -SentinelPath $sent9 -Night '20260718-230002' -OwnerPid $PID
    $r9 = Invoke-AoPreflightReclaim -SentinelPath $sent9 -CurrentNight '20260720-230000' `
            -AoPresent $false -LiveDispatch $null -BlarAiRepo $root9 -StopAssistantPath $stopAsst -Log { param($m) }
    Check "B9 the reclaim reports claim-without-ao" ($r9.Reason -eq 'claim-without-ao')
    Check "B9 the orphaned sentinel was tidied (no perpetual retry)" (-not (Test-Path $sent9))
}
finally {
    foreach ($id in $spawned) { try { & taskkill.exe /T /F /PID $id *> $null } catch {} }
    Remove-Item $work -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Host ''
if ($script:Fail -eq 0) {
    Write-Host "RESULT: $($script:Pass) passed, 0 failed" -ForegroundColor Green
    exit 0
} else {
    Write-Host "RESULT: $($script:Pass) passed, $($script:Fail) failed" -ForegroundColor Red
    exit 1
}
