#requires -Version 5.1
<#
.SYNOPSIS
  Verify the #1195 CODER-TEST QA wiring: the dispatch examines the exam the candidate wrote for itself.

.DESCRIPTION
  On a flat-queue run there is no sealed oracle, so the TESTS gate grades the tests the CODER wrote for
  its OWN code -- and new-agent-task.ps1 then SKIPS the review entirely because the gates are green. Run
  ceremony-check-create-kitchen-conversion-helper-20260729-164936 merged a converter whose ounce factor is
  wrong by 2.5x through exactly that gap, its own test widened around an answer its own comment named.

  This verifier locks the three properties the wiring has to hold:
    1. Invoke-CoderTestQa reads the scanner's JSON, never its exit code (the module exits 0 by design --
       a scanner that could hard-fail a dispatch would be a second merge authority).
    2. A DEGRADED scan is DISTINGUISHABLE from a clean one, everywhere it surfaces. Measured=$false, a
       status that is not 'clean', and a report block that says NOT MEASURED. A control that degrades into
       looking like a pass is this project's most-repeated defect.
    3. The finding SURFACES -- in the report block and in the machine-readable sidecar -- whether it is
       hard or soft, and it never blocks the merge.

  Mutation-resistant: the [kill] cases each fail a specific plausible wrong implementation. The scanner
  cases run the REAL shared/fleet/coder_test_qa.py over REAL crafted test files when BlarAI's venv has it;
  when it does not, the same run PROVES property 2 instead (an absent module reads as unavailable, never
  as clean), so this verifier has teeth in both environments and skips nothing silently.

  Pure/offline: no model, no dispatch, no network. Exit 0 iff every case passes.
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
function Assert-NotContains($H, $N, $Msg) { if (-not ($H -and $H.ToString().Contains($N))) { _pass $Msg } else { _fail "$Msg (unexpectedly found '$N')" } }

$BlarAiRepo = $(if ($env:BLARAI_REPO) { $env:BLARAI_REPO } else { 'C:\Users\mrbla\blarai' })

# ----------------------------------------------------------------------------
Section 'Fail-soft is not fail-silent: a scan that could not run NEVER reads as a clean one'
# The single most important property here. Each of these is a real degradation path.
$noPy = Invoke-CoderTestQa -Repo $PSScriptRoot -BlarAiRepo (Join-Path $env:TEMP 'no-such-blarai-root')
Assert-Eq 'unavailable' $noPy.Status 'U1: a missing python interpreter -> unavailable'
Assert-False ([bool]$noPy.Measured) 'U1 [kill] unavailable is Measured=$false (a caller gating on .Measured cannot mistake it for a verdict)'
Assert-Eq 0 $noPy.Hard 'U1: an unmeasured scan reports 0 hard findings (it must never force the 30B leg on nothing)'
Assert-True ([bool]$noPy.Detail) 'U1 [kill] the reason is NAMED, not swallowed -- an operator can act on it'
Assert-Contains $noPy.Detail 'python' 'U1: the detail names the missing interpreter'

$noRepo = Invoke-CoderTestQa -Repo (Join-Path $env:TEMP 'no-such-candidate-worktree') -BlarAiRepo $BlarAiRepo
Assert-Eq 'unavailable' $noRepo.Status 'U2: a missing candidate worktree -> unavailable'
Assert-False ([bool]$noRepo.Measured) 'U2 [kill] not measured'

# The report block is where the operator meets the result. THIS is the assertion that would have caught
# the "unmeasured renders as clean" defect at the surface the human actually reads.
$blockUnavail = Format-CoderTestQaBlock -Result $noPy
Assert-Contains $blockUnavail 'NOT MEASURED' 'U3: the report block says NOT MEASURED'
Assert-Contains $blockUnavail 'ABSENT measurement, not a clean one' 'U3: the block spells out that this is not evidence of a sound exam'
Assert-NotContains $blockUnavail 'CODER TEST QA: clean' 'U3 [kill] the degraded block is NOT the clean block'
Assert-Contains (Format-CoderTestQaBlock -Result $null) 'NOT MEASURED' 'U4 [kill] even a null result formats as NOT MEASURED, never as silence'

$sidecarUnavail = ConvertTo-CoderTestQaSidecarJson -Result $noPy | ConvertFrom-Json
Assert-Eq 'unavailable' $sidecarUnavail.status 'U5: the sidecar carries the status'
Assert-False ([bool]$sidecarUnavail.measured) 'U5 [kill] `measured` is a FIRST-CLASS sidecar field, so a scorecard need not infer it from an empty findings list'

# ----------------------------------------------------------------------------
Section 'Invoke-CoderTestQa reads the JSON, never the exit code'
$libSrc = Get-Content "$PSScriptRoot\fleet-lib.ps1" -Raw
$fnStart = $libSrc.IndexOf('function Invoke-CoderTestQa')
$fnEnd = $libSrc.IndexOf('function Format-CoderTestQaBlock')
Assert-True (($fnStart -ge 0) -and ($fnEnd -gt $fnStart)) 'X0: Invoke-CoderTestQa is present and bounded'
$fnBody = $libSrc.Substring($fnStart, $fnEnd - $fnStart)
# Strip comment lines: the function DOCUMENTS why it ignores the exit code, and the doc must not fail
# the assertion that the CODE ignores it.
$fnCode = (@($fnBody -split "`r?`n" | Where-Object { $_.Trim() -notmatch '^#' }) -join "`n")
Assert-NotContains $fnCode 'LASTEXITCODE' 'X1 [kill] the invoker never branches on $LASTEXITCODE -- coder_test_qa exits 0 ALWAYS by design, so an exit-code branch would read every run as success'
Assert-Contains $fnBody 'ConvertFrom-Json' 'X2: the verdict comes from the parsed JSON'

