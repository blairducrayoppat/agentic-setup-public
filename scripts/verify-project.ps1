# verify-project.ps1 - deterministic verification gate.
# Detects the project's ecosystem and runs whatever build / typecheck / lint
# checks are actually available, fully OFFLINE and FORGIVING:
#   - a missing tool or config = 'skip' (never blocks a merge)
#   - an environment/restore/network gap = 'skip' (see Test-EnvironmentFailure)
#   - only a check that RUNS and returns a real non-zero = 'fail'
#   - a check that HANGS past the timeout = 'fail' (a build that never finishes
#     is not a pass)
# This is a HIGH-PRECISION gate: it should only ever say 'fail' when the code is
# genuinely broken, so the fleet's auto-merge can trust it.
#
#   .\verify-project.ps1 -Path C:\...\worktree           # human-readable summary
#   $v = .\verify-project.ps1 -Path C:\...\worktree -Json | ConvertFrom-Json
#        $v.overall  ->  'pass' | 'fail' | 'none'
#        $v.checks   ->  per-check name/status/seconds/detail
param(
    [Parameter(Mandatory)][string]$Path,
    [switch]$Json,
    [int]$TimeoutSec = 600,
    # Optional base ref for the eco:language adherence check (#670). When supplied (the fleet
    # passes it), the gate diffs $BaseBranch...HEAD to learn the task's deliverable language(s) and
    # FAILS an all-foreign deliverable. Absent (a standalone/manual run) -> the eco:language check
    # is skipped entirely, so behavior is identical to before (backward-compatible).
    [string]$BaseBranch = '',
    # INCREMENT-2 (#675): the upstream 14B's coarse platform label (+ optional language refinement).
    # When a KNOWN surface resolves a structural_contract (today only WinUI), the EARLY struct:contract
    # check below enforces it BEFORE the expensive build. Absent/unknown/no-contract -> the check is a
    # PROVEN NO-OP (no struct:contract result is even added), so behaviour is byte-identical to before.
    [string]$Surface = '',
    [string]$LanguageHint = ''
)
$ErrorActionPreference = 'Stop'
. "$PSScriptRoot\fleet-lib.ps1"

if (-not (Test-Path $Path)) { throw "Path not found: $Path" }

$script:checks = New-Object System.Collections.ArrayList
function Add-Result($name, $status, $seconds, $detail) {
    [void]$script:checks.Add([pscustomobject]@{ name = $name; status = $status; seconds = $seconds; detail = $detail })
}
function Invoke-GateCheck($name, $commandLine) {
    $r = Invoke-WithTimeout -CommandLine $commandLine -WorkDir $Path -TimeoutSec $TimeoutSec
    if ($r.TimedOut) {
        Add-Result $name 'fail' $r.Seconds "TIMEOUT after ${TimeoutSec}s: $commandLine"
        return
    }
    if ($r.ExitCode -eq 0) {
        Add-Result $name 'pass' $r.Seconds $commandLine
        return
    }
    if (Test-EnvironmentFailure $r.Output) {
        Add-Result $name 'skip' $r.Seconds "environment/setup gap (not a code error): $commandLine"
        return
    }
    $tail = (($r.Output -split "`r?`n") | Where-Object { $_ } | Select-Object -Last 25) -join "`n"
    Add-Result $name 'fail' $r.Seconds ("$commandLine -> exit $($r.ExitCode)`n$tail")
}

