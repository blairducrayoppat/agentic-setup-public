# publish-public-snapshot.ps1 — publish a HISTORY-FREE snapshot of each repo's main
# to its clean-name GitHub repo (the "public" remote).
#
# How it protects history:
#   - The snapshot commit is built from main's current TREE only (git commit-tree).
#     Its ancestry contains ONLY previous snapshot commits — never any working history.
#   - Local repos are NEVER modified: no branch moves, no checkouts, no resets. The
#     only local writes are new objects + one additive bookkeeping ref per repo
#     (refs/public-snapshots/main), which no normal git command ever touches.
#   - Publishing again chains the new snapshot onto the previous one, so every push
#     is a plain fast-forward. No force-push, ever.
#
# Leak-gate: before pushing, the snapshot tree is scanned for known-sensitive
# patterns. Any hit ABORTS that repo's publish.
#
# The clean-name repos stay PRIVATE until the go-public ceremony; flipping them to
# public is a manual GitHub settings step (or: gh repo edit <name> --visibility public).
#
# Usage:  pwsh -File scripts\publish-public-snapshot.ps1 [-Only <repo-name>]

param([string]$Only)

$ErrorActionPreference = 'Continue'
$repos = @(
    @{ Path = 'C:/Users/mrbla/blarai';                       Name = 'blarai' },
    @{ Path = 'C:/Users/mrbla/agentic-setup';                Name = 'agentic-setup' },
    @{ Path = 'C:/Users/mrbla/devplatform';                  Name = 'devplatform' },
    @{ Path = 'C:/Users/mrbla/jobhunt';                      Name = 'jobhunt' },
    @{ Path = 'C:/Users/mrbla/projects/jobhunt-eligibility'; Name = 'jobhunt-eligibility' }
)

# --- leak-gate patterns ---
# Generic token shapes live inline (harmless to publish). Topic-sensitive
# patterns live in a PRIVATE file outside every repo — the published tree must
# never contain the terms it is scanned for. Fail-closed if the file is absent.
$fixedSecrets = @()
$vp = [Environment]::GetEnvironmentVariable('VIKUNJA_PASS', 'User')
if ($vp -and $vp -ne '${VIKUNJA_PASS}') { $fixedSecrets += $vp }
$regexes = @(
    'sk-ant-[A-Za-z0-9_\-]{10,}',
    'ghp_[A-Za-z0-9]{20,}', 'github_pat_[A-Za-z0-9_]{20,}', 'hf_[A-Za-z0-9]{20,}'
)
$privatePatterns = 'C:/Users/mrbla/.blarai-fleet/leakgate-patterns.txt'
if (-not (Test-Path $privatePatterns)) {
    Write-Host "FATAL: private leak-gate pattern file missing: $privatePatterns" -ForegroundColor Red
    Write-Host "Refusing to publish anything without the full gate (fail-closed)." -ForegroundColor Red
    exit 2
}
$regexes += @(Get-Content $privatePatterns | Where-Object { $_ -and $_ -notmatch '^\s*#' })

$fail = 0
foreach ($r in $repos) {
    if ($Only -and $r.Name -ne $Only) { continue }
    Push-Location $r.Path
    try {
        $tree = (git rev-parse 'main^{tree}').Trim()
        $srcHead = (git rev-parse main).Trim().Substring(0, 8)

        # --- leak-gate: scan the exact tree being published ---
        $hits = @()
        foreach ($s in $fixedSecrets) { $h = git grep -l -F $s $tree 2>$null; if ($h) { $hits += "secret-value -> $($h -join ',')" } }
        foreach ($rx in $regexes)     { $h = git grep -l -E $rx $tree 2>$null; if ($h) { $hits += "$rx -> $(($h | Select-Object -First 3) -join ',')" } }
        if ($hits) {
            Write-Host "[$($r.Name)] LEAK-GATE FAILED — NOT published:" -ForegroundColor Red
            $hits | ForEach-Object { Write-Host "    $_" -ForegroundColor Red }
            $fail++
            continue
        }

        # --- build snapshot commit (chained onto previous snapshot if any) ---
        $prev = (git rev-parse --verify -q refs/public-snapshots/main 2>$null)
        $msg = "Public snapshot $(Get-Date -Format yyyy-MM-dd) (from $srcHead)"
        if ($prev) {
            $prevTree = (git rev-parse "$($prev.Trim())^{tree}").Trim()
            if ($prevTree -eq $tree) { Write-Host "[$($r.Name)] tree unchanged since last snapshot — skipping"; continue }
            $commit = (git commit-tree $tree -p $prev.Trim() -m $msg).Trim()
        } else {
            $commit = (git commit-tree $tree -m $msg).Trim()
        }
        if ($commit -notmatch '^[0-9a-f]{40}$') { Write-Host "[$($r.Name)] snapshot commit failed" -ForegroundColor Red; $fail++; continue }

        git update-ref refs/public-snapshots/main $commit
        git push public "${commit}:refs/heads/main" 2>&1 | Out-Null
        if ($LASTEXITCODE -ne 0) { Write-Host "[$($r.Name)] push failed ($LASTEXITCODE)" -ForegroundColor Red; $fail++; continue }
        Write-Host "[$($r.Name)] published snapshot $($commit.Substring(0,8)) (tree of main @ $srcHead)" -ForegroundColor Green
    } finally { Pop-Location }
}
if ($fail -gt 0) { exit 1 }
