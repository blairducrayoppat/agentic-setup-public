#requires -Version 5.1
<#
.SYNOPSIS
  Verify the #694 read-only-review enforcement: the reviewer is read-only by CONTRACT
  (review.md) AND by HARNESS (Get-WorktreeDigest / Test-ReviewLegMutated fail closed on any
  worktree mutation during the review leg). Builds real throwaway git repos; no model, no network.

.DESCRIPTION
  Incident (run 20260627-083757-bd, #694): a "read-only" review leg MUTATED the worktree --
  it edited Calculator.cs (namespace App;->namespace App, CS1514) and added an untracked Tests/,
  leaving an un-buildable parked tree over a buildable commit. The reviewer's edit:deny alone did
  not stop it (the mutation came from outside its tool calls), AND a later config-sync reverted the
  bash:deny fix, so the DURABLE enforcement is a digest guard the sync cannot touch. Each check
  kills a specific wrong implementation:
    C1  review.md declares edit:deny, bash:deny, todowrite:deny (the contract the sync reverted).
    C2  review.md carries the 2026-07-09 shared-state checklist line (the reviewer's new criterion).
    D1  Get-WorktreeDigest is STABLE across a no-op (two calls on an unchanged tree match) ->
        a clean review never false-trips the guard.
    D2  Get-WorktreeDigest FLIPS on a tracked-file edit (the namespace-break shape).
    D3  Get-WorktreeDigest FLIPS on a NEW untracked file (the Tests/ shape).
    L1  Test-ReviewLegMutated is FALSE when the digests match (clean leg -> no false FAIL-CLOSED).
    L2  Test-ReviewLegMutated is TRUE when they differ (the loud-failure path the harness acts on).
    L3  Two empty/failed digests that MATCH are NOT reported as a mutation (git-hiccup safety).
#>
$ErrorActionPreference = 'Stop'
. "$PSScriptRoot\fleet-lib.ps1"

$script:Pass = 0; $script:Fail = 0
function _pass($m) { $script:Pass++; Write-Host "  [PASS] $m" -ForegroundColor Green }
function _fail($m) { $script:Fail++; Write-Host "  [FAIL] $m" -ForegroundColor Red }
function Assert($cond, $msg) { if ($cond) { _pass $msg } else { _fail $msg } }

$ReviewMd = Join-Path $PSScriptRoot '..\configs\agents\review.md'
$base = Join-Path ([System.IO.Path]::GetTempPath()) ("verify-review-" + [guid]::NewGuid().ToString('N').Substring(0, 8))
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

try {
    # ---- CONTRACT: the review.md agent definition (the surface the config-sync reverted) ----
    Write-Host "== review.md read-only contract ==" -ForegroundColor Cyan
    $md = Get-Content $ReviewMd -Raw
    Assert ($md -match '(?im)^\s*edit:\s*deny\s*$')      "C1 review.md declares edit: deny"
    Assert ($md -match '(?im)^\s*bash:\s*deny\s*$')      "C1 review.md declares bash: deny (the reverted fix, restored)"
    Assert ($md -match '(?im)^\s*todowrite:\s*deny\s*$') "C1 review.md declares todowrite: deny"
    Assert ($md -match '2026-07-09')                     "C2 review.md carries the 2026-07-09 shared-state lesson"
    Assert ($md -match '(?i)shared[- ]state')            "C2 review.md checklist asks about shared-state scope"

    # ---- HARNESS: Get-WorktreeDigest moves iff the tree really changed ----
    Write-Host "== Get-WorktreeDigest ==" -ForegroundColor Cyan

    # D1: a committed, unchanged tree (the review-time shape: candidate work already committed).
    $r = New-Repo r1; Add-Commit $r App.cs "namespace App;" 'commit'
    $d0 = Get-WorktreeDigest -Repo $r
    $d0b = Get-WorktreeDigest -Repo $r
    Assert ($d0 -eq $d0b) "D1 digest is STABLE across a no-op (clean review does not false-trip)"

    # D2: the incident's tracked-file edit (namespace App; -> namespace App).
    Set-Content (Join-Path $r App.cs) "namespace App"
    $d1 = Get-WorktreeDigest -Repo $r
    Assert ($d1 -ne $d0) "D2 digest FLIPS on a tracked-file edit (the CS1514 namespace break)"

    # D3: the incident's untracked addition (a new Tests/ dir), starting from a fresh clean tree.
    $r2 = New-Repo r2; Add-Commit $r2 App.cs "namespace App;" 'commit'
    $c0 = Get-WorktreeDigest -Repo $r2
    New-Item -ItemType Directory -Force (Join-Path $r2 'Tests') | Out-Null
    Set-Content (Join-Path $r2 'Tests\T.cs') "// new"
    $c1 = Get-WorktreeDigest -Repo $r2
    Assert ($c1 -ne $c0) "D3 digest FLIPS on a new untracked file (the un-tracked Tests/ dir)"

    # ---- LOUD-FAILURE PATH: Test-ReviewLegMutated is what the harness branches on ----
    Write-Host "== Test-ReviewLegMutated (the fail-closed decision) ==" -ForegroundColor Cyan
    Assert (-not (Test-ReviewLegMutated -Before $d0 -After $d0b)) "L1 matching digests -> NOT mutated (no false FAIL-CLOSED)"
    Assert (Test-ReviewLegMutated -Before $d0 -After $d1)        "L2 differing digests -> MUTATED (the harness forces FIX FIRST + parks)"
    Assert (-not (Test-ReviewLegMutated -Before '' -After ''))   "L3 two empty digests match -> NOT a false mutation (git-hiccup safety)"
}
finally {
    $ErrorActionPreference = 'Continue'
    Remove-Item $base -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Host ""
Write-Host ("  Passed: {0}   Failed: {1}" -f $script:Pass, $script:Fail) -ForegroundColor $(if ($script:Fail) { 'Red' } else { 'Green' })
if ($script:Fail) { exit 1 } else { Write-Host "  REVIEW-READONLY: VALIDATED." -ForegroundColor Green; exit 0 }
