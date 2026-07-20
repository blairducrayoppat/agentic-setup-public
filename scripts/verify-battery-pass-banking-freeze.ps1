# verify-battery-pass-banking-freeze.ps1 — offline locks for the #904 trim's banking
# guard (2026-07-15): the nightly set was cut to a lean diagnostic, and the runner
# banked a campaign "pass" whenever the night's REQUESTED jobs all completed with
# exit 0 — so a trimmed (easier) night would silently bank passes of the closed
# baseline 6-job campaign and corrupt what #763's landing trigger counts. The fix:
# run-battery-night.ps1 honors an opt-in `pass_banking_frozen` campaign-config flag.
# These locks make the three-state semantics structural (sibling pattern:
# verify-battery-unregister-scoping.ps1 — AST walk + the LIVE source block driven
# both ways, never a re-implementation):
#   F1  the $bankingFrozen guard exists and the completed_passes increment sits in
#       a NON-frozen clause of that same if-chain (AST, not grep).
#   F2  flag ABSENT  (the pre-#904 config shape) -> banks (legacy, byte-identical).
#   F3  flag false   -> banks (legacy).
#   F4  flag true    -> completed_passes UNCHANGED + the FROZEN report line, and
#       never the BANKED line (no vacuous pass).
#   F5  the runner's ConvertTo-Json write-back round-trips the flag + jobs for the
#       next night (the 2026-07-14 clobber class: state must survive the rewrite).
$ErrorActionPreference = 'Stop'
$script:pass = 0; $script:fail = 0
function Check([string]$name, [bool]$ok) {
    if ($ok) { $script:pass++; Write-Host "  [PASS] $name" }
    else     { $script:fail++; Write-Host "  [FAIL] $name" -ForegroundColor Red }
}

$launcher = Join-Path $PSScriptRoot 'run-battery-night.ps1'
$ast = [System.Management.Automation.Language.Parser]::ParseFile($launcher, [ref]$null, [ref]$null)

# ---- F1: structure (AST) -------------------------------------------------------
$assign = $ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.AssignmentStatementAst] -and
                         $n.Left.Extent.Text -eq '$bankingFrozen' }, $true)
Check "F1a the `$bankingFrozen assignment exists (got $($assign.Count))" ($assign.Count -eq 1)

$chain = $ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.IfStatementAst] -and
                        $n.Clauses[0].Item1.Extent.Text -match 'bankingFrozen' }, $true)
Check "F1b the frozen guard if-chain exists (got $($chain.Count))" ($chain.Count -eq 1)

if ($chain.Count -eq 1) {
    $frozenClauseBody = $chain[0].Clauses[0].Item2.Extent.Text
    Check "F1c the FROZEN clause never touches completed_passes" ($frozenClauseBody -notmatch 'completed_passes\s*=' )
    $increments = $ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.AssignmentStatementAst] -and
                                 $n.Left.Extent.Text -match 'completed_passes' }, $true) |
                  Where-Object { $_.Extent.StartOffset -ge $chain[0].Extent.StartOffset -and
                                 $_.Extent.EndOffset -le $chain[0].Extent.EndOffset }
    Check "F1d the banking increment lives INSIDE the guarded chain (got $($increments.Count))" ($increments.Count -eq 1)
}

# ---- F2-F4: behavior — the LIVE extracted block, driven three ways --------------
$script:bankingSrc = $assign[0].Extent.Text + "`n" + $chain[0].Extent.Text

function Invoke-BankingBlock([object]$camp) {
    $lines = @()
    $fullPass = $true      # a clean night: every requested job has a verdict
    $runnerExit = 0        # ...and the runner exited 0 (zero STALLED)
    . ([scriptblock]::Create($script:bankingSrc))
    [pscustomobject]@{ camp = $camp; lines = ($lines -join "`n") }
}

$absent = '{"completed_passes":3,"target_full_passes":5}' | ConvertFrom-Json
$r = Invoke-BankingBlock $absent
Check "F2 flag ABSENT banks (legacy): 3 -> $($r.camp.completed_passes)" ($r.camp.completed_passes -eq 4)
Check "F2 flag ABSENT reports BANKED" ($r.lines -match 'BANKED')

$falsy = '{"pass_banking_frozen":false,"completed_passes":3,"target_full_passes":5}' | ConvertFrom-Json
$r = Invoke-BankingBlock $falsy
Check "F3 flag false banks (legacy): 3 -> $($r.camp.completed_passes)" ($r.camp.completed_passes -eq 4)

$frozen = '{"pass_banking_frozen":true,"completed_passes":3,"target_full_passes":5}' | ConvertFrom-Json
$r = Invoke-BankingBlock $frozen
Check "F4 flag true never increments: stays $($r.camp.completed_passes)" ($r.camp.completed_passes -eq 3)
Check "F4 flag true reports FROZEN" ($r.lines -match 'FROZEN')
Check "F4 flag true never reports BANKED" ($r.lines -notmatch 'BANKED\.')

# ---- F5: the write-back round-trip preserves the new state ----------------------
$wb = '{"jobs":["B2","B4"],"pass_banking_frozen":true,"completed_passes":3}' | ConvertFrom-Json
$back = $wb | ConvertTo-Json -Depth 6 | ConvertFrom-Json
Check "F5 write-back preserves pass_banking_frozen=true" ($back.pass_banking_frozen -eq $true)
Check "F5 write-back preserves the trimmed jobs" (($back.jobs -join ',') -eq 'B2,B4')

Write-Host ""
Write-Host "RESULT: $script:pass passed, $script:fail failed"
if ($script:fail -gt 0) { exit 1 } else { exit 0 }
