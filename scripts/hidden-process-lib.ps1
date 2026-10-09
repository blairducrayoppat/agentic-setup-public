#requires -Version 7.0
<#
.SYNOPSIS
  The ONLY way the provisioning tests and helpers start a child process: never with a visible window. Also
  starts a child with a DE-ELEVATED token when the caller is elevated, still without a window. Dot-source it; it
  has no side effects on load beyond compiling a small type on first use.

.DESCRIPTION
  Invoke-HiddenProcess      System.Diagnostics.Process with CreateNoWindow = $true, UseShellExecute = $false,
                            output redirected. Returns @{ ExitCode; Stdout; Stderr; TimedOut }.
  Invoke-HiddenProcess -DeElevate
                            when the caller is elevated: CreateRestrictedToken(LUA_TOKEN) (Administrators becomes
                            deny-only), medium integrity, CreateProcessAsUser with CREATE_NO_WINDOW and
                            SW_HIDE. Replaces `runas /trustlevel`, which opens a visible console. When the caller is
                            not elevated it is the plain hidden launch (the token is already standard).
  Find-VisibleLaunches      LINT over script text: every Start-Process must say -WindowStyle Hidden or
                            -NoNewWindow; every ProcessStartInfo needs CreateNoWindow; no direct `& pwsh|powershell|cmd|python`
                            or runas.exe call (go through Invoke-HiddenProcess). Returns the offending lines.
  Get-NewVisibleConsoleWindows
                            processes named pwsh/powershell/cmd/python/conhost-like with a main window that were not
                            in a baseline set (the check each run ends with).
#>