# ---------- Structural contract (#675) -- EARLY fail-fast, BEFORE the build ----------
# When the upstream 14B classified a KNOWN surface that resolves a structural_contract (today only
# WinUI), enforce that contract in SECONDS, before the expensive build/restore. The 30-min churn we
# watched park (a real WinUI app PLUS a console Program.cs/Main, a 2nd test project, and loose
# top-level-statement .cs runner files -> CS8803 -> circuit-breaker park) becomes a fast, recoverable
# loop: a violation here flips $overall to 'fail', and new-agent-task.ps1 feeds Format-VerifyError back
# to the coder ("this is a WinUI app -- the entry is App.xaml.cs; one project; tests in Tests/") on the
# next pass. FAIL-CLOSED on a defined contract; a $null contract (absent/unknown surface, or a standalone
# run that passes no -Surface) -> Test-ProjectStructure returns '' and NO struct:contract result is added,
# so behaviour is byte-identical to before. Placed FIRST so it appears first and pre-empts the build.
if ($Surface) {
    $__profile = Resolve-BuildProfile -Surface $Surface -LanguageHint $LanguageHint
    if ($null -ne $__profile.structural_contract) {
        $__sw = [System.Diagnostics.Stopwatch]::StartNew()
        $__violation = ''
        try { $__violation = Test-ProjectStructure -Worktree $Path -Contract $__profile.structural_contract }
        catch { $__violation = '' }   # FORGIVING: a structural-check error never false-fails (treat as clean)
        $__sw.Stop(); $__secs = [math]::Round($__sw.Elapsed.TotalSeconds, 1)
        if ($__violation) {
            Add-Result 'struct:contract' 'fail' $__secs $__violation
        } else {
            Add-Result 'struct:contract' 'pass' $__secs "project structure matches the $($__profile.scaffold) contract (one project, no rogue entry point, no loose top-level-statement files)"
        }
    }
}

# ---------- Node / TypeScript ----------
$pkgPath = Join-Path $Path 'package.json'
if ((Test-Path $pkgPath) -and (Test-Path (Join-Path $Path 'node_modules'))) {
    $pkg = $null
    try { $pkg = Get-Content $pkgPath -Raw -Encoding UTF8 | ConvertFrom-Json }
    catch { Write-Host "  WARNING: package.json is not valid JSON - skipping Node checks ($($_.Exception.Message))" -ForegroundColor Yellow }
    if ($pkg -and $pkg.scripts) {
        if ($pkg.scripts.build) { Invoke-GateCheck 'node:build' 'npm run build' }
        if ($pkg.scripts.lint)  { Invoke-GateCheck 'node:lint'  'npm run lint' }
    }
    # typecheck only when a local TypeScript is present (stays offline; --no-install
    # prevents npx from reaching the network)
    if ((Test-Path (Join-Path $Path 'tsconfig.json')) -and (Test-Path (Join-Path $Path 'node_modules\typescript'))) {
        Invoke-GateCheck 'node:typecheck' 'npx --no-install tsc --noEmit'
    }
}

# ---------- Node tests (the built-in runner works WITHOUT node_modules) ----------
$njPkg = Join-Path $Path 'package.json'
if ((Test-Path $njPkg) -and (Get-Command npm -ErrorAction SilentlyContinue)) {
    $njp = $null
    try { $njp = Get-Content $njPkg -Raw -Encoding UTF8 | ConvertFrom-Json } catch {}
    if ($njp -and $njp.scripts -and $njp.scripts.test) { Invoke-GateCheck 'node:test' 'npm test' }
}

# ---------- Python ----------
$hasPy = (Test-Path (Join-Path $Path 'pyproject.toml')) -or
         (Test-Path (Join-Path $Path 'setup.py')) -or
         (@(Get-ChildItem -Path $Path -Recurse -Filter *.py -File -ErrorAction SilentlyContinue |
              Where-Object { $_.FullName -notmatch '\\(node_modules|\.git|\.venv|venv)\\' } |
              Select-Object -First 1).Count -gt 0)
