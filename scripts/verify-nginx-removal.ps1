#requires -Version 7.0
<#
.SYNOPSIS
  Verifies remove-nginx-gateway.ps1 (#1695) OFFLINE. The real script code runs (dot-sourced; its own
  Invoke-NginxRemoval and folder functions) against a FAKE system-call table (service, tasks, firewall rules,
  processes, listeners, elevation) and a REAL temp tree for the folder work (a real junction inside it, real
  takeown.exe, real access lists). NOTHING on the machine is changed, and -Execute is never passed to a real
  child process.

.DESCRIPTION
  WHAT IS REAL: the script's code paths, the link-safe walk, takeown.exe, Get-Acl / handle-based access-list
  edits, the folder move, the conf copy, the log file.
  WHAT IS A FAKE: the Service Control Manager, Task Scheduler, firewall, process and socket tables, and the
  elevation test. The accounts that "may keep the folder" are the current user, SYSTEM and Administrators (the
  current user stands in for the operator, who is an Administrators member); the production default
  (SYSTEM + Administrators only) is asserted separately as a constant.
  A read-only smoke runs the REAL script as a child process in dry-run mode and asserts the machine is
  unchanged (service, task and rule counts, C:\nginx presence) before and after.

  -Mutations re-runs THIS suite against mutated copies of the sources (each control disabled in turn). KILLED =
  non-zero exit AND a [FAIL] line; SURVIVED = exit 0; ERROR = non-zero with no [FAIL] line. The unmutated
  control must pass first. -ProveHarness shows the classification on a known survivor, crasher and kill.
  Exit 0 if everything passed.
#>
param([switch]$Mutations, [switch]$ProveHarness, [switch]$NoSmoke, [string[]]$Only = @(), [int]$Throttle = 3)
$ErrorActionPreference = 'Stop'

