<#
  verify-model-server-wedge.ps1  --  the #1495 control, driven.

  WHAT IT PROTECTS. The model server stopped answering completions repeatedly on 2026-09-01/02.
  Each time the ovms process was alive and port 8000 was listening, so both existing liveness
  checks -- start-llm's READY poll (start-llm.ps1:399) and watchdog.ps1 (line 17), which both
  GET /v3/models -- reported it healthy. Measured on the live server:

      GET  /v3/models            direct to 8000  ->  200 in 0.0016s
      POST /v3/chat/completions  direct to 8000  ->  no answer in 70s

  So watchdog.ps1 is not merely INERT (nothing schedules it); arming it would have detected
  none of this. Section P reproduces that difference against a fixture.

  WHAT THIS DELIBERATELY DOES NOT DO: restart anything. A WEDGED server and a merely BUSY one
  are indistinguishable from the client side, and an earlier version of this change tried to
  separate them by sampling OVMS's executor counters across a 90s window. Review defeated it,
  and measuring the banked logs showed there is no threshold to retreat to:

      gap before a tick that CHANGED         p50=2s  p90=100s  p99=157s  max=289s
      longest IDENTICAL-value stretch/log    4s .. 15s across 10 logs
      that stretch during the apparent wedge           8s

  A 90s window often spans no tick at all, so a working server reads as still; and the wedge's
  own identical-value stretch sits inside the healthy range, so the values do not separate the
  states either. Section N asserts the restart machinery is ABSENT rather than disabled.

  Sections
    U  Test-ModelServerLive    -- healthy / wedged / 200-without-content / 500 / dead port,
                                  plus the two headers-then-stall shapes that used to hang forever
    P  probe SHAPE             -- GET succeeds where the completion hangs
    H  Test-ModelServerHealth  -- reports; spares a BUSY server a second probe; never acts
    G  Get-ModelServerProgress -- parsing and the signature's properties
    N  structural absence      -- no restart capability exists to be switched on by accident
    V  endpoint derivation     -- the config is really read (the fallback cannot impersonate it)
    W  wiring                  -- the check is reachable, and runs BEFORE the build
    K  kill/toggle             -- the old probe shape is shown PASSING the wedged fixture

  No section touches the live server, the live 8099, or the real start-llm, and every case
  passes an explicit -LogDir so a live battery run cannot decide whether the suite passes.

  KNOWN LIMIT OF THIS HARNESS. There is no per-case timeout. If Test-ModelServerLive ever loses
  its bounded read again (reverting to Invoke-WebRequest, which stops at the response headers),
  the U10-U15 cases do not go RED -- they HANG, because the fixtures they drive stall forever by
  design. Run interactively that is obvious; wired into anything unattended it is a stall, not a
  failure. Treat a run of this suite that does not finish in about a minute as a failure of that
  shape rather than as a slow machine.
#>
[CmdletBinding()] param()
$ErrorActionPreference = 'Stop'
. "$PSScriptRoot\fleet-lib.ps1"

$script:Pass = 0; $script:Fail = 0
function Section($t) { Write-Host ''; Write-Host "== $t ==" -ForegroundColor Cyan }
function Assert-True($cond, $msg) {
    if ($cond) { $script:Pass++; Write-Host "  [PASS] $msg" -ForegroundColor DarkGray }
    else       { $script:Fail++; Write-Host "  [FAIL] $msg" -ForegroundColor Red }
}
function Assert-False($cond, $msg) { Assert-True (-not $cond) $msg }

