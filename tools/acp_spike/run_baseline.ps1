# ACP spike (#759) BASELINE leg -- drive the SAME task through the PRODUCTION
# `opencode run` + transcript-regex path, to A/B against the ACP leg.
#
# This does NOT modify any production script. It DOT-SOURCES fleet-lib.ps1 and CALLS
# the real Invoke-AgentRun exactly as new-agent-task.ps1's [1/5] build step does:
#   Invoke-AgentRun -WorkDir $wt -Model $Model -Prompt $p -LogPath $log -JsonStepCap ...
# The transcript-regex progress loop is INSIDE Invoke-AgentRun (fleet-lib.ps1), so this
# reproduces the exact seam under measurement. After the run we re-derive the production
# progress signals from the transcript with the IDENTICAL regexes production uses
# ("type":"step_finish" and "tool":"(write|edit|patch|multiedit)") for the fidelity A/B.
param(
    [Parameter(Mandatory)][string]$WorkDir,
    [Parameter(Mandatory)][string]$PromptFile,
    [string]$Model = 'local/coder-30b',
    [int]$TimeoutSec = 1200,
    [int]$IdleTimeoutSec = 240,
    [Parameter(Mandatory)][string]$OutDir
)
$ErrorActionPreference = 'Stop'
. "$PSScriptRoot\..\..\scripts\fleet-lib.ps1"   # USE the real functions (no modification)

$stamp = Get-Date -Format 'yyyyMMddTHHmmssZ'
$transcript = Join-Path $OutDir "baseline-$stamp.transcript.json"
$reportPath = Join-Path $OutDir "baseline-$stamp.json"
$prompt = Get-Content $PromptFile -Raw

$sw = [System.Diagnostics.Stopwatch]::StartNew()
$run = Invoke-AgentRun -WorkDir $WorkDir -Model $Model -Prompt $prompt -LogPath $transcript `
        -TimeoutSec $TimeoutSec -IdleTimeoutSec $IdleTimeoutSec -JsonStepCap
$sw.Stop()

$raw = if (Test-Path $transcript) { [string](Get-Content $transcript -Raw) } else { '' }
# The EXACT production progress regexes (fleet-lib.ps1 Invoke-AgentRun :437-438).
$stepFinish = ([regex]::Matches($raw, '"type":"step_finish"')).Count
$toolWrites = ([regex]::Matches($raw, '"tool":"(?:write|edit|patch|multiedit)"')).Count
# Any tool markers at all (broader, for context).
$anyToolMarks = ([regex]::Matches($raw, '"tool":"')).Count

# Produced diff (name-status + short stat) so we can compare artifacts to the ACP leg.
$diffStat = (git -C $WorkDir --no-pager diff --stat 2>$null) -join "`n"
$diffNames = (git -C $WorkDir --no-pager status --porcelain 2>$null) -join "`n"

$report = [ordered]@{
    phase              = 'baseline'
    t_iso              = (Get-Date).ToUniversalTime().ToString('o')
    cwd                = $WorkDir
    model              = $Model
    prompt_chars       = $prompt.Length
    wall_clock_s       = [math]::Round($sw.Elapsed.TotalSeconds, 3)
    timed_out          = [bool]$run.TimedOut
    timeout_reason     = $run.TimeoutReason
    capped             = [bool]$run.Capped
    capped_reason      = $run.CappedReason
    exit_code          = $run.ExitCode
    pin_refused        = [bool]$run.PinRefused
    transcript         = $transcript
    transcript_bytes   = $raw.Length
    step_finish_count  = $stepFinish
    tool_write_count   = $toolWrites
    any_tool_marks     = $anyToolMarks
    git_status_porcelain = $diffNames
    git_diff_stat      = $diffStat
}
$report | ConvertTo-Json -Depth 6 | Set-Content -Path $reportPath -Encoding UTF8
Write-Host "`n=== BASELINE DONE: wall=$($report.wall_clock_s)s step_finish=$stepFinish tool_writes=$toolWrites timedOut=$($run.TimedOut) capped=$($run.Capped) exit=$($run.ExitCode) ===" -ForegroundColor Green
Write-Host "Baseline report: $reportPath"
Write-Host "Transcript: $transcript"
