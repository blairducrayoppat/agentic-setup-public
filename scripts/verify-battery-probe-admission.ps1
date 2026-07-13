# verify-battery-probe-admission.ps1 -- offline structural locks for the #784
# probe-not-predict swap admission rework of run-battery-night.ps1.
#
# The rework must keep four invariants, or the night's admission logic silently
# regresses (a probe under -Now would stop the operator's live AO in daylight; a
# probe outside the marginal band would fire on a starved box; a missing exit
# branch would ignore the probe's answer; a broken fast path would probe every
# night). These AST/content checks make each invariant structural:
#   S1  the probe (`-m tools.dispatch_harness.probe`) is invoked EXACTLY ONCE.
#   S2  that invocation lives inside Test-NightAdmission, in the MARGINAL BAND --
#       guarded by both the fast-path return and the PROBE_FLOOR floor before it.
#   S3  the probe's EXIT CODE is branched on (`$probeExit -eq 0`).
#   S4  the FAST PATH is intact (projected >= $LEAN_GATE_GIB short-circuits).
#   S5  the probe is UNREACHABLE under -Now: Test-NightAdmission is called exactly
#       once and only inside an `if (-not $Now)` guard; the -Now branch measures
#       only (never probes).
$ErrorActionPreference = 'Stop'
$script:pass = 0; $script:fail = 0
function Check([string]$name, [bool]$ok) {
    if ($ok) { $script:pass++; Write-Host "  [PASS] $name" }
    else     { $script:fail++; Write-Host "  [FAIL] $name" -ForegroundColor Red }
}

$launcher = Join-Path $PSScriptRoot 'run-battery-night.ps1'
$ast = [System.Management.Automation.Language.Parser]::ParseFile($launcher, [ref]$null, [ref]$null)
$CommandAst  = [System.Management.Automation.Language.CommandAst]
$FuncAst     = [System.Management.Automation.Language.FunctionDefinitionAst]
$IfAst       = [System.Management.Automation.Language.IfStatementAst]

function Get-EnclosingFunction($node) {
    $p = $node.Parent
    while ($p) { if ($p -is $FuncAst) { return $p }; $p = $p.Parent }
    return $null
}

# S1 -- exactly one probe invocation.
$probeCalls = $ast.FindAll({ param($n) $n -is $CommandAst -and
                             $n.Extent.Text -match 'tools\.dispatch_harness\.probe' }, $true)
Check "S1 exactly one probe invocation (got $($probeCalls.Count))" ($probeCalls.Count -eq 1)

if ($probeCalls.Count -eq 1) {
    $probe = $probeCalls[0]
    $fn = Get-EnclosingFunction $probe

    # S2 -- inside Test-NightAdmission, in the marginal band (fast-path + floor guards precede it).
    Check "S2a probe is inside Test-NightAdmission" ($fn -and $fn.Name -eq 'Test-NightAdmission')
    if ($fn) {
        $fnText = $fn.Extent.Text
        $before = $fnText.Substring(0, $probe.Extent.StartOffset - $fn.Extent.StartOffset)
        Check "S2b fast-path return precedes the probe (Projected -ge LEAN_GATE)" `
            ($before -match '\$h\.Projected\s+-ge\s+\$LEAN_GATE_GIB')
        Check "S2c PROBE_FLOOR floor-guard precedes the probe (Avail -lt PROBE_FLOOR -> retry)" `
            (($before -match '\$h\.Avail\s+-lt\s+\$PROBE_FLOOR_GIB') -and ($before -match 'return \$false'))
        Check "S2d probe passes --min-free-gb `$PROBE_FLOOR_GIB" `
            ($probe.Extent.Text -match '--min-free-gb\s+\$PROBE_FLOOR_GIB')

        # S3 -- the probe's exit code is branched on, after the call.
        $after = $fnText.Substring($probe.Extent.StartOffset - $fn.Extent.StartOffset)
        Check "S3 exit-code branch present after the probe (`$probeExit -eq 0)" `
            ($after -match '\$probeExit\s+-eq\s+0')
    }
}

# S4 -- the fast path is intact (projected clears the gate short-circuits admission).
$src = Get-Content $launcher -Raw
Check "S4 fast path intact (Projected -ge LEAN_GATE_GIB present)" `
    ($src -match '\$h\.Projected\s+-ge\s+\$LEAN_GATE_GIB')
Check "S4b PROBE_FLOOR_GIB constant defined (15.0 sanity floor)" `
    ($src -match '\$PROBE_FLOOR_GIB\s*=\s*15')

# S5 -- the probe is unreachable under -Now.
$callSites = $ast.FindAll({ param($n) $n -is $CommandAst -and
                            $n.GetCommandName() -eq 'Test-NightAdmission' }, $true)
Check "S5a Test-NightAdmission called exactly once (got $($callSites.Count))" ($callSites.Count -eq 1)
if ($callSites.Count -eq 1) {
    $call = $callSites[0]
    $guarded = $false
    $p = $call.Parent
    while ($p) {
        if ($p -is $IfAst) {
            foreach ($clause in $p.Clauses) {
                if ($clause.Item1.Extent.Text -match '-not\s+\$Now' -and
                    $clause.Item1.Extent.StartOffset -lt $call.Extent.StartOffset -and
                    $clause.Item2.Extent.EndOffset -ge $call.Extent.EndOffset) { $guarded = $true }
            }
        }
        $p = $p.Parent
    }
    Check "S5b the Test-NightAdmission call sits inside an `if (-not `$Now)` guard" $guarded
}
# S5c -- the -Now (else) branch measures only, never probes.
Check "S5c -Now branch measures only (NOT probing)" ($src -match 'NOT blocking, NOT probing')

Write-Host ""
Write-Host "RESULT: $script:pass passed, $script:fail failed"
if ($script:fail -gt 0) { exit 1 } else { exit 0 }
