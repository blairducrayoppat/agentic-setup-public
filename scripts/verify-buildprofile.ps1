#requires -Version 5.1
<#
.SYNOPSIS
  Verify and validate the BUILD-PROFILE feature (Increment 1 / #675): the fleet's deterministic,
  curated map from the 14B's coarse platform classification (`surface`, + optional `language_hint`)
  to the concrete build profile (scaffold + structural contract + staged flag).

.DESCRIPTION
  Background (plain English):
    A pure-product `/dispatch` goal ("a calculator that looks like a rocket") carries no tech signal,
    so the fleet's conservative Resolve-TaskScaffold no-ops, the 30B authors from scratch, proliferates,
    and parks. The upstream 14B (which DOES know the platform) now emits a coarse `surface` label on each
    queued task. This is the FLEET CONSUMER: turn that label into the right scaffold + structural contract.
    The ownership model: the operator writes product intent, the 14B classifies the surface, and the
    SYSTEM (this curated map) supplies all the tech. Two pure pieces live in fleet-lib.ps1 so they
    unit-test without a model:
      - Resolve-BuildProfile : surface (+ language_hint) -> @{ scaffold; structural_contract; staged }
      - Resolve-TaskScaffold : now PREFERS the profile when the surface is KNOWN, else falls through to
                               TODAY'S keyword/-HasProject heuristic UNCHANGED (strictly additive).

    Strictly-additive contract: an ABSENT/unknown/unrecognised surface returns the EMPTY profile and
    Resolve-TaskScaffold behaves EXACTLY as it does today (never worse than now).

  THE OVER-MATCH LESSON (honoured here): an adversarial panel found the keyword heuristic over-matches
  (`\bnuget\b` hijacking powershell, the ".net" TLD, a "dotnet" CLI mention). The new surface path must
  not resurrect that class, so this suite COMBINES TOKENS ADVERSARIALLY -- it proves an `automation`
  surface + a "nuget"/".net"-mentioning prompt still resolves to powershell, and that a KNOWN surface
  PREEMPTS the keyword heuristic (only when known).

  Mutation-resistant: each [kill] case fails a specific wrong implementation.
  Exit 0 if all passed, 1 otherwise. Run it normally ( .\verify-buildprofile.ps1 ).
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
function Assert-False($Cond, $Msg) { if (-not $Cond) { _pass $Msg } else { _fail "$Msg (expected False, got True)" } }
function Assert-Null($Val, $Msg) { if ($null -eq $Val) { _pass $Msg } else { _fail "$Msg (expected `$null, got '$Val')" } }
function Assert-NotNull($Val, $Msg) { if ($null -ne $Val) { _pass $Msg } else { _fail "$Msg (expected non-null, got `$null)" } }

# ----------------------------------------------------------------------------
Section 'Unit tests: Resolve-BuildProfile (surface -> scaffold)'
Assert-Eq 'winui'      (Resolve-BuildProfile -Surface 'desktop-gui').scaffold  'BP1 desktop-gui -> winui'
Assert-Eq 'web'        (Resolve-BuildProfile -Surface 'web').scaffold          'BP2 web -> web'
# #886: the refiner-only static surface -> a lone self-contained index.html scaffold (no server seed)
Assert-Eq 'web-static' (Resolve-BuildProfile -Surface 'web-static').scaffold   'BP2b web-static -> web-static (static page seed, not the server skeleton)'
Assert-Null ((Resolve-BuildProfile -Surface 'web-static').structural_contract) 'BP2b web-static -> structural_contract $null'
Assert-False ((Resolve-BuildProfile -Surface 'web-static').staged)             'BP2b web-static -> staged $false'
Assert-Eq 'android'    (Resolve-BuildProfile -Surface 'mobile').scaffold       'BP3 mobile -> android'
Assert-Eq 'powershell' (Resolve-BuildProfile -Surface 'automation').scaffold   'BP4 automation -> powershell'
# command-line: default + language_hint refinement
Assert-Eq 'python'         (Resolve-BuildProfile -Surface 'command-line').scaffold                      'BP5 command-line (no hint) -> python (house default: Python-centric AI, consistent with library; #740)'
Assert-Eq 'python'         (Resolve-BuildProfile -Surface 'command-line' -LanguageHint 'python').scaffold 'BP6 command-line + python -> python'
Assert-Eq 'dotnet-console' (Resolve-BuildProfile -Surface 'command-line' -LanguageHint 'dotnet').scaffold 'BP7 command-line + dotnet -> dotnet-console'
Assert-Eq 'node-cli'       (Resolve-BuildProfile -Surface 'command-line' -LanguageHint 'node').scaffold   'BP8 command-line + node -> node-cli (a node CLI, NOT a node web server; #740)'
Assert-Eq 'cpp'            (Resolve-BuildProfile -Surface 'command-line' -LanguageHint 'cpp').scaffold    'BP9 command-line + cpp -> cpp'
Assert-Eq 'powershell'     (Resolve-BuildProfile -Surface 'command-line' -LanguageHint 'powershell').scaffold 'BP10 command-line + powershell -> powershell'
# library: default + refinement
Assert-Eq 'python' (Resolve-BuildProfile -Surface 'library').scaffold                       'BP11 library (no hint) -> python (house default)'
Assert-Eq 'cpp'    (Resolve-BuildProfile -Surface 'library' -LanguageHint 'cpp').scaffold   'BP12 library + cpp -> cpp'
Assert-Eq 'dotnet-console' (Resolve-BuildProfile -Surface 'library' -LanguageHint 'dotnet').scaffold 'BP13 library + dotnet -> dotnet-console'

Section 'Unit tests: Resolve-BuildProfile (the empty / fall-back profile)'
$u = Resolve-BuildProfile -Surface 'unknown'
Assert-Eq '' $u.scaffold              'BP14 unknown -> scaffold '''' (the fall-back path)'
Assert-Null $u.structural_contract    'BP14 unknown -> structural_contract $null'
Assert-False $u.staged                'BP14 unknown -> staged $false'
$e = Resolve-BuildProfile -Surface ''
Assert-Eq '' $e.scaffold              'BP15 [kill] empty surface -> scaffold '''' (absent == fall-back, not a guess)'
Assert-Null $e.structural_contract    'BP15 [kill] empty surface -> structural_contract $null'
$g = Resolve-BuildProfile -Surface 'banana'
Assert-Eq '' $g.scaffold              'BP16 [kill] unrecognised surface -> scaffold '''' (never invents a scaffold)'
Assert-Null $g.structural_contract    'BP16 [kill] unrecognised surface -> structural_contract $null'
# case/whitespace insensitivity (the label arrives from JSON; do not be brittle).
Assert-Eq 'winui' (Resolve-BuildProfile -Surface '  Desktop-GUI ').scaffold 'BP17 surface is case- and whitespace-insensitive ( " Desktop-GUI " -> winui)'
Assert-Eq 'python' (Resolve-BuildProfile -Surface 'command-line' -LanguageHint '  PYTHON ').scaffold 'BP18 language_hint is case- and whitespace-insensitive'

Section 'Unit tests: Resolve-BuildProfile (the WinUI structural contract + staged)'
$wp = Resolve-BuildProfile -Surface 'desktop-gui'
Assert-True $wp.staged                          'BP19 desktop-gui is staged (a testable-core/shell split)'
Assert-NotNull $wp.structural_contract          'BP20 desktop-gui carries a structural contract'
$c = $wp.structural_contract
Assert-Eq 1 ([int]$c.max_projects)              'BP21 WinUI contract: max_projects = 1'
Assert-True ($c.project_globs -contains '*.csproj') 'BP22 WinUI contract: project_globs includes *.csproj'
Assert-True ($c.entry_points -contains 'App.xaml.cs') 'BP23 WinUI contract: the allowed entry is App.xaml.cs'
Assert-True ([bool]$c.forbid_extra_entry_points)  'BP24 WinUI contract: forbids extra entry points (no rogue Program.cs/Main)'
Assert-True ($c.forbid_top_level_statements_outside -contains 'App.xaml.cs') 'BP25 WinUI contract: top-level statements allowed only in App.xaml.cs'
Assert-Eq 'Tests/' ([string]$c.test_dir)        'BP26 WinUI contract: tests belong under Tests/'
# [kill] the non-desktop surfaces do NOT (yet) carry a structural contract -> the struct gate stays a no-op for them.
Assert-Null (Resolve-BuildProfile -Surface 'web').structural_contract          'BP27 [kill] web carries NO contract (struct gate no-op until a web contract is curated)'
Assert-Null (Resolve-BuildProfile -Surface 'automation').structural_contract   'BP28 [kill] automation carries NO contract'
Assert-Null (Resolve-BuildProfile -Surface 'command-line').structural_contract 'BP29 [kill] command-line carries NO contract'
Assert-False (Resolve-BuildProfile -Surface 'web').staged                      'BP30 [kill] web is NOT staged'

# ----------------------------------------------------------------------------
Section 'Unit tests: Resolve-TaskScaffold PREFERS the profile when the surface is KNOWN'
# When the surface is known, the curated profile decides the scaffold (the SYSTEM owns tech).
Assert-Eq 'winui'      (Resolve-TaskScaffold -Prompt 'a rocket calculator'        -HasProject $false -Surface 'desktop-gui')  'TS1 surface desktop-gui -> winui (profile-driven, no keyword needed)'
Assert-Eq 'web'        (Resolve-TaskScaffold -Prompt 'a thing'                     -HasProject $false -Surface 'web')          'TS2 surface web -> web'
Assert-Eq 'android'    (Resolve-TaskScaffold -Prompt 'a thing'                     -HasProject $false -Surface 'mobile')       'TS3 surface mobile -> android'
Assert-Eq 'powershell' (Resolve-TaskScaffold -Prompt 'a thing'                     -HasProject $false -Surface 'automation')   'TS4 surface automation -> powershell'
Assert-Eq 'python'     (Resolve-TaskScaffold -Prompt 'a thing'                     -HasProject $false -Surface 'library')      'TS5 surface library (no hint) -> python'
Assert-Eq 'cpp'        (Resolve-TaskScaffold -Prompt 'a thing'                     -HasProject $false -Surface 'library' -LanguageHint 'cpp') 'TS6 surface library + cpp hint -> cpp'

Section 'Unit tests: the surface PREEMPTS the keyword heuristic (only when KNOWN)'
# A KNOWN surface wins over a CONFLICTING keyword in the prompt -- the SYSTEM trusts the 14B's classification.
Assert-Eq 'winui'  (Resolve-TaskScaffold -Prompt 'write a python script with pytest' -HasProject $false -Surface 'desktop-gui') 'TS7 [kill] desktop-gui surface PREEMPTS a python-keyword prompt -> winui (not python)'
Assert-Eq 'web'    (Resolve-TaskScaffold -Prompt 'a C++ prime sieve with CMake'       -HasProject $false -Surface 'web')         'TS8 [kill] web surface PREEMPTS a C++-keyword prompt -> web (not cpp)'
Assert-Eq 'python' (Resolve-TaskScaffold -Prompt 'build a WinUI 3 desktop app'        -HasProject $false -Surface 'library' -LanguageHint 'python') 'TS9 [kill] library+python PREEMPTS a WinUI-keyword prompt -> python (not winui)'

Section 'Unit tests: unknown/absent surface FALLS THROUGH to today''s heuristic UNCHANGED (strictly additive)'
# These pairs prove the no-surface and unknown-surface paths are IDENTICAL to today's keyword result.
Assert-Eq 'python'         (Resolve-TaskScaffold -Prompt 'Write a Python script that summarizes a CSV with pandas.' -HasProject $false -Surface 'unknown') 'TS10 unknown surface + python prompt -> python (heuristic)'
Assert-Eq 'python'         (Resolve-TaskScaffold -Prompt 'Write a Python script that summarizes a CSV with pandas.' -HasProject $false)                    'TS10b no surface + python prompt -> python (today, unchanged)'
Assert-Eq 'winui'          (Resolve-TaskScaffold -Prompt 'Build a WinUI 3 desktop app that adds two numbers.'       -HasProject $false -Surface 'unknown') 'TS11 unknown surface + WinUI prompt -> winui (heuristic)'
Assert-Eq 'winui'          (Resolve-TaskScaffold -Prompt 'Build a WinUI 3 desktop app that adds two numbers.'       -HasProject $false)                    'TS11b no surface + WinUI prompt -> winui (today, unchanged)'
Assert-Eq 'dotnet-console' (Resolve-TaskScaffold -Prompt 'Write a C# console app that adds two numbers.'            -HasProject $false -Surface 'unknown') 'TS12 unknown surface + C# console prompt -> dotnet-console (heuristic)'
Assert-Eq ''               (Resolve-TaskScaffold -Prompt 'Build a small tool that organizes my files.'              -HasProject $false -Surface 'unknown') 'TS13 unknown surface + ambiguous prompt -> '''' (conservative no-seed, unchanged)'
Assert-Eq ''               (Resolve-TaskScaffold -Prompt 'Build a small tool that organizes my files.'              -HasProject $false)                    'TS13b no surface + ambiguous prompt -> '''' (today, unchanged)'

Section 'Unit tests: safety precedence (no-clobber + explicit override still win over the surface)'
# No-clobber runs FIRST -- never seed over a real project, even with a known surface.
Assert-Eq '' (Resolve-TaskScaffold -Prompt 'x' -HasProject $true  -Surface 'desktop-gui') 'TS14 [kill] desktop-gui surface but a project exists -> '''' (no-clobber precedes the surface)'
# An explicit force/off overrides the surface (caller/operator intent, safety first).
Assert-Eq ''      (Resolve-TaskScaffold -Prompt 'x' -HasProject $false -Surface 'desktop-gui' -Explicit 'none')  'TS15 [kill] explicit none overrides a desktop-gui surface -> '''' (force off wins)'
Assert-Eq 'python' (Resolve-TaskScaffold -Prompt 'x' -HasProject $false -Surface 'desktop-gui' -Explicit 'python') 'TS16 [kill] an explicit scaffold overrides the surface -> python (force wins)'

# ----------------------------------------------------------------------------
Section 'THE OVER-MATCH LESSON: adversarial token combinations must NOT resurrect the C#-hijack class'
# An `automation`/`library` surface + a prompt that MENTIONS nuget / .net / dotnet must STILL resolve to the
# surface's scaffold -- the surface preempts, so the over-matching keyword heuristic is never even reached.
Assert-Eq 'powershell' (Resolve-TaskScaffold -Prompt 'An automation that builds with dotnet and pulls a nuget package from example.net.' -HasProject $false -Surface 'automation') 'OM1 [kill] automation + (dotnet+nuget+.net) prompt -> powershell (surface preempts; no C# hijack)'
Assert-Eq 'powershell' (Resolve-TaskScaffold -Prompt 'A PowerShell module that wraps a NuGet-distributed cmdlet and targets the .NET framework.' -HasProject $false -Surface 'automation') 'OM2 [kill] automation + (NuGet+.NET framework) prompt -> powershell'
Assert-Eq 'python'     (Resolve-TaskScaffold -Prompt 'A reusable library; compare it to a .NET version and ship a nuget package.' -HasProject $false -Surface 'library') 'OM3 [kill] library (no hint) + (.NET+nuget) prompt -> python (house default; surface preempts)'
Assert-Eq 'powershell' (Resolve-TaskScaffold -Prompt 'A library that downloads from example.net hourly.' -HasProject $false -Surface 'library' -LanguageHint 'powershell') 'OM4 [kill] library + powershell hint + ".net" TLD prompt -> powershell (the .net TLD does not matter; surface+hint decide)'
# CRUCIALLY: the over-match guard ALSO still holds on the heuristic path itself (unknown surface) -- the surface
# path did not weaken the existing anchored-.NET / nuget-is-not-exclusive protections (regression with the heuristic).
Assert-Eq 'powershell' (Resolve-TaskScaffold -Prompt 'A PowerShell automation that builds with dotnet.' -HasProject $false -Surface 'unknown') 'OM5 [kill] unknown surface + "dotnet" CLI mention -> powershell (heuristic over-match guard intact on the fall-back path)'
Assert-Eq 'powershell' (Resolve-TaskScaffold -Prompt 'A PowerShell script that downloads from example.net hourly.' -HasProject $false) 'OM6 [kill] no surface + ".net" TLD -> powershell (anchored .NET token still holds; not regressed)'

# ----------------------------------------------------------------------------
Section 'Wiring: the surface/language_hint flow end to end (queue -> run-fleet -> new-agent-task -> Resolve-TaskScaffold)'
$lib = Get-Content "$PSScriptRoot\fleet-lib.ps1" -Raw
Assert-True ([regex]::IsMatch($lib, '(?m)^\s*function\s+Resolve-BuildProfile\b')) 'W1 fleet-lib defines Resolve-BuildProfile'
Assert-True ([regex]::IsMatch($lib, '(?m)^\s*function\s+Resolve-TaskScaffold\b')) 'W2 fleet-lib defines Resolve-TaskScaffold'
# Resolve-TaskScaffold must accept -Surface and actually consult Resolve-BuildProfile.
Assert-True ([regex]::IsMatch($lib, '(?ms)function\s+Resolve-TaskScaffold\b.*?\[string\]\$Surface'))           'W3 Resolve-TaskScaffold accepts a -Surface parameter'
Assert-True ([regex]::IsMatch($lib, '(?ms)function\s+Resolve-TaskScaffold\b.*?Resolve-BuildProfile\s+-Surface')) 'W4 Resolve-TaskScaffold consults Resolve-BuildProfile when a surface is set'

$nat = Get-Content "$PSScriptRoot\new-agent-task.ps1" -Raw
Assert-True ([regex]::IsMatch($nat, '(?m)^\s*\[string\]\$Surface'))      'W5 new-agent-task accepts a -Surface parameter'
Assert-True ([regex]::IsMatch($nat, '(?m)^\s*\[string\]\$LanguageHint')) 'W6 new-agent-task accepts a -LanguageHint parameter'
# The surface must reach Resolve-TaskScaffold (else the consumer is dormant on the real run path).
Assert-True ([regex]::IsMatch($nat, 'Resolve-TaskScaffold\b[^\r\n]*-Surface\s+\$Surface')) 'W7 [kill] new-agent-task PASSES -Surface into Resolve-TaskScaffold (the seed actually routes)'
Assert-True ([regex]::IsMatch($nat, 'Resolve-BuildProfile\s+-Surface\s+\$Surface'))        'W8 new-agent-task resolves the profile to obtain the structural contract'

$runFleet = Get-Content "$PSScriptRoot\run-fleet.ps1" -Raw
Assert-True ([regex]::IsMatch($runFleet, '\$params\.Surface\s*=\s*\$t\.surface'))             'W9 [kill] run-fleet FORWARDS a queued task''s surface to new-agent-task (else the feature is dormant on the overnight path)'
Assert-True ([regex]::IsMatch($runFleet, '\$params\.LanguageHint\s*=\s*\$t\.language_hint')) 'W10 run-fleet forwards a queued task''s language_hint'

$addTask = Get-Content "$PSScriptRoot\add-fleet-task.ps1" -Raw
Assert-True ([regex]::IsMatch($addTask, '\[ValidateSet\([^)]*\bdesktop-gui\b[^)]*\)\]\[string\]\$Surface')) 'W11 add-fleet-task accepts a VALIDATED -Surface (mirrors the -Complexity ValidateSet)'
Assert-True ([regex]::IsMatch($addTask, '\[ValidateSet\([^)]*\bweb-static\b[^)]*\)\]\[string\]\$Surface')) 'W11b [#886] the -Surface ValidateSet includes web-static (the manual CLI can express the surface the refiner produces; N1 cohesion)'
Assert-True ([regex]::IsMatch($addTask, '\$item\.surface\s*=\s*\$Surface'))                                 'W12 [kill] add-fleet-task persists the surface into the queued task'
Assert-True ([regex]::IsMatch($addTask, '\$item\.language_hint\s*=\s*\$LanguageHint'))                       'W13 add-fleet-task persists the language_hint into the queued task'

# ----------------------------------------------------------------------------
Section 'End-to-end wiring proof: add-fleet-task writes a surface the queue carries (real file round-trip)'
$tmpQ = Join-Path ([System.IO.Path]::GetTempPath()) ("fleet-bp-queue-{0}.json" -f ([guid]::NewGuid().ToString('N')))
$tmpRepo = Join-Path ([System.IO.Path]::GetTempPath()) ("fleet-bp-repo-{0}" -f ([guid]::NewGuid().ToString('N')))
New-Item -ItemType Directory -Force $tmpRepo | Out-Null
New-Item -ItemType Directory -Force (Join-Path $tmpRepo '.git') | Out-Null   # satisfy the add-task git presence note
try {
    & "$PSScriptRoot\add-fleet-task.ps1" -Repo $tmpRepo -Task 'bp-roundtrip' -Prompt 'a rocket calculator' -Surface 'desktop-gui' -Complexity 'moderate' -Queue $tmpQ 2>&1 | Out-Null
    $q = @(Get-Content $tmpQ -Raw -Encoding UTF8 | ConvertFrom-Json)
    Assert-Eq 'desktop-gui' ([string]$q[0].surface)    'E1 the surface lands in the queued task JSON (add-fleet-task -> queue)'
    Assert-Eq 'moderate'    ([string]$q[0].complexity) 'E2 complexity still co-exists in the same queued task (no regression to the existing field)'
    # And the queue's surface re-resolves to the right scaffold (proves the field the queue carries is the field run-fleet forwards):
    Assert-Eq 'winui' (Resolve-BuildProfile -Surface ([string]$q[0].surface)).scaffold 'E3 the queued surface re-resolves to the winui scaffold (the value run-fleet forwards is actionable)'
} finally {
    Remove-Item $tmpQ -Force -ErrorAction SilentlyContinue
    Remove-Item -Recurse -Force $tmpRepo -ErrorAction SilentlyContinue
}

# ----------------------------------------------------------------------------
# INCREMENT-3 (#676; dead-button fix 2026-06-24): the STAGED prompt. Add-StagedHint injects the
# "(1) implement the core + RUN the tests via --test, (2) WIRE the UI, (3) THEN theme the shell"
# instruction ONLY for a staged surface (the BuildProfile's staged flag, set for winui/desktop-gui). Gated +
# strictly additive: a non-staged surface gets the prompt back verbatim.
Section 'Unit tests: Add-StagedHint (the staged core-then-shell instruction)'
$base = 'Build a calculator that looks like a rocket.'
$hinted = Add-StagedHint -Prompt $base -Staged $true
Assert-True ($hinted -ne $base)                'SH1 a STAGED surface ($Staged $true) appends the staging instruction (prompt changes)'
Assert-True ($hinted.StartsWith($base))        'SH2 the original prompt is preserved verbatim at the head (appended, never replaces)'
Assert-True ($hinted -match '(?i)STAGED BUILD') 'SH3 the appended block is labelled a STAGED BUILD'
# The two ORDERED stages are both present and in order (core/tests FIRST, theme the shell SECOND).
Assert-True ($hinted -match '(?i)\(1\)[^\r\n]*Calculator core') 'SH4 stage (1) tells the coder to implement the Calculator core'
Assert-True ($hinted -match '(?i)\(1\)[^\r\n]*tests in `?Tests') 'SH4b stage (1) tells the coder to EXTEND the tests in Tests/'
Assert-True ($hinted -match '(?i)\(3\)[^\r\n]*theme')           'SH5 stage (3) tells the coder to THEME the shell'
Assert-True ($hinted -match '(?i)\(2\)[^\r\n]*WIRE')            'SH5b [kill] stage (2) tells the coder to WIRE every button to the core (the dead-button fix, 2026-06-24)'
# CRUCIAL anti-patterns (the parked-run failure): no second project, no test-framework package.
Assert-True ($hinted -match '(?i)NOT add a second')            'SH6 [kill] the staged hint forbids a second project (the proliferation the run hit)'
Assert-True ($hinted -match '(?i)test-framework package')      'SH7 [kill] the staged hint forbids a test-framework package (the MSTest CS0246 the run hit)'
# The #676 no-execute ban is REPLACED by a SAFE run-and-iterate loop (dead-button fix, 2026-06-24): the coder
# RUNS the offline tests via the self-terminating --test entry, but STILL must not launch the GUI (the hang guard).
Assert-True ($hinted -match '(?i)dotnet run -- --test')        'SH7b [kill] the staged hint tells the coder to RUN the tests via the self-terminating --test entry (the feedback loop the no-wired-keypad run lacked)'
Assert-True ($hinted -match '(?i)NOT use [^\r\n]*dotnet test') 'SH7c [kill] the staged hint STILL forbids launching the GUI (no dotnet test / bare dotnet run -- the #676 hang guard survives)'
Assert-True ($hinted -match '(?i)already build')                     'SH8 the staged hint states the Tests/ already build (so EXTEND, do not re-author)'
# Gating: a NON-staged surface gets the prompt back UNCHANGED (strictly additive).
Assert-Eq $base (Add-StagedHint -Prompt $base -Staged $false) 'SH9 [kill] a NON-staged surface ($Staged $false) -> prompt returned VERBATIM (no staged hint)'

Section 'Unit tests: the staged hint is driven by the PROFILE''s staged flag (end to end, no model)'
# Drive the REAL gating exactly as new-agent-task does: resolve a profile, then pass its .staged into
# Add-StagedHint. A staged surface (desktop-gui) MUST get the hint; a non-staged one (web) MUST NOT.
$desktopStaged = (Resolve-BuildProfile -Surface 'desktop-gui').staged
$webStaged      = (Resolve-BuildProfile -Surface 'web').staged
$pDesktop = Add-StagedHint -Prompt $base -Staged ([bool]$desktopStaged)
$pWeb     = Add-StagedHint -Prompt $base -Staged ([bool]$webStaged)
Assert-True ($pDesktop -match '(?i)STAGED BUILD') 'SH10 [kill] a desktop-gui profile (staged $true) -> the coder prompt CONTAINS the staged instruction'
Assert-Eq $base $pWeb                             'SH11 [kill] a web profile (staged $false) -> the coder prompt gets NO staged instruction (ONLY staged surfaces are staged)'

Section 'Wiring: new-agent-task injects the staged hint, gated on the profile''s staged flag'
$natS = Get-Content "$PSScriptRoot\new-agent-task.ps1" -Raw
$libS = Get-Content "$PSScriptRoot\fleet-lib.ps1" -Raw
Assert-True ([regex]::IsMatch($libS, '(?m)^\s*function\s+Add-StagedHint\b')) 'W14 fleet-lib defines Add-StagedHint (pure -> unit-testable without a model)'
# [kill] new-agent-task must actually CALL Add-StagedHint with the profile's staged flag (else dormant on the real run).
Assert-True ([regex]::IsMatch($natS, 'Add-StagedHint\s+-Prompt\s+\$Prompt\s+-Staged\s+\(\[bool\]\$buildProfile\.staged\)')) 'W15 [kill] new-agent-task calls Add-StagedHint gated on $buildProfile.staged (the hint reaches the coder ONLY for a staged surface)'
# [kill] the staged hint must be applied to $Prompt (persists across resamples, like the complexity hint),
# and must come AFTER the complexity hint (the brief's order: after the complexity hint).
$iComplexity = $natS.IndexOf('Add-ComplexityHint -Prompt $Prompt')
$iStaged     = $natS.IndexOf('Add-StagedHint -Prompt $Prompt')
Assert-True (($iComplexity -gt 0) -and ($iStaged -gt 0) -and ($iComplexity -lt $iStaged)) 'W16 [kill] the staged hint is injected AFTER the complexity hint (and both mutate $Prompt above the resample loop, so a reset-to-base resample keeps them)'

# ----------------------------------------------------------------------------
# F3 (#670, 2026-06-30): the OFFLINE-WEB prompt. Add-WebHint injects the "extend the seeded offline
# Node skeleton; NO external URL (inline SVG / data: URI); test on an EPHEMERAL port, never a hardcoded
# unstarted one" instruction ONLY for a `web` scaffold. The live failure pulled a placehold.co CDN image
# and fetched an unstarted http://localhost:8081 -> "fetch failed" -> nothing merged. Gated + strictly
# additive: a non-web task gets the prompt back verbatim.
Section 'Unit tests: Add-WebHint (the offline-web instruction)'
$wbase = 'Create a webpage with a cartoon elephant image and a Hello message.'
$whinted = Add-WebHint -Prompt $wbase -Web $true
Assert-True ($whinted -ne $wbase)                 'WH1 a web scaffold ($Web $true) appends the offline-web instruction (prompt changes)'
Assert-True ($whinted.StartsWith($wbase))         'WH2 the original prompt is preserved verbatim at the head (appended, never replaces)'
Assert-True ($whinted -match '(?i)OFFLINE WEB BUILD') 'WH3 the appended block is labelled an OFFLINE WEB BUILD'
Assert-True ($whinted -match '(?i)NEVER reference an external URL') 'WH4 [kill] the hint forbids an external URL/CDN (the placehold.co failure)'
Assert-True ($whinted -match '(?i)inline\s+.?<svg' -or $whinted -match '(?i)data:.{0,3}URI') 'WH5 [kill] the hint steers images to inline SVG / data: URI (offline-safe assets)'
Assert-True ($whinted -match '(?i)server\.listen\(0' -or $whinted -match '(?i)EPHEMERAL port') 'WH6 [kill] the hint tells the coder to test on an EPHEMERAL port (the seed pattern), not a hardcoded one'
Assert-True ($whinted -match '(?i)NEVER `?fetch`? a hardcoded port') 'WH7 [kill] the hint forbids fetching a hardcoded port the test did not start (the localhost:8081 failure)'
Assert-True ($whinted -match '(?i)EXTEND it')      'WH8 the hint says EXTEND the seeded skeleton (do not re-scaffold)'
Assert-True ($whinted -match '(?i)ACT FIRST' -or $whinted -match '(?i)FIRST tool call should be an EDIT') 'WH8b [kill] the hint pushes ACT-FIRST (edit before exploratory reads -- the F2 stall mitigation, LESSONS Exp 3)'

# THE FRONT DOOR (#1367, 2026-08-14). Measured live: B9 delivered six pages and the operator
# opened the site to `<h1>App</h1>`. `public/index.html` was the scaffold placeholder, untouched
# by all seven tasks, and `src/server.js` mounts `/` to it -- so the front door reached nothing
# the coder had built. The cause was three surfaces disagreeing: the seed brief said "edit
# public/index.html", the decomposer asked for a task named `create-home-page` and named no file,
# and the coder reasonably created `home.html`. The delivered pages then split their navigation --
# the shared header linked `home.html` while three pages linked `index.html`.
#
# link_lint's `entry-reaches-nothing` (BlarAI, #1367) DETECTS the result. These assertions cover
# the CAUSE: the brief must state the entry-point contract so the coder builds the front door
# rather than a sibling nobody reaches. A detector without this reports the same defect nightly.
Assert-True ($whinted -match '(?i)FRONT DOOR') 'WH8c the hint names the FRONT DOOR contract'
Assert-True ($whinted -match '(?i)visitor\s+GETS\s+AT\s+`?/`?' -or $whinted -match '(?i)page a visitor (gets|lands)') 'WH8d [kill] it says index.html is what a visitor reaches at the site root'
Assert-True ($whinted -match '(?i)THAT PAGE IS `public/index\.html`') 'WH8e [kill] a home/landing page must BE index.html (the create-home-page -> home.html failure)'
Assert-True ($whinted -match '(?i)home\.html' -and $whinted -match '(?i)do NOT create a second home page') 'WH8f [kill] it forbids a second home page BY NAME (home.html/main.html/landing.html)'
Assert-True ($whinted -match '(?i)must LINK to each') 'WH8g [kill] every sibling page must be linked FROM index.html (nothing reaches an unlinked page)'
Assert-True ($whinted -match '(?i)"home" link points at `index\.html`' -or $whinted -match '(?i)One home page, one name') 'WH8h [kill] a shared header links home at index.html (the split-navigation half of #1367)'
Assert-True ($whinted -match '(?i)Never leave the seed.s placeholder') 'WH8i [kill] the delivered index.html must not still be the placeholder'

# THE SERVED ROOT (#1375, 2026-08-14). The operator opened pieces.html and read "Failed to load
# pieces." Both central pages ran `fetch('./data/pieces.json')` while the file sat at the PROJECT
# ROOT, a sibling of `public/` -- and `src/server.js` serves `public/` and nothing else, so the
# browser got a 404. Every instrument that touched that data read it FROM DISK; nothing ever
# fetched it the way a visitor does, so the file existed and was never served.
#
# link_lint's `extract_fetch_targets` (BlarAI, #1375) now RESOLVES fetch() string literals and
# catches the result. These assertions cover the CAUSE: before this, the brief said nothing
# whatsoever about where a data file must live -- measured, zero mentions of `data/`.
Assert-True ($whinted -match '(?i)SERVED ROOT') 'WH8j the hint names the SERVED ROOT contract'
Assert-True ($whinted -match '(?i)serves `?public/`? AND NOTHING ELSE') 'WH8k [kill] it states only public/ is served (a file outside it is a 404)'
Assert-True ($whinted -match '(?i)public/data/') 'WH8l [kill] it says a shared data file belongs at public/data/ (the pieces.json failure)'
Assert-True ($whinted -match '(?i)after writing any `?fetch') 'WH8m [kill] it tells the coder to check every fetch path resolves from public/'
Assert-True ($whinted -match '(?i)Failed to load') 'WH8n [kill] a page whose normal state is an error string counts as BROKEN (the exact words he read)'
# Gating: a NON-web scaffold gets the prompt back UNCHANGED (strictly additive -- the byte-identical kill).
Assert-Eq $wbase (Add-WebHint -Prompt $wbase -Web $false) 'WH9 [kill] a NON-web scaffold ($Web $false) -> prompt returned VERBATIM (no web hint; non-web profiles are byte-identical)'

Section 'Unit tests: Test-WebBuild -- the hint reaches tasks 2..N of a multi-page build (#1367/#1375)'
# THE DEFECT, measured 2026-08-14. Add-WebHint was gated on `$scaffold -eq 'web'`. `$scaffold` comes
# from Resolve-TaskScaffold, whose FIRST line is `if ($HasProject) { return '' }` -- correct, because
# its job is deciding what to SEED and it must not clobber an existing project. But used as a proxy
# for "is this a web build" it silences the brief for every task after the seed.
#
# B9 authors SEVEN tasks. One dispatch got the web brief; six did not. Measured across every banked
# agent log in state/reports: exactly ONE contains "OFFLINE WEB BUILD", a 2026-07-27 single-task job,
# and NO B9 coder has ever seen it. That is upstream of both operator-found defects -- the coder that
# built `home.html` had never been told what a visitor reaches (#1367), and the one that fetched a
# file from outside `public/` had never been told what the server serves (#1375).
$__wbRoot = Join-Path ([IO.Path]::GetTempPath()) ("webbuild-" + [guid]::NewGuid().ToString('N').Substring(0,8))
New-Item -ItemType Directory -Force (Join-Path $__wbRoot 'public') | Out-Null
New-Item -ItemType Directory -Force (Join-Path $__wbRoot 'src') | Out-Null
Set-Content -LiteralPath (Join-Path $__wbRoot 'src/server.js') -Value '// seed server' -Encoding utf8
$__wbBare = Join-Path ([IO.Path]::GetTempPath()) ("webbuild-bare-" + [guid]::NewGuid().ToString('N').Substring(0,8))
New-Item -ItemType Directory -Force $__wbBare | Out-Null
try {
    Assert-True (Test-WebBuild -Scaffold 'web')                        'WB1 a fresh dispatch that seeds the web scaffold is a web build (today''s signal, preserved)'
    Assert-True (Test-WebBuild -Surface 'web')                         'WB2 a declared web SURFACE is a web build even with no scaffold (the HasProject case)'
    Assert-True (Test-WebBuild -ProjectRoot $__wbRoot)                 'WB3 [kill] an ALREADY-SEEDED web tree (public/ + src/server.js) is a web build -- the six silent B9 tasks'
    Assert-True (-not (Test-WebBuild))                                 'WB4 [kill] no scaffold, no surface, no tree -> NOT a web build'
    Assert-True (-not (Test-WebBuild -Scaffold 'python' -Surface 'library' -ProjectRoot $__wbBare)) 'WB5 [kill] a python task in a bare tree is NOT a web build (strictly additive)'
    Assert-True (-not (Test-WebBuild -ProjectRoot $__wbBare))          'WB6 [kill] a tree with NEITHER marker is not a web build'
    # BOTH markers required, so an ordinary project with a public/ folder cannot collect web
    # instructions it cannot act on.
    $__wbPubOnly = Join-Path ([IO.Path]::GetTempPath()) ("webbuild-pub-" + [guid]::NewGuid().ToString('N').Substring(0,8))
    New-Item -ItemType Directory -Force (Join-Path $__wbPubOnly 'public') | Out-Null
    Assert-True (-not (Test-WebBuild -ProjectRoot $__wbPubOnly))       'WB7 [kill] public/ ALONE is not enough (a docs site, a dotnet wwwroot -- no web brief)'
    Remove-Item $__wbPubOnly -Recurse -Force -ErrorAction SilentlyContinue
    $__wbSrvOnly = Join-Path ([IO.Path]::GetTempPath()) ("webbuild-srv-" + [guid]::NewGuid().ToString('N').Substring(0,8))
    New-Item -ItemType Directory -Force (Join-Path $__wbSrvOnly 'src') | Out-Null
    Set-Content -LiteralPath (Join-Path $__wbSrvOnly 'src/server.js') -Value '//' -Encoding utf8
    Assert-True (-not (Test-WebBuild -ProjectRoot $__wbSrvOnly))       'WB8 [kill] src/server.js ALONE is not enough (a bare node service)'
    Remove-Item $__wbSrvOnly -Recurse -Force -ErrorAction SilentlyContinue

    # THE REGRESSION THIS EXISTS FOR, end to end: the same task, once fresh and once into a seeded
    # tree, must BOTH receive the brief. Under the old gate the second returned the prompt verbatim.
    $__g = 'Create the home page for the pottery studio site'
    $__sFresh = Resolve-TaskScaffold -Prompt $__g -HasProject $false -Surface 'web'
    $__sAfter = Resolve-TaskScaffold -Prompt $__g -HasProject $true  -Surface 'web'
    Assert-Eq 'web' $__sFresh 'WB9 the seeding dispatch resolves the web scaffold'
    Assert-Eq ''    $__sAfter 'WB10 a later task resolves NO scaffold (correct: never clobber an existing project)'
    Assert-True ((Add-WebHint -Prompt $__g -Web (Test-WebBuild -Scaffold $__sFresh -Surface 'web' -ProjectRoot $__wbRoot)) -match '(?i)OFFLINE WEB BUILD') 'WB11 task 1 of a multi-page build receives the web brief'
    Assert-True ((Add-WebHint -Prompt $__g -Web (Test-WebBuild -Scaffold $__sAfter -Surface 'web' -ProjectRoot $__wbRoot)) -match '(?i)OFFLINE WEB BUILD') 'WB12 [kill] task 2..N receives it TOO -- the six-of-seven silence this fixes'
    # And the pre-fix gate demonstrably did NOT, so WB12 is not a pass that could never fail.
    Assert-Eq $__g (Add-WebHint -Prompt $__g -Web ([bool]($__sAfter -eq 'web'))) 'WB13 [control] the OLD gate ($scaffold -eq ''web'') returns task 2..N VERBATIM -- the defect is real'
} finally {
    Remove-Item $__wbRoot -Recurse -Force -ErrorAction SilentlyContinue
    Remove-Item $__wbBare -Recurse -Force -ErrorAction SilentlyContinue
}

Section 'Unit tests: Test-WebStaticBuild -- the SIBLING that shared the defect (lesson 342)'
# The reasoning that found the web defect is a PREDICATE, not an explanation of one site, so it
# was run over every hint new-agent-task injects. Five gate on something sound (the complexity
# signal, the build PROFILE computed straight from the surface, or the worktree). Exactly ONE
# shared it: Add-WebStaticHint was gated on `$scaffold -eq 'web-static'`. Latent rather than
# measured only because web-static has run once -- the mechanism is identical.
$__wsRoot = Join-Path ([IO.Path]::GetTempPath()) ("webstatic-" + [guid]::NewGuid().ToString('N').Substring(0,8))
New-Item -ItemType Directory -Force $__wsRoot | Out-Null
Set-Content -LiteralPath (Join-Path $__wsRoot 'index.html') -Value '<h1>seed</h1>' -Encoding utf8
$__wsServer = Join-Path ([IO.Path]::GetTempPath()) ("webstatic-srv-" + [guid]::NewGuid().ToString('N').Substring(0,8))
New-Item -ItemType Directory -Force (Join-Path $__wsServer 'public') | Out-Null
New-Item -ItemType Directory -Force (Join-Path $__wsServer 'src') | Out-Null
Set-Content -LiteralPath (Join-Path $__wsServer 'src/server.js') -Value '//' -Encoding utf8
Set-Content -LiteralPath (Join-Path $__wsServer 'index.html') -Value '<h1>x</h1>' -Encoding utf8
try {
    Assert-True (Test-WebStaticBuild -Scaffold 'web-static')          'WS1 a fresh dispatch that seeds web-static is a static build (today''s signal, preserved)'
    Assert-True (Test-WebStaticBuild -Surface 'web-static')           'WS2 a declared web-static SURFACE is a static build even with a project present'
    Assert-True (Test-WebStaticBuild -ProjectRoot $__wsRoot)          'WS3 [kill] an ALREADY-SEEDED static tree (root index.html, no package.json/server/public) is a static build'
    Assert-True (-not (Test-WebStaticBuild))                          'WS4 [kill] no scaffold, no surface, no tree -> not a static build'
    # MUTUAL EXCLUSION: the two seeds are opposite shapes and a tree must never claim both,
    # or a coder would be handed "extend the node skeleton" and "add no server" together.
    Assert-True (-not (Test-WebStaticBuild -ProjectRoot $__wsServer)) 'WS5 [kill] a SERVER tree (public/ + src/server.js) is NOT a static build even with a root index.html'
    Assert-True (Test-WebBuild -ProjectRoot $__wsServer)              'WS6 ...and that same tree IS a web build (the two signatures are mutually exclusive)'
    Assert-True (-not (Test-WebBuild -ProjectRoot $__wsRoot))         'WS7 [kill] ...and the static tree is NOT a web build (no false double-brief)'
    # The regression, end to end: task 2..N of a multi-task STATIC site.
    $__gs = 'Add the contact section to the page'
    $__ssAfter = Resolve-TaskScaffold -Prompt $__gs -HasProject $true -Surface 'web-static'
    Assert-Eq '' $__ssAfter 'WS8 a later static task resolves NO scaffold (correct seeding behaviour)'
    Assert-True ((Add-WebStaticHint -Prompt $__gs -WebStatic (Test-WebStaticBuild -Scaffold $__ssAfter -Surface 'web-static' -ProjectRoot $__wsRoot)) -match '(?i)STATIC') 'WS9 [kill] task 2..N of a static build receives the static brief'
    Assert-Eq $__gs (Add-WebStaticHint -Prompt $__gs -WebStatic ([bool]($__ssAfter -eq 'web-static'))) 'WS10 [control] the OLD gate returns task 2..N VERBATIM -- the sibling defect is real'
} finally {
    Remove-Item $__wsRoot -Recurse -Force -ErrorAction SilentlyContinue
    Remove-Item $__wsServer -Recurse -Force -ErrorAction SilentlyContinue
}

Section 'Wiring: new-agent-task gates the web hint on Test-WebBuild, not the seeding decision'
$__natSrc = Get-Content (Join-Path $PSScriptRoot 'new-agent-task.ps1') -Raw
Assert-True ($__natSrc -match 'Test-WebBuild\s+-Scaffold\s+\$scaffold\s+-Surface\s+\$Surface\s+-ProjectRoot\s+\$wt') 'WB14 [kill] new-agent-task calls Test-WebBuild with the worktree (else the tree signal is dormant)'
Assert-True ($__natSrc -notmatch 'Add-WebHint\s+-Prompt\s+\$Prompt\s+-Web\s+\(\[bool\]\(\$scaffold\s+-eq\s+''web''\)\)') 'WB15 [kill] the OLD seeding-decision gate is GONE from the call site'

Section 'Unit tests: the web hint is driven by the RESOLVED scaffold (end to end, no model)'
# Drive the REAL gating exactly as new-agent-task does: resolve the scaffold, then pass ($scaffold -eq 'web')
# into Add-WebHint. A webpage prompt (resolves to 'web', surface OR heuristic) MUST get the hint; a python one MUST NOT.
$webScaffold = Resolve-TaskScaffold -Prompt 'create a webpage with an image' -HasProject $false
$pyScaffold  = Resolve-TaskScaffold -Prompt 'Write a Python script that summarizes a CSV with pandas.' -HasProject $false
Assert-Eq 'web' $webScaffold   'WH10 a "webpage" prompt resolves to the web scaffold (heuristic path; no surface needed)'
Assert-Eq 'python' $pyScaffold 'WH11 a python prompt resolves to the python scaffold (the web hint must NOT fire)'
$pWebSc = Add-WebHint -Prompt $wbase -Web ([bool]($webScaffold -eq 'web'))
$pPySc  = Add-WebHint -Prompt $wbase -Web ([bool]($pyScaffold  -eq 'web'))
Assert-True ($pWebSc -match '(?i)OFFLINE WEB BUILD') 'WH12 [kill] a web scaffold -> the coder prompt CONTAINS the offline-web instruction'
Assert-Eq $wbase $pPySc                              'WH13 [kill] a python scaffold -> the coder prompt gets NO web instruction (ONLY a web scaffold is hinted)'
# Web surface PREEMPTS too: a 'web' surface gets the web scaffold and thus the hint.
Assert-Eq 'web' (Resolve-TaskScaffold -Prompt 'a thing' -HasProject $false -Surface 'web') 'WH14 the web SURFACE also resolves to the web scaffold (so the hint fires on the surface path)'

Section 'Wiring: new-agent-task injects the web hint, gated on the resolved scaffold'
$natW = Get-Content "$PSScriptRoot\new-agent-task.ps1" -Raw
$libW = Get-Content "$PSScriptRoot\fleet-lib.ps1" -Raw
Assert-True ([regex]::IsMatch($libW, '(?m)^\s*function\s+Add-WebHint\b')) 'W17 fleet-lib defines Add-WebHint (pure -> unit-testable without a model)'
# [kill] new-agent-task must CALL Add-WebHint gated on the resolved scaffold == 'web' (else dormant on the real run).
# W18 asserted the literal gate `-Web ([bool]($scaffold -eq 'web'))` and so PINNED THE DEFECT: any
# correct fix to the gate had to fail this check first. The property it was reaching for is that the
# hint is GATED at all -- never unconditional, never absent -- not which expression does the gating.
# Re-anchored 2026-08-14 (#1367/#1375); WB14/WB15 above assert the specific new call shape.
Assert-True ([regex]::IsMatch($natW, 'Add-WebHint\s+-Prompt\s+\$Prompt\s+-Web\s+\S')) 'W18 [kill] new-agent-task calls Add-WebHint with a GATE (never unconditional)'
Assert-True (-not [regex]::IsMatch($natW, 'Add-WebHint\s+-Prompt\s+\$Prompt\s+-Web\s+\$true')) 'W18b [kill] the gate is not hard-wired true (a non-web task must stay byte-identical)'
# [kill] the web hint is applied AFTER the staged hint (both mutate $Prompt above the resample loop).
$iStagedW = $natW.IndexOf('Add-StagedHint -Prompt $Prompt')
$iWebW    = $natW.IndexOf('Add-WebHint -Prompt $Prompt')
Assert-True (($iStagedW -gt 0) -and ($iWebW -gt 0) -and ($iStagedW -lt $iWebW)) 'W19 [kill] the web hint is injected AFTER the staged hint (and mutates $Prompt above the resample loop, so a reset-to-base resample keeps it)'

# ----------------------------------------------------------------------------
Section 'Result'
Write-Host ("  Passed:  {0}" -f $script:Pass) -ForegroundColor Green
if ($script:Fail) {
    Write-Host ("  Failed:  {0}" -f $script:Fail) -ForegroundColor Red
    Write-Host ''
    Write-Host '  BUILD PROFILE: NOT VALIDATED - see the [FAIL] lines above:' -ForegroundColor Red
    $script:Failures | ForEach-Object { Write-Host "    - $_" -ForegroundColor Red }
    exit 1
} else {
    Write-Host ''
    Write-Host '  BUILD PROFILE: VALIDATED. A coarse upstream surface label maps to the curated scaffold + structural contract; it PREEMPTS the keyword heuristic only when KNOWN; unknown/absent falls through to today''s behaviour UNCHANGED (no over-match resurrected).' -ForegroundColor Green
    exit 0
}