# ----------------------------------------------------------------------------
Section 'Format-CoderTestQaBlock (pure): the operator-facing block'
$mkResult = {
    param($Status, $Measured, $Hard, $Findings, $Files, $Detail, $PropMeasured)
    $r = New-CoderTestQaResult -Status $Status -Detail $Detail
    $r.Measured = [bool]$Measured; $r.Hard = [int]$Hard; $r.Findings = @($Findings)
    $r.FilesScanned = [int]$Files; $r.PropertyExecutionMeasured = [bool]$PropMeasured
    $r
}
$clean = & $mkResult 'clean' $true 0 @() 4 '' $true
$blockClean = Format-CoderTestQaBlock -Result $clean
Assert-Contains $blockClean 'CODER TEST QA: clean' 'F1: a measured clean exam says clean'
Assert-Contains $blockClean '4 test file(s)' 'F1: and names how many files carried the verdict'

$noTests = & $mkResult 'no-tests' $true 0 @() 0 'no python test files under the candidate -- there was no exam to examine' $true
$blockNoTests = Format-CoderTestQaBlock -Result $noTests
Assert-Contains $blockNoTests 'NO EXAM' 'F2 [kill] zero files scanned is NOT reported as clean -- there was no exam, which is a different fact'
Assert-NotContains $blockNoTests 'CODER TEST QA: clean' 'F2 [kill] and it does not borrow the clean wording'

$hardFinding = @{ Class = 'dead_property'; Message = '`test_conversions` defines the property test `inner` (@given) but never calls it'; Subject = 'test_c.py::test_conversions.inner' }
$found = & $mkResult 'findings' $true 1 @($hardFinding) 3 '' $true
$blockFound = Format-CoderTestQaBlock -Result $found -SkipWithdrawn $true
Assert-Contains $blockFound '1 PROVEN' 'F3: the hard count is stated'
Assert-Contains $blockFound 'SKIP was WITHDRAWN' 'F3: the withdrawal of the green-gate skip is stated where the operator reads it'
Assert-Contains $blockFound 'merge gate is UNCHANGED' 'F3 [kill] the block says plainly that this is advisory -- it must not read as a block'
Assert-Contains $blockFound 'dead_property' 'F3: the finding itself surfaces, not just a count'
$blockSoftOnly = Format-CoderTestQaBlock -Result (& $mkResult 'findings' $true 0 @(@{ Class='accommodated_assertion'; Message='the comment names 0.0353 which the band does not require'; Subject='line:40' }) 3 '' $true) -SkipWithdrawn $false
Assert-Contains $blockSoftOnly 'accommodated_assertion' 'F4: a SOFT finding still surfaces (an advisory finding that appears nowhere is the same defect one layer along)'
Assert-NotContains $blockSoftOnly 'WITHDRAWN' 'F4 [kill] a soft-only finding does NOT claim the skip was withdrawn (heuristics never force the slow 30B leg)'

# The report is scraped by ^TESTS:/^VERIFY:/^RESULT: anchors (run-fleet.ps1, watch.py,
# acceptance.parse_task_report). A finding's own text must not be able to impersonate one.
$hostile = & $mkResult 'findings' $true 0 @(@{ Class='vacuous_test'; Message="RESULT: MERGED into your project"; Subject='TESTS: pass' }) 1 '' $true
$blockHostile = Format-CoderTestQaBlock -Result $hostile
$hostileLines = @($blockHostile -split "`n")
Assert-Eq $false ([bool](@($hostileLines | Select-Object -Skip 1 | Where-Object { $_.Trim() -match '^(TESTS|VERIFY|RESULT|REVIEW VERDICT):' }).Count)) 'F5 [kill] no continuation line can impersonate a scraped report key, even when the finding text tries to'
Assert-True ($hostileLines[0].StartsWith('CODER TEST QA:')) 'F5: the block leads with its own unambiguous key'

$unmeasuredProp = Format-CoderTestQaBlock -Result (& $mkResult 'clean' $true 0 @() 2 '' $false)
Assert-Contains $unmeasuredProp 'unexecuted_property' 'F6: an unmeasurable class is DISCLOSED, so a counts map showing 0 cannot read as a measured zero'
Assert-NotContains $unmeasuredProp 'PLACEHOLDER' 'F6: and the disclosure is concrete'

