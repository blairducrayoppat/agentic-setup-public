# Live GPU / CPU / RAM monitor - one line every 2 seconds. Close the window to stop.
# WHAT IS NORMAL: during AI text generation the Neural engines pulse in a sawtooth
# (one burst per token); solid 100% stretches are the model reading a long prompt.
# CPU perf >100% = turbo (good). Sustained CPU perf well under 100% = thermal throttling.
$ErrorActionPreference = 'Continue'
Write-Host "Live monitor - close this window to stop." -ForegroundColor Cyan
Write-Host ("{0,-8} {1,7} {2,7} {3,7} {4,9} {5,9} {6,6}" -f 'time','GPU-3D','Neural','CPU%','CPUperf','RAM-free','model')
while ($true) {
    $g3 = 0; $gn = 0
    try {
        $cs = (Get-Counter '\GPU Engine(*)\Utilization Percentage').CounterSamples |
              Where-Object { $_.CookedValue -ge 0 -and $_.CookedValue -le 100 }   # filter corrupt readings
        $g3 = [math]::Min(100, [math]::Round((($cs | Where-Object InstanceName -like '*engtype_3D*'     | Measure-Object CookedValue -Sum).Sum), 0))
        $gn = [math]::Min(100, [math]::Round((($cs | Where-Object InstanceName -like '*engtype_Neural*' | Measure-Object CookedValue -Sum).Sum), 0))
    } catch {}
    $cpu = 0; $perf = 0; $avail = 0
    try { $cpu   = [math]::Round((Get-Counter '\Processor(_Total)\% Processor Time').CounterSamples[0].CookedValue, 0) } catch {}
    try { $perf  = [math]::Round((Get-Counter '\Processor Information(_Total)\% Processor Performance').CounterSamples[0].CookedValue, 0) } catch {}
    try { $avail = [math]::Round((Get-Counter '\Memory\Available MBytes').CounterSamples[0].CookedValue / 1024, 1) } catch {}
    $model = '-'
    try {
        $r = Invoke-WebRequest 'http://127.0.0.1:8000/v3/models' -TimeoutSec 2 -UseBasicParsing
        $model = ((($r.Content | ConvertFrom-Json).data) | Select-Object -First 1).id
    } catch { if (Get-Process ovms -ErrorAction SilentlyContinue) { $model = 'loading' } }
    $ramCol = if ($avail -lt 3) { 'Red' } elseif ($avail -lt 5) { 'Yellow' } else { 'Gray' }
    $perfCol = if ($perf -lt 90) { 'Yellow' } else { 'Gray' }
    $line = "{0,-8} {1,6}% {2,6}% {3,6}% {4,8}% {5,7}GB {6,8}" -f (Get-Date -Format 'HH:mm:ss'), $g3, $gn, $cpu, $perf, $avail, $model
    if ($ramCol -eq 'Red' -or $perfCol -eq 'Yellow') { Write-Host $line -ForegroundColor $(if ($ramCol -eq 'Red') {'Red'} else {'Yellow'}) }
    else { Write-Host $line }
    Start-Sleep -Seconds 2
}
