# AI Status - read-only dashboard. Shows everything at a glance; changes nothing.
$ErrorActionPreference = 'Continue'
$LogDir = 'C:\Users\mrbla\agentic-setup\state\logs'
$StoppedVms = 'C:\Users\mrbla\agentic-setup\state\stopped-vms.txt'
$KnownGoodDriver = '32.0.101.8826'

. "$PSScriptRoot\ai-inventory-lib.ps1"   # the ONE model detection (assistant + OVMS + watchdog + the cannot-see notes)

Write-Host "=============== AI STATUS ===============" -ForegroundColor Cyan

# --- AI models in RAM (shared detection; VMs get their own section below) ---
Write-AiInventoryReport (Get-AiModelInventory) -NoVmLine

# --- Memory ---
$os = Get-CimInstance Win32_OperatingSystem
$totalGB = [math]::Round($os.TotalVisibleMemorySize/1MB,1)
try   { $availGB = [math]::Round((Get-Counter '\Memory\Available MBytes').CounterSamples[0].CookedValue/1024,1) }
catch { $availGB = [math]::Round($os.FreePhysicalMemory/1MB,1) }
$usedGB = [math]::Round($totalGB - $availGB,1)
$col = if ($usedGB -gt 26) { 'Red' } elseif ($usedGB -gt 23) { 'Yellow' } else { 'Green' }
Write-Host ("Memory       : {0} GB used of {1} GB ({2} GB available)" -f $usedGB, $totalGB, $availGB) -ForegroundColor $col
if ($col -eq 'Red') { Write-Host "               DANGER ZONE - close apps or stop the model before starting anything heavy." -ForegroundColor Red }

# --- VMs ---
$vms = Get-VM -ErrorAction SilentlyContinue
foreach ($vm in $vms) {
    $c = if ($vm.State -eq 'Running') { 'Green' } else { 'Yellow' }
    Write-Host ("VM           : {0} - {1}" -f $vm.Name, $vm.State) -ForegroundColor $c
}
if (Test-Path $StoppedVms) {
    $names = @(Get-Content $StoppedVms | Where-Object { $_ })
    if ($names) { Write-Host "               note: a model launcher stopped [$($names -join ', ')] - 'Stop AI Models' or the Everyday launcher will offer the restart." -ForegroundColor Yellow }
}

# --- Power / disk / driver ---
$onAC = (Get-CimInstance -ClassName BatteryStatus -Namespace root\wmi -ErrorAction SilentlyContinue | Select-Object -First 1).PowerOnline
if ($null -ne $onAC) {
    if ($onAC) { Write-Host "Power        : plugged in (AC)" -ForegroundColor Green }
    else       { Write-Host "Power        : ON BATTERY - long AI runs will throttle and drain fast" -ForegroundColor Yellow }
}
$d = Get-PSDrive C
Write-Host ("Disk C:      : {0} GB free" -f [math]::Round($d.Free/1GB,0))
$drv = (Get-CimInstance Win32_VideoController | Where-Object Name -like '*Arc*').DriverVersion
if ($drv) {
    if ($drv -eq $KnownGoodDriver) { Write-Host "GPU driver   : $drv (the known-good version)" -ForegroundColor Green }
    else { Write-Host "GPU driver   : $drv (known-good was $KnownGoodDriver - if AI crashes started after an update, this is suspect #1)" -ForegroundColor Yellow }
}

# --- Last server log lines ---
$lastErr = Get-ChildItem $LogDir -Filter 'ovms-*.err.log' -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending | Select-Object -First 1
if ($lastErr) {
    Write-Host ""
    Write-Host "Last server log ($($lastErr.Name)) - final 5 lines:" -ForegroundColor Cyan
    Get-Content $lastErr.FullName -Tail 5 -ErrorAction SilentlyContinue | ForEach-Object { "  $_" }
}
Write-Host "==========================================" -ForegroundColor Cyan
