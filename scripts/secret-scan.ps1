# secret-scan.ps1 - scan a repo/worktree's STAGED changes for secrets with
# gitleaks. Used by the fleet BEFORE it commits agent output, so a leaked
# credential never enters git history and never auto-merges.
#
# FAIL-CLOSED: any gitleaks detection (or an unexpected gitleaks error) returns
# 'blocked'. If gitleaks is not installed it returns 'unavailable' (the caller
# decides; the fleet warns loudly but does not brick itself pre-install).
#
#   $r = .\secret-scan.ps1 -Repo C:\...\worktree
#   $r.status  ->  'clean' | 'blocked' | 'unavailable'
#   $r.count, $r.detail
param(
    [Parameter(Mandatory)][string]$Repo,
    [string]$GitleaksExe = 'C:\Users\mrbla\agentic-setup\tools\gitleaks\gitleaks.exe',
    [string]$Config      = 'C:\Users\mrbla\agentic-setup\configs\gitleaks\gitleaks.toml'
)
# gitleaks writes its INFO log (e.g. "0 commits scanned") to stderr; under Windows
# PowerShell 5.1 with EAP=Stop that becomes a fatal NativeCommandError. Use Continue;
# we read gitleaks' real result from its exit code ($LASTEXITCODE) below.
$ErrorActionPreference = 'Continue'

if (-not (Test-Path $GitleaksExe)) {
    return [pscustomobject]@{ status = 'unavailable'; count = 0; detail = 'gitleaks not installed (run install-gitleaks.ps1)' }
}
if (-not (Test-Path (Join-Path $Repo '.git'))) {
    return [pscustomobject]@{ status = 'blocked'; count = 0; detail = "not a git repo: $Repo (failing closed)" }
}

$report = Join-Path $env:TEMP ("gl-" + [guid]::NewGuid().ToString('N').Substring(0, 8) + '.json')
$cfg = @(); if ($Config -and (Test-Path $Config)) { $cfg = @('--config', $Config) }
$findings = @()
Push-Location $Repo
try {
    # gitleaks v8: scan staged changes of the repo in CWD
    & $GitleaksExe git --staged --no-banner --redact --report-format json --report-path $report --exit-code 1 @cfg *> $null
    $code = $LASTEXITCODE
} finally {
    Pop-Location
}
$reportParseError = $null
if (Test-Path $report) {
    try { $findings = @(Get-Content $report -Raw -Encoding UTF8 | ConvertFrom-Json) } catch { $reportParseError = $_.Exception.Message }
    Remove-Item $report -ErrorAction SilentlyContinue
}
$count = $findings.Count

if ($code -eq 0) {
    return [pscustomobject]@{ status = 'clean'; count = 0; detail = 'no secrets in staged changes' }
}
if ($reportParseError) {
    # gitleaks flagged something but its report is unreadable - fail closed with a clear reason.
    return [pscustomobject]@{ status = 'blocked'; count = 0; detail = "gitleaks report unreadable (disk full / interrupted?): $reportParseError; failing closed" }
}
if ($code -eq 1 -or $count -gt 0) {
    $detail = (@($findings | ForEach-Object { "$($_.RuleID) in $($_.File)" }) | Select-Object -Unique -First 10) -join '; '
    if (-not $detail) { $detail = 'gitleaks reported a finding' }
    return [pscustomobject]@{ status = 'blocked'; count = $count; detail = $detail }
}
# Unexpected gitleaks exit (bad args, internal error): fail closed.
return [pscustomobject]@{ status = 'blocked'; count = 0; detail = "gitleaks exited $code unexpectedly; failing closed" }
