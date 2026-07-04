#requires -Version 5.1
<#
.SYNOPSIS
  Verify + validate the #690 SHARED ACCEPTANCE ORACLE (best-of-N's spec-derived scorecard).

.DESCRIPTION
  Background (plain English):
    Best-of-N (#689) takes N independent coder candidates and lets the deterministic gate pick the
    winner. But when the acceptance tests are FOLDED into the lone task, each candidate writes ITS
    OWN tests -- so the gate compares candidates that each graded their own homework. #690 fixes that:
    the 14B writes ONE spec-derived pytest ORACLE at PLAN time (cross-model -- the 30B coder never
    authors the tests that grade it; that lives in BlarAI's shared/fleet/acceptance.py). The fleet
    then SEEDS that oracle into the worktree as a PROTECTED test file committed into the coder's
    baseline ($codeBase), so every best-of-N candidate inherits + codes against + is judged by the
    BYTE-IDENTICAL scorecard, and RESTORES it before each gate so a candidate that edits, weakens, or
    deletes it cannot help itself merge.

  This suite proves two things:
    1. The CORE PROTECT PROPERTY, behaviorally, against a REAL throwaway git repo: a seeded oracle
       survives a candidate EDIT and a candidate DELETE (restored byte-identical before the gate),
       and the restore is idempotent. This is the security-relevant invariant -- tested for real,
       not mocked, because the protection IS the `git checkout <baseline> -- <path>` mechanism.
    2. The WIRING: new-agent-task.ps1 accepts the oracle, seeds it BEFORE the baseline commit, and
       restores it BEFORE the gate; run-fleet.ps1 forwards the queued field. A built-but-unwired
       control is the smell these assertions exist to catch.

  Exit 0 if all passed, 1 otherwise. Run it normally ( .\verify-oracle.ps1 ).
#>
$ErrorActionPreference = 'Stop'

$script:Pass = 0; $script:Fail = 0
$script:Failures = New-Object System.Collections.ArrayList
function Section($t) { Write-Host ''; Write-Host "== $t ==" -ForegroundColor Cyan }
function _pass($m) { $script:Pass++; Write-Host "  [PASS] $m" -ForegroundColor Green }
function _fail($m) { $script:Fail++; [void]$script:Failures.Add($m); Write-Host "  [FAIL] $m" -ForegroundColor Red }
function Assert-Eq($Expected, $Actual, $Msg) { if ([string]$Expected -ceq [string]$Actual) { _pass $Msg } else { _fail "$Msg (expected '$Expected', got '$Actual')" } }
function Assert-True($Cond, $Msg) { if ($Cond) { _pass $Msg } else { _fail "$Msg (expected True, got False)" } }
function Assert-False($Cond, $Msg) { if (-not $Cond) { _pass $Msg } else { _fail "$Msg (expected False, got True)" } }

$U8 = New-Object System.Text.UTF8Encoding $false   # BOM-free, mirrors new-agent-task's writer
# git restores the working-tree file under the repo's core.autocrlf (true on Windows -> CRLF), while
# the seed writes LF. That is a deterministic, benign normalisation applied EQUALLY to every candidate
# and carries NO assertion -- the property #690 needs is that the oracle's CONTENT (its assertions)
# survives tampering, not its byte-level line endings (git stores LF on add/commit, so the MERGED
# oracle is LF regardless; only the transient working tree is CRLF, which pytest reads fine). So the
# restore comparison is line-ending-normalised -- a candidate that WEAKENS an assertion still fails it.
function _norm($s) { ($s -replace "`r`n", "`n") -replace "`r", "`n" }

# ----------------------------------------------------------------------------
Section 'Behavioral: a seeded oracle SURVIVES candidate tampering (the core protect property)'
# Mirror new-agent-task's seed (write BOM-free + trailing newline, commit into the baseline) and
# restore (git checkout $codeBase -- $path) against a REAL throwaway repo -- so this proves the
# actual mechanism, not a mock of it.
$tmp = Join-Path ([System.IO.Path]::GetTempPath()) ("oracle-verify-" + [Guid]::NewGuid().ToString('N').Substring(0, 8))
New-Item -ItemType Directory -Force $tmp | Out-Null
try {
    git -C $tmp init -q 2>&1 | Out-Null
    git -C $tmp config user.email 't@t' 2>&1 | Out-Null
    git -C $tmp config user.name 't' 2>&1 | Out-Null

    $oraclePath = 'tests/test_acceptance.py'
    $oracleFull = Join-Path $tmp $oraclePath
    New-Item -ItemType Directory -Force (Split-Path $oracleFull -Parent) | Out-Null
    $oracleCode = "from calendar_math import add_days`n`n`ndef test_leap_day():`n    assert add_days(2024, 2, 28, 1) == (2024, 3, 1)"
    [System.IO.File]::WriteAllText($oracleFull, ($oracleCode.TrimEnd("`r", "`n") + "`n"), $U8)
    git -C $tmp add -A 2>&1 | Out-Null
    git -C $tmp commit -q -m "seed: acceptance oracle" 2>&1 | Out-Null
    $codeBase = "$(git -C $tmp rev-parse HEAD)".Trim()
    $original = [System.IO.File]::ReadAllText($oracleFull)
    Assert-True ($original.Contains('add_days(2024, 2, 28, 1) == (2024, 3, 1)')) 'OR0 the oracle was seeded with its real assertion'

    # (1) a candidate WEAKENS the oracle (rewrites the failing assertion to a vacuous one)
    [System.IO.File]::WriteAllText($oracleFull, "def test_leap_day():`n    assert True`n", $U8)
    Assert-False (([System.IO.File]::ReadAllText($oracleFull)) -ceq $original) 'OR1a the tamper actually changed the file (guard the test itself)'
    git -C $tmp checkout $codeBase -- $oraclePath 2>&1 | Out-Null
    Assert-Eq (_norm $original) (_norm ([System.IO.File]::ReadAllText($oracleFull))) 'OR1 a candidate EDIT to the oracle is RESTORED (its assertions, byte-for-byte mod line-endings) before the gate'

    # (2) a candidate DELETES the oracle outright (the "pass by removing the failing test" attack)
    Remove-Item $oracleFull -Force
    Assert-False (Test-Path $oracleFull) 'OR2a the delete actually removed the file (guard the test itself)'
    git -C $tmp checkout $codeBase -- $oraclePath 2>&1 | Out-Null
    Assert-True (Test-Path $oracleFull) 'OR2 a candidate DELETING the oracle is RE-CREATED by the restore'
    Assert-Eq (_norm $original) (_norm ([System.IO.File]::ReadAllText($oracleFull))) 'OR2b the re-created oracle has the identical assertions'

    # (3) the restore is idempotent: an untouched oracle is left exactly as-is
    git -C $tmp checkout $codeBase -- $oraclePath 2>&1 | Out-Null
    Assert-Eq (_norm $original) (_norm ([System.IO.File]::ReadAllText($oracleFull))) 'OR3 restoring an untouched oracle is a no-op (idempotent)'
} finally {
    Remove-Item -Recurse -Force $tmp -ErrorAction SilentlyContinue
}

# ----------------------------------------------------------------------------
Section 'Wiring: new-agent-task.ps1 accepts the oracle, seeds it into the baseline, restores it before the gate'
$nat = Get-Content "$PSScriptRoot\new-agent-task.ps1" -Raw
$lib = Get-Content "$PSScriptRoot\fleet-lib.ps1" -Raw   # #700: the gate-time oracle RESTORE moved to Invoke-CandidateBuild (the SEED stays in new-agent-task)
Assert-True ([regex]::IsMatch($nat, '\[string\]\$AcceptanceTestCode\s*=')) 'W1 the runner accepts -AcceptanceTestCode (the spec-derived pytest oracle)'
Assert-True ([regex]::IsMatch($nat, '\[string\]\$AcceptanceTestPath\s*=')) 'W2 the runner accepts -AcceptanceTestPath (where the oracle is seeded)'
# the seed fires ONLY when BOTH are set (either alone is a no-op -> today's behavior)
Assert-True ([regex]::IsMatch($nat, 'if \(\$AcceptanceTestCode -and \$AcceptanceTestPath\)')) 'W3 the seed is gated on BOTH code AND path (either alone = today''s behavior)'
Assert-True ([regex]::IsMatch($nat, '\$oracleActive\s*=\s*\$true')) 'W4 a successful seed arms $oracleActive (drives the restore)'
Assert-True ([regex]::IsMatch($nat, '\[System\.IO\.File\]::WriteAllText\(\$oraclePath')) 'W5 the oracle is written to disk (BOM-free, deterministic across PS 5.1 / pwsh 7)'
# [kill] the seed MUST be committed BEFORE $codeBase is computed, else the candidate baseline (which
# every fresh reset restores to) would NOT contain the oracle and the protect property collapses.
$idxSeed = $nat.IndexOf('$oracleActive = $false')
$idxBase = $nat.IndexOf('$codeBase = (git -C $wt rev-parse HEAD')
Assert-True (($idxSeed -gt 0) -and ($idxBase -gt 0) -and ($idxSeed -lt $idxBase)) 'W6 [kill] the oracle is seeded BEFORE $codeBase is computed (so it rides every candidate''s baseline)'
# the restore: re-materialise the committed oracle bytes from the baseline, gated on $oracleActive
Assert-True ([regex]::IsMatch($lib, 'if \(\$OracleActive\) \{ git -C \$wt checkout \$CodeBase -- \$AcceptanceTestPath')) 'W7 the gate-time RESTORE re-checks the baseline oracle over any candidate edit (gated on $OracleActive, in Invoke-CandidateBuild)'
# [kill] the restore MUST run BEFORE the staging/commit + the [2/5] gate, else the gate would judge a
# TAMPERED oracle (and the merged commit would keep the tamper).
$idxRestore = $lib.IndexOf('if ($OracleActive) { git -C $wt checkout $CodeBase -- $AcceptanceTestPath')
$idxStage = $lib.IndexOf('# Stage, then SECRET-SCAN before committing')
$idxTests = $lib.IndexOf('[2/5] Running pytest')
Assert-True (($idxRestore -gt 0) -and ($idxStage -gt 0) -and ($idxRestore -lt $idxStage)) 'W8 [kill] the restore runs BEFORE staging/commit (the merged candidate keeps the original oracle)'
Assert-True (($idxRestore -gt 0) -and ($idxTests -gt 0) -and ($idxRestore -lt $idxTests)) 'W9 [kill] the restore runs BEFORE the [2/5] test gate (every candidate is judged by the byte-identical oracle)'

# ----------------------------------------------------------------------------
Section 'Wiring: run-fleet.ps1 FORWARDS the queued oracle field to new-agent-task (else it is dormant on the overnight path)'
$runFleet = Get-Content "$PSScriptRoot\run-fleet.ps1" -Raw
Assert-True ([regex]::IsMatch($runFleet, '\$params\.AcceptanceTestCode\s*=\s*\$t\.acceptance_test_code')) 'W10 [kill] run-fleet forwards a queued task''s acceptance_test_code'
Assert-True ([regex]::IsMatch($runFleet, '\$params\.AcceptanceTestPath\s*=\s*\$t\.acceptance_test_path')) 'W11 [kill] run-fleet forwards a queued task''s acceptance_test_path'

# ----------------------------------------------------------------------------
Section 'Result'
Write-Host ("  Passed:  {0}" -f $script:Pass) -ForegroundColor Green
if ($script:Fail) {
    Write-Host ("  Failed:  {0}" -f $script:Fail) -ForegroundColor Red
    $script:Failures | ForEach-Object { Write-Host "    - $_" -ForegroundColor Red }
    exit 1
} else {
    Write-Host ''
    Write-Host '  ACCEPTANCE ORACLE: VALIDATED. One spec-derived scorecard is seeded into the candidate baseline and restored before every gate -- so a best-of-N candidate cannot weaken or delete the tests that judge it, and all candidates are judged byte-identically.' -ForegroundColor Green
    exit 0
}
