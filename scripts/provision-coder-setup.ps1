#requires -Version 5.1
<#
.SYNOPSIS
  The coder's tool-chain setup stage (#775 plan step 4): read-and-run grants for the tool chain the restricted
  coder account must run, and the coder-OWNED opencode configuration installed into the coder's own profile.
  DRY RUN by default; -Apply and -Rollback need an elevated shell.

.DESCRIPTION
  WHAT IT DOES (every step idempotent)
    1. GRANTS   - the folders returned by Get-CoderToolchainReadGrants (coder-setup-lib.ps1), each read-and-run
                  only: the opencode package folder (inheritable), the opencode shim folder (this folder ONLY),
                  the fleet tools folder and the offline docset folder (inheritable). Each target is gated
                  (exists, a real folder, not a link, no link above it) before icacls runs, the entry is built
                  from the coder SID (never a name), and read back: a coder entry with any write right fails the
                  stage. No icacls /T anywhere (it follows directory symlinks).
    2. CONFIG   - the coder's opencode configuration, rendered from the repo (configs/opencode.json minus the MCP
                  block, configs/AGENTS.md in its restricted rendering, the two fleet plugins, the offline-docs
                  tool wrapper whose usage log lives in the coder's own profile) into
                  <coder profile>\.config\opencode, plus the coder's git config at ~/.config/git/config
                  (safe.directory = <worktree base>/*, so git trusts the operator-created worktrees under the
                  base and nothing else). Nothing is read from the operator's profile and no credential is
                  written. Every file gets an explicit access list (Administrators, SYSTEM and the operator full
                  control; the coder read-and-run) and so do the folders ~/.config, opencode, plugin, tool and
                  git, which Administrators OWN: the coder cannot create, replace, rename or delete anything in
                  them. Only opencode
ode_modules is writable for the coder (opencode fills it on first start).
    The coder's profile folder must exist (Windows creates it at the account's first logon); until then the
    stage says so and the config step is PENDING (exit 3), never faked.

  -DryRun    (default) reads and prints; changes NOTHING; needs no elevation.
  -Apply     Elevated. Applies, then re-reads: the grants (read-only coder entry present) and the installed
             configuration (Test-CoderOpencodeConfigInstalled). Exit 1 on any difference.
  -Rollback  Elevated. The targeted undo: removes the coder's entry from each granted folder (the no-follow walk
             for an inheritable grant, the single object for the shim folder) and deletes exactly the files this
             stage installed. Files opencode itself wrote in the config folder (node_modules) are left alone.

  verify-coder-setup.ps1 drives the same functions on a temp tree; the real-account part (the coder really
  reading and running these) is proven by verify-coder-containment.ps1 checks 15-24.
#>
[CmdletBinding()]
param(
    [switch]$DryRun,
    [switch]$Apply,
    [switch]$Rollback,
    [string]$CoderUser = 'blarai-coder',
    [string]$CoderSid = '',
    [string]$OperatorSid = '',
    [string]$AgenticRoot = '',
    [string]$BlarRoot = 'C:\Users\mrbla\blarai',
    [string]$OperatorProfile = 'C:\Users\mrbla',
    [string]$WorktreeBase = 'C:\blarai-fleet\worktrees',
    [string]$ProfilePath = ''
)
$ErrorActionPreference = 'Stop'
if (-not $AgenticRoot) { $AgenticRoot = Split-Path $PSScriptRoot -Parent }
. "$PSScriptRoot\coder-acl-lib.ps1"
. "$PSScriptRoot\coder-leg-queue.ps1"
. "$PSScriptRoot\coder-setup-lib.ps1"

$modes = @($DryRun.IsPresent, $Apply.IsPresent, $Rollback.IsPresent) | Where-Object { $_ }
if (@($modes).Count -gt 1) { throw 'give exactly one of -DryRun, -Apply, -Rollback' }
$mode = if ($Apply) { 'Apply' } elseif ($Rollback) { 'Rollback' } else { 'DryRun' }

function Write-Line([string]$m) { Write-Host $m }
if ($mode -ne 'DryRun') {
    $isAdmin = [Security.Principal.WindowsPrincipal]::new([Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    if (-not $isAdmin) { throw "provision-coder-setup.ps1 -$mode must run ELEVATED (it changes access lists in the operator's folders and writes into the coder's profile)." }
}
if (-not $CoderSid) { try { $CoderSid = (Get-LocalUser $CoderUser -ErrorAction Stop).SID.Value } catch { throw "coder account '$CoderUser' does not exist: run provision-coder-account.ps1 first" } }
if (-not $OperatorSid) { $OperatorSid = ([Security.Principal.WindowsIdentity]::GetCurrent()).User.Value }
if ($CoderSid -eq $OperatorSid) { throw 'the coder SID and the operator SID are the same account: refusing' }

$manifest = Read-CoderToolchainManifest -Path (Join-Path $AgenticRoot 'configs\coder-toolchain.json')
$grants = @(Get-CoderToolchainReadGrants -Manifest $manifest -AgenticRoot $AgenticRoot -BlarRoot $BlarRoot -OperatorProfile $OperatorProfile)
$plan = @(Get-CoderOpencodeConfigPlan -AgenticRoot $AgenticRoot -Manifest $manifest -WorktreeBase $WorktreeBase)
if (-not $ProfilePath) { $ProfilePath = Get-CoderProfilePath -Sid $CoderSid }
$configDir = if ($ProfilePath) { Get-CoderOpencodeConfigDir -ProfilePath $ProfilePath } else { '' }

Write-Line "== coder tool-chain setup ($mode) for $CoderUser ($CoderSid) =="
Write-Line ''
Write-Line '1/2 read-and-run grants (the coder gets READ and RUN on these and nothing else of the operator profile)'
$pending = $false
foreach ($g in $grants) {
    $scope = if ($g.Flags) { 'this folder and everything below it' } else { 'this folder only' }
    $state = 'path-missing'
    $gate = Test-CoderGrantTargetSafe -Path $g.Path
    if ($gate.Ok) { $state = Get-CoderToolchainGrantState -Path $g.Path -CoderSid $CoderSid }
    Write-Line ("  [{0}] {1}  ({2}; now: {3})" -f $g.Id, $g.Path, $scope, $state)
    Write-Line ("        why: {0}" -f $g.Why)
    Write-Line ("        command: icacls {0}" -f ((Get-CoderToolchainGrantCommand -Grant $g -CoderSid $CoderSid) -join ' '))
    Write-Line ("        undo: remove the coder's explicit entry from {0}{1}" -f $g.Path, $(if ($g.Flags) { ' (no-follow walk)' } else { ' (this object only)' }))
    if (-not $gate.Ok) { Write-Line "        GATE: $($gate.Reason)" }
}
Write-Line ''
Write-Line "2/2 coder-owned opencode configuration -> $(if ($configDir) { $configDir } else { '(coder profile does not exist yet)' })"
foreach ($f in $plan) {
    $dest = if ($configDir) { Join-Path (Get-CoderConfigItemBase -ConfigDir $configDir -Item $f) $f.Rel } else { '' }
    $st = 'absent'
    if ($dest -and (Test-Path -LiteralPath $dest -PathType Leaf)) {
        $sha = [Security.Cryptography.SHA256]::Create()
        try { $h = -join ($sha.ComputeHash([IO.File]::ReadAllBytes($dest)) | ForEach-Object { $_.ToString('x2') }) } finally { $sha.Dispose() }
        $st = if ($h -ceq $f.Sha256) { 'identical' } else { 'DIFFERENT' }
    }
    Write-Line ("  {0}  sha256 {1}...  ({2} bytes; now: {3})" -f $f.Rel, $f.Sha256.Substring(0, 16), $f.Bytes.Length, $st)
}
Write-Line '  access list on every file and on .config, opencode, plugin, tool, git (owned by Administrators): Administrators, SYSTEM, operator = full control; coder = read-and-run; nothing inherited. opencode
ode_modules: coder = modify.'
Write-Line '  not written: the MCP block, any plugin declaration, any credential, anything from the operator profile.'
if (-not $configDir) { $pending = $true; Write-Line '  PENDING: the coder has never logged on, so Windows has not created its profile. Run verify-coder-containment.ps1 once (its task logs the coder on), then re-run this stage.' }

if ($mode -eq 'DryRun') {
    Write-Line ''
    Write-Line 'DRY RUN: nothing was changed. Re-run with -Apply (elevated) to apply, -Rollback to undo.'
    if ($pending) { exit 3 }
    exit 0
}

$problems = New-Object System.Collections.ArrayList
if ($mode -eq 'Apply') {
    foreach ($g in $grants) {
        try { Invoke-CoderToolchainGrant -Grant $g -CoderSid $CoderSid -Out { param($m) Write-Line $m }; Write-Line "  [ok] granted read-and-run on $($g.Path)" }
        catch { [void]$problems.Add($_.Exception.Message); Write-Host "  [FAIL] $($_.Exception.Message)" -ForegroundColor Red }
    }
    if ($configDir) {
        try {
            $r = Install-CoderOpencodeConfig -ConfigDir $configDir -Plan $plan -CoderSid $CoderSid -OperatorSid $OperatorSid -Out { param($m) Write-Line $m }
            $v = Test-CoderOpencodeConfigInstalled -ConfigDir $configDir -Plan $plan -CoderSid $CoderSid
            if ($v.Pass) { Write-Line "  [ok] configuration installed and re-read ($($r.Written.Count) written, $($r.Unchanged.Count) unchanged)" }
            else { [void]$problems.Add("installed configuration check failed: $($v.Failed -join ', ')"); Write-Host "  [FAIL] installed configuration check failed: $($v.Failed -join ', ')" -ForegroundColor Red }
        } catch { [void]$problems.Add($_.Exception.Message); Write-Host "  [FAIL] $($_.Exception.Message)" -ForegroundColor Red }
    }
} else {
    foreach ($g in $grants) {
        $gate = Test-CoderGrantTargetSafe -Path $g.Path
        if (-not $gate.Ok) { Write-Line "  [skip] $($g.Id): $($gate.Reason)"; continue }
        try { Invoke-CoderToolchainGrant -Grant $g -CoderSid $CoderSid -Undo; Write-Line "  [ok] removed the coder entry from $($g.Path)" }
        catch { [void]$problems.Add($_.Exception.Message); Write-Host "  [FAIL] $($_.Exception.Message)" -ForegroundColor Red }
    }
    if ($configDir -and (Test-Path -LiteralPath $configDir)) {
        $removed = Remove-CoderOpencodeConfig -ConfigDir $configDir -Plan $plan -Out { param($m) Write-Line $m }
        Write-Line "  [ok] removed $($removed.Count) installed configuration file(s)"
    } else { Write-Line '  [skip] no coder configuration folder' }
}
Write-Line ''
if ($problems.Count -gt 0) { Write-Host "RESULT: $mode finished WITH PROBLEMS ($($problems.Count))" -ForegroundColor Red; exit 1 }
if ($pending) { Write-Host "RESULT: $mode finished; configuration step PENDING (coder profile missing)" -ForegroundColor Yellow; exit 3 }
Write-Host "RESULT: $mode complete" -ForegroundColor Green
exit 0
