# fleet-lib.ps1 - shared helpers for the agent fleet (verify gate, secret-scan,
# circuit breakers, session supervisor). Dot-source it:
#     . "$PSScriptRoot\fleet-lib.ps1"
# Pure function definitions only - NO side effects on load (safe to dot-source).
# ASCII-only; PowerShell 5.1 + 7 compatible.

function Invoke-WithTimeout {
    # Run a shell command line (via cmd /c) in $WorkDir under a hard wall-clock
    # timeout. On timeout the WHOLE process tree is killed (taskkill /T /F) so a
    # hung build/agent cannot run forever. stdout+stderr are captured to temp
    # files (not the console) and returned.
    # Returns: @{ TimedOut=[bool]; ExitCode=[int]|$null; Output=[string]; Seconds=[double] }
    param(
        [Parameter(Mandatory)][string]$CommandLine,
        [string]$WorkDir = (Get-Location).Path,
        [int]$TimeoutSec = 600
    )
    $outFile = [System.IO.Path]::GetTempFileName()
    $errFile = [System.IO.Path]::GetTempFileName()
    # Empty stdin (#695): when this runs INSIDE a console-less Start-Job child (best-of-N CONCURRENCY), a
    # `cmd /c` grandchild started with -NoNewWindow + redirected stdout/stderr but an INHERITED, piped,
    # never-EOF stdin can BLOCK at 0% CPU -- two concurrent gate checks then wedge indefinitely (a live C=2
    # dispatch hung both candidates at `python -m compileall` until the wall-clock kill). Feeding an empty
    # file makes any stdin read hit EOF instantly. This is the SAME proven fix Invoke-AgentRun uses for
    # headless opencode; it is a no-op for the main-process (console) caller and for any command that never
    # reads stdin, so the sequential C=1 gate is byte-identical.
    $inFile  = [System.IO.Path]::GetTempFileName()
    Set-Content -Path $inFile -Value '' -NoNewline -ErrorAction SilentlyContinue
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    try {
        $p = Start-Process -FilePath $env:ComSpec -ArgumentList '/c', $CommandLine `
             -WorkingDirectory $WorkDir -PassThru -NoNewWindow `
             -RedirectStandardInput $inFile -RedirectStandardOutput $outFile -RedirectStandardError $errFile
        $null = $p.Handle   # PS 5.1: caching the handle makes $p.ExitCode readable after exit
    } catch {
        Remove-Item $outFile, $errFile, $inFile -ErrorAction SilentlyContinue
        return @{ TimedOut = $false; ExitCode = $null; Output = "Could not start command: $($_.Exception.Message)"; Seconds = 0 }
    }
    $done = $p.WaitForExit($TimeoutSec * 1000)
    $timedOut = $false
    if (-not $done) {
        $timedOut = $true
        try { & taskkill.exe /PID $p.Id /T /F *> $null } catch {}
        try { $null = $p.WaitForExit(5000) } catch {}
    }
    $sw.Stop()
    $stdout = Get-Content $outFile -Raw -ErrorAction SilentlyContinue
    $stderr = Get-Content $errFile -Raw -ErrorAction SilentlyContinue
    Remove-Item $outFile, $errFile, $inFile -ErrorAction SilentlyContinue
    $exit = if ($timedOut) { $null } else { $p.ExitCode }
    return @{
        TimedOut = $timedOut
        ExitCode = $exit
        Output   = (@($stdout, $stderr) | Where-Object { $_ }) -join "`n"
        Seconds  = [math]::Round($sw.Elapsed.TotalSeconds, 1)
    }
}

function Test-EnvironmentFailure {
    # Heuristic: did a non-zero check fail because of a MISSING tool / offline
    # restore / setup gap (which should NOT block a merge) rather than a real
    # code error? Keeps the verify gate high-precision: environment gaps -> skip.
    param([string]$Output)
    if (-not $Output) { return $false }
    $patterns = @(
        'is not recognized as an internal or external command',
        'command not found',
        'Missing script:',
        'npm error Missing script',
        'Cannot find module',                 # tooling absent, not user code
        # NOTE: NU1101/NU1301/NU1102 (NuGet package-not-found) are deliberately NOT
        # treated as env gaps - a package missing from the offline feed means the code
        # is not offline-buildable, so it must FAIL (not skip/auto-merge).
        'Unable to load the service index',   # NuGet feed unreachable (network/offline)
        'No such host is known',              # any network attempt offline
        'getaddrinfo',                        # network resolution failure
        'Could not start command',
        'The term .* is not recognized'
    )
    foreach ($p in $patterns) { if ($Output -match $p) { return $true } }
    return $false
}

function Get-LoadedModelId {
    # Returns the currently-loaded OVMS model id, or $null if the server is down
    # or no model is loaded.
    param([int]$TimeoutSec = 3)
    try {
        $r = Invoke-WebRequest 'http://127.0.0.1:8000/v3/models' -TimeoutSec $TimeoutSec -UseBasicParsing
        $first = ($r.Content | ConvertFrom-Json).data | Select-Object -First 1
        if ($first) { return $first.id } else { return $null }
    } catch { return $null }
}

function Write-Journal {
    # Append a timestamped, structured line to a session journal file. Used by the
    # supervisor so a long unattended run leaves a readable, resumable trail.
    param(
        [Parameter(Mandatory)][string]$JournalPath,
        [Parameter(Mandatory)][string]$Event,
        [string]$Detail = ''
    )
    $dir = Split-Path $JournalPath -Parent
    if ($dir -and -not (Test-Path $dir)) { New-Item -ItemType Directory -Force $dir | Out-Null }
    $line = '{0} | {1} | {2}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Event, ($Detail -replace '[\r\n]+', ' ')
    Add-Content -Path $JournalPath -Value $line
}

