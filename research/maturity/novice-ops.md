# novice-ops

## VERIFIED FACTS
VERIFIED BY FILE READS: (1) C:\Users\mrbla\.wslconfig contains ONLY "[wsl2]\nnetworkingMode=mirrored" — no memory cap, exactly as the blueprint warns; configs\wslconfig-snippet.txt already documents the target state (memory=4GB, processors=4). (2) start-llm.ps1 starts ovms.exe minimized with NO log capture — the two stray logs (agentic-setup\ovms-30b.log, ovms-test.log) are from manual runs; "last 5 log lines" is impossible today without adding --log_path. (3) stop-llm.ps1 is 4 lines and knows nothing about any fleet flag. (4) open-coding.ps1 uses C:\Users\mrbla\projects (local, safe) but its [B]rowse dialog allows any folder; it already has a BlarAI/.openclaw guard to extend. (5) start-llm.ps1 -Force skips all interactive prompts — perfect watchdog entry point; valid -Model values are coder-30b|qwen3-14b|vision. VERIFIED BY COMMAND OUTPUT: (6) WSL is NOT INSTALLED at all ("wsl --list" errors) — the .wslconfig is pre-staging, so the cap edit is zero-risk now. (7) ~/.ollama exists, 16.8 GB, and the Ollama app is GONE (not on PATH, no app dir) — the blob dir is orphaned data; it also contains an id_ed25519 keypair (recycle-bin recovery covers regret). (8) ovms NOT currently running, health endpoint dead, 22.5/31.3 GB RAM free, BlarAI-Orchestrator VM Off, C: has 202.4 GB free, coder-30b on disk = 15.2 GB. (9) C:\ovms\ovms.exe --help confirms --log_path and --log_level flags exist (OVMS 2026.2.5e9dcfc46 installed). (10) 02-install script downloads models via uvx hf download, NOT via ovms.exe — so an outbound block on ovms.exe costs nothing; no existing ovms/OpenVINO firewall rules. (11) opencode 1.17.3 installed = npm latest 1.17.3 (npm view works on this box). (12) Documents IS OneDrive-redirected (User Shell Folders: Personal=C:\Users\mrbla\OneDrive\Documents) and OneDrive.exe is running; Desktop is local. (13) Power: standby-timeout-AC already 0 (05-overnight-power.ps1 evidently applied); Windows Update active hours = 11:00→05:00, leaving 05:00–11:00 exposed to auto-restart — overlaps the tail of overnight runs. (14) Arc 140V driver 32.0.101.8826 (2026-05-28) matches blueprint known-good. (15) agentic-setup is NOT a git repo (.git absent); note C:\Users\mrbla itself IS a git repo, so a nested independent repo is the clean approach. (16) Bitdefender is present (its own watchdog task exists). (17) Get-VM works unelevated for this user (probe succeeded), so status/start scripts can keep using it. (18) Desktop launchers exist and follow a consistent pwsh-fallback-to-powershell .cmd pattern; scripts must stay PS5.1-safe (ASCII, -UseBasicParsing).

## IMPROVEMENTS

### [P0/small] Cap WSL2 memory in .wslconfig now (pre-staged, zero impact until WSL is installed)
Verified: .wslconfig has only networkingMode=mirrored, and WSL itself is not installed yet. That is exactly WHY to do it now: the moment anything installs WSL2 (OpenClaw phase 7 hardening, Docker Desktop, a stray 'wsl --install'), an uncapped WSL2 balloons to ~15.7 GB (50% of RAM) and kills the fleet tier. Pre-staging the cap means the trap can never spring. Preserves the existing mirrored-networking line; backup follows the existing .wslconfig.bak-<stamp> convention already present in the home dir.
```text
# PowerShell (no admin needed):
Copy-Item "$env:USERPROFILE\.wslconfig" "$env:USERPROFILE\.wslconfig.bak-$(Get-Date -Format yyyyMMdd-HHmmss)"
Set-Content "$env:USERPROFILE\.wslconfig" -Encoding ascii @'
[wsl2]
networkingMode=mirrored
memory=4GB
processors=4
'@
# Verify: Get-Content $env:USERPROFILE\.wslconfig
# (wsl --shutdown is NOT needed today - WSL is not installed; the file is read when it first starts.)
```
RISK: None today (WSL absent). Later: if a WSL workload legitimately needs >4GB, raise the number — symptoms are OOM-kills inside the distro, never host instability.

