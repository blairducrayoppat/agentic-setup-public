#requires -Version 5.1
<#
.SYNOPSIS
  The ACP-01 Decision-1(b) LIVE PROOF, as a standing check (#775 / PHASE1 §5.3, ACP-01 §4/§7.4). Runs the
  four containment probes AS the blarai-coder account on a REAL spawned child and asserts each — exit
  non-zero naming the failed check. This is the build-time gate on flipping
  [fleet_dispatch].containment = restricted_account; it re-runs as a pre-flight before each battery
  campaign (like the plugin canary). Windows per-SID isolation is VERIFY-NOT-ASSUME (the E8 incident — a
  wrongly-scoped rule once broke the operator's machine — is the precedent that makes this mandatory).

.DESCRIPTION
  The four checks (ACP-01 §7.4), each on a child spawned as blarai-coder (NEVER the launcher token — the
  whole point is to catch an impersonated/duplicated token that would dodge a SID-scoped rule):
    1. outbound external connect -> MUST FAIL (the per-SID block denies egress).
    2. read the operator's secret paths (~/.ssh, %LOCALAPPDATA%\BlarAI, ~/.aws, …) -> MUST be ACL-denied.
    3. GET the model's loopback URL (127.0.0.1:8000/v3/models) -> MUST SUCCEED (the positive control — a
       too-broad rule that kills loopback would silently no-op every dispatch).
    4. the spawned child's token SID -> MUST be the blarai-coder SID (proves the firewall keys on the
       token the coder actually runs under).

  MODES (how the probe is spawned as the coder):
    -ViaScheduledTask   (recommended; the strongest form of check 4) — enqueue a 'probe' job on the
                         coder-leg file-queue and Start-ScheduledTask \BlarAI\BlarAI-Coder-Leg, so the
                         probe runs through the EXACT path a dispatch uses. No password needed (the task
                         credential is OS-vaulted).
    -Credential <cred>  — spawn coder-containment-probe.ps1 directly as blarai-coder via Start-Process
                         -Credential (convenient right after provisioning, when the coordinator still
                         holds the account password in-session).
    (default: -ViaScheduledTask if the task is registered, else -Credential is required.)

  CHECK-3 MODES (OVMS is down and the GPU is reserved today):
    -LoopbackStub  — stand up a TEMPORARY operator-side listener on 127.0.0.1:8000 before the probe, so
                     check 3 proves the FIREWALL loopback scoping without OVMS/GPU (stub mode proves rule
                     scoping). Omit it for the real-OVMS re-run in the GPU window (real mode proves the
                     model path).

  Exit 0 iff all four checks pass — OR, under -AcceptedEgressGap, checks 2-4 pass and check 1 (outbound)
  is a conscious WARN (the LA-accepted Bitdefender-owns-filtering gap, #775 c.1653). Non-zero + the failed
  check name(s) on any other miss. This script does NOT provision — run provision-coder-account.ps1 first.
#>
[CmdletBinding()]
param(
    [pscredential]$Credential,
    [switch]$ViaScheduledTask,
    [switch]$LoopbackStub,
    # -AcceptedEgressGap (LA 2026-07-10, #775 c.1653): the LA chose to KEEP Bitdefender and ACCEPT the
    # coder-egress gap -- the per-SID Windows rule is INERT on this box (BD owns filtering; bisect-proven
    # that even a plain all-user outbound block does not enforce). With this switch, check 1 (outbound must
    # fail) becomes a WARN citing the decision instead of a FAIL. WITHOUT it, check 1 stays a hard FAIL --
    # so the gap must be CONSCIOUSLY invoked every run, never silently inherited. Checks 2-4 stay hard
    # either way. Re-visit triggers: BD posture change / the VM containment leg goes live / an egress incident.
    [switch]$AcceptedEgressGap,
    [string]$CoderUser = 'blarai-coder',
    [string]$LoopbackUrl = 'http://127.0.0.1:8000/v3/models',
    [string[]]$SecretPaths = @(),
    [string]$TaskPath = '\BlarAI\',
    [string]$TaskName = 'BlarAI-Coder-Leg',
    [int]$TimeoutSec = 180
)
$ErrorActionPreference = 'Stop'
. "$PSScriptRoot\coder-leg-queue.ps1"
. "$PSScriptRoot\coder-provisioning-lib.ps1"   # Get-ContainmentVerdict — the pure pass/fail/warn SSOT

# Default to the threat-model §3 operator secret list (resolved against the coordinator's OWN profile —
# these are the OPERATOR paths the coder must be denied).
if ($SecretPaths.Count -eq 0) {
    $SecretPaths = @(
        (Join-Path $env:USERPROFILE '.ssh'),
        (Join-Path $env:USERPROFILE '.git-credentials'),
        (Join-Path $env:LOCALAPPDATA 'BlarAI'),
        (Join-Path $env:USERPROFILE '.aws'),
        (Join-Path $env:USERPROFILE '.azure')
    ) | Where-Object { Test-Path $_ }
}

$expectedSid = $null
try { $expectedSid = (Get-LocalUser $CoderUser -ErrorAction Stop).SID.Value } catch {
    Write-Host "FAIL: coder account '$CoderUser' does not exist — run provision-coder-account.ps1 first." -ForegroundColor Red
    exit 2
}

function Start-LoopbackStub {
    # A tiny background HttpListener on 127.0.0.1:8000 that answers 200 to any GET — proves the coder's
    # loopback socket is ALLOWED (the firewall scoping), no OVMS/GPU. Returns the Job to stop later.
    Start-Job -ScriptBlock {
        $l = [System.Net.HttpListener]::new()
        $l.Prefixes.Add('http://127.0.0.1:8000/')
        try {
            $l.Start()
            $deadline = (Get-Date).AddSeconds(120)
            while ((Get-Date) -lt $deadline -and $l.IsListening) {
                $ctxTask = $l.GetContextAsync()
                if (-not $ctxTask.AsyncWaitHandle.WaitOne(2000)) { continue }
                $ctx = $ctxTask.GetResult()
                $bytes = [Text.Encoding]::UTF8.GetBytes('{"stub":true,"data":[{"id":"coder-30b"}]}')
                $ctx.Response.StatusCode = 200
                $ctx.Response.ContentType = 'application/json'
                $ctx.Response.OutputStream.Write($bytes, 0, $bytes.Length)
                $ctx.Response.OutputStream.Close()
            }
        } finally { try { $l.Stop() } catch {} }
    }
}

# ---- run the probe as the coder ------------------------------------------
$paths = Get-CoderLegPaths
Initialize-CoderLegQueue
$probeOut = $null
$stubJob = $null
if ($LoopbackStub) {
    Write-Host "[verify] starting the loopback stub on 127.0.0.1:8000 (stub mode — proves rule scoping, not the model path)" -ForegroundColor Yellow
    $stubJob = Start-LoopbackStub
    Start-Sleep -Seconds 1   # let the listener bind
}

try {
    $taskExists = [bool](Get-ScheduledTask -TaskPath $TaskPath -TaskName $TaskName -ErrorAction SilentlyContinue)
    $useTask = $ViaScheduledTask -or (-not $Credential -and $taskExists)

    if ($useTask) {
        if (-not $taskExists) { throw "the coder-leg task $TaskPath$TaskName is not registered — run provision (Stage 4) or pass -Credential" }
        Write-Host "[verify] spawning the probe via \BlarAI\$TaskName (the dispatch spawn path)" -ForegroundColor Cyan
        $jobId = Add-CoderLegJob -Job @{
            kind = 'probe'
            probe = @{ secret_paths = $SecretPaths; loopback_url = $LoopbackUrl; expected_sid = $expectedSid }
        }
        # Baseline the task's LastRunTime BEFORE triggering, so we can tell "it ran" from "it never ran".
        $preRun = [datetime]'1999-11-30'
        try { $pr = (Get-ScheduledTaskInfo -TaskPath $TaskPath -TaskName $TaskName -ErrorAction SilentlyContinue).LastRunTime; if ($pr) { $preRun = $pr } } catch {}
        Start-ScheduledTask -TaskPath $TaskPath -TaskName $TaskName
        # PROVE the task actually STARTED before blocking on its result. A password-principal task whose
        # account lacks 'Log on as a batch job' is left Ready and NEVER runs (0x41303 SCHED_S_TASK_HAS_NOT_RUN)
        # -- which the old code experienced as a blind ${TimeoutSec}s result-timeout (the 2026-07-10 live
        # proof). Poll ~20s for a start signal (LastRunTime advanced, or caught State=Running); fail LOUDLY
        # and diagnostically if it never starts, instead of waiting out the full window.
        $started = $false; $lastResult = $null; $state = ''
        foreach ($i in 1..27) {
            Start-Sleep -Milliseconds 750
            $info = Get-ScheduledTaskInfo -TaskPath $TaskPath -TaskName $TaskName -ErrorAction SilentlyContinue
            $state = [string](Get-ScheduledTask -TaskPath $TaskPath -TaskName $TaskName -ErrorAction SilentlyContinue).State
            if ($info) { $lastResult = $info.LastTaskResult }
            if (($info -and $info.LastRunTime -gt $preRun) -or $state -eq 'Running') { $started = $true; break }
        }
        if (-not $started) {
            $hex = if ($null -ne $lastResult) { ('0x{0:X}' -f ([uint32]$lastResult)) } else { 'unknown' }
            Write-Host "  [FAIL] check0-task-started — $TaskPath$TaskName did NOT start within 20s (State=$state, LastTaskResult=$hex)" -ForegroundColor Red
            if ($hex -eq '0x41303') {
                Write-Host "         0x41303 = SCHED_S_TASK_HAS_NOT_RUN: the coder account almost certainly lacks the 'Log on as a batch job' right (SeBatchLogonRight)." -ForegroundColor Red
                Write-Host "         Fix: re-run provision-coder-account.ps1 (it grants SeBatchLogonRight in step 1), then re-run this proof." -ForegroundColor Red
            }
            throw "coder-leg task never started (State=$state, LastTaskResult=$hex) — a diagnosable non-start, NOT a blind ${TimeoutSec}s timeout. Likely missing SeBatchLogonRight; re-run provisioning."
        }
        $res = Wait-CoderLegResult -JobId $jobId -TimeoutSec $TimeoutSec
        if ($null -eq $res) { throw "the coder-leg task STARTED but produced no result within ${TimeoutSec}s (probe wrote nothing) — inspect the task's last run + $($paths.Results)" }
        $probeOut = $res.result
        $ranSid = $res.ran_as_sid
    } else {
        if (-not $Credential) { throw "no coder-leg task registered and no -Credential given — cannot spawn the probe as the coder" }
        Write-Host "[verify] spawning the probe directly as $CoderUser via Start-Process -Credential" -ForegroundColor Cyan
        $outFile = Join-Path $paths.Results ("verify-" + [guid]::NewGuid().ToString('N') + '.json')
        $pwsh = (Get-Command pwsh -ErrorAction SilentlyContinue).Source; if (-not $pwsh) { $pwsh = 'powershell.exe' }
        $secretArg = ($SecretPaths | ForEach-Object { "'$_'" }) -join ','
        $argLine = "-NoProfile -NonInteractive -ExecutionPolicy Bypass -File `"$PSScriptRoot\coder-containment-probe.ps1`" -SecretPaths $secretArg -LoopbackUrl '$LoopbackUrl' -OutJson `"$outFile`""
        Start-Process -FilePath $pwsh -ArgumentList $argLine -Credential $Credential -WorkingDirectory $PSScriptRoot -Wait
        if (-not (Test-Path $outFile)) { throw "the probe wrote no output at $outFile" }
        $probeOut = Get-Content $outFile -Raw | ConvertFrom-Json
        Remove-Item $outFile -ErrorAction SilentlyContinue
        $ranSid = $probeOut.ran_as_sid
    }
} finally {
    if ($stubJob) { Stop-Job $stubJob -ErrorAction SilentlyContinue; Remove-Job $stubJob -Force -ErrorAction SilentlyContinue }
}

# ---- assert the four checks (decision via the PURE Get-ContainmentVerdict — the SSOT both modes share) ----
$checks = $probeOut.checks
$obPass = [bool]$checks.outbound_blocked.pass
$srPass = [bool]$checks.secret_reads_denied.pass
$lbPass = [bool]$checks.loopback_ok.pass
$sidMatch = ($ranSid -eq $expectedSid)
$verdict = Get-ContainmentVerdict -OutboundBlocked $obPass -SecretReadsDenied $srPass `
    -LoopbackOk $lbPass -SidIsCoder $sidMatch -AcceptedEgressGap:$AcceptedEgressGap

Write-Host ''
Write-Host "== ACP-01 (b) containment live proof (ran as $($probeOut.ran_as_user)) ==" -ForegroundColor Cyan
# Check 1 — outbound. PASS if blocked; else a conscious WARN under -AcceptedEgressGap (the per-SID rule is
# inert here — Bitdefender owns filtering) or a hard FAIL without it (so the gap is never silently inherited).
if ($obPass) {
    Write-Host "  [PASS] check1-outbound-blocked — $([string]$checks.outbound_blocked.detail)" -ForegroundColor Green
} elseif ($verdict.EgressWarned) {
    Write-Host "  [WARN] check1-outbound-blocked — $([string]$checks.outbound_blocked.detail)" -ForegroundColor Yellow
    Write-Host "         ACCEPTED EGRESS GAP (LA 2026-07-10, #775 c.1653): the per-SID rule is INERT on this box — Bitdefender owns filtering (bisect-proven: even a plain all-user outbound block does not enforce). The (b) egress leg is DOCUMENTED, NOT ENFORCED." -ForegroundColor Yellow
    Write-Host "         Re-visit triggers: Bitdefender posture change / the VM containment leg goes live / any egress incident." -ForegroundColor Yellow
} else {
    Write-Host "  [FAIL] check1-outbound-blocked — $([string]$checks.outbound_blocked.detail)" -ForegroundColor Red
}
# Checks 2-4 are HARD-REQUIRED in both modes (the accepted gap is egress-only).
function ShowHard([string]$name, [bool]$pass, [string]$detail) {
    if ($pass) { Write-Host "  [PASS] $name — $detail" -ForegroundColor Green }
    else { Write-Host "  [FAIL] $name — $detail" -ForegroundColor Red }
}
ShowHard 'check2-secret-reads-denied' $srPass ([string]$checks.secret_reads_denied.detail)
ShowHard 'check3-loopback-ok'        $lbPass ([string]$checks.loopback_ok.detail)
ShowHard 'check4-sid-is-coder'       $sidMatch "ran_as_sid=$ranSid expected=$expectedSid"

Write-Host ''
if ($verdict.Pass) {
    $suffix = ''
    if ($verdict.EgressWarned) { $suffix += ' [egress WARN-accepted per LA 2026-07-10 #775 c.1653 — the (b) egress leg is documented-not-enforced under Bitdefender]' }
    if ($LoopbackStub)         { $suffix += ' (check 3 in stub mode — re-run without -LoopbackStub in the GPU window for the real model path)' }
    $head = if ($verdict.EgressWarned) { 'RESULT: all HARD-REQUIRED containment checks PASSED (egress consciously WARN-accepted)' } else { 'RESULT: all 4 containment checks PASSED' }
    Write-Host "$head$suffix" -ForegroundColor Green
    exit 0
} else {
    Write-Host "RESULT: containment NOT proven — failed: $($verdict.Failed -join ', ')" -ForegroundColor Red
    if (($verdict.Failed -contains 'check1-outbound-blocked') -and -not $AcceptedEgressGap) {
        Write-Host "  NOTE: if this is the KNOWN Bitdefender-owns-filtering gap the LA accepted (#775 c.1653), re-run with -AcceptedEgressGap to record it as a conscious WARN; checks 2-4 still stay hard-required." -ForegroundColor DarkYellow
    }
    Write-Host "  containment=restricted_account MUST NOT flip until checks 2-4 pass (and check 1 passes OR is consciously WARN-accepted)." -ForegroundColor Red
    exit 1
}
