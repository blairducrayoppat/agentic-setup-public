#requires -Version 7.0
<#
.SYNOPSIS
  Verifies remove-nginx-gateway.ps1 (#1695) OFFLINE. The real script code runs (dot-sourced; its own
  Invoke-NginxRemoval and folder functions) against a FAKE system-call table (service, tasks, firewall rules,
  processes, listeners, elevation) and a REAL temp tree for the folder work (a real junction inside it, real
  takeown.exe, real access lists). NOTHING on the machine is changed, and -Execute is never passed to a real
  child process.

.DESCRIPTION
  WHAT IS REAL: the script's code paths, the link-safe walk, takeown.exe, Get-Acl / handle-based access-list
  edits, the folder move, the conf copy, the log file.
  WHAT IS A FAKE: the Service Control Manager, Task Scheduler, firewall, process and socket tables, and the
  elevation test. The accounts that "may keep the folder" are the current user, SYSTEM and Administrators (the
  current user stands in for the operator, who is an Administrators member); the production default
  (SYSTEM + Administrators only) is asserted separately as a constant.
  A read-only smoke runs the REAL script as a child process in dry-run mode and asserts the machine is
  unchanged (service, task and rule counts, C:\nginx presence) before and after.

  -Mutations re-runs THIS suite against mutated copies of the sources (each control disabled in turn). KILLED =
  non-zero exit AND a [FAIL] line; SURVIVED = exit 0; ERROR = non-zero with no [FAIL] line. The unmutated
  control must pass first. -ProveHarness shows the classification on a known survivor, crasher and kill.
  Exit 0 if everything passed.

  SAFETY CONTRACT: the suite's Lock-RemovalFolderTree, Remove-RemovalTree, Invoke-NginxRemoval,
  Initialize-RemovalQuarantineRoot and Invoke-RemovalTakeown calls (the fake system table's real-takeown path
  included) go through Assert-Throwaway, which refuses any path that is not strictly inside this suite's temp
  root, whose first component does not carry this run's random token, or that is, lies inside, or contains a
  protected folder (Windows, ProgramData, Program Files, C:\nginx, the canary paths, a drive root, the user
  profile, this repository). The protected list is written out here and read from the OS folder API, never from
  TMP/TEMP, and the suite REFUSES TO START (exit 3) if its temp folder is, contains or lies inside one. The
  end-of-suite cleanup re-checks every path with its own test (Test-CleanupPathSafe) before deleting and clears
  read-only attributes first. Not individually guarded: fixture setup with icacls / Set-Acl / Remove-Item /
  New-Item, which take paths built from the temp root and this run's ids, and a few decoy folders the tests make
  and remove in the temp root's PARENT (zz-outside-<id>). Fixture paths are safe only AS OF STARTUP: the temp root
  is re-checked each time a fixture id is issued, but a temp folder swapped for a junction while a fixture is being
  built would receive that fixture's entries (the guarded destructive helpers still refuse it).
  An ACL canary (read-only) hashes the access list of C:\Windows\Temp, C:\Windows, C:\ProgramData and the
  quarantine root AND of a bounded sample of the entries below each (so a rewrite of the children is seen even
  when the root already holds the rewritten list), at suite start and end and at the start and end of a -Mutations
  run. It fails loudly if any changed, and fails closed if a root cannot be read (run elevated; -AllowBlindCanary
  downgrades that to a printed no-claim for that root and is passed on to the mutation children).
  Folders are compared by their FINAL path (links followed, 8.3 names expanded); UNC and device-namespace spellings
  (\\server, \\?\, \\.\) are refused outright, and the suite refuses to start if its temp folder, or any folder
  above it, is a link. A run as SYSTEM has its temp folder under C:\Windows and is therefore refused (fail-closed).
  The canary cannot see deletions, and samples C:\Windows\Temp breadth-first up to 200 entries (not the whole
  folder, and nothing under C:\Windows\System32).
  The sweep of the mutation children's temp folders only acts on this run's own folder: a real directory named for the
  run's random token, strictly inside the resolved temp root, with no link in or above it; it refuses otherwise.
  The bound on nested test runs is the NGINXRM_NESTED environment variable alone.
  -Only is accepted only with -Mutations and must name at least one mutant, else exit 3. Each mutation child runs
  with its own private temp folder, which the parent sweeps and reports.
#>
param([switch]$Mutations, [switch]$ProveHarness, [switch]$NoSmoke, [switch]$AllowBlindCanary, [string[]]$Only = @(), [int]$Throttle = 3)
$ErrorActionPreference = 'Stop'
$onlyGiven = $PSBoundParameters.ContainsKey('Only')
$Only = @($Only | ForEach-Object { $_ -split ',' } | ForEach-Object { $_.Trim() } | Where-Object { $_ })   # -File binds 'a,b' as ONE string
if ($onlyGiven -and $Only.Count -eq 0) { Write-Host '  [FAIL] -Only was given but names no mutant: nothing was run' -ForegroundColor Red; exit 3 }
if ($onlyGiven -and -not $Mutations) { Write-Host '  [FAIL] -Only selects mutants and is meaningless without -Mutations: nothing was run' -ForegroundColor Red; exit 3 }

# ---- the ACL canary (read-only) ----------------------------------------------------------------------------
# For each canary path: the SHA-256 of its own SDDL (owner, group, access list) AND of a bounded breadth-first sample
# of the entries below it (links are listed, never entered). A destructive lock rewrites every child, so a root that
# already carries the lock's result (the state after the #1695 incident) still shows the defect in its children.
$script:CanaryPaths = @('C:\Windows\Temp', 'C:\Windows', 'C:\ProgramData', 'C:\ProgramData\nginx-quarantine')
$script:CanaryMaxEntries = 200
$script:CanaryMaxDepth = 2
function Get-AclCanarySample {
    # up to -Max entries below -Root, breadth-first, names in ordinal order, at most CanaryMaxDepth levels below the root
    param([Parameter(Mandatory)][string]$Root, [int]$Max = $script:CanaryMaxEntries)
    $out = New-Object System.Collections.ArrayList
    $queue = New-Object System.Collections.Queue
    $queue.Enqueue(@($Root, 0))
    while ($queue.Count -gt 0 -and $out.Count -lt $Max) {
        $item = $queue.Dequeue(); $dir = [string]$item[0]; $depth = [int]$item[1]
        $kids = try { [IO.Directory]::GetFileSystemEntries($dir) } catch { $null }
        if ($null -eq $kids -or @($kids).Count -eq 0) { continue }
        $kids = [string[]]@($kids)
        [Array]::Sort($kids, [StringComparer]::Ordinal)
        foreach ($k in $kids) {
            if ($out.Count -ge $Max) { break }
            [void]$out.Add($k)
            $enter = try { $at = [IO.File]::GetAttributes($k); (($at -band [IO.FileAttributes]::Directory) -ne 0) -and (($at -band [IO.FileAttributes]::ReparsePoint) -eq 0) } catch { $false }
            if ($enter -and $depth -lt $script:CanaryMaxDepth) { $queue.Enqueue(@($k, ($depth + 1))) }
        }
    }
    return @($out)
}
function Get-AclCanaryHash {
    # SHA-256 of the SDDL of one path; ABSENT if it does not exist; UNREADABLE if the access list cannot be read
    param([Parameter(Mandatory)][string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) { return 'ABSENT' }
    try {
        $sddl = (Get-Acl -LiteralPath $Path -ErrorAction Stop).Sddl
        return [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes($sddl)))
    } catch { return 'UNREADABLE' }
}
function Get-AclCanary {
    # path -> hash for every root in -Path and every sampled entry below it
    param([string[]]$Path = $script:CanaryPaths)
    $o = [ordered]@{}
    foreach ($p in $Path) {
        $o[$p] = Get-AclCanaryHash -Path $p
        if ($o[$p] -ceq 'ABSENT' -or $o[$p] -ceq 'UNREADABLE') { continue }
        foreach ($c in (Get-AclCanarySample -Root $p)) { $o[$c] = Get-AclCanaryHash -Path $c }
    }
    return $o
}
function Compare-AclCanary {
    # entries whose value differs between two snapshots, as "path: before -> after". A ROOT must be present in both
    # (and equal). A sampled entry that has truly vanished from disk (ordinary churn in a temp folder) is skipped;
    # one still on disk must be equal whether or not the end sample reached it.
    param($Before, $After, [string[]]$Roots = $script:CanaryPaths)
    $changed = New-Object System.Collections.ArrayList
    foreach ($k in $Before.Keys) {
        if (-not $After.Contains($k)) {
            if ($Roots -contains $k) { [void]$changed.Add("${k}: $($Before[$k]) -> (missing)") }
            else {
                # absent from the end SAMPLE is not absent from disk (new earlier-sorting entries push others out): read it directly
                $now = Get-AclCanaryHash -Path $k
                if ($now -cne 'ABSENT' -and $now -cne $Before[$k]) { [void]$changed.Add("${k}: $($Before[$k]) -> $now (outside the end sample)") }
            }
            continue
        }
        if ($Before[$k] -cne $After[$k]) { [void]$changed.Add("${k}: $($Before[$k]) -> $($After[$k])") }
    }
    return @($changed)
}
function Get-AclCanaryBlind {
    # the roots whose access list could not be read: the canary saw nothing there, so it may not certify them
    param($Snap, [string[]]$Roots = $script:CanaryPaths)
    return @($Roots | Where-Object { $Snap.Contains($_) -and $Snap[$_] -ceq 'UNREADABLE' })
}
function Get-AclCanaryObserved {
    # (roots read, sampled entries) in a snapshot
    param($Snap, [string[]]$Roots = $script:CanaryPaths)
    $r = @($Roots | Where-Object { $Snap.Contains($_) -and $Snap[$_] -cmatch '^[0-9A-F]{64}$' }).Count
    return @{ Roots = $r; Entries = ($Snap.Count - @($Roots | Where-Object { $Snap.Contains($_) }).Count) }
}
function Get-AclCanaryVerdict {
    # the canary's judgement of a start/end pair: Failures (any change; any root it could not read unless -AllowBlind),
    # Blind (the roots it made no claim for) and Observed (what it did read)
    param($Start, $End, [switch]$AllowBlind, [string[]]$Roots = $script:CanaryPaths)
    $f = New-Object System.Collections.ArrayList
    foreach ($m in @(Compare-AclCanary $Start $End -Roots $Roots)) { [void]$f.Add("ACL CANARY CHANGED: $m") }
    $blind = @(@(Get-AclCanaryBlind $Start -Roots $Roots) + @(Get-AclCanaryBlind $End -Roots $Roots) | Select-Object -Unique)
    if ($blind.Count -gt 0 -and -not $AllowBlind) { [void]$f.Add("ACL CANARY BLIND, it could not read: $($blind -join ', ') (run elevated)") }
    return @{ Failures = @($f); Blind = $blind; Observed = (Get-AclCanaryObserved $End -Roots $Roots) }
}
function Write-AclCanary {
    param([string]$Label, $Snap)
    $obs = Get-AclCanaryObserved $Snap
    foreach ($k in $script:CanaryPaths) { if ($Snap.Contains($k)) { Write-Host ("  CANARY {0} {1} {2}" -f $Label, $Snap[$k], $k) -ForegroundColor DarkGray } }
    Write-Host ("  CANARY {0}: {1} of {2} paths read, {3} sampled entries below them" -f $Label, $obs.Roots, $script:CanaryPaths.Count, $obs.Entries) -ForegroundColor DarkGray
    $blind = Get-AclCanaryBlind $Snap
    if ($blind.Count -gt 0) { Write-Host "  CANARY BLIND: $($blind.Count) path(s) UNREADABLE from this shell (run elevated): $($blind -join ', ')" -ForegroundColor Yellow }
}

