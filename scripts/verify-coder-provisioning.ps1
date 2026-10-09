#requires -Version 5.1
<#
.SYNOPSIS
  Verify the #775 ACP-01 provisioning PURE helpers (coder-provisioning-lib.ps1) — the secedit
  privilege-line manipulation and the code-read path SSOT — fully OFFLINE. No account, no secedit
  /configure, no ACL change; only the string/list logic the live provisioning depends on.

.DESCRIPTION
  These lock the two 2026-07-10 live-proof fixes at the logic layer:
    * SeBatchLogonRight: Resolve-PrivilegeLine adds the coder SID to the exported privilege line while
      PRESERVING every existing holder (so `secedit /configure` never wipes Administrators et al.),
      is idempotent (returns $null when already correct), and mirrors cleanly for -Rollback (remove).
    * the profile-homed code-read grant: Get-CoderCodeReadPaths is the exact 5-dir set, and NONE of the
      Get-CoderCodeReadExclusions (certs, repo roots, %LOCALAPPDATA%\BlarAI) may appear in it.

  Run it normally ( .\verify-coder-provisioning.ps1 ). Exit 0 if everything passed, 1 otherwise.
#>
param()
$ErrorActionPreference = 'Stop'
. "$PSScriptRoot\coder-provisioning-lib.ps1"

$script:Pass = 0; $script:Fail = 0
$script:Failures = New-Object System.Collections.ArrayList
function _pass($m) { $script:Pass++; Write-Host "  [PASS] $m" -ForegroundColor Green }
function _fail($m) { $script:Fail++; [void]$script:Failures.Add($m); Write-Host "  [FAIL] $m" -ForegroundColor Red }
function Section($t) { Write-Host ''; Write-Host "== $t ==" -ForegroundColor Cyan }
function Assert-Eq($e, $a, $m) { if ([string]$e -ceq [string]$a) { _pass $m } else { _fail "$m (expected '$e', got '$a')" } }
function Assert-Null($a, $m) { if ($null -eq $a) { _pass $m } else { _fail "$m (expected null, got '$a')" } }
function Assert-True($c, $m) { if ($c) { _pass $m } else { _fail "$m (expected True)" } }

$sid = 'S-1-5-21-4125655822-2918122917-2734753367-1009'
$export = @(
    '[Privilege Rights]',
    'SeBatchLogonRight = *S-1-5-32-544,*S-1-5-32-551,*S-1-5-32-559,*S-1-5-32-568',
    'SeChangeNotifyPrivilege = *S-1-1-0,*S-1-5-19'
)

Section 'Resolve-PrivilegeLine — add preserves existing holders + appends the coder SID'
$add = Resolve-PrivilegeLine -ExportLines $export -Privilege 'SeBatchLogonRight' -Sid $sid -Mode add
Assert-Eq "SeBatchLogonRight = *S-1-5-32-544,*S-1-5-32-551,*S-1-5-32-559,*S-1-5-32-568,*$sid" $add 'existing 4 holders preserved, coder appended'

Section 'Resolve-PrivilegeLine — add is idempotent (already present -> $null)'
$already = @('[Privilege Rights]', "SeBatchLogonRight = *S-1-5-32-544,*$sid")
Assert-Null (Resolve-PrivilegeLine -ExportLines $already -Privilege 'SeBatchLogonRight' -Sid $sid -Mode add) 'already-granted add is a no-op'

Section 'Resolve-PrivilegeLine — add when the privilege has NO current line creates it'
$noLine = @('[Privilege Rights]', 'SeSomethingElse = *S-1-5-32-544')
Assert-Eq "SeBatchLogonRight = *$sid" (Resolve-PrivilegeLine -ExportLines $noLine -Privilege 'SeBatchLogonRight' -Sid $sid -Mode add) 'missing line -> created with just the coder'

Section 'Resolve-PrivilegeLine — remove strips the coder, preserves the rest'
$rm = Resolve-PrivilegeLine -ExportLines $already -Privilege 'SeBatchLogonRight' -Sid $sid -Mode remove
Assert-Eq 'SeBatchLogonRight = *S-1-5-32-544' $rm 'coder removed, Administrators preserved'

