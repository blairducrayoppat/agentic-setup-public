# battery-bootstrap.ps1 — the scheduled task's entry point (#1181a).
#
# WHY THIS FILE EXISTS.
#
# #1181 is "the nightly battery does not measure main". The BlarAI half is fixed inside
# run-battery-night.ps1: it pins a BlarAI worktree at main and refuses to run when it
# cannot prove what it is about to execute. But that script is ITSELF the thing being
# executed, and Task Scheduler was invoking it as:
#
#     -File C:\Users\mrbla\agentic-setup\scripts\run-battery-night.ps1
#
# — the PRIMARY agentic-setup checkout, which is a shared working tree that sessions park
# on feature branches. On 2026-07-30 it sat on `fix/1171-declared-surface`, whose copy of
# the driver differed from main by -95/+18 lines: a night would have run a driver missing
# the very instrumentation merged that morning. A script cannot pin itself after it has
# already been read, so the fix needs one level of indirection. This is that level.
#
# The task now points at this file INSIDE the pinned worktree. This script:
#   1. proves the primary checkout is really the primary (state and git history live there),
#   2. creates-on-absence / advances the pinned worktree to main, non-destructively,
#   3. proves the pinned commit is contained in main,
#   4. hands the STATE root to the driver through an environment variable, and
#   5. invokes the pinned tree's run-battery-night.ps1.
#
# SELF-UPDATE IS SAFE, AND VISIBLE. This file lives in the tree it advances, so step 2 can
# rewrite it on disk mid-run. PowerShell parses a script fully before executing it, so the
# running instance is unaffected; the advanced copy takes effect next night. That is a real
# one-night lag on changes to THIS file, so the lag is not left implicit: when the executing
# bytes differ from the advanced tree's copy, the log says so by hash. Every other file —
# including the driver, which is read fresh at step 5 — is main's as of tonight.
#
# FAIL-CLOSED, LIKE EVERYTHING ELSE ON THIS PATH. Any failure stands the night down and
# writes a plain-language morning report. It NEVER falls back to the primary checkout's
# driver: that fallback is precisely the defect this replaces, and it would report a normal
# night while doing it. Nothing here deletes or discards anything, ever.

[CmdletBinding()]
param(
    [string]$CampaignConfig,
    [switch]$Now,

    # TEST SEAM (verify-battery-driver-pinning.ps1). The scheduled task passes neither, and
    # the defaults below are the real roots. They exist so the verifier can drive THIS file
    # end-to-end against throwaway git repositories instead of re-implementing its logic --
    # a re-implementation would keep passing while this script rotted. Not a bypass: every
    # proof below (primary-vs-worktree, same-repository, clean, contained-in-main) is
    # re-derived from whatever roots it is given, so a wrong value fails these checks rather
    # than skipping them.
    [string]$AgenticPrimary  = "C:\Users\mrbla\agentic-setup",
    [string]$AgenticMeasured = "C:\Users\mrbla\agentic-battery-measured"
)

$ErrorActionPreference = "Stop"

$DriverRelPath = "scripts\run-battery-night.ps1"

$Stamp   = Get-Date -Format "yyyyMMdd-HHmmss"
$LogDir  = Join-Path $AgenticPrimary "state\battery"
$LogPath = Join-Path $LogDir "bootstrap-$Stamp.log"
# The instant this run began, in the same clock the report file's timestamp uses. The trap
# below asks "has tonight's morning report been written YET?" and this is what "tonight"
# means -- the question cannot be answered against a stamp string, because the driver mints
# its own and the report carries no machine-readable one.
$StartedUtc = (Get-Date).ToUniversalTime()
New-Item -ItemType Directory -Force $LogDir | Out-Null

function Write-Log([string]$msg) {
    $line = "[{0}] {1}" -f (Get-Date -Format "HH:mm:ss"), $msg
    Write-Output $line
    # Fail-soft on the FILE only. The console/transcript copy above is what the trap below
    # and the stand-down report depend on; a log directory that cannot be written must not
    # be able to take down the very handler that explains why the night did not run.
    try { Add-Content -LiteralPath $LogPath -Value $line -Encoding utf8 } catch { }
}

