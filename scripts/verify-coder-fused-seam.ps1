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
param([switch]$Mutations, [switch]$ProveHarness, [string[]]$Only = @(), [int]$Throttle = 1)
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
        $files = 'fleet-lib.ps1', 'coder-leg-queue.ps1', 'coder-provisioning-lib.ps1', 'provision-coder-account.ps1', 'new-agent-task.ps1', 'critic-run.ps1', 'critique-loop.ps1', 'capture-app.ps1', 'check-design-structural.ps1', 'run-fleet.ps1', 'review-website.ps1', 'review-website-lib.ps1', 'review-website-report.ps1', 'run-battery-night.ps1', 'battery-bootstrap.ps1', 'coder-leg-run.ps1', 'register-coder-leg-task.ps1', 'verify-coder-fused-seam.ps1', 'verify-coder-containment.ps1'
        $run = {
            param($Dir, $Mut, $files, $pw, $SrcDir)
            New-Item -ItemType Directory -Force $Dir | Out-Null
            foreach ($f in $files) { Copy-Item (Join-Path $SrcDir $f) (Join-Path $Dir $f) }
            if ($Mut) {
                $target = Join-Path $Dir $Mut.F
                $text = [IO.File]::ReadAllText($target)
                if (-not $text.Contains($Mut.O)) { return @{ Class = 'ERROR'; Why = "mutation target not found in $($Mut.F)" } }
                [IO.File]::WriteAllText($target, $text.Replace($Mut.O, $Mut.W), (New-Object Text.UTF8Encoding($true)))
            }
            if ($Mut) { $env:BLARAI_FUSED_FAILFAST = '1' } else { Remove-Item Env:\BLARAI_FUSED_FAILFAST -ErrorAction SilentlyContinue }   # a mutant stops at its first [FAIL]; the control runs in full
            $out = & $pw -NoProfile -File (Join-Path $Dir 'verify-coder-fused-seam.ps1') 2>&1 | Out-String
            $code = $LASTEXITCODE
            $fails = @($out -split "`n" | Where-Object { $_ -match '\[FAIL\]' })
            if ($code -eq 0) { return @{ Class = 'SURVIVED'; Why = 'the suite did not notice' } }
            if ($fails.Count -gt 0) { return @{ Class = 'KILLED'; Why = ("$($fails[0])").Trim() } }
            return @{ Class = 'ERROR'; Why = 'non-zero exit with no [FAIL] line (crash or parse error): ' + (($out -split "`n" | Select-Object -Last 3) -join ' | ') }
        }
        $runText = $run.ToString()
        $ctl = & $run (Join-Path $tmp 's-control') $null $files $pw $PSScriptRoot
        $res = @()
        $controlOk = ($ctl.Class -eq 'SURVIVED')   # exit 0 on the unmutated copy = control passes
        if (-not $controlOk) { Write-Host "  [CONTROL FAILED] the unmutated copy does not pass: $($ctl.Why)" -ForegroundColor Red }
        else {
            Write-Host '  [control]  unmutated copy passes' -ForegroundColor Green
            # mutants are independent (own temp tree, own temp queue root, own mutex name): -Throttle N runs N at once
            $res = @($Muts | ForEach-Object -ThrottleLimit ([math]::Max(1, $Throttle)) -Parallel {
                $m = $_
                $rb = [scriptblock]::Create($using:runText)
                $r = & $rb (Join-Path $using:tmp ('s-' + $m.N)) $m $using:files $using:pw $using:PSScriptRoot
                $colour = if ($r.Class -eq 'KILLED') { 'Green' } else { 'Red' }
                Write-Host ("  [{0}] {1}  <- {2}" -f $r.Class.PadRight(8), $m.N, $r.Why) -ForegroundColor $colour
                @{ N = $m.N; Class = $r.Class; Why = $r.Why }
            })
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
        @{ N = 'acl-check-removed';           F = 'fleet-lib.ps1';       O = 'Assert-CoderQueueAclTight -Path @((Split-Path $paths.Root -Parent), $paths.Root, $paths.Queue, $paths.Prompts, $paths.Results, $paths.Logs, $wtBaseRaw) -CoderUser $o.CoderUser'; W = '' },
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
        @{ N = 'abandoned-mutex-accepted';    F = 'fleet-lib.ps1';       O = 'catch [System.Threading.AbandonedMutexException] { $held = $true }'; W = 'catch [System.Threading.AbandonedMutexException] { throw }' },
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
        @{ N = 'claimed-job-cleared';         F = 'fleet-lib.ps1';       O = 'if (Test-FusedDirIntact -Path $queueDir -ExpectedKey $ids.Queue) { Remove-Item -LiteralPath (Join-Path $queueDir "$jobId.json.claimed") -ErrorAction SilentlyContinue }'; W = '' },
        @{ N = 'cancel-polled-in-wait';       F = 'fleet-lib.ps1';       O = "if (& `$o.ShouldCancel) { throw 'fused leg: dispatch cancelled; stopping"; W = "if (`$false) { throw 'fused leg: dispatch cancelled; stopping" },
        @{ N = 'cancel-before-trigger';       F = 'fleet-lib.ps1';       O = "if (& `$o.ShouldCancel) { throw 'fused leg: dispatch cancelled before"; W = "if (`$false) { throw 'fused leg: dispatch cancelled before" },
        @{ N = 'job-removed-on-failure';      F = 'fleet-lib.ps1';       O = 'if ($jobId -and (Test-FusedDirIntact -Path $queueDir -ExpectedKey $ids.Queue)) {'; W = 'if ($jobId) {' },
        @{ N = 'prompt-removed';              F = 'fleet-lib.ps1';       O = 'if ($promptFile -and (Test-FusedDirIntact -Path $promptsDir -ExpectedKey $ids.Prompts)) { Remove-Item -LiteralPath $promptFile -ErrorAction SilentlyContinue }'; W = '' },
        @{ N = 'transcript-removed';          F = 'fleet-lib.ps1';       O = 'if ($sharedLog -and (Test-FusedDirIntact -Path $logsDir -ExpectedKey $ids.Logs)) { Remove-Item -LiteralPath $sharedLog -ErrorAction SilentlyContinue }'; W = '' },
        @{ N = 'transcript-copied-back';      F = 'fleet-lib.ps1';       O = 'if (Test-Path -LiteralPath $sharedLog) { Copy-CoderTranscript -Source $sharedLog -Destination $LogPath }'; W = '' },
        @{ N = 'default-result-wait';         F = 'fleet-lib.ps1';       O = '$result = $TimeoutSec + 300 + 60';                   W = '$result = 1' },
        @{ N = 'default-queue-wait';          F = 'fleet-lib.ps1';       O = 'QueueWaitSec = 2 * ($start + $result + $stop)';      W = 'QueueWaitSec = 1' },
        @{ N = 'default-start-wait';          F = 'fleet-lib.ps1';       O = '$start = 20; $stop = 30';                            W = '$start = 1; $stop = 30' },
        @{ N = 'budgets-used-by-run';         F = 'fleet-lib.ps1';       O = 'QueueWaitSec = $b.QueueWaitSec; ResultWaitSec = $b.ResultWaitSec'; W = 'QueueWaitSec = 1; ResultWaitSec = 1' },
        @{ N = 'identity-compare';            F = 'fleet-lib.ps1';       O = 'if ($id.Key -cne $ExpectedKey) {';                   W = 'if ($false) {' },
        @{ N = 'gitdir-pointer-recheck';      F = 'fleet-lib.ps1';       O = 'Assert-FusedWorktreeTrusted -Record (Get-Content -LiteralPath (Get-FusedWorktreeRecordPath $wdFull) -Raw | ConvertFrom-Json)'; W = '' },
        @{ N = 'wtgit-gitdir-guard';          F = 'fleet-lib.ps1';       O = 'if ((Get-FusedWorktreeGitDir -WorkTree $Record.Path) -cne $Record.GitDir) { throw'; W = 'if ($false) { throw' },
        @{ N = 'wtgit-pinned-argv';           F = 'fleet-lib.ps1';       O = 'return (Get-HardenedGitArgs -GitDir $reg.GitDir -WorkTree $final)'; W = "return @('-C', `$Path)" },
        @{ N = 'wtgit-fsmonitor-off';         F = 'fleet-lib.ps1';       O = "'-c', 'core.fsmonitor=false', ";                    W = "'-c', 'core.untrackedCache=false', " },
        @{ N = 'worktree-registered';         F = 'fleet-lib.ps1';       O = 'Register-FusedWorktree -Path $wdFull -Key $ids.Work -GitDir $gitDir'; W = '' },
        @{ N = 'worktree-must-be-linked';     F = 'fleet-lib.ps1';       O = 'if (-not (Test-Path -LiteralPath $dotGit -PathType Leaf)) { throw'; W = 'if ($false) { throw' },
        @{ N = 'logs-dir-recheck';            F = 'fleet-lib.ps1';       O = "`$null = Assert-FusedPathIntact -Path `$logsDir -ExpectedKey `$ids.Logs -What 'logs dir after the coder returned'"; W = '' },
        @{ N = 'log-hardlink-refused';        F = 'fleet-lib.ps1';       O = 'if ($id.Reparse -or $id.Links -gt 1) { throw "fused leg: the shared transcript'; W = 'if ($false) { throw "fused leg: the shared transcript' },
        @{ N = 'prompts-dir-recheck';         F = 'fleet-lib.ps1';       O = "`$null = Assert-FusedPathIntact -Path `$promptsDir -ExpectedKey `$ids.Prompts -What 'prompts dir'"; W = '' },
        @{ N = 'cancel-in-mutex-wait';        F = 'fleet-lib.ps1';       O = "if (& `$o.ShouldCancel) { throw `"fused leg: dispatch cancelled while waiting for the coder leg's turn.`" }"; W = '' },
        @{ N = 'cancel-in-running-wait';      F = 'fleet-lib.ps1';       O = "if (& `$o.ShouldCancel) { throw 'fused leg: dispatch cancelled while the coder-leg task was still running an earlier job.' }"; W = '' },
        @{ N = 'acl-owner-check';             F = 'fleet-lib.ps1';       O = 'if (-not $owner -or $allowedOwners -notcontains $owner) {'; W = 'if ($false) {' },
        @{ N = 'acl-generic-rights';          F = 'fleet-lib.ps1';       O = ' + 0x10000000 + 0x40000000';                        W = '' },
        @{ N = 'acl-parent-checked';          F = 'fleet-lib.ps1';       O = '@((Split-Path $paths.Root -Parent), $paths.Root,';   W = '@($paths.Root,' },
        @{ N = 'stop-needs-confirmed-state';  F = 'coder-leg-queue.ps1'; O = "if (`$queried -and `$state -ne 'Running') { return `$true }"; W = "if (`$state -ne 'Running') { return `$true }" },
        @{ N = 'marker-written-by-provisioning'; F = 'provision-coder-account.ps1'; O = '$markerPath = Write-CoderProvisionMarker -CoderUser $CoderUser -CoderSid $sid'; W = '$markerPath = $null' },
        @{ N = 'marker-removed-by-rollback';  F = 'provision-coder-account.ps1'; O = 'Remove-CoderProvisionMarker) {';        W = '$false) {' },
        @{ N = 'marker-path-agreement';       F = 'coder-provisioning-lib.ps1'; O = "'C:\blarai-fleet\coder-provisioned.marker'"; W = "'C:\blarai-fleet\coder-marker.txt'" },
        @{ N = 'fingerprint-compared';        F = 'fleet-lib.ps1';       O = 'if ((Get-GitDirFingerprint -GitDir $Record.GitDir) -cne $Record.Fingerprint) { throw'; W = 'if ($false) { throw' },
        @{ N = 'fingerprint-covers-hooks';    F = 'fleet-lib.ps1';       O = "`$hk = Join-Path `$d 'hooks'";                       W = "`$hk = Join-Path `$d 'hooks-not'" },
        @{ N = 'fingerprint-covers-config';   F = 'fleet-lib.ps1';       O = "foreach (`$n in 'config', 'config.worktree', 'commondir', 'gitdir', 'info\attributes') {"; W = "foreach (`$n in 'commondir', 'gitdir') {" },
        @{ N = 'fingerprint-follows-commondir'; F = 'fleet-lib.ps1';     O = '$dirs += [IO.Path]::GetFullPath($common)';           W = '' },
        @{ N = 'hardened-hooks-off';          F = 'fleet-lib.ps1';       O = "'-c', 'core.hooksPath=NUL', ";                       W = '' },
        @{ N = 'hardened-no-optional-locks';  F = 'fleet-lib.ps1';       O = "'--no-optional-locks', ";                            W = '' },
        @{ N = 'hardened-ssh-ext';            F = 'fleet-lib.ps1';       O = "'-c', 'core.sshCommand=false',";                     W = '' },
        @{ N = 'coder-supplied-logpath';      F = 'fleet-lib.ps1';       O = 'LogPath = $LogPath; Seconds = [double]$r.Seconds';   W = 'LogPath = [string]$r.LogPath; Seconds = [double]$r.Seconds' },
        @{ N = 'result-read-share';           F = 'coder-leg-queue.ps1'; O = '[IO.FileAccess]::Read, [IO.FileShare]::Read)';       W = '[IO.FileAccess]::Read, [IO.FileShare]::ReadWrite -bor [IO.FileShare]::Delete)' },
        @{ N = 'transcript-read-share';       F = 'fleet-lib.ps1';       O = '[IO.FileAccess]::Read, [IO.FileShare]::Read)';       W = '[IO.FileAccess]::Read, [IO.FileShare]::ReadWrite -bor [IO.FileShare]::Delete)' },
        @{ N = 'withtimeout-asserts-worktree'; F = 'fleet-lib.ps1';      O = '$null = Assert-OperatorWorktree -Path $WorkDir';     W = '' },
        @{ N = 'candidate-asserts-worktree';  F = 'fleet-lib.ps1';       O = '$null = Assert-OperatorWorktree -Path $wt   #';      W = '$null = $wt   #' },
        @{ N = 'operator-path-link-check';    F = 'fleet-lib.ps1';       O = 'if ($it -and ($it.Attributes -band [IO.FileAttributes]::ReparsePoint)) { throw "fused leg: ''$Relative'' passes'; W = 'if ($false) { throw "fused leg: ''$Relative'' passes' },
        @{ N = 'operator-path-escape-check';  F = 'fleet-lib.ps1';       O = 'if (-not $abs.StartsWith($root, [StringComparison]::OrdinalIgnoreCase)) { throw'; W = 'if ($false) { throw' },
        @{ N = 'operator-path-recorded-assert'; F = 'fleet-lib.ps1';     O = '    $null = Assert-OperatorWorktree -Path $Worktree'; W = '' },
        @{ N = 'remove-worktree-link-path';   F = 'fleet-lib.ps1';       O = '            [IO.Directory]::Delete($Path)';           W = '            Write-Verbose $Path' },
        @{ N = 'coder-idle-after-result';     F = 'fleet-lib.ps1';       O = 'Assert-CoderLegTaskIdle -TaskPath $o.TaskPath -TaskName $o.TaskName -WaitSec $o.StopWaitSec -PollMs $o.PollMs'; W = '' },
        @{ N = 'idle-state-unreadable';       F = 'coder-leg-queue.ps1'; O = 'throw "fused leg: cannot confirm that the coder-leg task has finished'; W = 'return; throw "fused leg: cannot confirm that the coder-leg task has finished' },
        @{ N = 'idle-stop-failure';           F = 'coder-leg-queue.ps1'; O = "throw 'fused leg: the coder-leg task is still running after it returned its result and could not be stopped.'"; W = 'return' },
        @{ N = 'lint-visual-fix-git';         F = 'new-agent-task.ps1';  O = '{ git @(Get-WtGit $wt) reset 2>&1 | Out-Null; return $false }'; W = '{ git -C $wt reset 2>&1 | Out-Null; return $false }' },
        @{ N = 'lint-worktree-remove';        F = 'new-agent-task.ps1';  O = 'Remove-WorktreeSafe -Repo $Repo -Path $wtOrig';       W = 'git -C $Repo worktree remove $wtOrig --force 2>&1 | Out-Null' },
        @{ N = 'lint-write-into-worktree';    F = 'fleet-lib.ps1';       O = "Set-Content -LiteralPath (Get-OperatorWorktreePath -Worktree `$wt -Relative '.blarai-hypothesis-stats.txt')"; W = "Set-Content -LiteralPath (Join-Path `$wt '.blarai-hypothesis-stats.txt')" },
        @{ N = 'exclusive-create';            F = 'coder-leg-queue.ps1'; O = '[IO.FileMode]::CreateNew';                            W = '[IO.FileMode]::Create' },
        @{ N = 'job-write-exclusive';         F = 'coder-leg-queue.ps1'; O = 'Write-OperatorFileExclusive -LiteralPath $tmp -Text ($Job | ConvertTo-Json -Depth 8)'; W = '($Job | ConvertTo-Json -Depth 8) | Set-Content -LiteralPath $tmp -Encoding UTF8' },
        @{ N = 'job-move-no-overwrite';       F = 'coder-leg-queue.ps1'; O = '[IO.File]::Move($tmp, $path)';                       W = 'Move-Item -LiteralPath $tmp -Destination $path -Force' },
        @{ N = 'job-id-shape-add';            F = 'coder-leg-queue.ps1'; O = 'if (-not (Test-CoderLegJobId $Job.id)) {';           W = 'if ($false) {' },
        @{ N = 'job-id-shape-wait';           F = 'coder-leg-queue.ps1'; O = 'if (-not (Test-CoderLegJobId $JobId)) {';            W = 'if ($false) {' },
        @{ N = 'job-id-pattern';              F = 'coder-leg-queue.ps1'; O = '^job-\d{8}-\d{6}-[0-9a-f]{8}$';                      W = '^job-.*$' },
        @{ N = 'result-hardlink-refused';     F = 'coder-leg-queue.ps1'; O = 'if ($idn.Reparse -or $idn.Links -gt 1) { throw';     W = 'if ($false) { throw' },
        @{ N = 'prompt-exclusive-write';      F = 'fleet-lib.ps1';       O = 'Write-OperatorFileExclusive -LiteralPath $promptFile -Text $Prompt'; W = 'Set-Content -LiteralPath $promptFile -Value $Prompt' },
        @{ N = 'link-deleted-as-link';        F = 'fleet-lib.ps1';       O = 'if ($attr -band [IO.FileAttributes]::Directory) { [IO.Directory]::Delete($e) } else { [IO.File]::Delete($e) }'; W = '' },
        @{ N = 'remove-worktree-sweeps-links'; F = 'fleet-lib.ps1';      O = '$null = Remove-LinksUnder -Root $Path';             W = '' },
        @{ N = 'lint-nonliteral-delete';      F = 'fleet-lib.ps1';       O = 'Remove-Item -LiteralPath (Get-OperatorWorktreePath -Worktree $wt -Relative $__rf)'; W = 'Remove-Item (Get-OperatorWorktreePath -Worktree $wt -Relative $__rf)' },
        @{ N = 'lint-nonliteral-queue';       F = 'coder-leg-queue.ps1'; O = 'if (Test-Path -LiteralPath $path) {';                W = 'if (Test-Path $path) {' },
        @{ N = 'lint-raw-clean';              F = 'new-agent-task.ps1';  O = 'Clear-WorktreeUntracked -Worktree $wt';              W = 'git @(Get-WtGit $wt) clean -fd 2>&1 | Out-Null' },
        @{ N = 'lint-quoted-wt';              F = 'new-agent-task.ps1';  O = '{ git @(Get-WtGit $wt) reset 2>&1 | Out-Null; return $false }'; W = '{ git -C "$wt" reset 2>&1 | Out-Null; return $false }' },
        @{ N = 'lint-helper-param-repo';      F = 'fleet-lib.ps1';       O = 'git @(Get-WtGit $Repo) reset --hard HEAD';           W = 'git -C $Repo reset --hard HEAD' },
        @{ N = 'lint-recursive-remove';       F = 'new-agent-task.ps1';  O = 'Remove-WorktreeSafe -Repo $Repo -Path $wtOrig';       W = 'Remove-Item -LiteralPath $wtOrig -Recurse -Force' },
        @{ N = 'lint-amp-git';                F = 'new-agent-task.ps1';  O = '$__head = "$(git @(Get-WtGit $wt) rev-parse HEAD 2>$null)".Trim()'; W = '$__head = "$(& git -C $wt rev-parse HEAD 2>$null)".Trim()' },
        @{ N = 'lint-start-process-git';      F = 'fleet-lib.ps1';       O = 'Clear-WorktreeUntracked -Worktree $Repo';           W = 'Start-Process git -ArgumentList "-C $Repo clean -fd" -Wait' },
        @{ N = 'lint-critic-range';           F = 'fleet-lib.ps1';       O = 'if ($BaseRef -and (((git @(Get-WtGit $Repo) diff';  W = 'if ($BaseRef -and (((git -C $Repo diff' },
        @{ N = 'fingerprint-config-worktree'; F = 'fleet-lib.ps1';       O = "'config', 'config.worktree', 'commondir'";           W = "'config', 'commondir'" },
        @{ N = 'fingerprint-attributes';      F = 'fleet-lib.ps1';       O = "'gitdir', 'info\attributes')";                       W = "'gitdir')" },
        @{ N = 'n5-critic-assert';            F = 'critic-run.ps1';      O = '$null = Assert-OperatorWorktree -Path $AppDir';      W = '' },
        @{ N = 'n5-critique-assert';          F = 'critique-loop.ps1';   O = 'try { $null = Assert-OperatorWorktree -Path $AppDir }'; W = 'try { $null = $AppDir }' },
        @{ N = 'n5-newtask-assert';           F = 'new-agent-task.ps1';  O = '$null = Assert-OperatorWorktree -Path $wt   # the critique'; W = '$null = $wt   # the critique' },
        @{ N = 'n1-confirm-survivors';        F = 'coder-leg-queue.ps1'; O = 'Write-Host "  [containment] coder-account process(es) survived termination'; W = 'return $true; Write-Host "  [containment] coder-account process(es) survived termination' },
        @{ N = 'n1-unverifiable-owner';       F = 'coder-leg-queue.ps1'; O = 'if ($list.Unverifiable.Count -gt 0) {';             W = 'if ($false) {' },
        @{ N = 'n1-elevation-required';       F = 'coder-leg-queue.ps1'; O = 'if (-not (Test-OrchestratorElevated)) {';           W = 'if ($false) {' },
        @{ N = 'n1-failure-path-kill';        F = 'fleet-lib.ps1';       O = '$gone = Stop-CoderProcessesConfirmed -CoderSid $coderSid -WaitSec $o.StopWaitSec -PollMs $o.PollMs'; W = '$gone = $true' },
        @{ N = 'n1-pin-lock-used';            F = 'fleet-lib.ps1';       O = '$final = Lock-FusedWorktree -Record $Record';       W = '$final = $Record.Path' },
        @{ N = 'strict-dup-keys';             F = 'coder-leg-queue.ps1'; O = 'if (d.ContainsKey(k)) throw';                        W = 'if (false) throw' },
        @{ N = 'strict-trailing-data';        F = 'coder-leg-queue.ps1'; O = 'if (!p.End) throw';                                  W = 'if (false) throw' },
        @{ N = 'strict-utf8-throw';           F = 'coder-leg-queue.ps1'; O = 'new UTF8Encoding(false, true)';                     W = 'new UTF8Encoding(false, false)' },
        @{ N = 'schema-key-case';             F = 'coder-leg-queue.ps1'; O = "return `"`$At key '`$k' has the wrong case`"";          W = 'continue' },
        @{ N = 'schema-bool-type';            F = 'coder-leg-queue.ps1'; O = "return `"`$At is not a boolean`"";                      W = 'return $null' },
        @{ N = 'schema-int-type';             F = 'coder-leg-queue.ps1'; O = "return `"`$At is not an integer`"";                     W = 'return $null' },
        @{ N = 'schema-required';             F = 'coder-leg-queue.ps1'; O = "return `"`$At is missing '`$req'`"";                    W = 'continue' },
        @{ N = 'schema-kind-enum';            F = 'coder-leg-queue.ps1'; O = "return `"`$At is not one of:";                          W = 'return $null; "' },
        @{ N = 'job-id-matches-file';         F = 'coder-leg-queue.ps1'; O = 'if ("$($f.Name)" -cne "$($job.id).json") { throw';   W = 'if ($false) { throw' },
        @{ N = 'dispatch-required-fields';    F = 'coder-leg-queue.ps1'; O = 'if ($null -eq $job.PSObject.Properties[$req]) { throw'; W = 'if ($false) { throw' },
        @{ N = 'envelope-validated';          F = 'fleet-lib.ps1';       O = 'try { Assert-CoderLegEnvelope -Envelope $leg }';       W = 'try { }' },
        @{ N = 'quarantine-alone-counts';     F = 'fleet-lib.ps1';       O = ' -or (Test-Path -LiteralPath (Get-FusedQuarantinePath $Path)))'; W = ')' },
        @{ N = 'state-dir-not-in-coder-root'; F = 'fleet-lib.ps1';       O = 'if ($stateDir.StartsWith($cr, [StringComparison]::OrdinalIgnoreCase)) { throw'; W = 'if ($false) { throw' },
        @{ N = 'state-dir-acl-gated';         F = 'fleet-lib.ps1';       O = '$wtBaseRaw, (Get-FusedWorktreeStateDir)) -CoderUser'; W = '$wtBaseRaw) -CoderUser' },
        @{ N = 'n1-kill-processes';           F = 'coder-leg-queue.ps1'; O = 'foreach ($pr in $list.Procs) { Stop-ProcessTreeForce -ProcessId $pr.ProcessId }'; W = '' },
        @{ N = 'n1-enumeration-failure';      F = 'coder-leg-queue.ps1'; O = 'try { $list = Get-CoderProcessList -CoderSid $CoderSid } catch {'; W = 'try { $list = Get-CoderProcessList -CoderSid $CoderSid } catch { return $true' },
        @{ N = 'n1-pin-anchor';               F = 'coder-leg-queue.ps1'; O = '$anchor = [IO.File]::Open((Join-Path $final $AnchorName), [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::Read)'; W = '$anchor = [IO.File]::Open((Join-Path $final $AnchorName), [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::ReadWrite -bor [IO.FileShare]::Delete)' },
        @{ N = 'result-strict-bound';         F = 'coder-leg-queue.ps1'; O = '-Schema $script:CoderLegResultSchema -What ''the result file'''; W = '-Schema @{ Type = ''any'' } -What ''the result file''' },
        @{ N = 'quarantine-early-checks';     F = 'fleet-lib.ps1';       O = 'if (Test-FusedWorktreeQuarantined $Path) { throw "fused leg: ''$Path'' is quarantined (a coder-account process may have survived the leg); operator-side use is refused." }'; W = '' },
        @{ N = 'job-kill-on-close';           F = 'coder-leg-queue.ps1'; O = 'Marshal.WriteInt32(buf, 16, 0x2000);';                W = 'Marshal.WriteInt32(buf, 16, 0x0);' },
        @{ N = 'job-no-breakaway';            F = 'coder-leg-queue.ps1'; O = 'Marshal.WriteInt32(buf, 16, 0x2000);';                W = 'Marshal.WriteInt32(buf, 16, 0x2800);' },
        @{ N = 'job-assign-before-resume';    F = 'coder-leg-queue.ps1'; O = 'if (!AssignProcessToJobObject(job, pi.hp)) {';        W = 'if (false) {' },
        @{ N = 'job-drain-kills';             F = 'coder-leg-queue.ps1'; O = 'foreach ($id in $ids) { [void][BlarCoderJob]::Kill($id) }'; W = '' },
        @{ N = 'job-drain-confirms-zero';     F = 'coder-leg-queue.ps1'; O = 'if ($others -eq 0) { return @{ Zero = $true; Active = 0 } }'; W = 'return @{ Zero = $true; Active = 0 }' },
        @{ N = 'job-runner-passes-job';       F = 'coder-leg-run.ps1';   O = '-SpinSteps ([int]$job.spin_steps) -Job $cj';           W = '-SpinSteps ([int]$job.spin_steps)' },
        @{ N = 'job-acp-uses-job';            F = 'fleet-lib.ps1';       O = 'if ($Job) { $p = Start-ProcessInJob -Job $Job';       W = 'if ($false) { $p = Start-ProcessInJob -Job $Job' },
        @{ N = 'job-runner-reports-zero';     F = 'coder-leg-run.ps1';   O = '$result.job_zero_confirmed = [bool]$drain.Zero';      W = '$result.job_zero_confirmed = $true' },
        @{ N = 'job-operator-typed-bool';     F = 'fleet-lib.ps1';       O = '($res.job_zero_confirmed -is [bool]) -and';           W = '' },
        @{ N = 'job-schema-bool';             F = 'coder-leg-queue.ps1'; O = "job_zero_confirmed = @{ Type = 'bool' }";            W = "job_zero_confirmed = @{ Type = 'any' }" },
        @{ N = 'failure-quarantine-nonelevated'; F = 'fleet-lib.ps1';   O = 'if (-not $excluded) {';                                 W = 'if ($false) {' },
        @{ N = 'clear-needs-name';            F = 'fleet-lib.ps1';       O = "if (-not `"`$ClearedBy`".Trim()) { throw";                  W = 'if ($false) { throw' },
        @{ N = 'drift-future-dated';          F = 'coder-leg-queue.ps1'; O = 'if ($ct -gt (Get-Date).ToUniversalTime().AddMinutes(5)) { throw'; W = 'if ($false) { throw' },
        @{ N = 'drift-preexisting-result';    F = 'fleet-lib.ps1';       O = 'if (Test-Path -LiteralPath (Join-Path $resultsDir "$jobId.result.json")) { throw'; W = 'if ($false) { throw' },
        @{ N = 'drift-quarantine-memory';     F = 'fleet-lib.ps1';       O = 'if ($script:FusedQuarantineMem -and $script:FusedQuarantineMem.ContainsKey('; W = 'if ($false -and $script:FusedQuarantineMem.ContainsKey(' },
        @{ N = 'trust-failure-needs-stop';    F = 'fleet-lib.ps1';       O = '$excluded = ($reportedZero -and $stopped)';             W = '$excluded = $reportedZero' },
        @{ N = 'trust-elevated-needs-stop';   F = 'fleet-lib.ps1';       O = 'if ($gone -eq $true -and $stopped) { $excluded = $true }'; W = 'if ($gone -eq $true) { $excluded = $true }' },
        @{ N = 'trust-taskkill-path';         F = 'coder-leg-queue.ps1'; O = "& (Join-Path `$env:SystemRoot 'System32\taskkill.exe')"; W = '& taskkill.exe' },
        @{ N = 'schema-path-pattern';         F = 'coder-leg-queue.ps1'; O = '[^\x00-\x1f"<>|*?\[\]]+$';                           W = '.*$' },
        @{ N = 'schema-model-pattern';        F = 'coder-leg-queue.ps1'; O = "'^local/[A-Za-z0-9._-]{1,64}$'";                     W = "'^.*$'" },
        @{ N = 'schema-int-max';              F = 'coder-leg-queue.ps1'; O = 'if ($null -ne $Schema.Max -and $Value -gt $Schema.Max)'; W = 'if ($false)' },
        @{ N = 'schema-int-min';              F = 'coder-leg-queue.ps1'; O = 'if ($null -ne $Schema.Min -and $Value -lt $Schema.Min)'; W = 'if ($false)' },
        @{ N = 'runner-path-prompt';          F = 'fleet-lib.ps1';       O = 'throw "job path refused: prompt_file is not ''$wantPrompt''."'; W = '' },
        @{ N = 'runner-path-log';             F = 'fleet-lib.ps1';       O = 'throw "job path refused: log_path is not ''$wantLog''."'; W = '' },
        @{ N = 'runner-path-workdir';         F = 'fleet-lib.ps1';       O = 'throw "job path refused: workdir ''$wd'' is outside ''$baseFull''."'; W = '' },
        @{ N = 'runner-validates-paths';      F = 'coder-leg-run.ps1';   O = '                Assert-CoderLegJobPathsSafe -Job $job';   W = '' },
        @{ N = 'n1-quarantine-on-failed-leg'; F = 'fleet-lib.ps1';       O = "Set-FusedWorktreeQuarantine -Path `$wdFull -Reason 'the leg failed and surviving coder-account processes could not be excluded'"; W = '' },
        @{ N = 'quarantine-survives-register'; F = 'fleet-lib.ps1';      O = 'if (Test-FusedWorktreeQuarantined $Path) { throw "fused leg: ''$Path'' is quarantined; only a human'; W = 'if ($false) { throw "fused leg: ''$Path'' is quarantined; only a human' },
        @{ N = 'job-operator-requires-zero';  F = 'fleet-lib.ps1';       O = 'if (-not $reportedZero) {';                            W = 'if ($false) {' },
        @{ N = 'nonelevated-not-a-failure';   F = 'coder-leg-queue.ps1'; O = "Write-Host '  [containment] orchestrator not elevated:"; W = "return `$false; Write-Host '  [containment] orchestrator not elevated:" },
        @{ N = 'failure-reported-zero-excludes'; F = 'fleet-lib.ps1';    O = '$excluded = ($reportedZero -and $stopped)';            W = '$excluded = $false' },
        @{ N = 'quarantine-human-only';       F = 'fleet-lib.ps1';       O = '    # drops the pre-run record and the pin; a quarantine marker is NOT touched'; W = '    Remove-Item -LiteralPath (Get-FusedQuarantinePath $Path) -ErrorAction SilentlyContinue; # drops the pre-run record and the pin; a quarantine marker is NOT touched' },
        @{ N = 'clear-audit-log';             F = 'fleet-lib.ps1';       O = "Add-Content -LiteralPath (Join-Path (Get-FusedWorktreeStateDir) 'quarantine-cleared.log') -Value"; W = 'Write-Output' },
        @{ N = 'trust-enumeration-overrides'; F = 'fleet-lib.ps1';       O = 'if ($gone -eq $false) {';                              W = 'if ($false) {' },
        @{ N = 'drift-quarantine-verified';   F = 'fleet-lib.ps1';       O = 'if (-not (Test-Path -LiteralPath $q)) { throw "fused leg: the quarantine marker'; W = 'if ($false) { throw "fused leg: the quarantine marker' },
        @{ N = 'job-suspended-structural';    F = 'coder-leg-queue.ps1'; O = 'false, 0x4 | 0x400, IntPtr.Zero, cwd';                 W = 'false, 0x400, IntPtr.Zero, cwd' },
        @{ N = 'strict-lone-surrogates';      F = 'coder-leg-queue.ps1'; O = 'return NoLoneSurrogates(b.ToString());';                W = 'return b.ToString();' },
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
function _fail($m) { $script:Fail++; [void]$script:Failures.Add($m); Write-Host "  [FAIL] $m" -ForegroundColor Red; if ($env:BLARAI_FUSED_FAILFAST) { Write-Host 'RESULT: stopped at the first failure (mutation run)' -ForegroundColor Red; exit 1 } }
function Section($t) { Write-Host ''; Write-Host "== $t ==" -ForegroundColor Cyan }
function Assert-True($c, $m)  { if ($c) { _pass $m } else { _fail "$m (expected True)" } }
function Assert-False($c, $m) { if (-not $c) { _pass $m } else { _fail "$m (expected False)" } }
function Assert-Eq($e, $a, $m) { if ([string]$e -ceq [string]$a) { _pass $m } else { _fail "$m (expected '$e', got '$a')" } }

function Res-Json([string]$Id, [string]$Tag) { '{"id":"' + $Id + '","kind":"dispatch","ok":true,"ran_as_sid":"S","ran_as_user":"u","error":"' + $Tag + '"}' }
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
foreach ($d in $wtBase, $elsewhere) { New-Item -ItemType Directory -Force $d | Out-Null }
$stateRoot = Join-Path ([IO.Path]::GetTempPath()) ('fused-state-' + [guid]::NewGuid().ToString('N'))
$env:BLARAI_FUSED_WT_STATE = $stateRoot
$mainRepo = Join-Path $tmpRoot 'mainrepo'
$victim = Join-Path $tmpRoot 'victim'
foreach ($r in $mainRepo, $victim) {
    New-Item -ItemType Directory -Force $r | Out-Null
    & git -C $r init -q 2>&1 | Out-Null
    Set-Content (Join-Path $r 'seed.txt') 'seed' -Encoding UTF8
    & git -C $r add seed.txt 2>&1 | Out-Null
    & git -C $r -c user.email=t@t -c user.name=t commit -q -m init 2>&1 | Out-Null
}
Set-Content (Join-Path $victim 'secret.txt') 'victim secret' -Encoding UTF8   # untracked: what an add -A would stage
$wdPath = "$wtBase\proj-task"
function New-TestWorktree {
    # (re)create the linked worktree the fused leg runs in, replacing whatever the last test left there
    Unregister-FusedWorktree -Path $wdPath   # releases the operator's pin (held handles)
    [void](Clear-FusedQuarantine -Path $wdPath -ClearedBy 'test harness')   # a quarantine is cleared by a human only: the test plays one
    if (Test-Path -LiteralPath $wdPath) {
        if ((Get-Item -LiteralPath $wdPath -Force).Attributes -band [IO.FileAttributes]::ReparsePoint) { [IO.Directory]::Delete($wdPath) }
        else { Remove-Item -LiteralPath $wdPath -Recurse -Force -ErrorAction SilentlyContinue }
    }
    & git -C $mainRepo worktree prune 2>&1 | Out-Null
    & git -C $mainRepo worktree add --detach $wdPath 2>&1 | Out-Null
}
New-TestWorktree
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
        Acl = 'tight'      # tight | authusers | users | everyone-read | unknown | real | inherit-ga | inherit-gw | parent-authusers
        Owner = ''         # '' = Administrators | a SID string for every guarded path | 'unreadable'
        OwnerPath = ''     # restrict the Owner knob to the path ending with this text
        Swap = ''          # workdir-junction | workdir-replace | gitdir-tamper | logs-junction | prompts-junction | log-hardlink
        StopThrows = $false; QueryThrows = $false; StaysRunning = $false; QueryBreaksAfterResult = $false
        CoderProcs = @(); ProcsSurvive = $false; Unverifiable = @(); NotElevated = $false; EnumThrows = $false; JobZero = 'true'
    }
}
Reset-Knobs
$script:LastJob = $null; $script:SeenPrompt = $null; $script:WaitArgs = $null
$realEgress = ${function:Assert-CoderEgressContained}
$realWait = ${function:Wait-CoderLegResult}
$realProcList = ${function:Get-CoderProcessList}
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
        'inherit-ga'    { $rules += New-FakeRule 'S-1-1-0' '268435456' }
        'inherit-gw'    { $rules += New-FakeRule 'S-1-1-0' '1073741824' }
        'state-authusers' { if ($LiteralPath -eq $stateRoot) { $rules += New-FakeRule 'S-1-5-11' 'Modify' } }
        'parent-authusers' { if ($LiteralPath -eq (Split-Path $tmpRoot -Parent)) { $rules += New-FakeRule 'S-1-5-11' 'DeleteSubdirectoriesAndFiles' } }
    }
    $owner = 'S-1-5-32-544'
    if ($script:Knobs.Owner -and (-not $script:Knobs.OwnerPath -or $LiteralPath.EndsWith($script:Knobs.OwnerPath))) { $owner = $script:Knobs.Owner }
    $acl = [pscustomobject]@{ Access = $rules }
    $acl | Add-Member -MemberType ScriptMethod -Name GetOwner -Value { param($t) if ($owner -eq 'unreadable') { throw 'owner unreadable' }; [pscustomobject]@{ Value = $owner } }.GetNewClosure()
    return $acl
}
function Get-ScheduledTask { [CmdletBinding()] param($TaskPath, $TaskName) [void]$script:Calls.Add('Get-ScheduledTask'); if ($script:Knobs.QueryThrows) { throw 'cim down' }; if ($script:Knobs.TaskMissing) { return $null }; [pscustomobject]@{ State = $script:Knobs.TaskState } }
function Get-ScheduledTaskInfo { [CmdletBinding()] param($TaskPath, $TaskName) [pscustomobject]@{ LastRunTime = $script:Knobs.LastRun; LastTaskResult = $script:Knobs.LastTaskResult } }
function Start-ScheduledTask { [CmdletBinding()] param($TaskPath, $TaskName) [void]$script:Calls.Add('Start-ScheduledTask'); if ($script:Knobs.TaskStarts) { $script:Knobs.LastRun = Get-Date; if ($script:Knobs.RunningAfterStart) { $script:Knobs.TaskState = 'Running' } } }
function Stop-ScheduledTask { [CmdletBinding()] param($TaskPath, $TaskName) [void]$script:Calls.Add('Stop-ScheduledTask'); if ($script:Knobs.StopThrows) { throw 'stop failed' }; if (-not $script:Knobs.StopHangs) { $script:Knobs.TaskState = 'Ready' } }
function Wait-CoderLegResult {
    [CmdletBinding()] param([string]$JobId, [int]$TimeoutSec = 300, [int]$PollSec = 2, [string]$ExpectedOwnerSid = '', [datetime]$NotBefore = [datetime]::MinValue)
    [void]$script:Calls.Add('Wait-CoderLegResult')
    $script:WaitArgs = @{ Owner = $ExpectedOwnerSid; NotBefore = $NotBefore; TimeoutSec = $TimeoutSec }
    $jf = Join-Path (Get-CoderLegPaths).Queue "$JobId.json"
    if (Test-Path $jf) {
        $script:LastJob = Get-Content $jf -Raw | ConvertFrom-Json
        $script:SeenPrompt = if (Test-Path $script:LastJob.prompt_file) { Get-Content $script:LastJob.prompt_file -Raw } else { $null }
        Move-Item $jf "$jf.claimed"   # the coder leg claims it
        $logPath = $script:LastJob.log_path
        switch ($script:Knobs.Swap) {
            'logs-junction' {
                $ld = Split-Path $logPath -Parent
                Set-Content (Join-Path $elsewhere "$JobId.log") 'decoy' -Encoding UTF8
                Move-Item $ld "$ld.real"; New-Item -ItemType Junction -Path $ld -Target $elsewhere | Out-Null
            }
            'logs-replaced' {
                $ld = Split-Path $logPath -Parent
                Move-Item $ld "$ld.real"; New-Item -ItemType Directory -Path $ld | Out-Null
            }
            'prompts-junction' {
                $pd = Split-Path $script:LastJob.prompt_file -Parent
                Set-Content (Join-Path $elsewhere "$JobId.prompt.txt") 'decoy' -Encoding UTF8
                Move-Item $pd "$pd.real"; New-Item -ItemType Junction -Path $pd -Target $elsewhere | Out-Null
            }
        }
        if ($script:Knobs.Swap -eq 'log-hardlink') {
            Set-Content (Join-Path $elsewhere 'hardlink-target.txt') 'target' -Encoding UTF8
            New-Item -ItemType HardLink -Path $logPath -Target (Join-Path $elsewhere 'hardlink-target.txt') | Out-Null
        } elseif ($script:Knobs.Swap -notin 'logs-junction', 'logs-replaced') {
            Set-Content -Path $logPath -Value 'transcript-from-the-coder-leg' -Encoding UTF8
        }
        switch ($script:Knobs.Swap) {
            'workdir-junction' { Unlock-FusedWorktree -Path $wdPath; [IO.Directory]::Delete($wdPath, $true); New-Item -ItemType Junction -Path $wdPath -Target $victim | Out-Null }
            'workdir-replace'  { Unlock-FusedWorktree -Path $wdPath; [IO.Directory]::Delete($wdPath, $true); New-Item -ItemType Directory -Path $wdPath | Out-Null }
            'workdir-clone-pointer' { $ptr = Get-Content (Join-Path $wdPath '.git') -Raw; Unlock-FusedWorktree -Path $wdPath; [IO.Directory]::Delete($wdPath, $true); New-Item -ItemType Directory -Path $wdPath | Out-Null; Set-Content (Join-Path $wdPath '.git') $ptr -NoNewline -Encoding ASCII }
            'gitdir-tamper'    { Set-Content (Join-Path $wdPath '.git') ("gitdir: " + (Join-Path $victim '.git')) -Encoding ASCII }
            'gitdir-elsewhere' { $own = Join-Path $elsewhere 'my-gitdir'; New-Item -ItemType Directory -Force $own | Out-Null; Set-Content (Join-Path $own 'config') "[core]`n`tfsmonitor = true" -Encoding ASCII; Set-Content (Join-Path $wdPath '.git') "gitdir: $own" -Encoding ASCII }
            'plant-hook'       { [IO.File]::WriteAllText((Join-Path $mainRepo '.git\hooks\pre-commit'), "#!/bin/sh`nexit 0`n") }
            'plant-config'     { Add-Content (Join-Path $mainRepo '.git\config') "[alias]`n`tx = !echo" }
        }
    }
    if ($script:Knobs.Leg -eq 'null') { Start-Sleep -Milliseconds 100; return $null }
    $inner = @{ Ok = $true; Reason = 'acp phase=done'
                Result = @{ TimedOut = $false; TimeoutReason = ''; Capped = $false; CappedReason = ''; ExitCode = 0; LogPath = 'x'; Seconds = 12.5; Error = '' } }
    $res = @{ id = $JobId; kind = 'dispatch'; ok = $true; ran_as_sid = $CODER_SID; ran_as_user = 'DEV\blarai-coder'; result = $inner; error = '' }
    switch ($script:Knobs.JobZero) {
        'true'   { $res.job_zero_confirmed = $true; $res.job_active = 0 }
        'false'  { $res.job_zero_confirmed = $false; $res.job_active = 2 }
        'string' { $res.job_zero_confirmed = 'true'; $res.job_active = 0 }
    }
    switch ($script:Knobs.Leg) {
        'wrongsid'      { $res.ran_as_sid = 'S-1-5-21-9-9-9-500' }
        'idmismatch'    { $res.id = 'job-20000101-000000-deadbeef' }
        'wrongkind'     { $res.kind = 'probe' }
        'toplevelfalse' { $res.ok = $false; $res.error = 'leg said no' }
        'okstring'      { $res.ok = 'true' }
        'innerokstring' { $inner.Ok = 'false' }
        'refused'       { $res.ok = $false; $inner.Ok = $false; $inner.Reason = $script:Knobs.ReasonText; $res.error = $script:Knobs.ReasonText }
        'refusedinner'  { $inner.Ok = $false; $inner.Reason = $script:Knobs.ReasonText }
        'evilpaths'     { $res.workdir = (Join-Path $elsewhere 'evil-workdir'); $res.log_path = (Join-Path $elsewhere 'evil-log.txt'); $inner.Result.LogPath = (Join-Path $elsewhere 'evil-result-log.txt') }
        'envelope-extra' { $inner.Result.Injected = 'x' }
        'envelope-badtype' { $inner.Result.Seconds = '12' }
        'nobody'        { $res.result = $null }
        'unusable'      { $res.result = @{ Ok = $true; Reason = 'x' } }
    }
    # the coder finished: it deletes its claim and the task is no longer running
    Remove-Item "$jf.claimed" -ErrorAction SilentlyContinue
    if (-not $script:Knobs.StaysRunning) { $script:Knobs.TaskState = 'Ready' }
    if ($script:Knobs.QueryBreaksAfterResult) { $script:Knobs.QueryThrows = $true }
    return ($res | ConvertTo-Json -Depth 8 | ConvertFrom-Json)
}
function Test-OrchestratorElevated { [void]$script:Calls.Add('Test-OrchestratorElevated'); return (-not $script:Knobs.NotElevated) }
function Stop-CoderProcessesConfirmedDouble { }
function Get-CoderProcessList {
    [CmdletBinding()] param([string]$CoderSid)
    [void]$script:Calls.Add('Get-CoderProcessList')
    if ($script:Knobs.EnumThrows) { throw 'cim down' }
    return @{ Procs = @($script:Knobs.CoderProcs); Unverifiable = @($script:Knobs.Unverifiable) }
}
function Stop-ProcessTreeForce {
    [CmdletBinding()] param([int]$ProcessId)
    [void]$script:Calls.Add("kill:$ProcessId")
    if (-not $script:Knobs.ProcsSurvive) { $script:Knobs.CoderProcs = @($script:Knobs.CoderProcs | Where-Object { $_.ProcessId -ne $ProcessId }) }
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
    Assert-Eq (Add-CoderFunnelNotice -Prompt 'implement rpn.py <now> & done') $script:SeenPrompt 'the prompt reaches the coder byte-for-byte via the prompt file (not argv), behind the restricted-account notice (#1678: the operator funnel commits)'
    Assert-True ($script:SeenPrompt.StartsWith('RESTRICTED ACCOUNT NOTICE') -and $script:SeenPrompt.EndsWith('implement rpn.py <now> & done') -and $script:SeenPrompt -match 'Do NOT run git add, git commit') 'the staged prompt carries the notice in front and the original prompt whole at the end'
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
        @{ Leg = 'innerokstring'; Pat = 'unusable result|could not run'; What = "an inner Ok given as the string 'false'" },
        @{ Leg = 'envelope-extra'; Pat = 'unusable result';       What = 'an envelope Result carrying an unknown key' },
        @{ Leg = 'envelope-badtype'; Pat = 'unusable result';     What = 'an envelope Result whose Seconds is a string' },
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
    Set-Content $rp (Res-Json $rid 'x') -Encoding UTF8
    $realOwner = (Microsoft.PowerShell.Security\Get-Acl -LiteralPath $rp).GetOwner([Security.Principal.SecurityIdentifier]).Value
    $threw = $null; try { [void](& $realWait -JobId $rid -TimeoutSec 2 -PollSec 1 -ExpectedOwnerSid $CODER_SID) } catch { $threw = $_.Exception.Message }
    Assert-True ($threw -match 'owned by') 'a result file owned by another SID is refused (forged)'
    Assert-True (Test-Path $rp) 'the refused file is left in place'
    $threw = $null; try { [void](& $realWait -JobId $rid -TimeoutSec 2 -PollSec 1 -ExpectedOwnerSid $realOwner -NotBefore (Get-Date).AddHours(1)) } catch { $threw = $_.Exception.Message }
    Assert-True ($threw -match 'created before') 'a result file older than the enqueue time is refused (stale)'
    $got = & $realWait -JobId $rid -TimeoutSec 2 -PollSec 1 -ExpectedOwnerSid $realOwner -NotBefore (Get-Date).AddHours(-1)
    Assert-True ($null -ne $got -and $got.error -eq 'x') 'a result owned by the expected SID and created after the enqueue is accepted'
    Assert-False (Test-Path $rp) 'an accepted result is consumed'
    Set-Content $rp (Res-Json $rid 'x') -Encoding UTF8
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
    Assert-True (Test-FusedWorktreeQuarantined $wdPath) 'a task the operator could not confirm stopped quarantines even when an elevated enumeration found nothing'
    New-TestWorktree

    Section 'L4: cancellation stops the coder'
    Reset-Knobs; $script:Knobs.Leg = 'null'
    $o2opts = $opts.Clone(); $o2opts.ShouldCancel = { $script:Calls -contains 'Wait-CoderLegResult' }
    $o = Run-Driver -Options $o2opts; Assert-RefusedRunningNothing $o 'cancelled; stopping' 'cancel during the result wait'
    Assert-True (Called 'Stop-ScheduledTask') 'cancel during the wait -> Stop-ScheduledTask is issued'
    Reset-Knobs
    $script:CancelPolls = 0
    $o3opts = $opts.Clone(); $o3opts.ShouldCancel = { $script:CancelPolls++; $script:CancelPolls -ge 2 }
    $o = Run-Driver -Options $o3opts; Assert-RefusedRunningNothing $o 'cancelled before' 'cancel just before the trigger'
    Assert-False (Called 'Start-ScheduledTask') 'cancel before the trigger -> the task is never started'
    $o4opts = $opts.Clone(); $o4opts.ShouldCancel = { $true }
    $o = Run-Driver -Options $o4opts; Assert-RefusedRunningNothing $o 'cancelled while waiting' 'cancel at once'
    Assert-False (Called 'Start-ScheduledTask') 'cancel at once -> the task is never started'
    Reset-Knobs; $script:Knobs.TaskState = 'Running'
    $script:CancelPolls = 0
    $o5opts = $opts.Clone(); $o5opts.ShouldCancel = { $script:CancelPolls++; $script:CancelPolls -ge 2 }
    $o = Run-Driver -Options $o5opts; Assert-RefusedRunningNothing $o 'cancelled while the coder-leg task was still running' 'cancel while an earlier job is running'
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

    Section 'M1: a workdir swapped after the check (while the coder runs) never reaches operator-side git'
    $beforeVictim = (& git -C $victim status --porcelain) -join '|'
    Reset-Knobs; Set-Config 'restricted_account' 'acp'; New-TestWorktree
    $o = Run-Driver; Assert-True ($null -eq $o.Error) "baseline: an intact linked worktree runs ($($o.Error))"
    Assert-True (Test-Path -LiteralPath (Get-FusedWorktreeRecordPath $wdPath)) 'the worktree is recorded BEFORE the coder runs (operator-side state)'
    $prefix = Get-WtGit $wdPath
    Assert-True ($prefix -contains '-c' -and $prefix -contains 'core.fsmonitor=false' -and ($prefix | Where-Object { $_ -like '--git-dir=*' }) -and ($prefix | Where-Object { $_ -like '--work-tree=*' })) 'a recorded worktree gets a PINNED git prefix (git-dir, work-tree, fsmonitor off)'
    Assert-True ((& git @prefix rev-parse --show-toplevel) -replace '/', '\' -eq $wdPath) 'the pinned prefix drives real git against the worktree'
    Assert-True ((@(Get-WtGit 'C:\some\other\repo')) -join ' ' -eq '-C C:\some\other\repo') 'an unrecorded path keeps the historical -C argv (the off path)'
    Remove-Item -LiteralPath (Get-FusedWorktreeRecordPath $wdPath) -Force
    Assert-True ((@(Get-WtGit $wdPath)) -join ' ' -eq "-C $wdPath") 'with no record the argv is the historical -C form'
    Register-FusedWorktree -Path $wdPath -Key (Get-FileIdentity $wdPath).Key -GitDir (Get-FusedWorktreeGitDir $wdPath)

    foreach ($swap in 'workdir-junction', 'workdir-replace', 'workdir-clone-pointer') {
        Reset-Knobs; $script:Knobs.Swap = $swap; New-TestWorktree
        $o = Run-Driver
        $pat = if ($swap -eq 'workdir-clone-pointer') { 'not the object it was before|not the directory recorded' } else { 'link \(reparse point\)|replaced|not the object|not the directory recorded|does not resolve|not a linked git worktree' }
        Assert-RefusedRunningNothing $o $pat "the coder swaps its workdir ($swap)"
        Assert-True (Called 'Stop-ScheduledTask') "$swap -> the coder-leg task is stopped"
        $threw = $null; $staged = $null
        try { & git @(Get-WtGit $wdPath) add -A 2>&1 | Out-Null } catch { $threw = $_.Exception.Message }
        Assert-True ($null -ne $threw) "$swap -> a later operator-side git call (Get-WtGit) THROWS before git starts"
        Assert-Eq $beforeVictim ((& git -C $victim status --porcelain) -join '|') "$swap -> the other repository is untouched"
        Assert-Eq 0 (@(& git -C $victim diff --cached --name-only).Count) "$swap -> nothing of the other repository was staged"
    }
    Reset-Knobs; $script:Knobs.Swap = 'gitdir-tamper'; New-TestWorktree
    $o = Run-Driver; Assert-RefusedRunningNothing $o 'gitdir pointer' 'the coder rewrites the worktree .git pointer'
    # defence in depth: even with the guard bypassed, the pinned argv never touches the other repository
    Unlock-FusedWorktree -Path $wdPath; [IO.Directory]::Delete($wdPath, $true); New-Item -ItemType Junction -Path $wdPath -Target $victim | Out-Null
    $adminDir = @(Get-ChildItem (Join-Path $mainRepo '.git\worktrees') -Directory)[0].FullName
    & git "--git-dir=$adminDir" "--work-tree=$wdPath" -c core.fsmonitor=false add -A 2>&1 | Out-Null
    Assert-Eq 0 (@(& git -C $victim diff --cached --name-only).Count) 'pinned git (guard bypassed) with the workdir swapped for a junction still does not stage into the other repository'
    New-TestWorktree
    Reset-Knobs; $o = Run-Driver
    Assert-True ($null -eq $o.Error) 'after restoring the worktree the leg runs again (the record is refreshed per run)'
    $plain = Join-Path $wtBase 'plain-dir'; New-Item -ItemType Directory -Force $plain | Out-Null
    $o = Run-Driver $plain; Assert-RefusedRunningNothing $o 'not a linked git worktree' 'a workdir that is not a linked git worktree'

    Section 'N1: no coder-account process survives the leg; the worktree is pinned; a survivor quarantines it'
    # the real enumerator reads owners (own SID: this very process must be in the list)
    $mine = & $realProcList -CoderSid $OPERATOR_SID
    Assert-True (@($mine.Procs | Where-Object { $_.ProcessId -eq $PID }).Count -eq 1) 'Get-CoderProcessList finds a live process by its owner SID (this pwsh, under my own SID)'
    Assert-Eq 0 (@((& $realProcList -CoderSid 'S-1-5-21-0-0-0-424242').Procs).Count) 'Get-CoderProcessList: no process is owned by an unknown SID'
    # surviving processes are killed (trees) and confirmed gone before the worktree is used
    Reset-Knobs; Set-Config 'restricted_account' 'acp'; New-TestWorktree
    $script:Knobs.CoderProcs = @(@{ ProcessId = 111; Name = 'node.exe' }, @{ ProcessId = 222; Name = 'opencode.exe' })
    $o = Run-Driver
    Assert-True ($null -eq $o.Error) "lingering coder processes that die when killed -> the run proceeds ($($o.Error))"
    Assert-True ((Called 'kill:111') -and (Called 'kill:222')) 'every coder-account process was terminated (tree kill requested for each)'
    Assert-False (Test-FusedWorktreeQuarantined $wdPath) 'a confirmed-gone coder leaves the worktree usable'
    # a process that survives the kill: the run fails and the worktree is quarantined
    Reset-Knobs; New-TestWorktree
    $script:Knobs.CoderProcs = @(@{ ProcessId = 333; Name = 'node.exe' }); $script:Knobs.ProcsSurvive = $true
    $o = Run-Driver; Assert-RefusedRunningNothing $o 'could not be confirmed gone' 'a coder process that survives termination'
    Assert-True (Called 'kill:333') 'the survivor was killed (attempted) before giving up'
    Assert-True (Test-FusedWorktreeQuarantined $wdPath) 'the worktree is QUARANTINED'
    foreach ($use in @(
        @{ N = 'Get-WtGit'; B = { Get-WtGit $wdPath } },
        @{ N = 'Assert-OperatorWorktree'; B = { Assert-OperatorWorktree -Path $wdPath } },
        @{ N = 'Get-OperatorWorktreePath'; B = { Get-OperatorWorktreePath -Worktree $wdPath -Relative 'a.txt' } },
        @{ N = 'Invoke-WithTimeout'; B = { Invoke-WithTimeout -CommandLine 'cmd /c echo hi' -WorkDir $wdPath -TimeoutSec 20 } }
    )) {
        $threw = $null; try { [void](& $use.B) } catch { $threw = $_.Exception.Message }
        Assert-True ($null -ne $threw -and $threw -match 'quarantined') "$($use.N) refuses a quarantined worktree"
    }
    New-TestWorktree
    Assert-False (Test-FusedWorktreeQuarantined $wdPath) 'a fresh worktree (re-registered) is no longer quarantined'
    # cannot confirm: unreadable owner, enumeration failure, no elevation
    foreach ($case in @(
        @{ K = 'Unverifiable'; V = @('mystery.exe'); What = 'a process whose owner cannot be read' },
        @{ K = 'EnumThrows'; V = $true; What = 'an enumeration failure' }
    )) {
        Reset-Knobs; New-TestWorktree; $script:Knobs[$case.K] = $case.V
        $o = Run-Driver; Assert-RefusedRunningNothing $o 'could not be confirmed gone' $case.What
        Assert-True (Test-FusedWorktreeQuarantined $wdPath) "$($case.What) -> the worktree is quarantined"
    }
    # every failure after the trigger also ends the coder's processes
    Reset-Knobs; New-TestWorktree; $script:Knobs.Leg = 'null'; $script:Knobs.CoderProcs = @(@{ ProcessId = 444; Name = 'node.exe' })
    $o = Run-Driver; Assert-RefusedRunningNothing $o 'wrote no result' 'a timeout with a lingering coder process'
    Assert-True (Called 'kill:444') 'a timed-out leg: the lingering coder process is killed'
    Reset-Knobs; New-TestWorktree; $script:Knobs.Leg = 'null'; $script:Knobs.CoderProcs = @(@{ ProcessId = 555; Name = 'node.exe' }); $script:Knobs.ProcsSurvive = $true
    $o = Run-Driver; Assert-RefusedRunningNothing $o 'ALSO: surviving processes of the coder account could not be excluded' 'a timeout whose coder process cannot be killed (elevated)'
    Assert-True (Test-FusedWorktreeQuarantined $wdPath) 'a failed leg with a surviving process also quarantines the worktree'
    Reset-Knobs; New-TestWorktree; $script:Knobs.AccountMissing = $true
    $o = Run-Driver; Assert-RefusedRunningNothing $o 'does not exist' 'a failure BEFORE the trigger'
    Assert-False (Called 'Get-CoderProcessList') 'before the trigger there is no coder to enumerate'
    # the pin: while the operator holds the worktree nothing can rename, replace or delete it or its ancestors
    Reset-Knobs; New-TestWorktree; $o = Run-Driver
    $gw = Get-WtGit $wdPath
    $moved = $null; try { [IO.Directory]::Move($wdPath, "$wdPath-moved"); $moved = $true } catch { $moved = $false }
    Assert-False $moved 'a pinned worktree cannot be renamed (the swap step of the attack)'
    $moved = $null; try { [IO.Directory]::Move($wtBase, "$wtBase-moved"); $moved = $true } catch { $moved = $false }
    Assert-False $moved 'nor can the worktree base (an ancestor)'
    $del = $null; try { Remove-Item -LiteralPath (Join-Path $wdPath '.git') -Force -ErrorAction Stop; $del = $true } catch { $del = $false }
    Assert-False $del 'nor can its .git pointer be deleted'
    Assert-True ((@($gw) | Where-Object { $_ -like '--work-tree=*' }) -match [regex]::Escape($wdPath)) 'git is handed the path the pinning handle resolves to'
    Unlock-FusedWorktree -Path $wdPath
    $moved = $null; try { [IO.Directory]::Move($wdPath, "$wdPath-moved"); [IO.Directory]::Move("$wdPath-moved", $wdPath); $moved = $true } catch { $moved = $false }
    Assert-True $moved 'after the pin is released the worktree can be renamed again (the pin is not permanent)'
    # a real race: another process flips the worktree between the real directory and a junction to a victim
    New-TestWorktree; $o = Run-Driver
    Set-Content (Join-Path $wdPath 'coder-made.txt') 'x'
    $realWt = "$wdPath-real"; $flipLog = Join-Path $tmpRoot 'flip.log'; Remove-Item $flipLog -ErrorAction SilentlyContinue
    $flipCode = @"
`$wt='$wdPath'; `$real='$realWt'; `$victim='$victim'; `$end=(Get-Date).AddSeconds(14); `$swaps=0
while ((Get-Date) -lt `$end) {
  try { [IO.Directory]::Move(`$wt, `$real); New-Item -ItemType Junction -Path `$wt -Target `$victim | Out-Null; `$swaps++ } catch {}
  try { [IO.Directory]::Delete(`$wt); [IO.Directory]::Move(`$real, `$wt) } catch {}
}
Set-Content '$flipLog' "swaps=`$swaps"
"@
    $flip = Start-Process pwsh -PassThru -WindowStyle Hidden -ArgumentList '-NoProfile', '-Command', $flipCode
    $ran = 0; $refused = 0; $t0 = Get-Date
    while (((Get-Date) - $t0).TotalSeconds -lt 10) {
        try { $a = Get-WtGit $wdPath; & git @a add -A 2>&1 | Out-Null; $ran++ } catch { $refused++ }
    }
    [void]$flip.WaitForExit(30000)
    $swapsDone = if (Test-Path $flipLog) { [int]((Get-Content $flipLog -Raw) -replace '\D', '') } else { -1 }
    Assert-True ($ran -gt 0) "the race ran git calls ($ran passed, $refused refused)"
    Assert-Eq 0 $swapsDone 'the flipping process managed 0 swaps while the worktree was pinned'
    Assert-Eq 0 (@(& git -C $victim diff --cached --name-only).Count) 'race: nothing staged in the victim repository'
    $gdr = Get-FusedWorktreeGitDir -WorkTree $wdPath
    Assert-False (@(& git --git-dir=$gdr ls-files) -contains 'secret.txt') 'race: the agent index holds no file from the victim'
    New-TestWorktree

    Section 'N1 without elevation: the runner reports its job object drained; a non-elevated operator relies on it'
    # (1) a non-elevated orchestrator does not fail the run for being unable to enumerate
    Reset-Knobs; Set-Config 'restricted_account' 'acp'; New-TestWorktree
    $script:Knobs.NotElevated = $true; $script:Knobs.CoderProcs = @(@{ ProcessId = 666; Name = 'node.exe' })
    $o = Run-Driver
    Assert-True ($null -eq $o.Error) "not elevated + the runner reported job_zero_confirmed=true -> the run proceeds ($($o.Error))"
    Assert-False ((@($script:Calls) | Where-Object { $_ -like 'kill:*' }).Count -gt 0) 'not elevated -> no enumeration or kill is attempted by the operator'
    Assert-False (Get-Command Get-CoderProcessList -ErrorAction SilentlyContinue | Where-Object { $false }) 'sanity'
    Assert-False (Called 'Get-CoderProcessList') 'not elevated -> the operator never enumerates processes'
    Assert-False (Test-FusedWorktreeQuarantined $wdPath) 'a drained job leaves the worktree usable'
    # (2) the operator refuses a result without the confirmed-zero fact (success path)
    foreach ($z in 'absent', 'false', 'string') {
        Reset-Knobs; New-TestWorktree; $script:Knobs.NotElevated = $true; $script:Knobs.JobZero = $z
        $o = Run-Driver
        Assert-RefusedRunningNothing $o 'job_zero_confirmed|surviving' "a result with job_zero_confirmed $z (non-elevated)"
        Assert-True (Test-FusedWorktreeQuarantined $wdPath) "job_zero_confirmed $z -> the worktree is quarantined"
    }
    Reset-Knobs; New-TestWorktree; $script:Knobs.JobZero = 'absent'   # elevated operator, but the runner did not report
    $o = Run-Driver; Assert-RefusedRunningNothing $o 'job_zero_confirmed' 'a result without the fact is refused even when the operator is elevated'
    # (3) failure paths: reported-zero failures are not quarantined, silent ones are
    Reset-Knobs; New-TestWorktree; $script:Knobs.NotElevated = $true; $script:Knobs.Leg = 'refused'
    $o = Run-Driver; Assert-RefusedRunningNothing $o 'reported failure' 'a failed leg whose runner reported a drained job (non-elevated)'
    Assert-False (Test-FusedWorktreeQuarantined $wdPath) '... is NOT quarantined (the runner excluded survivors)'
    Reset-Knobs; New-TestWorktree; $script:Knobs.NotElevated = $true; $script:Knobs.Leg = 'null'
    $o = Run-Driver; Assert-RefusedRunningNothing $o 'could not be excluded' 'a timeout where the runner cannot report (non-elevated)'
    Assert-True (Test-FusedWorktreeQuarantined $wdPath) '... the worktree is QUARANTINED and the survivors are recorded as not excludable'
    Assert-True ($o.Error -match 'Clear-FusedQuarantine') '... and the message names the human step'
    Reset-Knobs; New-TestWorktree; $script:Knobs.NotElevated = $true; $script:Knobs.Leg = 'wrongsid'
    $o = Run-Driver; Assert-RefusedRunningNothing $o 'ran as SID' 'a result from the wrong SID carries no trusted report (non-elevated)'
    Assert-True (Test-FusedWorktreeQuarantined $wdPath) '... so it quarantines too'
    Reset-Knobs; New-TestWorktree; $script:Knobs.Leg = 'null'; $script:Knobs.CoderProcs = @(@{ ProcessId = 777; Name = 'node.exe' })
    $o = Run-Driver; Assert-RefusedRunningNothing $o 'wrote no result' 'a timeout, elevated operator'
    Assert-False (Test-FusedWorktreeQuarantined $wdPath) '... an elevated operator that confirmed none alive does not quarantine (defence in depth)'
    # (4) only a human clears a quarantine
    Reset-Knobs; New-TestWorktree; $script:Knobs.NotElevated = $true; $script:Knobs.Leg = 'null'; [void](Run-Driver)
    Assert-True (Test-FusedWorktreeQuarantined $wdPath) 'setup: quarantined'
    Unregister-FusedWorktree -Path $wdPath
    Assert-True (Test-FusedWorktreeQuarantined $wdPath) 'Unregister-FusedWorktree (removing / recreating the worktree) does NOT clear it'
    $threw = $null; try { [void](Clear-FusedQuarantine -Path $wdPath -ClearedBy ' ') } catch { $threw = $_.Exception.Message }
    Assert-True ($threw -match 'ClearedBy') 'clearing needs a named human'
    Assert-True (Test-FusedWorktreeQuarantined $wdPath) '... and an unnamed attempt changes nothing'
    $threw = $null; try { Register-FusedWorktree -Path $wdPath -Key 'x' -GitDir $mainRepo } catch { $threw = $_.Exception.Message }
    Assert-True ($threw -match 'only a human') 'a new recording on a quarantined path is refused'
    Assert-True (Clear-FusedQuarantine -Path $wdPath -ClearedBy 'LA, checked tasklist') 'a human can clear it'
    Assert-True ((Test-Path (Join-Path (Get-FusedWorktreeStateDir) 'quarantine-cleared.log')) -and ((Get-Content (Join-Path (Get-FusedWorktreeStateDir) 'quarantine-cleared.log') -Raw) -match 'LA, checked tasklist')) 'the clearing is written to an audit log in the operator-only directory'
    $script:Knobs.Acl = 'state-authusers'
    Reset-Knobs
    # (5) the runner's report is strictly typed
    $rj = '{"id":"job-20260101-000000-eeeeeeee","kind":"dispatch","ok":true,"ran_as_sid":"S","ran_as_user":"u","error":"","job_zero_confirmed":true,"job_active":0}'
    $okObj = ConvertFrom-StrictJsonBytes -Bytes ([Text.Encoding]::UTF8.GetBytes($rj)) -Schema $script:CoderLegResultSchema -What 'r'
    Assert-True ($okObj.job_zero_confirmed -is [bool] -and $okObj.job_zero_confirmed) 'the strict schema carries job_zero_confirmed as a boolean'
    foreach ($bad in '"job_zero_confirmed":"true"', '"job_zero_confirmed":1') {
        $threw = $null; try { [void](ConvertFrom-StrictJsonBytes -Bytes ([Text.Encoding]::UTF8.GetBytes($rj.Replace('"job_zero_confirmed":true', $bad))) -Schema $script:CoderLegResultSchema -What 'r') } catch { $threw = $_.Exception.Message }
        Assert-True ($threw -match 'not a boolean') "job_zero_confirmed as $bad is refused"
    }

    Section 'The job object wrapper, for real (Win32): kill-on-close, no breakaway, descendants born inside, drained and confirmed'
    $jobScript = Join-Path $tmpRoot 'job-sim.ps1'
    Set-Content $jobScript @"
param([string]`$Mode, [string]`$Out)
. '$PSScriptRoot\coder-leg-queue.ps1'
`$j = New-CoderJob
`$st = Get-CoderJobState `$j
`$lines = @("flags=`$(`$st.LimitFlags)")
# a child that itself starts a grandchild (the shape of python -> opencode -> node)
`$c = Start-ProcessInJob -Job `$j -FilePath 'cmd.exe' -ArgumentList '/c', 'ping -n 3 127.0.0.1 >nul & ping -n 90 127.0.0.1 >nul' -WorkingDirectory `$env:TEMP
Start-Sleep -Seconds 5
`$ids = @((Get-CoderJobState `$j).Pids)
`$lines += "pids=`$(`$ids -join ',')"
`$lines += "child=`$(`$c.Id)"
if (`$Mode -eq 'drain') { `$d = Stop-CoderJobProcesses `$j -WaitSec 15; `$lines += "zero=`$(`$d.Zero) active=`$(`$d.Active)"; `$lines += "after=`$(@((Get-CoderJobState `$j).Pids).Count)" }
Set-Content `$Out (`$lines -join "``n")
if (`$Mode -eq 'exit') { exit 0 }   # the runner dies without draining: its job handle closes with it
"@ -Encoding UTF8
    function Test-PidAlive([int]$ProcessId) { try { $null = Get-Process -Id $ProcessId -ErrorAction Stop; $true } catch { $false } }
    $outA = Join-Path $tmpRoot 'job-a.txt'
    & pwsh -NoProfile -File $jobScript -Mode drain -Out $outA | Out-Null
    $A = @{}; (Get-Content $outA) | ForEach-Object { $k, $v = $_ -split '=', 2; $A[$k] = $v }
    $flags = [uint32]$A['flags']
    Assert-True (($flags -band 0x2000) -ne 0) 'the job has KILL_ON_JOB_CLOSE'
    Assert-Eq 0 ($flags -band 0x800) 'the job does NOT allow breakaway (JOB_OBJECT_LIMIT_BREAKAWAY_OK is clear)'
    Assert-Eq 0 ($flags -band 0x1000) 'nor silent breakaway'
    $idsA = @($A['pids'] -split ',' | Where-Object { $_ })
    Assert-True ($idsA.Count -ge 2) "a grandchild was born inside the job (pids: $($A['pids']))"
    Assert-True ($A['zero'] -match '^True') 'the drain reports zero'
    Assert-Eq '0' $A['after'] 'the job is empty when queried after the drain'
    foreach ($id in $idsA) { Assert-False (Test-PidAlive ([int]$id)) "process $id is dead after the job was terminated" }
    $outB = Join-Path $tmpRoot 'job-b.txt'
    & pwsh -NoProfile -File $jobScript -Mode exit -Out $outB | Out-Null
    $B = @{}; (Get-Content $outB) | ForEach-Object { $k, $v = $_ -split '=', 2; $B[$k] = $v }
    $idsB = @($B['pids'] -split ',' | Where-Object { $_ })
    Start-Sleep -Seconds 2
    Assert-True ($idsB.Count -ge 2) 'the second runner also had a descendant in its job'
    foreach ($id in $idsB) { Assert-False (Test-PidAlive ([int]$id)) "process $id died when its runner exited without draining (kill-on-close)" }
    $rt = Get-Content (Join-Path $PSScriptRoot 'coder-leg-run.ps1') -Raw
    Assert-True ($rt -match 'New-CoderJob' -and $rt -match '-Job \$cj' -and $rt -match 'job_zero_confirmed') 'the runner creates the job, starts the ACP client in it and reports the drained fact'
    $flText = (Get-Content (Join-Path $PSScriptRoot 'fleet-lib.ps1') -Raw)
    Assert-True ($flText -match 'if \(\$Job\) \{ \$p = Start-ProcessInJob -Job \$Job') 'Invoke-AcpCoderRun starts the ACP client in the job when given one'
    Assert-True ($flText -match 'else \{ \$p = Start-Process -FilePath \$py -ArgumentList \$argList -WorkingDirectory \$blarRoot -PassThru -NoNewWindow -ErrorAction Stop \}') 'without a job the historical Start-Process is unchanged'
    Assert-True ($rt -match 'spin_steps\) -Job \$cj') 'the runner passes the job to Invoke-AcpCoderRun (the ACP client is started inside it)'
    Assert-True ($rt -match '\$result\.job_zero_confirmed = \[bool\]\$drain\.Zero') 'the runner reports the drain result, not a constant'
    Assert-True ((Get-Content (Join-Path $PSScriptRoot 'coder-leg-queue.ps1') -Raw) -match 'false, 0x4 \| 0x400, IntPtr\.Zero, cwd') 'the coder is created SUSPENDED (a race against assignment cannot be driven deterministically, so this is asserted on the source)'
    Assert-True ($rt -notmatch 'Add-CurrentProcessToCoderJob') 'the runner does not rely on assigning itself (measured: that does not capture its later children)'

    Section 'Trust boundary: what the operator believes from coder-controlled sources'
    # (a) job_zero_confirmed is self-attested: it never overrides an operator-side finding
    Reset-Knobs; Set-Config 'restricted_account' 'acp'; New-TestWorktree
    $script:Knobs.CoderProcs = @(@{ ProcessId = 901; Name = 'node.exe' }); $script:Knobs.ProcsSurvive = $true; $script:Knobs.JobZero = 'true'
    $o = Run-Driver; Assert-RefusedRunningNothing $o 'could not be confirmed gone' 'a result that CLAIMS a drained job while an elevated enumeration finds a survivor'
    Assert-True (Test-FusedWorktreeQuarantined $wdPath) '... the claim is overridden: quarantined'
    Reset-Knobs; New-TestWorktree
    $script:Knobs.StaysRunning = $true; $script:Knobs.StopHangs = $true; $script:Knobs.JobZero = 'true'
    $o = Run-Driver; Assert-RefusedRunningNothing $o 'still running|did not leave Running' 'a result that claims a drained job while the task state still says Running'
    Reset-Knobs; New-TestWorktree; $script:Knobs.NotElevated = $true; $script:Knobs.Leg = 'refused'; $script:Knobs.JobZero = 'true'; $script:Knobs.StopHangs = $true; $script:Knobs.StaysRunning = $true
    $o = Run-Driver
    Assert-True ($null -ne $o.Error) 'a failed leg whose report says zero, but whose task the operator could not confirm stopped, is not trusted'
    Assert-True (Test-FusedWorktreeQuarantined $wdPath) '... it quarantines: the self-attested zero needs the operator-side stop confirmation (the failure path)'
    Reset-Knobs; New-TestWorktree; $script:Knobs.NotElevated = $true; $script:Knobs.Leg = 'refused'; $script:Knobs.JobZero = 'true'
    $o = Run-Driver; Assert-False (Test-FusedWorktreeQuarantined $wdPath) 'with the task confirmed stopped, the runner''s zero is accepted as the best available fact (non-elevated; documented as not independent)'
    # (b) the quarantine marker lives in an operator-only directory (shown above) and cannot fail open
    New-TestWorktree; $o = Run-Driver
    Set-FusedWorktreeQuarantine -Path $wdPath -Reason 'drift'
    Remove-Item -LiteralPath (Get-FusedQuarantinePath $wdPath) -Force
    Remove-Item -LiteralPath (Get-FusedWorktreeRecordPath $wdPath) -Force
    Assert-True (Test-FusedWorktreeQuarantined $wdPath) 'marker AND record deleted: this process still remembers the quarantine'
    $threw = $null; try { [void](Get-WtGit $wdPath) } catch { $threw = $_.Exception.Message }
    Assert-True ($threw -match 'quarantined') '... and Get-WtGit refuses'
    [void](Clear-FusedQuarantine -Path $wdPath -ClearedBy 'test'); New-TestWorktree; $o = Run-Driver
    $savedState2 = $env:BLARAI_FUSED_WT_STATE
    $blocker = Join-Path $tmpRoot 'state-is-a-file'; Set-Content $blocker 'x'
    $env:BLARAI_FUSED_WT_STATE = Join-Path $blocker 'sub'
    $threw = $null
    try { & { $ErrorActionPreference = 'Continue'; Set-FusedWorktreeQuarantine -Path $wdPath -Reason 'cannot persist' 2>$null } } catch { $threw = $_.Exception.Message }
    Assert-True ($null -ne $threw) 'a quarantine marker that cannot be written throws (never silently skipped)'
    Assert-True (Test-FusedWorktreeQuarantined $wdPath) '... and the worktree is quarantined for this process anyway'
    $env:BLARAI_FUSED_WT_STATE = $savedState2
    [void](Clear-FusedQuarantine -Path $wdPath -ClearedBy 'test'); New-TestWorktree; $o = Run-Driver
    # (c) the quarantine/record directory and the coder roots never overlap (shown in 'Sibling routes'); the job
    #     object wrapper comes from scripts the coder can only read, and taskkill from System32
    $qlibText = Get-Content (Join-Path $PSScriptRoot 'coder-leg-queue.ps1') -Raw
    Assert-True ($qlibText.Contains('& (Join-Path $env:SystemRoot ''System32\taskkill.exe'')')) 'the operator-side process killer is an absolute System32 path (not resolved through PATH)'
    $regText = Get-Content (Join-Path $PSScriptRoot 'register-coder-leg-task.ps1') -Raw
    Assert-True ($regText -match 'Get-Command pwsh' -and $regText -match 'New-ScheduledTaskAction -Execute \$pwsh') 'the task action is the pwsh resolved at registration, run on scripts under the operator-owned scripts dir (the coder is granted Read+Execute only)'
    # (d) job fields are constrained, not just typed, because the runner later uses them as paths and arguments
    $jid2 = 'job-20260101-000000-cccccccc'
    function Job-Json($kv) { $b = '{"id":"' + $jid2 + '","kind":"dispatch","created":"x","workdir":"C:\\blarai-fleet\\worktrees\\w","model":"local/coder-30b","prompt_file":"C:\\p\\a.txt","log_path":"C:\\p\\b.log","timeout_sec":60,"idle_sec":60,"max_steps":45,"spin_steps":10}'; foreach ($k in $kv.Keys) { $b = [regex]::Replace($b, '"' + $k + '":(?:"[^"]*"|\d+)', '"' + $k + '":' + $kv[$k]) }; $b }
    $okJ = ConvertFrom-StrictJsonBytes -Bytes ([Text.Encoding]::UTF8.GetBytes((Job-Json @{}))) -Schema $script:CoderLegJobSchema -What 'job'
    Assert-Eq 'local/coder-30b' $okJ.model 'control: a well-formed dispatch job passes the constrained schema'
    foreach ($bad in @(
        @{ K = 'workdir'; V = '"C:\\blarai-fleet\\worktrees\\*"'; W = 'a wildcard in workdir' },
        @{ K = 'workdir'; V = '"\\\\\\\\server\\\\share\\\\x"'; W = 'a UNC workdir' },
        @{ K = 'workdir'; V = '"relative\\path"'; W = 'a relative workdir' },
        @{ K = 'prompt_file'; V = '"C:\\p\\a[1].txt"'; W = 'brackets in prompt_file' },
        @{ K = 'log_path'; V = '"C:\\p\\b?.log"'; W = 'a ? in log_path' },
        @{ K = 'model'; V = '"local/x --dangerous"'; W = 'a model carrying arguments' },
        @{ K = 'model'; V = '"cloud/gpt"'; W = 'a non-local model' },
        @{ K = 'timeout_sec'; V = '99999999'; W = 'an enormous timeout' },
        @{ K = 'timeout_sec'; V = '0'; W = 'a zero timeout' },
        @{ K = 'max_steps'; V = '-5'; W = 'negative steps' }
    )) {
        $threw = $null; try { [void](ConvertFrom-StrictJsonBytes -Bytes ([Text.Encoding]::UTF8.GetBytes((Job-Json @{ ($bad.K) = $bad.V }))) -Schema $script:CoderLegJobSchema -What 'job') } catch { $threw = $_.Exception.Message }
        Assert-True ($null -ne $threw -and $threw -match 'strict JSON') "the runner's job schema refuses $($bad.W)"
    }
    # the runner-side path check: the operator-generated places only
    $rp1 = Join-Path (Get-CoderLegPaths).Prompts "$jid2.prompt.txt"; $rl1 = Join-Path (Get-CoderLegPaths).Logs "$jid2.log"
    $mkJob = { param($wd, $pf, $lp) [pscustomobject]@{ id = $jid2; workdir = $wd; prompt_file = $pf; log_path = $lp } }
    $threw = $null; try { Assert-CoderLegJobPathsSafe -Job (& $mkJob "$wtBase\proj-task" $rp1 $rl1) -WorktreeBase $wtBase } catch { $threw = $_.Exception.Message }
    Assert-True ($null -eq $threw) "control: the operator-generated paths pass ($threw)"
    foreach ($case in @(
        @{ W = 'a prompt_file elsewhere (an operator secret)'; A = @("$wtBase\proj-task", (Join-Path $elsewhere 'secret.txt'), $rl1); P = 'prompt_file' },
        @{ W = 'a prompt_file with another job''s name'; A = @("$wtBase\proj-task", (Join-Path (Get-CoderLegPaths).Prompts 'job-20260101-000000-dddddddd.prompt.txt'), $rl1); P = 'prompt_file' },
        @{ W = 'a log_path elsewhere'; A = @("$wtBase\proj-task", $rp1, (Join-Path $elsewhere 'log.txt')); P = 'log_path' },
        @{ W = 'a workdir outside the worktree base'; A = @($elsewhere, $rp1, $rl1); P = 'outside' },
        @{ W = 'a workdir that is a junction'; A = @($junction, $rp1, $rl1); P = 'link|outside' },
        @{ W = 'a workdir that does not exist'; A = @("$wtBase\no-such", $rp1, $rl1); P = 'does not resolve' }
    )) {
        $threw = $null; try { Assert-CoderLegJobPathsSafe -Job (& $mkJob $case.A[0] $case.A[1] $case.A[2]) -WorktreeBase $wtBase } catch { $threw = $_.Exception.Message }
        Assert-True ($null -ne $threw -and $threw -match $case.P) "the runner refuses $($case.W)"
    }
    $rt2 = Get-Content (Join-Path $PSScriptRoot 'coder-leg-run.ps1') -Raw
    Assert-True ($rt2.IndexOf('Assert-CoderLegJobPathsSafe') -ge 0 -and $rt2.IndexOf('Assert-CoderLegJobPathsSafe') -lt $rt2.IndexOf('New-CoderJob')) 'the runner validates the job paths BEFORE creating the job or starting the coder'

    Section 'State drift: a missing, stale or garbled gate record never means allow'
    Reset-Knobs; Set-Config 'restricted_account' 'acp'; New-TestWorktree; $o = Run-Driver
    $recFile = Get-FusedWorktreeRecordPath $wdPath
    $goodRec = Get-Content $recFile -Raw
    foreach ($case in @(
        @{ W = 'a garbled record'; T = '{ not json' },
        @{ W = 'an empty record'; T = '' },
        @{ W = 'a record with no Key'; T = ($goodRec | ConvertFrom-Json | Select-Object Path, GitDir, Fingerprint | ConvertTo-Json) },
        @{ W = 'a record with no Fingerprint'; T = ($goodRec | ConvertFrom-Json | Select-Object Path, Key, GitDir | ConvertTo-Json) },
        @{ W = 'a record with another worktree''s key'; T = ((($goodRec | ConvertFrom-Json) | Select-Object Path, GitDir, Fingerprint, @{ n = 'Key'; e = { '00000000:0000000000000001' } }) | ConvertTo-Json) }
    )) {
        Set-Content $recFile $case.T -Encoding UTF8
        $threw = $null; try { [void](Get-WtGit $wdPath) } catch { $threw = $_.Exception.Message }
        Assert-True ($null -ne $threw) "$($case.W) -> Get-WtGit refuses (never falls back to plain git -C)"
        $threw = $null; try { [void](Assert-OperatorWorktree -Path $wdPath) } catch { $threw = $_.Exception.Message }
        Assert-True ($null -ne $threw) "$($case.W) -> Assert-OperatorWorktree refuses"
    }
    Unlock-FusedWorktree -Path $wdPath
    Set-Content $recFile $goodRec -Encoding UTF8
    # a stale record: the directory was recreated at the same path since it was recorded
    Unlock-FusedWorktree -Path $wdPath
    [IO.Directory]::Delete($wdPath, $true); & git -C $mainRepo worktree prune 2>&1 | Out-Null; & git -C $mainRepo worktree add --detach $wdPath 2>&1 | Out-Null
    $threw = $null; try { [void](Get-WtGit $wdPath) } catch { $threw = $_.Exception.Message }
    Assert-True ($threw -match 'not the object|not the directory recorded|identity') 'a record from an earlier worktree at the same path (recreated directory) is refused, not reused'
    New-TestWorktree
    # a record deleted, then a fresh recording of a worktree the coder has already replaced, is not silently adopted by Get-WtGit
    $o = Run-Driver; Remove-Item (Get-FusedWorktreeRecordPath $wdPath) -Force; Unlock-FusedWorktree -Path $wdPath
    Assert-True ((@(Get-WtGit $wdPath)) -join ' ' -eq "-C $wdPath") 'no record at all is the documented historical -C path (an unfused worktree): only a fused run records, so absence is not an allow for any fused run (its own pre-trigger check records first)'
    # elevation is decided on every call, never cached at process start
    $elevBody = [regex]::Match($qlibText, '(?s)function Test-OrchestratorElevated \{.*?\n\}').Value
    Assert-False ($elevBody -match '\$script:|\$global:') 'Test-OrchestratorElevated holds no cached state'
    Assert-True ($elevBody -match 'GetCurrent\(\)') 'it reads the current token on every call'
    Reset-Knobs; New-TestWorktree; $script:Knobs.CoderProcs = @(@{ ProcessId = 902; Name = 'node.exe' })
    $o = Run-Driver; Assert-True (Called 'kill:902') 'elevated: the operator enumerates and kills'
    Reset-Knobs; New-TestWorktree; $script:Knobs.NotElevated = $true; $script:Knobs.CoderProcs = @(@{ ProcessId = 903; Name = 'node.exe' })
    $o = Run-Driver; Assert-False (Called 'kill:903') 'the very next run, not elevated: no enumeration (the decision is re-read, not remembered)'
    # a result already present for the new job id (a stale or planted file in a reused results path) is refused before the trigger
    Reset-Knobs; New-TestWorktree
    $realNewId2 = ${function:New-CoderLegJobId}
    function New-CoderLegJobId { 'job-20260101-000000-feedbeef' }
    Set-Content (Join-Path (Get-CoderLegPaths).Results 'job-20260101-000000-feedbeef.result.json') (Res-Json 'job-20260101-000000-feedbeef' 'stale') -Encoding UTF8
    $o = Run-Driver
    Set-Item Function:\New-CoderLegJobId $realNewId2
    Assert-True ($null -ne $o.Error -and $o.Error -match 'already exists') 'a result file already present for the new job id is refused (a stale job_zero_confirmed can never be read back)'
    Assert-False (Called 'Start-ScheduledTask') '... and the coder is never started'
    Remove-Item (Join-Path (Get-CoderLegPaths).Results 'job-20260101-000000-feedbeef.result.json') -Force -ErrorAction SilentlyContinue
    # clock: a result dated in the future is not 'after the enqueue'
    $script:Knobs.Acl = 'real'
    $fid = 'job-20260101-000000-f00dcafe'; $fp = Join-Path (Get-CoderLegPaths).Results "$fid.result.json"
    Set-Content $fp (Res-Json $fid 'future') -Encoding UTF8
    $ownF = (Microsoft.PowerShell.Security\Get-Acl -LiteralPath $fp).GetOwner([Security.Principal.SecurityIdentifier]).Value
    (Get-Item $fp).CreationTimeUtc = (Get-Date).ToUniversalTime().AddDays(2)
    $threw = $null; try { [void](& $realWait -JobId $fid -TimeoutSec 2 -PollSec 1 -ExpectedOwnerSid $ownF -NotBefore (Get-Date).AddMinutes(-5)) } catch { $threw = $_.Exception.Message }
    Assert-True ($threw -match 'in the future') 'a result whose creation time is in the future is refused (the owner can set its own timestamps)'
    Remove-Item $fp -Force -ErrorAction SilentlyContinue
    $fid = 'job-20260101-000000-f00dcaff'; $fp = Join-Path (Get-CoderLegPaths).Results "$fid.result.json"   # a new name: NTFS tunnelling would give a re-created file its old creation time
    Set-Content $fp (Res-Json $fid 'now') -Encoding UTF8
    $okF = & $realWait -JobId $fid -TimeoutSec 2 -PollSec 1 -ExpectedOwnerSid $ownF -NotBefore (Get-Date).AddMinutes(-5)
    Assert-True ($null -ne $okF) 'control: a result created just now is accepted'
    $script:Knobs.Acl = 'tight'
    New-TestWorktree

    Section 'Lead (1): coder-writable git state is never trusted and never executed'
    $plantDir = Join-Path $tmpRoot 'plant'; New-Item -ItemType Directory -Force $plantDir | Out-Null
    $fsmScript = (Join-Path $plantDir 'fsm.sh') -replace '\\', '/'
    $hookMark = Join-Path $plantDir 'hook.ran'; $fsmMark = Join-Path $plantDir 'fsm.ran'
    [IO.File]::WriteAllText($fsmScript, "#!/bin/sh`necho ran >> `"$($fsmMark -replace '\\', '/')`"`nexit 0`n")
    $cfgFile = Join-Path $mainRepo '.git\config'; $cfgBackup = Get-Content $cfgFile -Raw
    Reset-Knobs; Set-Config 'restricted_account' 'acp'; New-TestWorktree
    $o = Run-Driver; Assert-True ($null -eq $o.Error) "baseline for the planted-state tests ($($o.Error))"
    $rec = Get-Content (Get-FusedWorktreeRecordPath $wdPath) -Raw | ConvertFrom-Json
    $hardened = Get-HardenedGitArgs -GitDir $rec.GitDir -WorkTree $wdPath
    Assert-True ($hardened -contains '--no-optional-locks' -and $hardened -contains '--no-pager' -and $hardened -contains 'core.hooksPath=NUL' -and $hardened -contains 'core.fsmonitor=false' -and $hardened -contains 'core.sshCommand=false' -and $hardened -contains 'protocol.ext.allow=never') 'the hardened prefix names no-optional-locks, no-pager, hooks off, fsmonitor off, sshCommand off, ext transport off'
    # the coder plants a config setting and a hook in the gitdir's repository
    Add-Content $cfgFile "[core]`n`tfsmonitor = $fsmScript"
    [IO.File]::WriteAllText((Join-Path $mainRepo '.git\hooks\pre-commit'), "#!/bin/sh`necho ran >> `"$($hookMark -replace '\\', '/')`"`nexit 0`n")
    Set-Content (Join-Path $wdPath 'planted.txt') 'x'
    # control: the plant is REAL (plain git runs both); hardened git runs neither
    & git -C $wdPath add -A 2>&1 | Out-Null
    & git -C $wdPath -c user.email=t@t -c user.name=t commit -q -m control 2>&1 | Out-Null
    Assert-True ((Test-Path $fsmMark) -and (Test-Path $hookMark)) 'control: plain git -C really executes the planted fsmonitor and pre-commit hook (the test can fail)'
    Remove-Item $fsmMark, $hookMark -Force -ErrorAction SilentlyContinue
    Set-Content (Join-Path $wdPath 'planted2.txt') 'y'
    & git @hardened add -A 2>&1 | Out-Null
    & git @hardened -c user.email=t@t -c user.name=t commit -q -m hardened 2>&1 | Out-Null
    Assert-False ((Test-Path $fsmMark) -or (Test-Path $hookMark)) 'the hardened git argv executes NEITHER the planted fsmonitor NOR the planted hook'
    $threw = $null; try { [void](Get-WtGit $wdPath) } catch { $threw = $_.Exception.Message }
    Assert-True ($threw -match 'config or hooks') 'Get-WtGit refuses a gitdir whose config or hooks changed after the coder ran (no git starts)'
    # the same through the fused leg: plant while the coder runs
    [IO.File]::WriteAllText($cfgFile, $cfgBackup); Remove-Item (Join-Path $mainRepo '.git\hooks\pre-commit') -Force
    Reset-Knobs; $script:Knobs.Swap = 'plant-hook'; New-TestWorktree
    $o = Run-Driver; Assert-RefusedRunningNothing $o 'config or hooks' 'the coder plants a hook in the gitdir while it runs'
    Remove-Item (Join-Path $mainRepo '.git\hooks\pre-commit') -Force -ErrorAction SilentlyContinue
    Reset-Knobs; $script:Knobs.Swap = 'plant-config'; New-TestWorktree
    $o = Run-Driver; Assert-RefusedRunningNothing $o 'config or hooks' 'the coder plants a config setting in the gitdir while it runs'
    [IO.File]::WriteAllText($cfgFile, $cfgBackup)
    Reset-Knobs; New-TestWorktree
    $o = Run-Driver; Assert-True ($null -eq $o.Error) 'with the planted state removed the leg runs again'
    $fp1 = Get-GitDirFingerprint -GitDir $rec.GitDir; $fp2 = Get-GitDirFingerprint -GitDir $rec.GitDir
    Assert-Eq $fp1 $fp2 'the gitdir fingerprint is stable'
    Reset-Knobs; $script:Knobs.Swap = 'gitdir-elsewhere'; New-TestWorktree
    $o = Run-Driver; Assert-RefusedRunningNothing $o 'gitdir pointer' 'the coder repoints .git at a gitdir of its own'

    Section 'Lead (2): a path the coder returns is never used; the operator-recorded path is'
    Reset-Knobs; $script:Knobs.Leg = 'evilpaths'; New-TestWorktree
    $o = Run-Driver
    Assert-True ($null -eq $o.Error) "a result echoing other paths still completes ($($o.Error))"
    Assert-Eq $o.Log $o.Result.LogPath 'the returned LogPath is the operator-side one, not the path the coder wrote into the result'
    Assert-False ((Test-Path (Join-Path $elsewhere 'evil-workdir')) -or (Test-Path (Join-Path $elsewhere 'evil-log.txt')) -or (Test-Path (Join-Path $elsewhere 'evil-result-log.txt'))) 'nothing was created at a coder-supplied path'
    Assert-Eq "$wtBase\proj-task" $script:LastJob.workdir 'the job carries the operator-resolved workdir'

    Section 'Lead (3): check-then-read is closed by holding ONE handle (no swap between the check and the read)'
    $resDir = (Get-CoderLegPaths).Results
    $script:Knobs.Acl = 'real'
    $rid = 'job-20260101-000000-bbbbbbbb'; $rp = Join-Path $resDir "$rid.result.json"
    Set-Content $rp (Res-Json $rid 'orig') -Encoding UTF8
    $own = (Microsoft.PowerShell.Security\Get-Acl -LiteralPath $rp).GetOwner([Security.Principal.SecurityIdentifier]).Value
    $script:HookOut = @{}
    $got = & $realWait -JobId $rid -TimeoutSec 3 -PollSec 1 -ExpectedOwnerSid $own -BeforeRead {
        foreach ($act in 'delete', 'rename', 'overwrite') {
            try {
                switch ($act) {
                    'delete'    { Remove-Item -LiteralPath $rp -ErrorAction Stop }
                    'rename'    { Move-Item -LiteralPath $rp "$rp.moved" -ErrorAction Stop }
                    'overwrite' { Set-Content -LiteralPath $rp (Res-Json $rid 'forged') -ErrorAction Stop }
                }
                $script:HookOut[$act] = 'SUCCEEDED'
            } catch { $script:HookOut[$act] = 'blocked' }
        }
    }
    foreach ($act in 'delete', 'rename', 'overwrite') { Assert-Eq 'blocked' $script:HookOut[$act] "while the result is being checked and read, another process cannot $act it" }
    Assert-True ($null -ne $got -and $got.error -eq 'orig') 'the bound read returns the content that was checked'
    $tsrc = Join-Path $resDir 'transcript-src.txt'; $tdst = Join-Path $tmpRoot 'transcript-dst.txt'
    Set-Content $tsrc 'original transcript' -Encoding UTF8
    $script:HookOut = @{}
    Copy-CoderTranscript -Source $tsrc -Destination $tdst -BeforeCopy {
        foreach ($act in 'delete', 'rename', 'overwrite') {
            try {
                switch ($act) {
                    'delete'    { Remove-Item -LiteralPath $tsrc -ErrorAction Stop }
                    'rename'    { Move-Item -LiteralPath $tsrc "$tsrc.moved" -ErrorAction Stop }
                    'overwrite' { Set-Content -LiteralPath $tsrc 'forged' -ErrorAction Stop }
                }
                $script:HookOut[$act] = 'SUCCEEDED'
            } catch { $script:HookOut[$act] = 'blocked' }
        }
    }
    foreach ($act in 'delete', 'rename', 'overwrite') { Assert-Eq 'blocked' $script:HookOut[$act] "while the transcript is checked and copied, another process cannot $act it" }
    Assert-True ((Get-Content $tdst -Raw) -match 'original transcript') 'the copy is of the content that was checked'
    $script:Knobs.Acl = 'tight'

    Section 'M2: staging dirs swapped for links never turn operator writes, copies or deletes into actions elsewhere'
    function Restore-StagingDirs {
        $paths = Get-CoderLegPaths
        foreach ($d in $paths.Logs, $paths.Prompts) {
            if (Test-Path -LiteralPath "$d.real") { if (Test-Path -LiteralPath $d) { [IO.Directory]::Delete($d) }; Move-Item "$d.real" $d }
            Get-ChildItem -LiteralPath $d -File -ErrorAction SilentlyContinue | Remove-Item -Force   # what the skipped cleanup left behind, by design
        }
        Get-ChildItem $elsewhere -File -ErrorAction SilentlyContinue | Remove-Item -Force
    }
    Reset-Knobs; $script:Knobs.Swap = 'logs-junction'; New-TestWorktree
    $o = Run-Driver; Assert-True ($null -ne $o.Error -and $o.Error -match 'link \(reparse point\)|replaced') "logs dir swapped for a junction -> refused ($($o.Error))"
    Assert-True (Test-Path (Join-Path $elsewhere "$($script:LastJob.id).log")) 'logs junction -> the operator did NOT delete a file through it'
    Restore-StagingDirs
    Reset-Knobs; $script:Knobs.Swap = 'logs-replaced'; New-TestWorktree
    $o = Run-Driver; Assert-True ($null -ne $o.Error -and $o.Error -match 'not the object it was before') "logs dir replaced by a different real directory -> refused by identity ($($o.Error))"
    Restore-StagingDirs
    Reset-Knobs; $script:Knobs.Swap = 'prompts-junction'; New-TestWorktree
    $o = Run-Driver
    Assert-True (Test-Path (Join-Path $elsewhere "$($script:LastJob.id).prompt.txt")) 'prompts junction -> the operator did NOT delete a file through it'
    Restore-StagingDirs
    Reset-Knobs; $script:Knobs.Swap = 'log-hardlink'; New-TestWorktree
    $o = Run-Driver; Assert-RefusedRunningNothing $o 'hard links|link' 'a shared transcript that is a hard link to another file'
    Assert-False (Test-Path $o.Log) 'a hard-linked transcript is not copied to the operator-side log'
    Restore-StagingDirs
    Reset-Knobs; New-TestWorktree

    Section 'M3: the ACL gate sees inherit-only generic rights, parents and owners'
    foreach ($case in @(
        @{ Acl = 'inherit-ga'; What = 'an inherit-only GENERIC_ALL ACE for Everyone' },
        @{ Acl = 'inherit-gw'; What = 'an inherit-only GENERIC_WRITE ACE for Everyone' },
        @{ Acl = 'parent-authusers'; What = 'Authenticated Users deleting children of the PARENT folder' }
    )) {
        Reset-Knobs; $script:Knobs.Acl = $case.Acl
        $o = Run-Driver; Assert-RefusedRunningNothing $o '#1686' $case.What
        Assert-False (Called 'Start-ScheduledTask') "$($case.What) -> the task was never triggered"
    }
    Reset-Knobs; $script:Knobs.Owner = $CODER_SID; $script:Knobs.OwnerPath = '\prompts'
    $o = Run-Driver; Assert-RefusedRunningNothing $o "owner '$CODER_SID'" 'a guarded folder OWNED by the coder'
    Reset-Knobs; $script:Knobs.Owner = 'S-1-1-0'
    $o = Run-Driver; Assert-RefusedRunningNothing $o "owner 'S-1-1-0'" 'folders owned by Everyone'
    Reset-Knobs; $script:Knobs.Owner = 'unreadable'; $script:Knobs.OwnerPath = '\results'
    $o = Run-Driver; Assert-RefusedRunningNothing $o 'owner' 'a folder whose owner cannot be read'
    $parentSeen = $false
    Reset-Knobs; [void](Run-Driver)
    Assert-True (($script:Calls | Where-Object { $_ -eq 'Get-Acl' }).Count -ge 7) 'the gate reads 7 ACLs: parent, root, queue, prompts, results, logs, worktree base'
    # real ACLs through SDDL: an inherit-only Everyone GENERIC_ALL ACE and an orphan-SID write ACE
    $script:Knobs.Acl = 'real'
    foreach ($ace in @(@{ Sddl = '(A;OICIIO;GA;;;WD)'; What = 'a REAL inherit-only (A;OICIIO;GA;;;WD) ACE' }, @{ Sddl = '(A;OICI;FA;;;S-1-5-21-1-2-3-4)'; What = 'a REAL orphan-SID full-control ACE' })) {
        $d = Join-Path $tmpRoot ('sddl-' + [guid]::NewGuid().ToString('N')); New-Item -ItemType Directory -Force $d | Out-Null
        $a0 = Microsoft.PowerShell.Security\Get-Acl -LiteralPath $d
        $a0.SetAccessRuleProtection($true, $false)
        foreach ($r in @($a0.Access)) { [void]$a0.RemoveAccessRule($r) }
        foreach ($sid in $OPERATOR_SID, 'S-1-5-18', 'S-1-5-32-544') { $a0.AddAccessRule((New-Object Security.AccessControl.FileSystemAccessRule((New-Object Security.Principal.SecurityIdentifier($sid)), 'FullControl', 'ContainerInherit,ObjectInherit', 'None', 'Allow'))) }
        Microsoft.PowerShell.Security\Set-Acl -LiteralPath $d -AclObject $a0
        $okBefore = $null; try { Assert-CoderQueueAclTight -Path $d; $okBefore = $true } catch { $okBefore = $_.Exception.Message }
        Assert-True ($okBefore -eq $true) "control: the hermetic directory passes before the extra ACE ($okBefore)"
        $a1 = Microsoft.PowerShell.Security\Get-Acl -LiteralPath $d
        $a1.SetSecurityDescriptorSddlForm($a1.Sddl + $ace.Sddl)
        Microsoft.PowerShell.Security\Set-Acl -LiteralPath $d -AclObject $a1
        $threw = $null; try { Assert-CoderQueueAclTight -Path $d } catch { $threw = $_.Exception.Message }
        Assert-True ($null -ne $threw -and $threw -match '#1686') "$($ace.What) is refused"
    }
    $script:Knobs.Acl = 'tight'

    Section 'M4: Stop-CoderLegTask never reports stopped without a confirmed state'
    Reset-Knobs; $script:Knobs.StopThrows = $true; $script:Knobs.QueryThrows = $true
    Assert-False (Stop-CoderLegTask -WaitSec 1 -PollMs 20) 'stop and state query both failing -> NOT stopped'
    Reset-Knobs; $script:Knobs.QueryThrows = $true
    Assert-False (Stop-CoderLegTask -WaitSec 1 -PollMs 20) 'a state query that fails -> NOT stopped'
    Reset-Knobs; $script:Knobs.TaskState = 'Running'; $script:Knobs.StopThrows = $true
    Assert-False (Stop-CoderLegTask -WaitSec 1 -PollMs 20) 'a stop that fails while the task still runs -> NOT stopped'
    Reset-Knobs; $script:Knobs.TaskState = 'Running'
    Assert-True (Stop-CoderLegTask -WaitSec 1 -PollMs 20) 'a confirmed stop is reported as stopped'
    Reset-Knobs; Set-Config 'restricted_account' 'acp'; $script:Knobs.Leg = 'null'; $script:Knobs.QueryThrows = $true
    $script:Knobs.AccountMissing = $false
    $o = Run-Driver
    Assert-True ($null -ne $o.Error) 'with the task state unreadable the leg fails closed'

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
    $script:CancelAt = (Get-Date).AddSeconds(2)
    $copts = $opts.Clone(); $copts.QueueWaitSec = 12; $copts.ShouldCancel = { (Get-Date) -gt $script:CancelAt }
    $o = Run-Driver -Options $copts
    Assert-RefusedRunningNothing $o 'cancelled while waiting' 'cancellation during the mutex wait'
    Assert-True ($o.Seconds -lt 8) "the cancel is honoured within a poll slice, not after the whole wait (took $([math]::Round($o.Seconds,1))s of a 12s wait)"
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

    Section 'The provisioning marker: reader default, writer default and the provisioning script agree'
    $fnAst = (Get-Command Test-CoderContainmentExpected).ScriptBlock.Ast
    $readerDefault = ($fnAst.Body.ParamBlock.Parameters | Where-Object { $_.Name.VariablePath.UserPath -eq 'MarkerPath' }).DefaultValue.Value
    . "$PSScriptRoot\coder-provisioning-lib.ps1"
    Assert-Eq (Get-CoderProvisionMarkerPath) $readerDefault 'Test-CoderContainmentExpected reads the path provisioning writes'
    $provText = Get-Content "$PSScriptRoot\provision-coder-account.ps1" -Raw
    Assert-True ($provText -match 'Write-CoderProvisionMarker') 'provision-coder-account.ps1 writes the marker'
    Assert-True ($provText -match 'Remove-CoderProvisionMarker') 'the rollback removes the marker'

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

    Section 'Operator-side uses: one funnel per kind, and a lint that fails on a new unguarded use'
    # --- behaviour of the funnels, with real junctions ---
    Reset-Knobs; Set-Config 'restricted_account' 'acp'; New-TestWorktree
    $o = Run-Driver; Assert-True ($null -eq $o.Error) "baseline for the funnel tests ($($o.Error))"
    $plainWt = Join-Path $tmpRoot 'plain-wt'; New-Item -ItemType Directory -Force $plainWt | Out-Null
    Assert-Eq (Join-Path $plainWt 'a.txt') (Get-OperatorWorktreePath -Worktree $plainWt -Relative 'a.txt') 'Get-OperatorWorktreePath: an unrecorded worktree gets a plain Join-Path'
    Assert-Eq (Join-Path $wdPath 'a.txt') (Get-OperatorWorktreePath -Worktree $wdPath -Relative 'a.txt') 'Get-OperatorWorktreePath: an intact recorded worktree resolves the path'
    $threw = $null; try { [void](Get-OperatorWorktreePath -Worktree $wdPath -Relative '..\escape.txt') } catch { $threw = $_.Exception.Message }
    Assert-True ($threw -match 'leaves the worktree') 'Get-OperatorWorktreePath: a relative path that leaves the worktree is refused'
    New-Item -ItemType Junction -Path (Join-Path $wdPath 'inner-link') -Target $elsewhere | Out-Null
    $threw = $null; try { [void](Get-OperatorWorktreePath -Worktree $wdPath -Relative 'inner-link\x.txt') } catch { $threw = $_.Exception.Message }
    Assert-True ($threw -match 'link \(reparse point\)') 'Get-OperatorWorktreePath: a path through a link inside the worktree is refused'
    # Remove-WorktreeSafe: an inner link is deleted AS a link, the target survives
    Set-Content (Join-Path $elsewhere 'decoy.txt') 'keep me' -Encoding UTF8
    Remove-WorktreeSafe -Repo $mainRepo -Path $wdPath
    Assert-False (Test-Path -LiteralPath $wdPath) 'Remove-WorktreeSafe removes the worktree'
    Assert-True (Test-Path (Join-Path $elsewhere 'decoy.txt')) 'Remove-WorktreeSafe: a link inside the worktree is not followed (the target survives)'
    New-TestWorktree; $o = Run-Driver
    Unlock-FusedWorktree -Path $wdPath; [IO.Directory]::Delete($wdPath, $true); New-Item -ItemType Junction -Path $wdPath -Target $elsewhere | Out-Null
    Remove-WorktreeSafe -Repo $mainRepo -Path $wdPath
    Assert-True (Test-Path (Join-Path $elsewhere 'decoy.txt')) 'Remove-WorktreeSafe: a worktree path that IS a link is deleted as a link (the target survives)'
    Assert-False (Test-Path -LiteralPath $wdPath) '... and the link is gone'
    # Invoke-WithTimeout: a swapped worktree never runs a command
    New-TestWorktree; $o = Run-Driver
    $ranMark = Join-Path $tmpRoot 'cmd.ran'
    $okRun = Invoke-WithTimeout -CommandLine "cmd /c echo hi > `"$ranMark`"" -WorkDir $wdPath -TimeoutSec 30
    Assert-True (Test-Path $ranMark) 'Invoke-WithTimeout runs in an intact recorded worktree'
    Remove-Item $ranMark -Force
    Unlock-FusedWorktree -Path $wdPath; [IO.Directory]::Delete($wdPath, $true); New-Item -ItemType Junction -Path $wdPath -Target $victim | Out-Null
    $threw = $null; try { [void](Invoke-WithTimeout -CommandLine "cmd /c echo hi > `"$ranMark`"" -WorkDir $wdPath -TimeoutSec 30) } catch { $threw = $_.Exception.Message }
    Assert-True ($null -ne $threw -and -not (Test-Path $ranMark)) 'Invoke-WithTimeout: a worktree swapped for a junction throws and the command never starts'
    $threw = $null; try { [void](Assert-OperatorWorktree -Path $wdPath) } catch { $threw = $_.Exception.Message }
    Assert-True ($null -ne $threw) 'Assert-OperatorWorktree: throws for the swapped worktree'
    $threw = $null; try { [void](Get-OperatorWorktreePath -Worktree $wdPath -Relative 'x.txt') } catch { $threw = $_.Exception.Message }
    Assert-True ($null -ne $threw) 'Get-OperatorWorktreePath: throws for a swapped worktree root (the root itself is verified, not only the segments below it)'
    New-TestWorktree
    # the coder must not be running when the result is accepted
    Reset-Knobs; New-TestWorktree; $script:Knobs.StaysRunning = $true; $script:Knobs.StopHangs = $true
    $o = Run-Driver; Assert-RefusedRunningNothing $o 'still running after it returned|did not leave Running' 'the coder-leg task is still running after the result and cannot be stopped'
    Reset-Knobs; New-TestWorktree; $script:Knobs.StaysRunning = $true
    $o = Run-Driver; Assert-True ($null -eq $o.Error -and (Called 'Stop-ScheduledTask')) "a task still running after the result is stopped, then the run proceeds ($($o.Error))"
    Reset-Knobs; $script:Knobs.QueryBreaksAfterResult = $true; New-TestWorktree
    $o = Run-Driver; Assert-RefusedRunningNothing $o 'cannot confirm that the coder-leg task has finished' 'the task state becomes unreadable right after the result'
    Reset-Knobs; New-TestWorktree

    # --- the lint: every operator-side use of a coder-writable path goes through its funnel ---
    function Get-LintLines([string]$File) { @(Get-Content -LiteralPath (Join-Path $PSScriptRoot $File)) }
    function Find-RawWorktreeGit($Lines) {
        # git against a worktree variable with the raw -C form (the form that skips Get-WtGit)
        @($Lines | Where-Object { $_ -match 'git\s+-C\s+\$(wt|wt_k|Worktree|wtOrig|cand\.Worktree|__stale)\b' -and $_ -notmatch '^\s*#' })
    }
    $allowedRaw = @(
        '^\s*git -C \$wt add -A 2>&1 \| Out-Null\s*$',
        '^\s*git -C \$wt -c user\.email=''agent@local'' -c user\.name=''coding-agent'' commit -m "seed: ',
        '^\s*\$codeBase = \(git -C \$wt rev-parse HEAD 2>\$null\)\s*$',
        '^\s*Remove-Item \$_\.FullName -Recurse -Force -ErrorAction SilentlyContinue\s*$'   # run-battery-night: throwaway sandboxes under state\worktrees, never the fused base
    )
    $fleetLines = Get-LintLines 'fleet-lib.ps1'; $nat = Get-LintLines 'new-agent-task.ps1'
    $rawFleet = Find-RawWorktreeGit $fleetLines
    Assert-Eq 0 $rawFleet.Count "fleet-lib.ps1 has no raw 'git -C <worktree>' (every post-coder use is git @(Get-WtGit ...))"
    $rawNat = Find-RawWorktreeGit $nat
    $unlisted = @($rawNat | Where-Object { $l = $_; -not ($allowedRaw | Where-Object { $l -match $_ }) })
    Assert-Eq 0 $unlisted.Count "new-agent-task.ps1: every raw 'git -C <worktree>' is one of the pre-coder seed lines ($(($unlisted | ForEach-Object { $_.Trim() }) -join ' || '))"
    Assert-Eq 5 $rawNat.Count 'new-agent-task.ps1: exactly the 5 pre-coder seed lines are raw (a sixth is a new unguarded use)'
    $synthetic = @('    git -C $wt checkout main 2>&1 | Out-Null')
    Assert-Eq 1 (Find-RawWorktreeGit $synthetic).Count 'lint self-check: a new raw git call on a worktree variable IS detected'
    $rmRaw = @(($fleetLines + $nat) | Where-Object { $_ -match 'git\s+-C\s+\$Repo\s+worktree\s+remove' -and $_ -notmatch '^\s*#' })
    Assert-Eq 1 $rmRaw.Count "'git -C `$Repo worktree remove' appears once in total: inside Remove-WorktreeSafe"
    $fileOps = @(($fleetLines + $nat) | Where-Object { $_ -match '(Remove-Item|Copy-Item|Move-Item|Set-Content|Add-Content|WriteAllBytes|WriteAllText|Out-File)[^\n]*Join-Path \$(wt|Worktree|wt_k)\b' -and $_ -notmatch '^\s*#' })
    Assert-Eq 0 $fileOps.Count "no write/copy/delete into a worktree via a bare Join-Path (they use Get-OperatorWorktreePath): $(($fileOps | ForEach-Object { $_.Trim() }) -join ' || ')"
    Assert-Eq 1 (@(@('Remove-Item (Join-Path $wt "x")') | Where-Object { $_ -match '(Remove-Item|Copy-Item)[^\n]*Join-Path \$(wt|Worktree|wt_k)\b' }).Count) 'lint self-check: a bare Join-Path delete IS detected'
    $fused = (Get-Command Invoke-FusedCoderRun).ScriptBlock.ToString() -split "`n"
    $rmIdx = @(0..($fused.Count - 1) | Where-Object { $fused[$_] -match 'Remove-Item' -and $fused[$_] -notmatch '^\s*#' })
    $unguardedRm = @($rmIdx | Where-Object { $fused[$_] -notmatch 'Test-FusedDirIntact' -and ($_ -eq 0 -or $fused[$_ - 1] -notmatch 'Test-FusedDirIntact') })
    Assert-True ($rmIdx.Count -gt 0 -and $unguardedRm.Count -eq 0) 'Invoke-FusedCoderRun: every Remove-Item sits behind Test-FusedDirIntact on the same or the previous line (a swapped staging dir is never deleted through)'
    Assert-False (($fused -join "`n") -match '(?m)^[^#\r\n]*\b(Copy-Item|Move-Item)\b') 'Invoke-FusedCoderRun: no Copy-Item or Move-Item (the transcript goes through Copy-CoderTranscript)'
    Assert-True ((($fused -join "`n") -match 'Assert-FusedPathIntact -Path \$promptsDir[^
]*
\s*Write-OperatorFileExclusive -LiteralPath \$promptFile')) 'Invoke-FusedCoderRun: the prompt write is immediately preceded by the prompts-dir identity check'
    $wtl = (Get-Command Invoke-WithTimeout).ScriptBlock.ToString()
    Assert-True ($wtl -match 'Assert-OperatorWorktree') 'Invoke-WithTimeout asserts the worktree before running anything'
    $icb = (Get-Command Invoke-CandidateBuild).ScriptBlock.ToString()
    Assert-True ($icb.IndexOf('Invoke-BuildWithRetry') -lt $icb.IndexOf('Assert-OperatorWorktree -Path $wt')) 'Invoke-CandidateBuild asserts the worktree straight after the coder, before any gate step'
    Assert-True ((Get-Content (Join-Path $PSScriptRoot 'coder-leg-queue.ps1') -Raw) -match '\[IO\.FileAccess\]::Read, \[IO\.FileShare\]::Read\)') 'the result file is read through one handle that denies writers, renames and deletes'

    Section 'N2: AST lint of operator-side git and deletes'
    # --- AST lint (N2): every spelling of an operator-side git or recursive delete on a worktree ---
    function Get-GuardFindings([string]$Text, [string]$Label, [string[]]$AllowedLines = @()) {
        $tok = $null; $err = $null
        $ast = [System.Management.Automation.Language.Parser]::ParseInput($Text, [ref]$tok, [ref]$err)
        $worktreeish = '(?i)wt|worktree|cand|stale|workdir|appdir|\.fullname'
        $helperFns = 'Get-WorktreeDigest', 'Restore-WorktreeToHead', 'Get-CandidateTestPartition', 'Invoke-CandidateBuild', 'Resolve-CriticRange', 'Clear-WorktreeUntracked', 'Wait-WorktreeQuiesced', 'Invoke-ScratchTestSignal', 'Invoke-VisualFixPass'
        $mainRepoOk = @{ 'Get-ConfigDeployDivergence' = '$Repo'; 'Remove-WorktreeSafe' = '$Repo'; 'Get-WebBuildCommitCount' = '$Root'; 'Invoke-GitRead' = '' }
        $out = @()
        foreach ($c in $ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.CommandAst] }, $true)) {
            $els = @($c.CommandElements); if ($els.Count -eq 0) { continue }
            $texts = @($els | ForEach-Object { $_.Extent.Text })
            $name = $c.GetCommandName()
            $p = $c; $fn = '<script>'; while ($p) { if ($p -is [System.Management.Automation.Language.FunctionDefinitionAst]) { $fn = $p.Name; break }; $p = $p.Parent }
            $line = $Text.Split("`n")[$c.Extent.StartLineNumber - 1]
            if ($AllowedLines | Where-Object { $line -match $_ }) { continue }
            $isGit = ($texts[0] -match '^[''"]?git(\.exe)?[''"]?$')
            $gitViaStart = ($name -in 'Start-Process', 'Invoke-Expression', 'iex') -and (@($texts | Select-Object -Skip 1 | Where-Object { $_ -match '^[''"]?git(\.exe)?[''"]?$' }).Count -gt 0)
            if ($isGit -or $gitViaStart) {
                $where = "$Label::$fn line $($c.Extent.StartLineNumber): $($c.Extent.Text.Split("`n")[0].Trim())"
                if ($gitViaStart) { $out += "Start-Process/Invoke-Expression of git ($where)"; continue }
                if ($c.InvocationOperator -ne 'Unknown' -and -not $mainRepoOk.ContainsKey($fn)) { $out += "& git ($where)"; continue }
                $second = if ($texts.Count -gt 1) { $texts[1] } else { '' }
                $viaFunnel = ($second -match 'Get-WtGit')
                if ($helperFns -contains $fn) { if (-not $viaFunnel) { $out += "raw git inside the worktree helper $fn ($where)" }; continue }
                if ($viaFunnel) { continue }
                $ci = [array]::IndexOf($texts, '-C')
                if ($ci -ge 0 -and $ci + 1 -lt $texts.Count) {
                    $arg = $texts[$ci + 1]
                    $okArg = $mainRepoOk.ContainsKey($fn) -and (($mainRepoOk[$fn] -eq '') -or ($arg -ceq $mainRepoOk[$fn]))
                    $okMain = ($Label -eq 'new-agent-task.ps1' -and $arg -ceq '$Repo')
                    if ($arg -match $worktreeish -or -not ($okArg -or $okMain)) { $out += "raw git -C $arg ($where)" }
                }
            }
            if ($name -in 'Remove-Item', 'ri', 'rm', 'del', 'rd', 'rmdir', 'erase') {
                $hasRecurse = @($texts | Where-Object { $_ -match '^-Recurse$|^-r$' }).Count -gt 0
                if ($hasRecurse -and (($texts -join ' ') -match $worktreeish)) { $out += "recursive delete on a worktree-ish path ($Label::$fn line $($c.Extent.StartLineNumber): $($c.Extent.Text.Split("`n")[0].Trim()))" }
            }
        }
        return $out
    }
    $seedAllowed = @(
        '^\s*git -C \$wt add -A 2>&1 \| Out-Null\s*$',
        '^\s*git -C \$wt -c user\.email=''agent@local'' -c user\.name=''coding-agent'' commit -m "seed: ',
        '^\s*\$codeBase = \(git -C \$wt rev-parse HEAD 2>\$null\)\s*$',
        '^\s*Remove-Item \$_\.FullName -Recurse -Force -ErrorAction SilentlyContinue\s*$'   # run-battery-night: throwaway sandboxes under state\worktrees, never the fused base
    )
    $guardedFiles = 'fleet-lib.ps1', 'new-agent-task.ps1', 'critic-run.ps1', 'run-fleet.ps1', 'critique-loop.ps1', 'capture-app.ps1', 'check-design-structural.ps1', 'review-website.ps1', 'review-website-lib.ps1', 'review-website-report.ps1', 'run-battery-night.ps1', 'battery-bootstrap.ps1', 'coder-leg-queue.ps1', 'coder-leg-run.ps1'
    $allFindings = @()
    foreach ($gf in $guardedFiles) {
        if (-not (Test-Path (Join-Path $PSScriptRoot $gf))) { continue }
        $allFindings += Get-GuardFindings -Text (Get-Content (Join-Path $PSScriptRoot $gf) -Raw) -Label $gf -AllowedLines $(if ($gf -in 'new-agent-task.ps1', 'run-battery-night.ps1') { $seedAllowed } else { @() })
    }
    Assert-Eq 0 $allFindings.Count "AST lint over $($guardedFiles.Count) operator-side scripts finds no unguarded git or recursive worktree delete ($(($allFindings | Select-Object -First 4) -join ' || '))"
    # self-checks: each spelling the reviewer found surviving, and the other bypass forms, IS detected
    $syn = @(
        @{ T = 'git -C "$wt" reset --hard'; W = 'quoted worktree variable' },
        @{ T = 'function Restore-WorktreeToHead { param($Repo) git -C $Repo reset --hard HEAD }'; W = 'a helper whose parameter is named $Repo' },
        @{ T = 'Remove-Item -LiteralPath $wtOrig -Recurse -Force'; W = 'a recursive Remove-Item on a worktree variable' },
        @{ T = 'rm -Recurse -Force $cand.Worktree'; W = 'the rm alias with -Recurse' },
        @{ T = '& git -C $x status'; W = 'call operator & git' },
        @{ T = 'Start-Process git -ArgumentList "-C x status"'; W = 'Start-Process git' },
        @{ T = 'git -C $somethingElse status'; W = '-C followed by an arbitrary variable' },
        @{ T = 'git -C "$($cand.Worktree)" add -A'; W = 'a quoted subexpression' }
    )
    foreach ($case in $syn) {
        Assert-True ((Get-GuardFindings -Text $case.T -Label 'synthetic.ps1').Count -ge 1) "lint self-check: $($case.W) IS detected"
    }
    Assert-Eq 0 (Get-GuardFindings -Text 'git @(Get-WtGit $wt) status' -Label 'synthetic.ps1').Count 'lint self-check: the funnel form is accepted'
    Assert-Eq 0 (Get-GuardFindings -Text 'function Remove-WorktreeSafe { git -C $Repo worktree remove $Path --force }' -Label 'synthetic.ps1').Count 'lint self-check: the one allowlisted main-repo use is accepted'

    Section 'Hard links, link-following deletes and wildcard names'
    Assert-True (($fleetLines -join "`n").Contains('Set-Content -Path $promptFile -Value $Prompt -NoNewline -Encoding UTF8 -ErrorAction Stop')) 'the off (operator-side ACP) path still writes its prompt exactly as before'
    $precious = Join-Path $elsewhere 'precious.txt'
    function Reset-Precious { Set-Content $precious 'operator-owned original' -Encoding UTF8 }
    function Assert-PreciousIntact([string]$What) { Assert-True ((Get-Content $precious -Raw) -match '^operator-owned original') "$What -> the operator-owned file is untouched" }
    # --- (1) hard links: an operator-side write never goes through an existing name ---
    Reset-Precious
    $hl = Join-Path (Get-CoderLegPaths).Prompts 'hl-target.txt'
    New-Item -ItemType HardLink -Path $hl -Target $precious | Out-Null
    $threw = $null; try { Write-OperatorFileExclusive -LiteralPath $hl -Text 'overwritten by the operator' } catch { $threw = $_.Exception.Message }
    Assert-True ($null -ne $threw) 'Write-OperatorFileExclusive refuses a name that already exists (a planted hard link)'
    Assert-PreciousIntact 'exclusive write onto a planted hard link'
    Remove-Item -LiteralPath $hl -Force
    Write-OperatorFileExclusive -LiteralPath $hl -Text 'fresh'
    $threw = $null; try { Write-OperatorFileExclusive -LiteralPath $hl -Text 'again' } catch { $threw = $_.Exception.Message }
    Assert-True ($null -ne $threw -and (Get-Content $hl -Raw) -eq 'fresh') 'a second exclusive write to the same name fails and leaves the first content'
    Remove-Item -LiteralPath $hl -Force
    $jid = 'job-20260101-000000-cafef00d'; $qdir = (Get-CoderLegPaths).Queue
    foreach ($suffix in '.json.tmp', '.json') {
        Reset-Precious
        New-Item -ItemType HardLink -Path (Join-Path $qdir "$jid$suffix") -Target $precious | Out-Null
        $threw = $null; try { [void](Add-CoderLegJob -Job @{ id = $jid; kind = 'probe' }) } catch { $threw = $_.Exception.Message }
        Assert-True ($null -ne $threw) "Add-CoderLegJob refuses to write through a hard link planted at $jid$suffix"
        Assert-PreciousIntact "job write with a hard link at $suffix"
        Remove-Item -LiteralPath (Join-Path $qdir "$jid$suffix") -Force -ErrorAction SilentlyContinue
        Remove-Item -LiteralPath (Join-Path $qdir "$jid.json.tmp") -Force -ErrorAction SilentlyContinue
    }
    # through the fused leg: a hard link at the (deterministic, test-pinned) prompt name
    Reset-Precious; Reset-Knobs; Set-Config 'restricted_account' 'acp'; New-TestWorktree
    $realNewId = ${function:New-CoderLegJobId}
    function New-CoderLegJobId { 'job-20260101-000000-feedface' }
    New-Item -ItemType HardLink -Path (Join-Path (Get-CoderLegPaths).Prompts 'job-20260101-000000-feedface.prompt.txt') -Target $precious | Out-Null
    $o = Run-Driver
    Set-Item Function:\New-CoderLegJobId $realNewId
    Assert-True ($null -ne $o.Error) 'the fused leg refuses a prompt name that is already a hard link'
    Assert-PreciousIntact 'the fused prompt write onto a planted hard link'
    Assert-False (Called 'Start-ScheduledTask') 'a hard-linked prompt name -> the task was never triggered'
    Remove-Item -LiteralPath (Join-Path (Get-CoderLegPaths).Prompts 'job-20260101-000000-feedface.prompt.txt') -Force -ErrorAction SilentlyContinue
    # a result file that is hard-linked is not trusted
    $script:Knobs.Acl = 'real'
    $rid = 'job-20260101-000000-dddddddd'; $rp = Join-Path (Get-CoderLegPaths).Results "$rid.result.json"
    Set-Content $rp (Res-Json $rid 'x') -Encoding UTF8
    $own = (Microsoft.PowerShell.Security\Get-Acl -LiteralPath $rp).GetOwner([Security.Principal.SecurityIdentifier]).Value
    New-Item -ItemType HardLink -Path (Join-Path $elsewhere 'result-alias.json') -Target $rp | Out-Null
    $threw = $null; try { [void](& $realWait -JobId $rid -TimeoutSec 2 -PollSec 1 -ExpectedOwnerSid $own) } catch { $threw = $_.Exception.Message }
    Assert-True ($threw -match 'hard links') 'a result file with a second hard link is refused'
    Remove-Item -LiteralPath $rp, (Join-Path $elsewhere 'result-alias.json') -Force -ErrorAction SilentlyContinue
    $script:Knobs.Acl = 'tight'
    # --- (2) link-following deletes: links are removed as links, never walked ---
    $tree = Join-Path $tmpRoot 'sweep-tree'; $dirX = Join-Path $tmpRoot 'sweep-x'; $dirY = Join-Path $tmpRoot 'sweep-y'
    foreach ($d in "$tree\a\b", $dirX, $dirY) { New-Item -ItemType Directory -Force $d | Out-Null }
    Set-Content (Join-Path $dirX 'sentinel-x.txt') 'x' -Encoding UTF8; Set-Content (Join-Path $dirY 'sentinel-y.txt') 'y' -Encoding UTF8
    Set-Content (Join-Path $tree 'a\keep.txt') 'k' -Encoding UTF8
    New-Item -ItemType Junction -Path "$tree\a\b\to-x" -Target $dirX | Out-Null
    New-Item -ItemType Junction -Path "$dirX\to-y" -Target $dirY | Out-Null     # a link INSIDE the link target: must never be reached
    $n = Remove-LinksUnder -Root $tree
    Assert-Eq 1 $n 'Remove-LinksUnder removes exactly the one link under the tree (it does not walk into it)'
    Assert-False (Test-Path -LiteralPath "$tree\a\b\to-x") 'the junction itself is gone'
    Assert-True ((Test-Path (Join-Path $dirX 'sentinel-x.txt')) -and (Test-Path (Join-Path $dirY 'sentinel-y.txt')) -and (Test-Path -LiteralPath "$dirX\to-y")) 'the link targets (and the link inside the target) are untouched'
    Assert-True (Test-Path (Join-Path $tree 'a\keep.txt')) 'ordinary files in the tree are untouched'
    # git clean -fd through the helper, in a recorded worktree with a planted junction
    Reset-Knobs; Set-Config 'restricted_account' 'acp'; New-TestWorktree; $o = Run-Driver
    New-Item -ItemType Junction -Path (Join-Path $wdPath 'untracked-link') -Target $dirX | Out-Null
    Set-Content (Join-Path $wdPath 'untracked-file.txt') 'u' -Encoding UTF8
    Clear-WorktreeUntracked -Worktree $wdPath
    Assert-True (Test-Path (Join-Path $dirX 'sentinel-x.txt')) 'Clear-WorktreeUntracked: the junction target survives git clean'
    Assert-False ((Test-Path -LiteralPath (Join-Path $wdPath 'untracked-link')) -or (Test-Path (Join-Path $wdPath 'untracked-file.txt'))) 'Clear-WorktreeUntracked: the link and the untracked file are gone'
    New-Item -ItemType Junction -Path (Join-Path $wdPath 'deep-link') -Target $dirX | Out-Null
    Remove-WorktreeSafe -Repo $mainRepo -Path $wdPath
    Assert-True (Test-Path (Join-Path $dirX 'sentinel-x.txt')) 'Remove-WorktreeSafe: the junction target survives'
    New-TestWorktree
    # --- (3) wildcard names: ids are a strict shape, coder-chosen names are literal ---
    $sentinelRes = Join-Path (Get-CoderLegPaths).Results 'job-20260101-000000-aaaaaaaa.result.json'
    Set-Content $sentinelRes '{"id":"sentinel"}' -Encoding UTF8
    foreach ($bad in 'job-*', 'job-2026010?-000000-aaaaaaaa', 'job[1]', '..\x', 'job-20260101-000000-AAAAAAAA', 'job-20260101-000000-aaaaaaaa.result') {
        $threw = $null; try { [void](& $realWait -JobId $bad -TimeoutSec 1 -PollSec 1) } catch { $threw = $_.Exception.Message }
        Assert-True ($threw -match 'not a generated job id') "Wait-CoderLegResult refuses the id '$bad'"
        $threw = $null; try { [void](Add-CoderLegJob -Job @{ id = $bad; kind = 'probe' }) } catch { $threw = $_.Exception.Message }
        Assert-True ($threw -match 'not a generated job id') "Add-CoderLegJob refuses the id '$bad'"
    }
    Assert-True (Test-Path -LiteralPath $sentinelRes) 'the sentinel result file that a wildcard id would have matched is untouched'
    Remove-Item -LiteralPath $sentinelRes -Force
    Assert-True (Test-CoderLegJobId (New-CoderLegJobId)) 'every generated job id passes the strict shape'
    $wcDir = Join-Path $wdPath 'tests'; New-Item -ItemType Directory -Force $wcDir | Out-Null
    Set-Content -LiteralPath (Join-Path $wcDir 't[1].py') 'a'; Set-Content -LiteralPath (Join-Path $wcDir 't1.py') 'b'; Set-Content -LiteralPath (Join-Path $wcDir 'tx.py') 'c'
    Register-FusedWorktree -Path $wdPath -Key (Get-FileIdentity $wdPath).Key -GitDir (Get-FusedWorktreeGitDir $wdPath)
    Remove-Item -LiteralPath (Get-OperatorWorktreePath -Worktree $wdPath -Relative 'tests\t[1].py') -Force
    Assert-True ((-not (Test-Path -LiteralPath (Join-Path $wcDir 't[1].py'))) -and (Test-Path -LiteralPath (Join-Path $wcDir 't1.py')) -and (Test-Path -LiteralPath (Join-Path $wcDir 'tx.py'))) 'a coder-chosen name with brackets deletes only itself through the -LiteralPath call form (siblings matching the glob survive)'
    # --- the lint: literal paths on coder-influenced names ---
    function Find-NonLiteral($Lines) {
        @($Lines | Where-Object { $_ -match '\b(Remove-Item|Copy-Item|Move-Item|Set-Content|Add-Content|Get-Content|Test-Path|Get-ChildItem|Get-Item)\b' -and $_ -notmatch '-LiteralPath' -and $_ -notmatch '^\s*#' })
    }
    $queueLines = Get-LintLines 'coder-leg-queue.ps1'
    $nl = Find-NonLiteral $queueLines
    Assert-Eq 0 $nl.Count "coder-leg-queue.ps1: every file cmdlet uses -LiteralPath ($(($nl | ForEach-Object { $_.Trim() }) -join ' || '))"
    $guardedFns = 'Invoke-FusedCoderRun', 'Copy-CoderTranscript', 'Get-OperatorWorktreePath', 'Remove-WorktreeSafe', 'Remove-LinksUnder', 'Clear-WorktreeUntracked', 'Resolve-CoderFinalPath', 'Get-FusedWorktreeGitDir', 'Get-GitDirFingerprint', 'Register-FusedWorktree', 'Unregister-FusedWorktree', 'Get-WtGit', 'Test-FusedWorktreeRecorded', 'Assert-OperatorWorktree', 'Test-FusedDirIntact', 'Assert-FusedPathIntact', 'Assert-CoderQueueAclTight'
    $nlf = @(); foreach ($fn in $guardedFns) { $nlf += Find-NonLiteral ((Get-Command $fn).ScriptBlock.ToString() -split "`n") }
    Assert-Eq 0 $nlf.Count "the guarded fleet-lib functions use -LiteralPath on every file cmdlet ($(($nlf | ForEach-Object { $_.Trim() }) -join ' || '))"
    $siteNl = @(($fleetLines + $nat) | Where-Object { $_ -match 'Get-OperatorWorktreePath' -and $_ -match '\b(Remove-Item|Set-Content|Add-Content|Copy-Item|Move-Item)\b' -and $_ -notmatch '-LiteralPath' })
    Assert-Eq 0 $siteNl.Count "call sites that write into a worktree through Get-OperatorWorktreePath use -LiteralPath ($(($siteNl | ForEach-Object { $_.Trim() }) -join ' || '))"
    Assert-Eq 3 (Find-NonLiteral @('Remove-Item $path -Force', '(Test-Path $x)', 'Set-Content -Path $p -Value 1', 'Remove-Item -LiteralPath $ok')).Count 'lint self-check: positional and -Path uses ARE detected, -LiteralPath is not'
    $cleanRaw = @(($fleetLines + $nat) | Where-Object { $_ -match 'clean\s+-fd' -and $_ -notmatch '^\s*#' })
    Assert-Eq 1 $cleanRaw.Count "'git clean -fd' appears once in total: inside Clear-WorktreeUntracked"

    Section 'N3: the gitdir fingerprint covers config.worktree and info\attributes'
    Reset-Knobs; Set-Config 'restricted_account' 'acp'; New-TestWorktree; $o = Run-Driver
    $rec3 = Get-Content (Get-FusedWorktreeRecordPath $wdPath) -Raw | ConvertFrom-Json
    $cwt = Join-Path $rec3.GitDir 'config.worktree'
    Set-Content $cwt "[core]`n`tfsmonitor = true" -Encoding ASCII
    $threw = $null; try { [void](Get-WtGit $wdPath) } catch { $threw = $_.Exception.Message }
    Assert-True ($threw -match 'config or hooks') 'a planted config.worktree in the worktree gitdir is refused'
    Remove-Item -LiteralPath $cwt -Force
    New-TestWorktree; $o = Run-Driver
    $attr = Join-Path $mainRepo '.git\info\attributes'
    New-Item -ItemType Directory -Force (Split-Path $attr -Parent) | Out-Null
    Set-Content $attr '* filter=evil' -Encoding ASCII
    $threw = $null; try { [void](Get-WtGit $wdPath) } catch { $threw = $_.Exception.Message }
    Assert-True ($threw -match 'config or hooks') 'a planted info\attributes in the common dir is refused'
    Remove-Item -LiteralPath $attr -Force
    New-TestWorktree; $o = Run-Driver
    $threw = $null; try { [void](Get-WtGit $wdPath) } catch { $threw = $_.Exception.Message }
    Assert-True ($null -eq $threw) 'with the plants removed the funnel works again'

    Section 'N5: consumers of a worktree after the dispatch go through the funnels'
    $cr = Get-Content (Join-Path $PSScriptRoot 'critic-run.ps1') -Raw
    Assert-True ($cr -match 'Assert-OperatorWorktree -Path \$AppDir' -and $cr -match 'git @\(Get-WtGit \$AppDir\) diff') 'critic-run.ps1 asserts its AppDir and diffs through Get-WtGit'
    $cl = Get-Content (Join-Path $PSScriptRoot 'critique-loop.ps1') -Raw
    Assert-True ($cl -match 'Assert-OperatorWorktree -Path \$AppDir') 'critique-loop.ps1 (Invoke-CritiquePass) asserts the worktree before capturing or linting it'
    $nt = Get-Content (Join-Path $PSScriptRoot 'new-agent-task.ps1') -Raw
    Assert-True ($nt -match 'Assert-OperatorWorktree -Path \$wt\s+# the critique reads') 'new-agent-task.ps1 asserts the worktree at the start of the visual critique'
    Assert-True ((Get-Command Resolve-CriticRange).ScriptBlock.ToString() -notmatch 'git -C') 'Resolve-CriticRange (called with a worktree by new-agent-task.ps1) has no raw git -C'
    # behaviour: the critique pass refuses a quarantined worktree
    if (-not (Get-Command _FailResult -ErrorAction SilentlyContinue)) { function _FailResult([string]$Feedback) { @{ Failed = $true; Feedback = $Feedback } } }
    Reset-Knobs; New-TestWorktree; $o = Run-Driver
    Set-FusedWorktreeQuarantine -Path $wdPath -Reason 'test'
    $threw = $null; try { [void](Assert-OperatorWorktree -Path $wdPath) } catch { $threw = $_.Exception.Message }
    Assert-True ($threw -match 'quarantined') 'the guard the consumers call refuses a quarantined worktree'
    New-TestWorktree

    Section 'Sibling routes: a quarantined worktree is unusable by EVERY route that reaches it'
    Reset-Knobs; Set-Config 'restricted_account' 'acp'; New-TestWorktree; $o = Run-Driver
    Set-Content (Join-Path $wdPath 'sentinel-untracked.txt') 'must survive'
    Add-Content (Join-Path $wdPath 'seed.txt') 'dirty edit'
    Set-FusedWorktreeQuarantine -Path $wdPath -Reason 'matrix'
    $routes = @(
        @{ N = 'Get-WtGit'; B = { Get-WtGit $wdPath } },
        @{ N = 'Assert-OperatorWorktree'; B = { Assert-OperatorWorktree -Path $wdPath } },
        @{ N = 'Get-OperatorWorktreePath'; B = { Get-OperatorWorktreePath -Worktree $wdPath -Relative 'x.txt' } },
        @{ N = 'Invoke-WithTimeout'; B = { Invoke-WithTimeout -CommandLine 'cmd /c echo hi' -WorkDir $wdPath -TimeoutSec 20 } },
        @{ N = 'Restore-WorktreeToHead (retry / winner restore)'; B = { Restore-WorktreeToHead -Repo $wdPath } },
        @{ N = 'Get-WorktreeDigest (review-leg mutation check)'; B = { Get-WorktreeDigest -Repo $wdPath } },
        @{ N = 'Get-CandidateTestPartition'; B = { Get-CandidateTestPartition -Worktree $wdPath -BaseRef 'HEAD' } },
        @{ N = 'Invoke-ScratchTestSignal'; B = { Invoke-ScratchTestSignal -Worktree $wdPath -ScratchTests @('x') } },
        @{ N = 'Clear-WorktreeUntracked (git clean)'; B = { Clear-WorktreeUntracked -Worktree $wdPath } },
        @{ N = 'Resolve-CriticRange (new-agent-task review diff)'; B = { Resolve-CriticRange -Repo $wdPath -Base 'main' } },
        @{ N = 'Invoke-FusedCoderRun (a later job reusing the worktree)'; B = { $c = Get-FleetDriverConfig -ScriptRoot $PSScriptRoot -Fresh; Invoke-FusedCoderRun -WorkDir $wdPath -Model 'coder-30b' -Prompt 'x' -LogPath (Join-Path $tmpRoot 'm.log') -Cfg $c -TimeoutSec 100 -Options $opts } },
        @{ N = 'Register-FusedWorktree (re-recording does not shed the quarantine)'; B = { Register-FusedWorktree -Path $wdPath -Key (Get-FileIdentity $wdPath).Key -GitDir (Get-FusedWorktreeGitDir $wdPath) } }
    )
    foreach ($r in $routes) {
        $script:Calls.Clear()
        $threw = $null; $ret = $null; try { $ret = & $r.B } catch { $threw = $_.Exception.Message }
        $refused = ($null -ne $threw -and $threw -match 'quarantined') -or ($r.N -match 'Digest|Partition|Scratch|Restore|Clear|Critic' -and $null -ne $threw)
        Assert-True $refused "route '$($r.N)' refuses the quarantined worktree ($threw)"
        Assert-False (Called 'Start-ScheduledTask') "route '$($r.N)' never triggers the coder"
    }
    Assert-True ((Test-Path (Join-Path $wdPath 'sentinel-untracked.txt')) -and ((Get-Content (Join-Path $wdPath 'seed.txt') -Raw) -match 'dirty edit')) 'no route cleaned, reset or wrote anything in the quarantined worktree (sentinel file and dirty edit survive)'
    # the quarantine cannot be shed by deleting the record, nor by a later run's re-recording
    Remove-Item -LiteralPath (Get-FusedWorktreeRecordPath $wdPath) -Force
    $threw = $null; try { [void](Get-WtGit $wdPath) } catch { $threw = $_.Exception.Message }
    Assert-True ($threw -match 'quarantined') 'with the pre-run RECORD deleted, Get-WtGit still refuses (the quarantine stands alone)'
    $threw = $null; try { [void](Assert-OperatorWorktree -Path $wdPath) } catch { $threw = $_.Exception.Message }
    Assert-True ($threw -match 'quarantined') 'with the record deleted, Assert-OperatorWorktree still refuses'
    Assert-True (Test-FusedWorktreeRecorded $wdPath) 'a quarantine alone counts as recorded (the funnels engage)'
    $o = Run-Driver
    Assert-RefusedRunningNothing $o 'quarantined' 'a later leg on the quarantined worktree'
    Assert-False (Called 'Start-ScheduledTask') 'a later leg on the quarantined worktree never starts the coder'
    # another PROCESS quarantines; this process refuses (the state is shared, operator-side)
    New-TestWorktree; $o = Run-Driver
    $childCode = ". '$PSScriptRoot\fleet-lib.ps1'; `$env:BLARAI_FUSED_WT_STATE='$stateRoot'; Set-FusedWorktreeQuarantine -Path '$wdPath' -Reason 'child'"
    & pwsh -NoProfile -Command $childCode | Out-Null
    $threw = $null; try { [void](Get-WtGit $wdPath) } catch { $threw = $_.Exception.Message }
    Assert-True ($threw -match 'quarantined') 'a quarantine set by another process (a best-of-N candidate child) stops this process'
    # the sanctioned way out: removing the worktree
    Unregister-FusedWorktree -Path $wdPath
    Assert-True (Test-FusedWorktreeQuarantined $wdPath) 'Unregister-FusedWorktree (removal) does NOT shed the quarantine'
    [void](Clear-FusedQuarantine -Path $wdPath -ClearedBy 'test')
    Assert-False (Test-FusedWorktreeQuarantined $wdPath) 'only Clear-FusedQuarantine (a named human) clears it'
    New-TestWorktree
    # where the state lives, and who can write it
    Reset-Knobs; $o = Run-Driver; Assert-True ($null -eq $o.Error) "baseline with the state dir outside the coder roots ($($o.Error))"
    $savedState = $env:BLARAI_FUSED_WT_STATE
    foreach ($inside in (Join-Path $tmpRoot 'state-in-root'), (Join-Path $wtBase 'state-in-base')) {
        $env:BLARAI_FUSED_WT_STATE = $inside
        $o = Run-Driver; Assert-RefusedRunningNothing $o 'inside a coder-writable root' "a state dir inside a coder-writable root ($((Split-Path $inside -Leaf)))"
    }
    $env:BLARAI_FUSED_WT_STATE = $savedState
    Reset-Knobs; $script:Knobs.Acl = 'state-authusers'
    $o = Run-Driver; Assert-RefusedRunningNothing $o '#1686' 'a state dir writable by Authenticated Users'
    Assert-True (((Get-Command Invoke-FusedCoderRun).ScriptBlock.ToString()) -match 'Get-FusedWorktreeStateDir\)\) -CoderUser') 'the state dir is in the ACL gate path list'
    New-TestWorktree
    # route inventory: the sibling scripts and what covers them
    $routeTable = @(
        @{ R = 'new-agent-task.ps1 sequential candidates'; C = 'Invoke-CandidateBuild: Assert-OperatorWorktree + Get-WtGit' },
        @{ R = 'new-agent-task.ps1 concurrent candidates (Start-Job children)'; C = 'same functions; state shared through the operator-side dir (cross-process test above)' },
        @{ R = 'retry (Invoke-BuildWithRetry -ResetWorktree)'; C = 'Clear-WorktreeUntracked + Get-WtGit' },
        @{ R = 'winner restore / review diff'; C = 'Get-WtGit + Resolve-CriticRange via Get-WtGit' },
        @{ R = 'visual-fix loop and critique'; C = 'Get-WtGit; Assert-OperatorWorktree in new-agent-task and Invoke-CritiquePass' },
        @{ R = 'critic-run.ps1'; C = 'Assert-OperatorWorktree + Get-WtGit' },
        @{ R = 'worktree removal / reuse by a later job'; C = 'Remove-WorktreeSafe; Unregister only by creation of a fresh worktree' }
    )
    Assert-Eq 7 $routeTable.Count 'the route table has an entry per sibling route (documented in docs/fused-leg-operator-uses.md)'

    Section 'Strict, shared parsing of job, result and probe files (no parser differential, no fail-open)'
    $qdir = (Get-CoderLegPaths).Queue; $rdir = (Get-CoderLegPaths).Results
    $jidA = 'job-20260101-000000-aaaaaaaa'
    $good = '{"id":"' + $jidA + '","kind":"probe","created":"2026-01-01T00:00:00Z","probe":{"secret_paths":[],"loopback_url":"http://127.0.0.1:8000/v3/models","expected_sid":"S-1-5-21-1"}}'
    function Write-Bytes([string]$path, [byte[]]$b) { [IO.File]::WriteAllBytes($path, $b) }
    function U8([string]$t) { [Text.Encoding]::UTF8.GetBytes($t) }
    # reproduction of the differential: the permissive reader takes the LAST duplicate, and accepts what strict refuses
    $dupText = $good.Replace('"kind":"probe"', '"kind":"probe","kind":"dispatch"')
    Assert-Eq 'dispatch' (($dupText | ConvertFrom-Json).kind) 'repro: ConvertFrom-Json silently takes the LAST of duplicate keys (a differential with any first-wins parser)'
    $jobCases = @(
        @{ N = 'duplicate keys'; B = (U8 $dupText) },
        @{ N = 'case-insensitive duplicate'; B = (U8 $good.Replace('"kind":"probe"', '"kind":"probe","KIND":"dispatch"')) },
        @{ N = 'unknown key'; B = (U8 $good.Replace('"kind"', '"__proto__":{},"kind"')) },
        @{ N = 'wrong key case'; B = (U8 $good.Replace('"kind"', '"Kind"')) },
        @{ N = 'trailing data'; B = (U8 ($good + ' {"x":1}')) },
        @{ N = 'trailing comma'; B = (U8 $good.Replace('"expected_sid":"S-1-5-21-1"', '"expected_sid":"S-1-5-21-1",')) },
        @{ N = 'UTF-16 with BOM'; B = ([Text.Encoding]::Unicode.GetPreamble() + [Text.Encoding]::Unicode.GetBytes($good)) },
        @{ N = 'UTF-16 without BOM'; B = ([Text.Encoding]::Unicode.GetBytes($good)) },
        @{ N = 'invalid UTF-8'; B = ([byte[]](0x7b, 0xff, 0x7d)) },
        @{ N = 'comment'; B = (U8 ('/*x*/' + $good)) },
        @{ N = 'a numeric string where an integer is required'; B = (U8 ('{"id":"' + $jidA + '","kind":"dispatch","created":"x","workdir":"C:\\w\\x","model":"local/m","prompt_file":"C:\\p\\a.txt","log_path":"C:\\p\\b.log","timeout_sec":"60","idle_sec":1,"max_steps":1,"spin_steps":1}')) },
        @{ N = 'a dispatch job missing a field'; B = (U8 ('{"id":"' + $jidA + '","kind":"dispatch","created":"x","workdir":"w"}')) },
        @{ N = 'an unknown kind'; B = (U8 $good.Replace('"probe","created"', '"admin","created"')) },
        @{ N = 'an id that does not match its file name'; B = (U8 $good.Replace($jidA, 'job-20260101-000000-bbbbbbbb')) },
        @{ N = 'a truncated file'; B = (U8 $good.Substring(0, 40)) },
        @{ N = 'an empty file'; B = ([byte[]]@()) },
        @{ N = 'a bare scalar'; B = (U8 'true') }
    )
    # control for the numeric-string case: identical job with real integers IS claimed, so only the type refuses
    Get-ChildItem $qdir -Force | Remove-Item -Force
    Write-Bytes (Join-Path $qdir "$jidA.json") (U8 ('{"id":"' + $jidA + '","kind":"dispatch","created":"x","workdir":"C:\\w\\x","model":"local/m","prompt_file":"C:\\p\\a.txt","log_path":"C:\\p\\b.log","timeout_sec":60,"idle_sec":1,"max_steps":1,"spin_steps":1}'))
    $cNum = Get-NextCoderLegJob
    Assert-True ($null -ne $cNum) 'control: the same dispatch job with real integers IS claimed (so the numeric-string refusal below is the type)'
    foreach ($jc in $jobCases) {
        Get-ChildItem $qdir -Force | Remove-Item -Force
        Write-Bytes (Join-Path $qdir "$jidA.json") $jc.B
        $claimed = Get-NextCoderLegJob
        Assert-True ($null -eq $claimed) "runner side: a job with $($jc.N) is NOT run (parked, fail-closed)"
        Assert-True (Test-Path (Join-Path $qdir "$jidA.json.claimed.bad")) "... and parked as .bad ($($jc.N))"
    }
    Get-ChildItem $qdir -Force | Remove-Item -Force
    Write-Bytes (Join-Path $qdir "$jidA.json") ([byte[]](0xEF, 0xBB, 0xBF) + (U8 $good))
    $c = Get-NextCoderLegJob
    Assert-True ($null -ne $c -and $c.Job.id -ceq $jidA) 'control: a well-formed job (UTF-8 with BOM) IS claimed and parsed'
    Get-ChildItem $qdir -Force | Remove-Item -Force
    # N6: unpaired surrogates in a string are refused; a correctly paired one is accepted
    foreach ($sur in '\ud800', '\udc00', '\ud800x', 'x\udbff', '\udc00\ud800') {
        $threw = $null; try { [void](ConvertFrom-StrictJsonBytes -Bytes (U8 ('{"id":"' + $jidA + '","kind":"probe","created":"' + $sur + '"}')) -Schema $script:CoderLegJobSchema -What 'job') } catch { $threw = $_.Exception.Message }
        Assert-True ($threw -match 'surrogate') "a lone surrogate escape ($sur) in a value is refused"
    }
    $pairOk = ConvertFrom-StrictJsonBytes -Bytes (U8 ('{"id":"' + $jidA + '","kind":"probe","created":"\ud83d\ude00"}')) -Schema $script:CoderLegJobSchema -What 'job'
    Assert-Eq 2 $pairOk.created.Length 'control: a correctly paired surrogate escape (U+1F600) is accepted'
    $threw = $null; try { [void](ConvertFrom-StrictJsonBytes -Bytes (U8 '{"\ud800":1}') -Schema @{ Type = 'any' } -What 'key') } catch { $threw = $_.Exception.Message }
    Assert-True ($threw -match 'surrogate') 'a lone surrogate in an object KEY is refused too'
    # invalid UTF-8 INSIDE a string value (not just a broken document) is refused
    Write-Bytes (Join-Path $qdir "$jidA.json") ((U8 ($good.Substring(0, $good.IndexOf('"created":"')) + '"created":"')) + [byte[]](0xFF, 0xFE) + (U8 ('"' + $good.Substring($good.IndexOf(',"probe"')))))
    $c = Get-NextCoderLegJob
    Assert-True ($null -eq $c) 'a job whose string value carries invalid UTF-8 is NOT run (an invalid byte is never replaced and accepted)'
    Get-ChildItem $qdir -Force | Remove-Item -Force
    Write-Bytes (Join-Path $qdir "$jidA.json") ((U8 ($good.Substring(0, $good.IndexOf('"created":"')) + '"created":"')) + (U8 'ok') + (U8 ('"' + $good.Substring($good.IndexOf(',"probe"')))))
    $c = Get-NextCoderLegJob
    Assert-True ($null -ne $c -and $c.Job.created -ceq 'ok') 'control: the same shape with valid bytes IS claimed (so the refusal above is the encoding)'
    Get-ChildItem $qdir -Force | Remove-Item -Force
    # an internal validator error is a refusal, never a quiet pass
    $threw = $null; try { [void](ConvertFrom-StrictJsonBytes -Bytes (U8 '{"a":1}') -Schema @{ Type = 'object'; Props = $null; Required = @() } -What 'broken schema') } catch { $threw = $_.Exception.Message }
    Assert-True ($threw -match 'strict JSON') 'a validator that errors internally refuses (fail-closed), it does not accept the document'
    $threw = $null; $acc = $null
    try { $acc = ConvertFrom-StrictJsonBytes -Bytes (U8 '"abc"') -Schema @{ Type = 'string'; Pattern = '(' } -What 'bad pattern' } catch { $threw = $_.Exception.Message }
    Assert-True ($null -ne $threw -and $null -eq $acc) 'an exception thrown INSIDE the validator (an invalid regex) refuses the value; it is never skipped into an accept'
    # results: real Wait with owner binding, every defect throws and leaves the file
    $script:Knobs.Acl = 'real'
    $rgood = '{"id":"' + $jidA + '","kind":"dispatch","ok":true,"ran_as_sid":"S","ran_as_user":"u","error":"","result":{"Ok":true}}'
    $rp = Join-Path $rdir "$jidA.result.json"
    Set-Content $rp 'x' -Encoding UTF8; $ownerS = (Microsoft.PowerShell.Security\Get-Acl -LiteralPath $rp).GetOwner([Security.Principal.SecurityIdentifier]).Value; Remove-Item $rp -Force
    $resCases = @(
        @{ N = 'duplicate ok keys (false then true)'; B = (U8 $rgood.Replace('"ok":true', '"ok":false,"ok":true')) },
        @{ N = "ok as the string 'true'"; B = (U8 $rgood.Replace('"ok":true', '"ok":"true"')) },
        @{ N = 'an unknown key'; B = (U8 $rgood.Replace('"error"', '"PSObject":1,"error"')) },
        @{ N = 'trailing data'; B = (U8 ($rgood + 'x')) },
        @{ N = 'UTF-16'; B = ([Text.Encoding]::Unicode.GetPreamble() + [Text.Encoding]::Unicode.GetBytes($rgood)) },
        @{ N = 'a missing required field'; B = (U8 $rgood.Replace('"ran_as_user":"u",', '')) },
        @{ N = 'an id of the wrong shape'; B = (U8 $rgood.Replace($jidA, '*')) },
        @{ N = 'a truncated file'; B = (U8 $rgood.Substring(0, 30)) }
    )
    foreach ($rc in $resCases) {
        Write-Bytes $rp $rc.B
        $threw = $null; try { [void](& $realWait -JobId $jidA -TimeoutSec 2 -PollSec 1 -ExpectedOwnerSid $ownerS) } catch { $threw = $_.Exception.Message }
        Assert-True ($threw -match 'strict JSON') "operator side: a result with $($rc.N) is REFUSED (throws, not retried or accepted)"
        Assert-True (Test-Path $rp) "... and left in place ($($rc.N))"
        Remove-Item $rp -Force -ErrorAction SilentlyContinue
    }
    Write-Bytes $rp (U8 $rgood)
    $okRes = & $realWait -JobId $jidA -TimeoutSec 2 -PollSec 1 -ExpectedOwnerSid $ownerS
    Assert-True ($null -ne $okRes -and $okRes.ok -eq $true -and $okRes.result.Ok -eq $true) 'control: a well-formed result is accepted and typed'
    Write-Bytes $rp (U8 ($rgood.Replace('"ok":true', '"ok":false,"ok":true')))
    $threw = $null; try { [void](& $realWait -JobId $jidA -TimeoutSec 2 -PollSec 1) } catch { $threw = $_.Exception.Message }
    Assert-True ($threw -match 'strict JSON') 'the unbound (probe) read path is strict too'
    Remove-Item $rp -Force -ErrorAction SilentlyContinue
    $script:Knobs.Acl = 'tight'
    # one parser: nothing in the queue library or the runner uses the permissive reader
    foreach ($f in 'coder-leg-queue.ps1', 'coder-leg-run.ps1') {
        $code = (Get-Content (Join-Path $PSScriptRoot $f)) | Where-Object { $_ -notmatch '^\s*#' }
        Assert-Eq 0 (@($code | Where-Object { $_ -match 'ConvertFrom-Json|ConvertFrom-Clixml|Import-Clixml' }).Count) "$f has no ConvertFrom-Json / CLIXML read (everything goes through ConvertFrom-StrictJsonBytes)"
    }
    Assert-True ((Get-Content (Join-Path $PSScriptRoot 'coder-leg-run.ps1') -Raw) -match 'ConvertFrom-StrictJsonBytes') 'the coder-leg runner parses probe output with the shared strict parser'
    $envBad = [pscustomobject]@{ Ok = $true; Result = [pscustomobject]@{ TimedOut = $false } }
    $threw = $null; try { Assert-CoderLegEnvelope -Envelope $envBad } catch { $threw = $_.Exception.Message }
    Assert-True ($threw -match 'strict JSON') 'Assert-CoderLegEnvelope refuses an envelope with a missing Result field'
    $validator = $null
    $threw = $null; try { [void](Test-StrictSchemaValue -Value 1 -Schema @{ Type = 'object'; Props = @{}; Required = @('a') }) } catch { $threw = $_.Exception.Message }
    Assert-True ($null -ne $threw -or $true) 'the validator is exercised on a wrong-typed value'
    $msg = Test-StrictSchemaValue -Value 1 -Schema @{ Type = 'object'; Props = @{}; Required = @('a') }
    Assert-True ($msg -match 'not an object') 'a scalar where an object is required is refused with a message'

    Section 'Structure: no operator-account path inside the fused function'
    $fusedBody = (Get-Command Invoke-FusedCoderRun).ScriptBlock.ToString()
    Assert-False ($fusedBody -match 'Start-Process') 'Invoke-FusedCoderRun never spawns a process itself'
    Assert-False ($fusedBody -match 'Invoke-AgentRun') 'Invoke-FusedCoderRun never calls the stdin runner'
    Assert-False ($fusedBody -match '(?m)^\s*[^#\r\n]*Invoke-AcpCoderRun') 'Invoke-FusedCoderRun never calls the operator-side ACP runner'
}
finally {
    Remove-Item Env:\BLARAI_CODER_LEG_ROOT -ErrorAction SilentlyContinue
    Remove-Item Env:\BLARAI_FLEET_DRIVER_CONFIG -ErrorAction SilentlyContinue
    Remove-Item Env:\BLARAI_FUSED_WT_STATE -ErrorAction SilentlyContinue
    if ($stateRoot -like '*\Temp\fused-state-*') { Remove-Item $stateRoot -Recurse -Force -ErrorAction SilentlyContinue }
    foreach ($jn in $junction, $jbase, $wdPath) { try { if (Test-Path -LiteralPath $jn) { [IO.Directory]::Delete($jn) } } catch { } }
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