$script:HiddenTypeLoaded = $false
function Initialize-HiddenLaunchType {
    if ($script:HiddenTypeLoaded -or ('BlarHiddenLaunch' -as [type])) { $script:HiddenTypeLoaded = $true; return }
    Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
using System.Text;
public static class BlarHiddenLaunch {
    const uint TOKEN_ASSIGN_PRIMARY = 0x1, TOKEN_DUPLICATE = 0x2, TOKEN_QUERY = 0x8, TOKEN_ADJUST_DEFAULT = 0x80;
    const uint LUA_TOKEN = 0x4, DISABLE_MAX_PRIVILEGE = 0x1;
    const uint CREATE_NO_WINDOW = 0x08000000, CREATE_UNICODE_ENVIRONMENT = 0x400;
    const int STARTF_USESHOWWINDOW = 0x1; const short SW_HIDE = 0;
    const int TokenIntegrityLevel = 25; const uint SE_GROUP_INTEGRITY = 0x20;
    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    struct STARTUPINFO { public int cb; public string lpReserved, lpDesktop, lpTitle; public int dwX, dwY, dwXSize, dwYSize, dwXCountChars, dwYCountChars, dwFillAttribute, dwFlags; public short wShowWindow, cbReserved2; public IntPtr lpReserved2, hStdInput, hStdOutput, hStdError; }
    [StructLayout(LayoutKind.Sequential)]
    struct PROCESS_INFORMATION { public IntPtr hProcess, hThread; public int dwProcessId, dwThreadId; }
    [StructLayout(LayoutKind.Sequential)]
    struct SID_AND_ATTRIBUTES { public IntPtr Sid; public uint Attributes; }
    [StructLayout(LayoutKind.Sequential)]
    struct TOKEN_MANDATORY_LABEL { public SID_AND_ATTRIBUTES Label; }
    [DllImport("advapi32.dll", SetLastError = true)] static extern bool OpenProcessToken(IntPtr p, uint acc, out IntPtr tok);
    [DllImport("advapi32.dll", SetLastError = true)] static extern bool CreateRestrictedToken(IntPtr tok, uint flags, uint dsc, IntPtr sd, uint dpc, IntPtr priv, uint rsc, IntPtr sr, out IntPtr nt);
    [DllImport("advapi32.dll", SetLastError = true)] static extern bool SetTokenInformation(IntPtr tok, int cls, IntPtr info, int len);
    [DllImport("advapi32.dll", SetLastError = true, CharSet = CharSet.Unicode)] static extern bool ConvertStringSidToSid(string s, out IntPtr sid);
    [DllImport("advapi32.dll", SetLastError = true, CharSet = CharSet.Unicode)] static extern bool CreateProcessAsUser(IntPtr tok, string app, StringBuilder cmd, IntPtr pa, IntPtr ta, bool inherit, uint flags, IntPtr env, string cwd, ref STARTUPINFO si, out PROCESS_INFORMATION pi);
    [DllImport("kernel32.dll", SetLastError = true)] static extern uint WaitForSingleObject(IntPtr h, uint ms);
    [DllImport("kernel32.dll", SetLastError = true)] static extern bool GetExitCodeProcess(IntPtr h, out uint code);
    [DllImport("kernel32.dll", SetLastError = true)] static extern bool TerminateProcess(IntPtr h, uint code);
    [DllImport("kernel32.dll")] static extern bool CloseHandle(IntPtr h);
    [DllImport("kernel32.dll")] static extern IntPtr GetCurrentProcess();
    [DllImport("kernel32.dll")] static extern IntPtr LocalFree(IntPtr h);

    // Start commandLine with a LUA (standard-user) restricted copy of this process's token, medium integrity, no window.
    // Returns the exit code, or -1 on timeout (the process is terminated), or throws.
    public static int StartRestricted(string commandLine, string workDir, int timeoutMs) {
        IntPtr tok, rtok, sid = IntPtr.Zero, info = IntPtr.Zero;
        if (!OpenProcessToken(GetCurrentProcess(), TOKEN_ASSIGN_PRIMARY | TOKEN_DUPLICATE | TOKEN_QUERY | TOKEN_ADJUST_DEFAULT, out tok)) throw new System.ComponentModel.Win32Exception(Marshal.GetLastWin32Error(), "OpenProcessToken");
        try {
            if (!CreateRestrictedToken(tok, LUA_TOKEN | DISABLE_MAX_PRIVILEGE, 0, IntPtr.Zero, 0, IntPtr.Zero, 0, IntPtr.Zero, out rtok)) throw new System.ComponentModel.Win32Exception(Marshal.GetLastWin32Error(), "CreateRestrictedToken");
            try {
                if (!ConvertStringSidToSid("S-1-16-8192", out sid)) throw new System.ComponentModel.Win32Exception(Marshal.GetLastWin32Error(), "ConvertStringSidToSid");
                TOKEN_MANDATORY_LABEL tml = new TOKEN_MANDATORY_LABEL(); tml.Label.Sid = sid; tml.Label.Attributes = SE_GROUP_INTEGRITY;
                int sz = Marshal.SizeOf(tml); info = Marshal.AllocHGlobal(sz); Marshal.StructureToPtr(tml, info, false);
                if (!SetTokenInformation(rtok, TokenIntegrityLevel, info, sz)) throw new System.ComponentModel.Win32Exception(Marshal.GetLastWin32Error(), "SetTokenInformation(integrity)");
                STARTUPINFO si = new STARTUPINFO(); si.cb = Marshal.SizeOf(si); si.dwFlags = STARTF_USESHOWWINDOW; si.wShowWindow = SW_HIDE;
                PROCESS_INFORMATION pi;
                StringBuilder cl = new StringBuilder(commandLine);
                if (!CreateProcessAsUser(rtok, null, cl, IntPtr.Zero, IntPtr.Zero, false, CREATE_NO_WINDOW | CREATE_UNICODE_ENVIRONMENT, IntPtr.Zero, workDir, ref si, out pi)) throw new System.ComponentModel.Win32Exception(Marshal.GetLastWin32Error(), "CreateProcessAsUser");
                try {
                    uint w = WaitForSingleObject(pi.hProcess, (uint)timeoutMs);
                    if (w != 0) { TerminateProcess(pi.hProcess, 1); return -1; }
                    uint code; GetExitCodeProcess(pi.hProcess, out code); return (int)code;
                } finally { CloseHandle(pi.hProcess); CloseHandle(pi.hThread); }
            } finally { if (info != IntPtr.Zero) Marshal.FreeHGlobal(info); if (sid != IntPtr.Zero) LocalFree(sid); CloseHandle(rtok); }
        } finally { CloseHandle(tok); }
    }
}
'@
    $script:HiddenTypeLoaded = $true
}

