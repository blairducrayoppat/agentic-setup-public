#requires -Version 7.0
<#
.SYNOPSIS
  Verifies the coder's tool-chain setup (#775 plan step 4) OFFLINE: the read grants, the coder-owned opencode
  configuration and its protection, the new probe checks 15-24, the research-log placement, and git trust for
  worktrees another account owns. No real account, no real folder and no machine setting is changed: every access
  list operation runs on a TEMP tree; where a second account is needed the current user stands in (de-elevated
  child processes) or a SID that is in no token.

.DESCRIPTION
  WHAT IS REAL: icacls, Get-Acl, git (including a worktree whose OWNER is SYSTEM, which reproduces git's
  "dubious ownership" refusal), the probe script run as a hidden child, the library functions under test.
  WHAT IS NOT PROVEN HERE (proven on the machine by verify-coder-containment.ps1 checks 15-24): the distinct
  blarai-coder token reading and running these folders, the real opencode start-up and its package install, the
  real :8099 proxy, the first logon that creates the coder profile.

  -Mutations re-runs THIS suite against mutated copies of the sources (each control disabled in turn). KILLED =
  non-zero exit AND a [FAIL] line; SURVIVED = exit 0; ERROR = non-zero with no [FAIL] line. The unmutated control
  must pass first. -ProveHarness shows the classification on a known survivor, crasher and kill.
  Exit 0 if everything passed.
#>
param([switch]$Mutations, [switch]$ProveHarness, [string[]]$Only = @(), [int]$Throttle = 3)
$ErrorActionPreference = 'Stop'
$script:SrcDir = $PSScriptRoot

