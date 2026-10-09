#requires -Version 7.0
<#
.SYNOPSIS
  Verifies the ACL stage for the coder containment floor (#1678 projects narrowed to read, #1686 fleet root
  closed + worktree-root deny, #1692 model folders) WITHOUT any real account, real folder or real ACL change.
  Every ACL operation here runs on a TEMP tree; the current user stands in for the coder where no real coder
  account exists.

.DESCRIPTION
  WHAT IS REAL: icacls itself, Get-Acl, the .NET file calls, git, the probe script
  (coder-containment-probe.ps1 run as a child of this script), the stage code (Invoke-CoderAclStage and
  every function under it), the scratch repo and operator funnel (coder-acl-lib.ps1).

  WHAT IS A STAND-IN: the coder is the CURRENT USER (one token cannot be both the operator and the coder), so
  the operator-side steps (creating a repo after provisioning, the funnel commit) run inside a short
  OPERATOR WINDOW: the user gets a temporary explicit Modify on one folder, does the operator step, and the
  folder's saved access list is restored. After every window the suite asserts the folder is back to the
  narrowed state, so a leaking window cannot make the coder checks pass. The operator account is a SID that is
  not in any token (S-1-5-21-...-1001). Authenticated Users stands in for "every local account": the user is
  a member, exactly as every account is.

  REAL-ACCOUNT-ONLY (NOT proven here, proven by verify-coder-containment.ps1 on the machine): the distinct
  blarai-coder token; Windows resolving a different account's inherited ACEs; the scheduled-task path; owner
  and elevation interplay of a real operator; the real C:\ and B:\ access lists; Bitdefender.

  Sections: pure plan/simulator/command tests; the safety gate; a CONTROL showing icacls /T follows a junction
  without /L (so the /L test could have disagreed); the stage on a temp tree (dry run changes nothing and
  prints the contract; apply matches the printed AFTER; negative and positive coder checks; the toggle test;
  idempotence; rollback; restore from backup; refusal before any change); probe edge cases; the funnel
  notice, git environment and rules renderer; the wiring of the provisioning scripts.

  -Mutations: re-runs THIS suite against mutated copies of the sources (each control disabled in turn). KILLED
  = non-zero exit AND a [FAIL] line; SURVIVED = exit 0; ERROR = non-zero with no [FAIL] line. The unmutated
  control must pass first. -ProveHarness shows the classification on a known survivor, crasher and kill.
  Exit 0 if everything passed.
#>
param([switch]$Mutations, [switch]$ProveHarness, [string[]]$Only = @(), [int]$Throttle = 3)
$ErrorActionPreference = 'Stop'
$script:SrcDir = $PSScriptRoot

if ($Mutations -or $ProveHarness) {
    try { (Get-Process -Id $PID).PriorityClass = 'BelowNormal' } catch { }
    . "$PSScriptRoot\hidden-process-lib.ps1"
    $pw = (Get-Command pwsh -ErrorAction SilentlyContinue).Source
    $winBaseline = @(Get-VisibleConsoleProcessIds)
    $files = 'coder-acl-lib.ps1', 'coder-provisioning-lib.ps1', 'coder-leg-queue.ps1', 'coder-containment-probe.ps1', 'provision-coder-account.ps1', 'provision-coder-acls.ps1', 'verify-coder-containment.ps1', 'verify-coder-narrowing.ps1', 'fleet-lib.ps1', 'coder-leg-run.ps1', 'hidden-process-lib.ps1'
    $run = {
        param($Dir, $Mut, $files, $pw, $SrcDir)
        . (Join-Path $SrcDir 'hidden-process-lib.ps1')
        New-Item -ItemType Directory -Force $Dir | Out-Null
        New-Item -ItemType Directory -Force (Join-Path $Dir 'configs') | Out-Null
        Copy-Item (Join-Path (Split-Path $SrcDir -Parent) 'configs\AGENTS.md') (Join-Path $Dir 'configs\AGENTS.md')
        $sd = Join-Path $Dir 'scripts'; New-Item -ItemType Directory -Force $sd | Out-Null
        foreach ($f in $files) { Copy-Item (Join-Path $SrcDir $f) (Join-Path $sd $f) }
        if ($Mut) {
            $target = Join-Path $sd $Mut.F
            $text = [IO.File]::ReadAllText($target)
            if (-not $text.Contains($Mut.O)) { return @{ Class = 'ERROR'; Why = "mutation target not found in $($Mut.F)" } }
            [IO.File]::WriteAllText($target, $text.Replace($Mut.O, $Mut.W), (New-Object Text.UTF8Encoding($true)))
        }
        if ($Mut) { $env:BLARAI_NARROW_FAILFAST = '1' } else { Remove-Item Env:\BLARAI_NARROW_FAILFAST -ErrorAction SilentlyContinue }
        $h = Invoke-HiddenProcess -FilePath $pw -ArgumentList @('-NoProfile', '-NonInteractive', '-File', (Join-Path $sd 'verify-coder-narrowing.ps1')) -TimeoutSec 1500
        $out = $h.Stdout + "`n" + $h.Stderr
        $code = $h.ExitCode
        $fails = @($out -split "`n" | Where-Object { $_ -match '\[FAIL\]' })
        if ($code -eq 0) { return @{ Class = 'SURVIVED'; Why = 'the suite did not notice' } }
        if ($fails.Count -gt 0) { return @{ Class = 'KILLED'; Why = ("$($fails[0])").Trim() } }
        return @{ Class = 'ERROR'; Why = 'non-zero exit with no [FAIL] line: ' + (($out -split "`n" | Where-Object { $_.Trim() } | Select-Object -Last 3) -join ' | ') }
    }
    function Invoke-MutationRun([object[]]$Muts) {
        $tmp = Join-Path ([IO.Path]::GetTempPath()) ('narrow-mut-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
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
    if ($ProveHarness) {
        $probe = @(
            @{ N = 'equivalent-comment-change'; F = 'coder-acl-lib.ps1'; O = '# ---- the ACE model ----'; W = '# ---- the ACE model (renamed) ----' },
            @{ N = 'crashing-syntax-break';     F = 'coder-acl-lib.ps1'; O = 'function Get-AclRightName {'; W = 'function Get-AclRightName { }}}}' },
            @{ N = 'real-kill-undo-removed';    F = 'coder-acl-lib.ps1'; O = '(New-AclOp RemoveGrants -Sid $CoderSid -Tree), (New-AclOp SetGrant -Sid $CoderSid -Rights ''RX'' -Flags $OI_CI)'; W = '(New-AclOp SetGrant -Sid $CoderSid -Rights ''RX'' -Flags $OI_CI)' }
        )
        $r = Invoke-MutationRun $probe
        $want = @{ 'equivalent-comment-change' = 'SURVIVED'; 'crashing-syntax-break' = 'ERROR'; 'real-kill-undo-removed' = 'KILLED' }
        $bad = @($r.Results | Where-Object { $want[$_.N] -ne $_.Class })
        if ($r.Control -and $bad.Count -eq 0 -and $r.Results.Count -eq 3) { Write-Host 'HARNESS PROVEN: survivor reported SURVIVED, crasher reported ERROR, real kill reported KILLED' -ForegroundColor Green; exit 0 }
        Write-Host 'HARNESS NOT PROVEN' -ForegroundColor Red; exit 1
    }
    $A = 'coder-acl-lib.ps1'
    $muts = @(
        @{ N = 'undo-of-old-modify-removed';   F = $A; O = '-Steps @((New-AclOp RemoveGrants -Sid $CoderSid -Tree), (New-AclOp SetGrant -Sid $CoderSid -Rights ''RX'' -Flags $OI_CI))'; W = '-Steps @((New-AclOp SetGrant -Sid $CoderSid -Rights ''RX'' -Flags $OI_CI))' },
        @{ N = 'read-ace-not-inheritable';     F = $A; O = '-Steps @((New-AclOp RemoveGrants -Sid $CoderSid -Tree), (New-AclOp SetGrant -Sid $CoderSid -Rights ''RX'' -Flags $OI_CI))'; W = '-Steps @((New-AclOp RemoveGrants -Sid $CoderSid -Tree), (New-AclOp SetGrant -Sid $CoderSid -Rights ''RX'' -Flags ''''))' },
        @{ N = 'read-ace-is-modify';           F = $A; O = '-Steps @((New-AclOp RemoveGrants -Sid $CoderSid -Tree), (New-AclOp SetGrant -Sid $CoderSid -Rights ''RX'' -Flags $OI_CI))'; W = '-Steps @((New-AclOp RemoveGrants -Sid $CoderSid -Tree), (New-AclOp SetGrant -Sid $CoderSid -Rights ''M'' -Flags $OI_CI))' },
        @{ N = 'read-ace-missing';             F = $A; O = '-Steps @((New-AclOp RemoveGrants -Sid $CoderSid -Tree), (New-AclOp SetGrant -Sid $CoderSid -Rights ''RX'' -Flags $OI_CI))'; W = '-Steps @((New-AclOp RemoveGrants -Sid $CoderSid -Tree))' },
        @{ N = 'tree-op-uses-icacls-T';        F = $A; O = '$w = Invoke-AclTreeRemoveGrants -Root $Action.Path -Sid $op.Sid -Out $Out'; W = '$null = & icacls $Action.Path /remove:g "*$($op.Sid)" /T /C /L; $w = @{ Visited = 0; Changed = 0; Links = @(); Errors = @() }' },
        @{ N = 'walk-enters-links';            F = $A; O = 'if ($attr -band [IO.FileAttributes]::ReparsePoint) { [void]$res.Links.Add($e); continue }'; W = 'if ($false) { continue }' },
        @{ N = 'walk-skips-protected-children'; F = $A; O = 'if ($attr -band [IO.FileAttributes]::Directory) { [void]$subdirs.Add($e); continue }'; W = 'if (($attr -band [IO.FileAttributes]::Directory) -and ($e -notlike ''*repoC'')) { [void]$subdirs.Add($e); continue }' },
        @{ N = 'removal-does-nothing';          F = $A; O = '[void]$acl.RemoveAccessRuleSpecific($rule); $changed = $true'; W = '$changed = $false' },
        @{ N = 'removal-wrong-type';            F = $A; O = '[string]$rule.AccessControlType -eq $Type'; W = '$true' },
        @{ N = 'safe-gate-link-check';         F = $A; O = 'if ($item -and ($item.Attributes -band [IO.FileAttributes]::ReparsePoint)) {'; W = 'if ($false) {' },
        @{ N = 'safe-gate-wildcard';           F = $A; O = 'if ($Path -match ''[\*\?<>|"]'')'; W = 'if ($false)' },
        @{ N = 'safe-gate-dotdot';             F = $A; O = 'if ($Path -match ''(^|\\)\.\.(\\|$)'')'; W = 'if ($false)' },
        @{ N = 'safe-gate-relative';           F = $A; O = 'if ($Path -notmatch ''^[A-Za-z]:\\'')'; W = 'if ($false)' },
        @{ N = 'safe-gate-drive-root';         F = $A; O = 'if ($norm -match ''^[A-Za-z]:$'')'; W = 'if ($false)' },
        @{ N = 'safe-gate-system-folders';     F = $A; O = 'if ($forbidden) { $r.Reason'; W = 'if ($false) { $r.Reason' },
        @{ N = 'safe-gate-must-exist';         F = $A; O = 'if (-not (Test-Path -LiteralPath $norm)) { $r.Reason'; W = 'if ($false) { $r.Reason' },
        @{ N = 'safe-gate-reports-inner-links'; F = $A; O = 'if ($Tree) { $r.Links = @(Find-LinksUnder -Root $norm) }'; W = '' },
        @{ N = 'action-gates-before-commands'; F = $A; O = 'if (-not $safe.Ok) { throw "refusing ''$($Action.Path)'': $($safe.Reason)" }'; W = '' },
        @{ N = 'stage-refuses-before-any-change'; F = $A; O = 'if ($refused.Count -gt 0) { throw "refusing to run the stage, no change made'; W = 'if ($false) { throw "refusing to run the stage, no change made' },
        @{ N = 'same-sid-refused';             F = $A; O = 'if ($CoderSid -eq $OperatorSid) { throw'; W = 'if ($false) { throw' },
        @{ N = 'running-task-refused';         F = $A; O = 'if ($TaskState -eq ''Running'') { throw'; W = 'if ($false) { throw' },
        @{ N = 'backup-before-change';         F = $A; O = '$null = Write-AclBackup -Plan $plan -BackupDir $BackupDir -Runner $Runner'; W = '' },
        @{ N = 'readback-compared';            F = $A; O = 'if (-not $cmp.Match) { foreach ($d in $cmp.Diff) { [void]$mism.Add("$($act.Path): $d") } }'; W = '' },
        @{ N = 'simulator-removegrants-noop';  F = $A; O = '''RemoveGrants'' { $aces = @($aces | Where-Object { -not ($_.Type -eq ''Allow'' -and -not $_.Inherited -and $_.Sid -eq $Op.Sid) }) }'; W = '''RemoveGrants'' { }' },
        @{ N = 'fleet-authusers-kept';         F = $A; O = '(New-AclOp RemoveGrants -Sid $authUsers), '; W = '' },
        @{ N = 'fleet-inheritance-kept';       F = $A; O = '-Steps @((New-AclOp DisableInheritanceCopy), (New-AclOp RemoveGrants -Sid $authUsers)'; W = '-Steps @((New-AclOp RemoveGrants -Sid $authUsers)' },
        @{ N = 'fleet-coder-modify-kept';      F = $A; O = '(New-AclOp RemoveGrants -Sid $CoderSid -Tree), (New-AclOp AddGrant -Sid $OperatorSid'; W = '(New-AclOp AddGrant -Sid $OperatorSid' },
        @{ N = 'coder-modify-grants-missing';  F = $A; O = '-Steps @(New-AclOp SetGrant -Sid $CoderSid -Rights ''M'' -Flags $OI_CI) -Undo @(New-AclOp RemoveGrants -Sid $CoderSid)))'; W = '-Steps @() -Undo @()))' },
        @{ N = 'worktree-root-deny-dc';        F = $A; O = '(New-AclOp Deny -Sid $CoderSid -Rights ''DC''), '; W = '' },
        @{ N = 'worktree-root-deny-de';        F = $A; O = ', (New-AclOp Deny -Sid $CoderSid -Rights ''DE'' -Flags ''(CI)(IO)(NP)'')'; W = '' },
        @{ N = 'models-writers-kept';          F = $A; O = '[void]$steps.Add((New-AclOp RemoveGrants -Sid $w))'; W = '' },
        @{ N = 'models-read-dropped';          F = $A; O = '[void]$steps.Add((New-AclOp AddGrant -Sid $w -Rights (Get-AclRightName -Mask $c.Mask) -Flags $c.Flags))'; W = '' },
        @{ N = 'models-inheritance-kept';      F = $A; O = 'if (-not $wasProtected) { [void]$steps.Add((New-AclOp DisableInheritanceCopy)) }'; W = '' },
        @{ N = 'orphan-detection';             F = $A; O = '$_.Orphan -and $_.Type -eq ''Allow'' -and -not $_.Inherited'; W = '$false' },
        @{ N = 'orphan-flag-in-reader';        F = $A; O = 'if ($ref -is [Security.Principal.SecurityIdentifier]) { $sid = $ref.Value; $orphan = $true;'; W = 'if ($ref -is [Security.Principal.SecurityIdentifier]) { $sid = $ref.Value; $orphan = $false;' },
        @{ N = 'verdict-check8-dropped';       F = $A; O = 'if (-not $SourceGitWriteDenied) { [void]$failed.Add(''check8-source-git-write-denied'') }'; W = '' },
        @{ N = 'verdict-check9-dropped';       F = $A; O = 'if (-not $WorktreeCommitFails)  { [void]$failed.Add(''check9-worktree-commit-fails'') }'; W = '' },
        @{ N = 'verdict-check6-dropped';       F = $A; O = 'if (-not $SiblingWriteDenied)   { [void]$failed.Add(''check6-sibling-repo-write-denied'') }'; W = '' },
        @{ N = 'verdict-check12-dropped';      F = $A; O = 'if (-not $NewRepoInheritsRead)  { [void]$failed.Add(''check12-new-repo-inherits-read'') }'; W = '' },
        @{ N = 'probe-map-sibling-always-ok';  F = $A; O = '$sibOk = & $per $Checks.write_outside_denied $SiblingDir'; W = '$sibOk = $true' },
        @{ N = 'probe-map-missing-is-pass';    F = $A; O = 'if ($null -eq $e) { return $false }'; W = 'if ($null -eq $e) { return $true }' },
        @{ N = 'funnel-commit-skipped';        F = $A; O = '''commit'', ''-m'', ''operator funnel commit''';  W = '''status'', ''--short''' },
        @{ N = 'funnel-merge-skipped';         F = $A; O = '@(''merge'', ''--ff-only'', $Scratch.Branch)'; W = '@(''status'', ''--short'')' },
        @{ N = 'probe-inconclusive-as-denied'; F = 'coder-containment-probe.ps1'; O = 'return @{ Denied = $false; Detail = "$What inconclusive'; W = 'return @{ Denied = $true; Detail = "$What inconclusive' },
        @{ N = 'probe-success-as-denied';      F = 'coder-containment-probe.ps1'; O = 'try { & $Try; return @{ Denied = $false;'; W = 'try { & $Try; return @{ Denied = $true;' },
        @{ N = 'probe-commit-needs-permission-text'; F = 'coder-containment-probe.ps1'; O = '$ok = ($statusRc -eq 0) -and $failed -and $perm -and ($headBefore -eq $headAfter)'; W = '$ok = $failed' },
        @{ N = 'probe-worktree-write-unchecked'; F = 'coder-containment-probe.ps1'; O = '"write FAILED: $($_.Exception.Message)" }; $writeOk = $false }'; W = '"write FAILED: $($_.Exception.Message)" }; $writeOk = $true }' },
        @{ N = 'probe-read-check-always-pass'; F = 'coder-containment-probe.ps1'; O = 'detail = "NOT readable: $($_.Exception.Message)" }; $all = $false }'; W = 'detail = "NOT readable: $($_.Exception.Message)" }; $all = $true }' },
        @{ N = 'probe-objects-check-dropped';  F = 'coder-containment-probe.ps1'; O = 'if (-not ($r1.Denied -and $r2.Denied)) { $all = $false }'; W = 'if (-not ($r1.Denied)) { $all = $false }' },
        @{ N = 'probe-refs-check-dropped';     F = 'coder-containment-probe.ps1'; O = 'if (-not ($r1.Denied -and $r2.Denied)) { $all = $false }'; W = 'if (-not ($r2.Denied)) { $all = $false }' },
        @{ N = 'provision-regrants-projects-modify'; F = 'provision-coder-account.ps1'; O = '    & $aclStage -Apply'; W = '    Add-Ace $ProjectsDir $sid ''(OI)(CI)M''; & $aclStage -Apply' },
        @{ N = 'provision-stage-not-called';   F = 'provision-coder-account.ps1'; O = '    & $aclStage -Apply'; W = '    # & $aclStage -Apply' },
        @{ N = 'notice-not-added-to-prompt';   F = 'fleet-lib.ps1'; O = '-Text (Add-CoderFunnelNotice -Prompt $Prompt)'; W = '-Text $Prompt' },
        @{ N = 'rules-render-noop';            F = 'coder-leg-queue.ps1'; O = 'return $rx.Replace($Text, { param($m) $rule })'; W = 'return $Text' },
        @{ N = 'rules-off-rewritten';          F = 'coder-leg-queue.ps1'; O = 'if ($Containment -eq ''off'') { return $Text }'; W = '' },
        @{ N = 'git-env-optional-locks';       F = 'coder-leg-queue.ps1'; O = 'GIT_OPTIONAL_LOCKS   = ''0''';  W = 'GIT_OPTIONAL_LOCKS   = ''1''' },
        @{ N = 'git-env-safe-dir-star';        F = 'coder-leg-queue.ps1'; O = 'GIT_CONFIG_VALUE_0   = $wd'; W = 'GIT_CONFIG_VALUE_0   = ''*''' },
        @{ N = 'lint-start-process-check-removed'; F = 'hidden-process-lib.ps1'; O = 'elseif ($code -notmatch ''(?i)-W(indowStyle)?[:\s]+Hidden\b'' -and'; W = 'elseif ($false -and' },
        @{ N = 'lint-startinfo-check-removed'; F = 'hidden-process-lib.ps1'; O = 'if ($psiCount -gt $cnwCount) {'; W = 'if ($false) {' },
        @{ N = 'hidden-launch-shows-window';   F = 'hidden-process-lib.ps1'; O = '$psi.CreateNoWindow = $true'; W = '$psi.CreateNoWindow = $false' },
        @{ N = 'deelevate-ignored';            F = 'hidden-process-lib.ps1'; O = 'if ($DeElevate -and (Test-CallerElevated)) {'; W = 'if ($false) {' },
        @{ N = 'handle-open-follows-links';    F = $A; O = 'FILE_FLAG_BACKUP_SEMANTICS | FILE_FLAG_OPEN_REPARSE_POINT, IntPtr.Zero'; W = 'FILE_FLAG_BACKUP_SEMANTICS, IntPtr.Zero' },
        @{ N = 'handle-reparse-attr-unchecked'; F = $A; O = 'if ((fi.dwFileAttributes & FILE_ATTRIBUTE_REPARSE_POINT) != 0) return'; W = 'if (fi.dwFileAttributes == 0xFFFFFFFF) return' },
        @{ N = 'handle-kind-unchecked';        F = $A; O = 'if (isDir != wantDir) return'; W = 'if (isDir != wantDir && fi.dwFileAttributes == 0xFFFFFFFF) return' },
        @{ N = 'final-path-check-removed';     F = $A; O = 'if (-not $ok) { throw "refusing ''$Path'': it resolves to'; W = 'if ($false) { throw "refusing ''$Path'': it resolves to' },
        @{ N = 'handle-share-delete';          F = $A; O = 'FILE_SHARE_READ | FILE_SHARE_WRITE, IntPtr.Zero'; W = 'FILE_SHARE_READ | FILE_SHARE_WRITE | 4, IntPtr.Zero' },
        @{ N = 'digest-check-removed';         F = $A; O = 'if ($view.Digest -ne $ExpectPlan) {'; W = 'if ($false) {' },
        @{ N = 'expect-plan-optional';         F = $A; O = 'if (-not $ExpectPlan) { throw ''-Apply needs -ExpectPlan'; W = 'if ($false) { throw ''-Apply needs -ExpectPlan' },
        @{ N = 'digest-ignores-states';        F = $A; O = '$lines = @(Format-CoderAclPlan -Plan $shown -States $states -Safety $Safety -Names $names)'; W = '$lines = @($shown | ForEach-Object { $_.Title })' },
        @{ N = 'norm-removed';                 F = $A; O = '$norm = ConvertTo-NormalizedAclPath -Path $Path'; W = '$norm = $Path.TrimEnd(''\'').ToLowerInvariant()' },
        @{ N = 'norm-no-path-normalisation';   F = $A; O = 'return ([BlarHandleAcl]::LongPath([IO.Path]::GetFullPath($rebuilt))).TrimEnd(''\'')'; W = 'return $Path.TrimEnd(''\'')' },
        @{ N = 'prefix-gate-removed';          F = $A; O = 'if ($Path -match ''^[\\/]{2}[?.][\\/]'' -or $Path -match ''^[\\/]{2}[?.]$'')'; W = 'if ($false)' },
        @{ N = 'stream-gate-removed';          F = $A; O = 'if ($Path.Substring(2) -match '':'')'; W = 'if ($false)' },
        @{ N = 'device-name-gate-removed';     F = $A; O = 'if (@($Path -split ''\\'' | Where-Object'; W = 'if ($false -and @($Path -split ''\\'' | Where-Object' },
        @{ N = 'model-entry-flags-shared';     F = $A; O = '-Rights (Get-AclRightName -Mask $c.Mask) -Flags $c.Flags))'; W = '-Rights (Get-AclRightName -Mask $c.Mask) -Flags $cands[0].Flags))' },
        @{ N = 'model-cover-dedupe-dropped';   F = $A; O = 'if (-not $covered) { [void]$steps'; W = 'if ($true) { [void]$steps' },
        @{ N = 'model-read-entry-dropped';     F = $A; O = 'if ($mk -eq 0) { continue }'; W = 'if ($mk -eq 0 -or -not (Test-AceWriteCapable $e)) { continue }' },
        @{ N = 'fleet-operator-undo-dropped';  F = $A; O = 'if (-not $opHadFleet) { $fleetUndo += @(New-AclOp RemoveGrants -Sid $OperatorSid) }'; W = '' },
        @{ N = 'fleet-operator-undo-always';   F = $A; O = 'if (-not $opHadFleet) { $fleetUndo +='; W = 'if ($true) { $fleetUndo +=' },
        @{ N = 'models-operator-undo-dropped'; F = $A; O = '{ [void]$undo.Add((New-AclOp RemoveGrants -Sid $OperatorSid)) }'; W = '{ }' },
        @{ N = 'effective-groups-ignored';     F = $A; O = "elseif (`$GroupSids -contains `$rs) { 'group' }"; W = "elseif (`$false) { 'group' }" },
        @{ N = 'effective-owner-check-removed'; F = $A; O = 'if ($CheckOwner -and $got.Owner -eq $Sid'; W = 'if ($false -and $got.Owner -eq $Sid' },
        @{ N = 'effective-group-finding-dropped'; F = $A; O = 'foreach ($h in $wk.Hits) {'; W = 'foreach ($h in @($wk.Hits | Where-Object { $_.Kind -eq ''coder'' })) {' },
        @{ N = 'effective-warning-dropped';    F = $A; O = '[void]$warnings.Add("the coder has write access under'; W = '$null = ("the coder has write access under' },
        @{ N = 'model-roots-without-c-models'; F = $A; O = "@('B:\models', 'C:\models', 'C:\Users\mrbla\BlarAI\models')"; W = "@('B:\models', 'C:\Users\mrbla\BlarAI\models')" },
        @{ N = 'rollback-picks-newest';        F = $A; O = 'if ($all.Count -eq 1) { return $all[0].FullName }'; W = 'if ($all.Count -ge 1) { return $all[-1].FullName }' },
        @{ N = 'rollback-script-uses-newest';  F = 'provision-coder-acls.ps1'; O = 'Select-AclRollbackBackup -BackupRoot $BackupRoot'; W = 'Get-LatestAclBackup -BackupRoot $BackupRoot' },
        @{ N = 'secret-zero-read-passes';      F = 'coder-containment-probe.ps1'; O = 'pass = ($allDenied -and $deniedCount -gt 0)'; W = 'pass = $allDenied' },
        @{ N = 'probe-paramsfile-ignored';     F = 'coder-containment-probe.ps1'; O = 'if ($ParamsFile) {'; W = 'if ($false) {' },
        @{ N = 'verify-credential-literal-list'; F = 'verify-coder-containment.ps1'; O = '-ParamsFile `"$paramsFile`"'; W = '-SecretPaths $secretArg' },
        @{ N = 'icacls-handle-not-held';       F = $A; O = 'if (-not $Runner) { $held = Open-AclHandle -Path $Action.Path -IsDir $true -Write $false'; W = 'if ($false) { $held = Open-AclHandle -Path $Action.Path -IsDir $true -Write $false' },
        @{ N = 'icacls-postcheck-removed';     F = $A; O = 'if ($held -and ($f2 -ine $f1)) { throw'; W = 'if ($false) { throw' },
        @{ N = 'forbidden-prefix-removed';     F = $A; O = 'foreach ($p in $r.Prefix) { if (& $under $n $p) {'; W = 'foreach ($p in $r.Prefix) { if ($false) {' },
        @{ N = 'forbidden-other-profile-removed'; F = $A; O = 'if ($n -match ''^C:\\Users\\[^\\]+'' -and $r.Profile'; W = 'if ($false -and $r.Profile' },
        @{ N = 'apply-failure-message-dropped'; F = $A; O = 'throw "apply failed part-way at'; W = 'throw "failed at' },
        @{ N = 'addgrant-absorption-removed';  F = $A; O = 'if ($idx -ge 0) {'; W = 'if ($false) {' },
        @{ N = 'protected-children-not-listed'; F = $A; O = 'if ($sec.AreAccessRulesProtected -and'; W = 'if ($false -and' },
        @{ N = 'long-path-prefix-removed';     F = $A; O = 'string p = (path.Length >= 240'; W = 'string p = (path.Length >= 24000' },
        @{ N = 'checklist-removed';            F = $A; O = 'foreach ($cl in (Get-OperatorChecklistLines)) { & $Out $cl }'; W = '' },
        @{ N = 'lint-bare-host-removed';       F = 'hidden-process-lib.ps1'; O = 'if ($code -match ($sep + "(?i:$hostNames)'; W = 'if ($false -and $code -match ($sep + "(?i:$hostNames)' },
        @{ N = 'lint-exevar-removed';          F = 'hidden-process-lib.ps1'; O = 'if ($exeVars.ContainsKey($v) -or'; W = 'if ($false -or' },
        @{ N = 'lint-static-start-removed';    F = 'hidden-process-lib.ps1'; O = 'if ($code -match ''(?i)\[(System\.)?Diagnostics\.Process\]::Start'; W = 'if ($false -and $code -match ''(?i)\[(System\.)?Diagnostics\.Process\]::Start' },
        @{ N = 'lint-iex-removed';             F = 'hidden-process-lib.ps1'; O = 'if ($code -match ''(?i)\b(Invoke-Expression|iex)\b'')'; W = 'if ($false)' },
        @{ N = 'lint-verb-removed';            F = 'hidden-process-lib.ps1'; O = 'if ($code -match ''(?i)-Verb\b'')'; W = 'if ($false)' },
        @{ N = 'lint-comment-strip-removed';   F = 'hidden-process-lib.ps1'; O = '$ci = $b.IndexOf(''#'')'; W = '$ci = -1' },
        @{ N = 'lint-continuation-join-removed'; F = 'hidden-process-lib.ps1'; O = 'if ($raw[$i] -match ''`\s*$'')'; W = 'if ($false)' },
        @{ N = 'lint-quoted-callop-removed';   F = 'hidden-process-lib.ps1'; O = 'elseif ($rawCode -match'; W = 'elseif ($false -and $rawCode -match' },
        @{ N = 'lint-shell-rules-removed';     F = 'hidden-process-lib.ps1'; O = 'if ($code -match ''(?i)UseShellExecute'; W = 'if ($false -and $code -match ''(?i)UseShellExecute' },
        @{ N = 'r2-groups-drop-local-account'; F = 'coder-acl-lib.ps1'; O = '''S-1-5-113'', ''S-1-5-15'', '; W = '' },
        @{ N = 'r2-groups-drop-logon-types'; F = 'coder-acl-lib.ps1'; O = ', ''S-1-5-3'', ''S-1-5-4'', ''S-1-5-2'','; W = ',' },
        @{ N = 'r2-lookup-error-swallowed'; F = 'coder-acl-lib.ps1'; O = '} catch { [void]$errors.Add("the local group lookup failed: $($_.Exception.Message)") }'; W = '} catch { }' },
        @{ N = 'r2-unknown-coder-sid-silent'; F = 'coder-acl-lib.ps1'; O = 'if (-not $CoderSid) { [void]$errors.Add(''the coder SID is not known, so its local group memberships could not be read'') }'; W = 'if (-not $CoderSid) { }' },
        @{ N = 'r2-group-errors-not-a-finding'; F = 'coder-acl-lib.ps1'; O = 'foreach ($ge in @($CoderGroupErrors)) { [void]$f.Add('; W = 'foreach ($ge in @()) { [void]$f.Add(' },
        @{ N = 'r2-group-errors-not-in-dryrun'; F = 'coder-acl-lib.ps1'; O = 'foreach ($ge in @($GroupErrors)) {'; W = 'foreach ($ge in @()) {' },
        @{ N = 'r2-unreadable-not-in-plan'; F = 'coder-acl-lib.ps1'; O = 'if ($unreadable.Count -gt 0) {'; W = 'if ($false) {' },
        @{ N = 'r2-unreadable-digest-given'; F = 'coder-acl-lib.ps1'; O = '$withhold = ($view.Unreadable -gt 0 -and -not $AllowUnreadable)'; W = '$withhold = $false' },
        @{ N = 'r2-allow-unreadable-ignored'; F = 'coder-acl-lib.ps1'; O = '$withhold = ($view.Unreadable -gt 0 -and -not $AllowUnreadable)'; W = '$withhold = ($view.Unreadable -gt 0)' },
        @{ N = 'r2-params-file-in-results'; F = 'verify-coder-containment.ps1'; O = '-Dir (Split-Path $paths.Root -Parent)'; W = '-Dir $paths.Results' },
        @{ N = 'r2-params-file-kept'; F = 'coder-acl-lib.ps1'; O = '} finally { if (Test-Path -LiteralPath $f) { Remove-Item -LiteralPath $f -Force -ErrorAction SilentlyContinue } }'; W = '} finally { }' },
        @{ N = 'r2-params-file-coder-can-write'; F = 'coder-acl-lib.ps1'; O = '"*${CoderSid}:R"'; W = '"*${CoderSid}:M"' },
        @{ N = 'r2-params-file-everyone-reads'; F = 'coder-acl-lib.ps1'; O = '''/inheritance:r'', ''/grant:r'','; W = '''/grant:r'', ''*S-1-1-0:R'',' },
        @{ N = 'r2-temp-exemption-default-on'; F = 'coder-acl-lib.ps1'; O = '$script:AclAllowTempRoot = $false   # TESTS'; W = '$script:AclAllowTempRoot = $true   # TESTS' },
        @{ N = 'r2-temp-exemption-unconditional'; F = 'coder-acl-lib.ps1'; O = 'if ($profileRoot -and $script:AclAllowTempRoot)'; W = 'if ($profileRoot)' },
        @{ N = 'r2-lint-getcommand-callop'; F = 'hidden-process-lib.ps1'; O = 'if ($code -match ''&\s*\('' -and'; W = 'if ($false -and $code -match ''&\s*\('' -and' },
        @{ N = 'r2-lint-pshome-callop'; F = 'hidden-process-lib.ps1'; O = 'if ($code -match ''(?i)&\s*\$(PSHOME|env:ComSpec)\b'')'; W = 'if ($false)' },
        @{ N = 'r2-lint-batch-file'; F = 'hidden-process-lib.ps1'; O = 'if ($code -match ($sep + ''(?:\.[\\/]|'; W = 'if ($false -and $code -match ($sep + ''(?:\.[\\/]|' },
        @{ N = 'r2-lint-process-new'; F = 'hidden-process-lib.ps1'; O = 'if ($code -match ''(?i)\[(System\.)?(Diagnostics\.)?Process\]::new'; W = 'if ($false -and $code -match ''(?i)\[(System\.)?(Diagnostics\.)?Process\]::new' },
        @{ N = 'r2-lint-versioned-python'; F = 'hidden-process-lib.ps1'; O = '''python[\d.]*'', ''py[\d.]*'','; W = '''python\d*'', ''py'',' },
        @{ N = 'r2-lint-hidden-suffix'; F = 'hidden-process-lib.ps1'; O = '[:\s]+Hidden\b'' -and'; W = '[:\s]+Hidden'' -and' },
        @{ N = 'r2-lint-nonewwindow-suffix'; F = 'hidden-process-lib.ps1'; O = '-NoNewWindow\b'') {'; W = '-NoNewWindow'') {' },
        @{ N = 'runner-sets-git-env';          F = 'coder-leg-run.ps1'; O = 'foreach ($kv in (Get-CoderLegGitEnv -WorkDir ([string]$job.workdir)).GetEnumerator()) { Set-Item -LiteralPath "Env:\$($kv.Key)" -Value ([string]$kv.Value) }'; W = '' }
    )
    if ($Only.Count -gt 0) { $muts = @($muts | Where-Object { $Only -contains $_.N }) }
    $r = Invoke-MutationRun $muts
    if (-not $r.Control) { exit 1 }
    $k = @($r.Results | Where-Object { $_.Class -eq 'KILLED' }).Count
    $s = @($r.Results | Where-Object { $_.Class -eq 'SURVIVED' })
    $e = @($r.Results | Where-Object { $_.Class -eq 'ERROR' })
    $newWin = @(Get-NewVisibleConsoleWindows -BaselineIds $winBaseline)
    if ($newWin.Count -gt 0) { Write-Host "VISIBLE WINDOWS CAUSED BY THIS RUN: $($newWin -join '; ')" -ForegroundColor Red }
    Write-Host ''
    Write-Host "MUTATIONS: $k killed, $($s.Count) survived, $($e.Count) error, of $($r.Results.Count)" -ForegroundColor $(if ($s.Count + $e.Count -eq 0) { 'Green' } else { 'Red' })
    $s + $e | ForEach-Object { Write-Host "  $($_.Class): $($_.N)" -ForegroundColor Red }
    exit $(if ($s.Count + $e.Count -eq 0 -and $newWin.Count -eq 0) { 0 } else { 1 })
}

. "$PSScriptRoot\coder-acl-lib.ps1"
. "$PSScriptRoot\coder-provisioning-lib.ps1"
. "$PSScriptRoot\coder-leg-queue.ps1"
. "$PSScriptRoot\hidden-process-lib.ps1"
$script:AclAllowTempRoot = $true   # the self-test builds its trees under the temp folder; the library default is OFF (round 7, R2-5)
$script:WindowBaseline = @(Get-VisibleConsoleProcessIds)

$script:Pass = 0; $script:Fail = 0
$script:Failures = New-Object System.Collections.ArrayList
$script:FailFast = [bool]$env:BLARAI_NARROW_FAILFAST
function _pass($m) { $script:Pass++; Write-Host "  [PASS] $m" -ForegroundColor Green }
function _fail($m) {
    $script:Fail++; [void]$script:Failures.Add($m); Write-Host "  [FAIL] $m" -ForegroundColor Red
    if ($script:FailFast) { Write-Host "RESULT: $($script:Pass) passed, $($script:Fail) failed (fail-fast)" -ForegroundColor Red; exit 1 }
}
function Section($t) { Write-Host ''; Write-Host "== $t ==" -ForegroundColor Cyan }
function Assert-True($c, $m) { if ($c) { _pass $m } else { _fail "$m (expected True)" } }
function Assert-Eq($e, $a, $m) { if ([string]$e -ceq [string]$a) { _pass $m } else { _fail "$m (expected '$e', got '$a')" } }
function Test-Step { param([string]$Name, [scriptblock]$Body) try { & $Body } catch { _fail "$Name threw: $($_.Exception.Message)" } }

$User = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
$OperatorDummy = 'S-1-5-32-546'   # Guests: resolvable (icacls needs that) and not in this user's token
$OrphanSid = 'S-1-5-21-1999999999-1888888888-1777777777-5555'
$AuthUsers = 'S-1-5-11'; $UsersSid = 'S-1-5-32-545'
$ProbeScript = Join-Path $PSScriptRoot 'coder-containment-probe.ps1'
$Cleanup = New-Object System.Collections.ArrayList
$script:StandInDir = Join-Path ([IO.Path]::GetTempPath()) ('narrow-standin-' + [guid]::NewGuid().ToString('N').Substring(0, 8)); New-Item -ItemType Directory $script:StandInDir | Out-Null; [void]$Cleanup.Add($script:StandInDir)

function Test-DeniedByAcl {
    # denied ONLY on an access-denied error; success and any other error are not "denied"
    param([scriptblock]$Try, [string]$What)
    try { & $Try; return @{ Denied = $false; Detail = "$What SUCCEEDED" } }
    catch {
        $inner = $_.Exception; while ($inner.InnerException) { $inner = $inner.InnerException }
        if ($inner -is [System.UnauthorizedAccessException]) { return @{ Denied = $true; Detail = "$What denied" } }
        return @{ Denied = $false; Detail = "$What inconclusive ($($_.Exception.GetType().Name): $($_.Exception.Message))" }
    }
}

function Invoke-Ic {
    param([string[]]$A)
    $o = & icacls @A 2>&1
    if ($LASTEXITCODE -ne 0) { throw "icacls $($A -join ' ') failed (exit $LASTEXITCODE): $(($o | Out-String).Trim())" }
}
function Invoke-GitQuiet { param([string]$Dir, [string[]]$GitArgs) $o = & git -C $Dir -c user.name=t -c user.email=t@t -c core.hooksPath=NUL --no-pager @GitArgs 2>&1 | Out-String; if ($LASTEXITCODE -ne 0) { throw "git $($GitArgs -join ' ') in $Dir failed: $o" } }

function New-NarrowTree {
    # A temp tree shaped like the real machine, in its OLD (pre-stage) state.
    #   drive\                    stands in for C:\ and B:\ : Authenticated Users Modify + Users read, inheritable
    #   drive\blarai-fleet\...    the fleet root, worktrees, coder-leg   (the coder has the old explicit Modify)
    #   drive\models\             a model folder inheriting the drive
    #   projects\                 repoA, repoB, repoC (inheritance off), a junction to outside\  (old coder Modify)
    #   profile\                  carries an ACE for a deleted account
    $root = Join-Path ([IO.Path]::GetTempPath()) ('narrow-' + [guid]::NewGuid().ToString('N').Substring(0, 10))
    New-Item -ItemType Directory $root | Out-Null
    [void]$Cleanup.Add($root)
    Invoke-Ic @($root, '/inheritance:r')
    Invoke-Ic @($root, '/grant', '*S-1-5-18:(OI)(CI)F')
    Invoke-Ic @($root, '/grant', "*${User}:(M)")      # this folder only: the user can create children and inherits nothing into them
    $work = $root + '-work'; New-Item -ItemType Directory $work | Out-Null; [void]$Cleanup.Add($work)   # default access list: backups and probe output live here, outside the narrowed tree
    $t = [ordered]@{ Root = $root; Work = $work }
    foreach ($k in 'Projects', 'Drive', 'Outside', 'Profile') { $t[$k] = Join-Path $root $k.ToLowerInvariant(); New-Item -ItemType Directory $t[$k] | Out-Null }
    Invoke-Ic @($t.Drive, '/grant', "*${AuthUsers}:(OI)(CI)M")
    Invoke-Ic @($t.Drive, '/grant', "*${UsersSid}:(OI)(CI)RX")
    $t.Fleet = Join-Path $t.Drive 'blarai-fleet'; $t.Worktrees = Join-Path $t.Fleet 'worktrees'; $t.Leg = Join-Path $t.Fleet 'coder-leg'; $t.Models = Join-Path $t.Drive 'models'
    foreach ($d in $t.Fleet, $t.Worktrees, $t.Leg, (Join-Path $t.Leg 'queue'), (Join-Path $t.Leg 'results'), $t.Models) { New-Item -ItemType Directory $d | Out-Null }
    Set-Content -LiteralPath (Join-Path $t.Models 'weights.bin') -Value 'weights' -Encoding ASCII
    Invoke-Ic @($t.Fleet, '/grant', "*${User}:(OI)(CI)M", '/T', '/C')        # the OLD coder grant on the fleet tree
    $oacl = Get-Acl -LiteralPath $t.Profile
    $oacl.AddAccessRule((New-Object Security.AccessControl.FileSystemAccessRule((New-Object Security.Principal.SecurityIdentifier $OrphanSid), 'ReadAndExecute,Write', 'ContainerInherit,ObjectInherit', 'None', 'Allow')))
    Set-Acl -LiteralPath $t.Profile -AclObject $oacl
    Invoke-Ic @($t.Outside, '/grant', "*${User}:(OI)(CI)F")
    Set-Content -LiteralPath (Join-Path $t.Outside 'sentinel.txt') -Value 'outside' -Encoding ASCII
    Invoke-Ic @((Join-Path $t.Outside 'sentinel.txt'), '/grant', "*${User}:R")     # an EXPLICIT entry for the stand-in coder on a file behind the links
    Invoke-Ic @($t.Projects, '/grant', "*${User}:(OI)(CI)M")                 # the OLD coder grant on projects
    foreach ($r in 'repoA', 'repoB', 'repoC') {
        $d = Join-Path $t.Projects $r; New-Item -ItemType Directory $d | Out-Null
        Set-Content -LiteralPath (Join-Path $d 'app.txt') -Value "v1 $r" -Encoding ASCII
        Invoke-GitQuiet $d @('init', '-b', 'main'); Invoke-GitQuiet $d @('add', '-A'); Invoke-GitQuiet $d @('commit', '-m', 'seed')
    }
    $t.RepoA = Join-Path $t.Projects 'repoA'; $t.RepoC = Join-Path $t.Projects 'repoC'
    Invoke-Ic @($t.RepoC, '/inheritance:d')
    Invoke-Ic @($t.Projects, '/grant', "*${User}:(OI)(CI)M", '/T', '/C')     # exactly the old provisioning call (explicit copy on every file)
    $t.Junction = Join-Path $t.Projects 'jlink'
    New-Item -ItemType Junction -Path $t.Junction -Target $t.Outside | Out-Null
    $t.Symlink = Join-Path $t.Projects 'slink'
    New-Item -ItemType SymbolicLink -Path $t.Symlink -Target $t.Outside | Out-Null
    return $t
}

function Get-TreeSnapshot {
    # every directory (never into a link) -> its access list as sorted strings + the protected flag
    param([string]$Root)
    $snap = [ordered]@{}
    $stack = New-Object System.Collections.Stack; $stack.Push($Root)
    while ($stack.Count -gt 0) {
        $d = [string]$stack.Pop()
        try { $st = Read-AclState -Path $d } catch { $snap[$d] = 'UNREADABLE'; continue }
        $snap[$d] = (@($st.Aces | ForEach-Object { "$($_.Type)|$($_.Sid)|$($_.Rights)|$($_.Flags)|$([int]$_.Inherited)" } | Sort-Object) -join ';') + "|protected=$($st.Protected)"
        try { foreach ($k in [IO.Directory]::EnumerateDirectories($d)) { if (-not ([IO.File]::GetAttributes($k) -band [IO.FileAttributes]::ReparsePoint)) { $stack.Push($k) } } } catch { }
    }
    return $snap
}
function Compare-Snapshots($A, $B) {
    $diff = @()
    foreach ($k in $A.Keys) { if (-not $B.Contains($k)) { $diff += "missing now: $k" } elseif ($A[$k] -cne $B[$k]) { $diff += "changed: $k" } }
    foreach ($k in $B.Keys) { if (-not $A.Contains($k)) { $diff += "new: $k" } }
    return $diff
}

function Invoke-OperatorWindow {
    # The operator step. The stand-in user gets a temporary Modify on $Dir (saved ACL restored afterwards) and the
    # body runs; afterwards the directory MUST be back to its saved state or the suite fails.
    param([string]$Dir, [scriptblock]$Body)
    $save = Join-Path ([IO.Path]::GetTempPath()) ('win-' + [guid]::NewGuid().ToString('N') + '.acl')
    Invoke-Ic @($Dir, '/save', $save)
    $before = (Read-AclState -Path $Dir)
    Invoke-Ic @($Dir, '/grant', "*${User}:(OI)(CI)M")
    try { return (& $Body) }
    finally {
        Invoke-Ic @((Split-Path $Dir -Parent), '/restore', $save, '/C')
        Remove-Item -LiteralPath $save -Force -ErrorAction SilentlyContinue
        $after = (Read-AclState -Path $Dir)
        $cmp = Compare-AclStates -Expected $before -Actual $after
        if (-not $cmp.Match) { _fail "the operator window left '$Dir' changed: $($cmp.Diff -join '; ')" }
    }
}

$script:IsElevated = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
function Invoke-StandIn {
    # Run -ScriptText as the STAND-IN CODER: this user, but never with an elevated token. An elevated token
    # bypasses an explicit Deny on a folder it owns (measured 2026-10-06: rename and delete succeed with a Deny
    # on Delete and on Delete-child, elevated; both are denied from a de-elevated token), and the real coder is a
    # standard account. When this suite runs elevated the script is started with a restricted standard-user token
    # (Invoke-HiddenProcess -DeElevate), hidden, never through a console window.
    # The script text sees $A (the -Arguments hashtable) and returns one object, which comes back from JSON.
    param([Parameter(Mandatory)][string]$ScriptText, [hashtable]$Arguments = @{}, [int]$TimeoutSec = 180)
    $dir = $script:StandInDir
    $id = [guid]::NewGuid().ToString('N')
    $body = Join-Path $dir "$id.ps1"; $in = Join-Path $dir "$id.in.json"; $out = Join-Path $dir "$id.out.json"; $done = Join-Path $dir "$id.done"
    ConvertTo-Json -InputObject $Arguments -Depth 8 | Set-Content -LiteralPath $in -Encoding UTF8
    $wrapper = @"
param(`$InFile, `$OutFile, `$DoneFile)
`$ErrorActionPreference = 'Stop'
`$A = Get-Content -LiteralPath `$InFile -Raw | ConvertFrom-Json -AsHashtable
try { `$r = & { $ScriptText }; ConvertTo-Json -InputObject @{ ok = `$true; result = `$r } -Depth 12 | Set-Content -LiteralPath `$OutFile -Encoding UTF8 }
catch { ConvertTo-Json -InputObject @{ ok = `$false; error = "`$(`$_.Exception.Message)" } | Set-Content -LiteralPath `$OutFile -Encoding UTF8 }
finally { Set-Content -LiteralPath `$DoneFile -Value 'done' }
"@
    Set-Content -LiteralPath $body -Value $wrapper -Encoding UTF8
    $pw = (Get-Command pwsh).Source
    # never a window: a hidden process, de-elevated through a restricted token when this suite is elevated
    $h = Invoke-HiddenProcess -FilePath $pw -ArgumentList @('-NoProfile', '-NonInteractive', '-File', $body, $in, $out, $done) -DeElevate -TimeoutSec $TimeoutSec
    $deadline = (Get-Date).AddSeconds($TimeoutSec)
    while (-not (Test-Path -LiteralPath $done) -and (Get-Date) -lt $deadline) { Start-Sleep -Milliseconds 100 }
    if (-not (Test-Path -LiteralPath $done)) { throw "the stand-in script did not finish within ${TimeoutSec}s" }
    $res = Get-Content -LiteralPath $out -Raw | ConvertFrom-Json
    if (-not $res.ok) { throw "the stand-in script failed: $($res.error)" }
    return $res.result
}

function Invoke-StandInProbe {
    # the real probe script, run as the stand-in coder, with short timeouts and no real egress
    param([hashtable]$Lists, [string]$Tmp)
    $p = @{ SecretPaths = @(); LoopbackUrl = 'http://127.0.0.1:9/'; OutboundHost = '127.0.0.1'; OutboundPort = 9; OutboundTimeoutMs = 300 }
    foreach ($k in $Lists.Keys) { $p[$k] = @($Lists[$k]) }
    $p.Script = $ProbeScript; $p.OutJson = (Join-Path $Tmp ('probe-' + [guid]::NewGuid().ToString('N') + '.json'))
    $null = Invoke-StandIn -Arguments $p -ScriptText @'
$out = $A.OutJson; $params = @{}
foreach ($k in $A.Keys) { if ($k -notin 'Script', 'OutJson') { $params[$k] = if ($A[$k] -is [System.Collections.IEnumerable] -and $A[$k] -isnot [string]) { @($A[$k]) } else { $A[$k] } } }
& $A.Script @params -OutJson $out | Out-Null
'ok'
'@
    return (Get-Content -LiteralPath $p.OutJson -Raw | ConvertFrom-Json).checks
}

function Invoke-StandInAttempt {
    # one filesystem attempt as the stand-in coder: -Kind create-file | rename | create-dir. Returns @{ Denied; Detail }
    param([string]$Kind, [string]$Path, [string]$Dest = '')
    return (Invoke-StandIn -Arguments @{ Kind = $Kind; Path = $Path; Dest = $Dest } -ScriptText @'
try {
    switch ($A.Kind) {
        'create-file' { $s = [IO.File]::Create($A.Path); $s.Dispose(); Remove-Item -LiteralPath $A.Path -Force -ErrorAction SilentlyContinue }
        'create-dir'  { [void][IO.Directory]::CreateDirectory($A.Path) }
        'rename'      { [IO.Directory]::Move($A.Path, $A.Dest) }
    }
    @{ Denied = $false; Detail = "$($A.Kind) SUCCEEDED" }
} catch {
    $inner = $_.Exception; while ($inner.InnerException) { $inner = $inner.InnerException }
    if ($inner -is [System.UnauthorizedAccessException] -or $inner.HResult -eq -2147024891) { @{ Denied = $true; Detail = "$($A.Kind) denied" } }
    else { @{ Denied = $false; Detail = "$($A.Kind) inconclusive ($($_.Exception.GetType().Name): $($_.Exception.Message))" } }
}
'@)
}

function Remove-NarrowTree {
    param([string]$Root)
    if (-not $Root -or -not (Test-Path -LiteralPath $Root)) { return }
    if ((Split-Path $Root -Leaf) -notlike 'narrow-*') { return }
    try {
        # a stand-in coder deny (worktree roots) would block the delete: owners can clear their own DACLs
        Invoke-Ic @($Root, '/remove:d', "*$User", '/T', '/C', '/L')
        Invoke-Ic @($Root, '/grant', "*${User}:(OI)(CI)F", '/T', '/C', '/L')
        Get-ChildItem -LiteralPath $Root -Recurse -Force -ErrorAction SilentlyContinue | Where-Object { $_.Attributes -band [IO.FileAttributes]::ReadOnly } | ForEach-Object { try { $_.Attributes = $_.Attributes -band (-bnot [IO.FileAttributes]::ReadOnly) } catch { } }
        foreach ($j in @(Get-ChildItem -LiteralPath $Root -Recurse -Force -Attributes ReparsePoint -ErrorAction SilentlyContinue)) { try { [IO.Directory]::Delete($j.FullName) } catch { } }
        Remove-Item -LiteralPath $Root -Recurse -Force -ErrorAction SilentlyContinue
    } catch { }
}

function Get-PlanDigest($StageParams) { return (Invoke-CoderAclStage -Mode DryRun @StageParams -Out { param($l) }).Digest }

function Get-StageParams($t) {
    @{ CoderSid = $User; OperatorSid = $OperatorDummy; ProjectsDir = $t.Projects; WorktreeBase = $t.Worktrees; LegRoot = $t.Leg
       ModelRoots = @($t.Models); ProfileCleanupPaths = @($t.Profile); CoderGroupSids = @('S-1-1-0', 'S-1-5-11', 'S-1-5-32-545'); SkipOwnerCheck = $true }
}

try {

# =========================================================================================================
Section 'the ACE model and the simulator (pure)'
$st0 = [pscustomobject]@{ Path = 'X'; Owner = $null; Protected = $false; Aces = @(
    (New-Ace -Sid 'S-1-5-11' -Rights 'M' -Flags '(OI)(CI)' -Inherited $true),
    (New-Ace -Sid 'S-1-5-100' -Rights 'M' -Flags '(OI)(CI)'),
    (New-Ace -Sid 'S-1-5-100' -Rights 'DC' -Type 'Deny')) }
$r = Invoke-AclSimulation -State $st0 -Op (New-AclOp RemoveGrants -Sid 'S-1-5-11')
Assert-Eq 3 $r.Aces.Count 'RemoveGrants leaves an INHERITED ACE of the same SID (icacls /remove:g does)'
$r = Invoke-AclSimulation -State $st0 -Op (New-AclOp RemoveGrants -Sid 'S-1-5-100')
Assert-Eq 2 $r.Aces.Count 'RemoveGrants removes the explicit grant but not the deny'
$r = Invoke-AclSimulation -State $st0 -Op (New-AclOp SetGrant -Sid 'S-1-5-100' -Rights 'RX' -Flags '(OI)(CI)')
Assert-True (@($r.Aces | Where-Object { $_.Sid -eq 'S-1-5-100' -and $_.Type -eq 'Allow' }).Count -eq 1 -and @($r.Aces | Where-Object { $_.Sid -eq 'S-1-5-100' -and $_.Rights -eq 'RX' }).Count -eq 1) 'SetGrant REPLACES the SID''s explicit grants'
$r = Invoke-AclSimulation -State $st0 -Op (New-AclOp AddGrant -Sid 'S-1-5-100' -Rights 'RX' -Flags '')
Assert-Eq 4 $r.Aces.Count 'AddGrant adds without replacing (different flags: a separate entry)'
$r2 = Invoke-AclSimulation -State $r -Op (New-AclOp AddGrant -Sid 'S-1-5-100' -Rights 'RX' -Flags '')
Assert-Eq 4 $r2.Aces.Count 'AddGrant is idempotent'
$r3 = Invoke-AclSimulation -State $st0 -Op (New-AclOp AddGrant -Sid 'S-1-5-100' -Rights 'RX' -Flags '(OI)(CI)')
Assert-Eq 3 $r3.Aces.Count 'AddGrant of rights an existing same-flags entry already holds is absorbed'
$r = Invoke-AclSimulation -State $st0 -Op (New-AclOp DisableInheritanceCopy)
Assert-True ($r.Protected -and @($r.Aces | Where-Object { $_.Inherited }).Count -eq 0) 'DisableInheritanceCopy makes inherited ACEs explicit and protects the list'
Assert-True (-not $st0.Protected -and @($st0.Aces | Where-Object { $_.Inherited }).Count -eq 1) 'the simulator does not modify its input'
$threw = $false; try { Invoke-AclSimulation -State $st0 -Op (New-AclOp EnableInheritance) | Out-Null } catch { $threw = $true }
Assert-True $threw 'EnableInheritance is refused by the simulator (rollback-only)'
Assert-True (Test-AceWriteCapable (New-Ace -Sid 'S' -Rights 'M')) 'Modify is write-capable'
Assert-True (-not (Test-AceWriteCapable (New-Ace -Sid 'S' -Rights 'RX'))) 'Read and run is not write-capable'
Assert-True (Test-AceWriteCapable (New-Ace -Sid 'S' -Mask 0x10000000)) 'a GENERIC_ALL bit counts as write-capable'

Section 'the exact icacls commands (pure)'
$c = ConvertTo-IcaclsCommand -Path 'C:\p' -Op (New-AclOp RemoveGrants -Sid 'S-1-5-9' -Tree)
Assert-Eq 'C:\p|/remove:g|*S-1-5-9' ($c -join '|') 'tree undo of the old grant: the per-object icacls form, never /T (icacls /T follows directory symlinks)'
Assert-True ((Format-AclOpText -Path 'C:\p' -Op (New-AclOp RemoveGrants -Sid 'S-1-5-9' -Tree)) -match 'WALK every folder and file under C:\\p \(links are listed and never entered\)') 'a tree op is printed as a walk, with the per-object command'
$c = ConvertTo-IcaclsCommand -Path 'C:\p' -Op (New-AclOp SetGrant -Sid 'S-1-5-9' -Rights 'RX' -Flags '(OI)(CI)')
Assert-Eq 'C:\p|/grant:r|*S-1-5-9:(OI)(CI)(RX)' ($c -join '|') 'the read ACE: inheritable read-and-execute, one ACE'
$c = ConvertTo-IcaclsCommand -Path 'C:\p' -Op (New-AclOp Deny -Sid 'S-1-5-9' -Rights 'DE' -Flags '(CI)(IO)(NP)')
Assert-Eq 'C:\p|/deny|*S-1-5-9:(CI)(IO)(NP)(DE)' ($c -join '|') 'the worktree-root deny: inherit-only, container, no-propagate'
Assert-Eq 'C:\p|/inheritance:d' ((ConvertTo-IcaclsCommand -Path 'C:\p' -Op (New-AclOp DisableInheritanceCopy)) -join '|') 'inheritance off keeps a copy (/inheritance:d)'
foreach ($op in 'RemoveGrants', 'SetGrant', 'AddGrant', 'Deny', 'RemoveDenies', 'DisableInheritanceCopy') {
    $x = ConvertTo-IcaclsCommand -Path 'C:\p' -Op (New-AclOp $op -Sid 'S-1-5-9' -Rights 'M' -Flags '(OI)(CI)' -Tree)
    Assert-True (($x -notcontains '/T') -and ($x -notcontains '/L')) "$op with -Tree never carries /T (the walk is ours, not icacls's)"
}

# =========================================================================================================
Section 'the plan (pure, fake access lists)'
$fakeModel = [pscustomobject]@{ Path = 'M'; Owner = $null; Protected = $false; Aces = @(
    (New-Ace -Sid 'S-1-5-18' -Rights 'F' -Flags '(OI)(CI)' -Inherited $true), (New-Ace -Sid 'S-1-5-32-544' -Rights 'F' -Flags '(OI)(CI)' -Inherited $true),
    (New-Ace -Sid 'S-1-5-11' -Rights 'M' -Flags '(OI)(CI)' -Inherited $true -Name 'NT AUTHORITY\Authenticated Users'),
    (New-Ace -Sid 'S-1-5-32-545' -Rights 'RX' -Flags '(OI)(CI)' -Inherited $true), (New-Ace -Sid 'S-1-3-0' -Rights 'F' -Flags '(OI)(CI)(IO)' -Inherited $true)) }
$readFake = { param($p) if ($p -like '*missing*') { throw 'not found' }; if ($p -like '*prot*') { return [pscustomobject]@{ Path = $p; Owner = $null; Protected = $true; Aces = @((New-Ace -Sid 'S-1-5-18' -Rights 'F' -Flags '(OI)(CI)'), (New-Ace -Sid 'S-1-5-32-544' -Rights 'F' -Flags '(OI)(CI)'), (New-Ace -Sid $OperatorDummy -Rights 'M' -Flags '(OI)(CI)'), (New-Ace -Sid 'S-1-5-32-545' -Rights 'RX' -Flags '(OI)(CI)')) } }; return $fakeModel }
$plan = @(Get-CoderAclPlan -CoderSid $User -OperatorSid $OperatorDummy -ProjectsDir 'C:\P\projects' -WorktreeBase 'C:\F\blarai-fleet\worktrees' -ModelRoots @('B:\models', 'B:\missing', 'B:\protected') -ProfileCleanupPaths @() -ReadAcl $readFake)
$byId = @{}; foreach ($a in $plan) { $byId[$a.Id] = $a }
$pn = $byId['projects-narrow']
Assert-True ($null -ne $pn) 'the plan has the projects-narrow action'
Assert-Eq 'RemoveGrants|SetGrant' (($pn.Steps | ForEach-Object { $_.Op }) -join '|') 'projects: undo the old grant FIRST, then set the read ACE'
Assert-True ($pn.Steps[0].Tree -and $pn.Steps[0].Sid -eq $User) 'projects: the undo walks the tree for the coder SID'
Assert-True ($pn.Steps[1].Rights -eq 'RX' -and $pn.Steps[1].Flags -eq '(OI)(CI)' -and -not $pn.Steps[1].Tree) 'projects: the new ACE is inheritable read-and-execute, set once on the root'
Assert-True (@($plan | ForEach-Object { $_.Steps } | Where-Object { $_.Sid -eq $User -and $_.Op -in 'SetGrant', 'AddGrant' -and $_.Rights -in 'M', 'F' } | Where-Object { $true }).Count -eq 2) 'the coder gets Modify in exactly two places (worktrees, coder-leg) and nowhere else'
Assert-True ($pn.Undo[1].Rights -eq 'M' -and $pn.Undo[1].Flags -eq '(OI)(CI)' -and -not $pn.Undo[1].Tree -and -not $pn.Undo[0].Tree) 'projects: the rollback listing restores the old inheritable Modify on the root (no tree walk)'
$fr = $byId['fleet-root']
Assert-True ((($fr.Steps | ForEach-Object { "$($_.Op):$($_.Sid)" }) -join ' ') -match 'DisableInheritanceCopy.*RemoveGrants:S-1-5-11.*RemoveGrants:S-1-5-32-545.*RemoveGrants:' + [regex]::Escape($User)) 'fleet root: inheritance off, Authenticated Users and Users removed, the coder''s old grant removed'
Assert-True ($fr.Steps[-1].Sid -eq $User -and $fr.Steps[-1].Rights -eq 'RX' -and $fr.Steps[-1].Flags -eq '') 'fleet root: the coder keeps READ on the root folder only'
Assert-True ($byId['fleet-worktrees'].Steps[0].Rights -eq 'M' -and $byId['fleet-coder-leg'].Steps[0].Rights -eq 'M') 'fleet: Modify on worktrees and coder-leg'
Assert-Eq 'RemoveDenies|Deny|Deny' (($byId['worktree-root-deny'].Steps | ForEach-Object { $_.Op }) -join '|') 'worktree-root deny: re-runnable (removes its own denies first)'
$mid = @($plan | Where-Object { $_.Id -like 'models-B-models' })[0]
Assert-True ($null -ne $mid -and (($mid.Steps | ForEach-Object { "$($_.Op):$($_.Sid):$($_.Rights)" }) -contains 'RemoveGrants:S-1-5-11:') -and (($mid.Steps | ForEach-Object { "$($_.Op):$($_.Sid):$($_.Rights)" }) -contains 'AddGrant:S-1-5-11:RX')) 'models: Authenticated Users loses Modify AND keeps read'
Assert-True (@($mid.Steps | Where-Object { $_.Op -eq 'AddGrant' -and $_.Sid -eq $OperatorDummy -and $_.Rights -eq 'M' }).Count -eq 1) 'models: the operator is given Modify additively'
Assert-True (@($mid.Steps | Where-Object { $_.Op -eq 'DisableInheritanceCopy' }).Count -eq 1) 'models: inheritance is switched off (a copy is kept) so the parent''s write grant cannot return'
Assert-True (@($plan | Where-Object { $_.Id -like 'models-B-missing' -and $_.Skipped }).Count -eq 1) 'a missing model folder is reported as SKIPPED, not silently ignored'
$mprot = @($plan | Where-Object { $_.Id -like 'models-B-protected' })[0]
Assert-Eq 0 @($mprot.Steps).Count 'a model folder with no foreign writer is left alone'
$plan2 = @(Get-CoderAclPlan -CoderSid $User -OperatorSid $OperatorDummy -ProjectsDir 'C:\P\projects' -WorktreeBase 'C:\F\blarai-fleet\worktrees' -ModelRoots @() -ProfileCleanupPaths @('C:\prof') -ReadAcl { param($p) [pscustomobject]@{ Path = $p; Owner = $null; Protected = $false; Aces = @((New-Ace -Sid $OrphanSid -Rights 'RX' -Flags '(OI)(CI)' -Orphan $true)) } })
Assert-True (@($plan2 | Where-Object { $_.Id -like 'orphan-*' -and $_.Steps[0].Op -eq 'RemoveGrants' -and $_.Steps[0].Sid -eq $OrphanSid }).Count -eq 1) 'an ACE for a deleted account is removed'

Section 'the narrowing verdict (pure truth table)'
$all = @{ AclNoCoderWrite = $true; SiblingWriteDenied = $true; NewRepoWriteDenied = $true; SourceGitWriteDenied = $true; WorktreeCommitFails = $true; ReadAssetsOk = $true; WorktreeWriteOk = $true; NewRepoInheritsRead = $true; FunnelCommitOk = $true; FunnelMergeOk = $true }
Assert-True ((Get-NarrowingVerdict @all).Pass) 'all ten inputs true -> pass'
$names = @{ AclNoCoderWrite = 'check5'; SiblingWriteDenied = 'check6'; NewRepoWriteDenied = 'check7'; SourceGitWriteDenied = 'check8'; WorktreeCommitFails = 'check9'; ReadAssetsOk = 'check10'; WorktreeWriteOk = 'check11'; NewRepoInheritsRead = 'check12'; FunnelCommitOk = 'check13'; FunnelMergeOk = 'check14' }
foreach ($k in $names.Keys) {
    $x = $all.Clone(); $x[$k] = $false; $v = Get-NarrowingVerdict @x
    Assert-True ((-not $v.Pass) -and $v.Failed.Count -eq 1 -and $v.Failed[0] -like "$($names[$k])-*") "$k false -> fails with exactly $($names[$k])"
}

# =========================================================================================================
Section 'the safe-target gate'
$g = Join-Path ([IO.Path]::GetTempPath()) ('narrow-gate-' + [guid]::NewGuid().ToString('N').Substring(0, 8)); New-Item -ItemType Directory $g | Out-Null; [void]$Cleanup.Add($g)
New-Item -ItemType Directory (Join-Path $g 'real\sub') -Force | Out-Null
New-Item -ItemType Junction -Path (Join-Path $g 'jct') -Target (Join-Path $g 'real') | Out-Null
New-Item -ItemType Directory (Join-Path $g 'tree\inner') -Force | Out-Null
New-Item -ItemType Junction -Path (Join-Path $g 'tree\inner\jin') -Target (Join-Path $g 'real') | Out-Null
$ok = Test-AclTargetSafe -Path (Join-Path $g 'real')
Assert-True $ok.Ok 'a real folder is accepted'
foreach ($case in @(
    @('relative path', 'projects\x', 'not an absolute drive path'), @('empty', '', 'empty path'), @('wildcard star', (Join-Path $g 'real\*'), 'wildcard'), @('wildcard question', (Join-Path $g 'real\?'), 'wildcard'),
    @('dot-dot', (Join-Path $g 'real\..\real'), 'dot-dot'), @('drive root', 'C:\', 'drive root'), @('system folder', 'C:\Windows', 'system or profile-root'), @('profile root', $env:USERPROFILE, 'system or profile-root'),
    @('does not exist', (Join-Path $g 'nope'), 'does not exist'), @('is a junction', (Join-Path $g 'jct'), 'is a link'), @('below a junction', (Join-Path $g 'jct\sub'), 'sits below the link'), @('UNC path', '\\server\share\x', 'not an absolute drive path'))) {
    $x = Test-AclTargetSafe -Path $case[1]
    Assert-True ((-not $x.Ok) -and $x.Reason -match $case[2]) "refused: $($case[0]) for the RIGHT reason ($($x.Reason))"
}
$tr = Test-AclTargetSafe -Path (Join-Path $g 'tree') -Tree
Assert-True ($tr.Ok -and @($tr.Links).Count -eq 1 -and $tr.Links[0].Path -like '*jin') 'a link INSIDE a tree target is reported, not followed'
$calls = 0
$bad = New-AclAction -Id 'x' -Issue '#0' -Title 't' -Path (Join-Path $g 'real\*') -Plain 'p' -Steps @((New-AclOp RemoveGrants -Sid $User)) -Undo @()
$thr = $null; try { Invoke-CoderAclAction -Action $bad -Runner { $script:calls++ } | Out-Null } catch { $thr = $_.Exception.Message }
Assert-True ($thr -like 'refusing*' -and $script:calls -eq 0) 'an unsafe target throws BEFORE any command runs'
$goodAct = New-AclAction -Id 'x' -Issue '#0' -Title 't' -Path (Join-Path $g 'real') -Plain 'p' -Steps @((New-AclOp RemoveGrants -Sid $User)) -Undo @()
$script:calls = 0; try { Invoke-CoderAclAction -Action $goodAct -Runner { $script:calls++ } | Out-Null } catch { }
Assert-Eq 1 $script:calls 'a safe target does run its command through the runner'

Section 'CONTROL: icacls /T /L still reaches through a directory symlink; the own walk does not (so the test below could have disagreed)'
$ctl = Join-Path $g 'ctl'; New-Item -ItemType Directory (Join-Path $ctl 'tree') -Force | Out-Null; New-Item -ItemType Directory (Join-Path $ctl 'target') -Force | Out-Null
Set-Content -LiteralPath (Join-Path $ctl 'target\f.txt') -Value 'x' -Encoding ASCII
Invoke-Ic @((Join-Path $ctl 'target\f.txt'), '/grant', '*S-1-5-9:R')
$symOk = $true; try { New-Item -ItemType SymbolicLink -Path (Join-Path $ctl 'tree\s') -Target (Join-Path $ctl 'target') -ErrorAction Stop | Out-Null } catch { $symOk = $false }
Assert-True $symOk 'a directory symlink can be created here (the control needs one; Developer Mode or elevation)'
if ($symOk) {
    $sf = Join-Path $ctl 'target\f.txt'
    Invoke-Ic @((Join-Path $ctl 'tree'), '/remove:g', '*S-1-5-9', '/T', '/C', '/L')
    Assert-Eq 0 @((Read-AclState -Path $sf).Aces | Where-Object { $_.Sid -eq 'S-1-5-9' -and -not $_.Inherited }).Count 'icacls /remove:g /T /C /L removed an entry from a FILE BEHIND the symlink (why the stage does not use icacls /T)'
    Invoke-Ic @($sf, '/grant', '*S-1-5-9:R')
    $w = Invoke-AclTreeRemoveGrants -Root (Join-Path $ctl 'tree') -Sid 'S-1-5-9'
    Assert-Eq 1 @((Read-AclState -Path $sf).Aces | Where-Object { $_.Sid -eq 'S-1-5-9' -and -not $_.Inherited }).Count 'the own no-follow walk leaves the same file behind the symlink alone'
    Assert-True (@($w.Links).Count -eq 1 -and $w.Links[0] -like '*\s') 'the walk lists the symlink instead of entering it'
}
Section 'removing the explicit entries of one SID by type (the rollback of the provisioning removes both)'
$td = Join-Path $g 'types'; New-Item -ItemType Directory $td | Out-Null
Invoke-Ic @($td, '/grant', '*S-1-5-9:(OI)(CI)R'); Invoke-Ic @($td, '/deny', '*S-1-5-9:(DC)')
$cnt = { param($t) @((Read-AclState -Path $td).Aces | Where-Object { $_.Sid -eq 'S-1-5-9' -and $_.Type -eq $t -and -not $_.Inherited }).Count }
[void](Remove-ExplicitGrantOfSid -Path $td -IsDir $true -Sid 'S-1-5-9' -Type Allow)
Assert-True ((& $cnt 'Allow') -eq 0 -and (& $cnt 'Deny') -eq 1) 'Type Allow removes the grant and leaves the deny'
[void](Remove-ExplicitGrantOfSid -Path $td -IsDir $true -Sid 'S-1-5-9' -Type Deny)
Assert-True ((& $cnt 'Deny') -eq 0) 'Type Deny then removes the deny'

Section 'the no-follow walk'
$wk = Join-Path $g 'walk'; New-Item -ItemType Directory (Join-Path $wk 'a\b') -Force | Out-Null
Set-Content -LiteralPath (Join-Path $wk 'a\b\f.txt') -Value 'x' -Encoding ASCII; Set-Content -LiteralPath (Join-Path $wk 'top.txt') -Value 'x' -Encoding ASCII
New-Item -ItemType Junction -Path (Join-Path $wk 'a\jct') -Target (Join-Path $g 'real') | Out-Null
$seen = New-Object System.Collections.ArrayList
$wr = Invoke-NoFollowWalk -Root $wk -OnObject { param($p, $d) [void]$seen.Add($p) }
Assert-Eq 5 $wr.Visited 'the walk visits the root, a, a\b, f.txt and top.txt (five objects)'
Assert-True (@($seen | Where-Object { $_ -like '*jct*' -or $_ -like '*sub*' }).Count -eq 0) 'nothing under or at the junction is visited'
Assert-True (@($wr.Links).Count -eq 1) 'the junction is reported'
$wr2 = Invoke-NoFollowWalk -Root $wk -OnObject { param($p, $d) if ($p -like '*f.txt') { throw 'boom' } }
Assert-True (@($wr2.Errors).Count -eq 1 -and $wr2.Visited -eq 4) 'an object that fails is recorded, the walk goes on'

# =========================================================================================================
Section 'the stage on a temp tree: DRY RUN changes nothing and prints the contract'
$t1 = New-NarrowTree
$P1 = Get-StageParams $t1
$snapA = Get-TreeSnapshot $t1.Root
Test-Step 'dry run' {
    $lines = New-Object System.Collections.ArrayList
    $res = Invoke-CoderAclStage -Mode DryRun @P1 -Out { param($l) [void]$lines.Add([string]$l) }
    $txt = ($lines -join "`n")
    Assert-True $res.Ok 'the dry run reports Ok (no refusals)'
    Assert-True ($txt -match '=== DRY RUN: nothing below has been changed ===') 'dry run: opens by saying nothing has been changed'
    foreach ($needle in 'BEFORE:', 'AFTER', 'COMMANDS THAT WILL RUN, in order:', 'UNDO (rollback listing):', 'WHAT:', 'FOLDER:', 'BACKUP written before any change', 'RESTORE from that backup', 'NOTHING WAS CHANGED') {
        Assert-True ($txt.Contains($needle)) "dry run prints '$needle'"
    }
    Assert-True ($txt -match 'inheritance from the parent folder: ON' -and $txt -match 'inheritance from the parent folder: OFF') 'dry run shows inheritance before (ON) and after (OFF) for the fleet root'
    Assert-True ($txt -match 'icacls .*/remove:g \*' -and $txt -match 'WALK every folder and file under' -and $txt -notmatch '/T /C') 'dry run prints the exact icacls commands, and the tree walk (never icacls /T)'
    Assert-True ($txt -match 'SIZE OF THE TREE WALKS' -and $txt -match 'objects to walk') 'dry run counts the objects the walks will cover (read-only)'
    Assert-True ($txt -match 'blarai-coder \(the coder account\)') 'dry run names the coder account in plain words'
    Assert-True ($txt -match 'account that no longer exists' -or $txt -match 'deleted account') 'dry run names the orphan entry in plain words'
    Assert-True ($txt -match 'LINKS INSIDE THIS TREE \(2\)' -and $txt -match 'jlink' -and $txt -match 'slink') 'dry run lists the junction and the symlink inside projects and says they are never entered'
    $n = [regex]::Matches($txt, '^\[\d+/\d+\] ', 'Multiline').Count
    Assert-True ($n -ge 7) "dry run numbers every action ($n)"
}
$snapB = Get-TreeSnapshot $t1.Root
Assert-Eq 0 @(Compare-Snapshots $snapA $snapB).Count 'after the dry run every access list in the tree is byte-for-byte what it was'
Assert-True (@((Find-ProtectedChildren -Root $t1.Projects -Depth 1)).Count -eq 1) 'the repo with inheritance switched off is found (the stage lists it)'

Section 'the stage on a temp tree: APPLY'
$backup1 = Join-Path $t1.Work 'backup'
$applyLines = New-Object System.Collections.ArrayList
$ar = $null
Test-Step 'apply' { $script:ar = Invoke-CoderAclStage -Mode Apply @P1 -ExpectPlan (Get-PlanDigest $P1) -BackupDir $backup1 -Out { param($l) [void]$applyLines.Add([string]$l) } }
Assert-True ($null -ne $ar -and $ar.Ok) "apply reports Ok (mismatches: $(@($ar.Mismatches) -join ' | '); findings: $(@($ar.Findings) -join ' | '))"
Assert-Eq 0 @($ar.Mismatches).Count 'every changed folder equals its printed AFTER (the simulator agrees with icacls)'
Assert-True ((Test-Path (Join-Path $backup1 'manifest.json')) -and @(Get-ChildItem $backup1 -Filter '*.jsonl').Count -ge 3) 'the backup (manifest + saved access lists) was written before the change'
$full = Find-SidWriteAcesTree -Root $t1.Projects -Sid $User
Assert-True ($full.Hits.Count -eq 0 -and $full.Visited -gt 20) "full walk: no object in the projects tree has a write entry for the coder ($($full.Visited) objects, incl. the protected repo)"
Assert-True ($full.Links.Count -eq 2) 'the full walk saw the two links and did not enter them'
$ps = Read-AclState -Path $t1.Projects
Assert-True (@($ps.Aces | Where-Object { $_.Sid -eq $User -and $_.Rights -eq 'RX' -and $_.Flags -eq '(OI)(CI)' -and -not $_.Inherited }).Count -eq 1) 'projects carries ONE explicit inheritable read-and-run ACE for the coder'
$rcState = Read-AclState -Path $t1.RepoC
Assert-True (@($rcState.Aces | Where-Object { $_.Sid -eq $User -and (Test-AceWriteCapable $_) }).Count -eq 0) 'the old Modify is gone from the repo whose inheritance is off (the tree walk reached it)'
$outsideAfter = Read-AclState -Path $t1.Outside
Assert-True (@($outsideAfter.Aces | Where-Object { $_.Sid -eq $User -and $_.Rights -eq 'F' -and -not $_.Inherited }).Count -eq 1) 'the folder the links point at kept its access list'
$sent = Read-AclState -Path (Join-Path $t1.Outside 'sentinel.txt')
Assert-True (@($sent.Aces | Where-Object { $_.Sid -eq $User -and $_.Rights -eq 'R' -and -not $_.Inherited }).Count -eq 1) 'the file behind the junction and the symlink kept its explicit entry (the links were not followed)'
$fl = Read-AclState -Path $t1.Fleet
Assert-True ($fl.Protected -and @($fl.Aces | Where-Object { $_.Sid -in $AuthUsers, $UsersSid }).Count -eq 0) 'fleet root: inheritance off, Authenticated Users and Users have no entry'
Assert-True (@($fl.Aces | Where-Object { $_.Sid -eq $User -and (Test-AceWriteCapable $_) }).Count -eq 0) 'fleet root: the coder has no write entry on the root'
$wtState = Read-AclState -Path $t1.Worktrees
Assert-True (@($wtState.Aces | Where-Object { $_.Type -eq 'Deny' -and $_.Sid -eq $User }).Count -eq 2) 'the worktree base carries the two deny entries'
$mm = Read-AclState -Path $t1.Models
Assert-True ($mm.Protected -and @($mm.Aces | Where-Object { $_.Sid -eq $AuthUsers -and (Test-AceWriteCapable $_) }).Count -eq 0 -and @($mm.Aces | Where-Object { $_.Sid -eq $AuthUsers -and $_.Rights -eq 'RX' }).Count -eq 1) 'model folder: no write for Authenticated Users, read kept'
Assert-True (@((Read-AclState -Path $t1.Profile).Aces | Where-Object { $_.Orphan }).Count -eq 0) 'the deleted-account entry is gone'

Section 'the stand-in coder: NEGATIVE checks, as the coder'
# a repo created AFTER the stage, with seeded assets, as create_project(seed_assets=True) makes one
$scratch = Invoke-OperatorWindow -Dir $t1.Projects -Body { New-VerifyScratchRepo -ProjectsDir $t1.Projects -WorktreeBase $t1.Worktrees }
Assert-True ((Test-Path $scratch.Repo) -and (Test-Path $scratch.Readme) -and (Test-Path $scratch.Worktree)) 'the scratch repo, its seeded assets and its worktree exist'
$checks = $null
Test-Step 'probe' { $script:checks = Invoke-StandInProbe -Tmp $t1.Work -Lists @{ WriteDenyDirs = @($t1.RepoA, $scratch.Repo); SourceGitRepos = @($scratch.Repo); ReadFiles = @($scratch.Readme); WorktreePaths = @($scratch.Worktree) } }
Assert-True ([bool]$checks.write_outside_denied.per_path.($t1.RepoA).pass) 'cannot create a file in a SIBLING repo that existed before'
Assert-True ([bool]$checks.write_outside_denied.per_path.($scratch.Repo).pass) 'cannot create a file in the NEW (create_project) repo'
Assert-True ([bool]$checks.source_git_write_denied.per_path.("$($scratch.Repo) refs").pass) 'cannot create .git/refs/heads/x in the source repo'
Assert-True ([bool]$checks.source_git_write_denied.per_path.("$($scratch.Repo) objects").pass) 'cannot create .git/objects/xx in the source repo'
Assert-True ([bool]$checks.worktree_commit_fails.pass) "git add/commit in the worktree FAILS for a permission reason ($($checks.worktree_commit_fails.per_path.($scratch.Worktree).detail))"
Section 'the stand-in coder: POSITIVE checks, as the coder'
Assert-True ([bool]$checks.read_files_ok.pass) 'can read assets/README.txt of the seeded new repo'
Assert-True ([bool]$checks.worktree_write_ok.pass) 'can still write inside its own worktree'
Assert-True (-not (Test-Path (Join-Path $t1.RepoA 'blarai-probe-*'))) 'the probe left no file behind in the sibling repo'
$fleetCreate = Invoke-StandInAttempt -Kind create-file -Path (Join-Path $t1.Fleet 'x.tmp')
Assert-True ([bool]$fleetCreate.Denied) 'cannot create a file in the fleet root (Authenticated Users no longer holds Modify there)'
$rootDeny = Invoke-StandInAttempt -Kind rename -Path $scratch.Worktree -Dest (Join-Path $t1.Worktrees 'renamed')
Assert-True ([bool]$rootDeny.Denied) "cannot rename or delete its worktree root ($($rootDeny.Detail))"
$sel = $null
$inheritOk = (@((Read-AclState -Path $scratch.Repo).Aces | Where-Object { $_.Type -eq 'Allow' -and $_.Inherited -and $_.Sid -eq $User -and $_.Rights -eq 'RX' }).Count -gt 0)
Assert-True $inheritOk 'a repo created AFTER the stage carries the INHERITED read ACE'
$fun = Invoke-OperatorWindow -Dir $scratch.Repo -Body { Invoke-VerifyFunnel -Scratch $scratch }
Assert-True ($fun.CommitOk -and $fun.MergeOk) "the operator funnel commits what the coder wrote and the first dispatch merges to main ($($fun.Detail))"
$nv = Get-NarrowingFromProbe -Checks $checks -SiblingDir $t1.RepoA -NewRepoDir $scratch.Repo -AclNoCoderWrite (@(Find-SidWriteAces -Root $t1.Projects -Sid $User -Depth 2).Count -eq 0) -NewRepoInheritsRead $inheritOk -FunnelCommitOk $fun.CommitOk -FunnelMergeOk $fun.MergeOk
Assert-True $nv.Verdict.Pass "the shared verdict function passes all ten checks (failed: $(@($nv.Verdict.Failed) -join ','))"

Section 'TOGGLE TEST: restore the Modify grant on projects and the probe must FAIL'
Invoke-Ic @($t1.Projects, '/grant', "*${User}:(OI)(CI)M", '/T', '/C', '/L')
$checks2 = $null
Test-Step 'probe after toggle' { $script:checks2 = Invoke-StandInProbe -Tmp $t1.Work -Lists @{ WriteDenyDirs = @($t1.RepoA, $scratch.Repo); SourceGitRepos = @($scratch.Repo); ReadFiles = @($scratch.Readme); WorktreePaths = @($scratch.Worktree) } }
$hits2 = @(Find-SidWriteAces -Root $t1.Projects -Sid $User -Depth 2)
$nv2 = Get-NarrowingFromProbe -Checks $checks2 -SiblingDir $t1.RepoA -NewRepoDir $scratch.Repo -AclNoCoderWrite ($hits2.Count -eq 0) -NewRepoInheritsRead $inheritOk -FunnelCommitOk $true -FunnelMergeOk $true
Assert-True (-not $nv2.Verdict.Pass) 'with Modify restored the verdict FAILS'
foreach ($want in 'check5-no-coder-write-ace-on-projects', 'check6-sibling-repo-write-denied', 'check7-new-repo-write-denied', 'check8-source-git-write-denied', 'check9-worktree-commit-fails') {
    Assert-True ($nv2.Verdict.Failed -contains $want) "toggle: $want fails when the grant is restored"
}
Assert-True ($hits2.Count -gt 0) 'toggle: the operator-side scan sees the restored write ACE'

# =========================================================================================================
Section 'the read-back comparison can fail (the printed AFTER is checked against the real result)'
$t6 = New-NarrowTree; $P6 = Get-StageParams $t6
Test-Step 'readback' {
    $mm = & {
        # a simulator that is wrong on purpose: the real result then differs from the computed AFTER
        function Get-AclActionAfter { param($Before, $Action) return $Before }
        Invoke-CoderAclStage -Mode Apply @P6 -ExpectPlan (Get-PlanDigest $P6) -BackupDir (Join-Path $t6.Work 'bk') -Out { param($l) }
    }
    Assert-True ((-not $mm.Ok) -and @($mm.Mismatches).Count -ge 1) "a wrong computed AFTER is reported as a mismatch and the stage is not Ok ($(@($mm.Mismatches).Count) mismatches)"
}

Section 'idempotence: applying the stage a second time changes nothing'
$t2 = New-NarrowTree; $P2 = Get-StageParams $t2
Test-Step 'idempotent' {
    $r1 = Invoke-CoderAclStage -Mode Apply @P2 -ExpectPlan (Get-PlanDigest $P2) -BackupDir (Join-Path $t2.Work 'b1') -Out { param($l) }
    $s1 = Get-TreeSnapshot $t2.Root
    $r2 = Invoke-CoderAclStage -Mode Apply @P2 -ExpectPlan (Get-PlanDigest $P2) -BackupDir (Join-Path $t2.Work 'b2') -Out { param($l) }
    $s2 = Get-TreeSnapshot $t2.Root
    Assert-True ($r1.Ok -and $r2.Ok) "both runs report Ok (second: $(@($r2.Mismatches) -join ' | '))"
    $d = @(Compare-Snapshots $s1 $s2)
    Assert-Eq 0 $d.Count "the second run left every access list unchanged ($($d -join '; '))"
    $lines = New-Object System.Collections.ArrayList
    $null = Invoke-CoderAclStage -Mode DryRun @P2 -Out { param($l) [void]$lines.Add([string]$l) }
    Assert-True (($lines -join "`n") -match 'already in the wanted state') 'a dry run after the stage says the folders are already in the wanted state'
}

Section 'RESTORE from the backup puts every saved access list back exactly'
$t3 = New-NarrowTree; $P3 = Get-StageParams $t3
$snapBefore3 = Get-TreeSnapshot $t3.Projects
$fleetBefore3 = Get-TreeSnapshot $t3.Fleet
Test-Step 'restore' {
    $bk = Join-Path $t3.Work 'bk'
    $r = Invoke-CoderAclStage -Mode Apply @P3 -ExpectPlan (Get-PlanDigest $P3) -BackupDir $bk -Out { param($l) }
    Assert-True $r.Ok 'apply ok before restoring'
    Assert-True (@(Compare-Snapshots $snapBefore3 (Get-TreeSnapshot $t3.Projects)).Count -gt 0) 'the stage did change the projects tree (so the restore has something to undo)'
    $null = Invoke-CoderAclStage -Mode Restore -RestoreFrom $bk -Out { param($l) }
    $d1 = @(Compare-Snapshots $snapBefore3 (Get-TreeSnapshot $t3.Projects))
    Assert-Eq 0 $d1.Count "projects tree: every directory's access list is back to the saved original ($($d1 -join '; '))"
    $d2 = @(Compare-Snapshots $fleetBefore3 (Get-TreeSnapshot $t3.Fleet))
    Assert-Eq 0 $d2.Count "fleet tree: restored ($($d2 -join '; '))"
}

Section 'ROLLBACK (targeted undo) re-opens what the stage closed, last action first'
$t4 = New-NarrowTree; $P4 = Get-StageParams $t4
Test-Step 'rollback' {
    $bk4 = Join-Path $t4.Work 'bk'
    $null = Invoke-CoderAclStage -Mode Apply @P4 -ExpectPlan (Get-PlanDigest $P4) -BackupDir $bk4 -Out { param($l) }
    Assert-True (@(Find-SidWriteAces -Root $t4.Projects -Sid $User -Depth 2).Count -eq 0) 'before the rollback the coder has no write ACE on projects'
    $lines = New-Object System.Collections.ArrayList
    $r = Invoke-CoderAclStage -Mode Rollback @P4 -RollbackFrom $bk4 -Out { param($l) [void]$lines.Add([string]$l) }
    Assert-True $r.Ok 'rollback runs'
    Assert-True (@(Find-SidWriteAces -Root $t4.Projects -Sid $User -Depth 2).Count -gt 0) 'after the rollback the coder has its Modify back on projects (the undo is real)'
    $fl4 = Read-AclState -Path $t4.Fleet
    Assert-True (-not $fl4.Protected) 'after the rollback the fleet root inherits again'
    Assert-True (@((Read-AclState -Path $t4.Models).Aces | Where-Object { $_.Sid -eq $AuthUsers -and (Test-AceWriteCapable $_) }).Count -gt 0) 'after the rollback the model folder inherits the parent write grant again'
    $order = @($lines | Where-Object { $_ -like '  undo:*' })
    Assert-True ($order.Count -ge 7 -and $order[-1] -like '*projects*') "rollback runs the last action first (projects, the first action, is undone last) ($($order.Count): $($order -join ' / '))"
}

Section 'the stage REFUSES an unsafe target before changing anything'
$t5 = New-NarrowTree; $P5 = Get-StageParams $t5
$jm = Join-Path $t5.Root 'modeljunction'; New-Item -ItemType Junction -Path $jm -Target $t5.Models | Out-Null
$P5b = $P5.Clone(); $P5b.ModelRoots = @($jm)
$snap5 = Get-TreeSnapshot $t5.Projects
$thr = $null; try { Invoke-CoderAclStage -Mode Apply @P5b -BackupDir (Join-Path $t5.Work 'bk') -Out { param($l) } | Out-Null } catch { $thr = $_.Exception.Message }
Assert-True ($thr -like '*refusing to run the stage, no change made*') "apply with one link target is refused as a whole ($thr)"
Assert-Eq 0 @(Compare-Snapshots $snap5 (Get-TreeSnapshot $t5.Projects)).Count 'nothing was changed on the safe targets either'
Assert-True (-not (Test-Path (Join-Path $t5.Work 'bk\manifest.json'))) 'no backup was written for a refused run'
$dl = New-Object System.Collections.ArrayList
$dr = Invoke-CoderAclStage -Mode DryRun @P5b -Out { param($l) [void]$dl.Add([string]$l) }
Assert-True ((-not $dr.Ok) -and (($dl -join "`n") -match 'REFUSED')) 'the dry run shows the refusal and reports not-Ok'
$P5c = $P5.Clone(); $P5c.CoderSid = $OperatorDummy
$thr = $null; try { Invoke-CoderAclStage -Mode DryRun @P5c -Out { param($l) } | Out-Null } catch { $thr = $_.Exception.Message }
Assert-True ($thr -like '*same account*') 'the stage refuses when the coder and operator SIDs are the same'
$thr = $null; try { Invoke-CoderAclStage -Mode Apply @P5 -ExpectPlan (Get-PlanDigest $P5) -BackupDir (Join-Path $t5.Work 'bk3') -TaskState 'Running' -Out { param($l) } | Out-Null } catch { $thr = $_.Exception.Message }
Assert-True ($thr -like '*Running*') 'Apply refuses while the coder-leg task is Running'
$thr = $null; try { Invoke-CoderAclStage -Mode Apply @P5 -ExpectPlan (Get-PlanDigest $P5) -Out { param($l) } | Out-Null } catch { $thr = $_.Exception.Message }
Assert-True ($thr -like '*BackupDir*') 'Apply refuses without a backup folder'
$thr = $null; try { Invoke-CoderAclStage -Mode Rollback @P5 -Out { param($l) } | Out-Null } catch { $thr = $_.Exception.Message }
Assert-True ($thr -like '*RollbackFrom*') 'Rollback refuses without a saved backup to read the undo lists from'
$thr = $null; try { Invoke-CoderAclStage -Mode Rollback @P5 -RollbackFrom $t5.Work -Out { param($l) } | Out-Null } catch { $thr = $_.Exception.Message }
Assert-True ($thr -like '*not a backup written by this stage*') 'Rollback refuses a folder that holds no plan.json'
Assert-Eq 'RD,WD,X,RC,S' (ConvertTo-IcaclsRightsText -Rights 'custom:0x120023') 'a custom mask is turned into the specific rights icacls accepts'
Assert-Eq 'RX' (ConvertTo-IcaclsRightsText -Rights 'RX') 'a short name is left as it is'
$planJ = @((Get-Content -LiteralPath (Join-Path $t1.Work 'backup\plan.json') -Raw | ConvertFrom-Json))
Assert-True ($planJ.Count -ge 7 -and (@($planJ | Where-Object { $_.id -eq 'projects-narrow' })[0].undo.Count -eq 2) -and @($planJ | Where-Object { $_.id -like 'models-*' }).Count -eq 1) 'the backup holds the undo lists planned from the state BEFORE the change (models and the projects action included)'
Assert-True (@($planJ | Where-Object { $_.id -like 'orphan-*' })[0].undo.Count -eq 0) 'the deleted-account entry has no targeted undo (icacls cannot re-add it); the backup restore is its undo'

# =========================================================================================================
Section 'probe edge cases (the checks must be able to FAIL)'
$ec = New-Object System.Collections.ArrayList
$pe = Invoke-StandInProbe -Tmp $t1.Work -Lists @{ WriteDenyDirs = @((Join-Path $t1.Work 'no-such-dir')) }
Assert-True (-not [bool]$pe.write_outside_denied.pass) 'a folder that does not exist is INCONCLUSIVE, not "denied": the check fails'
$nogit = Join-Path $t1.Work 'plainfolder'; New-Item -ItemType Directory $nogit | Out-Null
$pe2 = Invoke-StandInProbe -Tmp $t1.Work -Lists @{ WorktreePaths = @($nogit) }
Assert-True (-not [bool]$pe2.worktree_commit_fails.pass) 'a commit that fails because the folder is not a repository is NOT counted as a permission denial'
Assert-True ([bool]$pe2.worktree_write_ok.pass) 'the write check is independent of the commit check'
$pe3 = Invoke-StandInProbe -Tmp $t1.Work -Lists @{ ReadFiles = @((Join-Path $t1.Work 'no-such-file.txt')) }
Assert-True (-not [bool]$pe3.read_files_ok.pass) 'an unreadable file fails the read check'
$open = Join-Path $t1.Work 'openfolder'; New-Item -ItemType Directory $open | Out-Null
Invoke-Ic @($open, '/grant', "*${User}:(OI)(CI)M")
$pe4 = Invoke-StandInProbe -Tmp $t1.Work -Lists @{ WriteDenyDirs = @($open) }
Assert-True (-not [bool]$pe4.write_outside_denied.pass) 'a folder the user CAN write fails the write-denied check'
Assert-True (@(Get-ChildItem $open -Force).Count -eq 0) 'the probe removed the file it created in the open folder'
$ro = Invoke-StandInProbe -Tmp $t1.Work -Lists @{ WorktreePaths = @($t2.RepoA) }
Assert-True (-not [bool]$ro.worktree_write_ok.pass) 'a worktree folder the coder cannot write fails the write check (the narrowed repo stands in)'
foreach ($mode in 'objects-denied-refs-open', 'refs-denied-objects-open') {
    $rx = Join-Path $t1.Work "gitrepo-$mode"; New-Item -ItemType Directory $rx | Out-Null
    Invoke-GitQuiet $rx @('init', '-b', 'main'); Set-Content -LiteralPath (Join-Path $rx 'a.txt') -Value 'x' -Encoding ASCII; Invoke-GitQuiet $rx @('add', '-A'); Invoke-GitQuiet $rx @('commit', '-m', 'seed')
    $denyDir = if ($mode -like 'objects-denied*') { '.git\objects' } else { '.git\refs' }
    Invoke-Ic @((Join-Path $rx $denyDir), '/deny', "*${User}:(OI)(CI)(WD,AD)")
    $pg = Invoke-StandInProbe -Tmp $t1.Work -Lists @{ SourceGitRepos = @($rx) }
    Assert-True (-not [bool]$pg.source_git_write_denied.pass) "the source-git check needs BOTH refs and objects denied ($mode fails it)"
}
$none = Invoke-StandInProbe -Tmp $t1.Work -Lists @{}
Assert-True ($null -eq $none.write_outside_denied -and $null -eq $none.worktree_commit_fails) 'a probe job without the new lists produces none of the new checks (old jobs are unchanged)'
$nvMissing = Get-NarrowingFromProbe -Checks $none -SiblingDir 'x' -NewRepoDir 'y' -AclNoCoderWrite $true -NewRepoInheritsRead $true -FunnelCommitOk $true -FunnelMergeOk $true
Assert-True (-not $nvMissing.Verdict.Pass -and $nvMissing.Verdict.Failed.Count -ge 5) 'a probe result with the narrowing checks MISSING fails the verdict (silence is not a pass)'

# =========================================================================================================
Section 'the operator funnel is the only committer: notice, git environment, rules renderer'
$notice = Get-CoderFunnelNotice
Assert-True ($notice -match 'Do NOT run git add, git commit' -and $notice -match 'operator saves a snapshot') 'the notice tells the coder not to commit and who does'
Assert-Eq (Add-CoderFunnelNotice -Prompt 'PROMPT') (Add-CoderFunnelNotice -Prompt (Add-CoderFunnelNotice -Prompt 'PROMPT')) 'adding the notice twice adds it once'
Assert-True ((Add-CoderFunnelNotice -Prompt 'PROMPT').EndsWith('PROMPT') -and (Add-CoderFunnelNotice -Prompt 'PROMPT').StartsWith('RESTRICTED ACCOUNT NOTICE')) 'the notice goes in front of the original prompt, which is kept whole'
$ge = Get-CoderLegGitEnv -WorkDir 'C:\blarai-fleet\worktrees\w1\'
Assert-Eq '0' $ge.GIT_OPTIONAL_LOCKS 'git env: GIT_OPTIONAL_LOCKS=0'
Assert-Eq '0' $ge.GIT_TERMINAL_PROMPT 'git env: no prompts'
Assert-Eq 'safe.directory' $ge.GIT_CONFIG_KEY_0 'git env: safe.directory key'
Assert-Eq 'C:/blarai-fleet/worktrees/w1' $ge.GIT_CONFIG_VALUE_0 'git env: safe.directory is exactly the coder worktree (no wildcard)'
$thr = $null; try { Get-CoderLegGitEnv -WorkDir 'C:\blarai-fleet\worktrees\*' | Out-Null } catch { $thr = $_ }
Assert-True ($null -ne $thr) 'git env refuses a wildcard workdir'
$agentsPath = Join-Path (Split-Path $PSScriptRoot -Parent) 'configs\AGENTS.md'
$agents = [IO.File]::ReadAllText($agentsPath)
Assert-True ((Get-CoderAgentsRulesText -Text $agents -Containment off) -ceq $agents) 'AGENTS.md rendered for containment OFF is byte-identical to the file'
$rr = Get-CoderAgentsRulesText -Text $agents -Containment restricted_account
Assert-True ($agents -match 'git add -A' -and $rr -notmatch 'git add -A' -and $rr -notmatch 'git commit -m') 'the restricted rendering no longer tells the coder to git add -A / git commit'
Assert-True ($rr -match 'STOP\. You are a restricted account' -and ($rr -split "`n").Count -eq ($agents -split "`n").Count) 'the restricted rendering replaces exactly one line'
$thr = $null; try { Get-CoderAgentsRulesText -Text "no commit rule here`n" -Containment restricted_account | Out-Null } catch { $thr = $_ }
Assert-True ($null -ne $thr) 'a rules file without the commit rule THROWS instead of silently rendering unchanged'
$runner = [IO.File]::ReadAllText((Join-Path $PSScriptRoot 'coder-leg-run.ps1'))
Assert-True ($runner -match 'Get-CoderLegGitEnv -WorkDir' -and $runner.IndexOf('Get-CoderLegGitEnv') -lt $runner.IndexOf('Invoke-AcpCoderRun')) 'the runner sets the git environment before it starts the coder'
$fl = [IO.File]::ReadAllText((Join-Path $PSScriptRoot 'fleet-lib.ps1'))
Assert-True ($fl -match 'Add-CoderFunnelNotice -Prompt \$Prompt' -and $fl -match "'Add-CoderFunnelNotice'\) \{") 'the fused dispatch adds the notice to the staged prompt and checks the helper is loaded'

Section 'the provisioning scripts are wired to the one stage'
$prov = [IO.File]::ReadAllText((Join-Path $PSScriptRoot 'provision-coder-account.ps1'))
Assert-True ($prov -match 'provision-coder-acls\.ps1' -and $prov -match '(?m)^\s+& \$aclStage -Apply') 'provision-coder-account.ps1 runs the ACL stage (a commented-out call does not count)'
Assert-True ($prov -notmatch 'Add-Ace \$ProjectsDir' -and $prov -notmatch 'Add-Ace \$FleetRoot') 'provision-coder-account.ps1 no longer grants on the projects folder or the fleet root itself'
Assert-True (-not ($prov -match "'\(OI\)\(CI\)M'")) 'provision-coder-account.ps1 contains no inheritable Modify grant at all'
$stageSrc = [IO.File]::ReadAllText((Join-Path $PSScriptRoot 'provision-coder-acls.ps1'))
Assert-True ($stageSrc -match '\[switch\]\$DryRun' -and $stageSrc -match '\[switch\]\$Rollback' -and $stageSrc -match '\$RestoreFrom') 'the stage has -DryRun, -Rollback and -RestoreFrom'
Assert-True ($stageSrc -match '\$mode = if \(\$Apply\) \{ ''Apply'' \}.*else \{ ''DryRun'' \}') 'with no switch the stage is a DRY RUN (the safe default)'
$ver = [IO.File]::ReadAllText((Join-Path $PSScriptRoot 'verify-coder-containment.ps1'))
Assert-True ($ver -match 'Get-NarrowingFromProbe' -and $ver -match 'New-VerifyScratchRepo' -and $ver -match 'Invoke-VerifyFunnel' -and $ver -match 'SkipNarrowing') 'verify-coder-containment.ps1 runs the narrowing checks (and -SkipNarrowing is the only opt-out)'

Section 'X1: no help text or document still claims icacls /L makes a tree walk safe'
$stalePatterns = 'self-test runs its stand-in coder de-elevated \(`runas', 'de-elevated through runas', 'never followed \(icacls /L\)', 'with /L the stage will not follow', 'links are never followed \(icacls', '\(/L\)\. Targets are NOT changed', 'icacls /L (protects|keeps|stops)'
$hasStale = { param($text) @($stalePatterns | Where-Object { $text -match $_ }) }
Assert-True (@(& $hasStale 'Links INSIDE a tree are never followed (icacls /L) and are listed.').Count -ge 1) 'the stale-claim scan finds a planted stale sentence (toggle)'
Assert-True (@(& $hasStale 'icacls /T follows directory symlinks even with /L').Count -eq 0) 'the scan leaves the corrected wording alone'
foreach ($f in 'provision-coder-acls.ps1', 'coder-acl-lib.ps1', 'provision-coder-account.ps1', 'verify-coder-containment.ps1') {
    Assert-True (@(& $hasStale ([IO.File]::ReadAllText((Join-Path $PSScriptRoot $f)))).Count -eq 0) "no stale /L claim in $f"
}
foreach ($f in 'docs\fused-leg-operator-uses.md', 'docs\reviews\provisioning-1678-1686-1692-decisions-2026-10-05.md') {
    $p = Join-Path (Split-Path $PSScriptRoot -Parent) $f
    if (Test-Path $p) { Assert-True (@(& $hasStale ([IO.File]::ReadAllText($p))).Count -eq 0) "no stale /L claim in $f" }
}

Section 'X2: a folder swapped for a junction between the check and the change; nothing outside the tree is modified'
$SidX = 'S-1-5-9'
$tx = Join-Path ([IO.Path]::GetTempPath()) ('narrow-x2-' + [guid]::NewGuid().ToString('N').Substring(0, 8)); New-Item -ItemType Directory $tx | Out-Null; [void]$Cleanup.Add($tx)
function New-SwapTree {
    param([string]$Name)
    $b = Join-Path $tx $Name; New-Item -ItemType Directory $b | Out-Null
    $o = [ordered]@{ Base = $b; Tree = (Join-Path $b 'tree'); Outside = (Join-Path $b 'outside'); Outside2 = (Join-Path $b 'outside2') }
    New-Item -ItemType Directory (Join-Path $o.Tree 'a\sub') -Force | Out-Null
    New-Item -ItemType Directory (Join-Path $o.Outside 'x') -Force | Out-Null
    New-Item -ItemType Directory (Join-Path $o.Outside2 'sub') -Force | Out-Null
    foreach ($f in (Join-Path $o.Tree 'a\sub\f.txt'), (Join-Path $o.Outside 'x\o.txt'), (Join-Path $o.Outside 'f.txt'), (Join-Path $o.Outside2 'sub\f.txt')) { Set-Content -LiteralPath $f -Value 'x' -Encoding ASCII }
    foreach ($d in $o.Tree, $o.Outside, $o.Outside2) { foreach ($it in @(Get-Item -LiteralPath $d -Force) + @(Get-ChildItem -LiteralPath $d -Recurse -Force)) { Invoke-Ic @($it.FullName, '/grant', "*${SidX}:R") } }     # one EXPLICIT entry for $SidX on every object (a SID no folder above grants, so it stays explicit)
    return $o
}
$explicitCount = { param($path) @((Read-AclState -Path $path).Aces | Where-Object { $_.Sid -eq $SidX -and -not $_.Inherited }).Count }
$sw = New-SwapTree 'a'
Assert-True ((& $explicitCount (Join-Path $sw.Outside 'x\o.txt')) -eq 1 -and (& $explicitCount $sw.Outside) -eq 1) 'setup: the objects outside the tree carry an explicit entry for the coder SID'
$script:swapped = $false
$script:AclTestHook = @{ BeforeOpen = { param($p) if (-not $script:swapped -and $p -like '*\a\sub') { $script:swapped = $true; Move-Item -LiteralPath $p -Destination ($p + '.moved'); New-Item -ItemType Junction -Path $p -Target $sw.Outside | Out-Null } } }
try { $wA = Invoke-AclTreeRemoveGrants -Root $sw.Tree -Sid $SidX } finally { $script:AclTestHook = $null }
Assert-True $script:swapped 'the hook swapped the folder for a junction after the listing classified it as a folder'
Assert-True (@($wA.Errors | Where-Object { $_ -match 'link' }).Count -ge 1) "the change was refused because the entry is now a link ($(@($wA.Errors) -join ' | '))"
Assert-True ((& $explicitCount (Join-Path $sw.Outside 'x\o.txt')) -eq 1 -and (& $explicitCount $sw.Outside) -eq 1 -and (& $explicitCount (Join-Path $sw.Outside 'x')) -eq 1) 'nothing outside the tree was modified (swap before the open)'
Assert-True ((& $explicitCount (Join-Path $sw.Tree 'a')) -eq 0) 'control: the objects that were not swapped did lose their entry (the walk did change things)'

$sw2 = New-SwapTree 'b'
$script:swapped = $false
$script:AclTestHook = @{ BeforeOpen = { param($p) if (-not $script:swapped -and $p -like '*\a\sub\f.txt') { $script:swapped = $true; $a = Join-Path $sw2.Tree 'a'; Move-Item -LiteralPath $a -Destination ($a + '.moved'); New-Item -ItemType Junction -Path $a -Target $sw2.Outside2 | Out-Null } } }
try { $wB = Invoke-AclTreeRemoveGrants -Root $sw2.Tree -Sid $SidX } finally { $script:AclTestHook = $null }
Assert-True $script:swapped 'the hook swapped a PARENT folder for a junction before a file inside it was opened'
Assert-True (@($wB.Errors | Where-Object { $_ -match 'outside' }).Count -ge 1) "the file was refused because it resolves outside the tree ($(@($wB.Errors) -join ' | '))"
Assert-True ((& $explicitCount (Join-Path $sw2.Outside2 'sub\f.txt')) -eq 1 -and (& $explicitCount $sw2.Outside2) -eq 1) 'nothing outside the tree was modified (parent swapped)'

$sw3 = New-SwapTree 'c'
$script:moved = $null
$script:AclTestHook = @{ AfterOpen = { param($p) if ($null -eq $script:moved -and $p -like '*\a\sub') { try { Move-Item -LiteralPath (Join-Path $sw3.Tree 'a') -Destination (Join-Path $sw3.Base 'elsewhere') -ErrorAction Stop; $script:moved = $true; New-Item -ItemType Junction -Path (Join-Path $sw3.Tree 'a') -Target $sw3.Outside | Out-Null } catch { $script:moved = $false } } } }
try { $wC = Invoke-AclTreeRemoveGrants -Root $sw3.Tree -Sid $SidX } finally { $script:AclTestHook = $null }
Write-Host "    (info) the swap after the open: moved out = $($script:moved); errors: $(@($wC.Errors) -join ' | ')"
Assert-True (($script:moved -eq $false) -or (@($wC.Errors | Where-Object { $_ -match 'outside' }).Count -ge 1)) 'the swap after the open (the folder moved OUT of the tree) either could not happen while the handle is held, or the change was refused because the held object now resolves outside the tree'
Assert-True ((& $explicitCount (Join-Path $sw3.Outside 'x\o.txt')) -eq 1 -and (& $explicitCount $sw3.Outside) -eq 1 -and (& $explicitCount (Join-Path $sw3.Outside 'f.txt')) -eq 1) 'nothing outside the tree was modified (swap after the open: the folder moved out and a junction put in its place)'

$sw5 = New-SwapTree 'e'
$script:swapped = $false
$script:AclTestHook = @{ BeforeOpen = { param($p) if (-not $script:swapped -and $p -like '*\a\sub\f.txt') { $script:swapped = $true; Remove-Item -LiteralPath $p -Force; New-Item -ItemType Directory -Path $p | Out-Null } } }
try { $wE = Invoke-AclTreeRemoveGrants -Root $sw5.Tree -Sid $SidX } finally { $script:AclTestHook = $null }
Assert-True ($script:swapped -and @($wE.Errors | Where-Object { $_ -match 'changed kind' }).Count -ge 1) "a file replaced by a folder between the listing and the open is refused ($(@($wE.Errors) -join ' | '))"

$sw6 = New-SwapTree 'f'
$script:renamedSelf = $null
$script:AclTestHook = @{ AfterOpen = { param($p) if ($null -eq $script:renamedSelf -and $p -like '*\a\sub') { try { [IO.Directory]::Move($p, $p + '.r'); $script:renamedSelf = $true } catch { $script:renamedSelf = $false } } } }
try { $null = Invoke-AclTreeRemoveGrants -Root $sw6.Tree -Sid $SidX } finally { $script:AclTestHook = $null }
Assert-True ($script:renamedSelf -eq $false) 'while the checked handle is held the object itself cannot be renamed or replaced (no share-delete)'

# the restore route
$sw4 = New-SwapTree 'd'
$bkd = Join-Path $sw4.Base 'bk'
$fakeAct = New-AclAction -Id 'x' -Issue '#0' -Title 't' -Path $sw4.Tree -Plain 'p' -Steps @((New-AclOp RemoveGrants -Sid $SidX -Tree)) -Undo @()
$null = Write-AclBackup -Plan @($fakeAct) -BackupDir $bkd
Move-Item -LiteralPath (Join-Path $sw4.Tree 'a\sub') -Destination (Join-Path $sw4.Tree 'a\sub.moved')
New-Item -ItemType Junction -Path (Join-Path $sw4.Tree 'a\sub') -Target $sw4.Outside | Out-Null
Invoke-Ic @($sw4.Outside, '/remove:g', "*$SidX"); Invoke-Ic @((Join-Path $sw4.Outside 'f.txt'), '/remove:g', "*$SidX"); Invoke-Ic @((Join-Path $sw4.Outside 'x\o.txt'), '/remove:g', "*$SidX")
$rr = Invoke-AclRestore -BackupDir $bkd -Out { param($l) }
Assert-True (@($rr.Skipped | Where-Object { $_ -match 'a\\sub' }).Count -ge 1) "the restore skipped the entry that is now a link ($(@($rr.Skipped) -join ' | '))"
Assert-Eq 0 (& $explicitCount $sw4.Outside) 'the restore did not write the saved list onto the folder behind the link'
Assert-Eq 0 ((& $explicitCount (Join-Path $sw4.Outside 'f.txt')) + (& $explicitCount (Join-Path $sw4.Outside 'x\o.txt'))) 'nor onto the files behind the link'

Section 'X3: -Apply only applies the plan the operator was shown'
$t7 = New-NarrowTree; $P7 = Get-StageParams $t7
$store7 = Join-Path $t7.Work 'plans'
$d1 = Invoke-CoderAclStage -Mode DryRun @P7 -PlanStoreDir $store7 -Out { param($l) }
$d2 = Invoke-CoderAclStage -Mode DryRun @P7 -Out { param($l) }
Assert-True ($d1.Digest -match '^[0-9a-f]{16}$' -and $d1.Digest -eq $d2.Digest) "two dry runs of an unchanged machine give the same digest ($($d1.Digest))"
$lines7 = New-Object System.Collections.ArrayList
$null = Invoke-CoderAclStage -Mode DryRun @P7 -Out { param($l) [void]$lines7.Add([string]$l) }
Assert-True (@($lines7 | Where-Object { $_ -eq "PLAN DIGEST: $($d1.Digest)" }).Count -eq 1) 'the dry run prints the digest'
Assert-True (Test-Path (Join-Path $store7 "plan-$($d1.Digest).txt")) 'the dry run stores the plan text under its digest (so a refusal can print a diff)'
$thr = $null; try { Invoke-CoderAclStage -Mode Apply @P7 -BackupDir (Join-Path $t7.Work 'bk') -Out { param($l) } | Out-Null } catch { $thr = $_.Exception.Message }
Assert-True ($thr -like '*-ExpectPlan*') 'Apply without a digest is refused (no plan was shown)'
# the machine changes between the dry run and the apply
Invoke-Ic @($t7.Models, '/grant', "*S-1-5-32-546:(OI)(CI)M")
$snap7 = Get-TreeSnapshot $t7.Projects; $snapM = Get-TreeSnapshot $t7.Fleet
$out7 = New-Object System.Collections.ArrayList; $thr = $null
try { Invoke-CoderAclStage -Mode Apply @P7 -ExpectPlan $d1.Digest -PlanStoreDir $store7 -BackupDir (Join-Path $t7.Work 'bk') -Out { param($l) [void]$out7.Add([string]$l) } | Out-Null } catch { $thr = $_.Exception.Message }
Assert-True ($thr -like '*differs from the one shown*') "Apply is refused when the plan changed since it was shown ($thr)"
Assert-True (@($out7 | Where-Object { $_ -match '^\s+(=>|<=) ' }).Count -ge 1) 'the refusal prints a diff of what changed'
Assert-True ((@(Compare-Snapshots $snap7 (Get-TreeSnapshot $t7.Projects)).Count -eq 0) -and (@(Compare-Snapshots $snapM (Get-TreeSnapshot $t7.Fleet)).Count -eq 0) -and -not (Test-Path (Join-Path $t7.Work 'bk\manifest.json'))) 'a refused apply changed nothing and wrote no backup'
$dNow = (Invoke-CoderAclStage -Mode DryRun @P7 -Out { param($l) }).Digest
Assert-True ($dNow -ne $d1.Digest) 'the digest of the changed machine differs'
$rOk = Invoke-CoderAclStage -Mode Apply @P7 -ExpectPlan $dNow -BackupDir (Join-Path $t7.Work 'bk2') -Out { param($l) }
Assert-True $rOk.Ok 'with the digest of the plan as it now is, Apply goes ahead'

Section 'X4: every spelling of a forbidden folder is refused (normalised before the gate)'
$fso = New-Object -ComObject Scripting.FileSystemObject
$short = { param($p) try { $fso.GetFolder($p).ShortPath } catch { $p } }
$pf = 'C:\Program Files'; $pfShort = & $short $pf
$variants = [ordered]@{
    'plain'                    = 'C:\Windows'
    'trailing backslash'       = 'C:\Windows\'
    'trailing dot'             = 'C:\Windows.'
    'trailing dots'            = 'C:\Windows...'
    'trailing space'           = 'C:\Windows '
    'dot segment'              = 'C:\Windows\.'
    'upper case'               = 'C:\WINDOWS'
    'mixed case + dot'         = 'c:\wInDoWs.'
    'program files, 8.3'       = $pfShort
    'program files, 8.3 + dot' = ($pfShort + '.')
    'users'                    = 'C:\Users'
    'users, case'              = 'C:\USERS'
    'users, trailing dot'      = 'C:\Users.'
    'profile root'             = $env:USERPROFILE
    'profile root, 8.3'        = (& $short $env:USERPROFILE)
    'profile root, case'       = $env:USERPROFILE.ToUpperInvariant()
    'profile root, trailing dot' = ($env:USERPROFILE + '.')
}
foreach ($k in $variants.Keys) {
    $x = Test-AclTargetSafe -Path $variants[$k]
    Assert-True ((-not $x.Ok) -and $x.Reason -match 'system or profile-root') "forbidden folder refused as such: $k ('$($variants[$k])') -> $($x.Reason)"
}
foreach ($pair in @(@('extended-length prefix', '\\?\C:\Windows', 'device or extended-length'), @('device prefix', '\\.\C:\Windows', 'device or extended-length'), @('extended-length UNC', '\\?\UNC\server\share', 'device or extended-length'),
        @('alternate stream', 'C:\Temp\x:stream', 'alternate-stream'), @('drive-relative colon', 'C:\Temp:x', 'alternate-stream'), @('reserved name NUL', 'C:\Temp\NUL', 'reserved device name'), @('reserved name con.txt', 'C:\Temp\con.txt', 'reserved device name'), @('reserved name with trailing dot', 'C:\Temp\COM1.', 'reserved device name'))) {
    $x = Test-AclTargetSafe -Path $pair[1]
    Assert-True ((-not $x.Ok) -and $x.Reason -match $pair[2]) "refused: $($pair[0]) -> $($x.Reason)"
}
$okNorm = Test-AclTargetSafe -Path ($tx + '\')
Assert-True ($okNorm.Ok -and $okNorm.Normalized -ieq $tx) 'a normal folder with a trailing backslash is accepted and normalised'
$shortTx = & $short $tx
Assert-True ((Test-AclTargetSafe -Path $shortTx).Ok) "an 8.3 spelling of an ordinary folder is accepted ($shortTx)"

Section 'X5: a separate read entry keeps its own inheritance (model folder)'
$sepRead = [pscustomobject]@{ Path = 'M'; Owner = $null; Protected = $true; Aces = @(
    (New-Ace -Sid 'S-1-5-18' -Rights 'F' -Flags '(OI)(CI)'), (New-Ace -Sid 'S-1-5-32-544' -Rights 'F' -Flags '(OI)(CI)'),
    (New-Ace -Sid 'S-1-5-11' -Rights 'M' -Flags ''),                       # write entry: this folder only
    (New-Ace -Sid 'S-1-5-11' -Rights 'RX' -Flags '(CI)(IO)')) }            # a SEPARATE read entry: subfolders only
$p5 = @(Get-CoderAclPlan -CoderSid $User -OperatorSid $OperatorDummy -ProjectsDir 'C:\P\projects' -WorktreeBase 'C:\F\blarai-fleet\worktrees' -ModelRoots @('B:\models') -ProfileCleanupPaths @() -ReadAcl { param($p) $sepRead })
$m5 = @($p5 | Where-Object { $_.Id -eq 'models-B-models' })[0]
$adds = @($m5.Steps | Where-Object { $_.Op -eq 'AddGrant' -and $_.Sid -eq 'S-1-5-11' } | ForEach-Object { "$($_.Rights)|$($_.Flags)" } | Sort-Object)
Assert-Eq 'RX||RX|(CI)(IO)' ($adds -join '|') 'each entry comes back with ITS OWN flags: the this-folder write entry as read on this folder only, the separate subfolders-only read entry exactly as it was (not rewritten with the write entry''s flags)'
$covered = [pscustomobject]@{ Path = 'M'; Owner = $null; Protected = $true; Aces = @((New-Ace -Sid 'S-1-5-18' -Rights 'F' -Flags '(OI)(CI)'), (New-Ace -Sid 'S-1-5-11' -Rights 'M' -Flags ''), (New-Ace -Sid 'S-1-5-11' -Rights 'RX' -Flags '(OI)(CI)')) }
$pc5 = @(Get-CoderAclPlan -CoderSid $User -OperatorSid $OperatorDummy -ProjectsDir 'C:\P\projects' -WorktreeBase 'C:\F\blarai-fleet\worktrees' -ModelRoots @('B:\models') -ProfileCleanupPaths @() -ReadAcl { param($p) $covered })
$addsC = @(@($pc5 | Where-Object { $_.Id -eq 'models-B-models' })[0].Steps | Where-Object { $_.Op -eq 'AddGrant' -and $_.Sid -eq 'S-1-5-11' } | ForEach-Object { "$($_.Rights)|$($_.Flags)" })
Assert-Eq 'RX|(OI)(CI)' ($addsC -join '|') 'a read-on-this-folder entry that the (OI)(CI) read entry already covers is not re-added (Windows would merge it)'
$t8 = New-NarrowTree; $P8 = Get-StageParams $t8
Invoke-Ic @($t8.Models, '/inheritance:r'); Invoke-Ic @($t8.Models, '/grant', '*S-1-5-18:(OI)(CI)F', "*${AuthUsers}:(M)", "*${AuthUsers}:(CI)(IO)(RX)")
$r8 = Invoke-CoderAclStage -Mode Apply @P8 -ExpectPlan (Get-PlanDigest $P8) -BackupDir (Join-Path $t8.Work 'bk') -Out { param($l) }
Assert-True ($r8.Ok -and @($r8.Mismatches).Count -eq 0) "the real result equals the printed AFTER for that folder ($(@($r8.Mismatches) -join ' | '))"
$mm8 = Read-AclState -Path $t8.Models
Assert-True (@($mm8.Aces | Where-Object { $_.Sid -eq $AuthUsers -and (Test-AceWriteCapable $_) }).Count -eq 0) 'no write entry is left for Authenticated Users'
Assert-True (@($mm8.Aces | Where-Object { $_.Sid -eq $AuthUsers -and $_.Rights -eq 'RX' -and $_.Flags -eq '(CI)' }).Count -eq 1 -and @($mm8.Aces | Where-Object { $_.Sid -eq $AuthUsers }).Count -eq 1) 'read on this folder (from the write entry) plus the separate subfolders-only read entry: one read entry for the folder and its subfolders (Windows merges them), and not for files'
$simM = Invoke-AclSimulation -State ([pscustomobject]@{ Path = 'x'; Owner = $null; Protected = $true; Aces = @() }) -Op (New-AclOp AddGrant -Sid 'S-1-5-11' -Rights 'RX' -Flags '')
$simM = Invoke-AclSimulation -State $simM -Op (New-AclOp AddGrant -Sid 'S-1-5-11' -Rights 'RX' -Flags '(CI)(IO)')
Assert-True (@($simM.Aces).Count -eq 1 -and $simM.Aces[0].Flags -eq '(CI)') 'the simulator merges this-folder and subfolders-only entries of the same rights like Windows does'
$simN = Invoke-AclSimulation -State $simM -Op (New-AclOp AddGrant -Sid 'S-1-5-11' -Rights 'M' -Flags '(OI)(IO)')
Assert-Eq 2 @($simN.Aces).Count 'entries with different rights are not merged'

Section 'X6: the operator Modify the stage adds is removed by the rollback, unless it was already there'
$fl = [pscustomobject]@{ Path = 'F'; Owner = $null; Protected = $false; Aces = @((New-Ace -Sid 'S-1-5-11' -Rights 'M' -Flags '(OI)(CI)' -Inherited $true), (New-Ace -Sid 'S-1-5-18' -Rights 'F' -Flags '(OI)(CI)' -Inherited $true)) }
$flHad = [pscustomobject]@{ Path = 'F'; Owner = $null; Protected = $false; Aces = @($fl.Aces) + @(New-Ace -Sid $OperatorDummy -Rights 'M' -Flags '(OI)(CI)') }
$pNo = @(Get-CoderAclPlan -CoderSid $User -OperatorSid $OperatorDummy -ProjectsDir 'C:\P\projects' -WorktreeBase 'C:\F\blarai-fleet\worktrees' -ModelRoots @() -ProfileCleanupPaths @() -ReadAcl { param($p) $fl })
$pHad = @(Get-CoderAclPlan -CoderSid $User -OperatorSid $OperatorDummy -ProjectsDir 'C:\P\projects' -WorktreeBase 'C:\F\blarai-fleet\worktrees' -ModelRoots @() -ProfileCleanupPaths @() -ReadAcl { param($p) $flHad })
$uNo = @(@($pNo | Where-Object { $_.Id -eq 'fleet-root' })[0].Undo | ForEach-Object { "$($_.Op):$($_.Sid)" })
$uHad = @(@($pHad | Where-Object { $_.Id -eq 'fleet-root' })[0].Undo | ForEach-Object { "$($_.Op):$($_.Sid)" })
Assert-True ($uNo -contains "RemoveGrants:$OperatorDummy") 'plan: the fleet-root undo removes the operator entry the stage added'
Assert-True ($uHad -notcontains "RemoveGrants:$OperatorDummy" -and @($pHad | Where-Object { $_.Id -eq 'fleet-root' })[0].UndoNote -match 'operator entry on the root STAYS') 'plan: when the operator already had an explicit entry the undo leaves it and says why'
$t9 = New-NarrowTree; $P9 = Get-StageParams $t9
$bk9 = Join-Path $t9.Work 'bk'
$null = Invoke-CoderAclStage -Mode Apply @P9 -ExpectPlan (Get-PlanDigest $P9) -BackupDir $bk9 -Out { param($l) }
Assert-True (@((Read-AclState -Path $t9.Fleet).Aces | Where-Object { $_.Sid -eq $OperatorDummy -and -not $_.Inherited }).Count -eq 1) 'after Apply the operator holds the Modify entry on the fleet root'
$null = Invoke-CoderAclStage -Mode Rollback @P9 -RollbackFrom $bk9 -Out { param($l) }
Assert-True (@((Read-AclState -Path $t9.Fleet).Aces | Where-Object { $_.Sid -eq $OperatorDummy }).Count -eq 0) 'after Rollback the operator Modify entry the stage added is gone from the fleet root'
Assert-True (@((Read-AclState -Path $t9.Models).Aces | Where-Object { $_.Sid -eq $OperatorDummy }).Count -eq 0) 'and from the model folder'
$t10 = New-NarrowTree; $P10 = Get-StageParams $t10
Invoke-Ic @($t10.Fleet, '/grant', "*${OperatorDummy}:(OI)(CI)R")     # the operator already had an explicit entry
$bk10 = Join-Path $t10.Work 'bk'
$null = Invoke-CoderAclStage -Mode Apply @P10 -ExpectPlan (Get-PlanDigest $P10) -BackupDir $bk10 -Out { param($l) }
$null = Invoke-CoderAclStage -Mode Rollback @P10 -RollbackFrom $bk10 -Out { param($l) }
Assert-True (@((Read-AclState -Path $t10.Fleet).Aces | Where-Object { $_.Sid -eq $OperatorDummy -and -not $_.Inherited }).Count -ge 1) 'when the operator already had an explicit entry on the fleet root, Rollback leaves the operator entries in place'

Section 'review round 6: X1 what the coder can really write (its own entries, its groups, ownership)'
$tg = New-NarrowTree; $PG = Get-StageParams $tg
Invoke-Ic @((Join-Path $tg.Projects 'repoA'), '/grant', '*S-1-5-11:(OI)(CI)M')
Invoke-Ic @((Join-Path $tg.Projects 'repoB'), '/grant', '*S-1-5-32-545:(OI)(CI)M')
$gl = New-Object System.Collections.ArrayList
$gd = Invoke-CoderAclStage -Mode DryRun @PG -Out { param($l) [void]$gl.Add([string]$l) }
$gtxt = ($gl -join "`n")
Assert-True ($gtxt -match 'WRITE ACCESS THIS STAGE WILL NOT REMOVE' -and $gtxt -match 'repoA' -and $gtxt -match 'repoB') 'the dry run lists the group write entries (Authenticated Users on repoA, Users on repoB) it will NOT remove'
Assert-True (@($gd.Warnings).Count -ge 1) 'and records them as a warning in its result'
$gr = Invoke-CoderAclStage -Mode Apply @PG -ExpectPlan (Get-PlanDigest $PG) -BackupDir (Join-Path $tg.Work 'bk') -Out { param($l) }
Assert-True ((-not $gr.Ok) -and @($gr.Findings | Where-Object { $_ -match 'through a group entry' -and $_ -match 'YOUR decision' }).Count -ge 2) "Apply does NOT say complete: the read-back reports the group entries as findings ($(@($gr.Findings).Count))"
Assert-Eq 0 @($gr.Mismatches).Count 'the stage changed what it set out to change (no mismatch); the group findings are separate'
Invoke-Ic @((Join-Path $tg.Projects 'repoA'), '/remove:g', '*S-1-5-11'); Invoke-Ic @((Join-Path $tg.Projects 'repoB'), '/remove:g', '*S-1-5-32-545')
$wkClean = Find-SidWriteAcesTree -Root $tg.Projects -Sid $User -GroupSids @('S-1-1-0', 'S-1-5-11', 'S-1-5-32-545')
Assert-True (@($wkClean.Hits).Count -eq 0) 'toggle: with the group entries gone the effective-write walk is clean'
Invoke-Ic @((Join-Path $tg.Projects 'repoB'), '/grant', '*S-1-5-32-545:(OI)(CI)M')
$wkDirty = Find-SidWriteAcesTree -Root $tg.Projects -Sid $User -GroupSids @('S-1-1-0', 'S-1-5-11', 'S-1-5-32-545')
Assert-True (@($wkDirty.Hits | Where-Object { $_.Kind -eq 'group' }).Count -ge 1) 'toggle: a group entry put back is found again, and named as a group entry'
$wkBlind = Find-SidWriteAcesTree -Root $tg.Projects -Sid $User -GroupSids @()
Assert-True (@($wkBlind.Hits | Where-Object { $_.Kind -eq 'group' }).Count -eq 0) 'with no group list the same entry is invisible (the old blind spot, shown as the control)'
$ownDir = Join-Path $tg.Work 'owned'; New-Item -ItemType Directory $ownDir | Out-Null
$ownerSid = ([Security.Principal.SecurityIdentifier](Get-Acl -LiteralPath $ownDir).GetOwner([Security.Principal.SecurityIdentifier])).Value
$wkOwn = Find-SidWriteAcesTree -Root $ownDir -Sid $ownerSid -CheckOwner
Assert-True (@($wkOwn.Hits | Where-Object { $_.Kind -eq 'owner' }).Count -ge 1) 'an object owned by the coder is reported (an owner can rewrite its own access list)'
$wkOwn0 = Find-SidWriteAcesTree -Root $ownDir -Sid $ownerSid
Assert-True (@($wkOwn0.Hits | Where-Object { $_.Kind -eq 'owner' }).Count -eq 0) 'the owner check is off unless asked for'
$vsrc = [IO.File]::ReadAllText((Join-Path $PSScriptRoot 'verify-coder-containment.ps1'))
Assert-True ($vsrc -match 'Find-SidWriteAcesTree -Root \$ProjectsDir -Sid \$expectedSid -GroupSids \$groupSids -CheckOwner' -and $vsrc -match 'Get-CoderGroupSids') 'check 5 of the real verify uses the effective-write walk (groups and ownership), not the entries that name the coder'
$cg = @(Get-CoderGroupSids)
Assert-True ($cg -contains 'S-1-5-11' -and $cg -contains 'S-1-5-32-545' -and $cg -contains 'S-1-1-0') 'the coder group list always holds Everyone, Authenticated Users and Users'

Section 'review round 6: X2 the folder the coder own model server loads from is a model root'
$srcA = [IO.File]::ReadAllText((Join-Path $PSScriptRoot 'coder-acl-lib.ps1')); $srcB = [IO.File]::ReadAllText((Join-Path $PSScriptRoot 'provision-coder-acls.ps1'))
$rootsText = "ModelRoots = @('B:\models', 'C:\models', 'C:\Users\mrbla\BlarAI\models')"
Assert-True (([regex]::Matches($srcA, [regex]::Escape($rootsText))).Count -eq 2 -and $srcB.Contains($rootsText)) 'the defaults of the plan, the stage and the script all name C:\models'
$wr = [pscustomobject]@{ Path = 'M'; Owner = $null; Protected = $false; Aces = @((New-Ace -Sid 'S-1-5-18' -Rights 'F' -Flags '(OI)(CI)' -Inherited $true), (New-Ace -Sid 'S-1-5-11' -Rights 'M' -Flags '(OI)(CI)' -Inherited $true)) }
$pDef = @(Get-CoderAclPlan -CoderSid $User -OperatorSid $OperatorDummy -ProjectsDir 'C:\P\projects' -WorktreeBase 'C:\F\blarai-fleet\worktrees' -ProfileCleanupPaths @() -ReadAcl { param($p) $wr })
$mc = @($pDef | Where-Object { $_.Path -eq 'C:\models' })
Assert-True ($mc.Count -eq 1 -and @($mc[0].Steps | Where-Object { $_.Op -eq 'RemoveGrants' -and $_.Sid -eq 'S-1-5-11' }).Count -eq 1 -and @($mc[0].Steps | Where-Object { $_.Op -eq 'AddGrant' -and $_.Sid -eq 'S-1-5-11' -and $_.Rights -eq 'RX' }).Count -eq 1) 'with the default roots the plan strips the write entry of Authenticated Users from C:\models and keeps read (the coder gets read)'

Section 'review round 6: X3 a bare rollback must not pick a backup that lacks undo lists'
$bkroot = Join-Path $tg.Work 'rbroot'; New-Item -ItemType Directory $bkroot | Out-Null
foreach ($n in '20260101-000001', '20260101-000002') { New-Item -ItemType Directory (Join-Path $bkroot $n) | Out-Null; Set-Content -LiteralPath (Join-Path $bkroot "$n\plan.json") -Value '[]' -Encoding ASCII }
$thr = $null; try { Select-AclRollbackBackup -BackupRoot $bkroot | Out-Null } catch { $thr = $_.Exception.Message }
Assert-True ($thr -like '*-Rollback -From <folder>*' -and $thr -match '20260101-000001' -and $thr -match 'OLDEST') 'with two backups a bare rollback is refused, says why, lists them and names the oldest as the full set'
Remove-Item -LiteralPath (Join-Path $bkroot '20260101-000002') -Recurse -Force
Assert-True ((Select-AclRollbackBackup -BackupRoot $bkroot) -like '*20260101-000001') 'with exactly one backup it is chosen'
Assert-Eq '' (Select-AclRollbackBackup -BackupRoot (Join-Path $tg.Work 'nobackups')) 'with none it returns nothing (the script then refuses)'
Assert-True ($srcB -match 'Select-AclRollbackBackup' -and $srcB -notmatch 'Get-LatestAclBackup -BackupRoot') 'the script uses the refusing chooser, not "newest"'

Section 'review round 6: X4 the credential-mode probe: arrays through a file, and a check that read nothing fails'
$sf1 = Join-Path $tg.Work 's1.txt'; $sf2 = Join-Path $tg.Work 's2.txt'; Set-Content -LiteralPath $sf1 -Value 'a' -Encoding ASCII; Set-Content -LiteralPath $sf2 -Value 'b' -Encoding ASCII
$pj = ConvertTo-ProbeParamsJson -Params @{ SecretPaths = @($sf1, $sf2); LoopbackUrl = 'http://127.0.0.1:9/'; OutboundHost = '127.0.0.1'; OutboundPort = 9; OutboundTimeoutMs = 200 }
Assert-Eq 2 @((ConvertFrom-Json $pj).SecretPaths).Count 'the params document keeps the list a list'
$pfile = Join-Path $tg.Work 'probe.params.json'; Set-Content -LiteralPath $pfile -Value $pj -Encoding UTF8
$pout = Join-Path $tg.Work 'probe-cred.json'
$hp1 = Invoke-HiddenProcess -FilePath (Get-Command pwsh).Source -ArgumentList @('-NoProfile', '-NonInteractive', '-File', $ProbeScript, '-ParamsFile', $pfile, '-OutJson', $pout) -TimeoutSec 120
$pc = (Get-Content -LiteralPath $pout -Raw | ConvertFrom-Json).checks.secret_reads_denied
Assert-True ((-not [bool]$pc.pass) -and @($pc.per_path.PSObject.Properties).Count -eq 2) 'through the -File route the two readable "secret" files are two separate paths and both are READ: check 2 FAILS (the old route passed having read nothing)'
$pe0 = Invoke-StandInProbe -Tmp $tg.Work -Lists @{ SecretPaths = @() }
Assert-True ((-not [bool]$pe0.secret_reads_denied.pass) -and $pe0.secret_reads_denied.detail -match 'ZERO') 'an empty secret list FAILS check 2 (a check that read nothing certifies nothing)'
$pe1 = Invoke-StandInProbe -Tmp $tg.Work -Lists @{ SecretPaths = @((Join-Path $tg.Work 'no-such-secret')) }
Assert-True (-not [bool]$pe1.secret_reads_denied.pass) 'a list of paths that do not exist FAILS check 2 as well'
$dsec = Join-Path $tg.Work 'denied-secret.txt'; Set-Content -LiteralPath $dsec -Value 's' -Encoding ASCII; Invoke-Ic @($dsec, '/deny', "*${User}:(R)")
$pe2 = Invoke-StandInProbe -Tmp $tg.Work -Lists @{ SecretPaths = @($dsec) }
Assert-True ([bool]$pe2.secret_reads_denied.pass) 'one existing path that is really denied passes check 2'
$pe3 = Invoke-StandInProbe -Tmp $tg.Work -Lists @{ SecretPaths = @($dsec, $sf1) }
Assert-True (-not [bool]$pe3.secret_reads_denied.pass) 'one denied and one READABLE path fails'
Assert-True ($vsrc -match 'Invoke-WithProbeParamsFile' -and $vsrc -match '-ParamsFile' -and $vsrc -notmatch '-SecretPaths \$secretArg') 'verify-coder-containment.ps1 in credential mode hands the lists over as a file, not as a command-line string'

Section 'review round 6: X6 a folder swapped for a link between the gate and icacls'
$tf = New-NarrowTree
$outsideS = Join-Path $tf.Work 'outsidesecret'; New-Item -ItemType Directory $outsideS | Out-Null; Set-Content -LiteralPath (Join-Path $outsideS 'keep.txt') -Value 'k' -Encoding ASCII
$actG = New-AclAction -Id 'g' -Issue '#0' -Title 'grant test' -Path $tf.Worktrees -Plain 'p' -Steps @((New-AclOp SetGrant -Sid 'S-1-5-32-546' -Rights 'M' -Flags '(OI)(CI)')) -Undo @()
$script:swapped = $false
$script:AclTestHook = @{ BeforeOpen = { param($p) if (-not $script:swapped -and $p -like '*\worktrees') { $script:swapped = $true; Move-Item -LiteralPath $p -Destination ($p + '.moved'); New-Item -ItemType SymbolicLink -Path $p -Target $outsideS | Out-Null } } }
$thr = $null; try { Invoke-CoderAclAction -Action $actG -Out { param($l) } | Out-Null } catch { $thr = $_.Exception.Message } finally { $script:AclTestHook = $null }
Assert-True ($script:swapped -and $thr -like 'refusing*link*') "a grant on a folder swapped for a directory SYMLINK after the gate is refused ($thr)"
Assert-True (@((Read-AclState -Path $outsideS).Aces | Where-Object { $_.Sid -eq 'S-1-5-32-546' }).Count -eq 0 -and @((Read-AclState -Path (Join-Path $outsideS 'keep.txt')).Aces | Where-Object { $_.Sid -eq 'S-1-5-32-546' }).Count -eq 0) 'nothing outside gained an entry'
$script:renamedG = $null
$tf2 = New-NarrowTree
$actG2 = New-AclAction -Id 'g' -Issue '#0' -Title 'grant test' -Path $tf2.Worktrees -Plain 'p' -Steps @((New-AclOp SetGrant -Sid 'S-1-5-32-546' -Rights 'M' -Flags '(OI)(CI)')) -Undo @()
$script:AclTestHook = @{ AfterOpen = { param($p) if ($null -eq $script:renamedG -and $p -like '*\worktrees') { try { [IO.Directory]::Move($p, $p + '.r'); $script:renamedG = $true } catch { $script:renamedG = $false } } } }
try { $null = Invoke-CoderAclAction -Action $actG2 -Out { param($l) } } finally { $script:AclTestHook = $null }
Assert-True ($script:renamedG -eq $false) 'while icacls runs the folder is held: it cannot be renamed away'
Assert-True (@((Read-AclState -Path $tf2.Worktrees).Aces | Where-Object { $_.Sid -eq 'S-1-5-32-546' -and $_.Rights -eq 'M' }).Count -ge 1) 'and the grant was made on the real folder'
$tf3 = New-NarrowTree
$actG3 = New-AclAction -Id 'g' -Issue '#0' -Title 'grant test' -Path $tf3.Worktrees -Plain 'p' -Steps @((New-AclOp SetGrant -Sid 'S-1-5-32-546' -Rights 'M' -Flags '(OI)(CI)')) -Undo @()
$script:AclTestHook = @{ FinalPathAfter = { 'C:\somewhere\else' } }
$thr = $null; try { Invoke-CoderAclAction -Action $actG3 -Out { param($l) } | Out-Null } catch { $thr = $_.Exception.Message } finally { $script:AclTestHook = $null }
Assert-True ($thr -like '*moved while icacls was running*') "a folder that resolves elsewhere after icacls ran is detected and stops the stage (seam: the real move is blocked by the held handle) ($thr)"

Section 'review round 6: X7 the forbidden gate covers the subfolders of the forbidden roots'
$subs = [ordered]@{
    'system32' = 'C:\Windows\System32'; 'system32 config' = 'C:\Windows\System32\config'; 'program files child' = 'C:\Program Files\Anything'; 'program files x86 child' = 'C:\Program Files (x86)\Any\Thing'
    'programdata child' = 'C:\ProgramData\Any'; 'profile ssh' = ($env:USERPROFILE + '\.ssh'); 'profile appdata roaming' = ($env:USERPROFILE + '\AppData\Roaming'); 'profile appdata deep' = ($env:USERPROFILE + '\AppData\Local\Programs\X')
    'other profile' = 'C:\Users\Public'; 'other profile child' = 'C:\Users\Default\Desktop'; 'trailing dot sub' = 'C:\Windows.\System32'; 'case sub' = 'c:\windows\SYSTEM32'
}
foreach ($k in $subs.Keys) {
    $x = Test-AclTargetSafe -Path $subs[$k]
    Assert-True ((-not $x.Ok) -and $x.Reason -match 'system or profile') "a subfolder is refused: $k ('$($subs[$k])') -> $($x.Reason)"
}
Assert-Eq '' (Test-AclForbiddenPath -Normalized ($env:USERPROFILE.TrimEnd('\') + '\projects')) 'the projects folder under the profile is NOT forbidden'
Assert-Eq '' (Test-AclForbiddenPath -Normalized ($env:USERPROFILE.TrimEnd('\') + '\BlarAI\models')) 'nor the brain model folder'
Assert-Eq '' (Test-AclForbiddenPath -Normalized ($env:TEMP.TrimEnd('\') + '\anything')) 'nor a folder under the temp folder (scratch space, carved out)'
Assert-True ((Test-AclTargetSafe -Path $tx).Ok) 'and a real temp tree passes the whole gate'

Section 'review round 6: X9 a failure part-way through -Apply names the backup and the restore command'
$th = New-NarrowTree; $PH = Get-StageParams $th
$snapH = Get-TreeSnapshot $th.Projects; $snapHF = Get-TreeSnapshot $th.Fleet
$bkH = Join-Path $th.Work 'bk'
$digH = Get-PlanDigest $PH
$script:AclTestHook = @{ BeforeOpen = { param($p) if ($p -like '*\coder-leg' -and (Test-Path (Join-Path $bkH 'manifest.json'))) { throw 'planted failure' } } }
$thr = $null; $outH = New-Object System.Collections.ArrayList
try { Invoke-CoderAclStage -Mode Apply @PH -ExpectPlan $digH -BackupDir $bkH -Out { param($l) [void]$outH.Add([string]$l) } | Out-Null } catch { $thr = $_.Exception.Message } finally { $script:AclTestHook = $null }
Assert-True ($thr -like '*failed part-way*' -and $thr -like "*$bkH*" -and $thr -like '*-RestoreFrom*') "the error names the backup folder and the exact restore command ($thr)"
Assert-True (@($outH | Where-Object { $_ -like '*APPLY FAILED PART-WAY*' }).Count -eq 1 -and @($outH | Where-Object { $_ -like '*Put everything back exactly with*' }).Count -eq 1) 'and the output says the same in plain lines'
$rrH = Invoke-CoderAclStage -Mode Restore -RestoreFrom $bkH -Out { param($l) }
Assert-True ($rrH.Ok -and @(Compare-Snapshots $snapH (Get-TreeSnapshot $th.Projects)).Count -eq 0 -and @(Compare-Snapshots $snapHF (Get-TreeSnapshot $th.Fleet)).Count -eq 0) 'and that restore puts every access list back exactly as it was before the failed apply'

Section 'review round 6: X10 a Modify added next to an existing Full control is absorbed, like Windows'
$absorb = [pscustomobject]@{ Path = 'x'; Owner = $null; Protected = $true; Aces = @((New-Ace -Sid 'S-1-5-32-546' -Rights 'F' -Flags '(OI)(CI)')) }
$simA = Invoke-AclSimulation -State $absorb -Op (New-AclOp AddGrant -Sid 'S-1-5-32-546' -Rights 'M' -Flags '(OI)(CI)')
Assert-True (@($simA.Aces).Count -eq 1 -and $simA.Aces[0].Rights -eq 'F') 'simulator: M added to an existing F with the same flags changes nothing'
$simB = Invoke-AclSimulation -State ([pscustomobject]@{ Path = 'x'; Owner = $null; Protected = $true; Aces = @((New-Ace -Sid 'S-1-5-32-546' -Rights 'R' -Flags '(OI)(CI)')) }) -Op (New-AclOp AddGrant -Sid 'S-1-5-32-546' -Rights 'DC' -Flags '(OI)(CI)')
Assert-True (@($simB.Aces).Count -eq 1 -and ([int64]$simB.Aces[0].Mask -band 0x40) -ne 0 -and ([int64]$simB.Aces[0].Mask -band 0x120089) -eq 0x120089) 'simulator: rights added to an existing same-flags entry are OR-ed into it'
$ti = New-NarrowTree; $PI = Get-StageParams $ti
Invoke-Ic @($ti.Fleet, '/grant', "*${OperatorDummy}:(OI)(CI)F")
$ri = Invoke-CoderAclStage -Mode Apply @PI -ExpectPlan (Get-PlanDigest $PI) -BackupDir (Join-Path $ti.Work 'bk') -Out { param($l) }
Assert-True ($ri.Ok -and @($ri.Mismatches).Count -eq 0) "a real apply where the operator already holds Full control on the fleet root gives no false MISMATCH ($(@($ri.Mismatches) -join ' | '))"

Section 'review round 6: X11 inheritance-off report at every depth, and the checklist'
$tp = Join-Path $tg.Work 'deepprot'; New-Item -ItemType Directory (Join-Path $tp 'a\b\c') -Force | Out-Null; New-Item -ItemType Directory (Join-Path $tp 'a\d') -Force | Out-Null
Invoke-Ic @((Join-Path $tp 'a\b\c'), '/inheritance:d'); Invoke-Ic @((Join-Path $tp 'a\d'), '/inheritance:d')
$pcs = @(Find-ProtectedChildren -Root $tp)
Assert-True ($pcs.Count -eq 2 -and @($pcs | Where-Object { $_ -like '*a\b\c' }).Count -eq 1 -and @($pcs | Where-Object { $_ -like '*a\d' }).Count -eq 1) "folders with inheritance off at depth 2 and 3 are listed ($($pcs -join ', '))"
$PG2 = Get-StageParams $tg
$dl = New-Object System.Collections.ArrayList
$null = Invoke-CoderAclStage -Mode DryRun @PG2 -Out { param($l) [void]$dl.Add([string]$l) }
Assert-True (@($dl | Where-Object { $_ -match 'remove:g' -and $_ -match 'checked handle' }).Count -ge 1) 'the dry run says that removals are done through a checked handle (not as the icacls line it prints)'
Assert-True (@($dl | Where-Object { $_ -like 'OPERATOR CHECKLIST*' }).Count -eq 1 -and @($dl | Where-Object { $_ -match 'Pause the fleet' }).Count -eq 1 -and @($dl | Where-Object { $_ -match 'FIRST backup' }).Count -eq 1) 'the dry run prints the operator checklist'
$al = New-Object System.Collections.ArrayList
$null = Invoke-CoderAclStage -Mode Apply @PG2 -ExpectPlan (Get-PlanDigest $PG2) -BackupDir (Join-Path $tg.Work 'bkC') -Out { param($l) [void]$al.Add([string]$l) }
Assert-True (@($al | Where-Object { $_ -like 'OPERATOR CHECKLIST*' }).Count -eq 1) 'and so does the apply'

Section 'review round 6: X12 a path of 300 characters'
$tl = Join-Path $tx 'long'
$deep = $tl
foreach ($i in 1..8) { $deep = $deep + '\' + ('d' * 38 + "$i") }
[void][IO.Directory]::CreateDirectory('\\?\' + $deep)
Set-Content -LiteralPath ('\\?\' + $deep + '\deep.txt') -Value 'x' -Encoding ASCII
Invoke-Ic @(('\\?\' + $deep + '\deep.txt'), '/grant', '*S-1-5-9:R')
Assert-True (($deep + '\deep.txt').Length -ge 300) "the test path is $(($deep + '\deep.txt').Length) characters"
$wd = Invoke-AclTreeRemoveGrants -Root $tl -Sid 'S-1-5-9'
Assert-True (@($wd.Errors | Where-Object { $_ -match 'win32 error 3' }).Count -eq 0) "the walk opens every object of the long tree ($(@($wd.Errors) -join ' | '))"
Assert-True (@((Read-AclState -Path ('\\?\' + $deep + '\deep.txt')).Aces | Where-Object { $_.Sid -eq 'S-1-5-9' -and -not $_.Inherited }).Count -eq 0) 'and the explicit entry on the deepest file is removed'

Section 'review round 6: X5 the visible-launch lint, table-driven (positives AND negatives)'
$lintRows = @(
    @('Start-Process pwsh', $true, 'plain Start-Process'), @('start notepad', $true, 'alias start'), @('saps cmd', $true, 'alias saps'),
    @('cmd /c dir', $true, 'bare cmd'), @('pwsh -File x.ps1', $true, 'bare pwsh -File'), @('python x.py', $true, 'bare python'), @('py -3 x.py', $true, 'bare py launcher'),
    @("& 'cmd.exe' /c x", $true, 'call operator, quoted cmd'), @('& "C:\Program Files\PowerShell\7\pwsh.exe" -File x', $true, 'call operator, quoted full path'),
    @('[Diagnostics.Process]::Start("pwsh.exe")', $true, 'static Process Start'), @('[System.Diagnostics.Process]::Start("a", "b")', $true, 'static Process Start, long name'),
    @('Invoke-Expression $c', $true, 'Invoke-Expression'), @('iex $c', $true, 'iex'),
    @('Start-Job -ScriptBlock { cmd /c start x }', $true, 'a job whose script block launches a console'), @('cmd /c start x', $true, 'cmd start'),
    @('Start-Process x -Verb RunAs -WindowStyle Hidden', $true, 'Start-Process -Verb even with Hidden'), @('Invoke-Item .\run.cmd', $true, 'Invoke-Item'),
    @('Start-Process pwsh # -WindowStyle Hidden', $true, 'Hidden only in a trailing comment'),
    @("`$runner = (Get-Command pwsh).Source`n& `$runner -File x", $true, 'call operator on a variable holding a host'),
    @('$psi = New-Object System.Diagnostics.ProcessStartInfo', $true, 'ProcessStartInfo without CreateNoWindow'), @('$p.UseShellExecute = $true', $true, 'UseShellExecute true'),
    @('(New-Object -ComObject Shell.Application).ShellExecute("x")', $true, 'Shell.Application'),
    @('Invoke-CimMethod -ClassName Win32_Process -MethodName Create', $true, 'WMI process Create'), @('runas /trustlevel:0x20000 x', $true, 'runas'),
    @("Start-Process pwsh ```n -ArgumentList x", $true, 'continuation line without Hidden'),
    @('Invoke-HiddenProcess -FilePath $pw -ArgumentList @()', $false, 'the approved launcher'), @('Start-Process pwsh -WindowStyle Hidden -Wait', $false, 'Hidden'),
    @('Start-Process pwsh -WindowStyle:Hidden', $false, 'Hidden with a colon'), @('Start-Process x -NoNewWindow', $false, 'NoNewWindow'),
    @("Start-Process pwsh ```n -WindowStyle Hidden", $false, 'Hidden on a continuation line'),
    @('& $Out $l', $false, 'call operator on a callback'), @('& $per $c $k', $false, 'call operator on a script block'), @('& $OnObject $d $true', $false, 'call operator on a callback 2'),
    @("`$s = 'Start-Process pwsh'", $false, 'a string that mentions a launch'), @('# cmd /c dir', $false, 'a comment'), @("<#`ncmd /c dir`n#>", $false, 'a block comment'),
    @('git status', $false, 'git'), @('& icacls $p /grant x', $false, 'icacls'), @('& git @pre', $false, 'git through the call operator'),
    @('Start-Sleep -Seconds 1', $false, 'Start-Sleep'), @('Start-Job -ScriptBlock { 1 }', $false, 'a harmless job'),
    @('$psi = New-Object System.Diagnostics.ProcessStartInfo; $psi.CreateNoWindow = $true', $false, 'ProcessStartInfo with CreateNoWindow'),
    @('$p = [System.Diagnostics.Process]::Start($psi)', $false, 'Process Start of a prepared start info'),
    @('$x = @{ Python = 1; Cmd = 2 }', $false, 'a hashtable key that is a host name')
)
foreach ($row in $lintRows) {
    $hit = @(Find-VisibleLaunches -Text $row[0])
    if ($row[1]) { Assert-True ($hit.Count -ge 1) "lint flags: $($row[2])" } else { Assert-True ($hit.Count -eq 0) "lint passes: $($row[2])$(if ($hit.Count) { ' -- ' + $hit[0] })" }
}

Section 'review round 7: R2-1: every group a local account token can carry, errors not hidden'
$gi = Get-CoderGroupInfo -CoderSid 'S-1-5-21-1-2-3-9999' -Lookup { param($s) @{ Sids = @(); Errors = @() } }
foreach ($want in 'S-1-1-0', 'S-1-5-11', 'S-1-5-32-545', 'S-1-5-113', 'S-1-5-15', 'S-1-5-3', 'S-1-5-4', 'S-1-5-2', 'S-1-2-0') { Assert-True ($gi.Sids -contains $want) "the coder group list holds $want" }
$gErr = Get-CoderGroupInfo -CoderSid 'S-1-5-21-1-2-3-9999' -Lookup { param($s) throw 'lookup boom' }
Assert-True (@($gErr.Errors | Where-Object { $_ -match 'lookup boom' }).Count -eq 1 -and $gErr.Sids -contains 'S-1-5-113') 'a failing lookup is reported (not swallowed) and the well-known list is still returned'
$gNone = Get-CoderGroupInfo -CoderSid ''
Assert-True (@($gNone.Errors).Count -ge 1) 'an unknown coder SID is an error, not a silent fallback'
$gMember = Get-CoderGroupInfo -CoderSid 'S-1-5-21-1-2-3-9999' -Lookup { param($s) @{ Sids = @('S-1-5-32-559'); Errors = @('group X: broken') } }
Assert-True ($gMember.Sids -contains 'S-1-5-32-559' -and $gMember.Errors -contains 'group X: broken') 'memberships from the lookup are added and its errors passed on'
$tg2 = New-NarrowTree
foreach ($sidG in $gi.Sids) {
    Invoke-Ic @((Join-Path $tg2.Projects 'repoA'), '/grant', "*${sidG}:(OI)(CI)M")
    $wkG = Find-SidWriteAcesTree -Root $tg2.Projects -Sid $User -GroupSids $gi.Sids
    Assert-True (@($wkG.Hits | Where-Object { $_.Kind -eq 'group' -and $_.Why -match [regex]::Escape($sidG) }).Count -ge 1) "Modify for $sidG on a repo is found as write access for the coder"
    Invoke-Ic @((Join-Path $tg2.Projects 'repoA'), '/remove:g', "*$sidG")
}
$tg3 = New-NarrowTree; $PG3 = Get-StageParams $tg3; $PG3.CoderGroupSids = @($gi.Sids)
Invoke-Ic @((Join-Path $tg3.Projects 'repoA'), '/grant', '*S-1-5-113:(OI)(CI)M'); Invoke-Ic @((Join-Path $tg3.Projects 'repoB'), '/grant', '*S-1-5-15:(OI)(CI)M')
$g3 = Invoke-CoderAclStage -Mode Apply @PG3 -ExpectPlan (Get-PlanDigest $PG3) -BackupDir (Join-Path $tg3.Work 'bk') -Out { param($l) }
Assert-True ((-not $g3.Ok) -and @($g3.Findings | Where-Object { $_ -match 'S-1-5-113' }).Count -ge 1 -and @($g3.Findings | Where-Object { $_ -match 'S-1-5-15' }).Count -ge 1) 'Modify for Local account and for This Organization on two repos: -Apply is not Ok and names both'
$tg4 = New-NarrowTree; $PG4 = Get-StageParams $tg4; $PG4.CoderGroupErrors = @('group X: broken')
$g4l = New-Object System.Collections.ArrayList
$g4d = Invoke-CoderAclStage -Mode DryRun @PG4 -Out { param($l) [void]$g4l.Add([string]$l) }
Assert-True ((($g4l -join "`n") -match 'UNKNOWN GROUPS: group X: broken') -and @($g4d.Warnings | Where-Object { $_ -match 'group memberships' }).Count -ge 1) 'an unknown group lookup is a warning in the dry run'
$g4 = Invoke-CoderAclStage -Mode Apply @PG4 -ExpectPlan (Get-PlanDigest $PG4) -BackupDir (Join-Path $tg4.Work 'bk') -Out { param($l) }
Assert-True ((-not $g4.Ok) -and @($g4.Findings | Where-Object { $_ -match 'group memberships could not all be read' }).Count -eq 1) 'and a finding at apply (fail closed): not Ok'

Section 'review round 7: R2-2: unreadable folders are part of the plan'
function Invoke-DryRunDeElevated($Params, [switch]$AllowUnreadable) {
    # the dry run as the stand-in coder's token (never elevated): a reader that cannot open some folders
    return (Invoke-StandIn -Arguments @{ Lib = (Join-Path $PSScriptRoot 'coder-acl-lib.ps1'); P = $Params; Allow = [bool]$AllowUnreadable } -ScriptText @'
. $A.Lib
$script:AclAllowTempRoot = $true
$p = @{}
foreach ($k in @('CoderSid', 'OperatorSid', 'ProjectsDir', 'WorktreeBase', 'LegRoot')) { $p[$k] = [string]$A.P.$k }
foreach ($k in @('ModelRoots', 'ProfileCleanupPaths', 'CoderGroupSids')) { $p[$k] = @($A.P.$k) }
$p.SkipOwnerCheck = $true
if ($A.Allow) { $p.AllowUnreadable = $true }
$lines = New-Object System.Collections.ArrayList
$r = Invoke-CoderAclStage -Mode DryRun @p -Out { param($l) [void]$lines.Add([string]$l) }
@{ Text = ($lines -join "`n"); Digest = [string]$r.Digest; Ok = [bool]$r.Ok; Warn = (@($r.Warnings) -join ' | ') }
'@)
}
$tu = New-NarrowTree; $PU = Get-StageParams $tu
$ud = Join-Path $tu.Projects 'repoA\locked'; New-Item -ItemType Directory $ud | Out-Null; Set-Content -LiteralPath (Join-Path $ud 'f.txt') -Value 'x' -Encoding ASCII
Invoke-Ic @($ud, '/inheritance:r'); Invoke-Ic @($ud, '/grant', '*S-1-5-18:(OI)(CI)F')
$ur = Invoke-DryRunDeElevated $PU
Assert-True ($ur.Text -match 'UNREADABLE \(\d+\)' -and $ur.Text -match 'locked' -and $ur.Text -match 'ELEVATED') 'the dry run lists the folder it could not open, with its path and the run-it-elevated instruction'
Assert-True ($ur.Digest -eq '' -and (-not $ur.Ok) -and $ur.Text -match 'NO PLAN DIGEST IS GIVEN' -and $ur.Text -notmatch 'PLAN DIGEST: [0-9a-f]{16}') 'and gives NO digest: nothing to pass to -ExpectPlan'
Assert-True ($ur.Warn -match 'could not be read') 'and records it as a warning'
$ua = Invoke-DryRunDeElevated $PU -AllowUnreadable
Assert-True ($ua.Digest -match '^[0-9a-f]{16}$' -and $ua.Ok) 'with -AllowUnreadable the digest is given and the list is part of it'
$thr = $null; try { Invoke-CoderAclStage -Mode Apply @PU -BackupDir (Join-Path $tu.Work 'bk0') -Out { param($l) } | Out-Null } catch { $thr = $_.Exception.Message }
Assert-True ($thr -like '*-ExpectPlan*') 'and without a digest nothing is applied'
$uel = Invoke-CoderAclStage -Mode DryRun @PU -Out { param($l) }
Assert-True ($script:IsElevated -and $uel.Digest -match '^[0-9a-f]{16}$' -and $uel.Digest -ne $ua.Digest -or (-not $script:IsElevated -and $uel.Digest -eq $ua.Digest)) "an elevated reader (which can open the folder) gets a digest of a plan WITHOUT the unreadable list: it differs from the de-elevated one ($($uel.Digest) vs $($ua.Digest))"
Invoke-Ic @($ud, '/grant', "*${User}:(OI)(CI)F")
$ub = Invoke-DryRunDeElevated $PU
Assert-True ($ub.Digest -match '^[0-9a-f]{16}$' -and $ub.Digest -ne $ua.Digest) 'once the folder is readable the digest is given WITHOUT the flag, and it differs from the one that listed it as unreadable'

Section 'review round 7: R2-3: the credential-mode params file: operator-controlled, read-only for the coder, always deleted'
$pdir = Join-Path $tg.Work 'paramsdir'; New-Item -ItemType Directory $pdir | Out-Null
$seen = @{}
Invoke-WithProbeParamsFile -Dir $pdir -Params @{ SecretPaths = @('a', 'b') } -CoderSid 'S-1-5-32-546' -OperatorSid $User -Body {
    param($f)
    $seen.File = $f; $seen.Exists = (Test-Path -LiteralPath $f)
    $st = Read-AclState -Path $f
    $seen.CoderRead = (@($st.Aces | Where-Object { $_.Sid -eq 'S-1-5-32-546' -and $_.Type -eq 'Allow' -and $_.Rights -eq 'R' }).Count -eq 1)
    $seen.OthersWrite = @($st.Aces | Where-Object { (Test-AceWriteCapable $_) -and $_.Type -eq 'Allow' -and $_.Sid -notin @($User, 'S-1-5-18') }).Count
    $seen.Broad = @($st.Aces | Where-Object { $_.Sid -in @('S-1-5-11', 'S-1-5-32-545', 'S-1-1-0') }).Count
    $seen.Protected = $st.Protected
}
Assert-True ($seen.Exists -and $seen.CoderRead -and $seen.OthersWrite -eq 0 -and $seen.Broad -eq 0 -and $seen.Protected) 'while it exists: the coder has ONE read entry, nobody else can write it, no broad group can read it, inheritance is off'
Assert-True (-not (Test-Path -LiteralPath $seen.File)) 'afterwards the file is gone'
$thr = $null; $leak = $null
try { Invoke-WithProbeParamsFile -Dir $pdir -Params @{ SecretPaths = @('a') } -CoderSid 'S-1-5-32-546' -OperatorSid $User -Body { param($f) $script:leak = $f; throw 'body failed' } } catch { $thr = $_.Exception.Message }
Assert-True ($thr -eq 'body failed' -and $script:leak -and -not (Test-Path -LiteralPath $script:leak)) 'a failure inside the body still deletes the file and passes the error on'
Assert-Eq 0 @(Get-ChildItem -LiteralPath $pdir -Force).Count 'no verify-*.params.json is left behind'
Assert-True ($vsrc -match 'Invoke-WithProbeParamsFile -Dir \(Split-Path \$paths\.Root -Parent\)' -and $vsrc -notmatch 'params\.json.{0,60}\$paths\.Results|Join-Path \$paths\.Results.{0,80}params') 'verify-coder-containment.ps1 puts the file in the fleet root (coder: read only), not in the coder-writable results folder'

Section 'review round 7: R2-5: the temp-folder exemption is an explicit test switch, never the default'
Assert-True ($srcA -match '\$script:AclAllowTempRoot = \$false') 'the library default is OFF'
$setters = @(Get-ChildItem -LiteralPath $PSScriptRoot -Filter '*.ps1' | Where-Object { [IO.File]::ReadAllText($_.FullName) -match '\$script:AclAllowTempRoot\s*=\s*\$true' } | ForEach-Object { $_.Name })
Assert-True (($setters -join ',') -eq 'verify-coder-narrowing.ps1') "only the self-test turns it on ($($setters -join ', '))"
$script:AclAllowTempRoot = $false
try {
    $refT = Test-AclTargetSafe -Path $tx
    Assert-True ((-not $refT.Ok) -and $refT.Reason -match 'system or profile') "with the switch off a real folder under the profile's temp folder is refused ($($refT.Reason))"
    Assert-True ((-not (Test-AclTargetSafe -Path $tg.Work).Ok)) 'and so is a temp work folder'
} finally { $script:AclAllowTempRoot = $true }
Assert-True ((Test-AclTargetSafe -Path $tx).Ok) 'with the switch on (tests) it passes'
Assert-True (-not (Test-AclTargetSafe -Path $env:SystemRoot).Ok -and -not (Test-AclTargetSafe -Path (Join-Path $env:ProgramFiles 'x')).Ok) 'the system roots come from the machine (SystemRoot, Program Files) as well as the C: spellings'

Section 'review round 7: R2-4: more launch styles in the lint (table)'
$lintRows2 = @(
    @('& $PSHOME\pwsh.exe -File x', $true, 'call operator on $PSHOME'), @('& (Get-Command pwsh).Source -File x', $true, 'call operator on a looked-up executable'),
    @('& $env:ComSpec /c dir', $true, 'call operator on ComSpec'), @('.\build.cmd', $true, 'a bare batch file'), @('build.bat x', $true, 'a bare .bat'),
    @('& ".\tools\run.cmd" x', $true, 'a quoted batch file through the call operator'),
    @('python3.12 x.py', $true, 'a versioned interpreter'), @('$p = [Process]::new(); $p.Start()', $true, 'Process::new'), @('$p = New-Object System.Diagnostics.Process', $true, 'New-Object Process'),
    @('Start-Process x -WindowStyle Hiddenx', $true, 'Hidden with a suffix'), @('Start-Process x -NoNewWindowx', $true, 'NoNewWindow with a suffix'),
    @('$x = (Get-Command pwsh).Source', $false, 'looking an executable up without running it'), @("Write-Host 'run build.cmd later'", $false, 'a batch file named in a string'),
    @('# .\build.cmd', $false, 'a batch file named in a comment'), @('$s = "python3.12 x.py"', $false, 'a versioned interpreter in a string'),
    @('Get-Command pwsh | Out-Null', $false, 'Get-Command alone'), @('$psi = New-Object System.Diagnostics.ProcessStartInfo; $psi.CreateNoWindow = $true', $false, 'ProcessStartInfo is not a Process')
)
foreach ($row in $lintRows2) {
    $hit = @(Find-VisibleLaunches -Text $row[0])
    if ($row[1]) { Assert-True ($hit.Count -ge 1) "lint flags: $($row[2])" } else { Assert-True ($hit.Count -eq 0) "lint passes: $($row[2])$(if ($hit.Count) { ' -- ' + $hit[0] })" }
}

Section 'no window, ever: the launch lint, its toggle test, and a check that this run opened none'
$bad1 = @(Find-VisibleLaunches -Text 'Start-Process -FilePath $p -ArgumentList $a -Wait')
Assert-True ($bad1.Count -eq 1) 'lint: a plain Start-Process is flagged'
Assert-True (@(Find-VisibleLaunches -Text 'Start-Process -FilePath $p -WindowStyle Hidden -Wait').Count -eq 0 -and @(Find-VisibleLaunches -Text 'Start-Process $p -NoNewWindow').Count -eq 0) 'lint: Start-Process with -WindowStyle Hidden or -NoNewWindow passes'
Assert-True (@(Find-VisibleLaunches -Text '$psi = New-Object System.Diagnostics.ProcessStartInfo').Count -eq 1 -and @(Find-VisibleLaunches -Text '$psi = New-Object System.Diagnostics.ProcessStartInfo; $psi.CreateNoWindow = $true').Count -eq 0) 'lint: a ProcessStartInfo needs CreateNoWindow = $true'
foreach ($line in '& $pw -NoProfile -File x.ps1', '& pwsh -File x.ps1', '& powershell.exe -File x.ps1', '& cmd /c dir', '& python x.py', '& runas.exe /trustlevel:0x20000 "x"') {
    Assert-True (@(Find-VisibleLaunches -Text $line).Count -ge 1) "lint: a direct console launch is flagged: $line"
}
Assert-True (@(Find-VisibleLaunches -Text '# Start-Process and runas are described here' ).Count -eq 0 -and @(Find-VisibleLaunches -Text ('<#' + "`n" + 'Start-Process runas /x' + "`n" + '#>')).Count -eq 0) 'lint: a comment or a block comment that only describes a launch is not one'
Assert-True (@(Find-VisibleLaunches -Text '$s = ''use Start-Process or & pwsh later''').Count -eq 0) 'lint: a quoted string that only describes a launch is not one'
# the files this change touches: new files in full, changed files by their ADDED lines
$repoRoot = Split-Path $PSScriptRoot -Parent
$newFiles = 'coder-acl-lib.ps1', 'provision-coder-acls.ps1', 'verify-coder-narrowing.ps1', 'verify-coder-off-differential.ps1', 'hidden-process-lib.ps1'
foreach ($f in $newFiles) {
    $p = Join-Path $PSScriptRoot $f
    if (-not (Test-Path $p)) { continue }
    $hits = @(Find-VisibleLaunches -Text ([IO.File]::ReadAllText($p)))
    Assert-True ($hits.Count -eq 0) "no visible launch in $f$(if ($hits.Count) { ' -- ' + ($hits -join ' | ') })"
}
foreach ($f in 'coder-containment-probe.ps1', 'coder-leg-queue.ps1', 'coder-leg-run.ps1', 'coder-provisioning-lib.ps1', 'fleet-lib.ps1', 'provision-coder-account.ps1', 'verify-coder-containment.ps1', 'verify-coder-fused-seam.ps1', 'verify-coder-provisioning.ps1') {
    $added = @(& git -C $repoRoot diff --unified=0 main -- "scripts/$f" 2>$null | Where-Object { $_ -match '^\+' -and $_ -notmatch '^\+\+\+' } | ForEach-Object { $_.Substring(1) })
    if ($added.Count -eq 0) { $added = @() }
    $hits = @(Find-VisibleLaunches -Text ($added -join "`n"))
    Assert-True ($hits.Count -eq 0) "no visible launch among the lines added to $f$(if ($hits.Count) { ' -- ' + ($hits -join ' | ') })"
}
$winNow = @(Get-NewVisibleConsoleWindows -BaselineIds $script:WindowBaseline)
Assert-True ($winNow.Count -eq 0) "this run opened no console window ($($winNow -join '; '))"
$hp = Invoke-HiddenProcess -FilePath (Get-Command pwsh).Source -ArgumentList @('-NoProfile', '-NonInteractive', '-Command', 'Write-Output hidden-ok; exit 7') -TimeoutSec 60
Assert-True ($hp.ExitCode -eq 7 -and $hp.Stdout.Trim() -eq 'hidden-ok') 'Invoke-HiddenProcess returns the exit code and the output of a hidden child'
$de = Join-Path $script:StandInDir 'deelev.out'
$null = Invoke-HiddenProcess -FilePath (Get-Command pwsh).Source -DeElevate -TimeoutSec 60 -ArgumentList @('-NoProfile', '-NonInteractive', '-Command', "([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator) | Set-Content -LiteralPath '$de'")
Assert-True ((Test-Path $de) -and ((Get-Content $de -Raw).Trim() -eq 'False')) 'a -DeElevate child runs with a standard token (not an administrator), without a window'

} finally {
    foreach ($c in $Cleanup) { try { Remove-NarrowTree -Root $c } catch { } ; if (Test-Path -LiteralPath $c) { try { Remove-Item -LiteralPath $c -Recurse -Force -ErrorAction SilentlyContinue } catch { } } }
}

Write-Host ''
if ($script:Fail -eq 0) { Write-Host "RESULT: $($script:Pass) passed, 0 failed" -ForegroundColor Green; exit 0 }
Write-Host "RESULT: $($script:Pass) passed, $($script:Fail) failed" -ForegroundColor Red
$script:Failures | ForEach-Object { Write-Host "  - $_" -ForegroundColor Red }
exit 1
