#requires -Version 5.1
<#
.SYNOPSIS
  Verify and validate the fleet's SCAFFOLD-SEEDING capability (the curated local template library).

.DESCRIPTION
  Background (plain English):
    A small model reliably trips on framework boilerplate it must author from scratch -- e.g. a
    WinUI event handler taking RoutedEventArgs while omitting `using Microsoft.UI.Xaml;` -> CS0246,
    repeated on every blind resample. SCAFFOLD SEEDING removes that class of failure: when a FRESH
    target is dispatched, the fleet copies a known-good, COMPILING skeleton from the local library
    (build-infra/<name>/reference) into the worktree, commits it as the coder's baseline, and the
    coder EXTENDS it. The two pure pieces live in fleet-lib.ps1 so they unit-test without a model:
      - Resolve-TaskScaffold : goal text (+ does a project already exist?) -> which scaffold, or none
      - Copy-ScaffoldInto    : copy the skeleton + the offline nuget.config into the worktree

    This is a general LIBRARY (add a scaffold = drop build-infra/<name>/reference + one detect rule +
    a test); WinUI is the first entry. A seeding MISS is safe -- the coder hand-authors and
    error-feedback backstops -- so the detector errs toward NOT seeding when a goal is ambiguous.

  Mutation-resistant: each [MUTATION-KILL] case fails a specific wrong implementation.
  Exit 0 if all passed, 1 otherwise. Run it normally ( .\verify-scaffold.ps1 ).
#>
$ErrorActionPreference = 'Stop'
. "$PSScriptRoot\fleet-lib.ps1"

$script:Pass = 0; $script:Fail = 0
$script:Failures = New-Object System.Collections.ArrayList
function Section($t) { Write-Host ''; Write-Host "== $t ==" -ForegroundColor Cyan }
function _pass($m) { $script:Pass++; Write-Host "  [PASS] $m" -ForegroundColor Green }
function _fail($m) { $script:Fail++; [void]$script:Failures.Add($m); Write-Host "  [FAIL] $m" -ForegroundColor Red }
function Assert-Eq($Expected, $Actual, $Msg) { if ([string]$Expected -ceq [string]$Actual) { _pass $Msg } else { _fail "$Msg (expected '$Expected', got '$Actual')" } }
function Assert-True($Cond, $Msg) { if ($Cond) { _pass $Msg } else { _fail "$Msg (expected True, got False)" } }
function Assert-Contains($H, $N, $Msg) { if ($H -and $H.ToString().Contains($N)) { _pass $Msg } else { _fail "$Msg (did not find '$N')" } }

# ----------------------------------------------------------------------------
Section 'Unit tests: Resolve-TaskScaffold (which skeleton to seed)'
$rocket = 'Create a space rocket calculator: a window with number buttons, a resizable rocket-shaped window, and a display.'

