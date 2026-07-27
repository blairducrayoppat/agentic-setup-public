#requires -Version 5.1
<#
.SYNOPSIS
  Verify the #790 SCRATCH-TEST SCOPING of the per-candidate gate (sub-task 1).

.DESCRIPTION
  Background (plain English):
    A plan-graph NODE seeds NO acceptance oracle into its worktree (the JOB oracle runs only at
    integration -- BlarAI shared/fleet/acceptance.py: "the #690 per-task oracle fires ONLY for
    single-task python plans"). So at a node EVERY test_*.py is coder-authored, and the coder writes
    BOTH real product tests AND throwaway self-verification scratch tests. On night-20260715, B4's
    `implement-card-management` produced working code (5 product tests passed) but ALSO wrote
    `test_final_verification_fixed.py` -- with a bug IN THE TEST (UnboundLocalError). The per-candidate
    gate runs `pytest -x -q` at the worktree root, which collected that scratch test, failed, and PARKED
    ~90%-complete working code. A gate ARTIFACT sinking good work -- the same shape as the idle-abort park.

    #790 fix (fleet-lib.ps1 Invoke-CandidateBuild): partition the test files into TRUSTED (present in the
    coder's baseline $CodeBase -- the seeded oracle + prior-wave / product tests, the immutable spec) and
    SCRATCH (coder-ADDED this task). RESTORE every Trusted test from the baseline (a candidate cannot
    delete/weaken a spec test to pass). Run SCRATCH as an ADVISORY soft signal and DROP the RED ones before
    the commit (a red self-test never parks working code, never poisons a downstream baseline gate) while
    KEEPING the GREEN ones. So a buggy coder self-test no longer hard-blocks, but the seeded/product tests
    still do.

  This suite proves, against a REAL throwaway git repo + REAL pytest (not a mock, because the fix IS the
  git-restore + pytest-collection mechanism):
    P    the PURE classifiers (Test-IsGatedTestPath, Split-CandidateTestFiles).
    B    BEHAVIOUR: the B4 shape (working product code + a buggy coder-added scratch test) is PARKED by
         the old whole-tree gate and PASSES after scoping; a genuinely-failing SEEDED/product (baseline)
         test STILL BLOCKS; a candidate that deletes/weakens a baseline test cannot escape it (restored);
         a GREEN scratch test is kept, a RED one dropped from the merge.
    W    WIRING: Invoke-CandidateBuild partitions + restores Trusted + quarantines Scratch, and does so
         AFTER the oracle restore and BEFORE staging/commit + the [2/5] gate (a built-but-unwired control
         is the smell these assertions exist to catch).

  Behaviour cases need pytest; if neither `uv` nor an importable `python -m pytest` is present they SKIP
  (never a false fail), and the pure + wiring assertions still run. LOCALAPPDATA is redirected to a temp
  dir for the whole run (defensive: never let a pytest invocation touch the real sessions.db).

  Exit 0 iff all passed. Run it normally ( .\verify-scratch-test-scoping.ps1 ).
#>
$ErrorActionPreference = 'Stop'
. "$PSScriptRoot\fleet-lib.ps1"

$script:Pass = 0; $script:Fail = 0
$script:Failures = New-Object System.Collections.ArrayList
function Section($t) { Write-Host ''; Write-Host "== $t ==" -ForegroundColor Cyan }
function _pass($m) { $script:Pass++; Write-Host "  [PASS] $m" -ForegroundColor Green }
function _fail($m) { $script:Fail++; [void]$script:Failures.Add($m); Write-Host "  [FAIL] $m" -ForegroundColor Red }
function Assert-True($Cond, $Msg) { if ($Cond) { _pass $Msg } else { _fail "$Msg (expected True, got False)" } }
function Assert-False($Cond, $Msg) { if (-not $Cond) { _pass $Msg } else { _fail "$Msg (expected False, got True)" } }
function Assert-Eq($Expected, $Actual, $Msg) { if ([string]$Expected -ceq [string]$Actual) { _pass $Msg } else { _fail "$Msg (expected '$Expected', got '$Actual')" } }

# Defensive: isolate any pytest run from the real per-user data dir (protect sessions.db).
$__prevLA = $env:LOCALAPPDATA
$__laTmp = Join-Path ([System.IO.Path]::GetTempPath()) ("la-790-" + [Guid]::NewGuid().ToString('N').Substring(0, 8))
New-Item -ItemType Directory -Force $__laTmp | Out-Null
$env:LOCALAPPDATA = $__laTmp

$U8 = New-Object System.Text.UTF8Encoding $false

# ----------------------------------------------------------------------------
Section 'P  pure classifiers'
Assert-True  (Test-IsGatedTestPath 'test_foo.py')            'P1 test_foo.py is a gated (python) test file'
Assert-True  (Test-IsGatedTestPath 'pkg/sub/test_bar.py')    'P2 nested test_*.py is gated'
Assert-True  (Test-IsGatedTestPath 'thing_test.py')          'P3 *_test.py is gated'
Assert-False (Test-IsGatedTestPath 'card_manager.py')        'P4 a product module is NOT a gated test file'
Assert-False (Test-IsGatedTestPath 'tests/helper.py')        'P5 a non-test helper under tests/ is NOT gated'
Assert-False (Test-IsGatedTestPath '.venv/lib/test_x.py')    'P6 a test under .venv is NOT gated (vendor dir)'
Assert-False (Test-IsGatedTestPath 'node_modules/a/test_x.py') 'P7 a test under node_modules is NOT gated'
Assert-False (Test-IsGatedTestPath 'suite.test.js')          'P8 a node *.test.js is NOT scoped yet (python-only; documented follow-up)'

$part = Split-CandidateTestFiles -BaseTestFiles @('tests/test_acceptance.py') `
                                 -WorktreeTestFiles @('tests/test_acceptance.py', 'test_final_verification_fixed.py', 'app/test_cards.py')
Assert-Eq 1 (@($part.Trusted).Count) 'P9 the one baseline test is TRUSTED'
Assert-Eq 2 (@($part.Scratch).Count) 'P10 the two coder-added tests are SCRATCH'
Assert-True ((@($part.Scratch) -contains 'test_final_verification_fixed.py') -and (@($part.Scratch) -contains 'app/test_cards.py')) 'P11 SCRATCH names the coder-added files'
Assert-False (@($part.Scratch) -contains 'tests/test_acceptance.py') 'P12 the baseline test is NOT in SCRATCH'
# a candidate DELETED the baseline test (absent from the worktree): it STAYS trusted so the caller restores it.
$partDel = Split-CandidateTestFiles -BaseTestFiles @('tests/test_acceptance.py') -WorktreeTestFiles @('test_scratch.py')
Assert-True (@($partDel.Trusted) -contains 'tests/test_acceptance.py') 'P13 a DELETED baseline test remains TRUSTED (restore target; delete cannot shrink the gate)'
# case/slashes reconciled (git-tree slash vs windows backslash).
$partCase = Split-CandidateTestFiles -BaseTestFiles @('Tests/Test_Acceptance.py') -WorktreeTestFiles @('Tests\Test_Acceptance.py', 'test_new.py')
Assert-Eq 1 (@($partCase.Scratch).Count) 'P14 case-insensitive, slash-normalised match (a baseline test is not miscounted as scratch)'

# ----------------------------------------------------------------------------
# Shared helper: build a REAL repo mirroring a plan-graph node baseline, run the coder's changes, then
# apply the #790 pre-commit scoping block EXACTLY as Invoke-CandidateBuild does, and report whether the
# whole-tree gate is green (== the candidate would merge) both BEFORE and AFTER scoping.
$pytestReady = $false; $pyCmd = ''
if (Get-Command uv -ErrorAction SilentlyContinue) {
    $pytestReady = $true; $pyCmd = 'uv run --no-project --with pytest --with hypothesis pytest -x -q'
}
elseif (Get-Command python -ErrorAction SilentlyContinue) {
    & python -c "import pytest" 2>$null
    if ($LASTEXITCODE -eq 0) { $pytestReady = $true; $pyCmd = 'python -m pytest -x -q' }
}

function New-NodeRepo {
    param([hashtable]$BaseFiles, [hashtable]$CoderFiles, [string[]]$CoderDeletes = @())
    $tmp = Join-Path ([System.IO.Path]::GetTempPath()) ("scope-790-" + [Guid]::NewGuid().ToString('N').Substring(0, 8))
    New-Item -ItemType Directory -Force $tmp | Out-Null
    git -C $tmp init -q 2>&1 | Out-Null
    git -C $tmp config user.email 't@t' 2>&1 | Out-Null
    git -C $tmp config user.name 't' 2>&1 | Out-Null
    foreach ($k in $BaseFiles.Keys) {
        $full = Join-Path $tmp $k; New-Item -ItemType Directory -Force (Split-Path $full -Parent) | Out-Null
        [System.IO.File]::WriteAllText($full, $BaseFiles[$k], $U8)
    }
    git -C $tmp add -A 2>&1 | Out-Null
    git -C $tmp commit -q -m 'baseline (the coder codeBase)' 2>&1 | Out-Null
    $codeBase = "$(git -C $tmp rev-parse HEAD)".Trim()
    # the coder's changes (uncommitted, as in Invoke-CandidateBuild before the commit)
    foreach ($k in $CoderFiles.Keys) {
        $full = Join-Path $tmp $k; New-Item -ItemType Directory -Force (Split-Path $full -Parent) | Out-Null
        [System.IO.File]::WriteAllText($full, $CoderFiles[$k], $U8)
    }
    foreach ($d in $CoderDeletes) { Remove-Item (Join-Path $tmp $d) -Force -ErrorAction SilentlyContinue }
    return @{ Dir = $tmp; CodeBase = $codeBase }
}
function Test-TreeGreen {
    param([string]$Dir)
    $prevPP = $env:PYTHONPATH; $env:PYTHONPATH = $Dir
    try { $r = Invoke-WithTimeout -CommandLine $pyCmd -WorkDir $Dir -TimeoutSec 300 }
    finally { if ($null -eq $prevPP) { Remove-Item Env:\PYTHONPATH -ErrorAction SilentlyContinue } else { $env:PYTHONPATH = $prevPP } }
    # green == the [2/5] gate would report pass/none, i.e. exit 0 (pass) or 5 (nothing collected). A real
    # failure is exit 1; a collection error exit 2 -- both would set TestResult='fail' -> park.
    return (-not $r.TimedOut) -and (($r.ExitCode -eq 0) -or ($r.ExitCode -eq 5))
}
function Invoke-ScopingBlock {
    # the EXACT #790 pre-commit block from Invoke-CandidateBuild, extracted so the test drives the real
    # helpers + real git restore + real quarantine (author != a mock of it).
    param([string]$Dir, [string]$CodeBase)
    $p = Get-CandidateTestPartition -Worktree $Dir -BaseRef $CodeBase
    foreach ($tt in @($p.Trusted)) { git -C $Dir checkout $CodeBase -- "$tt" 2>&1 | Out-Null }
    $sig = $null
    if (@($p.Scratch).Count -gt 0) {
        $sig = Invoke-ScratchTestSignal -Worktree $Dir -ScratchTests @($p.Scratch)
        foreach ($rf in @($sig.Red)) { Remove-Item (Join-Path $Dir $rf) -Force -ErrorAction SilentlyContinue }
    }
    return @{ Partition = $p; Scratch = $sig }
}

if (-not $pytestReady) {
    Section 'B  behaviour (REAL git + REAL pytest)'
    Write-Host '  [skip] neither uv nor python+pytest available offline - behaviour cases skipped (pure + wiring still run).' -ForegroundColor Yellow
}
else {
    # --- B4 SHAPE: a plan-graph node with NO baseline test; working product code + a buggy scratch test ---
    Section 'B  behaviour: the B4 shape (working code + a buggy coder-added scratch test)'
    $prod = "def summarize(cards):`n    return {'count': len(cards)}`n"
    $goodProductTest = "from card_manager import summarize`n`n`ndef test_summarize():`n    assert summarize(['a', 'b'])['count'] == 2`n"
    # a bug IN THE TEST itself (mirrors B4's UnboundLocalError): references an undefined name -> the test
    # ERRORS, exit != 0, even though the product code is fine.
    $buggyScratch = "from card_manager import summarize`n`n`ndef test_final_verification_fixed():`n    result = summarize([cards])`n    assert result['count'] == 1`n"
    $repo = New-NodeRepo -BaseFiles @{ 'README.md' = "# node sandbox`n" } `
                         -CoderFiles @{ 'card_manager.py' = $prod; 'test_card_manager.py' = $goodProductTest; 'test_final_verification_fixed.py' = $buggyScratch }
    try {
        Assert-False (Test-TreeGreen -Dir $repo.Dir) 'B1 OLD gate: the whole-tree pytest FAILS on the buggy scratch test (this is the park)'
        $res = Invoke-ScopingBlock -Dir $repo.Dir -CodeBase $repo.CodeBase
        Assert-True  (@($res.Partition.Scratch).Count -eq 2) 'B2 both coder tests are classified SCRATCH (node baseline has no seeded test)'
        Assert-True  (@($res.Scratch.Red) -contains 'test_final_verification_fixed.py') 'B3 the buggy scratch test is RED'
        Assert-False (Test-Path (Join-Path $repo.Dir 'test_final_verification_fixed.py')) 'B4 the RED scratch test is DROPPED from the tree (never merged, never poisons a later wave)'
        Assert-True  (Test-Path (Join-Path $repo.Dir 'test_card_manager.py')) 'B5 the GREEN coder product test is KEPT (delivered coverage)'
        Assert-True  (Test-TreeGreen -Dir $repo.Dir) 'B6 NEW gate: after scoping the whole-tree pytest PASSES (the ~90%-complete work now merges)'
    } finally { Remove-Item -Recurse -Force $repo.Dir -ErrorAction SilentlyContinue }

    # --- FAIL-CLOSED: a genuinely-failing SEEDED/baseline test STILL blocks (requirement #4) ---
    Section 'B  behaviour: a genuinely-failing SEEDED/product (baseline) test still HARD-BLOCKS'
    $seededOracle = "from calc import add`n`n`ndef test_add():`n    assert add(2, 2) == 4`n"
    $wrongProduct = "def add(a, b):`n    return a - b   # WRONG: fails the seeded oracle`n"
    $repo2 = New-NodeRepo -BaseFiles @{ 'tests/test_acceptance.py' = $seededOracle; 'calc.py' = "def add(a, b):`n    return a + b`n" } `
                          -CoderFiles @{ 'calc.py' = $wrongProduct; 'test_helper_scratch.py' = "def test_ok():`n    assert True`n" }
    try {
        $res2 = Invoke-ScopingBlock -Dir $repo2.Dir -CodeBase $repo2.CodeBase
        Assert-True (@($res2.Partition.Trusted) -contains 'tests/test_acceptance.py') 'B7 the seeded oracle is TRUSTED'
        Assert-False (Test-TreeGreen -Dir $repo2.Dir) 'B8 the seeded oracle FAILS the wrong product code -> still hard-blocks (fail-closed preserved)'
    } finally { Remove-Item -Recurse -Force $repo2.Dir -ErrorAction SilentlyContinue }

    # --- VALIDATE-BEFORE-TRUST: a candidate that WEAKENS or DELETES a seeded test cannot escape it ---
    Section 'B  behaviour: a candidate cannot delete/neuter a seeded baseline test to pass'
    $repo3 = New-NodeRepo -BaseFiles @{ 'tests/test_acceptance.py' = $seededOracle; 'calc.py' = "def add(a, b):`n    return a + b`n" } `
                          -CoderFiles @{ 'calc.py' = $wrongProduct; 'tests/test_acceptance.py' = "def test_add():`n    assert True   # NEUTERED`n" } `
                          -CoderDeletes @()
    try {
        $null = Invoke-ScopingBlock -Dir $repo3.Dir -CodeBase $repo3.CodeBase
        $restored = [System.IO.File]::ReadAllText((Join-Path $repo3.Dir 'tests/test_acceptance.py'))
        Assert-True ($restored.Contains('assert add(2, 2) == 4')) 'B9 a NEUTERED seeded test is RESTORED to its real assertion before the gate'
        Assert-False (Test-TreeGreen -Dir $repo3.Dir) 'B10 the restored seeded test still fails the wrong code -> the neuter did not help the candidate merge'
    } finally { Remove-Item -Recurse -Force $repo3.Dir -ErrorAction SilentlyContinue }

    $repo4 = New-NodeRepo -BaseFiles @{ 'tests/test_acceptance.py' = $seededOracle; 'calc.py' = "def add(a, b):`n    return a + b`n" } `
                          -CoderFiles @{ 'calc.py' = $wrongProduct } -CoderDeletes @('tests/test_acceptance.py')
    try {
        $null = Invoke-ScopingBlock -Dir $repo4.Dir -CodeBase $repo4.CodeBase
        Assert-True (Test-Path (Join-Path $repo4.Dir 'tests/test_acceptance.py')) 'B11 a DELETED seeded test is RE-CREATED before the gate'
        Assert-False (Test-TreeGreen -Dir $repo4.Dir) 'B12 the re-created seeded test still fails the wrong code -> deletion did not help the candidate merge'
    } finally { Remove-Item -Recurse -Force $repo4.Dir -ErrorAction SilentlyContinue }
}

