#requires -Version 7.0
<#
.SYNOPSIS
  The boot-surface sweep (#1695): which things that start with the machine at high privilege can be rewritten
  by a low-privilege account. Dot-source it; it has NO side effects on load.

.DESCRIPTION
  WHY. Account-level containment (ACP-01 / ADR-045) is only as strong as the weakest thing that runs as SYSTEM
  (or as an administrator) and whose code a low-privilege account can replace: the coder writes the file, the
  next boot runs it with the higher token. This library finds those.

  IN SCOPE
    services      Automatic and Delayed-start services whose account is LocalSystem, LocalService or
                  NetworkService (an empty account name is LocalSystem).
    scheduled     every ENABLED task whose principal is SYSTEM, LocalService, NetworkService, the
    tasks         Administrators group, or a member of it (or whose principal cannot be resolved: unknown is
                  treated as privileged).
  FOR EACH, the following are checked for write access by a non-administrator principal (WriterSids: Everyone,
  Authenticated Users, Users, Guests, Power Users, Interactive, Batch, Network, Local account, This Organization,
  the coder SID and every group it belongs to, plus -ExtraWriterSids):
    - the executable, and for a task action every script/binary the arguments name (-File x, "x.ps1", ...);
    - the directory that holds it (any add-file / write / delete right on the folder itself);
    - every ancestor folder, against the rights that let a folder be renamed away and replaced (delete,
      delete-child, change permissions, take ownership, generic all/write);
    - for an UNQUOTED service path with spaces, the folder of every earlier candidate Windows would try
      (C:\Program.exe, C:\Program Files\X.exe, ...) against add-file;
    - the owner of each object: an owner can rewrite its own access list.

  INHERIT-ONLY ENTRIES. An entry flagged inherit-only does not apply to the object that carries it; it is a
  template for children. A folder's inherit-only entry is therefore skipped when judging that folder (the child
  file carries the inherited copy, and is judged itself). Masks are read as unsigned 32-bit: the generic read and
  execute bits an inherit-only entry carries unexpanded are not write rights.

  FAIL-CLOSED. An object whose access list cannot be read is an offender (kind 'unreadable'), an unresolvable
  path is an offender (kind 'unresolved-path'). A sweep that enumerated no services or no tasks is blind and
  Get-BootSurfaceVerdict fails it; so does an absent result.

  NOT COVERED (stated, not assumed): DLLs a binary loads from elsewhere; the service-control DACL and the
  service registry key (who may re-point a service); Manual-start services, drivers and Run keys; COM-handler
  task actions; a Deny entry (a Deny is ignored, which can only over-report).

  SEAMS (every system read can be replaced, so the logic is tested offline): -ServiceSource, -TaskSource,
  -AclReader, -PathExists, -AdminMemberSids, -SidResolver, -CommandResolver.
#>

$script:BootWriteMask = [int64](2 + 4 + 16 + 64 + 256 + 65536 + 262144 + 524288 + 0x10000000 + 0x40000000)
# what lets a folder be renamed away or have its permissions/owner rewritten (no add-file, no write-attributes)
$script:BootReplaceMask = [int64](64 + 65536 + 262144 + 524288 + 0x10000000 + 0x40000000)
# what lets a file be planted in a folder (write-data on a folder is add-file)
$script:BootPlantMask = [int64](2 + 262144 + 524288 + 0x10000000 + 0x40000000)
# what lets a code file be replaced or planted through its OWN containing folder: add-file, add-subdirectory (a
# <program>.local folder beside the program redirects its DLL loads), delete-child, delete, permissions, owner. ANCESTORS above
# that folder use BootReplaceMask instead, so the default add-subdirectory right on C:\ is not a finding unless the program lives in C:\.
$script:BootFolderMask = [int64](2 + 4 + 64 + 65536 + 262144 + 524288 + 0x10000000 + 0x40000000)
# what lets a MISSING folder be created (add-file and add-subdirectory): judged on the nearest folder that exists
$script:BootCreateMask = [int64](2 + 4 + 262144 + 524288 + 0x10000000 + 0x40000000)
$script:BootInterpreters = '^(cmd|powershell|pwsh|py|pyw|python[0-9.]*w?|node|dotnet|msbuild|php|java|javaw|ruby|perl|mshta|rundll32|wscript|cscript|bash|sh|wsl)(\.exe)?$'
$script:BootDefaultWriterSids = @('S-1-1-0', 'S-1-5-11', 'S-1-5-32-545', 'S-1-5-32-546', 'S-1-5-32-547', 'S-1-5-4', 'S-1-5-3', 'S-1-5-2', 'S-1-5-113', 'S-1-5-15', 'S-1-2-0')
$script:BootPrivilegedSids = @('S-1-5-18', 'S-1-5-19', 'S-1-5-20', 'S-1-5-32-544')
$script:BootScriptExtensions = '\.(ps1|psm1|psd1|cmd|bat|vbs|vbe|js|jse|wsf|py|pyw|exe|dll|com|scr|msi|jar|sh|lnk|hta)$'

