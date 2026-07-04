#requires -Version 5.1
<#
.SYNOPSIS
  Verify and validate the fleet's ECOSYSTEM-ADHERENCE capability (#670).

.DESCRIPTION
  Background (plain English):
    The fleet dispatches a coding task to a small local model in an isolated worktree, then a
    DETERMINISTIC gate (verify-project.ps1) decides the auto-merge. The first live dispatch wrote
    the solution in JavaScript into a Python repo and nearly merged it: the coder had no language
    constraint, and the gate's checks were all keyed off manifests that already existed, so a
    foreign-language deliverable was checked by nothing. Two fixes close that hole:

      A1  new-agent-task.ps1 PREPENDS a hard "TARGET LANGUAGE" constraint (built from the project's
          declared ecosystem) to the coder's prompt, so a language-neutral task cannot drift to a
          foreign language.
      A2  verify-project.ps1 adds an eco:language check: it diffs the task's changed files, maps
          them to languages, and FAILS when the deliverable is ENTIRELY foreign to the project's
          declared ecosystem - flipping overall to 'fail' and blocking the merge independently of
          the LLM review.

    Both share one detector, Get-ProjectEcosystem (manifest -> declared ecosystem). The decision is
    the pure Test-LanguageAdherence; the file->language mapping is Get-ChangedLanguages; the prompt
    text is Get-LanguageConstraint. All four live in fleet-lib.ps1.

  This script proves the behaviour with NO model and NO OVMS, three ways:

    1. UNIT TESTS - drive the REAL pure functions with deterministic inputs and check the decision,
       the language mapping, and the constraint text EXACTLY. Mutation-resistant: each case is built
       to kill a specific wrong implementation (e.g. "ANY foreign -> fail" instead of "ALL foreign").

    2. INTEGRATION - build throwaway git repos on disk and run the REAL verify-project.ps1 end to
       end (no model), asserting the eco:language verdict. This catches wiring regressions the pure
       units cannot - e.g. a broken post-commit manifest read, or forgetting to pass -BaseBranch.

    3. WIRING - assert (by regex over the production scripts) that the runner and the gate actually
       INVOKE these functions on real, non-comment lines - mirroring verify-retry.ps1's U9/V10.

  Exit code is 0 if everything passed, 1 if any check failed. Run it normally
  ( .\verify-ecosystem.ps1 ) - do NOT dot-source it. No network; safe to run any time.
#>
param()
$ErrorActionPreference = 'Stop'
. "$PSScriptRoot\fleet-lib.ps1"

# ----------------------------------------------------------------------------
# Tiny zero-dependency test framework (same shape as verify-retry.ps1 - no Pester, offline forever)
# ----------------------------------------------------------------------------
$script:Pass = 0
$script:Fail = 0
$script:Inconclusive = 0
$script:Failures = New-Object System.Collections.ArrayList

function Section($t) { Write-Host ''; Write-Host "== $t ==" -ForegroundColor Cyan }
function _pass($m)   { $script:Pass++; Write-Host "  [PASS] $m" -ForegroundColor Green }
function _fail($m)   { $script:Fail++; [void]$script:Failures.Add($m); Write-Host "  [FAIL] $m" -ForegroundColor Red }
function _inconc($m) { $script:Inconclusive++; Write-Host "  [INCONCLUSIVE] $m" -ForegroundColor Yellow }

# Case-SENSITIVE exact match (so 'Pass' vs 'pass' would be caught - matches our "exact" claim).
function Assert-Eq($Expected, $Actual, $Msg) {
    if ([string]$Expected -ceq [string]$Actual) { _pass $Msg }
    else { _fail "$Msg (expected '$Expected', got '$Actual')" }
}
function Assert-True($Cond, $Msg) {
    if ($Cond) { _pass $Msg } else { _fail "$Msg (expected True, got False)" }
}
function Assert-Contains($Haystack, $Needle, $Msg) {
    if ($Haystack -and $Haystack.ToString().Contains($Needle)) { _pass $Msg }
    else { _fail "$Msg (did not find '$Needle')" }
}

