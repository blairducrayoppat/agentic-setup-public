# scripts

## VERIFIED FACTS
All facts verified by file reads and live commands on this machine (2026-06-10):

1. Read every file in C:\Users\mrbla\agentic-setup\scripts\ (start-llm.ps1, stop-llm.ps1, open-coding.ps1, new-agent-task.ps1, 01-05*.ps1), all 5 root .cmd launchers, and configs\opencode.json + openclaw.json5.
2. `opencode --help` (run on this machine, v1.17.x): the default TUI command DOES support `-m, --model` in `provider/model` format; `opencode run --help` confirms `--dir` and `-m` both exist, so new-agent-task.ps1's invocation is valid and open-coding.ps1 CAN pin the loaded model.
3. start-llm.ps1 line 69: `$reclaimFromOvms = 9` flat, with its own comment admitting "14B≈10, VL≈6, 30B≈18". BLUEPRINT.md section 1 table confirms measured residents: coder-30b \~18.8 GB, qwen3-14b \~10.5 GB, qwen3-vl-8b \~6 GB. So with the VL loaded and a 30B request, availability is overstated by \~3 GB (can pass the check then choke); with 30B loaded and 14B requested it is understated by \~9 GB (nags the user to close apps needlessly).
4. start-llm.ps1 line 170 starts OVMS with `Start-Process ... -WindowStyle Minimized` and NO -RedirectStandardOutput/-RedirectStandardError. Manual log files ovms-30b.log / ovms-test.log sitting in agentic-setup\ prove logs had to be captured by hand before; a later crash leaves zero diagnostics. C:\Users\mrbla\agentic-setup\state\logs does not exist (Test-Path = False).
5. LIVE REPRO of the stop-llm UX bug: the flag file $env:TEMP\agentic-blarai-vm-stopped.flag EXISTS right now and Get-VM shows BlarAI-Orchestrator is Off — start-llm stopped it at some point and nothing ever offered the restart because stop-llm.ps1 (4 lines total) never checks the flag. The flag also lives in %TEMP%, which Storage Sense/Disk Cleanup purges.
6. Get-VM works without elevation for this user: `whoami /groups` shows BUILTIN\Hyper-V Administrators membership; Get-VM returned BlarAI-Orchestrator (Off). Only that one VM exists today, but the script hardcodes the name and would ignore any future VM (HAOS VM is planned in BLUEPRINT 6.3).
7. Port 8000 is currently free and ovms is not running; start-llm's readiness loop polls /v3/models but never verifies the returned id matches the requested model nor that the listener is its own process — a foreign listener on 8000 would either make ovms exit (with no logs, see #4) or answer the poll and produce a false READY.
8. Read-Host in PS7 with -NonInteractive throws; with redirected stdin it hangs — start-llm has no guard (the memory-assistant loop and the VM-restart prompt both Read-Host when not -Force).
9. Desktop .cmd files are byte-identical copies of the agentic-setup originals today (diff verified), but there is NO sync mechanism anywhere (grep for "Desktop" in scripts finds only comments) — two sources of truth, drift is one edit away. Stop AI Models.cmd timestamps already differ (17:02 vs 17:34 batch).
10. Open Coding Chat.cmd is the only launcher with NO `pause` — any unhandled PS exception (EAP=Stop) closes the window before the novice can read the error.
11. configs\opencode.json sets default `"model": "local/qwen3-14b"` — so when coder-30b is the resident model and the user opens the chat, OpenCode silently targets qwen3-14b, OVMS returns the 'Mediapipe graph not found'-class error. open-coding.ps1 already queries /v3/models (line 14) but throws the answer away and launches bare `opencode` (line 96).
12. new-agent-task.ps1: native git exit codes are NOT caught by $ErrorActionPreference='Stop' (PS 5.1 and PS 7.x default) and $LASTEXITCODE is never checked after `git worktree add`, so a pre-existing branch/folder lets the script dispatch opencode into a broken worktree; $Task is unsanitized (a space breaks the branch name); the model-server check happens AFTER worktree creation and never verifies the LOADED model matches -Model.
13. 04-seed-offline.ps1 runs `npm config set registry http://localhost:4873/` unconditionally — if Verdaccio failed to install/start, every future npm install on the machine breaks. 05-overnight-power.ps1 says "Run as Administrator" but never checks (EAP=Continue makes powercfg failures silent). PS 7.6.1 is installed (pwsh path taken by all launchers); PS 5.1 fallback paths have latent bugs: start-llm's Invoke-WebRequest lacks -UseBasicParsing, and open-coding's `git ... 2>$null` under EAP=Stop throws on PS 5.1 when git emits stderr hints.
14. The opencode shim is AppData\Roaming\npm\opencode.ps1; uv/uvx/git all present (Get-Command verified). Available RAM at scan time \~22.8 GB.