if ($Mutations -or $ProveHarness) {
    try { (Get-Process -Id $PID).PriorityClass = 'BelowNormal' } catch { }
    . "$PSScriptRoot\hidden-process-lib.ps1"
    $pw = (Get-Command pwsh -ErrorAction SilentlyContinue).Source
    $files = 'remove-nginx-gateway.ps1', 'verify-nginx-removal.ps1', 'coder-acl-lib.ps1', 'hidden-process-lib.ps1'
    $run = {
        param($Dir, $Mut, $files, $pw, $SrcDir)
        . (Join-Path $SrcDir 'hidden-process-lib.ps1')
        $sd = Join-Path $Dir 'scripts'; New-Item -ItemType Directory -Force $sd | Out-Null
        foreach ($f in $files) { Copy-Item (Join-Path $SrcDir $f) (Join-Path $sd $f) }
        if ($Mut) {
            $target = Join-Path $sd $Mut.F
            $text = ([IO.File]::ReadAllText($target)).Replace("`r`n", "`n")   # match on LF: a CRLF working copy is the same text
            $mo = ([string]$Mut.O).Replace("`r`n", "`n"); $mw = ([string]$Mut.W).Replace("`r`n", "`n")
            if (-not $text.Contains($mo)) { return @{ Class = 'ERROR'; Why = "mutation target not found in $($Mut.F)" } }
            [IO.File]::WriteAllText($target, $text.Replace($mo, $mw), (New-Object Text.UTF8Encoding($true)))
        }
        $h = Invoke-HiddenProcess -FilePath $pw -ArgumentList @('-NoProfile', '-NonInteractive', '-File', (Join-Path $sd 'verify-nginx-removal.ps1'), '-NoSmoke') -TimeoutSec 900
        $out = $h.Stdout + "`n" + $h.Stderr
        $fails = @($out -split "`n" | Where-Object { $_ -match '\[FAIL\]' })
        if ($h.ExitCode -eq 0) { return @{ Class = 'SURVIVED'; Why = 'the suite did not notice' } }
        if ($fails.Count -gt 0) { return @{ Class = 'KILLED'; Why = ("$($fails[0])").Trim() } }
        return @{ Class = 'ERROR'; Why = 'non-zero exit with no [FAIL] line: ' + (($out -split "`n" | Where-Object { $_.Trim() } | Select-Object -Last 3) -join ' | ') }
    }
    function Invoke-MutationRun([object[]]$Muts) {
        $tmp = Join-Path ([IO.Path]::GetTempPath()) ('nginxrm-mut-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
        $ctl = & $run (Join-Path $tmp 'control') $null $files $pw $PSScriptRoot
        $controlOk = ($ctl.Class -eq 'SURVIVED'); $res = @()
        if (-not $controlOk) { Write-Host "  [CONTROL FAILED] the unmutated copy does not pass: $($ctl.Why)" -ForegroundColor Red }
        else {
            Write-Host '  [control]  unmutated copy passes' -ForegroundColor Green
            $runText = $run.ToString()
            $res = @($Muts | ForEach-Object -ThrottleLimit ([math]::Max(1, $Throttle)) -Parallel {
                    $m = $_; $rb = [scriptblock]::Create($using:runText)
                    $r = & $rb (Join-Path $using:tmp ('m-' + $m.N)) $m $using:files $using:pw $using:PSScriptRoot
                    Write-Host ("  [{0}] {1}  <- {2}" -f $r.Class.PadRight(8), $m.N, $r.Why) -ForegroundColor $(if ($r.Class -eq 'KILLED') { 'Green' } else { 'Red' })
                    @{ N = $m.N; Class = $r.Class; Why = $r.Why }
                })
        }
        Remove-Item $tmp -Recurse -Force -ErrorAction SilentlyContinue
        return @{ Control = $controlOk; Results = $res }
    }
    $R = 'remove-nginx-gateway.ps1'; $A = 'coder-acl-lib.ps1'
    if ($ProveHarness) {
        $probe = @(
            @{ N = 'equivalent-comment-change'; F = $R; O = '# ---- the plan view (read-only) ----'; W = '# ---- the plan view (renamed) ----' },
            @{ N = 'crashing-syntax-break';     F = $R; O = 'function Assert-RemovalAllowed {'; W = 'function Assert-RemovalAllowed { }}}}' },
            @{ N = 'real-kill-guard-disabled';  F = $R; O = 'if ($list -cnotcontains $Name) { throw'; W = 'if ($false) { throw' }
        )
        $r = Invoke-MutationRun $probe
        $want = @{ 'equivalent-comment-change' = 'SURVIVED'; 'crashing-syntax-break' = 'ERROR'; 'real-kill-guard-disabled' = 'KILLED' }
        $bad = @($r.Results | Where-Object { $want[$_.N] -ne $_.Class })
        if ($r.Control -and $bad.Count -eq 0 -and $r.Results.Count -eq 3) { Write-Host 'HARNESS PROVEN: survivor reported SURVIVED, crasher reported ERROR, real kill reported KILLED' -ForegroundColor Green; exit 0 }
        Write-Host 'HARNESS NOT PROVEN' -ForegroundColor Red; exit 1
    }
    $muts = @(
        @{ N = 'allowlist-guard-disabled';       F = $R; O = 'if ($list -cnotcontains $Name) { throw'; W = 'if ($false) { throw' },
        @{ N = 'allowlist-widened-to-prefix';    F = $R; O = 'if ($list -cnotcontains $Name) { throw'; W = 'if (-not @($list | Where-Object { $Name -like ($_ + ''*'') }).Count) { throw' },
        @{ N = 'allowlist-widened-to-wildcard';  F = $R; O = 'if ($list -cnotcontains $Name) { throw'; W = 'if (-not ($Name -like ''*ngin*'' -or $list -contains $Name)) { throw' },
        @{ N = 'allowlist-case-insensitive';     F = $R; O = 'if ($list -cnotcontains $Name) { throw'; W = 'if ($list -notcontains $Name) { throw' },
        @{ N = 'task-name-added-to-list';        F = $R; O = '''GatewayNginxPruneMonthly'')'; W = '''GatewayNginxPruneMonthly'', ''Evil'')' },
        @{ N = 'trusted-sids-widened';           F = $R; O = '$script:RemovalTrustedSids = @(''S-1-5-18'', ''S-1-5-32-544'')'; W = '$script:RemovalTrustedSids = @(''S-1-5-18'', ''S-1-5-32-544'', ''S-1-5-11'')' },
        @{ N = 'folder-gate-disabled';           F = $R; O = 'throw "refusing folder ''$Path'': only'; W = 'return; throw "refusing folder ''$Path'': only' },
        @{ N = 'quarantine-gate-disabled';       F = $R; O = 'throw "refusing quarantine root ''$Root''"'; W = 'return' },
        @{ N = 'dry-run-default-flipped';        F = $R; O = '    if (-not $Execute) {
        if (-not $state.Elevated)'; W = '    if ($Execute) {
        if (-not $state.Elevated)' },
        @{ N = 'dry-run-acts-anyway';            F = $R; O = '        return (& $result $(if ($refusals.Count -gt 0) { 2 } else { 0 }) $refusals)
    }'; W = '    }' },
        @{ N = 'elevation-check-removed';        F = $R; O = 'if ($IsExecute -and -not $State.Elevated) {'; W = 'if ($false) {' },
        @{ N = 'process-check-removed';          F = $R; O = 'if ($State.NginxProcesses -gt 0) {'; W = 'if ($false) {' },
        @{ N = 'listener-check-removed';         F = $R; O = 'if (@($State.Listeners).Count -gt 0) {'; W = 'if ($false) {' },
        @{ N = 'listener-port-8081-dropped';     F = $R; O = '$script:RemovalPorts = @(443, 8081)'; W = '$script:RemovalPorts = @(443)' },
        @{ N = 'listener-port-443-dropped';      F = $R; O = '$script:RemovalPorts = @(443, 8081)'; W = '$script:RemovalPorts = @(8081)' },
        @{ N = 'service-identity-unchecked';     F = $R; O = 'if (-not ([string]$State.Service.PathName).StartsWith($Plan.ServiceImagePrefix, [StringComparison]::OrdinalIgnoreCase)) {'; W = 'if ($false) {' },
        @{ N = 'task-identity-unchecked';        F = $R; O = '([string]$t.Task.ActionText) -notmatch ''(?i)nginx'') {'; W = '$false) {' },
        @{ N = 'rule-identity-unchecked';        F = $R; O = '($f.Direction -ne ''Inbound'' -or $f.Action -ne ''Allow'')) {'; W = '$false) {' },
        @{ N = 'folder-requires-service-dropped'; F = $R; O = 'if ($State.Service -and $Scope -notcontains ''Service'') {'; W = 'if ($false) {' },
        @{ N = 'folder-requires-tasks-dropped';  F = $R; O = 'if ($liveTasks.Count -gt 0 -and $Scope -notcontains ''Tasks'') {'; W = 'if ($false) {' },
        @{ N = 'other-references-ignored';       F = $R; O = 'foreach ($o in @($State.Others | Where-Object { $_.Enabled })) {'; W = 'foreach ($o in @()) {' },
        @{ N = 'delete-without-folder-allowed';  F = $R; O = 'if ($DeleteQuarantine -and $Scope -notcontains ''Folder'') {'; W = 'if ($false) {' },
        @{ N = 'quarantine-volume-unchecked';    F = $R; O = 'if ([IO.Path]::GetPathRoot($q) -ine [IO.Path]::GetPathRoot($Plan.Folder)) {'; W = 'if ($false) {' },
        @{ N = 'quarantine-skipped-and-unchecked'; F = $R; O = '                    [IO.Directory]::Move($Plan.Folder, $dest)
                    if (Test-Path -LiteralPath $Plan.Folder) { throw "''$($Plan.Folder)'' still exists after the move" }
'; W = '' },
        @{ N = 'quarantine-skipped';             F = $R; O = '[IO.Directory]::Move($Plan.Folder, $dest)'; W = '$null = 0' },
        @{ N = 'takeown-not-to-administrators';  F = $R; O = '& takeown.exe /A /F $Path'; W = '& takeown.exe /F $Path' },
        @{ N = 'qroot-owner-not-administrators'; F = $R; O = '    $sec.SetOwner($adminsSid)
'; W = '' },
        @{ N = 'qmarker-owner-not-administrators'; F = $R; O = '    $fsec.SetOwner($adminsSid)
'; W = '' },
        @{ N = 'existing-quarantine-root-trusted'; F = $R; O = 'if (-not (Test-Path -LiteralPath $marker)) { throw'; W = 'if ($false) { throw' },
        @{ N = 'existing-quarantine-root-unchecked'; F = $R; O = 'if (-not $chk.Ok) { throw "the existing quarantine root'; W = 'if ($false) { throw "the existing quarantine root' },
        @{ N = 'pre-move-lock-recheck-removed'; F = $R; O = 'if (-not $pre.Ok) { throw ''the folder is not locked at the moment of the move: refusing'' }'; W = '' },
        @{ N = 'takeown-skipped';                F = $R; O = '            & $TakeOwnership $p
'; W = '' },
        @{ N = 'lock-keeps-inheritance';         F = $R; O = '$acl.SetAccessRuleProtection($true, $false)
                    foreach ($r in @($acl.GetAccessRules($true, $false'; W = '$acl.SetAccessRuleProtection($false, $true)
                    foreach ($r in @($acl.GetAccessRules($true, $false' },
        @{ N = 'lock-keeps-old-entries';         F = $R; O = '[void]$acl.RemoveAccessRuleSpecific($r) }'; W = '}' },
        @{ N = 'lock-verification-skipped';      F = $R; O = '                    if (-not $chk.Ok) { throw "verification failed:'; W = '                    if ($false) { throw "verification failed:' },
        @{ N = 'lock-walk-errors-ignored';       F = $R; O = 'if (@($w.Errors).Count -gt 0) { throw "the lock walk had'; W = 'if ($false) { throw "the lock walk had' },
        @{ N = 'verifier-ignores-owner';         F = $R; O = 'if ($sids -notcontains $got.Owner) { [void]$script:__viol.Add("$p : owner is $($got.Owner)") }'; W = '' },
        @{ N = 'verifier-ignores-inheritance';   F = $R; O = 'if (-not $acl.AreAccessRulesProtected) { [void]$script:__viol.Add("$p : inherits from its parent") }'; W = '' },
        @{ N = 'verifier-ignores-foreign-entries'; F = $R; O = 'if ($sids -notcontains $r.IdentityReference.Value) { [void]$script:__viol.Add("$p : entry for $($r.IdentityReference.Value)") }'; W = '' },
        @{ N = 'verifier-passes-with-errors';    F = $R; O = '$v.Count -eq 0 -and @($w.Errors).Count -eq 0 -and $w.Visited -gt 0'; W = '$v.Count -eq 0' },
        @{ N = 'service-postcondition-removed';  F = $R; O = 'if (-not (& $Sys.ServiceGone $script:RemovalAllowedService[0])) { throw ''the service is still present and not marked for deletion'' }'; W = '' },
        @{ N = 'service-stop-unchecked';         F = $R; O = 'if ($now -and $now.State -ne ''Stopped'') { throw "the service did not stop'; W = 'if ($false) { throw "the service did not stop' },
        @{ N = 'task-postcondition-removed';     F = $R; O = 'if (& $Sys.GetTask $name) { throw "task $name is still registered" }'; W = '' },
        @{ N = 'rule-postcondition-removed';     F = $R; O = 'if (@(& $Sys.GetRules $name | Where-Object { $_.Id -eq $f.Id }).Count -gt 0) { throw "rule ''$name'' is still present" }'; W = '' },
        @{ N = 'final-readback-removed';         F = $R; O = 'if ($left.Count -gt 0) { throw "read-back: still present:'; W = 'if ($false) { throw "read-back: still present:' },
        @{ N = 'step-failure-does-not-stop';     F = $R; O = '& $log ''FAIL'' "$stepTitle : $($_.Exception.Message)"; throw }'; W = '& $log ''FAIL'' "$stepTitle : $($_.Exception.Message)" }' },
        @{ N = 'failure-exit-code-zero';         F = $R; O = 'return (& $result 3 @($_.Exception.Message))'; W = 'return (& $result 0 @($_.Exception.Message))' },
        @{ N = 'refusal-exit-code-zero';         F = $R; O = 'if ($refusals.Count -gt 0) { return (& $result 2 $refusals) }'; W = 'if ($refusals.Count -gt 0) { return (& $result 0 $refusals) }' },
        @{ N = 'service-step-before-lock';       F = $R; O = '        $dest = Get-RemovalDestination -Plan $Plan
        $folderHere'; W = '        $null = & $Sys.DeleteService ''NginxGateway''
        $dest = Get-RemovalDestination -Plan $Plan
        $folderHere' },
        @{ N = 'idempotence-service-recalled';   F = $R; O = 'if (-not $svc) { & $log ''INFO'' ''already done: service NginxGateway is not present'' }'; W = 'if ($false) { }' },
        @{ N = 'idempotence-task-recalled';      F = $R; O = 'if (-not $t) { & $log ''INFO'' "already done: task $name is not present"; continue }'; W = '' },
        @{ N = 'delete-follows-links';           F = $R; O = 'if ($attr -band [IO.FileAttributes]::ReparsePoint) {'; W = 'if ($false) {' },
        @{ N = 'delete-keeps-readonly';          F = $R; O = 'if ($attr -band [IO.FileAttributes]::ReadOnly) { [IO.File]::SetAttributes($e, [IO.FileAttributes]::Normal) }'; W = '' },
        @{ N = 'delete-link-as-folder-recursion'; F = $R; O = 'if ($attr -band [IO.FileAttributes]::Directory) { [IO.Directory]::Delete($e) } else { [IO.File]::Delete($e) }'; W = 'Remove-RemovalTree -Path $e' },
        @{ N = 'delete-root-link-unchecked';     F = $R; O = 'if ($rootAttr -band [IO.FileAttributes]::ReparsePoint) { throw "refusing to delete ''$Path'': it is a link (junction or symlink), not a real folder" }'; W = '' },
        @{ N = 'delete-root-recheck-dropped';    F = $R; O = 'if (-not $qchk.Ok) { throw'; W = 'if ($false) { throw' },
        @{ N = 'delete-copy-recheck-dropped';    F = $R; O = 'if (-not $dchk.Ok) { throw'; W = 'if ($false) { throw' },
        @{ N = 'delete-readonly-folder-not-cleared'; F = $R; O = 'if ($rootAttr -band [IO.FileAttributes]::ReadOnly) { [IO.File]::SetAttributes($Path,'; W = 'if ($false) { [IO.File]::SetAttributes($Path,' },
        @{ N = 'delete-readonly-link-not-cleared'; F = $R; O = 'if ($attr -band [IO.FileAttributes]::ReadOnly) { [IO.File]::SetAttributes($e, [IO.FileAttributes]($attr -band (-bnot [IO.FileAttributes]::ReadOnly))) }'; W = '' },
        @{ N = 'delete-quarantine-default-on';   F = $R; O = '            if ($DeleteQuarantine) {
                if (-not (Test-Path'; W = '            if ($true) {
                if (-not (Test-Path' },
        @{ N = 'delete-quarantine-flag-ignored'; F = $R; O = '            if ($DeleteQuarantine) {
                if (-not (Test-Path'; W = '            if ($false) {
                if (-not (Test-Path' },
        @{ N = 'delete-marker-unchecked';        F = $R; O = 'if (-not (Test-Path -LiteralPath ([IO.Path]::Combine($Plan.QuarantineRoot, ''.nginx-gateway-quarantine'')))) { throw ''the quarantine marker is missing: refusing to delete'' }'; W = '' },
        @{ N = 'conf-copy-skipped';              F = $R; O = '            $c = Confirm-RemovalConfBackup -Source (Join-Path $Plan.Folder ''conf\nginx.conf'') -BackupDir $Plan.ConfBackupDir -Write $true'; W = '            $c = @{ Ok = $true; Action = ''skipped''; Path = '''' }' },
        @{ N = 'conf-copy-overwrites';           F = $R; O = '$dest2 = Join-Path $BackupDir (''nginx.conf.'' + (Get-Date -Format ''yyyyMMdd-HHmmss'') + ''.'' + $h.Substring(0, 8))'; W = '$dest2 = $dest' },
        @{ N = 'log-not-written';                F = $R; O = 'if ($logPath) { Add-Content -LiteralPath $logPath -Value $line -Encoding UTF8 }'; W = '' },
        @{ N = 'key-material-listed';            F = $R; O = 'if ($p -match ''(?i)\.(key|pfx|p12|pk8)$'') { [void]$script:__inv.Keys.Add($p.Substring($root.Length).TrimStart(''\'')) }'; W = 'if ($p -match ''(?i)\.(key|pfx|p12|pk8)$'') { [void]$script:__inv.Keys.Add((Get-Content -LiteralPath $p -Raw)) }' },
        @{ N = 'key-names-not-counted';          F = $R; O = '        & $Out ("  private-key file NAMES (by .key/.pfx/.p12/.pk8 extension; contents are never read): {0}" -f @($f.KeyNames).Count)'; W = '' },
        @{ N = 'walk-enters-links';              F = $A; O = 'if ($attr -band [IO.FileAttributes]::ReparsePoint) { [void]$res.Links.Add($e); continue }'; W = 'if ($false) { continue }' }
    )
    if ($Only.Count -gt 0) { $muts = @($muts | Where-Object { $Only -contains $_.N }) }
    # Mutants judged EQUIVALENT or unreachable offline, so not run (each reason checked by hand):
    #   folder-gate-dotdot-removed          a path with '..' is refused by the exact-match test that follows it anyway
    #   quarantine-move-postcondition-only  [IO.Directory]::Move either renames or throws; the combined mutant above is run
    #   post-move-count-unchecked           a same-volume rename keeps every entry; a count that differs cannot be produced offline
    #   quarantine-root-not-locked          the OS applies the explicit protected list at creation whatever the in-memory flag says (measured)
    #   quarantine-root-lock-unverified     the read-back after creating the root uses the same trusted list that built it; a divergence cannot be produced offline
    #   idempotence-rule-recalled           looping over an empty rule list does nothing
    #   conf-copy-unverified                Copy-Item cannot be made to corrupt a copy offline
    #   log-folder-unchecked                Add-Content on a missing folder throws into the same refusal
    #   delete-dest-real-folder-unchecked   the same shapes are caught by the copy lock re-check and by Remove-RemovalTree's own root check
    #   handle-open-follows-links           the walk never hands a link to the handle open; killed by the narrowing suite instead
    Write-Host "== mutation run: $($muts.Count) mutants ==" -ForegroundColor Cyan
    $r = Invoke-MutationRun $muts
    if (-not $r.Control) { exit 2 }
    $killed = @($r.Results | Where-Object { $_.Class -eq 'KILLED' }); $other = @($r.Results | Where-Object { $_.Class -ne 'KILLED' })
    Write-Host ''
    Write-Host "MUTATION RESULT: $($killed.Count) of $($r.Results.Count) killed; $($other.Count) not killed" -ForegroundColor $(if ($other.Count -eq 0) { 'Green' } else { 'Red' })
    Write-Host "MUTATIONS: $($killed.Count) killed, $(@($other | Where-Object { $_.Class -eq 'SURVIVED' }).Count) survived, $(@($other | Where-Object { $_.Class -eq 'ERROR' }).Count) error"
    foreach ($o in $other) { Write-Host "  NOT KILLED: $($o.N) [$($o.Class)] $($o.Why)" -ForegroundColor Red }
    if ($other.Count -eq 0) { exit 0 } else { exit 1 }
}

. "$PSScriptRoot\remove-nginx-gateway.ps1"   # dot-sourced: functions only, nothing runs
$script:Pass = 0; $script:Fail = 0; $script:Failures = New-Object System.Collections.ArrayList
function _pass($m) { $script:Pass++; Write-Host "  [PASS] $m" -ForegroundColor Green }
function _fail($m) { $script:Fail++; [void]$script:Failures.Add($m); Write-Host "  [FAIL] $m" -ForegroundColor Red }
function Assert-True($c, $m) { if ($c) { _pass $m } else { _fail "$m (expected True)" } }
function Assert-Eq($e, $a, $m) { if ([string]$e -ceq [string]$a) { _pass $m } else { _fail "$m (expected '$e', got '$a')" } }
function Section($t) { Write-Host ''; Write-Host "== $t ==" -ForegroundColor Cyan }
function Test-Step { param([string]$Name, [scriptblock]$Body) try { & $Body } catch { _fail "$Name threw: $($_.Exception.Message)" } }

$MeSid = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
$Trusted = @($MeSid, 'S-1-5-18', 'S-1-5-32-544')   # the current user stands in for the operator (an Administrators member)
$TmpRoot = [IO.Path]::GetTempPath().TrimEnd('\')
$script:Cleanup = New-Object System.Collections.ArrayList

# ---- the fake system table ---------------------------------------------------------------------------------
function New-FakeState([string]$Folder) {
    $tasks = @{}
    foreach ($n in $script:RemovalAllowedTasks) {
        $on = $n -in @('NginxGatewayWatchdog', 'WslAgentBoot')
        $tasks[$n] = @{ Name = $n; Path = '\'; Enabled = $on; State = $(if ($on) { 'Ready' } else { 'Disabled' }); UserId = $(if ($n -eq 'WslAgentBoot') { 'op' } else { 'SYSTEM' }); ActionText = "powershell.exe -File $Folder\bin\$n.ps1" }
    }
    $rules = @(); $i = 0
    foreach ($n in $script:RemovalAllowedRules) { $i++; $rules += @{ Id = "{rule-$i}"; DisplayName = $n; Direction = 'Inbound'; Action = 'Allow'; Enabled = $true } }
    return @{
        Elevated = $true; Procs = 0; Listeners = @(); Others = @(); RealTakeown = $true
        Service = @{ Name = 'NginxGateway'; StartName = 'LocalSystem'; StartMode = 'Auto'; PathName = "$Folder\nginx.exe -p $Folder -c conf\nginx.conf"; State = 'Stopped' }
        Tasks = $tasks; Rules = $rules
        Calls = (New-Object System.Collections.ArrayList); Fail = @{}; NoEffect = @{}; Hooks = @{}
    }
}
function New-FakeSys($FakeState) {
    $sys = @{}
    $sys.IsElevated = { $FakeState.Elevated }.GetNewClosure()
    $sys.GetService = { param($n) if ($FakeState.Service -and $FakeState.Service.Name -eq $n) { $c = @{}; foreach ($k in $FakeState.Service.Keys) { $c[$k] = $FakeState.Service[$k] }; $c } else { $null } }.GetNewClosure()
    $sys.StopService = { param($n) [void]$FakeState.Calls.Add("StopService:$n"); if ($FakeState.Fail.StopService) { throw $FakeState.Fail.StopService }; if (-not $FakeState.NoEffect.StopService) { $FakeState.Service.State = 'Stopped' } }.GetNewClosure()
    $sys.DeleteService = { param($n) [void]$FakeState.Calls.Add("DeleteService:$n"); if ($FakeState.Fail.DeleteService) { throw $FakeState.Fail.DeleteService }; if (-not $FakeState.NoEffect.DeleteService) { $FakeState.Service = $null } }.GetNewClosure()
    $sys.ServiceGone = { param($n) $null -eq $FakeState.Service }.GetNewClosure()
    $sys.GetTask = { param($n) if ($FakeState.Tasks.ContainsKey($n)) { $FakeState.Tasks[$n] } else { $null } }.GetNewClosure()
    $sys.UnregisterTask = { param($n) [void]$FakeState.Calls.Add("UnregisterTask:$n"); if ($FakeState.Fail.UnregisterTask -and $FakeState.Fail.UnregisterTask -eq $n) { throw "cannot unregister $n" }; if (-not $FakeState.NoEffect.UnregisterTask) { $FakeState.Tasks.Remove($n) }; if ($FakeState.Hooks.UnregisterTask) { & $FakeState.Hooks.UnregisterTask $n } }.GetNewClosure()
    $sys.GetRules = { param($n) @($FakeState.Rules | Where-Object { $_.DisplayName -eq $n }) }.GetNewClosure()
    $sys.RemoveRule = { param($id) [void]$FakeState.Calls.Add("RemoveRule:$id"); if (-not $FakeState.NoEffect.RemoveRule) { $FakeState.Rules = @($FakeState.Rules | Where-Object { $_.Id -ne $id }) }; if ($FakeState.Hooks.RemoveRule) { & $FakeState.Hooks.RemoveRule $id } }.GetNewClosure()
    $sys.CountProcesses = { param($n) $FakeState.Procs }.GetNewClosure()
    $sys.GetListeners = { param($ports) @($FakeState.Listeners | Where-Object { $ports -contains $_ }) }.GetNewClosure()
    $sys.FindOtherReferences = { param($needle, $svcs, $tasks) @($FakeState.Others) }.GetNewClosure()
    $sys.TakeOwnership = { param($p) [void]$FakeState.Calls.Add("TakeOwnership:$p"); if ($FakeState.Hooks.TakeOwnership) { & $FakeState.Hooks.TakeOwnership $p }; if ($FakeState.Fail.TakeOwnership -and $p -like "*$($FakeState.Fail.TakeOwnership)") { throw "takeown failed for $p" }; if ($FakeState.RealTakeown) { Invoke-RemovalTakeown -Path $p } }.GetNewClosure()
    $sys.Sleep = { param($ms) }
    return $sys
}
function Get-MutatingCalls($FakeState) { @($FakeState.Calls | Where-Object { $_ -notlike 'Get*' }) }

# ---- the temp tree ------------------------------------------------------------------------------------------
function New-TestEnv {
    $id = [guid]::NewGuid().ToString('N').Substring(0, 8)
    $env1 = @{ Id = $id; Folder = "$TmpRoot\nginx-removal-test-$id"; Q = "$TmpRoot\nginx-removal-test-q-$id"; Aux = "$TmpRoot\removal-aux-$id"; Outside = "$TmpRoot\removal-outside-$id" }
    foreach ($d in @($env1.Folder, "$($env1.Folder)\conf\conf.d", "$($env1.Folder)\certs\sub", "$($env1.Folder)\bin", "$($env1.Folder)\logs", $env1.Aux, $env1.Outside)) { New-Item -ItemType Directory -Force $d | Out-Null }
    Set-Content -LiteralPath "$($env1.Folder)\nginx.exe" 'MZ-fake'
    Set-Content -LiteralPath "$($env1.Folder)\conf\nginx.conf" 'worker_processes 1;'
    Set-Content -LiteralPath "$($env1.Folder)\conf\conf.d\a.conf" 'server {}'
    Set-Content -LiteralPath "$($env1.Folder)\certs\a.key" 'TOPSECRET-KEY-MATERIAL-A'
    Set-Content -LiteralPath "$($env1.Folder)\certs\sub\b.key" 'TOPSECRET-KEY-MATERIAL-B'
    Set-Content -LiteralPath "$($env1.Folder)\certs\c.pem" 'TOPSECRET-PEM'
    Set-Content -LiteralPath "$($env1.Folder)\bin\run.ps1" 'Write-Host hi'
    Set-Content -LiteralPath "$($env1.Folder)\logs\error.log" 'log'
    # explicit entries for broad groups (as the real folder has): the lock must REMOVE them, not just stop inheriting
    & icacls $env1.Folder /grant '*S-1-5-11:(OI)(CI)R' | Out-Null
    & icacls "$($env1.Folder)\certs\a.key" /grant '*S-1-5-32-545:R' | Out-Null
    $env1.Plan = @{ Folder = $env1.Folder; ServiceImagePrefix = "$($env1.Folder)\nginx.exe"; QuarantineRoot = $env1.Q; ConfBackupDir = "$($env1.Aux)\conf-backup"; LogDir = $env1.Aux }
    foreach ($c in @($env1.Folder, $env1.Q, $env1.Aux, $env1.Outside)) { [void]$script:Cleanup.Add($c) }
    return $env1
}
function Get-TreeSnapshot([string]$Root) {
    if (-not (Test-Path -LiteralPath $Root)) { return 'ABSENT' }
    $rows = Get-ChildItem -LiteralPath $Root -Recurse -Force -ErrorAction SilentlyContinue | Sort-Object FullName | ForEach-Object {
        $rel = $_.FullName.Substring($Root.Length)
        $sd = try { (Get-Acl -LiteralPath $_.FullName).Sddl } catch { 'unreadable' }
        "$rel|$($_.Length)|$sd"
    }
    $rootSd = try { (Get-Acl -LiteralPath $Root).Sddl } catch { 'unreadable' }
    return "$rootSd`n" + ($rows -join "`n")
}
function Invoke-Run($TestEnv, $FakeState, [switch]$Execute, [switch]$DeleteQuarantine, [string[]]$Scope = @('Service', 'Tasks', 'FirewallRules', 'Folder')) {
    $lines = New-Object System.Collections.ArrayList
    $sys = New-FakeSys $FakeState
    $r = Invoke-NginxRemoval -Execute:$Execute -DeleteQuarantine:$DeleteQuarantine -Scope $Scope -Plan $TestEnv.Plan -Sys $sys -TrustedSids $Trusted -Out { param($l) [void]$lines.Add([string]$l) }.GetNewClosure()
    $r.Lines = @($lines)
    return $r
}
function Remove-AllCleanup { foreach ($c in $script:Cleanup) { if (Test-Path -LiteralPath $c) { try { [IO.Directory]::Delete($c, $true) } catch { try { Remove-Item -LiteralPath $c -Recurse -Force -ErrorAction SilentlyContinue } catch { } } } } }

try {
Section 'the compiled-in allowlists and constants'
Test-Step 'constants' {
    Assert-Eq 'NginxGateway' ($script:RemovalAllowedService -join ',') 'the service allowlist is exactly NginxGateway'
    Assert-Eq 'NginxGatewayWatchdog,WslAgentBoot,NginxGateway,nginx-background,NginxAtBoot,NginxReload,NginxReloadNow,NginxReopenLogsNow,NginxQuitNow,NginxLogRotateWeekly,GatewayNginxMonthlyBackup,GatewayNginxPruneMonthly' ($script:RemovalAllowedTasks -join ',') 'the task allowlist is exactly the twelve named tasks'
    Assert-Eq 'nginx.exe HTTPS (App)|nginx HTTPS 443 (Port)|TEMP-Allow-HTTPS' ($script:RemovalAllowedRules -join '|') 'the firewall-rule allowlist is exactly the three named rules'
    Assert-True (@($script:RemovalAllowedService + $script:RemovalAllowedTasks + $script:RemovalAllowedRules | Where-Object { $_ -match '[\*\?\[\]]' }).Count -eq 0) 'no allowlisted name contains a wildcard character'
    Assert-Eq 'S-1-5-18,S-1-5-32-544' ($script:RemovalTrustedSids -join ',') 'the production lock keeps only SYSTEM and Administrators'
    Assert-Eq 'C:\nginx' $script:RemovalAllowedFolder 'the only folder the production run may act on is C:\nginx'
    Assert-Eq '443,8081' ($script:RemovalPorts -join ',') 'the refuse-while-listening ports are 443 and 8081'
    Assert-Eq 'C:\ProgramData\nginx-quarantine' $script:RemovalProduction.QuarantineRoot 'the production quarantine is C:\ProgramData\nginx-quarantine'
}

Section 'the gates: names, folder, quarantine'
Test-Step 'gates' {
    foreach ($n in $script:RemovalAllowedTasks) { try { Assert-RemovalAllowed -Kind task -Name $n; $ok = $true } catch { $ok = $false }; if (-not $ok) { _fail "allowlisted task '$n' was refused" } }
    _pass 'every allowlisted task name passes the gate'
    foreach ($bad in 'Evil', 'W32Time', 'Nginx*', '*', 'NginxGatewayX', 'NginxGatewayWatchdog2', 'nginxgateway', 'nginxreload', '', 'NginxReloadNow ') {
        $threw = $false; try { Assert-RemovalAllowed -Kind task -Name $bad } catch { $threw = $true }
        Assert-True $threw "a task named '$bad' (outside the list) is REFUSED by the gate"
    }
    foreach ($bad in 'W32Time', 'NginxGateway*', 'NginxGatewayX', 'nginxgateway', 'Spooler') {
        $threw = $false; try { Assert-RemovalAllowed -Kind service -Name $bad } catch { $threw = $true }
        Assert-True $threw "a service named '$bad' is REFUSED by the gate"
    }
    foreach ($bad in 'Core Networking - DNS (UDP-Out)', 'nginx*', 'nginx.exe HTTPS (App) copy') {
        $threw = $false; try { Assert-RemovalAllowed -Kind rule -Name $bad } catch { $threw = $true }
        Assert-True $threw "a firewall rule named '$bad' is REFUSED by the gate"
    }
    $threw = $false; try { Assert-RemovalAllowed -Kind service -Name 'NginxGatewayWatchdog' } catch { $threw = $true }
    Assert-True $threw 'a name from the TASK list is refused as a SERVICE (the lists do not mix)'
    foreach ($bad in 'C:\Windows', 'C:\', 'C:\nginx\..\Windows', 'C:\ngin*', 'nginx', 'C:\Users\mrbla', 'C:\nginx2', 'C:\nginx\bin', "$TmpRoot\other-folder", "$TmpRoot\nginx-removal-test-x\sub") {
        $threw = $false; try { Assert-RemovalFolderAllowed -Path $bad } catch { $threw = $true }
        Assert-True $threw "the folder gate REFUSES '$bad'"
    }
    $ok = $true; try { Assert-RemovalFolderAllowed -Path 'C:\nginx'; Assert-RemovalFolderAllowed -Path 'c:\NGINX\'; Assert-RemovalFolderAllowed -Path "$TmpRoot\nginx-removal-test-abc" } catch { $ok = $false }
    Assert-True $ok 'the folder gate accepts C:\nginx (any case, trailing slash) and a test folder under temp'
    foreach ($bad in 'C:\', 'C:\ProgramData', 'C:\nginx', 'C:\ProgramData\nginx-quarantine\nginx', "$TmpRoot\x") {
        $threw = $false; try { Assert-RemovalQuarantineAllowed -Root $bad } catch { $threw = $true }
        Assert-True $threw "the quarantine gate REFUSES '$bad'"
    }
    $ok = $true; try { Assert-RemovalQuarantineAllowed -Root 'C:\ProgramData\nginx-quarantine'; Assert-RemovalQuarantineAllowed -Root "$TmpRoot\nginx-removal-test-q-1" } catch { $ok = $false }
    Assert-True $ok 'the quarantine gate accepts the production root and a test root'
    $threw = $false; try { Lock-RemovalFolderTree -Path 'C:\Windows\Temp' -TakeOwnership { param($p) } | Out-Null } catch { $threw = $true }
    Assert-True $threw 'Lock-RemovalFolderTree itself refuses a folder outside the gate (it is checked again at the point of action)'
}

Section 'DRY RUN: prints the exact listing and changes nothing'
Test-Step 'dryrun' {
    $te = New-TestEnv; $fs = New-FakeState $te.Folder
    $junction = "$($te.Folder)\conf\linked"
    New-Item -ItemType Junction -Path $junction -Target $te.Outside | Out-Null
    Set-Content -LiteralPath "$($te.Outside)\keep.txt" 'outside'
    $before = Get-TreeSnapshot $te.Folder; $outBefore = Get-TreeSnapshot $te.Outside
    $r = Invoke-Run $te $fs
    $txt = $r.Lines -join "`n"
    Assert-Eq 0 $r.ExitCode 'dry run: exit 0 when the preconditions hold (the shell need not be elevated)'
    Assert-Eq 'dry-run' $r.Mode 'the default mode is dry-run'
    Assert-True ($txt -match 'DRY RUN') 'it announces that it is a dry run'
    Assert-True ((Get-MutatingCalls $fs).Count -eq 0) "dry run: ZERO mutating calls on the system (service, tasks, rules, ownership): $((Get-MutatingCalls $fs) -join ',')"
    Assert-True ($before -ceq (Get-TreeSnapshot $te.Folder)) 'dry run: the folder tree (names, sizes, access lists) is byte-for-byte unchanged'
    Assert-True ($outBefore -ceq (Get-TreeSnapshot $te.Outside)) 'dry run: the folder a junction points to is unchanged'
    Assert-True (-not (Test-Path -LiteralPath $te.Q) -and -not (Test-Path -LiteralPath "$($te.Aux)\conf-backup") -and @(Get-ChildItem -LiteralPath $te.Aux -Force).Count -eq 0) 'dry run: no quarantine, no conf copy and no log file was created'
    Assert-True ($r.LogPath -eq '') 'dry run: no log path'
    Assert-True ($txt -match 'NginxGateway : present') 'the listing names the service'
    foreach ($n in $script:RemovalAllowedTasks) { Assert-True ($txt -match [regex]::Escape($n)) "the listing names task $n" }
    foreach ($n in $script:RemovalAllowedRules) { Assert-True ($txt -match [regex]::Escape($n)) "the listing names firewall rule '$n'" }
    Assert-True ($txt -match 'ENABLED') 'the listing marks enabled tasks'
    Assert-True ($txt -match '7 files in 8 folders' -or $txt -match '\d+ files in \d+ folders') 'the listing gives the folder file and folder counts'
    Assert-True ($txt -match 'private-key file NAMES .*: 2') 'the listing counts the key-file NAMES (2 in the test tree)'
    Assert-True ($txt -match 'certs\\a\.key' -and $txt -match 'certs\\sub\\b\.key') 'the listing prints key file names'
    Assert-True ($txt -notmatch 'TOPSECRET') 'the listing NEVER prints key material'
    Assert-True ($txt -match '\.pem files \(may hold keys\): 1') 'the listing counts .pem files separately'
    Assert-True ($txt -match 'links inside.*: 1' -and $txt -match [regex]::Escape($junction)) 'the listing names the link and says it is not entered'
    Assert-True ($txt -match 'quarantine' -and $txt -match 'KEPT') 'the listing says the folder is moved to the quarantine and the copy is KEPT by default'
    Assert-True ($txt -match 'DECISIONS FOR THE LA') 'the listing names the decisions the LA owns'
    $d = Invoke-Run $te $fs -DeleteQuarantine
    Assert-True (($d.Lines -join "`n") -match 'PERMANENTLY DELETE') 'with -DeleteQuarantine the dry run says it would delete permanently'
    Assert-True ((Get-MutatingCalls $fs).Count -eq 0) 'that dry run changed nothing either'
    $fs2 = New-FakeState $te.Folder; $fs2.Elevated = $false
    Assert-Eq 0 (Invoke-Run $te $fs2).ExitCode 'a non-elevated dry run is fine (exit 0)'
    $fs3 = New-FakeState $te.Folder; $fs3.Listeners = @(443)
    $w = Invoke-Run $te $fs3
    Assert-True ($w.ExitCode -eq 2 -and ($w.Lines -join "`n") -match 'WOULD REFUSE') 'a dry run that would be refused says so (exit 2) and still changes nothing'
    Assert-True ((Get-MutatingCalls $fs3).Count -eq 0) 'the would-refuse dry run made no mutating calls'
}

Section '-Execute refusals: every one exits 2 with NOTHING changed'
Test-Step 'refusals' {
    $cases = [ordered]@{
        'not elevated'                        = { param($s, $te) $s.Elevated = $false }
        'an nginx process is running'          = { param($s, $te) $s.Procs = 1 }
        'something listens on 443'             = { param($s, $te) $s.Listeners = @(443) }
        'something listens on 8081'             = { param($s, $te) $s.Listeners = @(8081) }
        'the service image path is not ours'    = { param($s, $te) $s.Service.PathName = 'C:\Windows\System32\svchost.exe -k x' }
        'a task does not mention nginx'         = { param($s, $te) $s.Tasks['NginxReload'].ActionText = 'cmd.exe /c del C:\important' }
        'a firewall rule is outbound/block'     = { param($s, $te) $s.Rules[0].Direction = 'Outbound' }
        'an enabled non-allowlisted task points into the folder' = { param($s, $te) $s.Others = @(@{ Kind = 'task'; Name = '\Other'; Enabled = $true; Text = "$($te.Folder)\x.exe" }) }
        'an enabled non-allowlisted service points into the folder' = { param($s, $te) $s.Others = @(@{ Kind = 'service'; Name = 'OtherSvc'; Enabled = $true; Text = "$($te.Folder)\x.exe" }) }
    }
    foreach ($k in $cases.Keys) {
        $te = New-TestEnv; $fs = New-FakeState $te.Folder; & $cases[$k] $fs $te
        $snap = Get-TreeSnapshot $te.Folder
        $r = Invoke-Run $te $fs -Execute
        Assert-True ($r.ExitCode -eq 2 -and $r.Refusals.Count -ge 1) "refused (exit 2): $k"
        Assert-True ((Get-MutatingCalls $fs).Count -eq 0 -and $snap -ceq (Get-TreeSnapshot $te.Folder) -and -not (Test-Path -LiteralPath $te.Q) -and @(Get-ChildItem -LiteralPath $te.Aux -Force).Count -eq 0) "nothing changed (no calls, tree identical, no quarantine, no log, no conf copy): $k"
    }
    $te = New-TestEnv; $fs = New-FakeState $te.Folder
    $r = Invoke-Run $te $fs -Execute -Scope Folder
    Assert-True ($r.ExitCode -eq 2 -and ($r.Refusals -join ' ') -match 'service') 'the folder alone is refused while the service still exists (any user could re-create it)'
    $r = Invoke-Run $te $fs -Execute -Scope Service, Folder
    Assert-True ($r.ExitCode -eq 2 -and ($r.Refusals -join ' ') -match 'task') 'the folder plus the service is refused while allowlisted tasks still exist'
    Assert-True ((Get-MutatingCalls $fs).Count -eq 0) 'those refusals changed nothing'
    $r = Invoke-Run $te $fs -Execute -DeleteQuarantine -Scope Service
    Assert-True ($r.ExitCode -eq 2) '-DeleteQuarantine without -Scope Folder is refused'
    $threw = $false; try { Invoke-NginxRemoval -Scope Bogus -Plan $te.Plan -Sys (New-FakeSys $fs) -Out { param($l) } | Out-Null } catch { $threw = $true }
    Assert-True $threw 'an unknown -Scope value throws'
    $te2 = New-TestEnv; $fs2 = New-FakeState $te2.Folder; $te2.Plan.LogDir = "$($te2.Aux)\no-such-dir"
    $r = Invoke-Run $te2 $fs2 -Execute
    Assert-True ($r.ExitCode -eq 2 -and (Get-MutatingCalls $fs2).Count -eq 0) 'an unwritable log folder refuses BEFORE any change'
    $te3 = New-TestEnv; $fs3 = New-FakeState $te3.Folder; Remove-Item -LiteralPath "$($te3.Folder)\conf\nginx.conf"
    $r = Invoke-Run $te3 $fs3 -Execute
    Assert-True ($r.ExitCode -eq 2 -and ($r.Refusals -join ' ') -match 'nginx.conf') 'no nginx.conf to copy and no existing copy: refused'
}

Section '-Execute happy path: lock, remove, quarantine, verify, log'
Test-Step 'happy' {
    $te = New-TestEnv; $fs = New-FakeState $te.Folder
    $junction = "$($te.Folder)\conf\linked"
    New-Item -ItemType Junction -Path $junction -Target $te.Outside | Out-Null
    Set-Content -LiteralPath "$($te.Outside)\keep.txt" 'outside'
    $outBefore = Get-TreeSnapshot $te.Outside
    $hashBefore = @{}; Get-ChildItem -LiteralPath $te.Folder -Recurse -File -Force | Where-Object { $_.Attributes -notmatch 'ReparsePoint' } | ForEach-Object { $hashBefore[$_.FullName.Substring($te.Folder.Length)] = (Get-FileHash -LiteralPath $_.FullName).Hash }
    $nObjects = @(Get-ChildItem -LiteralPath $te.Folder -Recurse -Force | Where-Object { $_.FullName -ne $junction }).Count + 1
    $r = Invoke-Run $te $fs -Execute
    Assert-Eq 0 $r.ExitCode "execute: exit 0 ($($r.Refusals -join '; '))"
    Assert-True ($null -eq $fs.Service) 'the service is gone'
    Assert-True ($fs.Tasks.Count -eq 0) 'all twelve tasks are gone'
    Assert-True (@($fs.Rules).Count -eq 0) 'all three firewall rules are gone'
    Assert-True (-not (Test-Path -LiteralPath $te.Folder)) 'the folder is gone from its place'
    $dest = "$($te.Q)\$([IO.Path]::GetFileName($te.Folder))"
    Assert-True (Test-Path -LiteralPath $dest) 'the folder is in the quarantine (default: KEPT)'
    $hashAfter = @{}; Get-ChildItem -LiteralPath $dest -Recurse -File -Force | Where-Object { $_.Attributes -notmatch 'ReparsePoint' } | ForEach-Object { $hashAfter[$_.FullName.Substring($dest.Length)] = (Get-FileHash -LiteralPath $_.FullName).Hash }
    Assert-True ($hashBefore.Count -gt 0 -and $hashBefore.Count -eq $hashAfter.Count -and @($hashBefore.Keys | Where-Object { $hashBefore[$_] -ne $hashAfter[$_] }).Count -eq 0) "every file arrived intact ($($hashBefore.Count) files, same SHA-256)"
    Assert-True ($outBefore -ceq (Get-TreeSnapshot $te.Outside)) 'the folder a JUNCTION pointed to was neither entered nor changed (names, sizes, access lists)'
    Assert-True (Test-Path -LiteralPath "$dest\conf\linked") 'the junction itself moved with the folder, not followed'
    # the quarantine is admin-only: real access lists
    $chk = Test-RemovalFolderLockedShallow -Path $te.Q -TrustedSids $Trusted
    Assert-True $chk.Ok "the quarantine ROOT is admin-only: protected, trusted owner, trusted entries only ($($chk.Why))"
    $deep = Test-RemovalFolderLocked -Path $dest -TrustedSids $Trusted
    Assert-True ($deep.Ok -and $deep.Visited -ge $nObjects - 1) "every object in the quarantined copy is owned by and open only to the trusted accounts ($($deep.Visited) objects, $(@($deep.Violations).Count) violations)"
    $bad = @('S-1-5-11', 'S-1-5-32-545', 'S-1-1-0')
    $anyBroad = $false
    foreach ($p in @($te.Q, $dest, "$dest\certs\a.key", "$dest\certs\sub\b.key", "$dest\nginx.exe")) {
        $acl = Get-Acl -LiteralPath $p
        foreach ($rule in $acl.GetAccessRules($true, $true, [Security.Principal.SecurityIdentifier])) { if ($bad -contains $rule.IdentityReference.Value) { $anyBroad = $true } }
    }
    Assert-True (-not $anyBroad) 'read directly: no Authenticated Users / Users / Everyone entry on the quarantine root, the folder, the key files or the exe'
    # the verifier can fail (toggle): open one deep file up and the check must see it
    $keyFile = "$dest\certs\a.key"
    $acl = Get-Acl -LiteralPath $keyFile; $acl.AddAccessRule((New-Object Security.AccessControl.FileSystemAccessRule(([Security.Principal.SecurityIdentifier]'S-1-5-11'), 'Read', 'Allow'))); Set-Acl -LiteralPath $keyFile -AclObject $acl
    $tog = Test-RemovalFolderLocked -Path $dest -TrustedSids $Trusted
    Assert-True ((-not $tog.Ok) -and (@($tog.Violations | Where-Object { $_ -match 'S-1-5-11' }).Count -ge 1)) 'toggle: giving Authenticated Users read on one key file makes the lock check FAIL (the verifier can see it)'
    # conf copy
    $conf = "$($te.Plan.ConfBackupDir)\nginx.conf"
    Assert-True ((Test-Path -LiteralPath $conf) -and (Get-FileHash -LiteralPath $conf).Hash -eq $hashBefore['\conf\nginx.conf']) 'nginx.conf was copied before anything changed and matches the original'
    # the log
    Assert-True ($r.LogPath -and (Test-Path -LiteralPath $r.LogPath)) 'a log file was written'
    $log = Get-Content -LiteralPath $r.LogPath -Raw
    foreach ($needle in 'copy nginx.conf', 'take ownership', 'delete service NginxGateway', 'unregister scheduled task NginxGatewayWatchdog', 'unregister scheduled task WslAgentBoot', "remove firewall rule 'TEMP-Allow-HTTPS'", 'move ', 'DONE') {
        Assert-True ($log -match [regex]::Escape($needle)) "the log records: $needle"
    }
    Assert-True ($log -notmatch 'TOPSECRET') 'the log holds no key material'
    $okSteps = @($r.Steps | Where-Object { $_.Status -eq 'done' }).Count
    Assert-True ($okSteps -eq $r.Steps.Count -and $okSteps -ge 17) "every step reports done and each was verified ($okSteps steps)"
    $order = @($fs.Calls | ForEach-Object { $_ })
    $firstOwn = $order.IndexOf(($order | Where-Object { $_ -like 'TakeOwnership:*' } | Select-Object -First 1)); $delSvc = $order.IndexOf('DeleteService:NginxGateway')
    Assert-True ($firstOwn -ge 0 -and $delSvc -gt $firstOwn) 'ORDER: the folder is locked (ownership taken) BEFORE the service is deleted'
    $ownCount = @($order | Where-Object { $_ -like 'TakeOwnership:*' }).Count
    Assert-True ($ownCount -ge $nObjects - 1) "ownership was taken on every object, one call each ($ownCount calls for $nObjects objects)"
    Assert-True (-not (@($order | Where-Object { $_ -like 'StopService*' }).Count)) 'a service that is already Stopped is not stopped again'
}

Section '-DeleteQuarantine: permanent deletion only when asked'
Test-Step 'delete' {
    $te = New-TestEnv; $fs = New-FakeState $te.Folder
    $r = Invoke-Run $te $fs -Execute -DeleteQuarantine
    $dest = "$($te.Q)\$([IO.Path]::GetFileName($te.Folder))"
    Assert-Eq 0 $r.ExitCode 'execute with -DeleteQuarantine: exit 0'
    Assert-True (-not (Test-Path -LiteralPath $dest) -and -not (Test-Path -LiteralPath $te.Folder)) 'the quarantined copy and the original place are both gone'
    Assert-True (Test-Path -LiteralPath "$($te.Plan.ConfBackupDir)\nginx.conf") 'the nginx.conf copy survives the deletion'
    Assert-True ((Get-Content -LiteralPath $r.LogPath -Raw) -match 'PERMANENTLY DELETE') 'the permanent deletion is logged'
    # the default keeps it (asserted in the happy path); here the toggle: no flag, no deletion
    $te2 = New-TestEnv; $fs2 = New-FakeState $te2.Folder
    $null = Invoke-Run $te2 $fs2 -Execute
    Assert-True (Test-Path -LiteralPath "$($te2.Q)\$([IO.Path]::GetFileName($te2.Folder))") 'toggle: the same run WITHOUT -DeleteQuarantine keeps the copy'
    # marker guard
    $te3 = New-TestEnv; $fs3 = New-FakeState $te3.Folder
    $null = Invoke-Run $te3 $fs3 -Execute
    Remove-Item -LiteralPath "$($te3.Q)\.nginx-gateway-quarantine" -Force
    $fs3b = New-FakeState $te3.Folder; $fs3b.Service = $null; $fs3b.Tasks = @{}; $fs3b.Rules = @()
    $r3 = Invoke-Run $te3 $fs3b -Execute -DeleteQuarantine
    Assert-True ($r3.ExitCode -eq 3 -and (Test-Path -LiteralPath "$($te3.Q)\$([IO.Path]::GetFileName($te3.Folder))")) 'without the quarantine marker the delete refuses and the copy stays'
}

Section '-DeleteQuarantine and links: a link is removed as a link, its target is left alone'
Test-Step 'deletelinks' {
    $te = New-TestEnv; $fs = New-FakeState $te.Folder
    $victim = "$TmpRoot\removal-victim-$($te.Id)"; New-Item -ItemType Directory $victim | Out-Null; [void]$script:Cleanup.Add($victim)
    Set-Content -LiteralPath "$victim\precious.txt" 'precious'
    New-Item -ItemType Junction -Path "$($te.Folder)\bin\jlink" -Target $victim | Out-Null
    $symOk = $true; try { New-Item -ItemType SymbolicLink -Path "$($te.Folder)\bin\flink" -Target "$victim\precious.txt" -ErrorAction Stop | Out-Null } catch { $symOk = $false }
    New-Item -ItemType SymbolicLink -Path "$($te.Folder)\bin\dlink" -Target $victim -ErrorAction SilentlyContinue | Out-Null
    Set-ItemProperty -LiteralPath "$($te.Folder)\logs\error.log" -Name IsReadOnly -Value $true
    $snap = Get-TreeSnapshot $victim
    $r = Invoke-Run $te $fs -Execute -DeleteQuarantine
    $dest = "$($te.Q)\$([IO.Path]::GetFileName($te.Folder))"
    Assert-True ($r.ExitCode -eq 0 -and -not (Test-Path -LiteralPath $dest)) "the quarantined copy with a junction$(if ($symOk) { ', a file symlink' }) and a read-only file inside is deleted completely ($($r.Refusals -join '; '))"
    Assert-True ($snap -ceq (Get-TreeSnapshot $victim) -and (Get-Content -LiteralPath "$victim\precious.txt" -Raw).Trim() -eq 'precious') 'the junction target (and the file a symlink pointed to) is untouched: the link went, the target stayed'
}

Section '-DeleteQuarantine hardening: link roots, state re-proved at the delete, read-only entries'
Test-Step 'deleteharden' {
    $te = New-TestEnv
    $victim = "$TmpRoot\removal-victim2-$($te.Id)"; New-Item -ItemType Directory $victim | Out-Null; [void]$script:Cleanup.Add($victim)
    Set-Content -LiteralPath "$victim\precious.txt" 'precious'; Set-Content -LiteralPath "$victim\more.txt" 'more'
    $snap = Get-TreeSnapshot $victim
    # unit: a link given AS THE ROOT is refused and its target is never walked
    $jroot = "$TmpRoot\removal-jroot-$($te.Id)"
    New-Item -ItemType Junction -Path $jroot -Target $victim | Out-Null
    $threw = $false; try { Remove-RemovalTree -Path $jroot } catch { $threw = $true }
    Assert-True ($threw -and $snap -ceq (Get-TreeSnapshot $victim)) 'Remove-RemovalTree REFUSES a junction as the root, and the target keeps every entry'
    [IO.Directory]::Delete($jroot)
    $sroot = "$TmpRoot\removal-sroot-$($te.Id)"; $symDir = $true
    try { New-Item -ItemType SymbolicLink -Path $sroot -Target $victim -ErrorAction Stop | Out-Null } catch { $symDir = $false }
    if ($symDir) {
        $threw = $false; try { Remove-RemovalTree -Path $sroot } catch { $threw = $true }
        Assert-True ($threw -and $snap -ceq (Get-TreeSnapshot $victim)) 'Remove-RemovalTree REFUSES a folder symlink as the root, and the target keeps every entry'
        [IO.Directory]::Delete($sroot)
    }
    # unit: read-only folder, read-only junction, read-only file symlink inside the tree
    $tree = "$TmpRoot\removal-ro-$($te.Id)"; [void]$script:Cleanup.Add($tree)
    New-Item -ItemType Directory "$tree\rodir" | Out-Null
    Set-Content -LiteralPath "$tree\rodir\f.txt" 'x'
    New-Item -ItemType Junction -Path "$tree\rojunc" -Target $victim | Out-Null
    $fl = $true; try { New-Item -ItemType SymbolicLink -Path "$tree\rolink" -Target "$victim\precious.txt" -ErrorAction Stop | Out-Null } catch { $fl = $false }
    foreach ($n in 'rodir', 'rojunc', 'rolink') { $q = "$tree\$n"; if (Test-Path -LiteralPath $q) { [IO.File]::SetAttributes($q, [IO.File]::GetAttributes($q) -bor [IO.FileAttributes]::ReadOnly) } }
    $err = ''; try { Remove-RemovalTree -Path $tree } catch { $err = $_.Exception.Message }
    Assert-True ($err -eq '' -and -not (Test-Path -LiteralPath $tree)) "a tree holding a read-only folder, a read-only junction$(if ($fl) { ' and a read-only file symlink' }) is deleted completely ($err)"
    Assert-True ($snap -ceq (Get-TreeSnapshot $victim)) 'and the targets of those links are untouched'

    $emptyState = { param($f) $s = New-FakeState $f; $s.Service = $null; $s.Tasks = @{}; $s.Rules = @(); $s }
    $leaf = { param($e) [IO.Path]::GetFileName($e.Folder) }
    # e2e: the folder is quarantined (no delete), then the state is spoiled in one way, then -DeleteQuarantine must refuse (exit 3, the copy stays)
    $te1 = New-TestEnv; $fs1 = New-FakeState $te1.Folder
    $null = Invoke-Run $te1 $fs1 -Execute
    $dest1 = "$($te1.Q)\$(& $leaf $te1)"
    $a = Get-Acl -LiteralPath $te1.Q; $a.AddAccessRule((New-Object Security.AccessControl.FileSystemAccessRule(([Security.Principal.SecurityIdentifier]'S-1-5-11'), 'ReadAndExecute', 'Allow'))); Set-Acl -LiteralPath $te1.Q -AclObject $a
    $r = Invoke-Run $te1 (& $emptyState $te1.Folder) -Execute -DeleteQuarantine -Scope Folder
    Assert-True ($r.ExitCode -eq 3 -and (Test-Path -LiteralPath $dest1) -and ($r.Refusals -join ' ') -match 'not admin-only') 'the quarantine ROOT re-opened to another account before the delete: refused (exit 3), the copy stays'
    $te2 = New-TestEnv; $fs2 = New-FakeState $te2.Folder
    $null = Invoke-Run $te2 $fs2 -Execute
    $dest2 = "$($te2.Q)\$(& $leaf $te2)"
    $k = "$dest2\certs\a.key"; $a = Get-Acl -LiteralPath $k; $a.AddAccessRule((New-Object Security.AccessControl.FileSystemAccessRule(([Security.Principal.SecurityIdentifier]'S-1-5-11'), 'Read', 'Allow'))); Set-Acl -LiteralPath $k -AclObject $a
    $r = Invoke-Run $te2 (& $emptyState $te2.Folder) -Execute -DeleteQuarantine -Scope Folder
    Assert-True ($r.ExitCode -eq 3 -and (Test-Path -LiteralPath $dest2) -and ($r.Refusals -join ' ') -match 'not fully locked') 'a key file in the copy re-opened before the delete: refused (exit 3), the copy stays'
    # e2e: the pre-planted shape: the folder is already gone; someone made the quarantine root (marker included) and a junction named like the folder, pointing at a victim
    foreach ($locked in $false, $true) {
        $te3 = New-TestEnv; $fs3 = New-FakeState $te3.Folder
        New-Item -ItemType Directory -Force $te3.Plan.ConfBackupDir | Out-Null
        Copy-Item -LiteralPath "$($te3.Folder)\conf\nginx.conf" "$($te3.Plan.ConfBackupDir)\nginx.conf"
        Remove-Item -LiteralPath $te3.Folder -Recurse -Force
        if ($locked) { $null = Initialize-RemovalQuarantineRoot -Root $te3.Q -TrustedSids $Trusted } else { New-Item -ItemType Directory $te3.Q | Out-Null; Set-Content -LiteralPath "$($te3.Q)\.nginx-gateway-quarantine" 'planted' }
        $v3 = "$TmpRoot\removal-victim3-$($te3.Id)"; New-Item -ItemType Directory $v3 | Out-Null; [void]$script:Cleanup.Add($v3)
        Set-Content -LiteralPath "$v3\a.txt" 'a'; Set-Content -LiteralPath "$v3\b.txt" 'b'
        New-Item -ItemType Junction -Path "$($te3.Q)\$(& $leaf $te3)" -Target $v3 | Out-Null
        $before3 = Get-TreeSnapshot $v3
        $r = Invoke-Run $te3 (& $emptyState $te3.Folder) -Execute -DeleteQuarantine -Scope Folder
        Assert-True ($r.ExitCode -eq 3 -and $before3 -ceq (Get-TreeSnapshot $v3) -and (Test-Path -LiteralPath "$v3\a.txt")) "PRE-PLANTED quarantine root ($(if ($locked) { 'locked' } else { 'unlocked' })) with a junction in place of the copy: refused (exit 3), the junction's target keeps every entry"
    }
}

Section 'conf copy: never overwritten'
Test-Step 'conf' {
    $te = New-TestEnv; $fs = New-FakeState $te.Folder
    New-Item -ItemType Directory -Force $te.Plan.ConfBackupDir | Out-Null
    $existing = "$($te.Plan.ConfBackupDir)\nginx.conf"
    Set-Content -LiteralPath $existing 'OLD DIFFERENT COPY'
    $oldHash = (Get-FileHash -LiteralPath $existing).Hash
    $r = Invoke-Run $te $fs -Execute
    Assert-Eq 0 $r.ExitCode 'a differing existing copy does not stop the run'
    Assert-True ((Get-FileHash -LiteralPath $existing).Hash -eq $oldHash) 'the EXISTING copy is byte-for-byte untouched'
    $new = @(Get-ChildItem -LiteralPath $te.Plan.ConfBackupDir | Where-Object { $_.Name -like 'nginx.conf.*' })
    Assert-True ($new.Count -eq 1 -and (Get-Content -LiteralPath $new[0].FullName -Raw).Trim() -eq 'worker_processes 1;') 'the new copy got its own timestamped name and holds the current conf'
    $te2 = New-TestEnv; $fs2 = New-FakeState $te2.Folder
    New-Item -ItemType Directory -Force $te2.Plan.ConfBackupDir | Out-Null
    Copy-Item -LiteralPath "$($te2.Folder)\conf\nginx.conf" "$($te2.Plan.ConfBackupDir)\nginx.conf"
    $null = Invoke-Run $te2 $fs2 -Execute
    Assert-True (@(Get-ChildItem -LiteralPath $te2.Plan.ConfBackupDir).Count -eq 1) 'an identical existing copy is reused: no second file'
}

Section 'idempotent: a re-run after completion does nothing'
Test-Step 'idempotent' {
    $te = New-TestEnv; $fs = New-FakeState $te.Folder
    $null = Invoke-Run $te $fs -Execute
    $fs.Calls.Clear()
    $r = Invoke-Run $te $fs -Execute
    Assert-Eq 0 $r.ExitCode 're-run after completion: exit 0'
    Assert-True ((Get-MutatingCalls $fs).Count -eq 0) "re-run: ZERO mutating calls ($((Get-MutatingCalls $fs) -join ','))"
    Assert-True (@($r.Lines | Where-Object { $_ -match 'already done' }).Count -ge 15) 'every item reports already done'
    $d = Invoke-Run $te $fs
    Assert-True ($d.ExitCode -eq 0 -and ($d.Lines -join "`n") -match 'not present') 'a dry run afterwards reports everything as not present'
}

Section 'partial failure: stops, reports, and a re-run resumes'
Test-Step 'partial' {
    # a task cannot be unregistered: later items untouched, the folder still in place
    $te = New-TestEnv; $fs = New-FakeState $te.Folder; $fs.Fail.UnregisterTask = 'WslAgentBoot'
    $r = Invoke-Run $te $fs -Execute
    Assert-Eq 3 $r.ExitCode 'a failing step ends the run with exit 3'
    Assert-True (@($fs.Calls | Where-Object { $_ -like 'RemoveRule*' }).Count -eq 0) 'STOPS: no firewall rule was touched after the failing task'
    Assert-True ((Test-Path -LiteralPath $te.Folder) -and -not (Test-Path -LiteralPath $te.Q)) 'STOPS: the folder was not moved'
    Assert-True ($null -eq $fs.Service) 'the steps BEFORE the failure stand (the service is gone)'
    $afterTask = @($fs.Calls | Where-Object { $_ -like 'UnregisterTask:*' })
    Assert-True ($afterTask[-1] -eq 'UnregisterTask:WslAgentBoot') 'no task after the failing one was attempted'
    Assert-True ((Get-Content -LiteralPath $r.LogPath -Raw) -match 'FAIL') 'the failure is in the log'
    $fs.Fail.Clear(); $fs.Calls.Clear()
    $r2 = Invoke-Run $te $fs -Execute
    Assert-Eq 0 $r2.ExitCode 'RESUME: re-running after the cause is fixed completes'
    Assert-True (@($fs.Calls | Where-Object { $_ -like 'DeleteService*' }).Count -eq 0) 'RESUME: the finished service step is not repeated'
    Assert-True ($fs.Tasks.Count -eq 0 -and @($fs.Rules).Count -eq 0 -and -not (Test-Path -LiteralPath $te.Folder)) 'RESUME: everything is removed at the end'
    # postcondition failures: the action "succeeds" but the thing is still there
    foreach ($case in @(@{ N = 'DeleteService'; Msg = 'service' }, @{ N = 'UnregisterTask'; Msg = 'still registered' }, @{ N = 'RemoveRule'; Msg = 'still present' })) {
        $te2 = New-TestEnv; $fs2 = New-FakeState $te2.Folder; $fs2.NoEffect[$case.N] = $true
        $r3 = Invoke-Run $te2 $fs2 -Execute
        Assert-True ($r3.ExitCode -eq 3 -and ($r3.Refusals -join ' ') -match $case.Msg) "a $($case.N) that has no effect is caught by its postcondition (exit 3): $($r3.Refusals -join ' ')"
        Assert-True ((Test-Path -LiteralPath $te2.Folder) -and -not (Test-Path -LiteralPath $te2.Q)) "that failure stops before the move ($($case.N))"
    }
    # a service that will not stop
    $te4 = New-TestEnv; $fs4 = New-FakeState $te4.Folder; $fs4.Service.State = 'Running'; $fs4.NoEffect.StopService = $true
    $r4 = Invoke-Run $te4 $fs4 -Execute
    Assert-True ($r4.ExitCode -eq 3 -and ($r4.Refusals -join ' ') -match 'did not stop' -and @($fs4.Calls | Where-Object { $_ -like 'DeleteService*' }).Count -eq 0) 'a service that does not stop is never deleted (exit 3)'
    $te5 = New-TestEnv; $fs5 = New-FakeState $te5.Folder; $fs5.Service.State = 'Running'
    $r5 = Invoke-Run $te5 $fs5 -Execute
    Assert-True ($r5.ExitCode -eq 0 -and @($fs5.Calls | Where-Object { $_ -like 'StopService*' }).Count -eq 1) 'a running service is stopped first, then deleted'
    # the lock fails: the service is never touched
    $te6 = New-TestEnv; $fs6 = New-FakeState $te6.Folder; $fs6.Fail.TakeOwnership = 'a.key'
    $r6 = Invoke-Run $te6 $fs6 -Execute
    Assert-True ($r6.ExitCode -eq 3 -and $null -ne $fs6.Service -and $fs6.Tasks.Count -eq 12) 'a lock failure (takeown) stops the run BEFORE the service, tasks or rules are touched'
    Assert-True (Test-Path -LiteralPath $te6.Folder) 'and the folder stays where it was'
    # a pre-existing destination
    $te7 = New-TestEnv; $fs7 = New-FakeState $te7.Folder
    $null = Initialize-RemovalQuarantineRoot -Root $te7.Q -TrustedSids $Trusted
    New-Item -ItemType Directory "$($te7.Q)\$([IO.Path]::GetFileName($te7.Folder))" | Out-Null
    $r7 = Invoke-Run $te7 $fs7 -Execute
    Assert-True ($r7.ExitCode -eq 2 -and (Test-Path -LiteralPath $te7.Folder) -and (Get-MutatingCalls $fs7).Count -eq 0) 'a quarantine destination that already exists while the folder is still in place is refused before any change'
}

Section 'the quarantine root: created admin-only, an existing one is verified'
Test-Step 'qroot' {
    $te = New-TestEnv
    $q = Initialize-RemovalQuarantineRoot -Root $te.Q -TrustedSids $Trusted
    Assert-True ((Test-RemovalFolderLockedShallow -Path $q -TrustedSids $Trusted).Ok) 'a new quarantine root is created protected, with only the trusted entries'
    Assert-True ((Test-Path -LiteralPath "$q\.nginx-gateway-quarantine")) 'it carries the marker'
    $again = Initialize-RemovalQuarantineRoot -Root $te.Q -TrustedSids $Trusted
    Assert-True ($again -eq $q) 'an existing, locked, marked root is accepted (idempotent)'
    $acl = Get-Acl -LiteralPath $q; $acl.AddAccessRule((New-Object Security.AccessControl.FileSystemAccessRule(([Security.Principal.SecurityIdentifier]'S-1-5-11'), 'ReadAndExecute', 'Allow'))); Set-Acl -LiteralPath $q -AclObject $acl
    $threw = $false; try { Initialize-RemovalQuarantineRoot -Root $te.Q -TrustedSids $Trusted | Out-Null } catch { $threw = $true }
    Assert-True $threw 'toggle: an existing root that gained an Authenticated Users entry is REFUSED'
    # the PRODUCTION trusted set (SYSTEM + Administrators only, the operator is NOT in it): a root created by a
    # normal elevated user must still pass, so it has to be created owned by Administrators
    $teP = New-TestEnv
    $qp = Initialize-RemovalQuarantineRoot -Root $teP.Q
    $own = (Get-AclSddlAndOwnerChecked -Path $qp -IsDir $true).Owner
    $ownM = (Get-AclSddlAndOwnerChecked -Path "$qp\.nginx-gateway-quarantine" -IsDir $false).Owner
    Assert-True ($own -eq 'S-1-5-32-544' -and $ownM -eq 'S-1-5-32-544') "with the production trusted set the new root and its marker are owned by Administrators (root $own, marker $ownM), not the current user"
    $te2 = New-TestEnv; New-Item -ItemType Directory $te2.Q | Out-Null
    $msg = ''; try { Initialize-RemovalQuarantineRoot -Root $te2.Q -TrustedSids $Trusted | Out-Null } catch { $msg = $_.Exception.Message }
    Assert-True ($msg -match 'marker') "an existing folder without our marker is refused for that reason ($msg)"
}

Section 'each safeguard catches its failure on its own'
Test-Step 'layers' {
    # the quarantine on another volume
    $te = New-TestEnv; $fs = New-FakeState $te.Folder; $te.Plan.QuarantineRoot = 'Z:\nginx-removal-test-q-other'
    $r = Invoke-Run $te $fs -Execute
    Assert-True ($r.ExitCode -eq 2 -and ($r.Refusals -join ' ') -match 'another volume' -and (Get-MutatingCalls $fs).Count -eq 0) 'a quarantine on another volume is refused before any change (a move must be a rename)'
    # access list reopened between the lock and the move: the move re-checks the lock itself
    $te = New-TestEnv; $fs = New-FakeState $te.Folder
    $key = "$($te.Folder)\certs\a.key"
    $fs.Hooks.UnregisterTask = { param($n) if ($n -eq 'NginxLogRotateWeekly') { $a = Get-Acl -LiteralPath $key; $a.AddAccessRule((New-Object Security.AccessControl.FileSystemAccessRule(([Security.Principal.SecurityIdentifier]'S-1-5-11'), 'Read', 'Allow'))); Set-Acl -LiteralPath $key -AclObject $a } }.GetNewClosure()
    $r = Invoke-Run $te $fs -Execute
    Assert-True ($r.ExitCode -eq 3 -and (Test-Path -LiteralPath $te.Folder) -and -not (Test-Path -LiteralPath "$($te.Q)\$([IO.Path]::GetFileName($te.Folder))")) 'a key file re-opened to Authenticated Users after the lock stops the run BEFORE the move (the folder stays, nothing is quarantined)'
    # tampering during the lock walk that the walk itself cannot see: the read-back verification catches it before the service is touched
    $te = New-TestEnv; $fs = New-FakeState $te.Folder
    $key2 = "$($te.Folder)\certs\a.key"
    $fs.Hooks.TakeOwnership = { param($p) if ($p -like '*\logs\error.log') { $a = Get-Acl -LiteralPath $key2; $a.AddAccessRule((New-Object Security.AccessControl.FileSystemAccessRule(([Security.Principal.SecurityIdentifier]'S-1-5-11'), 'Read', 'Allow'))); Set-Acl -LiteralPath $key2 -AclObject $a } }.GetNewClosure()
    $r = Invoke-Run $te $fs -Execute
    Assert-True ($r.ExitCode -eq 3 -and $null -ne $fs.Service -and ($r.Refusals -join ' ') -match 'verification failed') 'a lock that does not hold at the read-back stops the run BEFORE the service is deleted'
    # walk errors on their own (the tree is already locked, so the read-back alone would pass)
    $te = New-TestEnv; $fs = New-FakeState $te.Folder
    $null = Lock-RemovalFolderTree -Path $te.Folder -TrustedSids $Trusted -TakeOwnership { param($p) }
    $fs.Fail.TakeOwnership = 'a.key'
    $r = Invoke-Run $te $fs -Execute
    Assert-True ($r.ExitCode -eq 3 -and $null -ne $fs.Service -and ($r.Refusals -join ' ') -match 'lock walk had') 'an error during the lock walk stops the run even when the read-back would have passed'
    # the verifier, one clause at a time
    $te = New-TestEnv
    $broad = @($Trusted + 'S-1-5-11' + 'S-1-5-32-545')
    $v = Test-RemovalFolderLocked -Path $te.Folder -TrustedSids $broad
    Assert-True ((-not $v.Ok) -and @($v.Violations | Where-Object { $_ -match 'inherits' }).Count -ge 1) 'verifier: an object that still inherits from its parent is a violation'
    $v = Test-RemovalFolderLocked -Path $te.Folder -TrustedSids @('S-1-5-18')
    Assert-True (@($v.Violations | Where-Object { $_ -match 'owner is' }).Count -ge 1) 'verifier: an owner outside the trusted set is a violation'
    $te2 = New-TestEnv
    Set-Content -LiteralPath "$($te2.Folder)\held.txt" 'held'
    $null = Lock-RemovalFolderTree -Path $te2.Folder -TrustedSids $Trusted -TakeOwnership { param($p) }
    $okBefore = (Test-RemovalFolderLocked -Path $te2.Folder -TrustedSids $Trusted).Ok
    $script:AclTestHook = @{ BeforeOpen = { param($p) if ($p -like '*held.txt') { throw 'injected: cannot open' } } }   # the access-list library's own test seam
    try {
        $v = Test-RemovalFolderLocked -Path $te2.Folder -TrustedSids $Trusted
        Assert-True ($okBefore -and @($v.Errors).Count -ge 1 -and @($v.Violations).Count -eq 0 -and -not $v.Ok) 'verifier: a locked tree with an object it cannot open is NOT ok (a read error is never a pass)'
    } finally { $script:AclTestHook = $null }
    # something re-creates a task after the steps that removed it: the final read-back sees it
    $te = New-TestEnv; $fs = New-FakeState $te.Folder
    $fs.Hooks.RemoveRule = { param($id) if (@($fs.Rules).Count -eq 0) { $fs.Tasks['NginxReload'] = @{ Name = 'NginxReload'; Path = '\'; Enabled = $false; State = 'Disabled'; UserId = 'SYSTEM'; ActionText = 'nginx -s reload' } } }.GetNewClosure()
    $r = Invoke-Run $te $fs -Execute
    Assert-True ($r.ExitCode -eq 3 -and ($r.Refusals -join ' ') -match 'read-back') 'the final read-back catches an item that came back after its own step passed'
}

Section 'takeown hands ownership to the Administrators group (the real takeown.exe on a scratch file)'
Test-Step 'takeown-owner' {
    $te = New-TestEnv
    $f = "$($te.Folder)\own-me.txt"; Set-Content -LiteralPath $f 'x'
    $elev = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    if ($elev) {
        Invoke-RemovalTakeown -Path $f
        $o = (Get-AclSddlAndOwnerChecked -Path $f -IsDir $false).Owner
        Assert-True ($o -eq 'S-1-5-32-544') "after the production takeown call the owner is the Administrators group (got $o), not the current user"
    } else {
        $threw = $false; try { Invoke-RemovalTakeown -Path $f } catch { $threw = $true }
        Assert-True $threw 'not elevated: the production takeown call fails closed'
    }
}

Section 'the walk is link-safe (the lock never follows a junction)'
Test-Step 'links' {
    $te = New-TestEnv
    $victim = "$TmpRoot\removal-victim-$($te.Id)"; New-Item -ItemType Directory $victim | Out-Null; [void]$script:Cleanup.Add($victim)
    Set-Content -LiteralPath "$victim\precious.txt" 'precious'
    $snap = Get-TreeSnapshot $victim
    New-Item -ItemType Junction -Path "$($te.Folder)\bin\escape" -Target $victim | Out-Null
    New-Item -ItemType SymbolicLink -Path "$($te.Folder)\bin\filelink" -Target "$victim\precious.txt" -ErrorAction SilentlyContinue | Out-Null
    $own = New-Object System.Collections.ArrayList
    $w = Lock-RemovalFolderTree -Path $te.Folder -TrustedSids $Trusted -TakeOwnership { param($p) [void]$own.Add($p) }.GetNewClosure()
    Assert-True ($snap -ceq (Get-TreeSnapshot $victim)) 'the junction target (names, sizes, ACLs) is untouched after a full lock'
    Assert-True (@($own | Where-Object { $_ -like "$victim*" -or $_ -like '*\escape*' }).Count -eq 0) 'ownership was never taken through a link'
    Assert-True (@($w.Links).Count -ge 1 -and @($w.Links | Where-Object { $_ -like '*\escape' }).Count -eq 1) 'the junction is reported in Links, not entered'
    # inventory also stays out
    Assert-True (@((Get-RemovalFolderInventory -Path $te.Folder).Links).Count -ge 1) 'the inventory lists links without entering them'
}
}
finally { Remove-AllCleanup }

if (-not $NoSmoke) {
    Section 'REAL script, dry run only, as a child process: the machine is unchanged'
    Test-Step 'smoke' {
        . "$PSScriptRoot\hidden-process-lib.ps1"
        $snapNow = {
            $svc = [bool](Get-CimInstance Win32_Service -Filter "Name='NginxGateway'" -ErrorAction SilentlyContinue)
            $t = @(Get-ScheduledTask -ErrorAction SilentlyContinue | Where-Object { $_.TaskPath -eq '\' -and $script:RemovalAllowedTasks -ccontains $_.TaskName } | ForEach-Object { "$($_.TaskName)=$($_.State)" } | Sort-Object) -join ','
            $r = @(Get-NetFirewallRule -ErrorAction SilentlyContinue | Where-Object { $script:RemovalAllowedRules -contains $_.DisplayName } | ForEach-Object { "$($_.Name)=$($_.Enabled)" } | Sort-Object) -join ','
            $f = if (Test-Path -LiteralPath 'C:\nginx') { (Get-ChildItem -LiteralPath 'C:\nginx' -Recurse -Force -ErrorAction SilentlyContinue | Measure-Object).Count } else { -1 }
            $q = Test-Path -LiteralPath 'C:\ProgramData\nginx-quarantine'
            "svc=$svc|tasks=$t|rules=$r|folder=$f|quarantine=$q"
        }
        $before = & $snapNow
        $childArgs = @('-NoProfile', '-NonInteractive', '-File', (Join-Path $PSScriptRoot 'remove-nginx-gateway.ps1'))
        Assert-True ($childArgs -notcontains '-Execute') 'SAFETY: the smoke never passes -Execute to the real script'
        $h = Invoke-HiddenProcess -FilePath (Get-Command pwsh).Source -ArgumentList $childArgs -TimeoutSec 300
        Assert-True ($h.ExitCode -in 0, 2) "the real script in its default mode exits 0 or 2 (a would-refuse dry run), got $($h.ExitCode)"
        Assert-True ($h.Stdout -match 'DRY RUN') 'its output says DRY RUN'
        Assert-True ($h.Stdout -notmatch 'TOPSECRET' -and $h.Stdout -notmatch '-----BEGIN') 'its output holds no key material'
        $after = & $snapNow
        Assert-True ($before -ceq $after) "the real machine is unchanged by the real dry run ($after)"
    }
}

Write-Host ''
if ($script:Fail -eq 0) { Write-Host "RESULT: $($script:Pass) passed, 0 failed" -ForegroundColor Green; exit 0 }
Write-Host "RESULT: $($script:Pass) passed, $($script:Fail) failed" -ForegroundColor Red
$script:Failures | ForEach-Object { Write-Host "  - $_" -ForegroundColor Red }
exit 1