# Convenience: run Get-ChangedLanguages / Get-ProjectEcosystem and return the sorted-unique set as a
# stable joined string so a single assertion pins BOTH membership and order.
function Langs($paths)  { (Get-ChangedLanguages $paths) -join ',' }

# ----------------------------------------------------------------------------
# UNIT TESTS - Get-ChangedLanguages (file paths -> code-language set)
# ----------------------------------------------------------------------------
Section 'Unit tests: Get-ChangedLanguages (path -> language set)'
Assert-Eq 'python' (Langs @('a.py'))                       'L1  .py -> python'
Assert-Eq 'python' (Langs @('stub.pyi'))                   'L2  .pyi -> python'
Assert-Eq 'python' (Langs @('A.PY'))                       'L3  uppercase .PY -> python (case-insensitive ext)'
Assert-Eq 'node'   (Langs @('a.js'))                       'L4a .js -> node'
Assert-Eq 'node'   (Langs @('a.jsx'))                      'L4b .jsx -> node'
Assert-Eq 'node'   (Langs @('a.ts'))                       'L4c .ts -> node (kills a map that drops .ts)'
Assert-Eq 'node'   (Langs @('a.tsx'))                      'L4d .tsx -> node'
Assert-Eq 'node'   (Langs @('a.mjs'))                      'L4e .mjs -> node'
Assert-Eq 'node'   (Langs @('a.cjs'))                      'L4f .cjs -> node'
Assert-Eq 'dotnet' (Langs @('a.cs'))                       'L5a .cs -> dotnet'
Assert-Eq 'dotnet' (Langs @('a.fs'))                       'L5b .fs -> dotnet'
Assert-Eq 'dotnet' (Langs @('a.vb'))                       'L5c .vb -> dotnet'
Assert-Eq 'node,python' (Langs @('a.py','b.js'))           'L6  mixed -> sorted-unique (node,python)'
Assert-Eq 'python'      (Langs @('a.py','b.py'))           'L7  duplicates collapse to one'
Assert-Eq 'dotnet,python' (Langs @('src/a.py','src\b.cs')) 'L8  mixed / and \ separators both parse'
Assert-Eq ''       (Langs @('README.md','x.toml','y.json','.gitignore','s.css')) 'L9  docs/config/assets -> empty (no false code)'
Assert-Eq ''       (Langs @('main.go','lib.rs','A.java','s.rb','run.sh','q.sql'))  'L10 non-declarable languages -> ignored (precision, not completeness)'
Assert-Eq ''       (Langs @('Makefile'))                   'L11 extensionless -> empty'
Assert-Eq ''       (Langs @())                             'L12 empty input -> empty'
Assert-Eq ''       (Langs $null)                           'L13 $null input -> empty (binding guard)'
# Array-return contract (the comma-idiom). A scalar-unwrap would make the single case a [string],
# not an [array]; -is [array] is the assertion that actually catches it ( @(...).Count cannot - it
# reports 1 for a scalar too ). Count is checked directly on the returned array.
Assert-True ((Get-ChangedLanguages @('a.py')) -is [array])  'L14a single result is an ARRAY, not a scalar (kills scalar-unwrap)'
Assert-Eq 1 ((Get-ChangedLanguages @('a.py')).Count)        'L14b single result has Count 1'
Assert-Eq 2 ((Get-ChangedLanguages @('a.py','b.js')).Count) 'L14c two results have Count 2'
Assert-True ((Get-ChangedLanguages @()) -is [array])        'L15a empty result is still an ARRAY (never $null)'
Assert-Eq 0 ((Get-ChangedLanguages @()).Count)              'L15b empty result has Count 0'