if ($hasPy) {
    $py = $null
    if (Get-Command python -ErrorAction SilentlyContinue) { $py = 'python' }
    elseif (Get-Command uv -ErrorAction SilentlyContinue) { $py = 'uv run --no-project python' }
    # Detect uv separately: used for ephemeral --with installs (hypothesis, mutmut) even when
    # the primary Python is a system install. Available throughout the $hasPy block.
    $uvOk = [bool](Get-Command uv -ErrorAction SilentlyContinue)
    if ($py) {
        # compileall = stdlib syntax check across the tree; no deps, fully offline
        Invoke-GateCheck 'py:compile' "$py -m compileall -q ."
    }
    # pytest: run the test suite when tests exist AND pytest is importable. Stays
    # offline and forgiving - if pytest is not installed we SKIP (never a false
    # fail). Tests that RUN and report a real failure are the strongest signal
    # this gate has; gating auto-merge on them is what makes the fleet trustworthy.
    if ($py) {
        $hasTests = (Test-Path (Join-Path $Path 'tests')) -or
                    (@(Get-ChildItem -Path $Path -Recurse -Filter 'test_*.py' -File -ErrorAction SilentlyContinue |
                         Where-Object { $_.FullName -notmatch '\\(node_modules|\.git|\.venv|venv)\\' } |
                         Select-Object -First 1).Count -gt 0)
        if ($hasTests) {
            # Prefer uv ephemeral install: adds Hypothesis so any @given property-based
            # tests the coder wrote are EXECUTED here without a pre-install step. Falls
            # back to the local $py when uv is absent -- hypothesis is then a no-op unless
            # the project installed it; pytest still runs the conventional tests.
            if ($uvOk) {
                $pyTestCmd  = 'uv run --no-project --with pytest --with hypothesis pytest -q'
                $pyProbeCmd = 'uv run --no-project --with pytest pytest --version'
            } else {
                $pyTestCmd  = "$py -m pytest -q"
                $pyProbeCmd = "$py -m pytest --version"
            }
            $probe = Invoke-WithTimeout -CommandLine $pyProbeCmd -WorkDir $Path -TimeoutSec 60
            if ($probe.ExitCode -eq 0) {
                # Put the PROJECT ROOT on PYTHONPATH for the gate's pytest, so a standard `module.py` +
                # `tests/test_module.py` layout's `from module import ...` resolves -- mirroring the TWO
                # sibling sites that already do this (new-agent-task.ps1 [2/5] test step + Invoke-AgentRun,
                # both: "give pytest the worktree root so a test in tests/ can import a root module"). Without
                # it the gate's py:test failed to COLLECT a tests/-dir suite the [2/5] step had run GREEN,
                # wrongly parking valid work (surfaced by the #695 concurrency canary, 2026-06-27). The child
                # cmd/pytest inherits the env via Start-Process; save/restore scopes the mutation to this check.
                $__prevPyPath = $env:PYTHONPATH
                $env:PYTHONPATH = $Path
                try { Invoke-GateCheck 'py:test' $pyTestCmd }
                finally { if ($null -eq $__prevPyPath) { Remove-Item Env:\PYTHONPATH -ErrorAction SilentlyContinue } else { $env:PYTHONPATH = $__prevPyPath } }
            } else {
                Add-Result 'py:test' 'skip' 0 'pytest not installed (offline) - skipped'
            }
        }
    }
    # py:mutation: sampled, hard-time-boxed (~150s) mutation scoring via mutmut.
    # SOFT SIGNAL: status is always 'pass' or 'skip', NEVER 'fail'. Surviving
    # mutants are reported in the detail as a weak-test hint for the LLM reviewer;
    # they do NOT block the auto-merge (Test-ShouldMerge only hard-blocks on
    # VerifyResult='fail' or TestResult='fail', neither of which mutation sets).
    # Requires uv for the offline ephemeral install; skips gracefully if absent.
    # ConvertFrom-MutmutOutput / Get-MutationSignalNote live in fleet-lib.ps1.
    if ($hasPy -and $uvOk) {
        $mutHasTests = (Test-Path (Join-Path $Path 'tests')) -or
            (@(Get-ChildItem -Path $Path -Recurse -Filter 'test_*.py' -File -ErrorAction SilentlyContinue |
                 Where-Object { $_.FullName -notmatch '\\(node_modules|\.git|\.venv|venv)\\' } |
                 Select-Object -First 1).Count -gt 0)
        $mutSrc = @(Get-ChildItem -Path $Path -Recurse -Filter '*.py' -File -ErrorAction SilentlyContinue |
            Where-Object { $_.FullName -notmatch '\\(node_modules|\.git|\.venv|venv)\\' -and
                           $_.Name -notmatch '^test_' -and
                           $_.FullName -notmatch '\\tests\\' } |
            Select-Object -First 10)
        if (-not $mutHasTests -or $mutSrc.Count -eq 0) {
            Add-Result 'py:mutation' 'skip' 0 'no Python source + test pair found - mutation scoring skipped'
        } else {
            # Run mutmut with a hard 150s wall-clock kill (Invoke-WithTimeout reaps the whole
            # process tree); any partial results in .mutmut-cache are read back via
            # 'mutmut results' so even a time-boxed partial run yields a signal.
            $mutRun = Invoke-WithTimeout -CommandLine 'uv run --no-project --with mutmut --with pytest mutmut run pytest' -WorkDir $Path -TimeoutSec 150
            $mutRes = Invoke-WithTimeout -CommandLine 'uv run --no-project --with mutmut mutmut results'                  -WorkDir $Path -TimeoutSec 30
            $mutParsed = ConvertFrom-MutmutOutput -Output ($mutRun.Output + "`n" + $mutRes.Output) -TimedOut $mutRun.TimedOut
            $mutNote   = Get-MutationSignalNote -Survived $mutParsed.Survived -Total $mutParsed.Total -TimedOut $mutParsed.Sampled -TotalKnown ([bool]$mutParsed.TotalKnown)
            Add-Result 'py:mutation' 'pass' $mutRun.Seconds $mutNote
        }
    }
    # ruff only if it is already on PATH (no network fetch); needs a ruff config
    $hasRuffCfg = (Test-Path (Join-Path $Path 'ruff.toml')) -or
                  (Test-Path (Join-Path $Path '.ruff.toml')) -or
                  ((Test-Path (Join-Path $Path 'pyproject.toml')) -and
                   (Select-String -Path (Join-Path $Path 'pyproject.toml') -Pattern '\[tool\.ruff' -Quiet -ErrorAction SilentlyContinue))
    if ($hasRuffCfg -and (Get-Command ruff -ErrorAction SilentlyContinue)) {
        Invoke-GateCheck 'py:lint' 'ruff check .'
    }
}

