# AI Control Panel - the single entry point. Shows status, dispatches to the
# same scripts the individual launchers use (one source of truth).
$ErrorActionPreference = 'Continue'
$S = 'C:\Users\mrbla\agentic-setup\scripts'
& "$S\sync-harness.ps1"   # record any live-harness drift in git history

function Get-LoadedModel {
    try {
        $r = Invoke-WebRequest 'http://127.0.0.1:8000/v3/models' -TimeoutSec 2 -UseBasicParsing
        return ((($r.Content | ConvertFrom-Json).data) | Select-Object -First 1).id
    } catch { return $null }
}

function Get-BlarAIVMState {
    try { return (Get-VM 'BlarAI-Orchestrator' -ErrorAction Stop).State }
    catch { return 'Unknown' }
}

function Get-BackupStatus {
    # Reads the stamp the full-system backup writes; returns text + a color by age.
    $stamp = 'C:\Users\mrbla\OneDrive\BlarAI-Reformat-Backup-2026-07-01\LAST_BACKUP.txt'
    if (-not (Test-Path $stamp)) { return @{ Text = 'never run'; Color = 'Red' } }
    $line = Get-Content $stamp -TotalCount 1
    $when = if ($line -match '(\d{4}-\d{2}-\d{2} \d{2}:\d{2})') { [datetime]$Matches[1] } else { $null }
    $ok   = $line -match 'status: OK'
    $age  = if ($when) { (Get-Date) - $when } else { $null }
    $text = if ($when) { '{0:yyyy-MM-dd HH:mm}{1}' -f $when, $(if ($ok) { '' } else { ' (had failures)' }) } else { $line }
    $color = if (-not $ok) { 'Red' } elseif ($age -and $age.TotalDays -gt 3) { 'Yellow' } else { 'Green' }
    return @{ Text = $text; Color = $color }
}