# ---- the independent folder guard --------------------------------------------------------------------------
# Protected roots are listed by name here and read from the OS folder API, never from TMP/TEMP, so a temp folder moved
# onto a system folder is still recognised. NGINXRM_PROTECTED_EXTRA (semicolon list) and $script:ProtectedExtra can only ADD roots.
# A path overlaps a root when it is that root, lies inside it (Under), or contains it (Contains).
$script:ProtectedExtra = @()
function Get-SuiteProtectedRoots {
    $sys = @('C:\Windows', 'C:\Windows\Temp', 'C:\ProgramData', 'C:\Program Files', 'C:\Program Files (x86)', 'C:\nginx', 'C:\ProgramData\nginx-quarantine')
    foreach ($f in 'Windows', 'System', 'ProgramFiles', 'ProgramFilesX86', 'CommonApplicationData') { try { $d = [Environment]::GetFolderPath($f); if ($d) { $sys += $d } } catch { } }
    $sys += @($script:CanaryPaths)
    $sys += @($env:NGINXRM_PROTECTED_EXTRA -split ';' | Where-Object { $_ })
    $sys += @($script:ProtectedExtra)
    $rows = New-Object System.Collections.ArrayList
    foreach ($p in $sys) { [void]$rows.Add(@{ P = $p; Under = $true; Contains = $true }) }
    foreach ($p in @('C:\Users', [Environment]::GetFolderPath('UserProfile'))) { if ($p) { [void]$rows.Add(@{ P = $p; Under = $false; Contains = $true }) } }
    [void]$rows.Add(@{ P = (Split-Path $PSScriptRoot -Parent); Under = $true; Contains = $false })
    return @($rows)
}
if (-not ('BlarFinalPath' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
using System.Text;
public static class BlarFinalPath {
    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    static extern IntPtr CreateFileW(string name, uint access, uint share, IntPtr sec, uint disp, uint flags, IntPtr tmpl);
    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    static extern uint GetFinalPathNameByHandleW(IntPtr h, StringBuilder sb, uint len, uint flags);
    [DllImport("kernel32.dll")]
    static extern bool CloseHandle(IntPtr h);
    // the final path of an existing file or folder with every link followed, or null if it cannot be opened
    public static string Resolve(string path) {
        IntPtr h = CreateFileW(path, 0, 7, IntPtr.Zero, 3, 0x02000000, IntPtr.Zero);
        if (h == new IntPtr(-1)) return null;
        try {
            StringBuilder sb = new StringBuilder(2048);
            uint n = GetFinalPathNameByHandleW(h, sb, 2048, 0);
            if (n == 0 || n >= 2048) return null;
            return sb.ToString();
        } finally { CloseHandle(h); }
    }
}
'@
}
function Get-CanonicalPath {
    # The FINAL path of -Path: every link in it followed (the deepest existing ancestor is resolved by the OS, the not-yet-
    # existing remainder appended), 8.3 names expanded. $null (fail-closed) for UNC, device-namespace (\\?\, \\.\) and
    # relative-to-nothing forms, for a path whose ancestors cannot be opened, and for a final path that is a network path.
    param([string]$Path)
    if ([string]::IsNullOrWhiteSpace($Path)) { return $null }
    if ($Path.TrimStart() -match '^[\\/]{2}') { return $null }
    try { $cur = [IO.Path]::GetFullPath($Path).TrimEnd('\') } catch { return $null }
    $rest = ''
    while ($true) {
        $probe = if ($cur -match '^[A-Za-z]:$') { $cur + '\' } else { $cur }
        $r = [BlarFinalPath]::Resolve($probe)
        if ($r) { break }
        $parent = [IO.Path]::GetDirectoryName($cur)
        if (-not $parent) { return $null }
        $rest = '\' + [IO.Path]::GetFileName($cur) + $rest
        $cur = $parent.TrimEnd('\')
    }
    if ($r.StartsWith('\\?\UNC\', [StringComparison]::OrdinalIgnoreCase)) { return $null }
    if ($r.StartsWith('\\?\')) { $r = $r.Substring(4) } else { return $null }
    return ($r.TrimEnd('\') + $rest)
}
function Get-ReparseComponent {
    # the first component of -Path (drive root excluded) that is a link (junction or symlink), or $null
    param([string]$Path)
    $full = [IO.Path]::GetFullPath($Path).TrimEnd('\')
    $parts = $full.Split('\')
    $cur = $parts[0] + '\'
    for ($i = 1; $i -lt $parts.Count; $i++) {
        $cur = [IO.Path]::Combine($cur, $parts[$i])
        $at = try { [IO.File]::GetAttributes($cur) } catch { return $null }
        if ($at -band [IO.FileAttributes]::ReparsePoint) { return $cur }
    }
    return $null
}
function Test-ProtectedOverlap {
    # true if -Path (as written AND as finally resolved) is, is inside, or contains a protected root (as written AND as
    # finally resolved), is a drive root, or cannot be understood (UNC / device forms, unresolvable): fail-closed
    param([string]$Path)
    if ([string]::IsNullOrWhiteSpace($Path)) { return $true }
    $canon = Get-CanonicalPath $Path
    if ($null -eq $canon) { return $true }
    try { $lit = [IO.Path]::GetFullPath($Path).TrimEnd('\') } catch { return $true }
    # the as-written form is redundant with the link rule in Get-SuiteTempProblem (a spelling that differs from its final path goes through a link); kept for depth
    $mine = @($lit, $canon.TrimEnd('\'))
    foreach ($m in $mine) { if ($m -match '^[A-Za-z]:$') { return $true } }   # a drive root; redundant with the protected list and the temp-root test, kept for depth
    foreach ($row in (Get-SuiteProtectedRoots)) {
        $rootForms = @()
        try { $rootForms += [IO.Path]::GetFullPath([string]$row.P).TrimEnd('\') } catch { }
        $rc = Get-CanonicalPath ([string]$row.P)
        if ($rc) { $rootForms += $rc.TrimEnd('\') }
        foreach ($p in ($rootForms | Select-Object -Unique)) {
            if ($p -eq '') { continue }
            foreach ($full in $mine) {
                if ($full -ieq $p) { return $true }
                if ($row.Under -and $full.StartsWith($p + '\', [StringComparison]::OrdinalIgnoreCase)) { return $true }
                if ($row.Contains -and $p.StartsWith($full + '\', [StringComparison]::OrdinalIgnoreCase)) { return $true }
            }
        }
    }
    return $false
}
function Get-SuiteTempProblem {
    # why the suite must not start with this temp folder, or $null
    param([string]$Temp)
    if ([string]::IsNullOrWhiteSpace($Temp)) { return "the temp folder is not set" }
    if ($Temp.TrimStart() -match '^[\\/]{2}') { return "the temp folder '$Temp' is a UNC or device-namespace path, which is not supported" }
    if (-not (Test-Path -LiteralPath $Temp)) { return "the temp folder '$Temp' does not exist" }
    $link = Get-ReparseComponent $Temp
    if ($link) { return "the temp folder '$Temp' goes through the link '$link' (a junction or symlink as the temp root, or above it, is not supported)" }
    # redundant with Test-ProtectedOverlap, which treats an unresolvable path as protected; kept for depth, and for the message
    if ($null -eq (Get-CanonicalPath $Temp)) { return "the temp folder '$Temp' cannot be resolved to its final path" }
    if (Test-ProtectedOverlap $Temp) { return "the temp folder '$Temp' is, contains, or lies inside a system or protected folder" }
    return $null
}
function Write-SafetyFail {
    param([string]$Message)
    if ($script:SafetyFailSink) { & $script:SafetyFailSink $Message } else { _fail $Message }
}
function Clear-SuiteReadOnly {
    # clears the read-only attribute below -Root. A link ROOT is refused (it would be walked through to its target); a
    # link found below is cleared itself and never entered.
    param([Parameter(Mandatory)][string]$Root)
    $rootAt = [IO.File]::GetAttributes($Root)
    if ($rootAt -band [IO.FileAttributes]::ReparsePoint) { throw "refusing to clear attributes through the link '$Root'" }
    $stack = New-Object System.Collections.Stack
    $stack.Push($Root)
    while ($stack.Count -gt 0) {
        $d = [string]$stack.Pop()
        $kids = try { [IO.Directory]::GetFileSystemEntries($d) } catch { $null }
        foreach ($k in @($kids)) {
            if (-not $k) { continue }
            try {
                $at = [IO.File]::GetAttributes($k)
                if ($at -band [IO.FileAttributes]::ReadOnly) { [IO.File]::SetAttributes($k, [IO.FileAttributes]($at -band (-bnot [IO.FileAttributes]::ReadOnly))) }
                if (($at -band [IO.FileAttributes]::Directory) -and -not ($at -band [IO.FileAttributes]::ReparsePoint)) { $stack.Push($k) }
            } catch { }
        }
    }
}
function Remove-SuiteTree {
    # deletes -Path completely: a link root is removed as a link (target untouched); a real folder has its read-only
    # attributes cleared (links not entered) and is then deleted. Returns $true if nothing is left.
    param([Parameter(Mandatory)][string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) { return $true }
    $at = [IO.File]::GetAttributes($Path)
    if ($at -band [IO.FileAttributes]::ReparsePoint) {
        try {
            if ($at -band [IO.FileAttributes]::ReadOnly) { [IO.File]::SetAttributes($Path, [IO.FileAttributes]($at -band (-bnot [IO.FileAttributes]::ReadOnly))) }
            if ($at -band [IO.FileAttributes]::Directory) { [IO.Directory]::Delete($Path) } else { [IO.File]::Delete($Path) }
        } catch { }
    } else {
        Clear-SuiteReadOnly -Root $Path
        try { [IO.Directory]::Delete($Path, $true) } catch { try { Remove-Item -LiteralPath $Path -Recurse -Force -ErrorAction Stop } catch { } }
    }
    return (-not (Test-Path -LiteralPath $Path))
}

function Get-SweepRefusal {
    # why -Tmp may NOT be swept (a destructive walk), or $null. The folder must be this run's own mutation folder: a REAL
    # directory (no link in it or above it) named for this run's token, strictly inside this process's resolved temp root.
    param([string]$Tmp)
    if ([string]::IsNullOrWhiteSpace($script:SweepToken) -or $script:SweepToken -notmatch '^[0-9a-f]{8}$') { return 'this run has no mutation folder token' }
    if ((Split-Path $Tmp -Leaf) -cne "nginxrm-mut-$($script:SweepToken)") { return "'$Tmp' is not named for this run's token" }
    if (-not (Test-Path -LiteralPath $Tmp -PathType Container)) { return "'$Tmp' is not an existing folder" }
    if (Get-ReparseComponent $Tmp) { return "'$Tmp' is, or sits below, a link" }
    $canon = Get-CanonicalPath $Tmp
    $tempCanon = Get-CanonicalPath ([IO.Path]::GetTempPath())
    if ($null -eq $canon -or $null -eq $tempCanon) { return "'$Tmp' or the temp folder cannot be resolved" }
    if (-not $canon.StartsWith($tempCanon.TrimEnd('\') + '\', [StringComparison]::OrdinalIgnoreCase)) { return "'$Tmp' is not inside the temp folder" }
    if (Test-ProtectedOverlap $Tmp) { return "'$Tmp' overlaps a protected folder" }
    return $null
}
function Invoke-MutationSweep {
    # What the mutation children left behind, reported and then removed (nothing is removed silently):
    #   *.tmp folders: each child's private temp folder; entries in control.tmp are the UNMUTATED control's leaks
    #   anything else beside them in the parent folder: a leak outside the child's own temp folder
    # Returns Refused (a reason; nothing was listed or touched), Swept (name:count), ControlLeft (count), Outside (names),
    # Stuck (paths that could not be removed).
    param([Parameter(Mandatory)][string]$Tmp)
    $res = @{ Refused = ''; Swept = @(); ControlLeft = 0; Outside = @(); Stuck = @() }
    $why = Get-SweepRefusal $Tmp
    if ($why) { $res.Refused = $why; return $res }
    foreach ($e in @(Get-ChildItem -LiteralPath $Tmp -Force -ErrorAction SilentlyContinue)) {
        if ($e.Name -match '^(control|m-.+)$' -and $e.Name -notmatch '\.tmp$') { continue }   # the copies of the sources; removed with the folder
        if ($e.Name -match '^(control|m-.+)\.tmp$') {
            $nLeft = @(Get-ChildItem -LiteralPath $e.FullName -Force -ErrorAction SilentlyContinue).Count
            if ($nLeft -gt 0) {
                Write-Host ("  [swept]    {0}: left {1} entr{2} in its private temp folder; removed by the parent" -f ($e.Name -replace '\.tmp$', ''), $nLeft, $(if ($nLeft -eq 1) { 'y' } else { 'ies' })) -ForegroundColor Yellow
                $res.Swept += "$($e.Name -replace '\.tmp$', ''):$nLeft"
                if ($e.Name -ceq 'control.tmp') { $res.ControlLeft = $nLeft }
            }
        } else {
            Write-Host "  [LEAK-OUT] a mutation child left '$($e.Name)' in the parent folder, outside its own temp folder; removed by the parent" -ForegroundColor Yellow
            $res.Outside += $e.Name
        }
        if (-not (Remove-SuiteTree -Path $e.FullName)) { $res.Stuck += $e.FullName }
    }
    if (-not (Remove-SuiteTree -Path $Tmp)) { $res.Stuck += $Tmp }
    return $res
}
function Complete-MutationRun {
    # the end of a mutation run: the canary verdict, then the sweep, then the result. Returns the exit code.
    param([hashtable]$R, $CanaryStart)
    $canaryEnd = Get-AclCanary; Write-AclCanary 'run-end  ' $canaryEnd
    $runVerdict = Get-AclCanaryVerdict $CanaryStart $canaryEnd -AllowBlind:$AllowBlindCanary
    if ($runVerdict.Failures.Count -gt 0) { foreach ($c in $runVerdict.Failures) { Write-Host "  [FAIL] $c (DURING THE MUTATION RUN)" -ForegroundColor Red } }
    else { Write-Host ("  ACL canary: unchanged across the mutation run ({0} of {1} paths read, {2} sampled entries)" -f $runVerdict.Observed.Roots, $script:CanaryPaths.Count, $runVerdict.Observed.Entries) -ForegroundColor Green }
    $sw = Invoke-MutationSweep $R.Tmp
    if ($sw.Refused) { Write-Host "  [FAIL] refusing to sweep: $($sw.Refused). Nothing was listed or removed." -ForegroundColor Red; return 3 }
    if ($sw.Stuck.Count -gt 0) { foreach ($s in $sw.Stuck) { Write-Host "  [STUCK]    could not remove '$s'" -ForegroundColor Red }; return 5 }
    if ($runVerdict.Failures.Count -gt 0) { return 4 }
    if (-not $R.Control) { return 2 }
    if ($sw.ControlLeft -gt 0) { Write-Host "  [FAIL] the UNMUTATED control's child left $($sw.ControlLeft) entr$(if ($sw.ControlLeft -eq 1) { 'y' } else { 'ies' }) in its private temp folder: the suite does not clean up after itself" -ForegroundColor Red; return 6 }
    if (@($R.Results).Count -eq 0) { Write-Host '  [FAIL] no mutants ran: an empty run is not a result' -ForegroundColor Red; return 7 }
    $killed = @($R.Results | Where-Object { $_.Class -eq 'KILLED' }); $other = @($R.Results | Where-Object { $_.Class -ne 'KILLED' })
    Write-Host ''
    Write-Host "MUTATION RESULT: $($killed.Count) of $(@($R.Results).Count) killed; $($other.Count) not killed" -ForegroundColor $(if ($other.Count -eq 0) { 'Green' } else { 'Red' })
    Write-Host "MUTATIONS: $($killed.Count) killed, $(@($other | Where-Object { $_.Class -eq 'SURVIVED' }).Count) survived, $(@($other | Where-Object { $_.Class -eq 'ERROR' }).Count) error"
    foreach ($o in $other) { Write-Host "  NOT KILLED: $($o.N) [$($o.Class)] $($o.Why)" -ForegroundColor Red }
    if ($other.Count -eq 0) { return 0 } else { return 1 }
}

if ($Mutations -or $ProveHarness) {
    if ($env:NGINXRM_NESTED) { Write-Host '  [FAIL] a nested test run never starts a mutation run' -ForegroundColor Red; exit 9 }
    $tempProblem = Get-SuiteTempProblem ([IO.Path]::GetTempPath())
    if ($tempProblem) { Write-Host "  [FAIL] refusing to start: $tempProblem" -ForegroundColor Red; exit 3 }
    try { (Get-Process -Id $PID).PriorityClass = 'BelowNormal' } catch { }
    . "$PSScriptRoot\hidden-process-lib.ps1"
    $pw = (Get-Command pwsh -ErrorAction SilentlyContinue).Source
    $files = 'remove-nginx-gateway.ps1', 'verify-nginx-removal.ps1', 'coder-acl-lib.ps1', 'hidden-process-lib.ps1'
    $run = {
        param($Dir, $Mut, $files, $pw, $SrcDir, $Allow)
        . (Join-Path $SrcDir 'hidden-process-lib.ps1')
        $sd = Join-Path $Dir 'scripts'; New-Item -ItemType Directory -Force $sd | Out-Null
        foreach ($f in $files) { Copy-Item (Join-Path $SrcDir $f) (Join-Path $sd $f) }
        if ($Mut) {
            $target = Join-Path $sd $Mut.F
            $text = ([IO.File]::ReadAllText($target)).Replace("`r`n", "`n")   # match on LF: a CRLF working copy is the same text
            $mo = ([string]$Mut.O).Replace("`r`n", "`n"); $mw = ([string]$Mut.W).Replace("`r`n", "`n")
            if (-not $text.Contains($mo)) { return @{ Class = 'ERROR'; Why = "mutation target not found in $($Mut.F)" } }
            [IO.File]::WriteAllText($target, $text.Replace($mo, $mw), (New-Object Text.UTF8Encoding($true)))
        }
        $ca = @('-NoProfile', '-NonInteractive', '-File', (Join-Path $sd 'verify-nginx-removal.ps1'), '-NoSmoke')
        if ($Allow) { $ca += '-AllowBlindCanary' }
        $ct = $Dir + '.tmp'; New-Item -ItemType Directory -Force $ct | Out-Null   # the child's own temp folder: whatever it leaves is the parent's to find and sweep
        $h = Invoke-HiddenProcess -FilePath $pw -ArgumentList $ca -TimeoutSec 900 -Environment @{ TMP = $ct; TEMP = $ct }
        $out = $h.Stdout + "`n" + $h.Stderr
        $fails = @($out -split "`n" | Where-Object { $_ -match '\[FAIL\]' })
        if ($h.ExitCode -eq 0) { return @{ Class = 'SURVIVED'; Why = 'the suite did not notice' } }
        if ($fails.Count -gt 0) { return @{ Class = 'KILLED'; Why = ("$($fails[0])").Trim() } }
        return @{ Class = 'ERROR'; Why = 'non-zero exit with no [FAIL] line: ' + (($out -split "`n" | Where-Object { $_.Trim() } | Select-Object -Last 3) -join ' | ') }
    }
    function Invoke-MutationRun([object[]]$Muts) {
        $script:SweepToken = [guid]::NewGuid().ToString('N').Substring(0, 8)
        $tmp = Join-Path ([IO.Path]::GetTempPath()) ('nginxrm-mut-' + $script:SweepToken)
        $allowFlag = [bool]$AllowBlindCanary
        $ctl = & $run (Join-Path $tmp 'control') $null $files $pw $PSScriptRoot $allowFlag
        $controlOk = ($ctl.Class -eq 'SURVIVED'); $res = @()
        if (-not $controlOk) { Write-Host "  [CONTROL FAILED] the unmutated copy does not pass: $($ctl.Why)" -ForegroundColor Red }
        else {
            Write-Host '  [control]  unmutated copy passes' -ForegroundColor Green
            $runText = $run.ToString()
            $res = @($Muts | ForEach-Object -ThrottleLimit ([math]::Max(1, $Throttle)) -Parallel {
                    $m = $_; $rb = [scriptblock]::Create($using:runText)
                    $r = & $rb (Join-Path $using:tmp ('m-' + $m.N)) $m $using:files $using:pw $using:PSScriptRoot $using:allowFlag
                    Write-Host ("  [{0}] {1}  <- {2}" -f $r.Class.PadRight(8), $m.N, $r.Why) -ForegroundColor $(if ($r.Class -eq 'KILLED') { 'Green' } else { 'Red' })
                    @{ N = $m.N; Class = $r.Class; Why = $r.Why }
                })
        }
        return @{ Control = $controlOk; Results = $res; Tmp = $tmp }
    }
    $R = 'remove-nginx-gateway.ps1'; $A = 'coder-acl-lib.ps1'; $V = 'verify-nginx-removal.ps1'
    if ($ProveHarness) {
        $probe = @(
            @{ N = 'equivalent-comment-change'; F = $R; O = '# ---- the plan view (read-only) ----'; W = '# ---- the plan view (renamed) ----' },
            @{ N = 'crashing-syntax-break';     F = $R; O = 'function Assert-RemovalAllowed {'; W = 'function Assert-RemovalAllowed { }}}}' },
            @{ N = 'real-kill-guard-disabled';  F = $R; O = 'if ($list -cnotcontains $Name) { throw'; W = 'if ($false) { throw' }
        )
        $r = Invoke-MutationRun $probe
        $swp = Invoke-MutationSweep $r.Tmp
        if ($swp.Refused) { Write-Host "  [FAIL] refusing to sweep: $($swp.Refused)" -ForegroundColor Red; exit 3 }
        if ($swp.Stuck.Count -gt 0) { foreach ($s in $swp.Stuck) { Write-Host "  [STUCK]    could not remove '$s'" -ForegroundColor Red }; exit 5 }
        $want = @{ 'equivalent-comment-change' = 'SURVIVED'; 'crashing-syntax-break' = 'ERROR'; 'real-kill-guard-disabled' = 'KILLED' }
        $bad = @($r.Results | Where-Object { $want[$_.N] -ne $_.Class })
        if ($r.Control -and $bad.Count -eq 0 -and $r.Results.Count -eq 3) { Write-Host 'HARNESS PROVEN: survivor reported SURVIVED, crasher reported ERROR, real kill reported KILLED' -ForegroundColor Green; exit 0 }
        Write-Host 'HARNESS NOT PROVEN' -ForegroundColor Red; exit 1
    }
    $muts = @(
        @{ N = 'allowlist-guard-disabled';       F = $R; O = 'if ($list -cnotcontains $Name) { throw'; W = 'if ($false) { throw' },
        @{ N = 'allowlist-widened-to-prefix';    F = $R; O = 'if ($list -cnotcontains $Name) { throw'; W = 'if (-not @($list | Where-Object { $Name -like ($_ + ''*'') }).Count) { throw' },
        @{ N = 'allowlist-widened-to-wildcard';  F = $R; O = 'if ($list -cnotcontains $Name) { throw'; W = 'if (-not ($Name -like ''*ngin*'' -or $list -contains $Name)) { throw' },
        @{ N = 'allowlist-case-insensitive';     F = $R; O = 'if ($list -cnotcontains $Name) { throw'; W = 'if ($list -notcontains $Name) { throw' },
        @{ N = 'task-name-added-to-list';        F = $R; O = '''GatewayNginxPruneMonthly'')'; W = '''GatewayNginxPruneMonthly'', ''Evil'')' },
        @{ N = 'trusted-sids-widened';           F = $R; O = '$script:RemovalTrustedSids = @(''S-1-5-18'', ''S-1-5-32-544'')'; W = '$script:RemovalTrustedSids = @(''S-1-5-18'', ''S-1-5-32-544'', ''S-1-5-11'')' },
        @{ N = 'folder-gate-disabled';           F = $R; O = 'throw "refusing folder ''$Path'': only'; W = 'return; throw "refusing folder ''$Path'': only' },
        @{ N = 'quarantine-gate-disabled';       F = $R; O = 'throw "refusing quarantine root ''$Root''"'; W = 'return' },
        @{ N = 'dry-run-default-flipped';        F = $R; O = '    if (-not $Execute) {
        if (-not $state.Elevated)'; W = '    if ($Execute) {
        if (-not $state.Elevated)' },
        @{ N = 'dry-run-acts-anyway';            F = $R; O = '        return (& $result $(if ($refusals.Count -gt 0) { 2 } else { 0 }) $refusals)
    }'; W = '    }' },
        @{ N = 'elevation-check-removed';        F = $R; O = 'if ($IsExecute -and -not $State.Elevated) {'; W = 'if ($false) {' },
        @{ N = 'process-check-removed';          F = $R; O = 'if ($State.NginxProcesses -gt 0) {'; W = 'if ($false) {' },
        @{ N = 'listener-check-removed';         F = $R; O = 'if (@($State.Listeners).Count -gt 0) {'; W = 'if ($false) {' },
        @{ N = 'listener-port-8081-dropped';     F = $R; O = '$script:RemovalPorts = @(443, 8081)'; W = '$script:RemovalPorts = @(443)' },
        @{ N = 'listener-port-443-dropped';      F = $R; O = '$script:RemovalPorts = @(443, 8081)'; W = '$script:RemovalPorts = @(8081)' },
        @{ N = 'service-identity-unchecked';     F = $R; O = 'if (-not ([string]$State.Service.PathName).StartsWith($Plan.ServiceImagePrefix, [StringComparison]::OrdinalIgnoreCase)) {'; W = 'if ($false) {' },
        @{ N = 'task-identity-unchecked';        F = $R; O = '([string]$t.Task.ActionText) -notmatch ''(?i)nginx'') {'; W = '$false) {' },
        @{ N = 'rule-identity-unchecked';        F = $R; O = '($f.Direction -ne ''Inbound'' -or $f.Action -ne ''Allow'')) {'; W = '$false) {' },
        @{ N = 'folder-requires-service-dropped'; F = $R; O = 'if ($State.Service -and $Scope -notcontains ''Service'') {'; W = 'if ($false) {' },
        @{ N = 'folder-requires-tasks-dropped';  F = $R; O = 'if ($liveTasks.Count -gt 0 -and $Scope -notcontains ''Tasks'') {'; W = 'if ($false) {' },
        @{ N = 'other-references-ignored';       F = $R; O = 'foreach ($o in @($State.Others | Where-Object { $_.Enabled })) {'; W = 'foreach ($o in @()) {' },
        @{ N = 'delete-without-folder-allowed';  F = $R; O = 'if ($DeleteQuarantine -and $Scope -notcontains ''Folder'') {'; W = 'if ($false) {' },
        @{ N = 'quarantine-volume-unchecked';    F = $R; O = 'if ([IO.Path]::GetPathRoot($q) -ine [IO.Path]::GetPathRoot($Plan.Folder)) {'; W = 'if ($false) {' },
        @{ N = 'quarantine-skipped-and-unchecked'; F = $R; O = '                    [IO.Directory]::Move($Plan.Folder, $dest)
                    if (Test-Path -LiteralPath $Plan.Folder) { throw "''$($Plan.Folder)'' still exists after the move" }
'; W = '' },
        @{ N = 'quarantine-skipped';             F = $R; O = '[IO.Directory]::Move($Plan.Folder, $dest)'; W = '$null = 0' },
        @{ N = 'takeown-not-to-administrators';  F = $R; O = '& takeown.exe /A /F $Path'; W = '& takeown.exe /F $Path' },
        @{ N = 'qroot-owner-not-administrators'; F = $R; O = '    $sec.SetOwner($adminsSid)
'; W = '' },
        @{ N = 'qmarker-owner-not-administrators'; F = $R; O = '    $fsec.SetOwner($adminsSid)
'; W = '' },
        @{ N = 'existing-quarantine-root-trusted'; F = $R; O = 'if (-not (Test-Path -LiteralPath $marker)) { throw'; W = 'if ($false) { throw' },
        @{ N = 'existing-quarantine-root-unchecked'; F = $R; O = 'if (-not $chk.Ok) { throw "the existing quarantine root'; W = 'if ($false) { throw "the existing quarantine root' },
        @{ N = 'pre-move-lock-recheck-removed'; F = $R; O = 'if (-not $pre.Ok) { throw ''the folder is not locked at the moment of the move: refusing'' }'; W = '' },
        @{ N = 'takeown-skipped';                F = $R; O = '            & $TakeOwnership $p
'; W = '' },
        @{ N = 'lock-keeps-inheritance';         F = $R; O = '$acl.SetAccessRuleProtection($true, $false)
                    foreach ($r in @($acl.GetAccessRules($true, $false'; W = '$acl.SetAccessRuleProtection($false, $true)
                    foreach ($r in @($acl.GetAccessRules($true, $false' },
        @{ N = 'lock-keeps-old-entries';         F = $R; O = '[void]$acl.RemoveAccessRuleSpecific($r) }'; W = '}' },
        @{ N = 'lock-verification-skipped';      F = $R; O = '                    if (-not $chk.Ok) { throw "verification failed:'; W = '                    if ($false) { throw "verification failed:' },
        @{ N = 'lock-walk-errors-ignored';       F = $R; O = 'if (@($w.Errors).Count -gt 0) { throw "the lock walk had'; W = 'if ($false) { throw "the lock walk had' },
        @{ N = 'verifier-ignores-owner';         F = $R; O = 'if ($sids -notcontains $got.Owner) { [void]$script:__viol.Add("$p : owner is $($got.Owner)") }'; W = '' },
        @{ N = 'verifier-ignores-inheritance';   F = $R; O = 'if (-not $acl.AreAccessRulesProtected) { [void]$script:__viol.Add("$p : inherits from its parent") }'; W = '' },
        @{ N = 'verifier-ignores-foreign-entries'; F = $R; O = 'if ($sids -notcontains $r.IdentityReference.Value) { [void]$script:__viol.Add("$p : entry for $($r.IdentityReference.Value)") }'; W = '' },
        @{ N = 'verifier-passes-with-errors';    F = $R; O = '$v.Count -eq 0 -and @($w.Errors).Count -eq 0 -and $w.Visited -gt 0'; W = '$v.Count -eq 0' },
        @{ N = 'service-postcondition-removed';  F = $R; O = 'if (-not (& $Sys.ServiceGone $script:RemovalAllowedService[0])) { throw ''the service is still present and not marked for deletion'' }'; W = '' },
        @{ N = 'service-stop-unchecked';         F = $R; O = 'if ($now -and $now.State -ne ''Stopped'') { throw "the service did not stop'; W = 'if ($false) { throw "the service did not stop' },
        @{ N = 'task-postcondition-removed';     F = $R; O = 'if (& $Sys.GetTask $name) { throw "task $name is still registered" }'; W = '' },
        @{ N = 'rule-postcondition-removed';     F = $R; O = 'if (@(& $Sys.GetRules $name | Where-Object { $_.Id -eq $f.Id }).Count -gt 0) { throw "rule ''$name'' is still present" }'; W = '' },
        @{ N = 'final-readback-removed';         F = $R; O = 'if ($left.Count -gt 0) { throw "read-back: still present:'; W = 'if ($false) { throw "read-back: still present:' },
        @{ N = 'step-failure-does-not-stop';     F = $R; O = '& $log ''FAIL'' "$stepTitle : $($_.Exception.Message)"; throw }'; W = '& $log ''FAIL'' "$stepTitle : $($_.Exception.Message)" }' },
        @{ N = 'failure-exit-code-zero';         F = $R; O = 'return (& $result 3 @($_.Exception.Message))'; W = 'return (& $result 0 @($_.Exception.Message))' },
        @{ N = 'refusal-exit-code-zero';         F = $R; O = 'if ($refusals.Count -gt 0) { return (& $result 2 $refusals) }'; W = 'if ($refusals.Count -gt 0) { return (& $result 0 $refusals) }' },
        @{ N = 'service-step-before-lock';       F = $R; O = '        $dest = Get-RemovalDestination -Plan $Plan
        $folderHere'; W = '        $null = & $Sys.DeleteService ''NginxGateway''
        $dest = Get-RemovalDestination -Plan $Plan
        $folderHere' },
        @{ N = 'idempotence-service-recalled';   F = $R; O = 'if (-not $svc) { & $log ''INFO'' ''already done: service NginxGateway is not present'' }'; W = 'if ($false) { }' },
        @{ N = 'idempotence-task-recalled';      F = $R; O = 'if (-not $t) { & $log ''INFO'' "already done: task $name is not present"; continue }'; W = '' },
        @{ N = 'delete-follows-links';           F = $R; O = 'if ($attr -band [IO.FileAttributes]::ReparsePoint) {'; W = 'if ($false) {' },
        @{ N = 'delete-keeps-readonly';          F = $R; O = 'if ($attr -band [IO.FileAttributes]::ReadOnly) { [IO.File]::SetAttributes($e, [IO.FileAttributes]::Normal) }'; W = '' },
        @{ N = 'delete-link-as-folder-recursion'; F = $R; O = 'if ($attr -band [IO.FileAttributes]::Directory) { [IO.Directory]::Delete($e) } else { [IO.File]::Delete($e) }'; W = 'Remove-RemovalTree -Path $e' },
        @{ N = 'delete-root-link-unchecked';     F = $R; O = 'if ($rootAttr -band [IO.FileAttributes]::ReparsePoint) { throw "refusing to delete ''$Path'': it is a link (junction or symlink), not a real folder" }'; W = '' },
        @{ N = 'delete-root-recheck-dropped';    F = $R; O = 'if (-not $qchk.Ok) { throw'; W = 'if ($false) { throw' },
        @{ N = 'delete-copy-recheck-dropped';    F = $R; O = 'if (-not $dchk.Ok) { throw'; W = 'if ($false) { throw' },
        @{ N = 'delete-readonly-folder-not-cleared'; F = $R; O = 'if ($rootAttr -band [IO.FileAttributes]::ReadOnly) { [IO.File]::SetAttributes($Path,'; W = 'if ($false) { [IO.File]::SetAttributes($Path,' },
        @{ N = 'delete-readonly-link-not-cleared'; F = $R; O = 'if ($attr -band [IO.FileAttributes]::ReadOnly) { [IO.File]::SetAttributes($e, [IO.FileAttributes]($attr -band (-bnot [IO.FileAttributes]::ReadOnly))) }'; W = '' },
        @{ N = 'delete-quarantine-default-on';   F = $R; O = '            if ($DeleteQuarantine) {
                if (-not (Test-Path'; W = '            if ($true) {
                if (-not (Test-Path' },
        @{ N = 'delete-quarantine-flag-ignored'; F = $R; O = '            if ($DeleteQuarantine) {
                if (-not (Test-Path'; W = '            if ($false) {
                if (-not (Test-Path' },
        @{ N = 'delete-marker-unchecked';        F = $R; O = 'if (-not (Test-Path -LiteralPath ([IO.Path]::Combine($Plan.QuarantineRoot, ''.nginx-gateway-quarantine'')))) { throw ''the quarantine marker is missing: refusing to delete'' }'; W = '' },
        @{ N = 'conf-copy-skipped';              F = $R; O = '            $c = Confirm-RemovalConfBackup -Source (Join-Path $Plan.Folder ''conf\nginx.conf'') -BackupDir $Plan.ConfBackupDir -Write $true'; W = '            $c = @{ Ok = $true; Action = ''skipped''; Path = '''' }' },
        @{ N = 'conf-copy-overwrites';           F = $R; O = '$dest2 = Join-Path $BackupDir (''nginx.conf.'' + (Get-Date -Format ''yyyyMMdd-HHmmss'') + ''.'' + $h.Substring(0, 8))'; W = '$dest2 = $dest' },
        @{ N = 'log-not-written';                F = $R; O = 'if ($logPath) { Add-Content -LiteralPath $logPath -Value $line -Encoding UTF8 }'; W = '' },
        @{ N = 'key-material-listed';            F = $R; O = 'if ($p -match ''(?i)\.(key|pfx|p12|pk8)$'') { [void]$script:__inv.Keys.Add($p.Substring($root.Length).TrimStart(''\'')) }'; W = 'if ($p -match ''(?i)\.(key|pfx|p12|pk8)$'') { [void]$script:__inv.Keys.Add((Get-Content -LiteralPath $p -Raw)) }' },
        @{ N = 'key-names-not-counted';          F = $R; O = '        & $Out ("  private-key file NAMES (by .key/.pfx/.p12/.pk8 extension; contents are never read): {0}" -f @($f.KeyNames).Count)'; W = '' },
        @{ N = 'refusal-test-aimed-at-unowned-path'; F = $V; O = '$rf = "$TmpRoot\zz-refused-lock-$rfId"'; W = '$rf = "$TmpRoot\zz-refused-lock-notmine"' },
        @{ N = 'throwaway-ownership-dropped';    F = $V; O = 'return $canon.Substring($root.Length).Split(''\'')[0].Contains($script:RunToken)'; W = 'return $true' },
        @{ N = 'throwaway-overlap-check-dropped'; F = $V; O = '    if (Test-ProtectedOverlap $Path) { return $false }
    $root = $script:TmpRootCanon.TrimEnd(''\'') + ''\''
    if ($canon.Length -le $root.Length) { return $false }'; W = '    $root = $script:TmpRootCanon.TrimEnd(''\'') + ''\''
    if ($canon.Length -le $root.Length) { return $false }' },
        @{ N = 'throwaway-resolution-removed';   F = $V; O = '    $canon = Get-CanonicalPath $Path
    if ($null -eq $canon) { return $false }
    if (Test-ProtectedOverlap $Path) { return $false }
    $root = $script:TmpRootCanon.TrimEnd(''\'') + ''\''
    if ($canon.Length -le $root.Length) { return $false }'; W = '    $canon = [IO.Path]::GetFullPath($Path)
    if (Test-ProtectedOverlap $Path) { return $false }
    $root = $script:TmpRootCanon.TrimEnd(''\'') + ''\''
    if ($canon.Length -le $root.Length) { return $false }' },
        @{ N = 'cleanup-resolution-removed';     F = $V; O = '    $canon = Get-CanonicalPath $Path
    if ($null -eq $canon) { return $false }
    if (Test-ProtectedOverlap $Path) { return $false }
    $root = $script:TmpRootCanon.TrimEnd(''\'') + ''\''
    return ('; W = '    $canon = [IO.Path]::GetFullPath($Path)
    if (Test-ProtectedOverlap $Path) { return $false }
    $root = $script:TmpRootCanon.TrimEnd(''\'') + ''\''
    return (' },
        @{ N = 'canonical-resolution-removed';   F = $V; O = '$cur + ''\'' } else { $cur }
        $r = [BlarFinalPath]::Resolve($probe)'; W = '$cur + ''\'' } else { $cur }
        $r = ''\\?\'' + $probe' },
        @{ N = 'canonical-prefix-refusal-removed'; F = $V; O = 'if ($Path.TrimStart() -match ''^[\\/]{2}'') { return $null }'; W = '' },
        @{ N = 'temp-link-check-removed';        F = $V; O = '$link = Get-ReparseComponent $Temp'; W = '$link = $null' },
        @{ N = 'reparse-walk-ignores-links';     F = $V; O = 'if ($at -band [IO.FileAttributes]::ReparsePoint) { return $cur }'; W = 'if ($false) { return $cur }' },
        @{ N = 'nested-guard-removed';           F = $V; O = 'if ($env:NGINXRM_NESTED) { Write-Host ''  [FAIL] a nested test run never starts a mutation run'' -ForegroundColor Red; exit 9 }'; W = '' },
        @{ N = 'clear-readonly-link-root-allowed'; F = $V; O = 'if ($rootAt -band [IO.FileAttributes]::ReparsePoint) { throw'; W = 'if ($false) { throw' },
        @{ N = 'cleanup-readonly-enters-links';  F = $V; O = '-and -not ($at -band [IO.FileAttributes]::ReparsePoint)) { $stack.Push($k) }'; W = ') { $stack.Push($k) }' },
        @{ N = 'sweep-stuck-exit-removed';       F = $V; O = 'Write-Host "  [STUCK]    could not remove ''$s''" -ForegroundColor Red }; return 5 }'; W = 'Write-Host "  [STUCK]    could not remove ''$s''" -ForegroundColor Red } }' },
        @{ N = 'sweep-containment-removed';      F = $V; O = 'if ($why) { $res.Refused = $why; return $res }'; W = 'if ($false) { }' },
        @{ N = 'sweep-token-check-removed';      F = $V; O = 'if ((Split-Path $Tmp -Leaf) -cne "nginxrm-mut-$($script:SweepToken)") {'; W = 'if ($false) {' },
        @{ N = 'sweep-link-check-removed';       F = $V; O = 'if (Get-ReparseComponent $Tmp) {'; W = 'if ($false) {' },
        @{ N = 'sweep-temp-root-check-removed';  F = $V; O = 'if (-not $canon.StartsWith($tempCanon.TrimEnd(''\'') + ''\'', [StringComparison]::OrdinalIgnoreCase)) {'; W = 'if ($false) {' },
        @{ N = 'empty-run-passes';               F = $V; O = 'if (@($R.Results).Count -eq 0) {'; W = 'if ($false) {' },
        @{ N = 'sweep-control-leak-ignored';     F = $V; O = 'if ($sw.ControlLeft -gt 0) {'; W = 'if ($false) {' },
        @{ N = 'sweep-report-removed';           F = $V; O = '"  [swept]    {0}'; W = '"  [sweep]    {0}' },
        @{ N = 'sweep-outside-leak-silent';     F = $V; O = '"  [LEAK-OUT] a mutation child left'; W = '"  [LEAK-X]   a mutation child left' },
        @{ N = 'canonical-network-final-accepted'; F = $V; O = 'if ($r.StartsWith(''\\?\UNC\'', [StringComparison]::OrdinalIgnoreCase)) { return $null }'; W = '' },
        @{ N = 'snapshot-attributes-dropped';    F = $V; O = '"$rel|$($_.Length)|$($_.Attributes)|$sd"'; W = '"$rel|$($_.Length)|$sd"' },
        @{ N = 'protected-root-resolved-form-dropped'; F = $V; O = 'if ($rc) { $rootForms += $rc.TrimEnd(''\'') }'; W = '' },
        @{ N = 'temp-root-recheck-removed';      F = $V; O = 'if ($c -cne $script:TmpRootCanon -or (Get-ReparseComponent $TmpRoot)) {'; W = 'if ($false) {' },
        @{ N = 'cleanup-leftover-unreported';    F = $V; O = 'Write-SafetyFail "cleanup left'; W = 'Write-Verbose "cleanup left' },
        @{ N = 'assert-throwaway-never-throws';  F = $V; O = '; throw "unsafe target ''$Path'' for $What" }'; W = '; return }' },
        @{ N = 'startup-temp-check-disabled';    F = $V; O = 'if ($tempProblem) {'; W = 'if ($false) {' },
        @{ N = 'protected-overlap-always-false'; F = $V; O = 'function Test-ProtectedOverlap {'; W = 'function Test-ProtectedOverlap { return $false' },
        @{ N = 'cleanup-recheck-removed';        F = $V; O = 'if (-not (Test-CleanupPathSafe $c)) {'; W = 'if ($false) {' },
        @{ N = 'cleanup-keeps-readonly';         F = $V; O = '        Clear-SuiteReadOnly -Root $Path
'; W = '' },
        @{ N = 'only-empty-ignored';             F = $V; O = 'if ($onlyGiven -and $Only.Count -eq 0) {'; W = 'if ($false) {' },
        @{ N = 'only-without-mutations-ignored'; F = $V; O = 'if ($onlyGiven -and -not $Mutations) {'; W = 'if ($false) {' },
        @{ N = 'canary-depth-counter-broken';    F = $V; O = '$queue.Enqueue(@($k, ($depth + 1)))'; W = '$queue.Enqueue(@($k, $depth + 1))' },
        @{ N = 'canary-depth-unbounded';         F = $V; O = '$script:CanaryMaxDepth = 2'; W = '$script:CanaryMaxDepth = 99' },
        @{ N = 'canary-evicted-entry-skipped';   F = $V; O = 'if ($now -cne ''ABSENT'' -and $now -cne $Before[$k]) {'; W = 'if ($false) {' },
        @{ N = 'throwaway-guard-always-true';    F = $V; O = 'function Test-ThrowawayPath([string]$Path) {'; W = 'function Test-ThrowawayPath([string]$Path) { return $true' },
        @{ N = 'canary-compare-blind';           F = $V; O = 'if ($Before[$k] -cne $After[$k]) {'; W = 'if ($false) {' },
        @{ N = 'canary-snapshot-constant';       F = $V; O = '$sddl = (Get-Acl -LiteralPath $Path -ErrorAction Stop).Sddl'; W = '$sddl = "constant"' },
        @{ N = 'canary-children-not-sampled';    F = $V; O = '$script:CanaryMaxEntries = 200'; W = '$script:CanaryMaxEntries = 0' },
        @{ N = 'canary-sample-not-recursive';    F = $V; O = '$script:CanaryMaxDepth = 2'; W = '$script:CanaryMaxDepth = 0' },
        @{ N = 'canary-vanished-root-ignored';   F = $V; O = 'if ($Roots -contains $k) { [void]$changed.Add("${k}: $($Before[$k]) -> (missing)") }'; W = '' },
        @{ N = 'canary-unreadable-not-blind';    F = $V; O = 'return @($Roots | Where-Object { $Snap.Contains($_) -and $Snap[$_] -ceq ''UNREADABLE'' })'; W = 'return @()' },
        @{ N = 'canary-blind-allowed-always';    F = $V; O = 'if ($blind.Count -gt 0 -and -not $AllowBlind) {'; W = 'if ($false) {' },
        @{ N = 'in-lock-gate-recheck-removed';   F = $R; O = '    Assert-RemovalFolderAllowed -Path $Path
    $sids = @($TrustedSids)'; W = '    $sids = @($TrustedSids)' },
        @{ N = 'walk-enters-links';              F = $A; O = 'if ($attr -band [IO.FileAttributes]::ReparsePoint) { [void]$res.Links.Add($e); continue }'; W = 'if ($false) { continue }' }
    )
    if ($Only.Count -gt 0) {
        $unknown = @($Only | Where-Object { $n = $_; -not @($muts | Where-Object { $_.N -ceq $n }).Count })
        if ($unknown.Count -gt 0) {
            Write-Host "  [FAIL] -Only names no known mutant: $($unknown -join ', ')" -ForegroundColor Red; exit 3
        }
        $muts = @($muts | Where-Object { $Only -ccontains $_.N })
    }
    if ($muts.Count -eq 0) { Write-Host '  [FAIL] no mutants selected: a run of zero mutants is not a result' -ForegroundColor Red; exit 3 }
    # Mutants judged EQUIVALENT or unreachable offline, so not run (each reason checked by hand):
    #   folder-gate-dotdot-removed          a path with '..' is refused by the exact-match test that follows it anyway
    #   quarantine-move-postcondition-only  [IO.Directory]::Move either renames or throws; the combined mutant above is run
    #   post-move-count-unchecked           a same-volume rename keeps every entry; a count that differs cannot be produced offline
    #   quarantine-root-not-locked          the OS applies the explicit protected list at creation whatever the in-memory flag says (measured)
    #   quarantine-root-lock-unverified     the read-back after creating the root uses the same trusted list that built it; a divergence cannot be produced offline
    #   idempotence-rule-recalled           looping over an empty rule list does nothing
    #   conf-copy-unverified                Copy-Item cannot be made to corrupt a copy offline
    #   log-folder-unchecked                Add-Content on a missing folder throws into the same refusal
    #   delete-dest-real-folder-unchecked   the same shapes are caught by the copy lock re-check and by Remove-RemovalTree's own root check
    #   handle-open-follows-links           the walk never hands a link to the handle open; killed by the narrowing suite instead
    Write-Host "== mutation run: $($muts.Count) mutants ==" -ForegroundColor Cyan
    $canaryStart = Get-AclCanary; Write-AclCanary 'run-start' $canaryStart
    $startBlind = @(Get-AclCanaryBlind $canaryStart)
    if ($startBlind.Count -gt 0 -and -not $AllowBlindCanary) {
        Write-Host "  [FAIL] ACL CANARY BLIND, it could not read: $($startBlind -join ', '). Run elevated, or pass -AllowBlindCanary to run without the canary's claim for those paths. Nothing was run." -ForegroundColor Red; exit 4
    }
    $r = Invoke-MutationRun $muts
    exit (Complete-MutationRun -R $r -CanaryStart $canaryStart)
}

. "$PSScriptRoot\remove-nginx-gateway.ps1"   # dot-sourced: functions only, nothing runs
$script:Pass = 0; $script:Fail = 0; $script:Failures = New-Object System.Collections.ArrayList
function _pass($m) { $script:Pass++; Write-Host "  [PASS] $m" -ForegroundColor Green }
function _fail($m) { $script:Fail++; [void]$script:Failures.Add($m); Write-Host "  [FAIL] $m" -ForegroundColor Red }
function Assert-True($c, $m) { if ($c) { _pass $m } else { _fail "$m (expected True)" } }
function Assert-Eq($e, $a, $m) { if ([string]$e -ceq [string]$a) { _pass $m } else { _fail "$m (expected '$e', got '$a')" } }
function Section($t) { Write-Host ''; Write-Host "== $t ==" -ForegroundColor Cyan }
function Test-Step { param([string]$Name, [scriptblock]$Body) try { & $Body } catch { _fail "$Name threw: $($_.Exception.Message)" } }

$MeSid = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
$Trusted = @($MeSid, 'S-1-5-18', 'S-1-5-32-544')   # the current user stands in for the operator (an Administrators member)
$TmpRoot = [IO.Path]::GetTempPath().TrimEnd('\')
$tempProblem = Get-SuiteTempProblem $TmpRoot
if ($tempProblem) { Write-Host "  [FAIL] refusing to start: $tempProblem" -ForegroundColor Red; exit 3 }
$script:RunToken = [guid]::NewGuid().ToString('N').Substring(0, 8)
$script:TmpRootCanon = Get-CanonicalPath $TmpRoot
$script:Cleanup = New-Object System.Collections.ArrayList
$script:LocksNotExercised = New-Object System.Collections.ArrayList   # tests that could not run here, so the lock they prove was not exercised
$script:CanaryStart = Get-AclCanary; Write-AclCanary 'suite-start' $script:CanaryStart
$script:IsElevated = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)

# ---- the fake system table ---------------------------------------------------------------------------------
function New-FakeState([string]$Folder) {
    $tasks = @{}
    foreach ($n in $script:RemovalAllowedTasks) {
        $on = $n -in @('NginxGatewayWatchdog', 'WslAgentBoot')
        $tasks[$n] = @{ Name = $n; Path = '\'; Enabled = $on; State = $(if ($on) { 'Ready' } else { 'Disabled' }); UserId = $(if ($n -eq 'WslAgentBoot') { 'op' } else { 'SYSTEM' }); ActionText = "powershell.exe -File $Folder\bin\$n.ps1" }
    }
    $rules = @(); $i = 0
    foreach ($n in $script:RemovalAllowedRules) { $i++; $rules += @{ Id = "{rule-$i}"; DisplayName = $n; Direction = 'Inbound'; Action = 'Allow'; Enabled = $true } }
    return @{
        Elevated = $true; Procs = 0; Listeners = @(); Others = @(); RealTakeown = $true
        Service = @{ Name = 'NginxGateway'; StartName = 'LocalSystem'; StartMode = 'Auto'; PathName = "$Folder\nginx.exe -p $Folder -c conf\nginx.conf"; State = 'Stopped' }
        Tasks = $tasks; Rules = $rules
        Calls = (New-Object System.Collections.ArrayList); Fail = @{}; NoEffect = @{}; Hooks = @{}
    }
}
function New-FakeSys($FakeState) {
    $sys = @{}
    $sys.IsElevated = { $FakeState.Elevated }.GetNewClosure()
    $sys.GetService = { param($n) if ($FakeState.Service -and $FakeState.Service.Name -eq $n) { $c = @{}; foreach ($k in $FakeState.Service.Keys) { $c[$k] = $FakeState.Service[$k] }; $c } else { $null } }.GetNewClosure()
    $sys.StopService = { param($n) [void]$FakeState.Calls.Add("StopService:$n"); if ($FakeState.Fail.StopService) { throw $FakeState.Fail.StopService }; if (-not $FakeState.NoEffect.StopService) { $FakeState.Service.State = 'Stopped' } }.GetNewClosure()
    $sys.DeleteService = { param($n) [void]$FakeState.Calls.Add("DeleteService:$n"); if ($FakeState.Fail.DeleteService) { throw $FakeState.Fail.DeleteService }; if (-not $FakeState.NoEffect.DeleteService) { $FakeState.Service = $null } }.GetNewClosure()
    $sys.ServiceGone = { param($n) $null -eq $FakeState.Service }.GetNewClosure()
    $sys.GetTask = { param($n) if ($FakeState.Tasks.ContainsKey($n)) { $FakeState.Tasks[$n] } else { $null } }.GetNewClosure()
    $sys.UnregisterTask = { param($n) [void]$FakeState.Calls.Add("UnregisterTask:$n"); if ($FakeState.Fail.UnregisterTask -and $FakeState.Fail.UnregisterTask -eq $n) { throw "cannot unregister $n" }; if (-not $FakeState.NoEffect.UnregisterTask) { $FakeState.Tasks.Remove($n) }; if ($FakeState.Hooks.UnregisterTask) { & $FakeState.Hooks.UnregisterTask $n } }.GetNewClosure()
    $sys.GetRules = { param($n) @($FakeState.Rules | Where-Object { $_.DisplayName -eq $n }) }.GetNewClosure()
    $sys.RemoveRule = { param($id) [void]$FakeState.Calls.Add("RemoveRule:$id"); if (-not $FakeState.NoEffect.RemoveRule) { $FakeState.Rules = @($FakeState.Rules | Where-Object { $_.Id -ne $id }) }; if ($FakeState.Hooks.RemoveRule) { & $FakeState.Hooks.RemoveRule $id } }.GetNewClosure()
    $sys.CountProcesses = { param($n) $FakeState.Procs }.GetNewClosure()
    $sys.GetListeners = { param($ports) @($FakeState.Listeners | Where-Object { $ports -contains $_ }) }.GetNewClosure()
    $sys.FindOtherReferences = { param($needle, $svcs, $tasks) @($FakeState.Others) }.GetNewClosure()
    $sys.TakeOwnership = { param($p) [void]$FakeState.Calls.Add("TakeOwnership:$p"); if ($FakeState.Hooks.TakeOwnership) { & $FakeState.Hooks.TakeOwnership $p }; if ($FakeState.Fail.TakeOwnership -and $p -like "*$($FakeState.Fail.TakeOwnership)") { throw "takeown failed for $p" }; if ($FakeState.RealTakeown) { Assert-Throwaway $p 'Invoke-RemovalTakeown'; Invoke-RemovalTakeown -Path $p } }.GetNewClosure()
    $sys.Sleep = { param($ms) }
    return $sys
}
function Get-MutatingCalls($FakeState) { @($FakeState.Calls | Where-Object { $_ -notlike 'Get*' }) }

# ---- the temp tree ------------------------------------------------------------------------------------------
function New-TestEnv {
    $id = New-SuiteId
    $env1 = @{ Id = $id; Folder = "$TmpRoot\nginx-removal-test-$id"; Q = "$TmpRoot\nginx-removal-test-q-$id"; Aux = "$TmpRoot\removal-aux-$id"; Outside = "$TmpRoot\removal-outside-$id" }
    foreach ($d in @($env1.Folder, "$($env1.Folder)\conf\conf.d", "$($env1.Folder)\certs\sub", "$($env1.Folder)\bin", "$($env1.Folder)\logs", $env1.Aux, $env1.Outside)) { New-Item -ItemType Directory -Force $d | Out-Null }
    Set-Content -LiteralPath "$($env1.Folder)\nginx.exe" 'MZ-fake'
    Set-Content -LiteralPath "$($env1.Folder)\conf\nginx.conf" 'worker_processes 1;'
    Set-Content -LiteralPath "$($env1.Folder)\conf\conf.d\a.conf" 'server {}'
    Set-Content -LiteralPath "$($env1.Folder)\certs\a.key" 'TOPSECRET-KEY-MATERIAL-A'
    Set-Content -LiteralPath "$($env1.Folder)\certs\sub\b.key" 'TOPSECRET-KEY-MATERIAL-B'
    Set-Content -LiteralPath "$($env1.Folder)\certs\c.pem" 'TOPSECRET-PEM'
    Set-Content -LiteralPath "$($env1.Folder)\bin\run.ps1" 'Write-Host hi'
    Set-Content -LiteralPath "$($env1.Folder)\logs\error.log" 'log'
    # explicit entries for broad groups (as the real folder has): the lock must REMOVE them, not just stop inheriting
    & icacls $env1.Folder /grant '*S-1-5-11:(OI)(CI)R' | Out-Null
    & icacls "$($env1.Folder)\certs\a.key" /grant '*S-1-5-32-545:R' | Out-Null
    $env1.Plan = @{ Folder = $env1.Folder; ServiceImagePrefix = "$($env1.Folder)\nginx.exe"; QuarantineRoot = $env1.Q; ConfBackupDir = "$($env1.Aux)\conf-backup"; LogDir = $env1.Aux }
    foreach ($c in @($env1.Folder, $env1.Q, $env1.Aux, $env1.Outside)) { [void]$script:Cleanup.Add($c) }
    return $env1
}
function Get-TreeSnapshot([string]$Root) {
    if (-not (Test-Path -LiteralPath $Root)) { return 'ABSENT' }
    $rows = Get-ChildItem -LiteralPath $Root -Recurse -Force -ErrorAction SilentlyContinue | Sort-Object FullName | ForEach-Object {
        $rel = $_.FullName.Substring($Root.Length)
        $sd = try { (Get-Acl -LiteralPath $_.FullName).Sddl } catch { 'unreadable' }
        "$rel|$($_.Length)|$($_.Attributes)|$sd"
    }
    $rootSd = try { (Get-Acl -LiteralPath $Root).Sddl } catch { 'unreadable' }
    return "$rootSd|$([IO.File]::GetAttributes($Root))`n" + ($rows -join "`n")
}
function Invoke-Run($TestEnv, $FakeState, [switch]$Execute, [switch]$DeleteQuarantine, [switch]$QuarantineOnAbsentDrive, [string[]]$Scope = @('Service', 'Tasks', 'FirewallRules', 'Folder')) {
    # -QuarantineOnAbsentDrive: the quarantine root may name a drive that does not exist on this machine (the cross-volume refusal case); nothing can be created there
    foreach ($pp in $TestEnv.Plan.Folder, $TestEnv.Plan.ConfBackupDir, $TestEnv.Plan.LogDir) { Assert-Throwaway $pp 'Invoke-NginxRemoval' }
    if ($QuarantineOnAbsentDrive) {
        if (Test-Path -LiteralPath ([IO.Path]::GetPathRoot($TestEnv.Plan.QuarantineRoot))) { _fail "SAFETY: the 'absent drive' $($TestEnv.Plan.QuarantineRoot) is present on this machine; Invoke-NginxRemoval was NOT run"; throw 'absent-drive quarantine is present' }
    } else { Assert-Throwaway $TestEnv.Plan.QuarantineRoot 'Invoke-NginxRemoval' }
    $lines = New-Object System.Collections.ArrayList
    $sys = New-FakeSys $FakeState
    $r = Invoke-NginxRemoval -Execute:$Execute -DeleteQuarantine:$DeleteQuarantine -Scope $Scope -Plan $TestEnv.Plan -Sys $sys -TrustedSids $Trusted -Out { param($l) [void]$lines.Add([string]$l) }.GetNewClosure()
    $r.Lines = @($lines)
    return $r
}
function New-SuiteId {
    # issued for every fixture; refuses once the temp root is no longer the folder it was at start (swapped for a link)
    $c = Get-CanonicalPath $TmpRoot
    if ($c -cne $script:TmpRootCanon -or (Get-ReparseComponent $TmpRoot)) { Write-SafetyFail "SAFETY: the temp folder '$TmpRoot' is no longer what it was at start; no further fixture is created"; throw "the temp folder changed after start" }
    return ($script:RunToken + [guid]::NewGuid().ToString('N').Substring(0, 4))
}
function Test-ThrowawayPath([string]$Path) {
    # true only for a path whose FINAL (link-resolved) form is strictly below this suite's temp root, whose first
    # component there carries this run's token (so a folder the suite did not make is refused even inside temp), and
    # that overlaps no protected root
    if ([string]::IsNullOrWhiteSpace($Path)) { return $false }
    $canon = Get-CanonicalPath $Path
    if ($null -eq $canon) { return $false }
    if (Test-ProtectedOverlap $Path) { return $false }
    $root = $script:TmpRootCanon.TrimEnd('\') + '\'
    if ($canon.Length -le $root.Length) { return $false }
    if (-not $canon.StartsWith($root, [StringComparison]::OrdinalIgnoreCase)) { return $false }
    return $canon.Substring($root.Length).Split('\')[0].Contains($script:RunToken)
}
function Assert-Throwaway([string]$Path, [string]$What) {
    # fails the suite and stops the caller before a destructive helper can be pointed outside the throwaway tree
    if (-not (Test-ThrowawayPath $Path)) { Write-SafetyFail "SAFETY: $What was aimed at '$Path', which is not a throwaway folder of this run; it was NOT run"; throw "unsafe target '$Path' for $What" }
}
function Test-CleanupPathSafe([string]$Path) {
    # the cleanup's own check, independent of Test-ThrowawayPath: finally resolved, strictly inside the temp root, no protected overlap
    $canon = Get-CanonicalPath $Path
    if ($null -eq $canon) { return $false }
    if (Test-ProtectedOverlap $Path) { return $false }
    $root = $script:TmpRootCanon.TrimEnd('\') + '\'
    return ($canon.Length -gt $root.Length -and $canon.StartsWith($root, [StringComparison]::OrdinalIgnoreCase))
}
function Invoke-SuiteLock {
    param([Parameter(Mandatory)][string]$Path, [string[]]$TrustedSids, [Parameter(Mandatory)][scriptblock]$TakeOwnership)
    Assert-Throwaway $Path 'Lock-RemovalFolderTree'
    Lock-RemovalFolderTree @PSBoundParameters
}
function Invoke-SuiteInitQuarantine {
    param([Parameter(Mandatory)][string]$Root, [string[]]$TrustedSids)
    Assert-Throwaway $Root 'Initialize-RemovalQuarantineRoot'
    Initialize-RemovalQuarantineRoot @PSBoundParameters
}
function Invoke-SuiteRemoveTree {
    param([Parameter(Mandatory)][string]$Path)
    Assert-Throwaway $Path 'Remove-RemovalTree'
    Remove-RemovalTree -Path $Path
}
function Remove-AllCleanup {
    # deletes only what Test-CleanupPathSafe allows (a link as a link, a folder after clearing its read-only attributes,
    # links never entered); anything left behind is reported
    param([object[]]$Paths = $script:Cleanup)
    foreach ($c in $Paths) {
        if (-not (Test-Path -LiteralPath $c)) { continue }
        if (-not (Test-CleanupPathSafe $c)) { Write-SafetyFail "SAFETY: cleanup refused to delete '$c'; it was NOT deleted"; continue }
        if (-not (Remove-SuiteTree -Path $c)) { Write-SafetyFail "cleanup left '$c' behind" }
    }
}
try {
Section 'the compiled-in allowlists and constants'
Test-Step 'constants' {
    Assert-Eq 'NginxGateway' ($script:RemovalAllowedService -join ',') 'the service allowlist is exactly NginxGateway'
    Assert-Eq 'NginxGatewayWatchdog,WslAgentBoot,NginxGateway,nginx-background,NginxAtBoot,NginxReload,NginxReloadNow,NginxReopenLogsNow,NginxQuitNow,NginxLogRotateWeekly,GatewayNginxMonthlyBackup,GatewayNginxPruneMonthly' ($script:RemovalAllowedTasks -join ',') 'the task allowlist is exactly the twelve named tasks'
    Assert-Eq 'nginx.exe HTTPS (App)|nginx HTTPS 443 (Port)|TEMP-Allow-HTTPS' ($script:RemovalAllowedRules -join '|') 'the firewall-rule allowlist is exactly the three named rules'
    Assert-True (@($script:RemovalAllowedService + $script:RemovalAllowedTasks + $script:RemovalAllowedRules | Where-Object { $_ -match '[\*\?\[\]]' }).Count -eq 0) 'no allowlisted name contains a wildcard character'
    Assert-Eq 'S-1-5-18,S-1-5-32-544' ($script:RemovalTrustedSids -join ',') 'the production lock keeps only SYSTEM and Administrators'
    Assert-Eq 'C:\nginx' $script:RemovalAllowedFolder 'the only folder the production run may act on is C:\nginx'
    Assert-Eq '443,8081' ($script:RemovalPorts -join ',') 'the refuse-while-listening ports are 443 and 8081'
    Assert-Eq 'C:\ProgramData\nginx-quarantine' $script:RemovalProduction.QuarantineRoot 'the production quarantine is C:\ProgramData\nginx-quarantine'
}

Section 'the gates: names, folder, quarantine'
Test-Step 'gates' {
    foreach ($n in $script:RemovalAllowedTasks) { try { Assert-RemovalAllowed -Kind task -Name $n; $ok = $true } catch { $ok = $false }; if (-not $ok) { _fail "allowlisted task '$n' was refused" } }
    _pass 'every allowlisted task name passes the gate'
    foreach ($bad in 'Evil', 'W32Time', 'Nginx*', '*', 'NginxGatewayX', 'NginxGatewayWatchdog2', 'nginxgateway', 'nginxreload', '', 'NginxReloadNow ') {
        $threw = $false; try { Assert-RemovalAllowed -Kind task -Name $bad } catch { $threw = $true }
        Assert-True $threw "a task named '$bad' (outside the list) is REFUSED by the gate"
    }
    foreach ($bad in 'W32Time', 'NginxGateway*', 'NginxGatewayX', 'nginxgateway', 'Spooler') {
        $threw = $false; try { Assert-RemovalAllowed -Kind service -Name $bad } catch { $threw = $true }
        Assert-True $threw "a service named '$bad' is REFUSED by the gate"
    }
    foreach ($bad in 'Core Networking - DNS (UDP-Out)', 'nginx*', 'nginx.exe HTTPS (App) copy') {
        $threw = $false; try { Assert-RemovalAllowed -Kind rule -Name $bad } catch { $threw = $true }
        Assert-True $threw "a firewall rule named '$bad' is REFUSED by the gate"
    }
    $threw = $false; try { Assert-RemovalAllowed -Kind service -Name 'NginxGatewayWatchdog' } catch { $threw = $true }
    Assert-True $threw 'a name from the TASK list is refused as a SERVICE (the lists do not mix)'
    foreach ($bad in 'C:\Windows', 'C:\Windows\Temp', 'C:\', 'C:\nginx\..\Windows', 'C:\ngin*', 'nginx', 'C:\Users\mrbla', 'C:\nginx2', 'C:\nginx\bin', "$TmpRoot\other-folder", "$TmpRoot\nginx-removal-test-x\sub") {
        $threw = $false; try { Assert-RemovalFolderAllowed -Path $bad } catch { $threw = $true }
        Assert-True $threw "the folder gate REFUSES '$bad'"
    }
    $ok = $true; try { Assert-RemovalFolderAllowed -Path 'C:\nginx'; Assert-RemovalFolderAllowed -Path 'c:\NGINX\'; Assert-RemovalFolderAllowed -Path "$TmpRoot\nginx-removal-test-abc" } catch { $ok = $false }
    Assert-True $ok 'the folder gate accepts C:\nginx (any case, trailing slash) and a test folder under temp'
    foreach ($bad in 'C:\', 'C:\ProgramData', 'C:\nginx', 'C:\ProgramData\nginx-quarantine\nginx', "$TmpRoot\x") {
        $threw = $false; try { Assert-RemovalQuarantineAllowed -Root $bad } catch { $threw = $true }
        Assert-True $threw "the quarantine gate REFUSES '$bad'"
    }
    $ok = $true; try { Assert-RemovalQuarantineAllowed -Root 'C:\ProgramData\nginx-quarantine'; Assert-RemovalQuarantineAllowed -Root "$TmpRoot\nginx-removal-test-q-1" } catch { $ok = $false }
    Assert-True $ok 'the quarantine gate accepts the production root and a test root'
    # the refusal is proven on a REAL throwaway folder under temp whose name the gate refuses, never on a system folder
    $rfId = New-SuiteId
    $rf = "$TmpRoot\zz-refused-lock-$rfId"
    Assert-Throwaway $rf 'the lock refusal test'
    New-Item -ItemType Directory -Force "$rf\sub" | Out-Null; Set-Content -LiteralPath "$rf\sub\f.txt" 'x'; [void]$script:Cleanup.Add($rf)
    $gateThrew = $false; try { Assert-RemovalFolderAllowed -Path $rf } catch { $gateThrew = $true }
    Assert-True $gateThrew 'the throwaway folder is one the gate refuses (the test below is not vacuous)'
    $snapRf = Get-TreeSnapshot $rf
    $threw = $false; try { Invoke-SuiteLock -Path $rf -TrustedSids $Trusted -TakeOwnership { param($p) } | Out-Null } catch { $threw = $true }
    Assert-True $threw 'Lock-RemovalFolderTree itself refuses a folder outside the gate (it is checked again at the point of action)'
    Assert-True ($snapRf -ceq (Get-TreeSnapshot $rf)) 'and the refused folder is left exactly as it was (names, sizes, access lists)'
}

Section 'DRY RUN: prints the exact listing and changes nothing'
Test-Step 'dryrun' {
    $te = New-TestEnv; $fs = New-FakeState $te.Folder
    $junction = "$($te.Folder)\conf\linked"
    New-Item -ItemType Junction -Path $junction -Target $te.Outside | Out-Null
    Set-Content -LiteralPath "$($te.Outside)\keep.txt" 'outside'
    $before = Get-TreeSnapshot $te.Folder; $outBefore = Get-TreeSnapshot $te.Outside
    $r = Invoke-Run $te $fs
    $txt = $r.Lines -join "`n"
    Assert-Eq 0 $r.ExitCode 'dry run: exit 0 when the preconditions hold (the shell need not be elevated)'
    Assert-Eq 'dry-run' $r.Mode 'the default mode is dry-run'
    Assert-True ($txt -match 'DRY RUN') 'it announces that it is a dry run'
    Assert-True ((Get-MutatingCalls $fs).Count -eq 0) "dry run: ZERO mutating calls on the system (service, tasks, rules, ownership): $((Get-MutatingCalls $fs) -join ',')"
    Assert-True ($before -ceq (Get-TreeSnapshot $te.Folder)) 'dry run: the folder tree (names, sizes, access lists) is byte-for-byte unchanged'
    Assert-True ($outBefore -ceq (Get-TreeSnapshot $te.Outside)) 'dry run: the folder a junction points to is unchanged'
    Assert-True (-not (Test-Path -LiteralPath $te.Q) -and -not (Test-Path -LiteralPath "$($te.Aux)\conf-backup") -and @(Get-ChildItem -LiteralPath $te.Aux -Force).Count -eq 0) 'dry run: no quarantine, no conf copy and no log file was created'
    Assert-True ($r.LogPath -eq '') 'dry run: no log path'
    Assert-True ($txt -match 'NginxGateway : present') 'the listing names the service'
    foreach ($n in $script:RemovalAllowedTasks) { Assert-True ($txt -match [regex]::Escape($n)) "the listing names task $n" }
    foreach ($n in $script:RemovalAllowedRules) { Assert-True ($txt -match [regex]::Escape($n)) "the listing names firewall rule '$n'" }
    Assert-True ($txt -match 'ENABLED') 'the listing marks enabled tasks'
    Assert-True ($txt -match '7 files in 8 folders' -or $txt -match '\d+ files in \d+ folders') 'the listing gives the folder file and folder counts'
    Assert-True ($txt -match 'private-key file NAMES .*: 2') 'the listing counts the key-file NAMES (2 in the test tree)'
    Assert-True ($txt -match 'certs\\a\.key' -and $txt -match 'certs\\sub\\b\.key') 'the listing prints key file names'
    Assert-True ($txt -notmatch 'TOPSECRET') 'the listing NEVER prints key material'
    Assert-True ($txt -match '\.pem files \(may hold keys\): 1') 'the listing counts .pem files separately'
    Assert-True ($txt -match 'links inside.*: 1' -and $txt -match [regex]::Escape($junction)) 'the listing names the link and says it is not entered'
    Assert-True ($txt -match 'quarantine' -and $txt -match 'KEPT') 'the listing says the folder is moved to the quarantine and the copy is KEPT by default'
    Assert-True ($txt -match 'DECISIONS FOR THE LA') 'the listing names the decisions the LA owns'
    $d = Invoke-Run $te $fs -DeleteQuarantine
    Assert-True (($d.Lines -join "`n") -match 'PERMANENTLY DELETE') 'with -DeleteQuarantine the dry run says it would delete permanently'
    Assert-True ((Get-MutatingCalls $fs).Count -eq 0) 'that dry run changed nothing either'
    $fs2 = New-FakeState $te.Folder; $fs2.Elevated = $false
    Assert-Eq 0 (Invoke-Run $te $fs2).ExitCode 'a non-elevated dry run is fine (exit 0)'
    $fs3 = New-FakeState $te.Folder; $fs3.Listeners = @(443)
    $w = Invoke-Run $te $fs3
    Assert-True ($w.ExitCode -eq 2 -and ($w.Lines -join "`n") -match 'WOULD REFUSE') 'a dry run that would be refused says so (exit 2) and still changes nothing'
    Assert-True ((Get-MutatingCalls $fs3).Count -eq 0) 'the would-refuse dry run made no mutating calls'
}

Section '-Execute refusals: every one exits 2 with NOTHING changed'
Test-Step 'refusals' {
    $cases = [ordered]@{
        'not elevated'                        = { param($s, $te) $s.Elevated = $false }
        'an nginx process is running'          = { param($s, $te) $s.Procs = 1 }
        'something listens on 443'             = { param($s, $te) $s.Listeners = @(443) }
        'something listens on 8081'             = { param($s, $te) $s.Listeners = @(8081) }
        'the service image path is not ours'    = { param($s, $te) $s.Service.PathName = 'C:\Windows\System32\svchost.exe -k x' }
        'a task does not mention nginx'         = { param($s, $te) $s.Tasks['NginxReload'].ActionText = 'cmd.exe /c del C:\important' }
        'a firewall rule is outbound/block'     = { param($s, $te) $s.Rules[0].Direction = 'Outbound' }
        'an enabled non-allowlisted task points into the folder' = { param($s, $te) $s.Others = @(@{ Kind = 'task'; Name = '\Other'; Enabled = $true; Text = "$($te.Folder)\x.exe" }) }
        'an enabled non-allowlisted service points into the folder' = { param($s, $te) $s.Others = @(@{ Kind = 'service'; Name = 'OtherSvc'; Enabled = $true; Text = "$($te.Folder)\x.exe" }) }
    }
    foreach ($k in $cases.Keys) {
        $te = New-TestEnv; $fs = New-FakeState $te.Folder; & $cases[$k] $fs $te
        $snap = Get-TreeSnapshot $te.Folder
        $r = Invoke-Run $te $fs -Execute
        Assert-True ($r.ExitCode -eq 2 -and $r.Refusals.Count -ge 1) "refused (exit 2): $k"
        Assert-True ((Get-MutatingCalls $fs).Count -eq 0 -and $snap -ceq (Get-TreeSnapshot $te.Folder) -and -not (Test-Path -LiteralPath $te.Q) -and @(Get-ChildItem -LiteralPath $te.Aux -Force).Count -eq 0) "nothing changed (no calls, tree identical, no quarantine, no log, no conf copy): $k"
    }
    $te = New-TestEnv; $fs = New-FakeState $te.Folder
    $r = Invoke-Run $te $fs -Execute -Scope Folder
    Assert-True ($r.ExitCode -eq 2 -and ($r.Refusals -join ' ') -match 'service') 'the folder alone is refused while the service still exists (any user could re-create it)'
    $r = Invoke-Run $te $fs -Execute -Scope Service, Folder
    Assert-True ($r.ExitCode -eq 2 -and ($r.Refusals -join ' ') -match 'task') 'the folder plus the service is refused while allowlisted tasks still exist'
    Assert-True ((Get-MutatingCalls $fs).Count -eq 0) 'those refusals changed nothing'
    $r = Invoke-Run $te $fs -Execute -DeleteQuarantine -Scope Service
    Assert-True ($r.ExitCode -eq 2) '-DeleteQuarantine without -Scope Folder is refused'
    Assert-Throwaway $te.Plan.Folder 'Invoke-NginxRemoval'
    $threw = $false; try { Invoke-NginxRemoval -Scope Bogus -Plan $te.Plan -Sys (New-FakeSys $fs) -Out { param($l) } | Out-Null } catch { $threw = $true }
    Assert-True $threw 'an unknown -Scope value throws'
    $te2 = New-TestEnv; $fs2 = New-FakeState $te2.Folder; $te2.Plan.LogDir = "$($te2.Aux)\no-such-dir"
    $r = Invoke-Run $te2 $fs2 -Execute
    Assert-True ($r.ExitCode -eq 2 -and (Get-MutatingCalls $fs2).Count -eq 0) 'an unwritable log folder refuses BEFORE any change'
    $te3 = New-TestEnv; $fs3 = New-FakeState $te3.Folder; Remove-Item -LiteralPath "$($te3.Folder)\conf\nginx.conf"
    $r = Invoke-Run $te3 $fs3 -Execute
    Assert-True ($r.ExitCode -eq 2 -and ($r.Refusals -join ' ') -match 'nginx.conf') 'no nginx.conf to copy and no existing copy: refused'
}

Section '-Execute happy path: lock, remove, quarantine, verify, log'
Test-Step 'happy' {
    $te = New-TestEnv; $fs = New-FakeState $te.Folder
    $junction = "$($te.Folder)\conf\linked"
    New-Item -ItemType Junction -Path $junction -Target $te.Outside | Out-Null
    Set-Content -LiteralPath "$($te.Outside)\keep.txt" 'outside'
    $outBefore = Get-TreeSnapshot $te.Outside
    $hashBefore = @{}; Get-ChildItem -LiteralPath $te.Folder -Recurse -File -Force | Where-Object { $_.Attributes -notmatch 'ReparsePoint' } | ForEach-Object { $hashBefore[$_.FullName.Substring($te.Folder.Length)] = (Get-FileHash -LiteralPath $_.FullName).Hash }
    $nObjects = @(Get-ChildItem -LiteralPath $te.Folder -Recurse -Force | Where-Object { $_.FullName -ne $junction }).Count + 1
    $r = Invoke-Run $te $fs -Execute
    Assert-Eq 0 $r.ExitCode "execute: exit 0 ($($r.Refusals -join '; '))"
    Assert-True ($null -eq $fs.Service) 'the service is gone'
    Assert-True ($fs.Tasks.Count -eq 0) 'all twelve tasks are gone'
    Assert-True (@($fs.Rules).Count -eq 0) 'all three firewall rules are gone'
    Assert-True (-not (Test-Path -LiteralPath $te.Folder)) 'the folder is gone from its place'
    $dest = "$($te.Q)\$([IO.Path]::GetFileName($te.Folder))"
    Assert-True (Test-Path -LiteralPath $dest) 'the folder is in the quarantine (default: KEPT)'
    $hashAfter = @{}; Get-ChildItem -LiteralPath $dest -Recurse -File -Force | Where-Object { $_.Attributes -notmatch 'ReparsePoint' } | ForEach-Object { $hashAfter[$_.FullName.Substring($dest.Length)] = (Get-FileHash -LiteralPath $_.FullName).Hash }
    Assert-True ($hashBefore.Count -gt 0 -and $hashBefore.Count -eq $hashAfter.Count -and @($hashBefore.Keys | Where-Object { $hashBefore[$_] -ne $hashAfter[$_] }).Count -eq 0) "every file arrived intact ($($hashBefore.Count) files, same SHA-256)"
    Assert-True ($outBefore -ceq (Get-TreeSnapshot $te.Outside)) 'the folder a JUNCTION pointed to was neither entered nor changed (names, sizes, access lists)'
    Assert-True (Test-Path -LiteralPath "$dest\conf\linked") 'the junction itself moved with the folder, not followed'
    # the quarantine is admin-only: real access lists
    $chk = Test-RemovalFolderLockedShallow -Path $te.Q -TrustedSids $Trusted
    Assert-True $chk.Ok "the quarantine ROOT is admin-only: protected, trusted owner, trusted entries only ($($chk.Why))"
    $deep = Test-RemovalFolderLocked -Path $dest -TrustedSids $Trusted
    Assert-True ($deep.Ok -and $deep.Visited -ge $nObjects - 1) "every object in the quarantined copy is owned by and open only to the trusted accounts ($($deep.Visited) objects, $(@($deep.Violations).Count) violations)"
    $bad = @('S-1-5-11', 'S-1-5-32-545', 'S-1-1-0')
    $anyBroad = $false
    foreach ($p in @($te.Q, $dest, "$dest\certs\a.key", "$dest\certs\sub\b.key", "$dest\nginx.exe")) {
        $acl = Get-Acl -LiteralPath $p
        foreach ($rule in $acl.GetAccessRules($true, $true, [Security.Principal.SecurityIdentifier])) { if ($bad -contains $rule.IdentityReference.Value) { $anyBroad = $true } }
    }
    Assert-True (-not $anyBroad) 'read directly: no Authenticated Users / Users / Everyone entry on the quarantine root, the folder, the key files or the exe'
    # the verifier can fail (toggle): open one deep file up and the check must see it
    $keyFile = "$dest\certs\a.key"
    $acl = Get-Acl -LiteralPath $keyFile; $acl.AddAccessRule((New-Object Security.AccessControl.FileSystemAccessRule(([Security.Principal.SecurityIdentifier]'S-1-5-11'), 'Read', 'Allow'))); Set-Acl -LiteralPath $keyFile -AclObject $acl
    $tog = Test-RemovalFolderLocked -Path $dest -TrustedSids $Trusted
    Assert-True ((-not $tog.Ok) -and (@($tog.Violations | Where-Object { $_ -match 'S-1-5-11' }).Count -ge 1)) 'toggle: giving Authenticated Users read on one key file makes the lock check FAIL (the verifier can see it)'
    # conf copy
    $conf = "$($te.Plan.ConfBackupDir)\nginx.conf"
    Assert-True ((Test-Path -LiteralPath $conf) -and (Get-FileHash -LiteralPath $conf).Hash -eq $hashBefore['\conf\nginx.conf']) 'nginx.conf was copied before anything changed and matches the original'
    # the log
    Assert-True ($r.LogPath -and (Test-Path -LiteralPath $r.LogPath)) 'a log file was written'
    $log = Get-Content -LiteralPath $r.LogPath -Raw
    foreach ($needle in 'copy nginx.conf', 'take ownership', 'delete service NginxGateway', 'unregister scheduled task NginxGatewayWatchdog', 'unregister scheduled task WslAgentBoot', "remove firewall rule 'TEMP-Allow-HTTPS'", 'move ', 'DONE') {
        Assert-True ($log -match [regex]::Escape($needle)) "the log records: $needle"
    }
    Assert-True ($log -notmatch 'TOPSECRET') 'the log holds no key material'
    $okSteps = @($r.Steps | Where-Object { $_.Status -eq 'done' }).Count
    Assert-True ($okSteps -eq $r.Steps.Count -and $okSteps -ge 17) "every step reports done and each was verified ($okSteps steps)"
    $order = @($fs.Calls | ForEach-Object { $_ })
    $firstOwn = $order.IndexOf(($order | Where-Object { $_ -like 'TakeOwnership:*' } | Select-Object -First 1)); $delSvc = $order.IndexOf('DeleteService:NginxGateway')
    Assert-True ($firstOwn -ge 0 -and $delSvc -gt $firstOwn) 'ORDER: the folder is locked (ownership taken) BEFORE the service is deleted'
    $ownCount = @($order | Where-Object { $_ -like 'TakeOwnership:*' }).Count
    Assert-True ($ownCount -ge $nObjects - 1) "ownership was taken on every object, one call each ($ownCount calls for $nObjects objects)"
    Assert-True (-not (@($order | Where-Object { $_ -like 'StopService*' }).Count)) 'a service that is already Stopped is not stopped again'
}

Section '-DeleteQuarantine: permanent deletion only when asked'
Test-Step 'delete' {
    $te = New-TestEnv; $fs = New-FakeState $te.Folder
    $r = Invoke-Run $te $fs -Execute -DeleteQuarantine
    $dest = "$($te.Q)\$([IO.Path]::GetFileName($te.Folder))"
    Assert-Eq 0 $r.ExitCode 'execute with -DeleteQuarantine: exit 0'
    Assert-True (-not (Test-Path -LiteralPath $dest) -and -not (Test-Path -LiteralPath $te.Folder)) 'the quarantined copy and the original place are both gone'
    Assert-True (Test-Path -LiteralPath "$($te.Plan.ConfBackupDir)\nginx.conf") 'the nginx.conf copy survives the deletion'
    Assert-True ((Get-Content -LiteralPath $r.LogPath -Raw) -match 'PERMANENTLY DELETE') 'the permanent deletion is logged'
    # the default keeps it (asserted in the happy path); here the toggle: no flag, no deletion
    $te2 = New-TestEnv; $fs2 = New-FakeState $te2.Folder
    $null = Invoke-Run $te2 $fs2 -Execute
    Assert-True (Test-Path -LiteralPath "$($te2.Q)\$([IO.Path]::GetFileName($te2.Folder))") 'toggle: the same run WITHOUT -DeleteQuarantine keeps the copy'
    # marker guard
    $te3 = New-TestEnv; $fs3 = New-FakeState $te3.Folder
    $null = Invoke-Run $te3 $fs3 -Execute
    Remove-Item -LiteralPath "$($te3.Q)\.nginx-gateway-quarantine" -Force
    $fs3b = New-FakeState $te3.Folder; $fs3b.Service = $null; $fs3b.Tasks = @{}; $fs3b.Rules = @()
    $r3 = Invoke-Run $te3 $fs3b -Execute -DeleteQuarantine
    Assert-True ($r3.ExitCode -eq 3 -and (Test-Path -LiteralPath "$($te3.Q)\$([IO.Path]::GetFileName($te3.Folder))")) 'without the quarantine marker the delete refuses and the copy stays'
}

Section '-DeleteQuarantine and links: a link is removed as a link, its target is left alone'
Test-Step 'deletelinks' {
    $te = New-TestEnv; $fs = New-FakeState $te.Folder
    $victim = "$TmpRoot\removal-victim-$($te.Id)"; New-Item -ItemType Directory $victim | Out-Null; [void]$script:Cleanup.Add($victim)
    Set-Content -LiteralPath "$victim\precious.txt" 'precious'
    New-Item -ItemType Junction -Path "$($te.Folder)\bin\jlink" -Target $victim | Out-Null
    $symOk = $true; try { New-Item -ItemType SymbolicLink -Path "$($te.Folder)\bin\flink" -Target "$victim\precious.txt" -ErrorAction Stop | Out-Null } catch { $symOk = $false }
    New-Item -ItemType SymbolicLink -Path "$($te.Folder)\bin\dlink" -Target $victim -ErrorAction SilentlyContinue | Out-Null
    Set-ItemProperty -LiteralPath "$($te.Folder)\logs\error.log" -Name IsReadOnly -Value $true
    $snap = Get-TreeSnapshot $victim
    $r = Invoke-Run $te $fs -Execute -DeleteQuarantine
    $dest = "$($te.Q)\$([IO.Path]::GetFileName($te.Folder))"
    Assert-True ($r.ExitCode -eq 0 -and -not (Test-Path -LiteralPath $dest)) "the quarantined copy with a junction$(if ($symOk) { ', a file symlink' }) and a read-only file inside is deleted completely ($($r.Refusals -join '; '))"
    Assert-True ($snap -ceq (Get-TreeSnapshot $victim) -and (Get-Content -LiteralPath "$victim\precious.txt" -Raw).Trim() -eq 'precious') 'the junction target (and the file a symlink pointed to) is untouched: the link went, the target stayed'
}

Section '-DeleteQuarantine hardening: link roots, state re-proved at the delete, read-only entries'
Test-Step 'deleteharden' {
    $te = New-TestEnv
    $victim = "$TmpRoot\removal-victim2-$($te.Id)"; New-Item -ItemType Directory $victim | Out-Null; [void]$script:Cleanup.Add($victim)
    Set-Content -LiteralPath "$victim\precious.txt" 'precious'; Set-Content -LiteralPath "$victim\more.txt" 'more'
    $snap = Get-TreeSnapshot $victim
    # unit: a link given AS THE ROOT is refused and its target is never walked
    $jroot = "$TmpRoot\removal-jroot-$($te.Id)"
    New-Item -ItemType Junction -Path $jroot -Target $victim | Out-Null
    $threw = $false; try { Invoke-SuiteRemoveTree -Path $jroot } catch { $threw = $true }
    Assert-True ($threw -and $snap -ceq (Get-TreeSnapshot $victim)) 'Remove-RemovalTree REFUSES a junction as the root, and the target keeps every entry'
    [IO.Directory]::Delete($jroot)
    $sroot = "$TmpRoot\removal-sroot-$($te.Id)"; $symDir = $true
    try { New-Item -ItemType SymbolicLink -Path $sroot -Target $victim -ErrorAction Stop | Out-Null } catch { $symDir = $false }
    if ($symDir) {
        $threw = $false; try { Invoke-SuiteRemoveTree -Path $sroot } catch { $threw = $true }
        Assert-True ($threw -and $snap -ceq (Get-TreeSnapshot $victim)) 'Remove-RemovalTree REFUSES a folder symlink as the root, and the target keeps every entry'
        [IO.Directory]::Delete($sroot)
    }
    # unit: read-only folder, read-only junction, read-only file symlink inside the tree
    $tree = "$TmpRoot\removal-ro-$($te.Id)"; [void]$script:Cleanup.Add($tree)
    New-Item -ItemType Directory "$tree\rodir" | Out-Null
    Set-Content -LiteralPath "$tree\rodir\f.txt" 'x'
    New-Item -ItemType Junction -Path "$tree\rojunc" -Target $victim | Out-Null
    $fl = $true; try { New-Item -ItemType SymbolicLink -Path "$tree\rolink" -Target "$victim\precious.txt" -ErrorAction Stop | Out-Null } catch { $fl = $false }
    foreach ($n in 'rodir', 'rojunc', 'rolink') { $q = "$tree\$n"; if (Test-Path -LiteralPath $q) { [IO.File]::SetAttributes($q, [IO.File]::GetAttributes($q) -bor [IO.FileAttributes]::ReadOnly) } }
    $err = ''; try { Invoke-SuiteRemoveTree -Path $tree } catch { $err = $_.Exception.Message }
    Assert-True ($err -eq '' -and -not (Test-Path -LiteralPath $tree)) "a tree holding a read-only folder, a read-only junction$(if ($fl) { ' and a read-only file symlink' }) is deleted completely ($err)"
    Assert-True ($snap -ceq (Get-TreeSnapshot $victim)) 'and the targets of those links are untouched'

    $emptyState = { param($f) $s = New-FakeState $f; $s.Service = $null; $s.Tasks = @{}; $s.Rules = @(); $s }
    $leaf = { param($e) [IO.Path]::GetFileName($e.Folder) }
    # e2e: the folder is quarantined (no delete), then the state is spoiled in one way, then -DeleteQuarantine must refuse (exit 3, the copy stays)
    $te1 = New-TestEnv; $fs1 = New-FakeState $te1.Folder
    $null = Invoke-Run $te1 $fs1 -Execute
    $dest1 = "$($te1.Q)\$(& $leaf $te1)"
    $a = Get-Acl -LiteralPath $te1.Q; $a.AddAccessRule((New-Object Security.AccessControl.FileSystemAccessRule(([Security.Principal.SecurityIdentifier]'S-1-5-11'), 'ReadAndExecute', 'Allow'))); Set-Acl -LiteralPath $te1.Q -AclObject $a
    $r = Invoke-Run $te1 (& $emptyState $te1.Folder) -Execute -DeleteQuarantine -Scope Folder
    Assert-True ($r.ExitCode -eq 3 -and (Test-Path -LiteralPath $dest1) -and ($r.Refusals -join ' ') -match 'not admin-only') 'the quarantine ROOT re-opened to another account before the delete: refused (exit 3), the copy stays'
    $te2 = New-TestEnv; $fs2 = New-FakeState $te2.Folder
    $null = Invoke-Run $te2 $fs2 -Execute
    $dest2 = "$($te2.Q)\$(& $leaf $te2)"
    $k = "$dest2\certs\a.key"; $a = Get-Acl -LiteralPath $k; $a.AddAccessRule((New-Object Security.AccessControl.FileSystemAccessRule(([Security.Principal.SecurityIdentifier]'S-1-5-11'), 'Read', 'Allow'))); Set-Acl -LiteralPath $k -AclObject $a
    $r = Invoke-Run $te2 (& $emptyState $te2.Folder) -Execute -DeleteQuarantine -Scope Folder
    Assert-True ($r.ExitCode -eq 3 -and (Test-Path -LiteralPath $dest2) -and ($r.Refusals -join ' ') -match 'not fully locked') 'a key file in the copy re-opened before the delete: refused (exit 3), the copy stays'
    # e2e: the pre-planted shape: the folder is already gone; someone made the quarantine root (marker included) and a junction named like the folder, pointing at a victim
    foreach ($locked in $false, $true) {
        $te3 = New-TestEnv; $fs3 = New-FakeState $te3.Folder
        New-Item -ItemType Directory -Force $te3.Plan.ConfBackupDir | Out-Null
        Copy-Item -LiteralPath "$($te3.Folder)\conf\nginx.conf" "$($te3.Plan.ConfBackupDir)\nginx.conf"
        Remove-Item -LiteralPath $te3.Folder -Recurse -Force
        if ($locked) { $null = Invoke-SuiteInitQuarantine -Root $te3.Q -TrustedSids $Trusted } else { New-Item -ItemType Directory $te3.Q | Out-Null; Set-Content -LiteralPath "$($te3.Q)\.nginx-gateway-quarantine" 'planted' }
        $v3 = "$TmpRoot\removal-victim3-$($te3.Id)"; New-Item -ItemType Directory $v3 | Out-Null; [void]$script:Cleanup.Add($v3)
        Set-Content -LiteralPath "$v3\a.txt" 'a'; Set-Content -LiteralPath "$v3\b.txt" 'b'
        New-Item -ItemType Junction -Path "$($te3.Q)\$(& $leaf $te3)" -Target $v3 | Out-Null
        $before3 = Get-TreeSnapshot $v3
        $r = Invoke-Run $te3 (& $emptyState $te3.Folder) -Execute -DeleteQuarantine -Scope Folder
        Assert-True ($r.ExitCode -eq 3 -and $before3 -ceq (Get-TreeSnapshot $v3) -and (Test-Path -LiteralPath "$v3\a.txt")) "PRE-PLANTED quarantine root ($(if ($locked) { 'locked' } else { 'unlocked' })) with a junction in place of the copy: refused (exit 3), the junction's target keeps every entry"
    }
}

Section 'conf copy: never overwritten'
Test-Step 'conf' {
    $te = New-TestEnv; $fs = New-FakeState $te.Folder
    New-Item -ItemType Directory -Force $te.Plan.ConfBackupDir | Out-Null
    $existing = "$($te.Plan.ConfBackupDir)\nginx.conf"
    Set-Content -LiteralPath $existing 'OLD DIFFERENT COPY'
    $oldHash = (Get-FileHash -LiteralPath $existing).Hash
    $r = Invoke-Run $te $fs -Execute
    Assert-Eq 0 $r.ExitCode 'a differing existing copy does not stop the run'
    Assert-True ((Get-FileHash -LiteralPath $existing).Hash -eq $oldHash) 'the EXISTING copy is byte-for-byte untouched'
    $new = @(Get-ChildItem -LiteralPath $te.Plan.ConfBackupDir | Where-Object { $_.Name -like 'nginx.conf.*' })
    Assert-True ($new.Count -eq 1 -and (Get-Content -LiteralPath $new[0].FullName -Raw).Trim() -eq 'worker_processes 1;') 'the new copy got its own timestamped name and holds the current conf'
    $te2 = New-TestEnv; $fs2 = New-FakeState $te2.Folder
    New-Item -ItemType Directory -Force $te2.Plan.ConfBackupDir | Out-Null
    Copy-Item -LiteralPath "$($te2.Folder)\conf\nginx.conf" "$($te2.Plan.ConfBackupDir)\nginx.conf"
    $null = Invoke-Run $te2 $fs2 -Execute
    Assert-True (@(Get-ChildItem -LiteralPath $te2.Plan.ConfBackupDir).Count -eq 1) 'an identical existing copy is reused: no second file'
}

Section 'idempotent: a re-run after completion does nothing'
Test-Step 'idempotent' {
    $te = New-TestEnv; $fs = New-FakeState $te.Folder
    $null = Invoke-Run $te $fs -Execute
    $fs.Calls.Clear()
    $r = Invoke-Run $te $fs -Execute
    Assert-Eq 0 $r.ExitCode 're-run after completion: exit 0'
    Assert-True ((Get-MutatingCalls $fs).Count -eq 0) "re-run: ZERO mutating calls ($((Get-MutatingCalls $fs) -join ','))"
    Assert-True (@($r.Lines | Where-Object { $_ -match 'already done' }).Count -ge 15) 'every item reports already done'
    $d = Invoke-Run $te $fs
    Assert-True ($d.ExitCode -eq 0 -and ($d.Lines -join "`n") -match 'not present') 'a dry run afterwards reports everything as not present'
}

Section 'partial failure: stops, reports, and a re-run resumes'
Test-Step 'partial' {
    # a task cannot be unregistered: later items untouched, the folder still in place
    $te = New-TestEnv; $fs = New-FakeState $te.Folder; $fs.Fail.UnregisterTask = 'WslAgentBoot'
    $r = Invoke-Run $te $fs -Execute
    Assert-Eq 3 $r.ExitCode 'a failing step ends the run with exit 3'
    Assert-True (@($fs.Calls | Where-Object { $_ -like 'RemoveRule*' }).Count -eq 0) 'STOPS: no firewall rule was touched after the failing task'
    Assert-True ((Test-Path -LiteralPath $te.Folder) -and -not (Test-Path -LiteralPath $te.Q)) 'STOPS: the folder was not moved'
    Assert-True ($null -eq $fs.Service) 'the steps BEFORE the failure stand (the service is gone)'
    $afterTask = @($fs.Calls | Where-Object { $_ -like 'UnregisterTask:*' })
    Assert-True ($afterTask[-1] -eq 'UnregisterTask:WslAgentBoot') 'no task after the failing one was attempted'
    Assert-True ((Get-Content -LiteralPath $r.LogPath -Raw) -match 'FAIL') 'the failure is in the log'
    $fs.Fail.Clear(); $fs.Calls.Clear()
    $r2 = Invoke-Run $te $fs -Execute
    Assert-Eq 0 $r2.ExitCode 'RESUME: re-running after the cause is fixed completes'
    Assert-True (@($fs.Calls | Where-Object { $_ -like 'DeleteService*' }).Count -eq 0) 'RESUME: the finished service step is not repeated'
    Assert-True ($fs.Tasks.Count -eq 0 -and @($fs.Rules).Count -eq 0 -and -not (Test-Path -LiteralPath $te.Folder)) 'RESUME: everything is removed at the end'
    # postcondition failures: the action "succeeds" but the thing is still there
    foreach ($case in @(@{ N = 'DeleteService'; Msg = 'service' }, @{ N = 'UnregisterTask'; Msg = 'still registered' }, @{ N = 'RemoveRule'; Msg = 'still present' })) {
        $te2 = New-TestEnv; $fs2 = New-FakeState $te2.Folder; $fs2.NoEffect[$case.N] = $true
        $r3 = Invoke-Run $te2 $fs2 -Execute
        Assert-True ($r3.ExitCode -eq 3 -and ($r3.Refusals -join ' ') -match $case.Msg) "a $($case.N) that has no effect is caught by its postcondition (exit 3): $($r3.Refusals -join ' ')"
        Assert-True ((Test-Path -LiteralPath $te2.Folder) -and -not (Test-Path -LiteralPath $te2.Q)) "that failure stops before the move ($($case.N))"
    }
    # a service that will not stop
    $te4 = New-TestEnv; $fs4 = New-FakeState $te4.Folder; $fs4.Service.State = 'Running'; $fs4.NoEffect.StopService = $true
    $r4 = Invoke-Run $te4 $fs4 -Execute
    Assert-True ($r4.ExitCode -eq 3 -and ($r4.Refusals -join ' ') -match 'did not stop' -and @($fs4.Calls | Where-Object { $_ -like 'DeleteService*' }).Count -eq 0) 'a service that does not stop is never deleted (exit 3)'
    $te5 = New-TestEnv; $fs5 = New-FakeState $te5.Folder; $fs5.Service.State = 'Running'
    $r5 = Invoke-Run $te5 $fs5 -Execute
    Assert-True ($r5.ExitCode -eq 0 -and @($fs5.Calls | Where-Object { $_ -like 'StopService*' }).Count -eq 1) 'a running service is stopped first, then deleted'
    # the lock fails: the service is never touched
    $te6 = New-TestEnv; $fs6 = New-FakeState $te6.Folder; $fs6.Fail.TakeOwnership = 'a.key'
    $r6 = Invoke-Run $te6 $fs6 -Execute
    Assert-True ($r6.ExitCode -eq 3 -and $null -ne $fs6.Service -and $fs6.Tasks.Count -eq 12) 'a lock failure (takeown) stops the run BEFORE the service, tasks or rules are touched'
    Assert-True (Test-Path -LiteralPath $te6.Folder) 'and the folder stays where it was'
    # a pre-existing destination
    $te7 = New-TestEnv; $fs7 = New-FakeState $te7.Folder
    $null = Invoke-SuiteInitQuarantine -Root $te7.Q -TrustedSids $Trusted
    New-Item -ItemType Directory "$($te7.Q)\$([IO.Path]::GetFileName($te7.Folder))" | Out-Null
    $r7 = Invoke-Run $te7 $fs7 -Execute
    Assert-True ($r7.ExitCode -eq 2 -and (Test-Path -LiteralPath $te7.Folder) -and (Get-MutatingCalls $fs7).Count -eq 0) 'a quarantine destination that already exists while the folder is still in place is refused before any change'
}

Section 'the quarantine root: created admin-only, an existing one is verified'
Test-Step 'qroot' {
    $te = New-TestEnv
    $q = Invoke-SuiteInitQuarantine -Root $te.Q -TrustedSids $Trusted
    Assert-True ((Test-RemovalFolderLockedShallow -Path $q -TrustedSids $Trusted).Ok) 'a new quarantine root is created protected, with only the trusted entries'
    Assert-True ((Test-Path -LiteralPath "$q\.nginx-gateway-quarantine")) 'it carries the marker'
    $again = Invoke-SuiteInitQuarantine -Root $te.Q -TrustedSids $Trusted
    Assert-True ($again -eq $q) 'an existing, locked, marked root is accepted (idempotent)'
    $acl = Get-Acl -LiteralPath $q; $acl.AddAccessRule((New-Object Security.AccessControl.FileSystemAccessRule(([Security.Principal.SecurityIdentifier]'S-1-5-11'), 'ReadAndExecute', 'Allow'))); Set-Acl -LiteralPath $q -AclObject $acl
    $threw = $false; try { Invoke-SuiteInitQuarantine -Root $te.Q -TrustedSids $Trusted | Out-Null } catch { $threw = $true }
    Assert-True $threw 'toggle: an existing root that gained an Authenticated Users entry is REFUSED'
    # the PRODUCTION trusted set (SYSTEM + Administrators only, the operator is NOT in it): a root created by a
    # normal elevated user must still pass, so it has to be created owned by Administrators
    $teP = New-TestEnv
    $qp = Invoke-SuiteInitQuarantine -Root $teP.Q
    $own = (Get-AclSddlAndOwnerChecked -Path $qp -IsDir $true).Owner
    $ownM = (Get-AclSddlAndOwnerChecked -Path "$qp\.nginx-gateway-quarantine" -IsDir $false).Owner
    Assert-True ($own -eq 'S-1-5-32-544' -and $ownM -eq 'S-1-5-32-544') "with the production trusted set the new root and its marker are owned by Administrators (root $own, marker $ownM), not the current user"
    $te2 = New-TestEnv; New-Item -ItemType Directory $te2.Q | Out-Null
    $msg = ''; try { Invoke-SuiteInitQuarantine -Root $te2.Q -TrustedSids $Trusted | Out-Null } catch { $msg = $_.Exception.Message }
    Assert-True ($msg -match 'marker') "an existing folder without our marker is refused for that reason ($msg)"
}

Section 'each safeguard catches its failure on its own'
Test-Step 'layers' {
    # the quarantine on another volume
    $te = New-TestEnv; $fs = New-FakeState $te.Folder; $te.Plan.QuarantineRoot = 'Z:\nginx-removal-test-q-other'
    $r = Invoke-Run $te $fs -Execute -QuarantineOnAbsentDrive
    Assert-True ($r.ExitCode -eq 2 -and ($r.Refusals -join ' ') -match 'another volume' -and (Get-MutatingCalls $fs).Count -eq 0) 'a quarantine on another volume is refused before any change (a move must be a rename)'
    # access list reopened between the lock and the move: the move re-checks the lock itself
    $te = New-TestEnv; $fs = New-FakeState $te.Folder
    $key = "$($te.Folder)\certs\a.key"
    $fs.Hooks.UnregisterTask = { param($n) if ($n -eq 'NginxLogRotateWeekly') { $a = Get-Acl -LiteralPath $key; $a.AddAccessRule((New-Object Security.AccessControl.FileSystemAccessRule(([Security.Principal.SecurityIdentifier]'S-1-5-11'), 'Read', 'Allow'))); Set-Acl -LiteralPath $key -AclObject $a } }.GetNewClosure()
    $r = Invoke-Run $te $fs -Execute
    Assert-True ($r.ExitCode -eq 3 -and (Test-Path -LiteralPath $te.Folder) -and -not (Test-Path -LiteralPath "$($te.Q)\$([IO.Path]::GetFileName($te.Folder))")) 'a key file re-opened to Authenticated Users after the lock stops the run BEFORE the move (the folder stays, nothing is quarantined)'
    # tampering during the lock walk that the walk itself cannot see: the read-back verification catches it before the service is touched
    $te = New-TestEnv; $fs = New-FakeState $te.Folder
    $key2 = "$($te.Folder)\certs\a.key"
    $fs.Hooks.TakeOwnership = { param($p) if ($p -like '*\logs\error.log') { $a = Get-Acl -LiteralPath $key2; $a.AddAccessRule((New-Object Security.AccessControl.FileSystemAccessRule(([Security.Principal.SecurityIdentifier]'S-1-5-11'), 'Read', 'Allow'))); Set-Acl -LiteralPath $key2 -AclObject $a } }.GetNewClosure()
    $r = Invoke-Run $te $fs -Execute
    Assert-True ($r.ExitCode -eq 3 -and $null -ne $fs.Service -and ($r.Refusals -join ' ') -match 'verification failed') 'a lock that does not hold at the read-back stops the run BEFORE the service is deleted'
    # walk errors on their own (the tree is already locked, so the read-back alone would pass)
    $te = New-TestEnv; $fs = New-FakeState $te.Folder
    $null = Invoke-SuiteLock -Path $te.Folder -TrustedSids $Trusted -TakeOwnership { param($p) }
    $fs.Fail.TakeOwnership = 'a.key'
    $r = Invoke-Run $te $fs -Execute
    Assert-True ($r.ExitCode -eq 3 -and $null -ne $fs.Service -and ($r.Refusals -join ' ') -match 'lock walk had') 'an error during the lock walk stops the run even when the read-back would have passed'
    # the verifier, one clause at a time
    $te = New-TestEnv
    $broad = @($Trusted + 'S-1-5-11' + 'S-1-5-32-545')
    $v = Test-RemovalFolderLocked -Path $te.Folder -TrustedSids $broad
    Assert-True ((-not $v.Ok) -and @($v.Violations | Where-Object { $_ -match 'inherits' }).Count -ge 1) 'verifier: an object that still inherits from its parent is a violation'
    $v = Test-RemovalFolderLocked -Path $te.Folder -TrustedSids @('S-1-5-18')
    Assert-True (@($v.Violations | Where-Object { $_ -match 'owner is' }).Count -ge 1) 'verifier: an owner outside the trusted set is a violation'
    $te2 = New-TestEnv
    Set-Content -LiteralPath "$($te2.Folder)\held.txt" 'held'
    $null = Invoke-SuiteLock -Path $te2.Folder -TrustedSids $Trusted -TakeOwnership { param($p) }
    $okBefore = (Test-RemovalFolderLocked -Path $te2.Folder -TrustedSids $Trusted).Ok
    $script:AclTestHook = @{ BeforeOpen = { param($p) if ($p -like '*held.txt') { throw 'injected: cannot open' } } }   # the access-list library's own test seam
    try {
        $v = Test-RemovalFolderLocked -Path $te2.Folder -TrustedSids $Trusted
        Assert-True ($okBefore -and @($v.Errors).Count -ge 1 -and @($v.Violations).Count -eq 0 -and -not $v.Ok) 'verifier: a locked tree with an object it cannot open is NOT ok (a read error is never a pass)'
    } finally { $script:AclTestHook = $null }
    # something re-creates a task after the steps that removed it: the final read-back sees it
    $te = New-TestEnv; $fs = New-FakeState $te.Folder
    $fs.Hooks.RemoveRule = { param($id) if (@($fs.Rules).Count -eq 0) { $fs.Tasks['NginxReload'] = @{ Name = 'NginxReload'; Path = '\'; Enabled = $false; State = 'Disabled'; UserId = 'SYSTEM'; ActionText = 'nginx -s reload' } } }.GetNewClosure()
    $r = Invoke-Run $te $fs -Execute
    Assert-True ($r.ExitCode -eq 3 -and ($r.Refusals -join ' ') -match 'read-back') 'the final read-back catches an item that came back after its own step passed'
}

Section 'takeown hands ownership to the Administrators group (the real takeown.exe on a scratch file)'
Test-Step 'takeown-owner' {
    $te = New-TestEnv
    $f = "$($te.Folder)\own-me.txt"; Set-Content -LiteralPath $f 'x'
    Assert-Throwaway $f 'Invoke-RemovalTakeown'
    $elev = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    if ($elev) {
        Invoke-RemovalTakeown -Path $f
        $o = (Get-AclSddlAndOwnerChecked -Path $f -IsDir $false).Owner
        Assert-True ($o -eq 'S-1-5-32-544') "after the production takeown call the owner is the Administrators group (got $o), not the current user"
    } else {
        $threw = $false; try { Invoke-RemovalTakeown -Path $f } catch { $threw = $true }
        Assert-True $threw 'not elevated: the production takeown call fails closed'
    }
}

Section 'the walk is link-safe (the lock never follows a junction)'
Test-Step 'links' {
    $te = New-TestEnv
    $victim = "$TmpRoot\removal-victim-$($te.Id)"; New-Item -ItemType Directory $victim | Out-Null; [void]$script:Cleanup.Add($victim)
    Set-Content -LiteralPath "$victim\precious.txt" 'precious'
    $snap = Get-TreeSnapshot $victim
    New-Item -ItemType Junction -Path "$($te.Folder)\bin\escape" -Target $victim | Out-Null
    New-Item -ItemType SymbolicLink -Path "$($te.Folder)\bin\filelink" -Target "$victim\precious.txt" -ErrorAction SilentlyContinue | Out-Null
    $own = New-Object System.Collections.ArrayList
    $w = Invoke-SuiteLock -Path $te.Folder -TrustedSids $Trusted -TakeOwnership { param($p) [void]$own.Add($p) }.GetNewClosure()
    Assert-True ($snap -ceq (Get-TreeSnapshot $victim)) 'the junction target (names, sizes, ACLs) is untouched after a full lock'
    Assert-True (@($own | Where-Object { $_ -like "$victim*" -or $_ -like '*\escape*' }).Count -eq 0) 'ownership was never taken through a link'
    Assert-True (@($w.Links).Count -ge 1 -and @($w.Links | Where-Object { $_ -like '*\escape' }).Count -eq 1) 'the junction is reported in Links, not entered'
    # inventory also stays out
    Assert-True (@((Get-RemovalFolderInventory -Path $te.Folder).Links).Count -ge 1) 'the inventory lists links without entering them'
}

Section 'the throwaway-path guard and the ACL canary'
Test-Step 'guard' {
    foreach ($real in 'C:\Windows\Temp', 'C:\Windows', 'C:\', 'C:\ProgramData', 'C:\ProgramData\nginx-quarantine', 'C:\nginx', $TmpRoot, "$TmpRoot\..\x", "$TmpRoot\sub\..\..\x", '', 'relative\path', "$TmpRoot\zz-unowned-no-token") {
        Assert-True (-not (Test-ThrowawayPath $real)) "the guard says '$real' is NOT a throwaway path"
    }
    $gx = "$TmpRoot\zz-guard-$(New-SuiteId)"; [void]$script:Cleanup.Add($gx)
    Assert-True ((Test-ThrowawayPath $gx) -and (Test-ThrowawayPath "$gx\y\z")) 'the guard accepts a path of this run strictly below the suite temp root'
    # the sink makes the expected SAFETY failure countable by the assertion below instead of recorded as a suite failure
    $script:GuardCaught = $null
    $script:SafetyFailSink = { param($m) $script:GuardCaught = $m }
    $threw = $false
    try { try { Assert-Throwaway 'C:\Windows\Temp' 'self-test' } catch { $threw = $true } } finally { $script:SafetyFailSink = $null }
    Assert-True ($threw -and $script:GuardCaught -like 'SAFETY:*') 'Assert-Throwaway on a real path throws and reports a SAFETY failure'
    $script:GuardCaught = $null; $script:SafetyFailSink = { param($m) $script:GuardCaught = $m }
    $threw = $false
    try { try { Assert-Throwaway "$TmpRoot\zz-unowned-no-token" 'self-test' } catch { $threw = $true } } finally { $script:SafetyFailSink = $null }
    Assert-True ($threw -and $script:GuardCaught -like 'SAFETY:*') 'Assert-Throwaway on a folder inside temp that this run did not name throws too'
    $threw = $false; $script:SafetyFailSink = { param($m) }
    try { try { Assert-Throwaway $gx 'self-test' } catch { $threw = $true } } finally { $script:SafetyFailSink = $null }
    Assert-True (-not $threw) 'and Assert-Throwaway lets a path of this run through'
}
Test-Step 'protected-overlap' {
    $bad = @('C:\', 'C:\Windows', 'C:\Windows\Temp', 'C:\Windows\Temp\x', 'C:\ProgramData', 'C:\ProgramData\nginx-quarantine', 'C:\Program Files', 'C:\nginx', 'C:\Users', [Environment]::GetFolderPath('UserProfile'), (Split-Path $PSScriptRoot -Parent), "$(Split-Path $PSScriptRoot -Parent)\x", '', 'D:\')
    foreach ($b in $bad) { Assert-True (Test-ProtectedOverlap $b) "overlap: '$b' is protected" }
    foreach ($ok in $TmpRoot, "$TmpRoot\zz-any") { Assert-True (-not (Test-ProtectedOverlap $ok)) "no overlap: '$ok' (the real temp root and a folder in it)" }
    $s = "$TmpRoot\zz-standin-$(New-SuiteId)"; New-Item -ItemType Directory -Force "$s\inner" | Out-Null; [void]$script:Cleanup.Add($s)
    $script:ProtectedExtra = @($s)
    try {
        Assert-True ((Test-ProtectedOverlap $s) -and (Test-ProtectedOverlap "$s\inner") ) 'an added protected root: it, and what is inside it, overlap'
        Assert-True (-not (Test-ThrowawayPath "$s\inner")) 'a folder inside an added protected root is not throwaway'
        Assert-True ($null -ne (Get-SuiteTempProblem $s)) 'a temp folder that IS a protected root is a startup problem'
        Assert-True ($null -ne (Get-SuiteTempProblem "$s\inner")) 'a temp folder INSIDE a protected root is a startup problem'
    } finally { $script:ProtectedExtra = @() }
    Assert-True ($null -eq (Get-SuiteTempProblem $TmpRoot)) 'the real temp folder is not a startup problem'
    $c = Get-SuiteTempProblem 'C:\'; Assert-True ($null -ne $c) 'a temp folder of C:\ is a startup problem'
    $c = Get-SuiteTempProblem 'C:\Windows'; Assert-True ($null -ne $c) 'a temp folder of C:\Windows is a startup problem'
    $c = Get-SuiteTempProblem 'C:\Users'; Assert-True ($null -ne $c) 'a temp folder of C:\Users (contains the profile) is a startup problem'
    $c = Get-SuiteTempProblem "$s\no-such-folder"; Assert-True ($null -ne $c) 'a temp folder that does not exist is a startup problem'
}
Test-Step 'cleanup-guard' {
    $s = "$TmpRoot\zz-cleanup-$(New-SuiteId)"; New-Item -ItemType Directory -Force "$s\sub" | Out-Null; Set-Content -LiteralPath "$s\sub\f.txt" 'x'; [void]$script:Cleanup.Add($s)
    $script:GuardCaught = $null; $script:SafetyFailSink = { param($m) $script:GuardCaught = $m }
    $script:ProtectedExtra = @($s)
    try { Remove-AllCleanup -Paths @($s) } finally { $script:ProtectedExtra = @(); $script:SafetyFailSink = $null }
    Assert-True ((Test-Path -LiteralPath "$s\sub\f.txt") -and $script:GuardCaught -like 'SAFETY: cleanup refused*') 'BLOCK: the cleanup REFUSES to delete a folder that overlaps a protected root, and says so'
    # outside the temp root: refused even though nothing protects it (a decoy beside the temp folder, never the temp folder's parent)
    $out = [IO.Path]::GetFullPath("$TmpRoot\..\zz-outside-$(New-SuiteId)"); New-Item -ItemType Directory -Force $out | Out-Null
    $script:GuardCaught = $null; $script:SafetyFailSink = { param($m) $script:GuardCaught = $m }
    try { Remove-AllCleanup -Paths @($out) } finally { $script:SafetyFailSink = $null }
    $survived = Test-Path -LiteralPath $out
    if ($survived) { [IO.Directory]::Delete($out, $true) }
    Assert-True ($script:GuardCaught -like 'SAFETY: cleanup refused*' -and $survived) 'BLOCK: the cleanup REFUSES a folder outside the temp root'
    # a link that carries this run's token but points OUTSIDE the temp root: refused, the link and its target stay
    $out2 = [IO.Path]::GetFullPath("$TmpRoot\..\zz-outside-$(New-SuiteId)"); New-Item -ItemType Directory -Force $out2 | Out-Null; Set-Content -LiteralPath "$out2\keep.txt" 'keep'
    $lo = "$TmpRoot\zz-linkout-$(New-SuiteId)"; New-Item -ItemType Junction -Path $lo -Target $out2 | Out-Null
    $script:GuardCaught = $null; $script:SafetyFailSink = { param($m) $script:GuardCaught = $m }
    try { Remove-AllCleanup -Paths @($lo) } finally { $script:SafetyFailSink = $null }
    $linkStays = Test-Path -LiteralPath $lo; $keepStays = Test-Path -LiteralPath "$out2\keep.txt"
    [void](Remove-SuiteTree -Path $lo); [IO.Directory]::Delete($out2, $true)
    Assert-True ($script:GuardCaught -like 'SAFETY: cleanup refused*' -and $linkStays -and $keepStays) 'BLOCK: the cleanup REFUSES a link of this run that points outside the temp root, and its target is untouched'
    # a read-only tree with links: cleared and removed; the link targets keep their contents, ACLs AND attributes
    $vic = "$TmpRoot\zz-rovictim-$(New-SuiteId)"; New-Item -ItemType Directory -Force $vic | Out-Null; Set-Content -LiteralPath "$vic\precious.txt" 'precious'; [void]$script:Cleanup.Add($vic)
    [IO.File]::SetAttributes("$vic\precious.txt", [IO.FileAttributes]::ReadOnly)
    $vsnap = Get-TreeSnapshot $vic
    $ro = "$TmpRoot\zz-ro-$(New-SuiteId)"; New-Item -ItemType Directory -Force "$ro\rodir" | Out-Null; Set-Content -LiteralPath "$ro\rodir\f.txt" 'x'
    New-Item -ItemType Junction -Path "$ro\rojunc" -Target $vic | Out-Null
    try { New-Item -ItemType SymbolicLink -Path "$ro\rolink" -Target "$vic\precious.txt" -ErrorAction Stop | Out-Null } catch { }
    [IO.File]::SetAttributes("$ro\rodir\f.txt", [IO.FileAttributes]::ReadOnly)
    foreach ($n in 'rodir', 'rojunc', 'rolink') { $q = "$ro\$n"; if (Test-Path -LiteralPath $q) { [IO.File]::SetAttributes($q, [IO.File]::GetAttributes($q) -bor [IO.FileAttributes]::ReadOnly) } }
    [void]$script:Cleanup.Add($ro)
    Remove-AllCleanup -Paths @($ro)
    Assert-True (-not (Test-Path -LiteralPath $ro)) 'the cleanup removes a tree holding read-only files, folders, junctions and symlinks'
    Assert-True ($vsnap -ceq (Get-TreeSnapshot $vic) -and ([IO.File]::GetAttributes("$vic\precious.txt") -band [IO.FileAttributes]::ReadOnly)) 'and the link targets are untouched (names, sizes, ACLs and the read-only attribute)'
    # a link ROOT is refused by the attribute clearer and removed as a link by the cleanup
    $jr = "$TmpRoot\zz-jroot-$(New-SuiteId)"; New-Item -ItemType Junction -Path $jr -Target $vic | Out-Null; [void]$script:Cleanup.Add($jr)
    $threw = $false; try { Clear-SuiteReadOnly -Root $jr } catch { $threw = $true }
    Assert-True ($threw -and $vsnap -ceq (Get-TreeSnapshot $vic)) 'BLOCK: Clear-SuiteReadOnly REFUSES a junction root and the victim (names, ACLs, attributes) is untouched'
    Remove-AllCleanup -Paths @($jr)
    Assert-True (-not (Test-Path -LiteralPath $jr) -and $vsnap -ceq (Get-TreeSnapshot $vic)) 'the cleanup removes a junction root as a link and the victim is untouched'
    # a folder that cannot be deleted is REPORTED, not passed over
    $lk = "$TmpRoot\zz-locked-$(New-SuiteId)"; New-Item -ItemType Directory -Force $lk | Out-Null; [void]$script:Cleanup.Add($lk)
    $fs = [IO.File]::Open("$lk\held.txt", [IO.FileMode]::Create, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None)
    $script:GuardCaught = $null; $script:SafetyFailSink = { param($m) $script:GuardCaught = $m }
    try { Remove-AllCleanup -Paths @($lk) } finally { $script:SafetyFailSink = $null; $fs.Dispose() }
    Assert-True ($script:GuardCaught -like "cleanup left*") 'a folder the cleanup cannot delete is REPORTED as left behind'
}
Test-Step 'link-and-prefix-resolution' {
    $id = New-SuiteId
    $d = "$TmpRoot\zz-canon-d-$id"; New-Item -ItemType Directory -Force "$d\sub" | Out-Null; [void]$script:Cleanup.Add($d)
    $j = "$TmpRoot\zz-canon-j-$id"; New-Item -ItemType Junction -Path $j -Target $d | Out-Null; [void]$script:Cleanup.Add($j)
    $cj = Get-CanonicalPath $j; $cd = Get-CanonicalPath $d
    Assert-True ($cj -ceq $cd -and $cj -cne $j) 'a junction resolves to the final path of its target'
    Assert-True ((Get-CanonicalPath "$j\sub\not-yet") -ceq "$cd\sub\not-yet") 'a path through a junction with a not-yet-existing tail resolves the same way'
    Assert-True ((Get-ReparseComponent "$j\sub") -ceq $j) 'a junction anywhere in a path is found'
    Assert-True ($null -eq (Get-ReparseComponent $d)) 'and a plain path has none'
    Assert-True (-not (Test-ProtectedOverlap $j)) 'control: a junction to an unprotected folder is not protected'
    $script:ProtectedExtra = @($d)
    try { Assert-True ((Test-ProtectedOverlap $j) -and (Test-ProtectedOverlap "$j\sub")) 'BLOCK: a JUNCTION to a protected folder (and what is inside it) overlaps it' } finally { $script:ProtectedExtra = @() }
    $x = "$TmpRoot\zz-notmine-" + [guid]::NewGuid().ToString('N').Substring(0, 8); New-Item -ItemType Directory -Force $x | Out-Null; [void]$script:Cleanup.Add($x)
    $jx = "$TmpRoot\zz-canon-x-$id"; New-Item -ItemType Junction -Path $jx -Target $x | Out-Null; [void]$script:Cleanup.Add($jx)
    Assert-True (-not (Test-ThrowawayPath $jx)) 'BLOCK: a junction bearing this run''s token that points at a folder the run did not make is NOT throwaway'
    Assert-True ((Test-ThrowawayPath $d) -and (Test-ThrowawayPath $j)) 'control: the run''s own folder, and a link to it, are throwaway'
    $forms = @('\\?\C:\Windows', '\\.\C:\Windows', '\\localhost\C$\Windows', '\\127.0.0.1\C$\Windows\Temp', '\\?\UNC\localhost\C$\Windows', '\\?\GLOBALROOT\Device\HarddiskVolume3\Windows', '//localhost/C$/Windows')
    foreach ($f in $forms) {
        Assert-True ($null -eq (Get-CanonicalPath $f) -and (Test-ProtectedOverlap $f) -and -not (Test-ThrowawayPath $f) -and $null -ne (Get-SuiteTempProblem $f)) "BLOCK: the spelling '$f' is refused outright (no canonical path, protected, not throwaway, a startup problem)"
    }
    $script:ProtectedExtra = @($j)
    try { Assert-True (Test-ProtectedOverlap $d) 'BLOCK: a protected root DECLARED through a junction protects the folder the junction points to' } finally { $script:ProtectedExtra = @() }
    $tp = Get-SuiteTempProblem "$j\sub"
    Assert-True ($null -ne $tp -and $tp -like '*link*') 'BLOCK: a temp folder that goes through a junction is a startup problem'
}
function Invoke-SuiteChildRun {
    # runs this script as a child process (always flagged nested) with extra arguments and environment; hidden, bounded
    param([string[]]$ChildArgs, [hashtable]$ChildEnv = @{})
    . "$PSScriptRoot\hidden-process-lib.ps1"
    $e = @{ NGINXRM_NESTED = '1' }; foreach ($k in $ChildEnv.Keys) { $e[$k] = $ChildEnv[$k] }
    return (Invoke-HiddenProcess -FilePath (Get-Command pwsh).Source -ArgumentList (@('-NoProfile', '-NonInteractive', '-File', $PSCommandPath) + $ChildArgs) -TimeoutSec 600 -Environment $e)
}
Test-Step 'start-refusal' {
    # the suite is started as a child with TMP/TEMP spelled in each way that reaches a stand-in "system" folder declared
    # protected; it must refuse to start (exit 3) and the stand-in must hold exactly what it held before
    if ($env:NGINXRM_NESTED) { Write-Host '  (nested run: the child-process tests are skipped)' -ForegroundColor DarkGray; return }
    $id = New-SuiteId
    $s = "$TmpRoot\zz-standin-sys-$id"; New-Item -ItemType Directory -Force "$s\keep" | Out-Null; Set-Content -LiteralPath "$s\keep\f.txt" 'keep'; [void]$script:Cleanup.Add($s)
    $p = "$TmpRoot\zz-standin-par-$id"; New-Item -ItemType Directory -Force "$p\prot\keep" | Out-Null; Set-Content -LiteralPath "$p\prot\keep\f.txt" 'keep'; [void]$script:Cleanup.Add($p)
    $r = "$TmpRoot\zz-standin-real-$id"; New-Item -ItemType Directory -Force "$r\sub" | Out-Null; [void]$script:Cleanup.Add($r)
    $j1 = "$TmpRoot\zz-lnk-s-$id"; New-Item -ItemType Junction -Path $j1 -Target $s | Out-Null; [void]$script:Cleanup.Add($j1)
    $j2 = "$TmpRoot\zz-lnk-p-$id"; New-Item -ItemType Junction -Path $j2 -Target $p | Out-Null; [void]$script:Cleanup.Add($j2)
    $j3 = "$TmpRoot\zz-lnk-r-$id"; New-Item -ItemType Junction -Path $j3 -Target $r | Out-Null; [void]$script:Cleanup.Add($j3)
    $tail = $s.Substring(3)
    $cases = @(
        @{ W = 'plain stand-in'; Tmp = $s; Prot = $s; Watch = $s },
        @{ W = 'a junction TO the stand-in'; Tmp = $j1; Prot = $s; Watch = $s },
        @{ W = 'a junction to the PARENT of the stand-in'; Tmp = $j2; Prot = "$p\prot"; Watch = $p },
        @{ W = 'a junction above an unprotected temp folder'; Tmp = "$j3\sub"; Prot = $s; Watch = $r },
        @{ W = '\\?\ prefix'; Tmp = "\\?\$s"; Prot = $s; Watch = $s },
        @{ W = '\\.\ prefix'; Tmp = "\\.\$s"; Prot = $s; Watch = $s },
        @{ W = '\\localhost\C$ UNC'; Tmp = "\\localhost\C`$\$tail"; Prot = $s; Watch = $s },
        @{ W = '\\127.0.0.1\C$ UNC'; Tmp = "\\127.0.0.1\C`$\$tail"; Prot = $s; Watch = $s },
        @{ W = '\\?\UNC\localhost\C$'; Tmp = "\\?\UNC\localhost\C`$\$tail"; Prot = $s; Watch = $s }
    )
    foreach ($c in $cases) {
        $before = Get-TreeSnapshot $c.Watch
        $h = Invoke-SuiteChildRun -ChildArgs @('-NoSmoke') -ChildEnv @{ TMP = $c.Tmp; TEMP = $c.Tmp; NGINXRM_PROTECTED_EXTRA = $c.Prot }
        Assert-True ($h.ExitCode -eq 3 -and $h.Stdout -match 'refusing to start') "BLOCK: temp spelled as $($c.W): the suite REFUSES TO START (exit $($h.ExitCode))"
        Assert-True ($before -ceq (Get-TreeSnapshot $c.Watch)) "and nothing was created or changed in the stand-in ($($c.W))"
    }
}
Test-Step 'only-handling' {
    if ($env:NGINXRM_NESTED) { return }
    foreach ($case in @(
            @{ A = @('-Mutations', '-Only', ''); W = '-Mutations -Only "" (empty)'; X = 3 },
            @{ A = @('-Mutations', '-Only', ','); W = '-Mutations -Only "," (only separators)'; X = 3 },
            @{ A = @('-Mutations', '-Only', ' '); W = '-Mutations -Only " " (whitespace)'; X = 3 },
            @{ A = @('-Only', 'folder-gate-disabled'); W = '-Only without -Mutations'; X = 3 },
            @{ A = @('-Mutations', '-Only', 'folder-gate-disabled'); W = 'a nested -Mutations run (the nested-run guard)'; X = 9 })) {
        $h = Invoke-SuiteChildRun -ChildArgs (@('-NoSmoke') + $case.A)
        Assert-True ($h.ExitCode -eq $case.X) "BLOCK: $($case.W) exits $($case.X) and runs nothing (exit $($h.ExitCode))"
    }
}
Test-Step 'mapped-drive' {
    # a temp folder reached through a mapped network drive (its final path is a UNC path) or a SUBST drive, both aimed at a
    # stand-in declared protected: the suite must refuse to start and leave the stand-in as it was
    if ($env:NGINXRM_NESTED) { return }
    $id = New-SuiteId
    $s = "$TmpRoot\zz-standin-map-$id"; New-Item -ItemType Directory -Force "$s\keep", "$s\sub" | Out-Null; Set-Content -LiteralPath "$s\keep\f.txt" 'keep'; [void]$script:Cleanup.Add($s)
    $used = @([IO.DriveInfo]::GetDrives() | ForEach-Object { $_.Name.Substring(0, 1).ToUpperInvariant() })
    $free = @(@('W', 'V', 'U', 'T', 'S', 'R', 'Q', 'P') | Where-Object { $used -notcontains $_ } | Get-Random -Count 8)   # never Z: the absent-drive test needs it free
    if ($free.Count -lt 2) { Write-Host '  NOTE: no free drive letters; the mapped-drive and subst locks were NOT exercised' -ForegroundColor Yellow; [void]$script:LocksNotExercised.Add('mapped-drive and subst: no free drive letters'); return }
    $mapL = $free[0]; $subL = $free[1]
    $before = Get-TreeSnapshot $s
    $unc = '\\localhost\C$\' + $s.Substring(3)
    $mapped = $false
    try {
        $o = & net.exe use "${mapL}:" $unc '/persistent:no' 2>&1
        $mapped = ($LASTEXITCODE -eq 0)
        if (-not $mapped) { Write-Host "  NOTE: could not map ${mapL}: to the administrative share ($(($o | Out-String).Trim())); the mapped-drive lock was NOT exercised" -ForegroundColor Yellow; [void]$script:LocksNotExercised.Add('mapped-drive: net use failed') }
        else {
            $h = Invoke-SuiteChildRun -ChildArgs @('-NoSmoke') -ChildEnv @{ TMP = "${mapL}:\"; TEMP = "${mapL}:\"; NGINXRM_PROTECTED_EXTRA = $s }
            Assert-True ($h.ExitCode -eq 3 -and $h.Stdout -match 'cannot be resolved to its final path') "BLOCK: a temp folder on a MAPPED NETWORK DRIVE onto the stand-in: the suite REFUSES TO START because its final path is a network path (exit $($h.ExitCode))"
            Assert-True ($before -ceq (Get-TreeSnapshot $s)) 'and nothing was created or changed in the stand-in (mapped drive)'
        }
    } finally { if ($mapped) { & net.exe use "${mapL}:" /delete /y 2>&1 | Out-Null } }
    $substed = $false
    try {
        & subst.exe "${subL}:" $s 2>&1 | Out-Null
        $substed = ($LASTEXITCODE -eq 0)
        if (-not $substed) { Write-Host "  NOTE: subst ${subL}: failed; the subst lock was NOT exercised" -ForegroundColor Yellow; [void]$script:LocksNotExercised.Add('subst: subst failed') }
        else {
            $h = Invoke-SuiteChildRun -ChildArgs @('-NoSmoke') -ChildEnv @{ TMP = "${subL}:\"; TEMP = "${subL}:\"; NGINXRM_PROTECTED_EXTRA = $s }
            Assert-True ($h.ExitCode -eq 3 -and $h.Stdout -match 'refusing to start') "BLOCK: a temp folder on a SUBST drive onto the stand-in: the suite REFUSES TO START (exit $($h.ExitCode))"
            Assert-True ($before -ceq (Get-TreeSnapshot $s)) 'and nothing was created or changed in the stand-in (subst drive root)'
            $h = Invoke-SuiteChildRun -ChildArgs @('-NoSmoke') -ChildEnv @{ TMP = "${subL}:\sub"; TEMP = "${subL}:\sub"; NGINXRM_PROTECTED_EXTRA = $s }
            Assert-True ($h.ExitCode -eq 3 -and $h.Stdout -match 'refusing to start' -and $h.Stdout -match 'protected') "BLOCK: a temp folder BELOW a SUBST drive that maps onto the protected stand-in (only the drive's final path shows it): REFUSES TO START (exit $($h.ExitCode))"
            Assert-True ($before -ceq (Get-TreeSnapshot $s)) 'and nothing was created or changed in the stand-in (subst drive subfolder)'
        }
    } finally { if ($substed) { & subst.exe "${subL}:" /d 2>&1 | Out-Null } }
}
Test-Step 'sweep-reporting' {
    # The PARENT's end-of-run path (canary verdict, sweep, exit code), run in-process on fixture folders that are this
    # run's own (the sweep only accepts a real folder named for the sweep token, inside the temp root).
    $tok = [guid]::NewGuid().ToString('N').Substring(0, 8)
    $oldTok = $script:SweepToken; $script:SweepToken = $tok
    try {
        $mk = {
            param($leakControl, $leakOutside, $hold)
            $f = "$TmpRoot\nginxrm-mut-$tok"
            foreach ($d in 'control', 'control.tmp', 'm-a', 'm-a.tmp') { New-Item -ItemType Directory -Force "$f\$d" | Out-Null }
            [void]$script:Cleanup.Add($f)
            if ($leakControl) { Set-Content -LiteralPath "$f\control.tmp\leak.txt" 'x' }
            if ($leakOutside) { New-Item -ItemType Directory -Force "$f\zz-outside-leak" | Out-Null }
            $fs = $null
            if ($hold) { $fs = [IO.File]::Open("$f\m-a.tmp\held.txt", [IO.FileMode]::Create, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None) }
            return @{ F = $f; Hold = $fs }
        }
        $finish = {
            param($fx, $results)
            $all = @(& { Complete-MutationRun -R @{ Tmp = $fx.F; Control = $true; Results = $results } -CanaryStart $script:CanaryStart } 6>&1)
            if ($fx.Hold) { $fx.Hold.Dispose() }
            $code = @($all | Where-Object { $_ -is [int] })[-1]
            $text = (@($all | Where-Object { $_ -isnot [int] }) | ForEach-Object { [string]$_ }) -join "`n"
            return @{ Code = $code; Text = $text }
        }
        $one = @(@{ N = 'x'; Class = 'KILLED'; Why = 'w' })
        $fx = & $mk $false $false $false; $h = & $finish $fx $one
        Assert-True ($h.Code -eq 0 -and $h.Text -notmatch '\[swept\]|\[STUCK\]|\[LEAK-OUT\]' -and -not (Test-Path -LiteralPath $fx.F)) "control: a clean fixture is swept without a word and removed (code $($h.Code))"
        $fx = & $mk $true $false $false; $h = & $finish $fx $one
        Assert-True ($h.Text -match '\[swept\]\s+control:' -and $h.Code -eq 6) "BLOCK: a leak by the UNMUTATED control is reported by name and fails the run (code $($h.Code))"
        $fx = & $mk $false $true $false; $h = & $finish $fx $one
        Assert-True ($h.Text -match '\[LEAK-OUT\].*zz-outside-leak' -and -not (Test-Path -LiteralPath $fx.F)) 'BLOCK: a leak in the parent folder is reported by name, not removed silently'
        $fx = & $mk $false $false $true; $h = & $finish $fx $one
        $iCanary = $h.Text.IndexOf('ACL canary: unchanged'); $iStuck = $h.Text.IndexOf('[STUCK]')
        Assert-True ($h.Code -eq 5 -and $iStuck -ge 0 -and $h.Text -match '\[swept\]\s+m-a:') "BLOCK: a folder that cannot be removed is reported as [STUCK] and the run returns 5 (code $($h.Code))"
        Assert-True ($iCanary -ge 0 -and $iCanary -lt $iStuck) 'and the ACL canary verdict is printed BEFORE the stuck exit'
        $fx = & $mk $false $false $false; $h = & $finish $fx @()
        Assert-True ($h.Code -eq 7 -and $h.Text -match 'no mutants ran' -and $h.Text -notmatch 'MUTATION RESULT') "BLOCK: an empty mutation run is not a pass (code $($h.Code), 'no mutants ran')"
    } finally { $script:SweepToken = $oldTok }
}
Test-Step 'sweep-containment' {
    # The sweep deletes. It must refuse, listing nothing, anything that is not this run's own real mutation folder; each
    # decoy below is the run's own and must survive byte-identical.
    $tok = [guid]::NewGuid().ToString('N').Substring(0, 8)
    $oldTok = $script:SweepToken; $script:SweepToken = $tok
    $id = New-SuiteId
    try {
        $probe = {
            param($label, $folder, $watch)
            $before = Get-TreeSnapshot $watch
            $r = Invoke-MutationSweep $folder
            Assert-True ([bool]$r.Refused -and $before -ceq (Get-TreeSnapshot $watch) -and (Test-Path -LiteralPath $folder)) "BLOCK: the sweep REFUSES $label and it is left byte-identical ($($r.Refused))"
        }
        # 1. a real folder outside the temp root, with the right name
        $outer = [IO.Path]::GetFullPath("$TmpRoot\..\zz-elsewhere-$id"); $o1 = "$outer\nginxrm-mut-$tok"
        New-Item -ItemType Directory -Force "$o1\project\src" | Out-Null; Set-Content -LiteralPath "$o1\project\src\precious.txt" 'precious'
        & $probe 'a real folder OUTSIDE the temp root' $o1 $outer
        # 2. a junction with the right name inside the temp root, pointing at a victim
        $vic = "$TmpRoot\zz-sweepvic-$id"; New-Item -ItemType Directory -Force "$vic\sub" | Out-Null; Set-Content -LiteralPath "$vic\sub\precious.txt" 'precious'; [void]$script:Cleanup.Add($vic)
        $holder = "$TmpRoot\zz-sweephold-$id"; New-Item -ItemType Directory -Force $holder | Out-Null; [void]$script:Cleanup.Add($holder)
        $j = "$holder\nginxrm-mut-$tok"; New-Item -ItemType Junction -Path $j -Target $vic | Out-Null
        & $probe 'a JUNCTION named for the run, pointing at a folder' $j $vic
        # 3. a directory symlink likewise
        $holder2 = "$TmpRoot\zz-sweephold2-$id"; New-Item -ItemType Directory -Force $holder2 | Out-Null; [void]$script:Cleanup.Add($holder2)
        $sl = "$holder2\nginxrm-mut-$tok"
        $made = $true; try { New-Item -ItemType SymbolicLink -Path $sl -Target $vic -ErrorAction Stop | Out-Null } catch { $made = $false }
        if ($made) { & $probe 'a directory SYMLINK named for the run' $sl $vic } else { [void]$script:LocksNotExercised.Add('sweep-containment: no symlink could be made') ; Write-Host '  NOTE: no directory symlink could be made; the symlink case was NOT exercised' -ForegroundColor Yellow }
        # 4. a real folder named for the run, but below a junction (a link in its ancestry)
        $real = "$TmpRoot\zz-sweepreal-$id"; New-Item -ItemType Directory -Force "$real\nginxrm-mut-$tok\control.tmp" | Out-Null; Set-Content -LiteralPath "$real\nginxrm-mut-$tok\control.tmp\f.txt" 'x'; [void]$script:Cleanup.Add($real)
        $jl = "$TmpRoot\zz-sweeplnk-$id"; New-Item -ItemType Junction -Path $jl -Target $real | Out-Null; [void]$script:Cleanup.Add($jl)
        & $probe 'a real folder reached THROUGH a junction' "$jl\nginxrm-mut-$tok" $real
        # 5. look-alike names inside the temp root
        foreach ($name in "nginxrm-mut-$($tok)x", "xnginxrm-mut-$tok", 'nginxrm-mut-0badc0de') {
            $la = "$TmpRoot\$name"; New-Item -ItemType Directory -Force "$la\m-a.tmp" | Out-Null; Set-Content -LiteralPath "$la\m-a.tmp\f.txt" 'x'; [void]$script:Cleanup.Add($la)
            & $probe "the look-alike name '$name'" $la $la
        }
        # control: the same shape, properly named and placed, IS swept
        $good = "$TmpRoot\nginxrm-mut-$tok"; New-Item -ItemType Directory -Force "$good\m-a.tmp" | Out-Null; [void]$script:Cleanup.Add($good)
        $r = Invoke-MutationSweep $good
        Assert-True (-not $r.Refused -and -not (Test-Path -LiteralPath $good)) 'control: this run''s own mutation folder is swept and removed'
        # a run with no token refuses everything
        $script:SweepToken = $null
        $r = Invoke-MutationSweep "$TmpRoot\nginxrm-mut-$tok"
        Assert-True ([bool]$r.Refused) 'BLOCK: with no sweep token the sweep refuses'
    } finally {
        $script:SweepToken = $oldTok
        foreach ($x in @($outer)) { if ($x -and (Test-Path -LiteralPath $x)) { [void](Remove-SuiteTree -Path $x) } }
    }
}
Test-Step 'snapshot-attributes' {
    $d = "$TmpRoot\zz-snap-$(New-SuiteId)"; New-Item -ItemType Directory -Force $d | Out-Null; Set-Content -LiteralPath "$d\f.txt" 'x'; [void]$script:Cleanup.Add($d)
    $a = Get-TreeSnapshot $d
    [IO.File]::SetAttributes("$d\f.txt", [IO.FileAttributes]::ReadOnly)
    Assert-True ($a -cne (Get-TreeSnapshot $d)) 'the tree snapshot records attributes: a file turned read-only changes it'
    [IO.File]::SetAttributes("$d\f.txt", [IO.FileAttributes]::Normal)
    $b = Get-TreeSnapshot $d
    [IO.File]::SetAttributes($d, [IO.FileAttributes]'Directory,Hidden')
    Assert-True ($b -cne (Get-TreeSnapshot $d)) 'and the root folder''s own attributes too'
    [IO.File]::SetAttributes($d, [IO.FileAttributes]::Directory)
}
Test-Step 'temp-root-recheck' {
    $keep = $script:TmpRootCanon
    $script:GuardCaught = $null; $script:SafetyFailSink = { param($m) $script:GuardCaught = $m }
    $threw = $false
    try { $script:TmpRootCanon = 'Q:\not-the-temp-root'; try { [void](New-SuiteId) } catch { $threw = $true } } finally { $script:TmpRootCanon = $keep; $script:SafetyFailSink = $null }
    Assert-True ($threw -and $script:GuardCaught -like 'SAFETY:*') 'BLOCK: if the temp root is no longer what it was at start, no further fixture id is issued'
    $ok = $true; try { [void](New-SuiteId) } catch { $ok = $false }
    Assert-True $ok 'control: with the temp root unchanged an id is issued'
}
Test-Step 'canary-sample-depth' {
    $d = "$TmpRoot\zz-depth-$(New-SuiteId)"; New-Item -ItemType Directory -Force "$d\a\b\c\d\e\f" | Out-Null; [void]$script:Cleanup.Add($d)
    $smp = @(Get-AclCanarySample -Root $d)
    Assert-True ($smp -contains "$d\a" -and $smp -contains "$d\a\b" -and $smp -contains "$d\a\b\c") 'the sample reaches the configured depth (three levels below the root)'
    Assert-True (-not ($smp -contains "$d\a\b\c\d") -and $smp.Count -eq 3) 'and stops there: a 6-deep tree is cut off at that depth'
}
Test-Step 'canary-verdict' {
    # synthetic snapshots: the verdict logic is proven without touching any folder
    $h1 = 'A' * 64; $h2 = 'B' * 64
    $R1 = @('r1', 'r2')
    $s0 = [ordered]@{ r1 = $h1; 'r1\c' = $h1; r2 = 'ABSENT' }
    $v = Get-AclCanaryVerdict $s0 ([ordered]@{ r1 = $h1; 'r1\c' = $h1; r2 = 'ABSENT' }) -Roots $R1
    Assert-True ($v.Failures.Count -eq 0 -and $v.Blind.Count -eq 0) 'verdict control: identical snapshots, nothing read as blind, no failure'
    $v = Get-AclCanaryVerdict $s0 ([ordered]@{ r1 = $h1; 'r1\c' = $h2; r2 = 'ABSENT' }) -Roots $R1
    Assert-True ($v.Failures.Count -eq 1 -and $v.Failures[0] -like '*r1\c*') 'a CHILD whose access list changed under an unchanged root is reported'
    $v = Get-AclCanaryVerdict $s0 ([ordered]@{ r1 = $h1; r2 = 'ABSENT' }) -Roots $R1
    Assert-True ($v.Failures.Count -eq 0) 'a sampled child that vanished (temp-folder churn) is not a change'
    $v = Get-AclCanaryVerdict $s0 ([ordered]@{ 'r1\c' = $h1; r2 = 'ABSENT' }) -Roots $R1
    Assert-True ($v.Failures.Count -eq 1 -and $v.Failures[0] -like '*r1*missing*') 'a ROOT that vanished is reported'
    $sb = [ordered]@{ r1 = 'UNREADABLE'; r2 = $h1 }
    $v = Get-AclCanaryVerdict $sb $sb -Roots $R1
    Assert-True ($v.Failures.Count -eq 1 -and $v.Failures[0] -like 'ACL CANARY BLIND*' -and $v.Blind -ccontains 'r1') 'UNREADABLE equal to UNREADABLE is a FAILURE (fail-closed), not an all-clear'
    $v = Get-AclCanaryVerdict $sb $sb -Roots $R1 -AllowBlind
    Assert-True ($v.Failures.Count -eq 0 -and $v.Blind -ccontains 'r1' -and $v.Observed.Roots -eq 1) '-AllowBlind: no failure, but the blind root is still named and not counted as observed'
    $v = Get-AclCanaryVerdict ([ordered]@{ r1 = $h1 }) ([ordered]@{ r1 = 'UNREADABLE' }) -Roots $R1
    Assert-True ($v.Failures.Count -ge 1) 'a root readable at start and unreadable at end is reported'
}
Test-Step 'canary-eviction' {
    # an entry pushed out of the end SAMPLE by new earlier-sorting files is still on disk: its change must be seen
    $d = "$TmpRoot\zz-evict-$(New-SuiteId)"; New-Item -ItemType Directory -Force $d | Out-Null; [void]$script:Cleanup.Add($d)
    Set-Content -LiteralPath "$d\m-file.txt" 'x'; Set-Content -LiteralPath "$d\gone-q.txt" 'y'
    $b = Get-AclCanary -Path @($d)
    & icacls "$d\m-file.txt" /grant '*S-1-5-11:R' | Out-Null
    Remove-Item -LiteralPath "$d\gone-q.txt"
    $e = Get-AclCanary -Path @($d)
    $e.Remove("$d\m-file.txt")   # simulate eviction from the end sample
    $v = Get-AclCanaryVerdict $b $e -Roots @($d)
    Assert-True (@($v.Failures | Where-Object { $_ -like "*m-file.txt*outside the end sample*" }).Count -eq 1) 'a changed entry that fell out of the end sample is read from disk and reported'
    Assert-True (@($v.Failures | Where-Object { $_ -like '*gone-q.txt*' }).Count -eq 0) 'an entry that is really gone from disk is churn, not a change'
}
Test-Step 'canary-toggle' {
    # The real incident call shape: Lock-RemovalFolderTree with the DEFAULT trusted list (SYSTEM + Administrators) and a
    # no-op takeown, with the folder gate out of the way, on a sentinel that already holds the lock's result at its root
    # (the live C:\Windows\Temp is in that state, so a root-only hash cannot move). Sentinel only, never a real folder.
    $shape = if ($script:IsElevated) { @{} } else { @{ TrustedSids = $Trusted } }   # non-elevated would lock itself out of the cleanup
    $s = "$TmpRoot\zz-canary-sentinel-$(New-SuiteId)"
    Assert-Throwaway $s 'the canary toggle test'
    New-Item -ItemType Directory -Force "$s\sub\deep" | Out-Null; Set-Content -LiteralPath "$s\sub\f.txt" 'x'; Set-Content -LiteralPath "$s\sub\deep\g.txt" 'y'; [void]$script:Cleanup.Add($s)
    # the damaged baseline: lock once (gate out of the way), then create children, which inherit the locked root
    $orig = ${function:Assert-RemovalFolderAllowed}
    try { ${function:Assert-RemovalFolderAllowed} = { param($Path) }; Invoke-SuiteLock -Path $s -TakeOwnership { param($p) } @shape | Out-Null }
    finally { ${function:Assert-RemovalFolderAllowed} = $orig }
    foreach ($d in "$s\fresh", "$s\fresh\inner") { New-Item -ItemType Directory -Force $d | Out-Null }
    Set-Content -LiteralPath "$s\fresh\n.txt" 'z'; Set-Content -LiteralPath "$s\fresh\inner\m.txt" 'w'
    # arm 1, control: nothing done between two reads
    $b = Get-AclCanary -Path @($s)
    Assert-True ($b[$s] -match '^[0-9A-F]{64}$' -and $b.Count -ge 6) "the canary reads the sentinel root and its children ($($b.Count) entries)"
    $v = Get-AclCanaryVerdict $b (Get-AclCanary -Path @($s)) -Roots @($s)
    Assert-True ($v.Failures.Count -eq 0) 'control: nothing done to the sentinel, the canary reports no change'
    # arm 2, guard ENGAGED: the incident call is refused and the canary stays quiet
    $gateThrew = $false; try { Invoke-SuiteLock -Path $s -TakeOwnership { param($p) } @shape | Out-Null } catch { $gateThrew = $true }
    $v = Get-AclCanaryVerdict $b (Get-AclCanary -Path @($s)) -Roots @($s)
    Assert-True ($gateThrew -and $v.Failures.Count -eq 0) 'ENGAGED: the incident call (default trusted list, no-op takeown) is refused by the gate and the canary shows no change'
    # arm 3, guard OFF: the same call runs, and the canary must FAIL
    $rootBefore = $b[$s]
    $orig = ${function:Assert-RemovalFolderAllowed}
    try {
        ${function:Assert-RemovalFolderAllowed} = { param($Path) }
        Invoke-SuiteLock -Path $s -TakeOwnership { param($p) } @shape | Out-Null
    } finally { ${function:Assert-RemovalFolderAllowed} = $orig }
    $after = Get-AclCanary -Path @($s)
    $v = Get-AclCanaryVerdict $b $after -Roots @($s)
    Assert-True ($v.Failures.Count -ge 1 -and @($v.Failures | Where-Object { $_ -like "*$s\fresh*" }).Count -ge 1) "TOGGLE: with the gate OFF the incident call rewrites the children and the canary FAILS ($($v.Failures.Count) changed entries)"
    Write-Host ("  (info) sentinel root hash {0} by the incident call; a root-only canary would have {1}" -f $(if ($after[$s] -ceq $rootBefore) { 'UNCHANGED' } else { 'changed' }), $(if ($after[$s] -ceq $rootBefore) { 'MISSED it' } else { 'seen it' })) -ForegroundColor DarkGray
    $gateBack = $false; try { Assert-RemovalFolderAllowed -Path $s } catch { $gateBack = $true }
    Assert-True $gateBack 'and the gate is back in force afterwards'
}
}
finally { Remove-AllCleanup }

if (-not $NoSmoke) {
    Section 'REAL script, dry run only, as a child process: the machine is unchanged'
    Test-Step 'smoke' {
        . "$PSScriptRoot\hidden-process-lib.ps1"
        $snapNow = {
            $svc = [bool](Get-CimInstance Win32_Service -Filter "Name='NginxGateway'" -ErrorAction SilentlyContinue)
            $t = @(Get-ScheduledTask -ErrorAction SilentlyContinue | Where-Object { $_.TaskPath -eq '\' -and $script:RemovalAllowedTasks -ccontains $_.TaskName } | ForEach-Object { "$($_.TaskName)=$($_.State)" } | Sort-Object) -join ','
            $r = @(Get-NetFirewallRule -ErrorAction SilentlyContinue | Where-Object { $script:RemovalAllowedRules -contains $_.DisplayName } | ForEach-Object { "$($_.Name)=$($_.Enabled)" } | Sort-Object) -join ','
            $f = if (Test-Path -LiteralPath 'C:\nginx') { (Get-ChildItem -LiteralPath 'C:\nginx' -Recurse -Force -ErrorAction SilentlyContinue | Measure-Object).Count } else { -1 }
            $q = Test-Path -LiteralPath 'C:\ProgramData\nginx-quarantine'
            "svc=$svc|tasks=$t|rules=$r|folder=$f|quarantine=$q"
        }
        $before = & $snapNow
        $childArgs = @('-NoProfile', '-NonInteractive', '-File', (Join-Path $PSScriptRoot 'remove-nginx-gateway.ps1'))
        Assert-True ($childArgs -notcontains '-Execute') 'SAFETY: the smoke never passes -Execute to the real script'
        $h = Invoke-HiddenProcess -FilePath (Get-Command pwsh).Source -ArgumentList $childArgs -TimeoutSec 300
        Assert-True ($h.ExitCode -in 0, 2) "the real script in its default mode exits 0 or 2 (a would-refuse dry run), got $($h.ExitCode)"
        Assert-True ($h.Stdout -match 'DRY RUN') 'its output says DRY RUN'
        Assert-True ($h.Stdout -notmatch 'TOPSECRET' -and $h.Stdout -notmatch '-----BEGIN') 'its output holds no key material'
        $after = & $snapNow
        Assert-True ($before -ceq $after) "the real machine is unchanged by the real dry run ($after)"
    }
}

Section 'ACL canary (end of suite)'
$canaryEnd = Get-AclCanary; Write-AclCanary 'suite-end  ' $canaryEnd
$verdict = Get-AclCanaryVerdict $script:CanaryStart $canaryEnd -AllowBlind:$AllowBlindCanary
foreach ($m in $verdict.Failures) { _fail $m }
if ($verdict.Failures.Count -eq 0 -and $verdict.Blind.Count -eq 0) { _pass ("the ACL canary read {0} of {1} paths and {2} entries below them; all identical at suite start and end" -f $verdict.Observed.Roots, $script:CanaryPaths.Count, $verdict.Observed.Entries) }
elseif ($verdict.Failures.Count -eq 0) { Write-Host "  ACL canary: NO CLAIM for $($verdict.Blind -join ', ') (unreadable, -AllowBlindCanary); the other paths were identical" -ForegroundColor Yellow }

Write-Host ''
if ($script:LocksNotExercised.Count -gt 0) { Write-Host "locks not exercised: $($script:LocksNotExercised -join '; ')" -ForegroundColor Yellow }
if ($script:Fail -eq 0) { Write-Host "RESULT: $($script:Pass) passed, 0 failed" -ForegroundColor Green; exit 0 }
Write-Host "RESULT: $($script:Pass) passed, $($script:Fail) failed" -ForegroundColor Red
$script:Failures | ForEach-Object { Write-Host "  - $_" -ForegroundColor Red }
exit 1