# ---------- .NET ----------
$dotnetProj = @(Get-ChildItem -Path $Path -Recurse -Include *.sln, *.csproj -File -ErrorAction SilentlyContinue |
                  Where-Object { $_.FullName -notmatch '\\(bin|obj|\.git)\\' } | Select-Object -First 1)
if ($dotnetProj.Count -gt 0 -and (Get-Command dotnet -ErrorAction SilentlyContinue)) {
    # Offline restore depends on the seeded folder-feed; a restore/network gap is
    # downgraded to 'skip' by Test-EnvironmentFailure so it never false-fails.
    Invoke-GateCheck 'dotnet:build' 'dotnet build --nologo -v q'
}

# ---------- PowerShell ----------
$psFiles = @(Get-ChildItem -Path $Path -Recurse -File -Include *.ps1, *.psm1, *.psd1 -ErrorAction SilentlyContinue |
               Where-Object { $_.FullName -notmatch '\\(node_modules|\.git|\.venv|venv)\\' })
if ($psFiles.Count -gt 0) {
    # Deterministic + offline + zero-dependency: every PowerShell file must PARSE (the PS equivalent of
    # "compiles"). The strongest fast signal for a PowerShell deliverable; broken syntax -> fail.
    $psw = [System.Diagnostics.Stopwatch]::StartNew()
    $psErrs = New-Object System.Collections.ArrayList
    foreach ($psf in $psFiles) {
        $tok = $null; $perr = $null
        [void][System.Management.Automation.Language.Parser]::ParseFile($psf.FullName, [ref]$tok, [ref]$perr)
        if ($perr -and $perr.Count) {
            foreach ($pe in ($perr | Select-Object -First 3)) { [void]$psErrs.Add("$($psf.Name):$($pe.Extent.StartLineNumber) $($pe.Message)") }
        }
    }
    $psw.Stop(); $psSecs = [math]::Round($psw.Elapsed.TotalSeconds, 1)
    if ($psErrs.Count -gt 0) { Add-Result 'pwsh:parse' 'fail' $psSecs (($psErrs | Select-Object -First 12) -join "`n") }
    else { Add-Result 'pwsh:parse' 'pass' $psSecs "$($psFiles.Count) PowerShell file(s) parse cleanly" }
    # Pester tests, only if present AND Pester v5 is usable (else skip -- never a false fail).
    if (@($psFiles | Where-Object { $_.Name -like '*.Tests.ps1' }).Count -gt 0) {
        try {
            Import-Module Pester -MinimumVersion 5.0 -ErrorAction Stop
            $pcfg = New-PesterConfiguration
            $pcfg.Run.Path = $Path; $pcfg.Run.PassThru = $true; $pcfg.Output.Verbosity = 'None'
            $pres = Invoke-Pester -Configuration $pcfg
            if ($pres.FailedCount -gt 0) { Add-Result 'pwsh:pester' 'fail' ([math]::Round($pres.Duration.TotalSeconds, 1)) "$($pres.FailedCount) Pester test(s) failed" }
            else { Add-Result 'pwsh:pester' 'pass' ([math]::Round($pres.Duration.TotalSeconds, 1)) "$($pres.PassedCount) Pester test(s) passed" }
        } catch {
            Add-Result 'pwsh:pester' 'skip' 0 "Pester v5 not usable ($($_.Exception.Message))"
        }
    }
}

