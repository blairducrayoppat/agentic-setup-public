# Stop the local model server (frees its RAM) and offer to restart any VM
# that the model launchers stopped earlier to make room.
# Hard-stopping OVMS is safe: model files are read-only. If a model LOAD was
# interrupted mid-way and later starts fail oddly, delete C:\models\ov_cache and retry.
$ErrorActionPreference = 'Stop'
$StateDir   = 'C:\Users\mrbla\agentic-setup\state'
$StoppedVms = Join-Path $StateDir 'stopped-vms.txt'

# Honor the legacy %TEMP% flag once (older script versions wrote it there)
$LegacyFlag = Join-Path $env:TEMP 'agentic-blarai-vm-stopped.flag'
if (Test-Path $LegacyFlag) {
    New-Item -ItemType Directory -Force $StateDir | Out-Null
    if (-not (Test-Path $StoppedVms) -or -not (Select-String -Path $StoppedVms -Pattern 'BlarAI-Orchestrator' -Quiet)) {
        Add-Content $StoppedVms 'BlarAI-Orchestrator'
    }
    Remove-Item $LegacyFlag -ErrorAction SilentlyContinue
}

function Ask([string]$Prompt) {
    try { return (Read-Host $Prompt) } catch { return $null }
}

Remove-Item "$StateDir\server-should-run.txt" -ErrorAction SilentlyContinue   # stand the watchdog down: this stop is intentional
Remove-Item "$StateDir\watchdog-gave-up.flag" -ErrorAction SilentlyContinue
$p = Get-Process ovms -ErrorAction SilentlyContinue
if ($p) { $p | Stop-Process -Force; Write-Host "Model server stopped - its memory is free again. (Watchdog stood down.)" -ForegroundColor Green }
else    { Write-Host "The model server was not running." }

# Offer VM restarts; a name leaves the list ONLY when its VM is actually started
if (Test-Path $StoppedVms) {
    $names = @(Get-Content $StoppedVms | Where-Object { $_ })
    $remaining = @()
    foreach ($vmName in $names) {
        $vm = Get-VM -Name $vmName -ErrorAction SilentlyContinue
        if (-not $vm) { continue }
        if ($vm.State -eq 'Running') { continue }
        $back = Ask "Earlier a model launcher stopped the '$vmName' VM to free memory. Start it again now? (y/N)"
        if ($back -eq 'y') { Start-VM -Name $vmName; Write-Host "$vmName starting." -ForegroundColor Green }
        else {
            $remaining += $vmName
            if ($null -eq $back) { Write-Host "(No console input - keeping the restart offer for next time.)" }
        }
    }
    if ($remaining.Count -gt 0) { Set-Content $StoppedVms $remaining } else { Remove-Item $StoppedVms -ErrorAction SilentlyContinue }
}
