#requires -Version 7.0
# verify-battery-native-error-scoping.ps1 — offline locks for the #903 hardening
# (2026-07-15): run-battery-night.ps1's task-settings preflight branches on the
# child check's exit code (`& pwsh -File verify-battery-task-settings.ps1`), and the
# launcher runs $ErrorActionPreference = 'Stop'. On a host where
# $PSNativeCommandUseErrorActionPreference is $true, a non-zero child exit THROWS
# instead of setting $LASTEXITCODE; the throw lands in the wiring's generic catch and
# MISLABELS a real settings drift as "check errored" — the morning DRIFT banner is
# muddied (the night is never aborted either way; the check is non-fatal, so this is
# pure signal fidelity). The fix scopes $PSNativeCommandUseErrorActionPreference =
# $false around JUST the `& pwsh` call (save/restore), leaving the launcher's other
# native calls on the box default.
#
# These locks make that structural (sibling pattern: verify-battery-pass-banking-
# freeze.ps1 / verify-battery-unregister-scoping.ps1 — AST walk of the LIVE source +
# the LIVE extracted block driven both ways, never a re-implementation):
#   S1  the task-settings wiring try/catch exists.
#   S2  it scope-sets $PSNativeCommandUseErrorActionPreference = $false.
#   S3  it restores the saved value in a FINALLY (so an unrelated throw still restores).
#   S4  the drift branch reads a CAPTURED exit ($verifyExit), taken inside the scope.
#   S5  the set precedes the `& pwsh` call and the restore follows it (the call is wrapped).
#   B1  LIVE block, hostile host, child exit 0 -> conform, no drift, preference restored.
#   B2  LIVE block, hostile host, child exit 1 -> DRIFT recorded (NOT "errored"), restored.
#   B3  LIVE block, hostile host, child missing -> the non-fatal "not found" skip, restored.
#   B4  LIVE block, BOX default (pref $false), child exit 1 -> DRIFT (behavior-preserving here).
#   C0  control: the simulated hostile host genuinely throws a bare non-zero native exit
#       (else the whole suite is vacuous).
#   C1  control: the PRE-#903 shape, hostile host, child exit 1 -> mislabels as "errored"
#       with NO drift (the toggle-test: the probe fails when the lock is off).
$ErrorActionPreference = 'Stop'
$script:pass = 0; $script:fail = 0
function Check([string]$name, [bool]$ok) {
    if ($ok) { $script:pass++; Write-Host "  [PASS] $name" }
    else     { $script:fail++; Write-Host "  [FAIL] $name" -ForegroundColor Red }
}

$launcher = Join-Path $PSScriptRoot 'run-battery-night.ps1'
$ast = [System.Management.Automation.Language.Parser]::ParseFile($launcher, [ref]$null, [ref]$null)

# ---- S1: the wiring try/catch (the OUTER try owns the generic catch) -------------
$outerTry = @($ast.FindAll({ param($n)
            $n -is [System.Management.Automation.Language.TryStatementAst] -and
            $n.Extent.Text -match 'check errored' }, $true))
Check "S1 the task-settings wiring try/catch exists (got $($outerTry.Count))" ($outerTry.Count -eq 1)

$inTry = { param($node) $outerTry.Count -eq 1 -and
    $node.Extent.StartOffset -ge $outerTry[0].Extent.StartOffset -and
    $node.Extent.EndOffset   -le $outerTry[0].Extent.EndOffset }

# ---- S2: it scope-sets the native-error preference to $false --------------------
$setFalse = @($ast.FindAll({ param($n)
            $n -is [System.Management.Automation.Language.AssignmentStatementAst] -and
            $n.Left.Extent.Text -eq '$PSNativeCommandUseErrorActionPreference' -and
            $n.Right.Extent.Text -eq '$false' }, $true) | Where-Object { & $inTry $_ })
Check "S2 scope-sets `$PSNativeCommandUseErrorActionPreference = `$false in the wiring (got $($setFalse.Count))" ($setFalse.Count -eq 1)

# ---- S3: the restore lives in a FINALLY -----------------------------------------
$restore = @($ast.FindAll({ param($n)
            $n -is [System.Management.Automation.Language.AssignmentStatementAst] -and
            $n.Left.Extent.Text -eq '$PSNativeCommandUseErrorActionPreference' -and
            $n.Right.Extent.Text -ne '$false' }, $true) | Where-Object { & $inTry $_ })
Check "S3a a restore assignment exists in the wiring (got $($restore.Count))" ($restore.Count -eq 1)
$innerTry = @($ast.FindAll({ param($n)
            $n -is [System.Management.Automation.Language.TryStatementAst] -and
            $null -ne $n.Finally -and
            $n.Finally.Extent.Text -match 'PSNativeCommandUseErrorActionPreference' }, $true))
