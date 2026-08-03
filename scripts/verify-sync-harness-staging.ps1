#requires -Version 7.0
<#
.SYNOPSIS
  Verify sync-harness.ps1 stages ONLY the files it wrote, and fails loudly rather than silently (#1190).

.DESCRIPTION
  Background (plain English):
    sync-harness.ps1 copies the LIVE harness config files into agentic-setup\configs and commits
    the drift. It fires unattended - start-llm, the control panel and backups all call it, and
    start-llm sits on the battery path - so nobody is watching when it commits. It used to run
    `git add -A` across the whole shared tree and then auto-commit as 'harness-sync', which meant
    any other session's untracked work in that tree became part of a robot commit whose message
    described something else entirely. Both git calls were piped to Out-Null under
    $ErrorActionPreference='SilentlyContinue', so a failure left no trace anywhere.

    This suite does NOT re-implement the staging logic. It runs the SHIPPED scripts\sync-harness.ps1
    against REAL throwaway git repositories, pointed at a fake USERPROFILE and a fake setup root via
    the AGENTIC_SETUP_ROOT env override, and inspects what git actually recorded.

    Every check ships with its control tested OFF: the historical `git add -A` form is run against
    the SAME fixture and must sweep the untracked file, and the historical Out-Null form must stay
    silent on the SAME git failure. Without those, a passing suite would prove nothing.

  Run it normally ( .\verify-sync-harness-staging.ps1 ) - do NOT dot-source it.
  Needs git and pwsh on PATH. No model, no OVMS, no network, and it never touches the real
  agentic-setup repo. Exit 0 all passed, 1 any failure.
#>
param()
$ErrorActionPreference = 'Stop'

# Tiny zero-dependency test framework (mirrors verify-worktree-add-fail-loud.ps1 so the suites read identically).
$script:Pass = 0
$script:Fail = 0
$script:Failures = New-Object System.Collections.ArrayList
function Section($t) { Write-Host ''; Write-Host "== $t ==" -ForegroundColor Cyan }
function _pass($m)   { $script:Pass++; Write-Host "  [PASS] $m" -ForegroundColor Green }
function _fail($m)   { $script:Fail++; [void]$script:Failures.Add($m); Write-Host "  [FAIL] $m" -ForegroundColor Red }
function Assert-True($Cond, $Msg)  { if ($Cond) { _pass $Msg } else { _fail "$Msg (expected True, got False)" } }
function Assert-False($Cond, $Msg) { if (-not $Cond) { _pass $Msg } else { _fail "$Msg (expected False, got True)" } }
function Assert-Eq($Expected, $Actual, $Msg) {
    if ($Expected -eq $Actual) { _pass "$Msg (= $Actual)" } else { _fail "$Msg (expected '$Expected', got '$Actual')" }
}

$ScriptPath = Join-Path $PSScriptRoot 'sync-harness.ps1'
if (-not (Test-Path $ScriptPath)) { throw "sync-harness.ps1 not found at $ScriptPath" }
$ScriptText  = Get-Content -LiteralPath $ScriptPath -Raw
$ScriptLines = Get-Content -LiteralPath $ScriptPath
# CODE only, for the static checks: the header comment quotes `git add -A` to explain what was
# removed, and the commit call wraps across a backtick continuation. Scanning raw lines made the
# first check match prose and the second see half a statement. Fold continuations, drop comments.
$CodeText  = ($ScriptText -replace '`\r?\n\s*', ' ')
$CodeLines = @($CodeText -split "`r?`n" | Where-Object { $_ -notmatch '^\s*#' })
$Code      = $CodeLines -join "`n"

# ---------------------------------------------------------------------------
# Fixture: a throwaway setup repo + a fake USERPROFILE holding the live configs.
# ---------------------------------------------------------------------------
$script:Fixtures = New-Object System.Collections.ArrayList

function New-Fixture {
    $root = Join-Path ([System.IO.Path]::GetTempPath()) ("verify-1190-" + [guid]::NewGuid().ToString('N').Substring(0, 8))
    $setup = Join-Path $root 'setup'
    $home_ = Join-Path $root 'profile'
    New-Item -ItemType Directory -Force `
        (Join-Path $setup 'configs\agents'), (Join-Path $setup 'scripts'), (Join-Path $setup 'docs'), `
        (Join-Path $home_ '.config\opencode\agents'), (Join-Path $home_ '.openclaw') | Out-Null

    # The LIVE side (what agents actually read).
    Set-Content -LiteralPath (Join-Path $home_ '.config\opencode\opencode.json') -Value '{"model":"seed"}' -Encoding utf8
    Set-Content -LiteralPath (Join-Path $home_ '.config\opencode\AGENTS.md')     -Value "# agents`nseed" -Encoding utf8
    Set-Content -LiteralPath (Join-Path $home_ '.config\opencode\agents\review.md') -Value "# review`nseed" -Encoding utf8
    Set-Content -LiteralPath (Join-Path $home_ '.wslconfig')                     -Value '[wsl2]' -Encoding utf8
    Set-Content -LiteralPath (Join-Path $home_ '.openclaw\openclaw.json')        -Value '{"seed":1}' -Encoding utf8

    # The tracked mirror, seeded IN SYNC so a fresh run is a genuine no-op.
    Copy-Item (Join-Path $home_ '.config\opencode\opencode.json')      (Join-Path $setup 'configs\opencode.json')
    Copy-Item (Join-Path $home_ '.config\opencode\AGENTS.md')          (Join-Path $setup 'configs\AGENTS.md')
    Copy-Item (Join-Path $home_ '.config\opencode\agents\review.md')   (Join-Path $setup 'configs\agents\review.md')
    Copy-Item (Join-Path $home_ '.wslconfig')                          (Join-Path $setup 'configs\wslconfig-live.txt')
    Copy-Item (Join-Path $home_ '.openclaw\openclaw.json')             (Join-Path $setup 'configs\openclaw-live.json')
    Set-Content -LiteralPath (Join-Path $setup 'docs\unrelated.md') -Value 'someone else owns this' -Encoding utf8

    git -C $setup init -q -b main 2>&1 | Out-Null
    git -C $setup add -A 2>&1 | Out-Null
    git -C $setup -c user.email='probe@local' -c user.name='probe' commit -q -m 'seed' 2>&1 | Out-Null

    [void]$script:Fixtures.Add($root)
    return [pscustomobject]@{ Root = $root; Setup = $setup; Profile = $home_ }
}

# Plant exactly the hazard the ticket names: another session's in-flight work, live in this tree.
function Add-OtherSessionWork($fx) {
    Set-Content -LiteralPath (Join-Path $fx.Setup 'scripts\reenable-battery-nightly.ps1') `
        -Value '# another session''s untracked script (target of a registered scheduled task)' -Encoding utf8
    Add-Content -LiteralPath (Join-Path $fx.Setup 'docs\unrelated.md') -Value 'an uncommitted edit of theirs' -Encoding utf8
    Set-Content -LiteralPath (Join-Path $fx.Setup 'docs\their-staged.md') -Value 'they already ran git add on this' -Encoding utf8
    git -C $fx.Setup add -- 'docs/their-staged.md' 2>&1 | Out-Null
}

function Set-LiveDrift($fx) {
    # Two kinds at once: an EDIT to a tracked mirror, and a BRAND-NEW live agent file whose
    # destination git has never seen (the `commit --only` path that needs the add to have landed).
    Set-Content -LiteralPath (Join-Path $fx.Profile '.config\opencode\AGENTS.md') -Value "# agents`ndrifted live" -Encoding utf8
    Set-Content -LiteralPath (Join-Path $fx.Profile '.config\opencode\agents\build.md') -Value "# build`nbrand new" -Encoding utf8
}

function Get-Head($setup) { (git -C $setup rev-parse HEAD 2>&1 | Out-String).Trim() }
function Get-Untracked($setup) { @(git -C $setup ls-files --others --exclude-standard 2>&1) }
function Get-CommitFiles($setup, $ref = 'HEAD') { @(git -C $setup show --name-only --pretty=format: $ref 2>&1 | Where-Object { $_ -ne '' }) }
function Get-Staged($setup) { @(git -C $setup diff --cached --name-only 2>&1 | Where-Object { $_ -ne '' }) }

# Run a script file in a CHILD pwsh with the fixture's env, capturing every stream.
# The env is set on this process (children inherit) and restored immediately after.
function Invoke-InFixture($fx, [string]$File) {
    $prevProfile = $env:USERPROFILE
    $prevRoot    = $env:AGENTIC_SETUP_ROOT
    try {
        $env:USERPROFILE        = $fx.Profile
        $env:AGENTIC_SETUP_ROOT = $fx.Setup
        $out = & pwsh -NoProfile -ExecutionPolicy Bypass -File $File *>&1 | Out-String
        return [pscustomobject]@{ Output = $out; ExitCode = $LASTEXITCODE }
    } finally {
        $env:USERPROFILE        = $prevProfile
        if ($null -eq $prevRoot) { Remove-Item Env:\AGENTIC_SETUP_ROOT -ErrorAction SilentlyContinue }
        else { $env:AGENTIC_SETUP_ROOT = $prevRoot }
    }
}

# The pre-#1190 script, verbatim, as the control. Kept as a literal because the point of a
# control is to be the OLD code - extracting it from the current file is impossible by design.
$LegacyPath = Join-Path ([System.IO.Path]::GetTempPath()) ("verify-1190-legacy-" + [guid]::NewGuid().ToString('N').Substring(0, 8) + '.ps1')
Set-Content -LiteralPath $LegacyPath -Encoding utf8 -Value @'
$ErrorActionPreference = 'SilentlyContinue'
$Setup = $env:AGENTIC_SETUP_ROOT
function Sync-One([string]$src, [string]$dst) {
    if (-not (Test-Path $src)) { return $false }
    if ((Test-Path $dst) -and ((Get-FileHash $src).Hash -eq (Get-FileHash $dst).Hash)) { return $false }
    New-Item -ItemType Directory -Force (Split-Path $dst) | Out-Null
    Copy-Item $src $dst -Force
    return $true
}
$changed = $false
$changed = (Sync-One "$env:USERPROFILE\.config\opencode\opencode.json" "$Setup\configs\opencode.json") -or $changed
$changed = (Sync-One "$env:USERPROFILE\.config\opencode\AGENTS.md"     "$Setup\configs\AGENTS.md")     -or $changed
$changed = (Sync-One "$env:USERPROFILE\.wslconfig"                     "$Setup\configs\wslconfig-live.txt") -or $changed
if (Test-Path "$env:USERPROFILE\.openclaw\openclaw.json") {
    $changed = (Sync-One "$env:USERPROFILE\.openclaw\openclaw.json" "$Setup\configs\openclaw-live.json") -or $changed
}
foreach ($f in (Get-ChildItem "$env:USERPROFILE\.config\opencode\agents\*.md" -ErrorAction SilentlyContinue)) {
    $changed = (Sync-One $f.FullName "$Setup\configs\agents\$($f.Name)") -or $changed
}
if ($changed) {
    git -C $Setup add -A 2>&1 | Out-Null
    git -C $Setup -c user.email='sync@local' -c user.name='harness-sync' commit -m "harness sync: live config drift captured" 2>&1 | Out-Null
    Write-Host "Harness change detected - recorded in setup history." -ForegroundColor DarkCyan
}
'@

try {

# ---------------------------------------------------------------------------
Section 'Static: the shipped script no longer blanket-adds, and no longer discards git''s words'
# ---------------------------------------------------------------------------
Assert-False ($Code -match 'git\s+(-C\s+\S+\s+)?add\s+-A') 'no `git add -A` in the script''s CODE (the #1190 predicate)'
Assert-True  ($ScriptText -match 'git add -A') 'the header still explains WHY it is gone (prose, not code)'
$gitLines = @($CodeLines | Where-Object { $_ -match '\bgit\s+-C' })
Assert-True ($gitLines.Count -ge 3) "the git calls are present ($($gitLines.Count) found)"
foreach ($l in $gitLines) {
    Assert-True ($l -match 'add --|diff --cached|commit --only') "git call is path-scoped or a read: $($l.Trim())"
}
Assert-True ($Code -match 'commit --only') 'the commit uses --only, so a concurrent session''s staged index is not swept in'
Assert-True (($CodeLines | Where-Object { $_ -match 'Write-Warning' }).Count -ge 3) `
    'every git failure path reports (Write-Warning), instead of Out-Null swallowing it'
Assert-False ($Code -match '(?m)^\s*throw\b') `
    'the script never throws - its callers run under $ErrorActionPreference=Stop and start-llm is on the battery path'

# ---------------------------------------------------------------------------
Section 'A REAL sync leaves another session''s untracked work alone'
# ---------------------------------------------------------------------------
$fx = New-Fixture
Add-OtherSessionWork $fx
Set-LiveDrift $fx
$before = Get-Head $fx.Setup
$run = Invoke-InFixture $fx $ScriptPath
Write-Host "    script said: $($run.Output.Trim())" -ForegroundColor DarkGray

$after = Get-Head $fx.Setup
Assert-True ($after -ne $before) 'the sync DID commit (otherwise the checks below are vacuous)'
Assert-Eq 1 ([int](git -C $fx.Setup rev-list --count "$before..HEAD")) 'exactly one commit was created'

$committed = Get-CommitFiles $fx.Setup
Assert-True ($committed -contains 'configs/AGENTS.md') 'the drifted config WAS committed'
Assert-True ($committed -contains 'configs/agents/build.md') 'a brand-new live agent file WAS committed (commit --only handles a path new to git)'
Assert-Eq 2 $committed.Count "the commit touches ONLY what the sync wrote ($($committed -join ', '))"

$untracked = Get-Untracked $fx.Setup
Assert-True ($untracked -contains 'scripts/reenable-battery-nightly.ps1') `
    'THE DEFECT: the unrelated untracked script is STILL untracked after a real sync'
Assert-False ($committed -contains 'scripts/reenable-battery-nightly.ps1') 'it was not committed'
Assert-True ((git -C $fx.Setup diff --name-only) -contains 'docs/unrelated.md') `
    'another session''s uncommitted EDIT to a tracked file is still uncommitted'
Assert-True ((Get-Staged $fx.Setup) -contains 'docs/their-staged.md') `
    'another session''s already-STAGED file is left staged - neither committed nor unstaged'

# ---------------------------------------------------------------------------
Section 'Control, lock OFF: the historical `git add -A` form DOES sweep it'
# ---------------------------------------------------------------------------
$fxC = New-Fixture
Add-OtherSessionWork $fxC
Set-LiveDrift $fxC
$beforeC = Get-Head $fxC.Setup
$runC = Invoke-InFixture $fxC $LegacyPath
$afterC = Get-Head $fxC.Setup
Assert-True ($afterC -ne $beforeC) 'control: the historical form also commits (same trigger, same fixture)'
$committedC = Get-CommitFiles $fxC.Setup
Assert-True ($committedC -contains 'scripts/reenable-battery-nightly.ps1') `
    'control: the historical form SWEEPS the unrelated untracked script - so the check above is really measuring the fix'
Assert-True ($committedC -contains 'docs/their-staged.md') 'control: it also commits another session''s staged file'

# ---------------------------------------------------------------------------
Section 'No drift, no action (unchanged behaviour)'
# ---------------------------------------------------------------------------
$headBefore = Get-Head $fx.Setup
$run2 = Invoke-InFixture $fx $ScriptPath
Assert-Eq $headBefore (Get-Head $fx.Setup) 'a second run with nothing drifted creates no commit'
Assert-False ($run2.Output -match 'Harness change detected') 'and says nothing'
Assert-True ($untracked -contains 'scripts/reenable-battery-nightly.ps1') 'the untracked script survived that run too'

# ---------------------------------------------------------------------------
Section 'A git failure is LOUD but not fatal'
# ---------------------------------------------------------------------------
$fxL = New-Fixture
Set-LiveDrift $fxL
Set-Content -LiteralPath (Join-Path $fxL.Setup '.git\index.lock') -Value '' -Encoding utf8   # a concurrent agent holds the index
$headL = Get-Head $fxL.Setup
$runL = Invoke-InFixture $fxL $ScriptPath
Assert-Eq $headL (Get-Head $fxL.Setup) 'the failed capture recorded nothing'
Assert-True ($runL.Output -match 'WARNING') 'the failure is REPORTED (it used to vanish into Out-Null)'
Assert-True ($runL.Output -match 'index\.lock|Unable to create') 'the report carries git''s OWN words, not a generic sentence'
Assert-Eq 0 $runL.ExitCode 'and it is NOT fatal - the caller (start-llm, mid battery night) continues'
Write-Host "    reported: $(($runL.Output -split "`n" | Where-Object { $_ -match 'WARNING' }) -join ' ')" -ForegroundColor DarkGray

# Control, lock OFF: the historical form must stay SILENT on the same failure.
$fxLC = New-Fixture
Set-LiveDrift $fxLC
Set-Content -LiteralPath (Join-Path $fxLC.Setup '.git\index.lock') -Value '' -Encoding utf8
$runLC = Invoke-InFixture $fxLC $LegacyPath
Assert-False ($runLC.Output -match 'WARNING|index\.lock') `
    'control: the historical Out-Null form reports NOTHING on the same failure - so the checks above measure the fix'
Assert-True ($runLC.Output -match 'Harness change detected') `
    'control: worse, it announced success while nothing was recorded'

} finally {
    Remove-Item -LiteralPath $LegacyPath -Force -ErrorAction SilentlyContinue
    foreach ($r in $script:Fixtures) { Remove-Item -Recurse -Force -LiteralPath $r -ErrorAction SilentlyContinue }
}

Write-Host ''
Write-Host "PASS: $script:Pass   FAIL: $script:Fail" -ForegroundColor $(if ($script:Fail) { 'Red' } else { 'Green' })
if ($script:Fail) { $script:Failures | ForEach-Object { Write-Host "  - $_" -ForegroundColor Red }; exit 1 }
exit 0