# ----------------------------------------------------------------------------
# UNIT TESTS - Test-LanguageAdherence (the decision; each case kills a specific mutation)
# ----------------------------------------------------------------------------
Section 'Unit tests: Test-LanguageAdherence (declared x changed -> pass/fail/skip)'
function Dec($d, $c) { (Test-LanguageAdherence -DeclaredEcosystems $d -ChangedLanguages $c) }
Assert-Eq 'fail' (Dec @('python') @('node')).Status              'D1  python repo, JS deliverable -> fail (the #670 bug)'
Assert-Eq 'pass' (Dec @('python') @('python')).Status            'D2  python repo, python deliverable -> pass'
Assert-Eq 'pass' (Dec @('python','node') @('python','node')).Status 'D3  polyglot repo, polyglot deliverable -> pass'
Assert-Eq 'pass' (Dec @('python','node') @('node')).Status       'D4  repo declares node (added package.json) -> pass'
Assert-Eq 'pass' (Dec @('python') @('python','node')).Status     'D5  python + stray JS -> pass (kills "ANY foreign -> fail"; only ALL-foreign fails)'
Assert-Eq 'skip' (Dec @() @('node')).Status                      'D6  no manifest at all -> skip (backward-compat)'
Assert-Eq 'skip' (Dec @('python') @()).Status                    'D7  doc/config-only change -> skip (no false-fail)'
Assert-Eq 'skip' (Dec @() @()).Status                            'D8  nothing declared, nothing changed -> skip'
Assert-Eq 'fail' (Dec @('python') @('dotnet')).Status            'D9  python repo, C# deliverable -> fail (fail path not over-fit to node)'
Assert-Eq 'fail' (Dec @('dotnet') @('node')).Status              'D10 dotnet repo, JS deliverable -> fail'
Assert-Eq 'fail' (Dec @('node') @('python')).Status              'D11 node repo, python deliverable -> fail (symmetry)'
Assert-Contains (Dec @('python') @('node')).Reason 'node'        'D12 fail Reason names the offending language (not blank)'
Assert-Contains (Dec @('python') @('node')).Reason 'python'      'D13 fail Reason names the declared ecosystem'

# ----------------------------------------------------------------------------
# UNIT TESTS - Get-LanguageConstraint (A1 prompt text)
# ----------------------------------------------------------------------------
Section 'Unit tests: Get-LanguageConstraint (A1 prompt prefix)'
Assert-Eq '' (Get-LanguageConstraint -Ecosystems @())               'C1  empty ecosystem -> empty constraint (current behavior)'
$cp = Get-LanguageConstraint -Ecosystems @('python')
Assert-Contains $cp 'Python'      'C2a python constraint names Python'
Assert-Contains $cp 'test_*.py'   'C2b python constraint asks for a pytest test'
Assert-Contains $cp 'Do NOT'      'C2c python constraint forbids other languages'
Assert-Contains (Get-LanguageConstraint -Ecosystems @('node'))   'TypeScript' 'C3  node constraint names TypeScript/JavaScript'
Assert-Contains (Get-LanguageConstraint -Ecosystems @('dotnet')) 'C#'         'C4  dotnet constraint names C#'
$cpoly = Get-LanguageConstraint -Ecosystems @('node','python')
Assert-Contains $cpoly 'Python'                'C5a polyglot constraint names Python'
Assert-Contains $cpoly 'TypeScript/JavaScript' 'C5b polyglot constraint names TypeScript/JavaScript'
Assert-Contains $cpoly 'ONE of them'           'C5c polyglot constraint requires ONE of the declared languages'