## IMPROVEMENTS

### [P0/small] open-coding.ps1: launch OpenCode pinned to the loaded model (-m local/<id>)
The script already fetches /v3/models (line 14) but discards the id and runs bare `opencode` (line 96). opencode.json defaults to local/qwen3-14b, so whenever coder-30b or the vision model is resident, the first message fails with the 'Mediapipe graph not found' class of error and the novice is back in the /models guessing game. VERIFIED on this machine: `opencode --help` shows `-m, --model  model to use in the format of provider/model` on the default TUI command.
```text
In C:\Users\mrbla\agentic-setup\scripts\open-coding.ps1 replace lines 12-16 with:

$ids = @()
try {
    $resp = Invoke-WebRequest 'http://127.0.0.1:8000/v3/models' -TimeoutSec 3 -UseBasicParsing
    $ids = @((($resp.Content | ConvertFrom-Json).data) | ForEach-Object { $_.id })
} catch {}
$loaded = $ids -join ', '

and replace the final two lines (95-96, `Set-Location $target` / `opencode`) with:

Set-Location $target
$known = @('coder-30b','qwen3-14b','qwen3-vl-8b')
if ($ids.Count -ge 1 -and ($known -contains $ids[0])) {
    Write-Host ("Using the model that is actually loaded: local/{0}" -f $ids[0]) -ForegroundColor Green
    opencode -m ("local/" + $ids[0])
} else {
    Write-Host "Loaded model not recognized - starting OpenCode with its default; use /models to switch." -ForegroundColor Yellow
    opencode
}
```
RISK: Low. -m only overrides the session default; /models still works. If a future opencode version renames the flag, the else-branch behavior is today's behavior.

### [P0/small] start-llm.ps1: capture OVMS stdout/stderr to dated logs under state\logs
Line 170 starts ovms.exe minimized with no redirection. When the server dies an hour later (driver reset, OOM, bad flag) there are ZERO diagnostics; the manually-redirected ovms-30b.log/ovms-test.log in the repo root prove this has already been needed twice. The failure messages at lines 192/194 tell a novice to 're-run manually' — exactly the command-memorizing pattern that fails for this user.
```text
In C:\Users\mrbla\agentic-setup\scripts\start-llm.ps1 replace line 170 (`$proc = Start-Process ...`) with:

$LogDir = 'C:\Users\mrbla\agentic-setup\state\logs'
New-Item -ItemType Directory -Force $LogDir | Out-Null
Get-ChildItem $LogDir -Filter 'ovms-*.log' -ErrorAction SilentlyContinue |
    Sort-Object LastWriteTime -Descending | Select-Object -Skip 20 |
    Remove-Item -ErrorAction SilentlyContinue
$stamp  = Get-Date -Format 'yyyyMMdd-HHmmss'
$OutLog = Join-Path $LogDir "ovms-$Model-$stamp.out.log"
$ErrLog = Join-Path $LogDir "ovms-$Model-$stamp.err.log"
$proc = Start-Process -FilePath $Ovms -ArgumentList $args2 -PassThru -WindowStyle Minimized -RedirectStandardOutput $OutLog -RedirectStandardError $ErrLog

Replace line 192's throw with:

    if ($proc.HasExited) {
        Write-Host "--- last 15 lines of the server log ---" -ForegroundColor Yellow
        Get-Content $ErrLog -Tail 15 -ErrorAction SilentlyContinue
        throw "The model server exited (code $($proc.ExitCode)). Full log: $ErrLog"
    }

Replace line 194 with:

throw "The model server did not become ready in 180s. Log: $ErrLog"
```
RISK: Low. Start-Process supports -WindowStyle together with the two redirects; the two files must differ (they do). OVMS logs mostly to stderr, both streams captured.

