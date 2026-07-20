# verify-battery-two-counter-banking.ps1 — offline locks for two-counter pass
# banking (LA direction 2026-07-19: "two counters. one for the lean battery and one
# for the full battery"). A banked "pass" is a COMPLETENESS measure of the harness
# (every scheduled card produced a scorecard), so a complete 2-card lean night and a
# complete 6-card baseline night are different events: the runner classifies
# tonight's ACTUAL job set against baseline_jobs (set-equal, order-insensitive ->
# FULL -> completed_passes; else -> LEAN -> lean_passes, a bare count, no target).
# Sibling pattern: verify-battery-pass-banking-freeze.ps1 — AST walk + the LIVE
# extracted source block driven both ways, never a re-implementation. That freeze
# verifier's F1-F5 still run unmodified; these locks cover the new seam:
#   T1  structure (AST): exactly one lean bank site, inside the guarded chain; the
#       FROZEN clause touches NEITHER counter; classification lives inside the
#       non-frozen clause; the FULL branch never writes lean_passes and the LEAN
#       branch never writes completed_passes (assignments, not string mentions).
#   T2  lean job set + clean night  -> lean_passes absent->1, completed_passes
#       UNCHANGED, the LEAN report line (and never the FULL line).
#   T3  baseline job set (SHUFFLED order — order-insensitivity) + clean night ->
#       completed_passes +1, lean_passes UNCHANGED/uncreated, the FULL line.
#   T4  incomplete night (missing scorecard) or nonzero runner exit -> NEITHER.
#   T5  pass_banking_frozen: true -> NEITHER increments (freeze still honored).
#   T6  baseline_jobs ABSENT (pre-#904 config shape) -> FULL banks (legacy).
#   T7  write-back round-trips lean_passes + baseline_jobs (clobber class).
#   M1-M3 TOGGLE-OFF (CLAUDE.md principle 12 — prove the checks FAIL when the
#       logic is wrong): mutants with (M1) classification stripped, (M2) the
#       completeness condition stripped, (M3) the frozen guard stripped must each
#       VIOLATE the matching assertion above — otherwise the lock has no teeth.
$ErrorActionPreference = 'Stop'
$script:pass = 0; $script:fail = 0
function Check([string]$name, [bool]$ok) {
    if ($ok) { $script:pass++; Write-Host "  [PASS] $name" }
    else     { $script:fail++; Write-Host "  [FAIL] $name" -ForegroundColor Red }
}

$launcher = Join-Path $PSScriptRoot 'run-battery-night.ps1'
$ast = [System.Management.Automation.Language.Parser]::ParseFile($launcher, [ref]$null, [ref]$null)

# ---- T1: structure (AST) -------------------------------------------------------
$assign = $ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.AssignmentStatementAst] -and
                         $n.Left.Extent.Text -eq '$bankingFrozen' }, $true)
$chain = $ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.IfStatementAst] -and
                        $n.Clauses[0].Item1.Extent.Text -match 'bankingFrozen' }, $true)
Check "T1a the frozen guard if-chain still exists (got $($chain.Count))" ($chain.Count -eq 1)

$leanBanks = $ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.CommandAst] -and
                            $n.Extent.Text -match 'Add-Member' -and $n.Extent.Text -match 'lean_passes' }, $true)
Check "T1b exactly one lean bank site (Add-Member lean_passes; got $($leanBanks.Count))" ($leanBanks.Count -eq 1)
if ($chain.Count -eq 1 -and $leanBanks.Count -eq 1) {
    Check "T1c the lean bank site lives INSIDE the guarded chain" (
        $leanBanks[0].Extent.StartOffset -ge $chain[0].Extent.StartOffset -and
        $leanBanks[0].Extent.EndOffset -le $chain[0].Extent.EndOffset)
    $frozenClauseBody = $chain[0].Clauses[0].Item2.Extent.Text
    Check "T1d the FROZEN clause never touches lean_passes" ($frozenClauseBody -notmatch 'lean_passes')
    Check "T1e the FROZEN clause never assigns completed_passes" ($frozenClauseBody -notmatch 'completed_passes\s*=')
    $bankClauseBody = $chain[0].Clauses[1].Item2.Extent.Text
    Check "T1f classification (baseline_jobs + Compare-Object) lives inside the NON-frozen clause" (
        $bankClauseBody -match 'baseline_jobs' -and $bankClauseBody -match 'Compare-Object')
    $inner = $ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.IfStatementAst] -and
                            $n.Clauses[0].Item1.Extent.Text -match "nightClass\s+-eq\s+'FULL'" }, $true)
    Check "T1g the nightClass branch exists (the #973 rotation extension seam; got $($inner.Count))" ($inner.Count -eq 1)
    if ($inner.Count -eq 1) {
        $fullBody = $inner[0].Clauses[0].Item2
        $leanBody = $inner[0].Clauses[1].Item2
        $fullWritesLean = $fullBody.FindAll({ param($n) ($n -is [System.Management.Automation.Language.CommandAst] -and
                              $n.Extent.Text -match 'lean_passes') -or
                              ($n -is [System.Management.Automation.Language.AssignmentStatementAst] -and
                              $n.Left.Extent.Text -match 'lean_passes') }, $true)
        Check "T1h the FULL branch never writes lean_passes (got $($fullWritesLean.Count))" ($fullWritesLean.Count -eq 0)
        $leanWritesFull = $leanBody.FindAll({ param($n) $n -is [System.Management.Automation.Language.AssignmentStatementAst] -and
                              $n.Left.Extent.Text -match 'completed_passes' }, $true)
        Check "T1i the LEAN branch never assigns completed_passes (got $($leanWritesFull.Count))" ($leanWritesFull.Count -eq 0)
    }
}