# ----------------------------------------------------------------------------
# INTEGRATION - Get-ProjectEcosystem against real trees on disk (proves the recursion asymmetry)
# ----------------------------------------------------------------------------
Section 'Integration: Get-ProjectEcosystem (real manifest trees)'
$scratch = Join-Path $PSScriptRoot '..\state\test-scratch\eco'
try { if (Test-Path $scratch) { Remove-Item -Recurse -Force -LiteralPath $scratch -ErrorAction Stop } } catch {}
New-Item -ItemType Directory -Force $scratch | Out-Null
function New-Tree($name, [hashtable]$files) {
    $d = Join-Path $scratch $name
    foreach ($rel in $files.Keys) {
        $full = Join-Path $d $rel
        New-Item -ItemType Directory -Force (Split-Path $full -Parent) | Out-Null
        Set-Content -Path $full -Value $files[$rel] -Encoding ascii
    }
    return $d
}
$tPy   = New-Tree 'py'   @{ 'pyproject.toml' = "[project]"; 'mod.py' = "x=1" }
$tNode = New-Tree 'node' @{ 'package.json'   = '{}' }
# dotnet declared by a NESTED csproj only; a NESTED pyproject.toml must NOT mark python (top-level only)
$tNest = New-Tree 'nest' @{ 'sub\app.csproj' = '<Project/>'; 'sub\pyproject.toml' = "[project]" }
$tPoly = New-Tree 'poly' @{ 'pyproject.toml' = "[project]"; 'package.json' = '{}' }
$tNone = New-Tree 'none' @{ 'README.md' = "hi"; 'main.go' = "package main" }
Assert-Eq 'python'             ((Get-ProjectEcosystem $tPy)   -join ',') 'E1  top-level pyproject.toml -> python'
Assert-Eq 'node'               ((Get-ProjectEcosystem $tNode) -join ',') 'E2  top-level package.json -> node'
Assert-Eq 'dotnet'             ((Get-ProjectEcosystem $tNest) -join ',') 'E3  NESTED .csproj -> dotnet; NESTED pyproject ignored (top-level only)'
Assert-Eq 'node,python'        ((Get-ProjectEcosystem $tPoly) -join ',') 'E4  polyglot manifests -> sorted-unique set'
Assert-Eq ''                   ((Get-ProjectEcosystem $tNone) -join ',') 'E5  no manifest (.md + .go) -> empty set'
Assert-True ((Get-ProjectEcosystem $tNone) -is [array]) 'E6  empty ecosystem is still an ARRAY (comma-return contract, never $null)'
Assert-True ((Get-ProjectEcosystem $tPy)   -is [array]) 'E7  single ecosystem is an ARRAY, not a scalar'