### [P0/small] start-llm.ps1: per-model RAM reclaim instead of flat 9 GB
Line 69 credits a flat 9 GB for any running ovms. Real residents (BLUEPRINT section 1, measured): 30B \~18.8, 14B \~10.5, VL \~6. Two concrete failures: (a) VL loaded -> ask for 30B: availability overstated by \~3 GB, the check passes and the machine crawls/OOMs mid-load; (b) 30B loaded -> ask for 14B: understated by \~9 GB, the assistant nags the user to close apps that do not need closing. Query /v3/models to learn WHICH model is resident and use a per-model table rounded DOWN.
```text
In C:\Users\mrbla\agentic-setup\scripts\start-llm.ps1 replace lines 67-69 with:

# The currently-loaded model's RAM comes back when we stop it - count it as available.
# Per-model residents measured on this machine (BLUEPRINT.md section 1), rounded DOWN to stay safe.
$reclaimFromOvms = 0
if (Get-Process ovms -ErrorAction SilentlyContinue) {
    $residentGB = @{ 'coder-30b' = 18; 'qwen3-14b' = 10; 'qwen3-vl-8b' = 6 }
    try {
        $cur = ((Invoke-WebRequest 'http://127.0.0.1:8000/v3/models' -TimeoutSec 3 -UseBasicParsing).Content | ConvertFrom-Json).data
        foreach ($m in @($cur)) { if ($residentGB.ContainsKey($m.id)) { $reclaimFromOvms += $residentGB[$m.id] } }
    } catch {}
    if ($reclaimFromOvms -eq 0) { $reclaimFromOvms = 6 }   # server up but unknown/unresponsive: safest low guess
}
```
RISK: Low. Falls back to a conservative 6 GB when the server does not answer; worst case is extra nagging, never an overstated budget.

### [P0/small] stop-llm.ps1: offer to restart VMs stopped by start-llm (flag exists, VM is Off RIGHT NOW)
Live repro on this machine: %TEMP%\agentic-blarai-vm-stopped.flag exists and BlarAI-Orchestrator is Off — start-llm stopped the VM, the user later ran 'Stop AI Models', and nothing ever offered the restart, so the BlarAI assistant silently stays dead until the user remembers Hyper-V Manager (the exact command-memorizing failure mode). Also moves the flag out of %TEMP% (Storage Sense purges it) into state\, in the multi-VM one-name-per-line format used by the generic-VM fix below.
```text
Replace C:\Users\mrbla\agentic-setup\scripts\stop-llm.ps1 entirely with:

# Stop the local model server (frees its RAM), then offer to restart any
# VMs that start-llm.ps1 stopped earlier to make room.
$ErrorActionPreference = 'Stop'
$StateDir = 'C:\Users\mrbla\agentic-setup\state'
$VmFlag   = Join-Path $StateDir 'stopped-vms.txt'
$OldFlag  = Join-Path $env:TEMP 'agentic-blarai-vm-stopped.flag'   # legacy location

$p = Get-Process ovms -ErrorAction SilentlyContinue
if ($p) { $p | Stop-Process -Force; Write-Host "OVMS stopped. Its memory is free again." -ForegroundColor Green }
else    { Write-Host "OVMS was not running." }

$names = @()
if (Test-Path $VmFlag)  { $names += @(Get-Content $VmFlag | Where-Object { $_ }) }
if (Test-Path $OldFlag) { $names += 'BlarAI-Orchestrator' }
$names = @($names | Select-Object -Unique)

$interactive = [Environment]::UserInteractive -and -not [Console]::IsInputRedirected
if ($interactive) {
    foreach ($n in $names) {
        $vm = Get-VM -Name $n -ErrorAction SilentlyContinue
        if ($vm -and $vm.State -ne 'Running') {
            $back = Read-Host "Earlier the '$n' VM was stopped to free memory. Start it again now? (y/N)"
            if ($back -eq 'y') { Start-VM -Name $n; Write-Host "'$n' starting." -ForegroundColor Green }
        }
    }
    Remove-Item $VmFlag, $OldFlag -ErrorAction SilentlyContinue
}
```
RISK: Low. Get-VM works non-elevated for this user (verified Hyper-V Administrators membership). Non-interactive runs leave the flag in place so the offer is not lost.

