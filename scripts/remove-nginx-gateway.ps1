#requires -Version 7.0
<#
.SYNOPSIS
  Removes the vestigial NginxGateway service and the things that run code from C:\nginx (#1695). LA-RUN, from an
  elevated PowerShell. DRY RUN BY DEFAULT: without -Execute it prints exactly what it would act on and changes
  nothing (it writes no file either).

.DESCRIPTION
  WHY. C:\nginx and nginx.exe are writable by every signed-in account, and the NginxGateway service runs that
  executable as LocalSystem at boot, so a low-privilege account (the contained coder included) could become
  SYSTEM. Two enabled boot tasks read scripts from the same folder.

  WHAT IT TOUCHES: an EXACT allowlist, compiled into this file, never a pattern. Anything not named here cannot be
  acted on, whatever the system holds (the guard is checked again immediately before every action):
    service        NginxGateway (only when its image path is C:\nginx\nginx.exe)
    scheduled      the twelve tasks named in $script:RemovalAllowedTasks, in the root task folder only, only when
    tasks          an action names nginx
    firewall       the three inbound-allow rules named in $script:RemovalAllowedRules
    rules
    folder         C:\nginx (taken over, locked to SYSTEM + Administrators, then MOVED into an admin-only
                   quarantine; never edited in place)

  DECISIONS THIS SCRIPT DOES NOT MAKE (the operator's switches):
    -Scope          which classes to act on. Default: all four. Removing the folder while the service or an
                    enabled task still points at it is refused (any user could re-create C:\nginx and the entry
                    would run it).
    -DeleteQuarantine  permanent deletion of the quarantined copy. WITHOUT it the folder (private keys, a git
                    bundle) is kept, admin-only, at C:\ProgramData\nginx-quarantine\nginx.

  SAFETY, in order: preconditions first (elevated; no nginx process; nothing listening on 443/8081; identities of
  every named item match; no other service/task still references C:\nginx; the nginx.conf copy exists and matches;
  the quarantine is on the same volume); then each step logs, acts, and VERIFIES its postcondition and stops on a
  failure (exit 3, re-run after fixing: finished steps report 'already done'). The folder lock is a link-safe
  walk: a junction or symlink inside the tree is listed and never entered. The conf copy is never overwritten: a
  differing existing copy gets a new timestamped name.

  EXIT CODES  0 done / dry run clean   2 refused before any change   3 a step failed (partial; re-run)
  SYSTEM CALLS go through a table (New-NginxRemovalSystem), so verify-nginx-removal.ps1 drives this exact code
  against fakes; the file is dot-sourceable and then does nothing.
#>
param(
    [switch]$Execute,
    [switch]$DeleteQuarantine,
    [ValidateSet('Service', 'Tasks', 'FirewallRules', 'Folder')][string[]]$Scope = @('Service', 'Tasks', 'FirewallRules', 'Folder')
)
$ErrorActionPreference = 'Stop'
. "$PSScriptRoot\coder-acl-lib.ps1"   # the link-safe walk and the handle-based access-list edit

# ---- the compiled-in allowlists and constants ------------------------------------------------------------
$script:RemovalAllowedService = @('NginxGateway')
$script:RemovalAllowedTasks = @('NginxGatewayWatchdog', 'WslAgentBoot', 'NginxGateway', 'nginx-background', 'NginxAtBoot', 'NginxReload', 'NginxReloadNow', 'NginxReopenLogsNow', 'NginxQuitNow', 'NginxLogRotateWeekly', 'GatewayNginxMonthlyBackup', 'GatewayNginxPruneMonthly')
$script:RemovalAllowedRules = @('nginx.exe HTTPS (App)', 'nginx HTTPS 443 (Port)', 'TEMP-Allow-HTTPS')
$script:RemovalTrustedSids = @('S-1-5-18', 'S-1-5-32-544')   # SYSTEM, Administrators: the only principals the locked folder keeps
$script:RemovalAllowedFolder = 'C:\nginx'
$script:RemovalPorts = @(443, 8081)
$script:RemovalProduction = @{
    Folder = 'C:\nginx'
    ServiceImagePrefix = 'C:\nginx\nginx.exe'
    QuarantineRoot = 'C:\ProgramData\nginx-quarantine'
    ConfBackupDir = 'C:\Users\mrbla\blarai-research-data\ideation\nginx-gateway-conf-backup-20261008'
    LogDir = 'C:\Users\mrbla\blarai-research-data\ideation'
}

function Invoke-RemovalTakeown {
    # takeown.exe on ONE object (never /R: that recursion follows links). /A hands ownership to the Administrators
    # group; without it takeown assigns the CURRENT USER, which the lock check then rejects as an untrusted owner.
    param([Parameter(Mandatory)][string]$Path)
    $o = & takeown.exe /A /F $Path 2>&1
    if ($LASTEXITCODE -ne 0) { throw "takeown failed for '$Path' (exit $LASTEXITCODE): $($o | Out-String)" }
}

function Assert-RemovalAllowed {
    # THE name gate: called immediately before every service/task/rule action. Exact, case-sensitive membership.
    param([Parameter(Mandatory)][ValidateSet('service', 'task', 'rule')][string]$Kind, [Parameter(Mandatory)][string]$Name)
    $list = switch ($Kind) { 'service' { $script:RemovalAllowedService } 'task' { $script:RemovalAllowedTasks } 'rule' { $script:RemovalAllowedRules } }
    if ($list -cnotcontains $Name) { throw "refusing: '$Name' is not on the exact $Kind allowlist" }
}

function Assert-RemovalFolderAllowed {
    # THE folder gate: C:\nginx, or a folder named nginx-removal-test-* directly inside the temp folder (the test tree).
    param([Parameter(Mandatory)][string]$Path)
    if ($Path -match '[\*\?<>|"]' -or $Path -match '(^|\\)\.\.(\\|$)' -or $Path -notmatch '^[A-Za-z]:\\') { throw "refusing folder '$Path': not an absolute plain path" }
    $n = $Path.TrimEnd('\')
    if ($n -ieq $script:RemovalAllowedFolder) { return }
    $tmp = [IO.Path]::GetTempPath().TrimEnd('\')
    $parent = [IO.Path]::GetDirectoryName($n)
    if ($parent -and $parent -ieq $tmp -and ([IO.Path]::GetFileName($n)) -like 'nginx-removal-test-*') { return }
    throw "refusing folder '$Path': only $($script:RemovalAllowedFolder) (or a test folder under the temp folder) may be acted on"
}

function Assert-RemovalQuarantineAllowed {
    # THE quarantine gate: the production root, or a test root named nginx-removal-test-* directly inside the temp folder.
    param([Parameter(Mandatory)][string]$Root)
    $n = $Root.TrimEnd('\')
    if ($n -ieq 'C:\ProgramData\nginx-quarantine') { return }
    $parent = [IO.Path]::GetDirectoryName($n)
    if ($parent -and $parent -ieq [IO.Path]::GetTempPath().TrimEnd('\') -and ([IO.Path]::GetFileName($n)) -like 'nginx-removal-test-*') { return }
    throw "refusing quarantine root '$Root'"
}

function Get-RemovalDestination {
    # where the folder lands in the quarantine: <quarantine root>\<the folder's own name>; no PSDrive lookup, so an absent drive is just a path
    param([Parameter(Mandatory)]$Plan)
    return [IO.Path]::Combine($Plan.QuarantineRoot, [IO.Path]::GetFileName($Plan.Folder.TrimEnd([char]92)))
}

# ---- the system-call table (every read and write of the machine) -------------------------------------------
function New-NginxRemovalSystem {
    $sys = @{}
    $sys.IsElevated = { ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator) }
    $sys.GetService = {
        param($Name)
        $s = Get-CimInstance -ClassName Win32_Service -Filter ("Name='" + ($Name -replace "'", "''") + "'") -ErrorAction Stop
        if ($null -eq $s) { return $null }
        @{ Name = [string]$s.Name; StartName = [string]$s.StartName; StartMode = [string]$s.StartMode; PathName = [string]$s.PathName; State = [string]$s.State }
    }
    $sys.StopService = { param($Name) $o = & sc.exe stop $Name 2>&1; if ($LASTEXITCODE -ne 0 -and $LASTEXITCODE -ne 1062) { throw "sc.exe stop $Name failed (exit $LASTEXITCODE): $($o | Out-String)" } }
    $sys.DeleteService = { param($Name) $o = & sc.exe delete $Name 2>&1; if ($LASTEXITCODE -ne 0) { throw "sc.exe delete $Name failed (exit $LASTEXITCODE): $($o | Out-String)" } }
    # gone = the service no longer exists, or it is marked for deletion (it vanishes when the last handle closes)
    $sys.ServiceGone = {
        param($Name)
        $s = Get-CimInstance -ClassName Win32_Service -Filter ("Name='" + ($Name -replace "'", "''") + "'") -ErrorAction Stop
        if ($null -eq $s) { return $true }
        $k = Get-ItemProperty -LiteralPath "HKLM:\SYSTEM\CurrentControlSet\Services\$Name" -Name DeleteFlag -ErrorAction SilentlyContinue
        return ($null -ne $k -and [int]$k.DeleteFlag -eq 1)
    }
    $sys.GetTask = {
        param($Name)
        $t = Get-ScheduledTask -TaskName $Name -TaskPath '\' -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($null -eq $t) { return $null }
        $txt = (@($t.Actions) | ForEach-Object { "$($_.Execute) $($_.Arguments)".Trim() }) -join ' ; '
        @{ Name = [string]$t.TaskName; Path = [string]$t.TaskPath; Enabled = ([string]$t.State -ne 'Disabled'); State = [string]$t.State; UserId = [string]$t.Principal.UserId; ActionText = $txt }
    }
    $sys.UnregisterTask = { param($Name) Unregister-ScheduledTask -TaskName $Name -TaskPath '\' -Confirm:$false -ErrorAction Stop }
    # every rule carrying one of the three LA-named display names is returned, and so removed: by design, since the names are the allowlist
    $sys.GetRules = {
        param($DisplayName)
        @(Get-NetFirewallRule -ErrorAction Stop | Where-Object { [string]$_.DisplayName -eq $DisplayName } | ForEach-Object {
                @{ Id = [string]$_.Name; DisplayName = [string]$_.DisplayName; Direction = [string]$_.Direction; Action = [string]$_.Action; Enabled = ([string]$_.Enabled -eq 'True') }
            })
    }
    $sys.RemoveRule = { param($Id) Remove-NetFirewallRule -Name $Id -ErrorAction Stop }
    $sys.CountProcesses = { param($Name) @(Get-Process -Name $Name -ErrorAction SilentlyContinue).Count }
    $sys.GetListeners = { param($Ports) @(Get-NetTCPConnection -State Listen -ErrorAction SilentlyContinue | Where-Object { $Ports -contains [int]$_.LocalPort } | ForEach-Object { [int]$_.LocalPort } | Sort-Object -Unique) }
    # services / tasks OTHER than the allowlist that mention the folder (they would be left pointing at it)
    $sys.FindOtherReferences = {
        param($Needle, $AllowedServices, $AllowedTasks)
        $out = New-Object System.Collections.ArrayList
        foreach ($s in @(Get-CimInstance -ClassName Win32_Service -ErrorAction Stop)) {
            if ($AllowedServices -ccontains [string]$s.Name) { continue }
            if (([string]$s.PathName).IndexOf($Needle, [StringComparison]::OrdinalIgnoreCase) -ge 0) { [void]$out.Add(@{ Kind = 'service'; Name = [string]$s.Name; Enabled = ([string]$s.StartMode -ne 'Disabled'); Text = [string]$s.PathName }) }
        }
        foreach ($t in @(Get-ScheduledTask -ErrorAction Stop)) {
            if (([string]$t.TaskPath -eq '\') -and ($AllowedTasks -ccontains [string]$t.TaskName)) { continue }
            $txt = (@($t.Actions) | ForEach-Object { "$($_.Execute) $($_.Arguments) $($_.WorkingDirectory)".Trim() }) -join ' ; '
            if ($txt.IndexOf($Needle, [StringComparison]::OrdinalIgnoreCase) -ge 0) { [void]$out.Add(@{ Kind = 'task'; Name = "$($t.TaskPath)$($t.TaskName)"; Enabled = ([string]$t.State -ne 'Disabled'); Text = $txt }) }
        }
        @($out)
    }
    $sys.TakeOwnership = { param($Path) Invoke-RemovalTakeown -Path $Path }
    $sys.Sleep = { param($Ms) Start-Sleep -Milliseconds $Ms }
    return $sys
}

# ---- folder helpers (real file system; the folder gate applies) --------------------------------------------
function Get-RemovalFolderInventory {
    # Read-only, link-safe. Returns @{ Exists; Files; Dirs; Bytes; KeyNames[]; PemCount; Links[]; Errors[] }.
    param([Parameter(Mandatory)][string]$Path)
    Assert-RemovalFolderAllowed -Path $Path
    if (-not (Test-Path -LiteralPath $Path)) { return @{ Exists = $false; Files = 0; Dirs = 0; Bytes = [int64]0; KeyNames = @(); PemCount = 0; Links = @(); Errors = @() } }
    $script:__inv = @{ Files = 0; Dirs = 0; Bytes = [int64]0; Keys = (New-Object System.Collections.ArrayList); Pem = 0 }
    $root = $Path.TrimEnd('\')
    $w = Invoke-NoFollowWalk -Root $Path -OnObject {
        param($p, $isDir)
        if ($isDir) { $script:__inv.Dirs++; return }
        $script:__inv.Files++
        try { $script:__inv.Bytes += ([IO.FileInfo]$p).Length } catch { }
        if ($p -match '(?i)\.(key|pfx|p12|pk8)$') { [void]$script:__inv.Keys.Add($p.Substring($root.Length).TrimStart('\')) }
        elseif ($p -match '(?i)\.pem$') { $script:__inv.Pem++ }
    }
    $i = $script:__inv
    return @{ Exists = $true; Files = $i.Files; Dirs = $i.Dirs; Bytes = $i.Bytes; KeyNames = @($i.Keys | Sort-Object); PemCount = $i.Pem; Links = @($w.Links); Errors = @($w.Errors) }
}

function Lock-RemovalFolderTree {
    # Take ownership of EVERY object (one takeown call per object) and replace its access list with a protected
    # list holding only -TrustedSids with full control. Pre-order: a folder is locked before its children are listed.
    # Link-safe walk. Returns the walk result (Visited, Links, Errors).
    param([Parameter(Mandatory)][string]$Path, [string[]]$TrustedSids = $script:RemovalTrustedSids, [Parameter(Mandatory)][scriptblock]$TakeOwnership)
    Assert-RemovalFolderAllowed -Path $Path
    $sids = @($TrustedSids)
    return (Invoke-NoFollowWalk -Root $Path -OnObject {
            param($p, $isDir)
            & $TakeOwnership $p
            [void](Invoke-AclHandleEdit -Path $p -IsDir $isDir -Edit {
                    param($acl)
                    $acl.SetAccessRuleProtection($true, $false)
                    foreach ($r in @($acl.GetAccessRules($true, $false, [Security.Principal.SecurityIdentifier]))) { [void]$acl.RemoveAccessRuleSpecific($r) }
                    $flags = if ($isDir) { [Security.AccessControl.InheritanceFlags]'ContainerInherit,ObjectInherit' } else { [Security.AccessControl.InheritanceFlags]::None }
                    foreach ($sid in $sids) {
                        $acl.AddAccessRule((New-Object Security.AccessControl.FileSystemAccessRule(([Security.Principal.SecurityIdentifier]$sid), [Security.AccessControl.FileSystemRights]::FullControl, $flags, [Security.AccessControl.PropagationFlags]::None, [Security.AccessControl.AccessControlType]::Allow)))
                    }
                    return $true
                })
        })
}

function Test-RemovalFolderLocked {
    # Read-only check of the lock: every object (links not entered) is owned by a trusted SID, has a PROTECTED list
    # and no entry for anyone else. Returns @{ Ok; Visited; Violations[]; Links[]; Errors[] }. Errors make it not Ok.
    param([Parameter(Mandatory)][string]$Path, [string[]]$TrustedSids = $script:RemovalTrustedSids)
    $sids = @($TrustedSids)
    $script:__viol = New-Object System.Collections.ArrayList
    $w = Invoke-NoFollowWalk -Root $Path -OnObject {
        param($p, $isDir)
        $got = Get-AclSddlAndOwnerChecked -Path $p -IsDir $isDir
        $acl = if ($isDir) { New-Object Security.AccessControl.DirectorySecurity } else { New-Object Security.AccessControl.FileSecurity }
        $acl.SetSecurityDescriptorSddlForm($got.Sddl, [Security.AccessControl.AccessControlSections]::Access)
        if ($sids -notcontains $got.Owner) { [void]$script:__viol.Add("$p : owner is $($got.Owner)") }
        if (-not $acl.AreAccessRulesProtected) { [void]$script:__viol.Add("$p : inherits from its parent") }
        foreach ($r in @($acl.GetAccessRules($true, $true, [Security.Principal.SecurityIdentifier]))) {
            if ($sids -notcontains $r.IdentityReference.Value) { [void]$script:__viol.Add("$p : entry for $($r.IdentityReference.Value)") }
        }
    }
    $v = @($script:__viol)
    return @{ Ok = ($v.Count -eq 0 -and @($w.Errors).Count -eq 0 -and $w.Visited -gt 0); Visited = $w.Visited; Violations = $v; Links = @($w.Links); Errors = @($w.Errors) }
}

function Initialize-RemovalQuarantineRoot {
    # Creates the quarantine root already protected (no window with inherited entries), trusted SIDs only; or, if it
    # exists, verifies it is locked and carries the marker. Returns the root path.
    param([Parameter(Mandatory)][string]$Root, [string[]]$TrustedSids = $script:RemovalTrustedSids)
    Assert-RemovalQuarantineAllowed -Root $Root
    $marker = Join-Path $Root '.nginx-gateway-quarantine'
    if (Test-Path -LiteralPath $Root) {
        if (-not (Test-Path -LiteralPath $marker)) { throw "the quarantine root '$Root' exists but is not ours (no marker): refusing" }
        $chk = Test-RemovalFolderLockedShallow -Path $Root -TrustedSids $TrustedSids
        if (-not $chk.Ok) { throw "the existing quarantine root '$Root' is not admin-only: $($chk.Why)" }
        return $Root
    }
    $sec = New-Object Security.AccessControl.DirectorySecurity
    $sec.SetAccessRuleProtection($true, $false)
    # created OWNED by Administrators: a new object is otherwise owned by the creating user, and an owner can rewrite its own access list
    $adminsSid = [Security.Principal.SecurityIdentifier]'S-1-5-32-544'
    $sec.SetOwner($adminsSid)
    foreach ($sid in $TrustedSids) {
        $sec.AddAccessRule((New-Object Security.AccessControl.FileSystemAccessRule(([Security.Principal.SecurityIdentifier]$sid), [Security.AccessControl.FileSystemRights]::FullControl, [Security.AccessControl.InheritanceFlags]'ContainerInherit,ObjectInherit', [Security.AccessControl.PropagationFlags]::None, [Security.AccessControl.AccessControlType]::Allow)))
    }
    [void][IO.FileSystemAclExtensions]::Create((New-Object IO.DirectoryInfo $Root), $sec)
    $fsec = New-Object Security.AccessControl.FileSecurity
    $fsec.SetAccessRuleProtection($true, $false)
    $fsec.SetOwner($adminsSid)
    foreach ($sid in $TrustedSids) {
        $fsec.AddAccessRule((New-Object Security.AccessControl.FileSystemAccessRule(([Security.Principal.SecurityIdentifier]$sid), [Security.AccessControl.FileSystemRights]::FullControl, [Security.AccessControl.AccessControlType]::Allow)))
    }
    $fs = [IO.FileSystemAclExtensions]::Create((New-Object IO.FileInfo $marker), [IO.FileMode]::CreateNew, [Security.AccessControl.FileSystemRights]::Write, [IO.FileShare]::None, 4096, [IO.FileOptions]::None, $fsec)
    try { $b = [Text.Encoding]::ASCII.GetBytes("created by remove-nginx-gateway.ps1`r`n"); $fs.Write($b, 0, $b.Length) } finally { $fs.Dispose() }
    $chk = Test-RemovalFolderLockedShallow -Path $Root -TrustedSids $TrustedSids
    if (-not $chk.Ok) { throw "the new quarantine root '$Root' is not admin-only: $($chk.Why)" }
    return $Root
}

function Test-RemovalFolderLockedShallow {
    # the lock check on ONE folder (no walk): protected, trusted owner, trusted entries only
    param([Parameter(Mandatory)][string]$Path, [string[]]$TrustedSids = $script:RemovalTrustedSids)
    try {
        $got = Get-AclSddlAndOwnerChecked -Path $Path -IsDir $true
        $acl = New-Object Security.AccessControl.DirectorySecurity
        $acl.SetSecurityDescriptorSddlForm($got.Sddl, [Security.AccessControl.AccessControlSections]::Access)
        $bad = @()
        if ($TrustedSids -notcontains $got.Owner) { $bad += "owner is $($got.Owner)" }
        if (-not $acl.AreAccessRulesProtected) { $bad += 'inherits from its parent' }
        foreach ($r in @($acl.GetAccessRules($true, $true, [Security.Principal.SecurityIdentifier]))) { if ($TrustedSids -notcontains $r.IdentityReference.Value) { $bad += "entry for $($r.IdentityReference.Value)" } }
        return @{ Ok = ($bad.Count -eq 0); Why = ($bad -join '; ') }
    } catch { return @{ Ok = $false; Why = $_.Exception.Message } }
}

function Remove-RemovalTree {
    # Permanent delete of a folder tree that NEVER follows a link. The ROOT must be a real folder: a junction or symlink
    # given as the root is refused (throws), because deleting "its contents" would delete its target's. Inside the tree a
    # junction or symlink is removed as the link itself (its target is left untouched). A read-only attribute is cleared on
    # the entry itself (files, links, folders) before it is deleted. The caller has already gated the path. Throws on the
    # first failure.
    param([Parameter(Mandatory)][string]$Path)
    $rootAttr = [IO.File]::GetAttributes($Path)
    if ($rootAttr -band [IO.FileAttributes]::ReparsePoint) { throw "refusing to delete '$Path': it is a link (junction or symlink), not a real folder" }
    if (-not ($rootAttr -band [IO.FileAttributes]::Directory)) { throw "refusing to delete '$Path': it is not a folder" }
    foreach ($e in @([IO.Directory]::EnumerateFileSystemEntries($Path))) {
        $attr = [IO.File]::GetAttributes($e)
        if ($attr -band [IO.FileAttributes]::ReparsePoint) {
            if ($attr -band [IO.FileAttributes]::ReadOnly) { [IO.File]::SetAttributes($e, [IO.FileAttributes]($attr -band (-bnot [IO.FileAttributes]::ReadOnly))) }
            if ($attr -band [IO.FileAttributes]::Directory) { [IO.Directory]::Delete($e) } else { [IO.File]::Delete($e) }
        } elseif ($attr -band [IO.FileAttributes]::Directory) {
            Remove-RemovalTree -Path $e
        } else {
            if ($attr -band [IO.FileAttributes]::ReadOnly) { [IO.File]::SetAttributes($e, [IO.FileAttributes]::Normal) }
            [IO.File]::Delete($e)
        }
    }
    if ($rootAttr -band [IO.FileAttributes]::ReadOnly) { [IO.File]::SetAttributes($Path, [IO.FileAttributes]($rootAttr -band (-bnot [IO.FileAttributes]::ReadOnly))) }
    [IO.Directory]::Delete($Path)
}

function Confirm-RemovalConfBackup {
    # nginx.conf is copied before anything is changed. Never overwrites: an identical copy is reused, a differing one
    # leaves the original alone and the new copy gets a timestamped name. Returns @{ Ok; Path; Action; Why }.
    # -Write:$false only inspects (dry run).
    param([Parameter(Mandatory)][string]$Source, [Parameter(Mandatory)][string]$BackupDir, [bool]$Write = $true)
    $dest = Join-Path $BackupDir 'nginx.conf'
    $srcExists = Test-Path -LiteralPath $Source -PathType Leaf
    if (-not $srcExists) {
        if (Test-Path -LiteralPath $dest -PathType Leaf) { return @{ Ok = $true; Path = $dest; Action = 'source-gone-backup-kept'; Why = "the source '$Source' is already gone; the existing copy is kept" } }
        return @{ Ok = $false; Path = $dest; Action = 'none'; Why = "no source '$Source' and no existing copy at '$dest'" }
    }
    $h = (Get-FileHash -LiteralPath $Source -Algorithm SHA256).Hash
    if (Test-Path -LiteralPath $dest -PathType Leaf) {
        if ((Get-FileHash -LiteralPath $dest -Algorithm SHA256).Hash -eq $h) { return @{ Ok = $true; Path = $dest; Action = 'identical-copy-present'; Why = '' } }
        $dest2 = Join-Path $BackupDir ('nginx.conf.' + (Get-Date -Format 'yyyyMMdd-HHmmss') + '.' + $h.Substring(0, 8))
        if (-not $Write) { return @{ Ok = $true; Path = $dest2; Action = 'would-write-new-name'; Why = "an existing copy differs and is never overwritten" } }
        if (Test-Path -LiteralPath $dest2) { return @{ Ok = $false; Path = $dest2; Action = 'none'; Why = "'$dest2' already exists" } }
        Copy-Item -LiteralPath $Source -Destination $dest2
        if ((Get-FileHash -LiteralPath $dest2 -Algorithm SHA256).Hash -ne $h) { return @{ Ok = $false; Path = $dest2; Action = 'copy-mismatch'; Why = 'the new copy does not match the source' } }
        return @{ Ok = $true; Path = $dest2; Action = 'wrote-new-name'; Why = '' }
    }
    if (-not $Write) { return @{ Ok = $true; Path = $dest; Action = 'would-copy'; Why = '' } }
    New-Item -ItemType Directory -Force -Path $BackupDir | Out-Null
    Copy-Item -LiteralPath $Source -Destination $dest
    if ((Get-FileHash -LiteralPath $dest -Algorithm SHA256).Hash -ne $h) { return @{ Ok = $false; Path = $dest; Action = 'copy-mismatch'; Why = 'the copy does not match the source' } }
    return @{ Ok = $true; Path = $dest; Action = 'copied'; Why = '' }
}

# ---- the plan view (read-only) ----------------------------------------------------------------------------
function Get-NginxRemovalState {
    # Everything the listing and the preconditions need, read once. Read-only.
    param([Parameter(Mandatory)]$Plan, [Parameter(Mandatory)]$Sys)
    $st = @{}
    $st.Service = & $Sys.GetService $script:RemovalAllowedService[0]
    $st.Tasks = @($script:RemovalAllowedTasks | ForEach-Object { $t = & $Sys.GetTask $_; @{ Name = $_; Task = $t } })
    $st.Rules = @($script:RemovalAllowedRules | ForEach-Object { @{ Name = $_; Found = @(& $Sys.GetRules $_) } })
    $st.Folder = Get-RemovalFolderInventory -Path $Plan.Folder
    $st.NginxProcesses = [int](& $Sys.CountProcesses 'nginx')
    $st.Listeners = @(& $Sys.GetListeners $script:RemovalPorts)
    $st.Others = @(& $Sys.FindOtherReferences $Plan.Folder $script:RemovalAllowedService $script:RemovalAllowedTasks)
    $st.Elevated = [bool](& $Sys.IsElevated)
    return $st
}

function Get-NginxRemovalRefusals {
    # PURE over the state: the reasons -Execute must not start. Empty = go.
    param([Parameter(Mandatory)]$Plan, [Parameter(Mandatory)]$State, [Parameter(Mandatory)][string[]]$Scope, [bool]$DeleteQuarantine = $false, [bool]$IsExecute = $true)
    $r = New-Object System.Collections.ArrayList
    if ($IsExecute -and -not $State.Elevated) { [void]$r.Add('not elevated: run from an elevated PowerShell (Run as administrator)') }
    if ($State.NginxProcesses -gt 0) { [void]$r.Add("an nginx process is running ($($State.NginxProcesses)): stop it deliberately first; this script does not kill processes") }
    if (@($State.Listeners).Count -gt 0) { [void]$r.Add("something is listening on port(s) $(@($State.Listeners) -join ', '): the gateway may be in use; nothing is changed") }
    if ($DeleteQuarantine -and $Scope -notcontains 'Folder') { [void]$r.Add('-DeleteQuarantine only applies together with -Scope Folder') }
    if ($State.Service -and $Scope -contains 'Service') {
        if (-not ([string]$State.Service.PathName).StartsWith($Plan.ServiceImagePrefix, [StringComparison]::OrdinalIgnoreCase)) { [void]$r.Add("service '$($State.Service.Name)' has image path '$($State.Service.PathName)', not '$($Plan.ServiceImagePrefix)...': identity mismatch, refusing to touch it") }
    }
    foreach ($t in $State.Tasks) {
        if ($t.Task -and $Scope -contains 'Tasks' -and ([string]$t.Task.ActionText) -notmatch '(?i)nginx') { [void]$r.Add("task '$($t.Name)' does not mention nginx in its actions ('$($t.Task.ActionText)'): identity mismatch, refusing to touch it") }
    }
    foreach ($ru in $State.Rules) {
        foreach ($f in @($ru.Found)) {
            if ($Scope -contains 'FirewallRules' -and ($f.Direction -ne 'Inbound' -or $f.Action -ne 'Allow')) { [void]$r.Add("firewall rule '$($ru.Name)' is $($f.Direction)/$($f.Action), not Inbound/Allow: identity mismatch, refusing to touch it") }
        }
    }
    if ($Scope -contains 'Folder' -and $State.Folder.Exists) {
        # the folder may only go when nothing still points into it (any user can re-create C:\nginx)
        if ($State.Service -and $Scope -notcontains 'Service') { [void]$r.Add("the folder is in scope but the service '$($State.Service.Name)' still exists and is not: it would run whatever is re-created at $($Plan.Folder)") }
        $liveTasks = @($State.Tasks | Where-Object { $_.Task })
        if ($liveTasks.Count -gt 0 -and $Scope -notcontains 'Tasks') { [void]$r.Add("the folder is in scope but $($liveTasks.Count) allowlisted task(s) still exist and are not: they would run whatever is re-created at $($Plan.Folder)") }
        foreach ($o in @($State.Others | Where-Object { $_.Enabled })) { [void]$r.Add("an enabled $($o.Kind) NOT on the allowlist mentions the folder ('$($o.Name)': $($o.Text)): remove or retarget it deliberately; this script will not touch it") }
        if ($State.Folder.Dirs -le 0 -and $State.Folder.Files -le 0) { [void]$r.Add("the folder '$($Plan.Folder)' lists as empty: something is wrong, refusing") }
        $q = $Plan.QuarantineRoot
        if ([IO.Path]::GetPathRoot($q) -ine [IO.Path]::GetPathRoot($Plan.Folder)) { [void]$r.Add("the quarantine '$q' is on another volume than '$($Plan.Folder)': a move must be a rename on one volume, refusing") }
        if ([IO.Directory]::Exists((Get-RemovalDestination -Plan $Plan))) { [void]$r.Add("'$(Get-RemovalDestination -Plan $Plan)' already exists while the folder also exists: needs a human decision") }
    }
    return @($r)
}

function Write-NginxRemovalListing {
    param([Parameter(Mandatory)]$Plan, [Parameter(Mandatory)]$State, [Parameter(Mandatory)][string[]]$Scope, [bool]$DeleteQuarantine, [Parameter(Mandatory)][scriptblock]$Out)
    $mark = { param($c) if ($Scope -contains $c) { 'IN SCOPE' } else { 'not in scope (-Scope)' } }
    & $Out ''
    & $Out "SERVICE  ($(& $mark 'Service'))"
    if ($State.Service) { & $Out ("  NginxGateway : present; account $($State.Service.StartName); start $($State.Service.StartMode); state $($State.Service.State); image path $($State.Service.PathName)") }
    else { & $Out '  NginxGateway : not present (nothing to do)' }
    & $Out ''
    & $Out "SCHEDULED TASKS, root folder only  ($(& $mark 'Tasks'))  - $($script:RemovalAllowedTasks.Count) named"
    foreach ($t in $State.Tasks) {
        if ($t.Task) { & $Out ("  {0,-28} present; {1}; runs as {2}; {3}" -f $t.Name, $(if ($t.Task.Enabled) { 'ENABLED' } else { 'disabled' }), $t.Task.UserId, $t.Task.ActionText) }
        else { & $Out ("  {0,-28} not present" -f $t.Name) }
    }
    & $Out ''
    & $Out "FIREWALL RULES, inbound allow  ($(& $mark 'FirewallRules'))  - $($script:RemovalAllowedRules.Count) named"
    foreach ($ru in $State.Rules) {
        if (@($ru.Found).Count -gt 0) { foreach ($f in $ru.Found) { & $Out ("  {0,-26} present; {1}/{2}; {3}" -f $ru.Name, $f.Direction, $f.Action, $(if ($f.Enabled) { 'enabled' } else { 'disabled' })) } }
        else { & $Out ("  {0,-26} not present" -f $ru.Name) }
    }
    & $Out ''
    & $Out "FOLDER  $($Plan.Folder)  ($(& $mark 'Folder'))"
    $f = $State.Folder
    if ($f.Exists) {
        & $Out ("  {0} files in {1} folders, {2:N1} MB" -f $f.Files, $f.Dirs, ($f.Bytes / 1MB))
        & $Out ("  private-key file NAMES (by .key/.pfx/.p12/.pk8 extension; contents are never read): {0}" -f @($f.KeyNames).Count)
        foreach ($k in $f.KeyNames) { & $Out "    $k" }
        & $Out ("  .pem files (may hold keys): {0}" -f $f.PemCount)
        if (@($f.Links).Count -gt 0) { & $Out ("  links inside (listed, never entered or followed): {0}" -f @($f.Links).Count); foreach ($l in $f.Links) { & $Out "    $l" } }
        if (@($f.Errors).Count -gt 0) { & $Out ("  entries that could not be read: {0}" -f @($f.Errors).Count) }
        & $Out "  action: take ownership, lock to SYSTEM + Administrators, MOVE to $(Get-RemovalDestination -Plan $Plan) (admin-only quarantine)"
        & $Out $(if ($DeleteQuarantine) { '  then PERMANENTLY DELETE the quarantined copy (-DeleteQuarantine given)' } else { '  the quarantined copy is KEPT (add -DeleteQuarantine to delete it permanently)' })
    } else { & $Out '  not present (nothing to do)' }
    $q = Get-RemovalDestination -Plan $Plan
    if ([IO.Directory]::Exists($q)) { & $Out "  an earlier quarantine exists at $q" }
    & $Out ''
    & $Out "nginx.conf copy: $($Plan.ConfBackupDir)\nginx.conf (never overwritten)"
    if (@($State.Others).Count -gt 0) {
        & $Out ''
        & $Out "OTHER items that mention the folder and are NOT on the allowlist (left alone): $(@($State.Others).Count)"
        foreach ($o in $State.Others) { & $Out ("  {0} {1} ({2}) {3}" -f $o.Kind, $o.Name, $(if ($o.Enabled) { 'ENABLED' } else { 'disabled' }), $o.Text) }
    }
}

# ---- the run -------------------------------------------------------------------------------------------------
function Invoke-NginxRemoval {
    # Returns @{ ExitCode; Mode; Steps[]; Refusals[]; LogPath }. -Plan/-Sys default to the production values; the
    # tests pass a plan on a temp tree and a fake system table. Never calls exit.
    param(
        [switch]$Execute, [switch]$DeleteQuarantine,
        [string[]]$Scope = @('Service', 'Tasks', 'FirewallRules', 'Folder'),
        $Plan = $null, $Sys = $null, [string[]]$TrustedSids = $script:RemovalTrustedSids,
        [scriptblock]$Out = { param($l) Write-Host $l }
    )
    foreach ($s in $Scope) { if ($s -cnotin @('Service', 'Tasks', 'FirewallRules', 'Folder')) { throw "unknown -Scope value '$s'" } }
    if (-not $Plan) { $Plan = $script:RemovalProduction }
    if (-not $Sys) { $Sys = New-NginxRemovalSystem }
    $steps = New-Object System.Collections.ArrayList
    $logPath = ''
    $log = {
        param($level, $msg)
        $line = "[{0}] {1,-5} {2}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss K'), $level, $msg
        & $Out $line
        if ($logPath) { Add-Content -LiteralPath $logPath -Value $line -Encoding UTF8 }
    }
    $result = { param($code, $refusals) @{ ExitCode = $code; Mode = $(if ($Execute) { 'execute' } else { 'dry-run' }); Steps = @($steps); Refusals = @($refusals); LogPath = $logPath } }

    & $Out $(if ($Execute) { '== remove-nginx-gateway: EXECUTE ==' } else { '== remove-nginx-gateway: DRY RUN - nothing will be changed (add -Execute to act) ==' })
    $state = Get-NginxRemovalState -Plan $Plan -Sys $Sys
    Write-NginxRemovalListing -Plan $Plan -State $state -Scope $Scope -DeleteQuarantine ([bool]$DeleteQuarantine) -Out $Out
    $conf = Confirm-RemovalConfBackup -Source (Join-Path $Plan.Folder 'conf\nginx.conf') -BackupDir $Plan.ConfBackupDir -Write $false
    & $Out ("  conf copy: {0} ({1})" -f $conf.Action, $(if ($conf.Ok) { 'ok' } else { $conf.Why }))
    $refusals = @(Get-NginxRemovalRefusals -Plan $Plan -State $state -Scope $Scope -DeleteQuarantine ([bool]$DeleteQuarantine) -IsExecute ([bool]$Execute))
    if (-not $conf.Ok -and ($Scope -contains 'Folder') -and $state.Folder.Exists) { $refusals += "the nginx.conf copy cannot be guaranteed: $($conf.Why)" }
    & $Out ''
    if ($refusals.Count -gt 0) {
        & $Out $(if ($Execute) { 'REFUSED - nothing was changed:' } else { 'WOULD REFUSE if run with -Execute:' })
        foreach ($x in $refusals) { & $Out "  - $x" }
    } else { & $Out 'preconditions: all satisfied' }
    if (-not $Execute) {
        if (-not $state.Elevated) { & $Out 'note: this shell is NOT elevated; -Execute requires an elevated PowerShell' }
        & $Out ''
        & $Out 'DECISIONS FOR THE LA (this script makes none): 1) remove the scheduled tasks; 2) remove the firewall rules; 3) keep the quarantined folder (default) or also pass -DeleteQuarantine.'
        & $Out 'To act:  pwsh -File scripts\remove-nginx-gateway.ps1 -Execute   (narrow with -Scope Service,Tasks,...; add -DeleteQuarantine to delete the keys permanently)'
        return (& $result $(if ($refusals.Count -gt 0) { 2 } else { 0 }) $refusals)
    }
    if ($refusals.Count -gt 0) { return (& $result 2 $refusals) }

    # ---- execute ----
    try {
        if (-not (Test-Path -LiteralPath $Plan.LogDir -PathType Container)) { throw "the log folder '$($Plan.LogDir)' does not exist" }
        $logPath = Join-Path $Plan.LogDir ('nginx-removal-' + (Get-Date -Format 'yyyyMMdd-HHmmss') + '.log')
        Add-Content -LiteralPath $logPath -Value "remove-nginx-gateway.ps1 -Execute; scope: $($Scope -join ','); delete-quarantine: $([bool]$DeleteQuarantine)" -Encoding UTF8
    } catch { & $Out "REFUSED - nothing was changed: cannot write the log ($($_.Exception.Message))"; return (& $result 2 @("cannot write the log: $($_.Exception.Message)")) }
    & $log 'INFO' "log: $logPath"
    $step = {
        param($stepTitle, [scriptblock]$Body)
        & $log 'STEP' $stepTitle
        try { & $Body; [void]$steps.Add(@{ Step = $stepTitle; Status = 'done' }); & $log 'OK' $stepTitle }
        catch { [void]$steps.Add(@{ Step = $stepTitle; Status = 'FAILED'; Why = $_.Exception.Message }); & $log 'FAIL' "$stepTitle : $($_.Exception.Message)"; throw }
    }
    try {
        # 0. the nginx.conf copy
        & $step 'copy nginx.conf (never overwrites)' {
            $c = Confirm-RemovalConfBackup -Source (Join-Path $Plan.Folder 'conf\nginx.conf') -BackupDir $Plan.ConfBackupDir -Write $true
            if (-not $c.Ok) { throw $c.Why }
            & $log 'INFO' "conf copy: $($c.Action) -> $($c.Path)"
        }
        # 1. lock the folder in place: closes the privilege path first
        $dest = Get-RemovalDestination -Plan $Plan
        $folderHere = ($Scope -contains 'Folder') -and (Test-Path -LiteralPath $Plan.Folder)
        if ($Scope -contains 'Folder') {
            if ($folderHere) {
                & $step "take ownership of every object in $($Plan.Folder) and lock it to SYSTEM + Administrators" {
                    $w = Lock-RemovalFolderTree -Path $Plan.Folder -TrustedSids $TrustedSids -TakeOwnership $Sys.TakeOwnership
                    & $log 'INFO' "locked $($w.Visited) objects; links not entered: $(@($w.Links).Count); errors: $(@($w.Errors).Count)"
                    if (@($w.Errors).Count -gt 0) { throw "the lock walk had $(@($w.Errors).Count) error(s); first: $($w.Errors[0])" }
                    $chk = Test-RemovalFolderLocked -Path $Plan.Folder -TrustedSids $TrustedSids
                    if (-not $chk.Ok) { throw "verification failed: $(@($chk.Violations).Count) object(s) not locked, $(@($chk.Errors).Count) read error(s); first: $((@($chk.Violations) + @($chk.Errors))[0])" }
                    & $log 'INFO' "verified: $($chk.Visited) objects owned by and open only to the trusted accounts"
                }
            } else { & $log 'INFO' "already done: $($Plan.Folder) is not in place" }
        }
        # 2. service
        if ($Scope -contains 'Service') {
            Assert-RemovalAllowed -Kind service -Name $script:RemovalAllowedService[0]
            $svc = & $Sys.GetService $script:RemovalAllowedService[0]
            if (-not $svc) { & $log 'INFO' 'already done: service NginxGateway is not present' }
            else {
                & $step 'stop service NginxGateway if it is running' {
                    Assert-RemovalAllowed -Kind service -Name $script:RemovalAllowedService[0]
                    if ($svc.State -ne 'Stopped') {
                        & $Sys.StopService $script:RemovalAllowedService[0]
                        $n = 0; do { & $Sys.Sleep 1000; $now = & $Sys.GetService $script:RemovalAllowedService[0]; $n++ } while ($now -and $now.State -ne 'Stopped' -and $n -lt 30)
                        if ($now -and $now.State -ne 'Stopped') { throw "the service did not stop within 30 s (state $($now.State))" }
                    }
                }
                & $step 'delete service NginxGateway' {
                    Assert-RemovalAllowed -Kind service -Name $script:RemovalAllowedService[0]
                    & $Sys.DeleteService $script:RemovalAllowedService[0]
                    if (-not (& $Sys.ServiceGone $script:RemovalAllowedService[0])) { throw 'the service is still present and not marked for deletion' }
                }
            }
        }
        # 3. tasks
        if ($Scope -contains 'Tasks') {
            foreach ($name in $script:RemovalAllowedTasks) {
                $t = & $Sys.GetTask $name
                if (-not $t) { & $log 'INFO' "already done: task $name is not present"; continue }
                & $step "unregister scheduled task $name" {
                    Assert-RemovalAllowed -Kind task -Name $name
                    & $Sys.UnregisterTask $name
                    if (& $Sys.GetTask $name) { throw "task $name is still registered" }
                }
            }
        }
        # 4. firewall rules
        if ($Scope -contains 'FirewallRules') {
            foreach ($name in $script:RemovalAllowedRules) {
                $found = @(& $Sys.GetRules $name)
                if ($found.Count -eq 0) { & $log 'INFO' "already done: firewall rule '$name' is not present"; continue }
                foreach ($f in $found) {
                    & $step "remove firewall rule '$name' ($($f.Id))" {
                        Assert-RemovalAllowed -Kind rule -Name $name
                        & $Sys.RemoveRule $f.Id
                        if (@(& $Sys.GetRules $name | Where-Object { $_.Id -eq $f.Id }).Count -gt 0) { throw "rule '$name' is still present" }
                    }
                }
            }
        }
        # 5. move the folder into the quarantine
        if ($Scope -contains 'Folder') {
            if ($folderHere) {
                & $step "move $($Plan.Folder) -> $dest" {
                    Assert-RemovalFolderAllowed -Path $Plan.Folder
                    $pre = Test-RemovalFolderLocked -Path $Plan.Folder -TrustedSids $TrustedSids
                    if (-not $pre.Ok) { throw 'the folder is not locked at the moment of the move: refusing' }
                    [void](Initialize-RemovalQuarantineRoot -Root $Plan.QuarantineRoot -TrustedSids $TrustedSids)
                    if (Test-Path -LiteralPath $dest) { throw "'$dest' already exists" }
                    [IO.Directory]::Move($Plan.Folder, $dest)
                    if (Test-Path -LiteralPath $Plan.Folder) { throw "'$($Plan.Folder)' still exists after the move" }
                    if (-not (Test-Path -LiteralPath $dest)) { throw "'$dest' does not exist after the move" }
                    $post = Test-RemovalFolderLocked -Path $dest -TrustedSids $TrustedSids
                    if (-not $post.Ok -or $post.Visited -ne $pre.Visited) { throw "post-move check failed: visited $($post.Visited) of $($pre.Visited); $(@($post.Violations).Count) not locked; $(@($post.Errors).Count) read errors" }
                    & $log 'INFO' "quarantined $($post.Visited) objects, admin-only, at $dest"
                }
            } else { & $log 'INFO' "already done: $($Plan.Folder) is not in place$(if (Test-Path -LiteralPath $dest) { "; quarantined copy at $dest" })" }
            # 6. permanent deletion, only on request
            if ($DeleteQuarantine) {
                if (-not (Test-Path -LiteralPath $dest)) { & $log 'INFO' 'already done: no quarantined copy to delete' }
                else {
                    & $step "PERMANENTLY DELETE the quarantined copy $dest" {
                        Assert-RemovalFolderAllowed -Path $Plan.Folder
                        Assert-RemovalQuarantineAllowed -Root $Plan.QuarantineRoot
                        if ($dest -ine (Get-RemovalDestination -Plan $Plan)) { throw 'the delete target is not the quarantined copy' }
                        if (-not (Test-Path -LiteralPath ([IO.Path]::Combine($Plan.QuarantineRoot, '.nginx-gateway-quarantine')))) { throw 'the quarantine marker is missing: refusing to delete' }
                        # the state is re-proved at the moment of the delete: a root or copy that was swapped, re-opened or turned into a link is never walked
                        $qchk = Test-RemovalFolderLockedShallow -Path $Plan.QuarantineRoot -TrustedSids $TrustedSids
                        if (-not $qchk.Ok) { throw "the quarantine root is not admin-only any more ($($qchk.Why)): refusing to delete" }
                        if (-not [IO.Directory]::Exists($dest) -or ([IO.File]::GetAttributes($dest) -band [IO.FileAttributes]::ReparsePoint)) { throw "'$dest' is not a real folder (missing or a link): refusing to delete" }
                        $dchk = Test-RemovalFolderLocked -Path $dest -TrustedSids $TrustedSids
                        if (-not $dchk.Ok) { throw "the quarantined copy is not fully locked ($(@($dchk.Violations).Count) violations, $(@($dchk.Errors).Count) read errors): refusing to delete" }
                        Remove-RemovalTree -Path $dest
                        if (Test-Path -LiteralPath $dest) { throw "'$dest' still exists after the delete" }
                    }
                }
            }
        }
        # final read-back
        $final = Get-NginxRemovalState -Plan $Plan -Sys $Sys
        $left = New-Object System.Collections.ArrayList
        if ($Scope -contains 'Service' -and $final.Service -and -not (& $Sys.ServiceGone $script:RemovalAllowedService[0])) { [void]$left.Add('service NginxGateway') }
        if ($Scope -contains 'Tasks') { foreach ($t in $final.Tasks) { if ($t.Task) { [void]$left.Add("task $($t.Name)") } } }
        if ($Scope -contains 'FirewallRules') { foreach ($ru in $final.Rules) { if (@($ru.Found).Count -gt 0) { [void]$left.Add("firewall rule '$($ru.Name)'") } } }
        if ($Scope -contains 'Folder' -and (Test-Path -LiteralPath $Plan.Folder)) { [void]$left.Add("folder $($Plan.Folder)") }
        if ($left.Count -gt 0) { throw "read-back: still present: $($left -join '; ')" }
        & $log 'DONE' 'everything in scope is removed; read-back confirmed'
        return (& $result 0 @())
    } catch {
        & $log 'FAIL' "stopped: $($_.Exception.Message). Nothing further was attempted. Fix the cause and re-run: finished steps report 'already done'."
        return (& $result 3 @($_.Exception.Message))
    }
}

# dot-sourced (by the test suite): functions only
if ($MyInvocation.InvocationName -eq '.') { return }
$r = Invoke-NginxRemoval -Execute:$Execute -DeleteQuarantine:$DeleteQuarantine -Scope $Scope
exit $r.ExitCode