# ----------------------------------------------------------------------------
Section 'The report stays ASCII and the sidecar stays machine-readable, on either PowerShell host'
# coder_test_qa.py writes real prose (em-dashes, curly quotes). Set-Content picks its encoding from the
# HOST, so an unfolded message renders clean on PS 7 and as mojibake on PS 5.1 -- on the one line that
# tells the operator their exam is broken.
$emdash = [char]0x2014
$curly = [char]0x2019
$uni = & $mkResult 'findings' $true 1 @(@{ Class='dead_property'; Message="it defines the property${emdash}but never calls it${curly}s body"; Subject='t.py::x' }) 1 '' $true
$blockUni = Format-CoderTestQaBlock -Result $uni
Assert-True ([regex]::IsMatch($blockUni, '^[\x09\x0A\x0D\x20-\x7E]*$')) 'A1 [kill] the report block is pure ASCII -- no host-dependent byte reaches the operator'
Assert-Contains $blockUni 'property--but never' 'A1: the em-dash is SUBSTITUTED, not dropped (the message still reads)'
Assert-Contains $blockUni "it's body" 'A1: and so is the curly quote'
Assert-Contains $blockUni 'dead_property' 'A1 [kill] folding did not eat the finding'
$unavailUni = New-CoderTestQaResult -Detail "the scanner emitted no JSON${emdash}traceback"
Assert-True ([regex]::IsMatch((Format-CoderTestQaBlock -Result $unavailUni), '^[\x09\x0A\x0D\x20-\x7E]*$')) 'A2 [kill] python own last words are folded too -- the degraded path is the one most likely to carry odd bytes'

$sidecarPath = Join-Path ([System.IO.Path]::GetTempPath()) ("coder-test-qa-sidecar-" + [guid]::NewGuid().ToString('N').Substring(0, 8) + '.json')
try {
    $wrote = Write-CoderTestQaSidecar -Path $sidecarPath -Json (ConvertTo-CoderTestQaSidecarJson -Result $uni)
    Assert-True $wrote 'A3: the sidecar writes'
    $bytes = [System.IO.File]::ReadAllBytes($sidecarPath)
    Assert-False (($bytes.Length -ge 3) -and ($bytes[0] -eq 0xEF) -and ($bytes[1] -eq 0xBB) -and ($bytes[2] -eq 0xBF)) 'A3 [kill] no UTF-8 BOM -- a BOM makes python json.load raise, and evidence a consumer cannot open is no evidence'
    $back = [System.IO.File]::ReadAllText($sidecarPath, [System.Text.UTF8Encoding]::new($false)) | ConvertFrom-Json
    Assert-Eq 'findings' $back.status 'A3: and it round-trips as JSON'
    Assert-Eq 1 $back.hard 'A3: with the hard count intact'
} finally { Remove-Item -LiteralPath $sidecarPath -Force -ErrorAction SilentlyContinue }
Assert-True (Write-CoderTestQaSidecar -Path $sidecarPath -Json '{}') 'A4: a fresh path writes cleanly'
Remove-Item -LiteralPath $sidecarPath -Force -ErrorAction SilentlyContinue
Assert-False (Write-CoderTestQaSidecar -Path (Join-Path (Join-Path $env:TEMP 'no-such-dir-1195') 'x.json') -Json '{}') 'A5 [kill] an unwritable path returns $false and warns rather than throwing -- a sidecar failure must not take down a dispatch, and must not pass silently either'