# ----------------------------------------------------------------------------
# INTEGRATION - the REAL verify-project.ps1 eco:language gate end to end (git repos, NO model)
# ----------------------------------------------------------------------------
Section 'Integration: eco:language gate via the real verify-project.ps1 (no model)'
$VP = Join-Path $PSScriptRoot 'verify-project.ps1'
function New-GitRepo($name, [hashtable]$baseline, [hashtable]$deliver, $headEqualsBase = $false) {
    # Build a repo: baseline commit on main; then (unless headEqualsBase) an agent branch with the
    # deliverable committed. Returns the worktree path to hand to verify-project.ps1.
    # NOTE (PS 5.1): 'git checkout' writes progress to STDERR, which under Windows PowerShell 5.1 with
    # EAP=Stop becomes a FATAL NativeCommandError EVEN WITH 2>$null / *>$null (verified on this box).
    # The only reliable suppression is EAP=Continue - function-scoped here, exactly as the production
    # runner new-agent-task.ps1 does and why it sets EAP=Continue for its git calls. (verify-project's
    # own git calls stay safe under EAP=Stop only because rev-parse --quiet / diff / ls-files emit no
    # stderr.) Without this the whole integration tier silently never runs under 5.1.
    $ErrorActionPreference = 'Continue'
    $r = Join-Path $scratch $name
    New-Item -ItemType Directory -Force $r | Out-Null
    git -C $r init -b main 2>$null | Out-Null
    foreach ($rel in $baseline.Keys) {
        $full = Join-Path $r $rel; New-Item -ItemType Directory -Force (Split-Path $full -Parent) | Out-Null
        Set-Content -Path $full -Value $baseline[$rel] -Encoding ascii
    }
    git -C $r add -A 2>$null | Out-Null
    git -C $r -c user.email='t@local' -c user.name='t' commit -m base 2>$null | Out-Null
    if (-not $headEqualsBase) { git -C $r checkout -b agent/x 2>$null | Out-Null }
    foreach ($rel in $deliver.Keys) {
        $full = Join-Path $r $rel; New-Item -ItemType Directory -Force (Split-Path $full -Parent) | Out-Null
        Set-Content -Path $full -Value $deliver[$rel] -Encoding ascii
    }
    if ($deliver.Keys.Count) {
        git -C $r add -A 2>$null | Out-Null
        git -C $r -c user.email='t@local' -c user.name='t' commit -m deliver 2>$null | Out-Null
    }
    return $r
}
function EcoStatus($repo, $withBase = $true) {
    $v = if ($withBase) { & $VP -Path $repo -BaseBranch main -Json | ConvertFrom-Json }
         else           { & $VP -Path $repo -Json | ConvertFrom-Json }
    $e = @($v.checks | Where-Object { $_.name -eq 'eco:language' })
    if ($e.Count) { return $e[0].status } else { return '(none)' }
}
function EcoAndOverall($repo) {
    $v = & $VP -Path $repo -BaseBranch main -Json | ConvertFrom-Json
    $e = @($v.checks | Where-Object { $_.name -eq 'eco:language' })
    [pscustomobject]@{ eco = $(if ($e.Count) { $e[0].status } else { '(none)' }); overall = $v.overall }
}
try {
    # G1: the live #670 shape - JS (+ a JS test) committed into a Python repo -> fail, and overall fail.
    $g1 = New-GitRepo 'g1_js_in_py' @{ 'pyproject.toml' = "[project]"; 'leap_year.py' = "def leap(y): return y%4==0" } `
                                    @{ 'palindrome.js' = "function p(s){return true}"; 'test_palindrome.js' = "//t" }
    $r1 = EcoAndOverall $g1
    Assert-Eq 'fail' $r1.eco     'G1a JS-in-Python deliverable -> eco:language fail'
    Assert-Eq 'fail' $r1.overall 'G1b ... and that flips overall to fail (blocks the merge)'

    # G2: the task commits package.json WITH the .js together -> node is declared post-commit -> pass.
    #     Guards a regression in the POST-COMMIT manifest read that the pure unit cannot catch.
    $g2 = New-GitRepo 'g2_js_with_manifest' @{ 'README.md' = "x" } `
                                            @{ 'package.json' = '{"name":"x"}'; 'index.js' = "module.exports=1" }
    Assert-Eq 'pass' (EcoStatus $g2) 'G2  task adds package.json + .js together -> eco:language pass (manifest added)'

    # G3: correct Python deliverable -> pass.
    $g3 = New-GitRepo 'g3_py' @{ 'pyproject.toml' = "[project]" } `
                              @{ 'solution.py' = "def is_pal(s): return s==s[::-1]"; 'test_solution.py' = "def test(): assert True" }
    Assert-Eq 'pass' (EcoStatus $g3) 'G3  correct Python deliverable -> eco:language pass'

    # G4: doc-only change -> skip (no false-fail).
    $g4 = New-GitRepo 'g4_doc' @{ 'pyproject.toml' = "[project]" } @{ 'NOTES.md' = "notes" }
    Assert-Eq 'skip' (EcoStatus $g4) 'G4  doc-only change -> eco:language skip (no false-fail)'

    # G5: -BaseBranch omitted -> the check does not run at all (backward-compatible).
    Assert-Eq '(none)' (EcoStatus $g1 $false) 'G5  no -BaseBranch -> no eco:language check (backward-compatible)'

    # G6: base==HEAD (nothing ahead) -> the ls-files fallback judges the whole tree, still firing.
    #     A foreign .js sitting in an otherwise-Python tree must FAIL, not vacuously skip.
    $g6 = New-GitRepo 'g6_base_eq_head' @{ 'pyproject.toml' = "[project]"; 'stray.js' = "x" } @{} $true
    Assert-Eq 'fail' (EcoStatus $g6) 'G6  base==HEAD -> ls-files fallback judges the tree (foreign .js -> fail, not skip)'

    # G7: an unresolvable base ref -> skip (the $LASTEXITCODE guard, never a false pass).
    Assert-Eq 'skip' ((& $VP -Path $g3 -BaseBranch 'no-such-ref' -Json | ConvertFrom-Json).checks |
                        Where-Object { $_.name -eq 'eco:language' }).status 'G7  unresolvable base ref -> skip (guarded, no false-pass)'
} catch {
    _fail "integration harness threw (git available?): $($_.Exception.Message)"
}

# ----------------------------------------------------------------------------
# WIRING - assert the production scripts actually INVOKE these on real (non-comment) lines.
# A substring match alone would pass on an explanatory comment; anchor to assignment/call lines.
# (Mirrors verify-retry.ps1's U9 / V10.)
# ----------------------------------------------------------------------------
Section 'Wiring assertions (runner + gate really invoke the new logic)'
$vp  = Get-Content (Join-Path $PSScriptRoot 'verify-project.ps1')  -Raw
$nat = Get-Content (Join-Path $PSScriptRoot 'new-agent-task.ps1')  -Raw
Assert-True ([regex]::IsMatch($vp, '(?m)^\s*\[string\]\$BaseBranch'))                       'W1  verify-project.ps1 declares the -BaseBranch param'
Assert-True ([regex]::IsMatch($vp, '(?m)^\s*\$\w+\s*=\s*Test-LanguageAdherence\b'))         'W2  verify-project.ps1 INVOKES Test-LanguageAdherence on a real assignment line'
Assert-True ([regex]::IsMatch($vp, "(?m)^\s*Add-Result\s+'eco:language'"))                 'W3  verify-project.ps1 surfaces the result via Add-Result ''eco:language'' (kills compute-but-never-surface)'
Assert-True ([regex]::IsMatch($vp, '-DeclaredEcosystems\s+\(Get-ProjectEcosystem'))         'W4  verify-project.ps1 feeds Get-ProjectEcosystem into the decision'
Assert-True ([regex]::IsMatch($vp, '-ChangedLanguages\s+\(Get-ChangedLanguages'))           'W5  verify-project.ps1 feeds Get-ChangedLanguages into the decision'
Assert-True ([regex]::IsMatch($vp, '--diff-filter=ACMR'))                                   'W6  verify-project.ps1 excludes deletions from the language judgment'
Assert-True ([regex]::IsMatch($nat, '(?m)verify-project\.ps1.*-BaseBranch\s+\$BaseBranch')) 'W7  new-agent-task.ps1 PASSES -BaseBranch to verify-project (kills the silent-skip-forever regression)'
Assert-True ([regex]::IsMatch($nat, '(?m)^\s*\$ecoSet\s*=\s*Get-ProjectEcosystem\s+\$wt'))  'W8  new-agent-task.ps1 computes the ecosystem from the worktree (A1)'
Assert-True ([regex]::IsMatch($nat, '(?m)^\s*\$langConstraint\s*=\s*Get-LanguageConstraint')) 'W9  new-agent-task.ps1 builds the language constraint (A1)'
Assert-True ([regex]::IsMatch($nat, '(?m)^\s*\$Prompt\s*=\s*\$langConstraint'))             'W10 new-agent-task.ps1 actually PREPENDS the constraint to the prompt (kills compute-but-never-feed)'

# ----------------------------------------------------------------------------
# RESULT
# ----------------------------------------------------------------------------
Section 'Result'
Write-Host ("  Passed:        {0}" -f $script:Pass) -ForegroundColor Green
if ($script:Inconclusive) { Write-Host ("  Inconclusive:  {0}" -f $script:Inconclusive) -ForegroundColor Yellow }
if ($script:Fail) {
    Write-Host ("  Failed:        {0}" -f $script:Fail) -ForegroundColor Red
    Write-Host ''
    Write-Host '  ECOSYSTEM-ADHERENCE: NOT VALIDATED - see the [FAIL] lines above:' -ForegroundColor Red
    $script:Failures | ForEach-Object { Write-Host "    - $_" -ForegroundColor Red }
    exit 1
} else {
    Write-Host ''
    Write-Host '  ECOSYSTEM-ADHERENCE: VALIDATED. A1 pins the language; A2 fails an all-foreign deliverable.' -ForegroundColor Green
    exit 0
}