function Write-StandDown([string]$reason) {
    # The operator is non-technical and reads MORNING-REPORT.md. Say what did not happen,
    # why, and that nothing was damaged — the same contract as the driver's Write-SkipReport.
    Write-Log "STAND DOWN: $reason"
    $body = @(
        "# Battery — night stood down before it started ($Stamp)",
        "",
        "The battery did not run tonight. It stopped **before** starting rather than",
        "measuring something it could not identify.",
        "",
        "**Why:** $reason",
        "",
        "**Nothing was changed, deleted, or lost.** No jobs ran, so no results are missing",
        "from the campaign — the count is simply unchanged. The next scheduled night runs",
        "normally once the cause above is resolved.",
        "",
        "Bootstrap log: $LogPath"
    ) -join "`n"
    try { Set-Content -LiteralPath (Join-Path $LogDir "MORNING-REPORT.md") -Value $body -Encoding utf8 }
    catch { Write-Log "could not write the morning report: $($_.Exception.Message)" }
}

function Invoke-GitRead {
    # Native exit codes are the signal, so scope off the host preference that would turn a
    # non-zero exit into a throw (#903 pattern) and hand the caller both streams.
    param([Parameter(Mandatory)][string[]]$GitArgs)
    $prev = $PSNativeCommandUseErrorActionPreference
    try {
        $PSNativeCommandUseErrorActionPreference = $false
        $out = (& git @GitArgs 2>&1 | Out-String).Trim()
        return [pscustomobject]@{ Ok = ($LASTEXITCODE -eq 0); Out = $out; Code = $LASTEXITCODE }
    } catch {
        # `& git` with git absent from PATH raises CommandNotFoundException, which is
        # TERMINATING regardless of the preference above -- that switch neutralises native
        # EXIT CODES, not "no such command". Escaping here would skip Write-StandDown and
        # leave the morning report holding the PREVIOUS night's result: a night that never
        # ran, reported as one that did. It is a failed read; return it as one.
        return [pscustomobject]@{ Ok = $false; Out = "git could not be run: $($_.Exception.Message)"; Code = -1 }
    } finally { $PSNativeCommandUseErrorActionPreference = $prev }
}

function Test-ReportWrittenTonight {
    # Has SOMETHING already told the operator about tonight? The only honest way to ask is
    # to look at the artifact he actually reads and see whether it has been rewritten since
    # this run began. Fail-soft, and fail-CLOSED: if the question cannot be answered, the
    # answer is "no", so the trap writes a report rather than assuming one exists.
    try {
        $p = Join-Path $LogDir 'MORNING-REPORT.md'
        if (-not (Test-Path -LiteralPath $p -PathType Leaf)) { return $false }
        return ((Get-Item -LiteralPath $p).LastWriteTimeUtc -ge $StartedUtc)
    } catch { return $false }
}

# THE BACKSTOP. $ErrorActionPreference is Stop, so any terminating error anywhere below --
# a permission error mid-stat, a hash of a file that vanished, a cmdlet that changes its
# mind about a parameter -- ends the script. Ending it silently is the failure this file
# exists to prevent one level down: no stand-down report is written, so the operator's
# morning read still shows last night. Every exit from here on says what happened.
#
# $HandedOff CANNOT be the thing that decides whether a report gets written, because it is
# set by this script's optimism about invoking the driver, not by the driver reaching its
# own code. A driver that fails at LOAD -- a syntax error merged to main, a file removed
# between the Test-Path and the invoke -- never runs a line, writes nothing, and would have
# taken the "the driver owns the report" branch: stale report, exactly the hole this trap
# exists to close. So the decision is made on the OBSERVABLE instead. Has a report actually
# been written for tonight? Yes -> the account that exists is better than one about its
# launcher, defer. No -> write one, whatever stage we died at.
#
# Rejected: having the driver signal that it started. That defers to a report on the
# strength of the driver's first line executing -- and a driver that starts and then dies
# before writing anything leaves the same stale report, with the signal saying to trust it.
# The report's existence is the property that matters; the driver's liveness is a proxy for
# it that is wrong in exactly the case being fixed.
#
# $HandedOff survives for the two things it IS honest about: the wording, and the exit code.
$script:HandedOff = $false
trap {
    $already = Test-ReportWrittenTonight
    if ($script:HandedOff) {
        if ($already) {
            Write-Log "the pinned driver ended with a terminating error: $($_.Exception.Message). It had already written tonight's morning report; that account stands."
        } else {
            Write-StandDown "the battery launcher was started but stopped with an error before it could report anything: $($_.Exception.Message). No jobs ran."
        }
        # A launched-then-died driver is a real failure, not a refusal - it exits non-zero
        # either way, so Task Scheduler's own history shows it too.
        exit 1
    }
    if (-not $already) {
        Write-StandDown "an unexpected error stopped the bootstrap before the battery started: $($_.Exception.Message)"
    }
    exit 0
}

