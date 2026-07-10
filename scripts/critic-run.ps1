<#
.SYNOPSIS
    Run the 14B cross-model code critic on the merged diff (#687 task 2).
    Output is printed to stdout; the Python driver (real_run_critic) redirects that to a
    per-run log file and parses VERDICT: MERGE / VERDICT: FIX FIRST from it.

.DESCRIPTION
    1. Gathers the git diff for the prompt (the critic agent has bash:deny and cannot run
       git itself; the diff is given verbatim so the critic works from what it is shown).
    2. Calls Invoke-AgentRun with -Agent 'critic' (critic.md: read-only, blocker-only,
       default-merge, no-propose-fix).
    3. Reads the agent log and writes it to stdout for the caller to capture.

    PS 5.1-safe; ASCII only; all special chars in the diff are handled via string
    concatenation (not a double-quoted here-string) to avoid PS escape-char conflicts.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$AppDir,
    [Parameter(Mandatory)][string]$BaseBranch,
    [string]$Model = 'qwen3-14b',
    # #693: main's pre-dispatch HEAD SHA (recorded by swap_driver before the first task).
    # Non-empty -> the diff range is "<sha>..HEAD" = ALL merged work, robust to a
    # multi-commit fast-forward; empty -> the legacy Resolve-CriticRange chain.
    [string]$BaseRef = ''
)

$ErrorActionPreference = 'Stop'
$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path

. "$ScriptDir\fleet-lib.ps1"

# --- Gather the diff for the critic prompt ----------------------------------------
# critic.md has bash:deny; the agent cannot run git. We run it here and embed the output.
# Resolve-CriticRange (fleet-lib.ps1) handles the #687 #9 empty-diff bug: post-merge on the base
# branch "<base>...HEAD" is EMPTY (HEAD == base), so it falls back to the merged work's range.
$criticRange = Resolve-CriticRange -Repo $AppDir -Base $BaseBranch -BaseRef $BaseRef
$diffStat = if ($criticRange) { (git -C $AppDir diff $criticRange --stat 2>$null) -join "`n" } else { '' }
$diffFull = if ($criticRange) { (git -C $AppDir diff $criticRange 2>$null) -join "`n" } else { '' }
# Truncate very large diffs; the critic can Read individual files for more context.
$MaxDiffChars = 8000
if ($diffFull -and $diffFull.Length -gt $MaxDiffChars) {
    $diffFull = $diffFull.Substring(0, $MaxDiffChars) +
        "`n[diff truncated at $MaxDiffChars chars -- use the Read tool on specific files above for full context]"
}
if (-not $diffStat) { $diffStat = '(no stat output -- git may not be on PATH or branch not found)' }
if (-not $diffFull)  { $diffFull  = '(no diff output)' }

# --- Build the per-run prompt -------------------------------------------------------
# Static parts use single-quoted strings (no PS variable/escape expansion); dynamic parts
# (diff content) are concatenated so their bytes pass through exactly as-is.
$header = 'Review the diff below for MERGE-BLOCKING defects. The deterministic gate' +
    ' (build + unit tests + linter) is GREEN on this exact diff.' +
    ' You are looking ONLY for real bugs the automated gate cannot catch.' +
    ' Apply your rules exactly as defined in your instructions.'
$footer = 'If you need to read a full file for context, use the Read tool on the' +
    ' file path shown in the diff header lines.'
$Prompt = $header + "`n`nCHANGED FILES:`n" + $diffStat +
    "`n`nDIFF:`n" + $diffFull +
    "`n`n" + $footer

# --- Run the critic agent -----------------------------------------------------------
$LogFile = Join-Path $env:TEMP ("critic-" + $PID + "-" + [System.DateTime]::Now.ToString('yyyyMMddHHmmss') + ".log")
try {
    $null = Invoke-AgentRun `
        -WorkDir    $AppDir `
        -Model      $Model `
        -Agent      'critic' `
        -LogPath    $LogFile `
        -Prompt     $Prompt `
        -TimeoutSec 600

    if (Test-Path $LogFile) {
        Get-Content $LogFile -Raw
    }
} finally {
    foreach ($f in @($LogFile, "$LogFile.err", "$LogFile.stdin")) {
        if (Test-Path $f) {
            Remove-Item $f -Force -ErrorAction SilentlyContinue
        }
    }
}