# ---- T2-T6: behavior — the LIVE extracted block, driven both ways ---------------
$script:bankingSrc = $assign[0].Extent.Text + "`n" + $chain[0].Extent.Text
$BaselineSix = '["B1","B2","B4","B5","B6","B7"]'

function Invoke-BankingBlock([object]$camp, [object[]]$jobSet, [bool]$complete = $true,
                             [int]$exitCode = 0, [string]$src = $script:bankingSrc) {
    $lines = @()
    $jobs = $jobSet          # tonight's ACTUAL job set (post any late-start trim)
    $fullPass = $complete    # a clean night: every requested job has a verdict
    $runnerExit = $exitCode  # ...and the runner exited 0 (zero STALLED)
    . ([scriptblock]::Create($src))
    [pscustomobject]@{ camp = $camp; lines = ($lines -join "`n") }
}
function Has-Lean([object]$camp) { $camp.PSObject.Properties.Name -contains 'lean_passes' }

$leanCfg = "{`"jobs`":[`"B2`",`"B4`"],`"baseline_jobs`":$BaselineSix,`"completed_passes`":3,`"target_full_passes`":5}"

# T2: lean set + clean night -> lean +1 (absent initializes to 1), full UNCHANGED
$r = Invoke-BankingBlock ($leanCfg | ConvertFrom-Json) @('B2','B4')
Check "T2 lean night: lean_passes absent -> $($r.camp.lean_passes)" ((Has-Lean $r.camp) -and $r.camp.lean_passes -eq 1)
Check "T2 lean night: completed_passes UNCHANGED at $($r.camp.completed_passes)" ($r.camp.completed_passes -eq 3)
Check "T2 lean night reports the LEAN line" ($r.lines -match 'LEAN pass 1.*BANKED')
Check "T2 lean night never reports the FULL line" ($r.lines -notmatch 'FULL pass')

# T2b: lean counter accumulates when already present
$c = $leanCfg | ConvertFrom-Json; $c | Add-Member -NotePropertyName lean_passes -NotePropertyValue 2
$r = Invoke-BankingBlock $c @('B2','B4')
Check "T2b lean night with lean_passes=2 -> $($r.camp.lean_passes)" ($r.camp.lean_passes -eq 3)

# T3: baseline set, SHUFFLED order -> full +1, lean untouched (order-insensitive)
$r = Invoke-BankingBlock ($leanCfg | ConvertFrom-Json) @('B7','B2','B1','B5','B4','B6')
Check "T3 baseline night (shuffled): completed_passes 3 -> $($r.camp.completed_passes)" ($r.camp.completed_passes -eq 4)
Check "T3 baseline night: lean_passes never created" (-not (Has-Lean $r.camp))
Check "T3 baseline night reports the FULL line" ($r.lines -match 'FULL pass 4/5 BANKED')
Check "T3 baseline night never reports the LEAN line" ($r.lines -notmatch 'LEAN pass')

# T3b: baseline night leaves an EXISTING lean counter unchanged
$c = $leanCfg | ConvertFrom-Json; $c | Add-Member -NotePropertyName lean_passes -NotePropertyValue 2
$r = Invoke-BankingBlock $c @('B1','B2','B4','B5','B6','B7')
Check "T3b baseline night: lean_passes UNCHANGED at $($r.camp.lean_passes)" ($r.camp.lean_passes -eq 2)

