#requires -Version 7.0
<#
.SYNOPSIS
  Verify start-llm.ps1 picks an interpreter that can actually run the tool-call proxy, VERIFIES
  it came up, and STOPS rather than retrying when it cannot (#1495).

.DESCRIPTION
  Background (plain English):
    OpenCode's baseURL is http://127.0.0.1:8099/v3 -- the tool-call repair proxy
    (tools/qwen-proxy.py), NOT the model server on :8000. Several faults combined on 2026-09-01
    to make the coder produce nothing at all, and each is locked here:

    1. THE INTERPRETER. #1497 prepends C:\ovms\python to PATH so ovms.exe can find its DLLs.
       That directory ships an EMBEDDED CPython with a python312._pth file, i.e. isolated mode,
       which does not put a script's own directory on sys.path. `Get-Command pythonw` after that
       edit returns C:\ovms\python\pythonw.exe (measured; it returns C:\Python314\pythonw.exe
       before it), and under that interpreter qwen-proxy.py dies on its first line:
       `ModuleNotFoundError: No module named 'qwen_toolcall_fix'`.

    2. THE BLIND LAUNCH. The proxy was started under `pythonw`, which has no console, with both
       streams discarded, and then reported "Tool-call fixer started" without checking the port.
       A proxy that died on startup and one never launched produced byte-identical evidence.
       Both battery runs that evening logged "started"; nothing was listening; opencode raised
       "Cannot connect to API" 24 and 25 times over 600s until the idle breaker killed each
       candidate having written nothing; OVMS logged "All requests: 0".

    3. THE SWALLOWED FAILURE. The block sits inside the READY poll's try/catch. Under
       $ErrorActionPreference 'Stop', BOTH a `throw` and any unguarded terminating error are
       caught there; the model is still loaded, so the poll re-enters this branch and prints
       READY again every three seconds until the 480s deadline, then reports a load timeout that
       never happened. Measured at 13 retries in 4 minutes. Only `exit` actually stops.

    4. THE EXCLUSION'S SHAPE. A bare string prefix is wrong in both directions: it rejects a
       legitimate C:\ovms\python-tools\pythonw.exe, and it MISSES the OVMS interpreter when the
       PATH entry is spelled with forward slashes -- silently reinstating fault 1.

    This suite does NOT re-type the fixed lines. It EXTRACTS the shipped block out of
    start-llm.ps1 between its own markers and runs that exact text in a separate pwsh process,
    wrapped in the SAME try/catch shape production has, so it measures what really happens.

    Includes the control tested with the lock off: the HISTORICAL block (recovered from git,
    not retyped) is put through the identical harness and must sail past the same dying proxy.

  Run it normally ( .\verify-coder-proxy-verified.ps1 ) - do NOT dot-source it.
  Needs git and pwsh on PATH; no model, no OVMS, no fleet run. Exit 0 all passed, 1 any failure.
#>
param()
$ErrorActionPreference = 'Stop'

$script:Pass = 0
$script:Fail = 0
$script:Failures = New-Object System.Collections.ArrayList
function Section($t) { Write-Host ''; Write-Host "== $t ==" -ForegroundColor Cyan }
function _pass($m)   { $script:Pass++; Write-Host "  [PASS] $m" -ForegroundColor Green }
function _fail($m)   { $script:Fail++; [void]$script:Failures.Add($m); Write-Host "  [FAIL] $m" -ForegroundColor Red }
function Assert-True($Cond, $Msg)  { if ($Cond) { _pass $Msg } else { _fail "$Msg (expected True, got False)" } }
function Assert-False($Cond, $Msg) { if (-not $Cond) { _pass $Msg } else { _fail "$Msg (expected False, got True)" } }
function Assert-Match($Text, $Pattern, $Msg) {
    if ($Text -and ($Text -match $Pattern)) { _pass $Msg } else { _fail "$Msg (no match for /$Pattern/)" }
}
function Assert-Eq($Actual, $Expected, $Msg) {
    if ($Actual -eq $Expected) { _pass $Msg } else { _fail "$Msg (expected '$Expected', got '$Actual')" }
}

$scriptPath = Join-Path $PSScriptRoot 'start-llm.ps1'
$srcRaw     = Get-Content -LiteralPath $scriptPath -Raw

$StartMarker = '# --- Tool-call repair proxy (qwen-proxy) ---------------------------------'
$EndMarker   = '# -------------------------------------------------------------------------'

function Get-ProxyBlock([string]$Text, [string]$Label) {
    $i = $Text.IndexOf($StartMarker)
    if ($i -lt 0) { throw "$Label - proxy block start marker not found; this suite is testing nothing." }
    $j = $Text.IndexOf($EndMarker, $i)
    if ($j -lt 0) { throw "$Label - proxy block end marker not found; this suite is testing nothing." }
    return $Text.Substring($i, ($j + $EndMarker.Length) - $i)
}

$shippedBlock = Get-ProxyBlock $srcRaw 'shipped'

# ---------------------------------------------------------------------------------------------
Section 'The shipped block cannot report success without checking the port'

Assert-Match $shippedBlock 'RedirectStandardError' `
    'the proxy launch keeps stderr (pythonw has no console; without this the traceback is lost)'
Assert-Match $shippedBlock 'RedirectStandardOutput' `
    'the proxy launch keeps stdout'
Assert-Match $shippedBlock 'while \(-not \$proxyUp' `
    'the block WAITS for the port instead of assuming Start-Process succeeded'
Assert-Match $shippedBlock 'verified on http://127\.0\.0\.1:\$ProxyPort - it answered for \$name' `
    'the success message claims exactly what was checked: the endpoint ANSWERED for this model'
Assert-False ($shippedBlock -match 'Tool-call fixer started on') `
    'the old unconditional "started" claim is gone'

Section 'Interpreter selection, and stopping rather than retrying'

Assert-Match $shippedBlock 'Get-Command \$proxyCand -All' `
    'interpreter resolution enumerates ALL candidates instead of taking the first on PATH'
Assert-Match $shippedBlock '\$ovmsPyDir' `
    'the OVMS embedded-python directory is named so it can be excluded (#1497 prepends it to PATH)'
Assert-Match $shippedBlock 'GetFullPath' `
    'paths are NORMALISED before comparison, not compared as raw strings'
Assert-Match $shippedBlock 'DirectorySeparatorChar' `
    'the exclusion appends an explicit separator, so a sibling directory cannot prefix-match'
Assert-Match $shippedBlock '(?m)^\s*exit 1\s+#' `
    'a fatal EXITS (a throw here is swallowed by the enclosing READY poll and the load retries)'
Assert-False ($shippedBlock -match '(?m)^\s*throw ') `
    'the block contains no throw at all - it would be caught and retried, never surfacing'

# The launch is the statement most likely to throw under $ErrorActionPreference 'Stop' (a corrupt
# or wrong-architecture image cannot be CreateProcess'd). It must not be the one unguarded line.
# Match the launch STATEMENT, not the word: the block's own header comment discusses
# "Start-Process on a corrupt image", and matching that comment put the index before the try.
$launchIdx = $shippedBlock.IndexOf('Start-Process -FilePath $py')
$tryIdx    = $shippedBlock.IndexOf('try {')
Assert-True (($tryIdx -ge 0) -and ($tryIdx -lt $launchIdx)) `
    'the launch sits INSIDE a try (an unguarded Start-Process failure would reach the READY poll)'
Assert-Match $shippedBlock '(?s)catch \{[^}]*\$proxyFatal =' `
    'that catch records the failure as fatal rather than warning and carrying on'

# The behavioural harness rewrites exactly this one line onto a free port. Assert its shipped
# form so that rewrite can never quietly mask a drift in the real value.
Assert-Match $shippedBlock '(?m)^\s*\$ProxyPort\s*=\s*8099\s*$' `
    'the shipped port is a single assignable line reading 8099 (the value opencode.json points at)'

Section 'The script does not claim more than it checked'

# A port check proves only that something is bound, and a PID check is worse than it looks:
# the proxy may bind in a CHILD of the launched process, and the Store-Python App Execution
# Alias re-execs into a different pid, so comparing pids rejects a WORKING proxy (both measured).
# The property actually wanted is that the endpoint serves this model, so probe it.
Assert-Match $shippedBlock 'Invoke-WebRequest "http://127\.0\.0\.1:\$ProxyPort/v3/models"' `
    'the endpoint is PROBED for the model, not merely observed to be bound'
Assert-Match $shippedBlock '\$proxyServed -contains \$name' `
    'the probe requires the model the coding agent is about to ask for'
Assert-False ($shippedBlock -match 'OwningProcess') `
    'no pid comparison: it guards the rare branch and false-positives on a proxy that binds in a child'
Assert-False ($shippedBlock -match '-PassThru') `
    'the process handle is not needed once identity is established by behaviour'

# The proxy survives model swaps, so "already listening" is the NORMAL path on every swap after
# the first. A check that only runs on the branch we just started guards the rare case.
$probeIdx = $shippedBlock.IndexOf('Invoke-WebRequest "http://127.0.0.1:$ProxyPort/v3/models"')
$elseIdx  = $shippedBlock.IndexOf('if (-not $proxyUp) {')
Assert-True (($probeIdx -gt $elseIdx) -and ($elseIdx -ge 0)) `
    'the probe sits AFTER the start branch, so a pre-existing listener is verified too, not trusted'

# Whole-file ordering: "READY" must not be announced before the endpoint the coding agent uses
# is known to be live, or the console contradicts itself ("READY" then "Refusing to report READY").
$readyIdx    = $srcRaw.IndexOf('READY: $name is now loaded')
$blockEndIdx = $srcRaw.IndexOf($EndMarker, $srcRaw.IndexOf($StartMarker))
Assert-True ($readyIdx -gt $blockEndIdx) `
    'READY is announced only AFTER the proxy is verified, not 90 lines before the refusal to report it'
Assert-Match $srcRaw '(?m)^\s*Set-Content "\$StateDir\\server-should-run\.txt"' `
    'the watchdog sentinel is still armed for the loaded model (a live server left unwatched is its own defect)'

# ---------------------------------------------------------------------------------------------
Section 'Driving the SHIPPED block in a real process, inside production''s try/catch'

function New-Fixture {
    $root = Join-Path ([System.IO.Path]::GetTempPath()) ("proxyverify-" + [guid]::NewGuid().ToString('N').Substring(0,8))
    foreach ($d in @('tools', 'logs', 'ovms\python', 'ovms\python-tools', 'badpy')) {
        New-Item -ItemType Directory -Force (Join-Path $root $d) | Out-Null
    }
    # Binds nothing and dies immediately, with a distinctive word on stderr.
    'raise RuntimeError("FIXTURE_PROXY_REFUSED_TO_START")' |
        Set-Content -LiteralPath (Join-Path $root 'tools\qwen-proxy.py') -Encoding utf8
    # Decoys: named like interpreters, not actually executable images. Get-Command finds them by
    # name; Start-Process cannot create a process from them, which is exactly the case under test.
    foreach ($p in @('ovms\python\pythonw.exe', 'ovms\python-tools\pythonw.exe', 'badpy\pythonw.exe')) {
        'not a real interpreter' | Set-Content -LiteralPath (Join-Path $root $p) -Encoding ascii
    }
    return $root
}

function Get-FreeLoopbackPort {
    $l = [System.Net.Sockets.TcpListener]::new([System.Net.IPAddress]::Loopback, 0)
    $l.Start(); $p = $l.LocalEndpoint.Port; $l.Stop()
    return $p
}

function Invoke-ProxyBlockInProcess([string]$Block, [string]$Fixture, [int]$Port, [string]$PathExpr) {
    # Rewrite ONLY the port so the suite never fights a real proxy on 8099 and never leaves one
    # behind on it. The shipped form of that line is asserted above. The historical block has no
    # $ProxyPort variable at all -- it hardcodes the port inline -- so both forms are redirected.
    $code = $Block -replace '(?m)^(\s*)\$ProxyPort\s*=\s*8099\s*$', ('${1}$ProxyPort = ' + $Port)
    $code = $code -replace '-LocalPort 8099', "-LocalPort $Port"
    $code = $code -replace '127\.0\.0\.1:8099', "127.0.0.1:$Port"

    # If any 8099 survives the rewrite, this harness would drive the REAL proxy. That is not a
    # failing test, it is a test of nothing: the live proxy answers "already running" and every
    # case exits 0. Observed happening when a cosmetic realignment of the port line stopped the
    # rewrite regex matching, so refuse loudly rather than report green.
    # Comments in the block legitimately mention 8099 (they explain what it is); only executable
    # text matters, so strip trailing comments before the check.
    $codeNoComments = ($code -split "`n" | ForEach-Object { $_ -replace '#.*$', '' }) -join "`n"
    if ($codeNoComments -match '8099') {
        throw "harness refused: '8099' survived the port rewrite in executable text, so this would drive the LIVE proxy instead of the fixture."
    }

    # Reproduce production's shape: the block lives inside a try whose catch swallows terminating
    # errors and lets the caller retry. If the block signals failure with `throw`, or leaves a
    # statement unguarded, SWALLOWED is printed and the script reaches its end with exit 0 --
    # which is the pathology this locks.
    $harness = @(
        '$ErrorActionPreference = ''Stop'''   # production's setting, line 19 of start-llm.ps1
        "`$Setup  = '$Fixture'"
        "`$LogDir = '" + (Join-Path $Fixture 'logs') + "'"
        "`$Ovms   = '" + (Join-Path $Fixture 'ovms\ovms.exe') + "'"
        "`$name   = 'fixture-model'"   # the model id the probe demands the endpoint serve
        $PathExpr
        'try {'
        $code
        '} catch { Write-Host "SWALLOWED" }'
        'Write-Host "REACHED_END"'
        'exit 0'
    ) -join [Environment]::NewLine

    $tmp = Join-Path $Fixture ("harness-" + [guid]::NewGuid().ToString('N').Substring(0,6) + ".ps1")
    Set-Content -LiteralPath $tmp -Value $harness -Encoding utf8
    $out = & pwsh -NoProfile -ExecutionPolicy Bypass -File $tmp 2>&1 | Out-String
    return @{ Code = $LASTEXITCODE; Out = $out }
}

