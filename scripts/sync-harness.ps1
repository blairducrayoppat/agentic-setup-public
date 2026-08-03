# Captures drift between the LIVE harness files (the ones agents actually read)
# and the git-tracked copies in agentic-setup\configs. Called automatically by
# start-llm, the control panel, and backups - so any change to the live harness
# gets recorded in git history at the next use of the system.
#
# #1190: staging is scoped to the destinations THIS invocation actually wrote.
# It used to `git add -A` the whole tree and auto-commit as 'harness-sync' with
# nobody watching, so another session's untracked work got swept into a robot
# commit whose message described something else. Agents share this tree.
# Failures are LOUD but never fatal: start-llm.ps1 and backup-config.ps1 both
# call this under $ErrorActionPreference='Stop', and start-llm is on the battery
# path (dispatch_harness/probe.py -> start-llm.ps1:42 -> here). A throw over a
# transient git condition - an index.lock held by a concurrent agent - would
# abort a model load mid-night. Warn, skip the capture, let the caller continue.
$ErrorActionPreference = 'SilentlyContinue'
# Env override AGENTIC_SETUP_ROOT, else the canonical default - mirrors new-agent-task.ps1's
# BLARAI_REPO convention. verify-sync-harness-staging.ps1 drives the REAL script through it.
$Setup = if ($env:AGENTIC_SETUP_ROOT) { $env:AGENTIC_SETUP_ROOT } else { 'C:\Users\mrbla\agentic-setup' }

# The ONLY paths this run may stage: destinations it copied to, in this invocation.
$script:Written = @()

function Sync-One([string]$src, [string]$dst) {
    if (-not (Test-Path $src)) { return }
    if ((Test-Path $dst) -and ((Get-FileHash $src).Hash -eq (Get-FileHash $dst).Hash)) { return }
    try {
        New-Item -ItemType Directory -Force (Split-Path $dst) -ErrorAction Stop | Out-Null
        Copy-Item $src $dst -Force -ErrorAction Stop
    } catch {
        # Fail-closed on staging: a copy that did not happen must not be recorded as written.
        Write-Warning "sync-harness: could not capture $src -> $dst - drift NOT recorded. $($_.Exception.Message)"
        return
    }
    $script:Written += $dst
}

Sync-One "$env:USERPROFILE\.config\opencode\opencode.json" "$Setup\configs\opencode.json"
Sync-One "$env:USERPROFILE\.config\opencode\AGENTS.md"     "$Setup\configs\AGENTS.md"
Sync-One "$env:USERPROFILE\.wslconfig"                     "$Setup\configs\wslconfig-live.txt"
Sync-One "$env:USERPROFILE\.openclaw\openclaw.json"        "$Setup\configs\openclaw-live.json"
foreach ($f in (Get-ChildItem "$env:USERPROFILE\.config\opencode\agents\*.md" -ErrorAction SilentlyContinue)) {
    Sync-One $f.FullName "$Setup\configs\agents\$($f.Name)"
}

if ($script:Written.Count -gt 0) {
    # Read git's exit codes deterministically rather than through the host's preference
    # (the run-battery-night.ps1 Invoke-GitRead convention).
    $prevNativeErrPref = $PSNativeCommandUseErrorActionPreference
    try {
        $PSNativeCommandUseErrorActionPreference = $false

        $addOut = (git -C $Setup add -- $script:Written 2>&1 | Out-String).Trim()
        if ($LASTEXITCODE -ne 0) {
            Write-Warning "sync-harness: git add failed (exit $LASTEXITCODE) - live drift NOT recorded. $addOut"
            return
        }

        # --only commits these paths from a temporary index built on HEAD, so a concurrent
        # session's already-staged work is neither committed nor unstaged by this run.
        # Ask first whether OUR paths carry any staged difference: a raw-byte copy can be a
        # git no-op (line-ending normalisation), and a "nothing to commit" refusal is benign,
        # not a fault. Separating the two is what keeps the warning below meaningful.
        git -C $Setup diff --cached --quiet -- $script:Written 2>&1 | Out-Null
        $diffRc = $LASTEXITCODE
        if ($diffRc -eq 0) {
            Write-Host "Harness change detected - no git-visible difference (e.g. line endings); nothing recorded." -ForegroundColor DarkCyan
            return
        }
        if ($diffRc -ne 1) {
            Write-Warning "sync-harness: could not inspect the staged drift (git diff --cached exit $diffRc) - live drift NOT recorded."
            return
        }

        $rel = $script:Written | ForEach-Object { $_.Substring($Setup.Length).TrimStart('\').Replace('\', '/') }
        $msg = "harness sync: live config drift captured`n`n" + (($rel | ForEach-Object { "  $_" }) -join "`n")
        $commitOut = (git -C $Setup -c user.email='sync@local' -c user.name='harness-sync' `
            commit --only -m $msg -- $script:Written 2>&1 | Out-String).Trim()
        if ($LASTEXITCODE -ne 0) {
            Write-Warning "sync-harness: git commit failed (exit $LASTEXITCODE) - the drift was copied into $Setup\configs but is NOT in git history. $commitOut"
            return
        }
        Write-Host "Harness change detected - recorded in setup history: $($rel -join ', ')" -ForegroundColor DarkCyan
    } finally {
        $PSNativeCommandUseErrorActionPreference = $prevNativeErrPref
    }
}