Assert-Eq 'winui' (Resolve-TaskScaffold -Prompt 'Build a WinUI 3 desktop app that adds two numbers.' -HasProject $false) 'S1 explicit WinUI desktop -> winui'
Assert-Eq 'winui' (Resolve-TaskScaffold -Prompt $rocket -HasProject $false) 'S2 windowed calculator (the rocket-calc goal) -> winui'
Assert-Eq '' (Resolve-TaskScaffold -Prompt 'Write an is_palindrome(text) function with tests.' -HasProject $false) 'S3 ambiguous non-desktop goal -> none (conservative; coder + error-feedback handle it)'
# MUTATION-KILL: the no-clobber guard runs FIRST -- never seed over an existing project.
Assert-Eq '' (Resolve-TaskScaffold -Prompt $rocket -HasProject $true) 'S4 [kill] desktop goal but a project already exists -> none (no clobber)'
# MUTATION-KILL: the web-guard beats a stray "window".
Assert-Eq 'web' (Resolve-TaskScaffold -Prompt 'Build a React web app shown in a browser window.' -HasProject $false) 'S5 web/browser goal -> web (a web scaffold now exists; NOT winui despite the word window)'
Assert-Eq 'winui' (Resolve-TaskScaffold -Prompt 'anything' -HasProject $false -Explicit 'winui') 'S6a explicit winui -> winui'
Assert-Eq '' (Resolve-TaskScaffold -Prompt $rocket -HasProject $false -Explicit 'none') 'S6b explicit none -> none (force off)'
# MUTATION-KILL: no-clobber wins even over an explicit request (safety first).
Assert-Eq '' (Resolve-TaskScaffold -Prompt 'x' -HasProject $true -Explicit 'winui') 'S7 [kill] explicit winui but a project exists -> none (no-clobber precedes the override)'
Assert-Eq 'python' (Resolve-TaskScaffold -Prompt 'Write a Python script that summarizes a CSV with pandas.' -HasProject $false) 'S8 explicit Python goal -> python'
Assert-Eq '' (Resolve-TaskScaffold -Prompt 'Build a small tool that organizes my files.' -HasProject $false) 'S9 ambiguous goal, no language signal -> none (never guess a language)'
Assert-Eq 'powershell' (Resolve-TaskScaffold -Prompt 'Write a PowerShell module with a cmdlet to query firewall rules.' -HasProject $false) 'S10 explicit PowerShell goal -> powershell'
Assert-Eq 'cpp' (Resolve-TaskScaffold -Prompt 'Implement a fast prime sieve in C++ with CMake.' -HasProject $false) 'S11 explicit C++ goal -> cpp'
Assert-Eq 'web' (Resolve-TaskScaffold -Prompt 'Create a REST API in Node with an Express-style endpoint.' -HasProject $false) 'S12 Node REST API goal -> web'
Assert-Eq 'python' (Resolve-TaskScaffold -Prompt 'Build a Flask web service in Python.' -HasProject $false) 'S12b Python web (Flask) -> python (language-correct beats the generic web check)'
Assert-Eq 'dotnet-console' (Resolve-TaskScaffold -Prompt 'Write a C# console app that adds two numbers.' -HasProject $false) 'S13 C# console app -> dotnet-console'
Assert-Eq 'dotnet-console' (Resolve-TaskScaffold -Prompt 'Create a .NET console application.' -HasProject $false) 'S14 .NET console application -> dotnet-console'
Assert-Eq 'winui' (Resolve-TaskScaffold -Prompt 'Build a WinUI desktop app in C#.' -HasProject $false) 'S15 [kill] a .NET DESKTOP goal -> winui (winui precedes dotnet-console; C# alone does not hijack a desktop target)'
Assert-Eq 'web' (Resolve-TaskScaffold -Prompt 'Build an ASP.NET web API.' -HasProject $false) 'S16 [kill] a .NET WEB goal -> web (the web check precedes dotnet-console; .NET alone does not hijack a web target)'
# Regression kill-tests for the dotnet-console OVER-MATCH bugs an adversarial review found (2026-06-24):
# non-.NET-exclusive tokens (nuget, the .net TLD, a "dotnet" CLI mention) must NOT hijack powershell/cpp.
Assert-Eq 'powershell' (Resolve-TaskScaffold -Prompt 'Build a PowerShell module that wraps a NuGet-distributed cmdlet.' -HasProject $false) 'S17 [kill] "nuget" does NOT hijack PowerShell (NuGet is also the PSGallery format) -> powershell'
Assert-Eq 'cpp' (Resolve-TaskScaffold -Prompt 'Write a C++ library and publish a nuget package for it.' -HasProject $false) 'S18 [kill] "nuget" does NOT hijack C++ (also vcpkg) -> cpp'
Assert-Eq 'powershell' (Resolve-TaskScaffold -Prompt 'A PowerShell script that downloads from example.net hourly.' -HasProject $false) 'S19 [kill] the ".net" TLD in a hostname does NOT match (anchored .NET token) -> powershell'
Assert-Eq 'cpp' (Resolve-TaskScaffold -Prompt 'Implement a fast prime sieve in C++ and compare it to a .NET version.' -HasProject $false) 'S20 [kill] ".NET version" does NOT hijack C++ (cpp precedes dotnet-console) -> cpp'
Assert-Eq 'powershell' (Resolve-TaskScaffold -Prompt 'A PowerShell automation that builds with dotnet.' -HasProject $false) 'S21 [kill] a "dotnet" CLI mention does NOT shadow PowerShell (powershell precedes) -> powershell'
Assert-Eq 'winui' (Resolve-TaskScaffold -Prompt 'Make a C# desktop calculator with buttons.' -HasProject $false) 'S22 [kill] a C# DESKTOP GUI ("desktop"+a UI noun) -> winui, not a console seed'
# Android detection (build-signal-only so a mere mention can't hijack other languages):
Assert-Eq 'android' (Resolve-TaskScaffold -Prompt 'Build an Android app that tracks workouts.' -HasProject $false) 'S23 Android app -> android'
Assert-Eq 'android' (Resolve-TaskScaffold -Prompt 'Make an Android calculator app.' -HasProject $false) 'S24 Android calculator app -> android'
Assert-Eq 'powershell' (Resolve-TaskScaffold -Prompt 'A PowerShell script to back up my Android phone photos.' -HasProject $false) 'S25 [kill] a mere "android" mention (no app-build noun) does NOT hijack PowerShell -> powershell'
Assert-Eq 'android' (Resolve-TaskScaffold -Prompt 'Build a .NET MAUI Android app.' -HasProject $false) 'S26 [kill] a MAUI ANDROID app -> android (ordered before winui, so "maui" does not grab it for desktop)'
# #886: the refiner-only web-static surface short-circuits the keyword heuristic to the static seed;
# the SAME static ask WITHOUT that surface still falls to the web keyword arm -> proves the upstream
# refiner's surface=web-static is load-bearing (P1: without it the fleet re-seeds the node server).
$staticAsk = 'Build a static web page: one index.html file, no frameworks, no build step, opens in a browser.'
Assert-Eq 'web-static' (Resolve-TaskScaffold -Prompt $staticAsk -HasProject $false -Surface 'web-static') 'S27 web-static surface -> web-static (profile preempts the keyword heuristic; the static index.html seed, NOT the node server)'
Assert-Eq 'web' (Resolve-TaskScaffold -Prompt $staticAsk -HasProject $false) 'S28 [kill] the SAME static ask with NO surface still matches the web keyword arm -> web (proves surface=web-static from the upstream refiner is load-bearing; P1)'