### [P0/small] Make OVMS write a log file: add --log_path to start-llm.ps1 (+14-day rotation)
Today OVMS output lives in a minimized console window and dies with it — when a model crashes overnight there is zero forensic trail, and the requested 'last 5 log lines' in AI Status is impossible. Verified C:\ovms\ovms.exe --help shows --log_path exists in the installed 2026.2 build. One edit to start-llm.ps1 gives every run a dated log under state\logs with automatic 14-day cleanup. Also relocates the two stray root logs.
```text
# In scripts\start-llm.ps1, replace the $args2 = @(...) block (lines 166-167) with:
$LogDir = Join-Path $PSScriptRoot '..\state\logs'
New-Item -ItemType Directory -Force $LogDir | Out-Null
Get-ChildItem $LogDir -Filter 'ovms-*.log' -ErrorAction SilentlyContinue |
    Where-Object { $_.LastWriteTime -lt (Get-Date).AddDays(-14) } |
    Remove-Item -ErrorAction SilentlyContinue
$LogFile = Join-Path $LogDir ("ovms-$Model-{0}.log" -f (Get-Date -Format 'yyyyMMdd-HHmmss'))
$args2 = @('--rest_port','8000','--rest_bind_address','127.0.0.1','--model_path',$path,'--model_name',$name,
           '--task','text_generation','--target_device','GPU','--cache_size','4',
           '--log_path',$LogFile) + $extra

# One-time tidy of the stray manual-test logs:
New-Item -ItemType Directory -Force C:\Users\mrbla\agentic-setup\state\logs | Out-Null
Move-Item C:\Users\mrbla\agentic-setup\ovms-*.log C:\Users\mrbla\agentic-setup\state\logs\
```
RISK: Minimal. If a future OVMS release renames the flag, start-llm.ps1 already documents the drift procedure (ovms.exe --help). Logs are small (~KB per run) and self-pruned.

