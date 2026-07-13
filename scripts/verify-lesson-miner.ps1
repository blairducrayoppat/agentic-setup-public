#requires -Version 7.0
<#
.SYNOPSIS
  Verify the #793 FLEET LESSON-CANDIDATE MINER (Learning Loop 2, Stage C1, report-only).

.DESCRIPTION
  Background (plain English):
    The miner reads the coding fleet's own dispatch outputs (scorecards, oracle results,
    guest certificates, campaign history) and PROPOSES small improvements to the coder's
    instruction file (AGENTS.md) as UNTRUSTED, machine-proposed candidates. It never edits
    anything -- it writes one file, state/lesson-candidates/<date>.md, and that is all.

    The load-bearing half is the VERIFICATION HARNESS (decision D-5): the local 14B may
    propose, but a deterministic ruler disposes. Every candidate must clear, in order:
      1. schema         -- matches the required candidate shape (grammar-constrained output),
      2. byte-match     -- every cited evidence quote is VERBATIM in its source scorecard
                           (the deterministic kill for a small model's paraphrase drift),
      3. recurrence     -- recurs across >= N (default 3) distinct runs,
      4. diversity      -- spans >= 2 distinct jobs or eras (one bad run cannot mint a lesson),
      5. novelty        -- not already in LESSONS-LEARNED.md or a prior candidate,
      6. forbidden-class-- never proposes weakening the verify gate / secret scan / FALSE-DONE,
      7. removals-lint  -- a proposed delta DELETES lines; it never appends a "stop doing X"
                           negation of a still-present rule.
    Anything filtered is DROPPED and REPORTED (no silent caps).

  This suite runs the miner's own quality gate -- the GOLDEN MINING TEST SET (the D-5
  substrate) -- and its unit tests. The golden set seeds candidates engineered to die at
  each stage: a non-recurrent one, a forbidden-class one, a paraphrase-drift one, a
  negate-by-append one, plus a non-novel and a malformed one, against one genuinely-good
  candidate that must SURVIVE. It needs NO GPU and NO network (the model is faked/recorded).

  Exit 0 if everything passed, 1 otherwise. Run it normally ( .\verify-lesson-miner.ps1 ).
#>
$ErrorActionPreference = 'Stop'

$script:Pass = 0; $script:Fail = 0
$script:Failures = New-Object System.Collections.ArrayList
function Section($t) { Write-Host ''; Write-Host "== $t ==" -ForegroundColor Cyan }
function _pass($m) { $script:Pass++; Write-Host "  [PASS] $m" -ForegroundColor Green }
function _fail($m) { $script:Fail++; [void]$script:Failures.Add($m); Write-Host "  [FAIL] $m" -ForegroundColor Red }

$repoRoot = Split-Path -Parent $PSScriptRoot
$miner = Join-Path $repoRoot 'tools/lesson_miner/lesson_miner.py'
$minerDir = Join-Path $repoRoot 'tools/lesson_miner'

# Resolve a Python interpreter (the fleet box ships C:\Python314\python.exe; fall back to PATH).
$py = if (Test-Path 'C:\Python314\python.exe') { 'C:\Python314\python.exe' }
      elseif (Get-Command python -ErrorAction SilentlyContinue) { 'python' }
      elseif (Get-Command py -ErrorAction SilentlyContinue) { 'py' }
      else { $null }

Section 'Preconditions'
if (-not (Test-Path $miner)) { _fail "miner not found at $miner"; }
else { _pass "miner present ($miner)" }
if (-not $py) { _fail 'no Python interpreter found (looked for C:\Python314\python.exe, python, py)' }
else { _pass "Python interpreter: $py" }

if ($py -and (Test-Path $miner)) {
    Section 'Golden mining gate (the D-5 quality substrate)'
    # --check runs the golden set; exit 0 iff the seeded kills fire and the good one survives.
    & $py $miner --check
    if ($LASTEXITCODE -eq 0) { _pass 'lesson_miner.py --check (golden gate) exit 0' }
    else { _fail "lesson_miner.py --check exit $LASTEXITCODE (golden gate regressed)" }

    Section 'Unit tests (harness stages + post-pass guard)'
    Push-Location $minerDir
    try {
        & $py -m unittest test_lesson_miner
        if ($LASTEXITCODE -eq 0) { _pass 'unittest test_lesson_miner exit 0' }
        else { _fail "unittest test_lesson_miner exit $LASTEXITCODE" }
    } finally { Pop-Location }
}

Write-Host ''
$resultColor = if ($script:Fail -eq 0) { 'Green' } else { 'Red' }
Write-Host ("RESULT: {0} passed, {1} failed" -f $script:Pass, $script:Fail) -ForegroundColor $resultColor
if ($script:Fail -gt 0) {
    Write-Host 'Failures:' -ForegroundColor Red
    $script:Failures | ForEach-Object { Write-Host "  - $_" -ForegroundColor Red }
    exit 1
}
exit 0