# ----------------------------------------------------------------------------
Section 'Unit tests: Copy-ScaffoldInto (drops a compiling skeleton, with the using)'
$tmp = Join-Path ([System.IO.Path]::GetTempPath()) 'fleet-scaffold-test'
if (Test-Path $tmp) { Remove-Item -Recurse -Force $tmp }
New-Item -ItemType Directory -Force $tmp | Out-Null
try {
    $seeded = @(Copy-ScaffoldInto -Scaffold 'winui' -Worktree $tmp)
    Assert-True ($seeded -contains 'MainWindow.xaml.cs')  'C1 winui: seeds MainWindow.xaml.cs'
    Assert-True ($seeded -contains 'MinimalWinUI.csproj') 'C1 winui: seeds the .csproj'
    Assert-True ($seeded -contains 'nuget.config')        'C1 winui: seeds the offline nuget.config (so restore is offline)'
    Assert-True (Test-Path (Join-Path $tmp 'MainWindow.xaml.cs')) 'C1 winui: the file actually lands on disk'
    # MUTATION-KILL / the whole point: the seeded code-behind already has the using the 30B omits.
    $mw = Get-Content (Join-Path $tmp 'MainWindow.xaml.cs') -Raw
    Assert-Contains $mw 'using Microsoft.UI.Xaml;' 'C2 [kill] the seeded MainWindow already has using Microsoft.UI.Xaml; (prevents the CS0246 the coder kept hitting)'
    Assert-Contains $mw 'RoutedEventArgs'          'C2 the seeded code models the RoutedEventArgs handler pattern'
    # INCREMENT-3 (#676): the winui seed now ships the core/shell/offline-tests split the staged build extends.
    Assert-True ($seeded -contains 'Calculator.cs')              'C2i3a winui: seeds the platform-free Calculator core (the testable-logic the coder implements FIRST)'
    Assert-True ($seeded -contains 'Tests\CalculatorTests.cs')   'C2i3b winui: seeds Tests/CalculatorTests.cs (the offline tests; recursive copy preserves the Tests/ subdir)'
    Assert-True (Test-Path (Join-Path $tmp 'Tests\CalculatorTests.cs')) 'C2i3c winui: the test file actually lands on disk under Tests/'
    Assert-Contains (Get-Content (Join-Path $tmp 'Calculator.cs') -Raw) 'public double Divide' 'C2i3d winui: the seeded core carries the ops (incl. divide-by-zero) the coder extends'
    # THE KEY CONSTRAINT (the parked-run failure): the seeded tests are DEPENDENCY-FREE -> build offline.
    $ct = Get-Content (Join-Path $tmp 'Tests\CalculatorTests.cs') -Raw
    Assert-Contains $ct 'TestAssert' 'C2i3e [kill] the seeded tests use an in-file dependency-free assert harness (TestAssert), not a NuGet framework'
    # [kill] the harness must not actually USE a test framework. The file's own comments legitimately NAME
    # MSTest/[TestMethod]/xUnit/NUnit to warn the coder off them, so STRIP comments first (// and /* */, the
    # same way the struct gate does) and match only real CODE: a `using` directive or a [TestMethod]/[Fact] attr.
    $ctCode = [regex]::Replace($ct, '(?s)/\*.*?\*/', '')
    $ctCode = [regex]::Replace($ctCode, '(?m)//.*$', '')
    $usesFramework = [regex]::IsMatch($ctCode, '(?im)^\s*using\s+(Microsoft\.VisualStudio\.TestTools|Xunit|NUnit)\b') `
                  -or [regex]::IsMatch($ctCode, '\[\s*(TestMethod|TestClass|Fact|Theory)\b')
    Assert-True (-not $usesFramework) 'C2i3f [kill] the seeded tests reference NO test framework (no real using-MSTest/xunit/nunit, no [TestMethod]/[Fact] -> no NU1101/CS0246 offline)'
    # And the csproj must carry NO test-framework PackageReference (the actual offline-restore break vector).
    $csproj = Get-Content (Join-Path $tmp 'MinimalWinUI.csproj') -Raw
    Assert-True (-not [regex]::IsMatch($csproj, '(?i)PackageReference\s+Include="(MSTest|xunit|nunit)')) 'C2i3i [kill] the winui csproj declares NO test-framework PackageReference (MSTest/xUnit/NUnit are not in the offline feed)'
    # The shell carries the named hooks the coder themes/extends (the Calculator field + the Display readout).
    Assert-Contains $mw 'Calculator _calc' 'C2i3g [kill] the seeded MainWindow pre-wires the Calculator core (a _calc field) so the coder extends the wiring, not re-authors it'
    Assert-Contains $mw 'Display'           'C2i3h winui: the code-behind references the named Display hook'
    Assert-Eq 0 (@(Copy-ScaffoldInto -Scaffold 'does-not-exist' -Worktree $tmp)).Count 'C3 unknown scaffold -> seeds nothing, no throw'
    # The Python scaffold has SUBDIRS (app/, tests/) -> proves Copy-ScaffoldInto recurses + preserves structure.
    $seededPy = @(Copy-ScaffoldInto -Scaffold 'python' -Worktree $tmp)
    Assert-True ($seededPy -contains 'pyproject.toml') 'C4 python: seeds pyproject.toml'
    Assert-True (Test-Path (Join-Path $tmp 'app\__init__.py')) 'C4 python: nested app/__init__.py lands (recursive copy preserves subdirs)'
    Assert-True (Test-Path (Join-Path $tmp 'tests\test_smoke.py')) 'C4 python: nested tests/test_smoke.py lands'
    # #1048: the python seed is NEUTRAL -- it proves the toolchain and asserts NO product logic. The
    # old app/core.py placeholder (def summarize) shipped dead into every build: its own seeded test
    # kept it referenced, so only the jury ever saw it (green-quality band B, three straight B4 runs).
    Assert-True (-not (Test-Path (Join-Path $tmp 'app\core.py'))) 'C5 [kill] python seeds NO app/core.py domain placeholder (#1048: it shipped dead into every build)'
    $smoke = Get-Content (Join-Path $tmp 'tests\test_smoke.py') -Raw
    Assert-Contains $smoke 'import app' 'C5 python: the seeded smoke test imports the package (the toolchain proof)'
    Assert-Contains $smoke 'tmp_path'   'C5b python: the seeded tests model tmp_path-isolated data, never a repo-root store (#1036 d)'
    Assert-True (-not ($smoke -match 'summarize')) 'C5c [kill] no summarize residue in the seeded tests'
    $seededPs = @(Copy-ScaffoldInto -Scaffold 'powershell' -Worktree $tmp)
    Assert-True ($seededPs -contains 'AppModule.psm1') 'C6 powershell: seeds the .psm1 module'
    Assert-True ($seededPs -contains 'AppModule.psd1') 'C6 powershell: seeds the manifest'
    Assert-True ($seededPs -contains 'AppModule.Tests.ps1') 'C6 powershell: seeds the Pester test'
    $seededCpp = @(Copy-ScaffoldInto -Scaffold 'cpp' -Worktree $tmp)
    Assert-True ($seededCpp -contains 'CMakeLists.txt') 'C7 cpp: seeds CMakeLists.txt'
    Assert-True (Test-Path (Join-Path $tmp 'src\core.cpp')) 'C7 cpp: nested src/core.cpp lands'
    Assert-True (Test-Path (Join-Path $tmp 'tests\test_core.cpp')) 'C7 cpp: nested tests/test_core.cpp lands'
    $seededWeb = @(Copy-ScaffoldInto -Scaffold 'web' -Worktree $tmp)
    Assert-True ($seededWeb -contains 'package.json') 'C8 web: seeds package.json'
    Assert-True (Test-Path (Join-Path $tmp 'src\server.js')) 'C8 web: nested src/server.js lands'
    Assert-True (Test-Path (Join-Path $tmp 'public\index.html')) 'C8 web: nested public/index.html lands'
    # #886: web-static seeds ONE self-contained index.html and NOTHING that makes it a server/build
    # project. Use a FRESH dir so the [kill] absence assertions are not polluted by the 'web' seed above.
    $tmpWs = Join-Path $tmp 'web-static-only'
    New-Item -ItemType Directory -Force $tmpWs | Out-Null
    $seededWs = @(Copy-ScaffoldInto -Scaffold 'web-static' -Worktree $tmpWs)
    Assert-True ($seededWs -contains 'index.html') 'C8c web-static: seeds a single top-level index.html (opens straight in a browser)'
    Assert-True (Test-Path (Join-Path $tmpWs 'index.html')) 'C8c web-static: index.html actually lands on disk'
    Assert-True (-not (Test-Path (Join-Path $tmpWs 'src\server.js'))) 'C8c [kill] web-static seeds NO src/server.js (the server seed was the #886 static-page bug)'
    Assert-True (-not (Test-Path (Join-Path $tmpWs 'public\app.js'))) 'C8c [kill] web-static seeds NO public/app.js (no fetch wiring to hang on file://)'
    Assert-True (-not ($seededWs -contains 'package.json')) 'C8c [kill] web-static seeds NO package.json (no build; detect_ecosystem -> unknown -> exec-smoke a correct no-op)'
    $seededNcli = @(Copy-ScaffoldInto -Scaffold 'node-cli' -Worktree $tmp)
    Assert-True ($seededNcli -contains 'package.json') 'C8b node-cli: seeds package.json'
    Assert-True (Test-Path (Join-Path $tmp 'src\core.mjs')) 'C8b node-cli: nested src/core.mjs lands (the testable helper)'
    Assert-True (Test-Path (Join-Path $tmp 'bin\cli.mjs')) 'C8b node-cli: nested bin/cli.mjs lands (the thin argv entry)'
    Assert-True (Test-Path (Join-Path $tmp 'test\core.test.mjs')) 'C8b node-cli: nested test/core.test.mjs lands (node:test, offline)'
    Assert-True (-not ($seededNcli -contains 'server.js')) 'C8b [kill] node-cli is a CLI, NOT a web server -> its seed carries no server.js'
    $seededDn = @(Copy-ScaffoldInto -Scaffold 'dotnet-console' -Worktree $tmp)
    Assert-True ($seededDn -contains 'app.csproj') 'C9 dotnet-console: seeds app.csproj'
    Assert-True ($seededDn -contains 'Program.cs')  'C9 dotnet-console: seeds Program.cs (thin entry point)'
    Assert-True (Test-Path (Join-Path $tmp 'Calculator.cs')) 'C9 dotnet-console: Calculator.cs (testable logic class) lands on disk'
    Assert-True (-not ($seededDn -contains 'nuget.config')) 'C9 [kill] dotnet-console is dependency-free -> seeds NO nuget.config (builds offline with no feed)'
    $seededAnd = @(Copy-ScaffoldInto -Scaffold 'android' -Worktree $tmp)
    Assert-True ($seededAnd -contains 'App.csproj') 'C10 android: seeds App.csproj (net8.0-android)'
    Assert-True ($seededAnd -contains 'MainActivity.cs') 'C10 android: seeds MainActivity.cs (entry-point Activity)'
    Assert-True ($seededAnd -contains 'Calculator.cs') 'C10 android: seeds the testable logic class'
    Assert-True (Test-Path (Join-Path $tmp 'Resources\values\strings.xml')) 'C10 android: nested Resources/values/strings.xml lands (recursive copy preserves the resource tree)'
    Assert-Contains (Get-Content (Join-Path $tmp 'MainActivity.cs') -Raw) 'Calculator.Add' 'C11 android: the Activity is wired to the testable logic (models the extend pattern)'
    # ------------------------------------------------------------------------
    # #790 sub-task 5: -PackageName seeds ONE canonical package named by the job-oracle
    # contract -- the B4 flashcards park grew BOTH a generic app/ twin AND the oracle's
    # flashcard_app/ because the seed and the oracle pinned different layouts.
    $tmpCp = Join-Path $tmp 'canonical-pkg'
    New-Item -ItemType Directory -Force $tmpCp | Out-Null
    $seededCp = @(Copy-ScaffoldInto -Scaffold 'python' -Worktree $tmpCp -PackageName 'flashcard_app')
    Assert-True (Test-Path (Join-Path $tmpCp 'flashcard_app\__init__.py')) 'C12 canonical: the package seeds under the contract name (flashcard_app/__init__.py lands)'
    Assert-True (Test-Path (Join-Path $tmpCp 'tests\test_smoke.py'))       'C12 canonical: the neutral smoke test seeds beside the canonical package'
    Assert-True (-not (Test-Path (Join-Path $tmpCp 'app')))                'C12 [kill] NO generic app/ twin is seeded (the B4 duplicate-tree shape)'
    # EXACTLY ONE top-level package: the canonical dir, and no other seeded dir carrying an __init__.py.
    $topPkgs = @(Get-ChildItem -LiteralPath $tmpCp -Directory | Where-Object { Test-Path (Join-Path $_.FullName '__init__.py') })
    Assert-Eq 1 $topPkgs.Count 'C12 [kill] a scaffolded job carries EXACTLY ONE top-level package'
    Assert-Eq 'flashcard_app' $topPkgs[0].Name 'C12 canonical: ...and it is the contract-named one'
    # The seeded references FOLLOW the rename (no stale app.* import/config leakage).
    Assert-Contains (Get-Content (Join-Path $tmpCp 'tests\test_smoke.py') -Raw) 'import flashcard_app' 'C12 canonical: the seeded smoke test imports the canonical package (the rename follows into the import line)'
    $pyprojCp = Get-Content (Join-Path $tmpCp 'pyproject.toml') -Raw
    Assert-Contains $pyprojCp 'name = "flashcard_app"'    'C12 canonical: pyproject project name follows'
    Assert-Contains $pyprojCp '"flashcard_app*"'          'C12 canonical: pyproject package discovery follows'
    $staleApp = [regex]::IsMatch(((Get-Content (Join-Path $tmpCp 'tests\test_smoke.py') -Raw) + $pyprojCp + (Get-Content (Join-Path $tmpCp 'README.md') -Raw) + (Get-Content (Join-Path $tmpCp 'flashcard_app\__init__.py') -Raw)), '\bapp\b')
    Assert-True (-not $staleApp) 'C12 [kill] NO standalone-token ''app'' survives in any seeded text file (no stale template leakage)'
    # The seeded __init__ stays LAZY (docstring + version, no eager submodule imports) -- one broken
    # submodule must not fail the whole package at import time.
    Assert-True (-not ([regex]::IsMatch((Get-Content (Join-Path $tmpCp 'flashcard_app\__init__.py') -Raw), '(?m)^\s*from\s+\.\s+import\b'))) 'C12 canonical: the seeded __init__ is LAZY (no eager from-. imports)'
    # Deny-by-default: an invalid/hyphenated/empty/'app' name -> the byte-identical legacy generic seed.
    foreach ($bad in @('flash-card', 'app', '', '0bad', 'x.y')) {
        $tmpBad = Join-Path $tmp ("bad-pkg-" + [math]::Abs($bad.GetHashCode()))
        New-Item -ItemType Directory -Force $tmpBad | Out-Null
        $null = @(Copy-ScaffoldInto -Scaffold 'python' -Worktree $tmpBad -PackageName $bad)
        Assert-True ((Test-Path (Join-Path $tmpBad 'app\__init__.py')) -and -not (Test-Path (Join-Path $tmpBad 'flash-card'))) ("C13 [kill] invalid PackageName '" + $bad + "' -> the legacy generic app/ seed (never a guessed rename)")
    }
    # Non-python scaffolds ignore -PackageName entirely (no app/ package ships in them).
    $tmpWs2 = Join-Path $tmp 'ws-pkgname'
    New-Item -ItemType Directory -Force $tmpWs2 | Out-Null
    $seededWs2 = @(Copy-ScaffoldInto -Scaffold 'web-static' -Worktree $tmpWs2 -PackageName 'flashcard_app')
    Assert-True (($seededWs2 -contains 'index.html') -and -not (Test-Path (Join-Path $tmpWs2 'flashcard_app'))) 'C14 non-python scaffold ignores -PackageName (nothing to rename; byte-identical seed)'
} finally {
    if (Test-Path $tmp) { Remove-Item -Recurse -Force $tmp -ErrorAction SilentlyContinue }
}

# ----------------------------------------------------------------------------
Section 'Hygiene locks: the python seed is neutral, green out of the box, and tmp-path-isolated (#1036/#1048)'
# Three mechanical rules, each with a negative ([kill]) proof via the injectable -ScaffoldRoot:
#   NEUTRAL : seeded package modules define NO functions/classes -- a def/class in the seed IS a
#             domain placeholder (#1048's summarize survived into every shipped tree because its
#             own seeded test kept it referenced, so dead-code tooling saw live code).
#   ISOLATED: running the seeded tests leaves the seeded tree byte-identical -- test data goes
#             under pytest's tmp_path, never a repo-root store (#1036 d).
#   CLEAN   : the seeded set equals the COMMITTED reference list -- disk litter in the scaffold
#             source (cache dirs from a stray tool run) never rides into a coder baseline.
function Get-SeededDomainDefs {
    # Every def/class in the seeded PACKAGE modules (tests/ excluded: test functions are the
    # toolchain proof, not product logic -- the #1048 finding was package-side dead code).
    param([Parameter(Mandatory)][string]$Root)
    $hits = New-Object System.Collections.ArrayList
    foreach ($py in Get-ChildItem -LiteralPath $Root -Recurse -Filter *.py -File) {
        if ($py.FullName -match '[\\/]tests[\\/]') { continue }
        foreach ($m in [regex]::Matches((Get-Content -LiteralPath $py.FullName -Raw), '(?m)^\s*(?:def|class)\s+(\w+)')) {
            [void]$hits.Add($py.Name + ':' + $m.Groups[1].Value)
        }
    }
    return ,@($hits)
}
function Get-TreeFingerprint {
    # Path+hash of every file under $Root, excluding runner byproducts (pytest/hypothesis caches,
    # __pycache__). Sorted, so two fingerprints compare as one string.
    param([Parameter(Mandatory)][string]$Root)
    $lines = @(Get-ChildItem -LiteralPath $Root -Recurse -File |
        Where-Object { $_.FullName -notmatch '[\\/](\.pytest_cache|__pycache__|\.hypothesis)[\\/]' } |
        Sort-Object FullName |
        ForEach-Object { $_.FullName.Substring($Root.Length) + '|' + (Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash })
    return ($lines -join "`n")
}
$tmpH = Join-Path ([System.IO.Path]::GetTempPath()) ('fleet-scaffold-hygiene-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
New-Item -ItemType Directory -Force $tmpH | Out-Null
try {
    $wtH = Join-Path $tmpH 'fresh-seed'
    New-Item -ItemType Directory -Force $wtH | Out-Null
    $null = @(Copy-ScaffoldInto -Scaffold 'python' -Worktree $wtH)

    # H2: the neutral-seed detector over a fresh seed. (No @() re-wrap: the function's unary
    # comma already returns a real array, same consumption idiom as Get-ProjectEcosystem.)
    $defs = Get-SeededDomainDefs -Root $wtH
    Assert-Eq 0 $defs.Count ('H2 [kill] the seeded package ships ZERO def/class (neutral seed; found: ' + ($defs -join ', ') + ')')

    # H7: the seeded set EQUALS the committed reference list (git index truth) -- catches any
    # litter class the Copy-ScaffoldInto filter does not name: an on-disk extra in the source
    # fails loud here instead of riding silently into every coder baseline.
    $committedH = @(git -C (Split-Path $PSScriptRoot -Parent) ls-files -- 'build-infra/python/reference' |
        ForEach-Object { ($_ -replace '^build-infra/python/reference/', '') -replace '/', '\' } | Sort-Object)
    $seededNormH = @(@(Copy-ScaffoldInto -Scaffold 'python' -Worktree (New-Item -ItemType Directory -Force (Join-Path $tmpH 'set-check')).FullName) |
        ForEach-Object { $_ -replace '/', '\' } | Sort-Object)
    Assert-Eq ($committedH -join ';') ($seededNormH -join ';') 'H7 [kill] the seeded file set EQUALS the committed reference list (nothing extra rides in from the source dir)'

    # H1 + H3 drive the FLEET'S OWN pytest command form (Invoke-CandidateBuild's gate). uv missing
    # is a FAIL, never a skip: the fleet gate itself cannot run without it.
    $gateCmd = 'uv run --no-project --with pytest --with hypothesis pytest -q'
    if (Get-Command uv -ErrorAction SilentlyContinue) {
        $before = Get-TreeFingerprint -Root $wtH
        $r = Invoke-WithTimeout -CommandLine $gateCmd -WorkDir $wtH -TimeoutSec 300
        Assert-True ((-not $r.TimedOut) -and ($r.ExitCode -eq 0)) 'H1 [kill] a fresh python seed is GREEN out of the box under the fleet gate command'
        Assert-True ($r.Output -match '(?m)\b\d+ passed\b') 'H1b ...and tests actually RAN (a hollow exit-0 with zero tests would prove nothing)'
        Assert-True ($before -ceq (Get-TreeFingerprint -Root $wtH)) 'H3 [kill] the seeded tests leave the tree byte-identical (tmp_path-isolated; no repo-root data store)'

        # H1c: the CANONICAL -PackageName form -- the form production plan-graph jobs actually
        # dispatch -- is identically green out of the box under the same gate command.
        $wtHC = Join-Path $tmpH 'fresh-seed-canonical'
        New-Item -ItemType Directory -Force $wtHC | Out-Null
        $null = @(Copy-ScaffoldInto -Scaffold 'python' -Worktree $wtHC -PackageName 'flashcard_app')
        $rc = Invoke-WithTimeout -CommandLine $gateCmd -WorkDir $wtHC -TimeoutSec 300
        Assert-True ((-not $rc.TimedOut) -and ($rc.ExitCode -eq 0)) 'H1c [kill] the canonical -PackageName seed is GREEN out of the box under the fleet gate command'
        Assert-True ($rc.Output -match '(?m)\b\d+ passed\b') 'H1c ...with tests actually running in the canonical form too'

        # H5 (negative): a seeded test that writes into the repo tree IS caught by the purity check.
        $rootLeak = Join-Path $tmpH 'root-leak'
        New-Item -ItemType Directory -Force $rootLeak | Out-Null
        Copy-Item -LiteralPath (Join-Path (Split-Path $PSScriptRoot -Parent) 'build-infra\python') -Destination (Join-Path $rootLeak 'python') -Recurse -Force
        Add-Content -LiteralPath (Join-Path $rootLeak 'python\reference\tests\test_smoke.py') -Value "`n`ndef test_leaks_into_the_repo():`n    with open('leaked_store.json', 'w') as f:`n        f.write('leak')`n"
        $wtLeak = Join-Path $tmpH 'seed-leak'
        New-Item -ItemType Directory -Force $wtLeak | Out-Null
        $null = @(Copy-ScaffoldInto -Scaffold 'python' -Worktree $wtLeak -ScaffoldRoot $rootLeak)
        $beforeLeak = Get-TreeFingerprint -Root $wtLeak
        $null = Invoke-WithTimeout -CommandLine $gateCmd -WorkDir $wtLeak -TimeoutSec 300
        Assert-True ($beforeLeak -cne (Get-TreeFingerprint -Root $wtLeak)) 'H5 [kill] a seeded test writing a repo-root store IS flagged by the tree-purity check'
    } else {
        _fail 'H1/H1b/H3/H5: uv is not on PATH -- the out-of-box gate proof cannot run (fail-loud, never a silent skip)'
    }

    # H4 (negative): reintroduce #1048's domain placeholder via the injectable ScaffoldRoot -> flagged.
    $rootBad = Join-Path $tmpH 'root-domain'
    New-Item -ItemType Directory -Force $rootBad | Out-Null
    Copy-Item -LiteralPath (Join-Path (Split-Path $PSScriptRoot -Parent) 'build-infra\python') -Destination (Join-Path $rootBad 'python') -Recurse -Force
    Set-Content -LiteralPath (Join-Path $rootBad 'python\reference\app\core.py') -Value "def summarize(numbers):`n    return {'count': len(numbers)}`n" -Encoding utf8NoBOM
    $wtBad = Join-Path $tmpH 'seed-domain'
    New-Item -ItemType Directory -Force $wtBad | Out-Null
    $null = @(Copy-ScaffoldInto -Scaffold 'python' -Worktree $wtBad -ScaffoldRoot $rootBad)
    $defsBad = Get-SeededDomainDefs -Root $wtBad
    Assert-True (($defsBad.Count -gt 0) -and (($defsBad -join ',') -match 'summarize')) 'H4 [kill] a reintroduced domain placeholder (def summarize) IS flagged by the neutral-seed detector'

    # H6 (negative): planted source litter is NOT seeded (the Copy-ScaffoldInto litter guard holds).
    $rootLit = Join-Path $tmpH 'root-litter'
    New-Item -ItemType Directory -Force $rootLit | Out-Null
    Copy-Item -LiteralPath (Join-Path (Split-Path $PSScriptRoot -Parent) 'build-infra\python') -Destination (Join-Path $rootLit 'python') -Recurse -Force
    New-Item -ItemType Directory -Force (Join-Path $rootLit 'python\reference\app\__pycache__') | Out-Null
    Set-Content -LiteralPath (Join-Path $rootLit 'python\reference\app\__pycache__\junk.cpython-312.pyc') -Value 'junk'
    New-Item -ItemType Directory -Force (Join-Path $rootLit 'python\reference\.pytest_cache') | Out-Null
    Set-Content -LiteralPath (Join-Path $rootLit 'python\reference\.pytest_cache\CACHEDIR.TAG') -Value 'Signature: 8a477f597d28d172789f06886806bc55'
    New-Item -ItemType Directory -Force (Join-Path $rootLit 'python\reference\.hypothesis\examples') | Out-Null
    Set-Content -LiteralPath (Join-Path $rootLit 'python\reference\.hypothesis\examples\e1') -Value 'x'
    $wtLit = Join-Path $tmpH 'seed-litter'
    New-Item -ItemType Directory -Force $wtLit | Out-Null
    $seededLit = @(Copy-ScaffoldInto -Scaffold 'python' -Worktree $wtLit -ScaffoldRoot $rootLit)
    $litterSeeded = (@($seededLit) -match '__pycache__|\.pytest_cache|\.hypothesis').Count -gt 0 -or
        (Test-Path (Join-Path $wtLit 'app\__pycache__')) -or (Test-Path (Join-Path $wtLit '.pytest_cache')) -or (Test-Path (Join-Path $wtLit '.hypothesis'))
    Assert-True (-not $litterSeeded) 'H6 [kill] planted source litter (__pycache__/.pytest_cache/.hypothesis) is NOT seeded (the litter guard holds)'
    Assert-Eq 4 (@($seededLit)).Count 'H6 ...and the litter-planted source still seeds exactly the 4 real files'
} finally {
    if (Test-Path $tmpH) { Remove-Item -Recurse -Force $tmpH -ErrorAction SilentlyContinue }
}

# ----------------------------------------------------------------------------
Section 'Wiring: the runner seeds, commits a baseline, and measures the coder against it'
$nat = Get-Content "$PSScriptRoot\new-agent-task.ps1" -Raw
Assert-True ([regex]::IsMatch($nat, '(?m)^\s*\$scaffold\s*=\s*Resolve-TaskScaffold\b')) 'W1 wiring: runner calls Resolve-TaskScaffold (real, non-comment line)'
Assert-True ([regex]::IsMatch($nat, 'Copy-ScaffoldInto\b'))                              'W2 wiring: runner calls Copy-ScaffoldInto'
$lib = Get-Content "$PSScriptRoot\fleet-lib.ps1" -Raw   # #700: the per-candidate pipeline moved to Invoke-CandidateBuild
Assert-True ([regex]::IsMatch($lib, 'rev-list --count "\$CodeBase\.\.HEAD"'))            'W3 wiring: the coder is measured against the seeded baseline ($CodeBase) in Invoke-CandidateBuild, not the empty base'
# Seed BEFORE ecosystem detection so a seeded .csproj also drives the language pin.
$iScaffold = $nat.IndexOf('Resolve-TaskScaffold')
$iEco = $nat.IndexOf('Get-ProjectEcosystem $wt')
Assert-True ($iScaffold -gt 0 -and $iEco -gt 0 -and $iScaffold -lt $iEco) 'W4 wiring: seeding runs BEFORE ecosystem/language detection (the seed drives the language pin too)'
# #790 sub-task 5: the canonical package rides queue task -> run-fleet -> runner -> seeder.
Assert-True ([regex]::IsMatch($nat, 'Copy-ScaffoldInto\s+-Scaffold\s+\$scaffold\s+-Worktree\s+\$wt\s+-PackageName\s+\$CanonicalPackage')) 'W5 wiring: the runner passes -PackageName $CanonicalPackage into the seeder'
Assert-True ([regex]::IsMatch($nat, '(?m)^\s*\[string\]\$CanonicalPackage')) 'W5 wiring: the runner declares the -CanonicalPackage parameter'
$rf = Get-Content "$PSScriptRoot\run-fleet.ps1" -Raw
Assert-True ([regex]::IsMatch($rf, '\$t\.canonical_package\s*\)\s*\{\s*\$params\.CanonicalPackage')) 'W6 wiring: run-fleet forwards a queue task''s .canonical_package to the runner'

# ----------------------------------------------------------------------------
Section 'Result'
Write-Host ("  Passed:  {0}" -f $script:Pass) -ForegroundColor Green
if ($script:Fail) {
    Write-Host ("  Failed:  {0}" -f $script:Fail) -ForegroundColor Red
    Write-Host ''
    Write-Host '  SCAFFOLD SEEDING: NOT VALIDATED - see the [FAIL] lines above:' -ForegroundColor Red
    $script:Failures | ForEach-Object { Write-Host "    - $_" -ForegroundColor Red }
    exit 1
} else {
    Write-Host ''
    Write-Host '  SCAFFOLD SEEDING: VALIDATED. Fresh targets start from a compiling skeleton; the coder extends it.' -ForegroundColor Green
    exit 0
}
