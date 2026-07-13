#requires -Version 5.1
<#
.SYNOPSIS
  Verify the #780 fix (c) divergence-direction check: a git-tracked agent-def config vs its LIVE
  deployed copy, naming the DIRECTION of any drift so the #694 merge motion can PROVE the
  sync-harness revert trap is disarmed. Builds real throwaway git repos; no model, no network,
  and (unless -CheckLive) reads NOTHING under ~/.config -- deploys nothing, ever.

.DESCRIPTION
  Trap (#780): sync-harness.ps1 is one-way LIVE->repo -- it Copy-Items the live agent def over the
  repo copy whenever the two differ and auto-commits. So a repo-only fix that is not ALSO deployed
  live gets reverted at the next sync (proven in the wild: f219074's bash:deny reverted 3h later by
  3553b56). Get-ConfigDeployDivergence names which way the two have drifted; Test-DeployDivergenceFatal
  is the severity the gate acts on. Each check kills a specific wrong implementation:
    S1  IN_SYNC      identical repo+live -> deployed, a sync is a no-op (the state the motion must leave).
    S2  REPO_AHEAD   live == a KNOWN past committed version -> repo advanced, deploy pending.
    S3  LIVE_AHEAD   live carries content the repo history NEVER held -> the armed revert trap.
    S4  LIVE_ABSENT  no live copy (fresh box) -> nothing to revert.
    S5  CRLF drift is IN_SYNC, not a false LIVE_AHEAD (direction is decided on LF-normalized content).
    S6  the #780 shape end-to-end: repo gains bash:deny, live still lacks it -> REPO_AHEAD (pending
        deploy, the precursor); a novel live edit -> LIVE_AHEAD (the armed trap).
    F1-F7  Test-DeployDivergenceFatal: LIVE_AHEAD always fatal; REPO_AHEAD/LIVE_ABSENT non-fatal by
        default but fatal under -Strict (the POST-deploy gate that demands full IN_SYNC).
  -CheckLive additionally probes the REAL configs/agents/review.md vs ~/.config/opencode/agents/review.md
  (read-only), printing the verdict and failing iff it is fatal; -Strict promotes pending-deploy/absent
  to a failure for use as the post-deploy proof in the merge runbook.
#>
param([switch]$CheckLive, [switch]$Strict)
$ErrorActionPreference = 'Stop'
. "$PSScriptRoot\fleet-lib.ps1"

$script:Pass = 0; $script:Fail = 0
function _pass($m) { $script:Pass++; Write-Host "  [PASS] $m" -ForegroundColor Green }
function _fail($m) { $script:Fail++; Write-Host "  [FAIL] $m" -ForegroundColor Red }
function Assert($cond, $msg) { if ($cond) { _pass $msg } else { _fail $msg } }

$base = Join-Path ([System.IO.Path]::GetTempPath()) ("verify-deploysync-" + [guid]::NewGuid().ToString('N').Substring(0, 8))
function New-Repo($n) {
    $r = Join-Path $base $n
    New-Item -ItemType Directory -Force $r | Out-Null
    $ErrorActionPreference = 'Continue'
    git -C $r init -b main -q 2>$null
    git -C $r config user.email 't@t' 2>$null; git -C $r config user.name 't' 2>$null
    return $r
}
function Commit-Review($r, $content, $m) {
    # LF-normalized write so autocrlf on the box does not perturb the fixture content.
    [System.IO.File]::WriteAllText((Join-Path $r 'review.md'), (($content -replace "`r`n", "`n")))
    $ErrorActionPreference = 'Continue'
    git -C $r add -A 2>$null; git -C $r commit -q -m $m 2>$null
}
function New-LiveFile($name, $content) {
    $p = Join-Path $base $name
    [System.IO.File]::WriteAllText($p, $content)
    return $p
}

