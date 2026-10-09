#requires -Version 5.1
<#
.SYNOPSIS
  The ONE operator-run ACL stage for the coder containment floor: #1678 (the coder loses Modify on the
  projects folder and gets read only), #1686 (C:\blarai-fleet stops being writable by every local account,
  plus the worktree-root deny and the orphan-SID entry), #1692 (the model folders stop being writable by
  other accounts). Idempotent. Run with -DryRun first.

.DESCRIPTION
  MODES (exactly one; with none, it is a dry run):
    -DryRun            Read-only. Prints, per folder and in plain language: what it is for, what the access
                       list looks like NOW, what it will look like AFTER, the exact icacls commands, and the
                       undo for each. Also lists links inside the trees (never entered) and anything it
                       REFUSES, and ends with a PLAN DIGEST (a hash of what it printed). Changes nothing.
                       Needs no elevation, BUT a reader that cannot open some folders lists them under
                       UNREADABLE and gives NO digest: run it elevated (the same elevated window as -Apply), or
                       add -AllowUnreadable once you have read that list (it then belongs to the digest).
    -Apply -ExpectPlan <digest>
                       Elevated. Plans again first and REFUSES, printing what differs, unless the plan is the
                       one whose digest you pass (the one you read). Then saves the current access lists to a
                       backup folder, applies the changes, reads every folder back and compares it with the
                       printed AFTER, and scans for remaining write access. Exits non-zero if anything differs
                       or remains. Rolls nothing back by itself.
    -Rollback          Elevated. Runs each action's targeted undo, last action first (the UNDO listing printed
                       by -DryRun and saved by -Apply in the backup folder as plan.json). With more than one backup
                       folder it REFUSES unless you name one with -From <folder> (the OLDEST holds the full
                       original undo set; after a second -Apply the newest does not). Re-opens #1678, #1686
                       and #1692: it does what it says.
    -RestoreFrom <dir> Elevated. Puts back the exact access lists saved by an earlier -Apply.

  WHAT IT WILL NOT DO: touch a path that is relative, has a wildcard or a dot-dot, is a drive root, a system
  folder or the profile root (under any spelling: 8.3 short names, trailing dots or spaces, letter case, \\?\
  and \\.\ prefixes are normalised or refused first), does not exist, is itself a link, or sits below a link.
  Links INSIDE a tree are listed and never entered: the stage walks trees itself and re-checks every object on
  its own open handle just before changing it (icacls /T is not used: it follows directory symlinks even with
  /L). Residual: see docs/reviews/provisioning-1678-1686-1692-decisions-2026-10-05.md. It does not touch
  accounts, the firewall or scheduled tasks. It
  stops if the coder-leg task is Running (Apply). It does not change the coder's read access to anything
  outside the folders named here.

  The commands are built from SIDs (*S-1-...), never account names. The same code is exercised on a temp tree by
  verify-coder-narrowing.ps1, with the current user standing in for the coder.
#>
[CmdletBinding()]
param(
    [switch]$DryRun,
    [switch]$Apply,
    [switch]$Rollback,
    [string]$RestoreFrom = '',
    [string]$From = '',
    [string]$ExpectPlan = '',
    [switch]$AllowUnreadable,
    [string[]]$CoderGroupSids = @(),
    [string]$CoderUser = 'blarai-coder',
    [string]$CoderSid = '',
    [string]$OperatorSid = '',
    [string]$ProjectsDir = 'C:\Users\mrbla\projects',
    [string]$WorktreeBase = 'C:\blarai-fleet\worktrees',
    [string[]]$ModelRoots = @('B:\models', 'C:\models', 'C:\Users\mrbla\BlarAI\models'),
    [string[]]$ProfileCleanupPaths = @('C:\Users\mrbla\BlarAI'),
    [string[]]$ModelReaderSids = @(),
    [string]$BackupRoot = '',
    [string]$TaskPath = '\BlarAI\',
    [string]$TaskName = 'BlarAI-Coder-Leg'
)
$ErrorActionPreference = 'Stop'
. "$PSScriptRoot\coder-acl-lib.ps1"

$modes = @($DryRun.IsPresent, $Apply.IsPresent, $Rollback.IsPresent, [bool]$RestoreFrom) | Where-Object { $_ }
if (@($modes).Count -gt 1) { throw 'give exactly one of -DryRun, -Apply, -Rollback, -RestoreFrom' }
$mode = if ($Apply) { 'Apply' } elseif ($Rollback) { 'Rollback' } elseif ($RestoreFrom) { 'Restore' } else { 'DryRun' }

if ($mode -ne 'DryRun') {
    $isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    if (-not $isAdmin) { throw "provision-coder-acls.ps1 -$mode must run ELEVATED (it changes folder access lists). Run -DryRun first; it needs no elevation." }
}
if (-not $OperatorSid) { $OperatorSid = ([Security.Principal.WindowsIdentity]::GetCurrent()).User.Value }
if (-not $CoderSid -and $mode -ne 'Restore') {
    try { $CoderSid = (Get-LocalUser -Name $CoderUser -ErrorAction Stop).SID.Value }
    catch { throw "the coder account '$CoderUser' does not exist: run provision-coder-account.ps1 first (or pass -CoderSid)." }
}
$taskState = ''
try { $taskState = [string](Get-ScheduledTask -TaskPath $TaskPath -TaskName $TaskName -ErrorAction SilentlyContinue).State } catch { $taskState = '' }
if (-not $BackupRoot) { $BackupRoot = Join-Path (Split-Path $PSScriptRoot -Parent) 'state\acl-backup' }
$backupDir = Join-Path $BackupRoot (Get-Date -Format 'yyyyMMdd-HHmmss')

if ($mode -eq 'DryRun') {
    Write-Host "operator account SID: $OperatorSid   coder account SID: $CoderSid" -ForegroundColor Cyan
}
$rollbackFrom = ''
if ($mode -eq 'Rollback') {
    $rollbackFrom = if ($From) { $From } else { Select-AclRollbackBackup -BackupRoot $BackupRoot }
    if (-not $rollbackFrom) { throw "no backup folder with a plan.json under '$BackupRoot': nothing to roll back from (pass -From <folder>, or use -RestoreFrom)." }
    Write-Host "rolling back from $rollbackFrom" -ForegroundColor Cyan
}
$r = Invoke-CoderAclStage -Mode $mode -CoderSid $CoderSid -OperatorSid $OperatorSid -ProjectsDir $ProjectsDir -WorktreeBase $WorktreeBase `
    -ModelRoots $ModelRoots -ProfileCleanupPaths $ProfileCleanupPaths -ModelReaderSids $ModelReaderSids `
    -BackupDir $backupDir -RestoreFrom $RestoreFrom -RollbackFrom $rollbackFrom -TaskState $taskState `
    -CoderGroupSids $CoderGroupSids -AllowUnreadable:$AllowUnreadable -ExpectPlan $ExpectPlan -PlanStoreDir (Join-Path $BackupRoot 'plans')
if ($mode -eq 'Apply' -and $r.BackupDir) { Write-Host "backup of the previous access lists: $($r.BackupDir)  (restore: provision-coder-acls.ps1 -RestoreFrom `"$($r.BackupDir)`")" -ForegroundColor Cyan }
if (-not $r.Ok) { exit 1 }
exit 0
