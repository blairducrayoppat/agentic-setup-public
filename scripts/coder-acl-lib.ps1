#requires -Version 5.1
<#
.SYNOPSIS
  The ACL stage for the coder containment floor (#1678 narrow the projects grant, #1686 tighten
  C:\blarai-fleet, #1692 protect the model folders): a pure plan builder, an ACL model + simulator, a
  safe-target gate, and the apply engine. Dot-source it; it has NO side effects on load.

.DESCRIPTION
  WHY A MODEL AND A SIMULATOR. The stage is run once, by the Lead Architect, on the real machine. A plan the
  operator can read BEFORE it runs has to say what each folder looks like now and what it will look like
  after. The simulator (Invoke-AclSimulation) computes the "after" from the "before" and the operations, and
  verify-coder-narrowing.ps1 checks it against what icacls really does on a temp tree, so the printed
  "after" is not a hope.

  WHAT THE STAGE DOES, per folder (Get-CoderAclPlan):
    1. projects (#1678)   undo the coder's old inheritable Modify (every explicit copy under the tree), then
                          give it an inheritable READ-and-EXECUTE ACE. A repo created later inherits the read
                          ACE and nothing else: the coder can read it, never write it, and never write its
                          .git (refs, objects, index): the operator funnel is the only committer.
    2. fleet root (#1686) C:\blarai-fleet stops inheriting from C:\ (Authenticated Users: Modify), the coder
                          loses its Modify on the root, and gets Modify only on worktrees\ and coder-leg\.
    3. worktree-base deny the existing documented deny ACEs (the coder cannot delete or rename a worktree
                          root), now part of the stage.
    4. orphan SIDs        ACEs for accounts that no longer exist, on the paths named, are removed.
    5. model folders (#1692) any write-capable ACE for an account other than the operator, SYSTEM and
                          Administrators is removed (B:\models inherits Authenticated Users: Modify). The
                          operator keeps Modify and every account that could read keeps read.

  SAFETY. Every target passes Test-AclTargetSafe (absolute drive path, no wildcard, no link, no link above
  it, not a drive root or a system folder). TREE operations never use icacls /T: a directory symlink inside the
  tree is FOLLOWED by icacls /T even with /L (measured on a temp tree, 2026-10-06: /L protected the link's
  target folder but the files behind the link still lost their entries), so a link in a repo could make the
  stage rewrite access lists outside the tree. A tree operation here is an own walk (Invoke-NoFollowWalk) that
  enumerates folders and files, NEVER enters or touches a link (it lists it), and changes each object itself.
  The backup and the restore walk the same way.
#>

# ---- the ACE model ---------------------------------------------------------------------------------------

# icacls short rights -> the exact FileSystemRights masks Get-Acl reports for them
$script:AclRightMasks = [ordered]@{ F = 0x1F01FF; M = 0x1301BF; RX = 0x1200A9; R = 0x120089; DC = 0x40; DE = 0x10000 }
# any write, delete, permission-change or owner right, plus the GENERIC_ALL / GENERIC_WRITE bits an
# inherit-only ACE carries unexpanded (the same mask Assert-CoderQueueAclTight uses)
# the read-and-run bits: what a write-capable entry keeps when its write is taken away (a generic read or execute bit counts)
$script:AclReadKeepMask = [int64]0x1200A9
$script:AclWriteMask = [int64](2 + 4 + 16 + 64 + 256 + 65536 + 262144 + 524288 + 0x10000000 + 0x40000000)

function Get-AclRightName {
    param([Parameter(Mandatory)][int64]$Mask)
    foreach ($k in $script:AclRightMasks.Keys) { if ([int64]$script:AclRightMasks[$k] -eq $Mask) { return $k } }
    return ('custom:0x{0:X}' -f $Mask)
}

function ConvertTo-AceFlags {
    # canonical flag string, order OI CI IO NP, from the .NET InheritanceFlags / PropagationFlags integers
    param([int]$Inheritance, [int]$Propagation)
    $s = ''
    if ($Inheritance -band 2) { $s += '(OI)' }
    if ($Inheritance -band 1) { $s += '(CI)' }
    if ($Propagation -band 2) { $s += '(IO)' }
    if ($Propagation -band 1) { $s += '(NP)' }
    return $s
}

function New-Ace {
    param([string]$Sid, [string]$Type = 'Allow', [string]$Rights, [string]$Flags = '', [bool]$Inherited = $false, [int64]$Mask = 0, [bool]$Orphan = $false, [string]$Name = '')
    if ($Mask -eq 0 -and $script:AclRightMasks.Contains($Rights)) { $Mask = [int64]$script:AclRightMasks[$Rights] }
    if ($Mask -eq 0 -and $Rights -like 'custom:0x*') { $Mask = [Convert]::ToInt64($Rights.Substring(9), 16) }
    if (-not $Rights) { $Rights = Get-AclRightName -Mask $Mask }
    [pscustomobject]@{ Sid = $Sid; Type = $Type; Rights = $Rights; Mask = $Mask; Flags = $Flags; Inherited = $Inherited; Orphan = $Orphan; Name = $Name }
}

function Read-AclState {
    # The real ACL of a path as the model: @{ Path; Owner; Protected; Aces[] }. Orphan = the identity could
    # not be translated to an account name (Get-Acl then hands back the bare SID).
    param([Parameter(Mandatory)][string]$Path)
    $acl = Get-Acl -LiteralPath $Path -ErrorAction Stop
    $owner = $null
    try { $owner = [string]$acl.GetOwner([Security.Principal.SecurityIdentifier]).Value } catch { $owner = $null }
    $aces = New-Object System.Collections.ArrayList
    foreach ($r in $acl.Access) {
        $ref = $r.IdentityReference
        $sid = $null; $name = ''; $orphan = $false
        if ($ref -is [Security.Principal.SecurityIdentifier]) { $sid = $ref.Value; $orphan = $true; $name = $ref.Value }
        else {
            $name = [string]$ref.Value
            try { $sid = $ref.Translate([Security.Principal.SecurityIdentifier]).Value } catch { $sid = $null; $orphan = $true }
        }
        $mask = [int64]([int]$r.FileSystemRights) -band 0xFFFFFFFFL
        [void]$aces.Add((New-Ace -Sid $sid -Type ([string]$r.AccessControlType) -Mask $mask `
                -Flags (ConvertTo-AceFlags -Inheritance ([int]$r.InheritanceFlags) -Propagation ([int]$r.PropagationFlags)) `
                -Inherited ([bool]$r.IsInherited) -Orphan $orphan -Name $name))
    }
    [pscustomobject]@{ Path = $Path; Owner = $owner; Protected = [bool]$acl.AreAccessRulesProtected; Aces = @($aces) }
}

function Copy-AclState {
    param([Parameter(Mandatory)]$State)
    [pscustomobject]@{ Path = $State.Path; Owner = $State.Owner; Protected = [bool]$State.Protected
        Aces = @($State.Aces | ForEach-Object { New-Ace -Sid $_.Sid -Type $_.Type -Rights $_.Rights -Flags $_.Flags -Inherited ([bool]$_.Inherited) -Mask ([int64]$_.Mask) -Orphan ([bool]$_.Orphan) -Name $_.Name }) }
}

function Test-AceWriteCapable {
    param([Parameter(Mandatory)]$Ace)
    return (([int64]$Ace.Mask -band $script:AclWriteMask) -ne 0)
}

# ---- operations and the simulator -----------------------------------------------------------------------

function New-AclOp {
    # Op = DisableInheritanceCopy | EnableInheritance | RemoveGrants | RemoveDenies | SetGrant | AddGrant | Deny
    param([Parameter(Mandatory)][ValidateSet('DisableInheritanceCopy', 'EnableInheritance', 'RemoveGrants', 'RemoveDenies', 'SetGrant', 'AddGrant', 'Deny')][string]$Op,
          [string]$Sid = '', [string]$Rights = '', [string]$Flags = '', [switch]$Tree)
    @{ Op = $Op; Sid = $Sid; Rights = $Rights; Flags = $Flags; Tree = [bool]$Tree }
}

function ConvertTo-AceFlagSet {
    # inheritance flags as the set of places an entry applies: this folder, subfolders, files. $null for NP (not merged).
    param([string]$Flags)
    if ($Flags -match '\(NP\)') { return $null }
    $io = ($Flags -match '\(IO\)')
    return @{ Self = (-not $io); CI = ($Flags -match '\(CI\)'); OI = ($Flags -match '\(OI\)') }
}

function ConvertFrom-AceFlagSet {
    param($Set)
    $f = ''
    if ($Set.OI) { $f += '(OI)' }
    if ($Set.CI) { $f += '(CI)' }
    if (-not $Set.Self) { $f += '(IO)' }
    if (-not $Set.OI -and -not $Set.CI) { return '' }
    return $f
}

function Merge-AclAllowEntries {
    # Windows merges explicit Allow entries of the same account and rights whose scopes can be joined (this folder +
    # inherit-only subfolders become one entry for folder and subfolders). The simulator does the same, so the
    # computed AFTER is the list the machine really holds. Entries with NP are left alone.
    param([Parameter(Mandatory)][object[]]$Aces)
    $out = New-Object System.Collections.ArrayList
    $done = @{}
    for ($i = 0; $i -lt $Aces.Count; $i++) {
        if ($done.ContainsKey($i)) { continue }
        $a = $Aces[$i]
        $set = if ($a.Type -eq 'Allow' -and -not $a.Inherited) { ConvertTo-AceFlagSet -Flags $a.Flags } else { $null }
        if ($null -eq $set) { [void]$out.Add($a); continue }
        $union = @{ Self = $set.Self; CI = $set.CI; OI = $set.OI }
        for ($j = $i + 1; $j -lt $Aces.Count; $j++) {
            $b = $Aces[$j]
            if ($b.Type -ne 'Allow' -or $b.Inherited -or $b.Sid -ne $a.Sid -or [int64]$b.Mask -ne [int64]$a.Mask) { continue }
            $sb = ConvertTo-AceFlagSet -Flags $b.Flags
            if ($null -eq $sb) { continue }
            $union.Self = $union.Self -or $sb.Self; $union.CI = $union.CI -or $sb.CI; $union.OI = $union.OI -or $sb.OI
            $done[$j] = $true
        }
        $merged = New-Ace -Sid $a.Sid -Type 'Allow' -Rights $a.Rights -Flags (ConvertFrom-AceFlagSet -Set $union) -Mask ([int64]$a.Mask) -Orphan ([bool]$a.Orphan) -Name $a.Name
        [void]$out.Add($merged)
    }
    return @($out)
}

function Invoke-AclSimulation {
    # PURE. Apply ONE op to a state and return the new state (the input is not modified). Mirrors icacls:
    #   /inheritance:d  inherited ACEs become explicit and inheritance stops;
    #   /remove:g, /remove:d  remove the EXPLICIT grant / deny ACEs of the SID (inherited ones stay);
    #   /grant:r  replaces the SID's explicit grants with the one named; /grant adds one without replacing;
    #   /deny  adds a deny ACE.
    # EnableInheritance needs the parent's ACL and is not simulated (it only appears in rollback listings).
    param([Parameter(Mandatory)]$State, [Parameter(Mandatory)]$Op)
    $s = Copy-AclState -State $State
    $aces = @($s.Aces)
    switch ($Op.Op) {
        'DisableInheritanceCopy' { foreach ($a in $aces) { $a.Inherited = $false }; $s.Protected = $true }
        'RemoveGrants' { $aces = @($aces | Where-Object { -not ($_.Type -eq 'Allow' -and -not $_.Inherited -and $_.Sid -eq $Op.Sid) }) }
        'RemoveDenies' { $aces = @($aces | Where-Object { -not ($_.Type -eq 'Deny' -and -not $_.Inherited -and $_.Sid -eq $Op.Sid) }) }
        'SetGrant' {
            $aces = @($aces | Where-Object { -not ($_.Type -eq 'Allow' -and -not $_.Inherited -and $_.Sid -eq $Op.Sid) })
            $aces = @($aces) + @(New-Ace -Sid $Op.Sid -Type 'Allow' -Rights $Op.Rights -Flags $Op.Flags)
            $aces = @(Merge-AclAllowEntries -Aces $aces)
        }
        'AddGrant' {
            # Windows folds a new entry into an existing explicit entry of the same account and the same flags (its
            # rights are OR-ed in): a Modify added next to an existing Full control with the same flags changes nothing
            $new = New-Ace -Sid $Op.Sid -Type 'Allow' -Rights $Op.Rights -Flags $Op.Flags
            $idx = -1
            for ($k = 0; $k -lt $aces.Count; $k++) { if ($aces[$k].Type -eq 'Allow' -and -not $aces[$k].Inherited -and $aces[$k].Sid -eq $Op.Sid -and $aces[$k].Flags -eq $Op.Flags) { $idx = $k; break } }
            if ($idx -ge 0) {
                $union = [int64]$aces[$idx].Mask -bor [int64]$new.Mask
                if ($union -ne [int64]$aces[$idx].Mask) { $aces[$idx] = New-Ace -Sid $Op.Sid -Type 'Allow' -Mask $union -Flags $Op.Flags -Name $aces[$idx].Name }
            } else { $aces = @($aces) + @($new) }
            $aces = @(Merge-AclAllowEntries -Aces $aces)
        }
        'Deny' {
            $dup = @($aces | Where-Object { $_.Type -eq 'Deny' -and -not $_.Inherited -and $_.Sid -eq $Op.Sid -and $_.Rights -eq $Op.Rights -and $_.Flags -eq $Op.Flags })
            if ($dup.Count -eq 0) { $aces = @(New-Ace -Sid $Op.Sid -Type 'Deny' -Rights $Op.Rights -Flags $Op.Flags) + @($aces) }
        }
        'EnableInheritance' { throw 'EnableInheritance is a rollback-only operation and is not simulated (it depends on the parent ACL).' }
    }
    $s.Aces = @($aces)
    return $s
}

function ConvertTo-IcaclsRightsText {
    # icacls rights for the (...) part: a short name (F, M, RX, R, DC, DE) as is; 'custom:0xMASK' becomes the
    # comma list of specific rights icacls accepts (RD,WD,AD,REA,WEA,X,DC,RA,WA,D,RC,WDAC,WO,S).
    param([Parameter(Mandatory)][string]$Rights)
    if ($Rights -notlike 'custom:0x*') { return $Rights }
    $m = [Convert]::ToInt64($Rights.Substring(9), 16)
    $bits = [ordered]@{ RD = 0x1; WD = 0x2; AD = 0x4; REA = 0x8; WEA = 0x10; X = 0x20; DC = 0x40; RA = 0x80; WA = 0x100; D = 0x10000; RC = 0x20000; WDAC = 0x40000; WO = 0x80000; S = 0x100000 }
    $out = @(); foreach ($k in $bits.Keys) { if (($m -band $bits[$k]) -ne 0) { $out += $k } }
    if ($out.Count -eq 0) { throw "rights mask $Rights has no bit icacls can express" }
    return ($out -join ',')
}

function ConvertTo-IcaclsCommand {
    # The exact icacls argument vector for one op on one path. A TREE op is not run as one icacls /T call (see
    # SAFETY above): this is the command for ONE object of the tree, which the no-follow walk runs per object.
    # SIDs go in the *S-1-... form (no name lookup, language independent).
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)]$Op)
    $sidArg = "*$($Op.Sid)"
    $a = New-Object System.Collections.ArrayList
    [void]$a.Add($Path)
    switch ($Op.Op) {
        'DisableInheritanceCopy' { [void]$a.Add('/inheritance:d') }
        'EnableInheritance'      { [void]$a.Add('/inheritance:e') }
        'RemoveGrants'           { [void]$a.Add('/remove:g'); [void]$a.Add($sidArg) }
        'RemoveDenies'           { [void]$a.Add('/remove:d'); [void]$a.Add($sidArg) }
        'SetGrant'               { [void]$a.Add('/grant:r'); [void]$a.Add("${sidArg}:$($Op.Flags)($(ConvertTo-IcaclsRightsText $Op.Rights))") }
        'AddGrant'               { [void]$a.Add('/grant');   [void]$a.Add("${sidArg}:$($Op.Flags)($(ConvertTo-IcaclsRightsText $Op.Rights))") }
        'Deny'                   { [void]$a.Add('/deny');    [void]$a.Add("${sidArg}:$($Op.Flags)($(ConvertTo-IcaclsRightsText $Op.Rights))") }
    }
    return @($a)
}

function Format-IcaclsText {
    param([Parameter(Mandatory)][string[]]$IcaclsArgs)
    $parts = $IcaclsArgs | ForEach-Object { if ($_ -match '[\s]') { '"' + $_ + '"' } else { $_ } }
    return 'icacls ' + ($parts -join ' ')
}

# ---- the no-follow tree walk -------------------------------------------------------------------------------

$script:AclTestHook = $null        # tests only: @{ BeforeOpen = { param($p) }; AfterOpen = { param($p) } }
$script:AclWalkRootFinal = ''     # while a walk runs: the resolved path of its root; every object must resolve under it

$script:HandleAclTypeLoaded = $false
function Initialize-HandleAclType {
    if ($script:HandleAclTypeLoaded -or ('BlarHandleAcl' -as [type])) { $script:HandleAclTypeLoaded = $true; return }
    Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
using System.Text;
using Microsoft.Win32.SafeHandles;
public sealed class BlarOpenResult { public SafeFileHandle Handle; public string Refusal = ""; }
public static class BlarHandleAcl {
    const uint READ_CONTROL = 0x20000, WRITE_DAC = 0x40000, FILE_READ_DATA = 0x1, FILE_READ_ATTRIBUTES = 0x80;
    const uint FILE_SHARE_READ = 1, FILE_SHARE_WRITE = 2, OPEN_EXISTING = 3;
    const uint FILE_FLAG_BACKUP_SEMANTICS = 0x02000000, FILE_FLAG_OPEN_REPARSE_POINT = 0x00200000;
    const uint FILE_ATTRIBUTE_REPARSE_POINT = 0x400, FILE_ATTRIBUTE_DIRECTORY = 0x10;
    const int SE_FILE_OBJECT = 1;
    const uint DACL_SECURITY_INFORMATION = 4, PROTECTED_DACL = 0x80000000, UNPROTECTED_DACL = 0x20000000;
    [StructLayout(LayoutKind.Sequential)]
    struct BY_HANDLE_FILE_INFORMATION { public uint dwFileAttributes; public System.Runtime.InteropServices.ComTypes.FILETIME ftCreationTime, ftLastAccessTime, ftLastWriteTime; public uint dwVolumeSerialNumber, nFileSizeHigh, nFileSizeLow, nNumberOfLinks, nFileIndexHigh, nFileIndexLow; }
    [DllImport("kernel32.dll", SetLastError = true, CharSet = CharSet.Unicode)] static extern SafeFileHandle CreateFileW(string name, uint access, uint share, IntPtr sa, uint disp, uint flags, IntPtr tmpl);
    [DllImport("kernel32.dll", SetLastError = true)] static extern bool GetFileInformationByHandle(SafeFileHandle h, out BY_HANDLE_FILE_INFORMATION info);
    [DllImport("kernel32.dll", SetLastError = true, CharSet = CharSet.Unicode)] static extern uint GetFinalPathNameByHandleW(SafeFileHandle h, StringBuilder sb, uint len, uint flags);
    [DllImport("kernel32.dll", SetLastError = true, CharSet = CharSet.Unicode)] static extern uint GetLongPathNameW(string shortPath, StringBuilder sb, uint len);
    [DllImport("kernel32.dll")] static extern IntPtr LocalFree(IntPtr p);
    [DllImport("advapi32.dll", SetLastError = true)] static extern uint GetSecurityInfo(SafeFileHandle h, int objType, uint info, out IntPtr owner, IntPtr group, IntPtr dacl, IntPtr sacl, out IntPtr sd);
    [DllImport("advapi32.dll", SetLastError = true, CharSet = CharSet.Unicode)] static extern bool ConvertSidToStringSidW(IntPtr sid, out IntPtr str);
    [DllImport("advapi32.dll", SetLastError = true)] static extern uint GetSecurityInfo(SafeFileHandle h, int objType, uint info, IntPtr owner, IntPtr group, out IntPtr dacl, IntPtr sacl, out IntPtr sd);
    [DllImport("advapi32.dll", SetLastError = true)] static extern uint SetSecurityInfo(SafeFileHandle h, int objType, uint info, IntPtr owner, IntPtr group, IntPtr dacl, IntPtr sacl);
    [DllImport("advapi32.dll", SetLastError = true, CharSet = CharSet.Unicode)] static extern bool ConvertSecurityDescriptorToStringSecurityDescriptorW(IntPtr sd, uint rev, uint info, out IntPtr str, out uint len);
    [DllImport("advapi32.dll", SetLastError = true, CharSet = CharSet.Unicode)] static extern bool ConvertStringSecurityDescriptorToSecurityDescriptorW(string s, uint rev, out IntPtr sd, out uint len);
    [DllImport("advapi32.dll", SetLastError = true)] static extern bool GetSecurityDescriptorDacl(IntPtr sd, out bool present, out IntPtr dacl, out bool defaulted);
    [DllImport("advapi32.dll", SetLastError = true)] static extern bool GetSecurityDescriptorControl(IntPtr sd, out ushort control, out uint rev);

    // Open the object ITSELF (a final link is opened as a link, never followed), check on THAT handle that it is not
    // a link and is the kind of object expected. wantWrite adds WRITE_DAC. READ_DATA is requested and FILE_SHARE_DELETE
    // is not granted: a rename or delete of the object needs DELETE access, which then conflicts with this handle's
    // share mode, so while the handle is held the object itself cannot be renamed or replaced (sharing is only
    // enforced against data/delete access, so READ_CONTROL alone would not hold it).
    public static BlarOpenResult Open(string path, bool wantDir, bool wantWrite) {
        BlarOpenResult r = new BlarOpenResult();
        // a path of 240 characters or more needs the extended-length form for CreateFile (win32 error 3 otherwise)
        string p = (path.Length >= 240 && path.Length > 2 && path[1] == ':') ? @"\\?\" + path : path;
        SafeFileHandle h = CreateFileW(p, READ_CONTROL | FILE_READ_DATA | FILE_READ_ATTRIBUTES | (wantWrite ? WRITE_DAC : 0), FILE_SHARE_READ | FILE_SHARE_WRITE, IntPtr.Zero, OPEN_EXISTING, FILE_FLAG_BACKUP_SEMANTICS | FILE_FLAG_OPEN_REPARSE_POINT, IntPtr.Zero);
        if (h.IsInvalid) { r.Refusal = "cannot open (win32 error " + Marshal.GetLastWin32Error() + ")"; return r; }
        string why = CheckType(h, wantDir);
        if (why != null) { h.Dispose(); r.Refusal = why; return r; }
        r.Handle = h; return r;
    }
    public static string CheckType(SafeFileHandle h, bool wantDir) {
        BY_HANDLE_FILE_INFORMATION fi;
        if (!GetFileInformationByHandle(h, out fi)) return "cannot read the attributes of the open handle";
        if ((fi.dwFileAttributes & FILE_ATTRIBUTE_REPARSE_POINT) != 0) return "the entry is a link (junction or symlink): it was swapped or is one";
        bool isDir = (fi.dwFileAttributes & FILE_ATTRIBUTE_DIRECTORY) != 0;
        if (isDir != wantDir) return "the entry changed kind (folder/file)";
        return null;
    }
    public static string FinalPath(SafeFileHandle h) {
        StringBuilder sb = new StringBuilder(8192);
        uint n = GetFinalPathNameByHandleW(h, sb, 8192, 0);
        if (n == 0 || n >= 8192) throw new System.ComponentModel.Win32Exception(Marshal.GetLastWin32Error(), "GetFinalPathNameByHandle");
        string s = sb.ToString();
        if (s.StartsWith(@"\\?\UNC\", StringComparison.Ordinal)) return @"\\" + s.Substring(8);
        if (s.StartsWith(@"\\?\", StringComparison.Ordinal)) return s.Substring(4);
        return s;
    }
    public static string LongPath(string p) {
        StringBuilder sb = new StringBuilder(2048);
        uint n = GetLongPathNameW(p, sb, 2048);
        if (n == 0 || n >= 2048) return p;
        return sb.ToString();
    }
    public static string GetOwnerSid(SafeFileHandle h) {
        IntPtr owner, sd;
        uint e = GetSecurityInfo(h, SE_FILE_OBJECT, 1, out owner, IntPtr.Zero, IntPtr.Zero, IntPtr.Zero, out sd);
        if (e != 0) throw new System.ComponentModel.Win32Exception((int)e, "GetSecurityInfo(owner)");
        try {
            IntPtr str;
            if (!ConvertSidToStringSidW(owner, out str)) throw new System.ComponentModel.Win32Exception(Marshal.GetLastWin32Error(), "ConvertSidToStringSid");
            try { return Marshal.PtrToStringUni(str); } finally { LocalFree(str); }
        } finally { LocalFree(sd); }
    }
    public static string GetSddl(SafeFileHandle h) {
        IntPtr dacl, sd;
        uint e = GetSecurityInfo(h, SE_FILE_OBJECT, DACL_SECURITY_INFORMATION, IntPtr.Zero, IntPtr.Zero, out dacl, IntPtr.Zero, out sd);
        if (e != 0) throw new System.ComponentModel.Win32Exception((int)e, "GetSecurityInfo");
        try {
            IntPtr str; uint len;
            if (!ConvertSecurityDescriptorToStringSecurityDescriptorW(sd, 1, DACL_SECURITY_INFORMATION, out str, out len)) throw new System.ComponentModel.Win32Exception(Marshal.GetLastWin32Error(), "ConvertSecurityDescriptorToString");
            try { return Marshal.PtrToStringUni(str); } finally { LocalFree(str); }
        } finally { LocalFree(sd); }
    }
    public static void SetSddl(SafeFileHandle h, string sddl) {
        IntPtr sd; uint len;
        if (!ConvertStringSecurityDescriptorToSecurityDescriptorW(sddl, 1, out sd, out len)) throw new System.ComponentModel.Win32Exception(Marshal.GetLastWin32Error(), "ConvertStringToSecurityDescriptor");
        try {
            bool present, defaulted; IntPtr dacl;
            if (!GetSecurityDescriptorDacl(sd, out present, out dacl, out defaulted)) throw new System.ComponentModel.Win32Exception(Marshal.GetLastWin32Error(), "GetSecurityDescriptorDacl");
            ushort control; uint rev;
            if (!GetSecurityDescriptorControl(sd, out control, out rev)) throw new System.ComponentModel.Win32Exception(Marshal.GetLastWin32Error(), "GetSecurityDescriptorControl");
            uint info = DACL_SECURITY_INFORMATION | (((control & 0x1000) != 0) ? PROTECTED_DACL : UNPROTECTED_DACL);
            uint e = SetSecurityInfo(h, SE_FILE_OBJECT, info, IntPtr.Zero, IntPtr.Zero, dacl, IntPtr.Zero);
            if (e != 0) throw new System.ComponentModel.Win32Exception((int)e, "SetSecurityInfo");
        } finally { LocalFree(sd); }
    }
}
'@
    $script:HandleAclTypeLoaded = $true
}

function Test-FinalPathInside {
    param([string]$Final, [string]$Root)
    $r = $Root.TrimEnd('\')
    return ($Final.TrimEnd('\') -ieq $r) -or $Final.StartsWith($r + '\', [StringComparison]::OrdinalIgnoreCase)
}

function Get-AclFinalPath {
    # where -Path really is: opened without following a final link, resolved through the handle
    param([Parameter(Mandatory)][string]$Path, [bool]$IsDir = $true)
    Initialize-HandleAclType
    $r = [BlarHandleAcl]::Open($Path, $IsDir, $false)
    if ($null -eq $r.Handle) { throw "cannot open '$Path': $($r.Refusal)" }
    try { return [BlarHandleAcl]::FinalPath($r.Handle) } finally { $r.Handle.Dispose() }
}

function Open-AclHandle {
    # THE one door for changing or saving an access list by path. Opens the object itself, checks on the open
    # handle that it is not a link and is the expected kind, and that it RESOLVES under the walk root (or, with no
    # walk, is exactly -Path): a path component swapped for a link, or an object moved out, ends here. The caller
    # reads and writes through the SAME handle, so nothing can be swapped between the check and the change.
    # Returns the open handle; throws (fail closed) on anything unexpected.
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)][bool]$IsDir, [Parameter(Mandatory)][bool]$Write)
    Initialize-HandleAclType
    if ($script:AclTestHook -and $script:AclTestHook.BeforeOpen) { & $script:AclTestHook.BeforeOpen $Path }
    $r = [BlarHandleAcl]::Open($Path, $IsDir, $Write)
    if ($null -eq $r.Handle) { throw "refusing '$Path': $($r.Refusal)" }
    $h = $r.Handle
    try {
        if ($script:AclTestHook -and $script:AclTestHook.AfterOpen) { & $script:AclTestHook.AfterOpen $Path }
        $final = [BlarHandleAcl]::FinalPath($h)
        $ok = if ($script:AclWalkRootFinal) { Test-FinalPathInside -Final $final -Root $script:AclWalkRootFinal } else { ($final.TrimEnd('\') -ieq ([BlarHandleAcl]::LongPath([IO.Path]::GetFullPath($Path))).TrimEnd('\')) }
        if (-not $ok) { throw "refusing '$Path': it resolves to '$final', outside $(if ($script:AclWalkRootFinal) { "the tree '$($script:AclWalkRootFinal)'" } else { 'itself' })" }
        $why = [BlarHandleAcl]::CheckType($h, $IsDir)
        if ($why) { throw "refusing '$Path': $why" }
        return $h
    } catch { $h.Dispose(); throw }
}

function Invoke-AclHandleEdit {
    # Open (checked), read the access list from the handle, run -Edit { param($security) ... $true if changed } on
    # a security object built from it, and write it back through the same handle. Returns $true if it changed.
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)][bool]$IsDir, [Parameter(Mandatory)][scriptblock]$Edit)
    $h = Open-AclHandle -Path $Path -IsDir $IsDir -Write $true
    try {
        $sec = if ($IsDir) { New-Object Security.AccessControl.DirectorySecurity } else { New-Object Security.AccessControl.FileSecurity }
        $sec.SetSecurityDescriptorSddlForm([BlarHandleAcl]::GetSddl($h), [Security.AccessControl.AccessControlSections]::Access)
        $changed = [bool](& $Edit $sec)
        if ($changed) { [BlarHandleAcl]::SetSddl($h, $sec.GetSecurityDescriptorSddlForm([Security.AccessControl.AccessControlSections]::Access)) }
        return $changed
    } finally { $h.Dispose() }
}

function Get-AclSddlAndOwnerChecked {
    # one checked open: the access list (SDDL) and the owner SID string
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)][bool]$IsDir)
    $h = Open-AclHandle -Path $Path -IsDir $IsDir -Write $false
    try { return @{ Sddl = [BlarHandleAcl]::GetSddl($h); Owner = [BlarHandleAcl]::GetOwnerSid($h) } } finally { $h.Dispose() }
}

function Get-AclSddlChecked {
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)][bool]$IsDir)
    $h = Open-AclHandle -Path $Path -IsDir $IsDir -Write $false
    try { return [BlarHandleAcl]::GetSddl($h) } finally { $h.Dispose() }
}

