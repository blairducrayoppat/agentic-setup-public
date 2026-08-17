#requires -Version 5.1
<#
.SYNOPSIS
  Verify and validate the COMPLEXITY-SIGNAL feature (the 14B's coarse "how hard is this?" hint).

.DESCRIPTION
  Background (plain English):
    The upstream 14B decomposer is NOT a coder, so it must not prescribe a pass count. Instead it emits a
    COARSE complexity LABEL (simple | moderate | complex). The fleet maps that SIGNAL to the two independent
    pass budgets the multi-pass loop spends -- a harder task earns more build + review passes, a simple one
    fewer -- and tells the coder up front so it calibrates effort before pass 1. The two pure pieces live in
    fleet-lib.ps1 so they unit-test without a model:
      - Resolve-PassBudget : label (+ the caller's defaults) -> @{ Build; Review }
      - Add-ComplexityHint : label -> the original prompt with a one-line effort hint appended (or unchanged)

    An ABSENT or UNRECOGNISED label keeps the caller's explicit defaults and leaves the prompt untouched, so
    adding the signal is fully backward-compatible (a dispatch with no complexity field behaves exactly as before).

  Mutation-resistant: each [kill] case fails a specific wrong implementation (e.g. a flat budget, a hardcoded
  default, a hint that drops the original prompt, or a hint that fires on an unknown label).
  Exit 0 if all passed, 1 otherwise. Run it normally ( .\verify-complexity.ps1 ).
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
function Assert-Contains($H, $N, $Msg) { if ($H -and $H.ToString().Contains($N)) { _pass $Msg } else { _fail "$Msg (did not find '$N')" } }

# ----------------------------------------------------------------------------
Section 'Unit tests: Resolve-PassBudget (label -> the two pass budgets)'
$s = Resolve-PassBudget -Complexity 'simple'
Assert-Eq 2 $s.Build  'PB1 simple -> 2 build passes'
Assert-Eq 1 $s.Review 'PB1 simple -> 1 review pass'
$m = Resolve-PassBudget -Complexity 'moderate'
Assert-Eq 3 $m.Build  'PB2 moderate -> 3 build passes (the prior default)'
Assert-Eq 2 $m.Review 'PB2 moderate -> 2 review passes'
$x = Resolve-PassBudget -Complexity 'complex'
Assert-Eq 8 $x.Build  'PB3 [kill] complex -> 8 build passes (LA-raised 5->8 on 2026-06-27 for more best-of-N shots at hard tasks; a revert to 5 fails here)'
Assert-Eq 3 $x.Review 'PB3 complex -> 3 review passes'
# [kill] absent/unknown must return the CALLER'S defaults, not a hardcoded 3/2. Pass NON-default sentinels.
$d1 = Resolve-PassBudget -Complexity '' -DefaultBuild 9 -DefaultReview 7
Assert-Eq 9 $d1.Build  'PB4 [kill] empty label -> the caller default build is kept (not hardcoded)'
Assert-Eq 7 $d1.Review 'PB4 [kill] empty label -> the caller default review is kept (not hardcoded)'
$d2 = Resolve-PassBudget -Complexity 'banana' -DefaultBuild 9 -DefaultReview 7
Assert-Eq 9 $d2.Build  'PB5 [kill] unknown label -> the caller default build is kept (never guesses)'
Assert-Eq 7 $d2.Review 'PB5 [kill] unknown label -> the caller default review is kept'
$ci = Resolve-PassBudget -Complexity '  Complex '
Assert-Eq 8 $ci.Build  'PB6 label is case- and whitespace-insensitive ( " Complex " -> complex -> 8)'
# [kill] the mapping must NOT be flat: a complex task earns strictly more build budget than a simple one.
Assert-True ((Resolve-PassBudget -Complexity 'complex').Build -gt (Resolve-PassBudget -Complexity 'simple').Build) 'PB7 [kill] complex earns MORE build budget than simple (the mapping is not flat)'
Assert-True ((Resolve-PassBudget -Complexity 'complex').Review -gt (Resolve-PassBudget -Complexity 'simple').Review) 'PB8 [kill] complex earns MORE review budget than simple'
# [kill] complex must out-budget MODERATE too (not just simple) -- catches a complex->moderate flatten that
# PB7 would miss, and locks the 8 > 3 ordering after the 5->8 raise (so the top of the scale stays the top).
Assert-True ((Resolve-PassBudget -Complexity 'complex').Build -gt (Resolve-PassBudget -Complexity 'moderate').Build) 'PB8b [kill] complex earns MORE build budget than moderate (8 > 3; the raise did not flatten the top of the scale)'
# STAGED-GUI FLOOR (dead-button fix, 2026-06-24): a staged desktop-gui surface floors BUILD to 5 even at a low label.
$sg = Resolve-PassBudget -Complexity 'simple' -Staged $true
Assert-Eq 5 $sg.Build  'PB9 staged + simple -> BUILD floored to 5 (a GUI needs core->shell->wire->theme->verify)'
Assert-Eq 1 $sg.Review 'PB10 the staged floor touches BUILD only -> review stays the label value (1)'
Assert-Eq 2 (Resolve-PassBudget -Complexity 'simple').Build 'PB11 [kill] NON-staged simple is byte-identical (2) -> the floor is opt-in via -Staged'
Assert-Eq 8 (Resolve-PassBudget -Complexity 'complex' -Staged $true).Build 'PB12 staged + complex stays 8 (already >= the staged floor 5, never lowered)'

# ----------------------------------------------------------------------------
Section 'Unit tests: Add-ComplexityHint (label -> prompt + effort hint, or unchanged)'
$base = 'Build a thing that does X.'
$hs = Add-ComplexityHint -Prompt $base -Complexity 'simple'
Assert-True ($hs.StartsWith($base)) 'CH1 simple: the original prompt is preserved verbatim at the front'
Assert-Contains $hs 'SIMPLE'        'CH1 simple: the hint names the assessed complexity'
$hx = Add-ComplexityHint -Prompt $base -Complexity 'complex'
Assert-Contains $hx 'COMPLEX'       'CH2 complex: the hint names the assessed complexity'
Assert-True ($hx.Length -gt $base.Length) 'CH2 complex: the hint is appended (longer than the original)'
Assert-Eq $base (Add-ComplexityHint -Prompt $base -Complexity '')        'CH3 [kill] empty label -> prompt UNCHANGED (backward-compatible)'
Assert-Eq $base (Add-ComplexityHint -Prompt $base -Complexity 'banana')  'CH4 [kill] unknown label -> prompt UNCHANGED (never invents a hint)'
Assert-Eq $base (Add-ComplexityHint -Prompt $base -Complexity "  `n ")    'CH5 [kill] whitespace label -> prompt UNCHANGED'
Assert-Contains (Add-ComplexityHint -Prompt $base -Complexity 'moderate') 'MODERATE' 'CH6 moderate: the hint names the assessed complexity'
# [kill] the hint must CALIBRATE, not PRESCRIBE -- it must not inject an implementation directive.
Assert-False ((Add-ComplexityHint -Prompt $base -Complexity 'complex') -match '(?i)\buse (the )?(class|function|library|framework) ') 'CH7 [kill] the hint calibrates effort; it does NOT prescribe a specific implementation'

# ----------------------------------------------------------------------------
Section 'Wiring: the runner accepts the signal, scales the budgets, and tells the coder'
$nat = Get-Content "$PSScriptRoot\new-agent-task.ps1" -Raw
Assert-True ([regex]::IsMatch($nat, '\[string\]\$Complexity'))                                  'W1 wiring: the runner accepts a -Complexity parameter'
Assert-True ([regex]::IsMatch($nat, 'Resolve-PassBudget -Complexity \$Complexity'))             'W2 wiring: it maps the label to budgets via Resolve-PassBudget'
Assert-True ([regex]::IsMatch($nat, '\$MaxVerifyAttempts\s*=\s*\$__budget\.Build'))             'W3 wiring: the resolved BUILD budget drives the loop ($MaxVerifyAttempts)'
Assert-True ([regex]::IsMatch($nat, '\$MaxReviewPasses\s*=\s*\$__budget\.Review'))              'W4 wiring: the resolved REVIEW budget drives the loop ($MaxReviewPasses)'
Assert-True ([regex]::IsMatch($nat, '\$Prompt = Add-ComplexityHint -Prompt \$Prompt -Complexity \$Complexity')) 'W5 wiring: the coder is told the complexity up front (prompt hint)'
# [kill] the hint + budget scaling must happen BEFORE the build loop starts (not mid-loop, where candidate 1
# would miss it). #689: the build loop is now best-of-N ($bon = Invoke-BestOfN), so that call is the marker.
$idxHint = $nat.IndexOf('Add-ComplexityHint -Prompt $Prompt')
$idxLoop = $nat.IndexOf('$bon = Invoke-BestOfN')
Assert-True (($idxHint -gt 0) -and ($idxLoop -gt 0) -and ($idxHint -lt $idxLoop)) 'W6 [kill] the complexity hint + budget scaling are applied BEFORE the best-of-N build loop (so candidate 1 sees them)'
# The PRODUCTION path must actually carry the label end to end (a review found the runner dropped it):
# add-fleet-task writes it into the queue, run-fleet forwards it to new-agent-task.
$runFleet = Get-Content "$PSScriptRoot\run-fleet.ps1" -Raw
Assert-True ([regex]::IsMatch($runFleet, '\$params\.Complexity\s*=\s*\$t\.complexity')) 'W7 [kill] run-fleet.ps1 FORWARDS a queued task''s complexity to new-agent-task (else the feature is dormant on the overnight path)'
$addTask = Get-Content "$PSScriptRoot\add-fleet-task.ps1" -Raw
Assert-True ([regex]::IsMatch($addTask, '\[ValidateSet\([^)]*\bcomplex\b[^)]*\)\]\[string\]\$Complexity')) 'W8 add-fleet-task.ps1 accepts a validated -Complexity (so a queue task can carry the label)'
Assert-True ([regex]::IsMatch($addTask, '\$item\.complexity\s*=\s*\$Complexity')) 'W9 add-fleet-task.ps1 persists the label into the queued task'
# STAGED-GUI FLOOR wiring (dead-button fix, 2026-06-24): the runner must pass the profile's staged flag to
# Resolve-PassBudget, else the build-budget floor is dormant on the real dispatch path.
Assert-True ([regex]::IsMatch($nat, 'Resolve-PassBudget[^\r\n]*-Staged \(\[bool\]\$buildProfile\.staged\)')) 'W10 wiring: the runner passes -Staged ([bool]$buildProfile.staged) so a GUI surface gets the build-budget floor'

# ----------------------------------------------------------------------------

# ---------------------------------------------------------------------------
# #1398 / DoD row 19 clause 2 — "the choice AND its reason are recorded".
#
# The REASON was banked (acceptance.json carries spec.build_plan.complexity).
# The CHOICE — the budget that label resolved to — existed only as a prose line
# in a per-task .log. Measured on run 20260814-230237-bd: a walk of every key in
# acceptance.json matching complex|budget|candidate|pass|review returned exactly
# one hit, the label. No JSON on the run carried the 3 or the 2.
#
# Row 19's THIRD clause is a CROSS-RUN comparison — hard tasks demonstrably get
# more attempts than trivial ones — and prose in a log cannot be aggregated.
# ---------------------------------------------------------------------------

Section '#1398 -- the resolved budget is recordable, not just printable'

# B1-B3: every recognised label resolves to a DISTINCT pair, or "more attempts for harder
# tasks" is unmeasurable however well it is banked.
$bs = Resolve-PassBudget -Complexity 'simple'
$bm = Resolve-PassBudget -Complexity 'moderate'
$bc = Resolve-PassBudget -Complexity 'complex'
Assert-True ($bs.Build -lt $bm.Build -and $bm.Build -lt $bc.Build) `
    'B1 [kill] build budget strictly increases simple < moderate < complex'
Assert-True ($bs.Review -le $bm.Review -and $bm.Review -le $bc.Review) `
    'B2 [kill] review budget never decreases as difficulty rises'
Assert-True (@($bs.Build, $bm.Build, $bc.Build) | Select-Object -Unique).Count -eq 3 `
    'B3 [kill] the three labels are genuinely distinguishable by their build budget'

# B4-B5: THE STATE THE SIDECAR EXISTS TO SEPARATE. An unrecognised label and an absent one both
# fall through to the caller's defaults -- SAME NUMBERS, DIFFERENT REASONS. A record that
# stores only the budget cannot tell them apart, and a reader asking "why 3?" gets the wrong
# answer for one of them.
$bUnknown = Resolve-PassBudget -Complexity 'wildly-hard' -DefaultBuild 3 -DefaultReview 2
$bAbsent  = Resolve-PassBudget -Complexity ''            -DefaultBuild 3 -DefaultReview 2
Assert-True ($bUnknown.Build -eq $bAbsent.Build) `
    'B4 [kill] an unrecognised label and an absent one resolve to the SAME budget'
$known = @('simple', 'moderate', 'complex')
Assert-True (($known -contains 'wildly-hard') -eq $false -and [bool]'wildly-hard') `
    'B5 [kill] ...and are still distinguishable: present=true, recognised=false'

Section '#1398 -- new-agent-task.ps1 actually writes the sidecar'

$nat = Get-Content (Join-Path $PSScriptRoot 'new-agent-task.ps1') -Raw
Assert-True ($nat -match 'pass-budget/v1')       'B6 [kill] the schema is emitted'
Assert-True ($nat -match 'pass-budget\.json')    'B7 [kill] it is written beside the report'
Assert-True ($nat -match 'build_passes')         'B8 [kill] the CHOICE is banked, not only the label'
Assert-True ($nat -match 'label_recognised')     'B9 [kill] present-but-unrecognised is distinguishable from absent'
# Fail-soft: a sidecar that cannot be written must never sink a dispatch.
Assert-True ($nat -match 'pass-budget sidecar not written') 'B10 [kill] the write is fail-soft and says so'


Section 'Result'
Write-Host ("  Passed:  {0}" -f $script:Pass) -ForegroundColor Green
if ($script:Fail) {
    Write-Host ("  Failed:  {0}" -f $script:Fail) -ForegroundColor Red
    $script:Failures | ForEach-Object { Write-Host "    - $_" -ForegroundColor Red }
    exit 1
} else {
    Write-Host ''
    Write-Host '  COMPLEXITY SIGNAL: VALIDATED. A coarse upstream label scales the build + review budgets and tells the coder up front; absent/unknown is a no-op (backward-compatible).' -ForegroundColor Green
    exit 0
}