$restoreInFinally = $innerTry.Count -eq 1 -and $restore.Count -eq 1 -and
    $restore[0].Extent.StartOffset -ge $innerTry[0].Finally.Extent.StartOffset -and
    $restore[0].Extent.EndOffset   -le $innerTry[0].Finally.Extent.EndOffset
Check "S3b the restore runs in a FINALLY (unrelated throw still restores the box default)" $restoreInFinally

# ---- S4: the drift branch reads a CAPTURED exit, not $LASTEXITCODE inline --------
$capture = @($ast.FindAll({ param($n)
            $n -is [System.Management.Automation.Language.AssignmentStatementAst] -and
            $n.Left.Extent.Text -eq '$verifyExit' -and
            $n.Right.Extent.Text -eq '$LASTEXITCODE' }, $true) | Where-Object { & $inTry $_ })
Check "S4a the exit code is captured to `$verifyExit inside the wiring (got $($capture.Count))" ($capture.Count -eq 1)
$driftIf = @($ast.FindAll({ param($n)
            $n -is [System.Management.Automation.Language.IfStatementAst] -and
            $n.Clauses[0].Item1.Extent.Text -match '\$verifyExit' }, $true) | Where-Object { & $inTry $_ })
Check "S4b the drift branch tests the captured `$verifyExit (got $($driftIf.Count))" ($driftIf.Count -eq 1)

# ---- S5: the set precedes the `& pwsh` call, the restore follows it --------------
$pwshCall = @($ast.FindAll({ param($n)
            $n -is [System.Management.Automation.Language.CommandAst] -and
            $n.GetCommandName() -eq 'pwsh' -and
            $n.Extent.Text -match '\$verifyTaskSettings' }, $true) | Where-Object { & $inTry $_ })
Check "S5a exactly one wrapped `& pwsh` call to the child check (got $($pwshCall.Count))" ($pwshCall.Count -eq 1)
if ($pwshCall.Count -eq 1 -and $setFalse.Count -eq 1 -and $restore.Count -eq 1) {
    Check "S5b the `$false set precedes the `& pwsh` call" ($setFalse[0].Extent.StartOffset -lt $pwshCall[0].Extent.StartOffset)
    Check "S5c the restore follows the `& pwsh` call (call is wrapped)" ($restore[0].Extent.StartOffset -gt $pwshCall[0].Extent.EndOffset)
}

# ==== behavior: drive the LIVE extracted wiring block ============================
if ($outerTry.Count -ne 1) {
    Write-Host ''
    Write-Host "RESULT: $script:pass passed, $script:fail failed (wiring block not found — cannot drive behavior)" -ForegroundColor Red
    exit 1
}
$script:liveSrc = $outerTry[0].Extent.Text

# The PRE-#903 shape, kept ONLY as the negative control (C1): a faithful minimal
# reproduction of the wiring before the scope-set, to prove the suite can tell fixed
# from broken. Single-quoted here-string: $-tokens are literal, resolved at drive time
# in the driver's dot-source scope (same as the live block).
$script:preFixSrc = @'
try {
    if (Test-Path $verifyTaskSettings) {
        & pwsh -NoProfile -ExecutionPolicy Bypass -File $verifyTaskSettings -BlarRepo $BlarRoot *>&1 |
            ForEach-Object { Write-Log "task-settings: $_" }
        if ($LASTEXITCODE -ne 0) {
            $TaskSettingsDrift = "scheduled-task settings DRIFTED (exit $LASTEXITCODE)."
            Write-Log "WARNING: $TaskSettingsDrift"
        } else {
            Write-Log "task-settings: conform."
        }
    } else {
        Write-Log "task-settings: verify-battery-task-settings.ps1 not found - skipping (non-fatal)."
    }
} catch {
    Write-Log "task-settings: check errored ($($_.Exception.Message)) - non-fatal, continuing the night."
}
'@