Section 'Resolve-PrivilegeLine — remove is idempotent (absent -> $null); removing last -> empty line'
Assert-Null (Resolve-PrivilegeLine -ExportLines $export -Privilege 'SeBatchLogonRight' -Sid $sid -Mode remove) 'absent remove is a no-op'
$onlyCoder = @('[Privilege Rights]', "SeBatchLogonRight = *$sid")
Assert-Eq 'SeBatchLogonRight =' (Resolve-PrivilegeLine -ExportLines $onlyCoder -Privilege 'SeBatchLogonRight' -Sid $sid -Mode remove) 'removing the last holder yields an empty line'

Section 'Get-CoderCodeReadPaths — exactly the 5 profile-homed code dirs'
$agentic = 'C:\Users\mrbla\agentic-setup'; $blar = 'C:\Users\mrbla\blarai'
$paths = Get-CoderCodeReadPaths -AgenticRoot $agentic -BlarRoot $blar
$expected = @("$agentic\scripts", "$agentic\configs", "$agentic\.venv314-acp", "$blar\shared", "$blar\tools")
Assert-Eq ($expected -join '|') ($paths -join '|') 'the read-grant set is exactly scripts/configs/.venv314-acp/shared/tools'

Section 'Exclusions never overlap the read-grant set (certs, repo roots, %LOCALAPPDATA%\BlarAI)'
$excl = Get-CoderCodeReadExclusions -AgenticRoot $agentic -BlarRoot $blar
$norm = { param($p) ($p -replace '/', '\').TrimEnd('\').ToLower() }
$readNorm = @($paths | ForEach-Object { & $norm $_ })
$overlap = @($excl | Where-Object { $readNorm -contains (& $norm $_) })
Assert-True ($overlap.Count -eq 0) "no excluded path is in the read set (overlap=$($overlap -join ','))"
Assert-True (@($excl | Where-Object { $_ -like '*\certs' }).Count -eq 1) 'blarai\certs is explicitly excluded'
Assert-True ($excl -contains $blar) 'the blarai repo root is excluded (never granted wholesale)'
Assert-True (@($excl | Where-Object { $_ -like '*\BlarAI' }).Count -ge 1) '%LOCALAPPDATA%\BlarAI is excluded'

Section 'Get-ContainmentVerdict — the -AcceptedEgressGap mode (LA 2026-07-10, #775 c.1653)'
# all four pass -> clean pass, no warn (both modes)
$allPass = Get-ContainmentVerdict -OutboundBlocked $true -SecretReadsDenied $true -LoopbackOk $true -SidIsCoder $true
Assert-True ($allPass.Pass -and -not $allPass.EgressWarned) 'all-pass -> Pass, no egress warn (default mode)'
$allPassGap = Get-ContainmentVerdict -OutboundBlocked $true -SecretReadsDenied $true -LoopbackOk $true -SidIsCoder $true -AcceptedEgressGap
Assert-True ($allPassGap.Pass -and -not $allPassGap.EgressWarned) 'all-pass under -AcceptedEgressGap -> Pass, still no warn (egress WAS blocked)'

# outbound NOT blocked, DEFAULT mode -> hard FAIL naming check1
$obFail = Get-ContainmentVerdict -OutboundBlocked $false -SecretReadsDenied $true -LoopbackOk $true -SidIsCoder $true
Assert-True (-not $obFail.Pass) 'outbound-not-blocked WITHOUT the switch -> NOT Pass (hard fail)'
Assert-True ($obFail.Failed -contains 'check1-outbound-blocked') '  ...and check1 is in Failed'
Assert-True (-not $obFail.EgressWarned) '  ...and it is NOT a warn (never silently softened)'

# outbound NOT blocked, ACCEPTED-GAP mode -> WARN, checks 2-4 ok -> Pass
$obGap = Get-ContainmentVerdict -OutboundBlocked $false -SecretReadsDenied $true -LoopbackOk $true -SidIsCoder $true -AcceptedEgressGap
Assert-True ($obGap.Pass) 'outbound-not-blocked WITH -AcceptedEgressGap + checks 2-4 ok -> Pass'
Assert-True ($obGap.EgressWarned) '  ...recorded as an egress WARN'
Assert-True ($obGap.Failed.Count -eq 0) '  ...with nothing in Failed'

# checks 2-4 stay HARD-REQUIRED even under -AcceptedEgressGap (the gap is egress-ONLY)
$secretLeak = Get-ContainmentVerdict -OutboundBlocked $false -SecretReadsDenied $false -LoopbackOk $true -SidIsCoder $true -AcceptedEgressGap
Assert-True (-not $secretLeak.Pass) 'a secret-read failure still FAILS under -AcceptedEgressGap (checks 2-4 are hard)'
Assert-True ($secretLeak.Failed -contains 'check2-secret-reads-denied') '  ...check2 in Failed'
Assert-True (-not ($secretLeak.Failed -contains 'check1-outbound-blocked')) '  ...check1 is WARN-softened, not a fail'
$sidLeak = Get-ContainmentVerdict -OutboundBlocked $true -SecretReadsDenied $true -LoopbackOk $true -SidIsCoder $false -AcceptedEgressGap
Assert-True ((-not $sidLeak.Pass) -and ($sidLeak.Failed -contains 'check4-sid-is-coder')) 'a wrong-SID still FAILS under -AcceptedEgressGap'

Section 'the provisioning marker (written by provision-coder-account.ps1, read by the orchestrator)'
$mk = Join-Path ([IO.Path]::GetTempPath()) ("marker-" + [guid]::NewGuid().ToString('N') + '\sub\coder-provisioned.marker')
$written = Write-CoderProvisionMarker -Path $mk -CoderUser 'blarai-coder' -CoderSid 'S-1-5-21-1-2-3-1001'
Assert-Eq $mk $written 'Write-CoderProvisionMarker returns the path it wrote'
Assert-True (Test-Path -LiteralPath $mk) 'the marker file exists (parent folder created)'
$mkObj = Get-Content -LiteralPath $mk -Raw | ConvertFrom-Json
Assert-Eq 'blarai-coder' $mkObj.coder_user 'marker records the coder user'
Assert-Eq 'S-1-5-21-1-2-3-1001' $mkObj.coder_sid 'marker records the coder SID'
Assert-True ([bool]$mkObj.provisioned_utc) 'marker records when it was written'
Assert-True (-not (Test-Path -LiteralPath "$mk.tmp")) 'no temp file is left beside the marker'
$again = Write-CoderProvisionMarker -Path $mk
Assert-True (Test-Path -LiteralPath $mk) 'writing again (re-provisioning) is idempotent'
Assert-True (Remove-CoderProvisionMarker -Path $mk) 'Remove-CoderProvisionMarker removes it and says so'
Assert-True (-not (Remove-CoderProvisionMarker -Path $mk)) 'removing an absent marker is a no-op that says so'
Remove-Item (Split-Path (Split-Path $mk -Parent) -Parent) -Recurse -Force -ErrorAction SilentlyContinue
Assert-Eq 'C:\blarai-fleet\coder-provisioned.marker' (Get-CoderProvisionMarkerPath) 'the marker lives beside the fleet root'
$provSrc = Get-Content "$PSScriptRoot\provision-coder-account.ps1" -Raw
Assert-True ($provSrc -match 'Write-CoderProvisionMarker') 'provision-coder-account.ps1 writes the marker'
Assert-True ($provSrc -match 'Remove-CoderProvisionMarker') 'provision-coder-account.ps1 -Rollback removes the marker'

Section 'the worktree-root deny is an action of the ACL stage (#1686): built from the plan, applied by the stage, never printed-and-forgotten'
. "$PSScriptRoot\coder-acl-lib.ps1"
$fakeRead = { param($p) [pscustomobject]@{ Path = $p; Owner = $null; Protected = $true; Aces = @() } }
$planP = @(Get-CoderAclPlan -CoderSid 'S-1-5-21-1-2-3-1001' -OperatorSid 'S-1-5-21-1-2-3-1000' -ProjectsDir 'C:\P\projects' -WorktreeBase 'C:\blarai-fleet\worktrees' -ModelRoots @() -ProfileCleanupPaths @() -ReadAcl $fakeRead)
$denyAct = @($planP | Where-Object { $_.Id -eq 'worktree-root-deny' })[0]
Assert-True ($null -ne $denyAct) 'the plan carries the worktree-root deny action'
$denyCmds = @($denyAct.Steps | Where-Object { $_.Op -eq 'Deny' } | ForEach-Object { Format-IcaclsText -IcaclsArgs (ConvertTo-IcaclsCommand -Path $denyAct.Path -Op $_) })
Assert-Eq 2 $denyCmds.Count 'two deny ACEs: delete-child on the base, delete on the roots'
Assert-Eq 'icacls C:\blarai-fleet\worktrees /deny *S-1-5-21-1-2-3-1001:(DC)' $denyCmds[0] 'ACE 1: deny FILE_DELETE_CHILD (DC) to the coder on the worktree base'
Assert-Eq 'icacls C:\blarai-fleet\worktrees /deny *S-1-5-21-1-2-3-1001:(CI)(IO)(NP)(DE)' $denyCmds[1] 'ACE 2: deny DELETE (DE) on the worktree roots only (inherit-only, container, no-propagate)'
Assert-True ($denyCmds[1] -match '\(NP\)' -and $denyCmds[1] -match '\(IO\)') 'ACE 2 does not propagate below the roots (the coder keeps Modify inside a worktree)'
$provSrc2 = Get-Content "$PSScriptRoot\provision-coder-account.ps1" -Raw
Assert-True ($provSrc2 -match 'provision-coder-acls\.ps1' -and $provSrc2 -match '& \$aclStage -Apply') 'provision-coder-account.ps1 applies the ACL stage (which carries the deny)'
Assert-True ($provSrc2 -notmatch 'Get-CoderWorktreeRootDenyCommands') 'the old print-only function is gone from the provisioning script'
Assert-True (-not (Get-Command Get-CoderWorktreeRootDenyCommands -ErrorAction SilentlyContinue)) 'and from the lib'

Section 'the projects folder is READ-only for the coder after provisioning (#1678), and the fleet root is closed (#1686)'
$pn = @($planP | Where-Object { $_.Id -eq 'projects-narrow' })[0]
Assert-True (@($pn.Steps | Where-Object { $_.Op -in 'SetGrant', 'AddGrant' -and $_.Rights -in 'M', 'F' }).Count -eq 0) 'no step of the projects action grants the coder Modify or Full control'
Assert-True (@($pn.Steps | Where-Object { $_.Op -eq 'SetGrant' -and $_.Rights -eq 'RX' -and $_.Flags -eq '(OI)(CI)' }).Count -eq 1) 'the one grant on projects is inheritable read-and-run'
Assert-True (@($pn.Steps | Where-Object { $_.Op -eq 'RemoveGrants' -and $_.Tree }).Count -eq 1) 'the old grant is undone first (a targeted tree removal for the coder SID)'
Assert-True ($provSrc2 -notmatch 'Add-Ace \$ProjectsDir' -and $provSrc2 -notmatch 'Add-Ace \$FleetRoot') 'provision-coder-account.ps1 no longer grants on the projects folder or the fleet root'
Assert-True ($provSrc2 -notmatch '\(OI\)\(CI\)M') 'provision-coder-account.ps1 contains no inheritable Modify grant'
Assert-True ($provSrc2 -notmatch '/T /C' -and $provSrc2 -match 'Invoke-AclTreeRemoveGrants') 'provision-coder-account.ps1 never uses icacls /T (it follows directory symlinks); the -Rollback removal is the no-follow walk'

Write-Host ''
if ($script:Fail -eq 0) {
    Write-Host "RESULT: $($script:Pass) passed, 0 failed" -ForegroundColor Green; exit 0
} else {
    Write-Host "RESULT: $($script:Pass) passed, $($script:Fail) failed" -ForegroundColor Red
    $script:Failures | ForEach-Object { Write-Host "  - $_" -ForegroundColor Red }
    exit 1
}