function ConvertTo-Win32Arg {
    # Quote ONE argument for a Windows command line per the CommandLineToArgvW rules,
    # so Start-Process passes it as a single argv entry no matter what it contains.
    # WHY: Start-Process -ArgumentList with an ARRAY does NOT quote - it space-joins,
    # so the child re-splits on every space. That shattered a multi-word prompt into
    # dozens of tokens, and any token that looked like a flag (-m, -q, a bare -, or a
    # path with a space) was mis-read by opencode's parser, which then printed its help
    # and exited (a guaranteed no-op). Building a properly-quoted single string and
    # passing THAT to -ArgumentList fixes it on both PS 5.1 and PS 7.
    param([string]$Arg)
    if ($Arg.Length -gt 0 -and $Arg -notmatch '[\s"]') { return $Arg }
    $r = '"'; $bs = 0
    foreach ($ch in $Arg.ToCharArray()) {
        if ($ch -eq '\') { $bs++ }
        elseif ($ch -eq '"') { $r += ('\' * ($bs * 2 + 1)) + '"'; $bs = 0 }
        else { if ($bs -gt 0) { $r += ('\' * $bs); $bs = 0 }; $r += $ch }
    }
    $r += ('\' * ($bs * 2)) + '"'
    return $r
}

function Test-PluginLoadLines {
    # #762 load-line canary (the lesson-46 third-instance control, 2026-07-08).
    # Both fleet plugins print a designed-in stderr load-line at every opencode
    # boot precisely "so the fleet can VERIFY the plugin actually wired in" -- and
    # nothing ever read them, so both plugins ran silently DEAD in production from
    # 2026-06-30 until the #759 recon tripped over the loader errors a week and a
    # battery campaign later (#764). This is the reader those lines never had:
    # a PURE check over a completed run's transcript (stderr is folded into the
    # transcript at run end). Returns @{ Ok; Missing; LoaderErrors }.
    #
    # COUPLING: the literals below are pinned against the plugin sources in
    # configs/opencode-plugins/ by verify-plugin-canary.ps1 -- reword a plugin's
    # load-line and that verify names the drift before the canary goes blind.
    param([string]$TranscriptContent)
    $required = @(
        @{ Name = 'command-timeout'; Marker = '[command-timeout] loaded' },
        @{ Name = 'path-normalize';  Marker = '[path-normalize] loaded' }
    )
    $missing = @()
    foreach ($plugin in $required) {
        if ($TranscriptContent.IndexOf($plugin.Marker, [System.StringComparison]::Ordinal) -lt 0) {
            $missing += $plugin.Name
        }
    }
    $loaderErrors = @()
    if ($TranscriptContent) {
        $loaderErrors = @(
            $TranscriptContent -split "`n" |
                Where-Object { $_ -match 'failed to load plugin|Plugin export is not a function' } |
                ForEach-Object { $_.Trim() } | Select-Object -First 5
        )
    }
    return @{
        Ok           = (($missing.Count -eq 0) -and ($loaderErrors.Count -eq 0))
        Missing      = $missing
        LoaderErrors = $loaderErrors
    }
}

function Write-PluginCanaryVerdict {
    # Side-effecting half of the #762 canary: on a failed check, append a LOUD
    # line to the run transcript (the surface humans and the battery report read)
    # and a timestamped record to state/plugin-canary-failed.txt (a stable probe
    # for machines: the morning report, the battery runner, the #762 canary run).
    # NEVER fails the run -- a canary is visibility, not a gate; and NEVER throws
    # (it runs on the tail of every agent run, including mid-battery).
    param(
        [Parameter(Mandatory)][hashtable]$Verdict,
        [Parameter(Mandatory)][string]$LogPath,
        [string]$StateDir = ''
    )
    if ($Verdict.Ok) { return }
    try {
        $detail = 'PLUGIN-CANARY: FAILED'
        if ($Verdict.Missing.Count -gt 0) { $detail += (' -- load-line missing: ' + ($Verdict.Missing -join ', ')) }
        if ($Verdict.LoaderErrors.Count -gt 0) { $detail += (' -- loader errors: ' + ($Verdict.LoaderErrors -join ' | ')) }
        Add-Content -Path $LogPath -Value $detail -ErrorAction SilentlyContinue
        if (-not $StateDir) { $StateDir = Join-Path (Split-Path $PSScriptRoot -Parent) 'state' }
        if (Test-Path $StateDir) {
            $marker = Join-Path $StateDir 'plugin-canary-failed.txt'
            $line = '{0} | {1} | {2}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $LogPath, $detail
            Add-Content -Path $marker -Value $line -ErrorAction SilentlyContinue
        }
    } catch { }
}

function Test-DispatchCancelled {
    # #771 STOP-CONTRACT consumer. The dispatch monitor's `/dispatch stop` writes a cancel sentinel at
    # state/fleet-swap/cancel (blarai shared/fleet/swap_ops.cancel_path -- the SAME file run-battery-night.ps1
    # clears stale at launch and the swap driver clears at handoff). The Python swap DRIVER already honours it
    # at each TASK boundary, but WITHIN a task the PowerShell best-of-N candidate loop never read it -- so after
    # a stop landed, candidate N's gate timed out and the loop went on to BUILD candidate N+1 (a fresh ~hour of
    # GPU with OVMS still holding the card) until the run-budget watchdog tore down an hour later (the #771
    # defect, run 2026-07-08). This is the READ-ONLY consumer that loop needed: a cheap Test-Path checked
    # BETWEEN candidates and BETWEEN gate steps. It NEVER writes or clears the sentinel -- ownership stays with
    # the writer (the monitor) and the stale-clearers (the launcher at start + the driver at handoff), so it
    # cannot race them. This is the ALIVE loop acting on its OWN stop, never a reconciler presuming death (the
    # #758 invariant). ScriptRoot defaults to fleet-lib's own dir (Split-Path -Parent == the agentic root, the
    # same anchor run-battery-night.ps1 and Write-PluginCanaryVerdict use); tests point it at a temp dir.
    # Cheap + side-effect-free; unit-tested without a model (verify-stop-contract.ps1).
    param([string]$ScriptRoot = $PSScriptRoot)
    $cancel = Join-Path (Split-Path $ScriptRoot -Parent) 'state\fleet-swap\cancel'
    return [bool](Test-Path -LiteralPath $cancel)
}

function Get-OpencodePinVerdict {
    # #762 version-pin verdict -- the PURE half of the fail-closed spawn tripwire (mirrors Test-PluginLoadLines:
    # pure + injectable + unit-tested; the impure probing lives in the caller). opencode ships as an UNPINNED
    # global npm package (autoupdate:false is the only brake), so a silent npm upgrade -- or a tampered binary --
    # could swap the exact release the fleet was validated against out from under a live dispatch.
    # configs/opencode-version-pin.json records that release (version + sha256 + exe_path); this compares the
    # LIVE probe against it. FAIL-CLOSED: a null/unreadable manifest, an unresolved binary, a probe that read
    # NEITHER a version nor a hash, or ANY mismatch => Ok=$false with a cause-carrying Reason (never a vacuous
    # pass). Callers do the impure Get-Command / `opencode --version` / Get-FileHash and pass the results in.
    # Never throws. Pure; unit-tested without opencode installed (verify-opencode-pin-wiring.ps1).
    param(
        $Manifest,                       # parsed opencode-version-pin.json (or $null if missing/unparseable)
        [string]$LiveExePath = '',       # resolved live opencode.exe path (or '' if unresolved)
        [string]$LiveVersion = '',       # `opencode --version` output (or '' if unread)
        [string]$LiveHash = ''           # SHA-256 of the live exe (or '' if not computed)
    )
    if ($null -eq $Manifest) {
        return @{ Ok = $false; Reason = 'pin manifest missing or unreadable (configs/opencode-version-pin.json) -- cannot verify the opencode release; refusing fail-closed'; LiveVersion = $LiveVersion; PinVersion = '' }
    }
    $pinVersion = [string]$Manifest.version
    $pinSha     = [string]$Manifest.sha256
    $pinExe     = [string]$Manifest.exe_path
    if (-not $pinVersion -or -not $pinSha) {
        return @{ Ok = $false; Reason = "pin manifest incomplete (version='$pinVersion', has-sha256=$([bool]$pinSha)) -- refusing fail-closed"; LiveVersion = $LiveVersion; PinVersion = $pinVersion }
    }
    if (-not $LiveExePath) {
        return @{ Ok = $false; Reason = 'live opencode binary could not be resolved on PATH -- refusing fail-closed'; LiveVersion = $LiveVersion; PinVersion = $pinVersion }
    }
    if (-not $LiveVersion -and -not $LiveHash) {
        # Could not probe the live binary AT ALL (neither `--version` nor the hash) -- a vacuous "path matched"
        # is not a validation, so refuse rather than let an unverified binary spawn.
        return @{ Ok = $false; Reason = 'could not probe the live opencode (no version, no hash) -- refusing fail-closed'; LiveVersion = $LiveVersion; PinVersion = $pinVersion }
    }
    if ($pinExe) {
        $liveNorm = ($LiveExePath -replace '\\', '/')
        $pinNorm  = ($pinExe -replace '\\', '/')
        if ($liveNorm -ine $pinNorm) {
            return @{ Ok = $false; Reason = "opencode PATH drift: live '$liveNorm' != pin '$pinNorm' -- refusing fail-closed"; LiveVersion = $LiveVersion; PinVersion = $pinVersion }
        }
    }
    if ($LiveVersion -and ($LiveVersion -ne $pinVersion)) {
        return @{ Ok = $false; Reason = "opencode VERSION drift: live '$LiveVersion' != pin '$pinVersion' (a silent npm upgrade?) -- refusing fail-closed"; LiveVersion = $LiveVersion; PinVersion = $pinVersion }
    }
    if ($LiveHash -and ($LiveHash -ine $pinSha)) {
        return @{ Ok = $false; Reason = "opencode BINARY drift: live sha256 '$LiveHash' != pin '$pinSha' (tampered or replaced binary) -- refusing fail-closed"; LiveVersion = $LiveVersion; PinVersion = $pinVersion }
    }
    return @{ Ok = $true; Reason = "opencode $pinVersion matches the pin"; LiveVersion = $LiveVersion; PinVersion = $pinVersion }
}

function Invoke-OpencodePinProbe {
    # #762 impure probe + per-process memo around the PURE Get-OpencodePinVerdict. Resolves the live opencode
    # binary, reads its `--version` + SHA-256 + the pin manifest, and returns the fail-closed verdict.
    # MEMOISED per process by the exe's path+size+mtime fingerprint: the SHA-256 of the ~165 MB binary is ~1.5s,
    # and the sequential best-of-N loop calls Invoke-AgentRun many times per process (each candidate + each
    # review pass), so without the memo every call would re-hash. A silent npm upgrade changes the file
    # (size/mtime) => fingerprint miss => re-probed, so the memo can never HIDE drift. Never throws (any probe
    # error becomes a fail-closed verdict, not an exception that could crash the run). Impure by nature (spawns
    # + hashes), so the UNIT coverage is on Get-OpencodePinVerdict; this is the thin live shim.
    param([string]$ExePath = '', [switch]$NoMemo)
    try {
        if (-not $ExePath) {
            $src = (Get-Command opencode -ErrorAction SilentlyContinue).Source
            if ($src) { $ExePath = Join-Path (Split-Path $src -Parent) 'node_modules\opencode-ai\bin\opencode.exe' }
        }
        $fileInfo = if ($ExePath -and (Test-Path -LiteralPath $ExePath)) { Get-Item -LiteralPath $ExePath -ErrorAction SilentlyContinue } else { $null }
        $fingerprint = if ($fileInfo) { '{0}|{1}|{2}' -f $fileInfo.FullName, $fileInfo.Length, $fileInfo.LastWriteTimeUtc.Ticks } else { "unresolved:$ExePath" }
        if (-not $NoMemo -and $script:__OcPinMemo -and ($script:__OcPinMemo.Fingerprint -eq $fingerprint)) {
            return $script:__OcPinMemo.Verdict
        }
        # Manifest lives beside the scripts dir: <agentic-root>/configs/opencode-version-pin.json.
        $manifestPath = Join-Path (Split-Path $PSScriptRoot -Parent) 'configs\opencode-version-pin.json'
        $manifest = $null
        if (Test-Path -LiteralPath $manifestPath) {
            try { $manifest = Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json } catch { $manifest = $null }
        }
        $liveVersion = ''
        if ($fileInfo) {
            try { $liveVersion = ("$(& $ExePath --version 2>$null | Select-Object -First 1)").Trim() } catch { $liveVersion = '' }
        }
        $liveHash = ''
        if ($fileInfo) {
            try { $liveHash = (Get-FileHash -LiteralPath $ExePath -Algorithm SHA256 -ErrorAction Stop).Hash } catch { $liveHash = '' }
        }
        $verdict = Get-OpencodePinVerdict -Manifest $manifest -LiveExePath ($(if ($fileInfo) { $fileInfo.FullName } else { '' })) -LiveVersion $liveVersion -LiveHash $liveHash
        if (-not $NoMemo) { $script:__OcPinMemo = @{ Fingerprint = $fingerprint; Verdict = $verdict } }
        return $verdict
    } catch {
        # A probe crash must never crash the caller; treat it as a fail-closed refusal with the cause.
        return @{ Ok = $false; Reason = "opencode pin probe error: $($_.Exception.Message) -- refusing fail-closed"; LiveVersion = ''; PinVersion = '' }
    }
}

function Invoke-AgentRun {
    # Run `opencode run` under a PROGRESS-AWARE circuit breaker, capturing the transcript
    # to a log for anomaly analysis. On a stop the whole process tree is killed so a
    # confused small model cannot churn forever unattended.
    #
    # Progress-aware timeout (#682): the build/coder path ($JsonStepCap) no longer dies at
    # a single short absolute deadline. The monitor distinguishes a PRODUCTIVE-but-slow
    # coder (new step_finish / edits arriving) from a genuinely STUCK one:
    #   - IDLE   : no new step_finish AND no new edit for $IdleTimeoutSec -> stuck (wedged,
    #              frozen, server dead). Killed FAST so a doomed run can't bleed the budget.
    #   - CEILING: a generous absolute backstop ($TimeoutSec) so even a trickle-progress
    #              run cannot run unbounded. A still-progressing build runs until this
    #              ceiling rather than being guillotined at a short fixed deadline
    #              ("killing it too soon"). Both map to TimedOut (never resampled; see
    #              Test-ShouldResample). The decision is the PURE Resolve-RunStopDecision.
    # Returns: @{ TimedOut=[bool]; TimeoutReason=[string]; Capped=[bool]; CappedReason;
    #            ExitCode=[int]|$null; LogPath; Seconds; Error }
    param(
        [Parameter(Mandatory)][string]$WorkDir,
        [Parameter(Mandatory)][string]$Model,
        [Parameter(Mandatory)][string]$Prompt,
        [Parameter(Mandatory)][string]$LogPath,
        [int]$TimeoutSec = 1800,
        [string]$Agent = '',
        [switch]$JsonStepCap,
        [int]$MaxSteps = 45,
        [int]$SpinSteps = 10,
        [int]$IdleTimeoutSec = 240
    )
    # opencode 1.17.x wants the model as provider/model. Accept a bare OVMS model id
    # (e.g. 'coder-30b') and qualify it with the local provider, matching open-coding.ps1
    # ('local/<id>'). Without this, '-m coder-30b' is parsed as provider='coder-30b',
    # model='' -> ProviderModelNotFoundError and a 100% no-op.
    if ($Model -and $Model -notmatch '/') { $Model = "local/$Model" }
    # Pin OpenCode's bash tool to git-bash, NOT WSL (#670 / opencode issue #8396): on this box
    # opencode's Windows shell detection prefers WSL when wsl.exe exists -> the "install WSL" prompt
    # + the bash command fails (no distro), wedging the agent's verify steps. git-bash makes bash work.
    $env:OPENCODE_GIT_BASH_PATH = 'C:\Program Files\Git\bin\bash.exe'
    if (-not $env:SHELL -or $env:SHELL -match '(?i)wsl|System32') { $env:SHELL = 'C:\Program Files\Git\bin\bash.exe' }
    $ocSrc = (Get-Command opencode -ErrorAction SilentlyContinue).Source
    if (-not $ocSrc) { return @{ TimedOut = $false; ExitCode = $null; LogPath = $LogPath; Seconds = 0; Error = 'opencode not found on PATH' } }
    # Run the REAL compiled executable DIRECTLY (no cmd /c). Going through cmd made the prompt
    # subject to shell parsing, so any prompt containing <, >, &, | (e.g. a task that says
    # "...returns 'Hello, <name>!'") was mis-read as redirection and the launch died instantly
    # with "The system cannot find the file specified" (0.1s, empty transcript). opencode.exe
    # is a real executable: Start-Process can CreateProcess it WITH redirection and -ArgumentList
    # passes the prompt as ONE literal argv entry with no shell in between. The npm shims
    # (opencode.cmd / .ps1) just exec this same exe with %*, so this is equivalent but safe.
    $ocExe = Join-Path (Split-Path $ocSrc -Parent) 'node_modules\opencode-ai\bin\opencode.exe'
    $useExe = Test-Path $ocExe
    # #762 FAIL-CLOSED spawn tripwire (mirrors the tail canary, but at the HEAD -- BEFORE any agent spawns).
    # opencode is an unpinned global npm package, so a silent autoupgrade or a tampered binary would run a
    # DIFFERENT release than the fleet was validated against. Verify the live binary against the committed pin
    # (configs/opencode-version-pin.json) and REFUSE the run on any drift -- never silently proceed. The
    # verdict is memoised per process, so this costs the ~1.5s SHA-256 once per dispatch, not once per
    # candidate. `opencode --version` merely prints a version (no agent, no repo, no model), so probing a
    # drifted binary is benign. On refusal we write a loud, cause-carrying line to the transcript and return a
    # no-op result (ExitCode=$null, PinRefused) so the dispatch parks with the reason -- fail-closed by design.
    $pinVerdict = Invoke-OpencodePinProbe -ExePath $(if ($useExe) { $ocExe } else { '' })
    if (-not $pinVerdict.Ok) {
        $line = "OPENCODE-PIN REFUSED: $($pinVerdict.Reason)"
        Set-Content -Path $LogPath -Value $line -ErrorAction SilentlyContinue
        Write-Host "  $line" -ForegroundColor Red
        return @{ TimedOut = $false; TimeoutReason = ''; Capped = $false; CappedReason = ''; ExitCode = $null; LogPath = $LogPath; Seconds = 0; Error = $line; PinRefused = $true }
    }
    $errPath = "$LogPath.err"
    # CRITICAL (verified 2026-06-18): headless `opencode run` BLOCKS at "init" reading an
    # inherited non-TTY stdin that never EOFs. Start-Process -NoNewWindow gives the child
    # the parent's stdin; with no real terminal opencode waits forever, so every unattended
    # run hung at init until the wall-clock kill (the whole reason the fleet/eval path never
    # produced output). Feeding an empty file as stdin makes that read hit EOF instantly and
    # the run proceeds. A/B proven: without it -> STALL >60s; with it -> completes in ~20s.
    $inPath = "$LogPath.stdin"
    Set-Content -Path $inPath -Value '' -NoNewline -ErrorAction SilentlyContinue
    # Give the agent's own python/pytest the worktree root on PYTHONPATH so its test
    # runs can import root-level modules (same as the verify gate). Without this the
    # agent fights a phantom ModuleNotFoundError and burns the whole timeout.
    $prevPP = $env:PYTHONPATH; $env:PYTHONPATH = $WorkDir
    # #1206 ARM (or actively DISARM) the coder's local docset lookup for THIS spawn. Start-Process
    # -NoNewWindow hands the child this process's environment block, so the manifest's decision
    # reaches opencode -- and the tool it shells out to -- by construction. Restored below.
    $researchEnv = Set-CoderResearchEnv -DriverPath 'stdin' -WorkDir $WorkDir -LogPath $LogPath
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    if ($useExe) {
        $parts = @('run', '--dir', $WorkDir, '-m', $Model)
        if ($JsonStepCap) { $parts += @('--format', 'json') }   # build only: drives the step-cap below
        if ($Agent) { $parts += @('--agent', $Agent) }
        $parts += $Prompt
        # Quote each arg so the prompt arrives as ONE argv entry (see ConvertTo-Win32Arg);
        # passing the array directly space-splits the prompt and breaks opencode's parser.
        $argString = ($parts | ForEach-Object { ConvertTo-Win32Arg $_ }) -join ' '
        $p = Start-Process -FilePath $ocExe -ArgumentList $argString -WorkingDirectory $WorkDir -PassThru -NoNewWindow `
             -RedirectStandardInput $inPath -RedirectStandardOutput $LogPath -RedirectStandardError $errPath
    } else {
        # Fallback if the compiled exe is not where expected: go through the .cmd shim via cmd
        # (WARNING: on this path a prompt containing <, >, & may be mis-parsed by cmd).
        $ocCmd = [System.IO.Path]::ChangeExtension($ocSrc, 'cmd'); if (-not (Test-Path $ocCmd)) { $ocCmd = 'opencode' }
        $parts = @('/c', $ocCmd, 'run', '--dir', $WorkDir, '-m', $Model)
        if ($JsonStepCap) { $parts += @('--format', 'json') }   # build only: drives the step-cap below
        if ($Agent) { $parts += @('--agent', $Agent) }
        $parts += $Prompt
        $argString = ($parts | ForEach-Object { ConvertTo-Win32Arg $_ }) -join ' '
        $p = Start-Process -FilePath $env:ComSpec -ArgumentList $argString -WorkingDirectory $WorkDir -PassThru -NoNewWindow `
             -RedirectStandardInput $inPath -RedirectStandardOutput $LogPath -RedirectStandardError $errPath
    }
    $null = $p.Handle   # PS 5.1: caching the handle makes $p.ExitCode readable after exit
    $timedOut = $false; $capped = $false; $cappedReason = ''; $timeoutReason = ''
    if (-not $JsonStepCap) {
        # Legacy path (e.g. the REVIEW judge): wall-clock only, plain-text output preserved so the
        # 'VERDICT: ...' parse still works. A looping review just hits the wall-clock + fails closed.
        $done = $p.WaitForExit($TimeoutSec * 1000)
        if (-not $done) {
            $timedOut = $true
            try { & taskkill.exe /PID $p.Id /T /F *> $null } catch {}
            try { $null = $p.WaitForExit(5000) } catch {}
        }
    } else {
        # Deny-independent loop bound (#670 run-3). TWO bounds, both gate-ELIGIBLE (not loop-blocked):
        #   (1) a generous HARD turn cap ($MaxSteps) -> bounds even a loop that keeps making edits;
        #   (2) a SEMANTIC spin detector -> $SpinSteps consecutive turns making NO file-mutating tool
        #       call (write/edit/patch) AFTER work began = the compulsive "re-verify done work" loop.
        #       Catches it EARLY without strangling a legit long task (whose edit-count keeps rising).
        # A cap is NOT a timeout (the work is already on disk) -> $capped, NOT $timedOut, so the GATE
        # (tests/verify/review) still decides the merge; the cap only makes the run gate-eligible.
        $deadlineUtc = (Get-Date).AddSeconds($TimeoutSec)
        $prevEdits = 0; $stepsAtLastEdit = 0
        # Progress-aware idle tracking (#682): reset $lastProgressUtc whenever a NEW
        # step_finish or edit appears; the pure Resolve-RunStopDecision then kills a stall
        # (idle) fast and lets a still-progressing build run to the generous ceiling.
        $lastPollSteps = 0; $lastPollEdits = 0
        $lastProgressUtc = Get-Date
        while ($true) {
            if ($p.WaitForExit(1500)) { break }   # the agent finished on its own
            $raw   = [string](Get-Content $LogPath -Raw -ErrorAction SilentlyContinue)
            $steps = ([regex]::Matches($raw, '"type":"step_finish"')).Count
            $edits = ([regex]::Matches($raw, '"tool":"(?:write|edit|patch|multiedit)"')).Count
            if ($edits -gt $prevEdits) { $prevEdits = $edits; $stepsAtLastEdit = $steps }
            $spinning = ($edits -ge 1) -and (($steps - $stepsAtLastEdit) -ge $SpinSteps)
            if (($steps -ge $MaxSteps) -or $spinning) {
                $capped = $true
                $cappedReason = if ($spinning -and ($steps -lt $MaxSteps)) { "spin: $SpinSteps turns with no edit after work began" } else { "hard cap: $MaxSteps turns" }
                try { & taskkill.exe /PID $p.Id /T /F *> $null } catch {}
                try { $null = $p.WaitForExit(5000) } catch {}
                break
            }
            # Progress-aware stop: idle (genuinely stuck -> kill fast) OR hard-ceiling backstop.
            $stop = Resolve-RunStopDecision -NowUtc (Get-Date) -LastProgressUtc $lastProgressUtc `
                -DeadlineUtc $deadlineUtc -PrevSteps $lastPollSteps -Steps $steps `
                -PrevEdits $lastPollEdits -Edits $edits -IdleTimeoutSec $IdleTimeoutSec
            $lastProgressUtc = $stop.LastProgressUtc
            $lastPollSteps = $steps; $lastPollEdits = $edits
            if ($stop.Stop) {
                $timedOut = $true
                $timeoutReason = $stop.Reason
                try { & taskkill.exe /PID $p.Id /T /F *> $null } catch {}
                try { $null = $p.WaitForExit(5000) } catch {}
                break
            }
        }
    }
    $sw.Stop()
    # #694 follow-up -- REAP the leg's process tree on EVERY exit path (normal included). The timeout/cap
    # branches above already `taskkill /T` while $p is alive, but a NORMAL exit killed nothing, so opencode's
    # node / language-server / sub-agent children could orphan and flush a late write into the NEXT leg's
    # tree -- the 20260710-152121 park (a trailing-newline normalize of Calculator.cs landed ~10 min after
    # the coder-fix leg, DURING the read-only review, tripping the #694 digest guard). Kill the leg's own
    # tree now so no straggler outlives it. Scoped + guarded (Stop-AgentProcessTree) -- only this worktree's
    # descendants, never a sibling dispatch or the live AO/OVMS; never throws into the run.
    try {
        $reapedPids = Stop-AgentProcessTree -RootPid $p.Id -WorkDir $WorkDir
        if ($reapedPids.Count -gt 0) {
            Add-Content -Path $LogPath -Value ("[reap #694] killed $($reapedPids.Count) straggling child process(es) on leg exit: $($reapedPids -join ', ')") -ErrorAction SilentlyContinue
        }
    } catch {}
    if ($null -eq $prevPP) { Remove-Item Env:\PYTHONPATH -ErrorAction SilentlyContinue } else { $env:PYTHONPATH = $prevPP }
    Restore-CoderResearchEnv -State $researchEnv   # #1206: own the arming vars for the spawn only
    # Fold stderr into the transcript log, then drop the temp err file.
    if (Test-Path $errPath) {
        Get-Content $errPath -ErrorAction SilentlyContinue | Add-Content $LogPath -ErrorAction SilentlyContinue
        Remove-Item $errPath -ErrorAction SilentlyContinue
    }
    # #762 load-line canary: verify both plugins actually wired into THIS run
    # (their stderr load-lines are now in the folded transcript). Visibility only
    # -- a failed canary writes a loud transcript line + the state marker, never
    # a run failure; wholly try-guarded so it can NEVER break an agent run.
    try {
        if (Test-Path $LogPath) {
            $canary = Test-PluginLoadLines -TranscriptContent ([System.IO.File]::ReadAllText($LogPath))
            Write-PluginCanaryVerdict -Verdict $canary -LogPath $LogPath
        }
    } catch { }
    # #762 per-run version LOG: record the exact opencode release THIS run used, into the transcript the
    # battery/morning report reads. The pre-spawn tripwire already validated it against the pin, so this is
    # the durable provenance line ("which binary produced this run"). Try-guarded -- never fails a run.
    try {
        Add-Content -Path $LogPath -Value ("[opencode-pin] run used opencode $($pinVerdict.LiveVersion) (pin $($pinVerdict.PinVersion); validated)") -ErrorAction SilentlyContinue
    } catch { }
    # #1206 per-run arming PROVENANCE into the same transcript the battery/morning report reads, so
    # the local-docset posture of a run is legible without cross-referencing the ledger. (Written
    # after the run because Start-Process TRUNCATES $LogPath when it redirects stdout into it.)
    try {
        Add-Content -Path $LogPath -Value ("[research-docs] armed=$($researchEnv.Armed) -- $($researchEnv.Reason)") -ErrorAction SilentlyContinue
    } catch { }
    # A step-cap means the agent DID the work then looped; treat it as completed (exit 0), not a
    # failure, so the gate runs + the auto-merge can fire (#670 run-3).
    $exit = if ($timedOut) { $null } elseif ($capped) { 0 } else { $p.ExitCode }
    return @{ TimedOut = $timedOut; TimeoutReason = $timeoutReason; Capped = $capped; CappedReason = $cappedReason; ExitCode = $exit; LogPath = $LogPath; Seconds = [math]::Round($sw.Elapsed.TotalSeconds, 1); Error = '' }
}

function Get-FleetDriverConfig {
    # #775 ACP-01: read the fleet driver manifest (configs/fleet-driver.json). Returns a
    # normalized object with .driver ('stdin'|'acp'), .containment ('off'|'restricted_account'),
    # and .acp settings. FAIL-SAFE to the DORMANT defaults on ANY problem (file absent, bad JSON,
    # missing keys) so the production stdin/operator-account path runs unless the manifest
    # DELIBERATELY says otherwise -- flag-dormant by construction (the 23:00 battery boots on this).
    # Memoised per process (the manifest does not change mid-dispatch); pass -Fresh to re-read.
    param([string]$ScriptRoot = $PSScriptRoot, [switch]$Fresh)
    if (-not $Fresh -and $script:_FleetDriverCfg) { return $script:_FleetDriverCfg }
    $default = [pscustomobject]@{
        driver = 'stdin'; containment = 'off'; research_docs = $false
        acp = [pscustomobject]@{ python = ''; blarai_root = 'C:/Users/mrbla/blarai'; idle_sec = 600; max_steps = 45; spin_steps = 10 }
    }
    try {
        # $env:BLARAI_FLEET_DRIVER_CONFIG overrides the manifest path for OFFLINE verify/tests only
        # (mirrors the coder-leg queue's BLARAI_CODER_LEG_ROOT hook); production leaves it unset, so the
        # live path is always <agentic-setup>\configs\fleet-driver.json.
        $path = if ($env:BLARAI_FLEET_DRIVER_CONFIG) { $env:BLARAI_FLEET_DRIVER_CONFIG } else { Join-Path (Split-Path $ScriptRoot -Parent) 'configs\fleet-driver.json' }
        if (-not (Test-Path $path)) { $script:_FleetDriverCfg = $default; return $default }
        $raw = Get-Content $path -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
        $driver = if ($raw.driver -in @('stdin','acp')) { $raw.driver } else { 'stdin' }
        $cont   = if ($raw.containment -in @('off','restricted_account')) { $raw.containment } else { 'off' }
        # #1206 research_docs -- DENY-BY-DEFAULT and strictly typed: ONLY a literal JSON boolean
        # true arms the coder's local docset lookup. A string "true", a 1, a typo or a missing key
        # all mean OFF. An ambiguous manifest must never arm a build-time capability by accident.
        $research = ($raw.research_docs -is [bool]) -and [bool]$raw.research_docs
        $acp = [pscustomobject]@{
            python      = [string]$raw.acp.python
            blarai_root = if ($raw.acp.blarai_root) { [string]$raw.acp.blarai_root } else { 'C:/Users/mrbla/blarai' }
            idle_sec    = if ($raw.acp.idle_sec)    { [int]$raw.acp.idle_sec }    else { 600 }
            max_steps   = if ($raw.acp.max_steps)   { [int]$raw.acp.max_steps }   else { 45 }
            spin_steps  = if ($raw.acp.spin_steps)  { [int]$raw.acp.spin_steps }  else { 10 }
        }
        $cfg = [pscustomobject]@{ driver = $driver; containment = $cont; research_docs = $research; acp = $acp }
        $script:_FleetDriverCfg = $cfg
        return $cfg
    } catch {
        # A manifest we cannot read must never enable a non-default posture.
        $script:_FleetDriverCfg = $default
        return $default
    }
}

function Get-ResearchArmingVerdict {
    # #1206 PURE decision half (mirrors Get-OpencodePinVerdict): does THIS coder spawn get the
    # local docset lookup, and WHY? Injectable + never throws, so the whole truth table is
    # unit-testable with scripted inputs -- no config file, no opencode, no model.
    #
    # The manifest is the ONLY authority, and this verdict is ADVISORY: the tool itself re-reads the
    # same manifest at the point of use (tools/search_docs.py resolve_arming), so a coder process
    # that never met this function still resolves the same answer. This exists to decide what goes
    # in the arming ledger and whether to pin BLARAI_REPO -- not to grant the capability. The two
    # implementations are held in agreement by verify-research-arming.ps1 section J.
    #
    # $AmbientValue is whatever BLARAI_RESEARCH_DOCS already held in the spawning process. It can
    # never arm anything. A TRUTHY leftover is stale arming-era noise and gets cleared; an explicit
    # FALSY value is an operator emergency stop and is propagated to the child untouched.
    # Returns @{ Armed=[bool]; Reason=[string]; AmbientCleared=[bool]; ForcedOff=[bool] }.
    param(
        [pscustomobject]$Config,
        [string]$AmbientValue = ''
    )
    $trimmed = ([string]$AmbientValue).Trim()
    $forcedOff = $trimmed -and ($trimmed.ToLowerInvariant() -in @('0','false','no','off'))
    $staleTruthy = $trimmed -and (-not $forcedOff)
    if ($forcedOff) {
        return @{ Armed = $false; AmbientCleared = $false; ForcedOff = $true
                  Reason = "FORCED OFF by an operator emergency stop (BLARAI_RESEARCH_DOCS='$trimmed'); propagated to the child" }
    }
    if ($null -eq $Config) {
        return @{ Armed = $false; AmbientCleared = $staleTruthy; ForcedOff = $false
                  Reason = 'no fleet-driver manifest -- research docs stay DORMANT (fail-safe)' }
    }
    if (($Config.research_docs -is [bool]) -and $Config.research_docs) {
        $reason = 'armed by configs/fleet-driver.json research_docs=true'
        if ($staleTruthy) { $reason += " -- cleared a stale BLARAI_RESEARCH_DOCS='$trimmed' (the manifest, not the environment, arms this)" }
        return @{ Armed = $true; AmbientCleared = $staleTruthy; ForcedOff = $false; Reason = $reason }
    }
    $seen = if ($null -eq $Config.research_docs) { '<absent>' } else { "'$($Config.research_docs)'" }
    $reason = "DORMANT: configs/fleet-driver.json research_docs=$seen (only the JSON boolean true arms it)"
    if ($staleTruthy) {
        $reason += " -- CLEARED a stale BLARAI_RESEARCH_DOCS='$trimmed' from the child environment"
    }
    return @{ Armed = $false; Reason = $reason; AmbientCleared = $staleTruthy; ForcedOff = $false }
}

function Write-ResearchArmingRecord {
    # #1206 durable arming evidence. One append-only JSONL record per coder spawn, on BOTH driver
    # paths, so "was the local docset lookup armed for THIS run" is answerable after the fact
    # instead of inferred. It is the companion to state/research-usage.jsonl (which the CLI itself
    # writes, one record per lookup the coder actually MADE): together they separate the three
    # states that otherwise look identical in a transcript -- not armed / armed but never called /
    # armed and called. Override the path with $env:BLARAI_RESEARCH_ARMING_LOG (verify + tests).
    #
    # Fail-SOFT but never silent: this is EVIDENCE, not the control. The control is the env
    # mutation in Set-CoderResearchEnv, which is unconditional and cannot degrade. A ledger write
    # that fails says so loudly on the console rather than aborting a coder run mid-build.
    param(
        [bool]$Armed, [string]$Reason, [string]$DriverPath,
        [string]$WorkDir = '', [string]$LogPath = '', [string]$Interpreter = '',
        [string]$ScriptRoot = $PSScriptRoot
    )
    try {
        $path = if ($env:BLARAI_RESEARCH_ARMING_LOG) { $env:BLARAI_RESEARCH_ARMING_LOG }
                else { Join-Path (Split-Path $ScriptRoot -Parent) 'state\research-arming.jsonl' }
        $dir = Split-Path $path -Parent
        if ($dir -and -not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
        $now = [DateTime]::UtcNow
        $rec = [pscustomobject]@{
            ts          = [Math]::Round(($now - [DateTime]'1970-01-01').TotalSeconds, 6)  # correlates with research-usage.jsonl
            iso         = $now.ToString('yyyy-MM-ddTHH:mm:ssZ')
            driver_path = $DriverPath      # 'stdin' | 'acp'
            armed       = $Armed
            reason      = $Reason
            workdir     = $WorkDir
            log         = $LogPath
            interpreter = $Interpreter
        }
        Add-Content -Path $path -Value ($rec | ConvertTo-Json -Compress -Depth 4) -Encoding UTF8 -ErrorAction Stop
    } catch {
        Write-Host "  [research-docs] WARNING: could not append the arming record ($($_.Exception.Message)) -- the run continues, the evidence does not" -ForegroundColor Yellow
    }
}

function Set-CoderResearchEnv {
    # #1206 the pre-spawn seam. It does NOT grant the capability -- tools/search_docs.py resolves the
    # same committed manifest for itself on every call, so a coder process that never passed through
    # here still gets the right answer (a reboot, a crash relaunch, a hand-started session). What
    # this does is the part the child CANNOT do for itself:
    #   1. BANK the arming decision per spawn (state/research-arming.jsonl), so "was it armed for
    #      that run" is answerable months later instead of reconstructed.
    #   2. PIN BLARAI_REPO / BLARAI_RESEARCH_PYTHON from the manifest when armed, so an armed run
    #      resolves the same substrate + interpreter every time instead of whatever is on PATH.
    #   3. CLEAR a stale truthy BLARAI_RESEARCH_DOCS. Under the old contract that value armed things;
    #      it no longer can, and leaving it would misdescribe the run to anyone reading the child's
    #      environment. An explicit FALSY value is the operator's emergency stop and is PRESERVED --
    #      a deliberate kill must reach the coder's tools, not be tidied away by the launcher.
    # Returns a state token for Restore-CoderResearchEnv.
    param(
        [Parameter(Mandatory)][ValidateSet('stdin','acp')][string]$DriverPath,
        [string]$WorkDir = '', [string]$LogPath = '',
        [string]$ScriptRoot = $PSScriptRoot
    )
    $state = @{
        PrevDocs   = $env:BLARAI_RESEARCH_DOCS
        PrevRepo   = $env:BLARAI_REPO
        PrevPython = $env:BLARAI_RESEARCH_PYTHON
        Armed      = $false; Reason = ''; Interpreter = ''; ForcedOff = $false
    }
    $cfg = $null
    try { $cfg = Get-FleetDriverConfig -ScriptRoot $ScriptRoot } catch { $cfg = $null }
    $verdict = Get-ResearchArmingVerdict -Config $cfg -AmbientValue ([string]$state.PrevDocs)
    if ($verdict.AmbientCleared) { Remove-Item Env:\BLARAI_RESEARCH_DOCS -ErrorAction SilentlyContinue }
    if ($verdict.Armed) {
        if ($cfg.acp.blarai_root) { $env:BLARAI_REPO = [string]$cfg.acp.blarai_root }
        if ($cfg.acp.python -and (Test-Path $cfg.acp.python)) {
            $env:BLARAI_RESEARCH_PYTHON = [string]$cfg.acp.python
            $state.Interpreter = [string]$cfg.acp.python
        }
    }
    $state.Armed = [bool]$verdict.Armed
    $state.Reason = [string]$verdict.Reason
    $state.ForcedOff = [bool]$verdict.ForcedOff
    Write-ResearchArmingRecord -Armed $state.Armed -Reason $state.Reason -DriverPath $DriverPath `
        -WorkDir $WorkDir -LogPath $LogPath -Interpreter $state.Interpreter -ScriptRoot $ScriptRoot
    if ($state.Armed) {
        Write-Host "  [research-docs] ARMED for this run -- $($state.Reason)" -ForegroundColor DarkCyan
    } elseif ($verdict.AmbientCleared -or $verdict.ForcedOff) {
        Write-Host "  [research-docs] $($state.Reason)" -ForegroundColor Yellow
    }
    return $state
}

function Restore-CoderResearchEnv {
    # #1206 put the spawning process back exactly as it was. The variables are process-global and
    # this same console runs the gate, the review and sibling legs; owning them only for the spawn
    # keeps the arming decision per-run instead of leaking sideways.
    param($State)
    if ($null -eq $State) { return }
    foreach ($pair in @(
        @{ Name = 'BLARAI_RESEARCH_DOCS';   Value = $State.PrevDocs },
        @{ Name = 'BLARAI_REPO';            Value = $State.PrevRepo },
        @{ Name = 'BLARAI_RESEARCH_PYTHON'; Value = $State.PrevPython }
    )) {
        if ($null -eq $pair.Value) { Remove-Item "Env:\$($pair.Name)" -ErrorAction SilentlyContinue }
        else { Set-Item "Env:\$($pair.Name)" -Value $pair.Value -ErrorAction SilentlyContinue }
    }
}

function Invoke-AcpCoderRun {
    # #775 ACP-01: drive ONE coder build through the persistent opencode-acp session via the Python
    # client (blarai/tools/dispatch_harness/acp_coder.py, run under a Python 3.14 + agent-client-protocol
    # interpreter). Returns @{ Ok=[bool]; Result=<Invoke-AgentRun-shaped hashtable>; Reason=[string] }.
    #   Ok=$true  -> .Result is the run's result contract (surface it verbatim).
    #   Ok=$false -> the ACP client could NOT run pre-prompt (no interpreter, SDK import, or handshake
    #                failure) and the caller must FALL BACK to stdin for this run (ACP-01 §2 config-fallback).
    # A mid-run error (the prompt started then the SDK raised) is NOT a fallback -- it returns Ok=$true with
    # an errored .Result so the gate parks it rather than silently RE-driving the coder under stdin.
    param(
        [Parameter(Mandatory)][string]$WorkDir,
        [Parameter(Mandatory)][string]$Model,
        [Parameter(Mandatory)][string]$Prompt,
        [Parameter(Mandatory)][string]$LogPath,
        [Parameter(Mandatory)][pscustomobject]$Acp,
        [int]$TimeoutSec = 3600,
        [int]$IdleTimeoutSec = 600,
        [int]$MaxSteps = 45,
        [int]$SpinSteps = 10
    )
    $py = $Acp.python
    if (-not $py -or -not (Test-Path $py)) {
        return @{ Ok = $false; Reason = "no ACP python interpreter provisioned (acp.python='$py'); falling back to stdin" }
    }
    $blarRoot = if ($Acp.blarai_root) { $Acp.blarai_root } else { 'C:/Users/mrbla/blarai' }
    # Prompt + envelope ride files (never argv): the prompt may contain <, >, & etc., and the envelope is
    # JSON the shim parses -- exactly why Invoke-AgentRun feeds a stdin file, mirrored here.
    $promptFile = "$LogPath.acp-prompt.txt"
    $resultJson = "$LogPath.acp-result.json"
    try {
        Set-Content -Path $promptFile -Value $Prompt -NoNewline -Encoding UTF8 -ErrorAction Stop
    } catch {
        return @{ Ok = $false; Reason = "could not stage ACP prompt file: $($_.Exception.Message); falling back to stdin" }
    }
    $ideal = if ($IdleTimeoutSec -gt 0) { $IdleTimeoutSec } elseif ($Acp.idle_sec) { [int]$Acp.idle_sec } else { 600 }
    $argList = @(
        '-m', 'tools.dispatch_harness.acp_coder',
        '--workdir', $WorkDir,
        '--model', $Model,
        '--log-path', $LogPath,
        '--prompt-file', $promptFile,
        '--timeout-sec', "$TimeoutSec",
        '--idle-sec', "$ideal",
        '--max-steps', "$MaxSteps",
        '--spin-steps', "$SpinSteps",
        '--result-json', $resultJson
    )
    # The client must import blarai's `shared`/`tools` packages -> run WITH the blarai root on PYTHONPATH
    # and cwd there, matching how the fleet already invokes blarai python (run-battery-night.ps1).
    $prevPP = $env:PYTHONPATH; $env:PYTHONPATH = $blarRoot
    # #1206 ARM (or actively DISARM) the coder's local docset lookup for THIS spawn -- the ACP path
    # needs it as much as the stdin one: this interpreter spawns opencode-acp, which spawns the tool.
    # The env travels down that whole chain by inheritance, so the decision has to be made HERE, at
    # the process boundary, not in whatever shell launched the orchestrator. Restored on every exit.
    $researchEnv = Set-CoderResearchEnv -DriverPath 'acp' -WorkDir $WorkDir -LogPath $LogPath
    try {
        # A generous outer ceiling: the client enforces its OWN idle/step/overall bounds and tree-kills;
        # this WaitForExit is only a backstop against a wedged interpreter that never writes the envelope.
        $outerSec = [int]($TimeoutSec + 300)
        $p = Start-Process -FilePath $py -ArgumentList $argList -WorkingDirectory $blarRoot -PassThru -NoNewWindow -ErrorAction Stop
        $null = $p.Handle
        if (-not $p.WaitForExit($outerSec * 1000)) {
            try { & taskkill.exe /PID $p.Id /T /F *> $null } catch {}
            try { $null = $p.WaitForExit(5000) } catch {}
            if ($null -eq $prevPP) { Remove-Item Env:\PYTHONPATH -ErrorAction SilentlyContinue } else { $env:PYTHONPATH = $prevPP }
            Restore-CoderResearchEnv -State $researchEnv
            return @{ Ok = $false; Reason = "ACP client exceeded the outer ceiling (${outerSec}s) and was killed; falling back to stdin" }
        }
    } catch {
        if ($null -eq $prevPP) { Remove-Item Env:\PYTHONPATH -ErrorAction SilentlyContinue } else { $env:PYTHONPATH = $prevPP }
        Restore-CoderResearchEnv -State $researchEnv
        return @{ Ok = $false; Reason = "ACP client failed to launch: $($_.Exception.Message); falling back to stdin" }
    }
    if ($null -eq $prevPP) { Remove-Item Env:\PYTHONPATH -ErrorAction SilentlyContinue } else { $env:PYTHONPATH = $prevPP }
    Restore-CoderResearchEnv -State $researchEnv
    if (-not (Test-Path $resultJson)) {
        return @{ Ok = $false; Reason = 'ACP client wrote no result envelope; falling back to stdin' }
    }
    try {
        $envelope = Get-Content $resultJson -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
    } catch {
        return @{ Ok = $false; Reason = "ACP result envelope unreadable: $($_.Exception.Message); falling back to stdin" }
    } finally {
        Remove-Item $resultJson -ErrorAction SilentlyContinue
        Remove-Item $promptFile -ErrorAction SilentlyContinue
    }
    if ($envelope.fallback_to_stdin) {
        return @{ Ok = $false; Reason = "ACP client signalled fallback (phase=$($envelope.phase)): $($envelope.error)" }
    }
    if (-not $envelope.result) {
        return @{ Ok = $false; Reason = 'ACP envelope carried no result; falling back to stdin' }
    }
    # Rehydrate the result contract as a hashtable byte-compatible with Invoke-AgentRun's return.
    $r = $envelope.result
    $result = @{
        TimedOut = [bool]$r.TimedOut; TimeoutReason = [string]$r.TimeoutReason
        Capped = [bool]$r.Capped; CappedReason = [string]$r.CappedReason
        ExitCode = $r.ExitCode   # JSON null -> $null, matching Invoke-AgentRun
        LogPath = [string]$r.LogPath; Seconds = [double]$r.Seconds; Error = [string]$r.Error
    }
    return @{ Ok = $true; Result = $result; Reason = "acp phase=$($envelope.phase)" }
}

function Invoke-CoderDriver {
    # #775 ACP-01 SEAM: the single point the candidate loop calls to DRIVE + WATCH the coder. It selects
    # the driver from configs/fleet-driver.json and returns the SAME result contract Invoke-CandidateBuild
    # already consumes. With driver='stdin' (the DEFAULT), this is BYTE-IDENTICAL to the historical call --
    # it delegates to Invoke-AgentRun with the exact same arguments. With driver='acp' it drives the
    # persistent opencode-acp session via the Python client, and FALLS BACK to the identical stdin call on
    # any pre-prompt ACP failure (import/handshake/no-interpreter). ACP replaces only HOW the coder is
    # driven; the gate/selection/merge are untouched.
    param(
        [Parameter(Mandatory)][string]$WorkDir,
        [Parameter(Mandatory)][string]$Model,
        [Parameter(Mandatory)][string]$Prompt,
        [Parameter(Mandatory)][string]$LogPath,
        [int]$TimeoutSec = 1800,
        [int]$IdleTimeoutSec = 240,
        [string]$ScriptRoot = $PSScriptRoot
    )
    $cfg = Get-FleetDriverConfig -ScriptRoot $ScriptRoot
    if ($cfg.driver -eq 'acp') {
        try {
            $mdl = if ($Model -and $Model -notmatch '/') { "local/$Model" } else { $Model }
            # The ACP path uses its OWN semantic idle bound (acp.idle_sec, default 600 -- RAISED from
            # the spike's 120 after the #790 A/B finding that a 120 s idle watchdog false-killed ~84%
            # of 30B candidates: the "no session/update" signal cannot tell a slow-generating 30B
            # (first-token starvation / long thinking bursts) from a genuinely wedged one; calibrated
            # in shared/timeout_registry.py ACP_IDLE_TIMEOUT_S), NOT the stdin transcript-idle
            # ($IdleTimeoutSec, 240): it is a DIFFERENT number by design. This $cfg.acp.idle_sec is
            # the LIVE per-run value the nightly battery threads to acp_coder.py --idle-sec.
            $acpIdle = if ($cfg.acp.idle_sec) { [int]$cfg.acp.idle_sec } else { 600 }
            $acp = Invoke-AcpCoderRun -WorkDir $WorkDir -Model $mdl -Prompt $Prompt -LogPath $LogPath `
                -Acp $cfg.acp -TimeoutSec $TimeoutSec -IdleTimeoutSec $acpIdle `
                -MaxSteps ([int]$cfg.acp.max_steps) -SpinSteps ([int]$cfg.acp.spin_steps)
            if ($acp.Ok) {
                Write-Host "  [driver=acp] $($acp.Reason)" -ForegroundColor DarkCyan
                return $acp.Result
            }
            Write-Host "  [driver=acp] $($acp.Reason)" -ForegroundColor Yellow
        } catch {
            Write-Host "  [driver=acp] error, falling back to stdin: $($_.Exception.Message)" -ForegroundColor Yellow
        }
    }
    # stdin (default) OR an ACP pre-prompt fallback -> the byte-identical production path.
    return Invoke-AgentRun -WorkDir $WorkDir -Model $Model -Prompt $Prompt -LogPath $LogPath `
        -TimeoutSec $TimeoutSec -IdleTimeoutSec $IdleTimeoutSec -JsonStepCap
}

function Test-IsSamplingTerminal {
    # BEST-OF-N terminal classification (#740/W7): does THIS candidate's stop END sampling (terminal --
    # never resampled), or is it a random per-build slip that best-of-N should route AROUND with a fresh
    # independent candidate? This is the SINGLE SOURCE OF TRUTH the injected -StopSampling predicate
    # delegates to (new-agent-task.ps1, both the sequential + concurrent paths) AND the reason
    # Test-ShouldResample honours, so the two layers agree. TERMINAL when:
    #   - SecretBlocked      : a potential leak must be SURFACED to a human, never sampled-away (unchanged).
    #   - a NON-idle timeout : a wall-clock CEILING hit is a genuine runaway (a productive-but-too-slow or
    #                          wedged coder; expensive to retry). An EMPTY/UNKNOWN reason is treated as
    #                          ceiling -- the SAFE default (a pre-#740 Run object, or a reason we cannot read,
    #                          must NOT silently become resample-eligible).
    #   - NoChangeDeclared   : #1049 candidate (b) -- the coder EXPLICITLY declared "NO CHANGE NEEDED"
    #                          (offered on retry prompts only) after a verified zero-diff attempt. That is
    #                          an ANSWER, not a slip: a fresh candidate re-asks the same question under the
    #                          same produce-something pressure, and the measured outcome of that pressure
    #                          is a manufactured junk diff that MERGES (green gates cannot tell a comment
    #                          scribble from work -- dispatch-quality-ledger 2026-07-14, waves 2/3).
    # NOT terminal (resample-eligible):
    #   - an IDLE-reason timeout : the coder read a couple files then went silent, making ZERO changes before
    #                          the progress-aware idle breaker (#682) killed it FAST. That is a RANDOM slip --
    #                          precisely what best-of-N's fresh, independent samples exist to route around
    #                          (the 2026-07-03 no-op dispatches: candidate 1 idle-stalled, collapsing N=3 to
    #                          N=1 and no-op'ing the whole run, while a re-queued fresh attempt merged --
    #                          docs/no-op-diagnosis-2026-07.md). Bounded by the EXISTING MaxCandidates budget
    #                          (no new budget): worst case is N x idle_timeout, then the run parks.
    #   - a #1074 CAPTURE FAULT : DELIBERATELY NOT TERMINAL, and this is load-bearing -- do not "fix" it by
    #                          adding a -GitFailed terminal here. A capture fault is per-CANDIDATE and is
    #                          frequently a per-candidate SLIP, not a repo-wide verdict: the batch's
    #                          worktrees are created in a loop (new-agent-task -RunBatch), and a candidate
    #                          whose `git worktree add` silently failed then runs the whole pipeline
    #                          against a directory that does not exist -- where `git add -A` returns 128
    #                          (MEASURED) and every later git read returns 128 too. Making that terminal
    #                          lets ONE bad workspace stop the entire best-of-N run, where today the run
    #                          degrades to N-1 candidates and still merges a winner. That is the exact
    #                          shape of the idle-stall carve-out directly above, and it is a QUALITY
    #                          regression (fewer chances to merge good work) rather than a safety gain.
    #                          The fault stays LOUD by every other route -- it disqualifies the candidate
    #                          (Test-IsCandidateGreen), sinks its rank below every real attempt
    #                          (Get-CandidateRank), hard-blocks the merge (Test-ShouldMerge), stops the
    #                          review-FIX loop, and reports ERRORED carrying git's own message -- so
    #                          nothing is swallowed by letting sampling continue. Cost is bounded by the
    #                          EXISTING MaxCandidates budget, exactly as the idle carve-out is.
    # Pure + ASCII; unit-tested without a model (verify-bestofn.ps1 / verify-bestofn-concurrent.ps1 /
    # verify-nochange-outcome.ps1 / verify-git-capture-honesty.ps1). $NoChangeDeclared defaults $false so
    # every pre-#1049 caller/test is byte-identical.
    param(
        [bool]$TimedOut,
        [string]$TimeoutReason = '',
        [bool]$SecretBlocked,
        [bool]$NoChangeDeclared = $false
    )
    if ($SecretBlocked) { return $true }
    if ($NoChangeDeclared) { return $true }
    if ($TimedOut) { return ("$TimeoutReason".Trim().ToLower() -ne 'idle') }
    return $false
}

function Test-ShouldResample {
    # POLICY: should the build be RESAMPLED (re-run from a CLEAN worktree) because the
    # verify gate FAILED? Retry ONLY a real test/verify FAILURE (or a #740/W7 idle stall -- see below),
    # and only while attempts remain. NEVER resample a wall-clock CEILING timeout (the model is genuinely
    # too slow / wedged, not slipping) or a secret-block (a potential leak must be surfaced to a human,
    # never retried away). A high-variance small model makes ~1 random slip per full implementation, so
    # resampling a fresh attempt converges it toward a passing build. Pure + injectable so it is
    # unit-tested without a model (see scripts\verify-retry.ps1).
    #
    # #740/W7: an IDLE-reason timeout is NOT terminal -- it is a random per-build slip (the coder went silent
    # before making a change) treated like a build/test FAILURE: resample-eligible, bounded by the SAME
    # $MaxAttempts budget. A CEILING timeout, an empty/unknown reason (-> ceiling, the safe default), and a
    # secret-block stay terminal. The terminal call is the shared Test-IsSamplingTerminal so this inner
    # retry and the best-of-N -StopSampling classification never diverge. $TimeoutReason defaults to '' so
    # every existing caller (which passes none) keeps the pre-change "any timeout is terminal" behaviour
    # byte-identical -- the idle carve-out only fires when a caller EXPLICITLY passes -TimeoutReason 'idle'.
    param(
        [string]$VerifyResult,
        [string]$TestResult,
        [bool]$TimedOut,
        [bool]$SecretBlocked,
        [int]$Attempt,
        [int]$MaxAttempts,
        [string]$TimeoutReason = ''
    )
    if (Test-IsSamplingTerminal -TimedOut $TimedOut -TimeoutReason $TimeoutReason -SecretBlocked $SecretBlocked) { return $false }
    if ($Attempt -ge $MaxAttempts) { return $false }
    $idleStall = $TimedOut -and ("$TimeoutReason".Trim().ToLower() -eq 'idle')
    return ($idleStall -or ($VerifyResult -eq 'fail') -or ($TestResult -eq 'fail'))
}

function Resolve-RunStopDecision {
    # PURE policy (#682): given the latest monitor poll's progress counters + timing,
    # decide whether to STOP the coder run, and WHY. Separated from Invoke-AgentRun's
    # process mechanics so every branch is unit-testable mutation-resistantly with fixed
    # datetimes (no real process, no real clock). See scripts\verify-runtimeout.ps1.
    #
    # The old build path used a SINGLE absolute wall-clock: it guillotined a PRODUCTIVE-
    # but-slow coder at the deadline AND let a HUNG run bleed the whole budget. This splits
    # the stop:
    #   - 'idle'    : no NEW step_finish AND no NEW edit for IdleTimeoutSec -> genuinely
    #                 stuck (wedged / frozen / server dead). Kill FAST.
    #   - 'ceiling' : absolute hard-ceiling backstop (NowUtc >= DeadlineUtc) so even a
    #                 trickle-progress run cannot run unbounded.
    # A run still making progress (steps OR edits advanced since the last poll) is NOT
    # stopped here -> the fix for "we're killing it too soon". Progress resets the idle
    # clock by moving LastProgressUtc to NowUtc. IdleTimeoutSec <= 0 disables the idle
    # check (ceiling-only, the legacy behaviour).
    #
    # Returns @{ Stop=[bool]; Reason='idle'|'ceiling'|''; LastProgressUtc=[datetime]; Progressed=[bool] }
    param(
        [Parameter(Mandatory)][datetime]$NowUtc,
        [Parameter(Mandatory)][datetime]$LastProgressUtc,
        [Parameter(Mandatory)][datetime]$DeadlineUtc,
        [int]$PrevSteps = 0,
        [int]$Steps = 0,
        [int]$PrevEdits = 0,
        [int]$Edits = 0,
        [int]$IdleTimeoutSec = 240
    )
    # Progress = any NEW step_finish or any NEW edit since the previous poll. Counters are
    # monotonic non-decreasing, so "advanced" == current > previous.
    $progressed = ($Steps -gt $PrevSteps) -or ($Edits -gt $PrevEdits)
    $newLastProgressUtc = if ($progressed) { $NowUtc } else { $LastProgressUtc }
    $stop = $false; $reason = ''
    if ($NowUtc -ge $DeadlineUtc) {
        $stop = $true; $reason = 'ceiling'
    } elseif ($IdleTimeoutSec -gt 0 -and (($NowUtc - $newLastProgressUtc).TotalSeconds -ge $IdleTimeoutSec)) {
        $stop = $true; $reason = 'idle'
    }
    return @{ Stop = $stop; Reason = $reason; LastProgressUtc = $newLastProgressUtc; Progressed = $progressed }
}

function Format-VerifyError {
    # ERROR-FEEDBACK: collect the FAILING verify checks' captured build output into one string,
    # to feed back to the coder so the next attempt FIXES the specific error instead of blind-
    # resampling (which repeats a systematic bug, e.g. a missing 'using' the model keeps omitting).
    # Returns '' when nothing failed, so the caller falls back to a fresh resample. Defensive: a
    # null/empty list or a check missing .detail never throws (this runs inside the build loop).
    # Pure + injectable so it is unit-tested without a model (see scripts\verify-errorfeedback.ps1).
    param($Checks)
    $failed = @($Checks | Where-Object { $_ -and $_.status -eq 'fail' })
    if ($failed.Count -eq 0) { return '' }
    ($failed | ForEach-Object {
        $d = if ($null -ne $_.detail) { [string]$_.detail } else { '' }
        "[$($_.name)]`n$d"
    }) -join "`n`n"
}

function Add-ReviewFeedback {
    # REVIEW-FEEDBACK: augment the coder's prompt with the code reviewer's FIX-FIRST findings, so a
    # building-but-flawed attempt gets FIXED (logic/completeness the build gate can't see) instead of
    # parked. Returns the prompt UNCHANGED when there are no concerns. Pure + unit-tested.
    param([string]$Prompt, [string]$ReviewConcerns)
    if ([string]::IsNullOrWhiteSpace($ReviewConcerns)) { return $Prompt }
    $Prompt + "`n`n--- A CODE REVIEW OF YOUR PREVIOUS ATTEMPT ASKED FOR FIXES (it builds, but is not done) ---`n" +
        "Address these review findings, then make sure it still builds:`n`n" +
        $ReviewConcerns +
        "`n`nMake the SMALLEST changes to the EXISTING code that resolve the findings above. Do NOT start over or delete working code."
}

function Test-ShouldRunReview {
    # #687 (LA-approved 2026-06-26): should the per-pass LLM self-review run at all this pass? NO when
    # the deterministic gates are GREEN (verify=pass AND test=pass) -- the gate already decides the
    # merge (Test-ShouldMerge merges green work regardless of the review verdict), so running the slow,
    # over-flagging, sometimes-HANGING 30B self-review here is pure waste AND a stall risk on green
    # work (it blocked the design loop twice: a sticky FIX-FIRST timeout, then a 30B generation hang).
    # The cross-model 14B critic reviews ONCE post-merge instead (the accurate, swap-economical signal).
    # Also NO when there are no changes, or a gate FAILED (the merge is hard-blocked regardless). YES
    # otherwise -- changes present, no gate FAILURE, but the gates are NOT both green (e.g. a build-only
    # ecosystem with test=none, where the review verdict genuinely decides the merge). Pure + ASCII;
    # unit-tested without a model.
    # #1195 -- the skip's premise, named. "test=pass" was read as "an exam passed". On a flat-queue run
    # there is no sealed oracle, so it means the tests the CODER WROTE FOR ITS OWN CODE: the candidate set
    # the exam, sat it, marked it, and the harness reported the mark as evidence (2026-07-29 merged a unit
    # converter whose ounce factor is wrong by 2.5x; its own test named 0.0353 in a comment and then
    # asserted 0.01 <= result <= 0.1, a band widened around a known-wrong answer). $CoderTestHard is the
    # count of PROVEN defects in that exam -- shared/fleet/coder_test_qa.py's HARD set only: a property
    # test that provably never executed, and a test that provably cannot fail. A proven defect WITHDRAWS
    # the green-gate skip so the reviewer actually looks at the exam. It does NOT block the merge (that
    # stays Test-ShouldMerge's call -- a scanner that could park an unattended night would be a second
    # merge authority). SOFT/heuristic findings deliberately never reach here: forcing the slow,
    # over-flagging, sometimes-hanging 30B on prose-matching would re-import the very stall this skip
    # exists to prevent. Default 0 => byte-identical pre-#1195 behaviour.
    param([bool]$HasChanges, [string]$VerifyResult = 'none', [string]$TestResult = 'none', [int]$CoderTestHard = 0)
    if (-not $HasChanges) { return $false }
    if (($VerifyResult -eq 'fail') -or ($TestResult -eq 'fail')) { return $false }
    $gatesGreen = ($VerifyResult -eq 'pass') -and ($TestResult -eq 'pass')
    if ($gatesGreen -and ($CoderTestHard -gt 0)) { return $true }
    return (-not $gatesGreen)
}

#: #1195 -- the statuses Invoke-CoderTestQa can return. Kept as a named set because the whole point of
#: this layer is that "the scan found nothing" and "the scan did not happen" are DIFFERENT FACTS, and a
#: caller that collapses them re-creates the defect one layer up.
#: #1416 adds 'not-covered': the candidate WROTE an exam and this grader cannot read its
#: language. Deliberately distinct from 'no-tests' (there was no exam) and from
#: 'unavailable' (the scanner broke) -- three different facts that were one string, which is
#: how "it wrote no exam for its own work" came to be published against 55 website
#: deliveries holding real .test.js files.
$script:CoderTestQaStatuses = @('clean', 'findings', 'no-tests', 'not-covered', 'disabled', 'unavailable', 'not-applicable')

function Get-JsonField {
    # #1201: read one field off a ConvertFrom-Json object WITHOUT assuming it is there. A bare
    # `$obj.name` read of an absent property returns $null on a default host but THROWS under the
    # `Set-StrictMode -Version Latest` that ao-ownership-lib.ps1 puts in scope -- and "the field is
    # absent" is precisely the condition the cross-repo version-skew guard has to be able to observe.
    # An exception there would turn a detected skew into a crashed dispatch.
    param($Object, [Parameter(Mandatory)][string]$Name, $Default = '')
    if ($null -eq $Object) { return $Default }
    $prop = $Object.PSObject.Properties[$Name]
    if (-not $prop) { return $Default }
    return $prop.Value
}

function Get-ResultField {
    # #1416: read a field off a RESULT OBJECT without assuming it is there, for BOTH shapes a
    # result can take. Get-JsonField is the sibling of this and is NOT interchangeable with it:
    # it reads `$Object.PSObject.Properties[$Name]`, which sees a PSCustomObject's properties
    # (what ConvertFrom-Json produces) but NOT a Hashtable's KEYS -- and New-CoderTestQaResult
    # returns a Hashtable. Using Get-JsonField here returned the default for every field that
    # was actually present, turning a defensive read into a silencer: the language breakdown
    # rendered as absent on results that carried it. Caught by the positive-direction assertion
    # (verify-coder-test-qa.ps1 SM2), which exists because a guard that never throws and never
    # answers looks exactly like a guard that works.
    #
    # The bare `$Object.Name` read is not an option either: under Set-StrictMode -Version Latest
    # it THROWS on an absent property, which is the crash this whole helper exists to prevent.
    param($Object, [Parameter(Mandatory)][string]$Name, $Default = $null)
    if ($null -eq $Object) { return $Default }
    if ($Object -is [System.Collections.IDictionary]) {
        if ($Object.Contains($Name)) { return $Object[$Name] }
        return $Default
    }
    $prop = $Object.PSObject.Properties[$Name]
    if (-not $prop) { return $Default }
    return $prop.Value
}

function New-CoderTestQaResult {
    # The empty/degraded result shape. Every field present at every exit, so no caller ever reads a
    # missing property as a zero. Measured=$false means NO VERDICT WAS OBTAINED -- never "nothing found".
    param([string]$Status = 'unavailable', [string]$Detail = '')
    return @{
        Status = $Status; Measured = $false; Hard = 0; Findings = @(); Counts = @{};
        FilesScanned = 0; Unparsed = @(); Detail = $Detail; Json = ''
        # #1201: WHOSE exam the counts above describe. 'changed-since' = only the files this task
        # changed; 'full-tree' = every test file in the delivered tree, which on a repo with history
        # is a true statement about the TREE and a false attribution to the TASK; '' = no scan ran.
        # A finding charged to the wrong task costs a review-agent run plus up to two build/test/verify
        # FIX laps on an exam the coder never wrote, so the scope rides the result rather than being
        # inferred at each surface.
        ScopeMode = ''; ScopeChangedFiles = 0
        # #1416: WHICH languages were read, and which exams could not be read at all. A single
        # FilesScanned total cannot answer "was the website half of this delivery graded",
        # and that unanswerable total is what hid an entire ecosystem going ungraded for 55
        # consecutive records. Uncovered is never empty-meaning-clean: it is the list of exams
        # that exist and were NOT examined.
        NodeFilesScanned = 0; PythonFilesScanned = 0; Uncovered = @()
        # #1195 residual: the [2/5] pytest gate runs `pytest -x -q` with NO --hypothesis-show-statistics
        # and never persists its output, so there is no statistics artifact to hand the scanner's --stats.
        # The `unexecuted_property` class is therefore UNMEASURABLE from this seam today. Recorded as a
        # field, not a comment, so the report can DISCLOSE it instead of printing a counts map whose
        # `unexecuted_property: 0` would read as a measured zero.
        PropertyExecutionMeasured = $false
    }
}

function Invoke-CoderTestQa {
    # #1195: run BlarAI's shared/fleet/coder_test_qa.py over the SELECTED candidate's own test files and
    # return a status-bearing result. Never throws, never blocks, never adjudicates.
    #
    # The scanner exits 0 ALWAYS and deliberately -- from its own main() docstring: "a scanner that can
    # hard-fail a dispatch on its own exit code would be a second merge authority. One arbiter, in the
    # harness." So the verdict is the single JSON object on stdout and this function branches on THAT.
    # $LASTEXITCODE is never consulted; reading it would silently invert the module's design.
    #
    # FAIL-SOFT IS NOT FAIL-SILENT. Every degraded path returns Status='unavailable' + Measured=$false and
    # a Detail naming the cause. An unmeasured scan must never render as a clean one: a control that
    # degrades into looking like a pass is this project's most-repeated defect, and it is the exact defect
    # coder_test_qa exists to catch one layer down. Callers gate on .Measured, never on .Findings.Count.
    #
    # #1201 ATTRIBUTION. -Since names the commit this task started from, and the scan is then limited
    # to the files changed after it. Without it the scan reads the WHOLE delivered tree, so on any repo
    # with history every green-gated task loses its review-skip forever on tests the coder never wrote
    # (419 files / hard=48 on a clean BlarAI checkout), and inside the battery -- whose scaffold is fresh
    # per NIGHT, not per TASK -- task N is charged for the vacuous tests of tasks 1..N-1. Three seams can
    # break the attribution and each is FAIL-CLOSED to 'unavailable' below, never quietly downgraded to a
    # whole-tree read: a scanner too old to understand --since, a baseline the scanner could not resolve,
    # and a scanner that answered with a scope other than the one asked for.
    #
    # PS 5.1 + 7 safe (no ??/ternary). Only reads; never mutates the scanned tree.
    param(
        [Parameter(Mandatory)][string]$Repo,        # the candidate worktree -- the tree that would merge
        [Parameter(Mandatory)][string]$BlarAiRepo,  # BlarAI root; the module runs as `python -m` from here
        [string]$Since = '',                        # the task's baseline commit; '' asks for no scoping at all
        [string]$StatsPath = '',                    # a pytest --hypothesis-show-statistics capture, when one exists
        [switch]$RequireProperty                    # the task mandated a property-based test
    )
    if (-not $Repo -or -not (Test-Path $Repo)) {
        return (New-CoderTestQaResult -Detail "the candidate worktree is not on disk ($Repo)")
    }
    $pythonExe = Join-Path $BlarAiRepo '.venv\Scripts\python.exe'
    if (-not (Test-Path $pythonExe)) {
        return (New-CoderTestQaResult -Detail "no BlarAI python interpreter at $pythonExe")
    }
    $argsList = @('-m', 'shared.fleet.coder_test_qa', $Repo)
    if ($Since) { $argsList += @('--since', $Since) }
    if ($StatsPath) { $argsList += @('--stats', $StatsPath) }
    if ($RequireProperty) { $argsList += '--require-property' }
    $lines = @()
    try {
        $prevLoc = (Get-Location).Path
        try {
            Set-Location $BlarAiRepo
            $lines = @(& $pythonExe @argsList 2>&1)
        } finally { Set-Location $prevLoc }
    } catch {
        return (New-CoderTestQaResult -Detail "the scanner could not be invoked: $($_.Exception.Message)")
    }
    $jsonLine = ''
    foreach ($ln in $lines) { if ("$ln" -match '^\s*\{') { $jsonLine = "$ln" } }
    if (-not $jsonLine) {
        # The module is absent (it lands with #1170), un-importable, or it crashed. Carry python's own
        # last words: a scan that could not run is a fact the operator has to be able to act on.
        $tail = ((@($lines | Where-Object { "$_".Trim() }) | Select-Object -Last 3) -join ' | ')
        if ($tail.Length -gt 300) { $tail = $tail.Substring(0, 300) + '...' }
        return (New-CoderTestQaResult -Detail "the scanner emitted no JSON (module missing, import error or crash): $tail")
    }
    try { $obj = $jsonLine | ConvertFrom-Json } catch {
        return (New-CoderTestQaResult -Detail "the scanner's output was not parseable JSON: $jsonLine")
    }
    $out = New-CoderTestQaResult
    $out.Json = $jsonLine
    if (-not [bool]$obj.enabled) {
        # The kill-switch (BLARAI_CODER_TEST_QA) is off. A switched-off control is an ABSENT measurement,
        # so Measured stays $false -- it is not a clean exam, it is an unexamined one.
        $out.Status = 'disabled'
        $out.Detail = 'BLARAI_CODER_TEST_QA is switched off, so the coder''s own tests were not examined'
        return $out
    }
    # #1201: read the scope the scanner actually applied, defensively -- a scanner that predates this
    # seam emits no `scope` key at all, and under the StrictMode some callers put in scope a bare
    # property read on an absent key THROWS. Absence is the fact being tested for, so it must not be
    # an exception.
    $scopeProp = $obj.PSObject.Properties['scope']
    $scope = $null
    if ($scopeProp) { $scope = $scopeProp.Value }
    if ($scope) {
        $out.ScopeMode = "$(Get-JsonField -Object $scope -Name 'mode')"
        $out.ScopeChangedFiles = [int](Get-JsonField -Object $scope -Name 'changed_files' -Default 0)
    }
    if ($Since) {
        # A verdict this task can be CHARGED for, or no verdict. Widening to the whole tree here would
        # re-create the exact mis-attribution the -Since argument exists to end, and it would do so
        # invisibly, which is worse than the defect it replaced.
        $why = ''
        if (-not $scope) {
            $why = "this BlarAI checkout's coder_test_qa predates the --since scoping (#1201): it " +
                   "reported no scope, so its verdict covers the WHOLE delivered tree and cannot be " +
                   "attributed to this task"
        } elseif (-not [bool](Get-JsonField -Object $scope -Name 'resolved' -Default $false)) {
            $why = "the files THIS task changed could not be identified, so nothing was examined: " +
                   "$(Get-JsonField -Object $scope -Name 'reason')"
        } elseif ($out.ScopeMode -ne 'changed-since') {
            $why = "a task baseline was passed but the scan came back scoped '$($out.ScopeMode)', " +
                   "which is not attributable to this task"
        }
        if ($why) {
            $bad = New-CoderTestQaResult -Detail $why
            $bad.ScopeMode = $out.ScopeMode
            $bad.Json = $jsonLine
            return $bad
        }
    }
    $out.FilesScanned = [int]$obj.files_scanned
    $out.Unparsed = @($obj.unparsed | ForEach-Object { "$_" })
    $out.Hard = [int]$obj.hard
    $out.Findings = @($obj.findings | ForEach-Object {
        @{ Class = "$($_.class)"; Message = "$($_.message)"; Subject = "$($_.subject)" }
    })
    $counts = @{}
    if ($obj.counts) { foreach ($p in $obj.counts.PSObject.Properties) { $counts[$p.Name] = [int]$p.Value } }
    $out.Counts = $counts
    $out.PropertyExecutionMeasured = [bool]$StatsPath
    # #1416: read the scanner's OWN honesty bit rather than asserting it. This line was
    # `$out.Measured = $true`, set unconditionally after a successful parse, which is why
    # `measured: true` and `files_scanned: 0` sat in the same record for 55 consecutive
    # website deliveries. coder_test_qa computes it as `parsed > 0` and has emitted it since
    # #1223; the wrapper simply overwrote the answer it had asked for.
    #
    # Absent key => a scanner predating #1223. Fall back to the derivation rather than to
    # $false: defaulting a missing field to "not measured" would silently switch the whole
    # instrument off against an older checkout, which is a worse failure than the one fixed.
    $measuredProp = $obj.PSObject.Properties['measured']
    if ($measuredProp) { $out.Measured = [bool]$measuredProp.Value }
    else { $out.Measured = ($out.FilesScanned -gt 0) }

    # #1416: which languages were actually READ, and which exams could not be read at all.
    # Both default to the honest empty, and both are absent from a pre-#1416 scanner -- for
    # which every website record was `no-tests`, so the fallback below reproduces exactly the
    # old behaviour minus the false sentence.
    $langs = Get-JsonField -Object $obj -Name 'languages'
    $nodeFiles = 0; $pyFiles = 0
    if ($langs) {
        $nodeFiles = [int](Get-JsonField -Object $langs -Name 'node' -Default 0)
        $pyFiles = [int](Get-JsonField -Object $langs -Name 'python' -Default 0)
    }
    $out.NodeFilesScanned = $nodeFiles
    $out.PythonFilesScanned = $pyFiles
    $out.Uncovered = @(@(Get-JsonField -Object $obj -Name 'uncovered' -Default @()) |
        ForEach-Object { "$_" })

    if ($out.Findings.Count -gt 0) {
        $out.Status = 'findings'
    } elseif ($out.FilesScanned -eq 0 -and $out.Uncovered.Count -gt 0) {
        # #1416: the candidate DID write an exam and this grader cannot read its language.
        # Before, this fell into `no-tests` and told the operator the coder "wrote no exam
        # for its own work" -- a confident, wrong, human-readable accusation produced by a
        # check that never looked. It is an ABSENT measurement, so Measured is forced false
        # and the status is a not-measured value, never a finding about the coder.
        $out.Measured = $false
        $out.Status = 'not-covered'
        $shown = @($out.Uncovered | Select-Object -First 3) -join ', '
        $more = ''
        if ($out.Uncovered.Count -gt 3) { $more = " (and $($out.Uncovered.Count - 3) more)" }
        $out.Detail = "this candidate's exam is in a language this grader cannot read, so it was NOT examined -- $($out.Uncovered.Count) test file(s) went ungraded: $shown$more. This is a gap in the GRADER, not a fault of the coder"
    } elseif ($out.FilesScanned -eq 0) {
        # Zero files is NOT a clean exam -- there is no exam. A candidate that shipped no tests
        # at all lands here; it would read as "clean" if this branch were folded into the one
        # below, which is the same collapse this function exists to refuse.
        # #1201: say WHICH zero this is. Under a scoped scan the sentence "no test files under the
        # candidate" would be false whenever the tree has tests the task simply did not touch -- and the
        # fact worth reporting there is the stronger one: this task wrote no exam at all.
        $out.Status = 'no-tests'
        if ($out.ScopeMode -ne 'changed-since') {
            $out.Detail = 'no test files under the candidate in any language this grader reads -- there was no exam to examine'
        } elseif ([int]$out.ScopeChangedFiles -gt 0) {
            # #1416: was "NONE of them was a python test -- it wrote no exam for its own work".
            # The accusation was true only of python and was published against 55 website
            # deliveries holding real .test.js files. The grader now reads node too, so this
            # sentence is reachable only when the task genuinely wrote no exam -- and it still
            # names the limit rather than the coder's character.
            $out.Detail = "this task changed $($out.ScopeChangedFiles) file(s) and none of them was a test file in a language this grader reads (python, node) -- no exam of its own work was found"
        } else {
            # A DIFFERENT fact, and the caller only reaches here having already decided there ARE
            # changes -- but it decides that from a COMMIT COUNT against the baseline, while the scope
            # is a CONTENT diff against the same baseline. A coder that added something and then took
            # it back out again satisfies the first and empties the second. Saying "changed 0 file(s)
            # and none was a test" would be technically true and would hide the only thing worth
            # knowing here. Not treated as a fault: it is a legitimate outcome, just an odd one.
            $out.Detail = "this task's commits produce NO net content change against its baseline, so there was nothing to examine (its work was added and then reverted, or it committed only mode/metadata changes)"
        }
    } else {
        $out.Status = 'clean'
    }
    return $out
}

function ConvertTo-FleetAscii {
    # #1195: fold a string to ASCII for the task REPORT. coder_test_qa.py writes real prose and uses
    # em-dashes and curly quotes; Set-Content picks its encoding from the HOST (PS 5.1 = ANSI, PS 7 =
    # UTF-8), so the same finding renders clean on one and as mojibake on the other. The operator must
    # not have to decode the one line telling them their exam is broken. Substitutions, not deletions:
    # a folded message still names the same subject, the same value and the same fix.
    param([string]$Text)
    if (-not $Text) { return '' }
    $out = $Text
    $out = $out -replace ([char]0x2014), '--'   # em dash
    $out = $out -replace ([char]0x2013), '-'    # en dash
    $out = $out -replace ([char]0x2018), "'"    # left single quote
    $out = $out -replace ([char]0x2019), "'"    # right single quote
    $out = $out -replace ([char]0x201C), '"'    # left double quote
    $out = $out -replace ([char]0x201D), '"'    # right double quote
    $out = $out -replace ([char]0x2026), '...'  # ellipsis
    $out = $out -replace ([char]0x00A0), ' '    # non-breaking space
    # Anything still outside printable ASCII becomes '?' rather than a host-dependent byte.
    return ($out -replace '[^\x09\x0A\x0D\x20-\x7E]', '?')
}

function Format-CoderTestQaLanguages {
    # #1416: " (python 3, node 9)" -- or '' when the scanner did not report a breakdown, which
    # is how a pre-#1416 checkout stays silent rather than printing a fabricated "(python 0)".
    # PURE, so verify-coder-test-qa.ps1 can lock it without python or a model.
    #
    # Reads via Get-ResultField, NOT `$Result.NodeFilesScanned`. The first draft used
    # `if ($null -ne $Result.PythonFilesScanned)` as its own guard, which is the bug it was
    # guarding against: under `Set-StrictMode -Version Latest` a bare read of an ABSENT
    # property THROWS, so the guard crashed on exactly the old-shaped result it existed to
    # tolerate. Get-JsonField's own comment says this in terms, and it was written for
    # #1201 after the same mistake. Measured under pwsh 7.6.5 before and after.
    # Get-ResultField, not Get-JsonField: the latter reads PSObject.Properties, which does
    # not see a Hashtable's KEYS, and these results are Hashtables. See its definition.
    param($Result)
    if ($null -eq $Result) { return '' }
    $py = [int](Get-ResultField -Object $Result -Name 'PythonFilesScanned' -Default 0)
    $node = [int](Get-ResultField -Object $Result -Name 'NodeFilesScanned' -Default 0)
    if (($py + $node) -le 0) { return '' }
    $parts = @()
    if ($py -gt 0) { $parts += "python $py" }
    if ($node -gt 0) { $parts += "node $node" }
    return " ($($parts -join ', '))"
}

function Format-CoderTestQaBlock {
    # #1195: the operator-facing block for the task report + console. PURE -> unit-tested without python
    # or a model (verify-coder-test-qa.ps1). The first line is unindented and starts 'CODER TEST QA:' so
    # it cannot collide with the ^TESTS:/^VERIFY:/^RESULT: anchors run-fleet.ps1, watch.py and
    # acceptance.parse_task_report scrape; every continuation line is indented and prefixed '- ' so a
    # finding's own text can never impersonate one of those keys either.
    param($Result, [bool]$SkipWithdrawn = $false, [int]$MaxFindings = 12)
    if ($null -eq $Result) {
        return "CODER TEST QA: NOT MEASURED - no result object was produced. The coder's own tests were NOT examined; this is an ABSENT measurement, not a clean one."
    }
    $status = "$($Result.Status)"
    $detail = "$($Result.Detail)" -replace '\s*[\r\n]+\s*', ' '
    if (-not [bool]$Result.Measured) {
        $lead = 'CODER TEST QA: NOT MEASURED'
        if ($status -eq 'disabled') { $lead = 'CODER TEST QA: NOT MEASURED (kill-switch off)' }
        elseif ($status -eq 'not-applicable') { $lead = 'CODER TEST QA: NOT MEASURED (nothing to examine)' }
        # #1416: the one absent-measurement whose cause is THIS GRADER rather than the
        # candidate. It must not read like the coder's failing, because for 55 website
        # deliveries it did exactly that.
        elseif ($status -eq 'not-covered') { $lead = 'CODER TEST QA: NOT MEASURED (this grader cannot read the exam''s language)' }
        # #1416: 'no-tests' now arrives HERE, because Measured is read from the scanner and
        # the scanner has always said measured=false for a scan that parsed nothing. That is
        # the honest bit -- an empty path list is an unexamined project, not an examined one
        # that found nothing. But NOT MEASURED is a weaker sentence than the true one, and
        # this branch keeps the sharper wording: there was no exam, which is a FACT about the
        # candidate rather than a gap in the grader. Losing that distinction while fixing a
        # different one would be a poor trade.
        elseif ($status -eq 'no-tests') { $lead = 'CODER TEST QA: NO EXAM' }
        # $detail can carry python's own last words, so it gets the same fold as a finding message.
        $line = "$lead - $detail."
        # #1416, corrected in review: the comment above claimed this branch KEEPS the sharper
        # `no-tests` wording, and it kept only half of it. The lead said NO EXAM and the tail
        # still said "this is an ABSENT measurement", which is the grader-shaped sentence --
        # while the true fact here is about the CANDIDATE: it wrote no exam. The reviewer
        # found the old branch below had become unreachable in production and its sentence
        # lost with it, and that F2's fixture forces Measured=$true so it was still testing a
        # path nothing can reach. Both sentences now live on the path that actually runs.
        $tail = " The coder's own tests were NOT examined; this is an ABSENT measurement, not a clean one."
        if ($status -eq 'no-tests') {
            $tail = " The TESTS line above rests on no coder-authored test at all."
        }
        return (ConvertTo-FleetAscii -Text ($line + $tail))
    }
    $files = [int]$Result.FilesScanned
    $hard = [int]$Result.Hard
    # #1201: name WHOSE exam this is, on the line the operator reads. A count with no scope is the
    # thing that made "the coder's OWN exam carries 48 PROVEN defect(s)" a false sentence about a task
    # that had written none of them.
    $scopeMode = "$($Result.ScopeMode)"
    $subject = ' of the coder''s tests'
    if ($scopeMode -eq 'changed-since') {
        $subject = " of the $([int]$Result.ScopeChangedFiles) file(s) THIS task changed"
    } elseif ($scopeMode -eq 'full-tree') {
        $subject = ' of the WHOLE delivered tree (no task baseline, so findings are NOT attributed to this task alone)'
    }
    $lines = New-Object System.Collections.ArrayList
    if ($status -eq 'no-tests') {
        # True whether the TESTS line above reads pass or none: either way nothing coder-authored was
        # examined here, because on this candidate there was no exam to examine.
        [void]$lines.Add("CODER TEST QA: NO EXAM - $detail. The TESTS line above rests on no coder-authored test at all.")
    } elseif ($status -eq 'clean') {
        # #1416: name the LANGUAGE MIX on a clean line. "9 test file(s) examined, no findings"
        # is the same sentence whether the website half was graded or skipped entirely, and
        # telling those apart at a glance is the whole point of the ticket.
        [void]$lines.Add("CODER TEST QA: clean - $files test file(s) examined$subject$(Format-CoderTestQaLanguages -Result $Result), no findings.")
    } else {
        $n = @($Result.Findings).Count
        $tail = 'the merge gate is UNCHANGED (advisory by design).'
        if ($SkipWithdrawn) {
            $tail = "the green-gate review SKIP was WITHDRAWN so the reviewer looks at this exam; the merge gate is UNCHANGED (advisory by design)."
        }
        # #1416: the language mix belongs on the FINDINGS line too, not only the clean one.
        # The first draft put it only on 'clean' and the real archived delivery went straight
        # past it, because that delivery HAS a finding -- so the one line most likely to be
        # read on a website was the one still unable to say a website had been read.
        [void]$lines.Add("CODER TEST QA: $n finding(s) over $files test file(s)$subject$(Format-CoderTestQaLanguages -Result $Result), $hard PROVEN - $tail")
        $shown = 0
        foreach ($f in @($Result.Findings)) {
            if ($shown -ge $MaxFindings) { break }
            $subj = "$($f.Subject)"
            $where = ''
            if ($subj) { $where = " $subj" }
            [void]$lines.Add(("  - [$($f.Class)]$where : $($f.Message)" -replace '\s*[\r\n]+\s*', ' '))
            $shown++
        }
        if ($n -gt $shown) { [void]$lines.Add("  - (+$($n - $shown) more finding(s) in the sidecar JSON)") }
    }
    if (@($Result.Unparsed).Count -gt 0) {
        # #1416, review: "would not parse" is accurate for a syntax error and WRONG for the
        # other thing that lands here -- a file whose language scanner was unavailable, which
        # is a fact about the grader rather than the file. This module's whole thesis is that
        # those are different, and its own operator line was collapsing them. The two are
        # still carried in one list (both mean NOT EXAMINED, and both are excluded from the
        # verdict identically); what changes is that the sentence no longer asserts a cause
        # it cannot know from here.
        [void]$lines.Add("  - NOT EXAMINED: $(@($Result.Unparsed).Count) test file(s) could not be read (a syntax error, or no scanner available for their language), so they were skipped by the scan and the verdict above does not cover them.")
    }
    # #1416, added in review: `uncovered` reached the operator ONLY through the `not-covered`
    # status, which requires that NOTHING was scanned. On a mixed tree -- one python exam and
    # three ruby ones -- the line he read was "clean - 1 test file(s) examined, no findings"
    # while three exams went ungraded and were named nowhere he would look. The whole ticket
    # is that an unexamined exam must not be able to hide inside a clean-looking line, and the
    # field built to prevent it was invisible in the one case where something else passed.
    # Mirrors the Unparsed line above, because it is the same kind of disclosure.
    $uncoveredList = @(Get-ResultField -Object $Result -Name 'Uncovered' -Default @())
    if ($uncoveredList.Count -gt 0 -and $status -ne 'not-covered') {
        $head = @($uncoveredList | Select-Object -First 3) -join ', '
        $rest = ''
        if ($uncoveredList.Count -gt 3) { $rest = " (and $($uncoveredList.Count - 3) more)" }
        [void]$lines.Add("  - NOT EXAMINED: $($uncoveredList.Count) test file(s) are in a language this grader cannot read, so they were NOT graded at all: $head$rest. The verdict above does not cover them.")
    }
    if (-not [bool]$Result.PropertyExecutionMeasured) {
        # Disclosed, not silently absent: the counts map would otherwise carry unexecuted_property: 0,
        # which reads as a measured zero. See the field's comment in New-CoderTestQaResult.
        [void]$lines.Add('  - NOT MEASURED: the test gate captures no Hypothesis run statistics, so `unexecuted_property` (a property test that never generated an example) could not be checked (#1195).')
    }
    return (ConvertTo-FleetAscii -Text ($lines -join "`n"))
}

function ConvertTo-CoderTestQaSidecarJson {
    # #1195: the machine-readable companion to Format-CoderTestQaBlock, written beside the task report so
    # a scorecard can consume the verdict without regexing prose. PURE -> unit-tested. `measured` is a
    # FIRST-CLASS field for the same reason it exists in the result: a consumer must be able to tell an
    # unexamined run from a clean one without inferring it from an empty findings list.
    param($Result)
    $r = $Result
    if ($null -eq $r) { $r = (New-CoderTestQaResult -Detail 'no result object was produced') }
    $payload = [ordered]@{
        status = "$($r.Status)"
        measured = [bool]$r.Measured
        hard = [int]$r.Hard
        files_scanned = [int]$r.FilesScanned
        detail = "$($r.Detail)"
        property_execution_measured = [bool]$r.PropertyExecutionMeasured
        # #1201: a scorecard reading `hard` must be able to see WHOSE exam that number graded without
        # regexing the prose block, so the attribution is a first-class field here too.
        scope_mode = "$($r.ScopeMode)"
        scope_changed_files = [int]$r.ScopeChangedFiles
        # #1416: WHICH languages this record's numbers describe, and which exams went ungraded.
        # These belong here and not only in the prose block, because the audit that FOUND #1416
        # was computed over 95 of these sidecars -- without them a future audit still could not
        # ask "was the website half of this delivery graded" without re-parsing scanner_json.
        # A fix invisible to the instrument that would next look for it is not finished.
        # Get-JsonField, never a bare read: under StrictMode `$r.NodeFilesScanned` THROWS when
        # the property is absent, which is precisely the old-shaped result this must tolerate.
        languages = [ordered]@{
            python = [int](Get-ResultField -Object $r -Name 'PythonFilesScanned' -Default 0)
            node = [int](Get-ResultField -Object $r -Name 'NodeFilesScanned' -Default 0)
        }
        uncovered = @(@(Get-ResultField -Object $r -Name 'Uncovered' -Default @()) | ForEach-Object { "$_" })
        unparsed = @(@($r.Unparsed) | ForEach-Object { "$_" })
        counts = $r.Counts
        findings = @(@($r.Findings) | ForEach-Object {
            [ordered]@{ class = "$($_.Class)"; message = "$($_.Message)"; subject = "$($_.Subject)" }
        })
        scanner_json = "$($r.Json)"
    }
    return (ConvertTo-Json $payload -Depth 6)
}

function Write-CoderTestQaSidecar {
    # #1195: persist the sidecar as UTF-8 WITHOUT a BOM, deterministically. Set-Content would pick its
    # encoding from the host (PS 5.1 ANSI / UTF-8-with-BOM, PS 7 UTF-8), and a BOM makes Python's
    # json.load raise unless the reader remembered utf-8-sig -- an evidence file a consumer cannot open
    # is the same class of failure as an unmeasured scan. Best-effort: a write failure must never take
    # down a dispatch, but it is reported rather than swallowed.
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)][string]$Json)
    try {
        [System.IO.File]::WriteAllText($Path, $Json, (New-Object System.Text.UTF8Encoding($false)))
        return $true
    } catch {
        Write-Host "  CODER TEST QA: could not write the sidecar $Path ($($_.Exception.Message)); the report block above still carries the verdict." -ForegroundColor Yellow
        return $false
    }
}

function Format-VisualCritiqueSummary {
    # #1198: the operator-facing VISUAL CRITIQUE block for the task report + console. PURE -> unit-tested
    # without a VLM, a capture, python or a model (verify-critique-loop.ps1). It is a FUNCTION rather than
    # an inline string in new-agent-task.ps1 for one reason: the line that has to survive here is the
    # DISCLOSURE, and an inline string cannot be tested, so nothing could prove it survives.
    #
    # An UNMEASURED design lint does NOT change the loop's verdict (that decision lives in
    # Merge-DesignSignals). It changes what this block SAYS: the clean-bill lead is WITHHELD whenever a
    # lint produced no verdict, because "visual criteria look satisfied" over an unexamined axis is the
    # exact sentence #1198 exists to stop being printed.
    #
    # $Result is an Invoke-CritiquePass result (or $null). ASCII-folded like the coder-QA block: the
    # report is written with Set-Content, whose encoding follows the HOST (PS 5.1 ANSI / PS 7 UTF-8), so
    # unfolded prose renders as mojibake on one of them and the operator must not have to decode the one
    # line telling them their measurement is missing.
    param($Result, [string[]]$FixNotes = @(), [int]$FixCount = 0)
    $fixTail = ''
    if (@($FixNotes).Count -gt 0) { $fixTail = "`n" + ((@($FixNotes)) -join "`n") }
    if ($null -eq $Result) {
        return (ConvertTo-FleetAscii -Text "VLM critique ran but returned no result (treated as no-op).$fixTail")
    }
    $caveatTail = ''
    if ("$($Result.CaveatText)") { $caveatTail = "`n" + "$($Result.CaveatText)" }
    $line = ''
    if ("$($Result.CaptureTier)" -eq 'structural') {
        $line = "No pixel capture available (structural floor); visual critique skipped. $($Result.Feedback)$fixTail$caveatTail"
    } elseif (-not [bool]$Result.Ok) {
        $line = "VLM critique unavailable / failed (non-blocking): $($Result.Feedback)$fixTail$caveatTail"
    } elseif ([bool]$Result.NeedsWork) {
        $line = "VLM still suggests visual improvements after $FixCount auto-fix pass(es) (signal only -- your eyeball is the verdict):`n$($Result.Feedback)$fixTail$caveatTail"
    } else {
        # The ONLY branch that reads as a clean bill, so the only one that must refuse to print one when a
        # deterministic lint produced no verdict at all.
        $after = ''
        if ($FixCount) { $after = " after $FixCount auto-fix pass(es)" }
        # ANY caveat withholds the clean bill, not only a wholly absent lint -- a lint that skipped files
        # it could not parse examined less than the report would otherwise claim. Both conditions are kept
        # so a future caller that clears LintsMeasured without a caveat still cannot print the clean lead.
        if ((-not [bool]$Result.LintsMeasured) -or $caveatTail) {
            $line = ("VLM critique: the VLM saw no remaining issues$after, but this is a PARTIAL examination -- " +
                     "a deterministic design check did not examine everything it was pointed at (see below), " +
                     "so this deliverable has NOT been checked clean. $($Result.Feedback)$fixTail$caveatTail")
        } else {
            $line = "VLM critique: visual criteria look satisfied$after. $($Result.Feedback)$fixTail$caveatTail"
        }
    }
    return (ConvertTo-FleetAscii -Text $line)
}

function Resolve-CriticRange {
    # #687 #9 (empty-diff fix): the cross-model 14B critic runs POST-MERGE on the base branch, where
    # "<base>...HEAD" is EMPTY (HEAD == base) -- it returned no diff ("The diff content is missing").
    # Resolve the range that captures the merged work:
    #   1. "<base>...HEAD" -- non-empty PRE-merge (the agent worktree); old behavior preserved.
    #   2. "HEAD~1..HEAD"  -- POST-merge, the last merge's first-parent diff = exactly the work the
    #                         merge brought in: the agent's single fast-forward commit, OR a --no-ff
    #                         merge commit's merged changes EXCLUDING main's own concurrent commits.
    #                         (merge-base(main,agent)..agent does NOT work here: post-merge the agent
    #                         tip is an ancestor of main, so that range is always empty.)
    # #693 (closes the #687 follow-up gap): a MULTI-commit agent branch FAST-FORWARDED onto an
    # unchanged main collapses to linear history, so HEAD~1..HEAD sees only the LAST commit. The
    # robust path: swap_driver records main's pre-dispatch SHA and threads it here as -BaseRef;
    # "<base-sha>..HEAD" is ALL the merged work regardless of FF/commit-count. Checked FIRST; an
    # empty/invalid/unchanged BaseRef falls through to the legacy chain (fallback preserved).
    # Returns a git range string, or "" if nothing resolves. ASCII; PS 5.1 + 7 safe (EAP=Continue so
    # git's informational stderr -- e.g. HEAD~1 on a 1-commit repo -- never throws a NativeCommandError).
    # Only reads git; never mutates.
    param([Parameter(Mandatory)][string]$Repo, [string]$Base = 'main', [string]$BaseRef = '')
    $ErrorActionPreference = 'Continue'
    if ($BaseRef -and (((git -C $Repo diff "$BaseRef..HEAD" --name-only 2>$null) -join "`n"))) { return "$BaseRef..HEAD" }
    if (((git -C $Repo diff "$Base...HEAD" --name-only 2>$null) -join "`n")) { return "$Base...HEAD" }
    if (((git -C $Repo diff "HEAD~1..HEAD" --name-only 2>$null) -join "`n")) { return "HEAD~1..HEAD" }
    return ""
}

function Get-WorktreeDigest {
    # #694 read-only-review enforcement. Return a SHA-256 over the worktree's mutation-relevant state
    # so two snapshots taken around a "read-only" leg PROVE whether the tree changed under it. The
    # signature is `git status --porcelain --untracked-files=all` (every dirty OR new path) joined with
    # `git diff HEAD` (the full content of every tracked change vs the committed tree). A namespace edit
    # flips the diff; an untracked Tests/ dir flips the status -- exactly the two mutations the incident
    # produced (run 20260627-083757-bd: a read-only review leg edited Calculator.cs AND added Tests/,
    # leaving an un-buildable parked tree over a buildable commit). At review time the selected
    # candidate's work is already COMMITTED, so a clean review sees a stable "matches-HEAD" digest;
    # opencode stores session state in ~/.local/share/opencode (share disabled), NOT the --dir worktree,
    # so it does not move this digest -- only a real write does. Only reads git; never mutates.
    # ASCII; PS 5.1 + 7 safe (EAP=Continue so git's informational stderr never throws).
    param([Parameter(Mandatory)][string]$Repo)
    $ErrorActionPreference = 'Continue'
    $status = (git -C $Repo status --porcelain --untracked-files=all 2>$null) -join "`n"
    $diff   = (git -C $Repo diff HEAD 2>$null) -join "`n"
    $combined = $status + "`n--DIFF--`n" + $diff
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try {
        $bytes = [System.Text.Encoding]::UTF8.GetBytes($combined)
        return ([System.BitConverter]::ToString($sha.ComputeHash($bytes))).Replace('-', '')
    } finally { $sha.Dispose() }
}

function Test-ReviewLegMutated {
    # #694: the PURE verdict the harness acts on -- did the worktree digest move across the review leg?
    # $true => the read-only reviewer MUTATED the tree, so the harness FAILS CLOSED (never merge; park
    # for the operator). The reviewer's own edit/bash:deny is a REQUEST the harness cannot trust alone:
    # a live config-sync once reverted that very deny (2026-07-09), and the incident's mutation came from
    # OUTSIDE the agent's tool calls anyway -- so this digest guard is the enforcement, independent of
    # review.md. Two empty/failed digests that MATCH (a git hiccup on both sides) are NOT a false
    # mutation; only a genuine difference trips it. Pure -> unit-tested without a model.
    param([string]$Before, [string]$After)
    return ($Before -ne $After)
}

function ConvertTo-NormalizedContentHash {
    # #780 (c) helper: SHA-256 over LF-normalized UTF-8 text so a config file's IDENTITY is
    # line-ending-insensitive. sync-harness fires on raw-byte Get-FileHash, but the SECURITY question
    # #780 asks is "did the CONTENT (e.g. bash: deny) change direction?" -- that must not be fooled by a
    # bare CRLF drift. Trailing newlines are trimmed so a Copy-Item file vs a git-show round-trip compare equal.
    param([string]$Text)
    if ($null -eq $Text) { $Text = '' }
    $norm = (($Text -replace "`r`n", "`n") -replace "`r", "`n").TrimEnd("`n")
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try {
        return ([System.BitConverter]::ToString($sha.ComputeHash([System.Text.Encoding]::UTF8.GetBytes($norm)))).Replace('-', '')
    } finally { $sha.Dispose() }
}

function Get-ConfigDeployDivergence {
    # #780 fix (c): compare a git-tracked REPO config against its LIVE deployed copy and name the DIRECTION
    # of any divergence, so the #694 merge motion can PROVE the sync-harness revert trap is disarmed.
    # sync-harness.ps1 is one-way LIVE->repo (it Copy-Items the live file over the repo file whenever the two
    # differ, then auto-commits). So the four verdicts each carry an action:
    #   IN_SYNC     live == repo -- deployed; a sync is a no-op (the state the merge motion must LEAVE behind).
    #   REPO_AHEAD  live == a KNOWN past committed version of the repo path -- the repo advanced and is awaiting
    #               deploy. Benign IF deployed promptly; the exact #780 precursor if left (a later sync copies
    #               the stale live back over the repo fix -- how f219074 was reverted by 3553b56).
    #   LIVE_AHEAD  live carries content the repo's history NEVER held -- the next sync captures novel live state
    #               into the tracked tree with no review. For a security-critical agent def that is the armed
    #               trap and MUST fail loud (see Test-DeployDivergenceFatal).
    #   LIVE_ABSENT no live copy (fresh box) -- nothing deployed, nothing to revert.
    # Direction is decided on LF-normalized CONTENT (not raw bytes) so a bare CRLF drift is not misread as
    # novel. Read-only: git log/show never mutate and the live file is only read; NOTHING is deployed here.
    # ASCII; PS 5.1 + 7 safe.
    param(
        [Parameter(Mandatory)][string]$Repo,
        [Parameter(Mandatory)][string]$RepoRelPath,
        [Parameter(Mandatory)][string]$LivePath
    )
    $ErrorActionPreference = 'Continue'
    if (-not (Test-Path -LiteralPath $LivePath)) { return 'LIVE_ABSENT' }
    $liveRaw = Get-Content -LiteralPath $LivePath -Raw -ErrorAction SilentlyContinue
    if ($null -eq $liveRaw) { return 'LIVE_ABSENT' }
    $repoFull = Join-Path $Repo $RepoRelPath
    if (-not (Test-Path -LiteralPath $repoFull)) { return 'LIVE_AHEAD' }
    $liveH = ConvertTo-NormalizedContentHash $liveRaw
    $repoH = ConvertTo-NormalizedContentHash (Get-Content -LiteralPath $repoFull -Raw -ErrorAction SilentlyContinue)
    if ($liveH -eq $repoH) { return 'IN_SYNC' }
    foreach ($c in @(git -C $Repo log --all --format='%H' -- $RepoRelPath 2>$null)) {
        $past = (@(git -C $Repo show "$($c):$RepoRelPath" 2>$null) -join "`n")
        if ($past -and ((ConvertTo-NormalizedContentHash $past) -eq $liveH)) { return 'REPO_AHEAD' }
    }
    return 'LIVE_AHEAD'
}

function Test-DeployDivergenceFatal {
    # #780 (c): the PURE severity verdict a gate acts on. LIVE_AHEAD is ALWAYS fatal -- a sync would silently
    # mutate the tracked tree with unreviewed live content. REPO_AHEAD (pending deploy) and LIVE_ABSENT
    # (fresh box) are non-fatal by default -- they are the benign merge-window / new-box states -- but -Strict
    # (the POST-deploy gate the runbook uses) demands full IN_SYNC and fails anything else. Pure -> unit-tested.
    param([string]$Verdict, [switch]$Strict)
    if ($Verdict -eq 'LIVE_AHEAD') { return $true }
    if ($Strict.IsPresent -and $Verdict -ne 'IN_SYNC') { return $true }
    return $false
}

function Select-AgentProcessTreeTargets {
    # PURE (#694 follow-up -- the coder-leg reap decision). Given a process SNAPSHOT, return the pids to
    # reap for ONE agent leg so opencode's node / language-server / sub-agent children cannot outlive the
    # leg and flush a late write into the NEXT leg's tree. That is the 20260710-152121 park: a
    # trailing-newline normalize of Calculator.cs (a seed file the coder never edited) landed ~10 min after
    # the coder-fix leg, DURING the read-only review, tripping the #694 digest guard. Targets =
    #   (a) every DESCENDANT of $RootPid via the ParentProcessId chain -- Windows leaves the STALE ppid on an
    #       orphan after its parent exits, so the chain still attributes the leg's own children post-exit; and
    #   (b) any process whose image is in $ImageAllow AND whose CommandLine names the exact leg worktree
    #       $WorkDir -- coverage for a child a language server re-parented off the ppid chain.
    # NEVER returns $RootPid itself nor any pid in $Protect. The $WorkDir scoping is what makes a reap safe:
    # it can touch only THIS leg's own tree -- never a sibling dispatch (different worktree, different root)
    # nor the production AO/OVMS (not a descendant of this opencode, no worktree path in its cmdline). Kills
    # (a) regardless of image because ppid-attribution to our own freshly-spawned opencode is strong; the
    # weaker cmdline branch (b) is image-gated. Snapshot objects need .ProcessId/.ParentProcessId/.Name/
    # .CommandLine. Pure -> unit-tested without spawning anything.
    param(
        [Parameter(Mandatory)]$Processes,
        [Parameter(Mandatory)][int]$RootPid,
        [string]$WorkDir = '',
        [string[]]$ImageAllow = @('node.exe', 'opencode.exe'),
        [int[]]$Protect = @()
    )
    $byParent = @{}
    foreach ($pr in @($Processes)) {
        $k = [int]$pr.ParentProcessId
        if (-not $byParent.ContainsKey($k)) { $byParent[$k] = New-Object System.Collections.ArrayList }
        [void]$byParent[$k].Add($pr)
    }
    $targets = @{}
    # (a) ppid-chain descendants of RootPid (iterative; $walked guards a recycled-ppid cycle).
    $stack = New-Object System.Collections.Stack; $stack.Push([int]$RootPid)
    $walked = @{}
    while ($stack.Count -gt 0) {
        $cur = [int]$stack.Pop()
        if ($walked.ContainsKey($cur)) { continue }
        $walked[$cur] = $true
        if ($byParent.ContainsKey($cur)) {
            foreach ($ch in $byParent[$cur]) {
                $cid = [int]$ch.ProcessId
                if ($cid -ne [int]$RootPid) { $targets[$cid] = $true }
                if (-not $walked.ContainsKey($cid)) { $stack.Push($cid) }
            }
        }
    }
    # (b) allowlisted image whose command line names the exact worktree (re-parented straggler coverage).
    $wd = if ($WorkDir) { ($WorkDir -replace '/', '\').TrimEnd('\') } else { '' }
    if ($wd) {
        foreach ($pr in @($Processes)) {
            $cl = ("$($pr.CommandLine)") -replace '/', '\'
            if ($cl -and ($cl -like "*$wd*") -and ($ImageAllow -contains "$($pr.Name)")) {
                $targets[[int]$pr.ProcessId] = $true
            }
        }
    }
    $protectSet = @{}; foreach ($x in @($Protect)) { $protectSet[[int]$x] = $true }
    $protectSet[[int]$RootPid] = $true
    return @($targets.Keys | Where-Object { -not $protectSet.ContainsKey([int]$_) } | Sort-Object -Unique)
}

function Stop-AgentProcessTree {
    # #694 follow-up: REAP one agent leg's opencode process tree on EVERY exit path. The timeout/cap paths
    # already `taskkill /T` while the parent is alive; a NORMAL exit killed nothing, so node / language-server
    # / sub-agent children could orphan and flush a late write into the next leg (run 20260710-152121).
    # Snapshot the live processes, pick the leg's own tree (Select-AgentProcessTreeTargets -- scoped + pure),
    # and force-kill it. Fully guarded so it can NEVER throw into an agent run. Returns the reaped pids for
    # the transcript. Reads processes; kills ONLY this leg's tree (see the selector's scoping note).
    param([Parameter(Mandatory)][int]$RootPid, [string]$WorkDir = '', [int[]]$Protect = @())
    $reaped = @()
    try {
        $snap = @(Get-CimInstance Win32_Process -ErrorAction SilentlyContinue |
                  Select-Object ProcessId, ParentProcessId, Name, CommandLine)
        if (-not $snap -or $snap.Count -eq 0) { return @($reaped) }
        $prot = @($Protect) + @([int]$PID)
        $targets = Select-AgentProcessTreeTargets -Processes $snap -RootPid $RootPid -WorkDir $WorkDir -Protect $prot
        foreach ($t in @($targets)) {
            try { & taskkill.exe /PID $t /T /F *> $null; $reaped += [int]$t } catch {}
        }
    } catch {}
    return @($reaped)
}

function Wait-WorktreeQuiesced {
    # #694 follow-up: the write-SETTLE barrier. After a reap, PROVE the worktree stopped moving before the
    # next leg snapshots it: sample Get-WorktreeDigest across a quiet window and return once two consecutive
    # samples MATCH (no write landed in $QuietMs), or give up at $MaxWaitMs. A reaped tree settles on the
    # first window; a still-writing one (an un-reaped straggler) surfaces as Settled=$false so the caller can
    # log it and let the digest guard remain the backstop, rather than snapshot a moving tree. Read-only.
    param([Parameter(Mandatory)][string]$Repo, [int]$QuietMs = 750, [int]$MaxWaitMs = 6000)
    $ErrorActionPreference = 'Continue'
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $prev = Get-WorktreeDigest -Repo $Repo
    while ($sw.ElapsedMilliseconds -lt $MaxWaitMs) {
        Start-Sleep -Milliseconds $QuietMs
        $cur = Get-WorktreeDigest -Repo $Repo
        if ($cur -eq $prev) { return @{ Settled = $true; WaitedMs = [int]$sw.ElapsedMilliseconds } }
        $prev = $cur
    }
    return @{ Settled = $false; WaitedMs = [int]$sw.ElapsedMilliseconds }
}

function Restore-WorktreeToHead {
    # #694 follow-up: DISCARD-and-log any POST-COMMIT stray worktree write so the reviewed tree is EXACTLY
    # the committed candidate. Trade-off (named): the coder leg's COMMIT is its deliverable; a write that
    # lands AFTER it (a formatter / language-server flush from a straggling child) is tooling noise, not
    # intended work -- folding it into the commit would ship an unrequested change AND still race the digest
    # guard, so we restore to HEAD instead. Returns the stray paths it discarded (empty = tree already clean)
    # so the caller records them. Mirrors the existing best-of-N selection idiom (reset --hard + clean -fd).
    # CALLER CONTRACT: only invoke when the leg's work is COMMITTED (never on a secret-blocked tree, whose
    # uncommitted work is deliberately preserved for human review -- that path yields hasChanges=false and so
    # never reaches here).
    param([Parameter(Mandatory)][string]$Repo)
    $ErrorActionPreference = 'Continue'
    $stray = @(git -C $Repo status --porcelain --untracked-files=all 2>$null | Where-Object { $_ })
    if ($stray.Count -gt 0) {
        git -C $Repo reset --hard HEAD 2>&1 | Out-Null
        git -C $Repo clean -fd 2>&1 | Out-Null
    }
    return @($stray)
}

function Resolve-PassBudget {
    # COMPLEXITY SIGNAL (operator's idea): the upstream 14B emits a COARSE complexity label -- it is NOT a
    # coder, so it sends a SIGNAL ("simple" vs "very complex"), never a pass count. The SYSTEM maps that label
    # to the two INDEPENDENT pass budgets the multi-pass loop spends: a harder task earns more build + review
    # passes; a simple one fewer (don't burn the model iterating on a one-liner). An ABSENT or UNRECOGNISED
    # label keeps the caller's explicit defaults, so adding the signal is fully backward-compatible. Pure ->
    # unit-tests without a model.
    #   simple -> 2 build / 1 review     moderate -> 3 / 2     complex -> 8 / 3
    # (complex BUILD raised 5->8 on 2026-06-27, LA decision: more total best-of-N shots at hard tasks. With
    #  the concurrency default C=3 those 8 candidates run in 3 waves of 3,3,2 -- bounded wall-clock, more
    #  coverage. Sampling is near-free locally; best-of-N coverage is the weak-model bottleneck.)
    # STAGED-GUI FLOOR (dead-button fix, 2026-06-24): a desktop-gui/winui surface (staged) needs MORE build
    # passes than the coarse label implies -- its loop is core -> shell -> WIRE -> theme -> verify, and the
    # coder now RUNS the offline tests each pass (run -> read failure -> fix -> repeat). A "simple" GUI at 2
    # passes themes-then-quits before wiring the buttons. So when $Staged, floor BUILD to 5 (review
    # unchanged). $Staged defaults false, so existing non-staged callers are byte-identical to before.
    param([string]$Complexity, [int]$DefaultBuild = 3, [int]$DefaultReview = 2, [bool]$Staged = $false)
    $c = if ($Complexity) { $Complexity.Trim().ToLower() } else { '' }
    $b = switch ($c) {
        'simple'   { @{ Build = 2; Review = 1 } }
        'moderate' { @{ Build = 3; Review = 2 } }
        'complex'  { @{ Build = 8; Review = 3 } }
        default    { @{ Build = $DefaultBuild; Review = $DefaultReview } }
    }
    if ($Staged -and $b.Build -lt 5) { $b.Build = 5 }
    return $b
}

function Add-ComplexityHint {
    # Tell the coder, BEFORE pass 1, how hard the task was assessed to be (operator: "it might be good for the
    # coder to know if it will be a simple task or a very complex one, before it starts the first pass"). A
    # COARSE label only -- it calibrates effort, it does NOT prescribe an implementation. No-ops on an absent or
    # unrecognised label, and ALWAYS preserves the original prompt verbatim (the hint is appended, never replaces).
    param([string]$Prompt, [string]$Complexity)
    $c = if ($Complexity) { $Complexity.Trim().ToLower() } else { '' }
    $note = switch ($c) {
        'simple'   { 'This task was assessed as SIMPLE. Keep the solution minimal and direct; do not over-engineer or add unrequested scope.' }
        'moderate' { 'This task was assessed as MODERATE complexity. Implement it completely and correctly; expect to refine once if the build or a review finds gaps.' }
        'complex'  { 'This task was assessed as COMPLEX. Plan before you write, handle the edge cases, and prioritise a correct, complete solution over a fast one; you have room to iterate across several passes.' }
        default    { '' }
    }
    if (-not $note) { return $Prompt }
    return "$Prompt`n`n--- TASK COMPLEXITY (assessed upstream; calibrate your effort -- this does NOT prescribe the design) ---`n$note"
}

function Add-StagedHint {
    # STAGED CORE-THEN-WIRE-THEN-THEME PROMPT (#676; dead-button fix 2026-06-24): for a STAGED surface
    # (the BuildProfile's staged flag -- set for `winui`/desktop-gui, which ships the pre-wired
    # core/shell/Tests seed), tell the coder to work the seed in ordered stages and RUN THE TESTS each
    # pass: (1) implement the Calculator core + EXTEND the offline tests, running `dotnet run -- --test`
    # (the seed's self-terminating test entry in App.xaml.cs) and iterating run->read-failure->fix until
    # green; (2) build + WIRE the real UI -- every button routed through the core (the dead-button cure);
    # (3) THEN theme without breaking the wiring. The earlier no-execute ban (a blunt patch for the #676
    # `dotnet run` console-runner hang) is REPLACED: the seed now exposes a runnable `--test` entry (no
    # GUI) and the per-command timeout backstops any hang, so the coder gets the feedback loop it needs.
    # Still forbidden: a second/test project, a Program.cs, a NuGet test framework (offline), and
    # launching the GUI (a bare `dotnet run` / `dotnet test`). The hint is gated on $Staged so non-staged
    # surfaces are UNTOUCHED (strictly additive), and it ALWAYS preserves the original prompt verbatim
    # (appended, never replaces). Pure -> unit-tests without a model.
    param([string]$Prompt, [bool]$Staged)
    if (-not $Staged) { return $Prompt }
    $note = @'
This build ships a pre-wired skeleton: a Calculator core in `Calculator.cs`, dependency-free tests in `Tests/CalculatorTests.cs` that already build offline, and an App/MainWindow shell with named hooks. RUN the tests as you go and ITERATE until they pass -- do not build once and stop. Work it in stages, in order:
(1) Implement the Calculator core in `Calculator.cs` and EXTEND the tests in `Tests/CalculatorTests.cs` (add a `Check_*` method per behavior). After each change, RUN the tests: `dotnet run -- --test` runs the offline harness and EXITS 0 if all pass, non-zero on the first failure (it also writes the detail to `test-results.txt`). It opens NO window. Read the failure, fix the code, run again -- repeat until every check passes.
(2) Build the real UI in `MainWindow.xaml` (the number and operator buttons and the display) and WIRE it in `MainWindow.xaml.cs`: every button's Click handler must route through the `_calc` core to the `Display`. A button that LOOKS right but does nothing is a FAILURE -- make sure every digit, all four operators (+ - x /), equals, and clear actually change the Display. Re-run `dotnet run -- --test` to confirm the core still passes.
(3) THEN theme the shell (colours, flames, chunky buttons) WITHOUT breaking the wiring -- every button must still work after theming. Run `dotnet run -- --test` one final time.
RULES (these keep the build green and offline):
- ONE project only. Do NOT add a second/test `.csproj`, a `Program.cs`, or a test-framework package (MSTest/xUnit/NUnit are NOT available offline) -- the `Tests/` harness already builds; just add `Check_*` cases to it.
- To RUN the tests use ONLY `dotnet run -- --test` (it self-terminates with a pass/fail exit code). Do NOT run the app without `--test`, and do NOT use `dotnet test` or a bare `dotnet run` -- launching the GUI window blocks forever and wastes your budget.
- A clean build is necessary but NOT sufficient: the tests must PASS and the buttons must WORK before you are done.
'@
    return "$Prompt`n`n--- STAGED BUILD (core first, then shell; this is a known-good seed -- extend it, do not re-scaffold) ---`n$note"
}

function Add-WebHint {
    # OFFLINE-WEB PROMPT (#670, 2026-06-30): a `web` scaffold ships a pre-wired, dependency-free Node
    # skeleton (a node:http server + a static public/ + node:test tests that bind an EPHEMERAL port) that
    # already builds and tests OFFLINE. The live failure: the coder REWROTE the page with an external CDN
    # image (https://placehold.co/...) and wrote tests that fetched a hardcoded http://localhost:8081 it
    # never started -- on this air-gapped box every one of those failed ("fetch failed"), nothing merged.
    # This hint tells the coder to EXTEND the seed and STAY OFFLINE: inline SVG / data: URIs for images,
    # NO external URL, and test by importing the server on port 0 (like the seed) -- never a live fetch.
    # Gated on $Web (the resolved scaffold == 'web') so non-web tasks are byte-identical, and it ALWAYS
    # preserves the original prompt verbatim (appended, never replaces). Pure -> unit-tests without a model.
    param([string]$Prompt, [bool]$Web)
    if (-not $Web) { return $Prompt }
    $note = @'
This build ships a pre-wired, DEPENDENCY-FREE Node skeleton that already builds and tests OFFLINE: a `node:http` server in `src/server.js` (REST routes + static files from `public/`), a front-end in `public/index.html` + `public/app.js`, and `node --test` tests in `test/` that import the server and bind an EPHEMERAL port. EXTEND it -- add your feature to these files; do NOT re-scaffold or add a second project, and run `npm test` as you go until it is green.
ACT FIRST -- your FIRST tool call should be an EDIT to `public/index.html`. The seed files and their layout are described right here, so do NOT spend turns reading the seed before you start (every exploratory read is a chance to stall). Edit the page first, then the tests, then run `npm test`.
THE FRONT DOOR -- `public/index.html` is the page a visitor GETS AT `/`. The server mounts the site root to it, so it is the only page anyone reaches without typing a filename.
- If the goal has a home page, a landing page, or a main page, THAT PAGE IS `public/index.html`. Build it there. Do NOT create a second home page beside it (`home.html`, `main.html`, `landing.html`, `start.html`) -- a visitor never reaches it, the site opens on the leftover placeholder, and the delivery looks empty however many pages you wrote.
- Every OTHER page is a sibling file in `public/`, and `public/index.html` must LINK to each one, or there is no way to navigate to them.
- If a shared header or menu is asked for, its "home" link points at `index.html` -- the same page the server serves at `/`. One home page, one name for it, used everywhere.
- Never leave the seed's placeholder content (`<h1>App</h1>`, the lettered circle, `Loading...`) in the delivered `index.html`. If it is still there at the end, the front door was never built.
THE SERVED ROOT -- the server serves `public/` AND NOTHING ELSE (`src/server.js`: `const PUBLIC = join(here, '..', 'public')`). A file outside `public/` exists on disk and is a 404 in the browser.
- EVERYTHING the page loads at runtime lives under `public/`: pages, scripts, styles, images, and any DATA FILE you write. If pages share a data file, put it at `public/data/<name>.json` and fetch `./data/<name>.json` -- writing it to `data/` beside `public/` makes it unreachable, and the page will render its own "Failed to load" message while looking otherwise fine.
- After writing any `fetch('...')`, check the path resolves from `public/` as the root. `fetch('./data/pieces.json')` needs the file at `public/data/pieces.json`.
- A page that catches a failed fetch and shows an error string still COUNTS AS BROKEN. Do not ship a page whose normal state is "Failed to load", "Error", "undefined" or "NaN" -- if you see one of those in your own output, the data path is wrong.
OFFLINE RULES (this box has NO network -- breaking these is why the build fails):
- NEVER reference an external URL: no CDN, no remote image/script/style/font, no `fetch` to the internet. For an image use an inline `<svg>...</svg>` or a `data:` URI -- NOT `<img src="https://...">`. An external asset will not load and any test that requests one will fail.
- TEST OFFLINE, the way the seed does: in a test, `import { server }`, `await new Promise(r => server.listen(0, r))`, read `server.address().port`, `fetch` THAT port, then `server.close()`. Or assert the static files directly (read `public/index.html` and check its contents). NEVER `fetch` a hardcoded port (8081, 3000, ...) you did not start in that same test -- it is connection-refused and the test fails.
- The page is also checkable with the browser tool on a `file:///` path or the localhost port YOU started -- a clean console means done.
'@
    return "$Prompt`n`n--- OFFLINE WEB BUILD (extend the seeded offline skeleton; no external assets) ---`n$note"
}

function Test-WebBuild {
    # IS THIS A WEB BUILD? -- a DIFFERENT question from "should I seed a web scaffold?" (#1367/#1375).
    #
    # THE DEFECT THIS FIXES, measured 2026-08-14. Add-WebHint was gated on `$scaffold -eq 'web'`,
    # and `$scaffold` comes from Resolve-TaskScaffold, whose FIRST line is `if ($HasProject) {
    # return '' }` -- correctly, because its job is to decide what to SEED and it must never
    # clobber an existing project. The consequence nobody had traced: once the sandbox has been
    # seeded, EVERY LATER TASK resolves to '' and the web brief is not injected at all.
    #
    # For a one-task build that is invisible. For a multi-page site it is most of the run: B9
    # authors seven tasks, so ONE dispatch got the web brief and SIX did not. Measured across
    # every banked agent log in state/reports: exactly one contains "OFFLINE WEB BUILD", and it
    # is a 2026-07-27 single-task job. **No B9 coder has ever been shown the web brief.**
    #
    # That is upstream of both of the operator's own eyeball findings. The coder that created
    # `home.html` instead of building `public/index.html` (#1367) had never been told which file
    # a visitor reaches; the coder that wrote `fetch('./data/pieces.json')` against a file outside
    # the served root (#1375) had never been told what the server serves. Both briefs existed and
    # neither was delivered.
    #
    # Returns $true when this task builds into a web project, by any of three independent signals.
    # Deliberately NOT a rename of the scaffold question: the seeding decision stays exactly as it
    # is, because it is correct.
    param(
        [string]$Scaffold = '',      # the RESOLVED scaffold (fresh dispatches only)
        [string]$Surface = '',       # the planner's declared surface, if any
        [string]$ProjectRoot = ''    # the worktree, to ask what the tree actually IS
    )
    # 1. Today's signal, preserved byte-for-byte: a fresh dispatch that seeds the web scaffold.
    if ($Scaffold -eq 'web') { return $true }
    # 2. The planner declared a web surface. True whether or not a project already exists, which
    #    is precisely the case the scaffold question has to answer 'no' to.
    if ($Surface) {
        $p = Resolve-BuildProfile -Surface $Surface
        if ($p.scaffold -eq 'web') { return $true }
    }
    # 3. The tree IS the web seed. BOTH markers are required -- `public/` alone appears in plenty
    #    of non-web projects, and `src/server.js` alone is a bare node service. Together they are
    #    this scaffold's signature, and requiring both keeps a python or dotnet repo from ever
    #    collecting web instructions it cannot act on.
    if ($ProjectRoot) {
        $hasPublic = Test-Path -LiteralPath (Join-Path $ProjectRoot 'public') -PathType Container
        $hasServer = Test-Path -LiteralPath (Join-Path $ProjectRoot 'src/server.js') -PathType Leaf
        if ($hasPublic -and $hasServer) { return $true }
    }
    return $false
}

function Test-WebStaticBuild {
    # The web-static sibling of Test-WebBuild, fixed in the SAME change because the reasoning
    # that found the web defect is a PREDICATE, not an explanation of one site (lesson 342).
    #
    # Swept every hint injected by new-agent-task.ps1 on 2026-08-14. Five gate on something
    # sound -- the upstream complexity signal, the build PROFILE (computed straight from the
    # surface, never through Resolve-TaskScaffold), or the worktree. Exactly ONE shared the
    # web hint's defect: `Add-WebStaticHint` was gated on `$scaffold -eq 'web-static'`, and
    # `$scaffold` returns '' the moment a project exists. So a multi-task static site briefs
    # its seeding dispatch and no other -- the same silence, in the one other place it could
    # occur, latent rather than measured only because web-static has run once.
    #
    # Its seed is the opposite shape to the web one: ONE self-contained `index.html` at the
    # ROOT, with deliberately no package.json, no src/server.js, no public/ (#886). So the
    # tree signature is index.html PLUS the ABSENCE of the server-scaffold markers, which
    # also makes it mutually exclusive with Test-WebBuild -- a tree cannot answer yes to both.
    param(
        [string]$Scaffold = '',
        [string]$Surface = '',
        [string]$ProjectRoot = ''
    )
    if ($Scaffold -eq 'web-static') { return $true }
    if ($Surface) {
        $p = Resolve-BuildProfile -Surface $Surface
        if ($p.scaffold -eq 'web-static') { return $true }
    }
    if ($ProjectRoot) {
        $hasIndex  = Test-Path -LiteralPath (Join-Path $ProjectRoot 'index.html') -PathType Leaf
        $hasPkg    = Test-Path -LiteralPath (Join-Path $ProjectRoot 'package.json') -PathType Leaf
        $hasServer = Test-Path -LiteralPath (Join-Path $ProjectRoot 'src/server.js') -PathType Leaf
        $hasPublic = Test-Path -LiteralPath (Join-Path $ProjectRoot 'public') -PathType Container
        if ($hasIndex -and -not $hasPkg -and -not $hasServer -and -not $hasPublic) { return $true }
    }
    return $false
}

function Add-WebStaticHint {
    # STATIC-PAGE PROMPT (#886, 2026-07-15): a `web-static` scaffold ships a SINGLE self-contained
    # `index.html` (inline <style>, inline <svg>, inline <script> plain DOM) and NOTHING else -- no
    # package.json, no src/server.js, no public/app.js, no fetch. It is the correct seed for an ask
    # that explicitly excludes a server/build step ("one index.html file... opens correctly in a
    # browser"). The live failure this prevents: the `web` seed's node:http server + public/app.js
    # that fetches `/api/health` left a "Loading..." box stuck forever when the page was opened as
    # file:// (no backend). This hint tells the coder to EXTEND THE ONE FILE and stay static +
    # offline -- do NOT add a server, a build step, a package.json, or any fetch. Gated on $WebStatic
    # (the resolved scaffold == 'web-static') so every other task is byte-identical, and it ALWAYS
    # preserves the original prompt verbatim (appended, never replaces). Pure -> unit-tests without a model.
    param([string]$Prompt, [bool]$WebStatic)
    if (-not $WebStatic) { return $Prompt }
    $note = @'
This build ships ONE self-contained `index.html` (inline `<style>`, inline `<svg>` images, inline `<script>` using plain DOM) that opens straight in a browser with NO build step and NO server. EXTEND THAT ONE FILE -- do NOT add a `package.json`, a `src/server.js`, a `public/app.js`, a build tool, a framework, or a second project.
ACT FIRST -- your FIRST tool call should be an EDIT to `index.html`. The seed marks its placeholder content with `class="placeholder"` and an "EXTEND THIS FILE" comment; REPLACE that placeholder with the real content the goal asks for (never leave the placeholder text as the final page).
STATIC + OFFLINE RULES (this box has NO network, and there is NO backend -- breaking these is why the page fails):
- NO server, NO `fetch`, NO backend call, NO build step. Everything is inline in the one HTML file. There is no `/api/...` to call -- a page that waits on a fetch will hang forever when opened as `file://`.
- NEVER reference an external URL: no CDN, no remote image/script/style/font. For an image use an inline `<svg>...</svg>` or a `data:` URI -- NOT `<img src="https://...">` (a remote asset will not load offline).
- Put your JavaScript in an inline `<script>` in the same file using plain DOM (`document.querySelector`, event listeners) -- no `import`, no module, no external `.js` file.
- Verify by opening the page with the browser tool on its `file:///` path -- a rendered page with a clean console (no errors, nothing stuck "Loading...") means done.
'@
    return "$Prompt`n`n--- STATIC WEB PAGE (extend the ONE self-contained index.html; no server, no build, no fetch) ---`n$note"
}

function Add-AssetHint {
    # ASSET-CONSUMPTION PROMPT (#714, UC-010 SEAM A): when BlarAI's on-device image generator
    # PRE-GENERATED real raster image assets into the target repo BEFORE the coder ran, tell the
    # coder to REFERENCE the local file offline instead of drawing an <svg> placeholder or (worse)
    # reaching for a CDN. DYNAMIC + gated on ACTUAL FILE PRESENCE in the seeded worktree -- NOT on
    # $scaffold, because a real pre-existing project resolves to an EMPTY scaffold, so a scaffold
    # gate would MISS it (the exact seam-bug class the LESSONS warn about). No asset files present
    # -> a NO-OP (the inline-SVG fallback in Add-WebHint / AGENTS.md stands). The "no external URL"
    # rule is UNCHANGED -- a local relative path is not egress. ALWAYS preserves the original prompt
    # verbatim (appended, never replaces). Pure-ish (reads the filesystem); a bad/missing worktree
    # is a no-op. PS 5.1 + 7 compatible.
    param([string]$Prompt, [string]$Worktree, [string]$Surface)
    if (-not $Worktree -or -not (Test-Path -LiteralPath $Worktree)) { return $Prompt }
    $exts = @('.png', '.jpg', '.jpeg', '.webp', '.gif')
    # (asset dir under the worktree) -> (the offline reference PREFIX the coder writes). A web app
    # serves public/ as its root, so a file at public/assets/x.png is referenced as assets/x.png.
    $mapping = @(
        @{ Dir = 'public/assets'; Ref = 'assets' },
        @{ Dir = 'assets';        Ref = 'assets' },
        @{ Dir = 'Assets';        Ref = 'Assets' }
    )
    $refs = New-Object System.Collections.Generic.List[string]
    foreach ($m in $mapping) {
        $dir = Join-Path $Worktree $m.Dir
        if (-not (Test-Path -LiteralPath $dir)) { continue }
        Get-ChildItem -LiteralPath $dir -File -ErrorAction SilentlyContinue | ForEach-Object {
            if ($exts -contains $_.Extension.ToLower()) { $refs.Add("$($m.Ref)/$($_.Name)") }
        }
    }
    if ($refs.Count -eq 0) { return $Prompt }
    $isWeb = ($Surface -eq 'web') -or (Test-Path -LiteralPath (Join-Path $Worktree 'public'))
    $bullets = [string]::Join("`n", ($refs | ForEach-Object { "  - $_" }))
    if ($isWeb) {
        $howTo = 'For each, use a RELATIVE <img src="RELPATH"> tag (e.g. <img src="assets/elephant.png">). The file is served from public/, so the assets/... path resolves. Do NOT inline an <svg> in its place and do NOT use any http(s):// URL.'
    } else {
        $howTo = 'For each, reference the LOCAL file by its relative path (for a desktop app, point an Image/BitmapImage at the packaged asset). Do NOT redraw it and do NOT use any http(s):// URL.'
    }
    # PROVENANCE-NEUTRAL BY DESIGN (2026-08-06). This block used to tell the coder "BlarAI
    # already GENERATED the image asset(s) ... ON THIS BOX" -- but the scan above globs the
    # assets folder, which holds BOTH machine-generated images AND files the OPERATOR
    # supplied himself (the #1165 M5 intake pipeline, live since 2026-07-29). So an
    # operator's own photograph was described to the coder as machine output: a false
    # provenance claim, the #1172 class pointing the other way.
    #
    # The coder does not need to know WHO made them, and telling it wrongly is worse than
    # not telling it at all. What it needs is: they exist, use them, do not redraw, do not
    # fetch. That is all this says now.
    $note = @"
The image asset(s) this app needs are ALREADY IN YOUR WORKING TREE and committed. USE the local file(s) -- do NOT draw a placeholder <svg> for them, and NEVER reference an external URL:
$bullets
$howTo These files already exist in your tree (open one to confirm). A local relative path is NOT a network request -- it is the offline-correct way to show a real picture.
"@
    return "$Prompt`n`n--- IMAGE ASSETS IN YOUR TREE (use the local files; do not redraw or fetch) ---`n$note"
}

function Format-SmokeResultQualifier {
    # THE RESULT LINE MUST NOT OUTRANK THE INSTRUMENT. A web delivery whose DECLARED behaviour
    # contract was exercised and FAILED still signed off as "MERGED into your project - just open
    # the app and try it." -- the system's own browser check had reported that the declared result
    # region did not change when the declared primary control was used, three automatic fix passes
    # had then failed, and the last line of the report told the operator it was fine. Observed live
    # 2026-08-06 (fleet run 20260806-171303-bd, job create-habit-tracking).
    #
    # This adds a QUALIFIER and nothing else: no control flow moves, nothing blocks, nothing parks.
    # The merge already happened and stays; the sentence describing it stops overstating.
    #
    # PURE -> unit-tested without a browser, a capture or a coder (verify-smoke-contract.ps1). It is
    # a FUNCTION rather than an inline string in new-agent-task.ps1's here-string for the same
    # reason as Format-VisualCritiqueSummary: an inline string cannot be tested, so nothing could
    # prove the disclosure survives -- nor that it stays SILENT where it must.
    #
    # SILENCE IS THE DEFAULT AND IT IS LOAD-BEARING. Only a DECLARED contract speaks here, and only
    # in the two states the DELIVERY is answerable for. In particular the HEURISTIC no-delta -- the
    # capture guessing at "the first visible enabled control" because nothing was declared -- must
    # stay a soft note forever: a page with no button to press would otherwise carry a permanent
    # failure notice on a verdict nobody ever asked for. That is the #1140 shape ("a project with no
    # XAML is not an unexamined layout"), and the OFF cases in the suite exist to hold this line.
    #
    # TWO DIFFERENT SENTENCES, BECAUSE THEY ARE TWO DIFFERENT FACTS, and an operator must be able to
    # tell them apart from the RESULT line alone:
    #   * EXERCISED AND FAILED ($Measured, not $Passed) -- the control was pressed and the marked
    #     region did not change. The feature is there and does not work.
    #   * DECLARED AND NEVER EXERCISABLE ($Status is one of the two *-hook-missing) -- the coder was
    #     TOLD by Add-SmokeContractHint to place both markers and did not, so the check had nothing
    #     to press. Nothing was checked, so this branch must not say the check FAILED; it says the
    #     part is not on the page. That is the delivery's failure to build what it was asked for --
    #     the same overstatement as the failure case, which is why it qualifies the same line.
    #
    # $Status IS REQUIRED TO SPLIT THEM AND THE BOOLEANS CANNOT. A hook-missing capture and a capture
    # that CRASHED after reading a valid spec ('unavailable') are both Declared + not-Measured; only
    # the status separates them. The crash is the HARNESS's fault -- behavior.ran is false, no
    # finding was raised -- and blaming the delivery for it is the exact confusion
    # Format-SmokeContractCaveat was split apart to stop making. So the unexercised branch is an
    # ALLOWLIST of the two delivery-fault statuses, never a blocklist of the harness ones: a status
    # this side does not recognise (the JS half renames a constant, a legacy producer) resolves to
    # SILENCE here and stays the caveat channel's to disclose, because asserting a cause on evidence
    # this side cannot parse is how a wrong diagnosis reaches a non-technical reader as a fact.
    #
    # $Passed is positive-polarity: $false is "not affirmed", which covers both a real failure and a
    # capture that never stated the verdict. The failure wording therefore claims only what both
    # share -- the check did not come back clean -- and never narrates a mechanism it cannot see.
    # ASCII-folded like the other report blocks (Set-Content follows the HOST encoding, so unfolded
    # prose is mojibake on one of PS 5.1 / PS 7, and this is the one line that must be readable).
    param([bool]$Declared = $false, [bool]$Measured = $false, [bool]$Passed = $false,
          [string]$Status = '')
    if (-not $Declared) { return '' }
    if ($Measured) {
        if ($Passed) { return '' }
        return (ConvertTo-FleetAscii -Text (
            " (But the automatic browser check did NOT pass: it used the main control this task was " +
            "meant to make work and could not confirm the page responded, so the new part may not " +
            "actually work yet - please try that step first.)"))
    }
    if ($Status -eq 'action-hook-missing' -or $Status -eq 'result-hook-missing') {
        return (ConvertTo-FleetAscii -Text (
            " (But the automatic browser check could not run: the part this task was meant to add " +
            "is not on the page at all, so it looks like it was never built - please check whether " +
            "what you asked for is actually there.)"))
    }
    return ''
}

function Add-SmokeContractHint {
    # BEHAVIOR-CONTRACT PROMPT: when BlarAI's PLAN declared what the finished page must be able to
    # DO, tell the coder the two DOM markers a headless browser will look for. Without this the
    # capture's declared behavior check has nothing to key on and falls back to guessing at "the
    # first visible button" -- and a guess that fails is only a soft note, never a finding. That is
    # what every web build did before the plan-side writer existed.
    #
    # TELLING IS THE POINT. A check the coder was never informed of grades it against a contract it
    # had no way to meet, which manufactures false defects and burns fix cycles. This is the "TOLD"
    # half of capability 3 in BlarAI's docs/design/CODER_DEFINITION_OF_DONE.md; the capture is the
    # "GRADED" half. The markers are `data-` attributes -- valid HTML, invisible to the user, the
    # same shape as the `data-testid` convention -- so they cost the delivery nothing.
    #
    # DYNAMIC + gated on ACTUAL FILE PRESENCE in the seeded worktree, exactly like Add-AssetHint and
    # for the same reason: the file is present iff the PLAN declared a contract, which is a fact
    # about this dispatch, not about the scaffold. No file -> a NO-OP and the prompt is byte-
    # identical. The selectors are read FROM THE FILE, never written as a literal here, so the
    # marker the coder is told to place and the marker the capture hunts for cannot drift apart.
    # Fail-soft: an unreadable or malformed file is a no-op (the capture reports that same fact on
    # its own side). ALWAYS preserves the original prompt verbatim (appended, never replaces).
    param([string]$Prompt, [string]$Worktree)
    if (-not $Worktree -or -not (Test-Path -LiteralPath $Worktree)) { return $Prompt }
    $specPath = Join-Path $Worktree 'blarai-smoke.json'
    if (-not (Test-Path -LiteralPath $specPath)) { return $Prompt }
    try { $spec = Get-Content -LiteralPath $specPath -Raw -Encoding UTF8 | ConvertFrom-Json } catch { return $Prompt }
    if (-not $spec) { return $Prompt }
    $click = [string]$spec.click
    $delta = [string]$spec.expectDelta
    if (-not $click -or -not $delta) { return $Prompt }
    $actionLabel = if ($spec.actionLabel) { [string]$spec.actionLabel } else { 'the main control' }
    $resultLabel = if ($spec.resultLabel) { [string]$spec.resultLabel } else { 'the part of the page that changes' }
    # The worked example is DERIVED from this contract's own selectors, never written as a literal.
    # A fixed example would keep naming one marker no matter what the contract said, which is the
    # same drift hazard the selectors themselves avoid by being read from the file -- and to a small
    # model a concrete example that contradicts the requirement above it is worse than none.
    $howTo = "Add the matching attribute or id to each element so those selectors resolve."
    if ($click -match '^\[([\w-]+)="([^"]+)"\]$') {
        $howTo = "For $click write the attribute onto the element itself, e.g. <button $($Matches[1])=`"$($Matches[2])`">...</button>. Do the same for $delta on the result element."
    } elseif ($click -match '^#([\w-]+)$') {
        $howTo = "For $click give the element that id, e.g. <button id=`"$($Matches[1])`">...</button>. Do the same for $delta on the result element."
    }
    $note = @"
An automated browser will open your finished page, use its main control, and check that the page actually responds. It finds both by a marker you must put in your HTML:
  - $actionLabel -> must match the selector $click
  - $resultLabel -> must match the selector $delta
$howTo Put the markers on the REAL elements -- the control a person actually presses, and the region whose content actually changes when they press it.
The check then presses that control and requires the marked region to CHANGE. A page where the marked control is missing, is hidden or disabled, or leaves the marked region unchanged is a FAILURE and comes back to you to fix. Do NOT put a marker on a decorative element to satisfy the check, and do NOT fake the change -- make the feature work.
Markers cost the page nothing: an id or a data- attribute is valid HTML, invisible to the user, and has no effect on styling or layout.
"@
    return "$Prompt`n`n--- WHAT THE AUTOMATED BROWSER CHECK WILL DO (mark these two elements) ---`n$note"
}

function Save-SmokeContractPin {
    # A CANDIDATE CANNOT EDIT THE EXAM IT IS ABOUT TO SIT. The contract file is seeded into the
    # baseline so the coder can be TOLD what the capture will exercise -- which puts it in the tree
    # the coder writes to, for the whole build. A candidate that writes {"click":"body",
    # "expectDelta":"body"} makes its own critique report `honoured` while the real contract was
    # never exercised: not a false GREEN at run level (the post-merge design lap re-grades against
    # pinned bytes) but a false CLEAN at the hop that spends the coder's FIX BUDGET, which defers
    # the real finding into the smaller design-lap budget.
    #
    # BlarAI's swap driver pins the plan's bytes before its two post-merge captures
    # (`_pin_smoke_contract`). This is the same control at the PER-TASK critique hop, which runs
    # against the candidate worktree with its own fix cycle and was not covered by that pin.
    #
    # Snapshot the RAW BYTES while they are still the plan's -- before the coder has run. Bytes,
    # not a re-serialisation: acceptance.py's `smoke_spec_file_bytes` is the ONE authority for this
    # file's content, and a second writer here could only drift from it. $null when there is no
    # contract (every non-web dispatch), and the restore is then a no-op.
    param([string]$Worktree)
    if (-not $Worktree -or -not (Test-Path -LiteralPath $Worktree)) { return $null }
    $specPath = Join-Path $Worktree 'blarai-smoke.json'
    if (-not (Test-Path -LiteralPath $specPath)) { return $null }
    try { return [System.IO.File]::ReadAllBytes($specPath) } catch { return $null }
}

function Restore-SmokeContractPin {
    # Write the pinned bytes back immediately before a capture reads them. On an untampered tree
    # this is a byte-for-byte no-op that leaves no diff; on a tampered one it is a RESTORE. Called
    # before EVERY critique pass rather than once at loop entry, because the fix cycle hands the
    # tree back to the coder between passes -- pinning once would cover only the first capture,
    # which is the same reason the design lap re-pins.
    #
    # Structural, not vigilance: nothing has to NOTICE the tampering for the control to hold.
    # Fail-soft and returns nothing -- a contract write must never derail the critique that calls
    # it, exactly as on the BlarAI side.
    param([string]$Worktree, $PinBytes)
    if ($null -eq $PinBytes -or -not $Worktree -or -not (Test-Path -LiteralPath $Worktree)) { return }
    try { [System.IO.File]::WriteAllBytes((Join-Path $Worktree 'blarai-smoke.json'), $PinBytes) } catch { }
}

function Resolve-BuildProfile {
    # INCREMENT-1 FLEET CONSUMER (#675): turn the upstream 14B's COARSE platform classification
    # (`surface`, + optional `language_hint`) into the concrete build PROFILE the system curates --
    # the scaffold to seed, the structural contract the fail-fast gate enforces, and whether the
    # surface has a testable-core/shell split (staged). This is the deterministic SYSTEM half of the
    # ownership model: the operator writes product intent, the 14B classifies the surface, and THIS
    # function (curated, version-aware) maps that classification into engineering. Pure -> unit-tested
    # without a model or a worktree.
    #
    #   -Surface      : desktop-gui|web|mobile|command-line|automation|library|unknown (the primary signal)
    #   -LanguageHint : python|dotnet|node|cpp|powershell|null -- refines the AMBIGUOUS surfaces only
    #                   (command-line, library); the system NEVER guesses a language the 14B didn't signal.
    #
    # Returns @{ scaffold=<name|''>; structural_contract=<hashtable|$null>; staged=<bool> }.
    # An ABSENT/unknown/unrecognised surface returns the EMPTY profile (scaffold '', contract $null,
    # staged $false) -- so the caller falls through to today's heuristic and the struct gate no-ops.
    # This is the strictly-additive contract: never worse than now.
    param([string]$Surface, [string]$LanguageHint = '')
    $s = if ($Surface) { $Surface.Trim().ToLower() } else { '' }
    $h = if ($LanguageHint) { $LanguageHint.Trim().ToLower() } else { '' }

    # The single curated home for the WinUI structural contract the fail-fast gate (Test-ProjectStructure)
    # enforces. It encodes the EXACT proliferation we watched park: the real WinUI app PLUS a Console-style
    # Program.cs with its own Main(), a 2nd test project, and loose top-level-statement .cs runner files.
    $winuiContract = @{
        max_projects                     = 1
        project_globs                    = @('*.csproj')
        entry_points                     = @('App.xaml.cs')
        forbid_extra_entry_points        = $true
        forbid_top_level_statements_outside = @('App.xaml.cs')
        test_dir                         = 'Tests/'
    }

    # command-line / library are language-ambiguous: refine by the hint, else a per-surface house default.
    $byHint = @{ python = 'python'; dotnet = 'dotnet-console'; node = 'node-cli'; cpp = 'cpp'; powershell = 'powershell' }
    $libByHint = @{ python = 'python'; dotnet = 'dotnet-console'; node = 'node-cli'; cpp = 'cpp'; powershell = 'powershell' }

    switch ($s) {
        'desktop-gui'  { return @{ scaffold = 'winui';   structural_contract = $winuiContract; staged = $true } }
        'web'          { return @{ scaffold = 'web';      structural_contract = $null;          staged = $false } }
        'web-static'   { return @{ scaffold = 'web-static'; structural_contract = $null;        staged = $false } }
        'mobile'       { return @{ scaffold = 'android';  structural_contract = $null;          staged = $false } }
        'command-line' {
            # House default is PYTHON, consistent with `library` below: a Python-centric local
            # AI whose acceptance oracles are Python (tests/test_job_acceptance.py) defaults an
            # ambiguous CLI (no language_hint) to Python, NOT .NET. An explicit hint still wins
            # ($byHint: dotnet -> dotnet-console, node -> web, ...), and an explicit "C#/console
            # app" prompt is caught upstream by Resolve-TaskScaffold's keyword heuristic. (#740:
            # under the old .NET default both battery arms B1/B2 built C# for Python-oracle jobs
            # -> guaranteed park; the default was measuring a language mismatch, not capability.)
            $sc = if ($h -and $byHint.ContainsKey($h)) { $byHint[$h] } else { 'python' }
            return @{ scaffold = $sc; structural_contract = $null; staged = $false }
        }
        'automation'   { return @{ scaffold = 'powershell'; structural_contract = $null;        staged = $false } }
        'library'      {
            $sc = if ($h -and $libByHint.ContainsKey($h)) { $libByHint[$h] } else { 'python' }
            return @{ scaffold = $sc; structural_contract = $null; staged = $false }
        }
        default        { return @{ scaffold = ''; structural_contract = $null; staged = $false } }   # unknown / unrecognised -> the fall-back path
    }
}

function Test-ProjectStructure {
    # INCREMENT-2 STRUCTURAL FAIL-FAST GATE (#675): given a worktree path + a profile's
    # structural_contract, return a VIOLATION string (or '' if clean) -- run EARLY (before the
    # expensive build) so the exact 30-min-churn-to-park we watched becomes a seconds-fast,
    # recoverable loop (the violation routes through the existing error-feedback channel). Pure +
    # injectable (the path is read, but no git / no build / no model) so it unit-tests directly.
    #
    # The WinUI contract enforces (the proliferation case):
    #   - exactly one *.csproj                                  (max_projects / project_globs)
    #   - no rogue extra entry point: no Program.cs and no
    #     `static ... Main(` outside the allowed entry          (forbid_extra_entry_points)
    #   - no loose top-level-statement .cs outside the entry    (forbid_top_level_statements_outside)
    #
    # FAIL-CLOSED ON A DEFINED CONTRACT, NO-OP ON AN UNDEFINED ONE: a $null contract (the `unknown`
    # surface, today's behaviour) returns '' immediately -- it can NEVER false-fail a path we did not
    # define. HIGH-PRECISION: it only flags the unambiguous proliferation signatures so the fleet's
    # auto-recovery can trust it.
    param(
        [Parameter(Mandatory)][string]$Worktree,
        $Contract = $null
    )
    if ($null -eq $Contract) { return '' }                 # no contract -> proven NO-OP (today's behaviour)
    if (-not (Test-Path $Worktree)) { return '' }          # nothing to judge -> never a false-fail

    # bin/obj/.git are build/VCS output, never deliverables -- exclude them from every scan.
    $exclude = '\\(bin|obj|\.git)\\'

    # (1) PROJECT COUNT: exactly $max_projects matching any of $project_globs.
    $globs = @($Contract.project_globs); if ($globs.Count -eq 0) { $globs = @('*.csproj') }
    $maxProj = if ($null -ne $Contract.max_projects) { [int]$Contract.max_projects } else { 1 }
    $projFiles = @(Get-ChildItem -Path $Worktree -Recurse -File -Include $globs -ErrorAction SilentlyContinue |
                     Where-Object { $_.FullName -notmatch $exclude })
    if ($projFiles.Count -gt $maxProj) {
        $names = ($projFiles | ForEach-Object { $_.Name } | Sort-Object -Unique) -join ', '
        return "found $($projFiles.Count) project files ($names) but this app must be exactly ONE project. Keep a single *.csproj; do NOT add a second project (e.g. a separate console or test .csproj)."
    }

    # The allowed entry-point set (basenames) -- a .cs that IS an allowed entry is exempt from the
    # rogue-entry and top-level-statement checks below.
    $entries = @(@($Contract.entry_points) | Where-Object { $_ } | ForEach-Object { [string]$_ })
    $tlsAllowed = @(@($Contract.forbid_top_level_statements_outside) | Where-Object { $_ } | ForEach-Object { [string]$_ })
    $isEntry = { param($name) ($entries -contains $name) }

    $csFiles = @(Get-ChildItem -Path $Worktree -Recurse -File -Filter *.cs -ErrorAction SilentlyContinue |
                   Where-Object { $_.FullName -notmatch $exclude })

    # (2) FORBID EXTRA ENTRY POINTS: a Program.cs (the Console template's hallmark) or any non-entry
    # .cs declaring `static ... Main(` -- a WinExe WinUI app's Main is generated by the SDK, so a
    # hand-written one is the proliferation signature (CS0017 multiple-entry / CS8803).
    if ($Contract.forbid_extra_entry_points) {
        foreach ($f in $csFiles) {
            if (& $isEntry $f.Name) { continue }
            if ($f.Name -ieq 'Program.cs') {
                return "found a rogue entry point 'Program.cs'. This is a WinUI app -- the entry is $($entries -join ', ') (App.xaml.cs). Do NOT add a Program.cs or a console Main()."
            }
            $txt = [string](Get-Content -LiteralPath $f.FullName -Raw -ErrorAction SilentlyContinue)
            # Strip // line comments and /* */ block comments first so a commented-out or documented
            # "static Main" mention cannot trip the detector (a comment is not a second entry point).
            $code = [regex]::Replace($txt, '(?s)/\*.*?\*/', '')
            $code = [regex]::Replace($code, '(?m)//.*$', '')
            # The C# program entry signature is `static ... Main(`. Match `static` followed by `Main(`
            # within the SAME statement (no ; { } in between) so it tolerates an access modifier on
            # EITHER side and any return type (public static int Main(...), static async Task Main(...),
            # internal static void Main()), while a member merely NAMED Main on an instance (no static)
            # or in another statement does not trip it. The previous \w-class form could not cross the
            # `class X {` brace when the modifier+class+method were on one logical line (the Boot.cs miss).
            if ($code -match '(?s)\bstatic\b[^;{}]*\bMain\s*\(') {
                return "found a second program entry point (a static Main) in '$($f.Name)'. This is a WinUI app -- the entry is $($entries -join ', ') (App.xaml.cs). Remove the extra Main()."
            }
        }
    }

    # (3) FORBID LOOSE TOP-LEVEL STATEMENTS: a .cs (outside the allowed entry) whose first MEANINGFUL
    # line is an executable statement rather than a type/namespace declaration. Loose top-level-statement
    # files alongside a WinExe are the CS8803 proliferation we watched. HIGH-PRECISION: a file is only
    # flagged when its first real token is clearly a statement, never a declaration (class/namespace/
    # record/enum/struct/interface/delegate/attribute/modifier) -- so a normal class file never false-fails.
    if ($tlsAllowed.Count -gt 0 -or $Contract.forbid_extra_entry_points) {
        foreach ($f in $csFiles) {
            if ($tlsAllowed -contains $f.Name) { continue }
            if (& $isEntry $f.Name) { continue }
            $first = Get-FirstCodeToken -Path $f.FullName
            if ($first -eq 'STATEMENT') {
                return "found loose top-level statements in '$($f.Name)' (executable code at file scope, outside a class). A WinExe project allows top-level statements in only ONE file; put logic inside a class (e.g. a Calculator class) and tests under $($Contract.test_dir). Do NOT scatter runner/validation .cs files with top-level statements."
            }
        }
    }

    return ''
}

function Get-FirstCodeToken {
    # Helper for Test-ProjectStructure (#675): classify a C# file's FIRST meaningful line as a
    # 'DECLARATION' (namespace/type/attribute/modifier -- a normal source file) or a 'STATEMENT'
    # (executable code at file scope -- a top-level-statement file). Skips blank lines, // and /* */
    # comments, #-directives (#define/#region/#nullable...), using/global-using/extern-alias lines, and
    # assembly/module-level + standalone attribute lines (all of which legitimately precede a declaration,
    # or stand alone in an AssemblyInfo.cs). Returns 'DECLARATION', 'STATEMENT', or '' (nothing
    # classifiable). Deliberately CONSERVATIVE: anything that opens a declaration -> DECLARATION, so the
    # gate never false-fails an ordinary class. Pure (reads the file only).
    param([Parameter(Mandatory)][string]$Path)
    $raw = [string](Get-Content -LiteralPath $Path -Raw -ErrorAction SilentlyContinue)
    if (-not $raw) { return '' }
    # Strip block comments first so a leading /* ... */ banner never hides the first real token.
    $raw = [regex]::Replace($raw, '(?s)/\*.*?\*/', '')
    $declRe = '^\s*(?:\[[^\]]*\]\s*)*(?:public|private|internal|protected|partial|sealed|abstract|static|file|unsafe|readonly|ref|namespace|class|struct|interface|enum|record|delegate)\b'
    foreach ($line in ($raw -split "`r?`n")) {
        $t = $line.Trim()
        if ($t -eq '') { continue }
        if ($t.StartsWith('//')) { continue }
        if ($t.StartsWith('#')) { continue }                       # preprocessor directive
        if ($t -match '^\s*(?:global\s+)?using\b') { continue }    # using / global using
        if ($t -match '^\s*extern\s+alias\b') { continue }
        if ($t -match '^\[\s*(?:assembly|module)\s*:') { continue } # assembly/module-level attribute -- metadata (e.g. a hand-written AssemblyInfo.cs), NOT a statement
        if ($t -match '^\[[^\]]*\]$') { continue }                 # a standalone attribute line on its own -- decorates the NEXT line; let that line classify
        if ($t -match $declRe) { return 'DECLARATION' }
        return 'STATEMENT'
    }
    return ''
}

function Resolve-TaskScaffold {
    # C1 SCAFFOLD SEEDING -- decide which known-good skeleton (if any) to seed into a FRESH target's
    # worktree so the coder EXTENDS a compiling project instead of hand-authoring boilerplate from
    # scratch (where a small model trips on e.g. the WinUI `using Microsoft.UI.Xaml;` -> CS0246).
    # Pure + injectable (HasProject is passed in) so it unit-tests without a worktree.
    #   -Explicit    : 'auto' (detect from the prompt), 'none'/'' (force off), or a scaffold name to force.
    #   -HasProject  : does the worktree ALREADY contain a project? Then NEVER seed (do not clobber).
    #   -Surface     : INCREMENT-1 (#675) the upstream 14B's coarse platform label. When set+KNOWN,
    #                  the curated Resolve-BuildProfile decides the scaffold (the SYSTEM owns tech) and
    #                  PREEMPTS the keyword heuristic. On 'unknown'/absent/unrecognised, fall through to
    #                  TODAY'S keyword/-HasProject heuristic UNCHANGED -- strictly additive, never worse.
    #   -LanguageHint: refines the ambiguous surfaces (command-line, library) inside Resolve-BuildProfile.
    # Returns the scaffold name to seed, or '' for none. A miss is safe -- the coder hand-authors and
    # error-feedback backstops the slip; seeding is a HELP, not a hard dependency.
    param([string]$Prompt, [bool]$HasProject, [string]$Explicit = 'auto', [string]$Surface = '', [string]$LanguageHint = '')
    if ($HasProject) { return '' }
    # An explicit force/off still wins over the surface (operator/caller override, safety first).
    if ($Explicit -and $Explicit -ne 'auto') {
        if ($Explicit -eq 'none') { return '' }
        return $Explicit
    }
    # INCREMENT-1: prefer the curated profile when the 14B gave a KNOWN surface. The profile's scaffold
    # is '' for unknown/unrecognised, so this falls through to the heuristic below -- exactly today's path.
    if ($Surface) {
        $profile = Resolve-BuildProfile -Surface $Surface -LanguageHint $LanguageHint
        if ($profile.scaffold) { return $profile.scaffold }
    }
    # Python (incl. its web frameworks) -- a language-correct match wins over the generic web check.
    if ($Prompt -match '(?i)(\bpython\b|\bpytest\b|\bpandas\b|\bnumpy\b|\bpip\b|\.py\b|\bflask\b|\bdjango\b|\bfastapi\b)') { return 'python' }
    # Web / JavaScript / Node: front-end, back-end, or REST API.
    if ($Prompt -match '(?i)(\bweb\b|\bwebsite\b|\bwebpage\b|\bweb\s?app\b|\bweb page\b|\bfront[- ]?end\b|\bback[- ]?end\b|\bbrowser\b|\bhtml\b|\bcss\b|\bjavascript\b|\bnode\.?js\b|\bexpress\b|\breact\b|\bvue\b|\bangular\b|\bsvelte\b|\.js\b|\brest\s?api\b|\bweb service\b|\bendpoint\b)') { return 'web' }
    # Android (.NET Android app). BUILD signals only -- "android" PLUS an app-build noun, or an .apk -- so a
    # mere mention ("back up my android phone") does NOT hijack a powershell/python task. Ordered BEFORE winui
    # so "a .NET MAUI Android app" seeds android (mobile), not the desktop winui scaffold. Builds offline from
    # the local cache (JDK 17 + Android SDK installed; JAVA_HOME/ANDROID_HOME are machine/user-set).
    if (($Prompt -match '(?i)\.apk\b') -or (($Prompt -match '(?i)\bandroid\b') -and ($Prompt -match '(?i)\b(app|application|activity|apk|game|widget)\b'))) { return 'android' }
    # Strong desktop/WinUI signals, OR a "window"/"desktop" paired with a GUI term (a windowed app,
    # not a console/web tool). The "desktop"+UI-noun arm catches "a C# desktop calculator with buttons".
    $strong = '(?i)\b(win\s?ui|wpf|win32|maui|desktop\s+(app|application|gui|program|tool)|gui\s+(app|application)|native\s+windows|\.exe)\b'
    $windowed = ($Prompt -match '(?i)\b(window|desktop)\b') -and ($Prompt -match '(?i)\b(resize|maximize|minimize|title\s?bar|taskbar|calculator|button|menu|app|application|shaped|icon)\b')
    if (($Prompt -match $strong) -or $windowed) { return 'winui' }
    # PowerShell: explicit signals (a script/module/automation task). The networking + NAS knowledge
    # packs build on this scaffold once they exist.
    if ($Prompt -match '(?i)(\bpowershell\b|\bpwsh\b|\.ps1\b|\bcmdlet\b|\bpester\b|\.psm1\b)') { return 'powershell' }
    # C++: explicit signals. NOTE: no trailing \b after c++/g++ -- '+' is a non-word char, so '\bc\+\+\b'
    # fails to match "C++ " (a word boundary needs a word/non-word transition; '+'->space is non/non).
    if ($Prompt -match '(?i)(\bc\+\+|\bcpp\b|\bcmake\b|\.cpp\b|\.hpp\b|std::|\bg\+\+|\bmsvc\b)') { return 'cpp' }
    # .NET / C# console -- a non-desktop, non-web .NET target. Ordered LAST on purpose so the MORE-
    # SPECIFIC powershell (.ps1/pwsh/cmdlet) and cpp (c++/cmake) markers win first: "nuget" (also the
    # PSGallery + vcpkg package format) and "dotnet" (routinely driven FROM a .ps1) are NOT .NET-
    # exclusive, so an explicit PS/C++ prompt that merely mentions them must NOT be hijacked. The .NET
    # platform token is ANCHORED (".NET core/framework/standard/<digit>", asp.net) so it can't match the
    # ".net" TLD in a hostname (example.net) or the phrase ".NET version". Dependency-free -> builds
    # offline with no feed. A miss is safe (the coder hand-authors; error-feedback backstops).
    if ($Prompt -match '(?i)(\bc#|\bc-?sharp\b|\bdotnet\b|\basp\.net\b|\.net\s+(core|framework|standard|\d)|\.cs\b|\bconsole app(lication)?\b|\bxunit\b|\bnunit\b)') { return 'dotnet-console' }
    return ''
}

function Copy-ScaffoldInto {
    # Copy a known-good skeleton from build-infra/<name>/reference (+ the sibling offline nuget.config)
    # into the worktree so the coder starts from a compiling project. Returns the seeded file names
    # (empty array if the scaffold dir is missing). ScaffoldRoot is injectable for tests.
    # #790 sub-task 5: -PackageName seeds the skeleton's PACKAGE under the job-oracle contract's ONE
    # canonical top-level name instead of the generic 'app' -- the B4 flashcards park grew BOTH an
    # 'app/' twin (stale placeholder core + a tests/test_core.py importing app.core) AND the real
    # 'flashcard_app/' package because the seed and the oracle each pinned a different layout. The
    # rename fires ONLY when the name is a valid python identifier, differs from 'app', AND the
    # scaffold actually ships a top-level app/ package (today: the python skeleton) -- anything else
    # is the byte-identical legacy seed (deny-by-default; a miss is safe, never worse).
    param(
        [Parameter(Mandatory)][string]$Scaffold,
        [Parameter(Mandatory)][string]$Worktree,
        [string]$ScaffoldRoot = (Join-Path (Split-Path $PSScriptRoot -Parent) 'build-infra'),
        [string]$PackageName = ''
    )
    $base = Join-Path $ScaffoldRoot $Scaffold
    $ref  = Join-Path $base 'reference'
    if (-not (Test-Path $ref)) { return @() }
    $renameApp = [bool]($PackageName -and $PackageName -cne 'app' -and
        $PackageName -cmatch '^[A-Za-z_][A-Za-z0-9_]*$' -and
        (Test-Path (Join-Path (Join-Path $ref 'app') '__init__.py')))
    $seeded = New-Object System.Collections.ArrayList
    # Copy the WHOLE reference tree (files + subdirs, e.g. Python's app/ and tests/) into the
    # worktree, preserving structure. WinUI's flat layout is unaffected (rel == file name).
    foreach ($f in Get-ChildItem -LiteralPath $ref -Recurse -File) {
        $rel = $f.FullName.Substring($ref.Length).TrimStart('\', '/')
        # Litter guard (#1048 fix round): the reference tree is copied from DISK, so cache dirs a
        # stray tool run leaves in the SOURCE (__pycache__ / .pytest_cache / .hypothesis) would
        # seed into the worktree and be committed by the runner's add -A (the seed ships no
        # .gitignore). Never run pytest or the gate inside build-infra/<name>/reference -- always
        # seed into a temp dir first; this filter is the backstop, and verify-scaffold H7 locks
        # the seeded set to the COMMITTED reference list so litter classes this filter does not
        # name still fail loud.
        if ($rel -match '(^|[\\/])(__pycache__|\.pytest_cache|\.hypothesis)([\\/]|$)') { continue }
        $content = $null
        if ($renameApp) {
            # Re-root the package dir in the seeded PATH (app/... -> <pkg>/...) and rewrite the
            # package NAME inside the seeded text files. Every standalone lowercase 'app' token in
            # the python reference refers to THE PACKAGE (import lines, pyproject name/include,
            # README paths/prose) -- locked by verify-scaffold C12; word-boundary + case-sensitive
            # so 'apps'/'Application' never match.
            if ($rel -cmatch '^app([\\/])') { $rel = $PackageName + $rel.Substring(3) }
            if ($f.Extension -in @('.py', '.toml', '.md', '.cfg', '.ini', '.txt')) {
                $content = (Get-Content -LiteralPath $f.FullName -Raw) -creplace '\bapp\b', $PackageName
            }
        }
        $dest = Join-Path $Worktree $rel
        $destDir = Split-Path $dest -Parent
        if ($destDir -and -not (Test-Path $destDir)) { New-Item -ItemType Directory -Force $destDir | Out-Null }
        if ($null -ne $content) {
            Set-Content -LiteralPath $dest -Value $content -NoNewline -Encoding utf8NoBOM
        } else {
            Copy-Item -LiteralPath $f.FullName -Destination $dest -Force
        }
        [void]$seeded.Add($rel)
    }
    $ng = Join-Path $base 'nuget.config'
    if (Test-Path $ng) {
        Copy-Item -LiteralPath $ng -Destination (Join-Path $Worktree 'nuget.config') -Force
        [void]$seeded.Add('nuget.config')
    }
    @($seeded)
}

function Get-ProjectEcosystem {
    # The ONE detector of a project's DECLARED ecosystem(s), read from its MANIFESTS (not from
    # which file extensions happen to exist in the tree). A manifest is the project's STATED
    # identity; that is exactly what makes a loose '.js' in a Python repo detectable as a
    # FOREIGN deliverable (#670). Used by BOTH the language pin (new-agent-task.ps1) and the
    # eco:language gate check (verify-project.ps1) so there is a single source of truth.
    #   python : top-level pyproject.toml or setup.py
    #   node   : top-level package.json
    #   dotnet : any *.csproj / *.sln anywhere (excluding bin/obj/.git) - .NET solutions nest
    # The top-level-vs-recursive ASYMMETRY mirrors verify-project.ps1's existing detection
    # (py/node top-level; dotnet recursive) so this never changes which build checks fire.
    # Pure; no git / no network. Returns a sorted-unique set (possibly empty). The unary-comma
    # + @() guarantees an ARRAY is returned even for 0 or 1 element - PowerShell otherwise
    # unwraps a 1-element result to a scalar, which would break -contains / .Count at callers.
    param([Parameter(Mandatory)][string]$Path)
    $eco = New-Object System.Collections.ArrayList
    if ((Test-Path (Join-Path $Path 'pyproject.toml')) -or (Test-Path (Join-Path $Path 'setup.py'))) {
        [void]$eco.Add('python')
    }
    if (Test-Path (Join-Path $Path 'package.json')) {
        [void]$eco.Add('node')
    }
    $dotnet = @(Get-ChildItem -Path $Path -Recurse -Include *.csproj, *.sln -File -ErrorAction SilentlyContinue |
                  Where-Object { $_.FullName -notmatch '\\(bin|obj|\.git)\\' } | Select-Object -First 1)
    if ($dotnet.Count -gt 0) { [void]$eco.Add('dotnet') }
    return ,@($eco | Sort-Object -Unique)
}

function Get-ChangedLanguages {
    # Map a list of changed file PATHS to the set of CODE languages they represent, by file
    # extension. Lets the eco:language gate learn what language(s) a task actually produced:
    #   .py  .pyi                          -> python
    #   .js  .jsx .ts .tsx .mjs .cjs       -> node
    #   .cs  .fs  .vb                      -> dotnet
    # EVERYTHING ELSE IS IGNORED - docs/config/assets (.md .txt .toml .json .yml .gitignore
    # .html .css ...) AND source in languages we cannot DECLARE an ecosystem for (.go .rs
    # .java .rb .sh .sql). That makes the gate HIGH-PRECISION, NOT COMPLETE: a foreign
    # deliverable in an unrecognized language is not flagged here (only the A1 prompt pin
    # guards that) - the deliberate trade so the gate never false-fails a legitimately
    # vendored one-off helper. Pure (string-only); returns a sorted-unique set (possibly
    # empty), array-wrapped so a single language does not unwrap to a scalar.
    param([string[]]$Paths = @())
    $map = @{
        '.py' = 'python'; '.pyi' = 'python'
        '.js' = 'node'; '.jsx' = 'node'; '.ts' = 'node'; '.tsx' = 'node'; '.mjs' = 'node'; '.cjs' = 'node'
        '.cs' = 'dotnet'; '.fs' = 'dotnet'; '.vb' = 'dotnet'
    }
    $langs = New-Object System.Collections.ArrayList
    foreach ($p in @($Paths)) {
        if (-not $p) { continue }
        $ext = [System.IO.Path]::GetExtension([string]$p).ToLowerInvariant()
        if ($ext -and $map.ContainsKey($ext)) { [void]$langs.Add($map[$ext]) }
    }
    return ,@($langs | Sort-Object -Unique)
}

function Test-LanguageAdherence {
    # PURE DECISION for the eco:language gate (#670): does the task's deliverable match the
    # project's declared identity? Inputs are already-derived sets (Get-ProjectEcosystem /
    # Get-ChangedLanguages) so this is unit-tested with no git and no model (precedent:
    # Test-ShouldResample). HIGH-PRECISION + FORGIVING - only ever 'fail' on an unambiguous
    # wrong-language deliverable so the fleet's auto-merge can trust it:
    #   ChangedLanguages empty (doc/config-only change) -> skip  (never a false-fail)
    #   DeclaredEcosystems empty (no manifest at all)   -> skip  (unknown project = today)
    #   NONE of the changed code languages is declared  -> fail  (every code file is foreign)
    #   otherwise (>=1 changed lang is declared)        -> pass  (polyglot/partial is forgiven)
    # 'fail' ONLY when the deliverable is ENTIRELY foreign; a mix that includes an on-ecosystem
    # file passes (the soft LLM review still sees any stray file). Returns
    # @{ Status = 'pass'|'fail'|'skip'; Reason = <string> }.
    param(
        [string[]]$DeclaredEcosystems = @(),
        [string[]]$ChangedLanguages = @()
    )
    $declared = @($DeclaredEcosystems)
    $changed  = @($ChangedLanguages)
    if ($changed.Count -eq 0) {
        return @{ Status = 'skip'; Reason = 'no code files changed (doc/config only)' }
    }
    if ($declared.Count -eq 0) {
        return @{ Status = 'skip'; Reason = 'project declares no ecosystem (no manifest) - language not judged' }
    }
    # Intersection via Compare-Object (-IncludeEqual -ExcludeDifferent returns the elements
    # present in BOTH); empty-safe now that both sides are guaranteed non-empty above.
    $shared = @(Compare-Object -ReferenceObject $changed -DifferenceObject $declared -IncludeEqual -ExcludeDifferent -PassThru)
    if ($shared.Count -eq 0) {
        return @{ Status = 'fail'
                  Reason = "deliverable language(s) [$($changed -join ',')] are none of the project's declared ecosystem(s) [$($declared -join ',')]" }
    }
    return @{ Status = 'pass'
              Reason = "deliverable language(s) [$($changed -join ',')] match declared ecosystem(s) [$($declared -join ',')]" }
}

function Get-LanguageConstraint {
    # A1 (#670): build the hard TARGET-LANGUAGE instruction that is PREPENDED to the coder's
    # prompt so a language-neutral task ("write an is_palindrome function") cannot let the model
    # default to a foreign language (the live failure wrote JavaScript into a Python repo). Built
    # from the project's DECLARED ecosystem set (Get-ProjectEcosystem). Empty/unknown -> '' (no
    # constraint = current behavior). Pure; unit-tested; ASCII only.
    param([string[]]$Ecosystems = @())
    $eco = @($Ecosystems | Sort-Object -Unique)
    if ($eco.Count -eq 0) { return '' }
    $phrase = @{
        python = 'Python (.py source files), and add at least one pytest test named test_*.py that exercises the behavior'
        node   = 'TypeScript or JavaScript (.ts/.js source files), and add at least one test'
        dotnet = 'C# (.cs source files) within the existing project, and add at least one test'
    }
    $names = @{ python = 'Python'; node = 'TypeScript/JavaScript'; dotnet = 'C#' }
    if ($eco.Count -eq 1) {
        $l = $eco[0]
        $p = if ($phrase.ContainsKey($l)) { $phrase[$l] } else { "the project's existing language" }
        $n = if ($names.ContainsKey($l)) { $names[$l] } else { $l }
        return "TARGET PROJECT LANGUAGE: $n. Write your solution as $p. Do NOT use any other programming language - this is a $n project."
    }
    # polyglot: name every declared language and require the deliverable be in ONE of them.
    $nlist = @($eco | ForEach-Object { if ($names.ContainsKey($_)) { $names[$_] } else { $_ } })
    return "TARGET PROJECT LANGUAGES: $($nlist -join ', '). This project already uses these languages; write your solution in ONE of them (matching the existing code) and add at least one test. Do NOT introduce a different programming language."
}

function Test-ShouldMerge {
    # FIX C (#670) + merge-reliability (#688) + deterministic-gate-drives-merge (#687, 2026-06-26):
    # the single, testable auto-merge decision. Returns @{ Merge=<bool>; Via=<''|review|
    # review-over-hiccup|green-gates-over-review|green-gates-inconclusive-review|build-only-gate> }.
    #
    # PRINCIPLE (LA #687): the DETERMINISTIC gates (build + tests + verify, soon + PBT + mutation)
    # are the arbiter of work quality and DRIVE the merge; the LLM review is a SIGNAL that drives the
    # bounded review-feedback fix loop upstream, NEVER a veto that parks green work. A review TIMEOUT,
    # a coder CIRCUIT-BREAKER, or even a FIX FIRST does not block a diff the green gates vouch for.
    # (Three #688 dispatches + the #687 landing page parked good, building, verify-passing,
    # test-passing work on exactly these signals - the bug this closes.)
    #
    # HARD blocks (NEVER merge - work-quality / security signals, absolute, gate-independent): no
    # changes, a detected secret, a FAILED test, a FAILED verify.
    #
    # SOFT signals (never block when the gates are GREEN): AgentTimedOut / LoopSuspected (the
    # circuit-breaker), and ANY review verdict (MERGE / FIX FIRST / UNCLEAR). FIX FIRST blocks ONLY
    # when there is no green BEHAVIORAL gate to override it (test=none, e.g. build-only).
    #
    # Merge paths:
    #   review                          - explicit reviewer MERGE (green gates or test=none), no hiccup.
    #   review-over-hiccup              - explicit reviewer MERGE that survives a process hiccup: the
    #                                     reviewer vetted the DIFF; the hiccup is process-only. (F3)
    #   green-gates-over-review         - GREEN gates (verify=pass AND test=pass) merge OVER a FIX FIRST
    #                                     review: the deterministic arbiter vouched; the review's findings
    #                                     already fed back upstream. (#687 - fixes the landing-page park.)
    #   green-gates-inconclusive-review - GREEN gates merge an INCONCLUSIVE (UNCLEAR/timed-out) review:
    #                                     the passing tests stand in for a review that could not conclude. (F2)
    #   build-only-gate                 - dotnet-only, no test runner, strict verify pass, not FIX FIRST,
    #                                     no hiccup (unchanged #670 behavior; reviewer can't launch a GUI).
    # Pure; unit-tested; ASCII only.
    param(
        [bool]$HasChanges,
        [bool]$SecretBlocked,
        [bool]$AgentTimedOut,
        [bool]$LoopSuspected,
        [string]$TestResult   = 'none',    # none | pass | fail
        [string]$VerifyResult = 'none',    # none | pass | fail
        [string]$Verdict      = 'UNCLEAR', # MERGE | FIX FIRST | UNCLEAR
        [string[]]$Ecosystems = @(),
        # #1074: the stage->commit CAPTURE step faulted. HARD block -- a `git add` that failed part-way
        # can leave a PARTIAL commit, and a gate run over a tree we could not capture vouches for
        # nothing. Defaults $false so every pre-#1074 caller/test is byte-identical.
        [bool]$GitFailed      = $false
    )
    # HARD blocks - the work itself is bad or unsafe. ABSOLUTE, independent of the LLM review:
    # no changes to merge, a detected secret, a capture fault, a FAILED test, or a FAILED verify.
    # (A test/verify FAIL also makes the gates non-green below, so those two are belt-and-suspenders.)
    if ((-not $HasChanges) -or $SecretBlocked -or $GitFailed -or ($TestResult -eq 'fail') -or ($VerifyResult -eq 'fail')) {
        return @{ Merge = $false; Via = '' }
    }

    $processHiccup = $AgentTimedOut -or $LoopSuspected
    $gatesGreen    = ($VerifyResult -eq 'pass') -and ($TestResult -eq 'pass')

    # DETERMINISTIC GATE DRIVES THE MERGE (LA, 2026-06-26 / #687 critical-coding-loop): when BOTH
    # deterministic gates are GREEN (verify=pass AND test=pass) the work MERGES regardless of the
    # LLM review verdict -- the review (the same-model 30B today, a cross-model 14B critic soon) is
    # a SIGNAL that drives the bounded review-feedback fix loop UPSTREAM, never a veto that parks
    # green, building, test-passing work. The #687 landing page parked exactly this: a sticky
    # FIX-FIRST / timed-out 30B self-review vetoing a green merge. The reviewer's findings already
    # fed back across the bounded passes; if the gates are STILL green here, the deterministic
    # arbiter has vouched for the behaviour and the diff merges. (The weak-happy-path-tests risk is
    # closed by the PBT + mutation checks that STRENGTHEN this same green signal -- #687 (1).)
    if ($gatesGreen) {
        $via = if ($Verdict -eq 'MERGE') { if ($processHiccup) { 'review-over-hiccup' } else { 'review' } }
               elseif ($Verdict -eq 'FIX FIRST') { 'green-gates-over-review' }
               else { 'green-gates-inconclusive-review' }
        return @{ Merge = $true; Via = $via }
    }

    # Below here the deterministic gates are NOT both green (typically test=none -- a build-only
    # ecosystem with no runner). With no green BEHAVIORAL gate to vouch, the review IS the arbiter:
    #   - an explicit reviewer MERGE merges (surviving a process hiccup -- the reviewer vetted the
    #     diff; a timeout/circuit-breaker is process-only). (F3)
    #   - an explicit FIX FIRST blocks (the reviewer objected and nothing deterministic overrides it).
    if ($Verdict -eq 'MERGE') {
        return @{ Merge = $true; Via = $(if ($processHiccup) { 'review-over-hiccup' } else { 'review' }) }
    }
    if ($Verdict -eq 'FIX FIRST') {
        return @{ Merge = $false; Via = '' }
    }

    # Build-only ecosystem (dotnet/WinUI, no test runner): a strict verify pass merges an
    # inconclusive (UNCLEAR/timed-out) review - the read-only reviewer cannot launch the GUI.
    # Never on a process hiccup. (#670 FIX C)
    $eco = @($Ecosystems | Sort-Object -Unique)
    $buildOnly = ($eco.Count -eq 1) -and ($eco -contains 'dotnet') -and ($TestResult -eq 'none')
    if ($buildOnly -and ($VerifyResult -eq 'pass') -and -not $processHiccup) {
        return @{ Merge = $true; Via = 'build-only-gate' }
    }
    return @{ Merge = $false; Via = '' }
}

function Invoke-BuildWithRetry {
    # RETRY POLICY for the build stage, separated from the MECHANISM (running the model,
    # checking git) so the policy can be unit-tested deterministically without a model.
    #
    # Why retry at all: a small/quantized local model intermittently produces a NO-OP
    # build - it prints a tool call as text (malformed), or writes to a denied
    # out-of-project path - which leaves ZERO changes in the worktree. Those failures are
    # cheap (they finish fast) and independent between attempts, so re-running turns a
    # ~50% per-attempt success into ~85-90% effective.
    #
    # Rules (exactly the behaviour that was inline in new-agent-task.ps1):
    #   - Retry ONLY when an attempt produced no working-tree changes.
    #   - NEVER retry a timeout (expensive, and usually means the model is genuinely
    #     stuck, not a transient slip).
    #   - NEVER retry past an explicit "NO CHANGE NEEDED" declaration (#1049 candidate
    #     (b)): a declaration is an ANSWER, not a failure to comply -- re-running re-asks
    #     a question the model already answered, and the measured outcome of that
    #     pressure is a manufactured junk diff (dispatch-quality-ledger 2026-07-14:
    #     an oracle-file comment scribble, a create-then-delete scratch script).
    #   - Each retry starts from a CLEAN worktree (ResetWorktree) so a partial/garbled
    #     attempt cannot poison the next.
    #   - Never run more than MaxBuildAttempts attempts.
    #
    # Mechanism is injected as scriptblocks so a test can substitute deterministic fakes:
    #   -RunAgent        runs ONE attempt; returns the Invoke-AgentRun result shape
    #                    (@{ TimedOut=[bool]; ExitCode=...; ... }). Should yield a single
    #                    hashtable; a non-hashtable / multi-value result is normalized below.
    #   -ProducedChanges returns a single [bool]: did the attempt that just ran change the
    #                    worktree? A multi-value result is reduced to its LAST value below.
    #   -ResetWorktree   restores a clean worktree; called BEFORE each retry (not the first).
    #   -OnRetry         optional progress callback; receives the attempt number starting.
    #   -NoChangeDeclared returns a single [bool]: did the attempt that just ran DECLARE
    #                    the honest no-change outcome? Consulted ONLY after a no-change
    #                    attempt (a diff-producing attempt is graded normally). The
    #                    default { $false } is byte-identical to the pre-#1049 loop.
    # Each scriptblock resolves its free variables ($wt, $Model, ...) against the scope it
    # was DEFINED in (PowerShell lexical scoping), so the caller passes plain closures.
    #
    # Returns: @{ Run=<last RunAgent result>; Attempts=[int]; ProducedChanges=[bool];
    #             NoChangeDeclared=[bool] }
    param(
        [Parameter(Mandatory)][scriptblock]$RunAgent,
        [Parameter(Mandatory)][scriptblock]$ProducedChanges,
        [scriptblock]$ResetWorktree = {},
        [scriptblock]$OnRetry = {},
        [scriptblock]$NoChangeDeclared = { $false },
        [int]$MaxBuildAttempts = 3
    )
    if ($MaxBuildAttempts -lt 1) { $MaxBuildAttempts = 1 }
    $attempt = 0
    $run = $null
    $changed = $false
    $declared = $false
    do {
        $attempt++
        if ($attempt -gt 1) {
            & $OnRetry $attempt
            & $ResetWorktree
        }
        # Normalize defensively: take the LAST emitted object so a stray Write-Output cannot
        # make $run an array, and guarantee a hashtable so $run.TimedOut / $run.ExitCode stay
        # real scalars for the caller's circuit-breaker and auto-merge gate.
        $run = @(& $RunAgent)[-1]
        if ($run -isnot [hashtable]) { $run = @{ TimedOut = $false; ExitCode = $null; Error = 'RunAgent returned a non-hashtable result' } }
        # [bool] on a multi-value pipeline is True for ANY non-empty collection; take the LAST
        # value so a no-op that also emitted stray output (..., $false) is not misread as a change.
        $cv = & $ProducedChanges
        $changed = [bool](@($cv)[-1])
        # #1049: a declaration only matters on a VERIFIED no-change attempt -- with a diff on
        # disk the declaration is ignored and the gate grades the diff exactly as before.
        $declared = $false
        if (-not $changed) { $declared = [bool](@(& $NoChangeDeclared)[-1]) }
    } while (-not $changed -and -not $declared -and -not $run.TimedOut -and $attempt -lt $MaxBuildAttempts)
    return @{ Run = $run; Attempts = $attempt; ProducedChanges = $changed; NoChangeDeclared = $declared }
}

function Test-NoChangeEscapeEnabled {
    # #1049 kill-switch resolution: the no-change escape is ON by default -- this change lands in its
    # OWN battery attribution window (the merge IS the A/B flip), so the shipped default is the
    # behaviour under measurement. Disabled ONLY by an explicit BLARAI_NO_CHANGE_ESCAPE = 0/false/no/
    # off (the A/B lever + the toggle-off regression proof; the env var reaches Start-Job candidate
    # children via the inherited process environment). Pure + ASCII; the caller passes
    # $env:BLARAI_NO_CHANGE_ESCAPE. Unit-tested without a model (verify-nochange-outcome.ps1).
    param([string]$EnvValue = '')
    return -not (@('0', 'false', 'no', 'off') -contains "$EnvValue".Trim().ToLower())
}

function Add-NoChangeEscape {
    # #1049 candidate (b): give the RETRY prompt an HONEST EXIT. A retry prompt that implicitly
    # demands a diff GETS a diff -- the measured incidents (dispatch-quality-ledger.md 2026-07-14,
    # seed run): wave 2 scribbled a comment into the protected oracle file and wave 3 committed-then-
    # deleted a scratch script, both existing ONLY to satisfy the produced-changes detector. Appended
    # to RETRY attempts only (attempt >= 2, wired in Invoke-CandidateBuild): attempt 1 keeps the
    # byte-identical primary prompt, so the escape is offered exactly when the coder has ALREADY
    # produced one verified no-change attempt -- never as an easy first-attempt exit. ALWAYS preserves
    # the original prompt verbatim (appended, never replaces). Pure + ASCII; unit-tested without a
    # model (verify-nochange-outcome.ps1).
    param([string]$Prompt)
    return "$Prompt`n`n--- IF THE WORK IS ALREADY DONE (honest no-change outcome) ---`n" +
        "A previous attempt at this task finished without changing any file. If, after inspecting " +
        "the project, you conclude the task's requirements are ALREADY fully met by the current " +
        "code, do NOT invent an edit just to have something to show -- no comment tweaks, no " +
        "scratch/verification files, no cosmetic changes. Instead reply with one final line in " +
        "exactly this form and stop WITHOUT editing any file:`n" +
        "NO CHANGE NEEDED: <one line of evidence naming the file(s)/test(s) that already satisfy the task>`n" +
        "Declining to edit is a legal, honest answer here. Only use it when the requirements are " +
        "genuinely met; if anything is missing, build it as asked."
}

function Get-TextSha256 {
    # #1049 F1 helper: hex SHA-256 of a string's UTF-8 bytes -- the transcript-anchor identity
    # (see Get-TranscriptAnchor). Pure + ASCII.
    param([string]$Text)
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try {
        return ([BitConverter]::ToString($sha.ComputeHash([System.Text.Encoding]::UTF8.GetBytes("$Text"))) -replace '-', '')
    } finally { $sha.Dispose() }
}

function Get-TranscriptAnchor {
    # #1049 F1: fingerprint the transcript BEFORE an attempt so the declaration probe can later
    # scope itself to ONLY what that attempt wrote. Two facts identify "the file merely GREW":
    # the recorded Length and the SHA-256 of the text up to it. At probe time, a file at least
    # that long whose prefix still hashes identically has the current attempt's output as
    # exactly the text AFTER Length -- the live ACP driver's shape (acp_coder.py appends every
    # attempt into the one shared $LogPath). Anything else (a shorter file, a rewritten prefix)
    # means the writer TRUNCATED (the stdin driver's per-attempt shape), and the whole file IS
    # the current attempt. Length alone would NOT be safe: a truncating writer whose new
    # transcript is LONGER than the old one passes a length test and a naive slice would cut
    # mid-line into the current attempt's own text -- the hash is what proves the prefix is
    # still the OLD attempts' bytes. Text units throughout (Get-Content -Raw), never raw bytes.
    # Fail-soft empty anchor (= whole-file scope). Unit-tested (verify-nochange-outcome.ps1).
    param([string]$LogPath)
    $none = @{ Length = [long]0; Hash = '' }
    if (-not $LogPath -or -not (Test-Path $LogPath)) { return $none }
    try {
        $t = Get-Content $LogPath -Raw -ErrorAction Stop
        if (-not $t) { return $none }
        return @{ Length = [long]$t.Length; Hash = (Get-TextSha256 -Text $t) }
    } catch { return $none }
}

function Get-NoChangeDeclaration {
    # #1049 candidate (b): did the coder DECLARE the honest no-change outcome? Reads the attempt's
    # transcript and returns @{ Declared=[bool]; Evidence=[string] }. STRICT on purpose -- every
    # degraded path fails CLOSED toward today's behaviour (Declared=$false, the legacy retry
    # pressure stands): an absent/unreadable/empty log, no marker line, or only the instruction
    # echo. Two guards distinguish a real declaration from the prompt's own text riding the
    # transcript: the evidence must be NON-EMPTY, and an evidence beginning with '<' is the
    # instruction's placeholder ("<one line of evidence ...>"), never a declaration. The LAST
    # matching line wins (the final reply outranks a mid-session mention). Evidence is bounded to
    # one line (it is surfaced in the per-task report; the RESULT: line stays fixed-vocabulary so
    # the driver-side classifier can never misread coder-authored words like "merged").
    #
    # -Anchor (#1049 F1, reviewer finding): scope the read to the CURRENT attempt. The live ACP
    # driver APPENDS all attempts into one shared transcript, so an unscoped probe on attempt 2
    # could be satisfied by a SPONTANEOUS marker attempt 1 emitted -- an attempt whose prompt
    # never offered the escape (the offered-gating F1 names). The caller fingerprints the
    # transcript before each attempt (Get-TranscriptAnchor: Length + prefix SHA-256); the slice
    # applies ONLY when the file provably merely GREW (still at least Length long AND the prefix
    # hashes identically) -- then the text after Length is exactly this attempt's output. A
    # shorter file or a rewritten prefix (the stdin driver truncates per attempt) scopes the
    # WHOLE file, which is then the current attempt by construction. $null (the default) scopes
    # the whole file (back-compat for every pre-F1 caller).
    # Pure-over-a-file + ASCII; unit-tested without a model (verify-nochange-outcome.ps1).
    param([string]$LogPath, $Anchor = $null)
    $none = @{ Declared = $false; Evidence = '' }
    if (-not $LogPath -or -not (Test-Path $LogPath)) { return $none }
    $text = ''
    try { $text = Get-Content $LogPath -Raw -ErrorAction Stop } catch { return $none }
    if (-not $text) { return $none }
    if ($Anchor -and [long]$Anchor.Length -gt 0 -and $text.Length -ge [long]$Anchor.Length -and
        ((Get-TextSha256 -Text $text.Substring(0, [int]$Anchor.Length)) -eq "$($Anchor.Hash)")) {
        $text = $text.Substring([int]$Anchor.Length)
    }
    if (-not $text) { return $none }
    $m = [regex]::Matches($text, '(?im)^[ \t>]*NO CHANGE NEEDED:[ \t]*(?!<)(\S[^\r\n]*)')
    if ($m.Count -eq 0) { return $none }
    $ev = $m[$m.Count - 1].Groups[1].Value.Trim()
    if (-not $ev) { return $none }
    if ($ev.Length -gt 240) { $ev = $ev.Substring(0, 240) }
    return @{ Declared = $true; Evidence = $ev }
}

function Add-CandidateDiversity {
    # BEST-OF-N (#689): decorrelate independent candidate $Index from the others. The coder already
    # samples at temperature 0.7 / top_p 0.8 with NO fixed seed, so independent runs of the same
    # prompt diverge naturally; this appends a per-candidate INDEPENDENT-ATTEMPT framing + a distinct
    # variant tag as a SECOND decorrelator so the best-of-N coverage curve does not flatten on
    # correlated samples (the curve assumes DIVERSE samples -- arXiv 2407.21787). Candidate 1 gets the
    # prompt UNCHANGED (the common single-attempt happy path stays byte-identical); candidates 2..N
    # get the decorrelating suffix. ALWAYS preserves the original prompt verbatim (appended, never
    # replaces). Pure + ASCII; unit-tested without a model (see verify-bestofn.ps1).
    param([string]$Prompt, [int]$Index, [int]$Total)
    if ($Index -le 1) { return $Prompt }
    $n = if ($Total -ge $Index) { $Total } else { $Index }
    return "$Prompt`n`n--- INDEPENDENT ATTEMPT $Index OF $n (best-of-N; a deterministic build/test gate selects the winner) ---`n" +
        "This is a FRESH, independent attempt at the SAME task. Any earlier attempt has been discarded -- " +
        "do NOT assume a previous approach, file structure, or partial code exists; solve it your own way " +
        "from the seeded baseline. Favour a correct, complete, self-contained solution over matching any " +
        "prior attempt -- the gate picks whichever attempt actually builds and passes. (variant tag: c$Index)"
}

function Get-CandidateRank {
    # BEST-OF-N (#689): score ONE candidate so Select-BestCandidateIndex can pick the best to KEEP when
    # no candidate is a definitive winner (the best-PARTIAL path). HIGHER = better. The deterministic
    # GATE signals dominate (verify outranks test), and disqualifiers (no changes, secret, timeout,
    # suspected loop) sink a candidate below any real attempt. This is ONLY a rank for selecting which
    # partial/parked attempt to keep -- the actual merge stays Test-ShouldMerge. Pure; unit-tested.
    #   verify:  pass +600  none +300  fail +0      (a building attempt always outranks a non-building one)
    #   test:    pass +200  none +80   fail +0      (a failing test ranks below absent tests)
    #   changes: +20                                 (a real change outranks a no-op of the same gate class)
    #   flags:   timeout -2000   loop -400   git-fault -50000   secret -100000
    #            (#1074: a capture fault sinks a candidate below every real attempt -- its gate signals
    #             describe a build the box never captured, so it must never outrank one that IS on disk.
    #             Above a secret, so that when EVERY candidate faulted one is still selectable and the
    #             operator gets the git message in the report instead of an empty selection.)
    param(
        [string]$VerifyResult = 'none',
        [string]$TestResult   = 'none',
        [bool]$HasChanges     = $true,
        [bool]$TimedOut       = $false,
        [bool]$SecretBlocked  = $false,
        [bool]$LoopSuspected  = $false,
        [bool]$GitFailed      = $false
    )
    $score = 0
    switch ("$VerifyResult".Trim().ToLower()) { 'pass' { $score += 600 } 'fail' { } default { $score += 300 } }
    switch ("$TestResult".Trim().ToLower())   { 'pass' { $score += 200 } 'fail' { } default { $score += 80 } }
    if ($HasChanges)    { $score += 20 }
    if ($TimedOut)      { $score -= 2000 }
    if ($LoopSuspected) { $score -= 400 }
    if ($GitFailed)     { $score -= 50000 }
    if ($SecretBlocked) { $score -= 100000 }
    return $score
}

function Select-BestCandidateIndex {
    # BEST-OF-N (#689): given the per-candidate RANKS (Get-CandidateRank output, in candidate order),
    # return the 0-based index of the best, EARLIEST-wins on a tie (the first/lowest-index candidate is
    # kept -- deterministic + favours the cheapest attempt). Returns -1 for an empty list. Pure;
    # unit-tested without a model.
    param([int[]]$Ranks = @())
    $r = @($Ranks)
    if ($r.Count -eq 0) { return -1 }
    $bestIdx = 0; $bestRank = $r[0]
    for ($i = 1; $i -lt $r.Count; $i++) {
        if ($r[$i] -gt $bestRank) { $bestRank = $r[$i]; $bestIdx = $i }   # strictly-greater => first max kept
    }
    return $bestIdx
}

function Test-IsCandidateGreen {
    # BEST-OF-N (#689): is THIS candidate a definitive WINNER -> stop sampling (early-exit)? TRUE only
    # when the deterministic gate is satisfied with NO failure and NO disqualifier: real changes, no
    # secret, not timed-out, the verify gate actively PASSED, and tests did NOT fail (pass or none). A
    # green candidate always satisfies the downstream Test-ShouldMerge; this is just the cheap
    # early-exit so best-of-N stops at the first good attempt. Conservative on purpose -- a verify='none'
    # attempt is NOT a definitive winner (nothing vouched for it), so sampling continues for a
    # verify=pass one. Pure + ASCII; unit-tested without a model.
    param(
        [string]$VerifyResult = 'none',
        [string]$TestResult   = 'none',
        [bool]$HasChanges     = $false,
        [bool]$TimedOut       = $false,
        [bool]$SecretBlocked  = $false,
        # #1074: a candidate whose stage->commit CAPTURE step faulted is never a winner. Its gate
        # signals describe a build we could not capture, not a build that passed. Defaults $false so
        # every pre-#1074 caller/test is byte-identical.
        [bool]$GitFailed      = $false
    )
    if ((-not $HasChanges) -or $SecretBlocked -or $TimedOut -or $GitFailed) { return $false }
    if ("$VerifyResult".Trim().ToLower() -ne 'pass') { return $false }
    return ("$TestResult".Trim().ToLower() -ne 'fail')
}

function Resolve-CommitCapture {
    # #1074 FAIL-LOUD: classify the stage->commit CAPTURE step of the candidate pipeline from the
    # git facts the caller OBSERVED, so an infrastructure failure can never be laundered into "the
    # coder produced nothing." Pure (issues no git command itself) -> unit-testable without a repo.
    #
    # WHY THIS EXISTS. Invoke-CandidateBuild used to run `git add -A`, `git commit` and
    # `rev-list --count` with all three error channels sent to Out-Null and no exit-code check, so a
    # failed capture was INDISTINGUISHABLE from an honest no-op -- and the fail-open direction was
    # "the coder produced nothing". That reading then skipped the tests + verify steps, so the
    # candidate could never win the gate, and best-of-N resampled a fault it could not see. This sits
    # inside the instrument that MEASURES coder capability (40 of 488 reports read `CHANGES: none
    # made`), which is why it is a security_by_design principle-11 defect, not a cosmetic one.
    #
    # THE DISCRIMINATION -- getting this right IS the fix. `git commit` legitimately exits NON-ZERO on
    # the honest "nothing to commit, working tree clean", so an exit code alone cannot separate an
    # honest no-op from a real failure, and matching git's English would be locale- and version-
    # fragile. So the caller reads the INDEX instead and only ATTEMPTS a commit when the index
    # actually HOLDS staged paths (leaving $CommitExitCode $null otherwise). With content staged, a
    # non-zero commit is UNAMBIGUOUSLY a real failure -- a rejecting hook, a locked or corrupt index,
    # a full disk, a broken identity. The honest no-op never enters the failure channel at all.
    #
    # TWO INDEPENDENT DETECTORS, so one missed exit code cannot reopen the hole:
    #   1. EXIT CODES on add / staged-read / commit / status -- precise, and they carry git's own
    #      stderr through to the operator report.
    #   2. The STATE INVARIANT: after a healthy capture the worktree is CLEAN. A DIRTY worktree with
    #      ZERO commits means work existed and never reached a commit, whatever the cause -- which is
    #      the measured B4 `add-card` instance (run 20260723-001147-bd: three candidates wrote real
    #      files, `git status --porcelain` saw them, `rev-list` did not).
    #      This invariant is ALSO how the pipeline's two "did it produce anything" predicates are
    #      reconciled. They legitimately measure different things at different moments: the retry
    #      loop's -ProducedChanges reads the WORKING TREE (correct DURING the build, when nothing is
    #      committed yet), $hasChanges reads COMMITS (correct AFTER the capture). Unifying them would
    #      break one of the two. What is not allowed is for them to DISAGREE SILENTLY at this point,
    #      and that disagreement is exactly `dirty AND no commit` -- now a loud fault.
    #   The ONE sanctioned dirty-with-no-commit state is a SECRET block, which deliberately unstages
    #   and parks the work for a human; that is already a loud, first-class outcome.
    #
    # DETECTOR ORDER IS LOAD-BEARING. The exit-code detectors run most-specific-cause first, and
    # `revlist-unreadable` runs LAST among them. A candidate whose workspace was never created
    # returns 128 from EVERY git read including rev-list, so an early revlist check would reclassify
    # it away from `add-failed` and the operator would lose the reason that actually names the cause.
    # A fault that stays loud but starts lying about WHY is close to the original defect wearing a new
    # label, in an instrument whose whole job is honest attribution. Locked by D4c + U1p.
    #
    # AN UNRESOLVABLE BASE IS NOT A CAPTURE FAULT. $CodeBase is not guaranteed to be a SHA -- the
    # caller falls back to a branch NAME -- so a healthy repo whose branch is `trunk` while the
    # fallback name is `main` makes `rev-list --count main..HEAD` exit 128 with HEAD fine and the tree
    # clean (MEASURED). Faulting on that would turn every healthy build in such a repo into a
    # permanent silent ERRORED: the widen-the-fault inverse of the defect this whole change exists to
    # fix. So the two are told apart by whether the BASELINE resolves at all:
    #   base does not resolve      -> a dispatch CONFIGURATION problem, its own reason, NOT a fault
    #   base resolves, rev-list fails -> this repo's history is unreadable == the real capture fault
    # Folding them together would produce a loud error naming the wrong cause.
    #
    # Returns @{ Failed=[bool]; Reason=<''|add-failed|index-unreadable|commit-failed|status-unreadable|
    #            revlist-unreadable|base-unresolvable|uncommitted-work|secret-blocked>;
    #            Error=<operator line carrying git's message>; HasChanges=[bool] }. HasChanges stays
    #            HONEST (commits exist vs the baseline) even on a fault -- Failed is what blocks the
    #            merge, so a stale prior commit can never ride out.
    param(
        [int]$AddExitCode          = 0,
        [string]$AddOutput         = '',
        [int]$StagedReadExitCode   = 0,
        [string]$StagedReadOutput  = '',
        [int]$StagedCount          = 0,
        [bool]$SecretBlocked       = $false,
        $CommitExitCode            = $null,   # $null = the commit was deliberately NOT attempted
        [string]$CommitOutput      = '',
        [int]$CommitCount          = 0,       # rev-list --count <baseline>..HEAD
        [int]$CommitCountReadExitCode = 0,
        [string]$CommitCountRaw    = '0',     # the RAW rev-list stdout, so a non-numeric answer is visible
        [string]$CommitCountReadOutput = '',
        [int]$StatusReadExitCode   = 0,
        [string]$StatusReadOutput  = '',
        [int]$WorktreeDirtyCount   = 0,       # git status --porcelain lines AFTER the capture step
        # Did `git rev-parse --verify <base>^{commit}` resolve? Defaults $true so every pre-existing
        # caller/test keeps its exact behaviour; only a caller that actually probed passes $false.
        [bool]$BaseResolvable      = $true,
        [string]$BaseRef           = '',
        [int]$MaxDetailChars       = 600
    )
    # With no resolvable baseline the commit COUNT is meaningless, so "did this produce anything"
    # falls back to the only thing still knowable: did OUR commit succeed this pass. Reporting a
    # successful commit as "none made" merely because the baseline name was wrong would be this
    # ticket's own laundering, re-created through the configuration path.
    $has = if ($BaseResolvable) { ($CommitCount -gt 0) }
           else { ($null -ne $CommitExitCode) -and ([int]$CommitExitCode -eq 0) }
    $fmt = {
        param([string]$What, $Code, [string]$Text)
        $t = "$Text".Trim()
        if (-not $t) { $t = '(git printed no message)' }
        if ($t.Length -gt $MaxDetailChars) { $t = $t.Substring(0, $MaxDetailChars) + ' [truncated]' }
        "$What failed (git exit $Code): $t"
    }
    if ($AddExitCode -ne 0) {
        return @{ Failed = $true; Reason = 'add-failed'; HasChanges = $has
                  Error = (& $fmt "git add -A (staging the coder's work)" $AddExitCode $AddOutput) }
    }
    if ($StagedReadExitCode -ne 0) {
        return @{ Failed = $true; Reason = 'index-unreadable'; HasChanges = $has
                  Error = (& $fmt 'git diff --cached --name-only (reading the staged set)' $StagedReadExitCode $StagedReadOutput) }
    }
    if (($null -ne $CommitExitCode) -and ([int]$CommitExitCode -ne 0)) {
        # Reached ONLY with staged content, so this can never be the honest "nothing to commit".
        return @{ Failed = $true; Reason = 'commit-failed'; HasChanges = $has
                  Error = (& $fmt "git commit ($StagedCount path(s) were staged, so this is NOT an empty-commit refusal)" ([int]$CommitExitCode) $CommitOutput) }
    }
    if ($StatusReadExitCode -ne 0) {
        return @{ Failed = $true; Reason = 'status-unreadable'; HasChanges = $has
                  Error = (& $fmt 'git status --porcelain (confirming the worktree was captured)' $StatusReadExitCode $StatusReadOutput) }
    }
    # LAST among the exit-code detectors, deliberately -- see the header. A never-created workspace
    # fails rev-list too, and it must stay classified by the cause that actually names it.
    if (($CommitCountReadExitCode -ne 0) -or ("$CommitCountRaw".Trim() -notmatch '^\d+$')) {
        if (-not $BaseResolvable) {
            # Not a capture fault: the repo is fine, the BASELINE we were handed is not. Reported so
            # the operator can fix the dispatch config, but it must never mark the task ERRORED --
            # a healthy no-op with a mis-set base becoming ERRORED is the inverse regression.
            return @{ Failed = $false; Reason = 'base-unresolvable'; HasChanges = $has
                      Error = ("the baseline ref '$BaseRef' does not resolve in this repo, so changes could not be counted against it. " +
                               "This is a DISPATCH CONFIGURATION problem (a wrong -BaseBranch, or a default branch name this repo does not use), " +
                               "NOT a failure to capture the coder's work; the capture step itself reported success.") }
        }
        # The baseline DOES resolve and rev-list still failed -> this repo's history is unreadable,
        # which is the real capture fault. Defaulting the count to 0 here is exactly how a branch
        # holding a real commit gets reported as "none made". Refuse to guess.
        return @{ Failed = $true; Reason = 'revlist-unreadable'; HasChanges = $has
                  Error = (& $fmt "git rev-list --count (counting the coder's commits against the RESOLVABLE base '$BaseRef'; answered '$("$CommitCountRaw".Trim())')" $CommitCountReadExitCode $CommitCountReadOutput) }
    }
    # A secret block deliberately unstages and PARKS the work in the worktree for a human, so its
    # dirty-with-no-commit state is expected, already surfaced, and must not read as a capture fault.
    if ($SecretBlocked) { return @{ Failed = $false; Reason = 'secret-blocked'; HasChanges = $has; Error = '' } }
    if (($WorktreeDirtyCount -gt 0) -and ($CommitCount -le 0)) {
        return @{ Failed = $true; Reason = 'uncommitted-work'; HasChanges = $has
                  Error = ("the worktree holds $WorktreeDirtyCount uncommitted change(s) but NO commit landed on the candidate branch -- the coder's work exists and was not captured. " +
                           "Every git step reported success, so the cause is upstream of the exit codes; inspect the worktree before trusting any 'no changes' reading of this run.") }
    }
    return @{ Failed = $false; Reason = ''; HasChanges = $has; Error = '' }
}

function Invoke-BestOfN {
    # BEST-OF-N parallel sampling with the deterministic gate as SELECTOR (#689, epic #688). REPLACES
    # the serial error-feedback re-fix: instead of asking a weak local model to self-correct (its worst
    # skill -- it enters error traps and stays stuck), take up to $MaxCandidates INDEPENDENT, diverse
    # attempts at the SAME task and let the gate pick the winner. Generation COVERAGE, not review
    # precision, is the weak-model bottleneck; N fresh independent samples route around self-correction
    # (a weaker open model went 15.9% -> 56% on SWE-bench Lite from repeated sampling -- arXiv 2407.21787;
    # the verifier we already own makes selection nearly free locally).
    #
    # SEQUENTIAL for now (one candidate at a time; early-exit on the FIRST green). The samples are
    # independent, so a future change can run them CONCURRENTLY via OVMS continuous batching -- the real
    # on-box concurrency ceiling on the integrated Arc 140V (shared LPDDR5X) is undocumented and MEASURED
    # separately (Vikunja #695). Early-exit makes the common (easy) case cost-neutral vs the old serial
    # loop: candidate 1 green -> exactly one build, like today.
    #
    # POLICY ONLY: every side effect is an injected scriptblock so this whole control flow is unit-tested
    # deterministically WITHOUT a model (mirrors Invoke-BuildWithRetry; see verify-bestofn.ps1):
    #   -RunCandidate   {param($Index,$Total) -> hashtable}  build+test+verify ONE fresh candidate;
    #                   returns its result (carries the gate signals + a way to restore it). A
    #                   non-hashtable result is normalised to a disqualified placeholder.
    #   -IsWinner       {param($Result) -> [bool]}  definitive winner -> early-exit (Test-IsCandidateGreen).
    #   -StopSampling   {param($Result) -> [bool]}  TERMINAL condition -> stop sampling (do NOT keep
    #                   spending). PRESERVES the serial loop's posture: a secret-block must be SURFACED
    #                   to a human (never sampled-away), and a timeout means the model is genuinely
    #                   stuck (expensive to retry) -- so the caller passes {secret OR timeout}. Distinct
    #                   from IsWinner: a stop is NOT a win; selection still falls to the best partial
    #                   (so a timeout doesn't get picked over an earlier real attempt). The caller
    #                   inspects the candidates to surface a secret (see new-agent-task.ps1). Default: never.
    #   -ScoreCandidate {param($Result) -> [int]}   rank for the best-PARTIAL pick when none win.
    #   -OnCandidate    {param($Index,$Total)}      optional progress callback BEFORE each candidate.
    # Returns @{ Selected=<result|$null>; SelectedIndex=[int 0-based|-1]; WinnerFound=[bool];
    #            Stopped=[bool]; Count=[int]; Candidates=@(...) }. Selected = the winner if one was found,
    #            else the highest-ranked candidate (best partial); $null only when $MaxCandidates < 1.
    #            Stopped = a StopSampling terminal condition broke the loop (the last candidate triggered it).
    param(
        [Parameter(Mandatory)][scriptblock]$RunCandidate,
        [Parameter(Mandatory)][scriptblock]$IsWinner,
        [scriptblock]$ScoreCandidate = { param($r) 0 },
        [scriptblock]$StopSampling = { param($r) $false },
        [scriptblock]$OnCandidate = {},
        # #771 STOP-CONTRACT: checked BEFORE each candidate. Production passes { Test-DispatchCancelled } so a
        # `/dispatch stop` (the monitor's cancel sentinel) prevents starting a FRESH candidate -- the exact
        # #771 defect (candidate N+1 built 9 min after a stop). Default { $false } keeps the unit tests pure.
        [scriptblock]$ShouldCancel = { $false },
        [int]$MaxCandidates = 3
    )
    if ($MaxCandidates -lt 1) { return @{ Selected = $null; SelectedIndex = -1; WinnerFound = $false; Stopped = $false; Cancelled = $false; Count = 0; Candidates = @() } }
    $candidates = New-Object System.Collections.ArrayList
    $ranks = New-Object System.Collections.ArrayList
    $winnerIdx = -1
    $stopped = $false
    $cancelled = $false
    for ($k = 1; $k -le $MaxCandidates; $k++) {
        # #771: a stop that landed before this candidate must NOT start it. Honour the cancel BETWEEN
        # candidates (never mid-generation -- a running candidate finishes under its own circuit breaker).
        if ([bool](@(& $ShouldCancel)[-1])) { $cancelled = $true; break }
        & $OnCandidate $k $MaxCandidates
        # Normalise: take the LAST emitted object so a stray Write-Output cannot make the result an
        # array, and guarantee a hashtable so the caller's gate-signal reads stay real scalars.
        $res = @(& $RunCandidate $k $MaxCandidates)[-1]
        # A complete (disqualified) placeholder: ALL gate-signal keys present so the injected
        # ScoreCandidate / IsWinner reads never hit a $null that a [bool] param would reject.
        if ($res -isnot [hashtable]) { $res = @{ Malformed = $true; HasChanges = $false; VerifyResult = 'none'; TestResult = 'none'; TimedOut = $false; SecretBlocked = $false; LoopSuspected = $false } }
        [void]$candidates.Add($res)
        [void]$ranks.Add([int](@(& $ScoreCandidate $res)[-1]))
        if ([bool](@(& $IsWinner $res)[-1])) { $winnerIdx = $candidates.Count - 1; break }   # first green -> stop sampling
        if ([bool](@(& $StopSampling $res)[-1])) { $stopped = $true; break }                 # terminal (secret/timeout) -> stop, but no win
    }
    $arr = @($candidates)
    if ($winnerIdx -ge 0) {
        return @{ Selected = $arr[$winnerIdx]; SelectedIndex = $winnerIdx; WinnerFound = $true; Stopped = $false; Cancelled = $cancelled; Count = $arr.Count; Candidates = $arr }
    }
    $bestIdx = Select-BestCandidateIndex -Ranks @($ranks)
    $selected = if ($bestIdx -ge 0) { $arr[$bestIdx] } else { $null }
    return @{ Selected = $selected; SelectedIndex = $bestIdx; WinnerFound = $false; Stopped = $stopped; Cancelled = $cancelled; Count = $arr.Count; Candidates = $arr }
}

function Resolve-DispatchConcurrency {
    # CONCURRENCY KNOB (#695): resolve the effective best-of-N concurrency C from, in priority order,
    # an explicit caller value ($Explicit > 0 wins), then the env channel (BLARAI_DISPATCH_CONCURRENCY --
    # the detached /dispatch -> swap-driver -> run-fleet -> new-agent-task chain cannot pass a -param, so it
    # propagates an operator override the same way BLARAI_ENABLE_VISUAL_CRITIQUE does), then the built-in
    # PRODUCTION DEFAULT. Clamped to [1, Max]: C=1 is EXACTLY today's sequential path; the measured sweet
    # spot is 2-3 (continuous batching on the integrated Arc 140V is compute-bound, ~1.9-2.4x, little past
    # ~4 -- Vikunja #695 / PERFORMANCE_LOG 2026-06-27), so $Max defends against an absurd value spawning too
    # many concurrent coder process-trees. Pure + unit-tested without a model (verify-bestofn-concurrent.ps1).
    #
    # The PRODUCTION DEFAULT lives HERE (the -Default value) as the single source of truth (#695 DoD,
    # verify-then-enable). SET to 3: concurrency was live-proven on the Arc 140V (2026-06-27 -- a C=2 dispatch
    # drove OVMS continuous batching, `Scheduled requests` >= 2; a concurrent-gate stdin hang was found +
    # fixed; a C=3 dispatch then merged), and the LA chose C=3 within the measured 2-3 compute-bound sweet
    # spot -- 3 independent best-of-N samples per wall-clock (a moderate task runs all 3 at once, a complex
    # one finishes in fewer waves). Paired with the complex best-of-N budget raised 5->8 in Resolve-PassBudget
    # (more total shots at hard tasks; LA decision). C is clamped to [1, Max]; C=1 is the sequential path.
    param(
        [int]$Explicit = 0,
        [string]$EnvValue = '',
        [int]$Default = 3,
        [int]$Max = 8,
        # #714 RAM-headroom guard: when > 0, cap C so concurrent best-of-N coder trees cannot
        # starve each other on a tight box. 0 (default / unit tests) = NO guard -> pure resolution.
        [double]$AvailableGiB = 0,
        # measured headroom each concurrent coder (opencode + node + the growing build) needs on top
        # of the resident 30B. F2 (#670/#714): 3 candidates idle-starved at ~5 GiB free; 1 merged.
        [double]$GiBPerCandidate = 7
    )
    $c = 0
    if ($Explicit -gt 0) { $c = $Explicit }
    elseif ($EnvValue -and ("$EnvValue".Trim() -match '^\d+$')) { $c = [int]("$EnvValue".Trim()) }
    if ($c -le 0) { $c = $Default }
    if ($c -lt 1) { $c = 1 }
    if ($c -gt $Max) { $c = $Max }
    # RAM-HEADROOM GUARD (#714): the integrated Arc 140V shares LPDDR5X, so with the 30B resident a
    # tight box cannot feed N concurrent coder process-trees -- they idle-starve and the run STALLS
    # (a real production stall, 2026-07-01: C=3 at ~5 GiB free hung 27 min at [1/5]). When the caller
    # passes the live free RAM, cap C to what the headroom supports (never below 1). It only ever
    # LOWERS C; AvailableGiB=0 leaves the pure resolution above untouched (tests stay deterministic).
    if ($AvailableGiB -gt 0 -and $GiBPerCandidate -gt 0) {
        $ramCap = [int][math]::Max(1, [math]::Floor($AvailableGiB / $GiBPerCandidate))
        if ($c -gt $ramCap) { $c = $ramCap }
    }
    return $c
}

function Resolve-WorktreeBase {
    # WORKTREE LOCATION (#714): the fleet builds each task in throwaway git worktrees (one base + up to N
    # best-of-N candidates). They USED to be created BESIDE the operator's project ("<repo>-<task>[-cK]"),
    # so a KILLED/crashed run -- which never reaches the cleanup at the end of new-agent-task.ps1 -- left
    # "-c1/-c2/-c3" copies LITTERING the projects/ dir (the operator's "why are there all these extra
    # folders?", 2026-07-01). They now live in a hidden, gitignored, fleet-owned base (agentic-setup/
    # state/worktrees), so projects/ only EVER shows the one folder the operator named -- even a worktree
    # leaked by a hard-killed run is invisible here, not beside the project. Pure: derives the base from the
    # scripts dir; the caller creates it. Unit-tested in verify-worktree-location.ps1 (no git, no model).
    #
    # #775 ACP-01 (D-B): the (b) containment floor relocates the throwaway worktree base OUT of the operator
    # profile so the profile default-deny does the containment heavy-lifting (a separate standard account is
    # already denied everything under C:\Users\mrbla) instead of hand-punching read-holes into it -- and to a
    # SHARED tree both the operator SID and the coder SID can Modify, so the orchestrator-side merge can still
    # read the coder-created files. This is FLAG-GATED: it fires ONLY when -Containment 'restricted_account'.
    # With the default -Containment 'off' the return is BYTE-IDENTICAL to today (the 23:00 battery runs the
    # EXACT current path), so nothing merged here can move the live worktree base until the flag flips.
    param(
        [Parameter(Mandatory)][string]$ScriptRoot,
        [ValidateSet('off','restricted_account')][string]$Containment = 'off'
    )
    if ($Containment -eq 'restricted_account') { return 'C:\blarai-fleet\worktrees' }
    Join-Path (Split-Path $ScriptRoot -Parent) 'state\worktrees'
}

function Invoke-BestOfNBatched {
    # BEST-OF-N CONCURRENT batched sampling (#695, epic #688). The CONCURRENT analogue of Invoke-BestOfN:
    # the SAME deterministic-gate-as-selector policy, but candidates run in concurrent BATCHES of up to
    # $Concurrency (each in its own worktree, hitting OVMS continuous batching -- measured viable on the
    # integrated Arc 140V, #695). Returns the SAME shape as Invoke-BestOfN so new-agent-task's downstream
    # selection/restore/merge is byte-identical. POLICY ONLY: the concurrent mechanism is the injected
    # -RunBatch, so this whole control flow is unit-tested deterministically WITHOUT a model
    # (verify-bestofn-concurrent.ps1), exactly like Invoke-BestOfN.
    #
    #   -RunBatch {param($Indices,$Total) -> @(results)}  run a BATCH of candidates CONCURRENTLY and return
    #                 their result hashtables IN $Indices ORDER (one element per index). Each result carries
    #                 the gate signals (+ in production its Worktree/Branch/Index so the caller can promote
    #                 the winner + clean up the losers). A non-hashtable element is normalised below.
    #   -IsWinner / -ScoreCandidate / -StopSampling : IDENTICAL semantics to Invoke-BestOfN.
    #   -OnBatch {param($Indices,$Total)} : optional progress callback BEFORE each batch.
    #
    # BATCH POLICY -- preserves the sequential posture under batching (the highest-risk regression, #695 §6):
    #   * A whole batch runs concurrently; there is NO early-exit WITHIN a batch (all C already ran).
    #   * After a batch completes, the EARLIEST-index winner in it wins -> stop launching further batches.
    #     The winner is checked BEFORE the stop, so a batch holding BOTH a green winner AND a secret/timeout
    #     candidate still selects the (clean, independent) winner -- matching Invoke-BestOfN's "a green winner
    #     is never terminal". (The non-selected secret candidate's work is discarded with its worktree and
    #     never committed/merged, so it cannot leak; the caller surfaces a non-blocking note.)
    #   * Else if any candidate in the batch is a StopSampling terminal (secret OR timeout): stop launching
    #     further batches, but DO NOT select it as a win -- selection falls to the best partial by rank
    #     (Get-CandidateRank sinks a timeout below every real attempt, a secret far below that). The secret
    #     candidate stays in Candidates for the caller to surface/park (never sampled-away).
    #   * Else continue with the next batch until $MaxCandidates candidates have run.
    # Selection = the winner if found, else the highest-ranked candidate across ALL run so far (best partial).
    # With $Concurrency = 1 this reduces to Invoke-BestOfN's exact behaviour (batch size 1, one per round).
    param(
        [Parameter(Mandatory)][scriptblock]$RunBatch,
        [Parameter(Mandatory)][scriptblock]$IsWinner,
        [scriptblock]$ScoreCandidate = { param($r) 0 },
        [scriptblock]$StopSampling = { param($r) $false },
        [scriptblock]$OnBatch = {},
        # #771 STOP-CONTRACT: checked BEFORE each concurrent BATCH (the batch analogue of Invoke-BestOfN's
        # between-candidate check). Production passes { Test-DispatchCancelled }; default { $false } is pure.
        [scriptblock]$ShouldCancel = { $false },
        [int]$MaxCandidates = 3,
        [int]$Concurrency = 2
    )
    if ($MaxCandidates -lt 1) { return @{ Selected = $null; SelectedIndex = -1; WinnerFound = $false; Stopped = $false; Cancelled = $false; Count = 0; Candidates = @() } }
    $C = if ($Concurrency -lt 1) { 1 } else { $Concurrency }
    $candidates = New-Object System.Collections.ArrayList
    $ranks = New-Object System.Collections.ArrayList
    $winnerIdx = -1
    $stopped = $false
    $cancelled = $false
    $next = 1
    while (($next -le $MaxCandidates) -and ($winnerIdx -lt 0) -and (-not $stopped) -and (-not $cancelled)) {
        # #771: a stop that landed before this batch must NOT launch it (no fresh candidates after a stop).
        if ([bool](@(& $ShouldCancel)[-1])) { $cancelled = $true; break }
        $batchN = [Math]::Min($C, $MaxCandidates - $next + 1)
        $indices = @($next..($next + $batchN - 1))
        & $OnBatch $indices $MaxCandidates
        $batch = @(& $RunBatch $indices $MaxCandidates)
        # Append the batch's results IN INDEX ORDER, normalising each to a hashtable (a stray/non-hashtable
        # element becomes a fully-disqualified placeholder so the injected gate reads stay real scalars).
        $batchStart = $candidates.Count
        for ($j = 0; $j -lt $batchN; $j++) {
            $res = if ($j -lt $batch.Count) { $batch[$j] } else { $null }
            if ($res -isnot [hashtable]) { $res = @{ Malformed = $true; HasChanges = $false; VerifyResult = 'none'; TestResult = 'none'; TimedOut = $false; SecretBlocked = $false; LoopSuspected = $false } }
            [void]$candidates.Add($res)
            [void]$ranks.Add([int](@(& $ScoreCandidate $res)[-1]))
        }
        # Earliest-index winner in this batch wins (checked BEFORE the stop -> a winner alongside a
        # secret/timeout in the same batch still wins).
        for ($j = 0; $j -lt $batchN; $j++) {
            $abs = $batchStart + $j
            if ([bool](@(& $IsWinner $candidates[$abs])[-1])) { $winnerIdx = $abs; break }
        }
        if ($winnerIdx -ge 0) { break }
        # No winner: a terminal (secret/timeout) ANYWHERE in the batch stops launching further batches.
        for ($j = 0; $j -lt $batchN; $j++) {
            $abs = $batchStart + $j
            if ([bool](@(& $StopSampling $candidates[$abs])[-1])) { $stopped = $true; break }
        }
        $next += $batchN
    }
    $arr = @($candidates)
    if ($winnerIdx -ge 0) {
        return @{ Selected = $arr[$winnerIdx]; SelectedIndex = $winnerIdx; WinnerFound = $true; Stopped = $false; Cancelled = $cancelled; Count = $arr.Count; Candidates = $arr }
    }
    $bestIdx = Select-BestCandidateIndex -Ranks @($ranks)
    $selected = if ($bestIdx -ge 0) { $arr[$bestIdx] } else { $null }
    return @{ Selected = $selected; SelectedIndex = $bestIdx; WinnerFound = $false; Stopped = $stopped; Cancelled = $cancelled; Count = $arr.Count; Candidates = $arr }
}

function Test-IsGatedTestPath {
    # #790: does this repo-relative path name a test file the per-candidate gate COLLECTS? PYTHON only
    # for now -- pytest/unittest naming (test_*.py / *_test.py). Node (*.test.js) + Pester (*.Tests.ps1)
    # coder-authored tests are deliberately NOT scoped yet (their runners glob differently; scoping them
    # is a documented follow-up), so their behaviour is byte-identical to before. Never matches under a
    # vendor/vcs dir. Pure + ASCII; unit-tested without a repo.
    param([string]$Path)
    if ([string]::IsNullOrWhiteSpace($Path)) { return $false }
    $p = $Path -replace '\\', '/'
    if ($p -match '(^|/)(\.git|\.venv|venv|node_modules)/') { return $false }
    $leaf = ($p -split '/')[-1]
    return ($leaf -match '^test_.*\.py$') -or ($leaf -match '.+_test\.py$')
}

function Split-CandidateTestFiles {
    # #790: PURE partition (no git, no I/O -- unit-testable with plain arrays) of a candidate's test files
    # into TRUSTED vs SCRATCH. TRUSTED = the BASELINE set (every test file present in the coder's baseline
    # tree: the seeded #690 oracle + any prior-wave / product tests -- the immutable SPEC). It is returned
    # as the WHOLE baseline set (not the intersection with the worktree) SO THAT a candidate DELETING a
    # baseline test cannot shrink the hard gate -- the caller restores each Trusted path from the baseline.
    # SCRATCH = worktree test files whose path is NOT in the baseline (i.e. coder-ADDED this task): an
    # advisory soft signal, never a hard block. Paths are matched case-insensitively as POSIX-normalised
    # repo-relative strings (Windows fs + git-tree slashes reconciled).
    param([string[]]$BaseTestFiles = @(), [string[]]$WorktreeTestFiles = @())
    $norm = { param($s) ($s -replace '\\', '/') }
    $baseSet = @{}
    foreach ($b in $BaseTestFiles) { if ($b) { $baseSet[((& $norm $b)).ToLowerInvariant()] = $true } }
    $scratch = New-Object System.Collections.ArrayList
    foreach ($w in $WorktreeTestFiles) {
        if (-not $w) { continue }
        $wn = & $norm $w
        if (-not $baseSet.ContainsKey($wn.ToLowerInvariant())) { [void]$scratch.Add($wn) }
    }
    $trusted = @($BaseTestFiles | Where-Object { $_ } | ForEach-Object { & $norm $_ })
    return @{ Trusted = $trusted; Scratch = @($scratch) }
}

function Get-CandidateTestPartition {
    # #790: gather a candidate worktree's test files from git + the filesystem and classify them
    # (Split-CandidateTestFiles). BASELINE tests come from the $BaseRef TREE (git ls-tree -- exactly what
    # the coder inherited); WORKTREE tests from the FILESYSTEM so a still-UNTRACKED coder-added file is
    # seen (this runs BEFORE `git add`). Only PYTHON test files are classified (Test-IsGatedTestPath), so
    # a project with no coder-added python tests yields an empty Scratch set == today's behaviour. Reads
    # only; returns @{ Trusted; Scratch } of POSIX repo-relative paths.
    param([Parameter(Mandatory)][string]$Worktree, [Parameter(Mandatory)][string]$BaseRef)
    $base = @(git -C $Worktree ls-tree -r --name-only $BaseRef 2>$null | Where-Object { Test-IsGatedTestPath $_ })
    $root = (Resolve-Path -LiteralPath $Worktree).Path
    $wtFiles = New-Object System.Collections.ArrayList
    foreach ($f in @(Get-ChildItem -Path $root -Recurse -File -Filter '*.py' -ErrorAction SilentlyContinue)) {
        $rel = $f.FullName.Substring($root.Length).TrimStart('\', '/') -replace '\\', '/'
        if (Test-IsGatedTestPath $rel) { [void]$wtFiles.Add($rel) }
    }
    return Split-CandidateTestFiles -BaseTestFiles $base -WorktreeTestFiles @($wtFiles)
}

function Invoke-ScratchTestSignal {
    # #790: run coder-ADDED ("scratch") test files as an ADVISORY soft signal, ONE FILE AT A TIME so a
    # single buggy self-verification test is isolated to ITS file. NEVER sets the hard TestResult -- the
    # caller uses this only to (a) surface the signal (fail-LOUD -- a control that degrades silently is
    # worse than none) and (b) DROP the RED files before the commit so a coder's buggy throwaway test
    # neither parks working code NOR poisons a downstream wave's baseline gate; a GREEN file is KEPT
    # (delivered coverage that stays green). Mirrors the [2/5] pytest env (PYTHONPATH=worktree, the uv
    # ephemeral install with a local-python fallback). Exit 0/5 (pass / nothing-collected) = green; any
    # other exit or a timeout = red. Returns @{ Result='pass'|'fail'|'none'; Green; Red; Detail }.
    param([Parameter(Mandatory)][string]$Worktree, [string[]]$ScratchTests = @(), [int]$TimeoutSec = 300)
    $green = New-Object System.Collections.ArrayList
    $red = New-Object System.Collections.ArrayList
    if (@($ScratchTests).Count -eq 0) { return @{ Result = 'none'; Green = @(); Red = @(); Detail = 'no coder-added tests' } }
    $useUv = [bool](Get-Command uv -ErrorAction SilentlyContinue)
    $prevPP = $env:PYTHONPATH
    $env:PYTHONPATH = $Worktree
    try {
        foreach ($rel in $ScratchTests) {
            $cmd = if ($useUv) { "uv run --no-project --with pytest --with hypothesis pytest -q `"$rel`"" } else { "python -m pytest -q `"$rel`"" }
            $r = Invoke-WithTimeout -CommandLine $cmd -WorkDir $Worktree -TimeoutSec $TimeoutSec
            if ($r.TimedOut) { [void]$red.Add($rel) }
            elseif (($r.ExitCode -eq 0) -or ($r.ExitCode -eq 5)) { [void]$green.Add($rel) }   # 5 = nothing collected (empty file) -> harmless, keep
            else { [void]$red.Add($rel) }
        }
    } finally {
        if ($null -eq $prevPP) { Remove-Item Env:\PYTHONPATH -ErrorAction SilentlyContinue } else { $env:PYTHONPATH = $prevPP }
    }
    $result = if ($red.Count -gt 0) { 'fail' } elseif ($green.Count -gt 0) { 'pass' } else { 'none' }
    $detail = "$($green.Count) green kept, $($red.Count) red dropped-from-merge (of $(@($ScratchTests).Count) coder-added)"
    return @{ Result = $result; Green = @($green); Red = @($red); Detail = $detail }
}

function Invoke-CandidateBuild {
    # BEST-OF-N candidate pipeline (#695; UNIFIED by #700). The SINGLE per-candidate build->gate function for
    # BOTH the sequential (C=1) and concurrent (C>1) paths. It takes EVERY input as a PARAMETER (no
    # script-scope closure), so it runs IDENTICALLY in new-agent-task's main process (the sequential
    # RunCandidate + the review-FIX loop) AND inside a Start-Job CHILD PROCESS (one per concurrent candidate).
    # Process isolation (Start-Job, NOT Start-ThreadJob) for the concurrent path is DELIBERATE: this gate's
    # pytest step AND Invoke-AgentRun both mutate the process-global $env:PYTHONPATH, which would RACE across
    # ThreadJobs sharing one process; separate processes give each candidate its own environment.
    #
    # Pipeline = (optional reset-to-base) -> build (inner no-op retry) -> oracle-restore -> secret-scan ->
    # commit -> [2/5] tests -> [3/5] verify. Returns the CANDIDATE-shape hashtable best-of-N selection expects
    # (+ a `LogPath` alias for the sequential callers that read it). -ResetToBase $true does the sequential
    # reuse-ONE-worktree reset to $CodeBase between candidates; the concurrent path gives each candidate a
    # FRESH worktree, so it leaves -ResetToBase $false (the default). Before #700 this logic was duplicated in
    # new-agent-task's $BuildTestVerify closure; #700 folded that into this one function.
    param(
        [Parameter(Mandatory)][string]$ScriptRoot,
        [Parameter(Mandatory)][string]$Worktree,
        [Parameter(Mandatory)][string]$Model,
        [Parameter(Mandatory)][string]$CodeBase,
        [Parameter(Mandatory)][string]$AttemptPrompt,
        [Parameter(Mandatory)][string]$LogPath,
        [string]$Task = 'task',
        [string]$BaseBranch = 'main',
        [int]$MaxBuildAttempts = 3,
        [int]$MaxRunMinutes = 60,
        [int]$IdleTimeoutSec = 240,
        [bool]$OracleActive = $false,
        [string]$AcceptanceTestPath = '',
        [string]$Surface = '',
        [string]$LanguageHint = '',
        # #771 STOP-CONTRACT: checked BEFORE each numbered gate step (tests, verify). Production passes
        # { Test-DispatchCancelled } (works in the Start-Job child too -- it reads the same on-disk sentinel);
        # default { $false } keeps this unit-testable. A stop mid-generation lets the CURRENT generation finish
        # under its own circuit breaker (bounded), but a stopped candidate then SKIPS its gate and parks its
        # committed work rather than auto-merging a validation we cut short.
        [scriptblock]$ShouldCancel = { $false },
        [bool]$ResetToBase = $false
    )
    $wt = $Worktree
    $cancelled = $false
    # #700: the sequential path reuses ONE worktree across candidates, so candidate k>1 resets it to the
    # shared baseline first (a FRESH independent start). The concurrent path gets a fresh worktree per
    # candidate already AT $CodeBase, so it leaves -ResetToBase $false. (Was $BuildTestVerify's `if
    # ($resetToBase)` line, verbatim.)
    if ($ResetToBase) { git -C $wt reset --hard $CodeBase 2>&1 | Out-Null; git -C $wt clean -fd 2>&1 | Out-Null }
    # Inner no-op retry (Invoke-BuildWithRetry): a small/quantized model intermittently produces a NO-OP
    # build; cheap independent re-runs lift ~50% per-attempt to ~85-90%. Never retries a timeout. Each retry
    # starts CLEAN (reset to HEAD == $CodeBase, since no commit has landed yet for this fresh candidate).
    # #1049 candidate (b): $escape is the state box the three closures below share (they resolve it
    # lexically). $escape.active flips on the FIRST retry, so attempt 1's prompt AND detection are
    # byte-identical to legacy; the kill-switch env var is read ONCE here (it reaches Start-Job
    # candidate children via the inherited environment). With the escape inactive the -NoChangeDeclared
    # probe short-circuits to $false -- a declaration can only ever be honoured on a prompt that
    # actually OFFERED the escape (an accidental marker echo on attempt 1 can never terminate the loop).
    # F1 (reviewer): $escape.anchor is captured by RunAgent BEFORE each attempt so the probe reads
    # ONLY the current attempt's output -- the live ACP driver APPENDS all attempts into the one
    # shared $LogPath, and an unscoped probe on attempt 2 could be satisfied by a spontaneous
    # marker attempt 1 emitted (whose prompt never offered the escape). The anchor (length +
    # prefix hash, Get-TranscriptAnchor) distinguishes grew-vs-rewritten, so the stdin driver's
    # per-attempt truncate resolves to whole-file scope even when the new transcript is longer.
    $escape = @{ active = $false; anchor = $null; enabled = (Test-NoChangeEscapeEnabled -EnvValue $env:BLARAI_NO_CHANGE_ESCAPE) }
    $build = Invoke-BuildWithRetry -MaxBuildAttempts $MaxBuildAttempts `
        -OnRetry { param($n) if ($escape.enabled) { $escape.active = $true }; Write-Host "  Attempt $($n - 1) produced no changes; retrying ($n/$MaxBuildAttempts) from a clean worktree$(if ($escape.active) { ' (no-change escape offered)' })..." -ForegroundColor Yellow } `
        -ResetWorktree { git -C $wt reset --hard HEAD 2>&1 | Out-Null; git -C $wt clean -fd 2>&1 | Out-Null } `
        -RunAgent { $escape.anchor = Get-TranscriptAnchor -LogPath $LogPath; Invoke-CoderDriver -WorkDir $wt -Model $Model -Prompt $(if ($escape.active) { Add-NoChangeEscape -Prompt $AttemptPrompt } else { $AttemptPrompt }) -LogPath $LogPath -TimeoutSec ($MaxRunMinutes * 60) -IdleTimeoutSec $IdleTimeoutSec -ScriptRoot $ScriptRoot } `
        -ProducedChanges { (@(git -C $wt status --porcelain 2>$null).Count -gt 0) -or (([int](git -C $wt rev-list --count "$CodeBase..HEAD" 2>$null)) -gt 0) } `
        -NoChangeDeclared { if ($escape.active) { (Get-NoChangeDeclaration -LogPath $LogPath -Anchor $escape.anchor).Declared } else { $false } }
    $run = $build.Run
    $noChangeDeclared = [bool]$build.NoChangeDeclared
    $noChangeEvidence = ''
    if ($noChangeDeclared) {
        # F1: the evidence read rides the SAME attempt scope the probe fired on -- never an
        # earlier attempt's accumulated text.
        $noChangeEvidence = (Get-NoChangeDeclaration -LogPath $LogPath -Anchor $escape.anchor).Evidence
        Write-Host "  NO CHANGE NEEDED declared by the coder -- honest terminal outcome; retries stopped, no diff manufactured (#1049). Evidence: $noChangeEvidence" -ForegroundColor Yellow
    }
    if ($run.Error) { Write-Host "  $($run.Error)" -ForegroundColor Red }
    if ($run.TimedOut) {
        $why = switch ($run.TimeoutReason) {
            'idle'    { "went idle (no new step/edit for ${IdleTimeoutSec}s) -- genuinely stuck" }
            'ceiling' { "hit the ${MaxRunMinutes}-min ceiling while still working" }
            default   { "exceeded its time budget" }
        }
        Write-Host "  CIRCUIT BREAKER: agent $why and was stopped." -ForegroundColor Red
    }
    if ($run.Capped) { Write-Host "  TURN CAP: agent bounded ($($run.CappedReason)); work kept, the gate decides the merge." -ForegroundColor Yellow }
    if ($build.Attempts -gt 1) { Write-Host "  (build took $($build.Attempts) attempts$(if (-not $build.ProducedChanges) { '; still no changes' }))" -ForegroundColor DarkGray }
    Write-Host "  (agent transcript -> $LogPath)" -ForegroundColor DarkGray
    $anomaly = Get-RunAnomalies -LogPath $LogPath -TimedOut $run.TimedOut -ExitCode $run.ExitCode -TimeoutReason "$($run.TimeoutReason)"
    if ($anomaly.LoopSuspected) { Write-Host "  CIRCUIT BREAKER: possible loop/instability detected; this candidate cannot auto-merge." -ForegroundColor Yellow }
    # #690: RESTORE the protected acceptance oracle BEFORE staging + the gate, so a candidate that edited,
    # weakened, or deleted it is OVERWRITTEN -- judged by the BYTE-IDENTICAL scorecard, and the merged commit
    # keeps the original. `git checkout <baseline> -- <path>` re-materialises the committed bytes.
    if ($OracleActive) { git -C $wt checkout $CodeBase -- $AcceptanceTestPath 2>&1 | Out-Null }
    # #790: SCOPE the per-candidate hard gate to the SPEC/BASELINE tests, quarantining the coder's own
    # throwaway self-verification tests. A plan-graph NODE seeds NO oracle into the worktree (the job
    # oracle runs only at integration -- BlarAI shared/fleet/acceptance.py), so EVERY test_*.py at a node
    # is coder-authored; a buggy self-test (B4 night-20260715: `test_final_verification_fixed.py`, an
    # UnboundLocalError IN THE TEST) then failed `pytest -x -q` and PARKED ~90%-complete working code --
    # a gate ARTIFACT sinking good work, the same shape as the idle-abort park. Fix: partition test files
    # into TRUSTED (present in the coder's baseline $CodeBase -> the seeded oracle + prior-wave / product
    # tests: the immutable spec) and SCRATCH (coder-ADDED this task). RESTORE every Trusted test from the
    # baseline (fail-closed: a candidate cannot delete or weaken a spec test to pass -- the same protect
    # property #690 gives the oracle, generalised to every baseline test). Run SCRATCH as an ADVISORY soft
    # signal (reported, NEVER a hard block); DROP the RED scratch files before the commit so a red self-test
    # neither parks working code NOR poisons a downstream wave's baseline gate, and KEEP the GREEN ones
    # (delivered coverage that stays green). Runs AFTER the oracle restore + BEFORE staging, so the merged
    # candidate keeps the baseline spec tests and never carries a red scratch test. FORGIVING: any scoping
    # error falls back to today's whole-tree gate (fail-safe toward the stricter old behaviour, never open).
    try {
        $__part = Get-CandidateTestPartition -Worktree $wt -BaseRef $CodeBase
        foreach ($__tt in @($__part.Trusted)) { git -C $wt checkout $CodeBase -- "$__tt" 2>&1 | Out-Null }
        if (@($__part.Scratch).Count -gt 0) {
            $__scratch = Invoke-ScratchTestSignal -Worktree $wt -ScratchTests @($__part.Scratch)
            foreach ($__rf in @($__scratch.Red)) { Remove-Item (Join-Path $wt $__rf) -Force -ErrorAction SilentlyContinue }
            $__scColor = if ($__scratch.Result -eq 'fail') { 'Yellow' } else { 'DarkGray' }
            Write-Host "  SCRATCH TESTS (coder-added; advisory, non-gating): $($__scratch.Detail)" -ForegroundColor $__scColor
        }
    } catch {
        Write-Host "  test-gate scoping skipped (non-fatal; whole-tree gate stands): $($_.Exception.Message)" -ForegroundColor Yellow
    }
    # ---- CAPTURE the coder's work: stage -> SECRET-SCAN -> commit (a detected secret never enters
    # history + never merges). #1074 FAIL-LOUD: every git command in this step is EXIT-CODE CHECKED
    # and its stderr KEPT. Before #1074 all three channels were `2>&1 | Out-Null` with no exit check,
    # so a failed add/commit was indistinguishable from an honest no-op and fell open to "the coder
    # produced nothing" -- an infrastructure fault laundered into the capability measurement. The
    # classification (and the reasoning behind the honest-no-op discrimination) lives in the pure
    # Resolve-CommitCapture; this block's only job is to OBSERVE accurately and hand it the facts.
    # WINDOWS RESERVED DEVICE NAMES DESTROY THE CAPTURE (#1276). MEASURED 2026-08-06, battery
    # B4 store-cards: the coder left a file literally named `nul` in the worktree (shell
    # redirect residue), and `git add -A` died on it:
    #     error: short read while indexing nul
    #     error: nul: failed to insert into database
    #     fatal: adding files failed            (git exit 128)
    # All THREE candidates hit it identically -- 429s + 368s + 430s of real coder work
    # discarded -- the job PARKED-HONEST[BUILD], and its five dependent tasks skipped. The
    # coder was not at fault and nothing in the run measured the model.
    #
    # These names (CON/PRN/AUX/NUL/COM1-9/LPT1-9, with or without an extension) are DEVICES,
    # not files. They can never be a legitimate deliverable, git cannot index them, and one
    # of them is enough to throw away everything the coder produced. Removing them is the
    # only outcome that preserves the work; leaving them is a guaranteed total loss.
    #
    # Deletion needs the \?\ extended-length prefix: ordinary Remove-Item resolves the name
    # to the DEVICE and fails. Swept LOUDLY -- a silent sweep would hide a real signal about
    # what the coder is doing.
    $__reserved = @()
    try {
        Get-ChildItem -LiteralPath $wt -Recurse -Force -File -ErrorAction SilentlyContinue |
            Where-Object { $_.FullName -notlike '*\.git\*' -and
                           $_.BaseName -match '^(?i)(CON|PRN|AUX|NUL|COM[1-9]|LPT[1-9])$' } |
            ForEach-Object {
                $__p = $_.FullName
                # The \\?\ extended-length prefix is REQUIRED: without it the path resolves to
                # the DEVICE and the delete fails -- the same reason git cannot index it.
                try { [System.IO.File]::Delete("\\?\" + $__p); $__reserved += $__p }
                catch { $__reserved += "$__p (UNREMOVABLE: $($_.Exception.Message))" }
            }
    } catch { }
    if ($__reserved.Count -gt 0) {
        Write-Host ("  reserved-name sweep: removed $($__reserved.Count) Windows device-name " +
                    "file(s) before staging -- they cannot be indexed and would fail the whole " +
                    "capture: " + ($__reserved -join ', '))
    }
    $addOut = (git -C $wt add -A 2>&1 | Out-String); $addRc = $LASTEXITCODE
    # Read the INDEX, not git's English: the staged set is what tells an honest "nothing to commit"
    # apart from a real commit failure, so a commit is only ATTEMPTED when something is staged.
    # STDOUT ONLY for the two reads whose output is COUNTED. git writes warnings and advice to stderr
    # ("warning: LF will be replaced by CRLF", "warning: ignoring broken ref", ...), and merging those
    # into the stream would let a DIAGNOSTIC STRING be counted as a staged path or a dirty entry --
    # which would turn an honest no-op into a false capture fault, the same class of defect as #1074
    # itself pointed the other way. git's stderr is re-read separately, and only on the error path,
    # where it is a MESSAGE rather than data. (The add/commit captures below merge freely: their
    # output is never counted, only reported.)
    $stagedOut = @(); $stagedRaw = ''; $stagedRc = 0
    if ($addRc -eq 0) {
        $stagedOut = @(git -C $wt diff --cached --name-only 2>$null | Where-Object { "$_".Trim() })
        $stagedRc = $LASTEXITCODE
        if ($stagedRc -ne 0) { $stagedOut = @(); $stagedRaw = (git -C $wt diff --cached --name-only 2>&1 | Out-String) }
    }
    $commitRc = $null; $commitOut = ''
    $secret = $null; $secretBlocked = $false
    if (($addRc -ne 0) -or ($stagedRc -ne 0)) {
        # FAIL-CLOSED: the index is not in a state we can trust, so nothing is scanned and nothing is
        # committed. The scan's verdict would be about a stale/empty index, not about this build.
        $secret = [pscustomobject]@{ status = 'skipped'; count = 0; detail = "the stage step failed, so the staged set was never scanned and nothing was committed" }
        Write-Host "  SECRET SCAN: NOT RUN - the staging step failed before it (see the CAPTURE FAULT below)." -ForegroundColor Red
    } else {
        $secret = & "$ScriptRoot\secret-scan.ps1" -Repo $wt
        $secretBlocked = ($secret -and $secret.status -eq 'blocked')
        if ($secretBlocked) {
            Write-Host "  SECRET SCAN: BLOCKED - $($secret.detail)" -ForegroundColor Red
            git -C $wt reset 2>&1 | Out-Null   # unstage; leave the work in the worktree for human review
        } else {
            if ($secret.status -eq 'unavailable') { Write-Host "  SECRET SCAN: skipped (gitleaks not installed - run install-gitleaks.ps1)" -ForegroundColor Yellow }
            else { Write-Host "  SECRET SCAN: clean" -ForegroundColor Green }
            if (@($stagedOut).Count -gt 0) {
                $commitOut = (git -C $wt -c user.email='agent@local' -c user.name='coding-agent' commit -m "agent: $Task" 2>&1 | Out-String)
                $commitRc = $LASTEXITCODE
            }
            # else: nothing staged == the honest no-op. Skipping the commit keeps that case OUT of the
            # failure channel entirely, which is what makes a non-zero $commitRc unambiguous above.
        }
    }
    # The THIRD swallowed channel the ticket names. stdout only (this is COUNTED data), exit code
    # CHECKED, and the value must actually BE a number. An unresolvable base ref makes rev-list fail,
    # and a bare `else { 0 }` would then report a branch that HOLDS the coder's commit as "none
    # made" -- the same laundering by a different route, which is why moving this line was never the
    # same thing as fixing it.
    $__rl = "$(git -C $wt rev-list --count "$CodeBase..HEAD" 2>$null)".Trim()
    $rlRc = $LASTEXITCODE
    $rlRaw = ''
    $baseResolvable = $true
    if (($rlRc -ne 0) -or ($__rl -notmatch '^\d+$')) {
        $rlRaw = (git -C $wt rev-list --count "$CodeBase..HEAD" 2>&1 | Out-String)
        # Only when the count already failed: is the BASELINE itself resolvable here? $CodeBase is not
        # guaranteed to be a SHA (the caller falls back to a branch NAME), so an unresolvable base is a
        # dispatch-config problem on a perfectly healthy repo -- not a failure to capture anything.
        git -C $wt rev-parse --verify --quiet "$CodeBase^{commit}" 2>&1 | Out-Null
        $baseResolvable = ($LASTEXITCODE -eq 0)
    }
    $commitCount = if ($__rl -match '^\d+$') { [int]$__rl } else { 0 }
    # The invariant read must stay HERE -- immediately after the commit, BEFORE the [2/5] test and
    # [3/5] verify steps. Those steps legitimately litter the tree (a python verify leaves
    # app/__pycache__/), so a status read taken later would turn every healthy python build into a
    # false capture fault. Locked by verify-git-capture-honesty.ps1 D5f.
    $dirtyLines = @(git -C $wt status --porcelain 2>$null | Where-Object { "$_".Trim() })   # stdout only -- see above
    $statusRc = $LASTEXITCODE
    $statusRaw = ''
    $dirtyCount = if ($statusRc -eq 0) { $dirtyLines.Count } else { $statusRaw = (git -C $wt status --porcelain 2>&1 | Out-String); 0 }
    $capture = Resolve-CommitCapture -AddExitCode $addRc -AddOutput $addOut `
        -StagedReadExitCode $stagedRc -StagedReadOutput $stagedRaw -StagedCount (@($stagedOut).Count) `
        -SecretBlocked $secretBlocked -CommitExitCode $commitRc -CommitOutput $commitOut `
        -CommitCount $commitCount -CommitCountReadExitCode $rlRc -CommitCountRaw $__rl -CommitCountReadOutput $rlRaw `
        -StatusReadExitCode $statusRc -StatusReadOutput $statusRaw `
        -WorktreeDirtyCount $dirtyCount -BaseResolvable $baseResolvable -BaseRef "$CodeBase"
    $gitFailed = [bool]$capture.Failed
    $gitError = "$($capture.Error)"
    $hasChanges = [bool]$capture.HasChanges
    if ($gitFailed) {
        # LOUD: this is an ERRORED task, never an empty build. The work (if any) stays in the worktree.
        Write-Host "  CAPTURE FAULT ($($capture.Reason)): $gitError" -ForegroundColor Red
        Write-Host "  This task is ERRORED, not a no-op: the coder's output was NOT captured, so nothing here measures the model." -ForegroundColor Red
    } elseif ($capture.Reason -eq 'base-unresolvable') {
        # Loud but NOT a fault: the capture worked, the baseline we were handed does not resolve.
        Write-Host "  BASELINE UNRESOLVABLE (dispatch config, NOT a capture failure): $gitError" -ForegroundColor Yellow
    }
    $sha = if ($hasChanges) { "$(git -C $wt rev-parse HEAD 2>$null)".Trim() } else { '' }
    # #771: a stop that landed during generation short-circuits the gate steps (tests + verify) -- the
    # candidate's work is already committed to its branch (reflog-reachable), so it PARKS rather than
    # auto-merging a gate we didn't finish. VerifyResult/TestResult stay 'none' => never a winner => park.
    if ([bool](@(& $ShouldCancel)[-1])) { $cancelled = $true }
    # ---- [2/5] Tests (forgiving detection: absence of tests is not failure) ----
    $testResult = 'none'; $testOut = ''
    if ($hasChanges -and -not $cancelled -and -not $gitFailed) {   # #1074: never grade a build we could not capture
        if ((Test-Path (Join-Path $wt 'package.json')) -and
            (Select-String -Path (Join-Path $wt 'package.json') -Pattern '"test"\s*:' -Quiet) -and
            ((Test-Path (Join-Path $wt 'node_modules')) -or
             (Select-String -Path (Join-Path $wt 'package.json') -Pattern '"test"\s*:\s*"[^"]*node\s+--test' -Quiet))) {
            Write-Host "[2/5] Running npm test..." -ForegroundColor Cyan
            Push-Location $wt; $testOut = (cmd /c "npm test" 2>&1 | Out-String); Write-Host $testOut; $testResult = if ($LASTEXITCODE -eq 0) { 'pass' } else { 'fail' }; Pop-Location
        }
        elseif ((Test-Path (Join-Path $wt 'pyproject.toml')) -or (Test-Path (Join-Path $wt 'tests'))) {
            Write-Host "[2/5] Running pytest..." -ForegroundColor Cyan
            # Put the project root on PYTHONPATH so a test in tests/ can import a root module. SAFE under
            # concurrency: Invoke-CandidateBuild runs in its OWN Start-Job process, so this $env: mutation
            # is process-local and cannot race another candidate (the reason for Start-Job, not ThreadJob).
            $prevPP = $env:PYTHONPATH
            $env:PYTHONPATH = $wt
            Push-Location $wt
            try {
                # DoD row 4: --hypothesis-show-statistics ADDED (#1195 residual). Half that row's
                # proof set -- `unexecuted_property` -- could not fire in production for one
                # reason: this line produced no statistics artifact, so `-StatsPath` had nothing
                # to point at and `PropertyExecutionMeasured` was false on every run ever made.
                # A dead `@given` and a real one were indistinguishable in the report.
                #
                # SAFE BY CONSTRUCTION, and that is why it is done here rather than argued: the
                # flag only ADDS output. Hypothesis is already installed on this very line
                # (`--with hypothesis`), so the argument is recognised; the exit code is
                # untouched, so no build's pass/fail moves.
                $testOut = (uv run --no-project --with pytest --with hypothesis pytest -x -q --hypothesis-show-statistics 2>&1 | Out-String)
                $testResult = if ($LASTEXITCODE -eq 0) { 'pass' } elseif ($LASTEXITCODE -eq 5) { 'none' } else { 'fail' }
            } finally {
                Pop-Location
                if ($null -eq $prevPP) { Remove-Item Env:\PYTHONPATH -ErrorAction SilentlyContinue } else { $env:PYTHONPATH = $prevPP }
            }
            Write-Host ($testOut.Trim())
            # DoD row 4: PERSIST the statistics so a later stage can point at them. The capture
            # already exists in $testOut and was written only to the console, which is why
            # `-StatsPath` had nothing to reference and PropertyExecutionMeasured was false on
            # every production run ever made. Written INTO THE WORKTREE deliberately: the QA
            # stage runs in a different process after candidate selection and already holds
            # $wt, so this needs no cross-process plumbing and dies with the worktree.
            # Fail-soft -- a stats file that cannot be written must never sink a build.
            try { Set-Content -LiteralPath (Join-Path $wt '.blarai-hypothesis-stats.txt') -Value $testOut -Encoding utf8 } catch { }
        } else { Write-Host "[2/5] No test setup found - skipping." }
    }
    $testError = if ($testResult -eq 'fail') { "The test step failed:`n" + ((($testOut -split "`r?`n") | Where-Object { $_ } | Select-Object -Last 25) -join "`n") } else { '' }
    # ---- [3/5] Deterministic verify gate (build/typecheck/lint). Forgiving + offline: missing tools =
    # 'skip'; only a real non-zero (or a hang) = 'fail'. A 'fail' blocks the auto-merge. ----
    # #771: re-check before the verify step (a stop may have landed during the test run above).
    if (-not $cancelled -and [bool](@(& $ShouldCancel)[-1])) { $cancelled = $true }
    $verifyResult = 'none'; $verifyDetail = ''; $verifyError = ''
    if ($hasChanges -and -not $cancelled -and -not $gitFailed) {   # #1074: never grade a build we could not capture
        Write-Host "[3/5] Verifying (build/typecheck/lint)..." -ForegroundColor Cyan
        try {
            $__vpExtra = @{}
            if ($Surface) { $__vpExtra.Surface = $Surface }
            if ($LanguageHint) { $__vpExtra.LanguageHint = $LanguageHint }
            $vobj = & "$ScriptRoot\verify-project.ps1" -Path $wt -BaseBranch $BaseBranch -Json -TimeoutSec 600 @__vpExtra | ConvertFrom-Json
            $verifyResult = $vobj.overall
            $verifyDetail = (@($vobj.checks) | ForEach-Object { "  [$($_.status)] $($_.name)" }) -join "`n"
            $verifyError = Format-VerifyError -Checks $vobj.checks
            $vcolor = if ($verifyResult -eq 'fail') { 'Red' } elseif ($verifyResult -eq 'pass') { 'Green' } else { 'Yellow' }
            Write-Host "  verify: $verifyResult" -ForegroundColor $vcolor
            if ($verifyResult -eq 'fail') {
                foreach ($fc in @($vobj.checks | Where-Object { $_.status -eq 'fail' })) {
                    Write-Host "  --- verify output [$($fc.name)] ---" -ForegroundColor DarkGray
                    Write-Host $fc.detail
                }
            }
        } catch {
            $verifyResult = 'none'; $verifyDetail = "verify gate error: $($_.Exception.Message)"
            Write-Host "  verify gate could not run (treated as 'none'): $($_.Exception.Message)" -ForegroundColor Yellow
        }
    }
    if ($cancelled) { Write-Host "  STOP: a dispatch cancel was observed; this candidate parked its committed work without finishing the gate (#771)." -ForegroundColor Yellow }
    return @{
        VerifyResult = $verifyResult; TestResult = $testResult; HasChanges = [bool]$hasChanges;
        TimedOut = [bool]$run.TimedOut; SecretBlocked = [bool]$secretBlocked; LoopSuspected = [bool]$anomaly.LoopSuspected;
        Cancelled = [bool]$cancelled;
        NoChangeDeclared = [bool]$noChangeDeclared; NoChangeEvidence = "$noChangeEvidence";   # #1049 honest no-change outcome
        GitFailed = [bool]$gitFailed; GitError = "$gitError"; GitFaultReason = "$($capture.Reason)";   # #1074 fail-loud capture step
        SHA = $sha; Run = $run; Secret = $secret; Anomaly = $anomaly; BuildAttempts = $build.Attempts;
        TestError = $testError; VerifyDetail = $verifyDetail; VerifyError = $verifyError;
        AgentLog = $LogPath; LogPath = $LogPath   # AgentLog: the candidate shape; LogPath: the sequential ($BuildTestVerify) callers read this
    }
}

function ConvertTo-CandidateResult {
    # #695: re-normalise a concurrent candidate's result -- which crossed a Start-Job PROCESS boundary and
    # came back DESERIALISED (CliXml: hashtables -> Deserialized.* PSObjects) -- into a clean, plain hashtable
    # with explicit scalars + nested hashtables, tagged with the Worktree/Branch/Index the parent assigned.
    # This makes the downstream best-of-N selection + new-agent-task hydration read REAL hashtables (not
    # Deserialized.*), and turns a null/failed job into a fully-disqualified placeholder (a dead job can
    # never win, and never outranks a real attempt). Pure; unit-tested (verify-bestofn-concurrent.ps1).
    param(
        $Raw,
        [int]$Index = 0,
        [string]$Worktree = '',
        [string]$Branch = ''
    )
    if ($null -eq $Raw) {
        return @{
            Index = $Index; Worktree = $Worktree; Branch = $Branch
            VerifyResult = 'none'; TestResult = 'none'; HasChanges = $false; TimedOut = $false; SecretBlocked = $false; LoopSuspected = $false
            NoChangeDeclared = $false; NoChangeEvidence = ''
            GitFailed = $false; GitError = ''; GitFaultReason = ''   # #1074 (a dead job is not a capture fault; VerifyError already names it)
            SHA = ''; BuildAttempts = 0; TestError = ''; VerifyDetail = ''; VerifyError = 'concurrent candidate produced no result (job failed or empty)'; AgentLog = ''
            Run = @{ ExitCode = $null; TimedOut = $false; TimeoutReason = ''; Capped = $false; CappedReason = ''; Seconds = 0; Error = 'job produced no result' }
            Secret = @{ status = 'clean'; detail = '' }
            Anomaly = @{ Anomalies = @(); LoopSuspected = $false }
        }
    }
    $run = $Raw.Run; $secret = $Raw.Secret; $anomaly = $Raw.Anomaly
    return @{
        Index = $Index; Worktree = $Worktree; Branch = $Branch
        VerifyResult = "$($Raw.VerifyResult)"; TestResult = "$($Raw.TestResult)"; HasChanges = [bool]$Raw.HasChanges
        TimedOut = [bool]$Raw.TimedOut; SecretBlocked = [bool]$Raw.SecretBlocked; LoopSuspected = [bool]$Raw.LoopSuspected
        NoChangeDeclared = [bool]$Raw.NoChangeDeclared; NoChangeEvidence = "$($Raw.NoChangeEvidence)"   # #1049 (missing on a pre-#1049 raw -> $false/'')
        GitFailed = [bool]$Raw.GitFailed; GitError = "$($Raw.GitError)"; GitFaultReason = "$($Raw.GitFaultReason)"   # #1074: the capture fault MUST survive the Start-Job CliXml boundary, or the concurrent path silently re-opens the swallow
        SHA = "$($Raw.SHA)"; BuildAttempts = [int]$Raw.BuildAttempts
        TestError = "$($Raw.TestError)"; VerifyDetail = "$($Raw.VerifyDetail)"; VerifyError = "$($Raw.VerifyError)"; AgentLog = "$($Raw.AgentLog)"
        Run = @{
            ExitCode      = $(if ($null -ne $run) { $run.ExitCode } else { $null })
            TimedOut      = [bool]$(if ($null -ne $run) { $run.TimedOut } else { $false })
            TimeoutReason = "$(if ($null -ne $run) { $run.TimeoutReason })"
            Capped        = [bool]$(if ($null -ne $run) { $run.Capped } else { $false })
            CappedReason  = "$(if ($null -ne $run) { $run.CappedReason })"
            Seconds       = $(if ($null -ne $run) { $run.Seconds } else { 0 })
            Error         = "$(if ($null -ne $run) { $run.Error })"
        }
        Secret = @{
            status = "$(if ($null -ne $secret) { $secret.status } else { 'clean' })"
            detail = "$(if ($null -ne $secret) { $secret.detail })"
        }
        Anomaly = @{
            Anomalies     = @(if ($null -ne $anomaly) { $anomaly.Anomalies } else { @() })
            LoopSuspected = [bool]$(if ($null -ne $anomaly) { $anomaly.LoopSuspected } else { $false })
        }
    }
}

function Get-TimeoutStopText {
    # #740/W7 (no-op-diagnosis): turn a coder-run circuit-breaker stop into an HONEST one-line BUILD
    # status for the operator report. Invoke-AgentRun sets TimedOut for TWO distinct reasons
    # (Resolve-RunStopDecision): 'idle' = no new step/edit for IdleTimeoutSec -> genuinely stuck, killed
    # FAST (often in a few minutes, having made no changes); 'ceiling' = the generous absolute wall-clock
    # backstop ($MaxRunMinutes). The old report printed "STOPPED ... after <MaxRunMinutes> min" for BOTH,
    # so a ~4-min idle stall read as a 60-min wall-clock kill -- the exact mis-label that sent the M2 no-op
    # diagnosis chasing a phantom retry-budget bug. Pure + unit-tested (verify-runtimeout.ps1). An
    # unknown/empty reason falls back to the ceiling phrasing (back-compat with pre-#740 Run objects).
    param(
        [string]$Reason = '',
        [int]$MaxRunMinutes = 60,
        [int]$IdleTimeoutSec = 240
    )
    if ($Reason -eq 'idle') {
        return "STOPPED early: the coder went idle for ${IdleTimeoutSec}s (no new step or edit -- genuinely stuck), so it was stopped"
    }
    return "STOPPED at the ${MaxRunMinutes}-min hard ceiling (a generous absolute backstop)"
}

function Get-RunAnomalies {
    # Detective circuit breaker: scan an agent transcript for trouble signatures a
    # small model tends to produce - a circuit-breaker stop (idle stall or wall-clock
    # ceiling), the same line repeated many times (doom-loop), opencode's own doom-loop
    # flag, or a non-zero exit. Conservative thresholds keep false positives low.
    # LoopSuspected -> the fleet withholds auto-merge and parks the task for human review.
    # Returns: @{ Anomalies=[string[]]; LoopSuspected=[bool] }
    param(
        [Parameter(Mandatory)][string]$LogPath,
        [bool]$TimedOut = $false,
        $ExitCode = $null,
        [int]$LoopThreshold = 12,
        [string]$TimeoutReason = ''   # #740/W7: 'idle' | 'ceiling' | '' -> honest label below
    )
    $anoms = New-Object System.Collections.ArrayList
    $loop = $false
    # #740/W7: an idle stall and a wall-clock kill BOTH set TimedOut, but they are different failures --
    # calling an idle stall a "wall-clock timeout" misdiagnoses it (it misled the M2 plan's own no-op
    # hypothesis). LoopSuspected stays TRUE either way (unchanged merge-gate soft-signal); only the text
    # is made honest.
    if ($TimedOut) {
        $msg = if ($TimeoutReason -eq 'idle') { 'agent went idle (no new step or edit) and was stopped -- genuinely stuck' } else { 'agent hit the wall-clock timeout and was stopped' }
        [void]$anoms.Add($msg); $loop = $true
    }
    if (Test-Path $LogPath) {
        $lines = @(Get-Content $LogPath -ErrorAction SilentlyContinue)
        if ($lines.Count) {
            $groups = $lines | Where-Object { $_.Trim().Length -gt 12 } | Group-Object |
                      Where-Object { $_.Count -ge $LoopThreshold } | Sort-Object Count -Descending | Select-Object -First 3
            foreach ($g in $groups) {
                $snip = $g.Name.Trim()
                if ($snip.Length -gt 80) { $snip = $snip.Substring(0, 80) }
                [void]$anoms.Add(('a line repeated {0}x (possible doom-loop): {1}' -f $g.Count, $snip))
                $loop = $true
            }
            if ($lines | Where-Object { $_ -match 'doom.?loop' } | Select-Object -First 1) {
                [void]$anoms.Add('opencode flagged a doom loop'); $loop = $true
            }
        }
    }
    if (($null -ne $ExitCode) -and ($ExitCode -ne 0)) { [void]$anoms.Add("agent exited non-zero ($ExitCode)") }
    return @{ Anomalies = @($anoms); LoopSuspected = $loop }
}

# ============================================================================
# UC-010 VLM design-loop: the auto-FIX rebuild iteration (Phase 3)
# ============================================================================

function Add-VisualFeedback {
    # VISUAL-FEEDBACK: augment the coder's ORIGINAL prompt with the VLM's concrete design
    # critique so a built-and-merged-but-visually-rough app gets a FIX pass. Mirrors
    # Add-ReviewFeedback exactly (same delimited-section shape,
    # same "smallest change, do not start over" discipline). Returns the prompt UNCHANGED
    # when there is no feedback, so a no-op pass is a true no-op. Pure + unit-tested.
    param([string]$Prompt, [string]$Feedback)
    if ([string]::IsNullOrWhiteSpace($Feedback)) { return $Prompt }
    $Prompt + "`n`n--- Visual design feedback to address ---`n" +
        "A visual review of the running app flagged these design issues. Improve the app's " +
        "appearance to address them, keeping all existing behavior working:`n`n" +
        $Feedback +
        "`n`nMake focused changes to the EXISTING code to improve the visual design above. " +
        "Do NOT start over, delete working code, or break the build."
}

function Invoke-VisualFixPass {
    # ONE auto-FIX iteration of the VLM design loop, with every side-effecting MECHANISM
    # injected as a scriptblock so the POLICY (run coder -> re-verify -> commit -> re-merge,
    # with fail-soft aborts) is unit-testable WITHOUT a real coder / build / git. Mirrors the
    # Invoke-BuildWithRetry separation-of-policy-from-mechanism pattern.
    #
    # This runs AFTER the app's first successful merge, so it is FAIL-SOFT + NON-DESTRUCTIVE:
    # any failure (the coder no-op'd / errored, the re-verify FAILED, or the re-merge could not
    # cleanly apply) ABORTS this iteration and KEEPS the last good merged version. It NEVER
    # leaves the base branch broken or half-merged, and NEVER throws (a thrown mechanism is
    # caught and treated as an abort).
    #
    # Decision order (each gate fail-soft aborts, returning Applied=$false):
    #   1. RunCoder    -> run the coder on the FIX prompt. Result @{ TimedOut; ... }. A timeout
    #                     aborts (no partial work merged).
    #   2. CommitFix   -> stage + commit the coder's work on the agent branch. Returns $true iff
    #                     a NEW commit was actually created (no changes -> nothing to do -> abort,
    #                     but NOT a failure: the prior version is intact).
    #   3. Verify      -> re-run the build/verify gate. Returns 'pass'|'fail'|'none'. A 'fail'
    #                     ABORTS (never merge a broken rebuild over a working one). 'none'/'pass'
    #                     proceed (mirrors the merge gate: only a real 'fail' blocks).
    #   4. ReMerge     -> merge the agent branch into the base branch. Returns $true on a clean
    #                     merge/fast-forward (or a benign already-up-to-date), $false on conflict
    #                     or any merge error. A $false ABORTS fail-soft (the caller's ReMerge must
    #                     itself clean up a conflicted index, e.g. `git merge --abort`).
    #
    # Returns: @{ Applied=[bool]; Reason=[string]; Verify=[string] }
    #   Applied = $true ONLY when the coder changed something, it re-verified non-fail, AND the
    #   re-merge landed cleanly. Otherwise $false with a human-readable Reason.
    param(
        [Parameter(Mandatory)][scriptblock]$RunCoder,    # -> @{ TimedOut=[bool]; ExitCode; ... }
        [Parameter(Mandatory)][scriptblock]$CommitFix,   # -> [bool] (a new commit was created)
        [Parameter(Mandatory)][scriptblock]$Verify,      # -> 'pass'|'fail'|'none'
        [Parameter(Mandatory)][scriptblock]$ReMerge      # -> [bool] (clean merge landed)
    )
    try {
        # 1. Run the coder on the FIX prompt.
        $run = @(& $RunCoder)[-1]
        if ($run -isnot [hashtable]) { $run = @{ TimedOut = $false; ExitCode = $null } }
        # #1370: a BOUNDED coder is not an EMPTY one. This used to `return` here, discarding
        # whatever the coder had written before its clock ran out — without committing it,
        # without verifying it, without offering it to anything. MEASURED across two B9 runs
        # (2026-08-09/10): 35 fix cycles, 11 applied, 24 discarded, and every one of the 24
        # was this branch. Not one was rejected on merit. `create-home-page` lost 3 of 3 on
        # both runs, which is why #1367's placeholder front door survived a whole night of a
        # loop explicitly trying to fix it.
        #
        # Stages 2-4 below ARE the gate, and they already behave correctly: CommitFix reports
        # whether anything was actually written, Verify refuses to merge a broken rebuild over
        # a working one, and ReMerge fails soft on conflict. The 11 passes that reached them
        # landed cleanly. This early return protected none of that — it only prevented the
        # work from being looked at. The base-candidate path says it plainly: "work kept, the
        # gate decides the merge." This path now says the same.
        $boundedNote = if ($run.TimedOut) { ' (coder was time-bounded; judged on what it had written)' } else { '' }

        # 2. Commit the FIX; a no-op coder (no new commit) is a benign abort. A bounded coder
        # that wrote nothing lands here and is reported as such — which is the honest answer,
        # and one this function could not previously distinguish from "wrote something good".
        $committed = [bool](@(& $CommitFix)[-1])
        if (-not $committed) {
            return @{ Applied = $false; Reason = "the FIX pass produced no changes; kept the prior merged version$boundedNote"; Verify = '' }
        }

        # 3. Re-verify the build. Only a real 'fail' blocks (mirrors the merge gate).
        # NOTE: a distinct local name ($verifyResult) — PowerShell variable names are
        # case-INSENSITIVE, so a `$verify` here would alias the [scriptblock]-typed $Verify
        # parameter and a string assignment would trip the type-coercion guard.
        $verifyResult = "$(@(& $Verify)[-1])".Trim().ToLower()
        if ($verifyResult -eq 'fail') {
            return @{ Applied = $false; Reason = "the rebuilt app FAILED the verify gate; kept the prior merged version (not merged)$boundedNote"; Verify = $verifyResult }
        }

        # 4. Re-merge into the base branch. A conflict / error aborts fail-soft.
        $didMerge = [bool](@(& $ReMerge)[-1])
        if (-not $didMerge) {
            return @{ Applied = $false; Reason = "the FIX re-merge did not apply cleanly (conflict/error); kept the prior merged version$boundedNote"; Verify = $verifyResult }
        }

        return @{ Applied = $true; Reason = "FIX pass merged$boundedNote"; Verify = $verifyResult }
    } catch {
        # Any mechanism throwing is an abort, never a task failure.
        return @{ Applied = $false; Reason = "FIX pass aborted on an error (kept the prior merged version): $($_.Exception.Message)"; Verify = '' }
    }
}

function ConvertFrom-MutmutOutput {
    # Parse combined mutmut run + results output to extract mutation statistics.
    # DEFENSIVE: tries several output patterns from mutmut 2.x and 3.x, including
    # the progress bar "N/M", the labeled "Survived: N", "bad_survived: N", and
    # the "Killed N of M" forms. Returns zeros on no match so the caller's soft-
    # signal path always works (no 'fail' from a bad parse). Pure; unit-testable
    # without running mutmut.
    # Returns @{ Survived=[int]; Total=[int]; Sampled=[bool] }
    param([string]$Output = '', [bool]$TimedOut = $false)
    $survived = 0; $total = 0
    if ($Output) {
        # Survived count -- try labeled patterns in preference order
        if ($Output -match '(?i)\bSurvived:\s*(\d+)') {
            $survived = [int]$Matches[1]
        } elseif ($Output -match '(?i)bad_survived[:\s]+(\d+)') {
            $survived = [int]$Matches[1]
        } elseif ($Output -match '(?i)(\d+)\s+survived\s+of\s+(\d+)') {
            $survived = [int]$Matches[1]; $total = [int]$Matches[2]
        } elseif ($Output -match '(?i)(\d+)\s+survived') {
            $survived = [int]$Matches[1]
        }
        # Total count: from "Killed N of M" (provides total + killed in one pattern),
        # "Mutants run: N/M", or a bare "N/M" progress counter.
        if ($total -eq 0) {
            if ($Output -match '(?i)\bKilled[:\s]+(\d+)\s+of\s+(\d+)') {
                # e.g. "Killed: 8 of 10" -> total=10, survived=2 (if not already set)
                $total = [int]$Matches[2]
                if ($survived -eq 0) {
                    $k = [int]$Matches[1]
                    $survived = if ($total -gt $k) { $total - $k } else { 0 }
                }
            } elseif ($Output -match '(?i)Mutants\s+run:\s*(\d+)\s*/\s*(\d+)') {
                $total = [int]$Matches[2]
            } elseif ($Output -match '(?i)(\d+)\s*/\s*(\d+)') {
                $total = [int]$Matches[2]
            }
        }
        # Killed count (labeled only): derive survived when we have a total but not yet survived
        if ($survived -eq 0 -and $total -gt 0 -and $Output -match '(?i)\bKilled[:\s]+(\d+)(?!\s+of\s+\d)') {
            $k = [int]$Matches[1]
            $survived = if ($total -gt $k) { $total - $k } else { 0 }
        }
    }
    # #1393 item 1: TOTAL=0 WAS A SENTINEL DOING TWO JOBS -- "no total could be parsed" and
    # "mutmut ran and had zero mutants to test" produced the identical value, and the note
    # below could not tell them apart. $totalKnown is set by the SAME branches that assign a
    # total, so the fact and the number cannot drift; a caller reading only .Total is
    # unaffected. The two halves are still matched by separate passes, which is the deeper
    # shape this ticket names -- what changes here is that their DISAGREEMENT is now visible
    # to the renderer instead of collapsing into a zero.
    $totalKnown = ($total -gt 0) -or ($Output -match '(?i)\bKilled[:\s]+\d+\s+of\s+0\b') `
                  -or ($Output -match '(?i)Mutants\s+run:\s*\d+\s*/\s*0\b')
    return @{ Survived = $survived; Total = $total; Sampled = $TimedOut; TotalKnown = $totalKnown }
}

function Get-MutationSignalNote {
    # Build the human-readable detail string for the py:mutation gate check.
    # SOFT SIGNAL CONTRACT: this note is ALWAYS used with status='pass' or 'skip',
    # NEVER 'fail'. Surviving mutants are a test-coverage hint for the LLM reviewer,
    # not a merge block. Pure; unit-testable without running mutmut; ASCII-only.
    param([int]$Survived = 0, [int]$Total = 0, [bool]$TimedOut = $false, [bool]$TotalKnown = $false)
    $cap = if ($TimedOut) { ' (time-boxed, partial run)' } else { '' }
    if ($Total -eq 0) {
        # #1393: A KNOWN NUMERATOR MUST SURVIVE A MISSING DENOMINATOR. This branch tested
        # $Total first and returned "no mutants measured" while $Survived already held a real
        # count -- so "Survived: 3" (a genuine mutmut 2.x label that carries no total in the
        # same line) published as the one phrase that means the OPPOSITE of what was found.
        # Proved by execution, not by reading: ConvertFrom-MutmutOutput returns Survived=3
        # Total=0 on that input, because survivors and totals are matched by separate,
        # independent regex passes and nothing requires both to succeed.
        #
        # Same effect class as #1231/#1389/#1391 through a fourth mechanism: nothing here
        # shrinks a denominator, a real numerator is ORPHANED by a missing one and then
        # discarded. Three surviving mutants is exactly the weak-test evidence the reviewer
        # is meant to act on.
        if ($Survived -gt 0) {
            return "mutation: $Survived surviving mutant(s) found, but the run's total could not be parsed$cap -- weak tests; add property-based or edge-case tests (soft signal, NOT a merge block)"
        }
        if ($TotalKnown) {
            # #1393 item 1: mutmut RAN and had nothing to mutate. That is a measured zero and
            # must not borrow the words of an unparsed one.
            return "mutation: the run reported ZERO mutants to test$cap -- nothing to measure here (soft signal, not a merge block)"
        }
        return "mutation: no mutants measured$cap (soft signal, not a merge block)"
    }
    if ($Survived -eq 0) {
        return "mutation: all $Total tested mutants killed$cap -- strong test signal"
    }
    return "mutation: $Survived of $Total tested mutants survived$cap -- weak tests; add property-based or edge-case tests (soft signal, NOT a merge block)"
}