### [P0/medium] Add 'AI Status' double-click dashboard (model, RAM, VMs, health, logs, power, driver, disk)
The single biggest novice multiplier: one double-click answers 'is it running, which model, do I have room, why did it die'. Read-only — cannot break anything. Depends on the --log_path change for the log tail. Follows the exact .cmd launcher pattern of the five existing launchers.
```text
# NEW FILE C:\Users\mrbla\agentic-setup\scripts\ai-status.ps1 :
# AI Status - read-only dashboard. Changes nothing. (PS5.1-safe, pure ASCII)
$ErrorActionPreference = 'SilentlyContinue'
$Setup = 'C:\Users\mrbla\agentic-setup'
$KnownGoodDriver = '32.0.101.8826'   # update after a VERIFIED-good driver update
Write-Host ("=== AI STATUS  {0} ===" -f (Get-Date -Format 'yyyy-MM-dd HH:mm')) -ForegroundColor Cyan
# 1. Model server
$ovms = Get-Process ovms -ErrorAction SilentlyContinue
$loaded = $null
try { $r = Invoke-WebRequest 'http://127.0.0.1:8000/v3/models' -TimeoutSec 3 -UseBasicParsing
      $loaded = (($r.Content | ConvertFrom-Json).data | ForEach-Object { $_.id }) -join ', ' } catch {}
if ($loaded)   { Write-Host "Model server : HEALTHY - loaded: $loaded" -ForegroundColor Green }
elseif ($ovms) { Write-Host 'Model server : process running but API not answering (still loading? wait 60s, re-run)' -ForegroundColor Yellow }
else           { Write-Host 'Model server : NOT RUNNING (double-click a model launcher to start one)' }
# 2. Memory (blueprint yellow line: >26 GB in use)
$os = Get-CimInstance Win32_OperatingSystem
$totalGB = [math]::Round($os.TotalVisibleMemorySize/1MB,1); $freeGB = [math]::Round($os.FreePhysicalMemory/1MB,1)
$useGB = [math]::Round($totalGB - $freeGB,1)
$col = 'Green'; if ($useGB -gt 26) { $col = 'Red' } elseif ($useGB -gt 23) { $col = 'Yellow' }
Write-Host ("Memory       : {0} GB in use / {1} GB total ({2} GB available)" -f $useGB,$totalGB,$freeGB) -ForegroundColor $col
if ($ovms) { Write-Host ("               ovms.exe is using {0} GB" -f [math]::Round($ovms.WorkingSet64/1GB,1)) }
# 3. VMs
Get-VM -ErrorAction SilentlyContinue | ForEach-Object { Write-Host ("VM           : {0} - {1}" -f $_.Name,$_.State) }
# 4. Power source
$bat = Get-CimInstance Win32_Battery
if ($bat -and $bat.BatteryStatus -eq 1) { Write-Host "Power        : ON BATTERY ($($bat.EstimatedChargeRemaining)%) - plug in for AI work!" -ForegroundColor Yellow }
else { Write-Host 'Power        : AC (good)' -ForegroundColor Green }
# 5. Fleet mode / watchdog
if (Test-Path "$Setup\state\fleet-mode.flag") { Write-Host ('Fleet mode   : ON - watchdog will auto-restart the server (model: ' + (Get-Content "$Setup\state\fleet-mode.flag" -First 1) + ')') -ForegroundColor Cyan }
else { Write-Host 'Fleet mode   : off (watchdog idle - manual stops are respected)' }
# 6. GPU driver drift
$drv = (Get-CimInstance Win32_VideoController | Where-Object Name -like '*Arc*').DriverVersion
if ($drv -eq $KnownGoodDriver) { Write-Host "GPU driver   : $drv (known-good)" -ForegroundColor Green }
else { Write-Host "GPU driver   : $drv - CHANGED from known-good $KnownGoodDriver. If inference breaks, this is suspect #1." -ForegroundColor Yellow }
# 7. Disk
$d = Get-PSDrive C; Write-Host ("Disk C:      : {0} GB free" -f [math]::Round($d.Free/1GB,1)) -ForegroundColor $(if ($d.Free -lt 60GB) {'Yellow'} else {'Green'})
# 8. Last 5 server log lines
$log = Get-ChildItem "$Setup\state\logs\ovms-*.log" -ErrorAction SilentlyContinue | Sort-Object LastWriteTime | Select-Object -Last 1
if ($log) { Write-Host "--- last 5 lines of $($log.Name) ---" -ForegroundColor Cyan; Get-Content $log.FullName -Tail 5 }
else { Write-Host '(no server logs yet - they appear after the next model start)' }
Read-Host 'Press Enter to close'

# NEW FILE C:\Users\mrbla\agentic-setup\AI Status.cmd  (copy to Desktop too):
@echo off
title AI Status
where pwsh >nul 2>nul
if %errorlevel%==0 (
  pwsh -NoProfile -ExecutionPolicy Bypass -File "C:\Users\mrbla\agentic-setup\scripts\ai-status.ps1"
) else (
  powershell -NoProfile -ExecutionPolicy Bypass -File "C:\Users\mrbla\agentic-setup\scripts\ai-status.ps1"
)
```
RISK: None functional (read-only). Get-VM verified to work unelevated for this user. Driver constant must be manually bumped after an intentional, verified driver update.