$script:Servers = @()
function Start-Fake([string]$Mode) {
    $out = [IO.Path]::GetTempFileName()
    $p = Start-Process -FilePath 'python' -ArgumentList @("$PSScriptRoot\fake-model-server.py", $Mode) `
            -RedirectStandardOutput $out -WindowStyle Hidden -PassThru
    $port = $null
    foreach ($i in 1..100) {
        Start-Sleep -Milliseconds 100
        $t = (Get-Content $out -ErrorAction SilentlyContinue | Select-Object -First 1)
        if ($t -match '^\d+$') { $port = [int]$t; break }
    }
    if (-not $port) { throw "fake server ($Mode) never reported a port" }
    $script:Servers += [pscustomobject]@{ Proc = $p; Out = $out }
    return "http://127.0.0.1:$port"
}
function Stop-Fakes {
    foreach ($s in $script:Servers) {
        try { if (-not $s.Proc.HasExited) { Stop-Process -Id $s.Proc.Id -Force -ErrorAction SilentlyContinue } } catch { }
        try { Remove-Item $s.Out -Force -ErrorAction SilentlyContinue } catch { }
    }
    $script:Servers = @()
}
function New-StateDir {
    $d = Join-Path ([IO.Path]::GetTempPath()) ("wedge-" + [guid]::NewGuid().ToString('N').Substring(0,8))
    New-Item -ItemType Directory -Force $d | Out-Null; $d
}
function New-FakeOvmsLog([string]$dir, [string]$name, [int]$all, [int]$sched, [double]$cache, $stamp = $null) {
    New-Item -ItemType Directory -Force $dir | Out-Null
    # Defaults to NOW. Most cases are about the counters, and a fixture that was silently ancient
    # would fail the recency check for reasons the case is not about; the cases that ARE about
    # age pass an explicit stamp.
    $ts = if ($stamp) { $stamp } else { (Get-Date).ToString('yyyy-MM-dd HH:mm:ss') }
    $line = "[$ts.000][123][llm_executor][info][llm_executor.hpp:105] All requests: $all; Scheduled requests: $sched; Cache type: static, cache usage: $cache% of 4.0 GB;"
    Add-Content (Join-Path $dir $name) $line
}
# Every case passes an explicit -LogDir. Without one Get-ModelServerProgress reads the LIVE
# state/logs, and a battery run in progress would decide whether the suite passes.
$stillLogDir = New-StateDir
New-FakeOvmsLog $stillLogDir 'ovms-coder-30b-20260902-130000.out.log' 1 1 25.2
# A log showing NOTHING in flight, for the cases that must reach the second probe rather
# than short-circuiting to the busy verdict.
$idleLogDir = New-StateDir
New-FakeOvmsLog $idleLogDir 'ovms-coder-30b-20260902-130000.out.log' 0 0 0.0
$quiet = { param($m) }

try {
Section 'U  Test-ModelServerLive: it reports GENERATION, not reachability'

$uHealthy = Start-Fake 'healthy'
$r = Test-ModelServerLive -BaseUrl $uHealthy -Model 'coder-30b' -TimeoutSec 10
Assert-True  $r.Live                     'U1 a server that completes is Live'
Assert-True  ($r.Reason -eq 'generated') 'U2 ... and says why'

$uWedged = Start-Fake 'wedged'
$r = Test-ModelServerLive -BaseUrl $uWedged -Model 'coder-30b' -TimeoutSec 3
Assert-False $r.Live                 'U3 [kill] a server that HANGS the completion is NOT Live'
Assert-True  ($r.ElapsedSec -ge 2.5) 'U4 ... and the timeout was actually waited out'

$uEmpty = Start-Fake 'empty200'
$r = Test-ModelServerLive -BaseUrl $uEmpty -Model 'coder-30b' -TimeoutSec 10
Assert-False $r.Live                                    'U5 [kill] HTTP 200 carrying no completion is NOT Live'
Assert-True  ($r.Reason -match 'no completion content') 'U6 ... and the reason names it'

# An EMPTY completion is no completion. An empty string is not $null, so this answered
# Live=True while the docstring and the case above both said a 200 carrying no completion
# is not live.
$uEmptyStr = Start-Fake 'emptystr'
$r = Test-ModelServerLive -BaseUrl $uEmptyStr -Model 'coder-30b' -TimeoutSec 10
Assert-False $r.Live 'U5b [kill] a 200 whose completion content is the EMPTY STRING is NOT Live'
$uWs = Start-Fake 'whitespace'
$r = Test-ModelServerLive -BaseUrl $uWs -Model 'coder-30b' -TimeoutSec 10
Assert-False $r.Live 'U5c [kill] ... nor is one that is only whitespace'

$u500 = Start-Fake 'error500'
$r = Test-ModelServerLive -BaseUrl $u500 -Model 'coder-30b' -TimeoutSec 10
Assert-False $r.Live 'U7 an HTTP 500 is NOT Live'

$r = Test-ModelServerLive -BaseUrl 'http://127.0.0.1:9' -Model 'coder-30b' -TimeoutSec 5
Assert-False $r.Live                                 'U8 a dead port is NOT Live'
Assert-True  ($r.Reason -and $r.Reason.Length -gt 0) 'U9 every refusal carries a reason (fail-loud, never a bare false)'

# THE TIMEOUT MUST COVER THE BODY, NOT JUST THE HEADERS. Invoke-WebRequest reads with
# HttpCompletionOption.ResponseHeadersRead, so -TimeoutSec bounded the exchange only to the
# response headers and the body read afterwards was unbounded. Review demonstrated both shapes
# below running past 180s against a 12s timeout, and nothing downstream would have rescued it:
# new-agent-task.ps1's Wait-Job carries no -Timeout, so a hung probe hangs the dispatch. These
# cases COMPLETING at all is the assertion -- under the old implementation this never returned.
$uTrunc = Start-Fake 'truncate'
$r = Test-ModelServerLive -BaseUrl $uTrunc -Model 'coder-30b' -TimeoutSec 8
Assert-False $r.Live                                'U10 [kill] a server that sends headers then closes mid-body is NOT Live'
Assert-True  ($r.ElapsedSec -lt 11)                 'U11 [kill] ... and it RETURNS, bounded, instead of hanging forever'
Assert-True  ($r.Reason -match 'truncated|headers') 'U12 ... and the reason names what happened'

$uTrickle = Start-Fake 'trickle'
$r = Test-ModelServerLive -BaseUrl $uTrickle -Model 'coder-30b' -TimeoutSec 8
Assert-False $r.Live                'U13 [kill] a server that trickles the body forever is NOT Live'
Assert-True  ($r.ElapsedSec -lt 14) 'U14 [kill] ... and the timeout CUTS THE BODY READ (the finding-3 hole)'
Assert-True  ($r.ElapsedSec -ge 7)  'U15 ... having actually waited out its timeout, not failed early for another reason'

Section 'P  probe SHAPE: the old GET-based liveness check is BLIND to a wedge'

$sw = [Diagnostics.Stopwatch]::StartNew()
$get = Invoke-WebRequest "$uWedged/v3/models" -TimeoutSec 20 -UseBasicParsing
$sw.Stop()
Assert-True ($get.StatusCode -eq 200)         'P1 the WEDGED server answers GET /v3/models with 200'
Assert-True ($sw.Elapsed.TotalSeconds -lt 15) 'P2 ... promptly'
Assert-True ((($get.Content | ConvertFrom-Json).data[0].id) -eq 'coder-30b') 'P3 ... and lists the model as present'
$live = Test-ModelServerLive -BaseUrl $uWedged -Model 'coder-30b' -TimeoutSec 3
Assert-False $live.Live 'P4 [kill] the SAME server FAILS the completion probe -- the two shapes disagree, which is why the old ones saw none of it'

Section 'H  Test-ModelServerHealth: confirms twice, explains, and never acts'

$h = Test-ModelServerHealth -BaseUrl $uHealthy -Model 'coder-30b' -TimeoutSec 10 `
        -LogDir $idleLogDir -Log $quiet
Assert-True  $h.Live            'H1 a healthy server is Live'
Assert-False $h.Confirmed       'H2 ... and nothing is confirmed, because nothing failed'

# One missed check is never a verdict: the slow fixture hangs only its FIRST completion.
$uSlow = Start-Fake 'slow'
$h = Test-ModelServerHealth -BaseUrl $uSlow -Model 'coder-30b' -TimeoutSec 3 `
        -LogDir $idleLogDir -Log $quiet
Assert-True  $h.Live      'H3 [kill] a server that misses ONE check then answers is reported Live'
Assert-False $h.Confirmed 'H4 ... and is not confirmed unhealthy on a single failure'

$h = Test-ModelServerHealth -BaseUrl $uWedged -Model 'coder-30b' -TimeoutSec 3 `
        -LogDir $idleLogDir -Log $quiet
Assert-False $h.Live                            'H5 a server that fails BOTH checks is not Live'
Assert-True  $h.Confirmed                       'H6 ... and that is marked confirmed'
Assert-True  ($h.Reason -match 'executor')      'H7 [kill] ... and the report carries the executor context a human needs'
Assert-True  ($null -ne $h.Progress)            'H8 ... including the counters themselves'

# An unreadable log must degrade to an honest report, never to a confident one.
$h = Test-ModelServerHealth -BaseUrl $uWedged -Model 'coder-30b' -TimeoutSec 3 `
        -LogDir (Join-Path (New-StateDir) 'nope') -Log $quiet
Assert-False $h.Live                                  'H9 an unreadable executor log still reports not-Live'
Assert-True  ($h.Reason -match 'could not be read')   'H10 [kill] ... and SAYS the log could not be read rather than implying a verdict'

# COST, on the half that ships enabled: this runs before EVERY candidate. A busy server must
# cost ONE timeout, not two plus a sleep -- an earlier shape charged 60+90+60 = 210s per
# candidate, and up to ~1170s, paid most often exactly when the fleet was busiest.
$busyLogDir = New-StateDir
New-FakeOvmsLog $busyLogDir 'ovms-coder-30b-20260902-130000.out.log' 2 1 18.4
$sw2 = [Diagnostics.Stopwatch]::StartNew()
$h = Test-ModelServerHealth -BaseUrl $uWedged -Model 'coder-30b' -TimeoutSec 3 -LogDir $busyLogDir -Log $quiet
$sw2.Stop()
Assert-True  $h.Busy                            'H11 [kill] a server with work already in flight is reported BUSY, not faulty'
Assert-False $h.Confirmed                       'H12 ... and is never confirmed unhealthy on that basis'
Assert-True  ($h.Reason -match 'queued behind') 'H13 ... and says this candidate is queued behind it'
Assert-True  ($sw2.Elapsed.TotalSeconds -lt 6)  'H14 [kill] ... at the cost of ONE probe, not two, and with no sleep'

# THE ONE THAT MATTERED. A stuck request IS one request in flight: the 12:30-12:40 incident's
# last line was 'All requests: 1; Scheduled requests: 1' at 12:40:35, and it would have said that
# forever. With no recency check the health report called that BUSY -- "queued behind them" --
# which tells the operator not to worry about precisely the fault it exists to catch.
$staleBusyDir = New-StateDir
New-FakeOvmsLog $staleBusyDir 'ovms-coder-30b-20260902-123008.out.log' 1 1 25.2 '2026-09-02 12:40:35'
$h = Test-ModelServerHealth -BaseUrl $uWedged -Model 'coder-30b' -TimeoutSec 3 -LogDir $staleBusyDir -Log $quiet
Assert-False $h.Busy                    'H15 [kill] a request in flight per a STALE reading is NOT reported busy (the real wedge log says All requests: 1 forever)'
Assert-True  $h.Confirmed               'H16 [kill] ... it is confirmed not-serving instead'
Assert-True  ($h.Reason -match 'STALE') 'H17 ... and the report says the reading is stale rather than implying live work'

# The control: identical counters, a CURRENT timestamp, and the busy verdict returns -- so H15
# is the recency check and not some unrelated refusal.
$freshBusyDir = New-StateDir
New-FakeOvmsLog $freshBusyDir 'ovms-coder-30b-20260902-123008.out.log' 1 1 25.2
$h = Test-ModelServerHealth -BaseUrl $uWedged -Model 'coder-30b' -TimeoutSec 3 -LogDir $freshBusyDir -Log $quiet
Assert-True  $h.Busy      'H18 [kill] the SAME counters with a CURRENT timestamp DO read as busy - H15 was the age, not the numbers'
Assert-False $h.Confirmed 'H19 ... and a genuinely busy server is never confirmed unhealthy'

$gAge = New-StateDir
New-FakeOvmsLog $gAge 'ovms-coder-30b-20260902-130000.out.log' 1 1 10.0 '2026-09-02 12:40:35'
Assert-True ((Get-ModelServerProgress -LogDir $gAge).AgeSec -gt 300) 'H20 the AGE of the reading is parsed from the tick itself, not from the file mtime'

Section 'G  Get-ModelServerProgress: parsing, and what the signature does and does not mean'

$gd = New-StateDir
New-FakeOvmsLog $gd 'ovms-coder-30b-20260902-130000.out.log' 1 1 10.3
$g1 = Get-ModelServerProgress -LogDir $gd
Assert-True  $g1.Found             'G1 the executor counters are read from the newest ovms log'
Assert-True  ($g1.Requests -eq 1)  'G2 ... All requests parsed'
Assert-True  ($g1.Scheduled -eq 1) 'G3 ... Scheduled requests parsed'
Assert-True  ($g1.Cache -eq 10.3)  'G4 ... cache usage parsed'

New-FakeOvmsLog $gd 'ovms-coder-30b-20260902-130000.out.log' 1 1 10.3
$g2 = Get-ModelServerProgress -LogDir $gd
Assert-True ($g1.Signature -eq $g2.Signature) 'G5 [kill] a repeated identical tick produces an identical signature -- the timestamp is excluded, so a heartbeat cannot masquerade as work'

New-FakeOvmsLog $gd 'ovms-coder-30b-20260902-130000.out.log' 1 1 13.7
$g3 = Get-ModelServerProgress -LogDir $gd
Assert-True ($g3.Signature -ne $g1.Signature) 'G6 a changed cache figure changes the signature'

New-FakeOvmsLog $gd 'ovms-coder-30b-20260902-140000.out.log' 1 1 13.7
$g4 = Get-ModelServerProgress -LogDir $gd
Assert-True ($g4.Signature -ne $g3.Signature) 'G7 a new log file (a restart) reads as a change, not as stillness'

# The REAL idle tick carries no cache field at all. Rendering that absence as -1 put a
# sentinel into the signature where a measurement belongs, and New-FakeOvmsLog always
# emitted a cache figure, so this shape was never in the corpus.
$gNo = New-StateDir
Add-Content (Join-Path $gNo 'ovms-coder-30b-20260902-130000.out.log') ("[{0}.000][123][llm_executor][info][llm_executor.hpp:128] All requests: 0; Scheduled requests: 0;" -f (Get-Date).ToString('yyyy-MM-dd HH:mm:ss'))
$gn = Get-ModelServerProgress -LogDir $gNo
Assert-True  $gn.Found                     'G10 a tick with NO cache field is still parsed'
Assert-True  ($gn.Requests -eq 0)          'G11 ... with its counters read'
Assert-True  ($gn.Signature -match 'none') 'G12 [kill] ... and the ABSENT cache reads as none, not as the sentinel -1'
Assert-False ($gn.Signature -match '\|-1$') 'G13 [kill] ... so an absence is never rendered as a measured value'

$gEmpty = New-StateDir
Assert-False (Get-ModelServerProgress -LogDir $gEmpty).Found                       'G8 an absent log yields Found=false (no evidence either way)'
Assert-False (Get-ModelServerProgress -LogDir (Join-Path $gEmpty 'no')).Found      'G9 a missing directory is handled without throwing'

Section 'N  structural absence: there is no restart to switch on by accident'

# The strongest form of "this must not happen" is code that is not there. An earlier version
# could restart the server behind a default-off flag; the discriminator that would have made
# that safe does not exist in the evidence, so the machinery is removed rather than disabled.
$lib = Get-Content "$PSScriptRoot\fleet-lib.ps1" -Raw
$hStart = $lib.IndexOf('function Get-CoderBaseUrl')
$hEnd   = $lib.IndexOf('function Invoke-CandidateBuild')
Assert-True ($hStart -gt 0 -and $hEnd -gt $hStart) 'N1 the health-check region was located'
$health = $lib.Substring($hStart, $hEnd - $hStart)
# STRIP THE COMMENTS FIRST. These docstrings discuss start-llm and restarting at length -- that
# is the point of them -- so matching raw text would assert on prose rather than on code. This is
# the same confusion that made the first W7 compare documentation order; it is easy to make twice.
$healthCode = ($health -split "`r?`n" | Where-Object { $_ -notmatch '^\s*#' }) -join "`n"
Assert-True  ($healthCode.Length -gt 500)                'N1a the comment-stripped region is still substantial (the strip did not eat the code)'
Assert-True  ($healthCode -match 'Test-ModelServerLive') 'N1b ... and still contains the real function bodies'

# FILE-WIDE, not region-scoped. The region ends at `function Invoke-CandidateBuild`, so the CALL
# SITE -- the most natural place for someone to re-add a restart -- sat OUTSIDE it: review
# injected `& start-llm.ps1 -Force` and `Stop-Process -Name ovms` into the pre-flight block and
# the suite stayed green at 82/0. A containment check whose boundary excludes the likeliest
# offender is the same defect as W2's slice running to end-of-file, from the other direction.
# Verified before widening: this library has ZERO legitimate code references to either, so the
# assertion costs nothing and cannot be satisfied by an unrelated caller.
$libCode = ($lib -split "`r?`n" | Where-Object { $_ -notmatch '^\s*#' }) -join "`n"
Assert-True  ($libCode -match 'Invoke-CandidateBuild')      'N1c the comment-stripped LIBRARY still contains the pipeline (the strip did not eat the code)'
Assert-False ($libCode -match 'start-llm')                  'N2 [kill] nothing anywhere in fleet-lib invokes start-llm -- including the pre-flight call site'
Assert-False ($libCode -match 'Stop-Process')               'N3 [kill] ... and nothing anywhere in it stops a process'
Assert-False ($healthCode -match 'Restore-ModelServer')        'N4 [kill] ... and the restarting function is gone entirely, not merely unused'
Assert-False ($healthCode -match 'AllowRestart|RestartAction') 'N5 [kill] ... with no flag left that could re-enable one'
Assert-False ($lib -match '(?m)^function Restore-ModelServer') 'N6 [kill] no restarting function is defined anywhere in the library'
Assert-False ($healthCode -match '\[System\.Threading\.Mutex\]|New-Object System\.Threading\.Mutex') 'N7 [kill] ... and the cross-process restart lock is gone with it'

Section 'V  the endpoint is really DERIVED (the fallback must not impersonate it)'

# The first version of Get-CoderBaseUrl never read the config at all: opencode.json carries
# case-variant keys ('**/secrets/**' and '**/SECRETS/**'), pwsh 7's ConvertFrom-Json refuses the
# document over that without -AsHashtable, and every call fell into the fallback. Two tests
# passed anyway, because the derived value and the fallback are the SAME STRING on this box.
# These fixtures use URLs that DIFFER, so a function that has stopped deriving cannot agree.
function New-CfgFixture([string]$baseUrl, [bool]$caseVariantKeys) {
    $root = New-StateDir
    New-Item -ItemType Directory -Force (Join-Path $root 'configs') | Out-Null
    New-Item -ItemType Directory -Force (Join-Path $root 'scripts') | Out-Null
    $perm = if ($caseVariantKeys) { '"**/secrets/**": "deny", "**/SECRETS/**": "deny",' } else { '' }
    $json = '{ "permission": { ' + $perm + ' "x": "allow" }, "provider": { "local": { "options": { "baseURL": "' + $baseUrl + '" } } } }'
    Set-Content (Join-Path $root 'configs\opencode.json') $json -Encoding utf8
    return (Join-Path $root 'scripts')
}
$srA = New-CfgFixture 'http://127.0.0.1:9911/v7' $false
Assert-True ((Get-CoderBaseUrl -Model 'local/coder-30b' -ScriptRoot $srA -Log $quiet) -eq 'http://127.0.0.1:9911/v7') 'V1 [kill] a config naming a DIFFERENT host/port/version is actually read'

$srB = New-CfgFixture 'http://127.0.0.1:9922/v7' $true
Assert-True ((Get-CoderBaseUrl -Model 'local/coder-30b' -ScriptRoot $srB -Log $quiet) -eq 'http://127.0.0.1:9922/v7') 'V2 [kill] case-VARIANT permission keys no longer defeat the parse (the defect that hid for a day)'
Assert-True ((Get-CoderBaseUrl -Model 'local/coder-30b' -ScriptRoot $srA -Log $quiet) -match '/v7$') 'V3 [kill] the configured API version survives -- a config saying /v7 is never probed at /v3'

$srMissing = Join-Path (New-StateDir) 'scripts'
$script:spoke = $false
$null = Get-CoderBaseUrl -Model 'local/coder-30b' -ScriptRoot $srMissing -Log { param($m) $script:spoke = $true }
Assert-True ((Get-CoderBaseUrl -Model 'local/coder-30b' -ScriptRoot $srMissing -Log $quiet) -eq 'http://127.0.0.1:8099/v3') 'V4 an absent config falls back to the documented default'
Assert-True $script:spoke 'V5 [kill] ... and SAYS SO -- a silent fallback in a control path is how the original defect hid'

# A truthy-but-malformed baseURL bypassed the emptiness check and was returned verbatim and
# SILENTLY -- review's case was the JSON number 8099 -- so a config fault surfaced later as "An
# invalid request URI was provided" from the probe rather than as a named configuration problem.
$srNum = New-StateDir
New-Item -ItemType Directory -Force (Join-Path $srNum 'configs') | Out-Null
New-Item -ItemType Directory -Force (Join-Path $srNum 'scripts') | Out-Null
Set-Content (Join-Path $srNum 'configs\opencode.json') '{ "provider": { "local": { "options": { "baseURL": 8099 } } } }' -Encoding utf8
$script:spokeNum = $false
$numUrl = Get-CoderBaseUrl -Model 'local/coder-30b' -ScriptRoot (Join-Path $srNum 'scripts') -Log { param($m) $script:spokeNum = $true }
Assert-True ($numUrl -eq 'http://127.0.0.1:8099/v3') 'V5b [kill] a baseURL that is a NUMBER falls back instead of being returned verbatim'
Assert-True $script:spokeNum                         'V5c [kill] ... and says so, rather than surfacing later as an invalid-URI error from the probe'

Assert-True ((Get-CoderBaseUrl -Model 'local/coder-30b' -ScriptRoot $PSScriptRoot -Log $quiet) -eq 'http://127.0.0.1:8099/v3') 'V6 the REAL configs/opencode.json parses and derives'
Assert-True ((Get-CoderBaseUrl -Model 'nope/x' -ScriptRoot $PSScriptRoot -Log $quiet) -eq 'http://127.0.0.1:8099/v3')          'V7 an unknown provider falls back rather than throwing'

Section 'W  wiring: the check is reachable, and runs BEFORE the build'

$icbStart = $lib.IndexOf('function Invoke-CandidateBuild')
Assert-True ($icbStart -gt 0) 'W1 Invoke-CandidateBuild located'
# BOUND THE SLICE. Substring($icbStart) runs to END OF FILE and swallowed the eight functions
# defined after this one -- review proved it by DELETING the pre-flight and leaving only a
# comment naming the symbols: the suite still reported all green.
$icbEnd = $lib.IndexOf("`r`nfunction ", $icbStart + 10)
if ($icbEnd -lt 0) { $icbEnd = $lib.IndexOf("`nfunction ", $icbStart + 10) }
if ($icbEnd -lt 0) { $icbEnd = $lib.Length }
$icb = $lib.Substring($icbStart, $icbEnd - $icbStart)
Assert-True  ($icbEnd -lt $lib.Length) 'W2 the slice STOPS at the next function (it does not run to end-of-file)'
Assert-False ($icb -match '(?m)^function\s+(?!Invoke-CandidateBuild)') 'W3 [kill] no OTHER function definition is inside the slice -- the containment is real'
Assert-True  ($icb -match 'Test-ModelServerHealth') 'W4 [kill] the per-candidate pipeline CALLS the health check (a control nothing invokes is the built-but-wired-into-nothing failure)'
Assert-True  ($icb -match 'Get-CoderBaseUrl')       'W5 ... aiming at the DERIVED coder endpoint, not a second hardcoded copy'
Assert-True  ($lib -match '\$ModelServerRecovery')  'W6 the pipeline exposes an operator off switch'

# -ScriptRoot MUST be passed explicitly. Measured: inside a Start-Job child -- which is how the
# concurrent best-of-N path runs EVERY candidate -- $PSScriptRoot is the empty string, so the
# parameter defaults resolve to nothing and both functions would silently fall back (the endpoint
# to its hardcoded default, the progress read to Found=false). It works today only because the
# wiring passes it; nothing was asserting that.
Assert-True ($icb -match 'Get-CoderBaseUrl[^\r\n]*-ScriptRoot')       'W6a [kill] the endpoint lookup is given an explicit -ScriptRoot (its default is empty in a Start-Job child)'
Assert-True ($icb -match 'Test-ModelServerHealth[^\r\n]*-ScriptRoot') 'W6b [kill] the health check is given an explicit -ScriptRoot, for the same reason'

# ORDER MATTERS, and it must be measured on STATEMENTS. The first attempt compared
# IndexOf('Test-ModelServerHealth') against IndexOf('Invoke-BuildWithRetry'); both landed on
# COMMENT prose, so it compared documentation order and the moved-block mutant survived at 63/0.
$mCheck = [regex]::Match($icb, '(?m)^\s*\$__ms\s*=\s*Test-ModelServerHealth')
$mBuild = [regex]::Match($icb, '(?m)^\s*\$build\s*=\s*Invoke-BuildWithRetry')
Assert-True $mCheck.Success 'W7a the pre-flight assignment statement is present'
Assert-True $mBuild.Success 'W7b the build assignment statement is present'
Assert-True ($mCheck.Success -and $mBuild.Success -and $mCheck.Index -lt $mBuild.Index) 'W7 [kill] the check STATEMENT runs before the build STATEMENT, not after it'

Section 'K  kill: the OLD probe shape passes the wedged fixture'

$mutantSaysLive = $false
try {
    $g = Invoke-WebRequest "$uWedged/v3/models" -TimeoutSec 20 -UseBasicParsing
    $mutantSaysLive = ($g.StatusCode -eq 200)
} catch { }
Assert-True $mutantSaysLive 'K1 [kill] the GET-only mutant reports the WEDGED server as healthy, reproducing the blind spot of both existing probes'

} finally { Stop-Fakes }

Write-Host ''
Write-Host ("RESULT: {0} passed, {1} failed" -f $script:Pass, $script:Fail) -ForegroundColor $(if ($script:Fail) { 'Red' } else { 'Green' })
if ($script:Fail) { exit 1 }