# T4: an incomplete night (or nonzero exit) banks NOTHING, as today
$r = Invoke-BankingBlock ($leanCfg | ConvertFrom-Json) @('B2','B4') $false
Check "T4 incomplete night: completed_passes stays $($r.camp.completed_passes)" ($r.camp.completed_passes -eq 3)
Check "T4 incomplete night: lean_passes never created" (-not (Has-Lean $r.camp))
Check "T4 incomplete night reports NOT counted" ($r.lines -match 'NOT counted')
$r = Invoke-BankingBlock ($leanCfg | ConvertFrom-Json) @('B2','B4') $true 3
Check "T4 nonzero runner exit: NEITHER counter moves" ($r.camp.completed_passes -eq 3 -and -not (Has-Lean $r.camp))

# T5: the freeze is still honored — a frozen config banks NOTHING on either counter
$c = $leanCfg | ConvertFrom-Json; $c | Add-Member -NotePropertyName pass_banking_frozen -NotePropertyValue $true
$r = Invoke-BankingBlock $c @('B2','B4')
Check "T5 frozen: completed_passes stays $($r.camp.completed_passes)" ($r.camp.completed_passes -eq 3)
Check "T5 frozen: lean_passes never created" (-not (Has-Lean $r.camp))
Check "T5 frozen reports FROZEN, never BANKED" ($r.lines -match 'FROZEN' -and $r.lines -notmatch 'BANKED')

# T6: baseline_jobs ABSENT (pre-#904 shape) -> only one notion of a pass -> FULL (legacy)
$r = Invoke-BankingBlock ('{"completed_passes":3,"target_full_passes":5}' | ConvertFrom-Json) @('B2','B4')
Check "T6 no baseline_jobs: banks FULL (legacy): 3 -> $($r.camp.completed_passes)" ($r.camp.completed_passes -eq 4)
Check "T6 no baseline_jobs: lean_passes never created" (-not (Has-Lean $r.camp))

# ---- T7: the write-back round-trip preserves the new state ----------------------
$wb = "{`"jobs`":[`"B2`",`"B4`"],`"baseline_jobs`":$BaselineSix,`"lean_passes`":4,`"completed_passes`":3}" | ConvertFrom-Json
$back = $wb | ConvertTo-Json -Depth 6 | ConvertFrom-Json
Check "T7 write-back preserves lean_passes=4" ($back.lean_passes -eq 4)
Check "T7 write-back preserves baseline_jobs" (($back.baseline_jobs -join ',') -eq 'B1,B2,B4,B5,B6,B7')

# ---- M1-M3: toggle-off — each lock must CATCH the matching broken logic ---------
# A lock that passes against correct code AND against broken code is no lock at
# all (CLAUDE.md principle 12). Each mutant below re-drives the SAME fixture and
# the check passes only if the T-assertion above would have FAILED against it.
$classificationLine = '($baselineJobs.Count -eq 0) -or (-not (Compare-Object @($jobs) $baselineJobs))'
$mut = $script:bankingSrc.Replace($classificationLine, '$true')
Check "M1 mutation applied (classification stripped)" ($mut -ne $script:bankingSrc)
$r = Invoke-BankingBlock ($leanCfg | ConvertFrom-Json) @('B2','B4') $true 0 $mut
Check "M1 classification-stripped mutant is CAUGHT by T2 (mutant mis-banks FULL on a lean night)" (
    -not ($r.camp.completed_passes -eq 3 -and (Has-Lean $r.camp) -and $r.camp.lean_passes -eq 1))

$completenessCond = '($fullPass -and $runnerExit -eq 0)'
$mut = $script:bankingSrc.Replace($completenessCond, '($true)')
Check "M2 mutation applied (completeness condition stripped)" ($mut -ne $script:bankingSrc)
$r = Invoke-BankingBlock ($leanCfg | ConvertFrom-Json) @('B2','B4') $false 0 $mut
Check "M2 completeness-stripped mutant is CAUGHT by T4 (mutant banks an incomplete night)" (
    -not ($r.camp.completed_passes -eq 3 -and -not (Has-Lean $r.camp)))

$mut = $script:bankingSrc.Replace('if ($bankingFrozen) {', 'if ($false) {')
Check "M3 mutation applied (frozen guard stripped)" ($mut -ne $script:bankingSrc)
$c = $leanCfg | ConvertFrom-Json; $c | Add-Member -NotePropertyName pass_banking_frozen -NotePropertyValue $true
$r = Invoke-BankingBlock $c @('B2','B4') $true 0 $mut
Check "M3 frozen-guard-stripped mutant is CAUGHT by T5 (mutant banks under the freeze)" (
    -not ($r.camp.completed_passes -eq 3 -and -not (Has-Lean $r.camp)))

Write-Host ""
Write-Host "RESULT: $script:pass passed, $script:fail failed"
if ($script:fail -gt 0) { exit 1 } else { exit 0 }
