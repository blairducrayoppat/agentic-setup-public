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
    Assert-True (Test-Path (Join-Path $tmp 'app\core.py')) 'C4 python: nested app/core.py lands (recursive copy preserves subdirs)'
    Assert-True (Test-Path (Join-Path $tmp 'tests\test_core.py')) 'C4 python: nested tests/test_core.py lands'
    Assert-Contains (Get-Content (Join-Path $tmp 'app\core.py') -Raw) 'def summarize' 'C5 python: the seeded core carries the placeholder fn the coder extends'
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
} finally {
    if (Test-Path $tmp) { Remove-Item -Recurse -Force $tmp -ErrorAction SilentlyContinue }
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