### [P1/small] start-llm.ps1: port-8000 pre-flight check and READY must match the requested model
Two related gaps. (a) If anything other than ovms holds 127.0.0.1:8000 (an old start_llm.bat-era server — a Dec-2025 shortcut still sits on the Desktop — or any dev server), the new ovms exits on bind failure and, pre-log-fix, leaves no clue; worse, the readiness poll could get an answer FROM THE FOREIGN PROCESS and print READY for a server that is not OVMS. (b) The poll never checks the returned id equals $name, so READY can name the wrong model.
```text
In C:\Users\mrbla\agentic-setup\scripts\start-llm.ps1 insert BEFORE line 159 (`Get-Process ovms ... | Stop-Process`):

$listener = Get-NetTCPConnection -LocalPort 8000 -State Listen -ErrorAction SilentlyContinue | Select-Object -First 1
if ($listener) {
    $owner = Get-Process -Id $listener.OwningProcess -ErrorAction SilentlyContinue
    if ($owner -and $owner.Name -ne 'ovms') {
        throw "Port 8000 is being used by '$($owner.Name)' (PID $($owner.Id)), which is NOT the model server. Close that program (or reboot) and run this again."
    }
}

and replace lines 176-178 (the poll body) with:

        $resp = Invoke-WebRequest 'http://127.0.0.1:8000/v3/models' -TimeoutSec 3 -UseBasicParsing
        $idList = @((($resp.Content | ConvertFrom-Json).data) | ForEach-Object { $_.id })
        if ($idList -notcontains $name) { Write-Host "  loading..."; continue }
        Write-Host "READY: $name is now loaded." -ForegroundColor Green
```
RISK: Low. The `continue` keeps polling until the right id appears or the 180s deadline throws (now pointing at the log). -UseBasicParsing added for the PS 5.1 fallback path.

### [P1/small] start-llm.ps1: guard Read-Host against non-interactive runs
Without -Force, a short-on-memory run from a scheduled task / OpenClaw cron / redirected stdin either hangs forever on Read-Host (PS 5.1, redirected input) or throws an opaque PSInvalidOperationException (pwsh -NonInteractive). The planned Phase-8 overnight automation will hit this. Same applies to the VM-restart Read-Host after READY (already gated by -not $Force, which this guard satisfies).
```text
In C:\Users\mrbla\agentic-setup\scripts\start-llm.ps1 insert immediately after the $reclaimFromOvms block (before the '# ---------------- Memory assistant' comment):

$interactive = [Environment]::UserInteractive -and -not [Console]::IsInputRedirected
if (-not $Force -and -not $interactive) {
    $avail = (Get-AvailableGB) + $reclaimFromOvms
    if ($avail -lt $needGB) {
        throw "Not enough memory (~$avail GB usable, need ~$needGB GB) and there is no console to ask about closing apps. Run interactively, free memory first, or pass -Force."
    }
    $Force = $true   # enough memory: skip all prompts
}
```
RISK: Low. Interactive double-click behavior is unchanged; automation gets a clear failure instead of a hang.