Write-Log "bootstrap starting (stamp $Stamp); executing from $PSCommandPath"

# ---- 1. the primary checkout ------------------------------------------------------
# In the primary checkout .git is a DIRECTORY; in a linked worktree it is a FILE holding a
# gitdir: pointer. That one stat is the cheapest honest proof, and it structurally catches
# the mix-up that would put campaign history in a tree that is re-detached every night.
if (-not (Test-Path -LiteralPath $AgenticPrimary -PathType Container)) {
    Write-StandDown "the agentic-setup checkout is missing at $AgenticPrimary."
    exit 0
}
if (-not (Test-Path -LiteralPath (Join-Path $AgenticPrimary '.git') -PathType Container)) {
    Write-StandDown "$AgenticPrimary is not the primary agentic-setup checkout (its .git is not a directory). The campaign's state and history live in the primary checkout and must be read from there."
    exit 0
}

$mainRef = Invoke-GitRead @('-C', $AgenticPrimary, 'rev-parse', 'main')
if (-not $mainRef.Ok) {
    Write-StandDown "could not read main's commit from $AgenticPrimary : $($mainRef.Out)"
    exit 0
}
$mainSha = $mainRef.Out
Write-Log "agentic-setup main is $mainSha."

# ---- 2. create-on-absence, then advance -------------------------------------------
# `git worktree add --detach` is PURELY ADDITIVE: a new directory plus an admin entry. It
# cannot modify or destroy another session's work, and detached means it claims no branch
# name anyone else might want (it must be detached anyway — git refuses to check out `main`
# in a second worktree, and the primary already holds it).
$created = $false
if (-not (Test-Path -LiteralPath $AgenticMeasured -PathType Container)) {
    Write-Log "measured driver tree absent - creating $AgenticMeasured detached at main $mainSha."
    $add = Invoke-GitRead @('-C', $AgenticPrimary, 'worktree', 'add', '--detach', $AgenticMeasured, $mainSha)
    if (-not $add.Ok) {
        Write-StandDown "could not create the pinned driver worktree at $AgenticMeasured : $($add.Out)"
        exit 0
    }
    $created = $true
}

if (-not (Test-Path -LiteralPath (Join-Path $AgenticMeasured '.git') -PathType Leaf)) {
    Write-StandDown "$AgenticMeasured is not a linked git worktree (its .git is not a gitdir pointer file). Refusing rather than running an unpinned driver."
    exit 0
}

$commonA = Invoke-GitRead @('-C', $AgenticPrimary,  'rev-parse', '--path-format=absolute', '--git-common-dir')
$commonB = Invoke-GitRead @('-C', $AgenticMeasured, 'rev-parse', '--path-format=absolute', '--git-common-dir')
if (-not $commonA.Ok -or -not $commonB.Ok) {
    Write-StandDown "could not compare the two agentic-setup checkouts' git directories."
    exit 0
}
if ($commonA.Out -ne $commonB.Out) {
    Write-StandDown "$AgenticMeasured belongs to a different repository than $AgenticPrimary ($($commonB.Out) vs $($commonA.Out))."
    exit 0
}

# Cleanliness BEFORE the advance, so the advance only ever runs on a verified-clean tree.
# A dirty measured tree is REFUSED and left untouched: nobody should have work there, so if
# someone does it is either a bug worth seeing or a deliberate experiment, and discarding
# either is forbidden.
$dirty = Invoke-GitRead @('-C', $AgenticMeasured, 'status', '--porcelain')
if (-not $dirty.Ok) {
    Write-StandDown "could not read the pinned driver tree's status: $($dirty.Out)"
    exit 0
}
if ($dirty.Out) {
    $paths = ($dirty.Out -split "`n" | Select-Object -First 10) -join '; '
    Write-StandDown "the pinned driver tree $AgenticMeasured is DIRTY and was left untouched (nothing is ever discarded there). Uncommitted paths: $paths"
    exit 0
}

# Hash the executing bytes BEFORE the advance can overwrite them — this is the only moment
# the pre-advance copy is still on disk.
$selfHashBefore = $null
try { $selfHashBefore = (Get-FileHash -LiteralPath $PSCommandPath -Algorithm SHA256).Hash } catch { }

