#requires -Version 5.1
<#
.SYNOPSIS
  Verify the #694 follow-up coder-leg REAP + write-SETTLE barrier: an agent leg's opencode process
  tree is reaped on every exit path, the worktree is proven quiesced before the read-only review
  snapshots it, and post-commit stray writes are discarded so the reviewed tree == the committed
  candidate. Plus the dotnet-console scaffold now gitignores bin/+obj/ so build output stops widening
  the digest surface. Builds real throwaway git repos + synthetic process snapshots; no model, no
  network, and it SPAWNS/KILLS nothing (the reap decision is tested as the pure selector).

.DESCRIPTION
  Incident (run 20260710-152121, #694 follow-up): the #694 read-only-review digest guard FIRED on an
  HONEST build -- the reviewer made only Read calls, yet Calculator.cs (a seed file the coder never
  edited) had its trailing newline stripped ~10 min after the coder-fix leg, DURING the review, by a
  straggling opencode child (a language-server / formatter flush). Invoke-AgentRun tree-killed on
  timeout/cap but NOT on normal exit, so the child orphaned and flushed late. Each check kills a
  specific wrong implementation:
    T1-T7  Select-AgentProcessTreeTargets (PURE) reaps the leg's OWN tree only: ppid-chain descendants
           + worktree-scoped allowlisted children; never the root, a sibling dispatch, the live AO, a
           protected pid, or a non-allowlisted image matched only by cmdline.
    Q1     Wait-WorktreeQuiesced returns Settled on a quiet (committed) tree -> no false "did not settle".
    R1-R4  Restore-WorktreeToHead discards a post-commit stray (the trailing-newline shape) AND a new
           untracked file, restores content to HEAD, and is a no-op (empty) on an already-clean tree.
    S1-S3  the dotnet-console scaffold seeds a .gitignore covering bin/+obj/, and after a build +
           `git add -A` those artifacts are NOT staged (the digest surface no longer includes them).
    W1-W3  the wiring is REAL: Invoke-AgentRun reaps on exit; new-agent-task quiesces+discards before the
           review snapshot; the discard is guarded by -not $secretBlocked (never wipe a preserved secret).
#>
$ErrorActionPreference = 'Stop'
. "$PSScriptRoot\fleet-lib.ps1"

$script:Pass = 0; $script:Fail = 0
function _pass($m) { $script:Pass++; Write-Host "  [PASS] $m" -ForegroundColor Green }
function _fail($m) { $script:Fail++; Write-Host "  [FAIL] $m" -ForegroundColor Red }
function Assert($cond, $msg) { if ($cond) { _pass $msg } else { _fail $msg } }

$base = Join-Path ([System.IO.Path]::GetTempPath()) ("verify-quiesce-" + [guid]::NewGuid().ToString('N').Substring(0, 8))
New-Item -ItemType Directory -Force $base | Out-Null
function New-Repo($n) {
    $r = Join-Path $base $n
    New-Item -ItemType Directory -Force $r | Out-Null
    $ErrorActionPreference = 'Continue'
    git -C $r init -b main -q 2>$null
    git -C $r config user.email 't@t' 2>$null; git -C $r config user.name 't' 2>$null
    return $r
}

try {
    # ---- REAP SELECTOR (pure): the leg's OWN tree only ----
    Write-Host "== Select-AgentProcessTreeTargets (the reap decision) ==" -ForegroundColor Cyan
    $wd = 'C:\wt\leg-a'
    $snap = @(
        [pscustomobject]@{ ProcessId = 1000; ParentProcessId = 500;  Name = 'opencode.exe'; CommandLine = "opencode run --dir C:\wt\leg-a" }  # root
        [pscustomobject]@{ ProcessId = 1001; ParentProcessId = 1000; Name = 'node.exe';     CommandLine = "node lsp" }                          # child
        [pscustomobject]@{ ProcessId = 1002; ParentProcessId = 1001; Name = 'node.exe';     CommandLine = "node csharp-ls" }                    # grandchild
        [pscustomobject]@{ ProcessId = 1003; ParentProcessId = 1;    Name = 'node.exe';     CommandLine = "node srv C:\wt\leg-a\sub" }           # re-parented, cmdline names wt
        [pscustomobject]@{ ProcessId = 2000; ParentProcessId = 1;    Name = 'node.exe';     CommandLine = "node C:\wt\leg-b" }                   # SIBLING dispatch (other wt)
        [pscustomobject]@{ ProcessId = 3000; ParentProcessId = 1;    Name = 'python.exe';   CommandLine = "ovms serve 127.0.0.1:8000" }          # live AO/OVMS
        [pscustomobject]@{ ProcessId = 4000; ParentProcessId = 1;    Name = 'pwsh.exe';     CommandLine = "pwsh new-agent-task C:\wt\leg-a" }    # our own ps: names wt but not allowlisted
    )
    $t = @(Select-AgentProcessTreeTargets -Processes $snap -RootPid 1000 -WorkDir $wd)
    Assert (($t -contains 1001) -and ($t -contains 1002)) "T1 ppid-chain descendants (child + grandchild) are reaped"
    Assert (-not ($t -contains 1000))                     "T2 the root opencode pid is NEVER reaped"
    Assert ($t -contains 1003)                            "T3 a re-parented allowlisted child naming the worktree is reaped (coverage branch)"
    Assert (-not ($t -contains 2000))                     "T4 a SIBLING dispatch's child (different worktree) is NOT reaped"
    Assert (-not ($t -contains 3000))                     "T5 the live AO/OVMS (not a descendant, no worktree in cmdline) is NOT reaped"
    Assert (-not ($t -contains 4000))                     "T7 a non-allowlisted image matched only by cmdline is NOT reaped (image-gated coverage branch)"
    $tp = @(Select-AgentProcessTreeTargets -Processes $snap -RootPid 1000 -WorkDir $wd -Protect @(1001))
    Assert (-not ($tp -contains 1001))                    "T6 a -Protect pid is excluded even when it is a descendant"

    # ---- SETTLE barrier ----
    Write-Host "== Wait-WorktreeQuiesced (the settle barrier) ==" -ForegroundColor Cyan
    $rq = New-Repo rq
    [System.IO.File]::WriteAllText((Join-Path $rq 'a.cs'), "class A {}`n")
    $ErrorActionPreference = 'Continue'; git -C $rq add -A 2>$null; git -C $rq commit -q -m c 2>$null; $ErrorActionPreference = 'Stop'
    $q = Wait-WorktreeQuiesced -Repo $rq -QuietMs 150 -MaxWaitMs 3000
    Assert ($q.Settled)                                   "Q1 a quiet committed tree SETTLES (no false 'did not settle' on honest work)"

    # ---- DISCARD post-commit stray -> reviewed tree == committed candidate ----
    Write-Host "== Restore-WorktreeToHead (discard-and-log post-commit strays) ==" -ForegroundColor Cyan
    $rr = New-Repo rr
    $withNl = "namespace App;`npublic static class Calculator { }`n"
    [System.IO.File]::WriteAllText((Join-Path $rr 'Calculator.cs'), $withNl)
    $ErrorActionPreference = 'Continue'; git -C $rr add -A 2>$null; git -C $rr commit -q -m seed 2>$null; $ErrorActionPreference = 'Stop'
    # the incident shape: a straggler strips the trailing newline of a committed file, post-commit.
    [System.IO.File]::WriteAllText((Join-Path $rr 'Calculator.cs'), $withNl.TrimEnd("`n"))
    $strayed = @(Restore-WorktreeToHead -Repo $rr)
    Assert (($strayed -join "`n") -match 'Calculator\.cs')            "R1 a post-commit tracked stray (trailing-newline strip) is returned for logging"
    Assert ((((Get-Content (Join-Path $rr 'Calculator.cs') -Raw) -replace "`r", "") -eq ($withNl -replace "`r", ""))) "R4 the file CONTENT is restored to the committed HEAD version (trailing newline back)"
    Assert (-not (@(git -C $rr status --porcelain 2>$null | Where-Object { $_ })).Count) "R1b the tree is clean after the discard (== committed candidate)"
    # a NEW untracked file also flips the digest and is cleaned.
    [System.IO.File]::WriteAllText((Join-Path $rr 'Tests.cs'), "// stray")
    $strayed2 = @(Restore-WorktreeToHead -Repo $rr)
    Assert (($strayed2 -join "`n") -match 'Tests\.cs')               "R2 a new untracked stray file is returned and removed"
    Assert (-not (Test-Path (Join-Path $rr 'Tests.cs')))             "R2b the untracked stray is gone after the discard"
    $strayed3 = @(Restore-WorktreeToHead -Repo $rr)
    Assert ($strayed3.Count -eq 0)                                   "R3 an already-clean tree -> no-op (nothing discarded)"

    # ---- SCAFFOLD gitignore: bin/+obj/ never widen the digest ----
    Write-Host "== dotnet-console scaffold gitignores bin/+obj/ ==" -ForegroundColor Cyan
    $sc = New-Repo rsc
    $seeded = @(Copy-ScaffoldInto -Scaffold 'dotnet-console' -Worktree $sc)   # default ScaffoldRoot = <repo>\build-infra (matches production)
    Assert ($seeded -contains '.gitignore')                          "S1 the dotnet-console scaffold seeds a .gitignore"
    $gi = if (Test-Path (Join-Path $sc '.gitignore')) { Get-Content (Join-Path $sc '.gitignore') -Raw } else { '' }
    Assert (($gi -match '(?m)^\s*bin/\s*$') -and ($gi -match '(?m)^\s*obj/\s*$')) "S2 the .gitignore covers bin/ and obj/"
    # simulate the incident: seed -> commit -> build artifacts appear -> git add -A must NOT stage bin/obj.
    $ErrorActionPreference = 'Continue'
    git -C $sc add -A 2>$null; git -C $sc commit -q -m 'seed' 2>$null
    New-Item -ItemType Directory -Force (Join-Path $sc 'bin\Debug\net8.0') | Out-Null
    New-Item -ItemType Directory -Force (Join-Path $sc 'obj\Debug\net8.0') | Out-Null
    [System.IO.File]::WriteAllText((Join-Path $sc 'bin\Debug\net8.0\app.dll'), 'BINARY')
    [System.IO.File]::WriteAllText((Join-Path $sc 'obj\Debug\net8.0\app.pdb'), 'PDB')
    git -C $sc add -A 2>$null
    $ErrorActionPreference = 'Stop'
    $tracked = @(git -C $sc status --porcelain --untracked-files=all 2>$null | Where-Object { $_ -match '(^|/|\\)(bin|obj)(/|\\)' })
    Assert ($tracked.Count -eq 0)                                    "S3 after a build, bin/ and obj/ are gitignored -> NOT in the digest surface"

    # ---- WIRING: the fix is actually threaded into the live paths ----
    Write-Host "== wiring ==" -ForegroundColor Cyan
    $fl  = Get-Content "$PSScriptRoot\fleet-lib.ps1" -Raw
    $nat = Get-Content "$PSScriptRoot\new-agent-task.ps1" -Raw
    # W1: the reap is wired with the spawned process id + worktree ($p.Id exists ONLY inside Invoke-AgentRun),
    # and it sits on the post-run exit path (after $sw.Stop(), before the PYTHONPATH restore).
    Assert ([regex]::IsMatch($fl, 'Stop-AgentProcessTree -RootPid \$p\.Id -WorkDir \$WorkDir')) `
        "W1 Invoke-AgentRun REAPS the leg's tree with the spawned pid + worktree"
    Assert ([regex]::IsMatch($fl, '(?s)\$sw\.Stop\(\).*?Stop-AgentProcessTree.*?Remove-Item Env:\\PYTHONPATH')) `
        "W1b the reap runs on the post-run exit path (after `$sw.Stop(), before PYTHONPATH restore)"
    Assert ([regex]::IsMatch($nat, 'Wait-WorktreeQuiesced -Repo \$wt[\s\S]{0,900}?\$preReviewDigest = Get-WorktreeDigest')) `
        "W2 new-agent-task QUIESCES (settle) before the review pre-snapshot"
    Assert ([regex]::IsMatch($nat, 'if \(-not \$secretBlocked\)[\s\S]{0,200}?Restore-WorktreeToHead -Repo \$wt')) `
        "W3 the discard is GUARDED by -not `$secretBlocked (never wipe a preserved secret-blocked tree)"
}
finally {
    $ErrorActionPreference = 'Continue'
    Remove-Item $base -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Host ""
Write-Host ("  Passed: {0}   Failed: {1}" -f $script:Pass, $script:Fail) -ForegroundColor $(if ($script:Fail) { 'Red' } else { 'Green' })
if ($script:Fail) { exit 1 } else { Write-Host "  CODER-LEG-QUIESCE: VALIDATED." -ForegroundColor Green; exit 0 }
