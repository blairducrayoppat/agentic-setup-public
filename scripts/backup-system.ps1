# backup-system.ps1 — full-system periodic backup (GitHub + OneDrive + local secrets staging)
#
# What it does, each run:
#   1. GitHub: for each live repo — refresh a rolling `backup/wip-rolling` branch
#      capturing all uncommitted/untracked work (via a temp index; working tree
#      untouched), then push all branches + tags to the private origin.
#      blarai excludes 3 legacy branches carrying a >100 MB blob GitHub rejects.
#   2. OneDrive: incremental mirror of model weights, runtime databases
#      (SQLite online-backup for consistency where possible), Vikunja DB,
#      opencode config+history, Claude memory/settings, jobhunt data,
#      gitignored handoff docs, and a fresh winget package list.
#   3. Local secrets staging (C:\Users\mrbla\reformat-secrets): refreshed copies
#      of keys/credentials/env — NEVER copied to cloud by this script.
#
# Scheduled daily via Task Scheduler task "BlarAI System Backup" (see
# register-backup-task.ps1). Run manually any time:
#   pwsh -NoProfile -ExecutionPolicy Bypass -File scripts\backup-system.ps1

$ErrorActionPreference = 'Continue'
$BackupRoot = 'C:\Users\mrbla\OneDrive\BlarAI-Reformat-Backup-2026-07-01'
$SecretsDir = 'C:\Users\mrbla\reformat-secrets'
$LogFile    = Join-Path $BackupRoot 'backup-log.txt'
$failures   = [System.Collections.Generic.List[string]]::new()

function Log([string]$msg) {
    $line = "{0:yyyy-MM-dd HH:mm:ss}  {1}" -f (Get-Date), $msg
    Write-Host $line
    Add-Content -Path $LogFile -Value $line -ErrorAction SilentlyContinue
}

function Fail([string]$msg) { $script:failures.Add($msg); Log "FAIL: $msg" }

Log '===== backup-system run start ====='

# ---------------------------------------------------------------- 1. GitHub
$repos = @(
    @{ Path = 'C:/Users/mrbla/blarai';                       Name = 'blarai'
       # Branches whose history carries >100 MB blobs GitHub rejects (GH001).
       # They stay safe in the local repo + OneDrive git bundles.
       ExcludeBranches = @('refs/heads/copilot/worktree-2026-03-13T06-25-42',
                           'refs/heads/feature/openvino-contrib-agent',
                           'refs/heads/fix/vpux-crash-reproduction-intel-pr',
                           'refs/heads/feat/719-golive-ceremony') },
    @{ Path = 'C:/Users/mrbla/agentic-setup';                Name = 'agentic-setup';       ExcludeBranches = @() },
    @{ Path = 'C:/Users/mrbla/devplatform';                  Name = 'devplatform';         ExcludeBranches = @() },
    @{ Path = 'C:/Users/mrbla/jobhunt';                      Name = 'jobhunt';             ExcludeBranches = @() },
    @{ Path = 'C:/Users/mrbla/projects/jobhunt-eligibility'; Name = 'jobhunt-eligibility'; ExcludeBranches = @() }
)

foreach ($r in $repos) {
    if (-not (Test-Path $r.Path)) { Fail "$($r.Name): path missing"; continue }
    Push-Location $r.Path
    try {
        # Rolling WIP snapshot — only when the tree is dirty. Temp index keeps
        # the real index + working tree untouched. Each snapshot commit chains
        # onto the previous snapshot (parent 1) and current HEAD (parent 2), so
        # the branch only ever fast-forwards — no force-push, history preserved.
        $dirty = (git status --porcelain | Measure-Object).Count
        if ($dirty -gt 0) {
            $idx = Join-Path $env:TEMP ("bk-idx-" + [guid]::NewGuid().ToString('N'))
            $env:GIT_INDEX_FILE = $idx
            git read-tree HEAD 2>&1 | Out-Null
            git add -A -- . ':(exclude).worktrees' 2>&1 | Out-Null
            $tree   = (git write-tree).Trim()
            $head   = (git rev-parse HEAD).Trim()
            $prev   = (git rev-parse --verify -q refs/heads/backup/wip-rolling 2>$null)
            $msg    = "backup: rolling WIP snapshot $(Get-Date -Format yyyy-MM-dd_HH:mm)"
            if ($prev) { $commit = (git commit-tree $tree -p $prev.Trim() -p $head -m $msg).Trim() }
            else       { $commit = (git commit-tree $tree -p $head -m $msg).Trim() }
            Remove-Item Env:\GIT_INDEX_FILE -ErrorAction SilentlyContinue
            Remove-Item $idx -ErrorAction SilentlyContinue
            if ($commit -match '^[0-9a-f]{40}$') {
                git branch -f backup/wip-rolling $commit | Out-Null  # local ref move only; remote push below is a fast-forward
                Log "$($r.Name): WIP snapshot ($dirty entries) -> backup/wip-rolling $($commit.Substring(0,8))"
            } else { Fail "$($r.Name): WIP snapshot commit failed" }
        }

        # Push every branch except exclusions, then tags. All pushes are
        # plain (non-force); the rolling branch fast-forwards by construction.
        # @() around the WHOLE pipeline: a single surviving branch must stay an
        # array or the splat below mangles the refspec (seen as fatal: invalid refspec '/')
        $refs = @( git for-each-ref --format='%(refname)' refs/heads |
                   Where-Object { $r.ExcludeBranches -notcontains $_ } )
        $pushOut = git push origin @refs 2>&1
        if ($LASTEXITCODE -ne 0) {
            $why = ($pushOut | Where-Object { $_ -match 'error|fatal|rejected' } | Select-Object -First 3) -join ' | '
            Fail "$($r.Name): branch push exited $LASTEXITCODE — $why"
        }
        git push origin --tags 2>&1 | Out-Null
        Log "$($r.Name): pushed $($refs.Count) branches + tags"
    } finally { Pop-Location }
}