$headRef = Invoke-GitRead @('-C', $AgenticMeasured, 'rev-parse', 'HEAD')
if (-not $headRef.Ok) {
    Write-StandDown "could not read the pinned driver tree's HEAD: $($headRef.Out)"
    exit 0
}
if ($headRef.Out -ne $mainSha) {
    Write-Log "advancing the pinned driver tree $($headRef.Out.Substring(0,8)) -> main $($mainSha.Substring(0,8))."
    # `git switch --detach` refuses on its own if it would overwrite local modifications, so
    # git fails closed here too.
    $sw = Invoke-GitRead @('-C', $AgenticMeasured, 'switch', '--detach', $mainSha)
    if (-not $sw.Ok) {
        Write-StandDown "could not advance the pinned driver tree to main $mainSha : $($sw.Out)"
        exit 0
    }
}

# ---- 3. re-verify after the advance ------------------------------------------------
# The advance is the step most likely to half-succeed, and a half-advanced tree is the
# confound wearing a clean name.
$headRef = Invoke-GitRead @('-C', $AgenticMeasured, 'rev-parse', 'HEAD')
if (-not $headRef.Ok -or $headRef.Out -ne $mainSha) {
    Write-StandDown "the pinned driver tree is at $($headRef.Out) after the advance, not main $mainSha."
    exit 0
}
$dirty = Invoke-GitRead @('-C', $AgenticMeasured, 'status', '--porcelain')
if (-not $dirty.Ok -or $dirty.Out) {
    Write-StandDown "the pinned driver tree is dirty immediately after advancing to main - refusing rather than running it."
    exit 0
}
# Belt: the commit must actually BE on main. `switch --detach <sha>` cannot land anywhere
# else, but this whole ticket is about a version stamp nobody could find on main, so the
# claim gets checked rather than assumed.
$anc = Invoke-GitRead @('-C', $AgenticMeasured, 'merge-base', '--is-ancestor', $mainSha, 'main')
if (-not $anc.Ok) {
    Write-StandDown "the pinned driver commit $mainSha is not contained in main."
    exit 0
}

Write-Log "pinned driver tree: $AgenticMeasured @ main $mainSha$(if ($created) { ' (created tonight)' })."

# The one-night lag on THIS file, made visible rather than left implicit.
try {
    $selfHashAfter = (Get-FileHash -LiteralPath (Join-Path $AgenticMeasured 'scripts\battery-bootstrap.ps1') -Algorithm SHA256).Hash
    if ($selfHashBefore -and $selfHashAfter -and $selfHashBefore -ne $selfHashAfter) {
        Write-Log "NOTE: this bootstrap changed on main. Tonight ran the previous copy ($($selfHashBefore.Substring(0,12))); the advanced copy ($($selfHashAfter.Substring(0,12))) takes effect next night. The DRIVER below is tonight's main either way."
    }
} catch { Write-Log "could not compare the bootstrap's own hash (non-fatal): $($_.Exception.Message)" }

# ---- 4. the driver -----------------------------------------------------------------
$driver = Join-Path $AgenticMeasured $DriverRelPath
if (-not (Test-Path -LiteralPath $driver -PathType Leaf)) {
    Write-StandDown "the pinned driver tree has no $DriverRelPath, so main does not carry the battery driver at $mainSha."
    exit 0
}

# Campaign state, the per-night directories and the morning report stay in the PRIMARY
# checkout. Without this the driver would resolve them under the pinned worktree, whose
# state\ is empty — a brand-new campaign at pass 0, every night, reported as normal.
$env:BLARAI_BATTERY_AGENTIC_STATE_ROOT = $AgenticPrimary

# A HASHTABLE splat, not an array. Array splatting passes its elements POSITIONALLY, so
# @('-CampaignConfig', $path) handed the driver two positional arguments and died with
# "A positional parameter cannot be found that accepts argument '<path>'" -- $Now takes no
# position, so the path had nowhere to bind and every side-config run stood down before
# reaching the driver. Caught by the pre-repoint dry run (#1181a step 6), NOT by a night:
# the verifier's Invoke-Bootstrap never passed a campaign config, so no test walked this
# line. Hashtable splatting binds by NAME and is the only correct form here.
$driverArgs = @{}
if ($CampaignConfig) { $driverArgs['CampaignConfig'] = $CampaignConfig }
if ($Now)            { $driverArgs['Now'] = $true }

$argEcho = ($driverArgs.GetEnumerator() | Sort-Object Name | ForEach-Object { "-$($_.Key) $($_.Value)" }) -join ' '
Write-Log "handing off to the pinned driver: $driver $argEcho"
$script:HandedOff = $true
& $driver @driverArgs
$driverExit = $LASTEXITCODE
Write-Log "pinned driver exited $driverExit."
exit $driverExit
