<#
.SYNOPSIS
  Locks shut the interval-vs-instant guard class (#1334).

.DESCRIPTION
  THE DEFECT THIS LOCKS SHUT
  ==========================
  A scheduled battery night decides whether it may take the box. Three predicates have
  been used to answer that, and all three answered an INSTANT question when the real one
  is an INTERVAL:

    1. Guard A watched :8000. That is the OVMS port, and the swap driver restores the 14B
       between jobs, so :8000 is NECESSARILY down between waves. It logged
       "guard clear - no dispatch in flight" at 2026-08-07 23:00:07 while a dispatch that
       had been building for three hours was mid-flight.
    2. Guard B (b7af0a0) counted TASK-START vs TASK-END in fleet-run journals. Between two
       waves those balance, correctly, while the run still owns its sandbox.
    3. "Just go run-level" -- the obvious third try -- is ALSO wrong. RUN-START/RUN-END are
       emitted PER WAVE. The run destroyed on 2026-08-07 reads RUN-START=6, RUN-END=6.
       A run-level journal predicate would have admitted the collision identically.

  The consequence, measured: the nightly reclaimed a live run's AO (pid 28152, 23:00:11),
  archived its sandbox (23:01:15), and then STALLED itself at 256 s when its own
  replacement AO was torn down by the cleanup of the run it had orphaned. Two runs
  destroyed by one gap.

  WHY THE PROCESS IS THE RIGHT WITNESS
  ===================================
  A dispatch is live iff the process driving it exists. A process is an interval by
  construction: it spans the whole run including the between-wave gaps that defeat every
  file-based marker. It also covers OPERATOR-initiated dispatches, which claim no AO by
  design and were invisible to every prior check.

  WHY THIS FILE EXISTS AT ALL
  ===========================
  b7af0a0 shipped 60 lines of guard with NO test -- `git show --stat` is one file, and no
  verifier anywhere referenced it. The control had no control, so nobody could have found
  the task-vs-run defect by running anything. Security principle 12: a lock ships with a
  test proving it BLOCKS when engaged AND a toggle-test proving the probe FAILS when the
  lock is off. Every behavioural section below carries its toggle.

  HOW IT TESTS
  ============
  REAL processes against the REAL process table -- no stubbed Get-CimInstance. Decoys are
  spawned with genuinely matching command lines using the Start-LauncherDecoy trick
  (trailing script args land in the CommandLine without the interpreter consuming them),
  and Get-LiveDispatch is extracted from run-battery-night.ps1 BY AST so this exercises
  the shipped text rather than a paraphrase of it.

  TWO MODES, AND NEITHER PRETENDS TO BE THE OTHER
  ===============================================
  The negative cases ("nothing is running -> proceed") can only be evaluated on an idle
  box: with a real dispatch in flight the detector correctly finds it, and those checks
  would have to be waved through. Waving them through and still printing a green total is
  precisely the instrument-honesty defect this repo is tracking (#1241) -- a partial
  result presented as a whole one.

  So: the default mode REFUSES to run when a dispatch is live (exit 2, nothing asserted).
  -LiveProof is the deliberate opposite: it REQUIRES a live dispatch, drives the detector
  against that real run, and states in its result line that the idle-box cases were not
  evaluated. A -LiveProof pass is not a substitute for a default pass.

  Run it normally ( .\verify-battery-live-dispatch-guard.ps1 ) - do NOT dot-source it.
  Exit 0 iff every check that RAN passed, and the result line says which set that was.
#>
param(
    # Require a live dispatch and prove the detector sees it. Skips the idle-box cases and
    # says so. Used to prove the guard against a genuine in-flight run.
    [switch]$LiveProof
)
$ErrorActionPreference = 'Stop'

$script:Pass = 0
$script:Fail = 0
$script:Skipped = 0
function Check([string]$name, [bool]$ok) {
    if ($ok) { $script:Pass++; Write-Host "  [PASS] $name" -ForegroundColor Green }
    else     { $script:Fail++; Write-Host "  [FAIL] $name" -ForegroundColor Red }
}
function Section($t) { Write-Host ''; Write-Host "== $t ==" -ForegroundColor Cyan }

$launcher = Join-Path $PSScriptRoot 'run-battery-night.ps1'
$ownerLib = Join-Path $PSScriptRoot 'ao-ownership-lib.ps1'
$stopAsst = Join-Path $PSScriptRoot 'stop-assistant.ps1'

# ---------------------------------------------------------------------------
Section 'S0  the files parse, and the real function can be extracted'
# PARSE FIRST. ParseFile is error-TOLERANT: every structural check below would pass green
# on a launcher PowerShell refuses to run. Assert runnability before asserting shape.
foreach ($f in @(@{n='run-battery-night.ps1'; p=$launcher}, @{n='ao-ownership-lib.ps1'; p=$ownerLib})) {
    $perrs = $null
    [void][System.Management.Automation.Language.Parser]::ParseFile($f.p, [ref]$null, [ref]$perrs)
    Check "S0 $($f.n) parses with 0 errors (got $(@($perrs).Count))" (@($perrs).Count -eq 0)
}

$ast = [System.Management.Automation.Language.Parser]::ParseFile($launcher, [ref]$null, [ref]$null)
$FuncAst    = [System.Management.Automation.Language.FunctionDefinitionAst]
$CommandAst = [System.Management.Automation.Language.CommandAst]
function Get-FunctionText([string]$name) {
    $f = @($ast.FindAll({ param($n) $n -is $FuncAst -and $n.Name -eq $name }, $true))
    if ($f.Count -ne 1) { return $null }
    return @($f)[0].Extent.Text
}
$fnLive = Get-FunctionText 'Get-LiveDispatch'
Check "S0 Get-LiveDispatch extracted from the shipped launcher" ([bool]$fnLive)
if (-not $fnLive) { Write-Host 'cannot continue without the function'; exit 1 }

# ---------------------------------------------------------------------------
# Fixtures: real, short-lived decoy processes whose CommandLine genuinely matches.
$py = @(
    'C:\Users\mrbla\BlarAI\.venv\Scripts\python.exe',
    'C:\Users\mrbla\blarai\.venv\Scripts\python.exe',
    (Get-Command python -ErrorAction SilentlyContinue).Source
) | Where-Object { $_ -and (Test-Path $_) } | Select-Object -First 1
if (-not $py) { throw 'no python.exe found for the behaviour suite' }
$pwshExe = (Get-Process -Id $PID).Path

$work = Join-Path ([IO.Path]::GetTempPath()) ('live-dispatch-verify-' + [guid]::NewGuid().ToString('N').Substring(0,8))
New-Item -ItemType Directory -Force -Path $work | Out-Null
$sleeper = Join-Path $work 'fixture.py'
Set-Content -Path $sleeper -Encoding utf8 -Value 'import time; time.sleep(300)'
$spawned = New-Object System.Collections.ArrayList

function Start-Decoy([string[]]$TrailingArgs) {
    # Trailing script args land in the CommandLine WITHOUT python treating them as
    # interpreter options -- so the decoy's command line really does contain the text the
    # detector matches on, and the detector really does read it from the OS.
    $tag = [guid]::NewGuid().ToString('N').Substring(0,6)
    $inEmpty = Join-Path $work "in-$tag"; Set-Content -Path $inEmpty -Value '' -NoNewline -Encoding ascii
    $p = Start-Process -FilePath $py -ArgumentList (@($sleeper) + $TrailingArgs) -WorkingDirectory $work `
            -RedirectStandardInput $inEmpty -RedirectStandardOutput "$inEmpty.out" `
            -RedirectStandardError "$inEmpty.err" -NoNewWindow -PassThru
    $null = $p.Handle
    [void]$spawned.Add($p.Id)
    Start-Sleep -Milliseconds 400
    return $p
}
function Invoke-Detector([string]$AgenticRootValue) {
    # Run the REAL extracted function in a scope carrying only what it closes over.
    #
    # PRODUCTION'S STRICTNESS IS REPRODUCED HERE. A fresh runspace inherits neither
    # `Set-StrictMode -Version Latest` (which ao-ownership-lib.ps1 puts in the launcher's
    # scope) nor `$ErrorActionPreference = 'Stop'`. Without these two lines this verifier
    # would run the one function it exists to lock under WEAKER rules than production —
    # so a StrictMode regression (an unassigned variable read, a .Count on $null) would
    # pass here and throw at 23:00. Caught in review; the harness was the blind spot, not
    # the function.
    $sb = [scriptblock]::Create($fnLive + "`nGet-LiveDispatch")
    $ps = [powershell]::Create()
    $null = $ps.AddScript(
        "param(`$AgenticRoot)`nSet-StrictMode -Version Latest`n`$ErrorActionPreference = 'Stop'`n" + $sb.ToString()
    ).AddArgument($AgenticRootValue)
    $out = $ps.Invoke()
    if ($ps.Streams.Error.Count -gt 0) {
        $ps.Dispose()
        throw "Get-LiveDispatch errored under production strictness: $($ps.Streams.Error[0])"
    }
    $ps.Dispose()
    if ($out.Count -eq 0) { return $null }
    return $out[$out.Count - 1]
}

$emptyRoot = Join-Path $work 'agentic-empty'
New-Item -ItemType Directory -Force -Path $emptyRoot | Out-Null

# ---------------------------------------------------------------------------
# ENVIRONMENT GATE. Decide the mode against reality before asserting anything.
$realLive = Invoke-Detector $emptyRoot
if ($realLive -and -not $LiveProof) {
    Write-Host ''
    Write-Host 'REFUSING TO RUN: a dispatch is LIVE on this box right now.' -ForegroundColor Yellow
    Write-Host "  $($realLive.Detail)$(if ($realLive.RunId) { " (run $($realLive.RunId))" })"
    Write-Host '  The idle-box cases cannot be evaluated while it runs, and passing them'
    Write-Host '  vacuously to reach a green total is the exact defect this guard exists to'
    Write-Host '  stop. Nothing was asserted. Re-run when the box is idle, or use -LiveProof'
    Write-Host '  to deliberately prove the detector against this run.'
    Remove-Item -Recurse -Force $work -ErrorAction SilentlyContinue
    exit 2
}
if ($LiveProof -and -not $realLive) {
    Write-Host ''
    Write-Host 'REFUSING TO RUN: -LiveProof requires a live dispatch and none is running.' -ForegroundColor Yellow
    Write-Host '  A live-proof with nothing live proves nothing. Run without -LiveProof.'
    Remove-Item -Recurse -Force $work -ErrorAction SilentlyContinue
    exit 2
}

try {
    # -----------------------------------------------------------------------
    if ($LiveProof) {
        Section 'S1-LIVE  a REAL in-flight dispatch is detected (the seam, not a fixture)'
        # The strongest form of this check and the only one that cannot be faked: a
        # genuine dispatch, started by the operator, driving real work, seen by the
        # shipped detector through the real process table.
        Check "S1-LIVE a real live dispatch is detected" ($realLive.Why -eq 'driving-process-alive')
        Check "S1-LIVE it names at least one real pid" (@($realLive.Pids).Count -ge 1)
        Write-Host "         detected: $($realLive.Detail)" -ForegroundColor DarkGray
    } else {
        Section 'S1  nothing running -> the detector says nothing is running'
        $r = Invoke-Detector $emptyRoot
        Check "S1 no driving process -> null (the battery is allowed to proceed)" ($null -eq $r)
    }

    # -----------------------------------------------------------------------
    Section 'S2  each real driver shape is detected'
    foreach ($case in @(
        @{ n='swap driver (-m shared.fleet.swap_ops)';        a=@('-m','shared.fleet.swap_ops','--spec','x.json') },
        @{ n='coder leg (-m tools.dispatch_harness.acp_coder)'; a=@('-m','tools.dispatch_harness.acp_coder','--workdir','x') }
    )) {
        $d = Start-Decoy $case.a
        $r = Invoke-Detector $emptyRoot
        Check "S2 $($case.n) -> REFUSE" ($null -ne $r -and $r.Why -eq 'driving-process-alive')
        Check "S2 $($case.n) names the pid" ($null -ne $r -and (@($r.Pids) -contains $d.Id))
        Stop-Process -Id $d.Id -Force -ErrorAction SilentlyContinue
        Start-Sleep -Milliseconds 400
    }

    # run-fleet.ps1 needs a real -File invocation of a file with that name.
    $fakeRunFleet = Join-Path $work 'run-fleet.ps1'
    Set-Content -Path $fakeRunFleet -Encoding ascii -Value 'Start-Sleep -Seconds 300'
    $rf = Start-Process -FilePath $pwshExe -ArgumentList @('-NoProfile','-File',$fakeRunFleet) -NoNewWindow -PassThru
    $null = $rf.Handle; [void]$spawned.Add($rf.Id); Start-Sleep -Milliseconds 700
    $r = Invoke-Detector $emptyRoot
    Check "S2 outer driver (-File ...run-fleet.ps1) -> REFUSE" ($null -ne $r -and $r.Why -eq 'driving-process-alive')
    Stop-Process -Id $rf.Id -Force -ErrorAction SilentlyContinue
    Start-Sleep -Milliseconds 400

    # -----------------------------------------------------------------------
    Section 'S3  the self-match trap: a shell that MENTIONS a driver is not a driver'
    # Without this, anyone who greps for run-fleet.ps1 -- or any diagnostic shell whose
    # -Command text contains it -- pins the guard on forever and the battery never runs
    # again. The detector matches invocation FORMS (-File <path>, -m <module>), not text.
    if ($LiveProof) {
        Write-Host '  [NOT RUN] S3 needs an idle box - a real dispatch is live, so a null result is unobtainable.' -ForegroundColor DarkYellow
        $script:Skipped++
    } else {
        $mention = Start-Process -FilePath $pwshExe -ArgumentList @(
            '-NoProfile','-Command','# mentions run-fleet.ps1 and -m shared.fleet.swap_ops only as text
Start-Sleep -Seconds 300') -NoNewWindow -PassThru
        $null = $mention.Handle; [void]$spawned.Add($mention.Id); Start-Sleep -Milliseconds 700
        $r = Invoke-Detector $emptyRoot
        Check "S3 a -Command shell merely MENTIONING the drivers -> not live" ($null -eq $r)
        Stop-Process -Id $mention.Id -Force -ErrorAction SilentlyContinue
        Start-Sleep -Milliseconds 400
    }

    # -----------------------------------------------------------------------
    Section 'S4  identity is best-effort and NEVER gates the refusal'
    $idRoot = Join-Path $work 'agentic-id'
    New-Item -ItemType Directory -Force -Path (Join-Path $idRoot 'state\fleet-swap') | Out-Null
    Set-Content -Path (Join-Path $idRoot 'state\fleet-swap\spec.json') -Encoding utf8 `
        -Value '{ "run_id": "20260808-104536-bd", "session_id": "abc" }'
    $d = Start-Decoy @('-m','shared.fleet.swap_ops','--spec','x.json')
    $r = Invoke-Detector $idRoot
    Check "S4 run_id is read from spec.json when present" ($null -ne $r -and $r.RunId -eq '20260808-104536-bd')
    # The same live process with NO spec.json must STILL refuse -- an unnamed live
    # dispatch is still a live dispatch. current.json proved why identity cannot gate:
    # it named a run that had ended the previous night while a different run was live.
    $r2 = Invoke-Detector $emptyRoot
    Check "S4 no spec.json -> still REFUSE, just unnamed" ($null -ne $r2 -and $r2.Why -eq 'driving-process-alive' -and $r2.RunId -eq '')
    Stop-Process -Id $d.Id -Force -ErrorAction SilentlyContinue
    Start-Sleep -Milliseconds 400

    # -----------------------------------------------------------------------
    Section 'S5  the library lock BLOCKS a real teardown, and the toggle proves it'
    . $ownerLib
    function New-FixtureRoot {
        $root = Join-Path $work ('root-' + [guid]::NewGuid().ToString('N').Substring(0,6))
        New-Item -ItemType Directory -Force -Path (Join-Path $root 'certs') | Out-Null
        return $root
    }
    function Start-LauncherDecoy { return (Start-Decoy @('-m','launcher')) }
    function Test-Alive([int]$ProcessId) {
        try { $null = Get-Process -Id $ProcessId -ErrorAction Stop; return $true } catch { return $false }
    }
    function Wait-Dead([int]$ProcessId, [int]$TimeoutSec = 10) {
        $deadline = (Get-Date).AddSeconds($TimeoutSec)
        while ((Get-Date) -lt $deadline -and (Test-Alive $ProcessId)) { Start-Sleep -Milliseconds 150 }
        return (-not (Test-Alive $ProcessId))
    }
    $liveDesc = [pscustomobject]@{
        Why = 'driving-process-alive'; Detail = 'pid 1 (test) started now, 1 driving process(es) total'
        Pids = @(1); RunId = '20260808-104536-bd'
    }

    # LOCKED: a real launcher decoy, a real lock file, an unowned sentinel -- exactly the
    # 2026-08-07 23:00:11 shape ("NOTHING owns it") -- and the reclaim must NOT fire.
    $rootL = New-FixtureRoot
    $decL  = Start-LauncherDecoy
    Set-Content -Path (Join-Path $rootL 'certs\launcher.lock') -Value $decL.Id -NoNewline -Encoding ascii
    $sentL = Join-Path $work 'sentinel-locked.json'   # never created: nothing owns this AO
    $rl = Invoke-AoPreflightReclaim -SentinelPath $sentL -CurrentNight '20260808-230000' `
            -AoPresent $true -LiveDispatch $liveDesc -BlarAiRepo $rootL `
            -StopAssistantPath $stopAsst -Log { param($m) }
    Check "S5 LOCKED: the reclaim did NOT fire" (-not [bool]$rl.Reclaimed)
    Check "S5 LOCKED: the reason names the live dispatch (got '$($rl.Reason)')" ($rl.Reason -eq 'live-dispatch')
    Check "S5 LOCKED: the decoy AO is STILL ALIVE -- nothing was torn down" (Test-Alive $decL.Id)
    Stop-Process -Id $decL.Id -Force -ErrorAction SilentlyContinue

    # TOGGLE: identical fixture, lock OFF. If this does NOT reclaim, the LOCKED result
    # above proves nothing -- it would mean the probe never reaches the teardown at all.
    $rootU = New-FixtureRoot
    $decU  = Start-LauncherDecoy
    Set-Content -Path (Join-Path $rootU 'certs\launcher.lock') -Value $decU.Id -NoNewline -Encoding ascii
    $sentU = Join-Path $work 'sentinel-unlocked.json'
    $ru = Invoke-AoPreflightReclaim -SentinelPath $sentU -CurrentNight '20260808-230000' `
            -AoPresent $true -LiveDispatch $null -BlarAiRepo $rootU `
            -StopAssistantPath $stopAsst -Log { param($m) }
    Check "S5 TOGGLE: with no live dispatch the reclaim DOES fire (reason '$($ru.Reason)')" ([bool]$ru.Reclaimed)
    Check "S5 TOGGLE: the decoy AO is DEAD -- the probe can reach the teardown" (Wait-Dead $decU.Id 10)

    # -----------------------------------------------------------------------
    Section 'S6  the lock cannot be forgotten by a future call site'
    $threw = $false
    try {
        $null = Invoke-AoPreflightReclaim -SentinelPath (Join-Path $work 'sentinel-omit.json') `
                    -CurrentNight '20260808-230000' -AoPresent $true -BlarAiRepo (New-FixtureRoot) `
                    -StopAssistantPath $stopAsst -Log { param($m) } -ErrorAction Stop
    } catch { $threw = $true }
    Check "S6 omitting -LiveDispatch is a binding ERROR, not a silent unlocked reclaim" $threw

    # -----------------------------------------------------------------------
    Section 'S7  wiring: the guard is actually REACHED (built-but-called-by-nothing)'
    $src = Get-Content $launcher -Raw
    function Get-Calls([string]$name) {
        return @($ast.FindAll({ param($n) $n -is $CommandAst -and $n.GetCommandName() -eq $name }, $true))
    }
    $liveCalls = Get-Calls 'Get-LiveDispatch'
    Check "S7 Get-LiveDispatch is called at least 3x (dispatch guard, reclaim, archive) -- got $($liveCalls.Count)" `
        ($liveCalls.Count -ge 3)
    Check "S7 Test-DispatchBusy consults it (the :8000-only predicate is retired as sole signal)" `
        ((Get-FunctionText 'Test-DispatchBusy') -match 'Get-LiveDispatch')
    Check "S7 the reclaim call site passes -LiveDispatch" ($src -match '-LiveDispatch\s+\$liveNow')

    # ORDER MATTERS: the process witness must be consulted BEFORE the journal scan, so a
    # run with no journal.log yet (measured 11 minutes wide on a real operator dispatch)
    # is refused rather than skipped by the scan's `continue`.
    #
    # Re-anchored 2026-08-14 (#1380). The journal scan was 45 lines inline and its anchor
    # here was `$liveOwner = $null`, the scan's first statement. It is now the function
    # Get-BlockingRunOwner -- extracted precisely so it could be tested -- so the anchor
    # is its CALL SITE. Anchoring on the definition would silently invert this check, since
    # the function is defined near Get-LiveDispatch, hundreds of lines above both call
    # sites: an ordering assertion must point at the order things RUN in, not the order
    # they are written in. A -1 from IndexOf is failed explicitly rather than compared,
    # because -1 is less than every offset and would make a missing lock look correct.
    $iProc = $src.IndexOf('$liveDispatch = Get-LiveDispatch')
    $iJrnl = $src.IndexOf('$blockingOwner = Get-BlockingRunOwner')
    Check "S7 both archive locks are present at their call sites" (($iProc -ge 0) -and ($iJrnl -ge 0))
    Check "S7 the archive guard checks the process BEFORE the journal scan" `
        ($iProc -gt 0 -and $iJrnl -gt 0 -and $iProc -lt $iJrnl)
    # The refusal must be a CLEAN STAND-DOWN, not a bare throw and not a silent continue.
    # This loop is top-level, so an uncaught throw exits the script and skips the skip
    # report (leaving the operator's morning read showing LAST night's result), the
    # admission record, and the AO teardown. The first cut of this guard threw; the check
    # below asserts all four halves of the correct behaviour, because "it refuses" was too
    # weak a property and passed on the throwing version.
    # EVERY refusal site, not the first one (#1380, found in review 2026-08-14).
    #
    # This used `$src.IndexOf('archive guard: REFUSING')` -- the FIRST occurrence -- and built
    # one window from it. That was correct while LOCK 1 was the only clean stand-down. When
    # #1380 gave LOCK 2 the same treatment there were two, and the second sat OUTSIDE the
    # window entirely (measured: LOCK 1 at 1494, window ending 1526; LOCK 2 at 1583). One
    # assertion also hard-coded 'skipped-live-dispatch', which only LOCK 1 writes.
    #
    # So all four of these checks were measuring LOCK 1 twice over, and REVERTING LOCK 2 TO
    # THE BARE THROW #1380 REMOVED WOULD HAVE LEFT EVERY SUITE GREEN -- the precise
    # regression the ticket exists to prevent, unprotected by the suite written to protect
    # it. A window anchored on the first match is a census of one.
    $refusals = @()
    $iScan = $src.IndexOf('archive guard: REFUSING')
    while ($iScan -ge 0) {
        $iEnd = $src.IndexOf('Stop-Transcript | Out-Null; exit 0', $iScan)
        $refusals += [pscustomobject]@{
            Start  = $iScan
            End    = $iEnd
            Window = if ($iEnd -gt $iScan) { $src.Substring($iScan, $iEnd - $iScan) } else { '' }
            Line   = ($src.Substring(0, $iScan) -split "`n").Count
        }
        $iScan = $src.IndexOf('archive guard: REFUSING', $iScan + 1)
    }
    Check "S7 BOTH archive locks have a refusal site (got $($refusals.Count); a census of one is how LOCK 2 went unguarded)" `
        ($refusals.Count -ge 2)
    foreach ($rf in $refusals) {
        Check "S7 refusal at line $($rf.Line) writes a SKIP REPORT (no stale morning read)" `
            ($rf.Window -match 'Write-SkipReport')
        # Matched by SHAPE, not by a hard-coded outcome string: each lock writes its own
        # value ('skipped-live-dispatch' / 'skipped-blocking-run-owner') and a future third
        # lock will write a third. What must hold is that it records SOMETHING skipped.
        Check "S7 refusal at line $($rf.Line) records admission provenance (a skipped-* outcome)" `
            ($rf.Window -match "Write-AdmissionRecord\s+'skipped-[a-z-]+'")
        Check "S7 refusal at line $($rf.Line) TEARS DOWN an AO this night owns (no resident 14B)" `
            ($rf.Window -match 'Stop-OwnedAo')
        Check "S7 refusal at line $($rf.Line) exits cleanly rather than throwing past the teardown" `
            ($rf.End -gt $rf.Start)
    }
    # And the negative: no archive-guard refusal may reach a bare `throw` before its exit.
    # This is the mutation the old window could not see.
    foreach ($rf in $refusals) {
        Check "S7 refusal at line $($rf.Line) contains no bare throw before the clean exit" `
            ($rf.Window -notmatch '(?m)^\s*throw\s')
    }

    # THE SELF-MATCH ORDERING, ENCODED. `-m tools.dispatch_harness.` matches the battery's
    # OWN children: the admission probe (`-m tools.dispatch_harness.probe`) and the runner
    # (`-m tools.dispatch_harness.battery`). Today the night does not refuse itself only
    # because of STATEMENT ORDER — the probe is synchronous and finished, and the archive
    # loop runs BEFORE the runner is launched. Nothing encoded that, so a future reorder
    # would make the battery stand down against itself, every night, silently.
    # This is the requirement, written down.
    # Anchored on the LAUNCH LINE, not on the module name: `tools.dispatch_harness.battery`
    # appears in a header comment at the top of the file, so matching the module name found
    # line 18 and reported a false failure. A check anchored on prose measures prose.
    $iArchiveGuard = $src.IndexOf('$liveDispatch = Get-LiveDispatch')
    $iRunnerLaunch = $src.IndexOf('launching the battery runner')
    Check "S7 the archive guard runs BEFORE the runner launch (or the night refuses itself)" `
        ($iArchiveGuard -gt 0 -and $iRunnerLaunch -gt 0 -and $iArchiveGuard -lt $iRunnerLaunch)
    Check "S7 the guarded code CITES this verifier (a control nothing points at gets deleted)" `
        ($src -match 'verify-battery-live-dispatch-guard\.ps1')

    # -----------------------------------------------------------------------
    Section 'S8  documentation lint — NOT a regression lock, and labelled as such'
    # HONEST LABELLING, applied to this file. These two check COMMENT PROSE. They are green
    # on a launcher whose logic was gutted but whose comments survived, and red on a
    # harmless reword — the exact "asserts less than it names" defect this suite exists to
    # find, sitting inside the suite. They are kept because the reasoning genuinely is
    # worth pinning (a future session reaching for a journal-count predicate should trip
    # something), but they are named a LINT, not a lock, and they are NOT counted among the
    # behavioural checks a merge decision should rest on.
    # The behavioural coverage of the same property lives in S2/S4/S5 and, for the
    # blind-spot branch, S9.
    Check "S8 [lint] the launcher still records WHY journal markers cannot answer this" `
        ($src -match 'emitted PER WAVE' -and $src -match 'RUN-END=6')
    Check "S8 [lint] the launcher still records the fail-closed rule for an unreadable process table" `
        ($src -match 'process-table-unreadable')

    # -----------------------------------------------------------------------
    Section 'S9  the blind spot: "I saw nothing" is not evidence unless it could SEE'
    # A NON-ELEVATED process cannot read an ELEVATED process's CommandLine - WMI returns
    # null. The matcher requires a non-null CommandLine, so without this guard a
    # non-elevated run would silently skip every elevated driver and report an idle box
    # while a dispatch was mid-build: fail-OPEN, in the one direction that destroys work.
    # It is reachable because the elevation check at the top of the launcher WARNS AND
    # PROCEEDS by design (#756).
    Check "S9 a negative answer is gated on the blind-spot check, not returned bare" `
        ($src -match 'command-lines-unreadable')
    Check "S9 the blind-spot probe looks for DRIVER-CAPABLE images specifically" `
        ($src -match "python\|pythonw\|pwsh\|powershell\|node\|opencode")
    # ORDER: the bare `return $null` must come AFTER the blind check, or the guard answers
    # "idle" before asking whether it could see.
    $iBlind = $src.IndexOf('command-lines-unreadable')
    $iNull  = $src.IndexOf('        return $null', $iBlind)
    Check "S9 the blind check precedes the negative return" ($iBlind -gt 0 -and $iNull -gt $iBlind)
    Check "S9 elevation is computed IN the function (survives AST extraction under StrictMode)" `
        ((Get-FunctionText 'Get-LiveDispatch') -match 'WindowsPrincipal')

    # NOT MEASURED, and named rather than left implicit: the BEHAVIOURAL case - an actual
    # driver-capable process whose CommandLine this shell cannot read - is not reproducible
    # from an elevated shell, which is what the battery and this verifier both run as. A
    # process cannot drop its own elevation, so constructing the fixture would need a
    # separate non-elevated logon. The checks above are structural: they prove the branch
    # exists, is ordered correctly, and is self-contained. They do NOT prove it fires.
    Write-Host '  [NOT RUN] S9 behavioural case needs a non-elevated logon - structural checks only.' -ForegroundColor DarkYellow
    $script:Skipped++
}
finally {
    foreach ($id in $spawned) { Stop-Process -Id $id -Force -ErrorAction SilentlyContinue }
    Remove-Item -Recurse -Force $work -ErrorAction SilentlyContinue
}

Write-Host ''
Write-Host "== Result ==" -ForegroundColor Cyan
Write-Host "  Passed: $script:Pass"
if ($script:Skipped -gt 0) { Write-Host "  Not run: $script:Skipped (named above, with the reason)" -ForegroundColor DarkYellow }
if ($script:Fail -gt 0) {
    Write-Host "  FAILED: $script:Fail" -ForegroundColor Red
    exit 1
}
# SAY WHICH SET PASSED. A -LiveProof run has not evaluated the idle-box cases, and a
# result line that did not say so would be the same partial-presented-as-whole defect the
# guard itself exists to stop.
if ($LiveProof) {
    Write-Host "  LIVE-PROOF PASS: the shipped detector saw a REAL in-flight dispatch, and the locks held against it." -ForegroundColor Green
    Write-Host "  NOT EVALUATED: the idle-box cases (S1, S3). This is not a substitute for a default-mode pass." -ForegroundColor DarkYellow
} else {
    Write-Host "  THE INTERVAL-VS-INSTANT GUARD IS LOCKED: a live dispatch blocks the reclaim and the archive, and the toggle proves the probe can see the difference." -ForegroundColor Green
}
exit 0