try {
    Write-Host "== Get-ConfigDeployDivergence verdicts ==" -ForegroundColor Cyan

    # S1 IN_SYNC: repo == live.
    $r1 = New-Repo r1; Commit-Review $r1 "bash: deny`n" 'v1'
    $live1 = New-LiveFile 'live1.md' "bash: deny`n"
    Assert ((Get-ConfigDeployDivergence -Repo $r1 -RepoRelPath 'review.md' -LivePath $live1) -eq 'IN_SYNC') `
        "S1 identical repo+live -> IN_SYNC"

    # S2 REPO_AHEAD: repo advanced v1->v2; live still holds v1 (a KNOWN past version).
    $r2 = New-Repo r2; Commit-Review $r2 "v1 body`n" 'v1'; Commit-Review $r2 "v2 body`n" 'v2'
    $live2 = New-LiveFile 'live2.md' "v1 body`n"
    Assert ((Get-ConfigDeployDivergence -Repo $r2 -RepoRelPath 'review.md' -LivePath $live2) -eq 'REPO_AHEAD') `
        "S2 live == a past committed version -> REPO_AHEAD (pending deploy)"

    # S3 LIVE_AHEAD: repo has v1; live carries content the repo history never held.
    $r3 = New-Repo r3; Commit-Review $r3 "v1 body`n" 'v1'
    $live3 = New-LiveFile 'live3.md' "NOVEL live-only content`n"
    Assert ((Get-ConfigDeployDivergence -Repo $r3 -RepoRelPath 'review.md' -LivePath $live3) -eq 'LIVE_AHEAD') `
        "S3 live carries never-committed content -> LIVE_AHEAD (armed trap)"

    # S4 LIVE_ABSENT: no live file.
    $r4 = New-Repo r4; Commit-Review $r4 "v1`n" 'v1'
    Assert ((Get-ConfigDeployDivergence -Repo $r4 -RepoRelPath 'review.md' -LivePath (Join-Path $base 'does-not-exist.md')) -eq 'LIVE_ABSENT') `
        "S4 no live copy -> LIVE_ABSENT (fresh box)"

    # S5 CRLF-insensitive: repo LF, live CRLF, same content -> IN_SYNC (no false LIVE_AHEAD).
    $r5 = New-Repo r5; Commit-Review $r5 "line1`nline2`n" 'v1'
    $live5 = New-LiveFile 'live5.md' "line1`r`nline2`r`n"
    Assert ((Get-ConfigDeployDivergence -Repo $r5 -RepoRelPath 'review.md' -LivePath $live5) -eq 'IN_SYNC') `
        "S5 pure CRLF drift is IN_SYNC, not a false LIVE_AHEAD"

    # S6 the #780 shape end-to-end.
    Write-Host "== S6 the #780 incident shape ==" -ForegroundColor Cyan
    $noBash   = "permission:`n  edit: deny`n  todowrite: deny`n"
    $withBash = "permission:`n  edit: deny`n  bash: deny`n  todowrite: deny`n"
    $r6 = New-Repo r6; Commit-Review $r6 $noBash 'pre-fix'; Commit-Review $r6 $withBash 'add bash: deny (f219074 shape)'
    $liveStale = New-LiveFile 'live6-stale.md' $noBash              # live never got the deploy (the real trap precursor)
    $v6a = Get-ConfigDeployDivergence -Repo $r6 -RepoRelPath 'review.md' -LivePath $liveStale
    Assert ($v6a -eq 'REPO_AHEAD') "S6a repo gained bash:deny, live still lacks it -> REPO_AHEAD (the #780 precursor)"
    $liveNovel = New-LiveFile 'live6-novel.md' "permission:`n  edit: deny`n  bash: allow`n"  # an unreviewed live edit
    $v6b = Get-ConfigDeployDivergence -Repo $r6 -RepoRelPath 'review.md' -LivePath $liveNovel
    Assert ($v6b -eq 'LIVE_AHEAD') "S6b a novel live edit (bash: allow) -> LIVE_AHEAD (armed trap)"

    # F1-F7 severity mapping.
    Write-Host "== Test-DeployDivergenceFatal (the loud-failure decision) ==" -ForegroundColor Cyan
    Assert (Test-DeployDivergenceFatal -Verdict 'LIVE_AHEAD')                 "F1 LIVE_AHEAD -> fatal (always)"
    Assert (-not (Test-DeployDivergenceFatal -Verdict 'REPO_AHEAD'))          "F2 REPO_AHEAD -> non-fatal by default (pending deploy)"
    Assert (-not (Test-DeployDivergenceFatal -Verdict 'LIVE_ABSENT'))         "F3 LIVE_ABSENT -> non-fatal by default (fresh box)"
    Assert (-not (Test-DeployDivergenceFatal -Verdict 'IN_SYNC'))             "F4 IN_SYNC -> non-fatal"
    Assert (Test-DeployDivergenceFatal -Verdict 'REPO_AHEAD' -Strict)         "F5 REPO_AHEAD -Strict -> fatal (post-deploy gate demands IN_SYNC)"
    Assert (Test-DeployDivergenceFatal -Verdict 'LIVE_ABSENT' -Strict)        "F6 LIVE_ABSENT -Strict -> fatal (post-deploy gate demands IN_SYNC)"
    Assert (-not (Test-DeployDivergenceFatal -Verdict 'IN_SYNC' -Strict))     "F7 IN_SYNC -Strict -> non-fatal (the only clean post-deploy state)"

    # Optional REAL probe (read-only; deploys nothing). Off by default so the gate is hermetic like its siblings.
    if ($CheckLive) {
        Write-Host "== live probe: configs/agents/review.md vs ~/.config/opencode/agents/review.md ==" -ForegroundColor Cyan
        $repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
        $liveReview = Join-Path $env:USERPROFILE '.config\opencode\agents\review.md'
        $verdict = Get-ConfigDeployDivergence -Repo $repoRoot -RepoRelPath 'configs/agents/review.md' -LivePath $liveReview
        $fatal = Test-DeployDivergenceFatal -Verdict $verdict -Strict:$Strict
        $color = if ($fatal) { 'Red' } elseif ($verdict -eq 'IN_SYNC') { 'Green' } else { 'Yellow' }
        Write-Host ("  verdict: {0}{1}" -f $verdict, $(if ($Strict) { ' [strict]' } else { '' })) -ForegroundColor $color
        switch ($verdict) {
            'IN_SYNC'     { Write-Host "  live == repo: deployed, sync-harness is a no-op. Trap disarmed." -ForegroundColor Green }
            'REPO_AHEAD'  { Write-Host "  repo AHEAD of live (pending deploy). Deploy repo->live in the merge motion or a later sync-harness reverts the repo fix (#780 precursor)." -ForegroundColor Yellow }
            'LIVE_AHEAD'  { Write-Host "  live AHEAD of repo (novel content). The next sync-harness captures it into the tracked tree unreviewed -- RECONCILE before any sync (the #780 revert trap, armed)." -ForegroundColor Red }
            'LIVE_ABSENT' { Write-Host "  no live copy (fresh box). Nothing to revert; deploy on go-live." -ForegroundColor Yellow }
        }
        if ($fatal) { _fail "live probe fatal ($verdict)" } else { _pass "live probe non-fatal ($verdict)" }
    }
}
finally {
    $ErrorActionPreference = 'Continue'
    Remove-Item $base -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Host ""
Write-Host ("  Passed: {0}   Failed: {1}" -f $script:Pass, $script:Fail) -ForegroundColor $(if ($script:Fail) { 'Red' } else { 'Green' })
if ($script:Fail) { exit 1 } else { Write-Host "  CONFIG-DEPLOY-SYNC: VALIDATED." -ForegroundColor Green; exit 0 }