function Invoke-NoFollowWalk {
    # Walk -Root: the root, every folder below it and every file, calling -OnObject { param($Path, $IsDir) } for
    # each. A link (junction or symlink, file or folder) found at listing time is NEVER entered, touched or passed to
    # -OnObject: it is collected in .Links. Returns @{ Visited; Links[]; Errors[] }. Pre-order.
    # Listing classifies an entry by path; the CHANGE is made by the callbacks through Open-AclHandle, which
    # re-checks the object on its own open handle and that it resolves under this root (see "Residual" in the
    # decisions record). While the walk runs $script:AclWalkRootFinal holds the root's resolved path.
    param([Parameter(Mandatory)][string]$Root, [Parameter(Mandatory)][scriptblock]$OnObject, [int]$ProgressEvery = 0, [scriptblock]$Out = $null)
    $res = @{ Visited = 0; Links = (New-Object System.Collections.ArrayList); Errors = (New-Object System.Collections.ArrayList) }
    $prevRoot = $script:AclWalkRootFinal
    try { $script:AclWalkRootFinal = (Get-AclFinalPath -Path $Root -IsDir $true) }
    catch { $script:AclWalkRootFinal = $prevRoot; throw "the walk root '$Root' cannot be opened without following a link: $($_.Exception.Message)" }
    try {
        $stack = New-Object 'System.Collections.Generic.Stack[string]'
        $stack.Push($Root)
        while ($stack.Count -gt 0) {
            $d = $stack.Pop()
            try { & $OnObject $d $true; $res.Visited++ } catch { [void]$res.Errors.Add("$d : $($_.Exception.Message)"); continue }
            if ($ProgressEvery -gt 0 -and $Out -and ($res.Visited % $ProgressEvery) -lt 1) { & $Out "      ... $($res.Visited) objects" }
            $entries = $null
            try { $entries = @([IO.Directory]::EnumerateFileSystemEntries($d)) } catch { [void]$res.Errors.Add("$d : cannot list: $($_.Exception.Message)"); continue }
            $subdirs = New-Object System.Collections.ArrayList
            foreach ($e in $entries) {
                $attr = $null
                try { $attr = [IO.File]::GetAttributes($e) } catch { [void]$res.Errors.Add("$e : $($_.Exception.Message)"); continue }
                if ($attr -band [IO.FileAttributes]::ReparsePoint) { [void]$res.Links.Add($e); continue }
                if ($attr -band [IO.FileAttributes]::Directory) { [void]$subdirs.Add($e); continue }
                try { & $OnObject $e $false; $res.Visited++ } catch { [void]$res.Errors.Add("$e : $($_.Exception.Message)") }
                if ($ProgressEvery -gt 0 -and $Out -and ($res.Visited % $ProgressEvery) -lt 1) { & $Out "      ... $($res.Visited) objects" }
            }
            for ($i = $subdirs.Count - 1; $i -ge 0; $i--) { $stack.Push([string]$subdirs[$i]) }
        }
    } finally { $script:AclWalkRootFinal = $prevRoot }
    $res.Links = @($res.Links); $res.Errors = @($res.Errors)
    return $res
}

