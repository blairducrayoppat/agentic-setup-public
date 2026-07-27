#requires -Version 7.0
<#
.SYNOPSIS
  Verify a failed `git worktree add` carries git's OWN message into the thrown error (#1076).

.DESCRIPTION
  Background (plain English):
    Every fleet task builds in a throwaway git worktree. When that creation failed,
    new-agent-task.ps1 piped git's output to Out-Null and threw a generic sentence naming the
    path and the branch but never the REASON. Three parked runs and eight failed workspace
    creations later, git's actual words existed nowhere on disk, and the #1066 forensics could
    not establish why the workspaces never appeared. A locked worktree, a stale administrative
    entry and a path already in use all produce the same generic sentence -- and only git can
    tell them apart.

    This suite does NOT re-type the fixed lines. It EXTRACTS the shipped block out of
    new-agent-task.ps1 and runs that exact text against a REAL git repository whose
    `worktree add` genuinely fails, so it verifies what ships rather than a copy of it.

    Includes the control tested with the lock off: the historical `| Out-Null` form is run
    against the SAME failure and must NOT carry git's words -- otherwise a passing check here
    would prove nothing.

  Run it normally ( .\verify-worktree-add-fail-loud.ps1 ) - do NOT dot-source it.
  Needs git on PATH; no model, no OVMS, no fleet run. Exit 0 all passed, 1 any failure.
#>
param()
$ErrorActionPreference = 'Stop'

# Tiny zero-dependency test framework (mirrors verify-worktree-location.ps1 so the suites read identically).
$script:Pass = 0
$script:Fail = 0
$script:Failures = New-Object System.Collections.ArrayList
function Section($t) { Write-Host ''; Write-Host "== $t ==" -ForegroundColor Cyan }
function _pass($m)   { $script:Pass++; Write-Host "  [PASS] $m" -ForegroundColor Green }
function _fail($m)   { $script:Fail++; [void]$script:Failures.Add($m); Write-Host "  [FAIL] $m" -ForegroundColor Red }
function Assert-True($Cond, $Msg)  { if ($Cond) { _pass $Msg } else { _fail "$Msg (expected True, got False)" } }
function Assert-False($Cond, $Msg) { if (-not $Cond) { _pass $Msg } else { _fail "$Msg (expected False, got True)" } }

$scriptPath = Join-Path $PSScriptRoot 'new-agent-task.ps1'
$lines = Get-Content -LiteralPath $scriptPath

# #1076 F8: run the extracted block under PRODUCTION's error preference, not this harness's.
# new-agent-task.ps1 sets 'Continue'; this suite sets 'Stop' for its own error handling. The
# divergence is inert on this box ($PSNativeCommandUseErrorActionPreference measured False on
# pwsh 7.6.4, so a non-zero native exit does not throw under either) -- but if that ever flips,
# 'Stop' would make git's raw error throw BEFORE the block reaches its own exit-code check, and
# this suite would be proving behaviour production never has. READ the value out of the script
# rather than hard-coding it, so the harness tracks production instead of drifting from it.
$prodEap = ([regex]::Match((Get-Content -LiteralPath $scriptPath -Raw),
    '(?m)^\s*\$ErrorActionPreference\s*=\s*[''"](\w+)[''"]')).Groups[1].Value
function Invoke-AsProduction([string]$Code) {
    $outer = $ErrorActionPreference
    try {
        $ErrorActionPreference = $prodEap
        try { Invoke-Expression $Code; return '' } catch { return $_.Exception.Message }
    } finally { $ErrorActionPreference = $outer }
}

Section 'No `git worktree add` in the script discards its own output'
# BOTH creation sites: the task worktree ($wt) and the #695 best-of-N candidates ($wt_k). The
# candidate one was worse than the task one -- output discarded AND no exit-code check at all,
# so a candidate whose workspace never appeared "built" in a directory that did not exist.
$addLines = @($lines | Where-Object { $_ -match 'git\s+-C\s+\$Repo\s+worktree\s+add\s' })
Assert-True ($addLines.Count -eq 2) 'both `git worktree add` call sites are present'
foreach ($l in $addLines) {
    Assert-False ($l -match 'Out-Null') "worktree-add call does NOT discard git's message: $($l.Trim())"
}
$throwLine = @($lines | Where-Object { $_ -match 'Could not create the isolated workspace' })
Assert-True ($throwLine.Count -eq 1) 'exactly one workspace-creation throw'
Assert-True ($throwLine[0] -match '\$__wtWhy') 'the throw interpolates the CAPTURED git output, not a fixed sentence'
$candWarn = @($lines | Where-Object { $_ -match "candidate \`$k's workspace was NOT created" })
Assert-True ($candWarn.Count -eq 1) 'a failed CANDIDATE workspace is reported (it used to be wholly silent)'
Assert-True ($candWarn[0] -match '\$__cWhy') 'the candidate warning carries git''s own reason'
# F8: the harness must exercise the block under production's own error preference.
Assert-True ($prodEap -in @('Stop', 'Continue', 'SilentlyContinue')) `
    "read production's `$ErrorActionPreference out of the script (got '$prodEap')"
# R4: that read takes the FIRST match. Unambiguous while there is exactly one assignment;
# a second one added inside a function would silently pin the wrong scope's value and the
# harness would go on claiming it mirrors production. Fail loud the day that happens.
$eapAssignments = @($lines | Where-Object { $_ -match '^\s*\$ErrorActionPreference\s*=' })
Assert-True ($eapAssignments.Count -eq 1) `
    "exactly one `$ErrorActionPreference assignment in the script (found $($eapAssignments.Count) - a first-match read would pin the wrong one)"

