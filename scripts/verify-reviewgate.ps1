# verify-reviewgate.ps1 - self-test for Test-ShouldRunReview (#687 skip-the-per-pass-review-on-green).
# The deterministic gate decides the merge; a green gate means the slow/over-flagging/hanging 30B
# self-review is pure waste + a stall risk, so it is SKIPPED (the cross-model critic reviews once
# post-merge). The review still RUNS where its verdict actually decides the merge (build-only / no
# behavioral gate). Pure; offline; no model. Exit 0 iff every case matches.
. "$PSScriptRoot\fleet-lib.ps1"

# #1195 adds $CoderTestHard -- the count of PROVEN defects in the CODER'S OWN exam. Cases 1-8 are the
# pre-#1195 set, re-run through the DEFAULT (parameter omitted) so they lock "the default reproduces
# today's behaviour"; cases 9-16 pin the new dimension. The pairs (1/9/10, 4/12, 5/13, 7/15) are the
# teeth: same inputs, hard flipped, only the green-gate case may change its answer.
$cases = @(
    @{ n='GREEN gates (verify=pass, test=pass) -> SKIP the self-review';            hc=$true;  vr='pass'; tr='pass'; want=$false }
    @{ n='build-only (verify=pass, test=none) -> RUN (verdict decides the merge)';  hc=$true;  vr='pass'; tr='none'; want=$true  }
    @{ n='no gate ran (verify=none, test=none) -> RUN (the only signal)';           hc=$true;  vr='none'; tr='none'; want=$true  }
    @{ n='verify FAIL -> SKIP (merge is hard-blocked regardless)';                  hc=$true;  vr='fail'; tr='pass'; want=$false }
    @{ n='test FAIL -> SKIP (merge is hard-blocked regardless)';                    hc=$true;  vr='pass'; tr='fail'; want=$false }
    @{ n='test=pass but verify=none -> RUN (not both green)';                       hc=$true;  vr='none'; tr='pass'; want=$true  }
    @{ n='no changes -> SKIP (nothing to review or merge)';                         hc=$false; vr='pass'; tr='pass'; want=$false }
    @{ n='no changes even on a build-only shape -> SKIP';                           hc=$false; vr='pass'; tr='none'; want=$false }
    # ---- #1195: a PROVEN defect in the coder's own exam withdraws the green-gate skip ----
    @{ n='#1195 GREEN gates + hard=0 EXPLICIT -> SKIP (byte-identical to the default)';         hc=$true;  vr='pass'; tr='pass'; hard=0; want=$false }
    @{ n='#1195 GREEN gates + hard=1 -> RUN (the exam is proven broken; the reviewer looks)';   hc=$true;  vr='pass'; tr='pass'; hard=1; want=$true  }
    @{ n='#1195 GREEN gates + hard=3 -> RUN (any positive count, not just 1)';                  hc=$true;  vr='pass'; tr='pass'; hard=3; want=$true  }
    @{ n='#1195 [kill] verify FAIL + hard=2 -> SKIP (merge already blocked; no agent churn)';   hc=$true;  vr='fail'; tr='pass'; hard=2; want=$false }
    @{ n='#1195 [kill] test FAIL + hard=2 -> SKIP (merge already blocked; no agent churn)';     hc=$true;  vr='pass'; tr='fail'; hard=2; want=$false }
    @{ n='#1195 [kill] build-only + hard=2 -> RUN, unchanged (it already ran; hard adds nothing)'; hc=$true; vr='pass'; tr='none'; hard=2; want=$true }
    @{ n='#1195 [kill] no changes + hard=5 -> SKIP (nothing to review; hard cannot override)';  hc=$false; vr='pass'; tr='pass'; hard=5; want=$false }
    @{ n='#1195 [kill] negative hard -> SKIP (a garbage count never forces the slow 30B leg)';  hc=$true;  vr='pass'; tr='pass'; hard=-1; want=$false }
)

$pass = 0; $fail = 0
foreach ($c in $cases) {
    if ($c.ContainsKey('hard')) {
        $r = [bool](Test-ShouldRunReview -HasChanges $c.hc -VerifyResult $c.vr -TestResult $c.tr -CoderTestHard $c.hard)
    } else {
        # Parameter OMITTED on purpose: this is the default-preserves-behaviour lock.
        $r = [bool](Test-ShouldRunReview -HasChanges $c.hc -VerifyResult $c.vr -TestResult $c.tr)
    }
    if ($r -eq $c.want) { $pass++; Write-Host "[pass] $($c.n)" -ForegroundColor DarkGreen }
    else { $fail++; Write-Host "[FAIL] $($c.n) -> got $r, expected $($c.want)" -ForegroundColor Red }
}
Write-Host ""
Write-Host "Test-ShouldRunReview: $pass passed, $fail failed (of $($cases.Count))" -ForegroundColor $(if ($fail) { 'Red' } else { 'Green' })
exit $(if ($fail) { 1 } else { 0 })
