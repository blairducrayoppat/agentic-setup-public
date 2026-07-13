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
                 "expected_sid": "S-1-5-..." } }

  Result schema (JSON): { "id": "...", "kind": "...", "ok": <bool>, "ran_as_sid": "...",
                          "ran_as_user": "...", "result": <driver-envelope-or-probe-results>, "error": "" }

  DORMANT: nothing here runs on its own; the orchestrator only enqueues + triggers the coder-leg task
  when [fleet_dispatch].containment = restricted_account. With the default 'off' the queue is never
  written and the task is never started.
#>

# The dual-SID shared root (kept in ONE place; provision-coder-account.ps1 creates + grants it).
# Overridable via $env:BLARAI_CODER_LEG_ROOT for offline verify/smoke-tests ONLY — production leaves it
# unset, so the live path is the hardcoded shared tree both SIDs can Modify.
$script:CoderLegRoot    = if ($env:BLARAI_CODER_LEG_ROOT) { $env:BLARAI_CODER_LEG_ROOT } else { 'C:\blarai-fleet\coder-leg' }
$script:CoderLegQueue   = Join-Path $script:CoderLegRoot 'queue'
$script:CoderLegResults = Join-Path $script:CoderLegRoot 'results'

function Get-CoderLegPaths {
    [pscustomobject]@{ Root = $script:CoderLegRoot; Queue = $script:CoderLegQueue; Results = $script:CoderLegResults }
}

function Initialize-CoderLegQueue {
    New-Item -ItemType Directory -Force $script:CoderLegQueue   | Out-Null
    New-Item -ItemType Directory -Force $script:CoderLegResults | Out-Null
}

function New-CoderLegJobId {
    "job-$(Get-Date -Format 'yyyyMMdd-HHmmss')-$([guid]::NewGuid().ToString('N').Substring(0,8))"
}

function Add-CoderLegJob {
    # Orchestrator side: write a job to the queue. Returns the job id.
    param([Parameter(Mandatory)][hashtable]$Job)
    Initialize-CoderLegQueue
    if (-not $Job.id) { $Job.id = New-CoderLegJobId }
    if (-not $Job.created) { $Job.created = (Get-Date).ToString('o') }
    $path = Join-Path $script:CoderLegQueue "$($Job.id).json"
    # Write atomically (temp + move) so the coder side never claims a half-written job.
    $tmp = "$path.tmp"
    ($Job | ConvertTo-Json -Depth 8) | Set-Content -Path $tmp -Encoding UTF8
    Move-Item -Force $tmp $path
    return $Job.id
}

function Get-NextCoderLegJob {
    # Coder side: atomically CLAIM the oldest unclaimed job (rename to .claimed so a second worker
    # cannot grab it). Returns @{ Job=<obj>; ClaimPath=<path> } or $null when the queue is empty.
    Initialize-CoderLegQueue
    $candidates = Get-ChildItem $script:CoderLegQueue -Filter 'job-*.json' -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -notlike '*.claimed' } | Sort-Object CreationTime
    foreach ($f in $candidates) {
        $claim = "$($f.FullName).claimed"
        try {
            Move-Item -LiteralPath $f.FullName -Destination $claim -ErrorAction Stop   # atomic claim
        } catch { continue }   # someone else won the race; try the next
        try {
            $job = Get-Content $claim -Raw | ConvertFrom-Json
            return @{ Job = $job; ClaimPath = $claim }
        } catch {
            # Unreadable job -> park it aside so it never blocks the queue.
            Move-Item -Force $claim "$claim.bad" -ErrorAction SilentlyContinue
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
    ($Result | ConvertTo-Json -Depth 12) | Set-Content -Path $tmp -Encoding UTF8
    Move-Item -Force $tmp $path
    if ($ClaimPath -and (Test-Path $ClaimPath)) { Remove-Item $ClaimPath -ErrorAction SilentlyContinue }
    return $path
}

function Wait-CoderLegResult {
    # Orchestrator/verify side: poll for a job's result, up to -TimeoutSec. Returns the parsed
    # result object, or $null on timeout. Deletes the result file on read (consume-once).
    param([Parameter(Mandatory)][string]$JobId, [int]$TimeoutSec = 300, [int]$PollSec = 2)
    $path = Join-Path $script:CoderLegResults "$JobId.result.json"
    $deadline = (Get-Date).AddSeconds($TimeoutSec)
    while ((Get-Date) -lt $deadline) {
        if (Test-Path $path) {
            try {
                $obj = Get-Content $path -Raw | ConvertFrom-Json
                Remove-Item $path -ErrorAction SilentlyContinue
                return $obj
            } catch { Start-Sleep -Seconds $PollSec; continue }
        }
        Start-Sleep -Seconds $PollSec
    }
    return $null
}