function Remove-ExplicitGrantOfSid {
    # The per-object form of icacls /remove:g (or /remove:d with -Type Deny): drop the EXPLICIT entries of one SID
    # on one object (inherited entries stay), through one checked open handle. Only the access list is read and
    # written (never owner or group). Returns $true if it changed.
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)][bool]$IsDir, [Parameter(Mandatory)][string]$Sid, [ValidateSet('Allow', 'Deny')][string]$Type = 'Allow')
    return (Invoke-AclHandleEdit -Path $Path -IsDir $IsDir -Edit {
        param($acl)
        $changed = $false
        foreach ($rule in @($acl.GetAccessRules($true, $false, [Security.Principal.SecurityIdentifier]))) {
            if ($rule.IdentityReference.Value -eq $Sid -and [string]$rule.AccessControlType -eq $Type) {
                [void]$acl.RemoveAccessRuleSpecific($rule); $changed = $true
            }
        }
        return $changed
    })
}

function Invoke-AclTreeRemoveGrants {
    # RemoveGrants over a whole tree, without following links. Returns the walk result plus .Changed.
    param([Parameter(Mandatory)][string]$Root, [Parameter(Mandatory)][string]$Sid, [scriptblock]$Out = $null, [ValidateSet('Allow', 'Deny')][string]$Type = 'Allow')
    $script:__changed = 0
    $w = Invoke-NoFollowWalk -Root $Root -ProgressEvery 20000 -Out $Out -OnObject {
        param($p, $isDir)
        if (Remove-ExplicitGrantOfSid -Path $p -IsDir $isDir -Sid $Sid -Type $Type) { $script:__changed++ }
    }
    $w.Changed = $script:__changed
    return $w
}

function Get-CoderGroupInfo {
    # The groups the coder account can hold, by SID, and what could not be determined. Two sources:
    #  1. every well-known group a local account's token can carry: Everyone, Authenticated Users, BUILTIN\Users,
    #     NT AUTHORITY\Local account (S-1-5-113), This Organization (S-1-5-15), and the logon-type groups (BATCH for a
    #     scheduled-task logon, INTERACTIVE, NETWORK, LOCAL). A write entry for any of them is write access for the coder.
    #  2. every local group that lists the account as a member.
    # Nothing is hidden: a failed lookup is returned in .Errors, and the stage treats an unknown group as a finding
    # (group-based write access cannot be excluded). -Lookup is a test seam: { param($sid) @{ Sids = @(); Errors = @() } }.
    param([string]$CoderUser = 'blarai-coder', [string]$CoderSid = '', [scriptblock]$Lookup = $null)
    $sids = @('S-1-1-0', 'S-1-5-11', 'S-1-5-32-545', 'S-1-5-113', 'S-1-5-15', 'S-1-5-3', 'S-1-5-4', 'S-1-5-2', 'S-1-2-0')
    $errors = New-Object System.Collections.ArrayList
    if (-not $CoderSid) { [void]$errors.Add('the coder SID is not known, so its local group memberships could not be read') }
    else {
        try {
            if ($Lookup) { $r = & $Lookup $CoderSid; $sids += @($r.Sids); foreach ($e in @($r.Errors)) { [void]$errors.Add([string]$e) } }
            else {
                foreach ($g in @(Get-LocalGroup -ErrorAction Stop)) {
                    try {
                        $hit = @(Get-LocalGroupMember -Group $g -ErrorAction Stop | Where-Object { $_.SID.Value -eq $CoderSid })
                        if ($hit.Count -gt 0) { $sids += $g.SID.Value }
                    } catch { [void]$errors.Add("local group '$($g.Name)': $($_.Exception.Message)") }
                }
            }
        } catch { [void]$errors.Add("the local group lookup failed: $($_.Exception.Message)") }
    }
    return @{ Sids = @($sids | Sort-Object -Unique); Errors = @($errors) }
}

function Get-CoderGroupSids {
    # the SIDs only (see Get-CoderGroupInfo for the errors)
    param([string]$CoderUser = 'blarai-coder', [string]$CoderSid = '')
    return @((Get-CoderGroupInfo -CoderUser $CoderUser -CoderSid $CoderSid).Sids)
}

function Find-SidWriteAcesTree {
    # Read-only full no-follow walk: every object where -Sid (the coder) or any of -GroupSids (the groups it belongs
    # to) holds a write-capable Allow entry (explicit or inherited), and every object OWNED by -Sid (an owner can
    # change the object's own access list). Each hit is @{ Path; Why; Kind } with Kind coder | group | owner. The
    # direct check of what the coder can actually do, not only of what names it.
    # Returns @{ Hits[]; Visited; Links[]; Errors[] }.
    param([Parameter(Mandatory)][string]$Root, [Parameter(Mandatory)][string]$Sid, [string[]]$GroupSids = @(), [switch]$CheckOwner, [int]$MaxHits = 50, [scriptblock]$Out = $null)
    $hits = New-Object System.Collections.ArrayList
    $w = Invoke-NoFollowWalk -Root $Root -ProgressEvery 20000 -Out $Out -OnObject {
        param($p, $isDir)
        $got = Get-AclSddlAndOwnerChecked -Path $p -IsDir $isDir
        $acl = if ($isDir) { New-Object Security.AccessControl.DirectorySecurity } else { New-Object Security.AccessControl.FileSecurity }
        $acl.SetSecurityDescriptorSddlForm($got.Sddl, [Security.AccessControl.AccessControlSections]::Access)
        foreach ($rule in @($acl.GetAccessRules($true, $true, [Security.Principal.SecurityIdentifier]))) {
            $rs = $rule.IdentityReference.Value
            $kind = if ($rs -eq $Sid) { 'coder' } elseif ($GroupSids -contains $rs) { 'group' } else { '' }
            if ($kind -and $rule.AccessControlType -eq [Security.AccessControl.AccessControlType]::Allow -and (([int64]([int]$rule.FileSystemRights) -band 0xFFFFFFFFL -band $script:AclWriteMask) -ne 0)) {
                if ($hits.Count -lt $MaxHits) { [void]$hits.Add(@{ Path = $p; Kind = $kind; Why = "$([string]$rule.FileSystemRights)$(if ($rule.IsInherited) { ' (inherited)' } else { '' }) for $(if ($kind -eq 'group') { "the group $rs" } else { 'the coder' })" }) }
            }
        }
        if ($CheckOwner -and $got.Owner -eq $Sid -and $hits.Count -lt $MaxHits) { [void]$hits.Add(@{ Path = $p; Kind = 'owner'; Why = 'owned by the coder (an owner can change the access list of its own object)' }) }
    }
    return @{ Hits = @($hits); Visited = $w.Visited; Links = $w.Links; Errors = $w.Errors }
}

# ---- the safe-target gate -------------------------------------------------------------------------------