# ---- the pure parts -------------------------------------------------------------------------------------

function Test-BootMaskWritable {
    # $true when -Mask holds any right in -Against. The mask is the 32-bit access mask as an unsigned number.
    param([Parameter(Mandatory)][int64]$Mask, [int64]$Against = $script:BootWriteMask)
    return (($Mask -band [int64]4294967295 -band $Against) -ne 0)
}

function Get-BootAccountClass {
    # 'service-account' for LocalSystem / LocalService / NetworkService (or an empty name), 'other' for a named account
    param([AllowNull()][AllowEmptyString()][string]$StartName)
    $n = ([string]$StartName).Trim().ToLowerInvariant()
    if ($n -eq '') { return 'service-account' }
    if ($n -in @('localsystem', 'nt authority\system', 'nt authority\localservice', 'nt authority\local service', 'nt authority\networkservice', 'nt authority\network service')) { return 'service-account' }
    return 'other'
}

function Split-BootServicePath {
    # A service ImagePath -> @{ Exe; Quoted; Candidates[] }. Exe is the file Windows runs when the path is quoted,
    # or the first prefix at a space boundary that names an existing file when it is not; Candidates are the file
    # paths Windows tries BEFORE the real one (the plantable ones, empty when quoted or without spaces).
    # -PathExists is a seam (default Test-Path -PathType Leaf).
    param([Parameter(Mandatory)][AllowEmptyString()][string]$PathName, [scriptblock]$PathExists = $null)
    if (-not $PathExists) { $PathExists = { param($p) Test-Path -LiteralPath $p -PathType Leaf } }
    $raw = [Environment]::ExpandEnvironmentVariables($PathName.Trim())
    if ($raw -match '^\\SystemRoot\\') { $raw = (Join-Path $env:SystemRoot $raw.Substring(12)) }
    elseif ($raw -match '^(?i)system32\\') { $raw = (Join-Path $env:SystemRoot $raw) }
    if ($raw.StartsWith('"')) {
        $end = $raw.IndexOf('"', 1)
        if ($end -lt 0) { return @{ Exe = ''; Quoted = $true; Candidates = @(); Problem = 'unterminated quote'; Args = '' } }
        return @{ Exe = $raw.Substring(1, $end - 1); Quoted = $true; Candidates = @(); Problem = ''; Args = $raw.Substring($end + 1).Trim() }
    }
    $tokens = @($raw -split ' ')
    $cands = New-Object System.Collections.ArrayList
    for ($i = 1; $i -le $tokens.Count; $i++) {
        $prefix = ($tokens[0..($i - 1)] -join ' ')
        if ($prefix.Trim() -eq '') { continue }
        $file = if ([IO.Path]::GetExtension($prefix) -eq '') { $prefix + '.exe' } else { $prefix }
        if (& $PathExists $file) { return @{ Exe = $file; Quoted = $false; Candidates = @($cands); Problem = ''; Args = $(if ($i -lt $tokens.Count) { ($tokens[$i..($tokens.Count - 1)] -join ' ').Trim() } else { '' }) } }
        [void]$cands.Add($file)
    }
    # nothing exists: the whole text before the first argument-looking token is the best name; every prefix is a candidate
    return @{ Exe = ''; Quoted = $false; Candidates = @($cands); Problem = 'no file with that name exists'; Args = '' }
}

function Get-BootLongName {
    # 8.3 short name -> long name (GetLongPathNameW); the input unchanged when it does not exist or has no short part
    param([Parameter(Mandatory)][string]$Path)
    if ($Path -notmatch '~') { return $Path }
    if (-not ('BlarBootPath' -as [type])) {
        Add-Type -TypeDefinition 'using System; using System.Text; using System.Runtime.InteropServices; public static class BlarBootPath { [DllImport("kernel32.dll", CharSet = CharSet.Unicode)] static extern uint GetLongPathNameW(string s, StringBuilder b, uint n); public static string Long(string p) { StringBuilder sb = new StringBuilder(4096); uint n = GetLongPathNameW(p, sb, 4096); return (n == 0 || n >= 4096) ? p : sb.ToString(); } }'
    }
    return [BlarBootPath]::Long($Path)
}