# ----------------------------------------------------------------------------
Section 'The real scanner over real crafted tests (or, absent the module, the unavailable path)'
# Fixtures reproduce the two HARD fingerprints and one SOFT one on disk, so this exercises the actual
# module through the actual CLI -- not a mock of its JSON.
$fixRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("coder-test-qa-fixture-" + [guid]::NewGuid().ToString('N').Substring(0, 8))
$fixTests = Join-Path $fixRoot 'tests'
New-Item -ItemType Directory -Force $fixTests | Out-Null
$emptyRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("coder-test-qa-empty-" + [guid]::NewGuid().ToString('N').Substring(0, 8))
New-Item -ItemType Directory -Force $emptyRoot | Out-Null
try {
    # HARD 1 -- the 07-29 shape: a @given property defined inside a test and never called. Pytest
    # collects the outer function, which generates nothing and passes in microseconds.
    Set-Content -Path (Join-Path $fixTests 'test_dead_property.py') -Encoding ASCII -Value @'
from hypothesis import given, strategies as st


def test_property_based_conversions():
    @given(st.floats(min_value=0.1, max_value=100))
    def test_conversion_consistency(value):
        assert value > 0
'@
    # HARD 2 -- a collected test with no assert, no raise, no pytest.raises. It cannot fail.
    Set-Content -Path (Join-Path $fixTests 'test_vacuous.py') -Encoding ASCII -Value @'
def save_cards(cards, path=None):
    return path or "cards.json"


def test_default_save_path():
    save_cards([], None)
    # If we got here without error, the default path handling works
'@
    # SOFT -- the accommodated assertion proper: the comment names the answer the band declines to pin.
    Set-Content -Path (Join-Path $fixTests 'test_accommodated.py') -Encoding ASCII -Value @'
def convert(value, frm, to):
    return value * 0.01408


def test_gram_to_ounce():
    result = convert(1, 'gram', 'ounce')
    # The exact conversion should be ~0.0353 oz per gram, but we'll accept a reasonable range
    assert 0.01 <= result <= 0.1
'@
    # A genuinely sound test, so a scanner that flagged everything would fail the counts below.
    Set-Content -Path (Join-Path $fixTests 'test_sound.py') -Encoding ASCII -Value @'
def add(a, b):
    return a + b


def test_add():
    assert add(2, 2) == 4
'@

    $real = Invoke-CoderTestQa -Repo $fixRoot -BlarAiRepo $BlarAiRepo
    if ($real.Measured) {
        Assert-Eq 'findings' $real.Status 'R1: the real scanner returns a verdict over the crafted exam'
        Assert-True ($real.Hard -ge 2) "R2: both PROVABLE fingerprints are counted hard (got $($real.Hard))"
        $classes = @(@($real.Findings) | ForEach-Object { $_.Class })
        Assert-True ($classes -contains 'dead_property') 'R3: the never-called @given property is found (F2 of #1170)'
        Assert-True ($classes -contains 'vacuous_test') 'R4: the test that cannot fail is found'
        Assert-True ($classes -contains 'accommodated_assertion') 'R5: the widened band beside a named answer is found (F1 of #1170 -- the 2.5x converter)'
        Assert-True ($real.FilesScanned -ge 4) "R6: every crafted test file was examined (got $($real.FilesScanned))"
        Assert-False ([bool]$real.PropertyExecutionMeasured) 'R7: without --stats the property-EXECUTION class is reported unmeasured, not zero'
        Assert-True ([bool]$real.Json) 'R8: the raw scanner JSON is retained for the sidecar'

        # The control, not the subject: a finding against the SEALED job oracle would park a run whose
        # real defect is elsewhere, so the scanner must exclude it. Prove the exclusion is live.
        Set-Content -Path (Join-Path $fixTests 'test_job_acceptance.py') -Encoding ASCII -Value @'
def test_sealed_oracle_placeholder():
    pass
'@
        $withOracle = Invoke-CoderTestQa -Repo $fixRoot -BlarAiRepo $BlarAiRepo
        Assert-Eq $real.Hard $withOracle.Hard 'R9 [kill] adding a vacuous SEALED job oracle changes NOTHING -- the oracle is the control, never the subject'

        $emptyScan = Invoke-CoderTestQa -Repo $emptyRoot -BlarAiRepo $BlarAiRepo
        Assert-Eq 'no-tests' $emptyScan.Status 'R10 [kill] a candidate with no python tests is `no-tests`, NOT `clean`'
        Assert-Eq 0 $emptyScan.Hard 'R10: and it forces nothing'

        $prevSwitch = $env:BLARAI_CODER_TEST_QA
        try {
            $env:BLARAI_CODER_TEST_QA = '0'
            $off = Invoke-CoderTestQa -Repo $fixRoot -BlarAiRepo $BlarAiRepo
            Assert-Eq 'disabled' $off.Status 'R11: the kill-switch is honoured'
            Assert-False ([bool]$off.Measured) 'R11 [kill] a switched-off control is an ABSENT measurement, not a clean exam'
            Assert-Eq 0 $off.Hard 'R11: and it forces nothing'
        } finally {
            if ($null -eq $prevSwitch) { Remove-Item Env:\BLARAI_CODER_TEST_QA -ErrorAction SilentlyContinue }
            else { $env:BLARAI_CODER_TEST_QA = $prevSwitch }
        }
    } else {
        # shared/fleet/coder_test_qa.py is not importable from this BlarAI checkout (it lands with #1170).
        # That is not a skip: it is the degraded path, and the properties that matter are asserted HERE.
        Write-Host "  NOTE: shared/fleet/coder_test_qa.py is not importable from $BlarAiRepo -- asserting the DEGRADED contract instead." -ForegroundColor Yellow
        Assert-Eq 'unavailable' $real.Status 'R1-alt: an absent/unimportable module -> unavailable'
        Assert-False ([bool]$real.Measured) 'R2-alt [kill] and NEVER measured -- an absent scanner cannot certify an exam'
        Assert-Eq 0 $real.Hard 'R3-alt: an absent scanner forces no review leg'
        Assert-True ([bool]$real.Detail) 'R4-alt [kill] python own last words are carried, so the operator can see WHY it did not run'
        Assert-Contains (Format-CoderTestQaBlock -Result $real) 'NOT MEASURED' 'R5-alt: and the report block says so'
    }
} finally {
    Remove-Item -Recurse -Force $fixRoot -ErrorAction SilentlyContinue
    Remove-Item -Recurse -Force $emptyRoot -ErrorAction SilentlyContinue
}

# ----------------------------------------------------------------------------
Section 'Attribution (#1201): a task is charged only for the exam IT wrote'
# The scan used to read the WHOLE delivered tree. On a clean BlarAI checkout that is 419 files and
# hard=48, so every green-gated task on any repo with history lost its review-skip forever -- a
# review-agent run plus up to two build/test/verify FIX laps, spent on tests the coder never wrote.
# Inside the battery the same defect fires in miniature: the scaffold is fresh per NIGHT, not per TASK,
# so on a five-task plan task N is charged for the vacuous tests of tasks 1..N-1.
function New-CtqGitRepo {
    param([Parameter(Mandatory)][string]$Path)
    New-Item -ItemType Directory -Force $Path | Out-Null
    git -C $Path init -b main 2>&1 | Out-Null
    return $Path
}
function Add-CtqCommit {
    param([Parameter(Mandatory)][string]$Repo, [Parameter(Mandatory)][string]$Rel,
          [Parameter(Mandatory)][string]$Body, [string]$Message = 'commit')
    $full = Join-Path $Repo $Rel
    New-Item -ItemType Directory -Force (Split-Path $full -Parent) | Out-Null
    Set-Content -Path $full -Encoding ASCII -Value $Body
    git -C $Repo add -- $Rel 2>&1 | Out-Null
    git -C $Repo -c user.email='test@local' -c user.name='test' -c commit.gpgsign=false commit -m $Message 2>&1 | Out-Null
    return (git -C $Repo rev-parse HEAD 2>$null | Out-String).Trim()
}