$fixture = New-Fixture
try {
    $ovmsPy      = Join-Path $fixture 'ovms\python'
    $ovmsPyFwd   = $ovmsPy -replace '\\', '/'
    $ovmsSibling = Join-Path $fixture 'ovms\python-tools'
    $badPy       = Join-Path $fixture 'badpy'

    # --- Case A: a REAL interpreter is found, and the proxy it starts dies on import ----------
    $port = Get-FreeLoopbackPort
    $r = Invoke-ProxyBlockInProcess -Block $shippedBlock -Fixture $fixture -Port $port `
            -PathExpr ("`$env:PATH = '$ovmsPy' + [IO.Path]::PathSeparator + `$env:PATH")

    Assert-Eq $r.Code 1 `
        'LOCK ON: a proxy that dies on startup makes start-llm.ps1 EXIT NON-ZERO instead of reporting READY'
    Assert-False ($r.Out -match 'SWALLOWED') `
        "LOCK ON: the failure ESCAPES production's catch (a throw here would be caught and the load retried)"
    Assert-False ($r.Out -match 'REACHED_END') `
        'LOCK ON: execution stops at the failure rather than carrying on'
    Assert-Match $r.Out 'FATAL' 'LOCK ON: the failure is announced as fatal'
    Assert-Match $r.Out 'did NOT come up' 'LOCK ON: the failure says the proxy did not come up'
    Assert-Match $r.Out 'FIXTURE_PROXY_REFUSED_TO_START' `
        "LOCK ON: the failure carries the PROXY'S OWN words -- the traceback pythonw used to discard"
    Assert-Match $r.Out ([regex]::Escape(":$port")) `
        'LOCK ON: the failure names the port the coding agent would have talked to'
    Assert-False (Get-NetTCPConnection -LocalPort $port -State Listen -ErrorAction SilentlyContinue) `
        'the fixture proxy genuinely never bound (so the failure was earned, not incidental)'

    # --- Case B: the OVMS embedded interpreter is refused, not used --------------------------
    Section 'The OVMS embedded interpreter is refused rather than used (#1497 regression)'

    $p2 = Get-FreeLoopbackPort
    $o = Invoke-ProxyBlockInProcess -Block $shippedBlock -Fixture $fixture -Port $p2 `
            -PathExpr ("`$env:PATH = '$ovmsPy'")
    Assert-Eq $o.Code 1 `
        'with ONLY the OVMS python on PATH the block refuses rather than launching an interpreter that cannot import the fixer'
    Assert-Match $o.Out 'isolated mode' `
        'the refusal explains WHY that interpreter is unusable, not merely that it was rejected'
    Assert-False ($o.Out -match 'SWALLOWED') 'that refusal also escapes the enclosing catch'

    # --- Case C: forward-slash spelling must NOT defeat the exclusion ------------------------
    Section 'The exclusion survives PATH spelling, and does not over-match siblings'

    $p3 = Get-FreeLoopbackPort
    $f = Invoke-ProxyBlockInProcess -Block $shippedBlock -Fixture $fixture -Port $p3 `
            -PathExpr ("`$env:PATH = '$ovmsPyFwd'")
    Assert-Match $f.Out 'no Python outside' `
        'a PATH entry spelled with FORWARD SLASHES is still recognised as the OVMS python and excluded'
    Assert-Eq $f.Code 1 'and that exclusion is fatal rather than a silent launch of the wrong interpreter'

    # --- Case D: a sibling directory sharing the prefix must NOT be excluded -----------------
    $p4 = Get-FreeLoopbackPort
    $s = Invoke-ProxyBlockInProcess -Block $shippedBlock -Fixture $fixture -Port $p4 `
            -PathExpr ("`$env:PATH = '$ovmsSibling'")
    Assert-False ($s.Out -match 'no Python outside') `
        'a LEGITIMATE interpreter in a sibling directory (ovms\python-tools) is NOT excluded by prefix'
    Assert-Match $s.Out 'could not be started' `
        'it is attempted, and its launch failure is reported as a launch failure'

    # --- Case E: a launch that cannot create the process is caught, not leaked ---------------
    Section 'A launch failure is caught rather than escaping into the READY poll'

    $p5 = Get-FreeLoopbackPort
    $b = Invoke-ProxyBlockInProcess -Block $shippedBlock -Fixture $fixture -Port $p5 `
            -PathExpr ("`$env:PATH = '$badPy'")
    Assert-Eq $b.Code 1 'an interpreter that cannot be CreateProcess''d is fatal'
    Assert-False ($b.Out -match 'SWALLOWED') `
        'LOCK ON: the launch failure does NOT reach the enclosing catch (which would retry the whole model load)'
    Assert-False ($b.Out -match 'REACHED_END') 'and does not fall through'
    Assert-Match $b.Out 'could not be started' 'the message names it as a start failure'

    # --- Case F: a squatter already on the port must NOT be trusted --------------------------
    # This is the branch that matters most in production: the proxy survives model swaps, so
    # "already listening" is the normal path on every swap after the first. Review reproduced a
    # foreign process holding the port being accepted outright and proceeding to READY.
    Section 'A pre-existing listener that is not the fixer is refused, not trusted'

    $squatter = [System.Net.Sockets.TcpListener]::new([System.Net.IPAddress]::Loopback, 0)
    $squatter.Start()
    $squatPort = $squatter.LocalEndpoint.Port
    try {
        # It accepts nothing, so the TCP handshake completes (backlog) and the HTTP probe hangs
        # until its timeout -- exactly what a non-proxy squatter looks like.
        $q = Invoke-ProxyBlockInProcess -Block $shippedBlock -Fixture $fixture -Port $squatPort `
                -PathExpr ("`$env:PATH = '$ovmsPy' + [IO.Path]::PathSeparator + `$env:PATH")
        Assert-Eq $q.Code 1 `
            'a foreign process holding the port is FATAL rather than accepted as "already running"'
        Assert-False ($q.Out -match 'REACHED_END') `
            'it does not proceed to READY on the strength of something being bound'
        Assert-Match $q.Out 'did not answer a model query|serves \[' `
            'the refusal says the endpoint failed to answer for this model'
    }
    finally { $squatter.Stop() }

    # ------------------------------------------------------------------------------------------
    Section 'CONTROL - the same failure with the lock OFF must NOT be caught'

    # `git log -- <path>` resolves its pathspec against the CWD, while `git show <sha>:<path>`
    # always resolves against the repo root. Drive both from the root so they agree.
    $repoRoot = (& git -C $PSScriptRoot rev-parse --show-toplevel 2>$null)
    if (-not $repoRoot) { $repoRoot = Split-Path -Parent $PSScriptRoot }
    $historicalRaw = $null
    foreach ($sha in (& git -C $repoRoot log --format=%H -40 -- scripts/start-llm.ps1)) {
        $text = (& git -C $repoRoot show "${sha}:scripts/start-llm.ps1" 2>$null) -join [Environment]::NewLine
        if ($text -match 'Tool-call fixer started on') { $historicalRaw = $text; break }
    }

    if (-not $historicalRaw) {
        _fail 'CONTROL: could not recover the historical block from git - the control did not run, so LOCK ON proves nothing'
    } else {
        $historicalBlock = Get-ProxyBlock $historicalRaw 'historical'
        $p6 = Get-FreeLoopbackPort
        $c = Invoke-ProxyBlockInProcess -Block $historicalBlock -Fixture $fixture -Port $p6 `
                -PathExpr ("`$env:PATH = '$ovmsPy' + [IO.Path]::PathSeparator + `$env:PATH")
        Assert-Eq $c.Code 0 `
            'CONTROL: the historical block sails past the SAME dying proxy and exits clean'
        Assert-Match $c.Out 'REACHED_END' `
            'CONTROL: it runs to the end - it never looked at the port'
        Assert-False (Get-NetTCPConnection -LocalPort $p6 -State Listen -ErrorAction SilentlyContinue) `
            'CONTROL: nothing was listening there either - the old code simply never checked'
    }
}
finally {
    Remove-Item -Recurse -Force $fixture -ErrorAction SilentlyContinue
}

# ---------------------------------------------------------------------------------------------
Write-Host ''
Write-Host ("RESULT: {0} passed, {1} failed" -f $script:Pass, $script:Fail) -ForegroundColor $(if ($script:Fail) { 'Red' } else { 'Green' })
if ($script:Fail) { $script:Failures | ForEach-Object { Write-Host "  - $_" -ForegroundColor Red }; exit 1 }
exit 0