# ------------------------------------------------- 2. SQLite-consistent copies
# Online backup API folds WAL into a consistent snapshot even while apps run.
# Falls back to raw file copy (db + -wal + -shm) if python/sqlite can't open it.
function Backup-Sqlite([string]$Src, [string]$Dst) {
    if (-not (Test-Path $Src)) { return }
    New-Item -ItemType Directory -Force (Split-Path $Dst) | Out-Null
    $py = "import sqlite3,sys`ns=sqlite3.connect(sys.argv[1]);d=sqlite3.connect(sys.argv[2]);s.backup(d);d.close();s.close()"
    python -c $py $Src $Dst 2>$null
    if ($LASTEXITCODE -ne 0) {
        Copy-Item $Src $Dst -Force
        foreach ($suffix in '-wal','-shm') { if (Test-Path "$Src$suffix") { Copy-Item "$Src$suffix" "$Dst$suffix" -Force } }
        Log "sqlite fallback raw-copy: $(Split-Path $Src -Leaf)"
    } else { Log "sqlite snapshot: $(Split-Path $Src -Leaf)" }
}

Backup-Sqlite 'C:/Users/mrbla/AppData/Local/Vikunja/vikunja.db'      "$BackupRoot/vikunja/vikunja.db"
Backup-Sqlite 'C:/Users/mrbla/.local/share/opencode/opencode.db'     "$BackupRoot/opencode/opencode.db"
Backup-Sqlite 'C:/Users/mrbla/jobhunt/data/jobhunt.db'               "$BackupRoot/runtime-data/jobhunt/jobhunt.db"
foreach ($db in 'knowledge.db','sessions.db','substrate.db') {
    Backup-Sqlite "C:/Users/mrbla/AppData/Local/BlarAI/$db" "$BackupRoot/runtime-data/BlarAI/$db"
}
foreach ($f in 'dek_keystore.json','sessions.keystore.json','substrate.keystore.json','ui_prefs.json') {
    $src = "C:/Users/mrbla/AppData/Local/BlarAI/$f"
    if (Test-Path $src) { Copy-Item $src "$BackupRoot/runtime-data/BlarAI/" -Force }
}

# -------------------------------------------------------- 3. Incremental mirrors
# /E = incremental (only new/changed copy); models never shrink so no /PURGE.
robocopy C:\Users\mrbla\blarai\models "$BackupRoot\models\blarai-models" /E /NFL /NDL /NJH /NJS /R:2 /W:5 | Out-Null
if ($LASTEXITCODE -ge 8) { Fail "models robocopy exited $LASTEXITCODE" } else { Log 'models mirrored (incremental)' }

# Claude memory + settings (memory dirs only — transcripts are regenerable noise)
$claudeSrc = 'C:/Users/mrbla/.claude'
foreach ($ns in Get-ChildItem "$claudeSrc/projects" -Directory -ErrorAction SilentlyContinue) {
    $mem = Join-Path $ns.FullName 'memory'
    if (Test-Path $mem) {
        robocopy $mem "$BackupRoot\claude\projects\$($ns.Name)\memory" /E /NFL /NDL /NJH /NJS | Out-Null
    }
}
foreach ($f in 'settings.json','settings.local.json','keybindings.json','CLAUDE.md') {
    if (Test-Path "$claudeSrc/$f") { Copy-Item "$claudeSrc/$f" "$BackupRoot/claude/" -Force }
}
Log 'claude memory + settings mirrored'