### [P1/medium] start-llm.ps1: enumerate ALL running Hyper-V VMs, not just BlarAI-Orchestrator by name
Lines 84-87 (menu), 128-134 (stop handler) and 181-189 (restart offer) hardcode 'BlarAI-Orchestrator' and a hardcoded 2.0 GB. BLUEPRINT 6.3 plans a 3 GB HAOS VM; it would be invisible to the memory assistant. Generic enumeration uses each running VM's real MemoryAssigned and records stopped names (one per line) in state\stopped-vms.txt — the same file the new stop-llm.ps1 reads, making the restart offer consistent across both scripts. Verified Get-VM works non-elevated for this user (Hyper-V Administrators group).
```text
In C:\Users\mrbla\agentic-setup\scripts\start-llm.ps1:
1) Replace line 20 with:
$StateDir = 'C:\Users\mrbla\agentic-setup\state'
New-Item -ItemType Directory -Force $StateDir | Out-Null
$VmFlag = Join-Path $StateDir 'stopped-vms.txt'

2) Replace lines 84-87 (the $vm menu entry) with:
foreach ($rvm in @(Get-VM -ErrorAction SilentlyContinue | Where-Object { $_.State -eq 'Running' })) {
    $menu += [pscustomobject]@{ Kind='vm'; Name=('VM: ' + $rvm.Name); VmName=$rvm.Name; GB=[math]::Round($rvm.MemoryAssigned/1GB,1) }
}

3) Replace lines 128-134 (the vm branch) with:
if ($item.Kind -eq 'vm') {
    $ok = Read-Host "Stop the '$($item.VmName)' virtual machine? It shuts down cleanly and you will be offered a restart later. (y/N)"
    if ($ok -eq 'y') {
        Stop-VM -Name $item.VmName
        Add-Content -Path $VmFlag -Value $item.VmName
        Write-Host "'$($item.VmName)' stopped (restart will be offered by this script and by 'Stop AI Models')." -ForegroundColor Green
    }
}

4) Replace lines 181-189 (restart offer) with:
if ($Model -ne 'coder-30b' -and (Test-Path $VmFlag) -and -not $Force) {
    foreach ($n in @(Get-Content $VmFlag | Where-Object { $_ } | Select-Object -Unique)) {
        $rvm = Get-VM -Name $n -ErrorAction SilentlyContinue
        if ($rvm -and $rvm.State -ne 'Running') {
            $back = Read-Host "Earlier I stopped the '$n' VM. Start it again now? (y/N)"
            if ($back -eq 'y') { Start-VM -Name $n; Write-Host "'$n' starting." -ForegroundColor Green }
        }
    }
    Remove-Item $VmFlag -ErrorAction SilentlyContinue
}

Also delete the now-unused legacy line `$VmFlag = Join-Path $env:TEMP 'agentic-blarai-vm-stopped.flag'`.
```
RISK: Low-medium. Stop-VM performs a clean guest shutdown by default. A dynamic-memory VM shows its current MemoryAssigned, which is the honest number. Keep stop-llm.ps1's legacy-%TEMP%-flag check for one transition period.