# ----------------------------------------------------------------------------
Section 'W  wiring: Invoke-CandidateBuild partitions + restores + quarantines, in the right order'
$lib = Get-Content "$PSScriptRoot\fleet-lib.ps1" -Raw
Assert-True ([regex]::IsMatch($lib, 'Get-CandidateTestPartition -Worktree \$wt -BaseRef \$CodeBase')) 'W1 the gate partitions the worktree''s test files against the baseline'
Assert-True ([regex]::IsMatch($lib, 'git -C \$wt checkout \$CodeBase -- "\$__tt"')) 'W2 [kill] every TRUSTED baseline test is restored from the baseline (delete/neuter cannot help)'
Assert-True ([regex]::IsMatch($lib, 'Invoke-ScratchTestSignal -Worktree \$wt -ScratchTests')) 'W3 SCRATCH tests are run as an advisory signal'
Assert-True ([regex]::IsMatch($lib, 'Remove-Item \(Join-Path \$wt \$__rf\)')) 'W4 [kill] RED scratch tests are DROPPED before the commit'
# [kill] the scoping MUST run AFTER the oracle restore and BEFORE staging + the [2/5] gate, else the merged
# candidate keeps a red scratch test / a tampered baseline test, or the gate judges the un-scoped tree.
$idxOracle  = $lib.IndexOf('if ($OracleActive) { git -C $wt checkout $CodeBase -- $AcceptanceTestPath')
$idxScope   = $lib.IndexOf('Get-CandidateTestPartition -Worktree $wt -BaseRef $CodeBase')
# #1074: anchor the staging point on the CODE THAT STAGES, not on the comment above it. The old
# anchor was a comment string, so rewording that comment silently broke this ordering lock -- an
# ordering property must be pinned to the statement it orders.
$idxStage   = $lib.IndexOf('$addOut = (git -C $wt add -A')
$idxTests   = $lib.IndexOf('[2/5] Running pytest')
Assert-True (($idxOracle -gt 0) -and ($idxScope -gt $idxOracle)) 'W5 [kill] scoping runs AFTER the #690 oracle restore'
Assert-True (($idxScope -gt 0) -and ($idxStage -gt $idxScope))   'W6 [kill] scoping runs BEFORE staging/commit (the merged candidate keeps baseline tests, drops red scratch)'
Assert-True (($idxScope -gt 0) -and ($idxTests -gt $idxScope))   'W7 [kill] scoping runs BEFORE the [2/5] test gate (the gate judges the scoped tree)'
Assert-True ([regex]::IsMatch($lib, 'test-gate scoping skipped \(non-fatal')) 'W8 a scoping error is FORGIVING (falls back to the whole-tree gate, never fails open)'

# ----------------------------------------------------------------------------
$env:LOCALAPPDATA = $__prevLA
Remove-Item -Recurse -Force $__laTmp -ErrorAction SilentlyContinue

Section 'Result'
Write-Host ("  Passed:  {0}" -f $script:Pass) -ForegroundColor Green
if ($script:Fail) {
    Write-Host ("  Failed:  {0}" -f $script:Fail) -ForegroundColor Red
    $script:Failures | ForEach-Object { Write-Host "    - $_" -ForegroundColor Red }
    exit 1
} else {
    Write-Host ''
    Write-Host '  SCRATCH-TEST SCOPING: VALIDATED. A buggy coder-authored scratch test no longer parks working code; the seeded/baseline spec tests still hard-gate and cannot be deleted or weakened to pass.' -ForegroundColor Green
    exit 0
}
