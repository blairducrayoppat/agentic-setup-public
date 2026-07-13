#requires -Version 5.1
<#
.SYNOPSIS
  Provision the #775 ACP-01 Decision-1(b) containment floor: a restricted `blarai-coder`
  standard account + a per-SID deny-by-default outbound firewall rule + the relocated shared
  worktree base + a scoped Modify grant on the target-repos dir. IDEMPOTENT; -Rollback removes it.

.DESCRIPTION
  Decision-1(b) (Vikunja #787 / PHASE1_DISPATCH_THREAT_MODEL §5) is the universal floor for all
  dispatched code: the coding fleet stops running as the operator (elevated overnight) and runs as a
  deliberately POWERLESS local standard account whose egress is blocked at the OS by a per-SID rule.

  This script builds that substrate. It is written to be REVIEWED then run by the coordinator under
  supervision (author != verifier on a security-critical machine change); it does NOT run itself and
  takes no action on import.

  WHAT IT DOES (each step idempotent — safe to re-run):
    1. ACCOUNT   — create local standard user `blarai-coder`, member of **Users only** (never
                   Administrators / Power Users). A strong random password is generated IN MEMORY as a
                   SecureString and NEVER written to disk in plaintext (D-C). New-LocalUser takes the
                   SecureString directly; the only place a plaintext form is ever materialized is the
                   Task Scheduler registration, which vaults it in LSA secrets (register-coder-leg-task.ps1).
    2. WORKTREE  — create the shared throwaway worktree base C:\blarai-fleet\worktrees OUTSIDE the
                   operator profile (D-B), with **dual-SID Modify** (operator + coder, inherited) so the
                   coder can build there and the orchestrator-side merge can still read the files. This is
                   what lets the operator-profile default-deny do the containment heavy-lifting instead of
                   hand-punching read-holes into C:\Users\mrbla.
    3. PROJECTS  — grant the coder SID **Modify** on C:\Users\mrbla\projects (the target repos it must
                   read/build). This is the one deliberate, scoped read into the profile — paired with the
                   §5.2 operator footgun: NEVER point the fleet at a repo holding live secrets.
    4. SECRETS   — the threat-model secret list (~/.ssh, ~/.git-credentials, %LOCALAPPDATA%\BlarAI,
                   ~/.aws, ~/.azure, ~/.config/gcloud, backup/secrets-staging) all live UNDER the operator
                   profile, which Windows ALREADY default-denies to a separate standard user — so we add
                   NO explicit Deny there (poking into the profile is exactly what D-B avoids). Explicit
                   Deny ACEs are added ONLY for out-of-profile secret paths the operator names via
                   -ExtraSecretPaths (belt over the default suspenders).
    5. FIREWALL  — a per-SID deny-by-default OUTBOUND block (Windows Filtering Platform ALE_USER_ID via
                   New-NetFirewallRule -LocalUser <coder-SID-SDDL>). Per-SID, NEVER per-exe — the E8
                   incident (a per-exe curl/certutil block broke the operator's OWN tools and was reverted)
                   is the precedent. This touches ONLY the coder account. Loopback (127.0.0.0/8, the model
                   at 127.0.0.1:8000) survives on the Windows loopback exemption — VERIFIED, not assumed,
                   by verify-coder-containment.ps1 check 3 (the positive control). If that check ever fails,
                   re-run with -ExcludeLoopbackFromBlock to scope the block's RemoteAddress off 127/8.
    6. TASK      — if register-coder-leg-task.ps1 is present, register the DORMANT on-demand
                   \BlarAI\BlarAI-Coder-Leg scheduled task as blarai-coder (RunLevel Limited), vaulting the
                   credential in LSA secrets (D-C). The task only ever runs when Start-ScheduledTask is
                   called (no time trigger) — dormant until containment=restricted_account flips.

  SAFETY: this is a real machine-state change (an account + a firewall rule). It is NOT destructive to
  the operator's account or data. -Rollback cleanly removes the account, the rule, the grants, and the
  task. The whole point of the powerless coder account is that even a leaked coder credential buys an
  attacker nothing the ACLs + firewall don't already contain (the D-C compensating control).

.PARAMETER Rollback
  Remove everything this script creates (account, firewall rule, ACL grants, scheduled task). Idempotent.

.PARAMETER ForceNewPassword
  Reset the coder account's password to a fresh generated one and re-vault the scheduled-task credential.
  Use when re-keying; without it, a re-run on an existing account leaves the password (and vaulted cred)
  untouched, so it cannot re-register the task credential.

.PARAMETER ExtraSecretPaths
  Out-of-profile secret directories to explicitly Deny the coder SID (the in-profile secrets are already
  default-denied). Each is added with an inherited Deny(Read) ACE if it exists.

.PARAMETER ExcludeLoopbackFromBlock
  Scope the outbound block's RemoteAddress off 127.0.0.0/8 (only needed if the Windows loopback exemption
  does not hold on this box — verify-coder-containment.ps1 check 3 is the arbiter).

.EXAMPLE
  # Review first, then (coordinator, elevated):
  .\provision-coder-account.ps1
  # Live proof:
  .\verify-coder-containment.ps1 -LoopbackStub    # OVMS down today
  # Tear down:
  .\provision-coder-account.ps1 -Rollback
#>
[CmdletBinding()]
param(
    [switch]$Rollback,
    [switch]$ForceNewPassword,
    [string[]]$ExtraSecretPaths = @(),
    [switch]$ExcludeLoopbackFromBlock,
    [string]$CoderUser = 'blarai-coder',
    [string]$WorktreeBase = 'C:\blarai-fleet\worktrees',
    [string]$ProjectsDir = 'C:\Users\mrbla\projects',
    [string]$BlarRoot = 'C:\Users\mrbla\blarai',
    [string]$FirewallRuleName = 'blarai-coder-deny-outbound',
    [string]$TaskPath = '\BlarAI\',
    [string]$TaskName = 'BlarAI-Coder-Leg'
)
$ErrorActionPreference = 'Stop'

function Write-Step([string]$m) { Write-Host "[provision] $m" -ForegroundColor Cyan }
function Write-Ok([string]$m)   { Write-Host "  [ok] $m" -ForegroundColor Green }
function Write-Skip([string]$m) { Write-Host "  [skip] $m" -ForegroundColor DarkGray }

function Assert-Elevated {
    $isAdmin = [Security.Principal.WindowsPrincipal]::new(
        [Security.Principal.WindowsIdentity]::GetCurrent()
    ).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    if (-not $isAdmin) {
        throw "provision-coder-account.ps1 must run ELEVATED (it creates a local account + firewall rule). " +
              "Re-run from an Administrator PowerShell."
    }
}

function New-StrongPassword {
    # 24 chars from a broad set via the crypto RNG, guaranteeing the 3-of-4 complexity classes.
    $lower = 'abcdefghijkmnpqrstuvwxyz'; $upper = 'ABCDEFGHJKLMNPQRSTUVWXYZ'
    $digit = '23456789'; $sym = '!@#$%^&*()-_=+[]{}'
    $all = ($lower + $upper + $digit + $sym).ToCharArray()
    $rng = [System.Security.Cryptography.RandomNumberGenerator]::Create()
    try {
        $bytes = New-Object 'byte[]' 64
        $rng.GetBytes($bytes)
        $sb = New-Object System.Text.StringBuilder
        # seed one of each class first
        foreach ($set in @($lower, $upper, $digit, $sym)) {
            [void]$sb.Append($set[ [int]($bytes[$sb.Length] % $set.Length) ])
        }
        for ($i = 4; $i -lt 24; $i++) {
            [void]$sb.Append($all[ [int]($bytes[$i] % $all.Length) ])
        }
        $plain = $sb.ToString()
        $secure = ConvertTo-SecureString $plain -AsPlainText -Force
        # Best-effort scrub of the transient plaintext.
        $plain = $null
        return $secure
    } finally {
        $rng.Dispose()
    }
}

function Get-CoderSid([string]$user) {
    try { return (Get-LocalUser $user -ErrorAction Stop).SID.Value } catch { return $null }
}

function Add-Ace([string]$path, [string]$sid, [string]$rights, [string]$type) {
    # Idempotent icacls grant/deny (inherited). $type = 'grant' | 'deny'. Uses the SID form (*S-...)
    # so it is language-independent. Rights e.g. '(OI)(CI)M' (modify, inherited) or '(OI)(CI)(R)'.
    if (-not (Test-Path $path)) { Write-Skip "path absent, no ACE: $path"; return }
    $spec = "*$sid`:$rights"
    if ($type -eq 'deny') {
        & icacls $path /deny $spec /T /C | Out-Null
    } else {
        & icacls $path /grant $spec /T /C | Out-Null
    }
    if ($LASTEXITCODE -ne 0) { throw "icacls $type failed on $path (exit $LASTEXITCODE)" }
    Write-Ok "$type $rights -> $path"
}

function Remove-Ace([string]$path, [string]$sid) {
    if (-not (Test-Path $path)) { return }
    & icacls $path /remove:g "*$sid" /T /C | Out-Null
    & icacls $path /remove:d "*$sid" /T /C | Out-Null
    Write-Ok "removed coder ACEs from $path"
}

# Pure helpers (Resolve-PrivilegeLine + the code-read path SSOT), factored out so they are unit-testable
# offline in verify-coder-provisioning.ps1 without executing any live change.
. "$PSScriptRoot\coder-provisioning-lib.ps1"

function Set-BatchLogonRight {
    # Grant/revoke SeBatchLogonRight ('Log on as a batch job') for the coder SID via secedit, PRESERVING
    # every other holder. A password-principal scheduled task REQUIRES this right; a standard user lacks
    # it by default -- which is exactly why the coder-leg task silently never ran (0x41303
    # SCHED_S_TASK_HAS_NOT_RUN, the 2026-07-10 live proof). Idempotent: skips the live `secedit /configure`
    # when the membership is already correct (Resolve-PrivilegeLine returns $null).
    param([Parameter(Mandatory)][string]$Sid, [ValidateSet('add','remove')][string]$Mode = 'add')
    $stamp = [guid]::NewGuid().ToString('N')
    $exportInf = Join-Path $env:TEMP "acp01-ur-exp-$stamp.inf"
    $importInf = Join-Path $env:TEMP "acp01-ur-imp-$stamp.inf"
    $db        = Join-Path $env:TEMP "acp01-ur-$stamp.sdb"
    try {
        & secedit /export /cfg $exportInf /areas USER_RIGHTS *> $null
        $lines = if (Test-Path $exportInf) { Get-Content $exportInf } else { @() }
        $newLine = Resolve-PrivilegeLine -ExportLines $lines -Privilege 'SeBatchLogonRight' -Sid $Sid -Mode $Mode
        if ($null -eq $newLine) {
            Write-Ok "'Log on as a batch job' already $(if ($Mode -eq 'add') { 'granted' } else { 'absent' }) for the coder SID (idempotent)"
            return
        }
        Set-Content -Path $importInf -Encoding Unicode -Value @(
            '[Unicode]', 'Unicode=yes', '[Version]', 'signature="$CHICAGO$"', 'Revision=1',
            '[Privilege Rights]', $newLine
        )
        & secedit /configure /db $db /cfg $importInf /areas USER_RIGHTS *> $null
        if ($LASTEXITCODE -ne 0) { throw "secedit /configure failed (exit $LASTEXITCODE) applying SeBatchLogonRight" }
        Write-Ok "$(if ($Mode -eq 'add') { 'granted' } else { 'revoked' }) 'Log on as a batch job' (SeBatchLogonRight) for the coder SID"
    } finally {
        foreach ($f in @($exportInf, $importInf, $db)) { Remove-Item $f -ErrorAction SilentlyContinue }
    }
}

# ---------------------------------------------------------------------------
# ROLLBACK
# ---------------------------------------------------------------------------
if ($Rollback) {
    Assert-Elevated
    Write-Step "ROLLBACK — removing the ACP-01 containment substrate"
    # task
    try {
        if (Get-ScheduledTask -TaskPath $TaskPath -TaskName $TaskName -ErrorAction SilentlyContinue) {
            Unregister-ScheduledTask -TaskPath $TaskPath -TaskName $TaskName -Confirm:$false
            Write-Ok "unregistered $TaskPath$TaskName"
        } else { Write-Skip "scheduled task not present" }
    } catch { Write-Warning "task removal: $($_.Exception.Message)" }
    # firewall
    try {
        if (Get-NetFirewallRule -DisplayName $FirewallRuleName -ErrorAction SilentlyContinue) {
            Remove-NetFirewallRule -DisplayName $FirewallRuleName
            Write-Ok "removed firewall rule '$FirewallRuleName'"
        } else { Write-Skip "firewall rule not present" }
    } catch { Write-Warning "firewall removal: $($_.Exception.Message)" }
    # ACL grants
    $sid = Get-CoderSid $CoderUser
    if ($sid) {
        Remove-Ace $ProjectsDir $sid
        Remove-Ace (Split-Path $WorktreeBase -Parent) $sid   # the fleet root (covers worktrees + coder-leg)
        foreach ($p in $ExtraSecretPaths) { Remove-Ace $p $sid }
        # the profile-homed code-read grants (step 7) + the batch-logon right (step 1)
        $AgenticRoot = Split-Path $PSScriptRoot -Parent
        foreach ($cp in (Get-CoderCodeReadPaths -AgenticRoot $AgenticRoot -BlarRoot $BlarRoot)) { Remove-Ace $cp $sid }
        try { Set-BatchLogonRight -Sid $sid -Mode remove } catch { Write-Warning "batch-logon revoke: $($_.Exception.Message)" }
    } else { Write-Skip "coder account absent — no ACEs to remove" }
    # account
    try {
        if (Get-LocalUser $CoderUser -ErrorAction SilentlyContinue) {
            Remove-LocalUser $CoderUser
            Write-Ok "removed local user '$CoderUser'"
        } else { Write-Skip "local user not present" }
    } catch { Write-Warning "account removal: $($_.Exception.Message)" }
    Write-Step "ROLLBACK complete."
    exit 0
}

# ---------------------------------------------------------------------------
# PROVISION
# ---------------------------------------------------------------------------
Assert-Elevated
Write-Step "PROVISION — ACP-01 Decision-1(b) containment floor for '$CoderUser'"

# 1. account -----------------------------------------------------------------
Write-Step "1/7 account (standard user, Users group only) + 'Log on as a batch job' right"
$secure = $null
$existing = Get-LocalUser $CoderUser -ErrorAction SilentlyContinue
if (-not $existing) {
    $secure = New-StrongPassword
    New-LocalUser -Name $CoderUser -Password $secure -PasswordNeverExpires `
        -Description 'BlarAI ACP-01 restricted coder (#787 1b)' `
        -AccountNeverExpires | Out-Null
    Write-Ok "created local user '$CoderUser'"
} elseif ($ForceNewPassword) {
    $secure = New-StrongPassword
    Set-LocalUser -Name $CoderUser -Password $secure
    Write-Ok "reset password for existing '$CoderUser' (-ForceNewPassword)"
} else {
    Write-Skip "'$CoderUser' already exists (password left as-is; pass -ForceNewPassword to re-key)"
}
# Users-only membership (idempotent). Explicitly NOT Administrators / Power Users.
try {
    if (-not (Get-LocalGroupMember -Group 'Users' -Member $CoderUser -ErrorAction SilentlyContinue)) {
        Add-LocalGroupMember -Group 'Users' -Member $CoderUser
    }
    Write-Ok "'$CoderUser' is a member of Users"
} catch { Write-Warning "Users membership: $($_.Exception.Message)" }
foreach ($priv in @('Administrators','Power Users')) {
    try {
        if (Get-LocalGroupMember -Group $priv -Member $CoderUser -ErrorAction SilentlyContinue) {
            Remove-LocalGroupMember -Group $priv -Member $CoderUser -Confirm:$false
            Write-Ok "removed '$CoderUser' from $priv (must not be privileged)"
        }
    } catch { }  # group may not exist (Power Users) — fine
}
$sid = Get-CoderSid $CoderUser
if (-not $sid) { throw "could not resolve the SID for '$CoderUser' after creation" }
Write-Ok "coder SID = $sid"
# The 'Log on as a batch job' right (SeBatchLogonRight): a password-principal scheduled task REQUIRES it,
# and a standard user does NOT have it by default -- without it the coder-leg task is registered Ready but
# NEVER RUNS (0x41303 SCHED_S_TASK_HAS_NOT_RUN, the 2026-07-10 live proof). Idempotent.
Set-BatchLogonRight -Sid $sid -Mode add

# 2. relocated shared worktree base (dual-SID Modify) -------------------------
# Grant dual-SID Modify on the FLEET ROOT (parent of the worktree base) so the same inherited ACEs
# cover BOTH the worktree base AND the coder-leg file-queue (C:\blarai-fleet\coder-leg, Stage 4) — one
# shared tree, one grant, both SIDs can modify, the operator-profile default-deny stays intact.
$FleetRoot = Split-Path $WorktreeBase -Parent    # C:\blarai-fleet
Write-Step "2/7 shared fleet tree '$FleetRoot' (dual-SID Modify, outside the profile)"
New-Item -ItemType Directory -Force $FleetRoot | Out-Null
New-Item -ItemType Directory -Force $WorktreeBase | Out-Null
New-Item -ItemType Directory -Force (Join-Path $FleetRoot 'coder-leg\queue') | Out-Null
New-Item -ItemType Directory -Force (Join-Path $FleetRoot 'coder-leg\results') | Out-Null
$operatorSid = ([Security.Principal.WindowsIdentity]::GetCurrent()).User.Value
Add-Ace $FleetRoot $sid '(OI)(CI)M'           # coder: modify, inherited (covers worktrees + coder-leg)
Add-Ace $FleetRoot $operatorSid '(OI)(CI)M'   # operator (merge/orchestrator side): modify, inherited

# 3. target-repos Modify grant (the one deliberate scoped read into the profile) --
Write-Step "3/7 coder Modify on '$ProjectsDir' (the target repos it builds)"
if (Test-Path $ProjectsDir) {
    Add-Ace $ProjectsDir $sid '(OI)(CI)M'
    Write-Host "  [footgun] NEVER point the fleet at a repo under $ProjectsDir that holds live secrets (§5.2)." -ForegroundColor Yellow
} else {
    Write-Skip "$ProjectsDir absent — create it before first dispatch, then re-run to grant"
}

# 4. explicit Deny only for OUT-OF-PROFILE secrets ---------------------------
Write-Step "4/7 out-of-profile secret Deny ACEs (in-profile secrets are already default-denied)"
if ($ExtraSecretPaths.Count -eq 0) {
    Write-Skip "none named — the threat-model secrets (~/.ssh, %LOCALAPPDATA%\BlarAI, ~/.aws, …) live under the operator profile and are already default-denied to a separate standard user"
} else {
    foreach ($p in $ExtraSecretPaths) { Add-Ace $p $sid '(OI)(CI)(R)' 'deny' }
}

# 5. per-SID outbound block (per-SID, NEVER per-exe — the E8 lesson) ----------
Write-Step "5/7 per-SID deny-by-default outbound firewall rule"
if (Get-NetFirewallRule -DisplayName $FirewallRuleName -ErrorAction SilentlyContinue) {
    Remove-NetFirewallRule -DisplayName $FirewallRuleName   # recreate for a known clean state
}
$ruleArgs = @{
    DisplayName = $FirewallRuleName
    Direction   = 'Outbound'
    Action      = 'Block'
    Profile     = 'Any'
    Enabled     = 'True'
    LocalUser   = "D:(A;;CC;;;$sid)"   # WFP ALE_USER_ID — fires only when the token is the coder SID
    Description = 'ACP-01 Decision-1(b): deny all outbound for the blarai-coder SID (per-SID, not per-exe). Loopback to the model survives on the Windows loopback exemption (verify check 3).'
}
if ($ExcludeLoopbackFromBlock) {
    # Only if the loopback exemption does not hold: block all IPv4 EXCEPT 127/8.
    $ruleArgs['RemoteAddress'] = @('0.0.0.0-126.255.255.255','128.0.0.0-255.255.255.255')
    Write-Host "  [note] loopback excluded from the block's RemoteAddress (IPv4 non-127/8 only)." -ForegroundColor Yellow
}
New-NetFirewallRule @ruleArgs | Out-Null
Write-Ok "firewall rule '$FirewallRuleName' -> BLOCK outbound for SID $sid"
Write-Host "  [verify-not-assume] loopback-to-model (127.0.0.1:8000) is PROVEN by verify-coder-containment.ps1 check 3, not assumed." -ForegroundColor Yellow

# 6. vault the scheduled-task credential (D-C) -------------------------------
Write-Step "6/7 scheduled-task credential (DORMANT on-demand \BlarAI\$TaskName as $CoderUser)"
$registerScript = Join-Path $PSScriptRoot 'register-coder-leg-task.ps1'
if (-not (Test-Path $registerScript)) {
    Write-Skip "register-coder-leg-task.ps1 not present — task not registered (Stage 4). Account/firewall/tree are provisioned."
} elseif ($null -eq $secure) {
    Write-Skip "no fresh password this run (account pre-existed) — task credential NOT re-vaulted. Re-run with -ForceNewPassword to re-key + register."
} else {
    & $registerScript -CoderUser $CoderUser -PasswordSecure $secure -TaskPath $TaskPath -TaskName $TaskName
    Write-Ok "registered dormant on-demand task \BlarAI\$TaskName as $CoderUser (credential vaulted in LSA secrets)"
}
# Scrub the SecureString reference.
if ($secure -is [System.IDisposable]) { try { $secure.Dispose() } catch {} }
$secure = $null

# 7. coder Read+Execute on the fleet's OWN (profile-homed) code ---------------
# The fleet scripts/config/venv and the blarai driver modules all live UNDER C:\Users\mrbla, which is
# default-denied to a separate standard account -- so the de-elevated leg could not even READ its own
# runner (the 2026-07-10 live proof: coder-leg-run.ps1 was SYSTEM/Administrators/mrbla only, no coder ACE).
# This is the "the fleet's own code is profile-homed" breakage class (design §3.4). Grant Read+Execute on
# EXACTLY the code dirs the leg must load, and nothing more -- NOT the repo roots wholesale, NOT certs, NOT
# %LOCALAPPDATA%\BlarAI (the SSOT + exclusions live in coder-provisioning-lib.ps1). Deep grants rely on
# Everyone's Bypass Traverse Checking (SeChangeNotifyPrivilege) to traverse the profile root without a
# grant there -- proven, not assumed, by verify-coder-containment.ps1 (the leg actually reading its runner).
$AgenticRoot = Split-Path $PSScriptRoot -Parent
Write-Step "7/7 coder Read+Execute on the fleet's own (profile-homed) code"
$excluded = Get-CoderCodeReadExclusions -AgenticRoot $AgenticRoot -BlarRoot $BlarRoot
$excludedNorm = @($excluded | ForEach-Object { ($_ -replace '/', '\').TrimEnd('\').ToLower() })
foreach ($cp in (Get-CoderCodeReadPaths -AgenticRoot $AgenticRoot -BlarRoot $BlarRoot)) {
    $norm = ($cp -replace '/', '\').TrimEnd('\').ToLower()
    if ($excludedNorm -contains $norm) { Write-Skip "refusing to grant on an EXCLUDED path: $cp"; continue }
    Add-Ace $cp $sid '(OI)(CI)RX'
}
Write-Host "  [excluded, never granted] $($excluded -join '; ')" -ForegroundColor DarkGray
Write-Host "  [verify-not-assume] the coder can actually READ this code is PROVEN by verify-coder-containment.ps1 (the leg runs coder-leg-run.ps1)." -ForegroundColor Yellow

Write-Step "PROVISION complete. Next: run verify-coder-containment.ps1 (the live proof — the build-time gate on flipping containment)."
