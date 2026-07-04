#requires -Version 5.1
<#
.SYNOPSIS
  Verify fleet worktrees resolve to the hidden fleet-owned base, never beside the operator's project (#714).

.DESCRIPTION
  Background (plain English):
    The fleet builds each task in throwaway git worktrees (a base + up to N best-of-N candidates). They USED
    to be created BESIDE the project ("<repo>-<task>[-cK]"), so a killed/crashed run -- which never reaches
    the cleanup -- left "-c1/-c2/-c3" copies littering the projects/ dir (the operator's "why are there all
    these extra folders?", 2026-07-01). Resolve-WorktreeBase now roots them in a hidden, gitignored,
    fleet-owned dir (agentic-setup/state/worktrees). This suite proves that pure resolver: the base is
    state\worktrees under the scripts' parent, and a task's (and its candidates') worktree path is NOT inside
    projects/ and NOT the old sibling-of-project path. No git, no model; runs instantly.

  Run it normally ( .\verify-worktree-location.ps1 ) - do NOT dot-source it.
  Exit code 0 if everything passed, 1 if any check failed.
#>
param()
$ErrorActionPreference = 'Stop'
. "$PSScriptRoot\fleet-lib.ps1"

# Tiny zero-dependency test framework (mirrors verify-bestofn-concurrent.ps1 so the suites read identically).
$script:Pass = 0
$script:Fail = 0
$script:Failures = New-Object System.Collections.ArrayList
function Section($t) { Write-Host ''; Write-Host "== $t ==" -ForegroundColor Cyan }
function _pass($m)   { $script:Pass++; Write-Host "  [PASS] $m" -ForegroundColor Green }
function _fail($m)   { $script:Fail++; [void]$script:Failures.Add($m); Write-Host "  [FAIL] $m" -ForegroundColor Red }
function Assert-Eq($Expected, $Actual, $Msg) {
    if ([string]$Expected -ceq [string]$Actual) { _pass $Msg }
    else { _fail "$Msg (expected '$Expected', got '$Actual')" }
}
function Assert-True($Cond, $Msg)  { if ($Cond) { _pass $Msg } else { _fail "$Msg (expected True, got False)" } }
function Assert-False($Cond, $Msg) { if (-not $Cond) { _pass $Msg } else { _fail "$Msg (expected False, got True)" } }
# Separator-agnostic normalizer (Join-Path yields '\' on Windows; keep the assertions robust).
function N($p) { ($p -replace '/', '\').TrimEnd('\') }

Section 'Resolve-WorktreeBase: the hidden, gitignored, fleet-owned base'
$scripts = 'C:\Users\mrbla\agentic-setup\scripts'
$base = Resolve-WorktreeBase -ScriptRoot $scripts
Assert-Eq (N 'C:\Users\mrbla\agentic-setup\state\worktrees') (N $base) 'base is <agentic-setup>\state\worktrees'
Assert-True ((N $base) -like '*\state\worktrees') 'base lives under the gitignored state\ dir'
# Derives from the given scripts dir (not hard-coded), so it is correct no matter where the checkout lives.
# (Uses an existing drive: Split-Path -Parent resolves the drive qualifier, so the path's drive must exist
# even though the folder itself need not.)
$alt = Resolve-WorktreeBase -ScriptRoot 'C:\other\agentic-setup\scripts'
Assert-Eq (N 'C:\other\agentic-setup\state\worktrees') (N $alt) 'base derives from the given scripts dir'

Section 'A task worktree is NOT beside the project (the #714 regression it fixes)'
$repo = 'C:\Users\mrbla\projects\testproject9'
$projectsDir = Split-Path $repo -Parent
$repoName = Split-Path $repo -Leaf
$task = 'create-product-page'
$wt = Join-Path (Resolve-WorktreeBase -ScriptRoot $scripts) "$repoName-$task"
$oldSibling = Join-Path $projectsDir "$repoName-$task"    # the OLD, buggy location
Assert-False ((N $wt) -ceq (N $oldSibling)) 'task worktree is NOT the old sibling-of-project path'
Assert-False ((N $wt) -like ((N $projectsDir) + '\*')) 'task worktree is NOT inside projects/'
Assert-True ((N $wt) -like '*\state\worktrees\testproject9-create-product-page') 'task worktree is under state\worktrees'

Section 'Best-of-N candidate worktrees ("$wt-cK") inherit the hidden base'
foreach ($k in 1..3) {
    $cand = "$wt-c$k"
    Assert-False ((N $cand) -like ((N $projectsDir) + '\*')) "candidate -c$k is NOT inside projects/"
    Assert-True ((N $cand) -like "*\state\worktrees\testproject9-create-product-page-c$k") "candidate -c$k is under state\worktrees"
}

Write-Host ''
if ($script:Fail -eq 0) {
    Write-Host "RESULT: $($script:Pass) passed, 0 failed" -ForegroundColor Green; exit 0
} else {
    Write-Host "RESULT: $($script:Pass) passed, $($script:Fail) failed" -ForegroundColor Red
    $script:Failures | ForEach-Object { Write-Host "  - $_" -ForegroundColor Red }
    exit 1
}