while ($true) {
    try { Clear-Host } catch {}
    $loaded = Get-LoadedModel
    try { $avail = [math]::Round((Get-Counter '\Memory\Available MBytes').CounterSamples[0].CookedValue/1024,1) } catch { $avail = '?' }
    $vmState = Get-BlarAIVMState
    Write-Host "=============== AI CONTROL PANEL ===============" -ForegroundColor Cyan
    if ($loaded) { Write-Host (" Model loaded: {0}    RAM free: {1} GB" -f $loaded, $avail) -ForegroundColor Green }
    else         { Write-Host (" No model loaded.     RAM free: {0} GB" -f $avail) -ForegroundColor Yellow }
    $vmColor = switch ($vmState) { 'Running' { 'Green' } 'Off' { 'Red' } default { 'Yellow' } }
    Write-Host (" BlarAI VM:    {0}" -f $vmState) -ForegroundColor $vmColor
    $bk = Get-BackupStatus
    Write-Host (" Last backup:  {0}" -f $bk.Text) -ForegroundColor $bk.Color
    Write-Host ""
    Write-Host "  [1] Open Coding Chat        (auto-picks the loaded model)"
    Write-Host "  [2] Load Deep Coding (30B)  (big jobs - wants a lean machine)"
    Write-Host "  [3] Load Everyday (14B)"
    Write-Host "  [4] Load Vision (8B)        (screenshot analysis)"
    Write-Host "  [5] Stop the model server   (OVMS - the coder/vision/everyday swap models)"
    Write-Host "  [S] Stop the assistant      (BlarAI's resident 14B on :5001 - frees ~12.6 GB)"
    Write-Host "  [6] Full status report"
    Write-Host "  [7] Live GPU monitor        (opens its own window)"
    Write-Host "  [8] Undo AI changes in a project"
    Write-Host "  [9] Backup configs          (quick - AI configs only)"
    Write-Host "  [B] Backup EVERYTHING now   (repos to GitHub + OneDrive + secrets staging)"
    Write-Host "  [U] Check for updates       (report only, installs nothing)"
    Write-Host "  [V] Refresh status          (re-check VM + model + RAM)"
    Write-Host "  --- maturity tools ---" -ForegroundColor DarkGray
    Write-Host "  [F] Fleet activity report   (how recent agent tasks went)"
    Write-Host "  [E] Run quality check       (evals - needs a model loaded)"
    Write-Host "  [G] Install secret scanner  (one-time setup)"
    Write-Host "  [A] Add a coding task       (queue a job for the agent)"
    Write-Host "  [T] Run overnight queue now (processes queued fleet tasks)"
    Write-Host "  [H] Quality & Grading Health   (regenerate + open the #840 dashboard)"
    Write-Host "  [Q] Quit"
    try { $c = Read-Host "Pick" } catch { break }   # no console input -> exit instead of looping
    if ($null -eq $c) { break }

    if     ($c -eq '1') { & "$S\open-coding.ps1" }
    elseif ($c -eq '2') { & "$S\start-llm.ps1" -Model coder-30b }
    elseif ($c -eq '3') { & "$S\start-llm.ps1" -Model qwen3-14b }
    elseif ($c -eq '4') { & "$S\start-llm.ps1" -Model vision }
    elseif ($c -eq '5') { & "$S\stop-llm.ps1" }
    elseif ($c -match '^[Ss]$') { & "$S\stop-assistant.ps1" }
    elseif ($c -eq '6') { & "$S\ai-status.ps1" }
    elseif ($c -eq '7') {
        # own window so closing the monitor does not close the panel
        $exe = if (Get-Command pwsh -ErrorAction SilentlyContinue) { 'pwsh' } else { 'powershell' }
        Start-Process $exe -ArgumentList '-NoProfile','-ExecutionPolicy','Bypass','-File',"$S\monitor-gpu.ps1"
    }
    elseif ($c -eq '8') { & "$S\undo-ai-changes.ps1" }
    elseif ($c -eq '9') { & "$S\backup-config.ps1" }
    elseif ($c -match '^[Bb]$') { & "$S\backup-system.ps1" }
    elseif ($c -match '^[Uu]$') { & "$S\check-updates.ps1" }
    elseif ($c -match '^[Vv]$') { continue }   # skip pause; header redraws with fresh status
    elseif ($c -match '^[Ff]$') { & "$S\fleet-report.ps1" }
    elseif ($c -match '^[Ee]$') { & "$S\run-evals.ps1" }
    elseif ($c -match '^[Gg]$') { & "$S\install-gitleaks.ps1" }
    elseif ($c -match '^[Aa]$') {
        # Guided, novice-friendly: pick a project, name the task, describe it -> queue it.
        Write-Host ""
        Write-Host " Add a coding task to the overnight queue." -ForegroundColor Cyan
        $projRoot = 'C:\Users\mrbla\projects'
        $projects = @(Get-ChildItem -Path $projRoot -Directory -ErrorAction SilentlyContinue |
            Where-Object { Test-Path (Join-Path $_.FullName '.git') } | Select-Object -ExpandProperty Name)
        if ($projects.Count) { Write-Host ("  Your projects: " + ($projects -join ', ')) -ForegroundColor DarkGray }
        else { Write-Host "  (No projects yet - use [1] Open Coding Chat once to create one.)" -ForegroundColor DarkGray }
        $proj = (Read-Host "  Which project? (folder name under projects\)").Trim()
        if (-not $proj) {
            Write-Host "  Cancelled." -ForegroundColor Yellow
        } else {
            $repo = Join-Path $projRoot $proj
            if (-not (Test-Path (Join-Path $repo '.git'))) {
                Write-Host "  '$proj' is not a project folder yet. Use [1] Open Coding Chat once to create it (it sets up git safely), then add a task." -ForegroundColor Yellow
            } else {
                $taskName = (Read-Host "  Short task name (e.g. add-csv-export)").Trim()
                $taskPrompt = (Read-Host "  Describe what you want the agent to build or fix").Trim()
                if ($taskName -and $taskPrompt) {
                    & "$S\add-fleet-task.ps1" -Repo $repo -Task $taskName -Prompt $taskPrompt
                    Write-Host "  Added to the queue. Press [T] to run it now, or leave it for the overnight run." -ForegroundColor Green
                } else {
                    Write-Host "  Cancelled - a task needs both a name and a description." -ForegroundColor Yellow
                }
            }
        }
    }
    elseif ($c -match '^[Tt]$') { & "$S\run-fleet.ps1" }
    elseif ($c -match '^[Hh]$') {
        # Regenerate + open the #840 live-proof grading & integration health dashboard (blarai repo).
        $blarPy = 'C:\Users\mrbla\blarai\.venv\Scripts\python.exe'
        if (-not (Test-Path $blarPy)) { $blarPy = 'python' }
        $gen = 'C:\Users\mrbla\blarai\scripts\live_proof\generate_dashboard.py'
        Write-Host " Regenerating the grading & integration health dashboard..." -ForegroundColor Cyan
        & $blarPy $gen --open
    }
    elseif ($c -match '^[Qq]$') { break }
    else { continue }

    Write-Host ""
    Read-Host "Press Enter to return to the menu"
}