$VACUOUS_SRC = @'
def save_cards(cards, path=None):
    return path or "cards.json"


def test_default_save_path():
    save_cards([], None)
    # If we got here without error, the default path handling works
'@
$SOUND_SRC = @'
def add(a, b):
    return a + b


def test_add():
    assert add(2, 2) == 4
'@

$night = Join-Path ([System.IO.Path]::GetTempPath()) ("ctq-night-" + [guid]::NewGuid().ToString('N').Substring(0, 8))
$stubRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("ctq-legacy-" + [guid]::NewGuid().ToString('N').Substring(0, 8))
try {
    [void](New-CtqGitRepo -Path $night)
    [void](Add-CtqCommit -Repo $night -Rel 'README.md' -Body 'night' -Message 'baseline before task: task-1')
    # Task 1 ships an exam that cannot fail. Tasks 2 and 3 ship sound ones. Each task's baseline is HEAD
    # at the moment it starts -- exactly how new-agent-task.ps1 computes $codeBase.
    $afterTask1 = Add-CtqCommit -Repo $night -Rel 'tests/test_task1.py' -Body $VACUOUS_SRC -Message 'task 1'
    $afterTask2 = Add-CtqCommit -Repo $night -Rel 'tests/test_task2.py' -Body $SOUND_SRC -Message 'task 2'
    [void](Add-CtqCommit -Repo $night -Rel 'tests/test_task3.py' -Body $SOUND_SRC -Message 'task 3')

    $unscoped = Invoke-CoderTestQa -Repo $night -BlarAiRepo $BlarAiRepo
    $scoped = Invoke-CoderTestQa -Repo $night -BlarAiRepo $BlarAiRepo -Since $afterTask2

    if ($unscoped.Measured -and ("$($unscoped.ScopeMode)" -eq 'full-tree')) {
        # The TOGGLE first: without a baseline the same tree really does carry task 1's defect. Every
        # assertion below is only meaningful because this one holds -- otherwise "task 3 is clean" would
        # be proving that the scanner had gone blind.
        Assert-Eq 'findings' $unscoped.Status 'S1 [toggle] unscoped, the tree carries the earlier task''s vacuous test'
        Assert-True ($unscoped.Hard -ge 1) "S1 [toggle] and it is PROVEN (hard=$($unscoped.Hard))"
        Assert-Eq 3 $unscoped.FilesScanned 'S1 [toggle] all three tasks'' test files were read'

        Assert-True ([bool]$scoped.Measured) 'S2: the scoped scan is a real verdict'
        Assert-Eq 'changed-since' $scoped.ScopeMode 'S2: scoped to what THIS task changed'
        Assert-Eq 'clean' $scoped.Status 'S2 [kill] task 3''s exam is sound, so task 3 is charged with NOTHING -- the ticket''s own predicate'
        Assert-Eq 0 $scoped.Hard 'S2 [kill] and no FIX lap is spent on another task''s test'
        Assert-Eq 1 $scoped.FilesScanned 'S2: exactly the one file task 3 wrote'

        # Scoping must not become an escape hatch: the task that DID write the defect still pays.
        $owner = Invoke-CoderTestQa -Repo $night -BlarAiRepo $BlarAiRepo -Since $afterTask1
        Assert-Eq 'clean' $owner.Status 'S3: task 2 (which wrote a sound test) is clean'
        git -C $night checkout --detach $afterTask1 2>&1 | Out-Null
        $charged = Invoke-CoderTestQa -Repo $night -BlarAiRepo $BlarAiRepo -Since (git -C $night rev-parse 'HEAD~1' | Out-String).Trim()
        git -C $night checkout main 2>&1 | Out-Null
        Assert-Eq 'findings' $charged.Status 'S3 [kill] the task that WROTE the vacuous test is still charged for it -- scoping narrows attribution, it does not grant amnesty'
        Assert-True ($charged.Hard -ge 1) 'S3 [kill] and still as a PROVEN defect'

        # The decision this ticket had to make: an undeterminable scope yields NO verdict. Not a silent
        # widening to the whole tree (the mis-attribution wearing a different hat) and not a silent zero
        # (worse -- it reads as a clean exam).
        $bad = Invoke-CoderTestQa -Repo $night -BlarAiRepo $BlarAiRepo -Since ('deadbeef' * 5)
        Assert-Eq 'unavailable' $bad.Status 'S4 [kill] a baseline that cannot be resolved -> unavailable'
        Assert-False ([bool]$bad.Measured) 'S4 [kill] and NEVER measured -- a caller gating on .Measured cannot read it as a clean exam'
        Assert-Eq 0 $bad.Hard 'S4: an unresolved scope forces no review leg'
        Assert-True ([bool]$bad.Detail) 'S4 [kill] the reason is NAMED, so the operator can act on it'
        Assert-Contains (Format-CoderTestQaBlock -Result $bad) 'NOT MEASURED' 'S4 [kill] and the operator-facing block says NOT MEASURED, never `clean`'
        Assert-NotContains (Format-CoderTestQaBlock -Result $bad) 'CODER TEST QA: clean' 'S4 [kill] an unresolvable scope must not borrow the clean wording'
        Assert-Eq 0 $bad.FilesScanned 'S4 [kill] nothing was scanned -- it did not quietly fall back to the whole tree'

        $inject = Invoke-CoderTestQa -Repo $night -BlarAiRepo $BlarAiRepo -Since '--upload-pack=whoami'
        Assert-Eq 'unavailable' $inject.Status 'S5 [kill] a baseline that is not a plain commit id or branch name is refused, not passed to git'
        Assert-False ([bool]$inject.Measured) 'S5 [kill] and yields no verdict'

        # Scoping changes what a zero MEANS, so the sentence reporting it has to change too. In a tree
        # that has tests, "no python test files under the candidate" would now be false -- and the true
        # fact is the more useful one: this task shipped no exam for its own work.
        $beforeCodeOnly = (git -C $night rev-parse HEAD | Out-String).Trim()
        [void](Add-CtqCommit -Repo $night -Rel 'app/widget.py' -Body "def widget():`n    return 1" -Message 'task 4: code, no test')
        $noExam = Invoke-CoderTestQa -Repo $night -BlarAiRepo $BlarAiRepo -Since $beforeCodeOnly
        Assert-Eq 'no-tests' $noExam.Status 'S11 [kill] a task that changed code but wrote no test is `no-tests`, not `clean` -- the tree HAS tests, they just are not this task''s'
        Assert-Contains $noExam.Detail 'wrote no exam' 'S11 [kill] and the detail states the task-level fact, not the tree-level one it would now be wrong about'
        Assert-Contains (Format-CoderTestQaBlock -Result $noExam) 'NO EXAM' 'S11: which reaches the operator-facing block'

        # The caller decides there ARE changes from a COMMIT COUNT against the baseline (Test-CaptureFault
        # counts with git rev-list); the scope is a CONTENT diff against the same baseline. A coder that
        # adds something and then reverts it satisfies the first and empties the second, so the two
        # legitimately disagree -- which is why no guard refuses an empty change set here.
        $beforeNetZero = (git -C $night rev-parse HEAD | Out-String).Trim()
        [void](Add-CtqCommit -Repo $night -Rel 'app/scratch.py' -Body 'x = 1' -Message 'task 5: add')
        git -C $night rm -q -- 'app/scratch.py' 2>&1 | Out-Null
        git -C $night -c user.email='test@local' -c user.name='test' -c commit.gpgsign=false commit -m 'task 5: and revert' 2>&1 | Out-Null
        $netZero = Invoke-CoderTestQa -Repo $night -BlarAiRepo $BlarAiRepo -Since $beforeNetZero
        Assert-Eq 'no-tests' $netZero.Status 'S12: commits that net to nothing still leave no exam to examine'
        Assert-Eq 0 $netZero.ScopeChangedFiles 'S12: with an empty change set'
        Assert-Contains $netZero.Detail 'NO net content change' 'S12 [kill] and the detail names THAT fact, not a vacuous "0 file(s), none a test" -- the commit-count and content-diff readings legitimately disagree here, and the operator is told which one they are looking at'
    } else {
        # This BlarAI checkout's scanner predates the #1201 scoping, or is absent. That is not a skip:
        # it is the CROSS-REPO SKEW case, and the fail-closed contract is asserted here instead.
        Write-Host "  NOTE: $BlarAiRepo's coder_test_qa reports no scope -- asserting the cross-repo SKEW contract instead." -ForegroundColor Yellow
        Assert-Eq 'unavailable' $scoped.Status 'S1-alt [kill] a scanner that cannot scope must not return a verdict for a scoped request'
        Assert-False ([bool]$scoped.Measured) 'S2-alt [kill] a whole-tree count is not an attribution, so it is NOT measured'
        Assert-Eq 0 $scoped.Hard 'S3-alt: and it forces no review leg on another task''s tests'
        Assert-True ([bool]$scoped.Detail) 'S4-alt [kill] the skew is NAMED rather than silently tolerated'
    }

    # The version-skew guard, proved against a scanner that really does emit the pre-#1201 payload.
    # The stub is a whole BlarAI-root shape: a hardlinked interpreter (no elevation, no copy of the
    # venv) plus a module that answers in the old format.
    $stubVenv = Join-Path $stubRoot '.venv'
    New-Item -ItemType Directory -Force (Join-Path $stubVenv 'Scripts') | Out-Null
    New-Item -ItemType Directory -Force (Join-Path $stubRoot 'shared\fleet') | Out-Null
    $realVenv = Join-Path $BlarAiRepo '.venv'
    $stubReady = $false
    if (Test-Path (Join-Path $realVenv 'Scripts\python.exe')) {
        try {
            New-Item -ItemType HardLink -Path (Join-Path $stubVenv 'Scripts\python.exe') `
                     -Target (Join-Path $realVenv 'Scripts\python.exe') -ErrorAction Stop | Out-Null
            Copy-Item (Join-Path $realVenv 'pyvenv.cfg') (Join-Path $stubVenv 'pyvenv.cfg') -ErrorAction SilentlyContinue
            Set-Content -Path (Join-Path $stubRoot 'shared\__init__.py') -Encoding ASCII -Value ''
            Set-Content -Path (Join-Path $stubRoot 'shared\fleet\__init__.py') -Encoding ASCII -Value ''
            Set-Content -Path (Join-Path $stubRoot 'shared\fleet\coder_test_qa.py') -Encoding ASCII -Value @'
import json

# The pre-#1201 payload: a verdict over the WHOLE tree, with no `scope` key to say so.
print(json.dumps({
    "enabled": True, "hard": 1, "files_scanned": 3, "unparsed": [],
    "counts": {"dead_property": 0, "vacuous_test": 1, "accommodated_assertion": 0,
               "decorative_hypothesis": 0, "unexecuted_property": 0},
    "findings": [{"class": "vacuous_test", "message": "cannot fail", "subject": "test_task1.py::t"}],
}))
'@
            $stubReady = $true
        } catch { Write-Host "  NOTE: could not build the legacy-scanner stub ($($_.Exception.Message))." -ForegroundColor Yellow }
    }
    if ($stubReady) {
        $legacyScoped = Invoke-CoderTestQa -Repo $night -BlarAiRepo $stubRoot -Since $afterTask2
        Assert-Eq 'unavailable' $legacyScoped.Status 'S6 [kill] a scanner that answers WITHOUT a scope cannot satisfy a scoped request -- the two repos are versioned independently, so the seam checks rather than assumes'
        Assert-False ([bool]$legacyScoped.Measured) 'S6 [kill] and its whole-tree hard=1 never reaches the review decision as this task''s'
        Assert-Eq 0 $legacyScoped.Hard 'S6 [kill] the mis-attributed finding is dropped, not passed through'
        Assert-Contains $legacyScoped.Detail 'predates' 'S6: the skew is named in words the operator can act on'

        $legacyUnscoped = Invoke-CoderTestQa -Repo $night -BlarAiRepo $stubRoot
        Assert-True ([bool]$legacyUnscoped.Measured) 'S7 [kill] the guard fires ONLY on a scoped request -- an unscoped caller of an old scanner still gets its whole-tree verdict, so the check is a version gate and not a blanket refusal'
        Assert-Eq 1 $legacyUnscoped.Hard 'S7: with the finding intact'
    }

    # Disclosure: the operator-facing block and the sidecar must SAY which question was answered.
    $mkScoped = New-CoderTestQaResult -Status 'findings'
    $mkScoped.Measured = $true; $mkScoped.Hard = 1; $mkScoped.FilesScanned = 2
    $mkScoped.PropertyExecutionMeasured = $true
    $mkScoped.ScopeMode = 'changed-since'; $mkScoped.ScopeChangedFiles = 7
    $mkScoped.Findings = @(@{ Class = 'vacuous_test'; Message = 'cannot fail'; Subject = 't.py::x' })
    $blockScoped = Format-CoderTestQaBlock -Result $mkScoped
    Assert-Contains $blockScoped 'THIS task changed' 'S8: a scoped verdict says the findings are this task''s'
    Assert-Contains $blockScoped '7 file(s)' 'S8: and how wide the attribution was'

    $mkTree = New-CoderTestQaResult -Status 'findings'
    $mkTree.Measured = $true; $mkTree.Hard = 48; $mkTree.FilesScanned = 419
    $mkTree.PropertyExecutionMeasured = $true; $mkTree.ScopeMode = 'full-tree'
    $mkTree.Findings = @(@{ Class = 'vacuous_test'; Message = 'cannot fail'; Subject = 't.py::x' })
    $blockTree = Format-CoderTestQaBlock -Result $mkTree
    Assert-Contains $blockTree 'WHOLE delivered tree' 'S9 [kill] an unscoped verdict SAYS it is unscoped -- this is the line that made "the coder''s OWN exam carries 48 PROVEN defect(s)" a false sentence'
    Assert-Contains $blockTree 'NOT attributed to this task alone' 'S9 [kill] in words, not in a field the operator would have to know to look for'

    $sidecarScoped = ConvertTo-CoderTestQaSidecarJson -Result $mkScoped | ConvertFrom-Json
    Assert-Eq 'changed-since' $sidecarScoped.scope_mode 'S10: the sidecar carries the attribution as a first-class field'
    Assert-Eq 7 $sidecarScoped.scope_changed_files 'S10: with the width of the change set'
} finally {
    Remove-Item -Recurse -Force $night -ErrorAction SilentlyContinue
    Remove-Item -Recurse -Force $stubRoot -ErrorAction SilentlyContinue
}

# ----------------------------------------------------------------------------
Section 'Wiring: new-agent-task.ps1 runs the scan at the right seam and lets it withdraw the skip'
$nat = Get-Content "$PSScriptRoot\new-agent-task.ps1" -Raw
Assert-True ([regex]::IsMatch($nat, '\$coderQa\s*=\s*Invoke-CoderTestQa -Repo \$wt -BlarAiRepo \$BlarAiRepo')) 'W1 wiring: the scan runs against the SELECTED candidate worktree ($wt), which is what would merge'
$iScan = $nat.IndexOf('Invoke-CoderTestQa')
$iSkip = $nat.IndexOf('Review SKIPPED')
$iSelect = $nat.IndexOf('$bon.Selected')
Assert-True (($iScan -gt 0) -and ($iSkip -gt 0) -and ($iScan -lt $iSkip)) 'W2 [kill] the scan happens BEFORE the review-skip decision -- after it, the skip has already been taken and the finding changes nothing'
Assert-True (($iSelect -gt 0) -and ($iScan -gt $iSelect)) 'W3 [kill] and AFTER best-of-N selection -- before it, $wt is the baseline holder in the concurrent path, not the winner'
Assert-True ([regex]::IsMatch($nat, 'Test-ShouldRunReview -HasChanges \$hasChanges -VerifyResult \$verifyResult -TestResult \$testResult -CoderTestHard \$coderTestHard')) 'W4 wiring: the hard count reaches the review decision'
Assert-True ([regex]::IsMatch($nat, '(?m)^TESTS: \$testResult[^\r\n]*\r?\n\$coderQaBlock\r?$')) 'W5 wiring: the block is written into the TASK REPORT the operator reads, directly under the TESTS line it qualifies'
Assert-True ([regex]::IsMatch($nat, 'Write-CoderTestQaSidecar -Path \$coderQaSidecar -Json \(ConvertTo-CoderTestQaSidecarJson')) 'W6 wiring: and into the machine-readable sidecar beside the report'
Assert-True ([regex]::IsMatch($nat, 'coder-test-qa\.json')) 'W7 wiring: the sidecar sits beside the report, matching the existing .agent.log/.review.log naming'
Assert-True ([regex]::IsMatch($nat, 'Review RUNS despite GREEN gates')) 'W8 wiring: when the skip is withdrawn the console says so -- it must not still print "Review SKIPPED"'
# The whole posture in one assertion: this layer must never touch the merge authority.
Assert-True ([regex]::IsMatch($nat, 'Test-ShouldMerge -HasChanges \$hasChanges')) 'W9: the merge decision is still Test-ShouldMerge'
$mergeCall = [regex]::Match($nat, '\$mergeDecision = Test-ShouldMerge[\s\S]{0,400}?\r?\n\r?\n')
Assert-NotContains $mergeCall.Value 'coderTestHard' 'W10 [kill] the coder-test verdict is NOT an input to the merge gate -- advisory by design; a false block costs an unattended night'
Assert-NotContains $mergeCall.Value 'coderQa' 'W10b [kill] nor does the result object leak into the merge decision'
# A FIX lap rewrites the tree, so the recorded verdict must describe what actually merges.
Assert-True (([regex]::Matches($nat, 'Invoke-CoderTestQa')).Count -ge 2) 'W11: the exam is RE-examined after a review-FIX lap, so the report describes the tree that merges (and a repaired exam stops being charged for it)'
# #1201: the scoping is only worth building if the dispatch actually asks for it. EVERY call site must
# pass the baseline -- a single unscoped one silently restores the whole-tree attribution on that path.
$natCalls = @([regex]::Matches($nat, 'Invoke-CoderTestQa[^\r\n]*'))
Assert-True ($natCalls.Count -ge 2) 'W12: both scan sites are present'
Assert-Eq $natCalls.Count (@($natCalls | Where-Object { $_.Value -match '-Since \$codeBase' }).Count) 'W12 [kill] EVERY dispatch call passes -Since $codeBase -- one unscoped call site puts task N back on the hook for tasks 1..N-1'
# $codeBase is the anchor the rest of the task already measures against; re-deriving it here would let
# the scan and the no-op/resample checks disagree about where this task began.
Assert-True ([regex]::IsMatch($nat, '(?m)^\$codeBase = \(git -C \$wt rev-parse HEAD')) 'W13 [kill] and $codeBase is still the coder BASELINE commit, the same anchor $hasChanges and a resample use'
$iBase = $nat.IndexOf('$codeBase = (git -C $wt rev-parse HEAD')
Assert-True (($iBase -ge 0) -and ($iBase -lt $nat.IndexOf('Invoke-CoderTestQa'))) 'W13: computed before the scan needs it'

# ----------------------------------------------------------------------------
Section 'Result'
Write-Host ("  Passed:  {0}" -f $script:Pass) -ForegroundColor Green
if ($script:Fail) {
    Write-Host ("  Failed:  {0}" -f $script:Fail) -ForegroundColor Red
    $script:Failures | ForEach-Object { Write-Host "    - $_" -ForegroundColor Red }
    exit 1
} else {
    Write-Host ''
    Write-Host '  CODER-TEST QA: VALIDATED. The exam the candidate wrote for itself is examined before the review decision; a PROVEN defect withdraws the green-gate skip, an unmeasured scan can never read as a clean one, and the merge authority is untouched.' -ForegroundColor Green
    exit 0
}
