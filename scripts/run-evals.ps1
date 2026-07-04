# run-evals.ps1 - tiny local regression eval suite. Runs a fixed set of verifiable
# coding tasks against the loaded model and reports a pass/fail score, so you can
# tell whether a change (guided-gen, sampling, a model swap, an OpenCode update)
# helped or silently regressed quality. Fully offline; serial (one model resident).
#
#   start-llm.ps1 -Model qwen3-14b      # load a model first
#   .\run-evals.ps1                     # run the suite against it
#   .\run-evals.ps1 -Mock               # SELF-TEST the harness with reference
#                                       # solutions (no model needed)
#
# Each eval lives in evals\tasks\<name>\ with:
#   task.json   { "prompt": "...", "timeoutMinutes": 15 }
#   seed\       (optional) starting files copied into the work dir
#   solution\   reference solution (used by -Mock to self-test the harness)
#   verify.ps1  -Path <workdir>  ->  exit 0 = pass, non-zero = fail (prints reason)
param(
    [string]$EvalsDir = (Join-Path (Split-Path $PSScriptRoot -Parent) 'evals\tasks'),
    [string]$Model = '',
    [switch]$Mock,
    [int]$TimeoutMinutes = 15,
    [string[]]$Only = @()   # optional: run only these task dirs by name (focused iteration)
)
$ErrorActionPreference = 'Stop'
. "$PSScriptRoot\fleet-lib.ps1"

if (-not (Test-Path $EvalsDir)) { throw "No evals found at $EvalsDir" }
$model = $Model
if (-not $Mock) {
    $loaded = Get-LoadedModelId
    if (-not $loaded) { throw "Model server not ready. Start a model first, or use -Mock to self-test the harness." }
    if (-not $model) { $model = "local/$loaded" }
}

$Setup   = 'C:\Users\mrbla\agentic-setup'
$RunsDir = Join-Path $Setup 'state\eval-runs'
$stamp   = Get-Date -Format 'yyyyMMdd-HHmmss'
$RunDir  = Join-Path $RunsDir $stamp
New-Item -ItemType Directory -Force $RunDir | Out-Null

$tasks = @(Get-ChildItem $EvalsDir -Directory | Sort-Object Name)
if ($Only.Count) {
    $tasks = @($tasks | Where-Object { $Only -contains $_.Name })
    if (-not $tasks.Count) { throw "No matching eval task(s) for: $($Only -join ', ')" }
}
Write-Host ("Running {0} eval task(s) {1}" -f $tasks.Count, $(if ($Mock) { '[MOCK - reference solutions]' } else { "against $model" })) -ForegroundColor Cyan

$results = New-Object System.Collections.ArrayList
foreach ($td in $tasks) {
    $name = $td.Name
    $cfgPath = Join-Path $td.FullName 'task.json'
    if (-not (Test-Path $cfgPath)) { Write-Host "  skip $name (no task.json)" -ForegroundColor Yellow; continue }
    try { $cfg = Get-Content $cfgPath -Raw -Encoding UTF8 | ConvertFrom-Json }
    catch {
        Write-Host "  [FAIL] $name (invalid task.json: $($_.Exception.Message))" -ForegroundColor Red
        [void]$results.Add([pscustomobject]@{ name = $name; pass = $false; seconds = 0; reason = "task.json parse error: $($_.Exception.Message)" })
        continue
    }
    if (-not $cfg.prompt) {
        Write-Host "  [FAIL] $name (task.json missing 'prompt')" -ForegroundColor Red
        [void]$results.Add([pscustomobject]@{ name = $name; pass = $false; seconds = 0; reason = "task.json missing 'prompt'" })
        continue
    }
    $timeout = if ($cfg.timeoutMinutes) { [int]$cfg.timeoutMinutes } else { $TimeoutMinutes }

    $work = Join-Path $RunDir $name
    New-Item -ItemType Directory -Force $work | Out-Null
    if (Test-Path (Join-Path $td.FullName 'seed')) { Copy-Item (Join-Path $td.FullName 'seed\*') $work -Recurse -Force -ErrorAction SilentlyContinue }
    git -C $work init -q 2>$null
    git -C $work -c user.email='eval@local' -c user.name='eval' add -A 2>$null
    git -C $work -c user.email='eval@local' -c user.name='eval' commit -q --allow-empty -m 'seed' 2>$null

    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $loopNote = ''
    if ($Mock) {
        if (Test-Path (Join-Path $td.FullName 'solution')) { Copy-Item (Join-Path $td.FullName 'solution\*') $work -Recurse -Force }
    } else {
        $log = Join-Path $RunDir "$name.agent.log"
        $run = Invoke-AgentRun -WorkDir $work -Model $model -Prompt $cfg.prompt -LogPath $log -TimeoutSec ($timeout * 60)
        $an = Get-RunAnomalies -LogPath $log -TimedOut $run.TimedOut -ExitCode $run.ExitCode
        if ($an.LoopSuspected) { $loopNote = ' (anomaly: ' + ($an.Anomalies -join '; ') + ')' }
    }
    $sw.Stop()

    try {
        $reason = (& (Join-Path $td.FullName 'verify.ps1') -Path $work 2>&1 | Out-String).Trim()
        $pass = ($LASTEXITCODE -eq 0)
    } catch {
        $reason = "verify.ps1 error: $($_.Exception.Message)"; $pass = $false
    }
    [void]$results.Add([pscustomobject]@{ name = $name; pass = $pass; seconds = [math]::Round($sw.Elapsed.TotalSeconds, 1); reason = ($reason + $loopNote) })
    $c = if ($pass) { 'Green' } else { 'Red' }
    Write-Host ("  [{0}] {1}  ({2}s)  {3}" -f $(if ($pass) { 'PASS' } else { 'FAIL' }), $name, [math]::Round($sw.Elapsed.TotalSeconds, 1), $reason) -ForegroundColor $c
}

$passCount = @($results | Where-Object { $_.pass }).Count
$total = $results.Count
$results | ConvertTo-Json -Depth 5 | Set-Content (Join-Path $RunDir 'results.json') -Encoding UTF8
Write-Host ''
$score = if ($total -gt 0) { "$passCount/$total" } else { '0/0' }
$col = if ($passCount -eq $total -and $total -gt 0) { 'Green' } elseif ($passCount -ge [math]::Ceiling($total / 2)) { 'Yellow' } else { 'Red' }
Write-Host ("EVAL SCORE: {0} {1}" -f $score, $(if ($Mock) { '(mock self-test)' } else { "on $model" })) -ForegroundColor $col
Write-Host ("Results: {0}" -f (Join-Path $RunDir 'results.json')) -ForegroundColor Cyan
