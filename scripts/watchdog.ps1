# Sentinel-gated model-server watchdog. Runs every 2 minutes from Task Scheduler.
# Rules: only acts when state\server-should-run.txt exists (written by start-llm
# on READY, removed by stop-llm) - so manual stops are never fought. Max 3
# restarts per hour, then it gives up loudly in the log.
$ErrorActionPreference = 'SilentlyContinue'
$Setup    = 'C:\Users\mrbla\agentic-setup'
$Sentinel = "$Setup\state\server-should-run.txt"
$WLog     = "$Setup\state\logs\watchdog.log"
if (-not (Test-Path $Sentinel)) { exit 0 }
$model = (Get-Content $Sentinel -TotalCount 1).Trim()
if (-not $model) { exit 0 }

# Healthy = the expected model id answers on the API
$idMap = @{ 'coder-30b' = 'coder-30b'; 'qwen3-14b' = 'qwen3-14b'; 'vision' = 'qwen3-vl-8b' }
$wantId = $idMap[$model]
try {
    $r = Invoke-WebRequest 'http://127.0.0.1:8000/v3/models' -TimeoutSec 8 -UseBasicParsing
    if ($r.Content -match [regex]::Escape($wantId)) { exit 0 }   # healthy
} catch {}

# Not healthy. Rate-limit: max 3 restarts in the last hour.
$now = Get-Date
$recent = 0
if (Test-Path $WLog) {
    foreach ($line in (Get-Content $WLog | Select-Object -Last 60)) {
        if ($line -match '^(\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}) \| RESTART') {
            try { if ([datetime]::ParseExact($Matches[1],'yyyy-MM-dd HH:mm:ss',$null) -gt $now.AddHours(-1)) { $recent++ } } catch {}
        }
    }
}
if ($recent -ge 3) {
    $gaveUp = Test-Path "$Setup\state\watchdog-gave-up.flag"
    if (-not $gaveUp) {
        Add-Content $WLog "$($now.ToString('yyyy-MM-dd HH:mm:ss')) | GAVE UP after 3 restarts in an hour - something is repeatedly killing the server. Check Bitdefender notifications and AI Status."
        New-Item -ItemType File -Force "$Setup\state\watchdog-gave-up.flag" | Out-Null
    }
    exit 0
}
Remove-Item "$Setup\state\watchdog-gave-up.flag" -ErrorAction SilentlyContinue

Add-Content $WLog "$($now.ToString('yyyy-MM-dd HH:mm:ss')) | RESTART $model (server not answering)"
& "$Setup\scripts\start-llm.ps1" -Model $model -Force *> "$Setup\state\logs\watchdog-last-start.log"
