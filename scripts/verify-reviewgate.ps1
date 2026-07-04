# verify-reviewgate.ps1 - self-test for Test-ShouldRunReview (#687 skip-the-per-pass-review-on-green).
# The deterministic gate decides the merge; a green gate means the slow/over-flagging/hanging 30B
# self-review is pure waste + a stall risk, so it is SKIPPED (the cross-model critic reviews once
# post-merge). The review still RUNS where its verdict actually decides the merge (build-only / no
# behavioral gate). Pure; offline; no model. Exit 0 iff every case matches.
. "$PSScriptRoot\fleet-lib.ps1"

$cases = @(
    @{ n='GREEN gates (verify=pass, test=pass) -> SKIP the self-review';            hc=$true;  vr='pass'; tr='pass'; want=$false }
    @{ n='build-only (verify=pass, test=none) -> RUN (verdict decides the merge)';  hc=$true;  vr='pass'; tr='none'; want=$true  }
    @{ n='no gate ran (verify=none, test=none) -> RUN (the only signal)';           hc=$true;  vr='none'; tr='none'; want=$true  }
    @{ n='verify FAIL -> SKIP (merge is hard-blocked regardless)';                  hc=$true;  vr='fail'; tr='pass'; want=$false }
    @{ n='test FAIL -> SKIP (merge is hard-blocked regardless)';                    hc=$true;  vr='pass'; tr='fail'; want=$false }
    @{ n='test=pass but verify=none -> RUN (not both green)';                       hc=$true;  vr='none'; tr='pass'; want=$true  }
    @{ n='no changes -> SKIP (nothing to review or merge)';                         hc=$false; vr='pass'; tr='pass'; want=$false }
    @{ n='no changes even on a build-only shape -> SKIP';                           hc=$false; vr='pass'; tr='none'; want=$false }
)

$pass = 0; $fail = 0
foreach ($c in $cases) {
    $r = [bool](Test-ShouldRunReview -HasChanges $c.hc -VerifyResult $c.vr -TestResult $c.tr)
    if ($r -eq $c.want) { $pass++; Write-Host "[pass] $($c.n)" -ForegroundColor DarkGreen }
    else { $fail++; Write-Host "[FAIL] $($c.n) -> got $r, expected $($c.want)" -ForegroundColor Red }
}
Write-Host ""
Write-Host "Test-ShouldRunReview: $pass passed, $fail failed (of $($cases.Count))" -ForegroundColor $(if ($fail) { 'Red' } else { 'Green' })
exit $(if ($fail) { 1 } else { 0 })
