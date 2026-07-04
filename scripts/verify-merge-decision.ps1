# verify-merge-decision.ps1 - self-test for Test-ShouldMerge (FIX C, #670).
# Mutation-resistant: asserts the build-only-gate FIRES on a clean dotnet/inconclusive review AND
# does NOT fire on any adversarial mutant (security/anomaly/build blocks, python/node, polyglot,
# verify-not-strictly-pass, explicit FIX FIRST). The winui-smoke run is reconstructed as the regression.
# Pure; offline; no model/git. Exit 0 iff every case matches.
. "$PSScriptRoot\fleet-lib.ps1"

$cases = @(
    @{ n='winui-smoke regression: clean dotnet build, inconclusive review -> MERGE'; hc=$true;  sb=$false; at=$false; ls=$false; tr='none'; vr='pass'; vd='UNCLEAR';   eco=@('dotnet');          em=$true;  ev='build-only-gate' }
    @{ n='explicit MERGE (python) -> review path';                                    hc=$true;  sb=$false; at=$false; ls=$false; tr='pass'; vr='pass'; vd='MERGE';     eco=@('python');          em=$true;  ev='review' }
    @{ n='explicit MERGE (dotnet) -> review path wins first';                         hc=$true;  sb=$false; at=$false; ls=$false; tr='none'; vr='pass'; vd='MERGE';     eco=@('dotnet');          em=$true;  ev='review' }
    @{ n='secret blocks even a clean dotnet/UNCLEAR';                                  hc=$true;  sb=$true;  at=$false; ls=$false; tr='none'; vr='pass'; vd='UNCLEAR';   eco=@('dotnet');          em=$false; ev='' }
    @{ n='suspected loop blocks';                                                     hc=$true;  sb=$false; at=$false; ls=$true;  tr='none'; vr='pass'; vd='UNCLEAR';   eco=@('dotnet');          em=$false; ev='' }
    @{ n='circuit-breaker (agent timed out) blocks';                                  hc=$true;  sb=$false; at=$true;  ls=$false; tr='none'; vr='pass'; vd='UNCLEAR';   eco=@('dotnet');          em=$false; ev='' }
    @{ n='verify FAIL blocks even an explicit MERGE';                                 hc=$true;  sb=$false; at=$false; ls=$false; tr='none'; vr='fail'; vd='MERGE';     eco=@('dotnet');          em=$false; ev='' }
    @{ n='test FAIL blocks';                                                          hc=$true;  sb=$false; at=$false; ls=$false; tr='fail'; vr='pass'; vd='MERGE';     eco=@('python');          em=$false; ev='' }
    @{ n='build-only needs verify STRICTLY pass: none does NOT merge';                hc=$true;  sb=$false; at=$false; ls=$false; tr='none'; vr='none'; vd='UNCLEAR';   eco=@('dotnet');          em=$false; ev='' }
    @{ n='build-only respects an explicit FIX FIRST';                                 hc=$true;  sb=$false; at=$false; ls=$false; tr='none'; vr='pass'; vd='FIX FIRST'; eco=@('dotnet');          em=$false; ev='' }
    @{ n='python NEVER takes the build-only path on UNCLEAR';                         hc=$true;  sb=$false; at=$false; ls=$false; tr='none'; vr='pass'; vd='UNCLEAR';   eco=@('python');          em=$false; ev='' }
    @{ n='node NEVER takes the build-only path on UNCLEAR';                           hc=$true;  sb=$false; at=$false; ls=$false; tr='none'; vr='pass'; vd='UNCLEAR';   eco=@('node');            em=$false; ev='' }
    @{ n='polyglot dotnet+python does NOT take build-only (not dotnet-only)';         hc=$true;  sb=$false; at=$false; ls=$false; tr='none'; vr='pass'; vd='UNCLEAR';   eco=@('dotnet','python'); em=$false; ev='' }
    @{ n='green gates + UNCLEAR -> MERGE (passing tests are the arbiter; #688 F2)';    hc=$true;  sb=$false; at=$false; ls=$false; tr='pass'; vr='pass'; vd='UNCLEAR';   eco=@('dotnet');          em=$true;  ev='green-gates-inconclusive-review' }
    @{ n='no changes -> no merge';                                                    hc=$false; sb=$false; at=$false; ls=$false; tr='none'; vr='pass'; vd='MERGE';     eco=@('dotnet');          em=$false; ev='' }
    @{ n='green gates + FIX FIRST (python) -> MERGE over review (#687)';              hc=$true;  sb=$false; at=$false; ls=$false; tr='pass'; vr='pass'; vd='FIX FIRST'; eco=@('python');          em=$true;  ev='green-gates-over-review' }
    # --- #688 merge-reliability: a transient signal (review timeout / coder circuit-breaker) never
    # parks work the deterministic gates + the reviewer already vouch for; FIX FIRST / fails still park. ---
    @{ n='F2 node green gates + UNCLEAR -> MERGE (A fixed)';                           hc=$true;  sb=$false; at=$false; ls=$false; tr='pass'; vr='pass'; vd='UNCLEAR';   eco=@('node');            em=$true;  ev='green-gates-inconclusive-review' }
    @{ n='F2 python green gates + UNCLEAR + timeout -> MERGE (tests trump hiccup)';    hc=$true;  sb=$false; at=$true;  ls=$false; tr='pass'; vr='pass'; vd='UNCLEAR';   eco=@('python');          em=$true;  ev='green-gates-inconclusive-review' }
    @{ n='green gates + FIX FIRST (node) -> MERGE over review (#687)';                hc=$true;  sb=$false; at=$false; ls=$false; tr='pass'; vr='pass'; vd='FIX FIRST'; eco=@('node');            em=$true;  ev='green-gates-over-review' }
    @{ n='F3 explicit MERGE + circuit-breaker -> review-over-hiccup (B fixed)';        hc=$true;  sb=$false; at=$true;  ls=$false; tr='none'; vr='pass'; vd='MERGE';     eco=@('node');            em=$true;  ev='review-over-hiccup' }
    @{ n='F3 explicit MERGE + suspected loop -> review-over-hiccup';                   hc=$true;  sb=$false; at=$false; ls=$true;  tr='pass'; vr='pass'; vd='MERGE';     eco=@('python');          em=$true;  ev='review-over-hiccup' }
    @{ n='F3 MERGE + circuit-breaker still blocked by verify FAIL';                    hc=$true;  sb=$false; at=$true;  ls=$false; tr='none'; vr='fail'; vd='MERGE';     eco=@('node');            em=$false; ev='' }
    @{ n='inconclusive + hiccup + NO green gates (tr=none) -> park';                   hc=$true;  sb=$false; at=$true;  ls=$false; tr='none'; vr='pass'; vd='UNCLEAR';   eco=@('node');            em=$false; ev='' }
    # --- #687 deterministic-gate-drives-merge: GREEN gates (verify=pass AND test=pass) merge OVER a
    # FIX FIRST / timed-out review (the landing-page park); FIX FIRST still blocks where NO green
    # behavioral gate vouches (test=none). The review drove the bounded fix loop upstream; here the
    # deterministic arbiter decides. ---
    @{ n='#687 EXACT: node green gates + sticky FIX FIRST + review timeout -> MERGE';  hc=$true;  sb=$false; at=$true;  ls=$false; tr='pass'; vr='pass'; vd='FIX FIRST'; eco=@('node');            em=$true;  ev='green-gates-over-review' }
    @{ n='#687 green gates + explicit MERGE still wins via review (not over-review)';  hc=$true;  sb=$false; at=$false; ls=$false; tr='pass'; vr='pass'; vd='MERGE';     eco=@('node');            em=$true;  ev='review' }
    @{ n='#687 FIX FIRST blocks with NO green gate, non-build-only (tr=none/node)';    hc=$true;  sb=$false; at=$false; ls=$false; tr='none'; vr='pass'; vd='FIX FIRST'; eco=@('node');            em=$false; ev='' }
    @{ n='#687 green gates + UNCLEAR still merges via inconclusive path (unchanged)';  hc=$true;  sb=$false; at=$false; ls=$false; tr='pass'; vr='pass'; vd='UNCLEAR';   eco=@('python');          em=$true;  ev='green-gates-inconclusive-review' }
)

$pass = 0; $fail = 0
foreach ($c in $cases) {
    $r = Test-ShouldMerge -HasChanges $c.hc -SecretBlocked $c.sb -AgentTimedOut $c.at -LoopSuspected $c.ls `
                          -TestResult $c.tr -VerifyResult $c.vr -Verdict $c.vd -Ecosystems $c.eco
    if (($r.Merge -eq $c.em) -and ($r.Via -eq $c.ev)) {
        $pass++; Write-Host "[pass] $($c.n)" -ForegroundColor DarkGreen
    } else {
        $fail++; Write-Host "[FAIL] $($c.n) -> got Merge=$($r.Merge) Via='$($r.Via)'; expected Merge=$($c.em) Via='$($c.ev)'" -ForegroundColor Red
    }
}
Write-Host ""
Write-Host "Test-ShouldMerge: $pass passed, $fail failed (of $($cases.Count))" -ForegroundColor $(if ($fail) { 'Red' } else { 'Green' })
exit $(if ($fail) { 1 } else { 0 })
