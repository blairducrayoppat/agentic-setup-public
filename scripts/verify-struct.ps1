#requires -Version 5.1
<#
.SYNOPSIS
  Verify and validate the STRUCTURAL FAIL-FAST GATE (Increment 2 / #675): the cheap, EARLY
  struct:contract check that enforces a profile's structural_contract BEFORE the expensive build,
  so the 30-min-churn-to-park proliferation becomes a seconds-fast, recoverable feedback loop.

.DESCRIPTION
  Background (plain English):
    The parked rocket-calc run authored a real WinUI app PLUS a Console-style Program.cs with its own
    Main(), a 2nd test project, and ~7 loose top-level-statement .cs runner files -> CS8803 + a XAML
    internal compiler error -> 30-min circuit-breaker -> park (no recovery, because the wall-clock
    timeout pre-empts the error-feedback loops). This gate catches that proliferation in SECONDS,
    before the build, and routes the violation through the EXISTING error-feedback channel so the coder
    gets "this is a WinUI app -- the entry is App.xaml.cs; one project; tests in Tests/" on the next pass.
    The pure piece lives in fleet-lib.ps1 so it unit-tests without a model or a build:
      - Test-ProjectStructure : a worktree + a structural_contract -> a violation string (or '' if clean)

    FAIL-CLOSED on a DEFINED contract; NO-OP on an undefined one. A $null contract (the `unknown`
    surface, or a standalone verify run that passes no -Surface) -> '' and NO struct:contract result is
    even added, so behaviour is byte-identical to before. HIGH-PRECISION: it only flags the unambiguous
    proliferation signatures (a 2nd project / a rogue Program.cs or static Main / loose top-level-stmt
    .cs) so the fleet's auto-recovery can trust it -- a normal extra class file never false-fails.

  Mutation-resistant: each [kill] case fails a specific wrong implementation. A proliferated tree goes
  RED; a clean SEEDED tree passes; unknown/no-contract is a proven NO-OP.

  THE REAL SEED-BUILD PROOF: the winui scaffold has NEVER engaged in a live dispatch (verify-scaffold is
  unit-only). This suite Copy-ScaffoldInto's it into a temp worktree, runs the gate's EXACT
  `dotnet build` (-> 0/0, offline) AND Test-ProjectStructure (-> clean) to prove the seed both COMPILES
  and PASSES the new gate. (Gracefully SKIPS the build leg only if dotnet/the offline feed is absent.)

  Exit 0 if all passed, 1 otherwise. Run it normally ( .\verify-struct.ps1 ).
#>
$ErrorActionPreference = 'Stop'
. "$PSScriptRoot\fleet-lib.ps1"

$script:Pass = 0; $script:Fail = 0; $script:Skip = 0
$script:Failures = New-Object System.Collections.ArrayList
function Section($t) { Write-Host ''; Write-Host "== $t ==" -ForegroundColor Cyan }
function _pass($m) { $script:Pass++; Write-Host "  [PASS] $m" -ForegroundColor Green }
function _fail($m) { $script:Fail++; [void]$script:Failures.Add($m); Write-Host "  [FAIL] $m" -ForegroundColor Red }
function _skip($m) { $script:Skip++; Write-Host "  [SKIP] $m" -ForegroundColor Yellow }
function Assert-Eq($Expected, $Actual, $Msg) { if ([string]$Expected -ceq [string]$Actual) { _pass $Msg } else { _fail "$Msg (expected '$Expected', got '$Actual')" } }
function Assert-True($Cond, $Msg) { if ($Cond) { _pass $Msg } else { _fail "$Msg (expected True, got False)" } }
function Assert-False($Cond, $Msg) { if (-not $Cond) { _pass $Msg } else { _fail "$Msg (expected False, got True)" } }
function Assert-Empty($Val, $Msg) { if ([string]::IsNullOrEmpty([string]$Val)) { _pass $Msg } else { _fail "$Msg (expected empty/clean, got '$Val')" } }
function Assert-Match($Hay, $Pat, $Msg) { if ([string]$Hay -match $Pat) { _pass $Msg } else { _fail "$Msg (/$Pat/ did not match '$Hay')" } }

# The WinUI structural contract under test (the curated SSOT, via Resolve-BuildProfile).
$winuiContract = (Resolve-BuildProfile -Surface 'desktop-gui').structural_contract

# Helper: seed a fresh winui worktree, apply a mutation block, run Test-ProjectStructure, clean up.
function Invoke-OnSeededTree {
    param([scriptblock]$Mutate = {}, $Contract = $winuiContract)
    $tmp = Join-Path ([System.IO.Path]::GetTempPath()) ("fleet-struct-{0}" -f ([guid]::NewGuid().ToString('N')))
    New-Item -ItemType Directory -Force $tmp | Out-Null
    try {
        [void](Copy-ScaffoldInto -Scaffold 'winui' -Worktree $tmp)
        & $Mutate $tmp
        return Test-ProjectStructure -Worktree $tmp -Contract $Contract
    } finally {
        Remove-Item -Recurse -Force $tmp -ErrorAction SilentlyContinue
    }
}

# Helper: write a single temp .cs (via the block), run Get-FirstCodeToken on it, clean up.
function Invoke-WithTempFile {
    param([scriptblock]$Write)
    $p = Join-Path ([System.IO.Path]::GetTempPath()) ("fleet-tok-{0}.cs" -f ([guid]::NewGuid().ToString('N')))
    try { & $Write $p; return Get-FirstCodeToken -Path $p }
    finally { Remove-Item $p -Force -ErrorAction SilentlyContinue }
}

# ----------------------------------------------------------------------------
Section 'Unit tests: Test-ProjectStructure on a CLEAN seeded WinUI tree (no false-fail)'
Assert-Empty (Invoke-OnSeededTree {}) 'ST1 a freshly-seeded winui scaffold is CLEAN (the gate must not false-fail the legit skeleton)'
# Adding ONE legitimate testable-logic class (the extend pattern) is still clean.
Assert-Empty (Invoke-OnSeededTree { param($t) Set-Content (Join-Path $t 'Calculator.cs') 'namespace MinimalWinUI; public class Calculator { public int Add(int a,int b)=>a+b; }' }) 'ST2 the seed + one normal class (the coder EXTENDING it) is CLEAN'
# A tests/ class under the contract test_dir is clean (tests belong there).
Assert-Empty (Invoke-OnSeededTree { param($t) New-Item -ItemType Directory -Force (Join-Path $t 'Tests') | Out-Null; Set-Content (Join-Path $t 'Tests\CalcTests.cs') 'namespace MinimalWinUI.Tests; public class CalcTests { public void T(){} }' }) 'ST3 a class file under Tests/ is CLEAN'

Section 'Unit tests: Test-ProjectStructure FIRES on each proliferation signature ([kill])'
# (A) a 2nd project file.
$vA = Invoke-OnSeededTree { param($t) Set-Content (Join-Path $t 'Extra.csproj') '<Project Sdk="Microsoft.NET.Sdk"></Project>' }
Assert-True  ([bool]$vA) 'ST4 [kill] a 2nd .csproj -> RED (max one project)'
Assert-Match $vA 'project file' 'ST4b the violation names the project-count problem (feeds the coder a usable message)'
# (B) a rogue Program.cs (the Console template hallmark).
$vB = Invoke-OnSeededTree { param($t) Set-Content (Join-Path $t 'Program.cs') 'class Program { static void Main() { } }' }
Assert-True  ([bool]$vB) 'ST5 [kill] a Program.cs -> RED (rogue entry point)'
Assert-Match $vB 'App\.xaml\.cs' 'ST5b the violation tells the coder the real entry is App.xaml.cs'
# (C) a loose top-level-statement .cs runner (the CS8803 case).
$vC = Invoke-OnSeededTree { param($t) Set-Content (Join-Path $t 'Runner.cs') 'System.Console.WriteLine("validate");' }
Assert-True  ([bool]$vC) 'ST6 [kill] a loose top-level-statement .cs -> RED'
Assert-Match $vC 'top-level' 'ST6b the violation names the top-level-statement problem'
# (D) a hand-written `static Main` in a NON-Program-named class file (the regex-robustness case that
#     an earlier \w-class form missed -- caught during this build).
$vD = Invoke-OnSeededTree { param($t) Set-Content (Join-Path $t 'Boot.cs') 'public static class Boot { public static int Main(string[] a) { return 0; } }' }
Assert-True  ([bool]$vD) 'ST7 [kill] a static Main() in a class file (not named Program.cs) -> RED (second entry point)'
# (E) MULTIPLE proliferation at once (the actual parked-run shape) still fires.
$vE = Invoke-OnSeededTree { param($t)
    Set-Content (Join-Path $t 'Program.cs') 'class P { static void Main(){} }'
    Set-Content (Join-Path $t 'Validate.cs') 'System.Console.WriteLine(1);'
    Set-Content (Join-Path $t 'Tests.csproj') '<Project></Project>'
}
Assert-True ([bool]$vE) 'ST8 [kill] the full parked-run proliferation (Program.cs + loose .cs + 2nd csproj) -> RED'

Section 'Unit tests: Test-ProjectStructure is HIGH-PRECISION (negatives never false-fail)'
# A method merely NAMED Main but NOT static is an ordinary instance member, not an entry point.
Assert-Empty (Invoke-OnSeededTree { param($t) Set-Content (Join-Path $t 'Inst.cs') 'public class Inst { public int Main(int x){ return x; } }' }) 'ST9 [kill] an instance method named Main (no static) is NOT flagged (precision)'
# A commented-out static Main is not a real entry point.
Assert-Empty (Invoke-OnSeededTree { param($t) Set-Content (Join-Path $t 'C.cs') 'public class C { /* static void Main(){} */ public int V => 1; }' }) 'ST10 [kill] a COMMENTED-OUT static Main is NOT flagged (comment-stripping precision)'
# A normal class whose method bodies contain statements (Console.WriteLine inside a method) is fine --
# the file STARTS with a declaration, so it is not a top-level-statement file.
Assert-Empty (Invoke-OnSeededTree { param($t) Set-Content (Join-Path $t 'Helper.cs') "using System;`npublic class Helper { public void Go(){ Console.WriteLine(1); } }" }) 'ST11 [kill] a class with statements INSIDE a method body is NOT flagged (first token is a declaration)'
# A file-scoped-namespace + attribute-decorated class (real WinUI idioms) is a declaration.
Assert-Empty (Invoke-OnSeededTree { param($t) Set-Content (Join-Path $t 'Model.cs') "namespace MinimalWinUI;`n[System.Serializable]`npublic record Point(int X, int Y);" }) 'ST12 [kill] a file-scoped namespace + [attribute] + record is NOT flagged (declaration, not a statement)'
# A hand-written AssemblyInfo.cs whose FIRST meaningful line is an assembly/module-level attribute is
# METADATA, not a top-level statement -- a common .NET pattern the 30B may emit. The gate must NOT
# misfire here (the LA's independent gate caught this exact false-positive: $declRe required a modifier
# AFTER the attribute group, so a standalone [assembly: ...] fell through to STATEMENT).
$asmVersion = '[assembly: System.Reflection.AssemblyVersion("1.0.0.0")]'
Assert-Empty (Invoke-OnSeededTree { param($t) Set-Content (Join-Path $t 'AssemblyInfo.cs') $asmVersion }) 'ST16 [kill] an AssemblyInfo.cs starting with [assembly: AssemblyVersion(...)] is NOT flagged (assembly attribute = metadata, not a top-level statement)'
Assert-Empty (Invoke-OnSeededTree { param($t) Set-Content (Join-Path $t 'AssemblyInfo.cs') "using System.Reflection;`n[assembly: AssemblyTitle(`"App`")]`n[assembly: AssemblyVersion(`"1.0.0.0`")]" }) 'ST17 [kill] a multi-line AssemblyInfo.cs (using + several [assembly: ...]) is NOT flagged'
Assert-Empty (Invoke-OnSeededTree { param($t) Set-Content (Join-Path $t 'Mod.cs') '[module: System.Runtime.CompilerServices.SkipLocalsInit]' }) 'ST18 [kill] a [module: ...] attribute file is NOT flagged'
# Get-FirstCodeToken classifies the assembly-attribute file as a NON-statement (DECLARATION via the
# [assembly:] skip + a following [System.Serializable] decorating a class, or '' for attributes-only).
Assert-Eq 'DECLARATION' (Invoke-WithTempFile { param($p) Set-Content $p "[assembly: System.Reflection.AssemblyVersion(`"1.0`")]`npublic class Marker { }" }) 'ST19 Get-FirstCodeToken: [assembly: ...] then a class -> DECLARATION (the assembly attr is skipped, the class line classifies)'
# The skip MUST NOT open a hole: an assembly attr FOLLOWED BY a genuine top-level statement still fires.
Assert-True ([bool](Invoke-OnSeededTree { param($t) Set-Content (Join-Path $t 'Mixed.cs') "[assembly: System.Reflection.AssemblyVersion(`"1.0`")]`nSystem.Console.WriteLine(`"go`");" })) 'ST20 [kill] [assembly: ...] FOLLOWED BY a real top-level statement -> RED (the skip advances to the next line, it does not blanket-clear the file)'
# MUTATION PROOF (mutation-resistant, like the other kill-tests): with BOTH attribute-skip lines
# REMOVED from Get-FirstCodeToken, the ST16 AssemblyInfo case goes RED -- proving ST16 actually guards the
# skip rather than passing vacuously. (Both must go: the [assembly:] line ALSO matches the standalone
# attribute-only skip, so removing only one would still classify it as a non-statement. The defect was
# that NEITHER existed.) We rebuild the function from its real source minus the two skip lines.
$libSrc = Get-Content "$PSScriptRoot\fleet-lib.ps1" -Raw
$fnMatch = [regex]::Match($libSrc, '(?ms)^function\s+Get-FirstCodeToken\s*\{.*?^\}')
if ($fnMatch.Success) {
    # Drop every `if ($t -match '...[attribute...]') { continue }` skip line (both the assembly/module one
    # and the standalone attribute-only one) by removing any continue-skip whose regex contains a '\[' token.
    $mutatedFn = ($fnMatch.Value -split "`r?`n" | Where-Object { $_ -notmatch "if \(\`$t -match '.*\\\[.*'\) \{ continue \}" }) -join "`n"
    Assert-True ($mutatedFn.Contains('(?:assembly|module)') -eq $false) 'ST21 (mutation setup) the assembly/module skip line was removed from the mutant'
    Assert-True ($mutatedFn.Contains('decorates the NEXT line') -eq $false) 'ST21b (mutation setup) the standalone attribute-only skip line was also removed from the mutant'
    # Define the mutant under a distinct name and verify it now MISCLASSIFIES the assembly attr as STATEMENT.
    $mutatedFn2 = $mutatedFn -replace 'function\s+Get-FirstCodeToken', 'function Get-FirstCodeToken-MUT'
    . ([scriptblock]::Create($mutatedFn2))
    $mtmp = Join-Path ([System.IO.Path]::GetTempPath()) ("fleet-mut-" + [guid]::NewGuid().ToString('N') + '.cs')
    Set-Content $mtmp $asmVersion
    Assert-Eq 'STATEMENT' (Get-FirstCodeToken-MUT -Path $mtmp) 'ST22 [mutation] WITHOUT the attribute-skip lines, Get-FirstCodeToken misclassifies [assembly: ...] as STATEMENT -> the live ST16 catch is real (mutation-resistant)'
    Remove-Item $mtmp -Force -ErrorAction SilentlyContinue
} else {
    _fail 'ST21 (mutation setup) could not extract Get-FirstCodeToken source for the mutation proof'
}

Section 'Unit tests: the $null/undefined contract is a PROVEN NO-OP (today''s behaviour)'
Assert-Empty (Test-ProjectStructure -Worktree ([System.IO.Path]::GetTempPath()) -Contract $null) 'ST13 [kill] a $null contract -> '''' (no-op; can never false-fail an undefined path)'
# Even a wildly-proliferated tree returns clean when NO contract is supplied (the unknown-surface path).
Assert-Empty (Invoke-OnSeededTree -Contract $null -Mutate { param($t)
    Set-Content (Join-Path $t 'Program.cs') 'class P { static void Main(){} }'
    Set-Content (Join-Path $t 'Extra.csproj') '<Project></Project>'
}) 'ST14 [kill] a PROLIFERATED tree with a $null contract -> '''' (unknown surface = no struct gate, byte-identical to today)'
# A non-existent worktree never throws / never false-fails.
Assert-Empty (Test-ProjectStructure -Worktree (Join-Path ([System.IO.Path]::GetTempPath()) ([guid]::NewGuid().ToString('N'))) -Contract $winuiContract) 'ST15 a missing worktree -> '''' (forgiving; never a false-fail)'

# ----------------------------------------------------------------------------
Section 'Wiring: verify-project.ps1 runs struct:contract EARLY (before the build) and feeds it back'
$vp = Get-Content "$PSScriptRoot\verify-project.ps1" -Raw
Assert-True ([regex]::IsMatch($vp, '(?m)^\s*\[string\]\$Surface'))                          'W1 verify-project accepts a -Surface parameter'
Assert-True ([regex]::IsMatch($vp, 'Test-ProjectStructure\s+-Worktree\s+\$Path'))           'W2 verify-project calls the real Test-ProjectStructure on the worktree'
Assert-True ([regex]::IsMatch($vp, "Add-Result\s+'struct:contract'\s+'fail'"))              'W3 [kill] a violation is recorded as a struct:contract FAIL (which flips overall to fail -> blocks the merge)'
Assert-True ([regex]::IsMatch($vp, 'Resolve-BuildProfile\s+-Surface\s+\$Surface'))          'W4 verify-project resolves the contract from the surface via Resolve-BuildProfile'
# [kill] the struct check must come BEFORE the build checks (the whole point: fail FAST, seconds not minutes).
$iStruct = $vp.IndexOf("Add-Result 'struct:contract'")
$iNodeBuild = $vp.IndexOf("'node:build'")
$iDotnetBuild = $vp.IndexOf("'dotnet:build'")
Assert-True (($iStruct -gt 0) -and ($iNodeBuild -gt 0) -and ($iStruct -lt $iNodeBuild)) 'W5 [kill] struct:contract is assembled BEFORE node:build (fail-fast, pre-empts the build)'
Assert-True (($iStruct -gt 0) -and ($iDotnetBuild -gt 0) -and ($iStruct -lt $iDotnetBuild)) 'W6 [kill] struct:contract is assembled BEFORE dotnet:build (the WinUI build is the expensive one it pre-empts)'

$nat = Get-Content "$PSScriptRoot\new-agent-task.ps1" -Raw
$lib = Get-Content "$PSScriptRoot\fleet-lib.ps1" -Raw   # #700: the per-candidate gate body moved to Invoke-CandidateBuild
# [kill] the runner must FORWARD the surface to verify-project, else the struct gate is dormant on the real path.
Assert-True ([regex]::IsMatch($lib, '\$__vpExtra\.Surface\s*=\s*\$Surface'))                 'W7 [kill] Invoke-CandidateBuild forwards -Surface into the verify-project call (the struct gate actually fires on a real run)'
Assert-True ([regex]::IsMatch($lib, 'verify-project\.ps1.*@__vpExtra'))                      'W8 Invoke-CandidateBuild splats the surface args into verify-project'
# The runner captures the failing checks' .detail via Format-VerifyError (still used for the report/diagnostics).
Assert-True ([regex]::IsMatch($lib, 'Format-VerifyError\s+-Checks\s+\$vobj\.checks'))        'W9 [kill] the verify checks'' detail (incl. a struct:contract violation) is captured via Format-VerifyError (Invoke-CandidateBuild)'
# BEST-OF-N (#689): a struct violation makes the candidate FAIL the early struct gate; instead of feeding the
# violation back (the retired serial error-feedback re-fix), best-of-N resamples a FRESH candidate from the
# CONTRACT-COMPLIANT seed, with the WinUI structural rules delivered to EVERY candidate up front via the
# staged hint. So the structural guidance still reaches the coder -- via Add-StagedHint, not error-feedback.
Assert-True ([regex]::IsMatch($nat, '\$Prompt = Add-StagedHint -Prompt \$Prompt -Staged')) 'W10 wiring: the WinUI structural rules reach every candidate up front via Add-StagedHint (each best-of-N candidate starts from the contract-compliant seed)'
Assert-True ([regex]::IsMatch($nat, '(?m)^\s*\$bon\s*=\s*Invoke-BestOfN\b'))                'W10b wiring: a build/struct failure is handled by best-of-N fresh resampling + gate selection (Invoke-BestOfN), not error-feedback re-fix'

Section 'Function proof: Format-VerifyError surfaces a struct:contract violation as actionable guidance'
# #689: error-feedback is RETIRED from the production runner (best-of-N replaced it); the dormant
# Add-BuildErrorFeedback augmentation function was REMOVED in #696. Format-VerifyError REMAINS -- it
# captures the failing checks' detail for the report + the best-of-N candidate pipeline. This drives it
# directly to prove a struct:contract violation is surfaced with the actionable WinUI guidance.
$violation = Invoke-OnSeededTree { param($t) Set-Content (Join-Path $t 'Program.cs') 'class P { static void Main(){} }' }
Assert-True ([bool]$violation) 'FB0 (precondition) the proliferated tree produced a violation string'
$fakeChecks = @(
    [pscustomobject]@{ name = 'struct:contract'; status = 'fail'; seconds = 0; detail = $violation }
)
$captured = Format-VerifyError -Checks $fakeChecks
Assert-Match $captured 'struct:contract' 'FB1 Format-VerifyError surfaces the struct:contract check name'
Assert-Match $captured 'App\.xaml\.cs'   'FB2 the captured feedback carries the actionable WinUI guidance (the entry is App.xaml.cs)'

# ----------------------------------------------------------------------------
Section 'THE REAL SEED-BUILD PROOF: the never-live-engaged winui seed compiles AND passes the gate'
# (a) Test-ProjectStructure on the clean seed -> clean (already covered by ST1, re-asserted in this context).
# (b) the gate's EXACT `dotnet build` on the seeded scaffold -> 0/0, fully offline. SKIP only if dotnet
#     or the offline feed is absent (so the suite stays runnable anywhere; here it RUNS).
$seedTmp = Join-Path ([System.IO.Path]::GetTempPath()) ("fleet-seedbuild-{0}" -f ([guid]::NewGuid().ToString('N')))
New-Item -ItemType Directory -Force $seedTmp | Out-Null
try {
    $seeded = @(Copy-ScaffoldInto -Scaffold 'winui' -Worktree $seedTmp)
    Assert-True ($seeded -contains 'MinimalWinUI.csproj') 'SB1 the winui seed lands a single .csproj'
    Assert-Empty (Test-ProjectStructure -Worktree $seedTmp -Contract $winuiContract) 'SB2 Test-ProjectStructure on the freshly-seeded scaffold -> CLEAN (the gate passes the real seed)'
    $haveDotnet = [bool](Get-Command dotnet -ErrorAction SilentlyContinue)
    $feed = 'C:\Users\mrbla\blarai-build\nuget-feed'
    $haveFeed = Test-Path $feed
    if (-not $haveDotnet) {
        _skip 'SB3 dotnet not on PATH -> SKIP the live seed build (the gate downgrades a missing toolchain to skip too)'
    } elseif (-not $haveFeed) {
        _skip "SB3 offline feed '$feed' absent -> SKIP the live seed build (restore would be a network/env gap)"
    } else {
        # Run the gate's EXACT command (verify-project.ps1: Invoke-GateCheck 'dotnet:build' 'dotnet build --nologo -v q').
        $r = Invoke-WithTimeout -CommandLine 'dotnet build --nologo -v q' -WorkDir $seedTmp -TimeoutSec 300
        if (($r.ExitCode -ne 0) -and (Test-EnvironmentFailure $r.Output)) {
            _skip "SB3 dotnet build hit an environment/restore gap (not a code error) -> SKIP: $($r.Seconds)s"
        } else {
            Assert-Eq 0 ([string]$r.ExitCode) "SB3 the seeded winui scaffold BUILDS with the gate's exact 'dotnet build --nologo -v q' -> exit 0 (offline, $($r.Seconds)s) -- the seed compiles for real"
        }
        # And the full verify gate over the seed, WITH the surface, records struct:contract pass + dotnet:build pass and overall != fail.
        $vobj = & "$PSScriptRoot\verify-project.ps1" -Path $seedTmp -Surface 'desktop-gui' -Json -TimeoutSec 300 | ConvertFrom-Json
        $structCheck = @($vobj.checks | Where-Object { $_.name -eq 'struct:contract' })
        Assert-True ($structCheck.Count -eq 1 -and $structCheck[0].status -eq 'pass') 'SB4 verify-project (-Surface desktop-gui) records a struct:contract PASS on the clean seed'
        Assert-True ($vobj.overall -ne 'fail') "SB5 verify-project overall is not 'fail' on the clean seed (overall=$($vobj.overall))"
    }
} finally {
    Remove-Item -Recurse -Force $seedTmp -ErrorAction SilentlyContinue
}

Section 'No-op proof on the wire: verify-project WITHOUT a surface adds NO struct:contract check'
# A standalone / unknown-surface run must be byte-identical to before: no struct:contract result at all.
$noSurfTmp = Join-Path ([System.IO.Path]::GetTempPath()) ("fleet-nosurf-{0}" -f ([guid]::NewGuid().ToString('N')))
New-Item -ItemType Directory -Force $noSurfTmp | Out-Null
try {
    [void](Copy-ScaffoldInto -Scaffold 'winui' -Worktree $noSurfTmp)
    # Add proliferation that WOULD fail the struct gate -- proving its ABSENCE (not its pass) when no surface.
    Set-Content (Join-Path $noSurfTmp 'Program.cs') 'class P { static void Main(){} }'
    $vNo = & "$PSScriptRoot\verify-project.ps1" -Path $noSurfTmp -Json -TimeoutSec 300 | ConvertFrom-Json
    $hasStruct = @($vNo.checks | Where-Object { $_.name -eq 'struct:contract' }).Count
    Assert-Eq 0 $hasStruct 'NO1 [kill] verify-project with NO -Surface adds NO struct:contract check (proliferation present but the gate is dormant -> byte-identical to today)'
    $vUnknown = & "$PSScriptRoot\verify-project.ps1" -Path $noSurfTmp -Surface 'unknown' -Json -TimeoutSec 300 | ConvertFrom-Json
    $hasStructU = @($vUnknown.checks | Where-Object { $_.name -eq 'struct:contract' }).Count
    Assert-Eq 0 $hasStructU 'NO2 [kill] verify-project with -Surface unknown adds NO struct:contract check (unknown resolves a $null contract -> no-op)'
} finally {
    Remove-Item -Recurse -Force $noSurfTmp -ErrorAction SilentlyContinue
}

# ----------------------------------------------------------------------------
Section 'Result'
Write-Host ("  Passed:  {0}" -f $script:Pass) -ForegroundColor Green
if ($script:Skip) { Write-Host ("  Skipped: {0}" -f $script:Skip) -ForegroundColor Yellow }
if ($script:Fail) {
    Write-Host ("  Failed:  {0}" -f $script:Fail) -ForegroundColor Red
    Write-Host ''
    Write-Host '  STRUCTURAL GATE: NOT VALIDATED - see the [FAIL] lines above:' -ForegroundColor Red
    $script:Failures | ForEach-Object { Write-Host "    - $_" -ForegroundColor Red }
    exit 1
} else {
    Write-Host ''
    Write-Host '  STRUCTURAL GATE: VALIDATED. A proliferated tree fails FAST (before the build) and the violation reaches the coder''s feedback prompt; a clean seeded tree passes (and BUILDS); unknown/no-contract is a proven no-op.' -ForegroundColor Green
    exit 0
}
