#Requires -Version 7.0
<#
.SYNOPSIS
  Regression lock for #1045: optional campaign keys must survive StrictMode.

.DESCRIPTION
  `run-battery-night.ps1` dot-sources `ao-ownership-lib.ps1`, which sets
  `Set-StrictMode -Version Latest`. Dot-sourcing runs in the CALLER's scope, so StrictMode
  is live for the rest of that script — and under StrictMode, reading a key that a
  `ConvertFrom-Json` object does not have THROWS rather than returning $null.

  That turned two documented-optional keys into launch-killers on the side-config path,
  which is the sanctioned mechanism for daytime targeted runs:

    end_date   the cutoff comment says "a side/manual config just omits it"; omitting it
               threw "The property 'end_date' cannot be found on this object"
    excluded   a config with nothing to exclude has no reason to carry the key

  The default campaign carries both, so the 23:00 nightly never took these branches and the
  defect was invisible to every automated path. #1045 was closed 2026-07-22 by a commit that
  fixed a DIFFERENT StrictMode instance in the same file (the postlude, 84891b2) while the
  reported one survived behind the runbook's "2099-12-31" workaround — the workaround is why
  nobody tripped over it again.

  This verifier is READ-ONLY: no task, no campaign file, no dispatch. It proves the guards
  work, proves the probe could have caught the defect (the toggle), proves the guards did
  not neuter the feature (the converse), and pins the two source lines so a future edit
  cannot quietly reintroduce a bare access.

.PARAMETER RunnerScript
  The script under inspection. Defaults to run-battery-night.ps1 beside this file.
#>
[CmdletBinding()]
param(
    [string]$RunnerScript = "$PSScriptRoot\run-battery-night.ps1"
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest      # the very condition under test

$fails = 0
function Check([string]$name, [bool]$ok) {
    if ($ok) { Write-Host "  [PASS] $name" -ForegroundColor Green }
    else { Write-Host "  [FAIL] $name" -ForegroundColor Red; $script:fails++ }
}
function Section([string]$t) { Write-Host ''; Write-Host "== $t ==" }

Write-Host '============ SIDE-CONFIG OPTIONAL KEYS UNDER STRICTMODE (#1045) ============'
Write-Host "runner: $RunnerScript"
Write-Host "StrictMode: Latest (this process) | PSVersion: $($PSVersionTable.PSVersion)"

# A side config exactly as the documented contract allows: neither optional key present.
$minimal = '{ "campaign": "probe", "jobs": ["B9"], "completed_passes": 0, "target_full_passes": 1 }' | ConvertFrom-Json
$full = '{ "campaign": "m2", "jobs": ["B2"], "completed_passes": 0, "target_full_passes": 5, "end_date": "2026-11-11", "excluded": [ { "id": "B3", "reason": "known stall" } ] }' | ConvertFrom-Json

Section 'K  KILL TESTS - the bare access really is fatal (a probe that cannot fail proves nothing)'
$bareEndDateThrew = $false
try { if ($minimal.end_date) { } } catch { $bareEndDateThrew = $true }
Check 'K1 bare $camp.end_date on a config without it THROWS under StrictMode' $bareEndDateThrew

$bareExcludedThrew = $false
try { $null = @($minimal.excluded) } catch { $bareExcludedThrew = $true }
Check 'K2 bare $camp.excluded on a config without it THROWS under StrictMode' $bareExcludedThrew

Section 'G  the guarded idiom survives an absent key'
$guardedEndDate = $null
$ok1 = $true
try { $guardedEndDate = if (($minimal.PSObject.Properties.Name -contains 'end_date') -and $minimal.end_date) { $minimal.end_date } else { $null } }
catch { $ok1 = $false }
Check 'G1 guarded end_date does not throw when the key is absent' $ok1
Check 'G2 and yields the documented "no calendar cutoff" (null)' ($null -eq $guardedEndDate)

$guardedExcluded = $null
$ok2 = $true
try { $guardedExcluded = @(if ($minimal.PSObject.Properties.Name -contains 'excluded') { $minimal.excluded } else { @() }) }
catch { $ok2 = $false }
Check 'G3 guarded excluded does not throw when the key is absent' $ok2
Check 'G4 and yields an empty set (nothing excluded)' ($guardedExcluded.Count -eq 0)

Section 'C  CONVERSE - the guard did not neuter the feature when the key IS present'
$c1 = if (($full.PSObject.Properties.Name -contains 'end_date') -and $full.end_date) { $full.end_date } else { $null }
Check 'C1 a present end_date is still read' ($c1 -eq '2026-11-11')
$c2 = @(if ($full.PSObject.Properties.Name -contains 'excluded') { $full.excluded } else { @() })
Check 'C2 a present excluded list is still read' ($c2.Count -eq 1 -and $c2[0].id -eq 'B3')
$c3 = @($c2 | ForEach-Object { "$($_.id) ($($_.reason))" })
Check 'C3 and still renders the operator-facing "NOT silent" line' ($c3[0] -eq 'B3 (known stall)')

Section 'S  SOURCE PIN - a future edit cannot quietly reintroduce a bare access'
if (-not (Test-Path $RunnerScript)) {
    Check "S0 runner script found at $RunnerScript" $false
}
else {
    $src = Get-Content $RunnerScript -Raw
    # CODE ONLY. The first draft of this check scanned the raw file and failed on the
    # explanatory comment beside the fix, which necessarily quotes the bare form it
    # replaced. A source pin that cannot tell code from prose forbids documenting the very
    # defect it guards, so strip full-line comments before matching.
    $code = (Get-Content $RunnerScript | Where-Object { $_ -notmatch '^\s*#' }) -join "`n"

    $endGuarded = $code -match "\(\s*\`$camp\.PSObject\.Properties\.Name\s+-contains\s+'end_date'\s*\)\s+-and\s+\`$camp\.end_date"
    Check 'S1 the end_date cutoff test uses the presence-guarded idiom' $endGuarded
    $excGuarded = $code -match "\`$camp\.PSObject\.Properties\.Name\s+-contains\s+'excluded'"
    Check 'S2 the excluded read uses the presence-guarded idiom' $excGuarded
    # And the bare forms must be gone from those two sites specifically.
    Check 'S3 no bare `if ($camp.end_date)` remains in CODE' (-not ($code -match "if\s*\(\s*\`$camp\.end_date\s*\)"))
    Check 'S4 no bare `@($camp.excluded ...)` remains in CODE' (-not ($code -match "@\(\s*\`$camp\.excluded\s*\|"))
    # The StrictMode leak that makes all of this load-bearing must still be real. If the
    # dot-source ever moves or goes, this verifier's PREMISE changes and someone must
    # re-read it rather than assume these guards are still doing anything. Matched loosely
    # on purpose: the call form (quoted path vs Join-Path) is incidental, its presence is not.
    Check 'S5 the StrictMode leak this guards against still exists (ao-ownership-lib is dot-sourced)' `
        ($code -match "(?m)^\s*\.\s+.*ao-ownership-lib\.ps1")
}

Write-Host ''
if ($fails -eq 0) {
    Write-Host 'RESULT: all checks passed - optional side-config keys survive StrictMode.' -ForegroundColor Green
    exit 0
}
Write-Host "RESULT: $fails check(s) FAILED." -ForegroundColor Red
exit 1