# ---- extract the shipped block (the $__wtOut assignment through the closing brace) --------
$start = ($lines | Select-String -SimpleMatch '$__wtOut = @(git' | Select-Object -First 1).LineNumber - 1
$end = $start
while ($end -lt $lines.Count -and $lines[$end].Trim() -ne '}') { $end++ }
$shipped = ($lines[$start..$end] -join "`n")
Assert-True ($shipped -match 'worktree add' -and $shipped -match 'throw') 'extracted the real shipped block from the script'

# ---- a REAL repo whose `git worktree add` genuinely fails --------------------------------
function New-ProbeRepo {
    $root = Join-Path ([System.IO.Path]::GetTempPath()) ("verify-1076-" + [guid]::NewGuid().ToString('N').Substring(0, 8))
    New-Item -ItemType Directory -Force $root | Out-Null
    git -C $root init -q 2>&1 | Out-Null
    Set-Content -LiteralPath (Join-Path $root 'seed.txt') -Value 'seed' -Encoding utf8
    git -C $root add -A 2>&1 | Out-Null
    git -C $root -c user.email='probe@local' -c user.name='probe' commit -q -m 'seed' 2>&1 | Out-Null
    return $root
}

Section 'A REAL failing worktree add carries git''s own message into the throw'
$Repo = New-ProbeRepo
try {
    # Occupy the target path with a non-empty directory: git refuses with a specific fatal.
    $wt = Join-Path $Repo 'occupied-target'
    $branch = 'agent/probe-task'
    New-Item -ItemType Directory -Force $wt | Out-Null
    Set-Content -LiteralPath (Join-Path $wt 'blocker.txt') -Value 'x' -Encoding utf8

    $thrown = Invoke-AsProduction $shipped

    Assert-True ($thrown -ne '') 'the shipped block still THROWS on a failed worktree add (fail-closed preserved)'
    Assert-True ($thrown -match 'fatal') 'the thrown message carries git''s own diagnostic text'
    Assert-True ($thrown -match 'already exists') 'the thrown message names the actual REASON git refused'
    # R1: anchor on OUR OWN clause, not on the bare branch name. `$thrown -match [regex]::Escape($branch)`
    # was VACUOUS -- git's captured output already says "Preparing worktree (new branch 'agent/probe-task')",
    # so the branch name was present whether or not our sentence named it. Deleting "(branch '$branch')"
    # from the shipped throw left this suite at 17/17 against the mutant; with the anchor below the same
    # mutant fails (exit 1).
    #
    # WHY THE ANCHOR HOLDS, measured rather than argued (git 2.55.0, 10 real invocations -- six failure
    # modes including the three this ticket names, plus four add-spellings): git's "(" in this output is
    # ALWAYS followed by "new ", "checking " or "detached ", never by "branch " alone. So the discriminator
    # does not depend on the -b flag being present: switching -b to -B, dropping it, or adding --detach
    # cannot silently re-vacuum this assertion. That is a stronger guarantee than "git happens to say NEW
    # here", which is the weaker reason an earlier draft of this comment gave.
    #
    # Named residual: the regex pins exact clause punctuation, so double quotes, dropped parens or inserted
    # text between them WILL break it. That tightness is the fix -- a loose discriminator is what made the
    # original vacuous -- so if it ever fails, re-tighten it against the throw, never loosen it back toward
    # a bare branch-name match.
    Assert-True ($thrown -match "\(branch '$([regex]::Escape($branch))'\)") `
        'the thrown message names the branch IN OUR OWN clause (not merely echoed back by git)'
    Write-Host "    thrown: $thrown" -ForegroundColor DarkGray

    # ---- the control, with the lock OFF: the historical form must NOT carry git's words ----
    $legacy = @'
git -C $Repo worktree add $wt -b $branch 2>&1 | Out-Null
if ($LASTEXITCODE -ne 0) { throw "Could not create the isolated workspace at $wt (branch '$branch')." }
'@
    $legacyThrown = Invoke-AsProduction $legacy
    Assert-True ($legacyThrown -ne '') 'control: the historical form also throws (same fail-closed behaviour)'
    Assert-False ($legacyThrown -match 'fatal|already exists') `
        'control: the historical form loses git''s reason -- so the checks above are really measuring the fix'
} finally {
    git -C $Repo worktree prune 2>&1 | Out-Null
    Remove-Item -Recurse -Force $Repo -ErrorAction SilentlyContinue
}

Section 'The happy path is unchanged: a worktree that CAN be created does not throw'
$Repo = New-ProbeRepo
try {
    $wt = Join-Path $Repo 'fresh-target'
    $branch = 'agent/happy-task'
    $thrown = Invoke-AsProduction $shipped
    Assert-True ($thrown -eq '') 'a successful worktree add throws nothing (capturing output did not change control flow)'
    Assert-True (Test-Path (Join-Path $wt '.git')) 'the worktree was really created'
} finally {
    git -C $Repo worktree prune 2>&1 | Out-Null
    Remove-Item -Recurse -Force $Repo -ErrorAction SilentlyContinue
}

Write-Host ''
Write-Host "PASS: $script:Pass   FAIL: $script:Fail" -ForegroundColor $(if ($script:Fail) { 'Red' } else { 'Green' })
if ($script:Fail) { $script:Failures | ForEach-Object { Write-Host "  - $_" -ForegroundColor Red }; exit 1 }
exit 0
