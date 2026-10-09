#requires -Version 5.1
<#
.SYNOPSIS
  The file-queue + polled-result contract between the elevated orchestrator and the de-elevated
  coder leg (#775 ACP-01 Stage 4). Dot-source it; it defines the contract, spawns nothing.

.DESCRIPTION
  The scheduled-task-as-coder seam (PHASE1 §5.3 / ACP-01 §3.3) de-elevates the coder leg STRUCTURALLY:
  the elevated orchestrator cannot hand the coder-account task opencode's stdio, so it talks to the
  coder leg over FILES instead — exactly the pattern the nightly battery already uses (queue files in,
  result files polled). This module is the single source of truth for that contract, shared by:
    * the orchestrator side (enqueue a job, poll for its result),
    * the coder-leg side (coder-leg-run.ps1: claim the oldest job, run it, write the result),
    * verify-coder-containment.ps1 (enqueue a 'probe' job, poll the result — proving the coder token).

  Layout (under the dual-SID shared fleet tree both the operator SID and the coder SID can Modify —
  provision-coder-account.ps1 creates + grants it; it is OUTSIDE the operator profile so the profile
  default-deny stays intact):

      C:\blarai-fleet\coder-leg\
        queue\    job-<id>.json           # orchestrator writes; coder claims (rename -> .claimed)
        results\  job-<id>.result.json    # coder writes; orchestrator polls, then deletes

  Job schema (JSON):
    { "id": "...", "kind": "dispatch" | "probe", "created": "<iso>",
      # kind=dispatch:
      "workdir": "...", "model": "local/coder-30b", "prompt_file": "...", "log_path": "...",
      "timeout_sec": 3600, "idle_sec": 600, "max_steps": 45, "spin_steps": 10,
      # kind=probe (verify): the 4 containment checks
      "probe": { "secret_paths": ["..."], "loopback_url": "http://127.0.0.1:8000/v3/models",
                 "expected_sid": "S-1-5-...",
                 "write_deny_dirs": ["..."], "source_git_repos": ["..."], "read_files": ["..."], "worktree_paths": ["..."],
                 "proxy_url": "http://127.0.0.1:8099/v3/models", "operator_deny_paths": ["..."], "toolchain_exes": ["..."],
                 "config_dir": "...", "extra_write_deny_dirs": ["..."], "check_config": true } }

  Result schema (JSON): { "id": "...", "kind": "...", "ok": <bool>, "ran_as_sid": "...",
                          "ran_as_user": "...", "result": <driver-envelope-or-probe-results>, "error": "" }

  Nothing here runs on its own; the orchestrator only enqueues + triggers the coder-leg task when
  configs/fleet-driver.json says containment = restricted_account. With 'off' the queue is never
  written and the task is never started.
#>

# The dual-SID shared root (kept in ONE place; provision-coder-account.ps1 creates + grants it).
# Overridable via $env:BLARAI_CODER_LEG_ROOT for offline verify/smoke-tests ONLY — production leaves it
# unset, so the live path is the hardcoded shared tree both SIDs can Modify.
$script:CoderLegRoot    = if ($env:BLARAI_CODER_LEG_ROOT) { $env:BLARAI_CODER_LEG_ROOT } else { 'C:\blarai-fleet\coder-leg' }
$script:CoderLegQueue   = Join-Path $script:CoderLegRoot 'queue'
$script:CoderLegResults = Join-Path $script:CoderLegRoot 'results'
# Staging dirs for the fused dispatch leg (prompt in, transcript out): under the SAME dual-SID root so
# the coder reads the prompt and writes its log without any grant outside the shared tree.
$script:CoderLegPrompts = Join-Path $script:CoderLegRoot 'prompts'
$script:CoderLegLogs    = Join-Path $script:CoderLegRoot 'logs'

function Get-CoderLegPaths {
    [pscustomobject]@{ Root = $script:CoderLegRoot; Queue = $script:CoderLegQueue; Results = $script:CoderLegResults
                       Prompts = $script:CoderLegPrompts; Logs = $script:CoderLegLogs }
}

function Initialize-CoderLegQueue {
    New-Item -ItemType Directory -Force $script:CoderLegQueue   | Out-Null
    New-Item -ItemType Directory -Force $script:CoderLegResults | Out-Null
    New-Item -ItemType Directory -Force $script:CoderLegPrompts | Out-Null
    New-Item -ItemType Directory -Force $script:CoderLegLogs    | Out-Null
}

function New-CoderLegJobId {
    "job-$(Get-Date -Format 'yyyyMMdd-HHmmss')-$([guid]::NewGuid().ToString('N').Substring(0,8))"
}

function Test-CoderLegJobId {
    # The ONLY job id shape the operator generates (New-CoderLegJobId). Anything else (a wildcard, a path
    # separator, another suffix) is refused before it can name a file.
    param($Id)
    return ([string]$Id -cmatch '^job-\d{8}-\d{6}-[0-9a-f]{8}$')
}

function Write-OperatorFileExclusive {
    # Create a NEW file with the text, exclusively (CreateNew, no sharing): it never overwrites, appends to or
    # writes through an existing path, so a hard link or link planted at that name is an error, not a write
    # into some other file. UTF-8 without a BOM.
    param([Parameter(Mandatory)][string]$LiteralPath, [Parameter(Mandatory)][AllowEmptyString()][string]$Text)
    $bytes = (New-Object System.Text.UTF8Encoding($false)).GetBytes($Text)
    $fs = [IO.File]::Open($LiteralPath, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
    try { $fs.Write($bytes, 0, $bytes.Length) } finally { $fs.Dispose() }
}

function Add-CoderLegJob {
    # Orchestrator side: write a job to the queue. Returns the job id. The id must be a generated one; the
    # file is created exclusively (temp + move without overwrite) so nothing already at that name is
    # written through or replaced.
    param([Parameter(Mandatory)][hashtable]$Job)
    Initialize-CoderLegQueue
    if (-not $Job.id) { $Job.id = New-CoderLegJobId }
    if (-not (Test-CoderLegJobId $Job.id)) { throw "refusing job id '$($Job.id)': not a generated job id." }
    if (-not $Job.created) { $Job.created = (Get-Date).ToString('o') }
    $path = Join-Path $script:CoderLegQueue "$($Job.id).json"
    # Write atomically (temp + move) so the coder side never claims a half-written job.
    $tmp = "$path.tmp"
    Write-OperatorFileExclusive -LiteralPath $tmp -Text ($Job | ConvertTo-Json -Depth 8)
    [IO.File]::Move($tmp, $path)
    return $Job.id
}

function Get-NextCoderLegJob {
    # Coder side: atomically CLAIM the oldest unclaimed job (rename to .claimed so a second worker
    # cannot grab it). Returns @{ Job=<obj>; ClaimPath=<path> } or $null when the queue is empty.
    Initialize-CoderLegQueue
    $candidates = Get-ChildItem -LiteralPath $script:CoderLegQueue -Filter 'job-*.json' -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -notlike '*.claimed' } | Sort-Object CreationTime
    foreach ($f in $candidates) {
        $claim = "$($f.FullName).claimed"
        try {
            Move-Item -LiteralPath $f.FullName -Destination $claim -ErrorAction Stop   # atomic claim
        } catch { continue }   # someone else won the race; try the next
        try {
            $job = ConvertFrom-StrictJsonBytes -Bytes ([IO.File]::ReadAllBytes($claim)) -Schema $script:CoderLegJobSchema -What 'the job file'
            # the job names ITSELF: its id must be the file's own name (no id confusion between files)
            if ("$($f.Name)" -cne "$($job.id).json") { throw "strict JSON: job id '$($job.id)' does not match its file name '$($f.Name)'" }
            if ($job.kind -ceq 'dispatch') {
                foreach ($req in 'workdir', 'model', 'prompt_file', 'log_path', 'timeout_sec', 'idle_sec', 'max_steps', 'spin_steps') {
                    if ($null -eq $job.PSObject.Properties[$req]) { throw "strict JSON: a dispatch job is missing '$req'" }
                }
            }
            return @{ Job = $job; ClaimPath = $claim }
        } catch {
            # Unreadable job -> park it aside so it never blocks the queue.
            Move-Item -LiteralPath $claim -Destination "$claim.bad" -Force -ErrorAction SilentlyContinue
            continue
        }
    }
    return $null
}

function Write-CoderLegResult {
    # Coder side: write the result and drop the claim.
    param([Parameter(Mandatory)][hashtable]$Result, [string]$ClaimPath)
    Initialize-CoderLegQueue
    if (-not $Result.id) { throw 'result needs an id' }
    $path = Join-Path $script:CoderLegResults "$($Result.id).result.json"
    $tmp = "$path.tmp"
    ($Result | ConvertTo-Json -Depth 12) | Set-Content -LiteralPath $tmp -Encoding UTF8
    Move-Item -LiteralPath $tmp -Destination $path -Force
    if ($ClaimPath -and (Test-Path -LiteralPath $ClaimPath)) { Remove-Item -LiteralPath $ClaimPath -ErrorAction SilentlyContinue }
    return $path
}

function Wait-CoderLegResult {
    # Orchestrator/verify side: poll for a job's result, up to -TimeoutSec. Returns the parsed
    # result object, or $null on timeout. Deletes the result file on read (consume-once).
    # -ExpectedOwnerSid binds the file to its writer: a result whose OWNER is another SID, or that was
    # created before -NotBefore, is a forgery or a stale file and THROWS (the file is left in place).
    # The owner of a file cannot be set by a writer who lacks the right to give it away, so this is the
    # part of the binding a forger cannot supply; it is complete only with a results dir that only the coder
    # can write (#1686).
    param([Parameter(Mandatory)][string]$JobId, [int]$TimeoutSec = 300, [int]$PollSec = 2,
          [string]$ExpectedOwnerSid = '', [datetime]$NotBefore = [datetime]::MinValue, [scriptblock]$BeforeRead = $null)
    if (-not (Test-CoderLegJobId $JobId)) { throw "refusing job id '$JobId': not a generated job id." }
    $path = Join-Path $script:CoderLegResults "$JobId.result.json"
    $deadline = (Get-Date).AddSeconds($TimeoutSec)
    while ((Get-Date) -lt $deadline) {
        if (Test-Path -LiteralPath $path) {
            if ($ExpectedOwnerSid) {
                # Bound read: ONE handle, opened so nothing can write, rename or delete the file while it is
                # held; the owner is read from that handle, the creation time checked, and the text read from
                # the same handle, so the file cannot be swapped between the check and the read.
                if ((Get-Item -LiteralPath $path -Force).Attributes -band [IO.FileAttributes]::ReparsePoint) { throw "result file $path is a link; refusing it." }
                $fs = [IO.File]::Open($path, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::Read)
                $bytes = $null
                try {
                    $sd = if ('System.IO.FileSystemAclExtensions' -as [type]) { [System.IO.FileSystemAclExtensions]::GetAccessControl($fs) } else { $fs.GetAccessControl() }
                    $owner = $null
                    try { $owner = $sd.GetOwner([Security.Principal.SecurityIdentifier]).Value } catch { $owner = $null }
                    if ($owner -cne $ExpectedOwnerSid) { throw "result file $path is owned by '$owner', not the expected '$ExpectedOwnerSid' (forged or mis-provisioned); refusing it." }
                    $ct = (Get-Item -LiteralPath $path).CreationTimeUtc
                    if ($ct -lt $NotBefore.ToUniversalTime()) { throw "result file $path was created before the job was queued; refusing it." }
                    # a file's owner can set its own timestamps: one dated in the future is not 'after the enqueue', it is forged
                    if ($ct -gt (Get-Date).ToUniversalTime().AddMinutes(5)) { throw "result file $path carries a creation time in the future ($ct UTC); refusing it." }
                    $idn = Get-FileIdentity -Path $path
                    if ($idn.Reparse -or $idn.Links -gt 1) { throw "result file $path is a link or has $($idn.Links) hard links; refusing it." }
                    if ($BeforeRead) { & $BeforeRead }
                    $ms = New-Object IO.MemoryStream; $fs.CopyTo($ms); $bytes = $ms.ToArray()
                } finally { $fs.Dispose() }
                # one strict parse; any failure is a refusal (the file is left in place), never a retry
                $obj = ConvertFrom-StrictJsonBytes -Bytes $bytes -Schema $script:CoderLegResultSchema -What 'the result file'
                Remove-Item -LiteralPath $path -ErrorAction SilentlyContinue
                return $obj
            }
            $obj = ConvertFrom-StrictJsonBytes -Bytes ([IO.File]::ReadAllBytes($path)) -Schema $script:CoderLegResultSchema -What 'the result file'
            Remove-Item -LiteralPath $path -ErrorAction SilentlyContinue
            return $obj
        }
        Start-Sleep -Seconds $PollSec
    }
    return $null
}

function Get-CoderLegTaskStartDiagnosis {
    # Pure: turn a (State, LastTaskResult) pair into the operator-facing diagnosis for a task that did
    # not start. 0x41303 = SCHED_S_TASK_HAS_NOT_RUN: a password-principal task whose account lacks the
    # 'Log on as a batch job' right is left Ready and never runs. Shared by the fused dispatch leg and
    # verify-coder-containment.ps1 so both name the same cause.
    param($State, $LastTaskResult)
    $hex = if ($null -ne $LastTaskResult) { ('0x{0:X}' -f ([uint32]$LastTaskResult)) } else { 'unknown' }
    $hint = ''
    if ($hex -eq '0x41303') {
        $hint = "0x41303 = SCHED_S_TASK_HAS_NOT_RUN: the coder account almost certainly lacks the 'Log on as a batch job' right (SeBatchLogonRight). Fix: re-run provision-coder-account.ps1 (it grants SeBatchLogonRight in step 1)."
    }
    [pscustomobject]@{ Hex = $hex; State = [string]$State; Hint = $hint }
}

function Start-CoderLegTask {
    # Trigger the on-demand coder-leg task and PROVE it started before the caller blocks on a result.
    # Baselines LastRunTime, calls Start-ScheduledTask, then polls for a start signal (LastRunTime advanced,
    # or State=Running). THROWS, with the diagnosis, when no start signal appears within -StartWaitSec: a
    # task that never started must fail loudly in seconds, never as a blind result-timeout.
    param(
        [string]$TaskPath = '\BlarAI\',
        [string]$TaskName = 'BlarAI-Coder-Leg',
        [int]$StartWaitSec = 20,
        [int]$PollMs = 750
    )
    $preRun = [datetime]'1999-11-30'
    try { $pr = (Get-ScheduledTaskInfo -TaskPath $TaskPath -TaskName $TaskName -ErrorAction SilentlyContinue).LastRunTime; if ($pr) { $preRun = $pr } } catch {}
    Start-ScheduledTask -TaskPath $TaskPath -TaskName $TaskName -ErrorAction Stop
    $started = $false; $lastResult = $null; $state = ''
    $polls = [math]::Max(1, [int][math]::Ceiling(($StartWaitSec * 1000.0) / [math]::Max(1, $PollMs)))
    foreach ($i in 1..$polls) {
        Start-Sleep -Milliseconds $PollMs
        $info = Get-ScheduledTaskInfo -TaskPath $TaskPath -TaskName $TaskName -ErrorAction SilentlyContinue
        $state = [string](Get-ScheduledTask -TaskPath $TaskPath -TaskName $TaskName -ErrorAction SilentlyContinue).State
        if ($info) { $lastResult = $info.LastTaskResult }
        if (($info -and $info.LastRunTime -gt $preRun) -or $state -eq 'Running') { $started = $true; break }
    }
    if (-not $started) {
        $d = Get-CoderLegTaskStartDiagnosis -State $state -LastTaskResult $lastResult
        $msg = "coder-leg task $TaskPath$TaskName did NOT start within ${StartWaitSec}s (State=$($d.State), LastTaskResult=$($d.Hex))."
        if ($d.Hint) { $msg += " $($d.Hint)" }
        throw $msg
    }
    [pscustomobject]@{ Started = $true; State = $state }
}

function Stop-CoderLegTask {
    # Stop the coder-leg task and wait (bounded) for it to leave Running. Returns $true ONLY when a state
    # query succeeded and showed the task not running; $false when it is still running, or when the state
    # could not be read at all (a stop that cannot be confirmed is not a stop). Never throws: it runs on
    # failure paths.
    param(
        [string]$TaskPath = '\BlarAI\',
        [string]$TaskName = 'BlarAI-Coder-Leg',
        [int]$WaitSec = 30,
        [int]$PollMs = 750
    )
    try { Stop-ScheduledTask -TaskPath $TaskPath -TaskName $TaskName -ErrorAction SilentlyContinue } catch { }
    $deadline = (Get-Date).AddSeconds($WaitSec)
    do {
        $state = $null; $queried = $false
        try { $state = [string](Get-ScheduledTask -TaskPath $TaskPath -TaskName $TaskName -ErrorAction Stop).State; $queried = $true } catch { }
        if ($queried -and $state -ne 'Running') { return $true }
        Start-Sleep -Milliseconds ([int][math]::Max(1, $PollMs))
    } while ((Get-Date) -lt $deadline)
    return $false
}

function Assert-CoderLegTaskIdle {
    # After the coder leg has returned its result: confirm the task is NOT running (stopping it if it is) and
    # THROW when that cannot be confirmed. Nothing the coder could still do may overlap an operator-side use
    # of the worktree or the staging dirs.
    param(
        [string]$TaskPath = '\BlarAI\',
        [string]$TaskName = 'BlarAI-Coder-Leg',
        [int]$WaitSec = 30,
        [int]$PollMs = 750
    )
    $state = $null
    try { $state = [string](Get-ScheduledTask -TaskPath $TaskPath -TaskName $TaskName -ErrorAction Stop).State } catch { throw "fused leg: cannot confirm that the coder-leg task has finished (state unreadable: $($_.Exception.Message))." }
    if ($state -ne 'Running') { return }
    if (-not (Stop-CoderLegTask -TaskPath $TaskPath -TaskName $TaskName -WaitSec $WaitSec -PollMs $PollMs)) {
        throw 'fused leg: the coder-leg task is still running after it returned its result and could not be stopped.'
    }
}

function Get-FileIdentity {
    # The on-disk identity of a file or directory, opened WITHOUT following a reparse point:
    # @{ Key = 'VOLUMESERIAL:FILEID'; Links = <hard link count>; Reparse = <bool> }. Two paths with the same
    # Key are the same object; a directory deleted and recreated, or swapped for a junction, changes it.
    param([Parameter(Mandatory)][string]$Path)
    if (-not ('BlarFusedFileId' -as [type])) {
        Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
using Microsoft.Win32.SafeHandles;
public static class BlarFusedFileId {
    [StructLayout(LayoutKind.Sequential)] struct FT { public uint Lo; public uint Hi; }
    [StructLayout(LayoutKind.Sequential)] struct BHFI { public uint Attr; public FT C; public FT A; public FT W; public uint Vol; public uint SizeHi; public uint SizeLo; public uint Links; public uint IdHi; public uint IdLo; }
    [DllImport("kernel32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
    static extern SafeFileHandle CreateFile(string n, uint access, uint share, IntPtr sa, uint disp, uint flags, IntPtr t);
    [DllImport("kernel32.dll", SetLastError = true)]
    static extern bool GetFileInformationByHandle(SafeFileHandle h, out BHFI i);
    [DllImport("kernel32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
    static extern uint GetFinalPathNameByHandleW(SafeFileHandle h, System.Text.StringBuilder sb, uint len, uint flags);
    static string Format(BHFI i) {
        return String.Format("{0:X8}:{1:X8}{2:X8}|{3}|{4}", i.Vol, i.IdHi, i.IdLo, i.Links, ((i.Attr & 0x400) != 0) ? "1" : "0");
    }
    public static string QueryHandle(SafeFileHandle h) {
        BHFI i;
        if (!GetFileInformationByHandle(h, out i)) throw new System.ComponentModel.Win32Exception(Marshal.GetLastWin32Error());
        return Format(i);
    }
    public static string Query(string path) {
        // BACKUP_SEMANTICS (directories) | OPEN_REPARSE_POINT (never follow a link)
        using (SafeFileHandle h = CreateFile(path, 0, 7, IntPtr.Zero, 3, 0x02200000, IntPtr.Zero)) {
            if (h.IsInvalid) throw new System.ComponentModel.Win32Exception(Marshal.GetLastWin32Error());
            return QueryHandle(h);
        }
    }
    // A directory handle that does NOT follow a final-component link and whose share mode omits
    // FILE_SHARE_DELETE: while it is held nothing can rename or delete the directory (or any ancestor).
    public static SafeFileHandle OpenDirPinned(string path) {
        SafeFileHandle h = CreateFile(path, 0x80, 3, IntPtr.Zero, 3, 0x02200000, IntPtr.Zero);
        if (h.IsInvalid) throw new System.ComponentModel.Win32Exception(Marshal.GetLastWin32Error());
        return h;
    }
    public static string FinalPath(SafeFileHandle h) {
        System.Text.StringBuilder sb = new System.Text.StringBuilder(1024);
        uint n = GetFinalPathNameByHandleW(h, sb, (uint)sb.Capacity, 0);
        if (n == 0 || n >= sb.Capacity) throw new System.ComponentModel.Win32Exception(Marshal.GetLastWin32Error());
        string r = sb.ToString();
        if (r.StartsWith("\\\\?\\UNC\\")) return "\\\\" + r.Substring(8);
        if (r.StartsWith("\\\\?\\")) return r.Substring(4);
        return r;
    }
}
'@
    }
    $p = ([BlarFusedFileId]::Query($Path)) -split '\|'
    return [pscustomobject]@{ Key = $p[0]; Links = [int]$p[1]; Reparse = ($p[2] -eq '1') }
}

function Open-PinnedDirectory {
    # Open a directory once (a final-component link is refused) and PIN it: the directory handle gives the
    # identity and the path it actually resolves to (so an ancestor swapped for a junction shows up as a
    # different Final), and an open handle on a file inside it (-AnchorName, default '.git', share mode
    # Read only) stops any process from renaming, deleting or replacing the directory or any ancestor for
    # as long as it is held (Windows refuses a rename while a child is open without delete sharing; a
    # handle on the directory itself does NOT). Returns @{ Handle; Anchor; Key; Final; Reparse }.
    param([Parameter(Mandatory)][string]$Path, [string]$AnchorName = '.git')
    if (-not ('BlarFusedFileId' -as [type])) { $null = Get-FileIdentity -Path $Path }
    $h = [BlarFusedFileId]::OpenDirPinned($Path)
    try {
        $info = ([BlarFusedFileId]::QueryHandle($h)) -split '\|'
        $final = [BlarFusedFileId]::FinalPath($h)
    } catch { $h.Dispose(); throw }
    $anchor = $null
    if ($AnchorName) {
        try {
            $anchor = [IO.File]::Open((Join-Path $final $AnchorName), [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::Read)
            $afinal = [BlarFusedFileId]::FinalPath($anchor.SafeFileHandle)
            if ($afinal -ine (Join-Path $final $AnchorName)) { throw "anchor '$AnchorName' resolves to '$afinal', outside '$final'" }
        } catch { if ($anchor) { $anchor.Dispose() }; $h.Dispose(); throw }
    }
    return [pscustomobject]@{ Handle = $h; Anchor = $anchor; Key = $info[0]; Reparse = ($info[2] -eq '1'); Final = $final }
}

function Test-OrchestratorElevated {
    # Terminating another account's processes needs an elevated (Administrators) token.
    ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Get-CoderProcessList {
    # Every process owned by the coder SID. Returns @{ Procs = @(@{ProcessId; Name}); Unverifiable = @(names) }:
    # Unverifiable are processes whose owner could not be read (and that are not the protected system
    # processes that never can be): the caller cannot rule them out.
    param([Parameter(Mandatory)][string]$CoderSid)
    $procs = @(); $unver = @()
    $protected = 'System Idle Process', 'System', 'Registry', 'Memory Compression', 'Secure System'
    foreach ($p in @(Get-CimInstance Win32_Process -ErrorAction Stop)) {
        $o = $null
        try { $o = Invoke-CimMethod -InputObject $p -MethodName GetOwnerSid -ErrorAction Stop } catch { continue }   # exited meanwhile
        if ($o.ReturnValue -eq 0) {
            if ([string]$o.Sid -ceq $CoderSid) { $procs += @{ ProcessId = [int]$p.ProcessId; Name = [string]$p.Name } }
        } elseif ($protected -notcontains [string]$p.Name) { $unver += [string]$p.Name }
    }
    return @{ Procs = $procs; Unverifiable = $unver }
}

function Stop-ProcessTreeForce {
    param([Parameter(Mandatory)][int]$ProcessId)
    # an absolute path: never resolved through a PATH entry another account could write
    try { & (Join-Path $env:SystemRoot 'System32\taskkill.exe') /PID $ProcessId /T /F 2>&1 | Out-Null } catch { }
}

function Stop-CoderProcessesConfirmed {
    # ELEVATED ORCHESTRATOR ONLY (whether run-fleet is elevated is unverified; see docs/fused-leg-operator-uses.md).
    # It is the only control that sees a coder process started OUTSIDE the job (WMI, a scheduled task). The runner's
    # job object (New-CoderJob) needs no elevation. When the operator token is elevated this also
    # terminates EVERY process owned by the coder account (trees included) and CONFIRMS none remain within
    # -WaitSec. Returns $true on a confirmed empty list, $false when a process survives or an owner cannot be
    # read, and $null when the operator is NOT elevated (it can neither enumerate nor end another account's
    # processes: not applicable, NOT a failure; the caller relies on the runner's job_zero_confirmed fact).
    param([Parameter(Mandatory)][string]$CoderSid, [int]$WaitSec = 30, [int]$PollMs = 500)
    if (-not (Test-OrchestratorElevated)) {
        Write-Host '  [containment] orchestrator not elevated: coder-account processes are not enumerated here (the runner''s job object and its confirmed-zero fact are relied on).' -ForegroundColor DarkYellow
        return $null
    }
    $deadline = (Get-Date).AddSeconds($WaitSec)
    do {
        $list = $null
        try { $list = Get-CoderProcessList -CoderSid $CoderSid } catch {
            Write-Host "  [containment] cannot enumerate processes: $($_.Exception.Message)" -ForegroundColor Yellow
            return $false
        }
        if ($list.Procs.Count -eq 0) {
            if ($list.Unverifiable.Count -gt 0) {
                Write-Host "  [containment] $($list.Unverifiable.Count) process(es) with an unreadable owner cannot be ruled out: $(($list.Unverifiable | Select-Object -First 5) -join ', ')" -ForegroundColor Yellow
                return $false
            }
            return $true
        }
        foreach ($pr in $list.Procs) { Stop-ProcessTreeForce -ProcessId $pr.ProcessId }
        Start-Sleep -Milliseconds ([int][math]::Max(1, $PollMs))
    } while ((Get-Date) -lt $deadline)
    Write-Host "  [containment] coder-account process(es) survived termination: $((@($list.Procs) | ForEach-Object { "$($_.Name)#$($_.ProcessId)" }) -join ', ')" -ForegroundColor Yellow
    return $false
}

function Initialize-StrictJson {
    # One strict JSON parser for BOTH sides of the coder-leg contract (the operator that reads results, the
    # coder-leg runner that reads jobs and probe output). It is the ONLY parser those files go through, so
    # there is no differential between "what was validated" and "what was read".
    # Rejects: any byte order mark except UTF-8's, invalid UTF-8, NUL, comments, trailing commas, trailing
    # data after the value, duplicate object keys (compared case-INsensitively, because PowerShell reads
    # property names case-insensitively), leading zeros, raw control characters in strings, nesting deeper
    # than 32. Numbers are int64 when integral and in range, else double.
    if ('BlarStrictJson' -as [type]) { return }
    Add-Type -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.Globalization;
using System.Text;
public static class BlarStrictJson {
    public static object Parse(byte[] bytes) {
        if (bytes == null) throw new FormatException("no bytes");
        int off = 0;
        if (bytes.Length >= 2 && ((bytes[0] == 0xFF && bytes[1] == 0xFE) || (bytes[0] == 0xFE && bytes[1] == 0xFF))) throw new FormatException("UTF-16/32 byte order mark");
        if (bytes.Length >= 4 && bytes[0] == 0 && bytes[1] == 0 && bytes[2] == 0xFE && bytes[3] == 0xFF) throw new FormatException("UTF-32 byte order mark");
        if (bytes.Length >= 3 && bytes[0] == 0xEF && bytes[1] == 0xBB && bytes[2] == 0xBF) off = 3;
        string text = new UTF8Encoding(false, true).GetString(bytes, off, bytes.Length - off);
        if (text.IndexOf('\0') >= 0) throw new FormatException("NUL character");
        P p = new P(text);
        p.Ws();
        object v = p.Value(0);
        p.Ws();
        if (!p.End) throw new FormatException("trailing data after the JSON value at offset " + p.I);
        return v;
    }
    class P {
        string s; public int I;
        public P(string t) { s = t; }
        public bool End { get { return I >= s.Length; } }
        public void Ws() { while (I < s.Length && (s[I] == ' ' || s[I] == '\t' || s[I] == '\r' || s[I] == '\n')) I++; }
        Exception Bad(string m) { return new FormatException(m + " at offset " + I); }
        public object Value(int depth) {
            if (depth > 32) throw Bad("nesting deeper than 32");
            if (End) throw Bad("unexpected end");
            char c = s[I];
            if (c == '{') return Obj(depth);
            if (c == '[') return Arr(depth);
            if (c == '"') return Str();
            if (c == 't') { Lit("true"); return true; }
            if (c == 'f') { Lit("false"); return false; }
            if (c == 'n') { Lit("null"); return null; }
            if (c == '-' || (c >= '0' && c <= '9')) return Num();
            throw Bad("unexpected character '" + c + "'");
        }
        void Lit(string w) { if (String.CompareOrdinal(s, I, w, 0, w.Length) != 0) throw Bad("bad literal"); I += w.Length; }
        object Obj(int depth) {
            I++;
            Dictionary<string, object> d = new Dictionary<string, object>(StringComparer.OrdinalIgnoreCase);
            Ws();
            if (!End && s[I] == '}') { I++; return d; }
            while (true) {
                Ws();
                if (End || s[I] != '"') throw Bad("object key expected");
                string k = Str();
                if (d.ContainsKey(k)) throw Bad("duplicate key '" + k + "' (keys are compared case-insensitively)");
                Ws();
                if (End || s[I] != ':') throw Bad("':' expected");
                I++; Ws();
                d[k] = Value(depth + 1);
                Ws();
                if (End) throw Bad("unterminated object");
                if (s[I] == ',') { I++; continue; }
                if (s[I] == '}') { I++; return d; }
                throw Bad("',' or '}' expected");
            }
        }
        object Arr(int depth) {
            I++;
            List<object> l = new List<object>();
            Ws();
            if (!End && s[I] == ']') { I++; return l; }
            while (true) {
                Ws();
                l.Add(Value(depth + 1));
                Ws();
                if (End) throw Bad("unterminated array");
                if (s[I] == ',') { I++; continue; }
                if (s[I] == ']') { I++; return l; }
                throw Bad("',' or ']' expected");
            }
        }
        // \ud800 or \udc00 on its own is not text: refuse it (a paired \ud83d\ude00 is fine)
        string NoLoneSurrogates(string t) {
            for (int k = 0; k < t.Length; k++) {
                if (Char.IsHighSurrogate(t[k])) { if (k + 1 < t.Length && Char.IsLowSurrogate(t[k + 1])) { k++; continue; } throw Bad("lone high surrogate"); }
                if (Char.IsLowSurrogate(t[k])) throw Bad("lone low surrogate");
            }
            return t;
        }
        string Str() {
            I++;
            StringBuilder b = new StringBuilder();
            while (true) {
                if (End) throw Bad("unterminated string");
                char c = s[I++];
                if (c == '"') return NoLoneSurrogates(b.ToString());
                if (c < 0x20) throw Bad("control character in string");
                if (c != '\\') { b.Append(c); continue; }
                if (End) throw Bad("unterminated escape");
                char e = s[I++];
                switch (e) {
                    case '"': b.Append('"'); break; case '\\': b.Append('\\'); break; case '/': b.Append('/'); break;
                    case 'b': b.Append('\b'); break; case 'f': b.Append('\f'); break; case 'n': b.Append('\n'); break;
                    case 'r': b.Append('\r'); break; case 't': b.Append('\t'); break;
                    case 'u':
                        if (I + 4 > s.Length) throw Bad("short \\u escape");
                        int cp;
                        if (!Int32.TryParse(s.Substring(I, 4), NumberStyles.AllowHexSpecifier, CultureInfo.InvariantCulture, out cp)) throw Bad("bad \\u escape");
                        b.Append((char)cp); I += 4; break;
                    default: throw Bad("bad escape");
                }
            }
        }
        object Num() {
            int st = I;
            if (s[I] == '-') I++;
            if (End) throw Bad("bad number");
            if (s[I] == '0') { I++; if (!End && s[I] >= '0' && s[I] <= '9') throw Bad("leading zero"); }
            else if (s[I] >= '1' && s[I] <= '9') { while (!End && s[I] >= '0' && s[I] <= '9') I++; }
            else throw Bad("bad number");
            bool integral = true;
            if (!End && s[I] == '.') { integral = false; I++; int d0 = I; while (!End && s[I] >= '0' && s[I] <= '9') I++; if (I == d0) throw Bad("bad fraction"); }
            if (!End && (s[I] == 'e' || s[I] == 'E')) { integral = false; I++; if (!End && (s[I] == '+' || s[I] == '-')) I++; int e0 = I; while (!End && s[I] >= '0' && s[I] <= '9') I++; if (I == e0) throw Bad("bad exponent"); }
            string t = s.Substring(st, I - st);
            if (integral) { long l; if (Int64.TryParse(t, NumberStyles.AllowLeadingSign, CultureInfo.InvariantCulture, out l)) return l; }
            double dv = Double.Parse(t, NumberStyles.Float, CultureInfo.InvariantCulture);
            if (Double.IsInfinity(dv) || Double.IsNaN(dv)) throw Bad("number out of range");
            return dv;
        }
    }
}
'@
}

function Test-StrictSchemaValue {
    # Returns $null when the raw parsed value fits the schema, else a message. Schema forms:
    #   @{ Type = 'string'; Pattern = '...'; Enum = @(..); Nullable = $true }   Type in string|int|number|bool|any|object|array
    #   object: Props = @{ name = <schema> }; Required = @(names)  (unknown keys are errors)
    #   array:  Items = <schema>
    param($Value, $Schema, [string]$At = '$')
    $ErrorActionPreference = 'Stop'   # an unexpected error in the validator is a refusal, never a quiet pass
    if ($null -eq $Value) { if ($Schema.Nullable) { return $null }; return "$At is null" }
    switch ($Schema.Type) {
        'any' { return $null }
        'string' {
            if ($Value -isnot [string]) { return "$At is not a string" }
            if ($Schema.Pattern -and $Value -cnotmatch $Schema.Pattern) { return "$At does not match the required shape" }
            if ($Schema.Enum -and ($Schema.Enum -cnotcontains $Value)) { return "$At is not one of: $($Schema.Enum -join ', ')" }
            return $null
        }
        'int' {
            if ($Value -isnot [long] -and $Value -isnot [int]) { return "$At is not an integer" }
            if ($null -ne $Schema.Min -and $Value -lt $Schema.Min) { return "$At is below $($Schema.Min)" }
            if ($null -ne $Schema.Max -and $Value -gt $Schema.Max) { return "$At is above $($Schema.Max)" }
            return $null
        }
        'number' { if ($Value -isnot [long] -and $Value -isnot [double]) { return "$At is not a number" }; return $null }
        'bool' { if ($Value -isnot [bool]) { return "$At is not a boolean" }; return $null }
        'array' {
            if ($Value -isnot [System.Collections.IList]) { return "$At is not an array" }
            $i = 0; foreach ($it in $Value) { $e = Test-StrictSchemaValue -Value $it -Schema $Schema.Items -At "$At[$i]"; if ($e) { return $e }; $i++ }
            return $null
        }
        'object' {
            if ($Value -isnot [System.Collections.IDictionary]) { return "$At is not an object" }
            foreach ($k in @($Value.Keys)) {
                if (-not $Schema.Props.ContainsKey($k)) { return "$At has an unknown key '$k'" }
                # a key must match the schema spelling EXACTLY (the parser read it case-insensitively)
                if (-not (@($Schema.Props.Keys) -ccontains $k)) { return "$At key '$k' has the wrong case" }
            }
            foreach ($req in @($Schema.Required)) { if ($req -and -not $Value.ContainsKey($req)) { return "$At is missing '$req'" } }
            foreach ($k in @($Value.Keys)) { $e = Test-StrictSchemaValue -Value $Value[$k] -Schema $Schema.Props[$k] -At "$At.$k"; if ($e) { return $e } }
            return $null
        }
        default { return "${At}: unknown schema type '$($Schema.Type)'" }
    }
}

function Convert-StrictNode {
    param($Node)
    if ($Node -is [System.Collections.IDictionary]) {
        $o = [ordered]@{}; foreach ($k in $Node.Keys) { $o[$k] = Convert-StrictNode $Node[$k] }
        return [pscustomobject]$o
    }
    if ($Node -is [System.Collections.IList]) { return @(, @($Node | ForEach-Object { Convert-StrictNode $_ })) }
    return $Node
}

function ConvertFrom-StrictJsonBytes {
    # Parse bytes with the one strict parser, validate against -Schema, and return PowerShell objects built
    # from THAT parse (never re-parsed). Every failure throws.
    param([Parameter(Mandatory)][byte[]]$Bytes, [Parameter(Mandatory)]$Schema, [string]$What = 'JSON')
    $ErrorActionPreference = 'Stop'
    Initialize-StrictJson
    $raw = $null
    try { $raw = [BlarStrictJson]::Parse($Bytes) } catch { throw "strict JSON: $What refused: $($_.Exception.Message)" }
    $err = $null
    try { $err = Test-StrictSchemaValue -Value $raw -Schema $Schema } catch { throw "strict JSON: $What refused: validator error: $($_.Exception.Message)" }
    if ($err) { throw "strict JSON: $What refused: $err" }
    return (Convert-StrictNode $raw)
}

# Values the runner later uses as paths or arguments are constrained here, not just typed: an absolute
# drive path with no wildcard, control or UNC characters; a model of the shape the fleet uses; bounded integers.
$script:CoderLegPathPattern = '^[A-Za-z]:\\[^\x00-\x1f"<>|*?\[\]]+$'
$script:CoderLegJobSchema = @{
    Type = 'object'
    Required = @('id', 'kind', 'created')
    Props = @{
        id = @{ Type = 'string'; Pattern = '^job-\d{8}-\d{6}-[0-9a-f]{8}$' }
        kind = @{ Type = 'string'; Enum = @('dispatch', 'probe') }
        created = @{ Type = 'string' }
        workdir = @{ Type = 'string'; Pattern = $script:CoderLegPathPattern }
        model = @{ Type = 'string'; Pattern = '^local/[A-Za-z0-9._-]{1,64}$' }
        prompt_file = @{ Type = 'string'; Pattern = $script:CoderLegPathPattern }
        log_path = @{ Type = 'string'; Pattern = $script:CoderLegPathPattern }
        timeout_sec = @{ Type = 'int'; Min = 1; Max = 86400 }; idle_sec = @{ Type = 'int'; Min = 1; Max = 86400 }
        max_steps = @{ Type = 'int'; Min = 1; Max = 1000 }; spin_steps = @{ Type = 'int'; Min = 1; Max = 1000 }
        probe = @{ Type = 'object'; Props = @{
            secret_paths = @{ Type = 'array'; Items = @{ Type = 'string' } }
            loopback_url = @{ Type = 'string'; Pattern = '^http://127\.0\.0\.1(:\d{1,5})?/[A-Za-z0-9/_.-]*$' }
            expected_sid = @{ Type = 'string' }
            write_deny_dirs = @{ Type = 'array'; Items = @{ Type = 'string'; Pattern = $script:CoderLegPathPattern } }
            source_git_repos = @{ Type = 'array'; Items = @{ Type = 'string'; Pattern = $script:CoderLegPathPattern } }
            read_files = @{ Type = 'array'; Items = @{ Type = 'string'; Pattern = $script:CoderLegPathPattern } }
            worktree_paths = @{ Type = 'array'; Items = @{ Type = 'string'; Pattern = $script:CoderLegPathPattern } }
            # the tool-chain setup checks (#775 plan step 4): the repair proxy, the operator paths that must stay unreadable,
            # the executables that must start, the coder's own config folder, more folders that must stay unwritable
            proxy_url = @{ Type = 'string'; Pattern = '^http://127\.0\.0\.1(:\d{1,5})?/[A-Za-z0-9/_.-]*$' }
            operator_deny_paths = @{ Type = 'array'; Items = @{ Type = 'string'; Pattern = $script:CoderLegPathPattern } }
            toolchain_exes = @{ Type = 'array'; Items = @{ Type = 'string'; Pattern = $script:CoderLegPathPattern } }
            config_dir = @{ Type = 'string'; Pattern = $script:CoderLegPathPattern }
            extra_write_deny_dirs = @{ Type = 'array'; Items = @{ Type = 'string'; Pattern = $script:CoderLegPathPattern } }
            check_config = @{ Type = 'bool' } } }
    }
}

$script:CoderLegResultSchema = @{
    Type = 'object'
    Required = @('id', 'kind', 'ok', 'ran_as_sid', 'ran_as_user', 'error')
    Props = @{
        id = @{ Type = 'string'; Pattern = '^job-\d{8}-\d{6}-[0-9a-f]{8}$' }
        kind = @{ Type = 'string'; Enum = @('dispatch', 'probe') }
        ok = @{ Type = 'bool' }
        ran_as_sid = @{ Type = 'string' }; ran_as_user = @{ Type = 'string' }; error = @{ Type = 'string' }
        result = @{ Type = 'any'; Nullable = $true }
        job_zero_confirmed = @{ Type = 'bool' }
        job_active = @{ Type = 'int' }
    }
}

# The dispatch envelope the coder leg returns inside a result: what Invoke-AcpCoderRun produced.
$script:CoderLegEnvelopeSchema = @{
    Type = 'object'
    Required = @('Ok')
    Props = @{
        Ok = @{ Type = 'bool' }
        Reason = @{ Type = 'string'; Nullable = $true }
        Result = @{ Type = 'object'; Nullable = $true
            Required = @('TimedOut', 'TimeoutReason', 'Capped', 'CappedReason', 'ExitCode', 'LogPath', 'Seconds', 'Error')
            Props = @{
                TimedOut = @{ Type = 'bool' }; TimeoutReason = @{ Type = 'string'; Nullable = $true }
                Capped = @{ Type = 'bool' }; CappedReason = @{ Type = 'string'; Nullable = $true }
                ExitCode = @{ Type = 'int'; Nullable = $true }; LogPath = @{ Type = 'string'; Nullable = $true }
                Seconds = @{ Type = 'number' }; Error = @{ Type = 'string'; Nullable = $true }
            } }
    }
}

function Assert-CoderLegEnvelope {
    # Operator side: the dispatch envelope inside a result, as a typed shape (re-expressed from the parsed
    # object, so it is validated by the SAME schema machinery, never by loose property reads).
    param($Envelope)
    if ($null -eq $Envelope) { throw 'strict JSON: the dispatch envelope is missing' }
    $raw = $null
    function _ToRaw($n) {
        if ($n -is [pscustomobject]) { $d = New-Object 'System.Collections.Generic.Dictionary[string,object]' ([StringComparer]::OrdinalIgnoreCase); foreach ($p in $n.PSObject.Properties) { $d[$p.Name] = _ToRaw $p.Value }; return $d }
        if ($n -is [System.Collections.IList]) { return ,@($n | ForEach-Object { _ToRaw $_ }) }
        return $n
    }
    $raw = _ToRaw $Envelope
    $err = $null
    try { $err = Test-StrictSchemaValue -Value $raw -Schema $script:CoderLegEnvelopeSchema } catch { throw "strict JSON: the dispatch envelope is refused: validator error: $($_.Exception.Message)" }
    if ($err) { throw "strict JSON: the dispatch envelope is refused: $err" }
}

function Initialize-CoderJobType {
    if ('BlarCoderJob' -as [type]) { return }
    Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public static class BlarCoderJob {
    [DllImport("kernel32.dll", SetLastError = true, CharSet = CharSet.Unicode)] static extern IntPtr CreateJobObjectW(IntPtr a, string name);
    [DllImport("kernel32.dll", SetLastError = true)] static extern bool SetInformationJobObject(IntPtr job, int cls, IntPtr info, int len);
    [DllImport("kernel32.dll", SetLastError = true)] static extern bool QueryInformationJobObject(IntPtr job, int cls, IntPtr info, int len, out int ret);
    [DllImport("kernel32.dll", SetLastError = true)] static extern bool AssignProcessToJobObject(IntPtr job, IntPtr proc);
    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    struct SI { public int cb; public string r; public string d; public string t; public int x, y, xs, ys, xc, yc, fa, fl; public short sw, cb2; public IntPtr r2, i, o, e; }
    [StructLayout(LayoutKind.Sequential)] struct PI { public IntPtr hp, ht; public int pid, tid; }
    [DllImport("kernel32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
    static extern bool CreateProcessW(string app, System.Text.StringBuilder cmd, IntPtr pa, IntPtr ta, bool inherit, uint flags, IntPtr env, string dir, ref SI si, out PI pi);
    [DllImport("kernel32.dll", SetLastError = true)] static extern int ResumeThread(IntPtr t);
    [DllImport("kernel32.dll", SetLastError = true)] static extern IntPtr OpenProcess(uint access, bool inherit, uint pid);
    [DllImport("kernel32.dll", SetLastError = true)] static extern bool TerminateProcess(IntPtr h, uint code);
    [DllImport("kernel32.dll")] static extern bool CloseHandle(IntPtr h);
    static Exception Err(string what) { return new System.ComponentModel.Win32Exception(Marshal.GetLastWin32Error(), what); }
    // A job with KILL_ON_JOB_CLOSE (0x2000) and NO breakaway rights (BREAKAWAY_OK 0x800 / SILENT_BREAKAWAY_OK 0x1000
    // are never set). The handle is not inheritable, so no child can hold it open or close it.
    public static IntPtr Create() {
        IntPtr job = CreateJobObjectW(IntPtr.Zero, null);
        if (job == IntPtr.Zero) throw Err("CreateJobObject");
        int size = (IntPtr.Size == 8) ? 144 : 112;
        IntPtr buf = Marshal.AllocHGlobal(size);
        try {
            for (int i = 0; i < size; i++) Marshal.WriteByte(buf, i, 0);
            Marshal.WriteInt32(buf, 16, 0x2000);
            if (!SetInformationJobObject(job, 9, buf, size)) throw Err("SetInformationJobObject");
        } finally { Marshal.FreeHGlobal(buf); }
        return job;
    }
    // Create the process SUSPENDED, put it in the job, then let it run: it never executes a single instruction
    // outside the job, so no descendant can have been created before the assignment. Inherits this process's
    // environment and console. Returns the new process id. (Assigning the CURRENT process instead does not make
    // its later children join the job: measured, so it is not used.)
    public static int StartInJob(IntPtr job, string cmdLine, string cwd) {
        SI si = new SI(); si.cb = Marshal.SizeOf(typeof(SI)); PI pi;
        System.Text.StringBuilder sb = new System.Text.StringBuilder(cmdLine);
        if (!CreateProcessW(null, sb, IntPtr.Zero, IntPtr.Zero, false, 0x4 | 0x400, IntPtr.Zero, cwd, ref si, out pi)) throw Err("CreateProcess(suspended)");
        try {
            if (!AssignProcessToJobObject(job, pi.hp)) { int e = Marshal.GetLastWin32Error(); TerminateProcess(pi.hp, 1); throw new System.ComponentModel.Win32Exception(e, "AssignProcessToJobObject"); }
            if (ResumeThread(pi.ht) == -1) { int e = Marshal.GetLastWin32Error(); TerminateProcess(pi.hp, 1); throw new System.ComponentModel.Win32Exception(e, "ResumeThread"); }
        } finally { CloseHandle(pi.ht); CloseHandle(pi.hp); }
        return pi.pid;
    }
    public static uint LimitFlags(IntPtr job) {
        int size = (IntPtr.Size == 8) ? 144 : 112; int ret;
        IntPtr buf = Marshal.AllocHGlobal(size);
        try { if (!QueryInformationJobObject(job, 9, buf, size, out ret)) throw Err("QueryInformationJobObject(limits)"); return (uint)Marshal.ReadInt32(buf, 16); }
        finally { Marshal.FreeHGlobal(buf); }
    }
    public static int ActiveProcesses(IntPtr job) {
        IntPtr buf = Marshal.AllocHGlobal(48); int ret;
        try { if (!QueryInformationJobObject(job, 1, buf, 48, out ret)) throw Err("QueryInformationJobObject(accounting)"); return Marshal.ReadInt32(buf, 40); }
        finally { Marshal.FreeHGlobal(buf); }
    }
    public static int[] ProcessIds(IntPtr job) {
        int size = 8 + IntPtr.Size * 1024; IntPtr buf = Marshal.AllocHGlobal(size); int ret;
        try {
            if (!QueryInformationJobObject(job, 3, buf, size, out ret)) throw Err("QueryInformationJobObject(pids)");
            int n = Marshal.ReadInt32(buf, 4); int[] ids = new int[n];
            for (int i = 0; i < n; i++) ids[i] = (int)Marshal.ReadIntPtr(buf, 8 + i * IntPtr.Size).ToInt64();
            return ids;
        } finally { Marshal.FreeHGlobal(buf); }
    }
    public static bool Kill(int pid) {
        IntPtr h = OpenProcess(0x1, false, (uint)pid);
        if (h == IntPtr.Zero) return false;
        try { return TerminateProcess(h, 1); } finally { CloseHandle(h); }
    }
    public static void Close(IntPtr job) { CloseHandle(job); }
}
'@
}

function New-CoderJob {
    # A Windows job object for the coder process tree: kill-on-close, no breakaway. Created by the coder-leg
    # RUNNER, which starts the coder driver INSIDE it (Start-ProcessInJob: suspended, assigned, resumed), so every
    # descendant (python, opencode, node, builds) is born inside it with no race and no way to leave. When the
    # runner exits or is killed (Stop-ScheduledTask ends it) the job handle closes and Windows kills the whole
    # tree; the runner also drains and queries it before reporting. The coder ends its own tree: no elevation
    # is needed anywhere.
    Initialize-CoderJobType
    return [pscustomobject]@{ Handle = [BlarCoderJob]::Create() }
}

function ConvertTo-WindowsArg {
    param([string]$Arg)
    if ($Arg -ne '' -and $Arg -notmatch '[\s"]') { return $Arg }
    $sb = New-Object Text.StringBuilder; [void]$sb.Append('"'); $bs = 0
    foreach ($ch in $Arg.ToCharArray()) {
        if ($ch -eq [char]92) { $bs++; continue }
        if ($ch -eq '"') { [void]$sb.Append([char]92, $bs * 2 + 1); [void]$sb.Append('"'); $bs = 0; continue }
        if ($bs -gt 0) { [void]$sb.Append([char]92, $bs); $bs = 0 }
        [void]$sb.Append($ch)
    }
    if ($bs -gt 0) { [void]$sb.Append([char]92, $bs * 2) }
    [void]$sb.Append('"')
    return $sb.ToString()
}

function Start-ProcessInJob {
    # Start FilePath with ArgumentList INSIDE the job (suspended, assigned, resumed). Returns the Process.
    param([Parameter(Mandatory)]$Job, [Parameter(Mandatory)][string]$FilePath, [string[]]$ArgumentList = @(), [string]$WorkingDirectory = '')
    $cmd = (@($FilePath, $ArgumentList) | ForEach-Object { $_ } | ForEach-Object { ConvertTo-WindowsArg ([string]$_) }) -join ' '
    $cwd = if ($WorkingDirectory) { $WorkingDirectory } else { $null }
    $procId = [BlarCoderJob]::StartInJob($Job.Handle, $cmd, $cwd)
    return (Get-Process -Id $procId -ErrorAction Stop)
}

function Get-CoderJobState {
    param([Parameter(Mandatory)]$Job)
    [pscustomobject]@{ Active = [BlarCoderJob]::ActiveProcesses($Job.Handle); Pids = @([BlarCoderJob]::ProcessIds($Job.Handle)); LimitFlags = [BlarCoderJob]::LimitFlags($Job.Handle) }
}

function Stop-CoderJobProcesses {
    # Terminate every process in the job except -SelfPid (the runner), and CONFIRM the job holds nothing else:
    # QueryInformationJobObject reports the active count and the id list. Returns @{ Zero = <bool>; Active = <others> }.
    # Bounded; never throws.
    param([Parameter(Mandatory)]$Job, [int]$WaitSec = 20, [int]$SelfPid = $PID, [int]$PollMs = 100)
    $deadline = (Get-Date).AddSeconds($WaitSec)
    $others = -1
    do {
        try {
            $ids = @([BlarCoderJob]::ProcessIds($Job.Handle) | Where-Object { $_ -ne $SelfPid })
            $others = $ids.Count
            if ($others -eq 0) { return @{ Zero = $true; Active = 0 } }
            foreach ($id in $ids) { [void][BlarCoderJob]::Kill($id) }
        } catch { $others = -1 }
        Start-Sleep -Milliseconds ([int][math]::Max(1, $PollMs))
    } while ((Get-Date) -lt $deadline)
    return @{ Zero = $false; Active = $others }
}

function Close-CoderJob { param($Job) if ($Job) { try { [BlarCoderJob]::Close($Job.Handle) } catch { } } }


# ---- the operator funnel is the only committer (#1678) -----------------------------------------------------
# Under containment=restricted_account the coder account has READ on the source repo (its .git included) and
# Modify on its own worktree folder only, so it cannot commit: the index, the refs and the objects of a linked
# worktree live in the source repo's .git. The operator funnel (stage, secret scan, commit, merge) is the only
# committer. These helpers carry that fact to the coder; none of them runs with containment off.

function Get-CoderFunnelNotice {
    # The text added to the coder's prompt on the restricted path. States what the coder cannot do, what still
    # works, and who commits.
    @(
        'RESTRICTED ACCOUNT NOTICE (read first):',
        '- You run as a restricted account. You can read the whole project and write ONLY inside your working folder.',
        '- Do NOT run git add, git commit, git checkout, git reset, git stash, git merge or git rebase: they cannot succeed here (the repository metadata is read-only to you) and a failed attempt is wasted steps.',
        '- Do NOT create files or folders outside your working folder. A permission-denied there is by design: do not retry it or work around it.',
        '- git status and git diff (read-only) work. When your work is complete and verified, just stop: the operator saves a snapshot (commit) and merges it after you finish.',
        ''
    ) -join "`n"
}

function Add-CoderFunnelNotice {
    # Prepend the notice to a prompt. Idempotent (a prompt that already starts with it is returned unchanged).
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Prompt)
    $n = Get-CoderFunnelNotice
    if ($Prompt.StartsWith($n)) { return $Prompt }
    return $n + "`n" + $Prompt
}

function Get-CoderLegGitEnv {
    # Process-environment values for git inside the coder leg: no optional index refresh locks (the coder
    # cannot take them and must not contend with an operator-side git), no prompts, no fsmonitor daemon, and
    # safe.directory for exactly the coder's own worktree (operator-created folders are owned by another
    # account, which makes git refuse every command as "dubious ownership"). Returns an ordered hashtable
    # name -> value. -WorkDir must be an absolute drive path without a wildcard.
    param([Parameter(Mandatory)][string]$WorkDir)
    if ($WorkDir -notmatch '^[A-Za-z]:\\' -or $WorkDir -match '[\*\?<>|"\x00-\x1f]') { throw "Get-CoderLegGitEnv: refusing the workdir '$WorkDir'" }
    $wd = $WorkDir.TrimEnd('\').Replace('\', '/')
    [ordered]@{
        GIT_OPTIONAL_LOCKS   = '0'
        GIT_TERMINAL_PROMPT  = '0'
        GIT_CONFIG_COUNT     = '2'
        GIT_CONFIG_KEY_0     = 'safe.directory'
        GIT_CONFIG_VALUE_0   = $wd
        GIT_CONFIG_KEY_1     = 'core.fsmonitor'
        GIT_CONFIG_VALUE_1   = 'false'
    }
}

function Get-CoderAgentsRulesText {
    # The rules file (configs/AGENTS.md) as the coder should read it. -Containment 'off' returns the text
    # BYTE-FOR-BYTE (the coder runs as the operator and commits itself). 'restricted_account' replaces the one
    # "save a snapshot: git add -A then git commit" rule with the operator-funnel rule. A file whose commit rule
    # cannot be found THROWS (a silent no-op would leave the coder told to do what it cannot).
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Text, [ValidateSet('off', 'restricted_account')][string]$Containment = 'off')
    if ($Containment -eq 'off') { return $Text }
    $rx = [regex]'(?m)^- When a task is complete and verified, save a snapshot:.*$'
    if ($rx.Matches($Text).Count -ne 1) { throw 'AGENTS.md: the commit rule ("When a task is complete and verified, save a snapshot") was not found exactly once; the restricted rendering cannot replace it.' }
    $rule = '- When a task is complete and verified, STOP. You are a restricted account and cannot commit: do not run `git add` or `git commit`; the operator saves the snapshot and merges it after you finish. Never push.'
    return $rx.Replace($Text, { param($m) $rule })
}