### [P1/medium] New 'AI Status' script + Desktop launcher (which model, RAM, VMs, last log)
Today the only way to know what is loaded is to remember a curl URL or open Task Manager — both fail the user's known friction pattern. One double-click answering 'is a model running, which one, how much RAM is left, which VMs are up, where is the last server log' removes most of the guesswork (including the /models mismatch confusion already hit once).
```text
Create C:\Users\mrbla\agentic-setup\scripts\ai-status.ps1 (pure ASCII):

# AI Status - one screen: model, memory, VMs, last server log. Read-only.
$ErrorActionPreference = 'SilentlyContinue'
$StateDir = 'C:\Users\mrbla\agentic-setup\state'
Write-Host "=== AI STATUS ===" -ForegroundColor Cyan
$ovms = Get-Process ovms
if ($ovms) {
    $ws = [math]::Round(($ovms | Measure-Object WorkingSet64 -Sum).Sum / 1GB, 1)
    Write-Host ("Model server : RUNNING (PID {0}, ~{1} GB, since {2:HH:mm})" -f $ovms[0].Id, $ws, $ovms[0].StartTime) -ForegroundColor Green
    try {
        $ids = @(((Invoke-WebRequest 'http://127.0.0.1:8000/v3/models' -TimeoutSec 3 -UseBasicParsing).Content | ConvertFrom-Json).data | ForEach-Object { $_.id })
        Write-Host ("Loaded model : {0}" -f ($ids -join ', ')) -ForegroundColor Green
    } catch { Write-Host "Loaded model : server is up but not answering yet (still loading?)" -ForegroundColor Yellow }
} else {
    Write-Host "Model server : NOT running (double-click a model launcher to start one)" -ForegroundColor Yellow
    $l = Get-NetTCPConnection -LocalPort 8000 -State Listen | Select-Object -First 1
    if ($l) { $o = Get-Process -Id $l.OwningProcess; Write-Host ("WARNING: port 8000 is held by '{0}' (PID {1}) - model starts will fail until it is closed." -f $o.Name, $o.Id) -ForegroundColor Red }
}
$os = Get-CimInstance Win32_OperatingSystem
Write-Host ("Memory       : {0} GB free of {1} GB" -f [math]::Round($os.FreePhysicalMemory/1MB,1), [math]::Round($os.TotalVisibleMemorySize/1MB,1))
$vms = @(Get-VM)
if ($vms) { foreach ($vm in $vms) {
    $extra = ''; if ($vm.State -eq 'Running') { $extra = ' (using ' + [math]::Round($vm.MemoryAssigned/1GB,1) + ' GB)' }
    Write-Host ("VM           : {0} - {1}{2}" -f $vm.Name, $vm.State, $extra) -ForegroundColor $(if ($vm.State -eq 'Running') {'Green'} else {'Gray'})
} } else { Write-Host "VM           : none visible" -ForegroundColor Gray }
if (Test-Path (Join-Path $StateDir 'stopped-vms.txt')) { Write-Host "Note         : a VM was stopped earlier to free memory; 'Stop AI Models' will offer the restart." -ForegroundColor Yellow }
$log = Get-ChildItem (Join-Path $StateDir 'logs') -Filter 'ovms-*.err.log' | Sort-Object LastWriteTime -Descending | Select-Object -First 1
if ($log) { Write-Host ("Last log     : {0}" -f $log.FullName); Get-Content $log.FullName -Tail 3 | ForEach-Object { Write-Host ('   ' + $_) -ForegroundColor DarkGray } }

Create C:\Users\mrbla\agentic-setup\AI Status.cmd (same pwsh/powershell pattern as the other launchers, ending in `pause`), plus a Desktop stub per the drift fix below.
```
RISK: Minimal - strictly read-only.

### [P1/small] Desktop .cmd drift: replace copies with 2-line call-stubs (single source of truth)
The five Desktop .cmd files are full byte-copies of the agentic-setup originals (diff-verified identical today) with NO sync mechanism in any script — the next edit to an original silently leaves the Desktop running old logic. A stub that `call`s the original makes drift structurally impossible while keeping the double-click UX.
```text
Run once in PowerShell (also covers the new AI Status.cmd):

$names = 'Deep Coding (30B).cmd','Everyday AI (14B).cmd','Screenshot Vision (8B).cmd','Stop AI Models.cmd','Open Coding Chat.cmd','AI Status.cmd'
foreach ($n in $names) {
  Set-Content -Path (Join-Path "$env:USERPROFILE\Desktop" $n) -Encoding Ascii -Value @(
    '@echo off',
    ('call "C:\Users\mrbla\agentic-setup\{0}"' -f $n)
  )
}
```
RISK: Minimal. `call` preserves pause/exit behavior of the originals. If agentic-setup is ever moved, six stubs break loudly (clear 'not found' message) instead of silently running stale logic.

