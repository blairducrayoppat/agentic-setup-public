#requires -Version 5.1
<#
.SYNOPSIS
  Verify + validate the fleet's REVIEW-FEEDBACK loop (the review half of the unified multi-pass loop).

.DESCRIPTION
  Review-feedback fixes a build that PASSES but the code reviewer says FIX FIRST (logic/completeness
  the build gate can't see). The build dimension is now best-of-N (#689): N independent candidates, the
  deterministic gate selects the winner. The SELECTED candidate is then REVIEWED in a separate bounded
  loop that feeds the reviewer's FIX-FIRST findings back for another pass, until the reviewer says MERGE
  or the review budget runs out.

  The pure piece that REMAINS lives in fleet-lib.ps1, unit-tested without a model:
    - Add-ReviewFeedback  : append the reviewer's findings to the coder's prompt for the next pass.
  (Test-ShouldContinue, the OLD unified build+review multi-pass driver, was retired when best-of-N (#689)
  took over the build dimension and a separate bounded loop took over review; it + its unit tests were
  removed in #696. Its review-dimension INTENT is preserved by the post-selection review while-loop
  asserted in the WIRING section below.)

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
Section 'Wiring: the runner reviews the SELECTED candidate + feeds FIX-FIRST findings back (#689 review loop)'
$nat = Get-Content "$PSScriptRoot\new-agent-task.ps1" -Raw
# #689: the BUILD is now best-of-N (Invoke-BestOfN takes N independent candidates; the gate selects). The
# REVIEW side is a SEPARATE bounded loop AFTER selection -- the FROZEN review side, unchanged in intent. The
# serial Test-ShouldContinue multi-pass loop + error-feedback re-fix are retired (the build dimension is
# best-of-N now); Test-ShouldContinue + its unit tests were REMOVED in #696 (#689 follow-up), its review-
# dimension INTENT preserved by the post-selection review while-loop asserted below. The error-feedback-
# CHAINING assertions (old W11-W15) retire with it: a best-of-N candidate is a FRESH independent sample,
# so there is no build-fix pass to chain concerns onto.
Assert-True ([regex]::IsMatch($nat, '(?m)^\s*\$bon\s*=\s*Invoke-BestOfN\b')) 'W1 wiring: the build is driven by best-of-N (Invoke-BestOfN), replacing the serial multi-pass loop'
Assert-True ([regex]::IsMatch($nat, 'while \(\$hasChanges -and -not \$dispatchCancelled -and \(Test-ShouldRunReview\b')) 'W2 wiring: the review runs in a BOUNDED loop gated by Test-ShouldRunReview (only when gates are not both green) AND skipped on a cancelled dispatch (#771)'
Assert-True ([regex]::IsMatch($nat, 'Add-ReviewFeedback -Prompt \$Prompt -ReviewConcerns \$reviewFindings')) 'W3 wiring: a FIX-FIRST pass feeds the VERDICT-STRIPPED findings ($reviewFindings) back via Add-ReviewFeedback'
Assert-True ([regex]::IsMatch($nat, '\$reviewPass\+\+')) 'W4 wiring: each review-feedback pass spends the review budget ($reviewPass++)'
Assert-True ([regex]::IsMatch($nat, '\$reviewPass -ge \$MaxReviewPasses')) 'W5 wiring: the review-feedback loop is BOUNDED by the separate review budget ($MaxReviewPasses)'
Assert-True ([regex]::IsMatch($nat, "\`$everFixFirst -and \`$verdict -ne 'MERGE'")) 'W6 wiring: a FIX FIRST verdict is made STICKY before the merge decision (no auto-merge on a later UNCLEAR/timeout)'
Assert-True ([regex]::IsMatch($nat, '\$reviewFindings = ')) 'W7 wiring: the findings fed back are the verdict-STRIPPED review lines ($reviewFindings), not the verdict-heavy tail'
Assert-True ([regex]::IsMatch($nat, 'if \(\$secretBlocked -or \$agentTimedOut\) \{ break \}')) 'W8 wiring: a secret/timeout DURING a review-fix pass is TERMINAL -- never refine past it (the retained "never sample/refine past a secret/timeout" posture)'

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