# opencode config, jobhunt data files, gitignored handoff docs, fleet queue state
robocopy C:\Users\mrbla\.config\opencode "$BackupRoot\opencode\config" /E /XD node_modules /XF package-lock.json /NFL /NDL /NJH /NJS | Out-Null
robocopy C:\Users\mrbla\jobhunt\data "$BackupRoot\runtime-data\jobhunt" /E /XF jobhunt.db /NFL /NDL /NJH /NJS | Out-Null
if (Test-Path 'C:/Users/mrbla/blarai/docs/handoffs') {
    robocopy C:\Users\mrbla\blarai\docs\handoffs "$BackupRoot\misc\blarai-handoffs" /E /NFL /NDL /NJH /NJS | Out-Null
}
foreach ($f in 'C:/Users/mrbla/agentic-setup/state/fleet-queue.json','C:/Users/mrbla/agentic-setup/state/recent-projects.txt') {
    if (Test-Path $f) { Copy-Item $f "$BackupRoot/misc/" -Force }
}
Log 'opencode/jobhunt-data/handoffs/fleet-state mirrored'

# Fresh installed-package list (cheap, drifts as software changes)
winget export -o "$BackupRoot/system/winget-packages.json" --accept-source-agreements 2>&1 | Out-Null

# Restore runbook: the tracked MASTER (blarai repo) -> backup root, so the copy
# read after a disaster is never staler than the last backup (#782). Fail loud:
# a missing master means the runbook moved and this sync must be repointed.
$runbookMaster = 'C:/Users/mrbla/blarai/docs/runbooks/DISASTER_RECOVERY_RESTORE.md'
if (Test-Path $runbookMaster) {
    Copy-Item $runbookMaster "$BackupRoot/RESTORE_RUNBOOK.md" -Force
    Log 'restore runbook synced from tracked master'
} else { Fail 'restore runbook master missing (docs/runbooks/DISASTER_RECOVERY_RESTORE.md)' }

# ------------------------------------------- 4. Local secrets staging (no cloud)
New-Item -ItemType Directory -Force $SecretsDir | Out-Null
Copy-Item C:/Users/mrbla/.ssh "$SecretsDir/ssh" -Recurse -Force
foreach ($m in @(
    @{ s = 'C:/Users/mrbla/.gitconfig';                     d = 'gitconfig' },
    @{ s = 'C:/Users/mrbla/.git-credentials';               d = 'git-credentials' },
    @{ s = 'C:/Users/mrbla/jobhunt/.env';                   d = 'jobhunt.env' },
    @{ s = 'C:/Users/mrbla/.blarai-fleet/credentials.env';  d = 'blarai-fleet.credentials.env' },
    @{ s = 'C:/Users/mrbla/.blarai-fleet/leakgate-patterns.txt'; d = 'leakgate-patterns.txt' },
    @{ s = 'C:/Users/mrbla/blarai/.mcp.json';               d = 'blarai.mcp.json' },
    @{ s = 'C:/Users/mrbla/agentic-setup/.mcp.json';        d = 'agentic-setup.mcp.json' },
    @{ s = 'C:/Users/mrbla/devplatform/.mcp.json';          d = 'devplatform.mcp.json' },
    @{ s = 'C:/Users/mrbla/.codex/auth.json';               d = 'codex.auth.json' },
    @{ s = 'C:/Users/mrbla/devplatform/tools/vikunja/config.yml'; d = 'vikunja.config.yml' },
    @{ s = "$env:APPDATA/Claude/claude_desktop_config.json"; d = 'claude_desktop_config.json' }
)) { if (Test-Path $m.s) { Copy-Item $m.s "$SecretsDir/$($m.d)" -Force } }
[Environment]::GetEnvironmentVariables('User').GetEnumerator() | Sort-Object Name |
    ForEach-Object { "$($_.Name)=$($_.Value)" } | Set-Content "$SecretsDir/user-env-vars.txt"
Copy-Item "$BackupRoot/RESTORE_RUNBOOK.md" "$SecretsDir/" -Force -ErrorAction SilentlyContinue
Log 'secrets staging refreshed (local only)'

# ------------------------------------------------------------------- 5. Stamp
$status = if ($failures.Count -eq 0) { 'OK' } else { "COMPLETED WITH $($failures.Count) FAILURE(S): " + ($failures -join '; ') }
"Last backup: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')  status: $status" | Set-Content "$BackupRoot/LAST_BACKUP.txt"
Log "===== backup-system run end: $status ====="
if ($failures.Count -gt 0) { exit 1 }