### [P0/medium] Fleet-mode watchdog: scheduled task restarts OVMS only when the sentinel flag exists
For overnight runs: every 5 minutes, IF state\fleet-mode.flag exists, probe /v3/models; on two consecutive failures 30s apart, kill ovms and relaunch via the existing start-llm.ps1 -Force path (which skips all prompts — verified in the script). The flag contains the model name. Crucially, 'Stop AI Models' must clear the flag so the watchdog NEVER fights a manual stop — that is a 3-line edit to stop-llm.ps1. An AtLogOn trigger self-heals after a Windows Update reboot. Honest limit to document: the task runs 'only when user is logged on', so a 3am reboot pauses fleet night until you log in — acceptable, because opencode serve and the agents died in that reboot anyway.
```text
# NEW FILE C:\Users\mrbla\agentic-setup\scripts\watchdog.ps1 :
# Inert unless state\fleet-mode.flag exists (so it never fights manual stops).
$Setup = 'C:\Users\mrbla\agentic-setup'
$Flag  = Join-Path $Setup 'state\fleet-mode.flag'
if (-not (Test-Path $Flag)) { exit 0 }
$Model = (Get-Content $Flag -ErrorAction SilentlyContinue | Select-Object -First 1)
if (@('coder-30b','qwen3-14b','vision') -notcontains $Model) { $Model = 'qwen3-14b' }
$Log = Join-Path $Setup 'state\logs\watchdog.log'
function Test-Health { try { Invoke-WebRequest 'http://127.0.0.1:8000/v3/models' -TimeoutSec 10 -UseBasicParsing | Out-Null; $true } catch { $false } }
if (Test-Health) { exit 0 }
Start-Sleep -Seconds 30   # one retry: do not restart on a transient blip
if (Test-Health) { exit 0 }
Add-Content $Log "$(Get-Date -Format s) health FAILED twice - restarting $Model"
Get-Process ovms -ErrorAction SilentlyContinue | Stop-Process -Force
Start-Sleep -Seconds 5
& powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $Setup 'scripts\start-llm.ps1') -Model $Model -Force
if (Test-Health) { Add-Content $Log "$(Get-Date -Format s) restart OK" } else { Add-Content $Log "$(Get-Date -Format s) restart FAILED - needs a human" }

# REPLACE scripts\stop-llm.ps1 entirely with:
# Stop the local model server (frees its RAM) AND turn fleet mode off.
$Flag = 'C:\Users\mrbla\agentic-setup\state\fleet-mode.flag'
if (Test-Path $Flag) { Remove-Item $Flag; Write-Host 'Fleet mode was ON - turned OFF so the watchdog stays quiet.' -ForegroundColor Yellow }
$p = Get-Process ovms -ErrorAction SilentlyContinue
if ($p) { $p | Stop-Process -Force; Write-Host 'OVMS stopped.' -ForegroundColor Green } else { Write-Host 'OVMS was not running.' }

# NEW Desktop launcher 'Fleet Mode ON.cmd':
@echo off
title Fleet Mode ON
echo qwen3-14b> "C:\Users\mrbla\agentic-setup\state\fleet-mode.flag"
echo Fleet mode ON: the watchdog will keep qwen3-14b alive (checks every 5 min).
echo Turn it off with 'Fleet Mode OFF' or 'Stop AI Models'.
pause
# NEW Desktop launcher 'Fleet Mode OFF.cmd':
@echo off
title Fleet Mode OFF
del "C:\Users\mrbla\agentic-setup\state\fleet-mode.flag" 2>nul
echo Fleet mode OFF: the watchdog is idle; manual stops are respected.
pause

# ONE-TIME registration (normal PowerShell, no admin needed for a current-user task):
$a  = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument '-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File C:\Users\mrbla\agentic-setup\scripts\watchdog.ps1'
$t1 = New-ScheduledTaskTrigger -Once -At (Get-Date).AddMinutes(1) -RepetitionInterval (New-TimeSpan -Minutes 5)
$t2 = New-ScheduledTaskTrigger -AtLogOn
$s  = New-ScheduledTaskSettingsSet -StartWhenAvailable -MultipleInstances IgnoreNew -ExecutionTimeLimit (New-TimeSpan -Minutes 10)
Register-ScheduledTask -TaskName 'Agentic-ModelServer-Watchdog' -Action $a -Trigger $t1,$t2 -Settings $s -Description 'Restarts OVMS in fleet mode if /v3/models dies. Inert unless state\fleet-mode.flag exists.'
# Remove later with: Unregister-ScheduledTask -TaskName 'Agentic-ModelServer-Watchdog' -Confirm:$false
```
RISK: A hidden powershell.exe may flash a console for a fraction of a second every 5 min (cosmetic). If the 30B is mid-load (loads take 30-90s) when the probe runs, the double-check 30s apart plus the 180s readiness loop inside start-llm.ps1 make a false restart unlikely but not impossible on a pathologically slow load; fleet tier is 14B anyway per blueprint rule. Task does not run when logged out (documented above).

