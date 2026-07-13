#requires -Version 5.1
<#
.SYNOPSIS
  Pure helpers for the #775 ACP-01 coder provisioning — the string/list logic factored OUT of
  provision-coder-account.ps1 so it is unit-testable offline (verify-coder-provisioning.ps1) without
  executing any live account/secedit/ACL change. Dot-source it; it has NO side effects on load.

.DESCRIPTION
  Two gaps the live proof surfaced (2026-07-10) are fixed on top of this lib:
    * the coder account lacked SeBatchLogonRight, so a password-principal scheduled task never ran
      (0x41303 SCHED_S_TASK_HAS_NOT_RUN) -> Resolve-PrivilegeLine builds the secedit line that grants it,
      preserving the existing holders (idempotent; a remove mode mirrors it for -Rollback);
    * the fleet's OWN code is profile-homed (under C:\Users\mrbla), so the coder — a separate standard
      account — could not even READ coder-leg-run.ps1 or the driver modules -> Get-CoderCodeReadPaths is
      the SSOT of exactly which code dirs get a coder Read+Execute grant, and Get-CoderCodeReadExclusions
      names what must NEVER be granted (certs, repo roots wholesale, %LOCALAPPDATA%\BlarAI).
#>

function Resolve-PrivilegeLine {
    # PURE. Given the lines of a `secedit /export /areas USER_RIGHTS` INF, return the NEW
    # "[Privilege Rights]" line for $Privilege after adding/removing the coder $Sid, preserving all other
    # holders. Returns $null when there is nothing to change (add: already present; remove: absent) so the
    # caller can skip the live `secedit /configure` (idempotent). $Sid is the bare SID (no leading '*').
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][string[]]$ExportLines,
        [Parameter(Mandatory)][string]$Privilege,
        [Parameter(Mandatory)][string]$Sid,
        [Parameter(Mandatory)][ValidateSet('add','remove')][string]$Mode
    )
    $token = "*$Sid"
    $line = $ExportLines | Where-Object { $_ -match "^\s*$([regex]::Escape($Privilege))\s*=" } | Select-Object -First 1
    $members = @()
    if ($line) {
        $rhs = ($line -split '=', 2)[1]
        $members = @($rhs -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ })
    }
    if ($Mode -eq 'add') {
        if ($members -contains $token) { return $null }             # already granted -> no-op
        return "$Privilege = " + (@($members + $token) -join ',')
    } else {
        if (-not ($members -contains $token)) { return $null }      # not present -> no-op
        $kept = @($members | Where-Object { $_ -ne $token })
        if ($kept.Count -eq 0) { return "$Privilege =" }            # removed the last holder
        return "$Privilege = " + ($kept -join ',')
    }
}

function Get-CoderCodeReadPaths {
    # SSOT: the EXACT code dirs the coder gets Read+Execute on so the de-elevated leg can load its own
    # runner + the driver modules. Profile-homed (under C:\Users\mrbla), so a separate standard account
    # needs an explicit ACE — the "fleet's own code is profile-homed" breakage class (design §3.4).
    # NOTE (verify-not-assume): these are DEEP grants; they rely on Everyone holding Bypass Traverse
    # Checking (SeChangeNotifyPrivilege) so the coder can traverse C:\Users\mrbla WITHOUT a grant on the
    # profile root. verify-coder-containment.ps1 proves the coder can actually READ the code by running
    # the leg successfully (a real read of coder-leg-run.ps1), rather than assuming the traverse right.
    param(
        [Parameter(Mandatory)][string]$AgenticRoot,
        [string]$BlarRoot = 'C:\Users\mrbla\blarai'
    )
    @(
        (Join-Path $AgenticRoot 'scripts'),
        (Join-Path $AgenticRoot 'configs'),
        (Join-Path $AgenticRoot '.venv314-acp'),
        (Join-Path $BlarRoot 'shared'),
        (Join-Path $BlarRoot 'tools')
    )
}

function Get-CoderCodeReadExclusions {
    # NAMED so verify can assert none of these ever appears in the read-grant set. The coder must NOT get
    # the repo roots wholesale, the mTLS material, or the runtime keystore.
    param(
        [Parameter(Mandatory)][string]$AgenticRoot,
        [string]$BlarRoot = 'C:\Users\mrbla\blarai'
    )
    @(
        (Join-Path $BlarRoot 'certs'),
        $BlarRoot,
        $AgenticRoot,
        (Join-Path $env:LOCALAPPDATA 'BlarAI')
    )
}

function Get-ContainmentVerdict {
    # PURE. Decide the overall containment-proof verdict from the four check outcomes + the
    # -AcceptedEgressGap mode, so both modes are unit-testable offline without a live probe. Check 1
    # (outbound) is the ONLY check the accepted gap can soften -- and only to a conscious WARN, never a
    # silent pass: WITHOUT the switch a non-blocked egress is a hard FAIL (the gap must be re-invoked every
    # run). Checks 2-4 (secret-read denial, loopback, SID) are HARD-REQUIRED in BOTH modes -- the accepted
    # gap is about egress ONLY (LA 2026-07-10, #775 c.1653: Bitdefender owns filtering, the per-SID rule is
    # inert). Returns { Pass; Failed[]; EgressWarned }.
    param(
        [Parameter(Mandatory)][bool]$OutboundBlocked,
        [Parameter(Mandatory)][bool]$SecretReadsDenied,
        [Parameter(Mandatory)][bool]$LoopbackOk,
        [Parameter(Mandatory)][bool]$SidIsCoder,
        [switch]$AcceptedEgressGap
    )
    $failed = New-Object System.Collections.ArrayList
    $egressWarned = $false
    if (-not $OutboundBlocked) {
        if ($AcceptedEgressGap) { $egressWarned = $true } else { [void]$failed.Add('check1-outbound-blocked') }
    }
    if (-not $SecretReadsDenied) { [void]$failed.Add('check2-secret-reads-denied') }
    if (-not $LoopbackOk)        { [void]$failed.Add('check3-loopback-ok') }
    if (-not $SidIsCoder)        { [void]$failed.Add('check4-sid-is-coder') }
    return [pscustomobject]@{
        Pass         = ($failed.Count -eq 0)
        Failed       = @($failed)
        EgressWarned = $egressWarned
    }
}