if ($Mutations -or $ProveHarness) {
    try { (Get-Process -Id $PID).PriorityClass = 'BelowNormal' } catch { }
    . "$PSScriptRoot\hidden-process-lib.ps1"
    $pw = (Get-Command pwsh -ErrorAction SilentlyContinue).Source
    $files = 'coder-setup-lib.ps1', 'coder-acl-lib.ps1', 'coder-provisioning-lib.ps1', 'coder-leg-queue.ps1', 'coder-containment-probe.ps1', 'provision-coder-account.ps1', 'provision-coder-setup.ps1', 'verify-coder-containment.ps1', 'verify-coder-setup.ps1', 'fleet-lib.ps1', 'coder-leg-run.ps1', 'hidden-process-lib.ps1', 'new-agent-task.ps1', 'run-fleet.ps1'
    $run = {
        param($Dir, $Mut, $files, $pw, $SrcDir)
        . (Join-Path $SrcDir 'hidden-process-lib.ps1')
        New-Item -ItemType Directory -Force $Dir | Out-Null
        Copy-Item (Join-Path (Split-Path $SrcDir -Parent) 'configs') (Join-Path $Dir 'configs') -Recurse -Force
        $sd = Join-Path $Dir 'scripts'; New-Item -ItemType Directory -Force $sd | Out-Null
        foreach ($f in $files) { Copy-Item (Join-Path $SrcDir $f) (Join-Path $sd $f) }
        if ($Mut) {
            $target = Join-Path $sd $Mut.F
            # a checkout may hold CRLF; the mutation texts carry LF, so match on LF and write the mutated file back as LF
            $text = [IO.File]::ReadAllText($target).Replace("`r`n", "`n")
            if (-not $text.Contains($Mut.O)) { return @{ Class = 'ERROR'; Why = "mutation target not found in $($Mut.F)" } }
            [IO.File]::WriteAllText($target, $text.Replace($Mut.O, $Mut.W), (New-Object Text.UTF8Encoding($true)))
        }
        if ($Mut) { $env:BLARAI_SETUP_FAILFAST = '1' } else { Remove-Item Env:\BLARAI_SETUP_FAILFAST -ErrorAction SilentlyContinue }
        $h = Invoke-HiddenProcess -FilePath $pw -ArgumentList @('-NoProfile', '-NonInteractive', '-File', (Join-Path $sd 'verify-coder-setup.ps1')) -TimeoutSec 1500
        $out = $h.Stdout + "`n" + $h.Stderr
        $code = $h.ExitCode
        $fails = @($out -split "`n" | Where-Object { $_ -match '\[FAIL\]' })
        if ($code -eq 0) { return @{ Class = 'SURVIVED'; Why = 'the suite did not notice' } }
        if ($fails.Count -gt 0) { return @{ Class = 'KILLED'; Why = ("$($fails[0])").Trim() } }
        return @{ Class = 'ERROR'; Why = 'non-zero exit with no [FAIL] line: ' + (($out -split "`n" | Where-Object { $_.Trim() } | Select-Object -Last 3) -join ' | ') }
    }
    function Invoke-MutationRun([object[]]$Muts) {
        $tmp = Join-Path ([IO.Path]::GetTempPath()) ('setup-mut-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
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
        return @{ ControlOk = $controlOk; Results = $res }
    }
    if ($ProveHarness) {
        $proof = @(
            @{ N = 'survivor-comment-only';     F = 'coder-setup-lib.ps1'; O = 'function Test-CoderToolchainPathText {'; W = 'function Test-CoderToolchainPathText { # harmless' },
            @{ N = 'crashing-syntax-break';     F = 'coder-setup-lib.ps1'; O = 'function Test-CoderToolchainPathText {'; W = 'function Test-CoderToolchainPathText { }}}}' },
            @{ N = 'kill-wildcard-check-off';   F = 'coder-setup-lib.ps1'; O = "if (`$Path -match '[\*\?<>|`";\[\]]') { return"; W = "if (`$false -and `$Path -match '[\*\?<>|`";\[\]]') { return" }
        )
        $r = Invoke-MutationRun $proof
        $want = @{ 'survivor-comment-only' = 'SURVIVED'; 'crashing-syntax-break' = 'ERROR'; 'kill-wildcard-check-off' = 'KILLED' }
        $bad = @($r.Results | Where-Object { $want[$_.N] -ne $_.Class })
        if (-not $r.ControlOk -or $bad.Count -gt 0) { Write-Host 'PROVE-HARNESS FAILED' -ForegroundColor Red; exit 1 }
        Write-Host 'PROVE-HARNESS: survivor, crasher and kill each classified correctly' -ForegroundColor Green; exit 0
    }
    $muts = @(
        # the grants and their gate
        @{ N = 'grant-never-grant-equal-off';   F = 'coder-setup-lib.ps1'; O = "if (`$n -eq `$en) { return `"'`$Path' is a never-grant path`" }"; W = '' },
        @{ N = 'grant-contains-exclusion-off';  F = 'coder-setup-lib.ps1'; O = 'if ($en.StartsWith($n + ''\'')) {'; W = 'if ($false) {' },
        @{ N = 'grant-secret-component-off';    F = 'coder-setup-lib.ps1'; O = "if (`$comp -in '.ssh',"; W = "if (`$false -and `$comp -in '.ssh'," },
        @{ N = 'grant-operator-root-off';       F = 'coder-setup-lib.ps1'; O = "if (`$n -eq `$op) { return"; W = "if (`$false) { return" },
        @{ N = 'grant-appdata-root-off';        F = 'coder-setup-lib.ps1'; O = "foreach (`$root in 'appdata', 'appdata\roaming', 'appdata\local', '.config') {"; W = "foreach (`$root in @()) {" },
        @{ N = 'grant-shim-inheritable';        F = 'coder-setup-lib.ps1'; O = "Path = `$Manifest.OpencodeShimDir; Flags = '';"; W = "Path = `$Manifest.OpencodeShimDir; Flags = '(OI)(CI)';" },
        @{ N = 'grant-rights-modify';           F = 'coder-setup-lib.ps1'; O = "Id = 'docset'; Path = (Join-Path `$BlarRoot `$Manifest.DocsetRelative); Flags = '(OI)(CI)'; Rights = 'RX'"; W = "Id = 'docset'; Path = (Join-Path `$BlarRoot `$Manifest.DocsetRelative); Flags = '(OI)(CI)'; Rights = 'M'" },
        @{ N = 'grant-readback-off';            F = 'coder-setup-lib.ps1'; O = "if (`$state -ne 'read') { throw"; W = "if (`$false) { throw" },
        @{ N = 'grant-link-gate-off';           F = 'coder-setup-lib.ps1'; O = "if (`$it -and (`$it.Attributes -band [IO.FileAttributes]::ReparsePoint)) {`n            `$r.Reason = if"; W = "if (`$false) {`n            `$r.Reason = if" },
        @{ N = 'manifest-unknown-key-off';      F = 'coder-setup-lib.ps1'; O = "if (`$allowed -cnotcontains `$k) { throw"; W = "if (`$false) { throw" },
        @{ N = 'path-wildcard-check-off';       F = 'coder-setup-lib.ps1'; O = "if (`$Path -match '[\*\?<>|`";\[\]]') { return"; W = "if (`$false -and `$Path -match '[\*\?<>|`";\[\]]') { return" },
        @{ N = 'path-dotdot-check-off';         F = 'coder-setup-lib.ps1'; O = "if (`$Path -match '(^|[\\/])\.\.([\\/]|`$)') { return"; W = "if (`$false) { return" },
        # the config verdict and renderer
        @{ N = 'cfg-mcp-check-off';             F = 'coder-setup-lib.ps1'; O = "-ccontains 'mcp') { [void]`$failed.Add('mcp-present') }"; W = "-ccontains 'mcp-never') { [void]`$failed.Add('mcp-present') }" },
        @{ N = 'cfg-plugin-check-off';          F = 'coder-setup-lib.ps1'; O = "foreach (`$k in 'plugin', 'plugins') {"; W = "foreach (`$k in @()) {" },
        @{ N = 'cfg-loopback-check-off';        F = 'coder-setup-lib.ps1'; O = "if (`$url -notmatch '^http://(127"; W = "if (`$false -and `$url -notmatch '^http://(127" },
        @{ N = 'cfg-apikey-check-off';          F = 'coder-setup-lib.ps1'; O = "if (`$null -ne `$ak -and [string]`$ak -cne 'local') {"; W = "if (`$false) {" },
        @{ N = 'cfg-token-text-check-off';      F = 'coder-setup-lib.ps1'; O = "if (`$CoderText -match 'sk-"; W = "if (`$false -and `$CoderText -match 'sk-" },
        @{ N = 'cfg-permission-weaker-off';     F = 'coder-setup-lib.ps1'; O = "elseif (`$cm[`$k] -cne `$om[`$k]) {"; W = "elseif (`$false) {" },
        @{ N = 'cfg-permission-missing-off';    F = 'coder-setup-lib.ps1'; O = "if (-not `$cm.ContainsKey(`$k)) {"; W = "if (`$false) {" },
        @{ N = 'cfg-autoupdate-check-off';      F = 'coder-setup-lib.ps1'; O = "if (`$null -eq `$cv -or [string]`$cv -cne [string]`$ov) {"; W = "if (`$false) {" },
        @{ N = 'cfg-render-unchecked';          F = 'coder-setup-lib.ps1'; O = "if (-not `$v.Pass) { throw `"the coder opencode config would be unsafe"; W = "if (`$false) { throw `"the coder opencode config would be unsafe" },
        @{ N = 'cfg-surgery-count-off';         F = 'coder-setup-lib.ps1'; O = "if (`$hits.Count -ne 1) { throw"; W = "if (`$false) { throw" },
        @{ N = 'cfg-mcp-not-removed';           F = 'coder-setup-lib.ps1'; O = "if (`$topKeys -ccontains 'mcp') { `$text = Remove-JsonTopLevelProperty"; W = "if (`$false) { `$text = Remove-JsonTopLevelProperty" },
        @{ N = 'cfg-agents-unrendered';         F = 'coder-setup-lib.ps1'; O = "-Containment 'restricted_account')))"; W = "-Containment 'off')))" },
        @{ N = 'cfg-wrapper-operator-log';      F = 'coder-setup-lib.ps1'; O = 'path.join(os.homedir(), ".local", "share", "blarai-coder", "research-usage.jsonl")'; W = 'path.join("C:/Users/mrbla/agentic-setup/state", "research-usage.jsonl")' },
        @{ N = 'cfg-gitconfig-wildcard';        F = 'coder-setup-lib.ps1'; O = "`"``tdirectory = `$b/*`""; W = "`"``tdirectory = *`"" },
        # install, protection, verification
        @{ N = 'protect-coder-modify';          F = 'coder-setup-lib.ps1'; O = '(A;${inh};${CoderMask};;;${CoderSid})'; W = '(A;${inh};0x1301bf;;;${CoderSid})' },
        @{ N = 'stamp-path-based-fallback';     F = 'coder-setup-lib.ps1'; O = '[CoderHandleStamp]::Apply($h, $bytes, [bool]$SetOwner)'; W = '$pa = [Security.AccessControl.DirectorySecurity]::new(); $pa.SetSecurityDescriptorSddlForm($Sddl); Set-Acl -LiteralPath $Path -AclObject $pa' },
        @{ N = 'stamp-reparse-check-off';       F = 'coder-setup-lib.ps1'; O = 'if ((info.FileAttributes & ATTR_REPARSE_POINT) != 0)'; W = 'if (false)' },
        @{ N = 'stamp-protected-flag-dropped';  F = 'coder-setup-lib.ps1'; O = 'uint info = DACL_INFO | PROTECTED_DACL_INFO;'; W = 'uint info = DACL_INFO;' },
        @{ N = 'stamp-owner-dropped';           F = 'coder-setup-lib.ps1'; O = '[CoderHandleStamp]::Apply($h, $bytes, [bool]$SetOwner)'; W = '[CoderHandleStamp]::Apply($h, $bytes, $false)' },
        @{ N = 'stamp-open-follows-links';      F = 'coder-setup-lib.ps1'; O = 'BACKUP_SEMANTICS | OPEN_REPARSE_POINT, IntPtr.Zero'; W = 'BACKUP_SEMANTICS, IntPtr.Zero' },
        @{ N = 'probe-root-owner-off';          F = 'coder-containment-probe.ps1'; O = "pass = (`$o -eq 'S-1-5-32-544');"; W = 'pass = $true;' },
        @{ N = 'probe-root-link-off';           F = 'coder-containment-probe.ps1'; O = "elseif (`$a -band [IO.FileAttributes]::ReparsePoint) { `$per[`$d] = @{ pass = `$false; detail = 'is a link"; W = "elseif (`$false) { `$per[`$d] = @{ pass = `$false; detail = 'is a link" },
        @{ N = 'probe-root-inspect-error-passes'; F = 'coder-containment-probe.ps1'; O = '$per[$d] = @{ pass = $false; detail = "cannot be inspected'; W = '$per[$d] = @{ pass = $true; detail = "cannot be inspected' },
        @{ N = 'probe-root-unwired';            F = 'coder-containment-probe.ps1'; O = '; $result.checks.coder_config_root_intact = (Test-CoderConfigRootIntact) }'; W = ' }' },
        @{ N = 'setup-root-check-dropped';      F = 'coder-setup-lib.ps1'; O = "K = 'coder_config_root_intact';"; W = "K = 'coder_config_ok';" },
        @{ N = 'chain-final-path-check-off';    F = 'coder-setup-lib.ps1'; O = "if (`$final.TrimEnd('\') -ine `$expected.TrimEnd('\')) { throw"; W = "if (`$false) { throw" },
        @{ N = 'chain-assert-after-seam-off';   F = 'coder-setup-lib.ps1'; O = "            if (`$BeforeCreate) { & `$BeforeCreate `$d }`n            Assert-CoderHeldChain -Chain `$chain`n"; W = "            if (`$BeforeCreate) { & `$BeforeCreate `$d }`n" },
        @{ N = 'chain-assert-before-write-off'; F = 'coder-setup-lib.ps1'; O = "if (`$BeforeFileWrite) { & `$BeforeFileWrite `$dest }`n                Assert-CoderHeldChain -Chain `$chain`n"; W = "if (`$BeforeFileWrite) { & `$BeforeFileWrite `$dest }`n" },
        @{ N = 'chain-hold-allows-delete';      F = 'coder-setup-lib.ps1'; O = '$script:CoderHoldAllowsDelete = $false'; W = '$script:CoderHoldAllowsDelete = $true' },
        @{ N = 'chain-link-precheck-off';       F = 'coder-setup-lib.ps1'; O = "if (Test-PathIsLink -Path `$d) { throw `"refusing: '`$d' is a link`" }"; W = "`$null = 1" },
        @{ N = 'protect-skipped';               F = 'coder-setup-lib.ps1'; O = 'Set-CoderSecurityByHandle -Path $Path -Sddl $sddl -SetOwner:$SetOwner -Handle $Handle'; W = '$null = $sddl' },
        @{ N = 'install-link-check-off';        F = 'coder-setup-lib.ps1'; O = "throw `"refusing: '`$Path' is a link to"; W = "`$null = 1; `"is a link to" },
        @{ N = 'leaf-anchor-check-off';         F = 'coder-setup-lib.ps1'; O = "if (`$anchor -and (Test-PathIsLink -Path `$anchor))"; W = "if (`$false)" },
        @{ N = 'linkstate-error-passes';        F = 'coder-setup-lib.ps1'; O = "catch [IO.FileNotFoundException], [IO.DirectoryNotFoundException] { return `$false }"; W = "catch { return `$false }" },
        @{ N = 'protectdir-before-check-off';   F = 'coder-setup-lib.ps1'; O = "Assert-CoderDirNotLink -Path `$Path -When 'before'"; W = "`$null = 1" },
        @{ N = 'protectdir-after-check-off';    F = 'coder-setup-lib.ps1'; O = "Assert-CoderDirNotLink -Path `$Path -When 'after'"; W = "`$null = 1" },
        @{ N = 'verify-dir-link-off';           F = 'coder-setup-lib.ps1'; O = "[void]`$failed.Add(`"link:`$rel`"); continue"; W = "`$null = 1; continue" },
        @{ N = 'verify-write-check-off';        F = 'coder-setup-lib.ps1'; O = "[void]`$failed.Add(`"writable-by-coder:`$(`$f.Rel)`")"; W = "`$null = 1" },
        @{ N = 'verify-unexpected-off';         F = 'coder-setup-lib.ps1'; O = "[void]`$failed.Add(`"unexpected-file:`$d\`$(`$e.Name)`")"; W = "`$null = 1" },
        @{ N = 'verify-hash-off';               F = 'coder-setup-lib.ps1'; O = "if (`$h -cne `$f.Sha256) { [void]`$failed.Add(`"modified:"; W = "if (`$false) { [void]`$failed.Add(`"modified:" },
        @{ N = 'rights-mask-no-write';          F = 'coder-setup-lib.ps1'; O = 'return [int]($r::WriteData -bor'; W = 'return [int]($r::Delete -bor' },
        @{ N = 'setup-verdict-missing-passes';  F = 'coder-setup-lib.ps1'; O = "`$pass = `$false; `$detail = 'the probe result has no such check'"; W = "`$pass = `$true; `$detail = 'the probe result has no such check'" },
        # the probe
        @{ N = 'probe-safe-dir-wildcard';       F = 'coder-containment-probe.ps1'; O = "('safe.directory=' + `$wt.TrimEnd('\').Replace('\', '/'))"; W = "'safe.directory=*'" },
        @{ N = 'probe-extra-write-off';         F = 'coder-containment-probe.ps1'; O = "per[`$d] = @{ pass = [bool]`$r.Denied; detail = `$r.Detail }`n        if (-not `$r.Denied) { `$all = `$false }`n    }`n    return @{ pass = (`$all -and `$ExtraWriteDenyDirs.Count"; W = "per[`$d] = @{ pass = `$true; detail = `$r.Detail }`n    }`n    return @{ pass = (`$all -and `$ExtraWriteDenyDirs.Count" },
        @{ N = 'probe-config-write-delete-off'; F = 'coder-containment-probe.ps1'; O = 'pass = ([bool]$r.Denied -and [bool]$d.Denied)'; W = 'pass = ([bool]$r.Denied)' },
        @{ N = 'probe-userprofile-match-off';   F = 'coder-containment-probe.ps1'; O = '-and ($nRead -gt 20) -and $homeOk'; W = '-and ($nRead -gt 20)' },
        @{ N = 'probe-gitconfig-only-off';      F = 'coder-containment-probe.ps1'; O = '-and $rc2 -eq 0 -and -not $dubious2)'; W = ')' },
        @{ N = 'probe-toolchain-rc-off';        F = 'coder-containment-probe.ps1'; O = '$per[$tool] = @{ pass = ($p.ExitCode -eq 0);'; W = '$per[$tool] = @{ pass = $true;' },
        @{ N = 'probe-proxy-status-off';        F = 'coder-containment-probe.ps1'; O = 'if ($status -and $status -ge 400 -and $status -lt 500) { return @{ pass = $true; detail = "GET $ProxyUrl -> HTTP $status (the proxy answered)"'; W = 'if ($status) { return @{ pass = $true; detail = "GET $ProxyUrl -> HTTP $status (the proxy answered)"' },
        @{ N = 'probe-operator-deny-unwired';   F = 'coder-containment-probe.ps1'; O = "if (`$OperatorDenyPaths.Count -gt 0) { `$result.checks.operator_profile_denied"; W = "if (`$false) { `$result.checks.operator_profile_denied" },
        # wiring
        @{ N = 'runner-path-prefix-removed';    F = 'coder-leg-run.ps1'; O = "`$env:PATH = `$env:PATH.TrimEnd(';') + ';' + ((Get-CoderToolchainPathPrefix -Manifest `$tcm) -join ';')"; W = "`$null = `$tcm" },
        @{ N = 'runner-proxy-unmapped';         F = 'coder-leg-run.ps1'; O = "@('proxy_url', 'ProxyUrl'), "; W = "" },
        @{ N = 'schema-proxy-open';             F = 'coder-leg-queue.ps1'; O = "proxy_url = @{ Type = 'string'; Pattern = '^http://127"; W = "proxy_url = @{ Type = 'string'; Pattern = '^http://.*|^http://127" },
        @{ N = 'schema-deny-paths-unchecked';   F = 'coder-leg-queue.ps1'; O = "operator_deny_paths = @{ Type = 'array'; Items = @{ Type = 'string'; Pattern = `$script:CoderLegPathPattern } }"; W = "operator_deny_paths = @{ Type = 'array'; Items = @{ Type = 'string' } }" },
        @{ N = 'provision-setup-unwired';       F = 'provision-coder-account.ps1'; O = "& (Join-Path `$PSScriptRoot 'provision-coder-setup.ps1') -Apply"; W = "`$null = (Join-Path `$PSScriptRoot 'provision-coder-setup.ps1') -Apply" },
        @{ N = 'provision-rollback-unwired';    F = 'provision-coder-account.ps1'; O = "& (Join-Path `$PSScriptRoot 'provision-coder-setup.ps1') -Rollback"; W = "`$null = (Join-Path `$PSScriptRoot 'provision-coder-setup.ps1') -Rollback" },
        @{ N = 'containment-setup-not-decisive'; F = 'verify-coder-containment.ps1'; O = ' -and $setupFailed.Count -eq 0) {'; W = ') {' },
        @{ N = 'containment-install-check-off'; F = 'verify-coder-containment.ps1'; O = "`$setupFailed = @(`$sv.Verdict.Failed) + `$(if (-not `$installed.Pass)"; W = "`$setupFailed = @(`$sv.Verdict.Failed) + `$(if (`$false -and -not `$installed.Pass)" },
        @{ N = 'off-path-reads-setup-lib';      F = 'new-agent-task.ps1'; O = '. "$PSScriptRoot\fleet-lib.ps1"'; W = '. "$PSScriptRoot\fleet-lib.ps1"; . "$PSScriptRoot\coder-setup-lib.ps1"' }
    )
    if ($Only.Count -gt 0) { $muts = @($muts | Where-Object { $Only -contains $_.N }) }
    Write-Host "mutation run: $($muts.Count) mutants over the setup library, probe, provisioning, runner and verify wiring" -ForegroundColor Cyan
    $r = Invoke-MutationRun $muts
    if (-not $r.ControlOk) { exit 1 }
    $k = @($r.Results | Where-Object { $_.Class -eq 'KILLED' }).Count
    $s = @($r.Results | Where-Object { $_.Class -eq 'SURVIVED' }); $e = @($r.Results | Where-Object { $_.Class -eq 'ERROR' })
    Write-Host ("MUTATIONS: {0} killed, {1} survived, {2} error (of {3})" -f $k, $s.Count, $e.Count, @($r.Results).Count) -ForegroundColor $(if ($s.Count -eq 0 -and $e.Count -eq 0) { 'Green' } else { 'Red' })
    if ($s.Count -gt 0 -or $e.Count -gt 0) { exit 1 }
    exit 0
}

# =============================================================================================================
. "$PSScriptRoot\hidden-process-lib.ps1"
. "$PSScriptRoot\coder-acl-lib.ps1"
. "$PSScriptRoot\coder-leg-queue.ps1"
. "$PSScriptRoot\coder-provisioning-lib.ps1"
. "$PSScriptRoot\coder-setup-lib.ps1"
$script:Repo = Split-Path $PSScriptRoot -Parent
$script:Pass = 0; $script:Fail = 0
$script:Failures = New-Object System.Collections.ArrayList
$script:FailFast = [bool]$env:BLARAI_SETUP_FAILFAST
function _pass($m) { $script:Pass++; Write-Host "  [PASS] $m" -ForegroundColor Green }
function _fail($m) {
    $script:Fail++; [void]$script:Failures.Add($m); Write-Host "  [FAIL] $m" -ForegroundColor Red
    if ($script:FailFast) { Write-Host "RESULT: $($script:Pass) passed, $($script:Fail) failed (fail-fast)" -ForegroundColor Red; exit 1 }
}
function Section($t) { Write-Host ''; Write-Host "== $t ==" -ForegroundColor Cyan }
function Assert-True($c, $m) { if ($c) { _pass $m } else { _fail "$m (expected True)" } }
function Assert-Eq($e, $a, $m) { if ([string]$e -ceq [string]$a) { _pass $m } else { _fail "$m (expected '$e', got '$a')" } }
function Assert-Throws([scriptblock]$Body, [string]$Like, [string]$m) {
    $msg = $null
    try { & $Body } catch { $msg = $_.Exception.Message }
    if ($null -ne $msg -and $msg -like $Like) { _pass $m } elseif ($null -ne $msg) { _fail "$m (threw '$msg', expected like '$Like')" } else { _fail "$m (did not throw)" }
}
function Test-Step { param([string]$Name, [scriptblock]$Body) try { & $Body } catch { _fail "$Name threw: $($_.Exception.Message)" } }

# resolvable well-known accounts that are in no token of this run: icacls cannot write an entry for an unresolvable SID (exit 1332)
$fakeCoder = 'S-1-5-19'      # LOCAL SERVICE, stands in for the coder where an entry is written
$fakeOperator = 'S-1-5-20'   # NETWORK SERVICE, stands in for the operator
$meSid = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
$elevated = Test-CallerElevated
$tmpRoot = Join-Path ([IO.Path]::GetTempPath()) ('coder-setup-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
New-Item -ItemType Directory $tmpRoot | Out-Null
$pwsh = (Get-Command pwsh).Source
$winBefore = @(Get-VisibleConsoleProcessIds)

try {
$shippedManifestPath = Join-Path $script:Repo 'configs\coder-toolchain.json'
$shipped = Read-CoderToolchainManifest -Path $shippedManifestPath
$agentic = $script:Repo
$blar = 'C:\Users\mrbla\blarai'

Section 'A. the toolchain manifest is strict (a manifest that cannot be trusted grants nothing)'
Test-Step 'manifest' {
    Assert-True ($shipped.OpencodePackageDir -like '*\opencode-ai' -and $shipped.OpencodeShimDir -like '*\npm') 'the shipped manifest names the opencode package folder and the shim folder'
    Assert-Eq (Join-Path $shipped.OpencodePackageDir 'bin\opencode.exe') $shipped.OpencodeExe 'the opencode exe is derived from the package folder'
    Assert-True (@($shipped.MachineExes.Keys).Count -eq 4 -and $shipped.MachineExes.Contains('git_bash')) 'four machine executables: node, git, git_bash, python'
    $good = [IO.File]::ReadAllText($shippedManifestPath)
    $mk = { param($name, $text) $p = Join-Path $tmpRoot "$name.json"; [IO.File]::WriteAllText($p, $text); $p }
    Assert-Throws { Read-CoderToolchainManifest -Path (Join-Path $tmpRoot 'absent.json') } '*not found*' 'a missing manifest throws'
    Assert-Throws { Read-CoderToolchainManifest -Path (& $mk 'garbled' '{not json') } '*not valid JSON*' 'a garbled manifest throws'
    Assert-Throws { Read-CoderToolchainManifest -Path (& $mk 'unknown' ($good -replace '"note"', '"extra_grant": "C:/x", "note"')) } "*unknown key 'extra_grant'*" 'an unknown key throws (a typo would silently drop a grant)'
    Assert-Throws { Read-CoderToolchainManifest -Path (& $mk 'nokey' ($good -replace '"opencode_shim_dir"', '"opencode_shim_dirx"')) } '*unknown key*' 'a renamed key throws'
    Assert-Throws { Read-CoderToolchainManifest -Path (& $mk 'rel' ($good -replace 'C:/Users/mrbla/AppData/Roaming/npm/node_modules/opencode-ai', 'node_modules/opencode-ai')) } '*not an absolute drive path*' 'a relative path throws'
    Assert-Throws { Read-CoderToolchainManifest -Path (& $mk 'wild' ($good -replace 'node_modules/opencode-ai', 'node_modules/*')) } '*wildcard*' 'a wildcard path throws'
    Assert-Throws { Read-CoderToolchainManifest -Path (& $mk 'dd' ($good -replace 'npm/node_modules/opencode-ai', 'npm/../.ssh')) } '*dot-dot*' 'a dot-dot path throws'
    Assert-Throws { Read-CoderToolchainManifest -Path (& $mk 'unc' ($good -replace '"C:/Users/mrbla/AppData/Roaming/npm"', '"//evil/share"')) } '*not an absolute drive path*' 'a UNC path throws'
    Assert-Throws { Read-CoderToolchainManifest -Path (& $mk 'ver' ($good -replace '1\.17\.3', '^1.17')) } '*exact x.y.z*' 'a version range throws (the plugin version is pinned)'
    Assert-Throws { Read-CoderToolchainManifest -Path (& $mk 'docs' ($good -replace '"models/docsets"', '"../outside"')) } '*plain relative path*' 'a docset path that leaves the BlarAI root throws'
    Assert-Throws { Read-CoderToolchainManifest -Path (& $mk 'exe' ($good -replace '"node": "C:/Program Files/nodejs/node.exe"', '"node": "C:/Program Files/nodejs/node.exe", "curl": "C:/x"')) } "*machine_exes has unknown key 'curl'*" 'an extra machine executable throws'
    Assert-True ((Test-CoderToolchainPathText 'C:\a\b') -eq '' -and (Test-CoderToolchainPathText 'C:/a/b') -eq '') 'both slash spellings are accepted'
    foreach ($bad in 'C:\a;C:\b', 'C:\a|b', 'C:\a"b', 'C:\a?b', 'C:\a:stream', "C:\a`nb") { Assert-True ((Test-CoderToolchainPathText $bad) -ne '') "refused: $($bad -replace "`n", '<LF>')" }
}

Section 'B. the read grants: exactly four, read-and-run only, never an excluded path'
Test-Step 'grants' {
    $grants = @(Get-CoderToolchainReadGrants -Manifest $shipped -AgenticRoot $agentic -BlarRoot $blar -OperatorProfile 'C:\Users\mrbla')
    Assert-Eq 4 $grants.Count 'four grants'
    Assert-Eq 'opencode-package|opencode-shim-dir|agentic-tools|docset' (($grants | ForEach-Object { $_.Id }) -join '|') 'the grants are the opencode package, the shim folder, the fleet tools and the docset'
    Assert-True (@($grants | Where-Object { $_.Rights -ne 'RX' }).Count -eq 0) 'every grant is read-and-run (RX): no write right in any'
    Assert-Eq '' (@($grants | Where-Object { $_.Id -eq 'opencode-shim-dir' })[0].Flags) 'the shim folder is granted THIS FOLDER ONLY (no inheritance flags): its children stay unreadable'
    Assert-True (@($grants | Where-Object { $_.Id -ne 'opencode-shim-dir' -and $_.Flags -ne '(OI)(CI)' }).Count -eq 0) 'the three package/tool/docset folders carry the inheritable flags'
    $excl = Get-CoderCodeReadExclusions -AgenticRoot $agentic -BlarRoot $blar
    $norm = { param($p) ($p -replace '/', '\').TrimEnd('\').ToLowerInvariant() }
    $gn = @($grants | ForEach-Object { & $norm $_.Path })
    Assert-True (@($excl | Where-Object { $gn -contains (& $norm $_) }).Count -eq 0) 'no grant equals an excluded path (certs, repo roots, the runtime keystore)'
    Assert-True (@($grants | Where-Object { $_.Path -like '*\state' -or $_.Path -like '*\state\*' -or $_.Path -like '*\.config*' -or $_.Path -like '*\.ssh*' }).Count -eq 0) 'no grant touches the operator state folder, ~/.config or ~/.ssh'
    Assert-True (@($grants | Where-Object { $_.Path -like '*AppData\Local\BlarAI*' }).Count -eq 0) 'no grant touches %LOCALAPPDATA%\BlarAI'
    Assert-Eq 'C:\Users\mrbla\AppData\Roaming\npm' ((Get-CoderToolchainPathPrefix -Manifest $shipped) -join ';') 'the PATH prefix is exactly the shim folder'
    $exes = @(Get-CoderToolchainProbeExes -Manifest $shipped)
    Assert-True ($exes.Count -eq 5 -and $exes[0] -like '*opencode.exe') 'the probe runs opencode.exe plus the four machine executables'
    $cmd = Get-CoderToolchainGrantCommand -Grant $grants[0] -CoderSid $fakeCoder
    Assert-Eq "*${fakeCoder}:(OI)(CI)RX" $cmd[2] 'the icacls entry is built from the SID, with the inheritable read-and-run spelling'
    Assert-Eq "*${fakeCoder}:RX" (Get-CoderToolchainGrantCommand -Grant $grants[1] -CoderSid $fakeCoder)[2] 'the shim folder entry has no inheritance flags'
    # the gate refuses what it must
    $x = @((Join-Path $blar 'certs'), $blar, $agentic, 'C:\Users\mrbla\AppData\Local\BlarAI', 'C:\Users\mrbla\.config\opencode', 'C:\Users\mrbla\.ssh')
    foreach ($case in @(
        @{ P = (Join-Path $blar 'certs'); L = 'certs' }, @{ P = $blar; L = 'the BlarAI root (equal)' }, @{ P = $agentic; L = 'the agentic root (equal)' },
        @{ P = 'C:\Users\mrbla'; L = 'the operator profile root (contains the excluded .ssh and keystore)' },
        @{ P = 'C:\Users\mrbla\AppData\Local'; L = '%LOCALAPPDATA% (contains the keystore)' },
        @{ P = 'C:\Users\mrbla\AppData\Roaming'; L = '%APPDATA% root' }, @{ P = 'C:\Users\mrbla\AppData'; L = 'AppData root' },
        @{ P = 'C:\Users\mrbla\.ssh'; L = '.ssh' }, @{ P = 'C:\Users\mrbla\projects\x\.aws'; L = 'a .aws folder' },
        @{ P = (Join-Path $blar 'certs\mtls'); L = 'a folder inside certs' }, @{ P = 'C:\Users\mrbla\.config\opencode'; L = 'the operator opencode config (equal)' })) {
        Assert-True ((Test-CoderGrantAllowed -Path $case.P -Exclusions $x -OperatorProfile 'C:\Users\mrbla') -ne '') "a grant on $($case.L) is refused"
    }
    # each rule on its own (no other rule can catch the path)
    Assert-True ((Test-CoderGrantAllowed -Path 'C:\Users\mrbla' -Exclusions @() -OperatorProfile 'C:\Users\mrbla') -like '*operator profile root*') 'the operator profile root is refused by its own rule'
    Assert-True ((Test-CoderGrantAllowed -Path 'C:\Users\mrbla\AppData\Local' -Exclusions @() -OperatorProfile 'C:\Users\mrbla') -like '*appdata\local*root*') 'AppData\Local is refused by its own rule'
    Assert-True ((Test-CoderGrantAllowed -Path 'D:\proj' -Exclusions @('D:\proj\certs') -OperatorProfile '') -like '*contains the never-grant path*') 'a folder that CONTAINS an excluded one is refused (an inheritable grant would reach it)'
    Assert-True ((Test-CoderGrantAllowed -Path 'D:\proj\certs' -Exclusions @('D:\proj\certs') -OperatorProfile '') -like '*is a never-grant path*') 'an excluded folder itself is refused'
    Assert-Eq '' (Test-CoderGrantAllowed -Path 'D:\proj\other' -Exclusions @('D:\proj\certs') -OperatorProfile '') 'control: a sibling of an excluded folder is allowed'
    Assert-Eq '' (Test-CoderGrantAllowed -Path 'C:\Users\mrbla\AppData\Roaming\npm\node_modules\opencode-ai' -Exclusions $x -OperatorProfile 'C:\Users\mrbla') 'control: the real opencode package folder is allowed (the gate can say yes)'
    # a manifest aimed at a secret folder is refused as a whole
    $evil = $shipped.PSObject.Copy(); $evil.OpencodePackageDir = 'C:\Users\mrbla\.ssh'
    Assert-Throws { Get-CoderToolchainReadGrants -Manifest $evil -AgenticRoot $agentic -BlarRoot $blar -OperatorProfile 'C:\Users\mrbla' } "*grant 'opencode-package' refused*" 'a manifest pointing the package grant at ~/.ssh makes the whole list throw (nothing is partly applied)'
    $evil2 = $shipped.PSObject.Copy(); $evil2.OpencodeShimDir = 'C:\Users\mrbla\AppData\Roaming'
    Assert-Throws { Get-CoderToolchainReadGrants -Manifest $evil2 -AgenticRoot $agentic -BlarRoot $blar -OperatorProfile 'C:\Users\mrbla' } "*refused*" 'a shim grant on the whole Roaming folder throws'
}

Section 'C. the coder opencode config: rendered from the repo, minus the MCP block, safe by verdict'
$opText = [IO.File]::ReadAllText((Join-Path $agentic 'configs\opencode.json'), [Text.UTF8Encoding]::new($false))
Test-Step 'render' {
    $coderText = ConvertTo-CoderOpencodeConfigText -OperatorText $opText
    $o = ConvertFrom-JsonCompat -Text $opText; $c = ConvertFrom-JsonCompat -Text $coderText
    Assert-True ((Get-JsonKeys $o) -ccontains 'mcp') 'control: the operator source HAS an mcp block (so removing it is a real act)'
    Assert-True (-not ((Get-JsonKeys $c) -ccontains 'mcp')) 'the coder config has no mcp block'
    Assert-Eq ((Get-JsonKeys $o | Where-Object { $_ -ne 'mcp' }) -join ',') ((Get-JsonKeys $c) -join ',') 'every other top-level key is kept, in order'
    $om = Get-CoderPermissionMap $o; $cm = Get-CoderPermissionMap $c
    Assert-True ($om.Count -gt 100 -and $om.Count -eq $cm.Count) "the permission block is entry-for-entry the operator's ($($cm.Count) entries incl. the case variants)"
    Assert-True ($cm['read|**/secrets/**'] -ceq 'deny' -and $cm['read|**/SECRETS/**'] -ceq 'deny' -and $cm['read|~/.ssh/*'] -ceq 'deny') 'the read-deny list is intact (secrets, SECRETS, ~/.ssh)'
    Assert-Eq 'http://127.0.0.1:8099/v3' ([string](Get-JsonMember (Get-JsonMember (Get-JsonMember (Get-JsonMember $c 'provider') 'local') 'options') 'baseURL')) 'the provider wiring is the operator one (the :8099 repair proxy)'
    Assert-Eq $coderText (ConvertTo-CoderOpencodeConfigText -OperatorText $opText) 'the rendering is deterministic'
    # the text surgery touched nothing but the mcp property
    $mcpStart = $opText.IndexOf('"mcp"'); Assert-True ($mcpStart -gt 0 -and $coderText.IndexOf('"mcp"') -lt 0) 'the surgery removed the mcp key'
    Assert-True ($coderText.StartsWith($opText.Substring(0, $mcpStart).TrimEnd(" ", "`t"))) 'the text before the removed block is byte-identical'
    Assert-True ($coderText -notmatch 'playwright' -and $coderText -notmatch 'msedge') 'no browser tool command is left in the coder config'
    Assert-True ((Test-CoderOpencodeConfigSafe -CoderText $coderText -OperatorText $opText).Pass) 'the verdict function passes the rendered config'
}
Test-Step 'surgery' {
    $s = '{ "a": 1, "mcp": { "x": [1,2,{"mcp": 3}], "s": "}" }, "b": "mcp" }'
    $r = Remove-JsonTopLevelProperty -Text $s -Name 'mcp'
    $p = ConvertFrom-JsonCompat -Text $r
    Assert-True ((Get-JsonKeys $p) -join ',' -ceq 'a,b' -and $p['b'] -ceq 'mcp') 'a nested key of the same name and a string value "mcp" are not touched; braces inside strings do not confuse it'
    $last = Remove-JsonTopLevelProperty -Text "{`r`n  `"a`": 1,`r`n  `"mcp`": {`"k`": 1}`r`n}" -Name 'mcp'
    Assert-True ((Get-JsonKeys (ConvertFrom-JsonCompat -Text $last)) -join ',' -ceq 'a') 'removing the LAST property (CRLF text) leaves valid JSON'
    $first = Remove-JsonTopLevelProperty -Text "{`n  `"mcp`": 1,`n  `"a`": 2`n}" -Name 'mcp'
    Assert-True ((Get-JsonKeys (ConvertFrom-JsonCompat -Text $first)) -join ',' -ceq 'a') 'removing the FIRST property leaves valid JSON'
    Assert-Throws { Remove-JsonTopLevelProperty -Text '{"a":1}' -Name 'mcp' } '*occurs 0 time(s)*' 'a key that is not there throws'
    Assert-Throws { Remove-JsonTopLevelProperty -Text '{"mcp":1,"mcp":2}' -Name 'mcp' } '*occurs 2 time(s)*' 'a duplicate key throws (ambiguous)'
    Assert-Throws { Remove-JsonTopLevelProperty -Text '{"a":{"mcp":1}}' -Name 'mcp' } '*occurs 0 time(s)*' 'a key only nested is not a top-level hit'
    Assert-Throws { Remove-JsonTopLevelProperty -Text '{"MCP":1,"a":2}' -Name 'mcp' } '*occurs 0 time(s)*' 'the match is case-sensitive'
}
Test-Step 'verdict-toggles' {
    $good = ConvertTo-CoderOpencodeConfigText -OperatorText $opText
    $can = { param($text, $label, $expect)
        $v = Test-CoderOpencodeConfigSafe -CoderText $text -OperatorText $opText
        if (-not $v.Pass -and (@($v.Failed | Where-Object { $_ -like "$expect*" }).Count -gt 0)) { _pass "the verdict FAILS a config that $label ($expect)" }
        else { _fail "the verdict did not fail '$label' with $expect (Pass=$($v.Pass), Failed=$($v.Failed -join ','))" } }
    & $can $opText 'still has the MCP block' 'mcp-present'
    & $can ($good -replace '^\{', '{ "plugin": ["evil"],') 'declares a plugin' 'plugin-declared'
    & $can ($good -replace 'http://127\.0\.0\.1:8099/v3', 'https://api.example.com/v1') 'points the provider off the machine' 'provider-not-loopback'
    & $can ($good -replace '"apiKey": "local"', '"apiKey": "abc123"') 'carries a provider api key' 'credential-in-config:provider.local.apiKey'
    & $can ($good -replace '"apiKey": "local"', '"apiKey": "local", "authToken": "x"') 'carries an auth token option' 'credential-in-config:provider.local.authToken'
    & $can ($good -replace '"share": "disabled"', '"share": "disabled", "note": "sk-abcdefghijklmnopqrstuvwxyz0123"') 'contains a token-shaped string' 'credential-in-config:token-shaped-text'
    & $can ($good -replace '"~/.ssh/\*": "deny"', '"~/.ssh/*": "allow"') 'weakens a read deny' 'permission-weaker:read|~/.ssh/*'
    & $can ($good -replace '\s*"~/.ssh/\*": "deny",', '') 'drops a read deny' 'permission-missing:read|~/.ssh/*'
    & $can ($good -replace '"git push\*": "ask"', '"git push*": "allow"') 'weakens a bash ask' 'permission-weaker:bash|git push*'
    & $can ($good -replace '"autoupdate": false', '"autoupdate": true') 're-enables autoupdate' 'autoupdate-not-disabled'
    & $can ($good -replace '"share": "disabled"', '"share": "auto"') 're-enables sharing' 'share-not-disabled'
    Assert-Throws { ConvertTo-CoderOpencodeConfigText -OperatorText ($opText -replace 'http://127\.0\.0\.1:8099/v3', 'https://api.example.com/v1') } '*would be unsafe*provider-not-loopback*' 'the renderer refuses an operator source that would give an unsafe coder config'
    Assert-True ((Test-CoderOpencodeConfigSafe -CoderText '{garbled' -OperatorText $opText).Failed -contains 'parse-coder') 'an unparseable coder config fails (parse-coder)'
}

Section 'D. the plan: six config files plus the git config, from the repo only, nothing secret'
$plan = @(Get-CoderOpencodeConfigPlan -AgenticRoot $agentic -Manifest $shipped -WorktreeBase 'C:\blarai-fleet\worktrees')
Test-Step 'plan' {
    Assert-Eq 'opencode.json|AGENTS.md|package.json|plugin\command-timeout.js|plugin\path-normalize.js|tool\search_docs.js|git\config' (($plan | ForEach-Object { $_.Rel }) -join '|') 'the plan names exactly these files'
    $by = @{}; foreach ($f in $plan) { $by[$f.Rel] = $f }
    $txt = { param($rel) [Text.Encoding]::UTF8.GetString($by[$rel].Bytes) }
    Assert-Eq (Get-CoderAgentsRulesText -Text ([IO.File]::ReadAllText((Join-Path $agentic 'configs\AGENTS.md'), [Text.UTF8Encoding]::new($false))) -Containment 'restricted_account') (& $txt 'AGENTS.md') 'AGENTS.md is the restricted rendering (the commit rule replaced by the operator-funnel rule)'
    Assert-True ((& $txt 'AGENTS.md') -notmatch 'git add -A') 'the coder AGENTS.md no longer tells the coder to run git add -A'
    foreach ($p in 'command-timeout.js', 'path-normalize.js') {
        Assert-True ([Convert]::ToBase64String($by["plugin\$p"].Bytes) -ceq [Convert]::ToBase64String([IO.File]::ReadAllBytes((Join-Path $agentic "configs\opencode-plugins\$p")))) "plugin $p is byte-for-byte the repo file"
    }
    $pkg = (& $txt 'package.json') | ConvertFrom-Json
    Assert-Eq '1.17.3' $pkg.dependencies.'@opencode-ai/plugin' 'package.json pins the plugin package to the manifest version'
    $w = & $txt 'tool\search_docs.js'
    Assert-True ($w -match 'process\.env\.BLARAI_RESEARCH_USAGE_LOG' -and $w -match 'os\.homedir\(\), "\.local", "share", "blarai-coder", "research-usage\.jsonl"') 'the tool wrapper defaults the research usage log to a folder under the CODER profile'
    Assert-True ($w -match [regex]::Escape('/configs/opencode-tools/search_docs.js') -and $w -notmatch 'agentic-setup/state') 'the wrapper imports the repo tool and never names the operator state folder'
    $gc = & $txt 'git\config'
    Assert-True ($gc -match "(?m)^\s+directory = C:/blarai-fleet/worktrees/\*$" -and $gc -notmatch 'directory = \*') 'git\config trusts folders UNDER the worktree base (a prefix entry), never *'
    $all = ($plan | ForEach-Object { [Text.Encoding]::UTF8.GetString($_.Bytes) }) -join "`n"
    Assert-True ($all -notmatch 'C:/Users/mrbla/\.config|C:\\Users\\mrbla\\\.config|\.ssh/id_|BEGIN [A-Z ]*PRIVATE KEY|ghp_[A-Za-z0-9]{20}|sk-[A-Za-z0-9]{20}') 'no file names the operator opencode config or carries a key or token'
    Assert-True (@($plan | ForEach-Object { $_.Sha256 } | Select-Object -Unique).Count -eq $plan.Count -and @($plan | Where-Object { $_.Sha256 -notmatch '^[0-9a-f]{64}$' }).Count -eq 0) 'every file has its own SHA-256'
    Assert-Throws { Get-CoderGitConfigText -WorktreeBase 'C:\' } '*too broad*' 'a drive root is refused as the safe.directory prefix'
    Assert-Throws { Get-CoderGitConfigText -WorktreeBase 'C:\Users\mrbla' } '*too broad*' 'the operator profile folder is refused as the prefix'
    Assert-Throws { Get-CoderGitConfigText -WorktreeBase 'C:\fleet\*' } '*wildcard*' 'a wildcard base is refused'
}

Section 'E0. which rights count as "can change it"'
Test-Step 'rights' {
    $R = [Security.AccessControl.FileSystemRights]
    $one = { param($r, $type = 'Allow') @([pscustomobject]@{ Sid = $meSid; Rights = [int]$r; Type = $type }) }
    foreach ($w in 'WriteData', 'AppendData', 'WriteExtendedAttributes', 'WriteAttributes', 'Delete', 'DeleteSubdirectoriesAndFiles', 'ChangePermissions', 'TakeOwnership') {
        Assert-True (@(Test-RulesGrantWrite -Rules (& $one $R::$w) -WatchSids @($meSid)).Count -eq 1) "the single right $w counts as write access"
    }
    foreach ($rd in 'ReadData', 'ReadAttributes', 'ReadExtendedAttributes', 'ExecuteFile', 'ReadPermissions', 'Synchronize') {
        Assert-True (@(Test-RulesGrantWrite -Rules (& $one $R::$rd) -WatchSids @($meSid)).Count -eq 0) "the single right $rd does not"
    }
    Assert-True (@(Test-RulesGrantWrite -Rules (& $one 0x1200a9) -WatchSids @($meSid)).Count -eq 0) 'read-and-run (0x1200a9) is not write access'
    Assert-True (@(Test-RulesGrantWrite -Rules (& $one 0x1301bf) -WatchSids @($meSid)).Count -eq 1) 'modify (0x1301bf) is'
    $both = @(& $one 0x1301bf; & $one 0x1301bf 'Deny')
    Assert-True (@(Test-RulesGrantWrite -Rules $both -WatchSids @($meSid)).Count -eq 0) 'an explicit Deny of the same rights cancels the Allow'
    Assert-True (@(Test-RulesGrantWrite -Rules (& $one 0x1301bf) -WatchSids @('S-1-5-99')).Count -eq 0) 'a rule for a SID nobody watches is ignored'
}

Section 'E. installing it on a temp profile: protected, verified, idempotent, undone exactly'
$prof = Join-Path $tmpRoot 'profile'
New-Item -ItemType Directory $prof | Out-Null
$cfgDir = Join-Path $prof '.config\opencode'
Test-Step 'install' {
    $r = Install-CoderOpencodeConfig -ConfigDir $cfgDir -Plan $plan -CoderSid $meSid -OperatorSid $fakeOperator
    Assert-Eq 7 $r.Written.Count 'first install writes all seven files'
    Assert-True ((Test-Path (Join-Path $cfgDir 'plugin\command-timeout.js')) -and (Test-Path (Join-Path $prof '.config\git\config'))) 'the files exist (the git config under .config\git)'
    $v = Test-CoderOpencodeConfigInstalled -ConfigDir $cfgDir -Plan $plan -CoderSid $meSid
    Assert-True $v.Pass "the installed configuration verifies (failed: $($v.Failed -join ','))"
    # the access list: coder RX only, nothing inherited
    $rules = Get-ObjectAccessRules -Path (Join-Path $cfgDir 'opencode.json')
    $mine = @($rules | Where-Object { $_.Sid -eq $meSid })
    Assert-True ($mine.Count -eq 1 -and @(Test-RulesGrantWrite -Rules $mine -WatchSids @($meSid)).Count -eq 0) 'the coder (stand-in) has exactly one entry on opencode.json and it has no write right'
    Assert-True (@($rules | Where-Object { $_.Sid -in 'S-1-5-32-544', 'S-1-5-18', $fakeOperator }).Count -eq 3) 'Administrators, SYSTEM and the operator are the other three entries'
    foreach ($d in '.config', '.config\opencode', '.config\opencode\plugin', '.config\opencode\tool', '.config\git') {
        $dp = Join-Path $prof $d
        Assert-True ((Get-ObjectOwnerSid -Path $dp) -eq 'S-1-5-32-544' -and @(Test-RulesGrantWrite -Rules (Get-ObjectAccessRules -Path $dp) -WatchSids (Get-CoderConfigWatchSids -CoderSid $meSid)).Count -eq 0) "folder $d is OWNED by Administrators and has no write entry for the coder (an owner could rewrite the list)"
    }
    $nmRules = Get-ObjectAccessRules -Path (Join-Path $cfgDir 'node_modules')
    Assert-True (@(Test-RulesGrantWrite -Rules $nmRules -WatchSids @($meSid)).Count -eq 1) 'node_modules is the ONE writable folder (opencode fills it on first start)'
    Assert-True ((Get-Acl -LiteralPath (Join-Path $cfgDir 'opencode.json')).AreAccessRulesProtected) 'the file does not inherit from its folder'
    $r2 = Install-CoderOpencodeConfig -ConfigDir $cfgDir -Plan $plan -CoderSid $meSid -OperatorSid $fakeOperator
    Assert-True ($r2.Written.Count -eq 0 -and $r2.Unchanged.Count -eq 7) 'a second install is a no-op (idempotent)'
    # a file with drifted bytes is repaired
    [IO.File]::WriteAllText((Join-Path $cfgDir 'AGENTS.md'), 'tampered')
    $v2 = Test-CoderOpencodeConfigInstalled -ConfigDir $cfgDir -Plan $plan -CoderSid $meSid
    Assert-True ((-not $v2.Pass) -and ($v2.Failed -contains 'modified:AGENTS.md')) 'tampered content is detected (modified:AGENTS.md)'
    $r3 = Install-CoderOpencodeConfig -ConfigDir $cfgDir -Plan $plan -CoderSid $meSid -OperatorSid $fakeOperator
    Assert-True ($r3.Written -contains 'AGENTS.md' -and (Test-CoderOpencodeConfigInstalled -ConfigDir $cfgDir -Plan $plan -CoderSid $meSid).Pass) 're-installing repairs it'
    # detections
    Set-Content -LiteralPath (Join-Path $cfgDir 'plugin\evil.js') 'x'
    $v3 = Test-CoderOpencodeConfigInstalled -ConfigDir $cfgDir -Plan $plan -CoderSid $meSid
    Assert-True ($v3.Failed -contains 'unexpected-file:plugin\evil.js') 'an extra file in plugin\ is detected'
    Remove-Item (Join-Path $cfgDir 'plugin\evil.js') -Force
    Remove-Item (Join-Path $cfgDir 'tool\search_docs.js') -Force
    Assert-True ((Test-CoderOpencodeConfigInstalled -ConfigDir $cfgDir -Plan $plan -CoderSid $meSid).Failed -contains 'missing:tool\search_docs.js') 'a missing file is detected'
    $null = Install-CoderOpencodeConfig -ConfigDir $cfgDir -Plan $plan -CoderSid $meSid -OperatorSid $fakeOperator
    # TOGGLE: a file left with the ordinary inherited list (the coder = full control) must FAIL the verdict
    $loose = Join-Path $cfgDir 'AGENTS.md'
    & icacls $loose /grant "*${meSid}:(F)" | Out-Null    # the coder entry is now full control
    $vl = Test-CoderOpencodeConfigInstalled -ConfigDir $cfgDir -Plan $plan -CoderSid $meSid
    Assert-True ((-not $vl.Pass) -and ($vl.Failed -contains 'writable-by-coder:AGENTS.md')) 'TOGGLE: with the protection off (the coder holds a write entry) the verdict FAILS (writable-by-coder:AGENTS.md)'
    $null = Install-CoderOpencodeConfig -ConfigDir $cfgDir -Plan $plan -CoderSid $meSid -OperatorSid $fakeOperator
    # also a broad group counts as "the coder can write it"
    & icacls (Join-Path $cfgDir 'opencode.json') /grant '*S-1-5-32-545:(M)' | Out-Null
    Assert-True ((Test-CoderOpencodeConfigInstalled -ConfigDir $cfgDir -Plan $plan -CoderSid $meSid).Failed -contains 'writable-by-coder:opencode.json') 'Users:Modify on a file counts as writable by the coder (broad groups are watched)'
    $null = Install-CoderOpencodeConfig -ConfigDir $cfgDir -Plan $plan -CoderSid $meSid -OperatorSid $fakeOperator
    Assert-True ((Test-CoderOpencodeConfigInstalled -ConfigDir $cfgDir -Plan $plan -CoderSid $meSid).Pass) 'and re-installing repairs the list'
}
Test-Step 'links' {
    $p2 = Join-Path $tmpRoot 'profile2'; New-Item -ItemType Directory (Join-Path $p2 '.config\opencode') -Force | Out-Null
    $victim = Join-Path $tmpRoot 'victim'; New-Item -ItemType Directory $victim | Out-Null
    New-Item -ItemType Junction -Path (Join-Path $p2 '.config\opencode\plugin') -Target $victim | Out-Null
    Assert-Throws { Install-CoderOpencodeConfig -ConfigDir (Join-Path $p2 '.config\opencode') -Plan $plan -CoderSid $meSid -OperatorSid $fakeOperator } "*is a link*" 'a junction where plugin\ should be makes the install refuse'
    Assert-Eq 0 @(Get-ChildItem -LiteralPath $victim -Force).Count 'nothing was written through the junction'
    (Get-Item (Join-Path $p2 '.config\opencode\plugin')).Delete()
    New-Item -ItemType Junction -Path (Join-Path $p2 '.config') -Target $victim -Force -ErrorAction SilentlyContinue | Out-Null
}
Test-Step 'handle-stamp' {
    # The access list is applied to an OPEN HANDLE of the object itself (Set-CoderSecurityByHandle): a link is refused
    # and a path swapped for a link after the open changes nothing outside the opened object.
    $stampRef = {
        # the reference: the same descriptor text applied the old way (by path) to an ordinary folder/file
        param($Path, [bool]$IsDirectory)
        $inh = if ($IsDirectory) { 'OICI' } else { '' }
        $sddl = "O:BAD:P(A;${inh};FA;;;BA)(A;${inh};FA;;;SY)(A;${inh};FA;;;${fakeOperator})(A;${inh};0x1200a9;;;${fakeCoder})"
        $a = if ($IsDirectory) { [Security.AccessControl.DirectorySecurity]::new() } else { [Security.AccessControl.FileSecurity]::new() }
        $a.SetSecurityDescriptorSddlForm($sddl)
        Set-Acl -LiteralPath $Path -AclObject $a -ErrorAction Stop
    }
    $hs = Join-Path $tmpRoot 'handle-stamp'; New-Item -ItemType Directory $hs | Out-Null
    # normal stamp: identical to the path-based result (same list, same owner, protected)
    $dNew = Join-Path $hs 'dir-new'; $dRef = Join-Path $hs 'dir-ref'
    New-Item -ItemType Directory $dNew, $dRef | Out-Null
    Protect-CoderConfigObject -Path $dNew -CoderSid $fakeCoder -OperatorSid $fakeOperator -IsDir -SetOwner
    & $stampRef $dRef $true
    Assert-Eq (Get-Acl -LiteralPath $dRef).Sddl (Get-Acl -LiteralPath $dNew).Sddl 'a folder stamped through the handle has exactly the access list and owner the path-based apply gave'
    Assert-Eq 'S-1-5-32-544' (Get-ObjectOwnerSid -Path $dNew) 'the folder is owned by Administrators'
    Assert-True (Get-Acl -LiteralPath $dNew).AreAccessRulesProtected 'the folder list is protected (nothing inherited)'
    $fNew = Join-Path $hs 'file-new.txt'; $fRef = Join-Path $hs 'file-ref.txt'
    [IO.File]::WriteAllText($fNew, 'x'); [IO.File]::WriteAllText($fRef, 'x')
    Protect-CoderConfigObject -Path $fNew -CoderSid $fakeCoder -OperatorSid $fakeOperator -SetOwner
    & $stampRef $fRef $false
    Assert-Eq (Get-Acl -LiteralPath $fRef).Sddl (Get-Acl -LiteralPath $fNew).Sddl 'a file stamped through the handle has exactly the access list and owner the path-based apply gave'
    # a junction is refused and its target keeps its list
    $victim = Join-Path $hs 'victim'; New-Item -ItemType Directory $victim | Out-Null
    $vBefore = (Get-Acl -LiteralPath $victim).Sddl
    $jn = Join-Path $hs 'jn'; New-Item -ItemType Junction -Path $jn -Target $victim | Out-Null
    Assert-Throws { Protect-CoderConfigObject -Path $jn -CoderSid $fakeCoder -OperatorSid $fakeOperator -IsDir -SetOwner } '*reparse point*' 'stamping a junction is refused by the handle apply itself (no earlier link check in the way)'
    Assert-Eq $vBefore (Get-Acl -LiteralPath $victim).Sddl 'and the junction target keeps its list and owner'
    (Get-Item $jn).Delete()
    # fail-closed: a path that does not exist is an error, never a silent success
    Assert-Throws { Protect-CoderConfigObject -Path (Join-Path $hs 'absent') -CoderSid $fakeCoder -OperatorSid $fakeOperator -IsDir -SetOwner } '*cannot open*' 'a path that cannot be opened throws'
    # THE RACE: the folder is swapped for a junction AFTER the handle is open (the window a path-based call leaves)
    $raced = Join-Path $hs 'raced'; $aside = Join-Path $hs 'raced-aside'
    New-Item -ItemType Directory $raced | Out-Null
    $vBefore2 = (Get-Acl -LiteralPath $victim).Sddl
    $sddlRace = "O:BAD:P(A;OICI;FA;;;BA)(A;OICI;FA;;;SY)(A;OICI;FA;;;${fakeOperator})(A;OICI;0x1200a9;;;${fakeCoder})"
    Set-CoderSecurityByHandle -Path $raced -Sddl $sddlRace -SetOwner -AfterOpen {
        [IO.Directory]::Move($raced, $aside)
        New-Item -ItemType Junction -Path $raced -Target $victim | Out-Null
    }
    Assert-True (Test-PathIsLink -Path $raced) 'the stand-in really swapped the folder for a junction between the open and the apply'
    Assert-Eq $vBefore2 (Get-Acl -LiteralPath $victim).Sddl 'the junction target was NOT stamped (list and owner unchanged)'
    Assert-Eq 'S-1-5-32-544' (Get-ObjectOwnerSid -Path $aside) 'the opened folder (now renamed away) received the owner'
    Assert-Eq (Get-Acl -LiteralPath $dRef).Sddl (Get-Acl -LiteralPath $aside).Sddl 'and received the list'
    (Get-Item $raced).Delete()
    # the type definition is guarded: loading the library again in the same session is safe
    . "$PSScriptRoot\coder-setup-lib.ps1"
    Initialize-CoderHandleStamp
    Assert-True ([bool]('CoderHandleStamp' -as [type])) 'loading the library twice and re-initialising leaves the one type in place'
}
Test-Step 'ancestor-chain' {
    # The handle stamp covers the final component; the install also opens the profile root and every folder under it
    # into one verified chain of held handles. A swapped ANCESTOR must leave the victim tree completely untouched
    # (no new entry, no list or owner change, no inherited entry on what was already there) and make the run throw.
    $snap = {
        param($Root)
        (Get-ChildItem -LiteralPath $Root -Recurse -Force | Sort-Object FullName | ForEach-Object { "$($_.FullName.Substring($Root.Length))|$((Get-Acl -LiteralPath $_.FullName).Sddl)" }) -join "`n"
        (Get-Acl -LiteralPath $Root).Sddl
    }
    $newVictim = {
        param($Name)
        $v = Join-Path $tmpRoot $Name; New-Item -ItemType Directory (Join-Path $v 'opencode') -Force | Out-Null
        [IO.File]::WriteAllText((Join-Path $v 'opencode\secret.json'), 'secret')
        return $v
    }
    $newProfile = {
        param($Name)
        $pr = Join-Path $tmpRoot $Name; New-Item -ItemType Directory $pr | Out-Null
        return $pr
    }
    # (1) ~/.config is a junction before the install starts: refused, nothing written in the victim
    $pA = & $newProfile 'chainA'; $cA = Join-Path $pA '.config\opencode'; $vA = & $newVictim 'chainA-victim'
    New-Item -ItemType Junction -Path (Join-Path $pA '.config') -Target $vA | Out-Null
    $sA = & $snap $vA
    Assert-Throws { Install-CoderOpencodeConfig -ConfigDir $cA -Plan $plan -CoderSid $meSid -OperatorSid $fakeOperator } '*link*' '(1) ~/.config already a junction: the install is refused'
    Assert-Eq $sA (& $snap $vA) '(1) and the victim tree is untouched (no entry, list, owner or inherited entry changed)'
    (Get-Item (Join-Path $pA '.config')).Delete()

    # (2) the OS hold: a held ancestor cannot be renamed away while the install runs
    $pB = & $newProfile 'chainB'; $cB = Join-Path $pB '.config\opencode'; $vB = & $newVictim 'chainB-victim'
    $sB = & $snap $vB; $script:moveErr = $null
    $null = Install-CoderOpencodeConfig -ConfigDir $cB -Plan $plan -CoderSid $meSid -OperatorSid $fakeOperator -BeforeCreate {
        param($d)
        if ($d -eq $cB) { try { [IO.Directory]::Move((Join-Path $pB '.config'), (Join-Path $pB '.config-aside')) } catch { $script:moveErr = $_.Exception.Message } }
    }
    Assert-True ($null -ne $script:moveErr) '(2) renaming the held ~/.config while the install runs is REFUSED by the OS'
    Assert-Eq $sB (& $snap $vB) '(2) and the victim tree is untouched'
    Assert-True (Test-CoderOpencodeConfigInstalled -ConfigDir $cB -Plan $plan -CoderSid $meSid).Pass '(2) the install completed normally'

    # (3) the OS hold defeated (test hook): the swap succeeds, the re-resolve check must refuse BEFORE any create
    $pC = & $newProfile 'chainC'; $cC = Join-Path $pC '.config\opencode'; $vC = New-Item -ItemType Directory (Join-Path $tmpRoot 'chainC-victim') | Select-Object -ExpandProperty FullName
    $sC = & $snap $vC
    $script:CoderHoldAllowsDelete = $true
    try {
        Assert-Throws { Install-CoderOpencodeConfig -ConfigDir $cC -Plan $plan -CoderSid $meSid -OperatorSid $fakeOperator -BeforeCreate {
            param($d)
            if ($d -eq $cC) { [IO.Directory]::Move((Join-Path $pC '.config'), (Join-Path $pC '.config-aside')); New-Item -ItemType Junction -Path (Join-Path $pC '.config') -Target $vC | Out-Null }
        } } '*moved from*' '(3) ~/.config swapped for a junction right after it was verified (hold defeated): refused before the next create'
    } finally { $script:CoderHoldAllowsDelete = $false }
    Assert-Eq $sC (& $snap $vC) '(3) and the victim tree is completely untouched (nothing created in it)'
    (Get-Item (Join-Path $pC '.config')).Delete()

    # (4) a held leaf folder (plugin, tool or git: no held child, so the OS lets it be renamed once the hold is defeated)
    #     swapped for a junction right before the first file written into it: refused, no temp file lands in the victim.
    #     (A folder with a held child, such as ~/.config, cannot be renamed at all: the OS refuses, see (2).)
    $pD = & $newProfile 'chainD'; $cD = Join-Path $pD '.config\opencode'; $vD = & $newVictim 'chainD-victim'
    $sD = & $snap $vD
    $script:CoderHoldAllowsDelete = $true; $script:swappedDir = $null
    try {
        Assert-Throws { Install-CoderOpencodeConfig -ConfigDir $cD -Plan $plan -CoderSid $meSid -OperatorSid $fakeOperator -BeforeFileWrite {
            param($dest)
            $dir = Split-Path $dest -Parent
            if (-not $script:swappedDir -and (Split-Path $dir -Leaf) -in 'plugin', 'tool', 'git') {
                $script:swappedDir = $dir
                [IO.Directory]::Move($dir, "$dir-aside"); New-Item -ItemType Junction -Path $dir -Target $vD | Out-Null
            }
        } } '*moved from*' '(4) a held folder swapped for a junction right before a file is written into it (hold defeated): refused'
    } finally { $script:CoderHoldAllowsDelete = $false }
    Assert-True ($null -ne $script:swappedDir) '(4) the stand-in really swapped the folder'
    Assert-Eq $sD (& $snap $vD) '(4) and the victim tree is completely untouched (no temp file, no list change)'
    if ($script:swappedDir) { (Get-Item $script:swappedDir).Delete() }

    # (5) a folder NOT yet opened swapped for a junction: its own open refuses it
    $pE = & $newProfile 'chainE'; $cE = Join-Path $pE '.config\opencode'; $vE = & $newVictim 'chainE-victim'
    $sE = & $snap $vE
    Assert-Throws { Install-CoderOpencodeConfig -ConfigDir $cE -Plan $plan -CoderSid $meSid -OperatorSid $fakeOperator -BeforeCreate {
        param($d)
        if ($d -eq (Join-Path $pE '.config\git')) { New-Item -ItemType Junction -Path $d -Target $vE | Out-Null }
    } } '*link*' '(5) a not-yet-opened folder swapped for a junction after its parent was verified: refused by its own check'
    Assert-Eq $sE (& $snap $vE) '(5) and the victim tree is untouched'
    (Get-Item (Join-Path $pE '.config\git')).Delete()

    # (6) the resolve check on its own: a real folder BEHIND a junction ancestor does not resolve to where it was named
    Initialize-CoderHandleStamp
    $v6 = Join-Path $tmpRoot 'chain6-victim'; New-Item -ItemType Directory (Join-Path $v6 'sub') -Force | Out-Null
    $jn6 = Join-Path $tmpRoot 'chain6-jn'; New-Item -ItemType Junction -Path $jn6 -Target $v6 | Out-Null
    $ch6 = New-CoderHeldChain
    Assert-Throws { Add-CoderHeldDir -Chain $ch6 -Path (Join-Path $jn6 'sub') } '*resolves to*expected*' '(6) a real folder reached through a junction ancestor is refused (it resolves elsewhere than named)'
    Assert-Eq 0 $ch6.Count '(6) and nothing is left held'
    (Get-Item $jn6).Delete()
}
Test-Step 'dir-link-races' {
    # A folder the coder swapped for a junction after the plan was made: an operation that follows the path would act on the TARGET.
    $victim2 = Join-Path $tmpRoot 'victim2'; New-Item -ItemType Directory $victim2 | Out-Null
    $before = (Get-Acl -LiteralPath $victim2).Sddl
    $jn = Join-Path $tmpRoot 'jn-dir'; New-Item -ItemType Junction -Path $jn -Target $victim2 | Out-Null
    Assert-Throws { Protect-CoderConfigDir -Path $jn -CoderSid $meSid -OperatorSid $fakeOperator } "*is a link to*found before*" 'a folder that is a junction is refused BEFORE the list is applied'
    Assert-Eq $before (Get-Acl -LiteralPath $victim2).Sddl 'and the junction target keeps its access list'
    (Get-Item $jn).Delete()
    # swapped DURING the apply: a stand-in for Protect-CoderConfigObject swaps the folder for a junction, as the coder could
    $real = Join-Path $tmpRoot 'swapme'; New-Item -ItemType Directory $real | Out-Null
    $saved = ${function:Protect-CoderConfigObject}
    ${function:Protect-CoderConfigObject} = { param($Path, $CoderSid, $OperatorSid, [switch]$IsDir, [switch]$SetOwner, $CoderMask, $Handle)
        Remove-Item -LiteralPath $Path -Force; New-Item -ItemType Junction -Path $Path -Target $victim2 | Out-Null }
    try { Assert-Throws { Protect-CoderConfigDir -Path $real -CoderSid $meSid -OperatorSid $fakeOperator } "*is a link to*found after*" 'a folder swapped for a junction while the list is applied is caught AFTER' }
    finally { ${function:Protect-CoderConfigObject} = $saved }
    (Get-Item $real).Delete()
    # the installed-config verdict names a folder that is a link
    $p3 = Join-Path $tmpRoot 'profile3'; $c3 = Join-Path $p3 '.config\opencode'; New-Item -ItemType Directory $p3 | Out-Null
    $null = Install-CoderOpencodeConfig -ConfigDir $c3 -Plan $plan -CoderSid $meSid -OperatorSid $fakeOperator
    Assert-True (Test-CoderOpencodeConfigInstalled -ConfigDir $c3 -Plan $plan -CoderSid $meSid).Pass 'control: a clean install passes the verdict'
    $tool3 = Join-Path $c3 'tool'
    & icacls $c3 /grant "*${meSid}:(M)" | Out-Null   # let the stand-in coder swap a folder (the protection is what stops this in production)
    Remove-Item -LiteralPath $tool3 -Recurse -Force
    New-Item -ItemType Junction -Path $tool3 -Target $victim2 | Out-Null
    $v3 = Test-CoderOpencodeConfigInstalled -ConfigDir $c3 -Plan $plan -CoderSid $meSid
    Assert-True ((-not $v3.Pass) -and ($v3.Failed -contains 'link:tool')) 'a folder that is a junction fails the installed-config verdict (link:tool)'
    (Get-Item $tool3).Delete()
    # the undo must not delete THROUGH a folder the coder renamed away and replaced with a link
    $p4 = Join-Path $tmpRoot 'profile4'; $c4 = Join-Path $p4 '.config\opencode'; New-Item -ItemType Directory $p4 | Out-Null
    $null = Install-CoderOpencodeConfig -ConfigDir $c4 -Plan $plan -CoderSid $meSid -OperatorSid $fakeOperator
    $keep = Join-Path $tmpRoot 'operator-config'; New-Item -ItemType Directory (Join-Path $keep 'opencode') -Force | Out-Null
    Copy-Item (Join-Path $c4 'opencode.json') (Join-Path $keep 'opencode\opencode.json')
    & icacls $p4 /grant "*${meSid}:(M)" | Out-Null
    Rename-Item -LiteralPath (Join-Path $p4 '.config') -NewName '.config-away'
    New-Item -ItemType Junction -Path (Join-Path $p4 '.config') -Target $keep | Out-Null
    $gone4 = Remove-CoderOpencodeConfig -ConfigDir $c4 -Plan $plan
    Assert-Eq 0 @($gone4).Count 'the undo removes nothing when .config is a link'
    Assert-True (Test-Path (Join-Path $keep 'opencode\opencode.json')) 'and the file the link points at is still there'
    (Get-Item (Join-Path $p4 '.config')).Delete()
    Assert-True ($null -ne (Test-PathIsLink -Path (Join-Path $tmpRoot 'does-not-exist')) -and -not (Test-PathIsLink -Path (Join-Path $tmpRoot 'does-not-exist'))) 'an absent path is not a link'
    Assert-Throws { Test-PathIsLink -Path 'C:ad|name' } '*' 'a path whose attributes cannot be read THROWS instead of reading as not-a-link'
}
Test-Step 'undo' {
    New-Item -ItemType Directory (Join-Path $cfgDir 'node_modules\x') -Force | Out-Null
    & icacls (Join-Path $cfgDir 'plugin') /grant "*${meSid}:(OI)(CI)(M)" | Out-Null   # plant a foreign file past the protection
    Set-Content (Join-Path $cfgDir 'plugin\foreign.js') 'someone else'
    $gone = Remove-CoderOpencodeConfig -ConfigDir $cfgDir -Plan $plan
    Assert-Eq 7 $gone.Count 'the undo removes exactly the seven planned files'
    Assert-True ((Test-Path (Join-Path $cfgDir 'node_modules\x')) -and (Test-Path (Join-Path $cfgDir 'plugin\foreign.js'))) 'node_modules and a file the plan did not write are left alone'
    Assert-True ((Test-Path (Join-Path $cfgDir 'plugin')) -and -not (Test-Path (Join-Path $cfgDir 'tool'))) 'plugin\ stays (not empty), the empty tool\ folder is removed'
    Assert-True ((-not (Test-Path (Join-Path $prof '.config\git\config'))) -and (-not (Test-Path (Join-Path $prof '.config\git')))) 'the git config and its (now empty) folder are removed too'
}

Section 'F. the read grants on a temp tree (a SID in no token stands in for the coder)'
$g = Join-Path $tmpRoot 'grants'
New-Item -ItemType Directory $g | Out-Null
Test-Step 'grants-apply' {
    $pkgDir = Join-Path $g 'npm\node_modules\opencode-ai'; New-Item -ItemType Directory (Join-Path $pkgDir 'bin') -Force | Out-Null
    Set-Content (Join-Path $pkgDir 'bin\opencode.exe') 'x'
    $shim = Join-Path $g 'npm'; Set-Content (Join-Path $shim 'opencode.cmd') 'x'; Set-Content (Join-Path $shim 'secret-global.txt') 'x'
    $pkgGrant = [pscustomobject]@{ Id = 'opencode-package'; Path = $pkgDir; Flags = '(OI)(CI)'; Rights = 'RX'; Why = '' }
    $shimGrant = [pscustomobject]@{ Id = 'opencode-shim-dir'; Path = $shim; Flags = ''; Rights = 'RX'; Why = '' }
    Assert-Eq 'absent' (Get-CoderToolchainGrantState -Path $pkgDir -CoderSid $fakeCoder) 'before: no coder entry'
    Invoke-CoderToolchainGrant -Grant $pkgGrant -CoderSid $fakeCoder
    Invoke-CoderToolchainGrant -Grant $shimGrant -CoderSid $fakeCoder
    Assert-Eq 'read' (Get-CoderToolchainGrantState -Path $pkgDir -CoderSid $fakeCoder) 'after: the package folder carries a read-only coder entry'
    Assert-Eq 'read' (Get-CoderToolchainGrantState -Path (Join-Path $pkgDir 'bin\opencode.exe') -CoderSid $fakeCoder) 'the entry is INHERITED by a file below (the exe is runnable)'
    Assert-Eq 'read' (Get-CoderToolchainGrantState -Path $shim -CoderSid $fakeCoder) 'the shim folder carries the entry'
    Assert-Eq 'absent' (Get-CoderToolchainGrantState -Path (Join-Path $shim 'secret-global.txt') -CoderSid $fakeCoder) 'a file in the shim folder gets NO entry (this folder only: other global packages and files stay unreadable)'
    Assert-Eq 'absent' (Get-CoderToolchainGrantState -Path (Join-Path $shim 'node_modules') -CoderSid $fakeCoder) 'the shim folder''s node_modules (the other global packages) gets none'
    Assert-Eq 'read' (Get-CoderToolchainGrantState -Path (Join-Path $shim 'node_modules\opencode-ai') -CoderSid $fakeCoder) 'while the package folder below it keeps its own'
    Invoke-CoderToolchainGrant -Grant $pkgGrant -CoderSid $fakeCoder
    Assert-Eq 1 @(Get-ObjectAccessRules -Path $pkgDir | Where-Object { $_.Sid -eq $fakeCoder }).Count 'applying twice leaves ONE entry (idempotent)'
    # undo
    Invoke-CoderToolchainGrant -Grant $pkgGrant -CoderSid $fakeCoder -Undo
    Invoke-CoderToolchainGrant -Grant $shimGrant -CoderSid $fakeCoder -Undo
    Assert-True ((Get-CoderToolchainGrantState -Path $pkgDir -CoderSid $fakeCoder) -eq 'absent' -and (Get-CoderToolchainGrantState -Path (Join-Path $pkgDir 'bin\opencode.exe') -CoderSid $fakeCoder) -eq 'absent' -and (Get-CoderToolchainGrantState -Path $shim -CoderSid $fakeCoder) -eq 'absent') 'the undo removes the entry from the folder and from everything below it'
    # a write-capable result is a finding: a grant asking for Modify reads back as WRITE and throws
    $bad = [pscustomobject]@{ Id = 'bad'; Path = $pkgDir; Flags = '(OI)(CI)'; Rights = 'M'; Why = '' }
    Assert-Throws { Invoke-CoderToolchainGrant -Grant $bad -CoderSid $fakeCoder } "*read-back*WRITE*" 'TOGGLE: a grant that would give the coder Modify fails its read-back'
    Invoke-CoderToolchainGrant -Grant $pkgGrant -CoderSid $fakeCoder -Undo
}
Test-Step 'grant-gate' {
    $real = Join-Path $g 'real'; New-Item -ItemType Directory $real | Out-Null
    $target = Join-Path $g 'outside'; New-Item -ItemType Directory $target | Out-Null
    $link = Join-Path $g 'link'; New-Item -ItemType Junction -Path $link -Target $target | Out-Null
    Assert-True ((Test-CoderGrantTargetSafe -Path $real).Ok) 'control: a real folder passes the gate'
    Assert-True (-not (Test-CoderGrantTargetSafe -Path (Join-Path $g 'nope')).Ok) 'a missing folder is refused'
    $rl = Test-CoderGrantTargetSafe -Path $link; Assert-True ((-not $rl.Ok) -and $rl.Reason -like '*is a link*') 'a junction is refused'
    $under = Join-Path $link 'sub'; New-Item -ItemType Directory $under -Force | Out-Null
    $ru = Test-CoderGrantTargetSafe -Path $under; Assert-True ((-not $ru.Ok) -and $ru.Reason -like '*below the link*') 'a folder below a junction is refused'
    Assert-True (-not (Test-CoderGrantTargetSafe -Path 'C:\a\*').Ok) 'a wildcard path is refused'
    $inner = Join-Path $real 'tree'; New-Item -ItemType Directory $inner | Out-Null
    New-Item -ItemType Junction -Path (Join-Path $inner 'jump') -Target $target | Out-Null
    $grant = [pscustomobject]@{ Id = 't'; Path = $real; Flags = '(OI)(CI)'; Rights = 'RX'; Why = '' }
    Invoke-CoderToolchainGrant -Grant $grant -CoderSid $fakeCoder
    Assert-Eq 'absent' (Get-CoderToolchainGrantState -Path $target -CoderSid $fakeCoder) 'a junction INSIDE the granted tree is never followed: its target outside the tree got no entry'
    Invoke-CoderToolchainGrant -Grant $grant -CoderSid $fakeCoder -Undo
    Assert-Throws { Invoke-CoderToolchainGrant -Grant ([pscustomobject]@{ Id = 'l'; Path = $link; Flags = '(OI)(CI)'; Rights = 'RX'; Why = '' }) -CoderSid $fakeCoder } "*refused*is a link*" 'granting on a junction throws before icacls runs'
    Assert-Eq 'absent' (Get-CoderToolchainGrantState -Path $target -CoderSid $fakeCoder) 'and nothing was granted behind it'
}

Section 'G. the probe: each new check, with a positive control and a negative control'
$probe = Join-Path $PSScriptRoot 'coder-containment-probe.ps1'
function Invoke-Probe($Params, [switch]$DeElevate, [hashtable]$Env = @{}) {
    $pf = Join-Path $tmpRoot ('pp-' + [guid]::NewGuid().ToString('N').Substring(0, 6) + '.json'); $of = $pf -replace '\.json$', '.out.json'
    ($Params | ConvertTo-Json -Depth 6) | Set-Content -LiteralPath $pf -Encoding UTF8
    $saved = @{}; foreach ($k in $Env.Keys) { $saved[$k] = [Environment]::GetEnvironmentVariable($k); [Environment]::SetEnvironmentVariable($k, [string]$Env[$k]) }
    try { $h = Invoke-HiddenProcess -FilePath $pwsh -ArgumentList @('-NoProfile', '-NonInteractive', '-File', $probe, '-ParamsFile', $pf, '-OutJson', $of) -TimeoutSec 240 -DeElevate:$DeElevate }
    finally { foreach ($k in $Env.Keys) { [Environment]::SetEnvironmentVariable($k, $saved[$k]) } }
    if (-not (Test-Path -LiteralPath $of)) { throw "the probe wrote nothing (exit $($h.ExitCode)): $($h.Stderr)" }
    return (Get-Content -LiteralPath $of -Raw | ConvertFrom-Json -AsHashtable)
}
function Start-Stub([int]$Port, [int]$Status = 200) {
    $j = Start-Job -ArgumentList $Port, $Status -ScriptBlock { param($p, $st) $l = [Net.HttpListener]::new(); $l.Prefixes.Add("http://127.0.0.1:$p/"); $l.Start(); $dl = (Get-Date).AddSeconds(100); $t = $l.GetContextAsync()
        while ((Get-Date) -lt $dl) { if (-not $t.AsyncWaitHandle.WaitOne(1000)) { continue }; $c = $t.Result; $t = $l.GetContextAsync(); $b = [Text.Encoding]::UTF8.GetBytes('{}'); $c.Response.StatusCode = $st; $c.Response.OutputStream.Write($b, 0, $b.Length); $c.Response.OutputStream.Close() }; $l.Stop() }
    for ($i = 0; $i -lt 40; $i++) {
        $c = [Net.Sockets.TcpClient]::new(); try { $c.Connect('127.0.0.1', $Port); $c.Close(); break } catch { Start-Sleep -Milliseconds 250 } finally { $c.Dispose() }
    }
    return $j
}
$freePort = { $l = [Net.Sockets.TcpListener]::new([Net.IPAddress]::Loopback, 0); $l.Start(); $p = $l.LocalEndpoint.Port; $l.Stop(); $p }
Test-Step 'probe-proxy' {
    $port = & $freePort; $stub = Start-Stub $port
    try {
        $ok = Invoke-Probe @{ ProxyUrl = "http://127.0.0.1:$port/v3/models" }
        Assert-True ($ok.checks.proxy_loopback_ok.pass -eq $true) "proxy: a listener on the proxy address -> pass ($($ok.checks.proxy_loopback_ok.detail))"
    } finally { Stop-Job $stub -ErrorAction SilentlyContinue; Remove-Job $stub -Force -ErrorAction SilentlyContinue }
    $p4 = & $freePort; $st4 = Start-Stub $p4 404
    try { $r404 = Invoke-Probe @{ ProxyUrl = "http://127.0.0.1:$p4/v3/models" }; Assert-True ($r404.checks.proxy_loopback_ok.pass -eq $true) 'proxy: an HTTP 404 still proves the socket is open -> pass' } finally { Stop-Job $st4 -ErrorAction SilentlyContinue; Remove-Job $st4 -Force -ErrorAction SilentlyContinue }
    $p5 = & $freePort; $st5 = Start-Stub $p5 503
    try { $r503 = Invoke-Probe @{ ProxyUrl = "http://127.0.0.1:$p5/v3/models" }; Assert-True ($r503.checks.proxy_loopback_ok.pass -eq $false) 'proxy: an HTTP 503 (the proxy is up but broken) -> FAIL' } finally { Stop-Job $st5 -ErrorAction SilentlyContinue; Remove-Job $st5 -Force -ErrorAction SilentlyContinue }
    $dead = Invoke-Probe @{ ProxyUrl = "http://127.0.0.1:$(& $freePort)/v3/models" }
    Assert-True ($dead.checks.proxy_loopback_ok.pass -eq $false -and $dead.checks.proxy_loopback_ok.detail -like '*not reachable*') 'proxy: nothing listening -> FAIL (the check can fail)'
    $none = Invoke-Probe @{ SecretPaths = @() }
    Assert-True (-not $none.checks.ContainsKey('proxy_loopback_ok')) 'no proxy input -> no proxy check emitted (the verifier fails a result that lacks it)'
}
Test-Step 'probe-denied' {
    $deny = Join-Path $tmpRoot 'denied'; New-Item -ItemType Directory $deny | Out-Null; Set-Content (Join-Path $deny 'f') 'x'
    $open = Join-Path $tmpRoot 'open'; New-Item -ItemType Directory $open | Out-Null; Set-Content (Join-Path $open 'f') 'x'
    & icacls $deny /deny "*${meSid}:(OI)(CI)(R,WD,AD)" | Out-Null
    try {
        $r = Invoke-Probe @{ OperatorDenyPaths = @($deny); ExtraWriteDenyDirs = @($deny) } -DeElevate
        Assert-True ($r.checks.operator_profile_denied.pass -eq $true) 'operator paths: an ACL-denied folder -> pass'
        Assert-True ($r.checks.extra_write_denied.pass -eq $true) 'extra write: an ACL-denied folder -> pass'
        $r2 = Invoke-Probe @{ OperatorDenyPaths = @($deny, $open); ExtraWriteDenyDirs = @($deny, $open) } -DeElevate
        Assert-True ($r2.checks.operator_profile_denied.pass -eq $false -and $r2.checks.operator_profile_denied.per_path[$open] -like '*READABLE*') 'operator paths: ONE readable folder among the denied -> FAIL, and it is named'
        Assert-True ($r2.checks.extra_write_denied.pass -eq $false -and $r2.checks.extra_write_denied.per_path[$open].pass -eq $false) 'extra write: ONE writable folder among the denied -> FAIL, and it is named'
        $r3 = Invoke-Probe @{ OperatorDenyPaths = @((Join-Path $tmpRoot 'absent')); ExtraWriteDenyDirs = @((Join-Path $tmpRoot 'absent')) } -DeElevate
        Assert-True ($r3.checks.operator_profile_denied.pass -eq $false -and $r3.checks.extra_write_denied.pass -eq $false) 'absent paths prove nothing -> both FAIL (a mangled list must not pass)'
    } finally { & icacls $deny /remove:d "*$meSid" | Out-Null }
}
Test-Step 'probe-toolchain' {
    $git = (Get-Command git).Source
    $ok = Invoke-Probe @{ ToolchainExes = @($pwsh, $git) }
    Assert-True ($ok.checks.toolchain_runs.pass -eq $true) 'toolchain: pwsh and git start -> pass'
    $bad = Invoke-Probe @{ ToolchainExes = @($pwsh, (Join-Path $tmpRoot 'no-such.exe')) }
    Assert-True ($bad.checks.toolchain_runs.pass -eq $false -and $bad.checks.toolchain_runs.per_path[(Join-Path $tmpRoot 'no-such.exe')].detail -like '*not found*') 'toolchain: one missing executable -> FAIL, named'
    $wrongrc = Join-Path $tmpRoot 'failing.cmd'; Set-Content $wrongrc "@echo off`r`nexit /b 3"
    $rc = Invoke-Probe @{ ToolchainExes = @($wrongrc) }
    Assert-True ($rc.checks.toolchain_runs.pass -eq $false) 'toolchain: an executable that exits non-zero -> FAIL'
    $hang = Join-Path $tmpRoot 'hangs.cmd'; Set-Content $hang "@echo off`r`nping -n 30 127.0.0.1 >nul"
    $sw = [Diagnostics.Stopwatch]::StartNew()
    $hr = Invoke-Probe @{ ToolchainExes = @($hang); ToolchainTimeoutSec = 2 }
    Assert-True ($hr.checks.toolchain_runs.pass -eq $false -and $hr.checks.toolchain_runs.per_path[$hang].detail -like '*no answer within 2s*' -and $sw.Elapsed.TotalSeconds -lt 25) 'toolchain: an executable that never answers is killed after the wait and FAILS (the probe is not blocked)'
}
Test-Step 'probe-config' {
    if (-not $elevated) { Write-Host '  [note] not elevated: the stand-in is already a standard token; running the child directly' -ForegroundColor DarkYellow }
    $fakeHome = Join-Path $tmpRoot 'home'; New-Item -ItemType Directory $fakeHome | Out-Null
    $cfg2 = Join-Path $fakeHome '.config\opencode'
    $null = Install-CoderOpencodeConfig -ConfigDir $cfg2 -Plan $plan -CoderSid $meSid -OperatorSid $fakeOperator
    $envh = @{ USERPROFILE = $fakeHome; HOME = $fakeHome }
    $r = Invoke-Probe @{ CheckConfig = $true; ConfigDir = $cfg2 } -DeElevate -Env $envh
    Assert-True ($r.checks.coder_config_ok.pass -eq $true) "config: the installed config parses, no mcp block, permission block present ($($r.checks.coder_config_ok.detail))"
    Assert-True ($r.checks.coder_config_write_denied.pass -eq $true) "config: a standard-user token can NOT append to or delete the protected files ($(($r.checks.coder_config_write_denied.per_path | ConvertTo-Json -Compress)))"
    Assert-True ($r.checks.research_log_writable.pass -eq $true -and (Test-Path -LiteralPath (Join-Path $fakeHome '.local\share\blarai-coder'))) 'research log: the coder profile folder is created and writable (no grant anywhere)'
    # check 24: the coder can rename ~/.config away (it owns its profile root), so the probe DETECTS a replacement
    Assert-True ($r.checks.coder_config_root_intact.pass -eq $true) "root intact: every folder of an installed config is a real folder owned by Administrators ($(($r.checks.coder_config_root_intact.per_path.Values | ForEach-Object { $_.detail }) -join '; '))"
    if ($elevated) {
        $home7 = Join-Path $tmpRoot 'home7'; $cfg7 = Join-Path $home7 '.config\opencode'; New-Item -ItemType Directory $home7 | Out-Null
        $null = Install-CoderOpencodeConfig -ConfigDir $cfg7 -Plan $plan -CoderSid $meSid -OperatorSid $fakeOperator
        $env7 = @{ USERPROFILE = $home7; HOME = $home7 }
        & icacls (Split-Path $cfg7 -Parent) /setowner "*${meSid}" | Out-Null   # a replacement folder the coder created is owned by the coder
        $r7 = Invoke-Probe @{ CheckConfig = $true; ConfigDir = $cfg7 } -DeElevate -Env $env7
        Assert-True ($r7.checks.coder_config_root_intact.pass -eq $false -and $r7.checks.coder_config_root_intact.per_path[(Split-Path $cfg7 -Parent)].detail -like '*expected S-1-5-32-544*') 'TOGGLE: ~/.config owned by the account instead of Administrators (a rename-and-replace) -> the root-intact check FAILS'
        & icacls (Split-Path $cfg7 -Parent) /setowner '*S-1-5-32-544' | Out-Null
        $r7b = Invoke-Probe @{ CheckConfig = $true; ConfigDir = $cfg7 } -DeElevate -Env $env7
        Assert-True ($r7b.checks.coder_config_root_intact.pass -eq $true) '  ... and passes again once Administrators own it (the probe reads the owner, not the account name)'
    }
    $home8 = Join-Path $tmpRoot 'home8'; $real8 = Join-Path $tmpRoot 'real8'; New-Item -ItemType Directory $home8, $real8 | Out-Null
    $null = Install-CoderOpencodeConfig -ConfigDir (Join-Path $real8 '.config\opencode') -Plan $plan -CoderSid $meSid -OperatorSid $fakeOperator
    New-Item -ItemType Junction -Path (Join-Path $home8 '.config') -Target (Join-Path $real8 '.config') | Out-Null
    $r8 = Invoke-Probe @{ CheckConfig = $true; ConfigDir = (Join-Path $home8 '.config\opencode') } -DeElevate -Env @{ USERPROFILE = $home8; HOME = $home8 }
    Assert-True ($r8.checks.coder_config_root_intact.pass -eq $false -and $r8.checks.coder_config_root_intact.per_path[(Join-Path $home8 '.config')].detail -like '*is a link*') 'TOGGLE: ~/.config swapped for a junction -> the root-intact check FAILS (a correct-looking install behind the link does not rescue it)'
    (Get-Item (Join-Path $home8 '.config')).Delete()
    # negatives: protection off; mcp block present; config missing
    $cfg3 = Join-Path $tmpRoot 'home3\.config\opencode'; New-Item -ItemType Directory (Join-Path $cfg3 'plugin') -Force | Out-Null; New-Item -ItemType Directory (Join-Path $cfg3 'tool') -Force | Out-Null
    foreach ($f in $plan) { if ($f.Dir -eq 'config') { [IO.File]::WriteAllBytes((Join-Path $cfg3 $f.Rel), $f.Bytes) } }
    New-Item -ItemType Directory (Join-Path (Split-Path $cfg3 -Parent) 'git') -Force | Out-Null
    [IO.File]::WriteAllBytes((Join-Path (Split-Path $cfg3 -Parent) 'git\config'), @($plan | Where-Object { $_.Rel -eq 'git\config' })[0].Bytes)
    $r3 = Invoke-Probe @{ CheckConfig = $true; ConfigDir = $cfg3 } -DeElevate -Env @{ USERPROFILE = (Join-Path $tmpRoot 'home3'); HOME = (Join-Path $tmpRoot 'home3') }
    Assert-True ($r3.checks.coder_config_write_denied.pass -eq $false) 'TOGGLE: config files with the ordinary inherited list (writable by the account) -> the write-denied check FAILS'
    [IO.File]::WriteAllText((Join-Path $cfg3 'opencode.json'), $opText)
    $r4 = Invoke-Probe @{ CheckConfig = $true; ConfigDir = $cfg3 } -DeElevate -Env @{ USERPROFILE = (Join-Path $tmpRoot 'home3'); HOME = (Join-Path $tmpRoot 'home3') }
    Assert-True ($r4.checks.coder_config_ok.pass -eq $false -and $r4.checks.coder_config_ok.detail -like '*mcp-block=True*') 'config: a config that still has the MCP block -> FAIL'
    $rh = Invoke-Probe @{ CheckConfig = $true; ConfigDir = $cfg2 } -DeElevate -Env @{ USERPROFILE = (Join-Path $tmpRoot 'some-other-home'); HOME = $fakeHome }
    Assert-True ($rh.checks.coder_config_ok.pass -eq $false -and $rh.checks.coder_config_ok.detail -like '*USERPROFILE-is-the-config-profile=False*') 'config: if the account RUNS in a different profile than the one that was checked, the check FAILS (opencode would read another folder)'
    Assert-True ($r.checks.coder_config_write_denied.per_path['create-in-config-folder'].pass -eq $true -and $r.checks.coder_config_write_denied.per_path['rename-config-folder'].pass -eq $true -and $r.checks.coder_config_write_denied.per_path['node_modules-writable'].pass -eq $true) 'config folder: nothing can be CREATED in it, it cannot be RENAMED away, node_modules stays writable'
    # protected files in an UNPROTECTED folder: append is denied but the folder lets the account delete them -> must FAIL
    $cfg6 = Join-Path $tmpRoot 'home6\.config\opencode'; New-Item -ItemType Directory (Join-Path $cfg6 'plugin') -Force | Out-Null; New-Item -ItemType Directory (Join-Path $cfg6 'tool') -Force | Out-Null; New-Item -ItemType Directory (Join-Path $cfg6 'node_modules') -Force | Out-Null
    New-Item -ItemType Directory (Join-Path (Split-Path $cfg6 -Parent) 'git') -Force | Out-Null
    foreach ($f in $plan) { $dst = Join-Path (Get-CoderConfigItemBase -ConfigDir $cfg6 -Item $f) $f.Rel; [IO.File]::WriteAllBytes($dst, $f.Bytes); Protect-CoderConfigObject -Path $dst -CoderSid $meSid -OperatorSid $fakeOperator }
    $r6 = Invoke-Probe @{ CheckConfig = $true; ConfigDir = $cfg6 } -DeElevate -Env @{ USERPROFILE = (Join-Path $tmpRoot 'home6'); HOME = (Join-Path $tmpRoot 'home6') }
    Assert-True ($r6.checks.coder_config_write_denied.pass -eq $false -and $r6.checks.coder_config_write_denied.per_path['opencode.json'].pass -eq $false -and $r6.checks.coder_config_write_denied.per_path['opencode.json'].detail -like '*delete*SUCCEEDED*') 'TOGGLE: file entries alone are not enough - a folder that lets the account DELETE a protected file fails the check (the folder protection is what stops replacement)'
    Assert-True ($r6.checks.coder_config_write_denied.per_path['create-in-config-folder'].pass -eq $false) '  ... and so does a config folder where the account can create a second config file'
    $r5 = Invoke-Probe @{ CheckConfig = $true; ConfigDir = (Join-Path $tmpRoot 'nowhere\.config\opencode') } -DeElevate -Env @{ USERPROFILE = (Join-Path $tmpRoot 'nowhere'); HOME = (Join-Path $tmpRoot 'nowhere') }
    Assert-True ($r5.checks.coder_config_ok.pass -eq $false -and $r5.checks.coder_config_write_denied.pass -eq $false) 'config: no config at all -> both FAIL (absent proves nothing)'
    Assert-True ($r5.checks.coder_config_root_intact.pass -eq $false) 'root intact: no config folders at all -> FAIL (absent proves nothing)'
}
Test-Step 'setup-verdict' {
    $mkc = { $h = @{}; foreach ($k in 'proxy_loopback_ok', 'operator_profile_denied', 'git_status_ok', 'toolchain_runs', 'coder_config_ok', 'coder_config_write_denied', 'research_log_writable', 'extra_write_denied', 'coder_config_root_intact') { $h[$k] = @{ pass = $true; detail = 'ok' } }; $h }
    $v = Get-SetupChecksFromProbe -Checks (& $mkc)
    Assert-True ($v.Verdict.Pass -and $v.Rows.Count -eq 9) 'all nine setup checks pass -> verdict passes (9 rows: checks 15-21, 23 and 24)'
    foreach ($k in 'proxy_loopback_ok', 'operator_profile_denied', 'git_status_ok', 'toolchain_runs', 'coder_config_ok', 'coder_config_write_denied', 'research_log_writable', 'extra_write_denied', 'coder_config_root_intact') {
        $c = & $mkc; $c[$k].pass = $false
        $vf = Get-SetupChecksFromProbe -Checks $c
        $c2 = & $mkc; $c2.Remove($k)
        $vm = Get-SetupChecksFromProbe -Checks $c2
        Assert-True ((-not $vf.Verdict.Pass) -and (-not $vm.Verdict.Pass) -and $vf.Verdict.Failed.Count -eq 1 -and $vm.Verdict.Failed.Count -eq 1) "$k : a failing result and an ABSENT result both fail the verdict (exactly that one check)"
    }
    $asObj = Get-SetupChecksFromProbe -Checks ((& $mkc | ConvertTo-Json -Depth 4) | ConvertFrom-Json)
    Assert-True $asObj.Verdict.Pass 'the verdict reads a PSCustomObject (the shape Windows PowerShell 5.1 returns) as well'
}

Section 'H. git trust for a worktree another account owns (dubious ownership), measured with a worktree owned by SYSTEM'
Test-Step 'git-ownership' {
    $gitexe = (Get-Command git).Source
    $gt = Join-Path $tmpRoot 'wts'; New-Item -ItemType Directory $gt | Out-Null
    $repo = Join-Path $gt 'r1'
    & $gitexe init -q $repo; Set-Content (Join-Path $repo 'f') 'a'
    & $gitexe -C $repo add f; & $gitexe -C $repo -c user.name=t -c user.email=t@t commit -qm i
    $probeGit = { param($a, $envx = @{}) $saved = @{}; foreach ($k in $envx.Keys) { $saved[$k] = [Environment]::GetEnvironmentVariable($k); [Environment]::SetEnvironmentVariable($k, [string]$envx[$k]) }
        try { $o = & $gitexe @a 2>&1 | Out-String; return @{ Rc = $LASTEXITCODE; Out = $o.Trim() } } finally { foreach ($k in $envx.Keys) { [Environment]::SetEnvironmentVariable($k, $saved[$k]) } } }
    if (-not $elevated) { Write-Host '  [SKIP] not elevated: cannot set another account as the owner of a folder; the ownership cases below are not run' -ForegroundColor Yellow; return }
    $o = & icacls $repo /setowner '*S-1-5-18' /T /C 2>&1
    Assert-True ($LASTEXITCODE -eq 0) 'setup: the worktree (and its .git) is now owned by SYSTEM'
    $plain = & $probeGit @('-C', $repo, 'status', '--porcelain') @{ GIT_CONFIG_NOSYSTEM = '1'; HOME = $tmpRoot; USERPROFILE = $tmpRoot }
    Assert-True ($plain.Rc -ne 0 -and $plain.Out -match 'dubious ownership') 'CONTROL: git refuses the folder another account owns ("dubious ownership"), so the cases below could have failed'
    $f = $repo.Replace('\', '/')
    $scoped = & $probeGit @('-C', $repo, '-c', "safe.directory=$f", 'status', '--porcelain') @{ GIT_CONFIG_NOSYSTEM = '1' }
    Assert-True ($scoped.Rc -eq 0) 'the scoped safe.directory (that one worktree) makes git work'
    $other = & $probeGit @('-C', $repo, '-c', 'safe.directory=C:/some/other/place', 'status', '--porcelain') @{ GIT_CONFIG_NOSYSTEM = '1'; HOME = $tmpRoot; USERPROFILE = $tmpRoot }
    Assert-True ($other.Rc -ne 0) 'a safe.directory naming a DIFFERENT folder does not help (it is per-folder)'
    # the runner environment, exactly as Get-CoderLegGitEnv builds it
    $ge = Get-CoderLegGitEnv -WorkDir $repo; $genv = @{}; foreach ($k in $ge.Keys) { $genv[$k] = $ge[$k] }; $genv['GIT_CONFIG_NOSYSTEM'] = '1'; $genv['HOME'] = $tmpRoot; $genv['USERPROFILE'] = $tmpRoot
    $viaEnv = & $probeGit @('-C', $repo, 'status', '--porcelain') $genv
    Assert-True ($viaEnv.Rc -eq 0) 'the coder-leg runner environment (Get-CoderLegGitEnv) makes git work in that worktree'
    # the coder's own git config (what opencode's shell relies on): the prefix entry for the worktree base
    $fh = Join-Path $tmpRoot 'coderhome'; New-Item -ItemType Directory $fh | Out-Null
    $gcText = (Get-CoderGitConfigText -WorktreeBase $gt)
    New-Item -ItemType Directory (Join-Path $fh '.config\git') -Force | Out-Null; [IO.File]::WriteAllText((Join-Path $fh '.config\git\config'), $gcText)
    $viaCfg = & $probeGit @('-C', $repo, 'status', '--porcelain') @{ GIT_CONFIG_NOSYSTEM = '1'; HOME = $fh; USERPROFILE = $fh }
    Assert-True ($viaCfg.Rc -eq 0) 'the generated coder git config (safe.directory = <base>/*) makes git work in a worktree under the base, with NO git variables set'
    $outside = Join-Path $tmpRoot 'elsewhere\r2'; New-Item -ItemType Directory (Split-Path $outside -Parent) | Out-Null
    & $gitexe init -q $outside; $null = & icacls $outside /setowner '*S-1-5-18' /T /C 2>&1
    $viaCfgOut = & $probeGit @('-C', $outside, 'status', '--porcelain') @{ GIT_CONFIG_NOSYSTEM = '1'; HOME = $fh; USERPROFILE = $fh }
    Assert-True ($viaCfgOut.Rc -ne 0 -and $viaCfgOut.Out -match 'dubious ownership') 'a foreign-owned repo OUTSIDE the worktree base is still refused (the prefix is not a wildcard)'
    # operator side: the hardened form every operator-side call on a coder-run worktree takes
    $src = [IO.File]::ReadAllText((Join-Path $PSScriptRoot 'fleet-lib.ps1'))
    $m = [regex]::Match($src, '(?s)function Get-HardenedGitArgs \{.*?\n\}\r?\n')
    Assert-True $m.Success 'setup: Get-HardenedGitArgs found in fleet-lib.ps1'
    $fnFile = Join-Path $tmpRoot 'hardened-args.ps1'; [IO.File]::WriteAllText($fnFile, $m.Value); . $fnFile
    $hard = Get-HardenedGitArgs -GitDir (Join-Path $repo '.git') -WorkTree $repo
    $viaHard = & $probeGit (@($hard) + @('status', '--porcelain')) @{ GIT_CONFIG_NOSYSTEM = '1'; HOME = $tmpRoot; USERPROFILE = $tmpRoot }
    Assert-True ($viaHard.Rc -eq 0) 'OPERATOR SIDE: the hardened explicit --git-dir/--work-tree form works on the foreign-owned worktree with no safe.directory at all (git does not ownership-check an explicit git dir), so reading, cleaning and merging a coder-run worktree needs no trust setting'
    $viaC = & $probeGit @('-C', $repo, 'status', '--porcelain') @{ GIT_CONFIG_NOSYSTEM = '1'; HOME = $tmpRoot; USERPROFILE = $tmpRoot }
    Assert-True ($viaC.Rc -ne 0) 'LOCK: the plain -C form of an operator-side call WOULD be refused here, so the explicit form in Get-WtGit is load-bearing (a refactor to -C breaks the operator-side read of coder-run worktrees)'
    Assert-True (($hard -join ' ') -notmatch 'safe\.directory') 'and no global or wildcard safe.directory is added anywhere on the operator side'
    Assert-True ((Get-Content (Join-Path $PSScriptRoot 'fleet-lib.ps1') -Raw) -notmatch "safe\.directory['`"= ]+\*|safe\.directory=\*") 'no operator-side script sets safe.directory to *'
    $probeSrc = Get-Content $probe -Raw
    Assert-True ($probeSrc -notmatch "safe\.directory=\*'") 'the probe no longer uses a wildcard safe.directory either'
    # the probe's own git check, end to end, on this worktree: the coder .gitconfig path and the environment path
    $r = Invoke-Probe @{ WorktreePaths = @($repo) } -Env @{ GIT_CONFIG_NOSYSTEM = '1'; HOME = $fh; USERPROFILE = $fh }
    Assert-True ($r.checks.git_status_ok.pass -eq $true) "probe git_status_ok: passes in the foreign-owned worktree with the coder git config ($($r.checks.git_status_ok.per_path[$repo].detail))"
    $r2 = Invoke-Probe @{ WorktreePaths = @($repo) } -Env @{ GIT_CONFIG_NOSYSTEM = '1'; HOME = $tmpRoot; USERPROFILE = $tmpRoot }
    Assert-True ($r2.checks.git_status_ok.pass -eq $false -and $r2.checks.git_status_ok.per_path[$repo].detail -like '*coder git config only*') 'TOGGLE: with NO coder git config the probe check FAILS (the opencode-shell path is covered by the file, not by the runner environment)'
    $r3 = Invoke-Probe @{ WorktreePaths = @((Join-Path $tmpRoot 'notarepo')) }
    Assert-True ($r3.checks.git_status_ok.pass -eq $false) 'probe git_status_ok: a folder that is not a repository -> FAIL'
    $pe = Get-CoderProbeGitEnv -WorkDir $repo
    Assert-Eq (($ge.GetEnumerator() | ForEach-Object { "$($_.Key)=$($_.Value)" }) -join ';') (($pe.GetEnumerator() | ForEach-Object { "$($_.Key)=$($_.Value)" }) -join ';') 'the probe''s git variables equal Get-CoderLegGitEnv exactly (no drift between the two copies)'
}

Section 'I. wiring: the schema, the runner, the provisioning and verify scripts, and the off path'
Test-Step 'wiring' {
    $okJob = @{ id = 'job-20261008-120000-abcdef01'; kind = 'probe'; created = '2026-10-08T12:00:00Z'; probe = @{
        proxy_url = 'http://127.0.0.1:8099/v3/models'; operator_deny_paths = @('C:\Users\mrbla\.ssh'); toolchain_exes = @('C:\Program Files\Git\cmd\git.exe')
        config_dir = 'C:\Users\blarai-coder\.config\opencode'; extra_write_deny_dirs = @('C:\blarai-fleet'); check_config = $true } }
    $bytes = [Text.Encoding]::UTF8.GetBytes(($okJob | ConvertTo-Json -Depth 6))
    $parsed = ConvertFrom-StrictJsonBytes -Bytes $bytes -Schema $script:CoderLegJobSchema -What 'job'
    Assert-True ($parsed.probe.check_config -eq $true -and $parsed.probe.toolchain_exes.Count -eq 1) 'the strict job schema ACCEPTS the new probe fields'
    foreach ($case in @(
        @{ K = 'proxy_url'; V = 'http://evil.example.com/v3/models'; L = 'a non-loopback proxy_url' },
        @{ K = 'proxy_url'; V = 'http://127.0.0.1:8099/v3/models?x=1'; L = 'a proxy_url with a query' },
        @{ K = 'operator_deny_paths'; V = @('C:\a\*'); L = 'a wildcard in operator_deny_paths' },
        @{ K = 'toolchain_exes'; V = @('relative\git.exe'); L = 'a relative toolchain_exes entry' },
        @{ K = 'extra_write_deny_dirs'; V = @('C:\a|b'); L = 'a pipe in extra_write_deny_dirs' },
        @{ K = 'config_dir'; V = 'C:\a"b'; L = 'a quote in config_dir' },
        @{ K = 'check_config'; V = 'yes'; L = 'a non-boolean check_config' },
        @{ K = 'unknown_field'; V = 'x'; L = 'an unknown probe field' })) {
        $j = ($okJob | ConvertTo-Json -Depth 6 | ConvertFrom-Json -AsHashtable); $j.probe[$case.K] = $case.V
        $b = [Text.Encoding]::UTF8.GetBytes(($j | ConvertTo-Json -Depth 6)); $refused = $false
        try { $null = ConvertFrom-StrictJsonBytes -Bytes $b -Schema $script:CoderLegJobSchema -What 'job' } catch { $refused = $true }
        Assert-True $refused "the strict job schema REFUSES $($case.L)"
    }
    $run = Get-Content (Join-Path $PSScriptRoot 'coder-leg-run.ps1') -Raw
    foreach ($pair in 'proxy_url|ProxyUrl', 'config_dir|ConfigDir', 'operator_deny_paths|OperatorDenyPaths', 'toolchain_exes|ToolchainExes', 'extra_write_deny_dirs|ExtraWriteDenyDirs') {
        $a, $b2 = $pair -split '\|'; Assert-True ($run -match "'$a', '$b2'") "the runner maps probe job field $a to -$b2"
    }
    Assert-True ($run -match [regex]::Escape('check_config -eq $true') -and $run -match 'Read-CoderToolchainManifest' -and $run -match 'Get-CoderToolchainPathPrefix') 'the runner maps check_config and puts the manifest PATH prefix on the dispatch environment'
    $pathAt = $run.IndexOf('Get-CoderToolchainPathPrefix'); $startAt = $run.IndexOf('$cj = New-CoderJob'); $acpAt = $run.IndexOf('Invoke-AcpCoderRun')
    Assert-True ($pathAt -gt 0 -and $pathAt -lt $startAt -and $startAt -lt $acpAt) 'the PATH is set BEFORE the job object is created and the coder is started (a bad manifest refuses the run first)'
    $prov = Get-Content (Join-Path $PSScriptRoot 'provision-coder-account.ps1') -Raw
    Assert-True ($prov.Contains("& (Join-Path `$PSScriptRoot 'provision-coder-setup.ps1') -Apply") -and $prov.Contains("& (Join-Path `$PSScriptRoot 'provision-coder-setup.ps1') -Rollback")) 'provision-coder-account.ps1 CALLS the setup stage to apply and to roll back'
    Assert-True ($prov -match 'SetupPending') 'a pending config step (no coder profile yet) ends the provisioning with exit 3, not a silent success'
    $vc = Get-Content (Join-Path $PSScriptRoot 'verify-coder-containment.ps1') -Raw
    foreach ($n in 'check22-config-installed-intact', 'Get-SetupChecksFromProbe', 'proxy_url', 'operator_deny_paths', 'extra_write_deny_dirs', 'Test-CoderOpencodeConfigInstalled') { Assert-True ($vc.Contains($n)) "verify-coder-containment.ps1 carries $n" }
    Assert-True ($vc -match '-and \$setupFailed\.Count -eq 0\) \{') 'the setup checks decide the overall result (exit 0 only when none failed)'
    Assert-True ($vc.Contains('$(if (-not $installed.Pass) { @(''check22-config-installed-intact'') } else { @() })')) 'check 22 (the installed config) feeds that same decision'
    Assert-True ($vc -match 'Start-LoopbackStub -Port \$proxyPort') 'stub mode also stands up the proxy address, so check 15 can pass without the real proxy'
    # the new checks reach the verifier's default secret list: the operator opencode config dir is probed
    Assert-True ($vc -match [regex]::Escape("Join-Path `$env:USERPROFILE '.config\opencode'")) 'the operator opencode config folder is among the operator paths the coder must not read'
    # nothing on the containment=off path can read the new files
    foreach ($off in 'fleet-lib.ps1', 'new-agent-task.ps1', 'run-fleet.ps1', 'coder-leg-queue.ps1', 'coder-acl-lib.ps1', 'critic-run.ps1', 'run-battery-night.ps1') {
        $p = Join-Path $PSScriptRoot $off
        if (Test-Path $p) { Assert-True ((Get-Content $p -Raw) -notmatch 'coder-setup-lib|coder-toolchain|provision-coder-setup') "$off never names the setup library, the manifest or the stage (containment=off cannot read them)" }
    }
    $others = @(Get-ChildItem $PSScriptRoot -Filter *.ps1 | Where-Object { $_.Name -notmatch '^verify-|^(coder-setup-lib|provision-coder-setup|provision-coder-account|coder-leg-run|coder-containment-probe)\.ps1$' -and (Get-Content $_.FullName -Raw) -match 'coder-setup-lib|coder-toolchain' } | ForEach-Object { $_.Name })
    Assert-Eq '' ($others -join ',') 'only the stage, the provisioner, the runner and the probe path read the setup library or the manifest'
}
Test-Step 'no-visible-launch' {
    # no child process of the new code may show a window: the same lint the ACL suite runs
    foreach ($f in 'coder-setup-lib.ps1', 'provision-coder-setup.ps1', 'coder-containment-probe.ps1', 'verify-coder-setup.ps1') {
        $hit = @(Find-VisibleLaunches -Text (Get-Content (Join-Path $PSScriptRoot $f) -Raw))
        Assert-True ($hit.Count -eq 0) "no visible launch in $f$(if ($hit.Count) { ': ' + ($hit -join ' | ') })"
    }
    Assert-True (@(Find-VisibleLaunches -Text '$x = & $exe --version').Count -ge 1) 'control: the lint flags a call operator on a variable named like a host'
}
Test-Step 'research-log' {
    $setupSrc = Get-Content (Join-Path $PSScriptRoot 'coder-setup-lib.ps1') -Raw
    Assert-True ($setupSrc -notmatch "state\\research|agentic-setup\\state") 'the setup library never names the operator state folder'
    $aclSrc = Get-Content (Join-Path $PSScriptRoot 'coder-acl-lib.ps1') -Raw
    Assert-True ($aclSrc -notmatch 'research-usage|research-arming|agentic-setup\state') 'the ACL stage names no research log and no operator state folder, so it grants the coder nothing there'
    $grants = @(Get-CoderToolchainReadGrants -Manifest $shipped -AgenticRoot $agentic -BlarRoot $blar)
    Assert-True (@($grants | Where-Object { $_.Path -match '\\state(\\|$)' }).Count -eq 0 -and @($grants | Where-Object { $_.Rights -ne 'RX' }).Count -eq 0) 'no grant (write or read) names a state folder: the usage log needs none'
    $searchPy = Join-Path 'C:\Users\mrbla\blarai' 'tools\search_docs.py'
    if (Test-Path $searchPy) {
        $py = Get-Content $searchPy -Raw
        Assert-True ($py -match 'BLARAI_RESEARCH_USAGE_LOG' -and $py -match '_log_usage' -and $py -match 'usage logging must never affect a lookup') 'the lookup tool honours BLARAI_RESEARCH_USAGE_LOG and a failed log write never changes a lookup result (read from the tool source)'
    } else { Write-Host '  [note] the BlarAI tool source was not found; the env override check is skipped' -ForegroundColor DarkYellow }
}

} finally {
    foreach ($d in @('denied')) { $p = Join-Path $tmpRoot $d; if (Test-Path $p) { & icacls $p /remove:d "*$meSid" 2>$null | Out-Null } }
    Get-ChildItem -LiteralPath $tmpRoot -Recurse -Force -Attributes ReparsePoint -ErrorAction SilentlyContinue | ForEach-Object { try { $_.Delete() } catch { } }
    if (Test-Path $tmpRoot) { Remove-Item -LiteralPath $tmpRoot -Recurse -Force -ErrorAction SilentlyContinue }
}
$newWin = @(Get-NewVisibleConsoleWindows -BaselineIds $winBefore)
if ($newWin.Count -gt 0) { _fail "a visible console window was left behind: $($newWin -join ', ')" } else { _pass 'no visible console window was left by any child process' }
Write-Host ''
if ($script:Fail -eq 0) { Write-Host "RESULT: $($script:Pass) passed, 0 failed" -ForegroundColor Green; exit 0 }
Write-Host "RESULT: $($script:Pass) passed, $($script:Fail) failed" -ForegroundColor Red
$script:Failures | ForEach-Object { Write-Host "  - $_" -ForegroundColor Red }
exit 1