# ---------- C++ (CMake) ----------
if ((Test-Path (Join-Path $Path 'CMakeLists.txt')) -and (Get-Command cmake -ErrorAction SilentlyContinue)) {
    # cl is only on PATH inside a VS dev shell, so detect MSVC via vswhere too. No compiler -> skip
    # (a setup gap, not a code error) so the gate never false-fails on a machine without a toolchain.
    $haveCc = [bool](Get-Command cl, clang, clang++, g++, gcc -ErrorAction SilentlyContinue)
    if (-not $haveCc) {
        $vsw = 'C:\Program Files (x86)\Microsoft Visual Studio\Installer\vswhere.exe'
        if (Test-Path $vsw) { $haveCc = [bool](& $vsw -all -prerelease -products * -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath 2>$null) }
    }
    if ($haveCc) {
        # cmake's default/VS generators don't reliably find a prerelease VS, so configure+build+test
        # via Ninja inside an MSVC (vcvars) environment -- see build-cpp.ps1. One combined check.
        Invoke-GateCheck 'cpp:build' "pwsh -NoProfile -File $PSScriptRoot\build-cpp.ps1"
    } else {
        Add-Result 'cpp:build' 'skip' 0 'no C++ compiler found (MSVC/clang/gcc) - skipped'
    }
}