function Test-CallerElevated {
    return ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function ConvertTo-ArgumentLine {
    param([string[]]$Arguments)
    ($Arguments | ForEach-Object { if ($_ -match '[\s"]' -or $_ -eq '') { '"' + ($_ -replace '(\\*)"', '$1$1\"' -replace '(\\+)$', '$1$1') + '"' } else { $_ } }) -join ' '
}

function Invoke-HiddenProcess {
    # Start FilePath with ArgumentList, never with a window; wait up to TimeoutSec. Returns @{ ExitCode; Stdout; Stderr; TimedOut }.
    # -DeElevate: when the caller is elevated, start with a standard-user restricted token (still no window; output
    # is not captured in that mode, the child writes files).
    param([Parameter(Mandatory)][string]$FilePath, [string[]]$ArgumentList = @(), [int]$TimeoutSec = 600, [switch]$DeElevate, [string]$WorkingDirectory = '')
    if ($DeElevate -and (Test-CallerElevated)) {
        Initialize-HiddenLaunchType
        $cl = '"' + $FilePath + '" ' + (ConvertTo-ArgumentLine $ArgumentList)
        $wd = if ($WorkingDirectory) { $WorkingDirectory } else { [IO.Path]::GetTempPath() }
        $code = [BlarHiddenLaunch]::StartRestricted($cl, $wd, $TimeoutSec * 1000)
        return @{ ExitCode = $code; Stdout = ''; Stderr = ''; TimedOut = ($code -eq -1) }
    }
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $FilePath
    foreach ($a in $ArgumentList) { [void]$psi.ArgumentList.Add($a) }
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true
    $psi.WindowStyle = [System.Diagnostics.ProcessWindowStyle]::Hidden
    $psi.RedirectStandardOutput = $true; $psi.RedirectStandardError = $true; $psi.RedirectStandardInput = $true
    if ($WorkingDirectory) { $psi.WorkingDirectory = $WorkingDirectory }
    $p = [System.Diagnostics.Process]::Start($psi)
    $p.StandardInput.Close()
    $so = $p.StandardOutput.ReadToEndAsync(); $se = $p.StandardError.ReadToEndAsync()
    $timedOut = $false
    if (-not $p.WaitForExit($TimeoutSec * 1000)) { $timedOut = $true; try { $p.Kill($true) } catch { } }
    else { $p.WaitForExit() }
    return @{ ExitCode = $(if ($timedOut) { -1 } else { $p.ExitCode }); Stdout = [string]$so.GetAwaiter().GetResult(); Stderr = [string]$se.GetAwaiter().GetResult(); TimedOut = $timedOut }
}

function Find-VisibleLaunches {
    # LINT over script text: returns the offending lines as "line N: reason: text". Quoted strings and comments are
    # not code. A child process must be started with Invoke-HiddenProcess; anything that can show a window is flagged.
    # The rules are table-driven in the tests (positives and negatives). Backtick line continuations are joined first.
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Text)
    $bad = New-Object System.Collections.ArrayList
    $psiCount = 0; $cnwCount = 0
    $hostNames = @('cmd', 'powershell', 'pwsh', 'python[\d.]*', 'py[\d.]*', ('w' + 'script'), ('c' + 'script'), ('ms' + 'hta'), 'conhost', 'wt', 'runas') -join '|'
    $wmiClass = 'Win32_' + 'Process'
    $sep = '(^|[;|{(]\s*|&&\s*|\|\|\s*|&\s*)'
    $joined = New-Object System.Collections.ArrayList
    $raw = $Text -split "`r?`n"; $buf = ''; $start = 1
    for ($i = 0; $i -lt $raw.Count; $i++) {
        if ($buf -eq '') { $start = $i + 1 }
        if ($raw[$i] -match '`\s*$') { $buf += ($raw[$i] -replace '`\s*$', ' '); continue }
        [void]$joined.Add(@{ No = $start; Text = ($buf + $raw[$i]) }); $buf = ''
    }
    if ($buf -ne '') { [void]$joined.Add(@{ No = $start; Text = $buf }) }
    $blank = { param($s) [regex]::Replace($s, "'[^']*'|`"[^`"]*`"", { param($m) '"' + (' ' * [math]::Max(0, $m.Value.Length - 2)) + '"' }) }
    $exeVars = @{}
    foreach ($j in $joined) { if ($j.Text -match ('^\s*\$(\w+)\s*=.*(?i:\b(' + $hostNames + ')\b)')) { $exeVars[$Matches[1].ToLowerInvariant()] = $true } }
    $inBlock = $false
    foreach ($j in $joined) {
        $l = $j.Text; $t = $l.Trim(); $n = $j.No
        if ($inBlock) { if ($t -match '#>') { $inBlock = $false }; continue }
        if ($t.StartsWith('<#')) { if ($t -notmatch '#>') { $inBlock = $true }; continue }
        if ($t.StartsWith('#')) { continue }
        $b = & $blank $l
        $ci = $b.IndexOf('#')
        $code = if ($ci -ge 0) { $b.Substring(0, $ci) } else { $b }
        $rawCode = if ($ci -ge 0) { $l.Substring(0, $ci) } else { $l }
        if ($code -match 'ProcessStartInfo') { $psiCount++ }
        if ($code -match 'CreateNoWindow\s*=\s*\$true') { $cnwCount++ }
        if ($code -match ($sep + '(?i:start-process|start|saps)(?![-\w])') -or $code -match '(?i)\bStart-Process\b') {
            if ($code -match '(?i)-Verb\b') { [void]$bad.Add("line ${n}: Start-Process -Verb shows a prompt or window: $t") }
            elseif ($code -notmatch '(?i)-W(indowStyle)?[:\s]+Hidden\b' -and $code -notmatch '(?i)-NoNewWindow\b') { [void]$bad.Add("line ${n}: Start-Process/start without -WindowStyle Hidden or -NoNewWindow: $t") }
        }
        if ($code -match '&\s*\(' -and $code -match '(?i)get-command') { [void]$bad.Add("line ${n}: the call operator on a looked-up executable (use Invoke-HiddenProcess): $t") }
        if ($code -match '(?i)&\s*\$(PSHOME|env:ComSpec)\b') { [void]$bad.Add("line ${n}: the call operator on a host path (use Invoke-HiddenProcess): $t") }
        if ($code -match ($sep + '(?:\.[\\/]|[\w:\\/.~-]*[\\/])?[\w.~-]+\.(?i:cmd|bat)(\s|$)')) { [void]$bad.Add("line ${n}: a batch file started directly (it opens a console): $t") }
        if ($code -match '(?i)\[(System\.)?(Diagnostics\.)?Process\]::new\s*\(' -or $code -match '(?i)New-Object\s+(System\.)?Diagnostics\.Process\b(?!StartInfo)') { [void]$bad.Add("line ${n}: a Process object built by hand (use Invoke-HiddenProcess): $t") }
        if ($code -match '(?i)\[(System\.)?Diagnostics\.Process\]::Start\s*\((?!\s*\$psi\b)') { [void]$bad.Add("line ${n}: a static process start (use Invoke-HiddenProcess): $t") }
        if ($code -match '(?i)\b(Invoke-Expression|iex)\b') { [void]$bad.Add("line ${n}: text run as a command: $t") }
        if ($code -match ($sep + "(?i:$hostNames)(\.exe)?(?!\s*=)(\s|`$)")) { [void]$bad.Add("line ${n}: a console program or script host started directly (use Invoke-HiddenProcess): $t") }
        elseif ($rawCode -match ('(?i)(^\s*|[;|{(]\s*|&&\s*|\|\|\s*)&\s*[''"][^''"]*[\/]?(' + $hostNames + ')(\.exe)?[''"]')) { [void]$bad.Add("line ${n}: a console program started through the call operator with a quoted path (use Invoke-HiddenProcess): $t") }
        elseif ($code -match '&\s*\$(\w+)') {
            $v = $Matches[1].ToLowerInvariant()
            if ($exeVars.ContainsKey($v) -or $v -match '^(pw|pwsh|powershell|exe|py|python|cmd|interp\w*)$') { [void]$bad.Add("line ${n}: the call operator on a variable that holds an executable (use Invoke-HiddenProcess): $t") }
        }
        if ($code -match ($sep + '(?i:invoke-item|ii)(\s|$)')) { [void]$bad.Add("line ${n}: Invoke-Item opens a window: $t") }
        if ($code -match '(?i)UseShellExecute\s*=\s*\$true') { [void]$bad.Add("line ${n}: UseShellExecute = `$true: $t") }
        if ($code -match '(?i)\.ShellExecute\s*\(' -or $code -match '(?i)Shell\.Application') { [void]$bad.Add("line ${n}: Shell.Application ShellExecute: $t") }
        if ($rawCode -match ('(?i)W' + 'Script\.Shell') -and $code -match '(?i)\.(Run|Exec)\s*\(') { [void]$bad.Add("line ${n}: script-host Run/Exec: $t") }
        if ($code -match "(?i)$wmiClass" -and $code -match '(?i)\bCreate\b|Invoke-CimMethod|Invoke-WmiMethod') { [void]$bad.Add("line ${n}: a WMI/CIM process Create starts a process outside this tool: $t") }
    }
    if ($psiCount -gt $cnwCount) { [void]$bad.Add("ProcessStartInfo used $psiCount time(s) in code but CreateNoWindow = `$true appears $cnwCount time(s)") }
    return @($bad)
}

function Get-VisibleConsoleProcessIds {
    @(Get-Process -ErrorAction SilentlyContinue | Where-Object { $_.MainWindowHandle -ne 0 -and $_.ProcessName -in 'pwsh', 'powershell', 'cmd', 'python', 'python3', 'conhost', 'WindowsTerminal', 'OpenConsole' } | ForEach-Object { $_.Id })
}

function Get-NewVisibleConsoleWindows {
    param([Parameter(Mandatory)][int[]]$BaselineIds)
    @(Get-Process -ErrorAction SilentlyContinue | Where-Object { $_.MainWindowHandle -ne 0 -and $_.ProcessName -in 'pwsh', 'powershell', 'cmd', 'python', 'python3', 'conhost', 'WindowsTerminal', 'OpenConsole' -and $BaselineIds -notcontains $_.Id } | ForEach-Object { "$($_.ProcessName) pid $($_.Id) '$($_.MainWindowTitle)'" })
}