# Dot-source the given block under a chosen host preference + a stub child that exits
# a chosen code (or is absent), and report what the block decided. $verifyTaskSettings
# and $TaskSettingsDrift are the block's inputs/outputs (assigned on the lines the
# block relies on being set before it); Write-Log is captured; the host preferences are
# set in THIS function scope so the native call resolves them by normal scope lookup.
function Invoke-WiringBlock {
    param(
        [Parameter(Mandatory)][string]$Src,
        [Parameter(Mandatory)][bool]$HostileHost,
        [int]$StubExit = 0,
        [switch]$MissingChild
    )
    $ErrorActionPreference = 'Stop'
    $PSNativeCommandUseErrorActionPreference = $HostileHost
    $TaskSettingsDrift = $null
    $BlarRoot = 'C:\does-not-matter'   # the stub ignores -BlarRepo
    $script:logged = @()
    function Write-Log([string]$m) { $script:logged += $m }

    $tmp = [System.IO.Path]::GetTempPath()
    if ($MissingChild) {
        $verifyTaskSettings = Join-Path $tmp ("nb-903-absent-{0}.ps1" -f [guid]::NewGuid())
    } else {
        $verifyTaskSettings = Join-Path $tmp ("nb-903-stub-{0}.ps1" -f [guid]::NewGuid())
        Set-Content -LiteralPath $verifyTaskSettings -Value "exit $StubExit"
    }
    $threw = $false
    try {
        . ([scriptblock]::Create($Src))
    } catch {
        $threw = $true
    } finally {
        if (-not $MissingChild) { Remove-Item -LiteralPath $verifyTaskSettings -Force -ErrorAction SilentlyContinue }
    }
    [pscustomobject]@{
        Drift           = $TaskSettingsDrift
        Logged          = ($script:logged -join "`n")
        NativePrefAfter = $PSNativeCommandUseErrorActionPreference
        Threw           = $threw
    }
}

# ---- B1: hostile host, child exit 0 -> conform, no drift, preference restored ----
$b1 = Invoke-WiringBlock -Src $script:liveSrc -HostileHost $true -StubExit 0
Check "B1a hostile+exit0: no drift recorded" ($null -eq $b1.Drift)
Check "B1b hostile+exit0: logs 'conform'" ($b1.Logged -match 'conform')
Check "B1c hostile+exit0: preference restored to `$true" ($b1.NativePrefAfter -eq $true)
Check "B1d hostile+exit0: nothing escaped the wiring" (-not $b1.Threw)

# ---- B2: hostile host, child exit 1 -> DRIFT (the fix), NOT "errored" ------------
$b2 = Invoke-WiringBlock -Src $script:liveSrc -HostileHost $true -StubExit 1
Check "B2a hostile+exit1: DRIFT recorded (reaches the drift path)" ($b2.Drift -match 'DRIFTED')
Check "B2b hostile+exit1: drift names 'exit 1'" ($b2.Drift -match 'exit 1')
Check "B2c hostile+exit1: NOT mislabeled 'check errored'" ($b2.Logged -notmatch 'check errored')
Check "B2d hostile+exit1: logs the WARNING" ($b2.Logged -match 'WARNING')
Check "B2e hostile+exit1: preference restored to `$true" ($b2.NativePrefAfter -eq $true)
Check "B2f hostile+exit1: nothing escaped the wiring" (-not $b2.Threw)

# ---- B3: hostile host, child MISSING -> the non-fatal skip path ------------------
$b3 = Invoke-WiringBlock -Src $script:liveSrc -HostileHost $true -MissingChild
Check "B3a hostile+missing: no drift recorded" ($null -eq $b3.Drift)
Check "B3b hostile+missing: logs the 'not found' skip" ($b3.Logged -match 'not found')
Check "B3c hostile+missing: nothing escaped the wiring" (-not $b3.Threw)

# ---- B4: BOX default (pref $false), child exit 1 -> DRIFT (behavior-preserving) --
$b4 = Invoke-WiringBlock -Src $script:liveSrc -HostileHost $false -StubExit 1
Check "B4a box-default+exit1: DRIFT recorded (no regression on this box)" ($b4.Drift -match 'DRIFTED')
Check "B4b box-default+exit1: preference restored to `$false" ($b4.NativePrefAfter -eq $false)

# ---- C0: the simulated hostile host genuinely throws (suite is not vacuous) ------
function Test-BareNativeThrows {
    $ErrorActionPreference = 'Stop'
    $PSNativeCommandUseErrorActionPreference = $true
    try { & pwsh -NoProfile -Command 'exit 3' | Out-Null; return $false } catch { return $true }
}
Check "C0 hostile host genuinely throws a bare non-zero native exit (premise holds)" (Test-BareNativeThrows)

# ---- C1: the PRE-#903 shape mislabels the drift as "errored" (lock-off toggle) ---
$c1 = Invoke-WiringBlock -Src $script:preFixSrc -HostileHost $true -StubExit 1
Check "C1a pre-fix+hostile+exit1: drift path SKIPPED (no drift recorded)" ($null -eq $c1.Drift)
Check "C1b pre-fix+hostile+exit1: mislabeled as 'check errored'" ($c1.Logged -match 'check errored')

Write-Host ''
Write-Host "RESULT: $script:pass passed, $script:fail failed"
if ($script:fail -gt 0) { exit 1 } else { exit 0 }