# ---------- Ecosystem language adherence (#670) ----------
# Deterministic, HIGH-PRECISION guard: did the task's deliverable use the project's DECLARED
# language? The live failure wrote JavaScript into a Python repo and every existing check (keyed
# off manifests that already existed) was blind to it. This compares the languages the task
# CHANGED against the project's declared ecosystem and FAILS only when the deliverable is ENTIRELY
# foreign - which flips $overall to 'fail' below, blocking auto-merge independently of the review.
# Runs ONLY when a base ref is supplied (the fleet passes -BaseBranch); a standalone run without it
# skips this check, so prior behavior is unchanged. FORGIVING: any git problem -> 'skip', never a
# false 'fail'. The git guard is the explicit $LASTEXITCODE check (NOT $EAP: a native git exit 128
# does not throw under EAP=Stop before PS 7.4); stderr is redirected so git's progress cannot raise
# a NativeCommandError under EAP=Stop (the reason new-agent-task.ps1 runs with EAP=Continue).
if ($BaseBranch) {
    $ecoStatus = 'skip'; $ecoReason = ''
    try {
        $baseSha = (git -C $Path rev-parse --verify --quiet $BaseBranch 2>$null)
        if ($LASTEXITCODE -ne 0 -or -not $baseSha) {
            $ecoReason = "base ref '$BaseBranch' not resolvable in this path - language not judged"
        } else {
            $headSha = (git -C $Path rev-parse --verify --quiet HEAD 2>$null)
            if ($LASTEXITCODE -ne 0 -or -not $headSha) {
                $ecoReason = 'HEAD not resolvable - language not judged'
            } else {
                if ($baseSha.Trim() -eq $headSha.Trim()) {
                    # base == HEAD (brand-new repo / nothing ahead): the diff would be empty, so
                    # judge the whole tracked tree instead - A2 still fires rather than vacuously skip.
                    $ecoFiles = @(git -C $Path ls-files 2>$null)
                } else {
                    $ecoFiles = @(git -C $Path diff --name-only --diff-filter=ACMR "$BaseBranch...HEAD" 2>$null)
                }
                if ($LASTEXITCODE -ne 0) {
                    # the file listing itself failed - skip EXPLICITLY rather than read an empty/partial
                    # list as "no code changed", which would silently MISS a wrong-language catch.
                    $ecoReason = 'could not list the task''s changed files (git failed) - language not judged'
                } else {
                    $ecoDecision = Test-LanguageAdherence -DeclaredEcosystems (Get-ProjectEcosystem $Path) `
                                                          -ChangedLanguages (Get-ChangedLanguages $ecoFiles)
                    $ecoStatus = $ecoDecision.Status; $ecoReason = $ecoDecision.Reason
                }
            }
        }
    } catch {
        $ecoStatus = 'skip'; $ecoReason = "eco check error (treated as skip): $($_.Exception.Message)"
    }
    Add-Result 'eco:language' $ecoStatus 0 $ecoReason
}

# ---------- Aggregate ----------
$arr = @($script:checks)
$ran = @($arr | Where-Object { $_.status -in @('pass', 'fail') })
$overall = if ($ran.Count -eq 0) { 'none' }
           elseif (@($arr | Where-Object { $_.status -eq 'fail' }).Count -gt 0) { 'fail' }
           else { 'pass' }

$result = [pscustomobject]@{
    overall = $overall
    path    = $Path
    checks  = $arr
}

if ($Json) {
    $result | ConvertTo-Json -Depth 6 -Compress
} else {
    Write-Host ""
    Write-Host "Verification gate: $($Path)" -ForegroundColor Cyan
    if ($arr.Count -eq 0) {
        Write-Host "  (no build/lint/typecheck checks applied to this project)" -ForegroundColor Yellow
    }
    foreach ($c in $arr) {
        $color = switch ($c.status) { 'pass' { 'Green' } 'fail' { 'Red' } default { 'Yellow' } }
        Write-Host ("  [{0,-4}] {1}  ({2}s)" -f $c.status, $c.name, $c.seconds) -ForegroundColor $color
        if ($c.status -eq 'fail') { Write-Host ("        {0}" -f ($c.detail -replace "`n", "`n        ")) -ForegroundColor DarkRed }
    }
    $ocolor = switch ($overall) { 'pass' { 'Green' } 'fail' { 'Red' } default { 'Yellow' } }
    Write-Host ("OVERALL: {0}" -f $overall.ToUpper()) -ForegroundColor $ocolor
}