### [P1/small] Open Coding Chat.cmd: window closes before the user can read an error
It is the only launcher without a trailing `pause`. open-coding.ps1 handles its own friendly exits with Read-Host, but any UNHANDLED exception (EAP=Stop: opencode shim missing from PATH, projects dir ACL issue, FolderBrowserDialog/STA quirk) kills the window instantly — the novice sees a flash and nothing else.
```text
In C:\Users\mrbla\agentic-setup\Open Coding Chat.cmd append after the if/else block:

if errorlevel 1 (
  echo.
  echo Something went wrong above. Take a photo of this window if you need help.
  pause
)
```
RISK: None. The pause only triggers on non-zero exit, so the normal close-the-TUI flow is unchanged.

### [P1/small] new-agent-task.ps1: check git exit codes, sanitize -Task, verify loaded model BEFORE creating the worktree
Three defects: (a) `git -C $Repo worktree add` failure (branch/folder left over from a previous run) is invisible — $ErrorActionPreference='Stop' does not apply to native exit codes in either PS edition here, and $LASTEXITCODE is never checked, so opencode is dispatched into a missing/broken worktree; (b) -Task 'fix logging' (space) produces an invalid branch name; (c) the server check happens AFTER worktree creation and never confirms the LOADED model equals -Model — dispatching a coder-30b task while qwen3-14b is resident yields the Mediapipe-graph error after the worktree was already created. `opencode run --dir` and `-m` flags verified present in --help.
```text
In C:\Users\mrbla\agentic-setup\scripts\new-agent-task.ps1 replace lines 20-32 with:

$Task = ($Task -replace '[^\w\-]', '-').Trim('-')
if (-not $Task) { throw "Task name is empty after removing special characters." }

$repoName = Split-Path $Repo -Leaf
$wt = Join-Path (Split-Path $Repo -Parent) "$repoName-$Task"   # short path, dodge MAX_PATH
$branch = "agent/$Task"

# Check the server AND the loaded model BEFORE creating anything
$wantId = ($Model -split '/')[-1]
try { $ids = @((Invoke-RestMethod 'http://127.0.0.1:8000/v3/models' -TimeoutSec 3).data | ForEach-Object { $_.id }) }
catch { throw "Model server not running - start it first: scripts\start-llm.ps1 -Model coder-30b" }
if ($ids -notcontains $wantId) { throw "Loaded model is '$($ids -join ', ')' but this task needs '$wantId'. Swap first: scripts\start-llm.ps1 -Model coder-30b" }

git -C $Repo worktree add $wt -b $branch
if ($LASTEXITCODE -ne 0) { throw "git worktree add failed - branch '$branch' or folder '$wt' probably already exists from a previous run. Clean up per the comment at the top of this script." }
Write-Host "Worktree: $wt  (branch $branch)" -ForegroundColor Cyan

Write-Host "Dispatching to OpenCode ($Model)..." -ForegroundColor Cyan
opencode run --dir $wt -m $Model $Prompt
if ($LASTEXITCODE -ne 0) { Write-Host "OpenCode exited with code $LASTEXITCODE - the task may be incomplete. Worktree kept for inspection: $wt" -ForegroundColor Red }
```
RISK: Low. Sanitization matches open-coding.ps1's existing rule, so names stay consistent.