### [P0/medium] Known-good config backups: dated zip + numbered restore, and make agentic-setup a git repo
Blueprint section 10 already demands 'zip your three config files before first autonomous run' — this automates it. Backs up the LIVE files the tools actually read (opencode.json from ~\.config, openclaw.json when phase 4 lands, .wslconfig) plus the whole scripts/configs/launchers set. Keeps newest 12. Restore is a numbered picker with per-item confirm and a .before-restore safety copy. GIT RECOMMENDATION: YES — init a local-only repo in agentic-setup (ignore state/ and *.log). Rationale: zips give the novice the restore button; git gives diff/history when debugging 'what changed since it worked'. No remote — security-first, nothing leaves the machine. The backup script auto-commits, so the user never types a git command. (Note: C:\Users\mrbla is itself a git repo; a nested independent repo is cleaner than tracking via the parent.)
```text
# NEW FILE scripts\backup-config.ps1 :
$ErrorActionPreference = 'Stop'
$Setup = 'C:\Users\mrbla\agentic-setup'
$Dest = Join-Path $Setup 'state\backups'; New-Item -ItemType Directory -Force $Dest | Out-Null
$stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$work = Join-Path $env:TEMP "cfgbak-$stamp"; New-Item -ItemType Directory -Force "$work\live" | Out-Null
foreach ($f in @("$env:USERPROFILE\.config\opencode\opencode.json", "$env:USERPROFILE\.openclaw\openclaw.json", "$env:USERPROFILE\.wslconfig")) {
    if (Test-Path $f) { Copy-Item $f "$work\live\" }
}
Copy-Item "$Setup\scripts" "$work\scripts" -Recurse
Copy-Item "$Setup\configs" "$work\configs" -Recurse
Copy-Item "$Setup\*.cmd" $work
Copy-Item "$Setup\BLUEPRINT.md" $work
$zip = Join-Path $Dest "config-$stamp.zip"
Compress-Archive -Path "$work\*" -DestinationPath $zip
Remove-Item $work -Recurse -Force
Get-ChildItem $Dest -Filter 'config-*.zip' | Sort-Object LastWriteTime -Descending | Select-Object -Skip 12 | Remove-Item
Write-Host "Backed up to $zip" -ForegroundColor Green
if (Get-Command git -ErrorAction SilentlyContinue) { git -C $Setup add -A 2>$null; git -C $Setup commit -m "config backup $stamp" 2>$null | Out-Null }
Read-Host 'Press Enter to close'

# NEW FILE scripts\restore-config.ps1 :
$ErrorActionPreference = 'Stop'
$Setup = 'C:\Users\mrbla\agentic-setup'
$zips = @(Get-ChildItem "$Setup\state\backups\config-*.zip" -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending)
if (-not $zips) { Write-Host 'No backups yet - run Backup AI Configs first.'; Read-Host 'Enter to close'; exit }
for ($i=0; $i -lt $zips.Count; $i++) { Write-Host ("  [{0}] {1}" -f ($i+1), $zips[$i].Name) }
$c = Read-Host 'Restore which number? (Q quits)'
if ($c -notmatch '^\d+$' -or [int]$c -lt 1 -or [int]$c -gt $zips.Count) { exit }
$tmp = "$Setup\state\restore-preview"
if (Test-Path $tmp) { Remove-Item $tmp -Recurse -Force }
Expand-Archive $zips[[int]$c-1].FullName -DestinationPath $tmp
$map = @(
  @{ from = "$tmp\live\opencode.json"; to = "$env:USERPROFILE\.config\opencode\opencode.json"; dir = $false },
  @{ from = "$tmp\live\openclaw.json"; to = "$env:USERPROFILE\.openclaw\openclaw.json"; dir = $false },
  @{ from = "$tmp\live\.wslconfig";    to = "$env:USERPROFILE\.wslconfig"; dir = $false },
  @{ from = "$tmp\scripts";            to = "$Setup\scripts"; dir = $true },
  @{ from = "$tmp\configs";            to = "$Setup\configs"; dir = $true }
)
foreach ($m in $map) {
    if (-not (Test-Path $m.from)) { continue }
    if ((Read-Host ("Restore {0} ? (y/N)" -f $m.to)) -ne 'y') { continue }
    if (Test-Path $m.to) { Copy-Item $m.to "$($m.to).before-restore" -Recurse -Force -ErrorAction SilentlyContinue }
    if ($m.dir) { Copy-Item "$($m.from)\*" $m.to -Recurse -Force } else { New-Item -ItemType Directory -Force (Split-Path $m.to) | Out-Null; Copy-Item $m.from $m.to -Force }
    Write-Host 'restored.' -ForegroundColor Green
}
Write-Host 'Done. Restart the model server / OpenCode to pick up changes.'
Read-Host 'Press Enter to close'

# Launchers 'Backup AI Configs.cmd' / 'Restore AI Configs.cmd' follow the existing pwsh-fallback pattern, pointing at these two scripts.

# ONE-TIME git init (local only, no remote):
Set-Content C:\Users\mrbla\agentic-setup\.gitignore -Encoding ascii "state/`n*.log"
git -C C:\Users\mrbla\agentic-setup init
git -C C:\Users\mrbla\agentic-setup add -A
git -C C:\Users\mrbla\agentic-setup commit -m 'baseline: validated working setup 2026-06-10'
```
RISK: Low. Backups exclude models (15+ GB — correct). Restoring scripts over a half-edited scripts dir overwrites local experiments (the .before-restore copies and git history both cover that). state/ is gitignored so fleet flags/logs never pollute history.

### [P0/small] OneDrive guard in open-coding.ps1 (Documents IS OneDrive-redirected on this machine)
Verified: Personal folder = C:\Users\mrbla\OneDrive\Documents and OneDrive.exe is running. The [N]ew-project path is safe (C:\Users\mrbla\projects, local), but the [B]rowse dialog lets a novice pick Documents — the natural-feeling place — after which the first npm install syncs tens of thousands of node_modules files: CPU/battery thrash, quota burn, sync conflicts corrupting agent edits. This WILL happen in month 2 without a guard. Mirrors the existing BlarAI/.openclaw forbidden-folder pattern already in the script.
```text
# In scripts\open-coding.ps1, insert AFTER the existing forbidden-folders loop (after line 85):
# OneDrive sync trap: node_modules in a synced folder thrashes CPU/battery/quota
if ($env:OneDrive -and ($target.TrimEnd('\') -like "$env:OneDrive*")) {
    Write-Host "Heads-up: that folder is inside OneDrive ($env:OneDrive)." -ForegroundColor Yellow
    Write-Host "Coding projects there sync thousands of files (node_modules) - slow, noisy, and edits can conflict."
    Write-Host "Better home: C:\Users\mrbla\projects  (the [N]ew project option puts things there)."
    $go = Read-Host "Use this OneDrive folder anyway? (y/N)"
    if ($go -ne 'y') { Read-Host 'Press Enter to close'; exit 1 }
}
```
RISK: None — warn-and-confirm, never blocks. Edge case: paths compared as prefixes could in theory false-positive on a sibling folder literally named 'OneDriveX'; TrimEnd plus the wildcard keeps this acceptable.

### [P1/small] Block outbound network for ovms.exe (defense in depth; verified it costs nothing)
Verified no existing ovms firewall rules, AND that model downloads go through uvx/hf-cli, not ovms.exe — the only thing that would need ovms outbound is the unused --source_model HF-pull mode. Serving is inbound-on-loopback and unaffected by an outbound block (Windows exempts loopback in WFP regardless). On a security-first machine this turns 'the model server never phones anywhere' from policy into enforcement.
```text
# Requires an ELEVATED PowerShell (right-click Start -> Terminal (Admin)):
New-NetFirewallRule -DisplayName 'Block outbound - OVMS model server' -Direction Outbound -Program 'C:\ovms\ovms.exe' -Action Block -Profile Any -Enabled True
# Verify:
Get-NetFirewallRule -DisplayName 'Block outbound - OVMS model server' | Format-List DisplayName,Direction,Action,Enabled
# Temporarily lift (e.g. if you ever use ovms --source_model HF pull mode):
Disable-NetFirewallRule -DisplayName 'Block outbound - OVMS model server'
Enable-NetFirewallRule  -DisplayName 'Block outbound - OVMS model server'
# Permanent revert:
Remove-NetFirewallRule  -DisplayName 'Block outbound - OVMS model server'
```
RISK: Low. If a future OVMS feature (HF pull, telemetry, remote tokenizer fetch) silently needs outbound, the symptom is a hang/timeout at startup — the disable command is the 10-second diagnostic. Document the rule name in BLUEPRINT.md section 10 so future-you finds it.

### [P1/small] Monthly check-only update script (opencode / OVMS / OpenClaw / GPU driver drift)
Blueprint pinning doctrine says 'update monthly, reading release notes' — this makes the check a double-click. Verified mechanics on this box: 'npm view opencode-ai version' returns 1.17.3 (matches installed), ovms.exe --version prints a parseable line, and the GitHub releases API is how 02-install already finds OVMS. NEVER installs. Also prints the one npm footgun rule: 'npm update -g' would silently bump pinned tools past their pins.
```text
# NEW FILE scripts\check-updates.ps1 :
# CHECKS for updates - never installs anything. Run monthly (double-click 'Check AI Updates').
$ErrorActionPreference = 'SilentlyContinue'
Write-Host '=== Update check (nothing will be installed) ===' -ForegroundColor Cyan
$cur = (opencode --version) 2>$null; $new = (npm view opencode-ai version) 2>$null
$col = 'Yellow'; if ("$cur" -eq "$new") { $col = 'Green' }
Write-Host ("OpenCode : installed {0}   latest {1}" -f $cur,$new) -ForegroundColor $col
Write-Host '           notes: https://github.com/anomalyco/opencode/releases'
$verLine = (& 'C:\ovms\ovms.exe' --version 2>$null | Select-String 'Model Server') -join ''
$rel = Invoke-RestMethod 'https://api.github.com/repos/openvinotoolkit/model_server/releases/latest' -TimeoutSec 15
Write-Host ("OVMS     : installed {0}" -f $verLine.Trim())
Write-Host ("           latest    {0}" -f $rel.tag_name)
Write-Host '           notes: https://github.com/openvinotoolkit/model_server/releases'
if (Get-Command openclaw -ErrorAction SilentlyContinue) {
  $cur = (openclaw --version) 2>$null; $new = (npm view openclaw version) 2>$null
  Write-Host ("OpenClaw : installed {0}   latest {1}   (PINNED - read the security advisories BEFORE moving the pin)" -f $cur,$new) -ForegroundColor Yellow
} else { Write-Host 'OpenClaw : not installed yet (phase 4)' }
$known = '32.0.101.8826'
$drv = (Get-CimInstance Win32_VideoController | Where-Object Name -like '*Arc*').DriverVersion
if ($drv -eq $known) { Write-Host "GPU drv  : $drv (known-good)" -ForegroundColor Green }
else { Write-Host "GPU drv  : $drv - changed from known-good $known. Keep the old installer; watch for TDR/freezes." -ForegroundColor Yellow }
Write-Host ''
Write-Host 'RULES: update ONE tool at a time, after reading notes. NEVER run "npm update -g" (it bumps pinned tools).' -ForegroundColor Yellow
Read-Host 'Press Enter to close'
# Plus a 'Check AI Updates.cmd' launcher using the standard pwsh-fallback pattern.
# Optional monthly nudge (normal PowerShell):
$a = New-ScheduledTaskAction -Execute 'cmd.exe' -Argument '/c "C:\Users\mrbla\agentic-setup\Check AI Updates.cmd"'
$t = New-ScheduledTaskTrigger -Weekly -WeeksInterval 4 -DaysOfWeek Saturday -At 10:00
Register-ScheduledTask -TaskName 'Agentic-Monthly-Update-Check' -Action $a -Trigger $t -Settings (New-ScheduledTaskSettingsSet -StartWhenAvailable)
```
RISK: Needs internet (this is the one deliberately-online script); offline it prints blanks for 'latest' — harmless. GitHub API rate limits are irrelevant at monthly cadence. The scheduled nudge pops a console window — that is the point for a novice; delete the task if it annoys.

### [P1/small] Reclaim 16.8 GB: send orphaned ~/.ollama to the Recycle Bin (verified safe)
Verified: C:\Users\mrbla\.ollama exists at exactly 16.8 GB; the Ollama app is fully uninstalled (not on PATH, no service, app dir gone), so the blobs are orphaned data; coder-30b is on disk (15.2 GB) and was validated serving on 2026-06-10 per the blueprint and ovms-30b.log. The folder also holds Ollama's id_ed25519 identity keypair — moot once the app is gone, and Recycle Bin recovery covers any regret. Recycle-bin-safe method (not Remove-Item) per blueprint's own caution. Also the OVMS log policy: improvement #2 already rotates state\logs at 14 days — that IS the cleanup policy; the two stray root logs get moved there in the same change.
```text
# Normal PowerShell (recoverable - goes to Recycle Bin, NOT permanent delete):
Add-Type -AssemblyName Microsoft.VisualBasic
[Microsoft.VisualBasic.FileIO.FileSystem]::DeleteDirectory(
    "$env:USERPROFILE\.ollama",
    [Microsoft.VisualBasic.FileIO.UIOption]::OnlyErrorDialogs,
    [Microsoft.VisualBasic.FileIO.RecycleOption]::SendToRecycleBin)
# NOTE: disk space returns only when the Recycle Bin is emptied.
# Use the AI stack normally for a week, then: right-click Recycle Bin -> Empty.
```
RISK: Near zero: recoverable from Recycle Bin until emptied. Only caveat: if the documented llama.cpp fallback (blueprint section 3) is ever exercised, it loses the zero-download GGUF smoke-test blobs — it would need a fresh download. Acceptable: coder-30b is the validated primary.

### [P1/small] Shift Windows Update active hours to cover the full overnight window (currently exposed 05:00-07:00)
Verified: active hours are 11:00->05:00 (registry ActiveHoursStart=11, End=5). Blueprint section 8 defines the fleet window as roughly 22:00-07:00 — so Windows is allowed to auto-restart between 05:00 and 07:00, exactly when a long overnight task is finishing. Shifting to 13:00->07:00 keeps the maximum 18-hour span and closes the gap. Power settings are already correct (verified standby-timeout-AC=0). Combined with the watchdog's AtLogOn trigger, an update reboot becomes 'log in, server comes back' instead of a mystery.
```text
# ELEVATED PowerShell (HKLM write):
Set-ItemProperty 'HKLM:\SOFTWARE\Microsoft\WindowsUpdate\UX\Settings' -Name ActiveHoursStart -Value 13
Set-ItemProperty 'HKLM:\SOFTWARE\Microsoft\WindowsUpdate\UX\Settings' -Name ActiveHoursEnd   -Value 7
# Novice-friendly alternative (no admin): Settings > Windows Update > Advanced options > Active hours > Manual: 1:00 PM to 7:00 AM.
# Verify: Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\WindowsUpdate\UX\Settings' | Select-Object ActiveHoursStart,ActiveHoursEnd
```
RISK: Updates then install/restart 07:00-13:00 — daytime; Windows still prompts before restarting while the user is active. If Intune/policy ever manages this device the registry value may be overwritten (not currently the case).

### [P2/small] Month-2 traps: driver auto-update detection, battery runs, Bitdefender scan latency, npm -g discipline
Remaining ruthlessly-prioritized residue not covered above. (a) GPU driver auto-update: Windows Update can swap the Arc driver under you; inference stability on this machine is driver-bound (blueprint section 10). Detection is built into AI Status and check-updates (the $KnownGoodDriver constant) — the remaining action is keeping the current installer on disk. (b) Battery: Modern Standby on battery will sleep mid-inference; AI Status now surfaces ON BATTERY in yellow. (c) Bitdefender (verified present): real-time scanning can add minutes to each 15 GB model load and could slow every agent file-write; if loads feel slow, exclude ONLY the read-only weights dirs — never scripts or repos — a deliberate, narrow trade on a security-first machine. (d) npm: a well-meaning 'npm update -g' bypasses autoupdate:false and the OpenClaw pin; the check-updates script prints the rule monthly. (e) Disk: seeding weekend (section 9) wants 40-60 GB of the 202 GB free; AI Status's disk line yellows under 60 GB before this becomes an emergency.
```text
# (a) Keep the known-good driver installer (one-time, while online):
#     Download Intel Arc driver 32.0.101.8826 installer from intel.com to C:\Users\mrbla\agentic-setup\state\drivers\
#     (AI Status + check-updates already alarm on drift via $KnownGoodDriver.)
# (c) ONLY if model loads become slow and you accept the trade (ELEVATED PowerShell, Bitdefender's own exclusions UI is the supported path; for Defender it would be):
#     Add-MpPreference -ExclusionPath 'C:\models'   # weights only - NEVER exclude scripts, repos, or C:\ovms
# (d) Rule line is already printed by check-updates.ps1: never 'npm update -g'.
# (e) No action now - AI Status disk line yellows < 60 GB free.
```
RISK: (c) is a real security trade — excluding C:\models means a malicious file dropped there is unscanned; mitigate by excluding only after measuring that scanning is actually the bottleneck, and noting the exclusion in BLUEPRINT.md. (a) costs ~1 GB disk for the installer.