function ConvertTo-NormalizedAclPath {
    # One canonical spelling of a drive-absolute path, for comparing with the forbidden list and for the link walk:
    # trailing dots and spaces stripped from every component (Windows ignores them), single-dot segments dropped,
    # GetFullPath, 8.3 short names expanded (GetLongPathName), trailing backslash stripped. Case is NOT folded here
    # (compare with -ieq). The caller has already refused device and extended-length prefixes, wildcards and dot-dot.
    param([Parameter(Mandatory)][string]$Path)
    Initialize-HandleAclType
    $parts = @($Path -split '[\\/]+')
    $drive = $parts[0]
    $rest = @($parts | Select-Object -Skip 1 | ForEach-Object { $_.TrimEnd('.', ' ') } | Where-Object { $_ -ne '' })
    $rebuilt = $drive + '\' + ($rest -join '\')
    return ([BlarHandleAcl]::LongPath([IO.Path]::GetFullPath($rebuilt))).TrimEnd('\')
}

$script:AclAllowTempRoot = $false   # TESTS ONLY: allow targets under the profile's temp folder. Never set by any script that changes real folders.

function Get-AclForbiddenRules {
    # What this stage never touches, in the canonical spelling of ConvertTo-NormalizedAclPath. Exact: C:\Users and
    # the profile root. Prefix (the folder and everything below it): the system folders, the profile's secret and
    # application-data folders (the temp folder is carved out: it is scratch space), and every OTHER user's profile.
    $profileRoot = if ($env:USERPROFILE) { ConvertTo-NormalizedAclPath -Path $env:USERPROFILE.TrimEnd('\') } else { '' }
    $exact = @('C:\Users')
    if ($profileRoot) { $exact += $profileRoot }
    $prefix = @('C:\Windows', 'C:\Program Files', 'C:\Program Files (x86)', 'C:\ProgramData')
    foreach ($e in @($env:SystemRoot, $env:ProgramFiles, ${env:ProgramFiles(x86)}, $env:ProgramData)) { if ($e -and $e -match '^[A-Za-z]:\\') { $prefix += $e.TrimEnd('\') } }
    $prefix = @($prefix | Sort-Object -Unique)
    if ($profileRoot) { $prefix += @('AppData', '.ssh', '.aws', '.azure', '.config', '.gnupg') | ForEach-Object { "$profileRoot\$_" } }
    return @{
        Exact = @($exact | ForEach-Object { ConvertTo-NormalizedAclPath -Path $_ })
        Prefix = @($prefix | ForEach-Object { ConvertTo-NormalizedAclPath -Path $_ })
        Profile = $profileRoot
        Carve = $(if ($profileRoot -and $script:AclAllowTempRoot) { "$profileRoot\AppData\Local\Temp" } else { '' })
    }
}

function Test-AclForbiddenPath {
    # '' when allowed, else the reason. -Normalized must come from ConvertTo-NormalizedAclPath.
    param([Parameter(Mandatory)][string]$Normalized)
    $r = Get-AclForbiddenRules
    $n = $Normalized.TrimEnd('\')
    $under = { param($p, $root) $p -ieq $root -or $p.StartsWith($root.TrimEnd('\') + '\', [StringComparison]::OrdinalIgnoreCase) }
    foreach ($e in $r.Exact) { if ($n -ieq $e) { return "is a system or profile-root folder this stage never changes" } }
    if ($r.Carve -and (& $under $n $r.Carve)) { return '' }
    foreach ($p in $r.Prefix) { if (& $under $n $p) { return "is inside a system or profile-root folder ('$p') this stage never changes" } }
    if ($n -match '^C:\\Users\\[^\\]+' -and $r.Profile -and -not (& $under $n $r.Profile)) { return "is inside another user's profile folder (system or profile-root rule), which this stage never changes" }
    return ''
}

function Find-LinksUnder {
    # Reparse points (junctions, symlinks) under a root, WITHOUT descending into them. Returns @(@{Path; Target}).
    param([Parameter(Mandatory)][string]$Root, [int]$Max = 200)
    $found = New-Object System.Collections.ArrayList
    $stack = New-Object 'System.Collections.Generic.Stack[string]'
    $stack.Push($Root)
    while ($stack.Count -gt 0 -and $found.Count -lt $Max) {
        $d = $stack.Pop()
        try { $entries = [IO.Directory]::EnumerateFileSystemEntries($d) } catch { continue }
        foreach ($e in $entries) {
            $attr = $null
            try { $attr = [IO.File]::GetAttributes($e) } catch { continue }
            if ($attr -band [IO.FileAttributes]::ReparsePoint) {
                $t = ''
                try { $t = [string](Get-Item -LiteralPath $e -Force -ErrorAction Stop).Target } catch { $t = '' }
                [void]$found.Add(@{ Path = $e; Target = $t })
            } elseif ($attr -band [IO.FileAttributes]::Directory) { $stack.Push($e) }
        }
    }
    return @($found)
}

function Test-AclTargetSafe {
    # Returns @{ Ok; Reason; Links; Normalized }. REFUSES: an extended-length or device path (\\?\ \\.\), a relative or
    # UNC path, a wildcard (* ? or a < > | " character), an alternate-stream or device syntax (a colon after the drive,
    # a reserved device name such as NUL or COM1), a dot-dot segment, then - on the CANONICAL spelling (trailing dots
    # and spaces, 8.3 short names, case, .\ segments all resolved) - a drive root or a system folder or the profile
    # root, a path that does not exist, a path that is itself a link or sits below a link. For a tree target, any
    # link INSIDE it is reported (the stage never enters it; Links tells the operator it is there).
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Path, [switch]$Tree)
    $r = @{ Ok = $false; Reason = ''; Links = @(); Normalized = '' }
    if ([string]::IsNullOrWhiteSpace($Path)) { $r.Reason = 'empty path'; return $r }
    if ($Path -match '^[\\/]{2}[?.][\\/]' -or $Path -match '^[\\/]{2}[?.]$') { $r.Reason = "device or extended-length path prefix in '$Path'"; return $r }
    if ($Path -notmatch '^[A-Za-z]:\\') { $r.Reason = "not an absolute drive path: '$Path'"; return $r }
    if ($Path -match '[\*\?<>|"]') { $r.Reason = "wildcard or illegal character in '$Path'"; return $r }
    if ($Path.Substring(2) -match ':') { $r.Reason = "alternate-stream or device syntax (a colon after the drive) in '$Path'"; return $r }
    if ($Path -match '(^|\\)\.\.(\\|$)') { $r.Reason = "dot-dot segment in '$Path'"; return $r }
    if (@($Path -split '\\' | Where-Object { $_.TrimEnd('.', ' ') -match '^(CON|PRN|AUX|NUL|COM[0-9]|LPT[0-9])(\..*)?$' }).Count -gt 0) { $r.Reason = "reserved device name in '$Path'"; return $r }
    $norm = ConvertTo-NormalizedAclPath -Path $Path
    $r.Normalized = $norm
    if ($norm -match '^[A-Za-z]:$') { $r.Reason = "'$Path' is a drive root"; return $r }
    $forbidden = Test-AclForbiddenPath -Normalized $norm
    if ($forbidden) { $r.Reason = "'$Path' $forbidden"; return $r }
    if (-not (Test-Path -LiteralPath $norm)) { $r.Reason = "'$Path' does not exist"; return $r }
    # the path and every ancestor below the drive root must be a real directory, not a link
    $cur = $norm
    while ($cur -and $cur -notmatch '^[A-Za-z]:$') {
        $item = Get-Item -LiteralPath $cur -Force -ErrorAction SilentlyContinue
        if ($item -and ($item.Attributes -band [IO.FileAttributes]::ReparsePoint)) {
            $r.Reason = if ($cur -ieq $norm) { "'$Path' is a link (junction or symlink)" } else { "'$Path' sits below the link '$cur'" }
            return $r
        }
        $parent = [IO.Path]::GetDirectoryName($cur)
        if (-not $parent -or $parent -eq $cur) { break }
        $cur = $parent
    }
    if ($Tree) { $r.Links = @(Find-LinksUnder -Root $norm) }
    $r.Ok = $true
    return $r
}

# ---- the plan --------------------------------------------------------------------------------------------

function New-AclAction {
    param([string]$Id, [string]$Issue, [string]$Title, [string]$Path, [string]$Plain, $Steps, $Undo, [string]$UndoNote = '', [bool]$Skipped = $false)
    [pscustomobject]@{ Id = $Id; Issue = $Issue; Title = $Title; Path = $Path; Plain = $Plain; Steps = @($Steps); Undo = @($Undo); UndoNote = $UndoNote; Skipped = $Skipped }
}

function Get-AclForeignWriters {
    # SIDs holding an Allow ACE with a write-capable right that are NOT in the keep set. Orphans included.
    param([Parameter(Mandatory)]$State, [Parameter(Mandatory)][string[]]$KeepSids)
    @($State.Aces | Where-Object { $_.Type -eq 'Allow' -and (Test-AceWriteCapable $_) -and $_.Sid -and ($KeepSids -notcontains $_.Sid) } | ForEach-Object { $_.Sid } | Sort-Object -Unique)
}

function Get-CoderAclPlan {
    # PURE given -ReadAcl (default: the real ACLs). Builds the ordered actions of the stage. Nothing is
    # changed here. -ProfileCleanupPaths: folders whose orphan-SID ACEs are removed (#1686 note).
    param(
        [Parameter(Mandatory)][string]$CoderSid,
        [Parameter(Mandatory)][string]$OperatorSid,
        [string]$ProjectsDir = 'C:\Users\mrbla\projects',
        [string]$WorktreeBase = 'C:\blarai-fleet\worktrees',
        [string]$LegRoot = '',
        [string[]]$ModelRoots = @('B:\models', 'C:\models', 'C:\Users\mrbla\BlarAI\models'),
        [string[]]$ProfileCleanupPaths = @('C:\Users\mrbla\BlarAI'),
        [string[]]$ModelReaderSids = @(),
        [scriptblock]$ReadAcl = { param($p) Read-AclState -Path $p }
    )
    $fleetRoot = (Split-Path $WorktreeBase -Parent)
    if (-not $LegRoot) { $LegRoot = Join-Path $fleetRoot 'coder-leg' }
    $actions = New-Object System.Collections.ArrayList
    $OI_CI = '(OI)(CI)'
    $authUsers = 'S-1-5-11'; $users = 'S-1-5-32-545'; $system = 'S-1-5-18'; $admins = 'S-1-5-32-544'; $creatorOwner = 'S-1-3-0'

    # 1. projects (#1678)
    [void]$actions.Add((New-AclAction -Id 'projects-narrow' -Issue '#1678' -Title 'Coder: write access to the projects folder becomes read-only' -Path $ProjectsDir `
        -Plain "blarai-coder loses write access to $ProjectsDir and to every repo under it, including each repo's .git (refs, objects, index), and keeps READ. A repo created later inherits the read access and nothing else. Only the operator account (the funnel) commits and merges." `
        -Steps @((New-AclOp RemoveGrants -Sid $CoderSid -Tree), (New-AclOp SetGrant -Sid $CoderSid -Rights 'RX' -Flags $OI_CI)) `
        -Undo @((New-AclOp RemoveGrants -Sid $CoderSid), (New-AclOp SetGrant -Sid $CoderSid -Rights 'M' -Flags $OI_CI)) `
        -UndoNote 'Restores the old inheritable Modify on projects (every repo that inherits gets it back; a repo with inheritance switched off does not: use -RestoreFrom the backup for an exact return). That re-opens #1678.'))

    # 2. fleet root (#1686). The operator Modify the stage ADDS is removed again by the undo, unless the operator
    # already held an explicit entry here before (then it stays: it was not ours).
    $fst = $null; try { $fst = & $ReadAcl $fleetRoot } catch { $fst = $null }
    $opHadFleet = ($null -ne $fst) -and (@($fst.Aces | Where-Object { $_.Type -eq 'Allow' -and $_.Sid -eq $OperatorSid -and -not $_.Inherited }).Count -gt 0)
    $fleetUndo = @((New-AclOp EnableInheritance), (New-AclOp SetGrant -Sid $CoderSid -Rights 'M' -Flags $OI_CI))
    if (-not $opHadFleet) { $fleetUndo += @(New-AclOp RemoveGrants -Sid $OperatorSid) }
    [void]$actions.Add((New-AclAction -Id 'fleet-root' -Issue '#1686' -Title 'C:\blarai-fleet stops being writable by every local account' -Path $fleetRoot `
        -Plain "$fleetRoot stops inheriting from C:\ (which gives Authenticated Users Modify and Users read). It keeps SYSTEM, Administrators and the operator. blarai-coder loses its Modify on the root and keeps READ on the root folder itself (so it can list and reach worktrees\ and coder-leg\); it gets Modify again only on those two (next two steps)." `
        -Steps @((New-AclOp DisableInheritanceCopy), (New-AclOp RemoveGrants -Sid $authUsers), (New-AclOp RemoveGrants -Sid $users), (New-AclOp RemoveGrants -Sid $CoderSid -Tree), (New-AclOp AddGrant -Sid $OperatorSid -Rights 'M' -Flags $OI_CI), (New-AclOp SetGrant -Sid $CoderSid -Rights 'RX' -Flags '')) `
        -Undo $fleetUndo `
        -UndoNote $(if ($opHadFleet) { 'Turns inheritance back on, which brings back Authenticated Users: Modify from C:\ (the #1686 hole), and gives the coder Modify on the root again. The operator entry on the root STAYS: the operator already had an explicit entry there before this stage.' } else { 'Turns inheritance back on, which brings back Authenticated Users: Modify from C:\ (the #1686 hole), gives the coder Modify on the root again, and removes the operator Modify entry this stage added.' })))
    [void]$actions.Add((New-AclAction -Id 'fleet-worktrees' -Issue '#1678' -Title 'Coder: Modify on the worktree base only' -Path $WorktreeBase `
        -Plain "blarai-coder can create, change and delete files in $WorktreeBase (the worktrees it is dispatched into)." `
        -Steps @(New-AclOp SetGrant -Sid $CoderSid -Rights 'M' -Flags $OI_CI) -Undo @(New-AclOp RemoveGrants -Sid $CoderSid)))
    [void]$actions.Add((New-AclAction -Id 'fleet-coder-leg' -Issue '#1678' -Title 'Coder: Modify on the coder-leg job folders only' -Path $LegRoot `
        -Plain "blarai-coder can read jobs and write results and logs under $LegRoot (queue, prompts, results, logs)." `
        -Steps @(New-AclOp SetGrant -Sid $CoderSid -Rights 'M' -Flags $OI_CI) -Undo @(New-AclOp RemoveGrants -Sid $CoderSid)))

    # 3. the worktree-root deny (#1686 stage 9)
    [void]$actions.Add((New-AclAction -Id 'worktree-root-deny' -Issue '#1686' -Title 'Coder cannot delete or rename a worktree root' -Path $WorktreeBase `
        -Plain "blarai-coder is denied deleting entries directly under $WorktreeBase and deleting a worktree root itself, so it cannot swap its working folder for a link. Files and folders INSIDE a worktree stay writable." `
        -Steps @((New-AclOp RemoveDenies -Sid $CoderSid), (New-AclOp Deny -Sid $CoderSid -Rights 'DC'), (New-AclOp Deny -Sid $CoderSid -Rights 'DE' -Flags '(CI)(IO)(NP)')) `
        -Undo @(New-AclOp RemoveDenies -Sid $CoderSid)))

    # 4. orphan SIDs (#1686 note): decided from the real ACL at plan time
    $orphanRemoved = @{}
    foreach ($p in $ProfileCleanupPaths) {
        $st = $null; try { $st = & $ReadAcl $p } catch { $st = $null }
        if ($null -eq $st) { continue }
        $orph = @($st.Aces | Where-Object { $_.Orphan -and $_.Type -eq 'Allow' -and -not $_.Inherited -and $_.Sid } | ForEach-Object { $_.Sid } | Sort-Object -Unique)
        if ($orph.Count -eq 0) { continue }
        foreach ($o in $orph) { $orphanRemoved[$o] = $p }
        $steps = @($orph | ForEach-Object { New-AclOp RemoveGrants -Sid $_ })
        $undo = @()   # icacls cannot grant to an account that no longer exists (exit 1332); -RestoreFrom the backup puts the entry back byte for byte
        [void]$actions.Add((New-AclAction -Id "orphan-$((Split-Path $p -Leaf).ToLowerInvariant())" -Issue '#1686' -Title "Remove access entries for deleted accounts on $p" -Path $p `
            -Plain "Removes $($orph.Count) access entr$(if ($orph.Count -eq 1) { 'y' } else { 'ies' }) on $p that belong to an account that no longer exists ($($orph -join ', ')). Nobody can be that account; the entry only clutters the list and is write-capable. If the entry is inherited by the files below, Windows updates them all, which can take a few minutes." `
            -Steps $steps -Undo $undo -UndoNote 'No targeted undo: the entry belonged to a deleted account and grants nothing to anyone, and icacls cannot re-add it. Use -RestoreFrom the backup for a byte-exact return.'))
    }

    # 5. model folders (#1692): decided from the real ACL at plan time
    foreach ($m in $ModelRoots) {
        $st = $null; try { $st = & $ReadAcl $m } catch { $st = $null }
        if ($null -eq $st) {
            # fail loud: a model folder that cannot be read is NOT protected, and the plan says so
            [void]$actions.Add((New-AclAction -Id "models-$($m -replace '[^A-Za-z0-9]+','-')" -Issue '#1692' -Title "Model folder $m NOT FOUND or unreadable" -Path $m `
                -Plain "$m does not exist or its access list cannot be read from here, so it is NOT protected by this run. If the drive or folder should exist, fix that and run the stage again." -Steps @() -Undo @() -Skipped $true))
            continue
        }
        $keep = @($OperatorSid, $system, $admins, $creatorOwner)
        $writers = @(Get-AclForeignWriters -State $st -KeepSids $keep)
        # an orphan ACE inherited from a folder the orphan action above already cleans is not a finding here
        $writers = @($writers | Where-Object {
            $w = $_
            -not ($orphanRemoved.ContainsKey($w) -and @($st.Aces | Where-Object { $_.Sid -eq $w -and $_.Inherited }).Count -gt 0 -and ($m.ToLowerInvariant().StartsWith($orphanRemoved[$w].TrimEnd('\').ToLowerInvariant() + '\')))
        })
        $steps = New-Object System.Collections.ArrayList
        $undo = New-Object System.Collections.ArrayList
        $kept = New-Object System.Collections.ArrayList   # writers that keep READ (their write is removed, not their read)
        if ($writers.Count -gt 0) {
            $wasProtected = [bool]$st.Protected
            if (-not $wasProtected) { [void]$steps.Add((New-AclOp DisableInheritanceCopy)) }
            foreach ($w in $writers) {
                [void]$steps.Add((New-AclOp RemoveGrants -Sid $w))
                # EVERY allow entry of this account, with its OWN inheritance flags: a write-capable entry is cut down to
                # the read-and-run bits it held, an entry that is not write-capable is put back as it was. One entry's
                # flags are never applied to another (a separate read entry keeps its own inheritance).
                $entries = @($st.Aces | Where-Object { $_.Type -eq 'Allow' -and $_.Sid -eq $w -and -not [bool]$_.Orphan })
                $seen = @{}
                $cands = New-Object System.Collections.ArrayList
                foreach ($e in $entries) {
                    $mk = [int64]$e.Mask
                    if (Test-AceWriteCapable $e) { $mk = if (($mk -band 0xA0000000L) -ne 0) { $script:AclReadKeepMask } else { $mk -band $script:AclReadKeepMask } }
                    if ($mk -eq 0) { continue }
                    $key = "$mk|$($e.Flags)"; if ($seen.ContainsKey($key)) { continue }; $seen[$key] = $true
                    [void]$cands.Add(@{ Mask = $mk; Flags = [string]$e.Flags })
                }
                # an entry that a folder-subfolders-and-files entry with the same rights already covers is redundant
                # (Windows merges it): leaving it out keeps the computed AFTER equal to the real one
                foreach ($c in $cands) {
                    $covered = @($cands | Where-Object { $_.Mask -eq $c.Mask -and $_.Flags -eq '(OI)(CI)' -and $c.Flags -ne '(OI)(CI)' }).Count -gt 0
                    if (-not $covered) { [void]$steps.Add((New-AclOp AddGrant -Sid $w -Rights (Get-AclRightName -Mask $c.Mask) -Flags $c.Flags)) }
                }
                [void]$undo.Add((New-AclOp RemoveGrants -Sid $w))
                # inheritance still on: turning it back on returns the inherited entries; already off: re-add each original entry by hand
                if ($wasProtected) { foreach ($e in $entries) { [void]$undo.Add((New-AclOp AddGrant -Sid $w -Rights (Get-AclRightName -Mask ([int64]$e.Mask)) -Flags ([string]$e.Flags))) } }
            }
            if (-not $wasProtected) { [void]$undo.Add((New-AclOp EnableInheritance)) }
            [void]$steps.Add((New-AclOp AddGrant -Sid $OperatorSid -Rights 'M' -Flags $OI_CI))
            # the operator Modify this stage adds comes out again on rollback unless the operator already held an explicit entry
            if (@($st.Aces | Where-Object { $_.Type -eq 'Allow' -and $_.Sid -eq $OperatorSid -and -not $_.Inherited }).Count -eq 0) { [void]$undo.Add((New-AclOp RemoveGrants -Sid $OperatorSid)) }
        }
        # accounts named as model READERS (-ModelReaderSids) are given explicit read, additively
        foreach ($rs in $ModelReaderSids) {
            [void]$steps.Add((New-AclOp AddGrant -Sid $rs -Rights 'RX' -Flags $OI_CI))
            [void]$undo.Add((New-AclOp RemoveGrants -Sid $rs))
        }
        if ($steps.Count -eq 0) {
            [void]$actions.Add((New-AclAction -Id "models-$($m -replace '[^A-Za-z0-9]+','-')" -Issue '#1692' -Title "Model folder $m already protected" -Path $m `
                -Plain "No account other than the operator, SYSTEM and Administrators can write to $m. Nothing to change." -Steps @() -Undo @()))
            continue
        }
        $who = @($writers | ForEach-Object { $w = $_; $a = @($st.Aces | Where-Object { $_.Sid -eq $w } | Select-Object -First 1)[0]; if ($a -and $a.Name) { $a.Name } else { $w } })
        [void]$actions.Add((New-AclAction -Id "models-$($m -replace '[^A-Za-z0-9]+','-')" -Issue '#1692' -Title "Model folder $m is no longer writable by other accounts" -Path $m `
            -Plain "$m stops inheriting its parent's access list. Write access for $($who -join ', ') is removed; the operator keeps Modify, SYSTEM and Administrators keep Full control, and those accounts keep READ (read access is not tightened here: that is a separate decision)." `
            -Steps @($steps) -Undo @($undo) -UndoNote 'Re-enabling inheritance brings back whatever the parent folder grants, including the write access that was removed.'))
    }
    return @($actions)
}

# ---- simulation of a whole action, and the plain-language rendering ---------------------------------------

function Get-AclActionAfter {
    param([Parameter(Mandatory)]$Before, [Parameter(Mandatory)]$Action)
    $s = $Before
    foreach ($op in $Action.Steps) { $s = Invoke-AclSimulation -State $s -Op $op }
    return $s
}

function Format-AclFlagsPlain {
    param([string]$Flags)
    switch ($Flags) {
        ''                 { return 'this folder only' }
        '(OI)(CI)'         { return 'this folder, subfolders and files' }
        '(CI)(IO)(NP)'     { return 'subfolders one level down only' }
        '(OI)(CI)(IO)'     { return 'subfolders and files only' }
        default            { return $Flags }
    }
}

function Format-AclRightPlain {
    param([string]$Rights)
    switch ($Rights) {
        'F' { return 'full control' } 'M' { return 'modify (read, write, delete)' } 'RX' { return 'read and run' }
        'R' { return 'read' } 'DC' { return 'delete entries inside' } 'DE' { return 'delete this item' }
        default { return $Rights }
    }
}

function Get-AclSidDisplay {
    param([string]$Sid, [string]$Fallback = '')
    try { return ([Security.Principal.SecurityIdentifier]$Sid).Translate([Security.Principal.NTAccount]).Value } catch { if ($Fallback) { return $Fallback } else { return "$Sid (account no longer exists)" } }
}

function Format-AclStateLines {
    param([Parameter(Mandatory)]$State, [hashtable]$Names = @{})
    $lines = New-Object System.Collections.ArrayList
    [void]$lines.Add("    owner: $(if ($State.Owner) { Get-AclSidDisplay -Sid $State.Owner } else { '(unreadable)' })")
    [void]$lines.Add("    inheritance from the parent folder: $(if ($State.Protected) { 'OFF' } else { 'ON' })")
    foreach ($a in $State.Aces) {
        $n = if ($Names.ContainsKey($a.Sid)) { $Names[$a.Sid] } else { Get-AclSidDisplay -Sid $a.Sid -Fallback $a.Name }
        $kind = if ($a.Type -eq 'Deny') { 'DENY ' } else { 'allow' }
        [void]$lines.Add(("    {0}  {1,-34} {2,-30} {3}{4}" -f $kind, $n, (Format-AclRightPlain $a.Rights), (Format-AclFlagsPlain $a.Flags), $(if ($a.Inherited) { '  (inherited)' } else { '' })))
    }
    return @($lines)
}

function Format-AclOpText {
    # One op as the operator reads it: the icacls command, or for a TREE op the walk plus the per-object command.
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)]$Op)
    $cmd = Format-IcaclsText -IcaclsArgs (ConvertTo-IcaclsCommand -Path $Path -Op $Op)
    if ($Op.Op -eq 'RemoveGrants' -and -not $Op.Tree) { return "$cmd   [done directly through a checked handle, same effect]" }
    if ($Op.Tree) { return "WALK every folder and file under $Path (links are listed and never entered), and on each object run:  $($cmd -replace [regex]::Escape('icacls "' + $Path + '"'), 'icacls <object>' -replace [regex]::Escape('icacls ' + $Path), 'icacls <object>')" }
    return $cmd
}

function Format-CoderAclPlan {
    # The plain-language dry-run text. -States: path -> before state. Returns a string[]; prints nothing.
    param([Parameter(Mandatory)]$Plan, [Parameter(Mandatory)][hashtable]$States, [hashtable]$Safety = @{}, [hashtable]$Names = @{})
    $out = New-Object System.Collections.ArrayList
    $i = 0
    foreach ($act in $Plan) {
        $i++
        [void]$out.Add('')
        [void]$out.Add("[$i/$($Plan.Count)] $($act.Title)   ($($act.Issue))")
        [void]$out.Add("  WHAT: $($act.Plain)")
        [void]$out.Add("  FOLDER: $($act.Path)")
        if ($act.Skipped) { [void]$out.Add('  SKIPPED: nothing is changed for this folder in this run.'); continue }
        if ($act.Steps.Count -eq 0) { [void]$out.Add('  CHANGE: none (already in the wanted state)'); continue }
        $before = $States[$act.Path]
        [void]$out.Add('  BEFORE:')
        foreach ($l in (Format-AclStateLines -State $before -Names $Names)) { [void]$out.Add($l) }
        $after = Get-AclActionAfter -Before $before -Action $act
        $same = (Compare-AclStates -Expected $before -Actual $after).Match
        [void]$out.Add($(if ($same) { '  AFTER: identical to BEFORE - this folder is already in the wanted state; re-running changes nothing here.' } else { '  AFTER (computed; the real result is compared with it after the run):' }))
        if (-not $same) { foreach ($l in (Format-AclStateLines -State $after -Names $Names)) { [void]$out.Add($l) } }
        [void]$out.Add('  COMMANDS THAT WILL RUN, in order:')
        foreach ($op in $act.Steps) { [void]$out.Add('    ' + (Format-AclOpText -Path $act.Path -Op $op)) }
        [void]$out.Add('  UNDO (rollback listing):')
        foreach ($op in $act.Undo) { [void]$out.Add('    ' + (Format-AclOpText -Path $act.Path -Op $op)) }
        if ($act.UndoNote) { [void]$out.Add("    note: $($act.UndoNote)") }
        if ($Safety.ContainsKey($act.Path) -and $Safety[$act.Path].Links.Count -gt 0) {
            [void]$out.Add("  LINKS INSIDE THIS TREE ($($Safety[$act.Path].Links.Count)): the stage never enters or changes them, and does not touch what they point at:")
            foreach ($l in ($Safety[$act.Path].Links | Select-Object -First 10)) { [void]$out.Add("    $($l.Path) -> $($l.Target)") }
        }
    }
    return @($out)
}

# ---- apply ------------------------------------------------------------------------------------------------

function Invoke-IcaclsStep {
    # Runs ONE icacls command; throws on a non-zero exit. -Runner is a test seam (default: icacls).
    param([Parameter(Mandatory)][string[]]$IcaclsArgs, [scriptblock]$Runner = $null)
    if ($Runner) { $null = & $Runner $IcaclsArgs; return }
    $o = & icacls @IcaclsArgs 2>&1
    if ($LASTEXITCODE -ne 0) { throw "icacls failed (exit $LASTEXITCODE): $(Format-IcaclsText -IcaclsArgs $IcaclsArgs) :: $(($o | Out-String).Trim())" }
}

function Invoke-CoderAclAction {
    # Apply (or, with -UseUndo, undo) one action. Every target is gated first; an unsafe target throws before
    # any command runs. A tree op is a no-follow walk (Invoke-AclTreeRemoveGrants), never icacls /T. Returns the
    # after-state of the root read back from disk. -Runner is a test seam that replaces icacls and the walk.
    param([Parameter(Mandatory)]$Action, [switch]$UseUndo, [scriptblock]$Runner = $null, [scriptblock]$Out = { param($l) Write-Host $l })
    $ops = if ($UseUndo) { $Action.Undo } else { $Action.Steps }
    if (@($ops).Count -eq 0) { return $null }
    $needsTree = @($ops | Where-Object { $_.Tree }).Count -gt 0
    $safe = Test-AclTargetSafe -Path $Action.Path -Tree:$needsTree
    if (-not $safe.Ok) { throw "refusing '$($Action.Path)': $($safe.Reason)" }
    foreach ($op in $ops) {
        & $Out ("    > " + (Format-AclOpText -Path $Action.Path -Op $op))
        if ($op.Op -eq 'RemoveGrants' -and -not $op.Tree) {
            # applied directly, not through icacls: icacls cannot remove an entry whose account no longer exists (exit 1332)
            if ($Runner) { $null = & $Runner @('REMOVE-GRANT', $Action.Path, "*$($op.Sid)"); continue }
            [void](Remove-ExplicitGrantOfSid -Path $Action.Path -IsDir $true -Sid $op.Sid)
        } elseif ($op.Tree) {
            if ($op.Op -ne 'RemoveGrants') { throw "tree operation '$($op.Op)' is not supported (only RemoveGrants walks a tree)" }
            if ($Runner) { $null = & $Runner @('TREE', $Action.Path, '/remove:g', "*$($op.Sid)"); continue }
            $w = Invoke-AclTreeRemoveGrants -Root $Action.Path -Sid $op.Sid -Out $Out
            & $Out "      walked $($w.Visited) objects, changed $($w.Changed), links not entered: $(@($w.Links).Count), errors: $(@($w.Errors).Count)"
            if (@($w.Errors).Count -gt 0) { throw "the tree walk under '$($Action.Path)' had $(@($w.Errors).Count) error(s); first: $($w.Errors[0])" }
        } else {
            $cmd = ConvertTo-IcaclsCommand -Path $Action.Path -Op $op
            # icacls works by PATH. A checked handle is held on the folder for the length of the call: the folder
            # cannot be renamed or replaced meanwhile, it was verified (not a link, resolves to itself) just before,
            # and it must still resolve to the same place afterwards. Residual: an ANCESTOR swapped while icacls runs.
            $held = $null; $f1 = ''
            if (-not $Runner) { $held = Open-AclHandle -Path $Action.Path -IsDir $true -Write $false; $f1 = [BlarHandleAcl]::FinalPath($held) }
            try {
                Invoke-IcaclsStep -IcaclsArgs $cmd -Runner $Runner
                # test seam: AfterIcacls runs after the call; FinalPathAfter replaces the real read of the held folder's path
                if ($script:AclTestHook -and $script:AclTestHook.AfterIcacls) { & $script:AclTestHook.AfterIcacls $Action.Path }
                $f2 = if ($held) { if ($script:AclTestHook -and $script:AclTestHook.FinalPathAfter) { [string](& $script:AclTestHook.FinalPathAfter) } else { [BlarHandleAcl]::FinalPath($held) } } else { $f1 }
                if ($held -and ($f2 -ine $f1)) { throw "the folder '$($Action.Path)' moved while icacls was running ($f1 -> $f2); stop and check the machine" }
            } finally { if ($held) { $held.Dispose() } }
        }
    }
    return (Read-AclState -Path $Action.Path)
}

function Compare-AclStates {
    # Order-insensitive comparison of two states on (Sid, Type, Rights, Flags, Inherited-or-not) plus the
    # protected flag. Returns @{ Match; Diff[] }.
    param([Parameter(Mandatory)]$Expected, [Parameter(Mandatory)]$Actual, [switch]$IgnoreInherited)
    $key = { param($s) @($s.Aces | ForEach-Object { "$($_.Type)|$($_.Sid)|$($_.Rights)|$($_.Flags)|$(if ($IgnoreInherited) { '-' } else { [string][int]$_.Inherited })" } | Sort-Object) }
    $e = & $key $Expected; $a = & $key $Actual
    $diff = New-Object System.Collections.ArrayList
    foreach ($x in $e) { if ($a -notcontains $x) { [void]$diff.Add("expected but absent: $x") } }
    foreach ($x in $a) { if ($e -notcontains $x) { [void]$diff.Add("present but not expected: $x") } }
    if ([bool]$Expected.Protected -ne [bool]$Actual.Protected) { [void]$diff.Add("protected flag: expected $($Expected.Protected), actual $($Actual.Protected)") }
    return @{ Match = ($diff.Count -eq 0); Diff = @($diff) }
}

# ---- the checks the verify script and the self-test share ------------------------------------------------

function Find-SidWriteAces {
    # Read-only walk of DIRECTORIES to -Depth levels under -Root (never descending into a link), returning
    # every Allow ACE with a write-capable right held by -Sid. The operator-side half of the narrowing proof.
    param([Parameter(Mandatory)][string]$Root, [Parameter(Mandatory)][string]$Sid, [int]$Depth = 2)
    $hits = New-Object System.Collections.ArrayList
    $queue = New-Object System.Collections.Queue
    $queue.Enqueue(@($Root, 0))
    while ($queue.Count -gt 0) {
        $cur = $queue.Dequeue(); $p = $cur[0]; $lvl = $cur[1]
        $st = $null; try { $st = Read-AclState -Path $p } catch { [void]$hits.Add(@{ Path = $p; Why = "ACL unreadable: $($_.Exception.Message)" }); continue }
        foreach ($a in $st.Aces) { if ($a.Type -eq 'Allow' -and $a.Sid -eq $Sid -and (Test-AceWriteCapable $a)) { [void]$hits.Add(@{ Path = $p; Why = "$($a.Rights) $($a.Flags)" }) } }
        if ($lvl -ge $Depth) { continue }
        try { $kids = [IO.Directory]::EnumerateDirectories($p) } catch { continue }
        foreach ($k in $kids) {
            $attr = $null; try { $attr = [IO.File]::GetAttributes($k) } catch { continue }
            if ($attr -band [IO.FileAttributes]::ReparsePoint) { continue }
            $queue.Enqueue(@($k, ($lvl + 1)))
        }
    }
    return @($hits)
}

function Find-ProtectedChildrenEx {
    # Like Find-ProtectedChildren but also returns what could not be opened: @{ Hits[]; Errors[] }.
    param([Parameter(Mandatory)][string]$Root)
    $hits = New-Object System.Collections.ArrayList
    $w = Invoke-NoFollowWalk -Root $Root -OnObject {
        param($p, $isDir)
        if (-not $isDir) { return }
        $sec = New-Object Security.AccessControl.DirectorySecurity
        $sec.SetSecurityDescriptorSddlForm((Get-AclSddlChecked -Path $p -IsDir $true), [Security.AccessControl.AccessControlSections]::Access)
        if ($sec.AreAccessRulesProtected -and $p.TrimEnd('\') -ne $Root.TrimEnd('\')) { [void]$hits.Add($p) }
    }
    return @{ Hits = @($hits); Errors = @($w.Errors) }
}

function Find-ProtectedChildren {
    # EVERY folder under -Root (full depth, the no-follow walk, links never entered) whose access list has inheritance
    # switched off: it does NOT receive an inheritable entry set on -Root, so a repo like that is invisible to the
    # coder until granted by hand. -Depth is kept for old callers and ignored.
    param([Parameter(Mandatory)][string]$Root, [int]$Depth = 0)
    $hits = New-Object System.Collections.ArrayList
    $rootFinal = $null
    $w = Invoke-NoFollowWalk -Root $Root -OnObject {
        param($p, $isDir)
        if (-not $isDir) { return }
        $sec = New-Object Security.AccessControl.DirectorySecurity
        $sec.SetSecurityDescriptorSddlForm((Get-AclSddlChecked -Path $p -IsDir $true), [Security.AccessControl.AccessControlSections]::Access)
        if ($sec.AreAccessRulesProtected -and $p.TrimEnd('\') -ne $Root.TrimEnd('\')) { [void]$hits.Add($p) }
    }
    return @($hits)
}

function Get-NarrowingVerdict {
    # PURE. The pass/fail of the narrowing checks. Every input is a boolean the caller measured; the result
    # names each failed check. Both the real-account verify and the temp-tree self-test decide through this.
    param(
        [Parameter(Mandatory)][bool]$AclNoCoderWrite,        # operator-side: no write ACE for the coder SID on projects
        [Parameter(Mandatory)][bool]$SiblingWriteDenied,     # coder: create a file in a sibling repo -> denied
        [Parameter(Mandatory)][bool]$NewRepoWriteDenied,     # coder: create a file in a repo created after provisioning -> denied
        [Parameter(Mandatory)][bool]$SourceGitWriteDenied,   # coder: create .git/refs/heads/x and .git/objects/xx -> denied
        [Parameter(Mandatory)][bool]$WorktreeCommitFails,    # coder: git commit in its worktree fails, for a permission reason
        [Parameter(Mandatory)][bool]$ReadAssetsOk,           # coder: read assets/README.txt of the seeded repo
        [Parameter(Mandatory)][bool]$WorktreeWriteOk,        # coder: write inside its own worktree still works
        [Parameter(Mandatory)][bool]$NewRepoInheritsRead,    # operator-side: the repo created after provisioning carries the inherited read ACE
        [Parameter(Mandatory)][bool]$FunnelCommitOk,         # operator: the funnel commit lands
        [Parameter(Mandatory)][bool]$FunnelMergeOk           # operator: the first dispatch merges to main
    )
    $failed = New-Object System.Collections.ArrayList
    if (-not $AclNoCoderWrite)      { [void]$failed.Add('check5-no-coder-write-ace-on-projects') }
    if (-not $SiblingWriteDenied)   { [void]$failed.Add('check6-sibling-repo-write-denied') }
    if (-not $NewRepoWriteDenied)   { [void]$failed.Add('check7-new-repo-write-denied') }
    if (-not $SourceGitWriteDenied) { [void]$failed.Add('check8-source-git-write-denied') }
    if (-not $WorktreeCommitFails)  { [void]$failed.Add('check9-worktree-commit-fails') }
    if (-not $ReadAssetsOk)         { [void]$failed.Add('check10-read-seeded-assets') }
    if (-not $WorktreeWriteOk)      { [void]$failed.Add('check11-worktree-write-ok') }
    if (-not $NewRepoInheritsRead)  { [void]$failed.Add('check12-new-repo-inherits-read') }
    if (-not $FunnelCommitOk)       { [void]$failed.Add('check13-operator-funnel-commits') }
    if (-not $FunnelMergeOk)        { [void]$failed.Add('check14-first-dispatch-merges') }
    [pscustomobject]@{ Pass = ($failed.Count -eq 0); Failed = @($failed) }
}

function Get-NarrowingFromProbe {
    # PURE. Map the probe's check results (the coder's own measurements) plus the operator-side facts onto
    # Get-NarrowingVerdict. A check that is absent from the probe output is a FAIL (never a skip): an older
    # runner, or a probe that stopped early, cannot pass by saying nothing. Shared by verify-coder-containment.ps1
    # (the real coder) and verify-coder-narrowing.ps1 (the temp-tree stand-in), so both decide the same way.
    param(
        [Parameter(Mandatory)]$Checks, [Parameter(Mandatory)][string]$SiblingDir, [Parameter(Mandatory)][string]$NewRepoDir,
        [Parameter(Mandatory)][bool]$AclNoCoderWrite, [Parameter(Mandatory)][bool]$NewRepoInheritsRead,
        [Parameter(Mandatory)][bool]$FunnelCommitOk, [Parameter(Mandatory)][bool]$FunnelMergeOk
    )
    $per = {
        param($c, $key)
        $e = $null; try { $e = $c.per_path.$key } catch { $e = $null }
        if ($null -eq $e) { return $false }
        return [bool]$e.pass
    }
    $sibOk = & $per $Checks.write_outside_denied $SiblingDir
    $newOk = & $per $Checks.write_outside_denied $NewRepoDir
    $refOk = & $per $Checks.source_git_write_denied "$NewRepoDir refs"
    $objOk = & $per $Checks.source_git_write_denied "$NewRepoDir objects"
    $v = Get-NarrowingVerdict -AclNoCoderWrite $AclNoCoderWrite -SiblingWriteDenied $sibOk -NewRepoWriteDenied $newOk `
        -SourceGitWriteDenied ($refOk -and $objOk) -WorktreeCommitFails ([bool]$Checks.worktree_commit_fails.pass) `
        -ReadAssetsOk ([bool]$Checks.read_files_ok.pass) -WorktreeWriteOk ([bool]$Checks.worktree_write_ok.pass) `
        -NewRepoInheritsRead $NewRepoInheritsRead -FunnelCommitOk $FunnelCommitOk -FunnelMergeOk $FunnelMergeOk
    $detail = {
        param($c, $key)
        $e = $null; try { $e = $c.per_path.$key } catch { $e = $null }
        if ($null -eq $e) { return 'no result from the probe' }
        return [string]$e.detail
    }
    $rows = @(
        @{ Name = 'check5-no-coder-write-ace-on-projects'; Pass = $AclNoCoderWrite; Detail = 'operator-side ACL scan of the projects folder (depth 2)' },
        @{ Name = 'check6-sibling-repo-write-denied'; Pass = $sibOk; Detail = (& $detail $Checks.write_outside_denied $SiblingDir) },
        @{ Name = 'check7-new-repo-write-denied'; Pass = $newOk; Detail = (& $detail $Checks.write_outside_denied $NewRepoDir) },
        @{ Name = 'check8-source-git-write-denied'; Pass = ($refOk -and $objOk); Detail = 'create .git/refs/heads/x and .git/objects/xx in the new repo' },
        @{ Name = 'check9-worktree-commit-fails'; Pass = [bool]$Checks.worktree_commit_fails.pass; Detail = 'git add/commit in the coder worktree' },
        @{ Name = 'check10-read-seeded-assets'; Pass = [bool]$Checks.read_files_ok.pass; Detail = 'read assets/README.txt of the new repo' },
        @{ Name = 'check11-worktree-write-ok'; Pass = [bool]$Checks.worktree_write_ok.pass; Detail = 'write a file in the coder worktree' },
        @{ Name = 'check12-new-repo-inherits-read'; Pass = $NewRepoInheritsRead; Detail = 'the repo created after provisioning carries the inherited read ACE' },
        @{ Name = 'check13-operator-funnel-commits'; Pass = $FunnelCommitOk; Detail = 'the operator funnel stages and commits what the coder wrote' },
        @{ Name = 'check14-first-dispatch-merges'; Pass = $FunnelMergeOk; Detail = 'the branch merges to main of the new repo' }
    )
    return [pscustomobject]@{ Verdict = $v; Rows = @($rows) }
}

# ---- the operator-side scratch repo (a create_project analogue) and the funnel -------------------------

function Invoke-VerifyGit {
    # operator-side git with the hardening the funnel uses (no hooks, no fsmonitor, no pager, no optional
    # locks, no prompt), against an explicit directory
    param([Parameter(Mandatory)][string]$Dir, [Parameter(Mandatory)][string[]]$GitArgs)
    $pre = @('-C', $Dir, '-c', 'core.hooksPath=NUL', '-c', 'core.fsmonitor=false', '-c', 'user.name=verify-operator', '-c', 'user.email=verify@local', '--no-optional-locks', '--no-pager')
    $env:GIT_TERMINAL_PROMPT = '0'
    $o = & git @pre @GitArgs 2>&1 | Out-String
    return @{ Rc = $LASTEXITCODE; Out = $o.Trim() }
}

function New-VerifyScratchRepo {
    # Operator-side stand-in for create_project(seed_assets=True): a new repo under -ProjectsDir (name starts
    # .blarai-verify-), assets/README.txt seeded, one commit on main, and a linked worktree under -WorktreeBase
    # on a new branch. Returns @{ Repo; Worktree; Branch; Readme }.
    param([Parameter(Mandatory)][string]$ProjectsDir, [Parameter(Mandatory)][string]$WorktreeBase, [string]$Tag = ([guid]::NewGuid().ToString('N').Substring(0, 8)))
    $repo = Join-Path $ProjectsDir ".blarai-verify-$Tag"
    $wt = Join-Path $WorktreeBase "verify-$Tag"
    $branch = "agent/verify-$Tag"
    New-Item -ItemType Directory -Path (Join-Path $repo 'assets') -Force | Out-Null
    Set-Content -LiteralPath (Join-Path $repo 'assets\README.txt') -Value 'seeded assets readme' -Encoding ASCII
    Set-Content -LiteralPath (Join-Path $repo 'app.txt') -Value 'v1' -Encoding ASCII
    foreach ($step in @(@('init', '-b', 'main'), @('add', '-A'), @('commit', '-m', 'seed'))) {
        $r = Invoke-VerifyGit -Dir $repo -GitArgs $step
        if ($r.Rc -ne 0) { throw "scratch repo: git $($step -join ' ') failed: $($r.Out)" }
    }
    $r = Invoke-VerifyGit -Dir $repo -GitArgs @('worktree', 'add', $wt, '-b', $branch)
    if ($r.Rc -ne 0) { throw "scratch repo: git worktree add failed: $($r.Out)" }
    return @{ Repo = $repo; Worktree = $wt; Branch = $branch; Readme = (Join-Path $repo 'assets\README.txt') }
}

function Invoke-VerifyFunnel {
    # The operator funnel for the scratch worktree: stage everything the coder left, commit, then merge the
    # branch into main of the source repo (fast-forward only). Returns @{ CommitOk; MergeOk; Detail }.
    param([Parameter(Mandatory)]$Scratch, [string]$ExpectFile = 'probe-work.txt')
    $res = @{ CommitOk = $false; MergeOk = $false; Detail = '' }
    $a = Invoke-VerifyGit -Dir $Scratch.Worktree -GitArgs @('add', '-A')
    if ($a.Rc -ne 0) { $res.Detail = "add: $($a.Out)"; return $res }
    $c = Invoke-VerifyGit -Dir $Scratch.Worktree -GitArgs @('commit', '-m', 'operator funnel commit')
    if ($c.Rc -ne 0) { $res.Detail = "commit: $($c.Out)"; return $res }
    $inTree = Invoke-VerifyGit -Dir $Scratch.Worktree -GitArgs @('ls-tree', '-r', '--name-only', 'HEAD')
    if (-not ($inTree.Out -split "`n" | Where-Object { $_.Trim() -eq $ExpectFile })) { $res.Detail = "the commit does not contain $ExpectFile"; return $res }
    $res.CommitOk = $true
    $m = Invoke-VerifyGit -Dir $Scratch.Repo -GitArgs @('merge', '--ff-only', $Scratch.Branch)
    if ($m.Rc -ne 0) { $res.Detail = "merge: $($m.Out)"; return $res }
    if (-not (Test-Path -LiteralPath (Join-Path $Scratch.Repo $ExpectFile))) { $res.Detail = "main does not carry $ExpectFile after the merge"; return $res }
    $res.MergeOk = $true
    return $res
}

function Remove-VerifyScratch {
    # Removes ONLY a scratch repo this module made (name .blarai-verify-*, directly under -ProjectsDir) and its
    # worktree (verify-*, directly under -WorktreeBase). Refuses anything else, and refuses a link.
    param([Parameter(Mandatory)]$Scratch, [Parameter(Mandatory)][string]$ProjectsDir, [Parameter(Mandatory)][string]$WorktreeBase)
    foreach ($pair in @(@($Scratch.Repo, $ProjectsDir, '.blarai-verify-*'), @($Scratch.Worktree, $WorktreeBase, 'verify-*'))) {
        $p = $pair[0]; $parent = $pair[1].TrimEnd('\'); $pat = $pair[2]
        if (-not $p -or -not (Test-Path -LiteralPath $p)) { continue }
        if ((Split-Path $p -Parent).TrimEnd('\') -ine $parent -or (Split-Path $p -Leaf) -notlike $pat) { throw "refusing to remove '$p': not a scratch folder directly under '$parent'" }
        $it = Get-Item -LiteralPath $p -Force
        if ($it.Attributes -band [IO.FileAttributes]::ReparsePoint) { throw "refusing to remove '$p': it is a link" }
        # the coder may have left files the operator can read but the ACL stage made read-only: clear attributes then delete
        Remove-Item -LiteralPath $p -Recurse -Force -ErrorAction SilentlyContinue
        if (Test-Path -LiteralPath $p) { throw "could not remove scratch folder '$p'" }
    }
}

function Find-ForeignWriteAces {
    # Read-only walk of DIRECTORIES to -Depth levels under -Root (never into a link): every Allow ACE with a
    # write-capable right held by a SID NOT in -KeepSids. The operator-side half of the proof for the fleet
    # root (#1686) and the model folders (#1692). Orphan identities are included.
    param([Parameter(Mandatory)][string]$Root, [Parameter(Mandatory)][string[]]$KeepSids, [int]$Depth = 2)
    $hits = New-Object System.Collections.ArrayList
    $queue = New-Object System.Collections.Queue
    $queue.Enqueue(@($Root, 0))
    while ($queue.Count -gt 0) {
        $cur = $queue.Dequeue(); $p = $cur[0]; $lvl = $cur[1]
        $st = $null; try { $st = Read-AclState -Path $p } catch { [void]$hits.Add(@{ Path = $p; Sid = ''; Why = "ACL unreadable: $($_.Exception.Message)" }); continue }
        foreach ($a in $st.Aces) {
            if ($a.Type -eq 'Allow' -and (Test-AceWriteCapable $a) -and ((-not $a.Sid) -or ($KeepSids -notcontains $a.Sid))) {
                [void]$hits.Add(@{ Path = $p; Sid = [string]$a.Sid; Why = "$($a.Name) $($a.Rights) $($a.Flags)" })
            }
        }
        if ($lvl -ge $Depth) { continue }
        try { $kids = [IO.Directory]::EnumerateDirectories($p) } catch { continue }
        foreach ($k in $kids) {
            $attr = $null; try { $attr = [IO.File]::GetAttributes($k) } catch { continue }
            if ($attr -band [IO.FileAttributes]::ReparsePoint) { continue }
            $queue.Enqueue(@($k, ($lvl + 1)))
        }
    }
    return @($hits)
}

# ---- backup, restore and the stage driver ------------------------------------------------------------------

function Get-AclBackupSpecs {
    # Which paths are saved before the stage changes anything, and whether the save walks the tree. The projects
    # tree carries explicit coder ACEs on every file (the old grant used /T), so it is saved whole; the others
    # change by inheritance from their root, so the root's own ACL is enough to put them back.
    param([Parameter(Mandatory)]$Plan)
    $specs = New-Object System.Collections.ArrayList
    $seen = @{}
    foreach ($act in $Plan) {
        if (@($act.Steps).Count -eq 0) { continue }
        $k = $act.Path.ToLowerInvariant()
        if ($seen.ContainsKey($k)) { continue }
        $seen[$k] = $true
        $tree = (@($act.Steps | Where-Object { $_.Tree }).Count -gt 0) -or (@($act.Undo | Where-Object { $_.Tree }).Count -gt 0)
        [void]$specs.Add([pscustomobject]@{ Path = $act.Path; Tree = [bool]$tree; File = ('acl-{0:D2}.acl' -f $specs.Count) })
    }
    return @($specs)
}

function Write-AclBackup {
    # Save the access list (as SDDL, one JSON line per object) of every object each spec covers, walking trees
    # without entering links. -Runner replaces the whole save in tests that only count calls.
    param([Parameter(Mandatory)]$Plan, [Parameter(Mandatory)][string]$BackupDir, [scriptblock]$Runner = $null)
    New-Item -ItemType Directory -Force $BackupDir | Out-Null
    $specs = @(Get-AclBackupSpecs -Plan $Plan)
    $rows = New-Object System.Collections.ArrayList
    foreach ($sp in $specs) {
        $file = Join-Path $BackupDir ([IO.Path]::ChangeExtension($sp.File, '.jsonl'))
        if ($Runner) { $null = & $Runner @('SAVE', $sp.Path, $file); [void]$rows.Add(@{ path = $sp.Path; tree = $sp.Tree; file = [IO.Path]::GetFileName($file); objects = 0 }); continue }
        $sw = New-Object IO.StreamWriter($file, $false, (New-Object Text.UTF8Encoding($false)))
        $script:__bk = $sw; $script:__bkn = 0
        try {
            $save = {
                param($p, $isDir)
                $line = [ordered]@{ path = $p; dir = $isDir; sddl = (Get-AclSddlChecked -Path $p -IsDir $isDir) }
                $script:__bk.WriteLine((ConvertTo-Json -InputObject $line -Compress)); $script:__bkn++
            }
            if ($sp.Tree) {
                $w = Invoke-NoFollowWalk -Root $sp.Path -OnObject $save
                if (@($w.Errors).Count -gt 0) { throw "the backup walk under '$($sp.Path)' had $(@($w.Errors).Count) error(s); first: $($w.Errors[0])" }
            } else { & $save $sp.Path $true }
        } finally { $sw.Dispose() }
        [void]$rows.Add(@{ path = $sp.Path; tree = $sp.Tree; file = [IO.Path]::GetFileName($file); objects = $script:__bkn })
    }
    (ConvertTo-Json -InputObject @($rows) -Depth 4) | Set-Content -LiteralPath (Join-Path $BackupDir 'manifest.json') -Encoding UTF8
    # the undo lists AS PLANNED from the state before the change: a later run plans from the changed state (a model
    # folder that is now protected has no steps), so a targeted rollback must be read from here, not recomputed
    $recs = @($Plan | Where-Object { @($_.Steps).Count -gt 0 } | ForEach-Object { [ordered]@{ id = $_.Id; issue = $_.Issue; title = $_.Title; path = $_.Path; undo = @($_.Undo); undo_note = $_.UndoNote } })
    (ConvertTo-Json -InputObject @($recs) -Depth 8) | Set-Content -LiteralPath (Join-Path $BackupDir 'plan.json') -Encoding UTF8
    return $specs
}

function Read-AclUndoPlan {
    # The undo actions saved by Write-AclBackup, as actions Invoke-CoderAclAction -UseUndo can run.
    param([Parameter(Mandatory)][string]$BackupDir)
    $f = Join-Path $BackupDir 'plan.json'
    if (-not (Test-Path -LiteralPath $f)) { throw "no plan.json in '$BackupDir': not a backup written by this stage" }
    $recs = @((Get-Content -LiteralPath $f -Raw | ConvertFrom-Json))
    return @($recs | ForEach-Object {
        [pscustomobject]@{ Id = $_.id; Issue = $_.issue; Title = $_.title; Path = $_.path; Plain = ''; Steps = @(); Undo = @($_.undo); UndoNote = $_.undo_note; Skipped = $false }
    })
}

function Get-LatestAclBackup {
    param([Parameter(Mandatory)][string]$BackupRoot)
    if (-not (Test-Path -LiteralPath $BackupRoot)) { return '' }
    $d = @(Get-ChildItem -LiteralPath $BackupRoot -Directory -ErrorAction SilentlyContinue | Where-Object { Test-Path -LiteralPath (Join-Path $_.FullName 'plan.json') } | Sort-Object Name -Descending | Select-Object -First 1)
    if ($d.Count -eq 0) { return '' }
    return $d[0].FullName
}

function Invoke-AclRestore {
    # Put every saved access list back, parents before children. An object that is now missing or is now a link
    # is skipped and reported, never followed. -Runner replaces the writes in tests that only count calls.
    param([Parameter(Mandatory)][string]$BackupDir, [scriptblock]$Runner = $null, [scriptblock]$Out = { param($l) Write-Host $l })
    $mf = Join-Path $BackupDir 'manifest.json'
    if (-not (Test-Path -LiteralPath $mf)) { throw "no manifest.json in '$BackupDir': not a backup written by this stage" }
    $rows = @((Get-Content -LiteralPath $mf -Raw | ConvertFrom-Json))
    foreach ($row in $rows) {
        if (-not (Test-Path -LiteralPath (Join-Path $BackupDir $row.file))) { throw "backup file '$($row.file)' is missing from '$BackupDir'" }
        $safe = Test-AclTargetSafe -Path $row.path
        if (-not $safe.Ok) { throw "refusing to restore '$($row.path)': $($safe.Reason)" }
    }
    $skipped = New-Object System.Collections.ArrayList
    foreach ($row in $rows) {
        & $Out "    > restore the saved access lists of $($row.path) ($($row.objects) object(s))"
        if ($Runner) { $null = & $Runner @('RESTORE', $row.path, (Join-Path $BackupDir $row.file)); continue }
        $prevRoot = $script:AclWalkRootFinal
        try { $script:AclWalkRootFinal = (Get-AclFinalPath -Path $row.path -IsDir $true) } catch { [void]$skipped.Add("$($row.path) ($($_.Exception.Message))"); $script:AclWalkRootFinal = $prevRoot; continue }
        try {
            foreach ($line in [IO.File]::ReadLines((Join-Path $BackupDir $row.file))) {
                if (-not $line.Trim()) { continue }
                $o = $line | ConvertFrom-Json
                $sddl = [string]$o.sddl
                try { [void](Invoke-AclHandleEdit -Path $o.path -IsDir ([bool]$o.dir) -Edit { param($acl) $acl.SetSecurityDescriptorSddlForm($sddl, [Security.AccessControl.AccessControlSections]::Access); return $true }) }
                catch { [void]$skipped.Add("$($o.path) ($($_.Exception.Message))") }
            }
        } finally { $script:AclWalkRootFinal = $prevRoot }
    }
    foreach ($s in $skipped) { & $Out "      skipped: $s" }
    return @{ Rows = $rows; Skipped = @($skipped) }
}

function ConvertTo-ProbeParamsJson {
    # The probe's parameters as ONE JSON document (arrays stay arrays): -Credential mode used to build a command line
    # of `-SecretPaths 'a','b'`, which -File delivers as one literal string.
    param([Parameter(Mandatory)][hashtable]$Params)
    return (ConvertTo-Json -InputObject $Params -Depth 6)
}

function Invoke-WithProbeParamsFile {
    # Credential mode: write the probe's parameters to a file in -Dir (an operator-controlled folder the coder can NOT
    # write: the file is readable by the coder only through one explicit read entry, everyone else is cut off), run
    # -Body { param($file) ... }, and ALWAYS delete the file afterwards (try/finally).
    param([Parameter(Mandatory)][string]$Dir, [Parameter(Mandatory)][hashtable]$Params, [Parameter(Mandatory)][string]$CoderSid, [Parameter(Mandatory)][string]$OperatorSid, [Parameter(Mandatory)][scriptblock]$Body)
    $f = Join-Path $Dir ('verify-' + [guid]::NewGuid().ToString('N') + '.params.json')
    try {
        ConvertTo-ProbeParamsJson -Params $Params | Set-Content -LiteralPath $f -Encoding UTF8
        Invoke-IcaclsStep -IcaclsArgs @($f, '/inheritance:r', '/grant:r', '*S-1-5-18:F', "*${OperatorSid}:F", "*${CoderSid}:R")
        & $Body $f
    } finally { if (Test-Path -LiteralPath $f) { Remove-Item -LiteralPath $f -Force -ErrorAction SilentlyContinue } }
}

function Get-OperatorChecklistLines {
    # Printed with every dry run and at the start of every apply.
    @(
        'OPERATOR CHECKLIST (before -Apply):',
        '  1. Pause the fleet: no dispatch may run. The stage checks only the coder-leg task; with containment off a dispatch runs as the operator in these same folders.',
        '  2. Close anything that holds files open under projects, C:\blarai-fleet and the model folders (editors, test runs, a model server reading C:\models): the stage stops, part-way, on a file held exclusively.',
        '  3. Run -DryRun, read it (the model-folder actions included), then -Apply -ExpectPlan <digest> straight after, so the machine cannot change in between.',
        '  4. Keep the path of the FIRST backup folder this stage prints. Undo with -RestoreFrom <that folder> (exact) or -Rollback -From <that folder>. After a second -Apply the newest backup no longer holds the original state.',
        '  5. Afterwards verify with verify-coder-containment.ps1 in scheduled-task mode (the default), not -Credential mode.'
    )
}

function Select-AclRollbackBackup {
    # A bare -Rollback may only pick a backup when that choice is unambiguous. With more than one backup folder the
    # newest does NOT hold the original state (a second -Apply plans from the already-changed machine), so the
    # operator must name the folder: refuse and list them. Returns the folder path.
    param([Parameter(Mandatory)][string]$BackupRoot)
    $all = @(Get-ChildItem -LiteralPath $BackupRoot -Directory -ErrorAction SilentlyContinue | Where-Object { Test-Path -LiteralPath (Join-Path $_.FullName 'plan.json') } | Sort-Object Name)
    if ($all.Count -eq 0) { return '' }
    if ($all.Count -eq 1) { return $all[0].FullName }
    $list = $all | ForEach-Object { $n = @((Get-Content -LiteralPath (Join-Path $_.FullName 'plan.json') -Raw | ConvertFrom-Json)).Count; "    $($_.FullName)   ($n undo list(s))" }
    throw ("-Rollback without -From is refused: $($all.Count) backup folders exist and the newest does not necessarily hold the original state (a second -Apply plans from the changed machine, so its undo lists miss actions such as the model folders). Name the folder: -Rollback -From <folder>; the OLDEST holds the full original undo set:`n" + ($list -join "`n"))
}

function Get-CoderAclPlanView {
    # What the operator is shown, as data: the plan lines (BEFORE, AFTER, commands, undo, links, refusals, and the
    # read-only findings under projects) and a digest of them (first 16 hex of SHA-256 of the lines). -Apply must be given
    # the digest of the plan that was printed; if the machine changed in between, the digest differs and -Apply refuses.
    # FIRST-CLASS UNREADABLE FOLDERS: a folder the reader cannot open is listed with its path and reason in the plan (so it
    # is inside the digest): a reader without the right to see it must not look the same as one that saw nothing.
    param([Parameter(Mandatory)]$Plan, [Parameter(Mandatory)]$Ops, [Parameter(Mandatory)][hashtable]$Safety, $Refused, [Parameter(Mandatory)][string]$CoderSid, [Parameter(Mandatory)][string]$OperatorSid,
          [string]$ProjectsDir = '', [string[]]$GroupSids = @(), [string[]]$GroupErrors = @(), [switch]$SkipOwnerCheck)
    $states = @{}
    foreach ($act in $Ops) { if ($Safety[$act.Path].Ok) { $states[$act.Path] = Read-AclState -Path $act.Path } }
    $names = @{ $CoderSid = 'blarai-coder (the coder account)'; $OperatorSid = 'the operator account' }
    $shown = @($Plan | Where-Object { @($_.Steps).Count -eq 0 -or $states.ContainsKey($_.Path) })
    $lines = @(Format-CoderAclPlan -Plan $shown -States $states -Safety $Safety -Names $names)
    foreach ($r in @($Refused)) { $lines += ''; $lines += "REFUSED (the stage will not run while this stands): $r" }
    $warnings = New-Object System.Collections.ArrayList
    $unreadable = @{}
    if ($ProjectsDir -and $Safety.ContainsKey($ProjectsDir) -and $Safety[$ProjectsDir].Ok) {
        $eff = Find-SidWriteAcesTree -Root $ProjectsDir -Sid $CoderSid -GroupSids $GroupSids -CheckOwner:(-not $SkipOwnerCheck) -MaxHits 200
        foreach ($e in $eff.Errors) { $unreadable[[string]($e -split ' : ', 2)[0]] = [string]$e }
        $grp = @($eff.Hits | Where-Object { $_.Kind -ne 'coder' } | Sort-Object { [bool]($_.Why -match 'inherited') })   # explicit entries first
        if ($grp.Count -gt 0) {
            [void]$warnings.Add("the coder has write access under $ProjectsDir through groups or ownership on $($grp.Count)+ object(s)")
            $lines += ''; $lines += "WARNING - WRITE ACCESS THIS STAGE WILL NOT REMOVE ($($grp.Count) object(s) shown, first 20): the stage removes only entries that NAME the coder. Group entries and ownership stay; removing them is your decision, and -Apply will report them as a finding:"
            foreach ($g in ($grp | Select-Object -First 20)) { $lines += "    $($g.Path)  ($($g.Why))" }
        }
        $pcx = Find-ProtectedChildrenEx -Root $ProjectsDir
        foreach ($e in $pcx.Errors) { $unreadable[[string]($e -split ' : ', 2)[0]] = [string]$e }
        if ($pcx.Hits.Count -gt 0) {
            $lines += ''; $lines += "FOLDERS WITH INHERITANCE SWITCHED OFF under $ProjectsDir (all depths, $($pcx.Hits.Count); first 50): the read entry set on projects does not reach them and the old Modify on them is removed; the coder cannot read them until granted by hand:"
            foreach ($x in ($pcx.Hits | Select-Object -First 50)) { $lines += "    $x" }
        }
    }
    foreach ($ge in @($GroupErrors)) {
        [void]$warnings.Add("the coder's group memberships could not all be read: $ge")
        $lines += ''; $lines += "WARNING - UNKNOWN GROUPS: $ge. Group-based write access for the coder cannot be fully excluded; -Apply will report this as a finding."
    }
    if ($unreadable.Count -gt 0) {
        $lines += ''
        $lines += "UNREADABLE ($($unreadable.Count)): this reader could not open the folders or files below, so the write-access and inheritance-off sections above do NOT cover them. Run the dry run ELEVATED, in the same elevated window as -Apply, and check this line says UNREADABLE (0). Path and reason:"
        foreach ($k in ($unreadable.Keys | Sort-Object | Select-Object -First 50)) { $lines += "    $($unreadable[$k])" }
        [void]$warnings.Add("$($unreadable.Count) folder(s) or file(s) could not be read by this reader")
    }
    $sha = [Security.Cryptography.SHA256]::Create()
    $hex = (($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes(($lines -join "`n"))) | ForEach-Object { $_.ToString('x2') }) -join '')
    return @{ Lines = $lines; Digest = $hex.Substring(0, 16); States = $states; Unreadable = $unreadable.Count; UnreadableList = @($unreadable.Values | Sort-Object); Warnings = @($warnings) }
}

function Invoke-CoderAclStage {
    # The one stage. -Mode DryRun reads and prints (changes NOTHING); Apply backs up, changes, reads back and
    # compares; Rollback runs each action's targeted undo in reverse; Restore puts a saved backup back.
    # Returns @{ Ok; Refused[]; Mismatches[]; Findings[]; BackupDir }. Every target is gated by
    # Test-AclTargetSafe BEFORE any command runs; one refusal stops the whole stage.
    param(
        [Parameter(Mandatory)][ValidateSet('DryRun', 'Apply', 'Rollback', 'Restore')][string]$Mode,
        [string]$CoderSid, [string]$OperatorSid,
        [string]$ProjectsDir = 'C:\Users\mrbla\projects', [string]$WorktreeBase = 'C:\blarai-fleet\worktrees', [string]$LegRoot = '',
        [string[]]$ModelRoots = @('B:\models', 'C:\models', 'C:\Users\mrbla\BlarAI\models'), [string[]]$ProfileCleanupPaths = @('C:\Users\mrbla\BlarAI'),
        [string[]]$ModelReaderSids = @(),
        [string]$BackupDir = '', [string]$RestoreFrom = '', [string]$RollbackFrom = '',
        [string]$ExpectPlan = '', [string]$PlanStoreDir = '', [string[]]$CoderGroupSids = @(), [string[]]$CoderGroupErrors = @(), [switch]$SkipOwnerCheck, [switch]$AllowUnreadable,
        [scriptblock]$Runner = $null, [scriptblock]$Out = { param($l) Write-Host $l },
        [string]$TaskState = ''
    )
    $res = @{ Ok = $false; Refused = @(); Mismatches = @(); Findings = @(); BackupDir = ''; Digest = ''; Warnings = @() }
    if ($Mode -eq 'Restore') {
        if (-not $RestoreFrom) { throw '-Mode Restore needs -RestoreFrom <backup folder>' }
        & $Out "RESTORE from $RestoreFrom"
        $rr = Invoke-AclRestore -BackupDir $RestoreFrom -Runner $Runner -Out $Out
        $res.Ok = (@($rr.Skipped).Count -eq 0); $res.Findings = @($rr.Skipped); return $res
    }
    if (-not $CoderSid -or -not $OperatorSid) { throw 'CoderSid and OperatorSid are required' }
    if ($CoderSid -eq $OperatorSid) { throw 'the coder SID and the operator SID are the same account: refusing (the stage would give the coder the operator rights)' }
    if (@($CoderGroupSids).Count -eq 0) { $gi = Get-CoderGroupInfo -CoderSid $CoderSid; $CoderGroupSids = @($gi.Sids); $CoderGroupErrors = @($gi.Errors) }
    $plan = @(Get-CoderAclPlan -CoderSid $CoderSid -OperatorSid $OperatorSid -ProjectsDir $ProjectsDir -WorktreeBase $WorktreeBase -LegRoot $LegRoot -ModelRoots $ModelRoots -ProfileCleanupPaths $ProfileCleanupPaths -ModelReaderSids $ModelReaderSids)
    $ops = @($plan | Where-Object { @($_.Steps).Count -gt 0 })

    # gate every target first
    $safety = @{}; $refused = New-Object System.Collections.ArrayList
    # EVERY folder the plan names is gated, including one that needs no change: a model folder that is a link is
    # refused even when its (link) access list looks fine
    foreach ($act in @($plan | Where-Object { -not $_.Skipped -and $Mode -ne 'Rollback' })) {
        $useOps = $act.Steps
        $tree = @($useOps | Where-Object { $_.Tree }).Count -gt 0
        $sf = Test-AclTargetSafe -Path $act.Path -Tree:$tree
        $safety[$act.Path] = $sf
        if (-not $sf.Ok) { [void]$refused.Add("$($act.Path): $($sf.Reason)") }
    }
    $res.Refused = @($refused)

    if ($Mode -eq 'DryRun') {
        $view = Get-CoderAclPlanView -Plan $plan -Ops $ops -Safety $safety -Refused $refused -CoderSid $CoderSid -OperatorSid $OperatorSid -ProjectsDir $ProjectsDir -GroupSids $CoderGroupSids -GroupErrors $CoderGroupErrors -SkipOwnerCheck:$SkipOwnerCheck
        & $Out '=== DRY RUN: nothing below has been changed ==='
        foreach ($l in $view.Lines) { & $Out $l }
        $res.Warnings = @($view.Warnings)
        $withhold = ($view.Unreadable -gt 0 -and -not $AllowUnreadable)
        if (-not $withhold) { $res.Digest = $view.Digest }
        if (-not $withhold -and $PlanStoreDir) { New-Item -ItemType Directory -Force $PlanStoreDir | Out-Null; Set-Content -LiteralPath (Join-Path $PlanStoreDir "plan-$($view.Digest).txt") -Value $view.Lines -Encoding UTF8 }
        $bk = @(Get-AclBackupSpecs -Plan $plan)
        & $Out ''
        & $Out 'BACKUP written before any change (so the original state can be put back exactly):'
        foreach ($sp in $bk) { & $Out ("    save the access list of $(if ($sp.Tree) { 'every folder and file under' } else { '' }) $($sp.Path) $(if ($sp.Tree) { '(links are not entered) ' })to <backup folder>\$([IO.Path]::ChangeExtension($sp.File, '.jsonl'))") }
        & $Out 'RESTORE from that backup (rolls everything back to the saved state):'
        & $Out '    provision-coder-acls.ps1 -RestoreFrom "<backup folder>"'
        $treeCounts = @()
        foreach ($act in $ops) {
            if (@($act.Steps | Where-Object { $_.Tree }).Count -gt 0 -and $safety.ContainsKey($act.Path) -and $safety[$act.Path].Ok) {
                $cw = Invoke-NoFollowWalk -Root $act.Path -OnObject { param($p, $isDir) }
                $treeCounts += "  $($act.Path): $($cw.Visited) objects to walk, links not entered: $(@($cw.Links).Count), unreadable: $(@($cw.Errors).Count)"
            }
        }
        if ($treeCounts.Count -gt 0) { & $Out ''; & $Out 'SIZE OF THE TREE WALKS (read-only count):'; foreach ($c in $treeCounts) { & $Out $c } }
        & $Out ''
        foreach ($cl in (Get-OperatorChecklistLines)) { & $Out $cl }
        & $Out ''
        & $Out ''
        if ($withhold) {
            & $Out "NO PLAN DIGEST IS GIVEN: this reader could not open $($view.Unreadable) folder(s) or file(s) (listed above under UNREADABLE), so what it printed is not the whole picture. Run the dry run ELEVATED (the same elevated window as -Apply). If you have read the list and accept it, add -AllowUnreadable: the list is then part of the plan and of the digest."
        } else {
            & $Out "PLAN DIGEST: $($view.Digest)"
            & $Out "  hash of the plan printed above (BEFORE, AFTER, commands, undo, links, findings, unreadable folders). To apply exactly this plan: provision-coder-acls.ps1 -Apply -ExpectPlan $($view.Digest)"
            & $Out "  -Apply re-plans first and REFUSES, printing a diff, if the machine no longer matches what you read."
        }
        & $Out "=== DRY RUN COMPLETE: $($ops.Count) change(s) planned, $($refused.Count) refusal(s). NOTHING WAS CHANGED. ==="
        $res.Ok = ($refused.Count -eq 0 -and -not $withhold); return $res
    }

    if ($refused.Count -gt 0) { throw "refusing to run the stage, no change made: $($refused -join ' | ')" }

    if ($Mode -eq 'Rollback') {
        if (-not $RollbackFrom) { throw '-Mode Rollback needs -RollbackFrom <backup folder> (the folder an earlier Apply wrote: it holds the undo lists planned from the state BEFORE the change)' }
        & $Out "=== ROLLBACK: undoing the stage from $RollbackFrom, last action first ==="
        $saved = @(Read-AclUndoPlan -BackupDir $RollbackFrom)
        $rb = New-Object System.Collections.ArrayList
        foreach ($act in $saved) { $sf = Test-AclTargetSafe -Path $act.Path; if (-not $sf.Ok) { [void]$rb.Add("$($act.Path): $($sf.Reason)") } }
        if ($rb.Count -gt 0) { throw "refusing to roll back, no change made: $($rb -join ' | ')" }
        $rev = @($saved); [array]::Reverse($rev)
        foreach ($act in $rev) { & $Out "  undo: $($act.Title)"; $null = Invoke-CoderAclAction -Action $act -UseUndo -Runner $Runner -Out $Out }
        $res.Ok = $true; return $res
    }

    # Apply: only the plan the operator was shown
    if (-not $ExpectPlan) { throw '-Apply needs -ExpectPlan <digest>: run -DryRun, read the plan, and pass the PLAN DIGEST it printed (no plan was shown, so nothing is applied)' }
    $view = Get-CoderAclPlanView -Plan $plan -Ops $ops -Safety $safety -Refused $refused -CoderSid $CoderSid -OperatorSid $OperatorSid -ProjectsDir $ProjectsDir -GroupSids $CoderGroupSids -GroupErrors $CoderGroupErrors -SkipOwnerCheck:$SkipOwnerCheck
    $res.Digest = $view.Digest
    if ($view.Digest -ne $ExpectPlan) {
        & $Out "REFUSED: the plan now is NOT the plan you were shown (digest $($view.Digest), you passed $ExpectPlan). Nothing was changed."
        $stored = if ($PlanStoreDir) { Join-Path $PlanStoreDir "plan-$ExpectPlan.txt" } else { '' }
        if ($stored -and (Test-Path -LiteralPath $stored)) {
            $d = @(Compare-Object -ReferenceObject @(Get-Content -LiteralPath $stored) -DifferenceObject @($view.Lines))
            & $Out "  what changed since you read it ('<=' was shown, '=>' is now), first 60 lines:"
            foreach ($x in ($d | Select-Object -First 60)) { & $Out "    $($x.SideIndicator) $($x.InputObject)" }
        } else { & $Out "  the plan you were shown is not stored here ($stored): run -DryRun again and read it." }
        throw "refusing to apply: the plan differs from the one shown (digest $($view.Digest) <> $ExpectPlan)"
    }
    if ($TaskState -eq 'Running') { throw 'the coder-leg task is Running: the stage removes and re-adds the coder access, so no coder job may be in flight. Stop it and run again.' }
    if (-not $BackupDir) { throw '-BackupDir is required for Apply' }
    $res.BackupDir = $BackupDir
    foreach ($cl in (Get-OperatorChecklistLines)) { & $Out $cl }
    & $Out "=== APPLY: backing up to $BackupDir ==="
    try { $null = Write-AclBackup -Plan $plan -BackupDir $BackupDir -Runner $Runner }
    catch { throw "the backup failed BEFORE any change was made, so nothing was changed and nothing needs restoring: $($_.Exception.Message)" }
    $mism = New-Object System.Collections.ArrayList
    $doing = ''
    try {
        foreach ($act in $ops) {
            $doing = "$($act.Title) ($($act.Path))"
            & $Out "  [$($act.Issue)] $($act.Title)"
            $before = Read-AclState -Path $act.Path
            $expected = Get-AclActionAfter -Before $before -Action $act
            $after = Invoke-CoderAclAction -Action $act -Runner $Runner -Out $Out
            if ($null -ne $after -and $null -eq $Runner) {
                $cmp = Compare-AclStates -Expected $expected -Actual $after
                if (-not $cmp.Match) { foreach ($d in $cmp.Diff) { [void]$mism.Add("$($act.Path): $d") } }
            }
        }
    } catch {
        $why = $_.Exception.Message
        $cmdText = "provision-coder-acls.ps1 -RestoreFrom `"$BackupDir`""
        & $Out "=== APPLY FAILED PART-WAY at: $doing"
        & $Out "    reason: $why"
        & $Out "    Some folders were already changed. The original access lists are saved in: $BackupDir"
        & $Out "    Put everything back exactly with:  $cmdText"
        throw "apply failed part-way at '$doing': $why. The original access lists are saved in '$BackupDir'; restore them exactly with: $cmdText"
    }
    $res.Mismatches = @($mism)
    # the operator-side proof, read back from disk
    $f = New-Object System.Collections.ArrayList
    if ($null -eq $Runner) {
        & $Out '  read-back: walking the projects tree for any write access the coder still has, by its own entries, by the groups it belongs to, and by owning an object (links are not entered)...'
        $wk = Find-SidWriteAcesTree -Root $ProjectsDir -Sid $CoderSid -GroupSids $CoderGroupSids -CheckOwner:(-not $SkipOwnerCheck) -Out $Out
        foreach ($h in $wk.Hits) {
            if ($h.Kind -eq 'coder') { [void]$f.Add("coder still has write access: $($h.Path) ($($h.Why))") }
            else { [void]$f.Add("the coder can still write through $(if ($h.Kind -eq 'group') { 'a group entry' } else { 'ownership' }): $($h.Path) ($($h.Why)). This stage removes only entries that name the coder; removing group entries or changing owners is YOUR decision.") }
        }
        foreach ($e in $wk.Errors) { [void]$f.Add("read-back could not read: $e") }
        foreach ($ge in @($CoderGroupErrors)) { [void]$f.Add("the coder's group memberships could not all be read ($ge): group-based write access cannot be excluded") }
        & $Out "  read-back: $($wk.Visited) objects checked, $(@($wk.Links).Count) link(s) not entered"
        $fleetRoot = Split-Path $WorktreeBase -Parent
        $keep = @($OperatorSid, 'S-1-5-18', 'S-1-5-32-544', 'S-1-3-0', $CoderSid)
        foreach ($h in (Find-SidWriteAces -Root $fleetRoot -Sid $CoderSid -Depth 0)) { [void]$f.Add("coder still has write access on the fleet root itself: $($h.Path) ($($h.Why))") }
        foreach ($h in (Find-ForeignWriteAces -Root $fleetRoot -KeepSids $keep -Depth 2)) { [void]$f.Add("fleet folder writable by another account: $($h.Path) ($($h.Why))") }
        foreach ($m in $ModelRoots) {
            if (-not (Test-Path -LiteralPath $m)) { continue }
            foreach ($h in (Find-ForeignWriteAces -Root $m -KeepSids @($OperatorSid, 'S-1-5-18', 'S-1-5-32-544', 'S-1-3-0') -Depth 3)) { [void]$f.Add("model folder writable by another account: $($h.Path) ($($h.Why))") }
        }
    }
    $res.Findings = @($f)
    $res.Ok = ($mism.Count -eq 0 -and $f.Count -eq 0)
    foreach ($m in $mism) { & $Out "  MISMATCH (the real result differs from the printed AFTER): $m" }
    foreach ($x in $f) { & $Out "  FINDING: $x" }
    if ($res.Ok) { & $Out '=== APPLY COMPLETE: every changed folder matches its printed AFTER, and the read-back found no remaining write access ===' }
    else { & $Out '=== APPLY FINISHED WITH PROBLEMS (above). Nothing was rolled back automatically: run -Rollback or -RestoreFrom the backup. ===' }
    return $res
}
