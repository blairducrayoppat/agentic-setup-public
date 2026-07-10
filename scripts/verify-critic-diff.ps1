#requires -Version 5.1
<#
.SYNOPSIS
  Verify Resolve-CriticRange (fleet-lib.ps1) -- the #687 #9 cross-model-critic empty-diff fix.
  Builds real throwaway git repos and asserts the resolved range captures the merged work in
  every shape the fleet produces. PS 5.1 & 7 safe; no model, no network.

.DESCRIPTION
  The critic runs POST-MERGE on the base branch, where "<base>...HEAD" is EMPTY (HEAD == base) and
  the critic saw "The diff content is missing". Resolve-CriticRange falls back to the last merge's
  first-parent diff. Each scenario kills a specific wrong implementation:
    S1 pre-merge          -> "<base>...HEAD"  (drop path 1 -> S1 flips)
    S2 non-FF merge commit-> "HEAD~1..HEAD", agent's work only, excludes main's own commit
    S3 FF single commit   -> "HEAD~1..HEAD"   (drop the fallback -> S2/S3 flip to "")
    S4 nothing to review  -> ""               (return non-empty when nothing resolves -> S4 flips)
    S5 FF MULTI-commit + -BaseRef -> "<sha>..HEAD" shows ALL commits (#693; without the base
       the legacy fallback shows only the LAST commit -- asserted as the documented gap)
    S6 -BaseRef invalid/unchanged -> falls through to the legacy chain (fallback preserved)
#>
$ErrorActionPreference = 'Stop'
. "$PSScriptRoot\fleet-lib.ps1"

$script:Pass = 0; $script:Fail = 0
function _pass($m) { $script:Pass++; Write-Host "  [PASS] $m" -ForegroundColor Green }
function _fail($m) { $script:Fail++; Write-Host "  [FAIL] $m" -ForegroundColor Red }
function Assert($cond, $msg) { if ($cond) { _pass $msg } else { _fail $msg } }

$base = Join-Path ([System.IO.Path]::GetTempPath()) ("verify-critic-" + [guid]::NewGuid().ToString('N').Substring(0, 8))
function New-Repo($n) {
    $r = Join-Path $base $n
    New-Item -ItemType Directory -Force $r | Out-Null
    $ErrorActionPreference = 'Continue'
    git -C $r init -b main -q 2>$null
    git -C $r config user.email 't@t' 2>$null; git -C $r config user.name 't' 2>$null
    return $r
}
function Add-Commit($r, $f, $c, $m) {
    Set-Content (Join-Path $r $f) $c
    $ErrorActionPreference = 'Continue'
    git -C $r add -A 2>$null; git -C $r commit -q -m $m 2>$null
}
function Names($r, $rng) { ((git -C $r diff $rng --name-only 2>$null) -join ',') }

