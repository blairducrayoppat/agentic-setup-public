#requires -Version 5.1
<#
.SYNOPSIS
  Verify the #775 FUSED coder leg seam: with containment=restricted_account the coder step of a dispatch
  runs AS blarai-coder through the queue + scheduled task, and it fails CLOSED on every non-start --
  fully OFFLINE (no account, no task, no opencode, no model, no GPU, no egress).

.DESCRIPTION
  Drives the REAL Invoke-CoderDriver / Invoke-FusedCoderRun / Start-CoderLegTask / Stop-CoderLegTask /
  Add-CoderLegJob / Resolve-CoderFinalPath / Assert-CoderQueueAclTight against a TEMP queue root and TEMP
  worktree base (with a real junction), with test doubles standing in for everything that touches the
  machine (Get-LocalUser, Get-Acl, Get-ScheduledTask(Info), Start/Stop-ScheduledTask, Wait-CoderLegResult,
  Invoke-AcpCoderRun, Invoke-AgentRun). Proves:
    * containment off -> the existing path runs and NONE of the fused-leg functions are touched,
    * restricted_account -> a well-formed dispatch job is queued and the SAME result shape comes back,
    * every non-start THROWS and runs nothing as the operator: account/task missing, task never started,
      no result, a result not bound to the job / the coder SID / a boolean ok, a leg that refused, an
      unrecognised containment value, driver not acp, workdir outside the base or through a link, a shared
      tree writable by other accounts, serialize-wait expiry, a stale queue, cancellation,
    * after a failure the coder-leg task is stopped and the claimed job cleared; the mutex is released,
    * a manifest that cannot be read refuses the coder where containment is expected,
    * the egress hook runs first, and a refusing hook stops everything.

  -Mutations: re-runs THIS suite against mutated copies of the sources (each control disabled in turn). A
  mutant is KILLED only when the suite exits non-zero AND prints a [FAIL] line; exit 0 is SURVIVED; a
  non-zero exit with no [FAIL] line (crash, parse error) is ERROR. An unmutated control run must pass first.
  Exit non-zero if anything survived or errored. -ProveHarness shows the classification works on a known
  survivor, a known crasher and a known kill.

  Run it normally ( .\verify-coder-fused-seam.ps1 ). Exit 0 if everything passed, 1 otherwise.
#>
param([switch]$Mutations, [switch]$ProveHarness, [string[]]$Only = @())
$ErrorActionPreference = 'Stop'

