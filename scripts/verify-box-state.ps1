#requires -Version 7.0
<#
.SYNOPSIS
  Verify box-state.ps1 (#816): the canonical box-state report is (a) genuinely
  READ-ONLY, (b) complete (every consumer-class section present), (c) enumerates
  ALL Hyper-V guests rather than a known name (the unnoticed-VM incident fix), and
  (d) fail-loud ONLY under -Baseline lean - the default read-only path can never
  exit non-zero.

.DESCRIPTION
  Two layers, both safe to run on a live box (they only INVOKE the read-only report):

  STRUCTURE (AST + static - the safety + completeness invariants):
    S1  box-state.ps1 parses with zero syntax errors.
    S2  it invokes NO mutating cmdlet (AST denylist: Stop-Process / *-VM / taskkill /
        Stop-ProcessTree / *-ScheduledTask writers / Remove-Item / file writers /
        service+power writers). This is the load-bearing "it is a REPORT" lock.
    S3  every consumer-class section is present ([VM] [MODEL] [AO] [PORTS] [GPU]
        [PROC] [RAM] [TASK]) plus the [BASELINE] verdict.
    S4  it enumerates ALL guests: Get-VM is called and NEVER as `Get-VM -Name <x>`
        (the incident was a VM invisible to a known-name/process sweep).
    S5  the surface is parameterized as specified: -Baseline is ValidateSet('lean'),
        -MinLeanAvailableGiB has a numeric default, -Ports defaults include the
        canonical 5001/8000/8099/9000.
    S6  the default path cannot fail the caller: every non-zero `exit` is lexically
        guarded by an `if ($Baseline ...)` block (AST walk, like
        verify-stop-assistant.ps1's kill-site guard), and at least one `exit 0` exists.

  BEHAVIOR (live, read-only - never starts a VM / model; proves fail-loud by the
  parameter trick the ticket calls for, not by making the box non-lean):
    B1  a default invocation exits 0 and prints every section tag.
    B2  `-Baseline lean -MinLeanAvailableGiB 9999` forces the RAM dimension over the
        floor -> exit 1, prints "LEAN: FAIL" and names the below-band deviation, AND
        still prints the sections (proves report-THEN-verdict, not fail-fast-silent).
    B3  `-Baseline lean -MinLeanAvailableGiB 0` -> the below-band deviation is ABSENT
        (proves the band is really evaluated, not hard-failing). Exit code is not
        asserted - it legitimately depends on live VM/OVMS/AO state.
    B4  a second default invocation still exits 0 (side-effect-free / idempotent;
        the strong no-mutation guarantee is S2).

  Run it normally ( .\verify-box-state.ps1 ) - do NOT dot-source it.
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

$boxState = Join-Path $PSScriptRoot 'box-state.ps1'
Check "box-state.ps1 exists" (Test-Path $boxState)
if (-not (Test-Path $boxState)) {
    Write-Host "RESULT: $($script:Pass) passed, $($script:Fail) failed" -ForegroundColor Red
    exit 1
}

# ===========================================================================
# STRUCTURE - AST + static
# ===========================================================================
$errors = $null
$ast = [System.Management.Automation.Language.Parser]::ParseFile($boxState, [ref]$null, [ref]$errors)
$src = Get-Content $boxState -Raw
$CommandAst = [System.Management.Automation.Language.CommandAst]
$IfAst      = [System.Management.Automation.Language.IfStatementAst]
$ExitAst    = [System.Management.Automation.Language.ExitStatementAst]

Section 'S1  parses clean'
Check "S1 box-state.ps1 parses with zero syntax errors" (@($errors).Count -eq 0)

Section 'S2  READ-ONLY - no mutating cmdlet anywhere (the report lock)'
$deny = @(
    'Stop-Process', 'Stop-VM', 'Remove-VM', 'Set-VM', 'Suspend-VM', 'Checkpoint-VM', 'Start-VM',
    'taskkill', 'taskkill.exe', 'Stop-ProcessTree',
    'Unregister-ScheduledTask', 'Stop-ScheduledTask', 'Start-ScheduledTask', 'Disable-ScheduledTask', 'Enable-ScheduledTask', 'Register-ScheduledTask',
    'Remove-Item', 'Set-Content', 'Out-File', 'Add-Content', 'Clear-Content', 'New-Item', 'Move-Item', 'Rename-Item',
    'Stop-Service', 'Restart-Service', 'Start-Service', 'Set-Service', 'Restart-Computer', 'Stop-Computer',
    'Set-ItemProperty', 'Remove-ItemProperty'
)
$cmdNames = @($ast.FindAll({ param($n) $n -is $CommandAst }, $true) | ForEach-Object { $_.GetCommandName() } | Where-Object { $_ })
$hits = @($cmdNames | Where-Object { $_ -in $deny } | Sort-Object -Unique)
Check "S2 invokes NO mutating cmdlet (denylist hits: $(if ($hits) { $hits -join ', ' } else { 'none' }))" ($hits.Count -eq 0)

Section 'S3  every consumer-class section is present'
foreach ($tag in @('[VM]', '[MODEL]', '[AO]', '[PORTS]', '[GPU]', '[PROC]', '[RAM]', '[TASK]', '[BASELINE]')) {
    Check "S3 section $tag present in source" ($src.Contains($tag))
}

Section 'S4  enumerates ALL Hyper-V guests (never a known name)'
Check "S4 calls Get-VM" ($cmdNames -contains 'Get-VM')
Check "S4 does NOT scope Get-VM to a known name (no 'Get-VM -Name')" (-not ($src -match 'Get-VM\s+-Name'))

Section 'S5  parameterized surface (Baseline / MinLeanAvailableGiB / Ports)'
Check "S5 -Baseline is ValidateSet('lean')" ($src -match "\[ValidateSet\('lean'\)\]")
Check "S5 -MinLeanAvailableGiB has a numeric default" ($src -match '\$MinLeanAvailableGiB\s*=\s*[0-9]')
Check "S5 -Ports param present" ($src -match '\[int\[\]\]\$Ports')
Check "S5 -Ports default includes 5001 and 8000 (AO + OVMS)" (($src -match '5001') -and ($src -match '8000'))
Check "S5 -Ports default includes 8099 and 9000" (($src -match '8099') -and ($src -match '9000'))

Section 'S6  the default read-only path can never exit non-zero'
$exits = @($ast.FindAll({ param($n) $n -is $ExitAst }, $true))
$zeroExits = @($exits | Where-Object { $_.Pipeline -and $_.Pipeline.Extent.Text.Trim() -eq '0' })
$nonZeroExits = @($exits | Where-Object { $_.Pipeline -and $_.Pipeline.Extent.Text.Trim() -ne '0' })
Check "S6 at least one 'exit 0' exists (the read-only path)" ($zeroExits.Count -ge 1)
Check "S6 at least one non-zero exit exists (the fail-loud path)" ($nonZeroExits.Count -ge 1)
foreach ($e in $nonZeroExits) {
    $guarded = $false
    $p = $e.Parent
    while ($p) {
        if ($p -is $IfAst) {
            foreach ($clause in $p.Clauses) {
                if ($clause.Item1.Extent.Text -match '\$Baseline') { $guarded = $true }
            }
        }
        $p = $p.Parent
    }
    Check "S6 'exit $($e.Pipeline.Extent.Text)' at line $($e.Extent.StartLineNumber) is inside an if (`$Baseline ...) guard" $guarded
}

# ===========================================================================
# BEHAVIOR - live, read-only (safe while a battery pass runs)
# ===========================================================================
function Invoke-BoxState([string[]]$BoxArgs) {
    $raw = & pwsh -NoProfile -ExecutionPolicy Bypass -File $boxState @BoxArgs 2>&1
    $code = $LASTEXITCODE
    return @{ Code = $code; Out = ($raw | Out-String) }
}

Section 'B1  default invocation - exit 0, all sections printed'
$r1 = Invoke-BoxState @()
Check "B1 default exits 0" ($r1.Code -eq 0)
foreach ($tag in @('[VM]', '[MODEL]', '[AO]', '[PORTS]', '[GPU]', '[PROC]', '[RAM]', '[TASK]')) {
    Check "B1 output contains section $tag" ($r1.Out.Contains($tag))
}

Section 'B2  -Baseline lean -MinLeanAvailableGiB 9999 - fail-loud (parameter trick)'
$r2 = Invoke-BoxState @('-Baseline', 'lean', '-MinLeanAvailableGiB', '9999')
Check "B2 exits 1 (forced RAM dimension over floor)" ($r2.Code -eq 1)
Check "B2 prints 'LEAN: FAIL'" ($r2.Out -match 'LEAN: FAIL')
Check "B2 names the below-lean-band deviation (floor 9999)" ($r2.Out -match 'below lean band 9999')
Check "B2 still printed the report (sections precede the verdict)" (($r2.Out.Contains('[VM]')) -and ($r2.Out.Contains('[RAM]')))

Section 'B3  -MinLeanAvailableGiB 0 - the RAM band is really evaluated (not hard-failing)'
$r3 = Invoke-BoxState @('-Baseline', 'lean', '-MinLeanAvailableGiB', '0')
Check "B3 at floor 0 the RAM below-band deviation is ABSENT" (-not ($r3.Out -match 'below lean band'))

Section 'B4  side-effect-free - a second default run still exits 0'
$r4 = Invoke-BoxState @()
Check "B4 second default run exits 0 (idempotent / no mutation)" ($r4.Code -eq 0)

Write-Host ''
if ($script:Fail -eq 0) {
    Write-Host "RESULT: $($script:Pass) passed, 0 failed" -ForegroundColor Green
    exit 0
} else {
    Write-Host "RESULT: $($script:Pass) passed, $($script:Fail) failed" -ForegroundColor Red
    exit 1
}