try {
    Write-Host "== Resolve-CriticRange ==" -ForegroundColor Cyan

    # S1: PRE-merge -- on a feature branch with changes since main.
    $r = New-Repo r1; Add-Commit $r a.txt A A; & git -C $r checkout -q -b feature 2>$null; Add-Commit $r b.txt B B
    $rng = Resolve-CriticRange -Repo $r -Base main
    Assert ($rng -eq 'main...HEAD') "S1 pre-merge -> 'main...HEAD' (got '$rng')"
    Assert ((Names $r $rng) -match 'b\.txt') "S1 range shows b.txt"

    # S2: NON-FF merge commit (main diverged) -> HEAD~1..HEAD first-parent diff = agent's work only.
    $r = New-Repo r2; Add-Commit $r a.txt A A; & git -C $r checkout -q -b agent/foo 2>$null; Add-Commit $r c.txt C C
    & git -C $r checkout -q main 2>$null; Add-Commit $r e.txt E E
    $ErrorActionPreference = 'Continue'; git -C $r merge agent/foo --no-edit -q 2>$null; $ErrorActionPreference = 'Stop'
    $rng = Resolve-CriticRange -Repo $r -Base main
    Assert ($rng -eq 'HEAD~1..HEAD') "S2 non-FF merge commit -> 'HEAD~1..HEAD' (got '$rng')"
    Assert ((Names $r $rng) -match 'c\.txt') "S2 range shows the agent's c.txt"
    Assert (-not ((Names $r $rng) -match 'e\.txt')) "S2 range EXCLUDES main's own e.txt (first-parent diff)"

    # S3: FF merge, single commit (the live critic-probe2 shape) -> HEAD~1..HEAD.
    $r = New-Repo r3; Add-Commit $r a.txt A A; & git -C $r checkout -q -b agent/bar 2>$null; Add-Commit $r d.txt D D
    & git -C $r checkout -q main 2>$null
    $ErrorActionPreference = 'Continue'; git -C $r merge agent/bar --no-edit -q 2>$null; $ErrorActionPreference = 'Stop'
    $rng = Resolve-CriticRange -Repo $r -Base main
    Assert ($rng -eq 'HEAD~1..HEAD') "S3 FF single commit -> 'HEAD~1..HEAD' (got '$rng')"
    Assert ((Names $r $rng) -match 'd\.txt') "S3 range shows d.txt"

    # S4: nothing to review (a single commit, no agent branch) -> "".
    $r = New-Repo r4; Add-Commit $r a.txt A A
    $rng = Resolve-CriticRange -Repo $r -Base main
    Assert ($rng -eq '') "S4 single commit / no diff -> '' (got '$rng')"

    # S5 (#693): FF MULTI-commit merge -- the gap the base SHA closes. Record main's
    # pre-dispatch HEAD, merge a 2-commit agent branch fast-forward, then:
    #   with -BaseRef -> "<sha>..HEAD" and the diff shows BOTH commits' files;
    #   without      -> the legacy HEAD~1..HEAD shows ONLY the last (the documented gap).
    $r = New-Repo r5; Add-Commit $r a.txt A A
    $preSha = (git -C $r rev-parse HEAD 2>$null)
    & git -C $r checkout -q -b agent/multi 2>$null
    Add-Commit $r f1.txt F1 'commit 1'; Add-Commit $r f2.txt F2 'commit 2'
    & git -C $r checkout -q main 2>$null
    $ErrorActionPreference = 'Continue'; git -C $r merge agent/multi --ff-only -q 2>$null; $ErrorActionPreference = 'Stop'
    $rng = Resolve-CriticRange -Repo $r -Base main -BaseRef $preSha
    Assert ($rng -eq "$preSha..HEAD") "S5 FF multi-commit + BaseRef -> '<sha>..HEAD' (got '$rng')"
    $names = Names $r $rng
    Assert (($names -match 'f1\.txt') -and ($names -match 'f2\.txt')) "S5 BaseRef range shows BOTH f1.txt and f2.txt"
    $legacy = Resolve-CriticRange -Repo $r -Base main
    Assert (($legacy -eq 'HEAD~1..HEAD') -and -not ((Names $r $legacy) -match 'f1\.txt')) `
        "S5 legacy fallback (no BaseRef) misses f1.txt -- the documented gap BaseRef closes"

    # S6 (#693): an invalid or diff-less BaseRef falls through to the legacy chain.
    $rng = Resolve-CriticRange -Repo $r -Base main -BaseRef 'deadbeef0000'
    Assert ($rng -eq 'HEAD~1..HEAD') "S6 invalid BaseRef falls through to legacy (got '$rng')"
    $headSha = (git -C $r rev-parse HEAD 2>$null)
    $rng = Resolve-CriticRange -Repo $r -Base main -BaseRef $headSha
    Assert ($rng -eq 'HEAD~1..HEAD') "S6 BaseRef==HEAD (empty diff) falls through to legacy (got '$rng')"
}
finally {
    $ErrorActionPreference = 'Continue'
    Remove-Item $base -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Host ""
Write-Host ("  Passed: {0}   Failed: {1}" -f $script:Pass, $script:Fail) -ForegroundColor $(if ($script:Fail) { 'Red' } else { 'Green' })
if ($script:Fail) { exit 1 } else { Write-Host "  CRITIC-DIFF: VALIDATED." -ForegroundColor Green; exit 0 }
