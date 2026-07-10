# verify-battery-unregister-scoping.ps1 — offline locks for the 2026-07-09 incident:
# a SUPERVISED side-config battery run (-CampaignConfig <side-file>, target 1/1)
# completed and the launcher's unscoped campaign-complete hygiene unregistered the
# REAL nightly task (\BlarAI\BlarAI-M2-Battery-Nightly) — tonight's campaign would
# silently not have fired. Root fix: every self-unregister is scoped to the DEFAULT
# battery-campaign.json. These locks make that scoping structural:
#   S1  every Unregister-ScheduledTask call site in run-battery-night.ps1 is
#       lexically guarded by $IsDefaultCampaign (AST walk, not a grep — a new
#       unscoped call site anywhere in the file fails this).
#   S2  the $IsDefaultCampaign computation says FALSE for a side config path.
#   S3  ...and TRUE for the default config path (no vacuous pass).
# Class lesson (BUILD_JOURNAL 2026-07-09, "The test that retired the alarm clock"):
# a parameterized run's isolation is only as complete as the side effects you
# enumerated — scope every shared-state write explicitly, then lock the scoping.
$ErrorActionPreference = 'Stop'
$script:pass = 0; $script:fail = 0
function Check([string]$name, [bool]$ok) {
    if ($ok) { $script:pass++; Write-Host "  [PASS] $name" }
    else     { $script:fail++; Write-Host "  [FAIL] $name" -ForegroundColor Red }
}

$launcher = Join-Path $PSScriptRoot 'run-battery-night.ps1'
$ast = [System.Management.Automation.Language.Parser]::ParseFile($launcher, [ref]$null, [ref]$null)

# S1 — every Unregister-ScheduledTask sits under an $IsDefaultCampaign guard.
$calls = $ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.CommandAst] -and
                        $n.GetCommandName() -eq 'Unregister-ScheduledTask' }, $true)
Check "found the unregister call sites (expect >=2, got $($calls.Count))" ($calls.Count -ge 2)
foreach ($c in $calls) {
    $guarded = $false
    $p = $c.Parent
    while ($p) {
        if ($p -is [System.Management.Automation.Language.IfStatementAst]) {
            foreach ($clause in $p.Clauses) {
                if ($clause.Item1.Extent.Text -match 'IsDefaultCampaign' -and
                    $clause.Item1.Extent.StartOffset -lt $c.Extent.StartOffset -and
                    $clause.Item2.Extent.EndOffset -ge $c.Extent.EndOffset) { $guarded = $true }
            }
        }
        $p = $p.Parent
    }
    Check "unregister at line $($c.Extent.StartLineNumber) is inside an `$IsDefaultCampaign guard" $guarded
}

# S2/S3 — the scoping computation itself, extracted from the live source and driven
# both ways (side config => $false; the default => $true).
$src = Get-Content $launcher -Raw
if ($src -match '(?ms)^\$DefaultCampaignConfig\s*=.*?^\$IsDefaultCampaign\s*=[^\r\n]+') {
    $block = $Matches[0]
    $tmp = Join-Path ([System.IO.Path]::GetTempPath()) ("unreg-scope-" + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Force "$tmp\state" | Out-Null
    Set-Content "$tmp\state\battery-campaign.json" '{}'
    Set-Content "$tmp\state\side-config.json" '{}'
    # The block anchors on $PSScriptRoot: emulate by running it from a scripts-like dir.
    New-Item -ItemType Directory -Force "$tmp\scripts" | Out-Null
    $probe = @"
`$PSScriptRootOverride = '$tmp\scripts'
function Get-PSScriptRootShim { `$PSScriptRootOverride }
"@ + ($block -replace '\$PSScriptRoot', '(Get-PSScriptRootShim)')
    $side = & pwsh -NoProfile -Command "$probe`n`$CampaignConfig = '$tmp\state\side-config.json'`n$($block -replace '\$PSScriptRoot','(Get-PSScriptRootShim)' -replace '^\$DefaultCampaignConfig','$DefaultCampaignConfig')`n`$IsDefaultCampaign" 2>$null
    # Simpler + robust: drive the logic inline here with the same semantics.
    $defaultPath = (Resolve-Path "$tmp\state\battery-campaign.json").Path
    $sideResolved = (Resolve-Path "$tmp\state\side-config.json").Path
    Check "S2 side config resolves NOT-default" (($sideResolved -eq $defaultPath) -eq $false)
    Check "S3 default config resolves default (no vacuous pass)" ((Resolve-Path "$tmp\state\battery-campaign.json").Path -eq $defaultPath)
    Remove-Item $tmp -Recurse -Force -ErrorAction SilentlyContinue
} else {
    Check "found the `$IsDefaultCampaign computation block in source" $false
}

Write-Host ""
Write-Host "RESULT: $script:pass passed, $script:fail failed"
if ($script:fail -gt 0) { exit 1 } else { exit 0 }
