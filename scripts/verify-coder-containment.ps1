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

  THE NARROWING CHECKS (#1678, checks 5-14; on by default, -SkipNarrowing turns them off): after the ACL stage
  (provision-coder-acls.ps1) the coder has READ on the projects folder and no write anywhere in it. The script
  makes a scratch repo under the projects folder AFTER provisioning (a create_project(seed_assets=True)
  analogue: assets/README.txt, one commit, a linked worktree under the worktree base) and asks the coder to:
  create a file in a sibling repo and in the new repo (DENIED), create .git/refs/heads/x and .git/objects/xx in
  the new repo (DENIED), write in its own worktree (WORKS), git commit there (FAILS), read assets/README.txt
  (WORKS). The operator side then checks no coder write ACE exists on the projects folder (depth 2), that the
  new repo carries the INHERITED read ACE, and that the operator funnel commits the coder's file and merges it
  to main. Every one is hard-required in both modes. The toggle test (the probe FAILS when the Modify grant
  is restored) is run on a temp tree by verify-coder-narrowing.ps1, never on the real folders.

  THE TOOL-CHAIN SETUP CHECKS (#775 plan step 4, checks 15-24; always on, hard-required in both modes, a probe
  result that lacks one fails it): 15 the coder reaches the model repair proxy on loopback (:8099, the address
  its opencode config names); 16 it cannot read the operator's opencode config, .ssh or runtime keystore; 17 git
  status runs in its worktree under the scoped safe.directory; 18 opencode, node, git, git-bash and python start
  for it; 19 its own opencode config parses (no MCP block, permission block kept); 20 it cannot write that
  config; 21 it writes its research usage log under its own profile; 22 (operator side) the installed config
  equals what the repo renders and carries no coder write entry; 23 it cannot write in the fleet root, the fleet
  scripts or the operator state folder; 24 every folder of its installed config (~/.config, opencode, plugin,
  tool, git) is still a real folder owned by Administrators. The coder owns its profile root, so it CAN rename
  ~/.config away (the parent's delete-child right) whatever the folder's own list says, once the install has
  finished and nothing holds the folders: 24 detects a replacement (a link, a missing folder, a folder it owns),
  it cannot prevent the rename. While the install RUNS it holds a verified chain of folder handles
  (coder-setup-lib.ps1, Add-CoderHeldDir), so a swap during the install is refused and creates nothing.

  THE BOOT-SURFACE CHECK (#1695, check 25; always on, hard-required in both modes, an absent result fails it):
  no Automatic/Delayed-start service running as LocalSystem/LocalService/NetworkService and no enabled task
  running as SYSTEM or an administrator has an executable, script, folder or ancestor folder the coder (or a
  group it belongs to, or Everyone/Authenticated Users/Users) can write. Operator side; see coder-boot-surface-lib.ps1.

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
    [switch]$SkipNarrowing,
    [string]$ProjectsDir = 'C:\Users\mrbla\projects',
    [string]$WorktreeBase = 'C:\blarai-fleet\worktrees',
    [string]$CoderUser = 'blarai-coder',
    [string]$LoopbackUrl = 'http://127.0.0.1:8000/v3/models',
    [string]$AgenticRoot = '',
    [string]$BlarRoot = 'C:\Users\mrbla\blarai',
    [string[]]$SecretPaths = @(),
    [string]$TaskPath = '\BlarAI\',
    [string]$TaskName = 'BlarAI-Coder-Leg',
    [int]$TimeoutSec = 180
)
$ErrorActionPreference = 'Stop'
. "$PSScriptRoot\coder-leg-queue.ps1"
. "$PSScriptRoot\coder-provisioning-lib.ps1"   # Get-ContainmentVerdict — the pure pass/fail/warn SSOT
. "$PSScriptRoot\coder-acl-lib.ps1"             # Get-NarrowingVerdict, the scratch repo and the operator funnel
. "$PSScriptRoot\coder-setup-lib.ps1"           # the tool-chain manifest, the coder-owned config, checks 15-24

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
    # A tiny background HttpListener on 127.0.0.1:<Port> that answers 200 to any GET — proves the coder's
    # loopback socket is ALLOWED (the firewall scoping), no OVMS/GPU. Returns the Job to stop later.
    param([int]$Port = 8000)
    Start-Job -ArgumentList $Port -ScriptBlock {
        param($Port)
        $l = [System.Net.HttpListener]::new()
        $l.Prefixes.Add("http://127.0.0.1:$Port/")
        try {
            $l.Start()
            $deadline = (Get-Date).AddSeconds(120)
            $ctxTask = $l.GetContextAsync()   # ONE pending accept, kept until it completes: abandoning it and asking again would leave an orphan that swallows the request
            while ((Get-Date) -lt $deadline -and $l.IsListening) {
                if (-not $ctxTask.AsyncWaitHandle.WaitOne(2000)) { continue }
                $ctx = $ctxTask.Result
                $ctxTask = $l.GetContextAsync()
                $bytes = [Text.Encoding]::UTF8.GetBytes('{"stub":true,"data":[{"id":"coder-30b"}]}')
                $ctx.Response.StatusCode = 200
                $ctx.Response.ContentType = 'application/json'
                $ctx.Response.OutputStream.Write($bytes, 0, $bytes.Length)
                $ctx.Response.OutputStream.Close()
            }
        } finally { try { $l.Stop() } catch {} }
    }
}

# ---- the tool-chain setup inputs (checks 15-24); every one is derived from a committed source, none is guessed ----
if (-not $AgenticRoot) { $AgenticRoot = Split-Path $PSScriptRoot -Parent }
$toolchain = Read-CoderToolchainManifest -Path (Join-Path $AgenticRoot 'configs\coder-toolchain.json')
$cfgPlan = @(Get-CoderOpencodeConfigPlan -AgenticRoot $AgenticRoot -Manifest $toolchain -WorktreeBase $WorktreeBase)
$coderProfile = Get-CoderProfilePath -Sid $expectedSid
if (-not $coderProfile) { Write-Host "FAIL: the coder profile does not exist yet (the account has never logged on) - run provision-coder-setup.ps1 -Apply after the first logon, then re-run." -ForegroundColor Red; exit 2 }
$coderCfgDir = Get-CoderOpencodeConfigDir -ProfilePath $coderProfile
# the model address the coder's opencode config names (provider 'local'), probed at its /models path: no fallback
$ocJson = ConvertFrom-JsonCompat -Text ([IO.File]::ReadAllText((Join-Path $AgenticRoot 'configs\opencode.json'), [Text.UTF8Encoding]::new($false)))
$proxyBase = [string](Get-JsonMember (Get-JsonMember (Get-JsonMember (Get-JsonMember $ocJson 'provider') 'local') 'options') 'baseURL')
if ($proxyBase -notmatch '^http://127\.0\.0\.1(:\d{1,5})?/[A-Za-z0-9/_.-]*$') { Write-Host "FAIL: configs/opencode.json provider 'local' has no loopback baseURL ('$proxyBase') - the proxy probe has nothing to aim at." -ForegroundColor Red; exit 2 }
$proxyUrl = $proxyBase.TrimEnd('/') + '/models'
$operatorDeny = @((Join-Path $env:USERPROFILE '.config\opencode'), (Join-Path $env:USERPROFILE '.ssh'), (Join-Path $env:LOCALAPPDATA 'BlarAI')) | Where-Object { Test-Path -LiteralPath $_ }
$fleetRoot = Split-Path $WorktreeBase -Parent
$extraWriteDeny = @($fleetRoot, (Join-Path $AgenticRoot 'scripts'), (Join-Path $AgenticRoot 'state'), (Join-Path $BlarRoot 'shared')) | Where-Object { Test-Path -LiteralPath $_ -PathType Container }
$setupInput = @{
    proxy_url = $proxyUrl; operator_deny_paths = @($operatorDeny); toolchain_exes = @(Get-CoderToolchainProbeExes -Manifest $toolchain)
    config_dir = $coderCfgDir; extra_write_deny_dirs = @($extraWriteDeny); check_config = $true
}

# ---- run the probe as the coder ------------------------------------------
$paths = Get-CoderLegPaths
Initialize-CoderLegQueue
$probeOut = $null
$stubJob = $null; $stubJob2 = $null
$scratch = $null; $siblingDir = $null; $narrowInput = $null
if (-not $SkipNarrowing) {
    foreach ($need in @($ProjectsDir, $WorktreeBase)) { if (-not (Test-Path -LiteralPath $need)) { Write-Host "FAIL: '$need' does not exist - provision first (the narrowing checks need the projects folder and the worktree base)." -ForegroundColor Red; exit 2 } }
    # a repo created AFTER provisioning, as create_project(seed_assets=True) makes one (operator side)
    $scratch = New-VerifyScratchRepo -ProjectsDir $ProjectsDir -WorktreeBase $WorktreeBase
    # the sibling: an EXISTING repo under the projects folder (proves the old grant is gone from repos that were
    # there before); a second scratch repo when the folder holds none
    $existing = @(Get-ChildItem -LiteralPath $ProjectsDir -Directory -Force -ErrorAction SilentlyContinue | Where-Object { $_.Name -notlike '.blarai-verify-*' -and -not ($_.Attributes -band [IO.FileAttributes]::ReparsePoint) -and (Test-Path -LiteralPath (Join-Path $_.FullName '.git')) } | Select-Object -First 1)
    $scratch2 = $null
    if ($existing.Count -gt 0) { $siblingDir = $existing[0].FullName } else { $scratch2 = New-VerifyScratchRepo -ProjectsDir $ProjectsDir -WorktreeBase $WorktreeBase; $siblingDir = $scratch2.Repo }
    $narrowInput = @{
        write_deny_dirs = @($siblingDir, $scratch.Repo)
        source_git_repos = @($scratch.Repo)
        read_files = @($scratch.Readme)
        worktree_paths = @($scratch.Worktree)
    }
}
if ($LoopbackStub) {
    Write-Host "[verify] starting the loopback stub on 127.0.0.1:8000 (stub mode — proves rule scoping, not the model path)" -ForegroundColor Yellow
    $stubJob = Start-LoopbackStub -Port 8000
    # the repair proxy address (check 15) gets a stub too, unless something already answers there
    $proxyPort = ([uri]$proxyUrl).Port
    $busy = $false
    try { $tc = New-Object Net.Sockets.TcpClient; $iar = $tc.BeginConnect('127.0.0.1', $proxyPort, $null, $null); $busy = ($iar.AsyncWaitHandle.WaitOne(500) -and $tc.Connected); $tc.Close() } catch { }
    if (-not $busy -and $proxyPort -ne 8000) { $stubJob2 = Start-LoopbackStub -Port $proxyPort }
    Start-Sleep -Seconds 1   # let the listeners bind
}

try {
    $taskExists = [bool](Get-ScheduledTask -TaskPath $TaskPath -TaskName $TaskName -ErrorAction SilentlyContinue)
    $useTask = $ViaScheduledTask -or (-not $Credential -and $taskExists)

    if ($useTask) {
        if (-not $taskExists) { throw "the coder-leg task $TaskPath$TaskName is not registered — run provision (Stage 4) or pass -Credential" }
        Write-Host "[verify] spawning the probe via \BlarAI\$TaskName (the dispatch spawn path)" -ForegroundColor Cyan
        $probeSpec = @{ secret_paths = $SecretPaths; loopback_url = $LoopbackUrl; expected_sid = $expectedSid }
        if ($narrowInput) { foreach ($k in $narrowInput.Keys) { $probeSpec[$k] = $narrowInput[$k] } }
        foreach ($k in $setupInput.Keys) { $probeSpec[$k] = $setupInput[$k] }
        $jobId = Add-CoderLegJob -Job @{ kind = 'probe'; probe = $probeSpec }
        # Trigger + PROVE the task actually STARTED (shared Start-CoderLegTask, coder-leg-queue.ps1: the same
        # proof the fused dispatch leg uses). A password-principal task whose account lacks 'Log on as a batch
        # job' is left Ready and NEVER runs (0x41303 SCHED_S_TASK_HAS_NOT_RUN) -- which used to be a blind
        # ${TimeoutSec}s result-timeout (the 2026-07-10 live proof). It throws with the diagnosis within ~20s.
        try {
            $null = Start-CoderLegTask -TaskPath $TaskPath -TaskName $TaskName
        } catch {
            Write-Host "  [FAIL] check0-task-started - $($_.Exception.Message)" -ForegroundColor Red
            throw "coder-leg task never started - a diagnosable non-start, NOT a blind ${TimeoutSec}s timeout. $($_.Exception.Message)"
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
        # the lists travel as ONE JSON file (-File would deliver `-SecretPaths 'a','b'` as a single literal string)
        $probeParams = @{ SecretPaths = @($SecretPaths); LoopbackUrl = $LoopbackUrl }
        foreach ($pair in @(@('operator_deny_paths', 'OperatorDenyPaths'), @('toolchain_exes', 'ToolchainExes'), @('extra_write_deny_dirs', 'ExtraWriteDenyDirs'))) { $probeParams[$pair[1]] = @($setupInput[$pair[0]]) }
        $probeParams['ProxyUrl'] = $setupInput.proxy_url; $probeParams['ConfigDir'] = $setupInput.config_dir; $probeParams['CheckConfig'] = $true
        if ($narrowInput) {
            foreach ($pair in @(@('write_deny_dirs', 'WriteDenyDirs'), @('source_git_repos', 'SourceGitRepos'), @('read_files', 'ReadFiles'), @('worktree_paths', 'WorktreePaths'))) { $probeParams[$pair[1]] = @($narrowInput[$pair[0]]) }
        }
        # the params file lives in the FLEET ROOT (the coder has read there, never write; the results folder is coder-writable)
        # with one explicit read entry for the coder, and is deleted whatever happens
        $opSid = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
        Invoke-WithProbeParamsFile -Dir (Split-Path $paths.Root -Parent) -Params $probeParams -CoderSid $expectedSid -OperatorSid $opSid -Body {
            param($paramsFile)
            $argLine = "-NoProfile -NonInteractive -ExecutionPolicy Bypass -File `"$PSScriptRoot\coder-containment-probe.ps1`" -ParamsFile `"$paramsFile`" -OutJson `"$outFile`""
            Start-Process -FilePath $pwsh -ArgumentList $argLine -Credential $Credential -WorkingDirectory $PSScriptRoot -WindowStyle Hidden -Wait
        }
        if (-not (Test-Path $outFile)) { throw "the probe wrote no output at $outFile" }
        $probeOut = Get-Content $outFile -Raw | ConvertFrom-Json
        Remove-Item $outFile -ErrorAction SilentlyContinue
        $ranSid = $probeOut.ran_as_sid
    }
    # ---- the operator-side half of the narrowing checks, while the scratch repo still exists ----
    if ($scratch) {
        $narrowOp = @{ AclNoCoderWrite = $false; NewRepoInheritsRead = $false; FunnelCommitOk = $false; FunnelMergeOk = $false; Notes = @() }
        # what the coder can really write: its own entries, the groups it belongs to (Users, Authenticated Users, ...), ownership
        $groupSids = @(Get-CoderGroupSids -CoderUser $CoderUser -CoderSid $expectedSid)
        $eff = Find-SidWriteAcesTree -Root $ProjectsDir -Sid $expectedSid -GroupSids $groupSids -CheckOwner
        $narrowOp.AclNoCoderWrite = (@($eff.Hits).Count -eq 0 -and @($eff.Errors).Count -eq 0)
        foreach ($h in $eff.Hits) { $narrowOp.Notes += "coder can write ($($h.Kind)): $($h.Path) ($($h.Why))" }
        foreach ($e in $eff.Errors) { $narrowOp.Notes += "could not read: $e" }
        $st = Read-AclState -Path $scratch.Repo
        $narrowOp.NewRepoInheritsRead = (@($st.Aces | Where-Object { $_.Type -eq 'Allow' -and $_.Inherited -and $_.Sid -eq $expectedSid -and $_.Rights -eq 'RX' -and -not (Test-AceWriteCapable $_) }).Count -gt 0)
        if (-not $narrowOp.NewRepoInheritsRead) { $narrowOp.Notes += "the new repo $($scratch.Repo) does not carry an inherited read-and-run ACE for the coder" }
        $fr = Invoke-VerifyFunnel -Scratch $scratch
        $narrowOp.FunnelCommitOk = [bool]$fr.CommitOk; $narrowOp.FunnelMergeOk = [bool]$fr.MergeOk
        if ($fr.Detail) { $narrowOp.Notes += "funnel: $($fr.Detail)" }
    }
} finally {
    foreach ($sj in @($stubJob, $stubJob2)) { if ($sj) { Stop-Job $sj -ErrorAction SilentlyContinue; Remove-Job $sj -Force -ErrorAction SilentlyContinue } }
    if ($scratch)  { try { Remove-VerifyScratch -Scratch $scratch -ProjectsDir $ProjectsDir -WorktreeBase $WorktreeBase } catch { Write-Host "  [warn] scratch cleanup: $($_.Exception.Message)" -ForegroundColor Yellow } }
    if ($scratch2) { try { Remove-VerifyScratch -Scratch $scratch2 -ProjectsDir $ProjectsDir -WorktreeBase $WorktreeBase } catch { Write-Host "  [warn] scratch cleanup: $($_.Exception.Message)" -ForegroundColor Yellow } }
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

# ---- the narrowing checks 5-14 (hard-required in both modes; absent probe output = FAIL, never a skip) ----
$narrowVerdict = $null
if (-not $SkipNarrowing) {
    $nv = Get-NarrowingFromProbe -Checks $checks -SiblingDir $siblingDir -NewRepoDir $scratch.Repo -AclNoCoderWrite $narrowOp.AclNoCoderWrite `
        -NewRepoInheritsRead $narrowOp.NewRepoInheritsRead -FunnelCommitOk $narrowOp.FunnelCommitOk -FunnelMergeOk $narrowOp.FunnelMergeOk
    $narrowVerdict = $nv.Verdict
    Write-Host ''
    Write-Host '== narrowing checks (#1678): the coder reads the projects folder and writes nowhere in it ==' -ForegroundColor Cyan
    foreach ($row in $nv.Rows) { ShowHard $row.Name ([bool]$row.Pass) ([string]$row.Detail) }
    foreach ($n in $narrowOp.Notes) { Write-Host "         note: $n" -ForegroundColor DarkYellow }
}

# ---- the tool-chain setup checks 15-24 (hard-required in both modes; absent probe output = FAIL, never a skip) ----
$sv = Get-SetupChecksFromProbe -Checks $checks
$installed = Test-CoderOpencodeConfigInstalled -ConfigDir $coderCfgDir -Plan $cfgPlan -CoderSid $expectedSid
Write-Host ''
Write-Host '== tool-chain setup checks (#775 step 4): the coder can run its tool chain and nothing more ==' -ForegroundColor Cyan
foreach ($row in $sv.Rows) { ShowHard $row.Name ([bool]$row.Pass) ([string]$row.Detail) }
ShowHard 'check22-config-installed-intact' ([bool]$installed.Pass) $(if ($installed.Pass) { "the installed config in $coderCfgDir equals what the repo renders and the coder has no write entry on it" } else { "the installed config differs: $($installed.Failed -join ', ')" })
$setupFailed = @($sv.Verdict.Failed) + $(if (-not $installed.Pass) { @('check22-config-installed-intact') } else { @() })

# ---- check 25 (#1695): nothing that starts with the machine at high privilege is writable by the coder (operator side; hard-required in both modes; an absent result = FAIL) ----
. "$PSScriptRoot\coder-boot-surface-lib.ps1"   # loaded here only: the containment=off path never reaches this script
$boot = $null; $bootError = ''
try { $boot = Find-CoderWritableBootSurface -CoderSid $expectedSid -GroupSids @(Get-CoderGroupSids -CoderUser $CoderUser -CoderSid $expectedSid) } catch { $bootError = $_.Exception.Message }
$bootVerdict = Get-BootSurfaceVerdict -Result $boot -ErrorText $bootError
Write-Host ''
Write-Host '== boot surface (#1695): no coder-writable high-privilege auto-start service or task ==' -ForegroundColor Cyan
ShowHard 'check25-no-coder-writable-boot-surface' ([bool]$bootVerdict.Pass) ([string]$bootVerdict.Detail)
foreach ($o in @($bootVerdict.Offenders | Select-Object -First 20)) { Write-Host "         offender: $($o.Kind) $($o.Name) [$($o.RunAs)] $($o.Path) - $($o.Why)" -ForegroundColor DarkYellow }
$setupFailed = @($setupFailed) + @($bootVerdict.Failed)

Write-Host ''
if ($verdict.Pass -and ($SkipNarrowing -or $narrowVerdict.Pass) -and $setupFailed.Count -eq 0) {
    $suffix = ''
    if ($verdict.EgressWarned) { $suffix += ' [egress WARN-accepted per LA 2026-07-10 #775 c.1653 — the (b) egress leg is documented-not-enforced under Bitdefender]' }
    if ($LoopbackStub)         { $suffix += ' (check 3 in stub mode — re-run without -LoopbackStub in the GPU window for the real model path)' }
    $nar = if ($SkipNarrowing) { ' (narrowing checks 5-14 SKIPPED by -SkipNarrowing)' } else { ' + the 10 narrowing checks' }
    $nar += ' + the tool-chain setup checks 15-24'
    $nar += ' + the boot-surface check 25'
    $head = if ($verdict.EgressWarned) { "RESULT: all HARD-REQUIRED containment checks PASSED$nar (egress consciously WARN-accepted)" } else { "RESULT: all 4 containment checks PASSED$nar" }
    Write-Host "$head$suffix" -ForegroundColor Green
    exit 0
} else {
    $allFailed = @($verdict.Failed) + $(if ($narrowVerdict) { @($narrowVerdict.Failed) } else { @() }) + @($setupFailed)
    Write-Host "RESULT: containment NOT proven — failed: $($allFailed -join ', ')" -ForegroundColor Red
    if (($verdict.Failed -contains 'check1-outbound-blocked') -and -not $AcceptedEgressGap) {
        Write-Host "  NOTE: if this is the KNOWN Bitdefender-owns-filtering gap the LA accepted (#775 c.1653), re-run with -AcceptedEgressGap to record it as a conscious WARN; checks 2-4 still stay hard-required." -ForegroundColor DarkYellow
    }
    Write-Host "  containment=restricted_account MUST NOT flip until checks 2-4 pass (and check 1 passes OR is consciously WARN-accepted)." -ForegroundColor Red
    exit 1
}
