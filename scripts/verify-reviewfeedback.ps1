#requires -Version 5.1
<#
.SYNOPSIS
  Verify + validate the fleet's REVIEW-FEEDBACK loop (the review half of the unified multi-pass loop).

.DESCRIPTION
  Error-feedback fixes BUILD failures; review-feedback fixes a build that PASSES but the code reviewer
  says FIX FIRST (logic/completeness the build gate can't see). The runner now makes multiple passes:
  build -> verify -> (if it builds) review -> feed back whatever failed (a compile error OR the review's
  findings) -> next pass, until it builds AND the reviewer says MERGE, or the pass budget runs out.

  The two pure pieces live in fleet-lib.ps1, so they unit-test without a model:
    - Test-ShouldContinue : run another pass? (a build/test failure -> resample/error-feedback, OR a
      builds-but-FIX-FIRST review -> review-feedback; bounded by the pass budget; never on timeout/secret).
      It REUSES the proven Test-ShouldResample for the build dimension.
    - Add-ReviewFeedback  : append the reviewer's findings to the coder's prompt for the next pass.

  Mutation-resistant: each [kill] case fails a specific wrong implementation. Exit 0 if all pass.
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
Section 'Unit tests: Add-ReviewFeedback'
$base = 'Build a calculator.'
$a1 = Add-ReviewFeedback -Prompt $base -ReviewConcerns 'Divide-by-zero is unhandled.'
Assert-Contains $a1 $base 'A1: preserves the original prompt'
Assert-Contains $a1 'Divide-by-zero is unhandled.' 'A1: includes the review findings'
Assert-Contains $a1 'FIX' 'A1: includes a fix banner'
Assert-Eq $base (Add-ReviewFeedback -Prompt $base -ReviewConcerns '')      'A2 [kill] empty concerns -> prompt unchanged'
Assert-Eq $base (Add-ReviewFeedback -Prompt $base -ReviewConcerns "  `n ") 'A2b [kill] whitespace concerns -> unchanged'
$a3 = Add-ReviewFeedback -Prompt $base -ReviewConcerns 'X'
Assert-True ($a3.Length -gt $base.Length) 'A3 [kill] appends (longer than original)'
Assert-True ($a3.StartsWith($base))       'A3 [kill] original prompt preserved at the front (appended, not replaced)'

# ----------------------------------------------------------------------------
Section 'Unit tests: Test-ShouldContinue (the multi-pass decision; dual budgets)'
$RB = @{ ReviewPass = 0; MaxReviewPasses = 2 }   # a default review budget for the build-dimension cases
Assert-True  (Test-ShouldContinue -VerifyResult 'fail' -TestResult 'none' -Verdict 'UNCLEAR'   -TimedOut $false -SecretBlocked $false -Pass 1 -MaxPasses 3 @RB) 'RC1 build FAIL, build budget left -> continue (resample/error-feedback)'
Assert-True  (Test-ShouldContinue -VerifyResult 'pass' -TestResult 'none' -Verdict 'FIX FIRST' -TimedOut $false -SecretBlocked $false -Pass 1 -MaxPasses 3 -ReviewPass 0 -MaxReviewPasses 2) 'RC2 builds but FIX FIRST, review budget left -> continue (review-feedback)'
Assert-False (Test-ShouldContinue -VerifyResult 'pass' -TestResult 'pass' -Verdict 'MERGE'     -TimedOut $false -SecretBlocked $false -Pass 1 -MaxPasses 3 @RB) 'RC3 builds + MERGE -> done'
Assert-False (Test-ShouldContinue -VerifyResult 'pass' -TestResult 'none' -Verdict 'UNCLEAR'   -TimedOut $false -SecretBlocked $false -Pass 1 -MaxPasses 3 @RB) 'RC4 [kill] builds + UNCLEAR -> do NOT loop (only FIX FIRST continues the review dim)'
Assert-False (Test-ShouldContinue -VerifyResult 'fail' -TestResult 'fail' -Verdict 'FIX FIRST' -TimedOut $true  -SecretBlocked $false -Pass 1 -MaxPasses 3 @RB) 'RC5 [kill] TIMEOUT never continues'
Assert-False (Test-ShouldContinue -VerifyResult 'fail' -TestResult 'fail' -Verdict 'FIX FIRST' -TimedOut $false -SecretBlocked $true  -Pass 1 -MaxPasses 3 @RB) 'RC6 [kill] SECRET-block never continues'
Assert-False (Test-ShouldContinue -VerifyResult 'fail' -TestResult 'none' -Verdict 'UNCLEAR'   -TimedOut $false -SecretBlocked $false -Pass 3 -MaxPasses 3 -ReviewPass 0 -MaxReviewPasses 0) 'RC7 [kill] build budget reached (no review budget) -> stop'
Assert-True  (Test-ShouldContinue -VerifyResult 'pass' -TestResult 'none' -Verdict 'FIX FIRST' -TimedOut $false -SecretBlocked $false -Pass 1 -MaxPasses 3 -ReviewPass 1 -MaxReviewPasses 2) 'RC8 builds + FIX FIRST, build budget barely used + review pass 1 of 2 -> continue'
Assert-False (Test-ShouldContinue -VerifyResult 'none' -TestResult 'none' -Verdict 'MERGE'     -TimedOut $false -SecretBlocked $false -Pass 1 -MaxPasses 3 @RB) 'RC9 nothing failed + MERGE -> done'
Assert-False (Test-ShouldContinue -VerifyResult 'pass' -TestResult 'none' -Verdict 'FIX FIRST' -TimedOut $false -SecretBlocked $false -Pass 1 -MaxPasses 3 -ReviewPass 2 -MaxReviewPasses 2) 'RC10 [kill] review budget reached -> stop (build budget still free, but review is spent)'
Assert-True  (Test-ShouldContinue -VerifyResult 'fail' -TestResult 'none' -Verdict 'UNCLEAR'   -TimedOut $false -SecretBlocked $false -Pass 1 -MaxPasses 3 -ReviewPass 2 -MaxReviewPasses 2) 'RC11 [kill] budgets are INDEPENDENT: a build-fail still resamples even when the review budget is spent'

# ----------------------------------------------------------------------------
Section 'Wiring: the runner reviews the SELECTED candidate + feeds FIX-FIRST findings back (#689 review loop)'
$nat = Get-Content "$PSScriptRoot\new-agent-task.ps1" -Raw
# #689: the BUILD is now best-of-N (Invoke-BestOfN takes N independent candidates; the gate selects). The
# REVIEW side is a SEPARATE bounded loop AFTER selection -- the FROZEN review side, unchanged in intent. The
# serial Test-ShouldContinue multi-pass loop + error-feedback re-fix are retired (the build dimension is
# best-of-N now; Test-ShouldContinue's UNIT behaviour is still proven above, the function is dormant, slated
# for cleanup -- #689 follow-up). The error-feedback-CHAINING assertions (old W11-W15) retire with it: a
# best-of-N candidate is a FRESH independent sample, so there is no build-fix pass to chain concerns onto.
Assert-True ([regex]::IsMatch($nat, '(?m)^\s*\$bon\s*=\s*Invoke-BestOfN\b')) 'W1 wiring: the build is driven by best-of-N (Invoke-BestOfN), replacing the serial multi-pass loop'
Assert-True ([regex]::IsMatch($nat, 'while \(\$hasChanges -and \(Test-ShouldRunReview\b')) 'W2 wiring: the review runs in a BOUNDED loop gated by Test-ShouldRunReview (only when the gates are not both green)'
Assert-True ([regex]::IsMatch($nat, 'Add-ReviewFeedback -Prompt \$Prompt -ReviewConcerns \$reviewFindings')) 'W3 wiring: a FIX-FIRST pass feeds the VERDICT-STRIPPED findings ($reviewFindings) back via Add-ReviewFeedback'
Assert-True ([regex]::IsMatch($nat, '\$reviewPass\+\+')) 'W4 wiring: each review-feedback pass spends the review budget ($reviewPass++)'
Assert-True ([regex]::IsMatch($nat, '\$reviewPass -ge \$MaxReviewPasses')) 'W5 wiring: the review-feedback loop is BOUNDED by the separate review budget ($MaxReviewPasses)'
Assert-True ([regex]::IsMatch($nat, "\`$everFixFirst -and \`$verdict -ne 'MERGE'")) 'W6 wiring: a FIX FIRST verdict is made STICKY before the merge decision (no auto-merge on a later UNCLEAR/timeout)'
Assert-True ([regex]::IsMatch($nat, '\$reviewFindings = ')) 'W7 wiring: the findings fed back are the verdict-STRIPPED review lines ($reviewFindings), not the verdict-heavy tail'
Assert-True ([regex]::IsMatch($nat, 'if \(\$secretBlocked -or \$agentTimedOut\) \{ break \}')) 'W8 wiring: a secret/timeout DURING a review-fix pass is TERMINAL -- never refine past it (the retained "never sample/refine past a secret/timeout" posture)'
Assert-True ([regex]::IsMatch($nat, "\`$priorReviewConcerns = ''")) 'W9 wiring: $priorReviewConcerns is initialised (the review side keeps its own state; best-of-N candidates do not chain it)'

# ----------------------------------------------------------------------------
Section 'Result'
Write-Host ("  Passed:  {0}" -f $script:Pass) -ForegroundColor Green
if ($script:Fail) {
    Write-Host ("  Failed:  {0}" -f $script:Fail) -ForegroundColor Red
    $script:Failures | ForEach-Object { Write-Host "    - $_" -ForegroundColor Red }
    exit 1
} else {
    Write-Host ''
    Write-Host '  REVIEW-FEEDBACK: VALIDATED. A building-but-FIX-FIRST attempt is fed the findings and re-tried, bounded by the pass budget.' -ForegroundColor Green
    exit 0
}