if ($Mutations -or $ProveHarness) {
    try { (Get-Process -Id $PID).PriorityClass = 'BelowNormal' } catch { }
    $pw = (Get-Command pwsh -ErrorAction SilentlyContinue).Source; if (-not $pw) { $pw = 'powershell.exe' }
    function Invoke-MutationRun([object[]]$Muts) {
        # Returns @{ Control = <bool>; Results = @(@{N; Class; Why}) }; Class in KILLED | SURVIVED | ERROR
        $tmp = Join-Path ([IO.Path]::GetTempPath()) ("fused-mut-" + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Force (Join-Path $tmp 'configs') | Out-Null
        Copy-Item (Join-Path (Split-Path $PSScriptRoot -Parent) 'configs\fleet-driver.json') (Join-Path $tmp 'configs\fleet-driver.json')
        # every file the suite reads or dot-sources
        $files = 'fleet-lib.ps1', 'coder-leg-queue.ps1', 'verify-coder-fused-seam.ps1', 'verify-coder-containment.ps1'
        $run = {
            param($Dir, $Mut)
            New-Item -ItemType Directory -Force $Dir | Out-Null
            foreach ($f in $files) { Copy-Item (Join-Path $PSScriptRoot $f) (Join-Path $Dir $f) }
            if ($Mut) {
                $target = Join-Path $Dir $Mut.F
                $text = [IO.File]::ReadAllText($target)
                if (-not $text.Contains($Mut.O)) { return @{ Class = 'ERROR'; Why = "mutation target not found in $($Mut.F)" } }
                [IO.File]::WriteAllText($target, $text.Replace($Mut.O, $Mut.W), (New-Object Text.UTF8Encoding($true)))
            }
            $out = & $pw -NoProfile -File (Join-Path $Dir 'verify-coder-fused-seam.ps1') 2>&1 | Out-String
            $code = $LASTEXITCODE
            $fails = @($out -split "`n" | Where-Object { $_ -match '\[FAIL\]' })
            if ($code -eq 0) { return @{ Class = 'SURVIVED'; Why = 'the suite did not notice' } }
            if ($fails.Count -gt 0) { return @{ Class = 'KILLED'; Why = ("$($fails[0])").Trim() } }
            return @{ Class = 'ERROR'; Why = 'non-zero exit with no [FAIL] line (crash or parse error): ' + (($out -split "`n" | Select-Object -Last 3) -join ' | ') }
        }
        $ctl = & $run (Join-Path $tmp 's-control') $null
        $res = @()
        $controlOk = ($ctl.Class -eq 'SURVIVED')   # exit 0 on the unmutated copy = control passes
        if (-not $controlOk) { Write-Host "  [CONTROL FAILED] the unmutated copy does not pass: $($ctl.Why)" -ForegroundColor Red }
        else {
            Write-Host '  [control]  unmutated copy passes' -ForegroundColor Green
            foreach ($m in $Muts) {
                $r = & $run (Join-Path $tmp ('s-' + $m.N)) $m
                $res += @{ N = $m.N; Class = $r.Class; Why = $r.Why }
                $colour = if ($r.Class -eq 'KILLED') { 'Green' } else { 'Red' }
                Write-Host ("  [{0}] {1}  <- {2}" -f $r.Class.PadRight(8), $m.N, $r.Why) -ForegroundColor $colour
            }
        }
        Remove-Item $tmp -Recurse -Force -ErrorAction SilentlyContinue
        return @{ Control = $controlOk; Results = $res }
    }

    if ($ProveHarness) {
        $probe = @(
            @{ N = 'equivalent-comment-change'; F = 'fleet-lib.ps1'; O = '# 1. the egress seam, before anything else touches the coder'; W = '# 1. egress seam first' },
            @{ N = 'crashing-syntax-break';     F = 'fleet-lib.ps1'; O = 'function Resolve-AclSid {';                                          W = 'function Resolve-AclSid { }}}}' },
            @{ N = 'real-kill-stale-queue';     F = 'fleet-lib.ps1'; O = 'if ($stale.Count -gt 0) {';                                       W = 'if ($false) {' }
        )
        $r = Invoke-MutationRun $probe
        $want = @{ 'equivalent-comment-change' = 'SURVIVED'; 'crashing-syntax-break' = 'ERROR'; 'real-kill-stale-queue' = 'KILLED' }
        $bad = @($r.Results | Where-Object { $want[$_.N] -ne $_.Class })
        if ($r.Control -and $bad.Count -eq 0 -and $r.Results.Count -eq 3) { Write-Host 'HARNESS PROVEN: survivor reported SURVIVED, crasher reported ERROR, real kill reported KILLED' -ForegroundColor Green; exit 0 }
        Write-Host 'HARNESS NOT PROVEN' -ForegroundColor Red; exit 1
    }

    $muts = @(
        @{ N = 'unknown-containment-guard';   F = 'fleet-lib.ps1';       O = 'if ($cfg.containment_invalid) {';                    W = 'if ($false -and $cfg.containment_invalid) {' },
        @{ N = 'invalid-flag-detection';      F = 'fleet-lib.ps1';       O = '$contInvalid = ($null -ne $raw.containment) -and';   W = '$contInvalid = $false -and ($null -ne $raw.containment) -and' },
        @{ N = 'restricted-branch-removed';   F = 'fleet-lib.ps1';       O = "if (`$cfg.containment -eq 'restricted_account') {"; W = 'if ($false) {' },
        @{ N = 'off-routed-into-fused';       F = 'fleet-lib.ps1';       O = "if (`$cfg.containment -eq 'restricted_account') {"; W = 'if ($true) {' },
        @{ N = 'unresolved-gate-removed';     F = 'fleet-lib.ps1';       O = 'if ($cfg.containment_unresolved) {';                W = 'if ($false) {' },
        @{ N = 'unresolved-expected-check';   F = 'fleet-lib.ps1';       O = 'if (Test-CoderContainmentExpected @expectArgs) {';  W = 'if ($false) {' },
        @{ N = 'default-config-resolved';     F = 'fleet-lib.ps1';       O = 'containment_unresolved = $true; research_docs = $false'; W = 'containment_unresolved = $false; research_docs = $false' },
        @{ N = 'expected-by-task';            F = 'fleet-lib.ps1';       O = 'try { return [bool](Get-ScheduledTask -TaskPath $TaskPath -TaskName $TaskName -ErrorAction SilentlyContinue) } catch { return $true }'; W = 'return $false' },
        @{ N = 'expected-by-marker';          F = 'fleet-lib.ps1';       O = 'if (Test-Path -LiteralPath $MarkerPath) { return $true }'; W = '' },
        @{ N = 'egress-hook-not-called';      F = 'fleet-lib.ps1';       O = "`$null = Assert-CoderEgressContained -Context 'fused-dispatch'"; W = '' },
        @{ N = 'acl-check-removed';           F = 'fleet-lib.ps1';       O = 'Assert-CoderQueueAclTight -Path @($paths.Root, $paths.Queue, $paths.Prompts, $paths.Results, $paths.Logs, $wtBaseRaw) -CoderUser $o.CoderUser'; W = '' },
        @{ N = 'acl-write-mask';              F = 'fleet-lib.ps1';       O = 'if (([int]$rule.FileSystemRights -band $writeMask) -eq 0) { continue }'; W = 'continue' },
        @{ N = 'acl-sid-allowlist';           F = 'fleet-lib.ps1';       O = 'if (-not $sid -or $allowed -notcontains $sid) {';    W = 'if ($false) {' },
        @{ N = 'acl-missing-path-refused';    F = 'fleet-lib.ps1';       O = 'catch { throw "fused leg: cannot read the ACL of';   W = 'catch { return; throw "fused leg: cannot read the ACL of' },
        @{ N = 'driver-must-be-acp';          F = 'fleet-lib.ps1';       O = "if (`$Cfg.driver -ne 'acp') {";                      W = 'if ($false) {' },
        @{ N = 'workdir-under-shared-base';   F = 'fleet-lib.ps1';       O = "if (-not (`$wdFull + '\') .StartsWith(".Replace(') .', ').');  W = 'if ($false -and -not ($wdFull + ''\'').StartsWith(' },
        @{ N = 'reparse-point-refused';       F = 'fleet-lib.ps1';       O = 'if ($match[0].Attributes -band [IO.FileAttributes]::ReparsePoint) {'; W = 'if ($false) {' },
        @{ N = 'component-must-resolve';      F = 'fleet-lib.ps1';       O = 'if ($match.Count -ne 1) {';                          W = 'if ($false) {' },
        @{ N = 'workdir-resolved-into-job';   F = 'fleet-lib.ps1';       O = 'workdir = $wdFull;';                                 W = 'workdir = $WorkDir;' },
        @{ N = 'account-must-exist';          F = 'fleet-lib.ps1';       O = 'if (-not $coderSid) { throw';                        W = 'if ($false) { throw' },
        @{ N = 'task-must-be-registered';     F = 'fleet-lib.ps1';       O = 'if (-not (Get-ScheduledTask -TaskPath $o.TaskPath -TaskName $o.TaskName -ErrorAction SilentlyContinue)) {'; W = 'if ($false) {' },
        @{ N = 'serialize-wait-bounded';      F = 'fleet-lib.ps1';       O = 'if (-not $held) { throw';                            W = 'if ($false) { throw' },
        @{ N = 'abandoned-mutex-accepted';    F = 'fleet-lib.ps1';       O = 'catch [System.Threading.AbandonedMutexException] { $held = $true }'; W = 'catch [System.Threading.AbandonedMutexException] { $held = $false }' },
        @{ N = 'release-mutex-removed';       F = 'fleet-lib.ps1';       O = 'if ($held) { try { $mutex.ReleaseMutex() } catch {} }; $mutex.Dispose()'; W = '' },
        @{ N = 'wait-for-idle-task';          F = 'fleet-lib.ps1';       O = "while ([string](Get-ScheduledTask -TaskPath `$o.TaskPath -TaskName `$o.TaskName -ErrorAction SilentlyContinue).State -eq 'Running') {"; W = 'while ($false) {' },
        @{ N = 'stale-queue-refused';         F = 'fleet-lib.ps1';       O = 'if ($stale.Count -gt 0) {';                          W = 'if ($false) {' },
        @{ N = 'queue-contract-loaded-guard'; F = 'fleet-lib.ps1';       O = 'if (-not (Get-Command $need -ErrorAction SilentlyContinue)) { throw'; W = 'if ($false) { throw' },
        @{ N = 'task-start-proof';            F = 'coder-leg-queue.ps1'; O = 'if (-not $started) {';                               W = 'if ($false) {' },
        @{ N = 'result-wait-honoured';        F = 'fleet-lib.ps1';       O = '$resDeadline = (Get-Date).AddSeconds([int]$o.ResultWaitSec)'; W = '$resDeadline = (Get-Date).AddSeconds(0)' },
        @{ N = 'no-result-timeout';           F = 'fleet-lib.ps1';       O = 'if ($null -eq $res) { throw';                        W = 'if ($false) { throw' },
        @{ N = 'result-id-binding';           F = 'fleet-lib.ps1';       O = 'if ([string]$res.id -cne $jobId) {';                 W = 'if ($false) {' },
        @{ N = 'result-kind-binding';         F = 'fleet-lib.ps1';       O = "if ([string]`$res.kind -cne 'dispatch') {";          W = 'if ($false) {' },
        @{ N = 'ran-as-sid-check';            F = 'fleet-lib.ps1';       O = 'if ([string]$res.ran_as_sid -cne $coderSid) {';      W = 'if ($false) {' },
        @{ N = 'top-level-ok-boolean';        F = 'fleet-lib.ps1';       O = 'if (($res.ok -isnot [bool]) -or ($res.ok -ne $true)) {'; W = 'if ($false) {' },
        @{ N = 'inner-ok-boolean';            F = 'fleet-lib.ps1';       O = 'if (($leg.Ok -isnot [bool]) -or ($leg.Ok -ne $true)) {'; W = 'if ($false) {' },
        @{ N = 'unusable-result-refused';     F = 'fleet-lib.ps1';       O = 'if ($null -eq $leg -or $null -eq $leg.Result) {';    W = 'if ($false) {' },
        @{ N = 'owner-and-time-args';         F = 'fleet-lib.ps1';       O = '-ExpectedOwnerSid $coderSid -NotBefore $enqueuedAt'; W = '' },
        @{ N = 'wait-owner-check';            F = 'coder-leg-queue.ps1'; O = 'if ($owner -cne $ExpectedOwnerSid) { throw';         W = 'if ($false) { throw' },
        @{ N = 'wait-created-after-check';    F = 'coder-leg-queue.ps1'; O = '.CreationTimeUtc -lt $NotBefore.ToUniversalTime()) { throw'; W = '.CreationTimeUtc -lt [datetime]::MinValue) { throw' },
        @{ N = 'operator-fallback-on-refusal';F = 'fleet-lib.ps1';       O = 'throw "fused leg: the coder leg could not run the build ('; W = '$null = Invoke-AcpCoderRun -WorkDir $WorkDir -Model $mdl -Prompt $Prompt -LogPath $LogPath -Acp $acp; throw "fused leg: the coder leg could not run the build (' },
        @{ N = 'stop-task-on-failure';        F = 'fleet-lib.ps1';       O = '$stopped = Stop-CoderLegTask -TaskPath $o.TaskPath -TaskName $o.TaskName -WaitSec $o.StopWaitSec -PollMs $o.PollMs'; W = '$stopped = $true' },
        @{ N = 'stop-failure-reported';       F = 'fleet-lib.ps1';       O = 'if (-not $stopped) { throw "$($failure';             W = 'if ($false) { throw "$($failure' },
        @{ N = 'stop-waits-for-not-running';  F = 'coder-leg-queue.ps1'; O = "if (`$state -ne 'Running') { return `$true }";     W = 'return $true' },
        @{ N = 'claimed-job-cleared';         F = 'fleet-lib.ps1';       O = 'Remove-Item -LiteralPath (Join-Path $queueDir "$jobId.json.claimed") -ErrorAction SilentlyContinue'; W = '' },
        @{ N = 'cancel-polled-in-wait';       F = 'fleet-lib.ps1';       O = "if (& `$o.ShouldCancel) { throw 'fused leg: dispatch cancelled; stopping"; W = "if (`$false) { throw 'fused leg: dispatch cancelled; stopping" },
        @{ N = 'cancel-before-trigger';       F = 'fleet-lib.ps1';       O = "if (& `$o.ShouldCancel) { throw 'fused leg: dispatch cancelled before"; W = "if (`$false) { throw 'fused leg: dispatch cancelled before" },
        @{ N = 'job-removed-on-failure';      F = 'fleet-lib.ps1';       O = 'Remove-Item -LiteralPath (Join-Path $queueDir "$jobId.json") -ErrorAction SilentlyContinue'; W = '' },
        @{ N = 'prompt-removed';              F = 'fleet-lib.ps1';       O = 'if ($promptFile) { Remove-Item -LiteralPath $promptFile -ErrorAction SilentlyContinue }'; W = '' },
        @{ N = 'transcript-removed';          F = 'fleet-lib.ps1';       O = 'if ($sharedLog)  { Remove-Item -LiteralPath $sharedLog -ErrorAction SilentlyContinue }'; W = '' },
        @{ N = 'transcript-copied-back';      F = 'fleet-lib.ps1';       O = 'Copy-Item -LiteralPath $sharedLog -Destination $LogPath -Force -ErrorAction Stop'; W = 'Write-Verbose $sharedLog' },
        @{ N = 'default-result-wait';         F = 'fleet-lib.ps1';       O = '$result = $TimeoutSec + 300 + 60';                   W = '$result = 1' },
        @{ N = 'default-queue-wait';          F = 'fleet-lib.ps1';       O = 'QueueWaitSec = 2 * ($start + $result + $stop)';      W = 'QueueWaitSec = 1' },
        @{ N = 'default-start-wait';          F = 'fleet-lib.ps1';       O = '$start = 20; $stop = 30';                            W = '$start = 1; $stop = 30' },
        @{ N = 'budgets-used-by-run';         F = 'fleet-lib.ps1';       O = 'QueueWaitSec = $b.QueueWaitSec; ResultWaitSec = $b.ResultWaitSec'; W = 'QueueWaitSec = 1; ResultWaitSec = 1' },
        @{ N = 'sanitise-control-chars';      F = 'fleet-lib.ps1';       O = "'[\x00-\x1F\x7F-\x9F]'";                              W = "'[\x00-\x00]'" },
        @{ N = 'sanitise-length-cap';         F = 'fleet-lib.ps1';       O = 'if ($t.Length -gt $MaxLength) {';                    W = 'if ($false) {' }
    )
    if ($Only.Count -gt 0) {
        $want = @($Only | ForEach-Object { $_ -split ',' } | Where-Object { $_ })
        $muts = @($muts | Where-Object { $want -contains $_.N })
        if ($muts.Count -ne $want.Count) { Write-Host "MUTATIONS: -Only named a mutant that does not exist" -ForegroundColor Red; exit 1 }
    }
    $r = Invoke-MutationRun $muts
    Write-Host ''
    $bad = @($r.Results | Where-Object { $_.Class -ne 'KILLED' })
    if ($r.Control -and $bad.Count -eq 0 -and $muts.Count -gt 0) { Write-Host "MUTATIONS: $($muts.Count) of $($muts.Count) killed" -ForegroundColor Green; exit 0 }
    Write-Host "MUTATIONS: control_ok=$($r.Control); not killed: $(($bad | ForEach-Object { "$($_.N)=$($_.Class)" }) -join ', ')" -ForegroundColor Red
    exit 1
}

# ---- suite ----
$script:Pass = 0; $script:Fail = 0
$script:Failures = New-Object System.Collections.ArrayList
function _pass($m) { $script:Pass++; Write-Host "  [PASS] $m" -ForegroundColor Green }
function _fail($m) { $script:Fail++; [void]$script:Failures.Add($m); Write-Host "  [FAIL] $m" -ForegroundColor Red }
function Section($t) { Write-Host ''; Write-Host "== $t ==" -ForegroundColor Cyan }
function Assert-True($c, $m)  { if ($c) { _pass $m } else { _fail "$m (expected True)" } }
function Assert-False($c, $m) { if (-not $c) { _pass $m } else { _fail "$m (expected False)" } }
function Assert-Eq($e, $a, $m) { if ([string]$e -ceq [string]$a) { _pass $m } else { _fail "$m (expected '$e', got '$a')" } }

$tmpRoot = Join-Path ([IO.Path]::GetTempPath()) ("fused-seam-" + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Force $tmpRoot | Out-Null
$env:BLARAI_CODER_LEG_ROOT = $tmpRoot          # BEFORE the dot-source: the queue paths are read at load
. "$PSScriptRoot\fleet-lib.ps1"
if ((Get-CoderLegPaths).Root -ne $tmpRoot) { Write-Host 'ABORT: queue-root override did not take; refusing to touch the real path.' -ForegroundColor Red; exit 2 }

$CODER_SID = 'S-1-5-21-1111-2222-3333-1001'
$OPERATOR_SID = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
$mutexName = 'Global\BlarAI-Coder-Leg-Dispatch-test-' + [guid]::NewGuid().ToString('N')
$wtBase = Join-Path $tmpRoot 'worktrees'
$elsewhere = Join-Path $tmpRoot 'elsewhere'
$junction = Join-Path $wtBase 'jx'
$jbase = Join-Path $tmpRoot 'jbase'
foreach ($d in $wtBase, "$wtBase\proj-task", $elsewhere) { New-Item -ItemType Directory -Force $d | Out-Null }
New-Item -ItemType Junction -Path $junction -Target $elsewhere | Out-Null
New-Item -ItemType Junction -Path $jbase -Target $wtBase | Out-Null
$opts = @{ StartWaitSec = 1; PollMs = 20; QueueWaitSec = 2; ResultWaitSec = 3; StopWaitSec = 1; CancelSliceSec = 1; MutexName = $mutexName
           WorktreeBase = $wtBase; ShouldCancel = { $false }; MarkerPath = (Join-Path $tmpRoot 'no-such-marker') }

# ---- test doubles (defined AFTER the dot-source so they shadow the real ones / the cmdlets) ----
$script:Calls = New-Object System.Collections.ArrayList
$script:Knobs = $null
function Reset-Knobs {
    $script:Knobs = @{
        AccountMissing = $false; TaskMissing = $false; TaskStarts = $true; LastTaskResult = 0; TaskState = 'Ready'
        RunningAfterStart = $true; StopHangs = $false
        LastRun = [datetime]'2000-01-01'; EgressThrows = $false
        Leg = 'ok'; ReasonText = 'no ACP python interpreter provisioned'
        Acl = 'tight'      # tight | authusers | users | everyone-read | unknown | real
    }
}
Reset-Knobs
$script:LastJob = $null; $script:SeenPrompt = $null; $script:WaitArgs = $null
$realEgress = ${function:Assert-CoderEgressContained}
$realWait = ${function:Wait-CoderLegResult}
function Assert-CoderEgressContained { param([string]$Context = '') [void]$script:Calls.Add('egress'); if ($script:Knobs.EgressThrows) { throw 'egress filters absent' }; return [pscustomobject]@{ Enforced = $false; Status = 'test' } }
function Get-LocalUser { [CmdletBinding()] param($Name) [void]$script:Calls.Add('Get-LocalUser'); if ($script:Knobs.AccountMissing) { throw 'no such user' }; [pscustomobject]@{ SID = [pscustomobject]@{ Value = $CODER_SID } } }
function New-FakeRule([string]$Sid, [string]$Rights) { [pscustomobject]@{ IdentityReference = $Sid; FileSystemRights = [Security.AccessControl.FileSystemRights]$Rights; AccessControlType = 'Allow' } }
function Get-Acl {
    [CmdletBinding()] param([string]$LiteralPath, [string]$Path)
    if ($script:Knobs.Acl -eq 'real') { return (Microsoft.PowerShell.Security\Get-Acl -LiteralPath $LiteralPath) }
    [void]$script:Calls.Add('Get-Acl')
    $rules = @((New-FakeRule $OPERATOR_SID 'FullControl'), (New-FakeRule 'S-1-5-18' 'FullControl'), (New-FakeRule 'S-1-5-32-544' 'FullControl'))
    if (-not $script:Knobs.AccountMissing) { $rules += New-FakeRule $CODER_SID 'Modify' }
    switch ($script:Knobs.Acl) {
        'authusers'     { $rules += New-FakeRule 'S-1-5-11' 'Modify' }
        'users'         { $rules += New-FakeRule 'S-1-5-32-545' 'Write' }
        'everyone-read' { $rules += New-FakeRule 'S-1-1-0' 'ReadAndExecute' }
        'unknown'       { $rules += New-FakeRule 'S-1-5-21-5-5-5-1234' 'AppendData' }
    }
    return [pscustomobject]@{ Access = $rules }
}
function Get-ScheduledTask { [CmdletBinding()] param($TaskPath, $TaskName) [void]$script:Calls.Add('Get-ScheduledTask'); if ($script:Knobs.TaskMissing) { return $null }; [pscustomobject]@{ State = $script:Knobs.TaskState } }
function Get-ScheduledTaskInfo { [CmdletBinding()] param($TaskPath, $TaskName) [pscustomobject]@{ LastRunTime = $script:Knobs.LastRun; LastTaskResult = $script:Knobs.LastTaskResult } }
function Start-ScheduledTask { [CmdletBinding()] param($TaskPath, $TaskName) [void]$script:Calls.Add('Start-ScheduledTask'); if ($script:Knobs.TaskStarts) { $script:Knobs.LastRun = Get-Date; if ($script:Knobs.RunningAfterStart) { $script:Knobs.TaskState = 'Running' } } }
function Stop-ScheduledTask { [CmdletBinding()] param($TaskPath, $TaskName) [void]$script:Calls.Add('Stop-ScheduledTask'); if (-not $script:Knobs.StopHangs) { $script:Knobs.TaskState = 'Ready' } }
function Wait-CoderLegResult {
    [CmdletBinding()] param([string]$JobId, [int]$TimeoutSec = 300, [int]$PollSec = 2, [string]$ExpectedOwnerSid = '', [datetime]$NotBefore = [datetime]::MinValue)
    [void]$script:Calls.Add('Wait-CoderLegResult')
    $script:WaitArgs = @{ Owner = $ExpectedOwnerSid; NotBefore = $NotBefore; TimeoutSec = $TimeoutSec }
    $jf = Join-Path (Get-CoderLegPaths).Queue "$JobId.json"
    if (Test-Path $jf) {
        $script:LastJob = Get-Content $jf -Raw | ConvertFrom-Json
        $script:SeenPrompt = if (Test-Path $script:LastJob.prompt_file) { Get-Content $script:LastJob.prompt_file -Raw } else { $null }
        Move-Item $jf "$jf.claimed"   # the coder leg claims it
        Set-Content -Path $script:LastJob.log_path -Value 'transcript-from-the-coder-leg' -Encoding UTF8
    }
    if ($script:Knobs.Leg -eq 'null') { Start-Sleep -Milliseconds 100; return $null }
    $inner = @{ Ok = $true; Reason = 'acp phase=done'
                Result = @{ TimedOut = $false; TimeoutReason = ''; Capped = $false; CappedReason = ''; ExitCode = 0; LogPath = 'x'; Seconds = 12.5; Error = '' } }
    $res = @{ id = $JobId; kind = 'dispatch'; ok = $true; ran_as_sid = $CODER_SID; ran_as_user = 'DEV\blarai-coder'; result = $inner; error = '' }
    switch ($script:Knobs.Leg) {
        'wrongsid'      { $res.ran_as_sid = 'S-1-5-21-9-9-9-500' }
        'idmismatch'    { $res.id = 'job-20000101-000000-deadbeef' }
        'wrongkind'     { $res.kind = 'probe' }
        'toplevelfalse' { $res.ok = $false; $res.error = 'leg said no' }
        'okstring'      { $res.ok = 'true' }
        'innerokstring' { $inner.Ok = 'false' }
        'refused'       { $res.ok = $false; $inner.Ok = $false; $inner.Reason = $script:Knobs.ReasonText; $res.error = $script:Knobs.ReasonText }
        'refusedinner'  { $inner.Ok = $false; $inner.Reason = $script:Knobs.ReasonText }
        'nobody'        { $res.result = $null }
        'unusable'      { $res.result = @{ Ok = $true; Reason = 'x' } }
    }
    # the coder finished: it deletes its claim and the task is no longer running
    Remove-Item "$jf.claimed" -ErrorAction SilentlyContinue
    $script:Knobs.TaskState = 'Ready'
    return ($res | ConvertTo-Json -Depth 8 | ConvertFrom-Json)
}
function Invoke-AcpCoderRun { [CmdletBinding()] param($WorkDir, $Model, $Prompt, $LogPath, $Acp, $TimeoutSec, $IdleTimeoutSec, $MaxSteps, $SpinSteps)
    [void]$script:Calls.Add('Invoke-AcpCoderRun')
    return @{ Ok = $true; Reason = 'acp phase=done'; Result = @{ TimedOut = $false; TimeoutReason = ''; Capped = $false; CappedReason = ''; ExitCode = 0; LogPath = $LogPath; Seconds = 1.0; Error = '' } } }
function Invoke-AgentRun { [CmdletBinding()] param($WorkDir, $Model, $Prompt, $LogPath, $TimeoutSec, $IdleTimeoutSec, [switch]$JsonStepCap)
    [void]$script:Calls.Add('Invoke-AgentRun')
    return @{ TimedOut = $false; TimeoutReason = ''; Capped = $false; CappedReason = ''; ExitCode = 0; LogPath = $LogPath; Seconds = 1.0; Error = ''; IdleBoundSec = $IdleTimeoutSec; IdleSignal = 'no new step/edit' } }

# ---- helpers ----
$cfgPath = Join-Path $tmpRoot 'fleet-driver.json'
function Set-Config($Containment, [string]$Driver = 'acp') {
    $c = if ($null -eq $Containment) { '' } else { ", `"containment`": `"$Containment`"" }
    Set-Content -Path $cfgPath -Encoding UTF8 -Value "{ `"driver`": `"$Driver`"$c, `"acp`": { `"python`": `"`", `"idle_sec`": 600, `"max_steps`": 45, `"spin_steps`": 10 } }"
    $env:BLARAI_FLEET_DRIVER_CONFIG = $cfgPath
    [void](Get-FleetDriverConfig -ScriptRoot $PSScriptRoot -Fresh)
}
function Run-Driver([string]$Work = "$wtBase\proj-task", [hashtable]$Options = $opts) {
    $script:Calls.Clear(); $script:LastJob = $null; $script:SeenPrompt = $null; $script:WaitArgs = $null
    $log = Join-Path $tmpRoot 'run.log'; Remove-Item $log -ErrorAction SilentlyContinue
    $out = @{ Result = $null; Error = $null; Log = $log; Seconds = 0 }
    $t0 = Get-Date
    try { $out.Result = Invoke-CoderDriver -WorkDir $Work -Model 'coder-30b' -Prompt 'implement rpn.py <now> & done' -LogPath $log -TimeoutSec 100 -IdleTimeoutSec 240 -ScriptRoot $PSScriptRoot -FusedOptions $Options }
    catch { $out.Error = $_.Exception.Message }
    $out.Seconds = ((Get-Date) - $t0).TotalSeconds
    return $out
}
function Called([string]$n) { return ($script:Calls -contains $n) }
function Queue-Files { return @(Get-ChildItem (Get-CoderLegPaths).Queue -Filter 'job-*' -ErrorAction SilentlyContinue) }
function Staged-Files { return @(Get-ChildItem (Get-CoderLegPaths).Prompts, (Get-CoderLegPaths).Logs -File -ErrorAction SilentlyContinue) }
function Test-MutexFree([string]$Name) {
    # Probe from ANOTHER thread: a .NET Mutex is re-entrant for the thread that owns it, so a same-thread
    # check can never see a leaked hold.
    $ps = [powershell]::Create()
    [void]$ps.AddScript({ param($n) $m = New-Object System.Threading.Mutex($false, $n); $ok = $m.WaitOne(300); if ($ok) { $m.ReleaseMutex() }; $m.Dispose(); $ok }).AddArgument($Name)
    try { return [bool]($ps.Invoke() | Select-Object -First 1) } finally { $ps.Dispose() }
}
function Assert-RefusedRunningNothing($out, [string]$pattern, [string]$what) {
    Assert-True ($null -ne $out.Error) "$what -> throws"
    if ($null -ne $out.Error) { Assert-True ($out.Error -match $pattern) "$what -> the error names the cause (/$pattern/): $($out.Error)" }
    Assert-False (Called 'Invoke-AcpCoderRun') "$what -> Invoke-AcpCoderRun (operator account) NOT run"
    Assert-False (Called 'Invoke-AgentRun') "$what -> Invoke-AgentRun (stdin, operator account) NOT run"
    Assert-Eq 0 (Queue-Files).Count "$what -> no job (queued or claimed) left in the queue"
    Assert-Eq 0 (Staged-Files).Count "$what -> no prompt or transcript left in the shared tree"
}

try {
    Section 'containment OFF: the existing path runs, the fused leg is never touched'
    Reset-Knobs; Set-Config 'off' 'acp'
    $o1 = Run-Driver 'C:\Users\x\state\worktrees\proj-task'
    Assert-True ($null -eq $o1.Error) 'off + acp: no error'
    Assert-True (Called 'Invoke-AcpCoderRun') 'off + acp: the ACP path runs as before'
    foreach ($fn in 'egress', 'Get-Acl', 'Get-LocalUser', 'Get-ScheduledTask', 'Start-ScheduledTask', 'Stop-ScheduledTask', 'Wait-CoderLegResult') { Assert-False (Called $fn) "off + acp: $fn NOT called" }
    Assert-Eq 0 (Queue-Files).Count 'off: nothing queued'
    Assert-Eq 600 $o1.Result.IdleBoundSec 'off + acp: the result still carries the acp idle bound stamp'
    $offKeys = ($o1.Result.Keys | Sort-Object) -join ','
    Reset-Knobs; Set-Config 'off' 'stdin'
    $o1b = Run-Driver 'C:\Users\x\state\worktrees\proj-task'
    Assert-True ((Called 'Invoke-AgentRun') -and -not (Called 'Invoke-AcpCoderRun')) 'off + stdin: the stdin path runs, ACP does not'
    foreach ($fn in 'egress', 'Get-Acl', 'Get-LocalUser', 'Get-ScheduledTask', 'Start-ScheduledTask', 'Wait-CoderLegResult') { Assert-False (Called $fn) "off + stdin: $fn NOT called" }
    Reset-Knobs; Set-Config $null 'acp'
    $o1c = Run-Driver 'C:\Users\x\state\worktrees\proj-task'
    Assert-True ((Called 'Invoke-AcpCoderRun') -and -not (Called 'Get-LocalUser') -and -not (Called 'Get-ScheduledTask')) 'containment key absent (readable manifest): behaves as off, no machine probing'

    Section 'containment restricted_account: job queued, same result shape back'
    Reset-Knobs; Set-Config 'restricted_account' 'acp'
    $o2 = Run-Driver
    Assert-True ($null -eq $o2.Error) "restricted: no error ($($o2.Error))"
    Assert-Eq 'egress' $script:Calls[0] 'the egress hook is the FIRST call'
    Assert-Eq 'Get-Acl' $script:Calls[1] 'the ACL assertion is the SECOND step, straight after the egress hook'
    Assert-True ($script:Calls.IndexOf('Get-Acl') -lt $script:Calls.IndexOf('Start-ScheduledTask')) 'the ACL is read before the task is started'
    Assert-False (Called 'Invoke-AcpCoderRun') 'restricted: Invoke-AcpCoderRun (operator account) NOT run'
    Assert-False (Called 'Invoke-AgentRun') 'restricted: Invoke-AgentRun NOT run'
    Assert-True ((Called 'Start-ScheduledTask') -and (Called 'Wait-CoderLegResult')) 'restricted: the task is triggered and the result awaited'
    Assert-False (Called 'Stop-ScheduledTask') 'restricted success: the task is not stopped'
    Assert-Eq $CODER_SID $script:WaitArgs.Owner 'the result wait is bound to the coder SID as the expected file owner'
    Assert-True ($script:WaitArgs.NotBefore -gt (Get-Date).AddMinutes(-2) -and $script:WaitArgs.NotBefore -le (Get-Date)) 'the result wait is bound to a creation time not before the enqueue'
    $j = $script:LastJob
    Assert-True ($null -ne $j) 'a job file was written to the queue'
    if ($j) {
        Assert-Eq 'dispatch' $j.kind 'job.kind = dispatch'
        Assert-Eq "$wtBase\proj-task" $j.workdir 'job.workdir = the RESOLVED worktree path'
        Assert-Eq 'local/coder-30b' $j.model 'job.model gets the local/ prefix (as the ACP path does)'
        Assert-Eq 100 $j.timeout_sec 'job.timeout_sec = the caller timeout'
        Assert-Eq 600 $j.idle_sec 'job.idle_sec = acp.idle_sec from the manifest'
        Assert-Eq 45 $j.max_steps 'job.max_steps from the manifest'
        Assert-Eq 10 $j.spin_steps 'job.spin_steps from the manifest'
        Assert-True ($j.prompt_file -like "$tmpRoot\prompts\*") 'job.prompt_file sits under the shared coder-leg root'
        Assert-True ($j.log_path -like "$tmpRoot\logs\*") 'job.log_path sits under the shared coder-leg root'
    }
    Assert-Eq 'implement rpn.py <now> & done' $script:SeenPrompt 'the prompt reaches the coder byte-for-byte via the prompt file (not argv)'
    Assert-Eq 0 (Queue-Files).Count 'nothing left in the queue'
    Assert-Eq 0 (Staged-Files).Count 'the staged prompt and the shared transcript are removed after a run'
    Assert-Eq $offKeys (($o2.Result.Keys | Sort-Object) -join ',') 'the result hashtable has EXACTLY the keys the ACP path returns'
    Assert-Eq 600 $o2.Result.IdleBoundSec 'result.IdleBoundSec stamped'
    Assert-Eq 'no session/update' $o2.Result.IdleSignal 'result.IdleSignal stamped'
    Assert-Eq 12.5 $o2.Result.Seconds 'result values come from the leg'
    Assert-Eq $o2.Log $o2.Result.LogPath 'result.LogPath is the operator-side transcript path'
    Assert-True ((Test-Path $o2.Log) -and ((Get-Content $o2.Log -Raw) -match 'transcript-from-the-coder-leg')) 'the coder transcript is copied back to the operator-side LogPath'
    Assert-True (Test-MutexFree $mutexName) 'the dispatch mutex is free for another candidate after a successful run'

    Section 'FAIL CLOSED: each non-start throws and runs nothing as the operator'
    Reset-Knobs; Set-Config 'restricted_account' 'acp'; $script:Knobs.AccountMissing = $true
    $o = Run-Driver; Assert-RefusedRunningNothing $o 'does not exist' 'coder account missing'
    Assert-False (Called 'Start-ScheduledTask') 'coder account missing -> the task was never triggered'

    Reset-Knobs; $script:Knobs.TaskMissing = $true
    $o = Run-Driver; Assert-RefusedRunningNothing $o 'not registered' 'task missing'

    Reset-Knobs; $script:Knobs.TaskStarts = $false; $script:Knobs.LastTaskResult = 267011   # 0x41303
    $o = Run-Driver; Assert-RefusedRunningNothing $o '0x41303' 'task never started'
    if ($o.Error) { Assert-True ($o.Error -match 'SeBatchLogonRight') 'task never started -> the 0x41303 diagnosis names SeBatchLogonRight' }
    Assert-False (Called 'Wait-CoderLegResult') 'task never started -> no blind wait for a result'

    Reset-Knobs; $script:Knobs.Leg = 'refused'; $script:Knobs.ReasonText = "no ACP python`e[31m HACK`e[0m " + ('x' * 600)
    $o = Run-Driver; Assert-RefusedRunningNothing $o 'reported failure' 'leg reported ok=false'
    Assert-True ($o.Error -notmatch '[\x00-\x1F\x7F-\x9F]') 'result text in the error carries no control characters'
    Assert-True ($o.Error.Length -lt 700) "result text in the error is length-capped ($($o.Error.Length) chars)"
    $sanitised = ConvertTo-SafeConsoleText ("a`e[2Jb" + ('y' * 500)) 50
    Assert-True ($sanitised -notmatch '[\x00-\x1F]' -and $sanitised.Length -le 53) 'ConvertTo-SafeConsoleText strips control characters and caps length'

    Section 'L1: the result is bound to THIS job, the coder SID and a boolean ok'
    foreach ($case in @(
        @{ Leg = 'wrongsid';      Pat = 'ran as SID';           What = 'a result run as another SID' },
        @{ Leg = 'idmismatch';    Pat = 'is for job';           What = 'a result for another job id' },
        @{ Leg = 'wrongkind';     Pat = "not 'dispatch'";       What = 'a result of the wrong kind' },
        @{ Leg = 'toplevelfalse'; Pat = 'reported failure';     What = 'a result with top-level ok=false' },
        @{ Leg = 'okstring';      Pat = 'reported failure';     What = "a result with ok as the string 'true'" },
        @{ Leg = 'refusedinner';  Pat = 'could not run';        What = 'a leg that could not run (inner Ok=false)' },
        @{ Leg = 'innerokstring'; Pat = 'could not run';        What = "an inner Ok given as the string 'false'" },
        @{ Leg = 'nobody';        Pat = 'unusable result';      What = 'a result with no body' },
        @{ Leg = 'unusable';      Pat = 'unusable result';      What = 'a result without the driver envelope' }
    )) {
        Reset-Knobs; $script:Knobs.Leg = $case.Leg
        $o = Run-Driver; Assert-RefusedRunningNothing $o $case.Pat $case.What
        Assert-True (Called 'Stop-ScheduledTask') "$($case.What) -> the coder-leg task is stopped"
    }

    Section 'L1: the REAL Wait-CoderLegResult binds the result file to its owner and creation time'
    $script:Knobs.Acl = 'real'
    $resDir = (Get-CoderLegPaths).Results
    New-Item -ItemType Directory -Force $resDir | Out-Null
    $rid = 'job-20260101-000000-aaaaaaaa'
    $rp = Join-Path $resDir "$rid.result.json"
    Set-Content $rp '{"id":"x","ok":true}' -Encoding UTF8
    $realOwner = (Microsoft.PowerShell.Security\Get-Acl -LiteralPath $rp).GetOwner([Security.Principal.SecurityIdentifier]).Value
    $threw = $null; try { [void](& $realWait -JobId $rid -TimeoutSec 2 -PollSec 1 -ExpectedOwnerSid $CODER_SID) } catch { $threw = $_.Exception.Message }
    Assert-True ($threw -match 'owned by') 'a result file owned by another SID is refused (forged)'
    Assert-True (Test-Path $rp) 'the refused file is left in place'
    $threw = $null; try { [void](& $realWait -JobId $rid -TimeoutSec 2 -PollSec 1 -ExpectedOwnerSid $realOwner -NotBefore (Get-Date).AddHours(1)) } catch { $threw = $_.Exception.Message }
    Assert-True ($threw -match 'created before') 'a result file older than the enqueue time is refused (stale)'
    $got = & $realWait -JobId $rid -TimeoutSec 2 -PollSec 1 -ExpectedOwnerSid $realOwner -NotBefore (Get-Date).AddHours(-1)
    Assert-True ($null -ne $got -and $got.id -eq 'x') 'a result owned by the expected SID and created after the enqueue is accepted'
    Assert-False (Test-Path $rp) 'an accepted result is consumed'
    Set-Content $rp '{"id":"x","ok":true}' -Encoding UTF8
    $got = & $realWait -JobId $rid -TimeoutSec 2 -PollSec 1
    Assert-True ($null -ne $got) 'without a binding the wait still works (verify-coder-containment probe path)'
    $script:Knobs.Acl = 'tight'

    Section 'FAIL CLOSED: result timeout is bounded, then the coder is stopped'
    Reset-Knobs; $script:Knobs.Leg = 'null'
    $o = Run-Driver; Assert-RefusedRunningNothing $o 'wrote no result' 'result timeout'
    Assert-True (Called 'Stop-ScheduledTask') 'result timeout -> Stop-ScheduledTask is issued (the coder does not keep editing)'
    Assert-True ($o.Seconds -ge 2.5 -and $o.Seconds -lt 15) "the result wait honours ResultWaitSec (took $([math]::Round($o.Seconds,1))s of 3s)"
    Assert-True (Test-MutexFree $mutexName) 'the dispatch mutex is free after a failure'
    Reset-Knobs; $script:Knobs.Leg = 'null'; $script:Knobs.StopHangs = $true
    $o = Run-Driver; Assert-RefusedRunningNothing $o 'did not leave Running' 'a task that will not stop'

    Section 'L4: cancellation stops the coder'
    Reset-Knobs; $script:Knobs.Leg = 'null'
    $o2opts = $opts.Clone(); $o2opts.ShouldCancel = { $script:Calls -contains 'Wait-CoderLegResult' }
    $o = Run-Driver -Options $o2opts; Assert-RefusedRunningNothing $o 'cancelled; stopping' 'cancel during the result wait'
    Assert-True (Called 'Stop-ScheduledTask') 'cancel during the wait -> Stop-ScheduledTask is issued'
    Reset-Knobs
    $o3opts = $opts.Clone(); $o3opts.ShouldCancel = { $true }
    $o = Run-Driver -Options $o3opts; Assert-RefusedRunningNothing $o 'cancelled before' 'cancel before the trigger'
    Assert-False (Called 'Start-ScheduledTask') 'cancel before the trigger -> the task is never started'
    Assert-True ((Get-Command Invoke-FusedCoderRun).ScriptBlock.ToString() -match 'Test-DispatchCancelled') 'the default cancel check is the dispatch stop sentinel'

    Section 'L2: a shared tree writable by other accounts is refused'
    foreach ($acl in 'authusers', 'users', 'unknown') {
        Reset-Knobs; $script:Knobs.Acl = $acl
        $o = Run-Driver; Assert-RefusedRunningNothing $o '#1686' "ACL grants write to $acl"
        Assert-False (Called 'Start-ScheduledTask') "ACL $acl -> the task was never triggered"
    }
    Reset-Knobs; $script:Knobs.Acl = 'everyone-read'
    $o = Run-Driver; Assert-True ($null -eq $o.Error) "a read-only grant to Everyone is fine ($($o.Error))"
    $script:Knobs.Acl = 'real'
    $aclDir = Join-Path $tmpRoot 'acltest'; New-Item -ItemType Directory -Force $aclDir | Out-Null
    # hermetic ACL: no inheritance, exactly operator + SYSTEM + Administrators
    $acl0 = Microsoft.PowerShell.Security\Get-Acl -LiteralPath $aclDir
    $acl0.SetAccessRuleProtection($true, $false)
    foreach ($r in @($acl0.Access)) { [void]$acl0.RemoveAccessRule($r) }
    foreach ($sid in $OPERATOR_SID, 'S-1-5-18', 'S-1-5-32-544') {
        $acl0.AddAccessRule((New-Object Security.AccessControl.FileSystemAccessRule((New-Object Security.Principal.SecurityIdentifier($sid)), 'FullControl', 'ContainerInherit,ObjectInherit', 'None', 'Allow')))
    }
    Microsoft.PowerShell.Security\Set-Acl -LiteralPath $aclDir -AclObject $acl0
    $realOk = $null; try { Assert-CoderQueueAclTight -Path $aclDir; $realOk = $true } catch { $realOk = $_.Exception.Message }
    Assert-True ($realOk -eq $true) "a real temp dir (user, SYSTEM, Administrators) passes ($realOk)"
    $acl = Microsoft.PowerShell.Security\Get-Acl -LiteralPath $aclDir
    $acl.AddAccessRule((New-Object Security.AccessControl.FileSystemAccessRule('Authenticated Users', 'Modify', 'ContainerInherit,ObjectInherit', 'None', 'Allow')))
    Microsoft.PowerShell.Security\Set-Acl -LiteralPath $aclDir -AclObject $acl
    $threw = $null; try { Assert-CoderQueueAclTight -Path $aclDir } catch { $threw = $_.Exception.Message }
    Assert-True ($threw -match 'Authenticated Users' -and $threw -match '#1686') 'a REAL Authenticated Users Modify grant on a real directory is refused'
    $threw = $null; try { Assert-CoderQueueAclTight -Path (Join-Path $tmpRoot 'no-such-dir') } catch { $threw = $_.Exception.Message }
    Assert-True ($threw -match 'cannot read the ACL') 'an unreadable or missing path is refused'
    $script:Knobs.Acl = 'tight'

    Section 'L3: links and paths outside the base are refused'
    Reset-Knobs
    $o = Run-Driver 'C:\Users\mrbla\agentic-setup\state\worktrees\proj-task'
    Assert-RefusedRunningNothing $o 'does not resolve|outside the shared worktree base' 'workdir outside the shared base'
    $o = Run-Driver $elsewhere
    Assert-RefusedRunningNothing $o 'outside the shared worktree base' 'an existing directory outside the base'
    Assert-False (Called 'Start-ScheduledTask') 'workdir outside the base -> the task was never triggered'
    $o = Run-Driver $junction
    Assert-RefusedRunningNothing $o 'link \(reparse point\)' 'a workdir that is a JUNCTION out of the base'
    $o = Run-Driver (Join-Path $junction 'x')
    Assert-RefusedRunningNothing $o 'link \(reparse point\)|does not resolve' 'a path through a junction'
    $jopts = $opts.Clone(); $jopts.WorktreeBase = $jbase
    $o = Run-Driver (Join-Path $jbase 'proj-task') -Options $jopts
    Assert-RefusedRunningNothing $o 'link \(reparse point\)' 'a worktree base that is itself a junction'
    $o = Run-Driver "$wtBase\..\worktrees\proj-task"
    Assert-True ($null -eq $o.Error -and $script:LastJob.workdir -eq "$wtBase\proj-task") '.. segments are normalised to the resolved path'
    $o = Run-Driver "$wtBase\missing-dir"
    Assert-RefusedRunningNothing $o 'does not resolve' 'a workdir that does not exist'
    $threw = $null; try { [void](Resolve-CoderFinalPath -Path $junction -What 'p') } catch { $threw = $_.Exception.Message }
    Assert-True ($threw -match 'reparse') 'Resolve-CoderFinalPath refuses a junction directly'
    $plain = Resolve-CoderFinalPath -Path "$wtBase\PROJ-TASK" -What 'p'
    Assert-Eq "$wtBase\proj-task" $plain 'Resolve-CoderFinalPath returns the on-disk spelling (case-normalised)'
    $short = $null; try { $short = (New-Object -ComObject Scripting.FileSystemObject).GetFolder("$wtBase\proj-task").ShortPath } catch { }
    if ($short -and ($short -ne "$wtBase\proj-task")) {
        $viaShort = $null; try { $viaShort = Resolve-CoderFinalPath -Path $short -What 'p' } catch { $viaShort = "threw: $($_.Exception.Message)" }
        Assert-Eq "$wtBase\proj-task" $viaShort "an 8.3 short-name spelling resolves to the real long path ($short)"
    } else { _pass 'no 8.3 short names on this volume (short-name case not applicable)' }

    Section 'FAIL CLOSED: unknown containment value, driver not acp'
    foreach ($bad in 'restricted-account', 'wide-open', 'RESTRICTED', '') {
        Reset-Knobs; Set-Config $bad 'acp'
        $o = Run-Driver
        Assert-RefusedRunningNothing $o 'unrecognised containment' "containment '$bad'"
        Assert-Eq 0 $script:Calls.Count "containment '$bad' -> NOTHING was called (not even the egress hook)"
    }
    Reset-Knobs; Set-Config 'restricted_account' 'stdin'
    $o = Run-Driver; Assert-RefusedRunningNothing $o 'needs driver=acp' 'restricted_account with driver=stdin'

    Section 'FAIL CLOSED: the queue contract must be loaded'
    Reset-Knobs; Set-Config 'restricted_account' 'acp'
    $savedStart = ${function:Start-CoderLegTask}
    Remove-Item Function:\Start-CoderLegTask
    $o = Run-Driver; Assert-RefusedRunningNothing $o 'queue contract is not loaded' 'queue contract not loaded'
    Set-Item Function:\Start-CoderLegTask $savedStart

    Section 'L7: a manifest that cannot be read refuses the coder where containment is expected'
    $marker = Join-Path $tmpRoot 'coder-provisioned.marker'
    $mopts = $opts.Clone(); $mopts.MarkerPath = $marker
    foreach ($shape in 'missing', 'garbled') {
        Reset-Knobs
        if ($shape -eq 'missing') { $env:BLARAI_FLEET_DRIVER_CONFIG = (Join-Path $tmpRoot 'no-such-manifest.json') }
        else { Set-Content $cfgPath '{ this is not json' -Encoding UTF8; $env:BLARAI_FLEET_DRIVER_CONFIG = $cfgPath }
        $cfgU = Get-FleetDriverConfig -ScriptRoot $PSScriptRoot -Fresh
        Assert-True ($cfgU.containment_unresolved -and $cfgU.containment -eq 'off') "$shape manifest -> containment off AND containment_unresolved"
        $o = Run-Driver -Options $mopts
        Assert-RefusedRunningNothing $o 'could not be read' "$shape manifest + coder-leg task registered"
        $script:Knobs.TaskMissing = $true
        $o = Run-Driver -Options $mopts
        Assert-True ($null -eq $o.Error -and (Called 'Invoke-AgentRun')) "$shape manifest + no task + no marker -> the dormant path runs as before"
        Set-Content $marker 'provisioned' -Encoding UTF8
        $o = Run-Driver -Options $mopts
        Assert-RefusedRunningNothing $o 'could not be read' "$shape manifest + provisioning marker (no task)"
        Remove-Item $marker -Force
    }
    Reset-Knobs; Set-Config 'off' 'acp'
    Assert-False (Get-FleetDriverConfig -ScriptRoot $PSScriptRoot -Fresh).containment_unresolved 'a readable manifest is never unresolved'
    $o = Run-Driver -Options $mopts
    Assert-True ($null -eq $o.Error -and (Called 'Invoke-AcpCoderRun') -and -not (Called 'Get-ScheduledTask')) 'readable manifest + off: runs as before and never probes the machine'

    Section 'EGRESS hook: a refusing hook stops everything; the shipped hook records the accepted gap'
    Reset-Knobs; Set-Config 'restricted_account' 'acp'; $script:Knobs.EgressThrows = $true
    $o = Run-Driver; Assert-RefusedRunningNothing $o 'egress filters absent' 'egress hook refuses'
    Assert-Eq 'egress' (($script:Calls | Select-Object -Unique) -join ',') 'egress refusal -> nothing ran after the hook'
    $hookOut = & $realEgress -Context 'test' 6>&1 | Out-String
    $hookObj = & $realEgress -Context 'test' 6>$null
    Assert-True ($hookOut -match 'accepted gap') 'the shipped hook logs "egress: accepted gap"'
    Assert-False ([bool]$hookObj.Enforced) 'the shipped hook reports not-enforced'

    Section 'SERIALIZE: one candidate at a time, a bounded wait, a clear error on expiry'
    Reset-Knobs; Set-Config 'restricted_account' 'acp'
    $holderMarker = Join-Path $tmpRoot 'holder.ready'
    $held = New-Object System.Threading.Mutex($false, $mutexName); [void]$held.WaitOne()
    Assert-False (Test-MutexFree $mutexName) 'self-check: a held mutex is seen as busy from another thread'
    $held.ReleaseMutex(); $held.Dispose()
    $holder = Start-Job -ArgumentList $mutexName, $holderMarker -ScriptBlock {
        param($n, $mk)
        $m = New-Object System.Threading.Mutex($false, $n); [void]$m.WaitOne()
        Set-Content $mk 'held'; Start-Sleep -Seconds 25
    }
    $t0 = Get-Date; while (-not (Test-Path $holderMarker) -and ((Get-Date) - $t0).TotalSeconds -lt 30) { Start-Sleep -Milliseconds 200 }
    Assert-True (Test-Path $holderMarker) 'test setup: another process holds the dispatch mutex'
    $o = Run-Driver
    Assert-RefusedRunningNothing $o 'gave up' 'another candidate holds the turn'
    Assert-False (Called 'Start-ScheduledTask') 'serialize wait expired -> the task was never triggered'
    Assert-True ($o.Seconds -ge 1.5 -and $o.Seconds -lt 10) "the wait is bounded by QueueWaitSec (waited $([math]::Round($o.Seconds,1))s of 2s)"
    Stop-Job $holder -ErrorAction SilentlyContinue; Remove-Job $holder -Force -ErrorAction SilentlyContinue
    Start-Sleep -Milliseconds 500
    # a holder THREAD that exits while owning the mutex leaves it ABANDONED (the handle is kept alive)
    Add-Type -TypeDefinition 'public static class FusedMutexAbandoner { static System.Threading.Mutex keep; public static void Hold(string n) { var t = new System.Threading.Thread(() => { keep = new System.Threading.Mutex(false, n); keep.WaitOne(); }); t.Start(); t.Join(); } }'
    [FusedMutexAbandoner]::Hold($mutexName)
    Reset-Knobs
    $o = Run-Driver
    Assert-True ($null -eq $o.Error) "an ABANDONED mutex (the holder thread died owning it) does not block the next candidate ($($o.Error))"
    Assert-True (Called 'Start-ScheduledTask') 'the candidate that met the abandoned mutex ran'

    Reset-Knobs; $script:Knobs.TaskState = 'Running'
    $o = Run-Driver; Assert-RefusedRunningNothing $o 'stayed Running' 'task still running an earlier job'
    Assert-False (Called 'Start-ScheduledTask') 'task still Running -> our trigger (which IgnoreNew would swallow) is never sent'

    Reset-Knobs
    Initialize-CoderLegQueue
    Set-Content -Path (Join-Path (Get-CoderLegPaths).Queue 'job-stale.json') -Value '{}'
    $o = Run-Driver
    Assert-True ($null -ne $o.Error -and $o.Error -match 'unclaimed job') 'a stale unclaimed job in the queue is refused (it would run first)'
    Assert-False (Called 'Start-ScheduledTask') 'stale queue -> the task was never triggered'
    Remove-Item (Join-Path (Get-CoderLegPaths).Queue 'job-stale.json') -Force

    Section 'the SHIPPED wait budgets (defaults, not the test overrides)'
    $b100 = Get-FusedLegBudgets -TimeoutSec 100
    Assert-Eq 20 $b100.StartWaitSec 'StartWaitSec default = 20'
    Assert-Eq 460 $b100.ResultWaitSec 'ResultWaitSec default = timeout + 300 (the ACP client outer ceiling) + 60'
    Assert-Eq 30 $b100.StopWaitSec 'StopWaitSec default = 30'
    Assert-Eq 1020 $b100.QueueWaitSec 'QueueWaitSec default = 2 x (start + result + stop)'
    foreach ($t in 60, 100, 1800, 3600) {
        $b = Get-FusedLegBudgets -TimeoutSec $t
        Assert-True ($b.ResultWaitSec -gt ($t + 300)) "timeout ${t}: the result wait outlasts the ACP client's own ceiling (timeout + 300)"
        Assert-True ($b.QueueWaitSec -ge 2 * ($b.StartWaitSec + $b.ResultWaitSec + $b.StopWaitSec)) "timeout ${t}: the queue wait covers two earlier candidates"
    }
    Assert-True ((Get-Command Invoke-FusedCoderRun).ScriptBlock.ToString() -match 'ResultWaitSec = \$b\.ResultWaitSec') 'Invoke-FusedCoderRun takes its budgets from Get-FusedLegBudgets'

    Section 'Start-CoderLegTask + the shared diagnosis'
    Reset-Knobs; $script:Knobs.TaskStarts = $false; $script:Knobs.TaskState = 'Running'
    $s = Start-CoderLegTask -StartWaitSec 1 -PollMs 20
    Assert-True $s.Started 'a task caught Running counts as started'
    Reset-Knobs; $script:Knobs.TaskStarts = $false
    $threw = $null; try { [void](Start-CoderLegTask -StartWaitSec 1 -PollMs 20) } catch { $threw = $_.Exception.Message }
    Assert-True ($threw -match 'did NOT start') 'a task that never starts throws'
    $d = Get-CoderLegTaskStartDiagnosis -State 'Ready' -LastTaskResult 267011
    Assert-Eq '0x41303' $d.Hex 'diagnosis: 267011 -> 0x41303'
    Assert-True ($d.Hint -match 'SeBatchLogonRight') 'diagnosis: 0x41303 names SeBatchLogonRight'
    Reset-Knobs; $script:Knobs.TaskState = 'Running'; $script:Knobs.StopHangs = $false
    Assert-True (Stop-CoderLegTask -WaitSec 1 -PollMs 20) 'Stop-CoderLegTask returns true once the task leaves Running'
    $script:Knobs.TaskState = 'Running'; $script:Knobs.StopHangs = $true
    Assert-False (Stop-CoderLegTask -WaitSec 1 -PollMs 20) 'Stop-CoderLegTask returns false when the task will not stop'
    $containSrc = Get-Content "$PSScriptRoot\verify-coder-containment.ps1" -Raw
    Assert-True ($containSrc -match 'Start-CoderLegTask') 'verify-coder-containment.ps1 uses the SAME shared start-proof helper'

    Section 'Structure: no operator-account path inside the fused function'
    $fusedBody = (Get-Command Invoke-FusedCoderRun).ScriptBlock.ToString()
    Assert-False ($fusedBody -match 'Start-Process') 'Invoke-FusedCoderRun never spawns a process itself'
    Assert-False ($fusedBody -match 'Invoke-AgentRun') 'Invoke-FusedCoderRun never calls the stdin runner'
    Assert-False ($fusedBody -match '(?m)^\s*[^#\r\n]*Invoke-AcpCoderRun') 'Invoke-FusedCoderRun never calls the operator-side ACP runner'
}
finally {
    Remove-Item Env:\BLARAI_CODER_LEG_ROOT -ErrorAction SilentlyContinue
    Remove-Item Env:\BLARAI_FLEET_DRIVER_CONFIG -ErrorAction SilentlyContinue
    foreach ($jn in $junction, $jbase) { try { if (Test-Path -LiteralPath $jn) { [IO.Directory]::Delete($jn) } } catch { } }
    if ($tmpRoot -like '*\Temp\fused-seam-*') { Remove-Item $tmpRoot -Recurse -Force -ErrorAction SilentlyContinue }
}

Write-Host ''
if ($script:Fail -eq 0) {
    Write-Host "RESULT: $($script:Pass) passed, 0 failed" -ForegroundColor Green; exit 0
} else {
    Write-Host "RESULT: $($script:Pass) passed, $($script:Fail) failed" -ForegroundColor Red
    $script:Failures | ForEach-Object { Write-Host "  - $_" -ForegroundColor Red }
    exit 1
}