### [P2/small] start-llm.ps1: needGB sanity — raise vision from 8 to 10, re-verify 30B's 21 from new logs
All three model starts pass `--cache_size 4` (4 GB KV cache pre-allocation) — including vision, whose needGB is 8 against \~6 GB resident weights + 4 GB cache + runtime overhead. 14B at 13 (10.5 resident) and 30B at 21 (matches BLUEPRINT's '>= 21 GB' lean rule) are plausible but were never confirmed against captured logs because there were no logs. After the log-capture fix lands, read the first allocation lines of state\logs\ovms-vision-*.err.log and adjust.
```text
In C:\Users\mrbla\agentic-setup\scripts\start-llm.ps1, in the 'vision' switch branch change:
        $needGB = 8
to:
        $needGB = 10
Optionally also pass a smaller cache for vision (screenshots need far less KV): change `$extra = @()` to `$extra = @('--cache_size','2')` and remove '--cache_size','4' from the shared $args2 line into each branch's $extra so each model declares its own.
```
RISK: Low. Worst case the assistant asks the user to close one more app than strictly necessary.

### [P2/small] 04-seed-offline.ps1: never repoint npm at Verdaccio unless it is actually answering; pip via uv needs --with pip
Lines 32-33 run `npm config set registry http://localhost:4873/` unconditionally. If the Verdaccio install or scheduled-task start failed (both unchecked, EAP=Continue), EVERY future npm/pnpm install on the machine breaks with confusing network errors — including reinstalling opencode. Separately, `uv run --python 3.12 -- python -m pip download` can fail with 'No module named pip' on uv-managed interpreters; `--with pip` guarantees pip is present. Also (Get-Command verdaccio.cmd).Source on $null feeds New-ScheduledTaskAction a null Execute.
```text
Replace lines 25-33 with:

$verdaccioCmd = (Get-Command verdaccio.cmd -ErrorAction SilentlyContinue).Source
if ($verdaccioCmd) {
    $action  = New-ScheduledTaskAction -Execute $verdaccioCmd
    $trigger = New-ScheduledTaskTrigger -AtLogOn
    Register-ScheduledTask -TaskName 'Verdaccio' -Action $action -Trigger $trigger -Force | Out-Null
    Start-ScheduledTask -TaskName 'Verdaccio'
    Start-Sleep 5
}
$verdaccioUp = $false
try { Invoke-WebRequest 'http://localhost:4873/-/ping' -TimeoutSec 5 -UseBasicParsing | Out-Null; $verdaccioUp = $true } catch {}
if ($verdaccioUp) {
    npm config set registry http://localhost:4873/
    pnpm config set registry http://localhost:4873/
} else {
    Write-Host "Verdaccio is NOT responding - leaving npm/pnpm at the default registry so installs keep working. Fix Verdaccio, then set the registry manually." -ForegroundColor Red
}

And change both wheelhouse lines (15 and 17) from `uv run --python 3.1X -- python -m pip download ...` to `uv run --python 3.1X --with pip -- python -m pip download ...`.
```
RISK: Low. The ping gate only defers an optimization; nothing else depends on the registry switch.

### [P2/small] 05-overnight-power.ps1: hard admin check (silent no-op today) 
The script says 'Run as Administrator' in a comment, but with $ErrorActionPreference='Continue' every powercfg call fails quietly in a normal shell — the user believes overnight protection is configured, then Modern Standby kills the first fleet night. This is the highest-consequence silent failure in the 01-05 set.
```text
Insert at the top of C:\Users\mrbla\agentic-setup\scripts\05-overnight-power.ps1, after line 4:

if (-not ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Write-Host "This one needs admin: right-click PowerShell > 'Run as administrator', then run the script again. Nothing was changed." -ForegroundColor Red
    exit 1
}
```
RISK: None.

### [P2/small] PS 5.1 fallback parity: -UseBasicParsing in start-llm; avoid `git init 2>$null` under EAP=Stop
All .cmd launchers fall back to powershell.exe (5.1) when pwsh is absent (pwsh 7.6.1 is installed today, so these are latent, but the fallback exists by design). (a) start-llm.ps1 line 176 Invoke-WebRequest lacks -UseBasicParsing — on PS 5.1 it can fail on the IE-engine dependency (open-coding.ps1 already does this correctly). (b) open-coding.ps1 line 64 `git -C $target init 2>$null` under $ErrorActionPreference='Stop' throws NativeCommandError on PS 5.1 whenever git emits stderr hints (e.g. default-branch advice), killing the script right after creating the folder; PS 7.2+ is immune.
```text
(a) Covered if the READY-check fix above is applied (it adds -UseBasicParsing); otherwise add the switch to line 176.
(b) In C:\Users\mrbla\agentic-setup\scripts\open-coding.ps1 replace line 64 with:

    git -C $target -c init.defaultBranch=main init *> $null

(`*> $null` merges all streams without creating ErrorRecords on 5.1, and pinning init.defaultBranch suppresses the stderr hints at the source.)
```
RISK: None observable on PS 7; removes a latent PS 5.1 crash.