function Resolve-BootProgram {
    # The program text as Windows would see it: environment variables expanded, quotes, trailing dots and spaces dropped
    # (Win32 ignores them), forward slashes turned into backslashes, an 8.3 short name turned into the long one. Pure but for -LongName.
    param([AllowEmptyString()][string]$Execute = '', [scriptblock]$LongName = { param($p) Get-BootLongName -Path $p })
    $e = [Environment]::ExpandEnvironmentVariables($Execute.Trim().Trim('"')).Trim().TrimEnd('.', ' ')
    if ($e -match '^([A-Za-z]:|[\\/]{2})') { $e = $e.Replace('/', '\') }
    if ($e -match '~') { $e = [string](& $LongName $e) }
    return $e
}

function ConvertTo-BootNormalArguments {
    # The arguments as the program will see them, for the shells whose escaping differs: cmd.exe (caret escapes, the outer
    # quote pair after /c or /k), PowerShell (backtick escapes; a backtick-space stays inside its word). Everywhere: $env:NAME is
    # expanded, and forward slashes inside drive-rooted and UNC paths become backslashes. Returns the text with U+0001 standing for
    # an escaped space (the tokenizer restores it). Pure.
    param([AllowEmptyString()][string]$Program = '', [AllowEmptyString()][string]$Arguments = '')
    $leaf = [IO.Path]::GetFileName($Program)
    $a = [Environment]::ExpandEnvironmentVariables($Arguments)
    $a = [regex]::Replace($a, '\$env:(\w+)', { param($m) $v = [Environment]::GetEnvironmentVariable($m.Groups[1].Value); if ($null -ne $v) { $v } else { $m.Value } })
    if ($leaf -match '^cmd(\.exe)?$') {
        $a = $a -replace '\^(.)', '$1'
        $a = $a -replace '(?i)^(\s*/[ck]\s+)"(.*"[^"]*)"\s*$', '$1$2'
    }
    elseif ($leaf -match '^(powershell|pwsh)(\.exe)?$') {
        $a = $a -replace '`\s', ([string][char]1)
        $a = $a -replace '`(.)', '$1'
    }
    # doubled quotes around a word are one level of quoting; a lone empty pair (the title of start) stays
    $a = [regex]::Replace($a, '""(?=[^"\s])|(?<=[^"\s])""', '"')
    # rundll32 <dll>,<entry> (also ,#ordinal, a quoted dll, trailing arguments): the entry point is not part of the path
    $a = [regex]::Replace($a, '(\.(?:dll|ocx|cpl|drv))(["'']?)\s*,\s*[#\w@?]+(?![\w.])', '$1$2')
    $a = [regex]::Replace($a, '[A-Za-z]:[\\/](?:(?!\s[-/])[^"''<>|*?\r\n])*', { param($m) $m.Value.Replace('/', '\') })
    $a = [regex]::Replace($a, '(?<![:\w])//[^\s"'']+', { param($m) $m.Value.Replace('/', '\') })
    return $a
}

function Test-BootWorkingDirMatters {
    # $true when the working folder can decide what runs: the program is an interpreter, or the arguments name a
    # relative word that is not a switch (a relative script, or a file that exists in the working folder).
    # A relative word counts when it is a script/binary name, or when it names a file that exists in the working folder
    # (-Exists is a seam: { param($path) bool }); an interpreter always counts.
    # NOT COVERED, deliberately: a working folder the program itself resolves things from when the program is NOT an interpreter and
    # its arguments name nothing relative (a plain exe started in a user-writable folder). Judging every exe there flags only the
    # Firefox Background Update task (an admin-member account, firefox.exe in Program Files, working folder under
    # ProgramData\Mozilla-*\updates which grants Users full control), and Firefox removes the working folder from its DLL search.
    # check 25 does not certify that case.
    param([AllowEmptyString()][string]$Execute = '', [AllowEmptyString()][string]$Arguments = '', [AllowEmptyString()][string]$WorkingDirectory = '', [scriptblock]$Exists = $null, [scriptblock]$LongName = { param($p) Get-BootLongName -Path $p })
    $prog = Resolve-BootProgram -Execute $Execute -LongName $LongName
    $leaf = [IO.Path]::GetFileName($prog)
    if ($leaf -match $script:BootInterpreters) { return $true }
    $norm = (ConvertTo-BootNormalArguments -Program $prog -Arguments $Arguments).Replace([string][char]1, ' ')
    foreach ($m in [regex]::Matches($norm, '"([^"]+)"|''([^'']+)''|(\S+)')) {
        $tok = if ($m.Groups[1].Success) { $m.Groups[1].Value } elseif ($m.Groups[2].Success) { $m.Groups[2].Value } else { $m.Groups[3].Value }
        $tok = $tok.TrimEnd('.', ' ')
        if ($tok -notmatch '^[-/]' -and $tok -notmatch '^([A-Za-z]:[\\/]|\\\\|%)') {
            if ($tok -match $script:BootScriptExtensions) { return $true }
            if ($Exists -and $WorkingDirectory -and $tok -notmatch '[:*?<>|]' -and (& $Exists ([IO.Path]::Combine($WorkingDirectory, $tok)))) { return $true }
        }
    }
    return $false
}

function Get-BootActionPaths {
    # A program + arguments -> the code paths it names: the executable; every path in the arguments that is a script or
    # binary (by extension) or follows -File/-f/-FilePath; the command word of each command in the arguments whatever
    # its extension (cmd /c C:\drop\run); every quoted path inside a command string; and, with a working folder, every
    # relative script word resolved against it. Redirect targets are not code. The text is first read the way the shell reads
    # it (see ConvertTo-BootNormalArguments); trailing dots and spaces, forward slashes, %VAR% and $env:VAR are resolved.
    # Pure but for -LongName. Returns @{ Path; Role }[].
    param([AllowEmptyString()][string]$Execute = '', [AllowEmptyString()][string]$Arguments = '', [AllowEmptyString()][string]$WorkingDirectory = '', [scriptblock]$LongName = { param($p) Get-BootLongName -Path $p })
    $out = New-Object System.Collections.ArrayList
    $exe = Resolve-BootProgram -Execute $Execute -LongName $LongName
    if ($exe) { [void]$out.Add(@{ Path = $exe; Role = 'executable' }) }
    $args2 = (ConvertTo-BootNormalArguments -Program $exe -Arguments $Arguments) -replace '(\d?>>?|<)\s*("[^"]*"|\S+)', ' '
    $wd = [Environment]::ExpandEnvironmentVariables($WorkingDirectory).Trim().Trim('"')
    $seen = @{}
    $sp = [string][char]1
    $add = { param($p, $role) $p = $p.Replace($sp, ' ').Trim().Trim('"', "'").TrimEnd('.', ' '); if ($p -match '^([A-Za-z]:|[\\/]{2})') { $p = $p.Replace('/', '\') }; if ($p -and -not $seen.ContainsKey($p.ToLowerInvariant())) { $seen[$p.ToLowerInvariant()] = 1; [void]$out.Add(@{ Path = $p; Role = $role }) } }
    $skipWords = '^(call|start|start-process|invoke-item|invoke-expression|iex|&|\.|-filepath|-wait|/wait|/b|/min|-nonewwindow|-command|-c|/c|/k|-noprofile|-noninteractive|-executionpolicy|bypass)$'
    $rooted = '^([A-Za-z]:\\|\\\\)'
    $launchers = '^(/c|/k|-command|-c|-filepath|call|start|start-process|invoke-item)$'
    $prevTok = ''; $tokIndex = 0
    foreach ($m in [regex]::Matches($args2, '"([^"]+)"|''([^'']+)''|(\S+)')) {
        $tok = if ($m.Groups[1].Success) { $m.Groups[1].Value } elseif ($m.Groups[2].Success) { $m.Groups[2].Value } else { $m.Groups[3].Value }
        # `start "" X` and `start "title" X`: cmd takes the first quoted word after start as a window title; the command is the next word
        if ($prevTok -eq 'start' -and ($m.Groups[1].Success -or $m.Groups[2].Success -or $tok -match '^(""|'''')$')) { continue }
        # a lone token is a command only when it comes first or right after a launcher word (cmd /c X); a path after a data switch (--log-file X) is data
        $loneIsCommand = ($tokIndex -eq 0) -or ($prevTok -match $launchers)
        $prevTok = $tok; $tokIndex++
        # quoted paths inside a command string: -Command "& { . 'C:\a b\run.ps1' }"
        foreach ($q in [regex]::Matches($tok, '''([^'']+)''|"([^"]+)"')) {
            $qv = if ($q.Groups[1].Success) { $q.Groups[1].Value } else { $q.Groups[2].Value }
            $qv = $qv.Replace($sp, ' ').TrimEnd('.', ' ')
            if ($qv -match $rooted -and $qv -match $script:BootScriptExtensions) { & $add $qv 'argument' }
        }
        # a token like -File:C:\x.ps1 or /c C:\x.cmd
        $tok = $tok -replace '^(?i)(-file|-f|-filepath|-command|-c|/c|/k)[:=]?', ''
        foreach ($piece in @($tok -split '[;&|]' | ForEach-Object { $_.Trim().Trim('"', "'", '&', ' ') })) {
            if (-not $piece) { continue }
            $pieceR = $piece.Replace($sp, ' ').TrimEnd('.', ' ')
            if ($pieceR -match $rooted -and ($pieceR -match $script:BootScriptExtensions)) { & $add $pieceR 'argument'; continue }
            $words = @($piece -split '\s+' | ForEach-Object { $_.Replace($sp, ' ').Trim().Trim('"', "'").TrimEnd('.', ' ') } | Where-Object { $_ })
            # the command word: the first word that is not a switch or a launcher word
            $cmdWord = $words | Where-Object { $_ -notmatch $skipWords -and $_ -notmatch '^[-/]' } | Select-Object -First 1
            if ($cmdWord -and $cmdWord -match $rooted -and ($words.Count -gt 1 -or $loneIsCommand)) { & $add $cmdWord 'argument' }
            foreach ($w in $words) {
                if ($w -notmatch $script:BootScriptExtensions) { continue }
                if ($w -match $rooted) { & $add $w 'argument' }
                elseif ($wd -and $w -notmatch '[:*?<>|]') { & $add ([IO.Path]::Combine($wd, $w)) 'relative-script' }
            }
        }
    }
    # the token right after -File / -f / -FilePath, whatever its extension
    foreach ($m in [regex]::Matches($args2, '(?i)(?:^|\s)-(?:file|f|filepath)(?:\s+|[:=])(?:"([^"]+)"|''([^'']+)''|(\S+))')) {
        $p = if ($m.Groups[1].Success) { $m.Groups[1].Value } elseif ($m.Groups[2].Success) { $m.Groups[2].Value } else { $m.Groups[3].Value }
        if ($p -match $rooted) { & $add $p 'script' }
        elseif ($wd) { & $add ([IO.Path]::Combine($wd, $p)) 'script' }
    }
    return @($out)
}

function Test-BootAcePlainWrite {
    # one access-list entry, judged against -Against, for an object that is a FILE or a FOLDER; -WriterSids names the
    # low-privilege principals. Inherit-only entries do not apply to the object that carries them.
    param([Parameter(Mandatory)]$Ace, [Parameter(Mandatory)][string[]]$WriterSids, [int64]$Against = $script:BootWriteMask)
    if ([string]$Ace.Type -ne 'Allow') { return $false }
    if ($Ace.InheritOnly) { return $false }
    if ($WriterSids -notcontains [string]$Ace.Sid) { return $false }
    return (Test-BootMaskWritable -Mask ([int64]$Ace.Mask) -Against $Against)
}

# ---- reading the system ---------------------------------------------------------------------------------

function Read-BootAcl {
    # The access list of one path as plain data: @{ Exists; IsDir; Owner; Aces[]{Sid;Type;Mask;InheritOnly}; Error }.
    # A path that exists but cannot be read returns Exists = $true with Error set (fail-closed upstream).
    param([Parameter(Mandatory)][string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) { return @{ Exists = $false; IsDir = $false; Owner = ''; Aces = @(); Error = '' } }
    try {
        $item = Get-Item -LiteralPath $Path -Force -ErrorAction Stop
        $acl = Get-Acl -LiteralPath $Path -ErrorAction Stop
        $owner = ''
        try { $owner = [string]$acl.GetOwner([Security.Principal.SecurityIdentifier]).Value } catch { $owner = '' }
        $aces = @($acl.GetAccessRules($true, $true, [Security.Principal.SecurityIdentifier]) | ForEach-Object {
                @{ Sid = [string]$_.IdentityReference.Value; Type = [string]$_.AccessControlType
                    Mask = ([int64]([int]$_.FileSystemRights) -band [int64]4294967295)
                    InheritOnly = (([int]$_.PropagationFlags -band 2) -ne 0) }
            })
        return @{ Exists = $true; IsDir = [bool]$item.PSIsContainer; Owner = $owner; Aces = $aces; Error = '' }
    } catch { return @{ Exists = $true; IsDir = $false; Owner = ''; Aces = @(); Error = $_.Exception.Message } }
}

function Get-BootServiceList {
    # every service as @{ Name; StartMode; StartName; PathName; DelayedAutoStart } (default source: Win32_Service)
    return @(Get-CimInstance -ClassName Win32_Service -ErrorAction Stop | ForEach-Object {
            @{ Name = [string]$_.Name; StartMode = [string]$_.StartMode; StartName = [string]$_.StartName; PathName = [string]$_.PathName }
        })
}

function Get-BootTaskList {
    # every scheduled task as @{ Path; Name; Enabled; UserId; GroupId; RunLevel; Actions[]{Execute;Arguments;WorkingDirectory} }
    return @(Get-ScheduledTask -ErrorAction Stop | ForEach-Object {
            $t = $_
            @{ Path = [string]$t.TaskPath; Name = [string]$t.TaskName; Enabled = ([string]$t.State -ne 'Disabled')
                UserId = [string]$t.Principal.UserId; GroupId = [string]$t.Principal.GroupId; RunLevel = [string]$t.Principal.RunLevel
                Actions = @($t.Actions | Where-Object { $null -ne $_.PSObject.Properties['Execute'] } | ForEach-Object { @{ Execute = [string]$_.Execute; Arguments = [string]$_.Arguments; WorkingDirectory = [string]$_.WorkingDirectory } }) }
        })
}

function Get-BootAdminMemberSids {
    # SIDs of the members of the local Administrators group (one level of nested local groups expanded);
    # throws when the group cannot be read (the caller then treats every principal as privileged)
    $sids = New-Object System.Collections.ArrayList
    foreach ($m in @(Get-LocalGroupMember -SID 'S-1-5-32-544' -ErrorAction Stop)) {
        [void]$sids.Add([string]$m.SID.Value)
        if ([string]$m.ObjectClass -eq 'Group' -and $m.SID.Value -like 'S-1-5-21-*') {
            try { foreach ($n in @(Get-LocalGroupMember -SID $m.SID.Value -ErrorAction Stop)) { [void]$sids.Add([string]$n.SID.Value) } } catch { }
        }
    }
    return @($sids)
}

function Resolve-BootAccountSid {
    # an account name or SID text -> SID string, '' when it cannot be resolved
    param([AllowEmptyString()][string]$Name)
    $n = ([string]$Name).Trim()
    if (-not $n) { return '' }
    if ($n -match '^S-1-\d+(-\d+)+$') { return $n }
    try { return [string]([Security.Principal.NTAccount]$n).Translate([Security.Principal.SecurityIdentifier]).Value } catch { }
    if ($n -match '^\.\\') { $n = "$env:COMPUTERNAME\" + $n.Substring(2) }
    try { return [string]([Security.Principal.NTAccount]"$env:COMPUTERNAME\$n").Translate([Security.Principal.SecurityIdentifier]).Value } catch { return '' }
}

function Resolve-BootCommand {
    # a bare command name -> the file task scheduler would run: System32, the Windows folder, then PATH; '' if none
    param([Parameter(Mandatory)][string]$Name)
    $sys = if ($env:SystemRoot) { $env:SystemRoot } else { 'C:\Windows' }
    foreach ($d in @((Join-Path $sys 'System32'), $sys) + @($env:PATH -split ';')) {
        if (-not $d) { continue }
        foreach ($ext in '', '.exe') { $p = Join-Path $d ($Name + $ext); if (Test-Path -LiteralPath $p -PathType Leaf) { return $p } }
    }
    return ''
}

# ---- the sweep ------------------------------------------------------------------------------------------

function Get-BootAncestors {
    # parent folders of -Path from the nearest to the drive root
    param([Parameter(Mandatory)][string]$Path)
    $out = New-Object System.Collections.ArrayList
    $p = $Path
    while ($true) {
        $parent = [IO.Path]::GetDirectoryName($p)
        if (-not $parent -or $parent -eq $p) { break }
        [void]$out.Add($parent); $p = $parent
    }
    return @($out)
}

function Find-CoderWritableBootSurface {
    # Sweep. Returns @{ Offenders[]; Errors[]; ServicesEnumerated; TasksEnumerated; ServicesInScope; TasksInScope; Complete }.
    # An offender is @{ Kind; Name; RunAs; Start; Command; Path; Role; Why }. Throws when services or tasks cannot be
    # enumerated at all (the caller must treat a thrown sweep as no result, which fails).
    param(
        [string]$CoderSid = '', [string[]]$GroupSids = @(), [string[]]$ExtraWriterSids = @(),
        [scriptblock]$ServiceSource = { Get-BootServiceList }, [scriptblock]$TaskSource = { Get-BootTaskList },
        [scriptblock]$AclReader = { param($p) Read-BootAcl -Path $p }, [scriptblock]$PathExists = $null,
        [scriptblock]$AdminMemberSids = { Get-BootAdminMemberSids }, [scriptblock]$SidResolver = { param($n) Resolve-BootAccountSid -Name $n },
        [scriptblock]$CommandResolver = { param($n) Resolve-BootCommand -Name $n }
    )
    $writers = @($script:BootDefaultWriterSids + @($ExtraWriterSids) + @($GroupSids) + $(if ($CoderSid) { @($CoderSid) } else { @() }) | Where-Object { $_ } | Sort-Object -Unique)
    $offenders = New-Object System.Collections.ArrayList
    $errors = New-Object System.Collections.ArrayList
    $aclCache = @{}
    $read = { param($p) $k = $p.ToLowerInvariant(); if (-not $aclCache.ContainsKey($k)) { $aclCache[$k] = & $AclReader $p }; $aclCache[$k] }

    # judge one object; returns the reasons it is writable (empty = fine)
    $judge = {
        param($path, $against, $what)
        $reasons = New-Object System.Collections.ArrayList
        $a = & $read $path
        if (-not $a.Exists) { return @{ Reasons = @(); Missing = $true } }
        if ($a.Error) { [void]$reasons.Add("access list unreadable ($($a.Error))"); return @{ Reasons = @($reasons); Missing = $false; Unreadable = $true } }
        foreach ($ace in @($a.Aces)) {
            if (Test-BootAcePlainWrite -Ace $ace -WriterSids $writers -Against $against) { [void]$reasons.Add("$what grants write rights (0x{0:X}) to $($ace.Sid)" -f [int64]$ace.Mask) }
        }
        if ($a.Owner -and ($writers -contains $a.Owner)) { [void]$reasons.Add("$what is owned by $($a.Owner) (an owner can rewrite its own access list)") }
        return @{ Reasons = @($reasons); Missing = $false }
    }
    # judge a code file: the file, its folder, every ancestor
    $judgeCode = {
        param($file, $item)
        $hits = New-Object System.Collections.ArrayList
        $r = & $judge $file $script:BootWriteMask 'the file'
        foreach ($w in $r.Reasons) { [void]$hits.Add(@{ Path = $file; Why = $w; Kind = $(if ($r.Unreadable) { 'unreadable' } else { 'writable' }) }) }
        $fileMissing = [bool]$r.Missing
        $dir = [IO.Path]::GetDirectoryName($file)
        if ($dir) {
            $r = & $judge $dir $script:BootFolderMask 'the folder'
            if ($r.Missing) {
                # the folder is gone too: whoever can create it decides what runs, so the nearest folder that exists is judged
                $near = $dir
                while ($near -and -not (& $read $near).Exists) { $near = [IO.Path]::GetDirectoryName($near) }
                if (-not $near) { [void]$hits.Add(@{ Path = $dir; Why = 'neither the file nor any folder above it exists'; Kind = 'unresolved-path' }) }
                else {
                    $r = & $judge $near $script:BootCreateMask 'the nearest existing folder'
                    foreach ($w in $r.Reasons) { [void]$hits.Add(@{ Path = $near; Why = "$file and $dir do not exist and can be created: $w"; Kind = $(if ($r.Unreadable) { 'unreadable' } else { 'writable' }) }) }
                    $r = @{ Reasons = @() }
                }
            }
            foreach ($w in $r.Reasons) { [void]$hits.Add(@{ Path = $dir; Why = $(if ($fileMissing) { "the file $file does not exist; $w" } else { $w }); Kind = $(if ($r.Unreadable) { 'unreadable' } else { 'writable' }) }) }
            foreach ($anc in (Get-BootAncestors -Path $dir)) {
                $r = & $judge $anc $script:BootReplaceMask 'an ancestor folder'
                foreach ($w in $r.Reasons) { [void]$hits.Add(@{ Path = $anc; Why = $w; Kind = $(if ($r.Unreadable) { 'unreadable' } else { 'writable' }) }) }
            }
        }
        return @($hits)
    }

    $services = @(& $ServiceSource)
    $tasks = @(& $TaskSource)
    if ($services.Count -eq 0) { throw 'the service list came back empty: the sweep is blind' }
    if ($tasks.Count -eq 0) { throw 'the scheduled-task list came back empty: the sweep is blind' }

    $adminSids = $null
    try { $adminSids = @(& $AdminMemberSids) } catch { [void]$errors.Add("Administrators group members could not be read ($($_.Exception.Message)): every account is treated as privileged") }

    # one action (program + arguments + working folder) -> offenders through -Emit { param($kind, $path, $role, $why) }
    $judgeAction = {
        param($execute, $arguments, $wd, $emit)
        $wdX = [Environment]::ExpandEnvironmentVariables([string]$wd).Trim().Trim('"')
        if ($wdX -and (Test-BootWorkingDirMatters -Execute $execute -Arguments $arguments -WorkingDirectory $wdX -Exists { param($f) $fa = & $read $f; ($fa.Exists -and -not $fa.IsDir) })) {
            $r = & $judge $wdX $script:BootPlantMask 'the working folder'
            foreach ($w in $r.Reasons) { & $emit $(if ($r.Unreadable) { 'unreadable' } else { 'writable' }) $wdX 'working-folder' "$w (what it runs may be resolved from there)" }
        }
        foreach ($p in (Get-BootActionPaths -Execute $execute -Arguments $arguments -WorkingDirectory $wdX)) {
            $path = [Environment]::ExpandEnvironmentVariables([string]$p.Path)
            if (-not [IO.Path]::IsPathRooted($path)) {
                if ($p.Role -eq 'executable' -and $path -notmatch '[\\/]') {
                    $resolved = [string](& $CommandResolver $path)
                    if (-not $resolved) { & $emit 'unresolved-path' $path 'executable' "the command '$path' cannot be resolved to a file"; continue }
                    $path = $resolved
                } else { & $emit 'unresolved-path' $path ([string]$p.Role) 'the path is relative and cannot be resolved'; continue }
            }
            if ($p.Role -ne 'executable' -and (& $read $path).IsDir) { continue }   # a folder named in the arguments is data, not code
            foreach ($h in (& $judgeCode $path $null)) { & $emit $h.Kind $h.Path ([string]$p.Role) $h.Why }
        }
    }

    $svcScope = 0
    foreach ($s in $services) {
        if (([string]$s.StartMode) -notin @('Auto', 'Automatic', 'Delayed', 'Auto Start')) { continue }
        if ((Get-BootAccountClass -StartName $s.StartName) -ne 'service-account') {
            # a named account counts when it is (or may be) an administrator: a member of the group, unresolvable, or the membership unknown
            $acct = [string](& $SidResolver ([string]$s.StartName))
            if ($acct -and $null -ne $adminSids -and ($adminSids -notcontains $acct) -and ($script:BootPrivilegedSids -notcontains $acct)) { continue }
        }
        $svcScope++
        $cmd = [string]$s.PathName
        $sp = Split-BootServicePath -PathName $cmd -PathExists $PathExists
        $add = { param($kind, $path, $role, $why) [void]$offenders.Add(@{ Kind = $kind; Name = [string]$s.Name; RunAs = $(if ($s.StartName) { [string]$s.StartName } else { 'LocalSystem' }); Start = [string]$s.StartMode; Command = $cmd; Path = $path; Role = $role; Why = $why }) }
        if (-not $sp.Exe -and -not $sp.Candidates) { & $add 'unresolved-path' $cmd 'executable' "the service path cannot be resolved ($($sp.Problem))"; continue }
        foreach ($c in @($sp.Candidates)) {
            $cd = [IO.Path]::GetDirectoryName($c)
            if (-not $cd) { continue }
            $r = & $judge $cd $script:BootPlantMask 'the folder'
            foreach ($w in $r.Reasons) { & $add $(if ($r.Unreadable) { 'unreadable' } else { 'unquoted-path' }) $cd 'unquoted-candidate' "unquoted path: Windows tries $c first; $w" }
        }
        if (-not $sp.Exe) { & $add 'unresolved-path' $cmd 'executable' "the service path cannot be resolved ($($sp.Problem))"; continue }
        & $judgeAction $sp.Exe $sp.Args '' $add
    }

    $taskScope = 0
    foreach ($t in $tasks) {
        if (-not $t.Enabled) { continue }
        $uid = [string]$t.UserId; $gid = [string]$t.GroupId
        $userSid = if ($uid) { [string](& $SidResolver $uid) } else { '' }
        $groupSid = if ($gid) { [string](& $SidResolver $gid) } else { '' }
        $priv = $false; $runAs = if ($uid) { $uid } else { $gid }
        if (($uid -and -not $userSid) -or ($gid -and -not $groupSid) -or (-not $uid -and -not $gid)) { $priv = $true }   # unknown = privileged
        elseif ($userSid -and ($script:BootPrivilegedSids -contains $userSid)) { $priv = $true }
        elseif ($groupSid -eq 'S-1-5-32-544') { $priv = $true }
        elseif ($userSid -and ($null -eq $adminSids -or ($adminSids -contains $userSid))) { $priv = $true }
        if (-not $priv) { continue }
        $taskScope++
        $taskFullName = "$($t.Path)$($t.Name)"
        foreach ($act in @($t.Actions)) {
            $cmdText = ("$($act.Execute) $($act.Arguments)").Trim()
            $add = { param($kind, $pp, $role, $why) [void]$offenders.Add(@{ Kind = $kind; Name = $taskFullName; RunAs = $runAs; Start = 'task'; Command = $cmdText; Path = $pp; Role = $role; Why = $why }) }
            & $judgeAction ([string]$act.Execute) ([string]$act.Arguments) ([string]$act.WorkingDirectory) $add
        }
    }
    $uniq = @{}
    $list = New-Object System.Collections.ArrayList
    foreach ($o in $offenders) { $k = "$($o.Kind)|$($o.Name)|$($o.Path)|$($o.Why)"; if (-not $uniq.ContainsKey($k)) { $uniq[$k] = 1; [void]$list.Add($o) } }
    return @{ Offenders = @($list); Errors = @($errors); ServicesEnumerated = $services.Count; TasksEnumerated = $tasks.Count
        ServicesInScope = $svcScope; TasksInScope = $taskScope; Complete = $true }
}

function Get-BootSurfaceVerdict {
    # PURE. The pass/fail the verify script acts on. Pass only for a complete, non-blind result with no offenders;
    # an absent result ($null) FAILS. Returns @{ Pass; Failed[]; Detail; Offenders[] }.
    # Errors in the result (e.g. the Administrators membership could not be read) FAIL it too: the sweep then ran on
    # assumptions, and a pass would read as certainty.
    param([AllowNull()]$Result, [string]$ErrorText = '')
    $name = 'check25-no-coder-writable-boot-surface'
    if ($null -eq $Result) { return @{ Pass = $false; Failed = @($name); Offenders = @(); Detail = "the boot-surface sweep produced no result$(if ($ErrorText) { ": $ErrorText" })" } }
    if (-not $Result.Complete -or [int]$Result.ServicesEnumerated -le 0 -or [int]$Result.TasksEnumerated -le 0) {
        return @{ Pass = $false; Failed = @($name); Offenders = @(); Detail = 'the boot-surface sweep is incomplete or blind (no services or no tasks were enumerated)' }
    }
    $off = @($Result.Offenders)
    $errs = @($Result.Errors | Where-Object { $_ })
    if ($errs.Count -gt 0 -and $off.Count -eq 0) {
        return @{ Pass = $false; Failed = @($name); Offenders = @(); Detail = "the boot-surface sweep had $($errs.Count) error(s) and cannot certify: $($errs -join ' | ')" }
    }
    if ($off.Count -gt 0) {
        $first = $off | Select-Object -First 3 | ForEach-Object { "$($_.Kind) $($_.Name) [$($_.RunAs)]: $($_.Path) - $($_.Why)" }
        return @{ Pass = $false; Failed = @($name); Offenders = $off; Detail = "$($off.Count) coder-writable high-privilege boot item(s); first: $($first -join ' | ')" }
    }
    return @{ Pass = $true; Failed = @(); Offenders = @(); Detail = "0 coder-writable high-privilege boot items ($($Result.ServicesInScope) auto-start services and $($Result.TasksInScope) enabled privileged tasks swept of $($Result.ServicesEnumerated) / $($Result.TasksEnumerated) enumerated)" }
}
