#requires -Version 7.0
<#
.SYNOPSIS
  Verifies the boot-surface sweep (#1695, coder-boot-surface-lib.ps1) and its wiring into
  verify-coder-containment.ps1 as check 25, OFFLINE: every system read is replaced by a fake, and the real
  access-list reading is exercised on a TEMP tree. Nothing on the machine is changed.

.DESCRIPTION
  WHAT IS REAL: Get-Acl / icacls on a temp tree (positive and negative controls, the inherit-only case, the
  toggle), the library code, the verify script's text.
  WHAT IS A FAKE: the service list, the task list, the account-name resolver, the Administrators membership and
  (for the logic cases) the access lists, so each rule is driven by exactly one input.
  A read-only smoke runs the sweep against the real machine and asserts only that it completes and enumerated
  something; what it finds there is printed, never asserted.

  -Mutations re-runs THIS suite against mutated copies of the sources (each control disabled in turn). KILLED =
  non-zero exit AND a [FAIL] line; SURVIVED = exit 0; ERROR = non-zero with no [FAIL] line. The unmutated
  control must pass first. -ProveHarness shows the classification on a known survivor, crasher and kill.
  Exit 0 if everything passed.
#>
param([switch]$Mutations, [switch]$ProveHarness, [string[]]$Only = @(), [int]$Throttle = 3)
$ErrorActionPreference = 'Stop'

if ($Mutations -or $ProveHarness) {
    try { (Get-Process -Id $PID).PriorityClass = 'BelowNormal' } catch { }
    . "$PSScriptRoot\hidden-process-lib.ps1"
    $pw = (Get-Command pwsh -ErrorAction SilentlyContinue).Source
    $files = 'coder-boot-surface-lib.ps1', 'verify-coder-boot-surface.ps1', 'verify-coder-containment.ps1', 'fleet-lib.ps1', 'coder-leg-queue.ps1', 'coder-leg-run.ps1', 'new-agent-task.ps1', 'run-fleet.ps1', 'critic-run.ps1', 'hidden-process-lib.ps1'
    $run = {
        param($Dir, $Mut, $files, $pw, $SrcDir)
        . (Join-Path $SrcDir 'hidden-process-lib.ps1')
        $sd = Join-Path $Dir 'scripts'; New-Item -ItemType Directory -Force $sd | Out-Null
        foreach ($f in $files) { if (Test-Path (Join-Path $SrcDir $f)) { Copy-Item (Join-Path $SrcDir $f) (Join-Path $sd $f) } }
        if ($Mut) {
            $target = Join-Path $sd $Mut.F
            $text = ([IO.File]::ReadAllText($target)).Replace("`r`n", "`n")   # match on LF: a CRLF working copy is the same text
            $mo = ([string]$Mut.O).Replace("`r`n", "`n"); $mw = ([string]$Mut.W).Replace("`r`n", "`n")
            if (-not $text.Contains($mo)) { return @{ Class = 'ERROR'; Why = "mutation target not found in $($Mut.F)" } }
            [IO.File]::WriteAllText($target, $text.Replace($mo, $mw), (New-Object Text.UTF8Encoding($true)))
        }
        $h = Invoke-HiddenProcess -FilePath $pw -ArgumentList @('-NoProfile', '-NonInteractive', '-File', (Join-Path $sd 'verify-coder-boot-surface.ps1')) -TimeoutSec 900
        $out = $h.Stdout + "`n" + $h.Stderr
        $fails = @($out -split "`n" | Where-Object { $_ -match '\[FAIL\]' })
        if ($h.ExitCode -eq 0) { return @{ Class = 'SURVIVED'; Why = 'the suite did not notice' } }
        if ($fails.Count -gt 0) { return @{ Class = 'KILLED'; Why = ("$($fails[0])").Trim() } }
        return @{ Class = 'ERROR'; Why = 'non-zero exit with no [FAIL] line: ' + (($out -split "`n" | Where-Object { $_.Trim() } | Select-Object -Last 3) -join ' | ') }
    }
    function Invoke-MutationRun([object[]]$Muts) {
        $tmp = Join-Path ([IO.Path]::GetTempPath()) ('bootsurf-mut-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
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
    $L = 'coder-boot-surface-lib.ps1'; $V = 'verify-coder-containment.ps1'
    if ($ProveHarness) {
        $probe = @(
            @{ N = 'equivalent-comment-change'; F = $L; O = '# ---- the pure parts ----'; W = '# ---- the pure parts (renamed) ----' },
            @{ N = 'crashing-syntax-break';     F = $L; O = 'function Test-BootMaskWritable {'; W = 'function Test-BootMaskWritable { }}}}' },
            @{ N = 'real-kill-inherit-only';    F = $L; O = 'if ($Ace.InheritOnly) { return $false }'; W = '' }
        )
        $r = Invoke-MutationRun $probe
        $want = @{ 'equivalent-comment-change' = 'SURVIVED'; 'crashing-syntax-break' = 'ERROR'; 'real-kill-inherit-only' = 'KILLED' }
        $bad = @($r.Results | Where-Object { $want[$_.N] -ne $_.Class })
        if ($r.Control -and $bad.Count -eq 0 -and $r.Results.Count -eq 3) { Write-Host 'HARNESS PROVEN: survivor reported SURVIVED, crasher reported ERROR, real kill reported KILLED' -ForegroundColor Green; exit 0 }
        Write-Host 'HARNESS NOT PROVEN' -ForegroundColor Red; exit 1
    }
    $muts = @(
        @{ N = 'inherit-only-not-skipped';     F = $L; O = 'if ($Ace.InheritOnly) { return $false }'; W = '' },
        @{ N = 'deny-counted-as-allow';        F = $L; O = 'if ([string]$Ace.Type -ne ''Allow'') { return $false }'; W = '' },
        @{ N = 'writer-authenticated-users-dropped'; F = $L; O = '''S-1-1-0'', ''S-1-5-11'', ''S-1-5-32-545'',' ; W = '''S-1-1-0'', ''S-1-5-32-545'',' },
        @{ N = 'writer-everyone-dropped';      F = $L; O = '@(''S-1-1-0'', ''S-1-5-11'',' ; W = '@(''S-1-5-11'',' },
        @{ N = 'writer-users-dropped';         F = $L; O = '''S-1-5-11'', ''S-1-5-32-545'',' ; W = '''S-1-5-11'',' },
        @{ N = 'coder-sid-not-a-writer';       F = $L; O = '+ $(if ($CoderSid) { @($CoderSid) } else { @() })'; W = '' },
        @{ N = 'coder-groups-not-writers';     F = $L; O = '+ @($GroupSids) +'; W = '+' },
        @{ N = 'extra-writers-ignored';        F = $L; O = '+ @($ExtraWriterSids) +'; W = '+' },
        @{ N = 'owner-check-dropped';          F = $L; O = 'if ($a.Owner -and ($writers -contains $a.Owner))'; W = 'if ($false)' },
        @{ N = 'ancestors-dropped';            F = $L; O = 'foreach ($anc in (Get-BootAncestors -Path $dir)) {'; W = 'foreach ($anc in @()) {' },
        @{ N = 'ancestor-uses-full-mask';      F = $L; O = '$r = & $judge $anc $script:BootReplaceMask ''an ancestor folder'''; W = '$r = & $judge $anc $script:BootWriteMask ''an ancestor folder''' },
        @{ N = 'file-check-dropped';           F = $L; O = '$r = & $judge $file $script:BootWriteMask ''the file'''; W = '$r = @{ Reasons = @() }' },
        @{ N = 'unreadable-passes';            F = $L; O = 'if ($a.Error) { [void]$reasons.Add("access list unreadable ($($a.Error))"); return @{ Reasons = @($reasons); Missing = $false; Unreadable = $true } }'; W = 'if ($a.Error) { return @{ Reasons = @(); Missing = $false } }' },
        @{ N = 'unquoted-candidates-dropped';  F = $L; O = 'foreach ($c in @($sp.Candidates)) {'; W = 'foreach ($c in @()) {' },
        @{ N = 'unquoted-uses-quoted-rule';    F = $L; O = '$r = & $judge $cd $script:BootPlantMask ''the folder'''; W = '$r = @{ Reasons = @() }' },
        @{ N = 'unresolved-path-passes';       F = $L; O = 'if (-not $sp.Exe) { & $add ''unresolved-path'' $cmd ''executable'' "the service path cannot be resolved ($($sp.Problem))"; continue }'; W = 'if (-not $sp.Exe) { continue }' },
        @{ N = 'manual-services-swept';        F = $L; O = 'if (([string]$s.StartMode) -notin @(''Auto'', ''Automatic'', ''Delayed'', ''Auto Start'')) { continue }'; W = '' },
        @{ N = 'auto-services-skipped';        F = $L; O = 'if (([string]$s.StartMode) -notin @(''Auto'', ''Automatic'', ''Delayed'', ''Auto Start'')) { continue }'; W = 'continue' },
        @{ N = 'empty-account-not-system';     F = $L; O = 'if ($n -eq '''') { return ''service-account'' }'; W = '' },
        @{ N = 'disabled-tasks-swept';         F = $L; O = 'if (-not $t.Enabled) { continue }'; W = '' },
        @{ N = 'enabled-tasks-skipped';        F = $L; O = 'if (-not $t.Enabled) { continue }'; W = 'continue' },
        @{ N = 'unknown-principal-not-privileged'; F = $L; O = '$priv = $true }   # unknown = privileged'; W = '$priv = $false }' },
        @{ N = 'admin-group-principal-ignored'; F = $L; O = 'elseif ($groupSid -eq ''S-1-5-32-544'') { $priv = $true }'; W = '' },
        @{ N = 'admin-member-user-ignored';    F = $L; O = 'elseif ($userSid -and ($null -eq $adminSids -or ($adminSids -contains $userSid))) { $priv = $true }'; W = '' },
        @{ N = 'admin-lookup-failure-trusts';  F = $L; O = '($null -eq $adminSids -or ($adminSids -contains $userSid))'; W = '($adminSids -contains $userSid)' },
        @{ N = 'non-admin-user-swept';         F = $L; O = 'elseif ($userSid -and ($null -eq $adminSids -or ($adminSids -contains $userSid))) { $priv = $true }'; W = 'elseif ($userSid) { $priv = $true }' },
        @{ N = 'system-principal-ignored';     F = $L; O = 'elseif ($userSid -and ($script:BootPrivilegedSids -contains $userSid)) { $priv = $true }'; W = '' },
        @{ N = 'file-flag-script-not-found';   F = $L; O = '''(?i)(?:^|\s)-(?:file|f|filepath)(?:\s+|[:=])'; W = '''(?i)(?:^|\s)-(?:zzfile)(?:\s+|[:=])' },
        @{ N = 'missing-script-folder-ignored'; F = $L; O = '$(if ($fileMissing) { "the file $file does not exist; $w" } else { $w })'; W = '$w' },
        @{ N = 'task-arguments-not-parsed';    F = $L; O = '& $judgeAction ([string]$act.Execute) ([string]$act.Arguments) ([string]$act.WorkingDirectory) $add'; W = '& $judgeAction ([string]$act.Execute) '''' ([string]$act.WorkingDirectory) $add' },
        @{ N = 'bare-command-unresolved-passes'; F = $L; O = 'if (-not $resolved) { & $emit ''unresolved-path'' $path ''executable'' "the command ''$path'' cannot be resolved to a file"; continue }'; W = 'if (-not $resolved) { continue }' },
        @{ N = 'quoted-path-expanded';         F = $L; O = 'return @{ Exe = $raw.Substring(1, $end - 1); Quoted = $true; Candidates = @(); Problem = ''''; Args = $raw.Substring($end + 1).Trim() }'; W = 'return @{ Exe = $raw.Substring(1, $end - 1); Quoted = $true; Candidates = @($raw.Split('' '')[0]); Problem = ''''; Args = '''' }' },
        @{ N = 'ghost-ancestor-search-dropped'; F = $L; O = 'while ($near -and -not (& $read $near).Exists) { $near = [IO.Path]::GetDirectoryName($near) }'; W = '$near = $null' },
        @{ N = 'ghost-uses-replace-mask';      F = $L; O = '$r = & $judge $near $script:BootCreateMask ''the nearest existing folder'''; W = '$r = & $judge $near $script:BootReplaceMask ''the nearest existing folder''' },
        @{ N = 'ghost-nothing-exists-passes';  F = $L; O = 'if (-not $near) { [void]$hits.Add(@{ Path = $dir; Why = ''neither the file nor any folder above it exists''; Kind = ''unresolved-path'' }) }'; W = 'if (-not $near) { }' },
        @{ N = 'wd-interpreter-rule-dropped';  F = $L; O = 'if ($leaf -match $script:BootInterpreters) { return $true }'; W = '' },
        @{ N = 'wd-judged-with-no-switch-test'; F = $L; O = 'if ($tok -notmatch ''^[-/]'' -and'; W = 'if (' },
        @{ N = 'relative-script-not-resolved'; F = $L; O = 'elseif ($wd -and $w -notmatch ''[:*?<>|]'') { & $add ([IO.Path]::Combine($wd, $w)) ''relative-script'' }'; W = '' },
        @{ N = 'service-arguments-not-judged'; F = $L; O = '& $judgeAction $sp.Exe $sp.Args '''' $add'; W = '& $judgeAction $sp.Exe '''' '''' $add' },
        @{ N = 'named-admin-service-out-of-scope'; F = $L; O = 'if ($acct -and $null -ne $adminSids -and ($adminSids -notcontains $acct) -and ($script:BootPrivilegedSids -notcontains $acct)) { continue }'; W = 'continue' },
        @{ N = 'named-unresolved-account-skipped'; F = $L; O = 'if ($acct -and $null -ne $adminSids -and'; W = 'if ($null -ne $adminSids -and' },
        @{ N = 'named-service-lookup-failure-trusts'; F = $L; O = 'if ($acct -and $null -ne $adminSids -and ($adminSids -notcontains $acct)'; W = 'if ($acct -and ($adminSids -notcontains $acct)' },
        @{ N = 'verdict-errors-ignored';       F = $L; O = 'if ($errs.Count -gt 0 -and $off.Count -eq 0) {'; W = 'if ($false) {' },
        @{ N = 'wd-script-word-rule-dropped'; F = $L; O = 'if ($tok -match $script:BootScriptExtensions) { return $true }'; W = '' },
        @{ N = 'wd-existing-file-rule-dropped'; F = $L; O = 'if ($Exists -and $WorkingDirectory -and $tok -notmatch ''[:*?<>|]'' -and (& $Exists ([IO.Path]::Combine($WorkingDirectory, $tok)))) { return $true }'; W = '' },
        @{ N = 'wd-any-relative-word-counts'; F = $L; O = 'if ($tok -match $script:BootScriptExtensions) { return $true }'; W = 'return $true' },
        @{ N = 'redirect-target-judged'; F = $L; O = ' -replace ''(\d?>>?|<)\s*("[^"]*"|\S+)'', '' '''; W = '' },
        @{ N = 'folder-argument-judged-as-code'; F = $L; O = 'if ($p.Role -ne ''executable'' -and (& $read $path).IsDir) { continue }'; W = '' },
        @{ N = 'folder-mask-includes-append'; F = $L; O = '$r = & $judge $dir $script:BootFolderMask ''the folder''
            if ($r.Missing) {'; W = '$r = & $judge $dir $script:BootWriteMask ''the folder''
            if ($r.Missing) {' },
        @{ N = 'lone-path-always-a-command'; F = $L; O = '($words.Count -gt 1 -or $loneIsCommand)'; W = '$true' },
        @{ N = 'wd-existing-folder-counts'; F = $L; O = '($fa.Exists -and -not $fa.IsDir)'; W = '$fa.Exists' },
        @{ N = 'folder-check-dropped';         F = $L; O = '$r = & $judge $dir $script:BootFolderMask ''the folder'''; W = '$r = @{ Reasons = @() }' },
        @{ N = 'wd-never-judged';              F = $L; O = 'if ($wdX -and (Test-BootWorkingDirMatters'; W = 'if ($false -and (Test-BootWorkingDirMatters' },
        @{ N = 'command-word-dropped';         F = $L; O = 'if ($cmdWord -and $cmdWord -match $rooted -and ($words.Count -gt 1 -or $loneIsCommand)) { & $add $cmdWord ''argument'' }'; W = '' },
        @{ N = 'own-dir-mask-without-append'; F = $L; O = '$script:BootFolderMask = [int64](2 + 4 + 64'; W = '$script:BootFolderMask = [int64](2 + 64' },
        @{ N = 'ancestor-uses-folder-mask';  F = $L; O = '$r = & $judge $anc $script:BootReplaceMask ''an ancestor folder'''; W = '$r = & $judge $anc $script:BootFolderMask ''an ancestor folder''' },
        @{ N = 'interpreters-dotnet-msbuild-php-dropped'; F = $L; O = '|dotnet|msbuild|php|'; W = '|' },
        @{ N = 'interpreters-python-versions-dropped'; F = $L; O = 'python[0-9.]*w?'; W = 'python|pythonw' },
        @{ N = 'interpreters-mshta-rundll32-wscript-dropped'; F = $L; O = '|mshta|rundll32|wscript|cscript|'; W = '|' },
        @{ N = 'start-title-not-skipped';    F = $L; O = 'if ($prevTok -eq ''start'' -and ('; W = 'if ($false -and (' },
        @{ N = 'parser-caret-not-stripped';    F = $L; O = '$a = $a -replace ''\^(.)'', ''$1'''; W = '' },
        @{ N = 'parser-cmd-outer-quotes-kept'; F = $L; O = '$a = $a -replace ''(?i)^(\s*/[ck]\s+)"(.*"[^"]*)"\s*$'', ''$1$2'''; W = '' },
        @{ N = 'parser-doubled-quotes-kept';   F = $L; O = '$a = [regex]::Replace($a, ''""(?=[^"\s])|(?<=[^"\s])""'', ''"'')'; W = '' },
        @{ N = 'parser-backtick-space-split';  F = $L; O = '$a = $a -replace ''`\s'', ([string][char]1)'; W = '' },
        @{ N = 'parser-backtick-not-stripped'; F = $L; O = '$a = $a -replace ''`(.)'', ''$1'''; W = '' },
        @{ N = 'parser-env-var-not-expanded';  F = $L; O = '$a = [regex]::Replace($a, ''\$env:(\w+)'', { param($m) $v = [Environment]::GetEnvironmentVariable($m.Groups[1].Value); if ($null -ne $v) { $v } else { $m.Value } })'; W = '' },
        @{ N = 'parser-program-env-not-expanded'; F = $L; O = '$e = [Environment]::ExpandEnvironmentVariables($Execute.Trim().Trim(''"'')).Trim().TrimEnd(''.'', '' '')'; W = '$e = $Execute.Trim().Trim(''"'').Trim().TrimEnd(''.'', '' '')' },
        @{ N = 'parser-program-trailing-dot-kept'; F = $L; O = ').Trim().TrimEnd(''.'', '' '')'; W = ').Trim()' },
        @{ N = 'parser-program-slashes-kept';  F = $L; O = 'if ($e -match ''^([A-Za-z]:|[\\/]{2})'') { $e = $e.Replace(''/'', ''\'') }'; W = '' },
        @{ N = 'parser-short-name-kept';       F = $L; O = 'if ($e -match ''~'') { $e = [string](& $LongName $e) }'; W = '' },
        @{ N = 'parser-arg-slashes-kept';      F = $L; O = '$a = [regex]::Replace($a, ''[A-Za-z]:[\\/](?:(?!\s[-/])[^"''''<>|*?\r\n])*'', { param($m) $m.Value.Replace(''/'', ''\'') })'; W = '' },
        @{ N = 'parser-unc-slashes-kept';      F = $L; O = '$a = [regex]::Replace($a, ''(?<![:\w])//[^\s"'''']+'', { param($m) $m.Value.Replace(''/'', ''\'') })'; W = '' },
        @{ N = 'parser-trailing-dot-in-paths-kept'; F = $L; O = '$p = $p.Replace($sp, '' '').Trim().Trim(''"'', "''").TrimEnd(''.'', '' '');'; W = '$p = $p.Replace($sp, '' '').Trim().Trim(''"'', "''");' },
        @{ N = 'parser-trailing-dot-in-words-kept'; F = $L; O = '$_.Replace($sp, '' '').Trim().Trim(''"'', "''").TrimEnd(''.'', '' '')'; W = '$_.Replace($sp, '' '').Trim().Trim(''"'', "''")' },
        @{ N = 'parser-quoted-inner-paths-dropped'; F = $L; O = 'if ($qv -match $rooted -and $qv -match $script:BootScriptExtensions) { & $add $qv ''argument'' }'; W = '' },
        @{ N = 'parser-working-dir-program-unresolved'; F = $L; O = '$prog = Resolve-BootProgram -Execute $Execute -LongName $LongName'; W = '$prog = $Execute' },
        @{ N = 'dll-entry-split-dropped'; F = $L; O = '$a = [regex]::Replace($a, ''(\.(?:dll|ocx|cpl|drv))(["'''']?)\s*,\s*[#\w@?]+(?![\w.])'', ''$1$2'')'; W = '' },
        @{ N = 'dll-entry-ordinal-dropped'; F = $L; O = '$a = [regex]::Replace($a, ''(\.(?:dll|ocx|cpl|drv))(["'''']?)\s*,\s*[#\w@?]+(?![\w.])'', ''$1$2'')'; W = '$a = [regex]::Replace($a, ''(\.(?:dll|ocx|cpl|drv))(["'''']?)\s*,\s*\w+(?![\w.])'', ''$1$2'')' },
        # dll-entry-quote-dropped is equivalent: a quoted DLL path is already one token for the tokenizer, so the comma split is not needed for it
        @{ N = 'dll-entry-extensions-dll-only-dropped'; F = $L; O = '$a = [regex]::Replace($a, ''(\.(?:dll|ocx|cpl|drv))(["'''']?)\s*,\s*[#\w@?]+(?![\w.])'', ''$1$2'')'; W = '$a = [regex]::Replace($a, ''(\.xyz)(["'''']?)\s*,\s*[#\w@?]+(?![\w.])'', ''$1$2'')' },
        @{ N = 'empty-service-list-not-blind'; F = $L; O = 'if ($services.Count -eq 0) { throw ''the service list came back empty: the sweep is blind'' }'; W = '' },
        @{ N = 'empty-task-list-not-blind';    F = $L; O = 'if ($tasks.Count -eq 0) { throw ''the scheduled-task list came back empty: the sweep is blind'' }'; W = '' },
        @{ N = 'verdict-null-passes';          F = $L; O = 'if ($null -eq $Result) { return @{ Pass = $false;'; W = 'if ($null -eq $Result) { return @{ Pass = $true;' },
        @{ N = 'verdict-blind-passes';         F = $L; O = '[int]$Result.ServicesEnumerated -le 0 -or [int]$Result.TasksEnumerated -le 0'; W = '$false' },
        @{ N = 'verdict-ignores-offenders';    F = $L; O = 'if ($off.Count -gt 0) {'; W = 'if ($false) {' },
        @{ N = 'verdict-incomplete-passes';    F = $L; O = 'if (-not $Result.Complete -or'; W = 'if ($false -or' },
        @{ N = 'wiring-sweep-not-called';      F = $V; O = '$boot = Find-CoderWritableBootSurface'; W = '$boot = $null; $null = (Get-Command Find-CoderWritableBootSurface)' },
        @{ N = 'wiring-failure-not-joined';    F = $V; O = '$setupFailed = @($setupFailed) + @($bootVerdict.Failed)'; W = '' },
        @{ N = 'wiring-verdict-bypassed';      F = $V; O = '$bootVerdict = Get-BootSurfaceVerdict -Result $boot -ErrorText $bootError'; W = '$bootVerdict = @{ Pass = $true; Failed = @(); Detail = ''skipped'' }' },
        @{ N = 'wiring-exception-swallowed-as-pass'; F = $V; O = '} catch { $bootError = $_.Exception.Message }'; W = '} catch { $boot = @{ Offenders = @(); Errors = @(); ServicesEnumerated = 1; TasksEnumerated = 1; ServicesInScope = 0; TasksInScope = 0; Complete = $true } }' },
        @{ N = 'wiring-lib-not-loaded';        F = $V; O = '. "$PSScriptRoot\coder-boot-surface-lib.ps1"'; W = '' },
        @{ N = 'off-path-loads-lib';           F = 'fleet-lib.ps1'; O = '$ErrorActionPreference'; W = '# coder-boot-surface-lib' + "`n" + '$ErrorActionPreference' }
    )
    if ($Only.Count -gt 0) { $muts = @($muts | Where-Object { $Only -contains $_.N }) }
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

. "$PSScriptRoot\coder-boot-surface-lib.ps1"
$script:Pass = 0; $script:Fail = 0; $script:Failures = New-Object System.Collections.ArrayList
function _pass($m) { $script:Pass++; Write-Host "  [PASS] $m" -ForegroundColor Green }
function _fail($m) { $script:Fail++; [void]$script:Failures.Add($m); Write-Host "  [FAIL] $m" -ForegroundColor Red }
function Assert-True($c, $m) { if ($c) { _pass $m } else { _fail "$m (expected True)" } }
function Assert-Eq($e, $a, $m) { if ([string]$e -ceq [string]$a) { _pass $m } else { _fail "$m (expected '$e', got '$a')" } }
function Section($t) { Write-Host ''; Write-Host "== $t ==" -ForegroundColor Cyan }

$AuthUsers = 'S-1-5-11'; $UsersSid = 'S-1-5-32-545'; $Admins = 'S-1-5-32-544'; $System = 'S-1-5-18'
$CoderSid = 'S-1-5-21-1111111111-2222222222-3333333333-1009'; $OperatorSid = 'S-1-5-21-1111111111-2222222222-3333333333-1001'
$Modify = [int64]0x1301BF; $Full = [int64]0x1F01FF; $RX = [int64]0x1200A9; $GenericReadExec = [int64]0xA0000000; $GenericAll = [int64]0x10000000

# ---- fake access lists -----------------------------------------------------------------------------------
function New-FakeAcl([string]$Owner = 'S-1-5-18', [object[]]$Aces = @(), [bool]$IsDir = $false) { @{ Exists = $true; IsDir = $IsDir; Owner = $Owner; Aces = @($Aces); Error = '' } }
function New-FakeAce([string]$Sid, [int64]$Mask, [string]$Type = 'Allow', [bool]$InheritOnly = $false) { @{ Sid = $Sid; Type = $Type; Mask = $Mask; InheritOnly = $InheritOnly } }
$Locked = { New-FakeAcl -Aces @((New-FakeAce $System $Full), (New-FakeAce $Admins $Full), (New-FakeAce $UsersSid $RX)) }.GetNewClosure()
# a reader over a table; any path not in the table is a clean, protected one
function New-Reader([hashtable]$Table, [switch]$MissingByDefault) {
    $t = @{}; foreach ($k in $Table.Keys) { $t[$k.ToLowerInvariant()] = $Table[$k] }
    $md = [bool]$MissingByDefault
    return { param($p) $k = $p.ToLowerInvariant(); if ($t.ContainsKey($k)) { $t[$k] } elseif ($md) { @{ Exists = $false; IsDir = $false; Owner = ''; Aces = @(); Error = '' } } else { & $Locked } }.GetNewClosure()
}
function New-Svc([string]$Name, [string]$Path, [string]$Mode = 'Auto', [string]$As = 'LocalSystem') { @{ Name = $Name; StartMode = $Mode; StartName = $As; PathName = $Path } }
function New-Task([string]$Name, [string]$Exe, [string]$Args2 = '', [string]$User = 'SYSTEM', [bool]$Enabled = $true, [string]$Group = '', [string]$Wd = '') {
    @{ Path = '\'; Name = $Name; Enabled = $Enabled; UserId = $User; GroupId = $Group; RunLevel = 'Highest'; Actions = @(@{ Execute = $Exe; Arguments = $Args2; WorkingDirectory = $Wd }) }
}
$Filler = @{ Name = 'Filler'; StartMode = 'Manual'; StartName = 'LocalSystem'; PathName = 'C:\Windows\filler.exe' }
$FillerTask = New-Task 'FillerTask' 'C:\Windows\filler.exe' -Enabled $false
$sidMap = @{ 'SYSTEM' = $System; 'NT AUTHORITY\SYSTEM' = $System; 'LOCAL SERVICE' = 'S-1-5-19'; 'Administrators' = $Admins; 'BUILTIN\Administrators' = $Admins; 'op' = $OperatorSid; 'std' = 'S-1-5-21-1111111111-2222222222-3333333333-1500'; 'Users' = $UsersSid }
$Resolver = { param($n) if ($sidMap.ContainsKey($n)) { $sidMap[$n] } else { '' } }.GetNewClosure()
$AdminMembers = { @($OperatorSid) }.GetNewClosure()
$ex = { param($p) $true }   # every named service file "exists" for the unquoted-path splitter unless a case says otherwise
function Invoke-Sweep {
    param([object[]]$Services = @(), [object[]]$Tasks = @(), [scriptblock]$Reader, [string]$Coder = '', [string[]]$Groups = @(), [string[]]$Extra = @(), [scriptblock]$Exists = $ex, [scriptblock]$Cmd = { param($n) "C:\Windows\System32\$n.exe" }, [scriptblock]$Admin = $AdminMembers)
    $svcs = @($Services) + @($Filler); $tsk = @($Tasks) + @($FillerTask)
    Find-CoderWritableBootSurface -CoderSid $Coder -GroupSids $Groups -ExtraWriterSids $Extra -ServiceSource { $svcs }.GetNewClosure() -TaskSource { $tsk }.GetNewClosure() -AclReader $Reader -PathExists $Exists -AdminMemberSids $Admin -SidResolver $Resolver -CommandResolver $Cmd
}
function Test-Step { param([string]$Name, [scriptblock]$Body) try { & $Body } catch { _fail "$Name threw: $($_.Exception.Message)" } }

Section 'pure: masks, accounts, service paths, task action paths, verdict'
Test-Step 'pure' {
    Assert-True (Test-BootMaskWritable -Mask $Modify) 'Modify is a write right'
    Assert-True (-not (Test-BootMaskWritable -Mask $RX)) 'read-and-execute is not a write right'
    Assert-True (-not (Test-BootMaskWritable -Mask $GenericReadExec)) 'the generic read+execute bits of an unexpanded inherit-only entry are not a write right'
    Assert-True (Test-BootMaskWritable -Mask $GenericAll) 'GENERIC_ALL is a write right'
    Assert-True (Test-BootMaskWritable -Mask ([int64]([int]-1073741824) -band [int64]4294967295)) 'a mask read as a SIGNED 32-bit number with GENERIC_WRITE set is read as unsigned and counts as write'
    Assert-True (-not (Test-BootMaskWritable -Mask ([int64]([int]-1610612736) -band [int64]4294967295))) 'a signed-negative generic read+execute mask (0xA0000000) does not count as write'
    Assert-Eq 'service-account' (Get-BootAccountClass 'LocalSystem') 'LocalSystem is a service account'
    Assert-Eq 'service-account' (Get-BootAccountClass 'NT AUTHORITY\LocalService') 'LocalService is a service account'
    Assert-Eq 'service-account' (Get-BootAccountClass 'NT AUTHORITY\NetworkService') 'NetworkService is a service account'
    Assert-Eq 'service-account' (Get-BootAccountClass '') 'an empty account name is LocalSystem'
    Assert-Eq 'other' (Get-BootAccountClass '.\someone') 'a named account is not a service account'
    $q = Split-BootServicePath -PathName '"C:\Program Files\App One\svc.exe" -k grp' -PathExists { param($p) $true }
    Assert-True ($q.Exe -eq 'C:\Program Files\App One\svc.exe' -and @($q.Candidates).Count -eq 0 -and $q.Quoted) 'quoted service path: the exe is the quoted text, no candidates'
    $exists = { param($p) $p -eq 'C:\Program Files\App One\svc.exe' }
    $u = Split-BootServicePath -PathName 'C:\Program Files\App One\svc.exe -k grp' -PathExists $exists
    Assert-True ($u.Exe -eq 'C:\Program Files\App One\svc.exe' -and (@($u.Candidates) -join '|') -eq 'C:\Program.exe|C:\Program Files\App.exe') 'unquoted service path with spaces: the earlier candidates Windows tries are listed'
    $n = Split-BootServicePath -PathName 'C:\Windows\system32\svchost.exe -k netsvcs' -PathExists { param($p) $p -eq 'C:\Windows\system32\svchost.exe' }
    Assert-True ($n.Exe -eq 'C:\Windows\system32\svchost.exe' -and @($n.Candidates).Count -eq 0) 'a path without spaces in the exe name has no candidates'
    $m = Split-BootServicePath -PathName 'C:\No Such\thing.exe' -PathExists { param($p) $false }
    Assert-True ([string]::IsNullOrEmpty($m.Exe) -and @($m.Candidates).Count -ge 1) 'a path with no existing file resolves to no exe (and is reported by the sweep)'
    $a = @(Get-BootActionPaths -Execute 'powershell.exe' -Arguments '-NoProfile -File C:\nginx\bin\gateway-watchdog.ps1 -Quiet')
    Assert-True (@($a | Where-Object { $_.Path -eq 'C:\nginx\bin\gateway-watchdog.ps1' }).Count -eq 1) 'a task action: -File <script> is picked out of the arguments'
    $a = @(Get-BootActionPaths -Execute 'cmd.exe' -Arguments '/c "C:\tools\a b\run.cmd" > C:\logs\out.txt')
    Assert-True (@($a | Where-Object { $_.Path -eq 'C:\tools\a b\run.cmd' }).Count -eq 1 -and @($a | Where-Object { $_.Path -like '*out.txt' }).Count -eq 0) 'a quoted script path with spaces is found; an output file is not code'
    $a = @(Get-BootActionPaths -Execute 'pwsh.exe' -Arguments '-Command "& ''C:\x\y.ps1''; Get-Date"')
    Assert-True (@($a | Where-Object { $_.Path -eq 'C:\x\y.ps1' }).Count -eq 1) 'a script path inside -Command is found'
    $a = @(Get-BootActionPaths -Execute '"C:\Program Files\X\x.exe"' -Arguments '')
    Assert-True ($a.Count -eq 1 -and $a[0].Path -eq 'C:\Program Files\X\x.exe') 'a quoted Execute is unquoted'
    $a = @(Get-BootActionPaths -Execute 'powershell.exe' -Arguments '-File run.ps1' -WorkingDirectory 'C:\work')
    Assert-True (@($a | Where-Object { $_.Path -eq 'C:\work\run.ps1' }).Count -eq 1) 'a relative -File script resolves against the working directory'
    Assert-True ((Get-BootSurfaceVerdict -Result $null).Pass -eq $false) 'verdict: an ABSENT result fails'
    Assert-True ((Get-BootSurfaceVerdict -Result $null -ErrorText 'boom').Detail -match 'boom') 'verdict: an absent result carries the error text'
    Assert-True ((Get-BootSurfaceVerdict -Result @{ Complete = $true; ServicesEnumerated = 0; TasksEnumerated = 5; Offenders = @(); Errors = @() }).Pass -eq $false) 'verdict: a sweep that saw no services is blind and fails'
    Assert-True ((Get-BootSurfaceVerdict -Result @{ Complete = $true; ServicesEnumerated = 5; TasksEnumerated = 0; Offenders = @(); Errors = @() }).Pass -eq $false) 'verdict: a sweep that saw no tasks is blind and fails'
    Assert-True ((Get-BootSurfaceVerdict -Result @{ Complete = $false; ServicesEnumerated = 5; TasksEnumerated = 5; Offenders = @(); Errors = @() }).Pass -eq $false) 'verdict: an incomplete sweep fails'
    Assert-True ((Get-BootSurfaceVerdict -Result @{ Complete = $true; ServicesEnumerated = 5; TasksEnumerated = 5; Offenders = @(@{ Kind = 'writable'; Name = 'X'; RunAs = 'SYSTEM'; Path = 'C:\x'; Why = 'w' }); Errors = @() }).Pass -eq $false) 'verdict: one offender fails'
    $ok = Get-BootSurfaceVerdict -Result @{ Complete = $true; ServicesEnumerated = 5; TasksEnumerated = 5; ServicesInScope = 2; TasksInScope = 3; Offenders = @(); Errors = @() }
    Assert-True ($ok.Pass -and $ok.Failed.Count -eq 0) 'verdict: a complete sweep with zero offenders passes'
    Assert-Eq 'check25-no-coder-writable-boot-surface' (Get-BootSurfaceVerdict -Result $null).Failed[0] 'the failed check is named check25-no-coder-writable-boot-surface'
}

Section 'the sweep: services (fake system, fake access lists)'
Test-Step 'services' {
    $svc = New-Svc 'Evil' '"C:\Svc\evil.exe" -x'
    $clean = Invoke-Sweep -Services @($svc) -Reader (New-Reader @{})
    Assert-True (@($clean.Offenders).Count -eq 0 -and $clean.ServicesInScope -eq 1) 'negative control: an auto SYSTEM service with a protected exe and folder is not an offender'
    $r = Invoke-Sweep -Services @($svc) -Reader (New-Reader @{ 'C:\Svc\evil.exe' = (New-FakeAcl -Aces @((New-FakeAce $System $Full), (New-FakeAce $AuthUsers $Modify))) })
    Assert-True (@($r.Offenders | Where-Object { $_.Name -eq 'Evil' -and $_.Path -eq 'C:\Svc\evil.exe' }).Count -eq 1) 'positive control: Authenticated Users Modify on the exe is an offender'
    $r = Invoke-Sweep -Services @($svc) -Reader (New-Reader @{ 'C:\Svc' = (New-FakeAcl -IsDir $true -Aces @((New-FakeAce $System $Full), (New-FakeAce $UsersSid ([int64]6)))) })
    Assert-True (@($r.Offenders | Where-Object { $_.Path -eq 'C:\Svc' }).Count -eq 1) 'a folder where Users may create files/folders (write-data, append-data) is an offender'
    $r = Invoke-Sweep -Services @($svc) -Reader (New-Reader @{ 'C:\Svc' = (New-FakeAcl -IsDir $true -Aces @((New-FakeAce $System $Full), (New-FakeAce 'S-1-1-0' $Modify))) })
    Assert-True (@($r.Offenders).Count -ge 1) 'Everyone Modify on the folder is an offender'
    $r = Invoke-Sweep -Services @($svc) -Reader (New-Reader @{ 'C:\Svc' = (New-FakeAcl -IsDir $true -Aces @((New-FakeAce $System $Full), (New-FakeAce $AuthUsers $Modify $true))) })
    Assert-True (@($r.Offenders).Count -eq 0) 'INHERIT-ONLY Modify on the folder does not apply to the folder: not an offender'
    $r = Invoke-Sweep -Services @($svc) -Reader (New-Reader @{ 'C:\Svc' = (New-FakeAcl -IsDir $true -Aces @((New-FakeAce $System $Full), (New-FakeAce $UsersSid $GenericReadExec $true), (New-FakeAce $UsersSid $RX))) })
    Assert-True (@($r.Offenders).Count -eq 0) 'an inherit-only entry with the unexpanded generic read+execute mask is not a write (the first manual sweep misread this)'
    $r = Invoke-Sweep -Services @($svc) -Reader (New-Reader @{ 'C:\Svc' = (New-FakeAcl -IsDir $true -Aces @((New-FakeAce $System $Full), (New-FakeAce $AuthUsers $Modify 'Deny'))) })
    Assert-True (@($r.Offenders).Count -eq 0) 'a Deny entry is never counted as a grant'
    $r = Invoke-Sweep -Services @($svc) -Reader (New-Reader @{ 'C:\Svc' = (New-FakeAcl -Owner $UsersSid -IsDir $true -Aces @((New-FakeAce $System $Full))) })
    Assert-True (@($r.Offenders | Where-Object { $_.Why -match 'owned by' }).Count -eq 1) 'a folder OWNED by a low-privilege principal is an offender (an owner can rewrite the access list)'
    $r = Invoke-Sweep -Services @($svc) -Reader (New-Reader @{ 'C:\Svc' = (New-FakeAcl -IsDir $true -Aces @((New-FakeAce $System $Full), (New-FakeAce $CoderSid $Modify))) }) -Coder $CoderSid
    Assert-True (@($r.Offenders | Where-Object { $_.Path -eq 'C:\Svc' }).Count -eq 1) 'a write entry for the coder SID is an offender'
    $r = Invoke-Sweep -Services @($svc) -Reader (New-Reader @{ 'C:\Svc' = (New-FakeAcl -IsDir $true -Aces @((New-FakeAce $System $Full), (New-FakeAce $CoderSid $Modify))) })
    Assert-True (@($r.Offenders).Count -eq 0) 'the coder SID is only a writer when it is passed in (toggle)'
    $other = 'S-1-5-21-1111111111-2222222222-3333333333-7777'
    $rx = New-Reader @{ 'C:\Svc' = (New-FakeAcl -IsDir $true -Aces @((New-FakeAce $System $Full), (New-FakeAce $other $Modify))) }
    Assert-True (@((Invoke-Sweep -Services @($svc) -Reader $rx).Offenders).Count -eq 0 -and @((Invoke-Sweep -Services @($svc) -Reader $rx -Extra @($other)).Offenders).Count -ge 1) 'an extra writer SID passed in (-ExtraWriterSids) is judged; the same SID not passed is not (toggle)'
    $grp = 'S-1-5-21-1111111111-2222222222-3333333333-1100'
    $r = Invoke-Sweep -Services @($svc) -Reader (New-Reader @{ 'C:\Svc' = (New-FakeAcl -IsDir $true -Aces @((New-FakeAce $System $Full), (New-FakeAce $grp $Modify))) }) -Coder $CoderSid -Groups @($grp)
    Assert-True (@($r.Offenders | Where-Object { $_.Path -eq 'C:\Svc' }).Count -eq 1) 'a write entry for a group the coder belongs to is an offender'
    $r = Invoke-Sweep -Services @($svc) -Reader (New-Reader @{ 'C:\Svc' = (New-FakeAcl -Owner $OperatorSid -IsDir $true -Aces @((New-FakeAce $System $Full), (New-FakeAce $Admins $Full))) })
    Assert-True (@($r.Offenders).Count -eq 0) 'a folder owned by an administrator account with only admin entries is fine'
    $r = Invoke-Sweep -Services @($svc) -Reader (New-Reader @{ 'C:\' = (New-FakeAcl -IsDir $true -Aces @((New-FakeAce $System $Full), (New-FakeAce $AuthUsers ([int64]65536)))) })
    Assert-True (@($r.Offenders | Where-Object { $_.Path -eq 'C:\' -and $_.Why -match 'ancestor' }).Count -eq 1) 'an ANCESTOR folder where Authenticated Users may delete (so the folder can be renamed away and replaced) is an offender'
    $r = Invoke-Sweep -Services @($svc) -Reader (New-Reader @{ 'C:\' = (New-FakeAcl -IsDir $true -Aces @((New-FakeAce $System $Full), (New-FakeAce $AuthUsers ([int64]6)))) })
    Assert-True (@($r.Offenders).Count -eq 0) 'an ancestor where users may only create files and folders (the normal drive root) is not an offender'
    $r = Invoke-Sweep -Services @($svc) -Reader { param($p) @{ Exists = $true; IsDir = $false; Owner = ''; Aces = @(); Error = 'Access is denied' } }
    Assert-True (@($r.Offenders | Where-Object { $_.Kind -eq 'unreadable' }).Count -ge 1) 'FAIL-CLOSED: an access list that cannot be read is an offender of kind unreadable'
    $r = Invoke-Sweep -Services @(New-Svc 'Gone' 'C:\No Such\thing.exe') -Reader (New-Reader @{}) -Exists { param($p) $false }
    Assert-True (@($r.Offenders | Where-Object { $_.Kind -eq 'unresolved-path' }).Count -eq 1) 'FAIL-CLOSED: a service path that resolves to no file is an offender of kind unresolved-path'
    $r = Invoke-Sweep -Services @(New-Svc 'Rel' 'foo.exe') -Reader (New-Reader @{}) -Exists { param($p) $true } -Cmd { param($n) '' }
    Assert-True (@($r.Offenders | Where-Object { $_.Kind -eq 'unresolved-path' }).Count -eq 1) 'a service path that is not absolute is an offender of kind unresolved-path'
    # scope
    $bad = New-FakeAcl -Aces @((New-FakeAce $System $Full), (New-FakeAce $AuthUsers $Modify))
    $rd = New-Reader @{ 'C:\Svc\evil.exe' = $bad }
    Assert-True (@((Invoke-Sweep -Services @((New-Svc 'M' '"C:\Svc\evil.exe"' 'Manual')) -Reader $rd).Offenders).Count -eq 0) 'scope: a Manual service is not swept'
    Assert-True (@((Invoke-Sweep -Services @((New-Svc 'D' '"C:\Svc\evil.exe"' 'Disabled')) -Reader $rd).Offenders).Count -eq 0) 'scope: a Disabled service is not swept'
    Assert-True (@((Invoke-Sweep -Services @((New-Svc 'U' '"C:\Svc\evil.exe"' 'Auto' 'std')) -Reader $rd).Offenders).Count -eq 0) 'scope: a service running as a named NON-admin account is not swept'
    Assert-True (@((Invoke-Sweep -Services @((New-Svc 'LS' '"C:\Svc\evil.exe"' 'Auto' 'NT AUTHORITY\LocalService')) -Reader $rd).Offenders).Count -ge 1) 'scope: a LocalService auto service is swept'
    Assert-True (@((Invoke-Sweep -Services @((New-Svc 'NS' '"C:\Svc\evil.exe"' 'Auto' 'NT AUTHORITY\NetworkService')) -Reader $rd).Offenders).Count -ge 1) 'scope: a NetworkService auto service is swept'
    Assert-True (@((Invoke-Sweep -Services @((New-Svc 'ES' '"C:\Svc\evil.exe"' 'Auto' '')) -Reader $rd).Offenders).Count -ge 1) 'scope: an auto service with an empty account name (LocalSystem) is swept'
    Assert-True (@((Invoke-Sweep -Services @((New-Svc 'DL' '"C:\Svc\evil.exe"' 'Delayed')) -Reader $rd).Offenders).Count -ge 1) 'scope: a Delayed-start service is swept'
    # unquoted
    $unq = New-Svc 'Unq' 'C:\Program Files\App One\svc.exe -k grp'
    $ex2 = { param($p) $p -eq 'C:\Program Files\App One\svc.exe' }
    $r = Invoke-Sweep -Services @($unq) -Reader (New-Reader @{}) -Exists $ex2
    Assert-True (@($r.Offenders).Count -eq 0) 'unquoted path with all folders protected: not an offender'
    $r = Invoke-Sweep -Services @($unq) -Reader (New-Reader @{ 'C:\' = (New-FakeAcl -IsDir $true -Aces @((New-FakeAce $System $Full), (New-FakeAce $AuthUsers ([int64]2)))) }) -Exists $ex2
    Assert-True (@($r.Offenders | Where-Object { $_.Kind -eq 'unquoted-path' -and $_.Why -match 'C:\\Program\.exe' }).Count -eq 1) 'UNQUOTED path: a writable C:\ lets C:\Program.exe be planted: an offender naming the candidate'
    $r = Invoke-Sweep -Services @($unq) -Reader (New-Reader @{ 'C:\Program Files' = (New-FakeAcl -IsDir $true -Aces @((New-FakeAce $System $Full), (New-FakeAce $UsersSid ([int64]2)))) }) -Exists $ex2
    Assert-True (@($r.Offenders | Where-Object { $_.Kind -eq 'unquoted-path' -and $_.Why -match 'Program Files\\App\.exe' }).Count -eq 1) 'UNQUOTED path: a plantable C:\Program Files\App.exe is an offender'
    $quo = New-Svc 'Quo' '"C:\Program Files\App One\svc.exe" -k grp'
    $r = Invoke-Sweep -Services @($quo) -Reader (New-Reader @{ 'C:\' = (New-FakeAcl -IsDir $true -Aces @((New-FakeAce $System $Full), (New-FakeAce $AuthUsers ([int64]2)))) }) -Exists $ex2
    Assert-True (@($r.Offenders | Where-Object { $_.Kind -eq 'unquoted-path' }).Count -eq 0) 'the same writable C:\ is not an unquoted-path offender when the path is quoted (toggle)'
    # blind
    $threw = $false; try { Find-CoderWritableBootSurface -ServiceSource { @() } -TaskSource { @($FillerTask) } -AclReader (New-Reader @{}) | Out-Null } catch { $threw = $true }
    Assert-True $threw 'FAIL-CLOSED: an empty service list throws (the sweep is blind)'
    $threw = $false; try { Find-CoderWritableBootSurface -ServiceSource { @($Filler) } -TaskSource { @() } -AclReader (New-Reader @{}) | Out-Null } catch { $threw = $true }
    Assert-True $threw 'FAIL-CLOSED: an empty task list throws (the sweep is blind)'
}

Section 'the sweep: scheduled tasks'
Test-Step 'tasks' {
    $badDir = New-FakeAcl -IsDir $true -Aces @((New-FakeAce $System $Full), (New-FakeAce $AuthUsers $Modify))
    $rd = New-Reader @{ 'C:\Gw\bin' = $badDir }
    $tSys = New-Task 'Watchdog' 'powershell.exe' '-NoProfile -File C:\Gw\bin\wd.ps1'
    $r = Invoke-Sweep -Tasks @($tSys) -Reader $rd
    Assert-True (@($r.Offenders | Where-Object { $_.Name -eq '\Watchdog' -and $_.Path -eq 'C:\Gw\bin' }).Count -eq 1) 'positive control: a SYSTEM task whose -File script sits in a user-writable folder is an offender'
    $r = Invoke-Sweep -Tasks @($tSys) -Reader (New-Reader @{})
    Assert-True (@($r.Offenders).Count -eq 0 -and $r.TasksInScope -eq 1) 'negative control: the same task with a protected folder is not an offender'
    Assert-True (@((Invoke-Sweep -Tasks @((New-Task 'Off' 'powershell.exe' '-File C:\Gw\bin\wd.ps1' -Enabled $false)) -Reader $rd).Offenders).Count -eq 0) 'scope: a DISABLED task is not swept'
    Assert-True (@((Invoke-Sweep -Tasks @((New-Task 'Op' 'powershell.exe' '-File C:\Gw\bin\wd.ps1' -User 'op')) -Reader $rd).Offenders).Count -ge 1) 'scope: a task run by a member of Administrators is swept'
    Assert-True (@((Invoke-Sweep -Tasks @((New-Task 'Std' 'powershell.exe' '-File C:\Gw\bin\wd.ps1' -User 'std')) -Reader $rd).Offenders).Count -eq 0) 'scope: a task run by a non-administrator account is not swept'
    Assert-True (@((Invoke-Sweep -Tasks @((New-Task 'Adm' 'powershell.exe' '-File C:\Gw\bin\wd.ps1' -User '' -Group 'Administrators')) -Reader $rd).Offenders).Count -ge 1) 'scope: a task whose principal is the Administrators group is swept'
    Assert-True (@((Invoke-Sweep -Tasks @((New-Task 'Usr' 'powershell.exe' '-File C:\Gw\bin\wd.ps1' -User '' -Group 'Users')) -Reader $rd).Offenders).Count -eq 0) 'scope: a task whose principal is the Users group is not swept'
    Assert-True (@((Invoke-Sweep -Tasks @((New-Task 'Unk' 'powershell.exe' '-File C:\Gw\bin\wd.ps1' -User 'nobody-resolves')) -Reader $rd).Offenders).Count -ge 1) 'FAIL-CLOSED: a task whose principal cannot be resolved is swept as privileged'
    Assert-True (@((Invoke-Sweep -Tasks @((New-Task 'LS' 'powershell.exe' '-File C:\Gw\bin\wd.ps1' -User 'LOCAL SERVICE')) -Reader $rd).Offenders).Count -ge 1) 'scope: a LocalService task is swept'
    $r = Invoke-Sweep -Tasks @((New-Task 'Op2' 'powershell.exe' '-File C:\Gw\bin\wd.ps1' -User 'op')) -Reader $rd -Admin { throw 'cannot read the group' }
    Assert-True (@($r.Offenders).Count -ge 1 -and @($r.Errors).Count -eq 1) 'FAIL-CLOSED: when the Administrators membership cannot be read, the error is reported and the principal is treated as privileged'
    $r = Invoke-Sweep -Tasks @((New-Task 'Std2' 'powershell.exe' '-File C:\Gw\bin\wd.ps1' -User 'std')) -Reader $rd -Admin { throw 'cannot read the group' }
    Assert-True (@($r.Offenders).Count -ge 1) 'FAIL-CLOSED: with an unreadable membership list even a plain user task is swept'
    # the executable itself
    $r = Invoke-Sweep -Tasks @((New-Task 'Exe' 'C:\Gw\bin\tool.exe')) -Reader $rd
    Assert-True (@($r.Offenders | Where-Object { $_.Path -eq 'C:\Gw\bin' }).Count -eq 1) 'the task executable is judged too (its folder)'
    # script that does not exist yet: the folder decides
    $rd2 = New-Reader @{ 'C:\Gw\bin' = $badDir; 'C:\Gw\bin\wd.ps1' = @{ Exists = $false; IsDir = $false; Owner = ''; Aces = @(); Error = '' } }
    $r = Invoke-Sweep -Tasks @($tSys) -Reader $rd2
    Assert-True (@($r.Offenders | Where-Object { $_.Why -match 'does not exist' }).Count -eq 1) 'a named script that does not exist is still a plant point: the writable folder is an offender'
    # script file itself writable in a protected folder
    $r = Invoke-Sweep -Tasks @($tSys) -Reader (New-Reader @{ 'C:\Gw\bin\wd.ps1' = (New-FakeAcl -Aces @((New-FakeAce $System $Full), (New-FakeAce $UsersSid $Modify))) })
    Assert-True (@($r.Offenders | Where-Object { $_.Path -eq 'C:\Gw\bin\wd.ps1' }).Count -eq 1) 'a user-writable script file in a protected folder is an offender'
    # bare command
    $r = Invoke-Sweep -Tasks @((New-Task 'Bare' 'cmd.exe' '/c echo hi')) -Reader (New-Reader @{}) -Cmd { param($n) 'C:\Windows\System32\cmd.exe' }
    Assert-True (@($r.Offenders).Count -eq 0) 'a bare command name resolves through the resolver and is judged'
    $r = Invoke-Sweep -Tasks @((New-Task 'Bare2' 'nothing.exe')) -Reader (New-Reader @{}) -Cmd { param($n) '' }
    Assert-True (@($r.Offenders | Where-Object { $_.Kind -eq 'unresolved-path' }).Count -eq 1) 'FAIL-CLOSED: a bare command that cannot be resolved is an offender of kind unresolved-path'
}

Section 'the sweep: real access lists on a TEMP tree (positive and negative controls, inherit-only, toggle)'
$tmp = Join-Path ([IO.Path]::GetTempPath()) ('bootsurf-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
try {
    New-Item -ItemType Directory $tmp | Out-Null
    $me = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
    $sweepReal = {
        param([string]$Exe)
        $svcs = @((New-Svc 'TempSvc' "`"$Exe`""), $Filler); $tsk = @($FillerTask)
        Find-CoderWritableBootSurface -ServiceSource { $svcs }.GetNewClosure() -TaskSource { $tsk }.GetNewClosure() -AdminMemberSids { @() } -SidResolver $Resolver
    }
    function Mk-Svc([string]$Name) { $d = Join-Path $tmp $Name; New-Item -ItemType Directory $d | Out-Null; $f = Join-Path $d 'svc.exe'; Set-Content -LiteralPath $f 'x'; return @{ Dir = $d; Exe = $f } }
    Test-Step 'real-negative' {
        $s = Mk-Svc 'neg'
        $r = & $sweepReal $s.Exe
        Assert-True (@($r.Offenders | Where-Object { $_.Path -like "$tmp*" }).Count -eq 0) 'negative control (real ACLs): an untouched temp folder and file are not offenders'
    }
    Test-Step 'real-positive' {
        $s = Mk-Svc 'pos'
        & icacls $s.Dir /grant '*S-1-5-11:(OI)(CI)M' | Out-Null
        $r = & $sweepReal $s.Exe
        Assert-True (@($r.Offenders | Where-Object { $_.Path -eq $s.Dir }).Count -eq 1 -and @($r.Offenders | Where-Object { $_.Path -eq $s.Exe }).Count -eq 1) 'positive control (real ACLs): Authenticated Users Modify, inherited to the file, flags the folder AND the file'
        & icacls $s.Dir /remove:g '*S-1-5-11' | Out-Null
        & icacls $s.Exe /remove:g '*S-1-5-11' | Out-Null
        $r2 = & $sweepReal $s.Exe
        Assert-True (@($r2.Offenders | Where-Object { $_.Path -like "$tmp*" }).Count -eq 0) 'toggle (real ACLs): removing the grant clears the finding'
    }
    Test-Step 'real-inherit-only' {
        $s = Mk-Svc 'io'
        & icacls $s.Exe /inheritance:r | Out-Null
        & icacls $s.Exe /grant "*${me}:F" '*S-1-5-18:F' | Out-Null
        & icacls $s.Dir /grant '*S-1-5-11:(OI)(IO)M' | Out-Null
        $a = Read-BootAcl -Path $s.Dir
        Assert-True (@($a.Aces | Where-Object { $_.Sid -eq 'S-1-5-11' -and $_.InheritOnly }).Count -ge 1) 'the real reader reports the (OI)(IO) entry as inherit-only'
        $r = & $sweepReal $s.Exe
        Assert-True (@($r.Offenders | Where-Object { $_.Path -like "$tmp*" }).Count -eq 0) 'real INHERIT-ONLY Modify on the folder, file protected from inheritance: the folder is not flagged (it does not apply to it)'
        & icacls $s.Dir /grant '*S-1-5-11:(OI)(CI)M' | Out-Null
        $r = & $sweepReal $s.Exe
        Assert-True (@($r.Offenders | Where-Object { $_.Path -eq $s.Dir }).Count -eq 1) 'toggle: making the same entry apply to the folder flags it'
    }
    Test-Step 'real-owner' {
        $s = Mk-Svc 'own'
        $coderStandIn = $me
        $svcs = @((New-Svc 'TempSvc' "`"$($s.Exe)`""), $Filler); $tsk = @($FillerTask)
        $r = Find-CoderWritableBootSurface -CoderSid $coderStandIn -ServiceSource { $svcs }.GetNewClosure() -TaskSource { $tsk }.GetNewClosure() -AdminMemberSids { @() } -SidResolver $Resolver
        Assert-True (@($r.Offenders | Where-Object { $_.Path -like "$tmp*" }).Count -ge 1) 'real ACLs: with the current user standing in for the coder (it owns and can write the temp folder), the temp item is an offender'
        $r = Find-CoderWritableBootSurface -ServiceSource { $svcs }.GetNewClosure() -TaskSource { $tsk }.GetNewClosure() -AdminMemberSids { @() } -SidResolver $Resolver
        Assert-True (@($r.Offenders | Where-Object { $_.Path -like "$tmp*" }).Count -eq 0) 'toggle: without the stand-in the same temp item is clean'
    }
    Test-Step 'real-addsub' {
        $s = Mk-Svc 'addsub'
        & icacls $s.Dir /grant '*S-1-5-11:(AD)' | Out-Null
        $r = & $sweepReal $s.Exe
        Assert-True (@($r.Offenders | Where-Object { $_.Path -eq $s.Dir }).Count -eq 1) 'real ACLs: add-subdirectory only, on the exe''s own folder, is an offender'
        & icacls $s.Dir /remove:g '*S-1-5-11' | Out-Null
        $r = & $sweepReal $s.Exe
        Assert-True (@($r.Offenders | Where-Object { $_.Path -like "$tmp*" }).Count -eq 0) 'toggle (real ACLs): removing it clears the finding'
    }
} finally { Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue }

Section 'review round: ghost folders, working folders, named admin services, arguments, errors'
Test-Step 'review' {
    $gone = @{ Exists = $false; IsDir = $false; Owner = ''; Aces = @(); Error = '' }
    $rootAD = New-FakeAcl -IsDir $true -Aces @((New-FakeAce $System $Full), (New-FakeAce $AuthUsers ([int64]4)))
    $ghostTable = @{ 'C:\gone\svc.exe' = $gone; 'C:\gone' = $gone; 'C:\gone\x.ps1' = $gone; 'C:\' = $rootAD }
    $r = Invoke-Sweep -Services @((New-Svc 'Ghost' '"C:\gone\svc.exe"')) -Reader (New-Reader $ghostTable)
    Assert-True (@($r.Offenders | Where-Object { $_.Path -eq 'C:\' -and $_.Why -match 'can be created' }).Count -ge 1) 'GHOST service: file and folder missing, and users may create folders in the nearest existing one (C:\): an offender'
    $clean = @{ 'C:\gone\svc.exe' = $gone; 'C:\gone' = $gone }
    Assert-True (@((Invoke-Sweep -Services @((New-Svc 'Ghost' '"C:\gone\svc.exe"')) -Reader (New-Reader $clean)).Offenders).Count -eq 0) 'GHOST service with a protected nearest folder: not an offender (toggle)'
    $r = Invoke-Sweep -Tasks @((New-Task 'GhostT' 'powershell.exe' '-File C:\gone\x.ps1')) -Reader (New-Reader $ghostTable)
    Assert-True (@($r.Offenders | Where-Object { $_.Path -eq 'C:\' -and $_.Name -eq '\GhostT' }).Count -ge 1) 'GHOST task script: the same'
    $r = Invoke-Sweep -Services @((New-Svc 'Ghost2' '"C:\gone\svc.exe"')) -Reader { param($p) $gone }
    Assert-True (@($r.Offenders | Where-Object { $_.Kind -eq 'unresolved-path' }).Count -ge 1) 'GHOST with no existing folder anywhere above: unresolved-path offender (never silent)'

    $wdBad = New-FakeAcl -IsDir $true -Aces @((New-FakeAce $System $Full), (New-FakeAce $UsersSid ([int64]2)))
    $rdW = New-Reader @{ 'C:\Work' = $wdBad }
    $cmdExe = 'C:\Windows\System32\cmd.exe'
    Assert-True (@((Invoke-Sweep -Tasks @((New-Task 'W1' $cmdExe '/c run.cmd' -Wd 'C:\Work')) -Reader $rdW).Offenders | Where-Object { $_.Path -eq 'C:\Work' }).Count -ge 1) 'WORKING FOLDER: cmd.exe /c run.cmd from a user-writable folder: an offender'
    Assert-True (@((Invoke-Sweep -Tasks @((New-Task 'W2' 'powershell.exe' '-Command "Start-Process task.bat"' -Wd 'C:\Work')) -Reader $rdW).Offenders | Where-Object { $_.Path -eq 'C:\Work' }).Count -ge 1) 'WORKING FOLDER: powershell -Command "Start-Process task.bat": an offender'
    Assert-True (@((Invoke-Sweep -Tasks @((New-Task 'W3' 'C:\Python\python.exe' '-m mod' -Wd 'C:\Work')) -Reader $rdW).Offenders | Where-Object { $_.Path -eq 'C:\Work' }).Count -ge 1) 'WORKING FOLDER: python -m module with an absolute exe: an offender (interpreter)'
    Assert-True (@((Invoke-Sweep -Tasks @((New-Task 'W4' 'C:\Tools\foo.exe' '--flag' -Wd 'C:\Work')) -Reader $rdW).Offenders).Count -eq 0) 'WORKING FOLDER: a plain program with only switches does not depend on it: not an offender'
    Assert-True (@((Invoke-Sweep -Tasks @((New-Task 'W5' $cmdExe '/c run.cmd' -Wd 'C:\Work')) -Reader (New-Reader @{})).Offenders).Count -eq 0) 'WORKING FOLDER protected: not an offender (toggle)'
    $rdS = New-Reader @{ 'C:\Work\run.cmd' = (New-FakeAcl -Aces @((New-FakeAce $System $Full), (New-FakeAce $UsersSid $Modify))) }
    Assert-True (@((Invoke-Sweep -Tasks @((New-Task 'W6' $cmdExe '/c run.cmd' -Wd 'C:\Work')) -Reader $rdS).Offenders | Where-Object { $_.Path -eq 'C:\Work\run.cmd' }).Count -eq 1) 'the relative script itself is judged against the working folder'
    Assert-True (Test-BootWorkingDirMatters -Execute 'C:\x\cmd.exe' -Arguments '') 'pure: an interpreter always depends on the working folder'
    Assert-True (-not (Test-BootWorkingDirMatters -Execute 'C:\x\foo.exe' -Arguments '/silent --x C:\abs\file.cfg')) 'pure: switches and absolute paths do not'
    Assert-True (Test-BootWorkingDirMatters -Execute 'C:\x\foo.exe' -Arguments 'job.ps1') 'pure: a relative script word does'
    Assert-True (-not (Test-BootWorkingDirMatters -Execute 'C:\x\foo.exe' -Arguments 'S-1-5-21-1 308046B0' -WorkingDirectory 'C:\Work' -Exists { param($f) $false })) 'pure: relative words that name nothing in the working folder do not (an id on a command line)'
    Assert-True (Test-BootWorkingDirMatters -Execute 'C:\x\foo.exe' -Arguments 'settings.ini' -WorkingDirectory 'C:\Work' -Exists { param($f) $f -eq 'C:\Work\settings.ini' }) 'pure: a relative word that names a file there does'
    # a folder named in the arguments is data; the normal drive root (users may create folders) is not a plant point for a file in it
    $rootAppend = New-FakeAcl -IsDir $true -Aces @((New-FakeAce $System $Full), (New-FakeAce $AuthUsers ([int64]4)))
    $dirTable = @{ 'C:\app' = (New-FakeAcl -IsDir $true -Aces @((New-FakeAce $System $Full))); 'C:\' = $rootAppend }
    Assert-True (@((Invoke-Sweep -Tasks @((New-Task 'DirArg' 'C:\Tools\foo.exe' '-p C:\app')) -Reader (New-Reader $dirTable)).Offenders).Count -eq 0) 'a folder named in the arguments is not judged as code; users creating sub-folders at the drive root is not a finding'
    Assert-True (@((Invoke-Sweep -Services @((New-Svc 'RootSvc' '"C:\svc.exe"')) -Reader (New-Reader $dirTable)).Offenders | Where-Object { $_.Path -eq 'C:\' }).Count -eq 1) 'an exe directly in C:\ where users may create sub-folders IS a finding (a svc.exe.local folder beside it redirects its DLL loads)'
    # P1: the program's OWN folder grants only add-subdirectory: flagged. The same right on an ANCESTOR is not.
    $subOnly = New-FakeAcl -IsDir $true -Aces @((New-FakeAce $System $Full), (New-FakeAce $UsersSid ([int64]4)))
    $r = Invoke-Sweep -Services @((New-Svc 'P1' '"C:\Svc\evil.exe"')) -Reader (New-Reader @{ 'C:\Svc' = $subOnly })
    Assert-True (@($r.Offenders | Where-Object { $_.Path -eq 'C:\Svc' }).Count -eq 1) 'P1: a service exe whose own folder grants Users only add-subdirectory is an offender (DotLocal redirect)'
    $r = Invoke-Sweep -Tasks @((New-Task 'P1c' 'powershell.exe' '-File C:\Tools\job.ps1')) -Reader (New-Reader @{ 'C:\Tools' = $subOnly; 'C:\Tools\job.ps1' = (New-FakeAcl -Aces @((New-FakeAce $System $Full))) })
    Assert-True (@($r.Offenders | Where-Object { $_.Path -eq 'C:\Tools' }).Count -eq 1) 'P1c: a task script whose own folder grants only add-subdirectory is an offender'
    $attrOnly = New-FakeAcl -IsDir $true -Aces @((New-FakeAce $System $Full), (New-FakeAce $UsersSid ([int64](16 + 256))))
    $r = Invoke-Sweep -Services @((New-Svc 'P1d' '"C:\Svc\evil.exe"')) -Reader (New-Reader @{ 'C:\Svc' = $attrOnly })
    Assert-True (@($r.Offenders).Count -eq 0) 'a program folder where Users may only write attributes and extended attributes is not an offender (they cannot add or replace anything)'
    $r = Invoke-Sweep -Services @((New-Svc 'P1a' '"C:\Svc\evil.exe"')) -Reader (New-Reader @{ 'C:\' = $subOnly })
    Assert-True (@($r.Offenders).Count -eq 0) 'an ANCESTOR (C:\) with only add-subdirectory is not an offender'
    foreach ($ip in 'python3.exe', 'python3.11.exe', 'python.exe', 'pythonw.exe', 'py.exe', 'pyw.exe', 'dotnet.exe', 'msbuild.exe', 'php.exe', 'java.exe', 'javaw.exe', 'ruby.exe', 'perl.exe', 'mshta.exe', 'rundll32.exe', 'wscript.exe', 'cscript.exe', 'node.exe', 'bash.exe', 'sh.exe', 'cmd.exe', 'powershell.exe', 'pwsh.exe', 'wsl.exe') {
        Assert-True (Test-BootWorkingDirMatters -Execute "C:\x\$ip" -Arguments '') "interpreter list: $ip depends on the working folder"
    }
    foreach ($np in 'notepad.exe', 'pythonista.exe', 'dotnetfoo.exe') { Assert-True (-not (Test-BootWorkingDirMatters -Execute "C:\x\$np" -Arguments '')) "interpreter list: $np is not an interpreter" }
    # ---- parser differentials: shapes the Windows command-line parsers accept
    $bt = [string][char]96
    $shapes = @(
        @{ N = 'cmd caret escape in the path';       X = 'cmd.exe';        A = '/c C:\drop\ru^n.cmd';                       W = 'C:\drop\run.cmd' },
        @{ N = 'cmd caret-escaped quotes';           X = 'cmd.exe';        A = '/c ^"C:\a b\run.cmd^"';                      W = 'C:\a b\run.cmd' },
        @{ N = 'cmd outer quote pair (doubled quotes)'; X = 'cmd.exe';     A = '/c ""C:\a b\run.cmd" arg"';                  W = 'C:\a b\run.cmd' },
        @{ N = 'doubled quotes around a path';       X = 'cmd.exe';        A = '/c ""C:\drop\run.cmd""';                     W = 'C:\drop\run.cmd' },
        @{ N = 'powershell backtick-space in a path'; X = 'powershell.exe'; A = ('-Command C:\Program' + $bt + ' Files\x\run.ps1'); W = 'C:\Program Files\x\run.ps1' },
        @{ N = 'powershell backtick-escaped quotes'; X = 'powershell.exe'; A = ('-Command & ' + $bt + '"C:\a b\run.ps1' + $bt + '"'); W = 'C:\a b\run.ps1' },
        @{ N = '%COMSPEC% in Execute';               X = '%COMSPEC%';      A = '/c C:\drop\run.cmd';                         W = 'C:\drop\run.cmd' },
        @{ N = '%SystemRoot% in Arguments';          X = 'cmd.exe';        A = '/c %SystemRoot%\Temp\x.cmd';                 W = ($env:SystemRoot + '\Temp\x.cmd') },
        @{ N = '$env:NAME in a PowerShell command';  X = 'powershell.exe'; A = '-Command & $env:SystemRoot\Temp\x.ps1';       W = ($env:SystemRoot + '\Temp\x.ps1') },
        @{ N = 'trailing dot on a script';           X = 'cmd.exe';        A = '/c C:\drop\run.cmd.';                        W = 'C:\drop\run.cmd' },
        @{ N = 'trailing space inside quotes';       X = 'cmd.exe';        A = '/c "C:\drop\run.cmd "';                      W = 'C:\drop\run.cmd' },
        @{ N = 'forward slashes in a command word';  X = 'cmd.exe';        A = '/c C:/drop/run.cmd';                         W = 'C:\drop\run.cmd' },
        @{ N = 'forward slashes after -File';        X = 'powershell.exe'; A = '-File C:/drop/run.ps1';                      W = 'C:\drop\run.ps1' },
        @{ N = 'forward-slash UNC script';           X = 'cmd.exe';        A = '/c //srv/share/run.cmd';                     W = '\\srv\share\run.cmd' },
        @{ N = 'doubled quotes around a spaced path'; X = 'cmd.exe'; A = '/c ""C:\a b\run.cmd""'; W = 'C:\a b\run.cmd' },
        @{ N = 'trailing dot on a -File script'; X = 'powershell.exe'; A = '-File C:\drop\run.ps1.'; W = 'C:\drop\run.ps1' },
        @{ N = 'trailing dot inside a command string'; X = 'powershell.exe'; A = '-Command "Start-Process C:\drop\run.cmd."'; W = 'C:\drop\run.cmd' },
        @{ N = 'cmd outer quotes around a command line'; X = 'cmd.exe'; A = '/c "ping x & "C:\a b\run.cmd" arg"'; W = 'C:\a b\run.cmd' },
        @{ N = 'doubled quotes after -File'; X = 'powershell.exe'; A = '-File ""C:\a b\run.ps1""'; W = 'C:\a b\run.ps1' },
        @{ N = 'trailing dot on a non-command word'; X = 'cmd.exe'; A = '/c "echo C:\drop\run.cmd."'; W = 'C:\drop\run.cmd' },
        @{ N = 'rundll32 dll,entry'; X = 'rundll32.exe'; A = 'C:\drop\run.dll,Entry'; W = 'C:\drop\run.dll' },
        @{ N = 'rundll32 dll,#ordinal'; X = 'rundll32.exe'; A = 'C:\drop\run.dll,#12'; W = 'C:\drop\run.dll' },
        @{ N = 'rundll32 quoted dll with spaces,entry'; X = 'rundll32.exe'; A = '"C:\a b\x.dll",Entry'; W = 'C:\a b\x.dll' },
        @{ N = 'rundll32 dll,entry then an argument'; X = 'rundll32.exe'; A = 'C:\drop\run.dll,Entry arg1'; W = 'C:\drop\run.dll' },
        @{ N = 'rundll32 through cmd /c'; X = 'cmd.exe'; A = '/c rundll32 C:\drop\run.dll,Entry'; W = 'C:\drop\run.dll' },
        @{ N = 'quoted -File with a space';          X = 'powershell.exe'; A = '-File "C:\a b\run.ps1"';                     W = 'C:\a b\run.ps1' },
        @{ N = '-File: colon form with a space';     X = 'powershell.exe'; A = '-File:"C:\a b\run.ps1"';                     W = 'C:\a b\run.ps1' },
        @{ N = 'single-quoted path inside a script block'; X = 'powershell.exe'; A = '-Command "& { . ''C:\a b\run.ps1'' }"'; W = 'C:\a b\run.ps1' }
    )
    foreach ($sh in $shapes) {
        $got = @(Get-BootActionPaths -Execute $sh.X -Arguments $sh.A)
        Assert-True (@($got | Where-Object { $_.Path -match '[. ]$' }).Count -eq 0) "parser: $($sh.N): no returned path keeps a trailing dot or space"
        Assert-True (@($got | Where-Object { $_.Path -ieq $sh.W }).Count -ge 1) "parser: $($sh.N): found $($sh.W) (got: $(($got | ForEach-Object { $_.Path }) -join ' | '))"
    }
    $g = @(Get-BootActionPaths -Execute 'C:\Windows\System32\cmd.exe.' -Arguments '')
    Assert-True ($g[0].Path -eq 'C:\Windows\System32\cmd.exe') 'parser: a trailing dot on the program is dropped (Win32 ignores it)'
    Assert-True (Test-BootWorkingDirMatters -Execute 'C:\Windows\System32\cmd.exe.' -Arguments '') 'parser: cmd.exe. (trailing dot) is still an interpreter'
    Assert-True (Test-BootWorkingDirMatters -Execute '%COMSPEC%' -Arguments '') 'parser: %COMSPEC% is an interpreter'
    Assert-True (Test-BootWorkingDirMatters -Execute 'C:/Windows/System32/cmd.exe' -Arguments '') 'parser: a forward-slash program path is an interpreter'
    $fakeLong = { param($p) $p.Replace('POWERS~1', 'powershell').Replace('WINDOW~1', 'WindowsPowerShell') }
    Assert-True (Test-BootWorkingDirMatters -Execute 'C:\Windows\System32\WINDOW~1\v1.0\POWERS~1.exe' -Arguments '' -LongName $fakeLong) 'parser: an 8.3 short name of an interpreter is resolved to the long name'
    $g = @(Get-BootActionPaths -Execute 'C:\Windows\System32\WINDOW~1\v1.0\POWERS~1.exe' -Arguments '' -LongName $fakeLong)
    Assert-True ($g[0].Path -eq 'C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe') 'parser: the executable path is the long name'
    Assert-True ((Get-BootLongName -Path 'C:\Windows') -eq 'C:\Windows' -and (Get-BootLongName -Path 'C:\PROGRA~1') -match 'Program Files') 'parser: the real GetLongPathName resolves C:\PROGRA~1'
    # integrated: the sweep reaches the file through each shape
    $badFile = New-FakeAcl -Aces @((New-FakeAce $System $Full), (New-FakeAce $AuthUsers $Modify))
    $tbl = @{ 'C:\drop\run.cmd' = $badFile; 'C:\Svc\evil.exe' = $badFile }
    $r = Invoke-Sweep -Tasks @((New-Task 'Mix' '%COMSPEC%' '/c C:/drop/ru^n.cmd.')) -Reader (New-Reader $tbl)
    Assert-True (@($r.Offenders | Where-Object { $_.Path -eq 'C:\drop\run.cmd' }).Count -ge 1) 'integrated: %COMSPEC% /c C:/drop/ru^n.cmd. reaches C:\drop\run.cmd'
    $r = Invoke-Sweep -Services @((New-Svc 'Fwd' '"C:/Svc/evil.exe"')) -Reader (New-Reader $tbl)
    Assert-True (@($r.Offenders | Where-Object { $_.Path -eq 'C:\Svc\evil.exe' }).Count -ge 1) 'integrated: a forward-slash service path reaches the file'
    $dllBad = New-FakeAcl -Aces @((New-FakeAce $System $Full), (New-FakeAce $AuthUsers $Modify))
    $r = Invoke-Sweep -Tasks @((New-Task 'Dll' 'rundll32.exe' 'C:\drop\run.dll,Entry')) -Reader (New-Reader @{ 'C:\drop\run.dll' = $dllBad }) -Cmd { param($n) 'C:\Windows\System32\rundll32.exe' }
    Assert-True (@($r.Offenders | Where-Object { $_.Path -eq 'C:\drop\run.dll' }).Count -ge 1) 'a coder-writable DLL named in the comma form (rundll32 x.dll,Entry) is an offender'
    $r = Invoke-Sweep -Tasks @((New-Task 'DllQ' 'rundll32.exe' '"C:\a b\x.dll",Entry arg')) -Reader (New-Reader @{ 'C:\a b\x.dll' = $dllBad }) -Cmd { param($n) 'C:\Windows\System32\rundll32.exe' }
    Assert-True (@($r.Offenders | Where-Object { $_.Path -eq 'C:\a b\x.dll' }).Count -ge 1) 'the same for a quoted DLL path with spaces and a trailing argument'
    $r = Invoke-Sweep -Tasks @((New-Task 'DllSys' 'rundll32.exe' 'C:\Windows\System32\shell32.dll,Control_RunDLL')) -Reader (New-Reader @{}) -Cmd { param($n) 'C:\Windows\System32\rundll32.exe' }
    Assert-True (@($r.Offenders).Count -eq 0) 'a protected System32 DLL in the comma form stays clean'
    foreach ($form in '/c start "" C:\drop\run', '/c start "My Title" C:\drop\run', '/c start C:\drop\run') {
        $a = @(Get-BootActionPaths -Execute $cmdExe -Arguments $form)
        Assert-True (@($a | Where-Object { $_.Path -eq 'C:\drop\run' }).Count -eq 1) "cmd start form is parsed to its command: $form"
    }

    $bad = New-FakeAcl -Aces @((New-FakeAce $System $Full), (New-FakeAce $AuthUsers $Modify))
    $rdE = New-Reader @{ 'C:\Svc\evil.exe' = $bad }
    Assert-True (@((Invoke-Sweep -Services @((New-Svc 'AdmSvc' '"C:\Svc\evil.exe"' 'Auto' 'op')) -Reader $rdE).Offenders).Count -ge 1) 'NAMED ADMIN service: an Auto service running as an Administrators member is swept'
    Assert-True (@((Invoke-Sweep -Services @((New-Svc 'StdSvc' '"C:\Svc\evil.exe"' 'Auto' 'std')) -Reader $rdE).Offenders).Count -eq 0) 'a named NON-admin service account is not swept'
    Assert-True (@((Invoke-Sweep -Services @((New-Svc 'StdSvc' '"C:\Svc\evil.exe"' 'Auto' 'std')) -Reader $rdE -Admin { throw 'no group' }).Offenders).Count -ge 1) 'FAIL-CLOSED: with the Administrators list unreadable a named service account is swept'
    Assert-True (@((Invoke-Sweep -Services @((New-Svc 'NoSvc' '"C:\Svc\evil.exe"' 'Auto' 'nobody-resolves')) -Reader $rdE).Offenders).Count -ge 1) 'FAIL-CLOSED: a named service account that cannot be resolved is swept'

    $rdD = New-Reader @{ 'C:\drop\start.cmd' = $bad; 'C:\drop\run' = $bad; 'C:\drop\out.cmd' = $bad }
    Assert-True (@((Invoke-Sweep -Services @((New-Svc 'ArgSvc' '"C:\Windows\System32\cmd.exe" /c C:\drop\start.cmd')) -Reader $rdD).Offenders | Where-Object { $_.Path -eq 'C:\drop\start.cmd' }).Count -ge 1) 'SERVICE ARGUMENTS: a script named in the image path arguments is judged'
    Assert-True (@((Invoke-Sweep -Services @((New-Svc 'ArgSvc2' '"C:\Windows\System32\cmd.exe" /c C:\drop\run')) -Reader $rdD).Offenders | Where-Object { $_.Path -eq 'C:\drop\run' }).Count -ge 1) 'ARGUMENTS: a command word without a script extension (cmd /c C:\drop\run) is judged'
    Assert-True (@((Invoke-Sweep -Tasks @((New-Task 'RedirT' $cmdExe '/c echo hi > C:\drop\out.cmd')) -Reader $rdD).Offenders | Where-Object { $_.Path -eq 'C:\drop\out.cmd' }).Count -eq 0) 'a redirect target is output, not code: not judged'
    $ffDir = New-FakeAcl -IsDir $true -Aces @((New-FakeAce $System $Full), (New-FakeAce $UsersSid $Full))
    $ffTable = @{ 'C:\Data' = $ffDir; 'C:\Data\updates' = $ffDir; 'C:\Data\updates\bgtask' = $ffDir; 'C:\Data\updates\log.moz_log' = (New-FakeAcl -Aces @((New-FakeAce $UsersSid $Full))) }
    $ffTask = New-Task 'Firefox' 'C:\Program Files\Mozilla Firefox\firefox.exe' '--MOZ_LOG sync,append --MOZ_LOG_FILE C:\Data\updates\log.moz_log --backgroundtask bgtask' -User 'op' -Wd 'C:\Data\updates'
    $ffTable['C:\Data\updates\sync,append'] =@{ Exists = $false; IsDir = $false; Owner = ''; Aces = @(); Error = '' }
    Assert-True (@((Invoke-Sweep -Tasks @($ffTask) -Reader (New-Reader $ffTable)).Offenders).Count -eq 0) 'a data path after a switch (--MOZ_LOG_FILE x) and a relative word that is a FOLDER in the working folder are not code: a browser background task is not a finding'
    $a = @(Get-BootActionPaths -Execute 'powershell.exe' -Arguments '-File job.dat' -WorkingDirectory 'C:\Work')
    Assert-True (@($a | Where-Object { $_.Path -eq 'C:\Work\job.dat' -and $_.Role -eq 'script' }).Count -eq 1) 'pure: -File <anything> is a script, resolved against the working folder'
    $rootCreate = New-FakeAcl -IsDir $true -Aces @((New-FakeAce $System $Full), (New-FakeAce $AuthUsers ([int64]2)))
    $dirTable2 = @{ 'C:\app' = (New-FakeAcl -IsDir $true -Aces @((New-FakeAce $System $Full))); 'C:\' = $rootCreate }
    Assert-True (@((Invoke-Sweep -Tasks @((New-Task 'DirArg2' $cmdExe '/c C:\app')) -Reader (New-Reader $dirTable2)).Offenders).Count -eq 0) 'a folder named as the command word is data: its parent being writable does not make it an offender'
    $a = @(Get-BootActionPaths -Execute $cmdExe -Arguments '/c C:\drop\run')
    Assert-True (@($a | Where-Object { $_.Path -eq 'C:\drop\run' }).Count -eq 1) 'pure: the command word is found'
    $a = @(Get-BootActionPaths -Execute 'powershell.exe' -Arguments '-Command "Start-Process task.bat"' -WorkingDirectory 'C:\Work')
    Assert-True (@($a | Where-Object { $_.Path -eq 'C:\Work\task.bat' }).Count -eq 1) 'pure: a relative script word inside -Command resolves against the working folder'

    $v = Get-BootSurfaceVerdict -Result @{ Complete = $true; ServicesEnumerated = 5; TasksEnumerated = 5; ServicesInScope = 1; TasksInScope = 1; Offenders = @(); Errors = @('Administrators group members could not be read (x)') }
    Assert-True ((-not $v.Pass) -and $v.Detail -match 'could not be read') 'verdict: an error in the result FAILS it and the text is shown'
    $r = Invoke-Sweep -Services @((New-Svc 'Evil' '"C:\Svc\evil.exe"')) -Reader (New-Reader @{}) -Admin { throw 'no group' }
    Assert-True ((-not (Get-BootSurfaceVerdict -Result $r).Pass) -and @($r.Errors).Count -eq 1) 'a real sweep whose Administrators lookup failed has an error and does not pass'
    Assert-True ((Get-BootSurfaceVerdict -Result (Invoke-Sweep -Services @((New-Svc 'Evil' '"C:\Svc\evil.exe"')) -Reader (New-Reader @{}))).Pass) 'the same sweep without the failure passes (toggle)'
}

Section 'the sweep against the real machine (read-only smoke: completes and enumerates; findings are printed, not asserted)'
Test-Step 'smoke' {
    $r = Find-CoderWritableBootSurface
    Assert-True ($r.Complete -and $r.ServicesEnumerated -gt 0 -and $r.TasksEnumerated -gt 0) "the real sweep completed: $($r.ServicesEnumerated) services ($($r.ServicesInScope) in scope), $($r.TasksEnumerated) tasks ($($r.TasksInScope) in scope), $(@($r.Offenders).Count) offender(s), $(@($r.Errors).Count) error(s)"
    foreach ($o in @($r.Offenders | Select-Object -First 10)) { Write-Host "         finding: $($o.Kind) $($o.Name) [$($o.RunAs)] $($o.Path) - $($o.Why)" -ForegroundColor DarkYellow }
}

Section 'wiring: verify-coder-containment.ps1 runs the sweep as a hard-required check in both modes; the off path never loads it'
Test-Step 'wiring' {
    $vt = [IO.File]::ReadAllText((Join-Path $PSScriptRoot 'verify-coder-containment.ps1'))
    Assert-True ($vt -match [regex]::Escape('. "$PSScriptRoot\coder-boot-surface-lib.ps1"')) 'verify-coder-containment.ps1 loads the library'
    Assert-True ($vt -match '\$boot = Find-CoderWritableBootSurface -CoderSid \$expectedSid -GroupSids' -and $vt -match 'Get-BootSurfaceVerdict -Result \$boot -ErrorText \$bootError') 'it runs the sweep and decides through the pure verdict (an absent result fails)'
    Assert-True ($vt -match [regex]::Escape('$setupFailed = @($setupFailed) + @($bootVerdict.Failed)')) 'a failed boot-surface check joins the failures that fail the run'
    Assert-True ($vt -match 'check25-no-coder-writable-boot-surface') 'the check prints under its name'
    $swallow = [regex]::Match($vt, '(?s)\$boot = \$null; \$bootError = .*?\$bootVerdict = Get-BootSurfaceVerdict').Value
    Assert-True ($swallow -match 'catch \{ \$bootError = \$_\.Exception\.Message \}' -and $swallow -notmatch '\$boot = @\{') 'a thrown sweep leaves NO result (the error text only), so the verdict fails'
    $skipIdx = $vt.IndexOf('if ($SkipNarrowing')
    $bootIdx = $vt.IndexOf('Find-CoderWritableBootSurface')
    Assert-True ($bootIdx -gt 0 -and -not ($vt.Substring($bootIdx - 200, 200) -match 'SkipNarrowing')) 'the check does not sit behind -SkipNarrowing (hard-required in both modes)'
    foreach ($f in 'fleet-lib.ps1', 'coder-leg-queue.ps1', 'coder-leg-run.ps1', 'new-agent-task.ps1', 'run-fleet.ps1', 'critic-run.ps1') {
        $p = Join-Path $PSScriptRoot $f
        if (-not (Test-Path $p)) { continue }
        Assert-True (-not ([IO.File]::ReadAllText($p) -match 'coder-boot-surface-lib')) "$f (loaded on the containment=off path) never names the boot-surface library"
    }
}

Write-Host ''
if ($script:Fail -eq 0) { Write-Host "RESULT: $($script:Pass) passed, 0 failed" -ForegroundColor Green; exit 0 }
Write-Host "RESULT: $($script:Pass) passed, $($script:Fail) failed" -ForegroundColor Red
$script:Failures | ForEach-Object { Write-Host "  - $_" -ForegroundColor Red }
exit 1
