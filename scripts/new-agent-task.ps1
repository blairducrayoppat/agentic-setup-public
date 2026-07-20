# Autonomous task pipeline: one task -> isolated worktree -> agent builds ->
# tests run -> review agent verdicts -> AUTO-MERGE on green, or a plain-language
# report when not. The human never touches git; their gate is trying the app.
# Usage:
#   .\new-agent-task.ps1 -Repo C:\Users\mrbla\projects\myapp -Task fix-logging -Prompt "Fix the logging; run tests."
# Optional: -Model local/coder-30b (default: whatever model is loaded)
param(
    [Parameter(Mandatory)][string]$Repo,
    [Parameter(Mandatory)][string]$Task,
    [Parameter(Mandatory)][string]$Prompt,
    [string]$Model = '',
    [string]$BaseBranch = 'main',
    [int]$MaxRunMinutes = 60,    # HARD CEILING (#682): generous absolute backstop. A coder that
                                 # keeps making progress runs until here instead of being killed at
                                 # a short fixed deadline ("killing it too soon"). The fast kill is
                                 # the idle timeout below, so this can be generous without bleeding.
    [int]$MaxReviewMinutes = 10,
    [int]$IdleTimeoutSec = 240,  # progress-aware idle kill (#682): no new step_finish AND no new
                                 # edit for this long = genuinely stuck -> killed FAST. A PROGRESSING
                                 # coder is never stopped by this (each step/edit resets the clock).
    [int]$MaxBuildAttempts = 3,
    [int]$MaxVerifyAttempts = 3,
    [string]$Complexity = '',  # upstream COARSE label (simple|moderate|complex). The 14B is NOT a coder ->
                               # a SIGNAL, not a pass count; it SCALES the budgets. Absent -> defaults kept.
    [string]$Surface = '',     # INCREMENT-1 (#675) the 14B's coarse platform label (desktop-gui|web|mobile|
                               # command-line|automation|library|unknown). When set+KNOWN it drives the
                               # curated build profile (scaffold + structural contract); 'unknown'/absent
                               # -> today's keyword heuristic, strictly additive.
    [string]$LanguageHint = '', # INCREMENT-1 (#675) optional language refinement (python|dotnet|node|cpp|
                               # powershell) for the ambiguous surfaces (command-line, library).
    # ---- #690 SHARED ACCEPTANCE ORACLE (best-of-N's spec-derived scorecard) ----
    [string]$AcceptanceTestCode = '',  # the 14B-written, spec-blind pytest ORACLE (python single-feature, from
                               # acceptance.py generate_acceptance_oracle). When set it is SEEDED into the worktree
                               # as a PROTECTED test file committed into the coder's baseline ($codeBase), so EVERY
                               # best-of-N candidate inherits + codes against + is judged by the byte-identical
                               # scorecard, and it is RESTORED before each gate (a candidate edit/delete cannot help).
                               # Absent -> today's behavior (the coder writes its own folded tests).
    [string]$AcceptanceTestPath = '',  # repo-relative path the oracle is seeded + protected at (e.g.
                               # tests/test_acceptance.py). Paired with -AcceptanceTestCode; either alone is a no-op.
    # ---- UC-010 VLM design-loop critique (Phase 3) — DORMANT post-merge enhancement ----
    [string]$Goal = '',        # plain-English product goal (the queue task's $t.goal). Used only by the
                               # post-merge VLM critique; absent -> falls back to $OrigPrompt for the goal text.
    [string]$VisualCriteriaJson = '',  # JSON array string of visual-tier criterion texts (the queue task's
                               # $t.visual_criteria_json). The critique hook fires ONLY when this is present
                               # and not empty/'[]'/whitespace. Common (non-visual) task -> hook is a no-op.
    [switch]$EnableVisualCritique,     # OPT-IN master gate (default OFF). Even a visual task does NOTHING
                               # until the operator passes -EnableVisualCritique at go-live. Belt-and-braces
                               # with the criteria gate so the loop is double-dormant by default.
    [string]$BlarAiRepo = $(if ($env:BLARAI_REPO) { $env:BLARAI_REPO } else { 'C:\Users\mrbla\blarai' }),
                               # BlarAI repo root where `python -m shared.fleet.critique` runs (the VLM CLI).
                               # Env override BLARAI_REPO, else the canonical default — mirrors start-llm.ps1's
                               # candidate-path-with-default convention (no config-file convention in this repo).
    # ---- #695 BEST-OF-N CONCURRENCY ----
    [int]$Concurrency = 0,     # 0 = RESOLVE from BLARAI_DISPATCH_CONCURRENCY then the built-in production
                               # default (Resolve-DispatchConcurrency, below). C=1 is EXACTLY today's
                               # sequential best-of-N; C>1 runs up to C candidates CONCURRENTLY, each in its
                               # own worktree off $codeBase via Start-Job (OVMS continuous batching, #695). An
                               # explicit value (run-fleet -Concurrency / a queue task's .concurrency) wins.
    # ---- #790 sub-task 5: ONE canonical package, named by the job-oracle contract ----
    [string]$CanonicalPackage = ''  # the ONE top-level python package the plan-graph job's acceptance
                               # oracle imports (a queue task's .canonical_package, derived upstream by
                               # blarai context_pack.canonical_package_from_contract). When set, the
                               # python skeleton seeds its package UNDER THIS NAME so the coder extends
                               # the oracle's layout -- the generic 'app/' seed beside the oracle's real
                               # package grew B4's duplicate tree (both app/ AND flashcard_app/; the
                               # stale app/core.py placeholder + tests/test_core.py rode along). Absent/
                               # invalid -> the byte-identical legacy generic seed (a miss is safe).
)
# git writes normal progress (e.g. "Preparing worktree") to stderr; under Windows
# PowerShell 5.1 with EAP=Stop that becomes a FATAL NativeCommandError. Use Continue
# and rely on the explicit $LASTEXITCODE checks and throws below for real failures.
$ErrorActionPreference = 'Continue'
. "$PSScriptRoot\fleet-lib.ps1"

# #695: resolve the effective best-of-N concurrency C (explicit -Concurrency > BLARAI_DISPATCH_CONCURRENCY
# env channel > built-in production default). C=1 is today's sequential path; C>1 runs candidates concurrently.
# #714 RAM-headroom guard: measure the live free RAM (the 30B is resident by now) so a memory-tight
# box auto-drops to a concurrency its RAM can actually feed -- prevents the F2 starve-stall without
# any env var or human. A measurement failure (AvailableGiB=0) safely means "no guard".
$__freeGiB = try { [math]::Round((Get-CimInstance Win32_OperatingSystem -ErrorAction Stop).FreePhysicalMemory / 1MB, 1) } catch { 0 }
$__reqC = Resolve-DispatchConcurrency -Explicit $Concurrency -EnvValue $env:BLARAI_DISPATCH_CONCURRENCY
$Concurrency = Resolve-DispatchConcurrency -Explicit $Concurrency -EnvValue $env:BLARAI_DISPATCH_CONCURRENCY -AvailableGiB $__freeGiB
if ($Concurrency -lt $__reqC) { Write-Host "  Concurrency capped $__reqC -> $Concurrency by the RAM-headroom guard ($__freeGiB GiB free; #714 -- prevents the tight-box best-of-N stall)." -ForegroundColor Yellow }

# HEADLESS-BUILD GUARD (2026-06-25): mark this a headless build so the seeded WinUI app's App.xaml.cs
# refuses a no-args GUI launch. Without this the coder's `dotnet run` launches App.exe, which HANGS
# (a WinUI window never exits) and can pop a ".NET" runtime dialog at the operator -- a major cause of
# build timeouts (the blind coder burns its budget hanging on a window it cannot even see). --test,
# --render-to-file (the VLM capture), and the real operator launch are all unaffected. Inherited by the
# coder process tree (opencode -> dotnet run -> App.exe).
$env:BLARAI_HEADLESS_BUILD = '1'

if (-not (Test-Path (Join-Path $Repo '.git'))) { throw "$Repo is not a git repository." }
foreach ($forbidden in @("$env:USERPROFILE\BlarAI", "$env:USERPROFILE\.openclaw")) {
    if ($Repo.TrimEnd('\') -like "$forbidden*") { throw "Refusing: agents must not run in $forbidden." }
}
$Task = $Task -replace '[^\w\-]', '-'
if (-not $Task) { throw "Task name became empty after sanitizing." }

# Resolve the model: default to whatever is actually loaded
try {
    $resp = Invoke-WebRequest 'http://127.0.0.1:8000/v3/models' -TimeoutSec 3 -UseBasicParsing -ErrorAction Stop
    $ids = @((($resp.Content | ConvertFrom-Json).data) | ForEach-Object { $_.id })
} catch { throw "Model server not running - start it first (a model launcher on the Desktop)." }
if (-not $Model) {
    if ($ids.Count -eq 0) { throw "The model server is up but no model is loaded. Start one first (a model launcher)." }
    $Model = "local/$($ids[0])"
}
$wantId = ($Model -split '/')[-1]
if ($ids -notcontains $wantId) { throw "Requested $Model but server has '$($ids -join ',')' loaded." }

# Make the repo worktree-able: commit any baseline state (handles brand-new
# repos with no commits yet, and uncommitted work from interactive sessions)
$dirty = @(git -C $Repo status --porcelain 2>$null)
$hasHead = $true; git -C $Repo rev-parse HEAD 2>&1 | Out-Null; if ($LASTEXITCODE -ne 0) { $hasHead = $false }
if ($dirty -or -not $hasHead) {
    git -C $Repo add -A 2>&1 | Out-Null
    git -C $Repo -c user.email='agent@local' -c user.name='coding-agent' commit -m "baseline before task: $Task" 2>&1 | Out-Null
    Write-Host "Saved a baseline snapshot of the project first." -ForegroundColor Cyan
}
git -C $Repo rev-parse --verify $BaseBranch 2>&1 | Out-Null
if ($LASTEXITCODE -ne 0) { $BaseBranch = (git -C $Repo branch --show-current).Trim() }

$repoName = Split-Path $Repo -Leaf
# #714: build worktrees in the hidden fleet-owned base (state/worktrees), NOT beside the project, so a
# "New Project" only ever shows the ONE folder the operator named -- even a KILLED run (which never reaches
# the cleanup below) leaks its "-cK" candidate copies here, invisibly, instead of littering projects/. The
# candidate worktrees derive from $wt ("$wt-cK") so they inherit the location; the merge, the reap, and the
# report all use absolute paths + branch names, so they are location-independent. (Resolve-WorktreeBase is
# unit-tested in verify-worktree-location.ps1.)
# #775 ACP-01 (D-B): the worktree base relocates to the shared dual-SID tree ONLY when the containment flag
# in configs/fleet-driver.json is 'restricted_account'; with the default 'off' this is byte-identical to the
# historical call (the flag-dormant guarantee -- tonight's battery uses the exact current state\worktrees).
$wtBase = Resolve-WorktreeBase -ScriptRoot $PSScriptRoot -Containment (Get-FleetDriverConfig -ScriptRoot $PSScriptRoot).containment
New-Item -ItemType Directory -Force $wtBase | Out-Null
$wt = Join-Path $wtBase "$repoName-$Task"
$branch = "agent/$Task"
$ReportDir = 'C:\Users\mrbla\agentic-setup\state\reports'
New-Item -ItemType Directory -Force $ReportDir | Out-Null
$Report = Join-Path $ReportDir "$repoName-$Task-$(Get-Date -Format 'yyyyMMdd-HHmmss').txt"

# Idempotent: clear any worktree/branch left by a PRIOR run of THIS exact task so
# re-runs do not collide. (Parked work from OTHER task names is untouched.)
if (Test-Path $wt) { git -C $Repo worktree remove $wt --force 2>&1 | Out-Null }
# #695: also reap stale CONCURRENT-candidate worktrees/branches ("<repo>-<task>-cK") left by a CRASHED prior
# run of THIS exact task, so a re-run starts clean. (Parked work from OTHER task names is untouched.)
foreach ($__stale in @(git -C $Repo worktree list --porcelain 2>$null | Where-Object { $_ -like 'worktree *' } | ForEach-Object { ($_ -replace '^worktree\s+', '').Trim() })) {
    if ((Split-Path $__stale -Leaf) -like "$repoName-$Task-c*") { git -C $Repo worktree remove $__stale --force 2>&1 | Out-Null }
}
git -C $Repo worktree prune 2>&1 | Out-Null
git -C $Repo branch -D $branch 2>&1 | Out-Null
foreach ($__br in @(git -C $Repo branch --list "agent/$Task-c*" 2>$null | ForEach-Object { ($_ -replace '^[\*\+]?\s*', '').Trim() })) {
    if ($__br) { git -C $Repo branch -D $__br 2>&1 | Out-Null }
}
git -C $Repo worktree add $wt -b $branch 2>&1 | Out-Null
if ($LASTEXITCODE -ne 0) { throw "Could not create the isolated workspace at $wt (branch '$branch')." }
# C1 SCAFFOLD SEEDING (#670): seed a known-good skeleton into a FRESH target so the coder EXTENDS a
# compiling project instead of hand-authoring boilerplate (where a small model trips on e.g. the
# WinUI `using Microsoft.UI.Xaml;` -> CS0246). Only when the worktree has NO project yet (never
# clobbers a real one). Committed as the coder's BASELINE ($codeBase) and seeded BEFORE the ecosystem
# detection below so a seeded .csproj also drives the language pin. A miss is safe -- error-feedback backstops.
$hasProj = @(Get-ChildItem -Path $wt -Recurse -File -Include *.csproj,*.sln,pyproject.toml,package.json,CMakeLists.txt,*.vcxproj -ErrorAction SilentlyContinue).Count -gt 0
# INCREMENT-1 (#675): when the 14B classified a KNOWN surface, the curated profile decides the scaffold
# (and carries the structural contract the fail-fast gate enforces in [3/5]); 'unknown'/absent falls
# through to today's keyword heuristic UNCHANGED. Resolve-TaskScaffold itself prefers-then-falls-back, so
# the seeded scaffold is correct either way; we resolve the profile SEPARATELY here only to obtain the
# $structContract for the verify gate below (a $null contract = a proven no-op there).
$buildProfile = if ($Surface) { Resolve-BuildProfile -Surface $Surface -LanguageHint $LanguageHint } else { @{ scaffold = ''; structural_contract = $null; staged = $false } }
$structContract = $buildProfile.structural_contract
$scaffold = Resolve-TaskScaffold -Prompt $Prompt -HasProject $hasProj -Surface $Surface -LanguageHint $LanguageHint
if ($Surface) { Write-Host "  Build surface (upstream signal): $Surface$(if ($LanguageHint) { " / $LanguageHint" }) -> profile scaffold '$($buildProfile.scaffold)'$(if ($null -ne $structContract) { ' + structural contract' })" -ForegroundColor DarkCyan }
if ($scaffold) {
    # #790 sub-task 5: the python skeleton's package seeds under the job-oracle contract's canonical
    # name (Copy-ScaffoldInto validates + falls back to the legacy generic seed on any miss), so the
    # coder extends the ONE tree the oracle grades -- never the generic app/ twin beside it (B4).
    $seeded = @(Copy-ScaffoldInto -Scaffold $scaffold -Worktree $wt -PackageName $CanonicalPackage)
    if ($seeded.Count) {
        git -C $wt add -A 2>&1 | Out-Null
        git -C $wt -c user.email='agent@local' -c user.name='coding-agent' commit -m "seed: $scaffold skeleton (coder extends this)" 2>&1 | Out-Null
        $pkgNote = if ($CanonicalPackage -and ($seeded -match '^' + [regex]::Escape($CanonicalPackage) + '[\\/]')) { " package '$CanonicalPackage' (oracle-contract canonical)" } else { '' }
        Write-Host "  Seeded a known-good '$scaffold' skeleton ($($seeded.Count) files)$pkgNote; the coder EXTENDS it." -ForegroundColor DarkGray
    }
}
# #690 ACCEPTANCE-ORACLE SEEDING: when the PLAN step generated a shared, spec-derived oracle (python
# single-feature), seed it as a PROTECTED test file and commit it into the coder's BASELINE ($codeBase
# below). Every best-of-N candidate then inherits the byte-identical scorecard on its fresh reset, codes
# against it (the prompt already says to), and is judged by it -- so the gate compares candidates fairly
# instead of each grading its own self-written tests. A candidate that edits/deletes it is overwritten by
# the RESTORE in $BuildTestVerify before the gate. Absent oracle (every non-python/multi-feature task) ->
# this is a no-op and the baseline is exactly today's (skeleton-or-base) commit.
$oracleActive = $false
if ($AcceptanceTestCode -and $AcceptanceTestPath) {
    $oraclePath = Join-Path $wt $AcceptanceTestPath
    $oracleDir = Split-Path $oraclePath -Parent
    if ($oracleDir -and -not (Test-Path $oracleDir)) { New-Item -ItemType Directory -Force $oracleDir | Out-Null }
    # BOM-free UTF-8 + a single trailing newline (POSIX text convention; matches what the gate restore
    # re-materialises). [IO.File]::WriteAllText is deterministic across PS 5.1 and pwsh 7 (Set-Content
    # -Encoding utf8 adds a BOM under 5.1).
    [System.IO.File]::WriteAllText($oraclePath, ($AcceptanceTestCode.TrimEnd("`r", "`n") + "`n"), (New-Object System.Text.UTF8Encoding $false))
    git -C $wt add -A 2>&1 | Out-Null
    git -C $wt -c user.email='agent@local' -c user.name='coding-agent' commit -m "seed: acceptance oracle (protected; the coder codes against this)" 2>&1 | Out-Null
    $oracleActive = $true
    Write-Host "  Seeded the shared acceptance oracle -> $AcceptanceTestPath (protected; restored before each gate)." -ForegroundColor DarkGray
}
# The coder's BASELINE = the worktree HEAD now (the seed commit if seeded, else the base commit). The
# no-op check, $hasChanges, and a fresh resample all measure against THIS -- so a seeded skeleton is the
# floor (a no-op coder shows zero work and never merges a bare skeleton; a resample resets to the skeleton).
$codeBase = (git -C $wt rev-parse HEAD 2>$null)
$codeBase = if ($codeBase) { "$codeBase".Trim() } else { $BaseBranch }
# A1 (#670): pin the TARGET LANGUAGE so the coder cannot default to a foreign language (the live
# failure wrote JavaScript into a Python repo). Derive it from the project's DECLARED ecosystem
# (Get-ProjectEcosystem reads the just-branched worktree's manifests = the project's identity) and
# PREPEND a hard constraint. Empty/unknown ecosystem -> no constraint = current behavior. We reassign
# $Prompt IN PLACE (keeping $OrigPrompt for the human-facing report) so the -RunAgent closure below -
# which references $Prompt by name and resolves it late - picks up the pinned text without editing
# that line. Computed ONCE here, above the resample loop, so a reset-to-base resample keeps the pin.
$OrigPrompt = $Prompt
$ecoSet = Get-ProjectEcosystem $wt
$langConstraint = Get-LanguageConstraint -Ecosystems $ecoSet
if ($langConstraint) {
    $Prompt = $langConstraint + "`n`n" + $Prompt
    Write-Host "  Language pin -> $($ecoSet -join ', ') (coder constrained to the project's language)." -ForegroundColor DarkGray
}
# BEST-OF-N (#689, epic #688): instead of a serial loop that asks the weak local model to SELF-CORRECT
# its own failing build (its worst skill -- it enters error traps and stays stuck), generate up to N
# INDEPENDENT, diverse candidates from the seeded baseline and let the DETERMINISTIC gate pick the winner
# (the first that would merge), or the best partial if none win. Generation COVERAGE -- not review
# precision -- is the weak-model bottleneck; N fresh samples route around self-correction (a weaker open
# model went 15.9% -> 56% on SWE-bench Lite from repeated sampling -- arXiv 2407.21787). N reuses the
# existing complexity-scaled build budget ($MaxVerifyAttempts: simple 2 / moderate 3 / complex 5, staged
# floor 5). Two execution paths select on the resolved concurrency C (computed above): C=1 runs the
# SEQUENTIAL best-of-N with early-exit (an easy task = candidate 1 green = ONE build, byte-identical to
# the original #689 path); C>1 runs Invoke-BestOfNBatched (#695, SHIPPED -- the concurrent path is the
# production default, ~line 278 below) which builds candidates CONCURRENTLY in batches of C, each in its
# own worktree off $codeBase, all hitting the shared OVMS server so continuous batching overlaps them.
# POLICY is the unit-tested Invoke-BestOfN / Invoke-BestOfNBatched / Test-IsCandidateGreen /
# Get-CandidateRank (fleet-lib.ps1; see verify-bestofn.ps1 + verify-bestofn-concurrent.ps1); the real
# MECHANISM is injected below.
$everFixFirst = $false
$reviewPass = 0
$MaxReviewPasses = 2   # default review budget (scaled below if an upstream complexity signal is present)
$__budget = Resolve-PassBudget -Complexity $Complexity -DefaultBuild $MaxVerifyAttempts -DefaultReview $MaxReviewPasses -Staged ([bool]$buildProfile.staged)
$MaxVerifyAttempts = $__budget.Build   # = N, the best-of-N candidate budget
$MaxReviewPasses   = $__budget.Review
$Prompt = Add-ComplexityHint -Prompt $Prompt -Complexity $Complexity
if ($Complexity) { Write-Host "  Task complexity (upstream signal): $Complexity -> up to $MaxVerifyAttempts candidate(s), review budget $MaxReviewPasses" -ForegroundColor DarkCyan }
# INCREMENT-3 STAGED PROMPT (#676): a STAGED surface (winui/desktop-gui) gets the core-then-shell staging
# instruction so the coder EXTENDS the offline-building tests instead of inventing a framework. Gated on
# $buildProfile.staged -> non-staged surfaces are byte-identical. Computed ONCE here (every candidate
# inherits it via $Prompt). The original prompt is preserved verbatim (Add-StagedHint appends).
$Prompt = Add-StagedHint -Prompt $Prompt -Staged ([bool]$buildProfile.staged)
if ($buildProfile.staged) { Write-Host "  Staged build (core first, then shell): the coder extends the seeded Calculator core + Tests/ before theming the shell." -ForegroundColor DarkCyan }
# F3 (#670): the OFFLINE-WEB hint for a `web` scaffold -- the coder EXTENDS the seeded offline Node
# skeleton and stays offline (inline SVG/data: URIs, port-0 tests) instead of pulling a CDN image and
# fetching an unstarted port (the live failure). Gated on the RESOLVED scaffold (set by surface OR the
# keyword heuristic), so it fires whenever the web seed is placed and non-web tasks are byte-identical;
# mutates $Prompt above the resample loop like the other hints (survives a reset-to-base resample).
$Prompt = Add-WebHint -Prompt $Prompt -Web ([bool]($scaffold -eq 'web'))
if ($scaffold -eq 'web') { Write-Host "  Offline web build: the coder extends the seeded offline Node skeleton (no external assets; port-0 tests)." -ForegroundColor DarkCyan }
# #886: the STATIC-PAGE hint for a `web-static` scaffold -- the coder EXTENDS the single seeded
# self-contained index.html and stays static + offline (inline SVG/data: URIs, NO server, NO fetch,
# NO package.json) instead of adding a node server that leaves a "Loading..." box hung on file://.
# Gated on the RESOLVED scaffold (set by the surface -> profile mapping); non-static tasks are byte-
# identical; mutates $Prompt above the resample loop like the other hints (survives a reset-to-base).
$Prompt = Add-WebStaticHint -Prompt $Prompt -WebStatic ([bool]($scaffold -eq 'web-static'))
if ($scaffold -eq 'web-static') { Write-Host "  Static web page: the coder extends the ONE self-contained index.html (no server, no build step, no fetch)." -ForegroundColor DarkCyan }
# W4 (#714, UC-010 SEAM A): if BlarAI pre-generated raster image assets into the seeded worktree
# (its on-device image generator, before the coder ran), tell the coder to USE the local files
# (offline, relative path) instead of drawing an <svg> placeholder. DYNAMIC + gated on ACTUAL FILE
# PRESENCE in $wt (the baseline-holder worktree, created above; $wtOrig is not assigned until later,
# so $wt is valid here) -- a real pre-existing project resolves to an EMPTY scaffold, so a file-
# presence gate is the correct trigger, NOT $scaffold. No assets -> a no-op (inline-SVG fallback
# stands). Computed ONCE (every candidate inherits it via $Prompt); preserves the prompt verbatim.
$__assetPromptBefore = $Prompt
$Prompt = Add-AssetHint -Prompt $Prompt -Worktree $wt -Surface $Surface
if ($Prompt -ne $__assetPromptBefore) { Write-Host "  Generated image assets present: the coder is told to reference the local file(s) offline (no <svg> placeholder, no CDN)." -ForegroundColor DarkCyan }

# ONE attempt = (optional reset-to-base) -> build (inner no-op retry) -> oracle-restore -> secret-scan ->
# commit -> [2/5] tests -> [3/5] verify. #700 UNIFIED this into fleet-lib's Invoke-CandidateBuild -- the SINGLE
# per-candidate pipeline both the sequential best-of-N (below, -ResetToBase ($k -gt 1)) and the concurrent
# Start-Job candidates call. Previously this was a duplicated $BuildTestVerify closure here; folding it into
# the one function removes the drift hazard (the two gate bodies could silently diverge). $BTV is the thin
# adapter the sequential RunCandidate + the review-FIX loop call, so those call sites stay one-liners; it
# returns Invoke-CandidateBuild's result verbatim (which carries a `LogPath` alias for those callers).
$BuildTestVerify = {
    param([string]$attemptPrompt, [string]$logPath, [bool]$resetToBase)
    Invoke-CandidateBuild -ScriptRoot $PSScriptRoot -Worktree $wt -Model $Model -CodeBase $codeBase `
        -AttemptPrompt $attemptPrompt -LogPath $logPath -Task $Task -BaseBranch $BaseBranch `
        -MaxBuildAttempts $MaxBuildAttempts -MaxRunMinutes $MaxRunMinutes -IdleTimeoutSec $IdleTimeoutSec `
        -OracleActive $oracleActive -AcceptanceTestPath $AcceptanceTestPath -Surface $Surface `
        -LanguageHint $LanguageHint -ResetToBase $resetToBase `
        -ShouldCancel { Test-DispatchCancelled }   # #771: honour a `/dispatch stop` between this candidate's gate steps
}

# ---- BEST-OF-N BUILD: up to N independent diverse candidates; the gate selects the winner ----
# #695: C=1 -> the SEQUENTIAL path (byte-identical to #689). C>1 -> the CONCURRENT path: candidates run in
# batches of C, EACH in its OWN worktree off $codeBase via Start-Job (process isolation -> no env race),
# all hitting the shared OVMS server -> continuous batching. Both feed the SAME gate + selection + merge below.
$ScriptDir = $PSScriptRoot            # captured for the Start-Job children (robust across the fleet-lib indirection)
$bon = $null
$wtOrig = $wt; $brOrig = $branch      # the baseline-holder worktree/branch; in concurrent mode the SELECTED
                                      # candidate's own worktree is promoted to $wt/$branch and this is reaped.
$usedConcurrent = $false
$concurrencyNote = ''                 # a non-blocking note surfaced into the report (e.g. a discarded co-batch secret)
if ($Concurrency -gt 1) {
    try {
        $bon = Invoke-BestOfNBatched -MaxCandidates $MaxVerifyAttempts -Concurrency $Concurrency `
            -ShouldCancel { Test-DispatchCancelled } `
            -OnBatch { param($idxs, $n) Write-Host "[1/5] Building $($idxs.Count) candidate(s) CONCURRENTLY ($($idxs -join ', ') of $n) in isolated worktrees ($Model, max $MaxRunMinutes min each)..." -ForegroundColor Cyan } `
            -IsWinner { param($c) Test-IsCandidateGreen -VerifyResult $c.VerifyResult -TestResult $c.TestResult -HasChanges $c.HasChanges -TimedOut $c.TimedOut -SecretBlocked $c.SecretBlocked } `
            -StopSampling { param($c) Test-IsSamplingTerminal -SecretBlocked $c.SecretBlocked -TimedOut $c.TimedOut -TimeoutReason "$($c.Run.TimeoutReason)" } `
            -ScoreCandidate { param($c) Get-CandidateRank -VerifyResult $c.VerifyResult -TestResult $c.TestResult -HasChanges $c.HasChanges -TimedOut $c.TimedOut -SecretBlocked $c.SecretBlocked -LoopSuspected $c.LoopSuspected } `
            -RunBatch {
                param($idxs, $n)
                # 1) Create this batch's candidate worktrees SEQUENTIALLY (fast; avoids any git ref race),
                #    each off the shared $codeBase on its own branch (inherits the scaffold + #690 oracle).
                $meta = @{}
                foreach ($k in $idxs) {
                    $wt_k = "$wtOrig-c$k"; $br_k = "agent/$Task-c$k"
                    if (Test-Path $wt_k) { git -C $Repo worktree remove $wt_k --force 2>&1 | Out-Null }
                    git -C $Repo branch -D $br_k 2>&1 | Out-Null
                    git -C $Repo worktree add $wt_k -b $br_k $codeBase 2>&1 | Out-Null
                    $meta[$k] = @{ wt = $wt_k; branch = $br_k; prompt = (Add-CandidateDiversity -Prompt $Prompt -Index $k -Total $n); log = ($Report -replace '\.txt$', ".c$k.agent.log") }
                }
                # 2) Launch C concurrent Start-Job CHILD PROCESSES (separate processes -> isolated
                #    $env:PYTHONPATH; each candidate hits the shared OVMS server -> continuous batching).
                $jobs = @()
                foreach ($k in $idxs) {
                    $m = $meta[$k]
                    $job = Start-Job -ScriptBlock {
                        param($sr, $w, $mdl, $cb, $ap, $lp, $tk, $bb, $mba, $mrm, $idle, $oa, $atp, $sf, $lh)
                        . "$sr\fleet-lib.ps1"
                        # #771: the Start-Job child reads the SAME on-disk cancel sentinel (Test-DispatchCancelled
                        # anchors on fleet-lib's dir == $sr), so a concurrent candidate honours a stop between its
                        # own gate steps too -- not only the parent's between-batch check.
                        Invoke-CandidateBuild -ScriptRoot $sr -Worktree $w -Model $mdl -CodeBase $cb -AttemptPrompt $ap -LogPath $lp -Task $tk -BaseBranch $bb -MaxBuildAttempts $mba -MaxRunMinutes $mrm -IdleTimeoutSec $idle -OracleActive $oa -AcceptanceTestPath $atp -Surface $sf -LanguageHint $lh -ShouldCancel { Test-DispatchCancelled }
                    } -ArgumentList $ScriptDir, $m.wt, $Model, $codeBase, $m.prompt, $m.log, $Task, $BaseBranch, $MaxBuildAttempts, $MaxRunMinutes, $IdleTimeoutSec, $oracleActive, $AcceptanceTestPath, $Surface, $LanguageHint
                    $jobs += @{ k = $k; job = $job }
                }
                $null = ($jobs | ForEach-Object { $_.job }) | Wait-Job
                # 3) Collect each candidate's result IN INDEX ORDER, re-normalising the deserialised job
                #    output (CliXml) back into a clean hashtable tagged with its Worktree/Branch/Index.
                $results = @()
                foreach ($k in $idxs) {
                    $m = $meta[$k]
                    $entry = $jobs | Where-Object { $_.k -eq $k } | Select-Object -First 1
                    $out = @()
                    try { $out = @(Receive-Job $entry.job -ErrorAction Stop 6>$null) } catch { Write-Host "  candidate c$k job error: $($_.Exception.Message)" -ForegroundColor Yellow }
                    try { Remove-Job $entry.job -Force 2>&1 | Out-Null } catch {}
                    $raw = if ($out.Count) { $out[-1] } else { $null }
                    $cand = ConvertTo-CandidateResult -Raw $raw -Index $k -Worktree $m.wt -Branch $m.branch
                    $results += $cand
                    Write-Host ("  candidate c{0}: verify={1} test={2} changes={3}{4}{5}" -f $k, $cand.VerifyResult, $cand.TestResult, $cand.HasChanges, $(if ($cand.SecretBlocked) { ' SECRET' }), $(if ($cand.TimedOut) { ' TIMEOUT' })) -ForegroundColor DarkGray
                }
                return $results
            }
        $usedConcurrent = $true
    } catch {
        Write-Host "  Concurrent best-of-N path errored ($($_.Exception.Message)); falling back to sequential best-of-N." -ForegroundColor Yellow
        # reap any candidate worktrees this run created, restore the baseline holder as the working tree.
        foreach ($k in 1..$MaxVerifyAttempts) {
            $wt_k = "$wtOrig-c$k"
            if (Test-Path $wt_k) { git -C $Repo worktree remove $wt_k --force 2>&1 | Out-Null }
            git -C $Repo branch -D "agent/$Task-c$k" 2>&1 | Out-Null
        }
        git -C $Repo worktree prune 2>&1 | Out-Null
        $wt = $wtOrig; $branch = $brOrig; $bon = $null; $usedConcurrent = $false
    }
}
if ($null -eq $bon) {
    # ---- SEQUENTIAL best-of-N (C=1, or the concurrent fallback): today's EXACT path (#689), byte-identical ----
    $bon = Invoke-BestOfN -MaxCandidates $MaxVerifyAttempts `
        -ShouldCancel { Test-DispatchCancelled } `
        -OnCandidate { param($k, $n) if ($k -gt 1) { Write-Host "  Candidate $($k - 1) did not pass the gate; trying a FRESH independent candidate ($k/$n)..." -ForegroundColor Yellow } } `
        -IsWinner { param($c) Test-IsCandidateGreen -VerifyResult $c.VerifyResult -TestResult $c.TestResult -HasChanges $c.HasChanges -TimedOut $c.TimedOut -SecretBlocked $c.SecretBlocked } `
        -StopSampling { param($c) Test-IsSamplingTerminal -SecretBlocked $c.SecretBlocked -TimedOut $c.TimedOut -TimeoutReason "$($c.Run.TimeoutReason)" } `
        -ScoreCandidate { param($c) Get-CandidateRank -VerifyResult $c.VerifyResult -TestResult $c.TestResult -HasChanges $c.HasChanges -TimedOut $c.TimedOut -SecretBlocked $c.SecretBlocked -LoopSuspected $c.LoopSuspected } `
        -RunCandidate {
            param($k, $n)
            $candPrompt = Add-CandidateDiversity -Prompt $Prompt -Index $k -Total $n
            $log = $Report -replace '\.txt$', ".c$k.agent.log"
            Write-Host "[1/5] Building candidate $k of $n in isolated workspace ($Model, max $MaxRunMinutes min)..." -ForegroundColor Cyan
            $btv = & $BuildTestVerify $candPrompt $log ($k -gt 1)
            @{
                Index = $k; VerifyResult = $btv.VerifyResult; TestResult = $btv.TestResult; HasChanges = [bool]$btv.HasChanges;
                TimedOut = [bool]$btv.Run.TimedOut; SecretBlocked = [bool]$btv.SecretBlocked; LoopSuspected = [bool]$btv.Anomaly.LoopSuspected;
                SHA = $btv.SHA; Run = $btv.Run; Secret = $btv.Secret; Anomaly = $btv.Anomaly; BuildAttempts = $btv.BuildAttempts;
                TestError = $btv.TestError; VerifyDetail = $btv.VerifyDetail; VerifyError = $btv.VerifyError; AgentLog = $btv.LogPath
            }
        }
}

# ---- SELECT (the gate, never a model) + restore the winner / best partial onto the worktree ----
$sel = $bon.Selected
# #771 STOP-CONTRACT: best-of-N observed a `/dispatch stop` between candidates -> proceed PROMPTLY to this
# task's finish so the swap driver reaches its normal teardown (stop OVMS -> restore 14B -> terminal stamp) at
# the next task boundary, instead of the run-budget watchdog tearing down an hour later. A cancelled run has NO
# green winner (best-of-N breaks on the first green BEFORE any cancel), so its selection is at best a parked
# partial: skip the review-FIX loop (more agent runs) and never auto-merge a gate we cut short.
$dispatchCancelled = [bool]$bon.Cancelled
if ($dispatchCancelled) { Write-Host "  STOP: dispatch cancel observed; parking after the current candidate and proceeding to teardown (no fresh candidates, no review-fix churn) (#771)." -ForegroundColor Yellow }
# Security posture preserved (#689): a SECRET-blocked candidate is SURFACED + parked, NEVER sampled-away.
# Scan ALL candidates for a secret (sequential: it is the last candidate that stopped the loop; concurrent: it
# can be anywhere in the stopping batch). If the run STOPPED on a secret, keep that candidate's worktree state.
$secretStop = $false
if ($bon.Stopped -and $bon.Count -gt 0) {
    $__sc = @($bon.Candidates | Where-Object { $_.SecretBlocked }) | Select-Object -First 1
    if ($__sc) { $sel = $__sc; $secretStop = $true }
}
# #695: in the CONCURRENT path, each candidate built in its OWN worktree -> promote the SELECTED candidate's
# worktree to be the working tree ($wt/$branch the review loop + merge + cleanup operate on), then reap every
# non-selected candidate worktree + the baseline holder. (Sequential keeps the single $wt; this is skipped.)
if ($usedConcurrent -and $sel -and $sel.Worktree) {
    $wt = $sel.Worktree; $branch = $sel.Branch
    if ($bon.WinnerFound -and (@($bon.Candidates | Where-Object { $_.SecretBlocked }).Count -gt 0)) {
        $concurrencyNote = 'a discarded concurrent candidate tripped the secret scanner; its work was destroyed with its worktree (never committed or merged). The selected winner is clean.'
    }
    foreach ($cand in $bon.Candidates) {
        if ($cand.Worktree -and ($cand.Worktree -ne $wt)) {
            git -C $Repo worktree remove $cand.Worktree --force 2>&1 | Out-Null
            if ($cand.Branch) { git -C $Repo branch -D $cand.Branch 2>&1 | Out-Null }
        }
    }
    if ((Test-Path $wtOrig) -and ($wtOrig -ne $wt)) {
        git -C $Repo worktree remove $wtOrig --force 2>&1 | Out-Null
        git -C $Repo branch -D $brOrig 2>&1 | Out-Null   # the seed-only holder branch (an ancestor of the winner)
    }
    git -C $Repo worktree prune 2>&1 | Out-Null
}
if (-not $sel) {
    # Defensive: nothing generated (N<1 -- never in practice). Treat as a no-op build.
    $sel = @{ VerifyResult='none'; TestResult='none'; HasChanges=$false; TimedOut=$false; SecretBlocked=$false;
              SHA=''; Run=@{ ExitCode=$null; TimedOut=$false; Capped=$false; CappedReason='' }; Secret=@{ status='clean'; detail='' };
              Anomaly=@{ Anomalies=@(); LoopSuspected=$false }; BuildAttempts=0; TestError=''; VerifyDetail=''; VerifyError=''; AgentLog=($Report -replace '\.txt$', '.agent.log') }
}
if (-not $secretStop -and $sel.SHA) {
    $__head = "$(git -C $wt rev-parse HEAD 2>$null)".Trim()
    if ($__head -ne $sel.SHA) {
        git -C $wt reset --hard $sel.SHA 2>&1 | Out-Null   # restore the selected candidate (reflog-reachable)
        git -C $wt clean -fd 2>&1 | Out-Null
    }
}
if ($bon.Count -gt 1) {
    $__how = if ($bon.WinnerFound) { "candidate $($bon.SelectedIndex + 1) passed the gate" } else { "no candidate passed; kept the best of $($bon.Count) by gate rank" }
    Write-Host "  Best-of-N: $($bon.Count) candidate(s) -> $__how." -ForegroundColor Cyan
}
# Hydrate the downstream gate vars from the SELECTED candidate (the review loop + merge + report read these).
$run = $sel.Run
$buildExit = $run.ExitCode
$buildAttempt = $sel.BuildAttempts
$agentTimedOut = [bool]$sel.TimedOut
$anomaly = $sel.Anomaly
$secret = $sel.Secret
$secretBlocked = [bool]$sel.SecretBlocked
$hasChanges = [bool]$sel.HasChanges
$testResult = $sel.TestResult
$verifyResult = $sel.VerifyResult
$verifyDetail = $sel.VerifyDetail
$AgentLog = $sel.AgentLog

# ---- [4/5] REVIEW + bounded review-FEEDBACK (the FROZEN review side; #687/#689). Only runs when the
# gates are NOT both green (Test-ShouldRunReview) -- e.g. a build-only dotnet/WinUI surface with no test
# runner, where the review verdict genuinely decides the merge. A FIX FIRST feeds the findings back for a
# bounded number of fix passes (each KEEPS the selected candidate's code + refines it -- NOT a fresh
# sample; review precision is deliberately left as the cheap signal it is). Green-gated work skips review
# entirely (the deterministic gate already decided). ----
$verdict = 'UNCLEAR'; $reviewTail = ''
if ($hasChanges -and ($verifyResult -eq 'pass') -and ($testResult -eq 'pass')) {
    Write-Host "[4/5] Review SKIPPED - deterministic gates are GREEN (build + tests + verify pass); the gate decides the merge and the cross-model critic reviews post-merge." -ForegroundColor DarkGray
}
while ($hasChanges -and -not $dispatchCancelled -and (Test-ShouldRunReview -HasChanges $hasChanges -VerifyResult $verifyResult -TestResult $testResult)) {   # #771: a stopped run skips review-FIX (no more agent churn)
    Write-Host "[4/5] Review agent is judging the changes (max $MaxReviewMinutes min)..." -ForegroundColor Cyan
    $ReviewLog = $Report -replace '\.txt$', '.review.log'
    # #694: gather the diff IN POWERSHELL and embed it in the prompt (the exact critic-run.ps1
    # posture) so the review agent needs no git/bash -- its read-only contract is then ENFORCED
    # (bash: deny in review.md), not merely requested. Live incident (run 20260627-083757-bd):
    # the old prompt told the reviewer to run `git diff` itself, which required bash, and a
    # bash-capable agent mutated the worktree DURING the "read-only" review (namespace edit +
    # an untracked Tests/ dir), leaving an un-buildable parked tree over a buildable commit.
    # Re-gathered EVERY pass: a review-FIX lap changes the tree, so the diff must be fresh.
    $revRange = Resolve-CriticRange -Repo $wt -Base $BaseBranch
    $revStat  = if ($revRange) { (git -C $wt diff $revRange --stat 2>$null) -join "`n" } else { '' }
    $revDiff  = if ($revRange) { (git -C $wt diff $revRange 2>$null) -join "`n" } else { '' }
    $MaxRevDiffChars = 8000
    if ($revDiff -and $revDiff.Length -gt $MaxRevDiffChars) {
        $revDiff = $revDiff.Substring(0, $MaxRevDiffChars) +
            "`n[diff truncated at $MaxRevDiffChars chars -- use the Read tool on specific files above for full context]"
    }
    if (-not $revStat) { $revStat = '(no stat output -- git may not be on PATH or branch not found)' }
    if (-not $revDiff) { $revDiff = '(no diff output)' }
    $revPrompt = 'Review the changes this branch makes. The diff is provided below; do NOT run any command.' +
        "`n`nCHANGED FILES:`n" + $revStat + "`n`nDIFF:`n" + $revDiff +
        "`n`nApply your protocol. If you need full-file context, use the Read tool on the paths in the diff headers. " +
        "Your reply MUST end with one final line that is exactly 'VERDICT: MERGE' or 'VERDICT: FIX FIRST' and nothing after it."
    # #694 FAIL-CLOSED read-only enforcement: review.md's edit/bash:deny is a REQUEST the harness cannot
    # trust alone -- a live config-sync once reverted that very deny (2026-07-09), and the incident's
    # mutation came from OUTSIDE the agent's own tool calls anyway. So snapshot the worktree digest around
    # the review leg and REFUSE to trust a verdict from a leg that MOVED it: a "read-only" reviewer that
    # changed the tree corrupted the candidate it judged (run 20260627-083757-bd left an un-buildable
    # Calculator.cs over a buildable commit). This guard is independent of review.md and cannot be
    # reverted by a config sync. The fix pass legitimately mutates, so the window is JUST this call.
    # #694 follow-up -- QUIESCE the coder leg before snapshotting the tree for review. Invoke-AgentRun now
    # reaps each leg's process tree on exit, but PROVE the tree stopped moving (a straggling child's late
    # flush is what tripped the guard on an HONEST build -- run 20260710-152121: a trailing-newline normalize
    # of Calculator.cs landed during the read-only review) and DISCARD any post-commit stray write so the
    # reviewed tree is exactly the committed candidate. Iteration 1 (fresh off the best-of-N selection reset)
    # is a no-op; a later iteration settles + cleans the preceding review-FIX coder leg. The discard is
    # guarded by -not $secretBlocked so a deliberately-preserved secret-blocked tree is NEVER wiped (that
    # path yields hasChanges=false and does not reach here anyway -- belt over suspenders).
    $qz = Wait-WorktreeQuiesced -Repo $wt
    if (-not $secretBlocked) {
        $strayed = Restore-WorktreeToHead -Repo $wt
        if ($strayed.Count -gt 0) {
            Write-Host "  QUIESCE (#694): discarded $($strayed.Count) post-leg stray worktree change(s) before review (tooling flush; tree restored to the committed candidate)." -ForegroundColor DarkYellow
            Add-Content -Path $Report -Value ("QUIESCE (#694): discarded post-coder-leg stray write(s) so the reviewed tree == the committed candidate: " + ((@($strayed) | Select-Object -First 8) -join '; ')) -ErrorAction SilentlyContinue
        }
    }
    if (-not $qz.Settled) {
        Write-Host "  QUIESCE (#694): worktree did not settle within the barrier window ($($qz.WaitedMs)ms) -- a straggling child may still be writing; the #694 digest guard remains the backstop." -ForegroundColor Yellow
    }
    $preReviewDigest = Get-WorktreeDigest -Repo $wt
    $rv = Invoke-AgentRun -WorkDir $wt -Model $Model -Agent 'review' -LogPath $ReviewLog -TimeoutSec ($MaxReviewMinutes * 60) -IdleTimeoutSec $IdleTimeoutSec `
          -Prompt $revPrompt
    if (Test-ReviewLegMutated -Before $preReviewDigest -After (Get-WorktreeDigest -Repo $wt)) {
        Write-Host "  FAIL-CLOSED (#694): the READ-ONLY review leg MUTATED the worktree ($wt). The reviewer is a SIGNAL, never an actor; a tree that changed under review corrupts the candidate it judged. Forcing FIX FIRST and parking the branch -- NO auto-merge. (incident 20260627-083757-bd)" -ForegroundColor Red
        Add-Content -Path $Report -Value "REVIEW-MUTATION (#694): the read-only review leg changed the worktree; verdict forced to FIX FIRST, branch parked for the operator." -ErrorAction SilentlyContinue
        $verdict = 'FIX FIRST'; $everFixFirst = $true
        break
    }
    $review = if (Test-Path $ReviewLog) { Get-Content $ReviewLog -Raw } else { '' }
    $reviewTail = (($review -split "`r?`n") | Where-Object { $_ } | Select-Object -Last 15) -join "`n"
    $reviewFindings = (($review -split "`r?`n") | Where-Object { $_ -and $_ -notmatch '(?im)^\s*VERDICT:\s*(MERGE|FIX FIRST)' } | Select-Object -Last 60) -join "`n"
    $vm = [regex]::Matches($review, '(?im)VERDICT:\s*(MERGE|FIX FIRST)')
    if ($vm.Count -gt 0) { $verdict = $vm[$vm.Count - 1].Groups[1].Value.ToUpper() }
    elseif ($reviewTail -match 'FIX FIRST') { $verdict = 'FIX FIRST' }
    elseif ($reviewTail -match '\bMERGE\b') { $verdict = 'MERGE' }
    if ($rv.TimedOut) { $verdict = 'UNCLEAR'; $reviewTail += "`n(review agent timed out)" }
    if ($verdict -ne 'FIX FIRST') { break }            # MERGE / UNCLEAR -> stop reviewing; the merge gate decides
    $everFixFirst = $true
    if ($reviewPass -ge $MaxReviewPasses) { break }    # review budget spent -> park with the findings
    $reviewPass++
    Write-Host "  Review said FIX FIRST; feeding the findings back so the coder FIXES it (review pass $reviewPass/$MaxReviewPasses)..." -ForegroundColor Yellow
    $fixLog = $Report -replace '\.txt$', ".review-fix$reviewPass.agent.log"
    $btv = & $BuildTestVerify (Add-ReviewFeedback -Prompt $Prompt -ReviewConcerns $reviewFindings) $fixLog $false   # KEEP the code; refine (no reset)
    # Re-hydrate from the refined attempt so the merge decision matches what is on disk.
    $run = $btv.Run; $buildExit = $run.ExitCode; $buildAttempt = $btv.BuildAttempts; $agentTimedOut = [bool]$btv.Run.TimedOut
    $anomaly = $btv.Anomaly; $secret = $btv.Secret; $secretBlocked = [bool]$btv.SecretBlocked
    $hasChanges = [bool]$btv.HasChanges; $testResult = $btv.TestResult; $verifyResult = $btv.VerifyResult
    $verifyDetail = $btv.VerifyDetail; $AgentLog = $btv.LogPath
    if ($secretBlocked -or $agentTimedOut) { break }   # terminal: park (never refine past a secret/timeout)
}

# A FIX FIRST verdict is STICKY: once flagged, a later UNCLEAR / timed-out re-review must NOT let the
# dotnet build-only-gate auto-merge it. Keep it FIX FIRST so Test-ShouldMerge parks it.
if ($everFixFirst -and $verdict -ne 'MERGE') { $verdict = 'FIX FIRST' }

# ---- [5/5] Act on the verdicts ----
# The merge decision is the pure, unit-tested Test-ShouldMerge (fleet-lib.ps1): security/anomaly/build
# gates block everything; an explicit reviewer MERGE merges; and a build-only ecosystem (dotnet/WinUI,
# no test runner, reviewer can't launch the GUI) with a STRICTLY-passing verify gate merges an
# inconclusive (UNCLEAR) review - never an explicit FIX FIRST, never python/node. (#670 FIX C)
$merged = $false
$mergeDecision = Test-ShouldMerge -HasChanges $hasChanges -SecretBlocked $secretBlocked `
    -AgentTimedOut $agentTimedOut -LoopSuspected $anomaly.LoopSuspected `
    -TestResult $testResult -VerifyResult $verifyResult -Verdict $verdict `
    -Ecosystems (Get-ProjectEcosystem $wt)
if ($mergeDecision.Merge -and $dispatchCancelled) {
    # #771: a cancelled run never auto-merges. This only bites the build-only-ecosystem UNCLEAR-merge edge
    # (a verify=pass partial whose review we deliberately skipped on the stop); a real green winner cannot be
    # cancelled (best-of-N breaks on the first green before any cancel), so no completed work is lost here.
    Write-Host "  STOP: skipping the auto-merge -- this run was cancelled; parking the branch for the operator (#771)." -ForegroundColor Yellow
}
if ($mergeDecision.Merge -and -not $dispatchCancelled) {
    git -C $Repo merge $branch --no-edit 2>&1 | Out-Null
    if ($LASTEXITCODE -eq 0) {
        $merged = $true
        # NOTE: the worktree removal is DEFERRED to AFTER the optional post-merge VLM
        # design critique below, because the critique captures the BUILT App.exe that
        # lives in $wt\bin\ (the build artifacts are gitignored and did NOT come across
        # the merge). When the critique is dormant (the common case) this is removed
        # immediately just like before. The branch delete is likewise deferred.
    }
}
$mergedVia = if ($merged) { $mergeDecision.Via } else { '' }

# ============================================================================
# [6/6] VLM DESIGN CRITIQUE — DORMANT, post-merge, fail-soft, NON-BLOCKING (UC-010 Phase 3)
# ============================================================================
# A POST-MERGE design ENHANCEMENT, never a gate. The merge already happened above; this
# block can NEVER change $merged, $mergedVia, or the task's RESULT. It is double-dormant:
#   GATE 1 (master opt-in):  -EnableVisualCritique must be passed (default OFF).
#   GATE 2 (per-task signal): $VisualCriteriaJson must be present AND not ''/'[]'/whitespace.
# For every non-visual task (the common case) BOTH gates are closed and this is a complete
# no-op — zero behavior change to today's flow.
#
# SHIPPED VARIANT: AUTO-FIX (v2). The loop runs build -> screenshot -> VLM critique -> feed the
# feedback back to the coder -> rebuild -> re-critique, bounded by MaxIter, stopping on the VLM's
# PASS, on the cap, or on any fail-soft abort. The -RebuildCallback ($rebuildAutoFix below) runs
# ONE fail-soft FIX pass per flagged iteration on the still-alive worktree and RE-MERGES the FIX
# into the base branch. Each FIX is NON-DESTRUCTIVE: a coder no-op, a verify FAIL, or a re-merge
# conflict ABORTS that iteration and keeps the LAST GOOD merged version (main is never broken /
# half-merged). The feedback + each FIX outcome is SURFACED into the report's CRITIQUE section.
#
# MODEL NOTE (documented, NOT implemented here): during a real dispatch the 14B is already
# swapped OUT and the 30B (~18 GB) is resident; the VLM (Qwen3-VL, ~5 GB) co-resides for the
# critique (~23 GB < 31.323 GB ceiling) with NO OVMS swap. The asset-GENERATION phase
# (Playground, which needs the 30B swapped out — the measured 32.5 GB breach) is OUT OF SCOPE
# here and stays a separate OVMS-gated go-live step. This block performs no OVMS stop/swap.
$critiqueSummary = ''
# Capture EVERYTHING the hook needs from the real params/vars NOW, into hook-local copies.
# This is load-bearing: dot-sourcing critique-loop.ps1 below binds ITS param block in THIS
# scope, which would overwrite $Goal / $VisualCriteriaJson / $AppDir. We never read those
# names after the dot-source — only these pre-captured copies + $wt / $BlarAiRepo (not clobbered).
$_visualTrimmed = "$VisualCriteriaJson".Trim()
$_critiqueGoal  = if ($Goal) { $Goal } else { $OrigPrompt }
$_critiqueWork  = Join-Path $ReportDir "critique-$repoName-$Task"
$_blarAiRepo    = $BlarAiRepo
# Master opt-in: the -EnableVisualCritique switch OR the BLARAI_ENABLE_VISUAL_CRITIQUE env var
# (=1/true/yes/on). The env var is the ONLY way the /dispatch -> swap-driver -> run-fleet ->
# new-agent-task chain can turn the loop on (the chain cannot pass a -switch); it propagates
# because the detached swap-driver inherits BlarAI's environment. Still double-gated by the
# per-task visual_criteria_json below, so a non-visual task is a no-op even with this on.
$_critiqueSentinel = Join-Path (Split-Path $PSScriptRoot -Parent) 'state\enable-visual-critique.flag'
$_enableCritique = $EnableVisualCritique -or `
    ("$env:BLARAI_ENABLE_VISUAL_CRITIQUE" -match '^(1|true|yes|on)$') -or `
    (Test-Path $_critiqueSentinel)
$_critiqueActive = $merged -and $_enableCritique -and `
    $_visualTrimmed -and ($_visualTrimmed -ne '[]') -and (Test-Path $wt)
if ($_critiqueActive) {
    try {
        Write-Host "[6/6] VLM design critique (post-merge, non-blocking)..." -ForegroundColor Cyan
        # Load the two functions. The throwaway args satisfy the script's Mandatory params; the
        # script's own dot-source guard ($MyInvocation.InvocationName -eq '.') skips the one-pass body.
        . "$PSScriptRoot\critique-loop.ps1" -AppDir 'x' -Goal 'x' -VisualCriteriaJson '[]' -BlarAiRepo 'x' 2>$null
        $critiqueGoal = $_critiqueGoal
        $critiqueWork = $_critiqueWork
        # AUTO-FIX rebuild callback (v2). For each VLM-flagged iteration the loop invokes this
        # with the concrete $Feedback; it runs ONE fail-soft FIX pass ON THE STILL-ALIVE worktree
        # ($wt — the deferred-removal below keeps it alive across the loop) and RE-MERGES the FIX
        # into the base branch, then returns $wt so the loop re-captures + re-critiques the rebuilt
        # app. The POLICY (run coder -> re-verify -> commit -> re-merge, with fail-soft aborts) lives
        # in Invoke-VisualFixPass (fleet-lib.ps1, unit-tested); here we inject the REAL mechanisms,
        # reusing the EXISTING build machinery ([1/5] Invoke-BuildWithRetry/Invoke-AgentRun, [3/5]
        # verify-project.ps1, the same secret-scan + commit) — none of it re-implemented.
        #
        # SAFETY: this runs AFTER the first successful merge — the app is already shipped. A FIX that
        # the coder no-op's, that fails verify, or whose re-merge conflicts is ABORTED and the LAST
        # GOOD merged version is kept (never main broken / half-merged). $fixCount tracks applied
        # FIXes for the report; $fixNotes accumulates each iteration's outcome.
        $script:fixCount = 0
        $script:fixNotes = New-Object System.Collections.ArrayList
        $rebuildAutoFix = {
            param($Feedback, $AppDir)
            $fixLog = $AgentLog -replace '\.agent\.log$', ".fix$($script:fixCount + 1).agent.log"
            $fixPrompt = Add-VisualFeedback -Prompt $OrigPrompt -Feedback $Feedback
            $res = Invoke-VisualFixPass `
                -RunCoder {
                    # Reuse the EXACT [1/5] machinery: Invoke-BuildWithRetry wrapping Invoke-AgentRun,
                    # with the same no-op retry + clean-reset-between-retries semantics.
                    $b = Invoke-BuildWithRetry -MaxBuildAttempts $MaxBuildAttempts `
                        -ResetWorktree { git -C $wt reset --hard HEAD 2>&1 | Out-Null; git -C $wt clean -fd 2>&1 | Out-Null } `
                        -RunAgent { Invoke-AgentRun -WorkDir $wt -Model $Model -Prompt $fixPrompt -LogPath $fixLog -TimeoutSec ($MaxRunMinutes * 60) -JsonStepCap } `
                        -ProducedChanges { (@(git -C $wt status --porcelain 2>$null).Count -gt 0) -or (([int](git -C $wt rev-list --count "$branch..HEAD" 2>$null)) -gt 0) }
                    $b.Run
                } `
                -CommitFix {
                    # Stage + secret-scan + commit on the agent branch (reuse the same secret-scan.ps1).
                    # A detected secret means NO commit (return $false -> the FIX aborts, prior kept).
                    git -C $wt add -A 2>&1 | Out-Null
                    $sec = & "$PSScriptRoot\secret-scan.ps1" -Repo $wt
                    if ($sec -and $sec.status -eq 'blocked') { git -C $wt reset 2>&1 | Out-Null; return $false }
                    $before = (git -C $wt rev-parse HEAD 2>$null)
                    git -C $wt -c user.email='agent@local' -c user.name='coding-agent' commit -m "agent: $Task (visual fix $($script:fixCount + 1))" 2>&1 | Out-Null
                    $after = (git -C $wt rev-parse HEAD 2>$null)
                    return ("$before".Trim() -ne "$after".Trim())   # a NEW commit landed?
                } `
                -Verify {
                    # Reuse the EXACT [3/5] gate: verify-project.ps1 -> overall pass|fail|none.
                    try {
                        $__vp = @{}
                        if ($Surface) { $__vp.Surface = $Surface }
                        if ($LanguageHint) { $__vp.LanguageHint = $LanguageHint }
                        $vo = & "$PSScriptRoot\verify-project.ps1" -Path $wt -BaseBranch $BaseBranch -Json -TimeoutSec 600 @__vp | ConvertFrom-Json
                        return "$($vo.overall)"
                    } catch { return 'none' }   # gate could not run -> 'none' (non-blocking), not a 'fail'
                } `
                -ReMerge {
                    # Bring ONLY the new FIX commit into the base branch. The branch's first merge
                    # already landed; the branch is now ahead by the FIX commit(s). A clean merge /
                    # fast-forward returns $true; a conflict or error is aborted (merge --abort) and
                    # returns $false so the prior merged version is kept untouched.
                    git -C $Repo merge $branch --no-edit 2>&1 | Out-Null
                    if ($LASTEXITCODE -eq 0) { return $true }
                    git -C $Repo merge --abort 2>&1 | Out-Null   # leave main exactly as it was
                    return $false
                }
            $script:fixCount++
            if ($res.Applied) {
                [void]$script:fixNotes.Add("FIX #$($script:fixCount): applied + re-merged (verify=$($res.Verify)).")
                Write-Host "  [6/6] visual FIX #$($script:fixCount) applied + re-merged." -ForegroundColor Green
            } else {
                [void]$script:fixNotes.Add("FIX #$($script:fixCount): $($res.Reason)")
                Write-Host "  [6/6] visual FIX #$($script:fixCount) not applied: $($res.Reason)" -ForegroundColor Yellow
            }
            return $AppDir   # always $wt; the loop re-captures the (possibly) rebuilt app
        }
        # A PLAIN scriptblock is REQUIRED here — NOT .GetNewClosure(). GetNewClosure() rebinds the
        # block's FUNCTION lookup to GLOBAL, so when new-agent-task.ps1 runs nested (run-fleet ->
        # & new-agent-task.ps1, two levels deep) the dot-sourced fleet-lib functions it calls
        # (Add-VisualFeedback / Invoke-VisualFixPass / Invoke-BuildWithRetry / Invoke-AgentRun) become
        # invisible -> "is not recognized" at runtime. A plain block binds to THIS script scope, which
        # HAS them. The captured vars ($wt / $OrigPrompt / $AgentLog / $Model / ...) are script-scope
        # and stable between this definition and the immediate Invoke-CritiqueLoop call below, so
        # freezing is unnecessary. (Caught live 2026-06-25; the unit tests passed because their mock
        # callbacks were defined in-scope and one level deep, never crossing this boundary.)
        $loop = Invoke-CritiqueLoop -AppDir $wt -Goal $critiqueGoal `
            -VisualCriteriaJson $_visualTrimmed -BlarAiRepo $_blarAiRepo `
            -MaxIter 3 -WorkDir $critiqueWork -RebuildCallback $rebuildAutoFix
        $fr = $loop.FinalResult
        $fixTail = if ($script:fixNotes.Count) { "`n" + (($script:fixNotes) -join "`n") } else { '' }
        if ($null -eq $fr) {
            $critiqueSummary = "VLM critique ran but returned no result (treated as no-op).$fixTail"
        } elseif ($fr.CaptureTier -eq 'structural') {
            $critiqueSummary = "No pixel capture available (structural floor); visual critique skipped. $($fr.Feedback)$fixTail"
        } elseif (-not $fr.Ok) {
            $critiqueSummary = "VLM critique unavailable / failed (non-blocking): $($fr.Feedback)$fixTail"
        } elseif ($fr.NeedsWork) {
            $critiqueSummary = "VLM still suggests visual improvements after $($script:fixCount) auto-fix pass(es) (signal only — your eyeball is the verdict):`n$($fr.Feedback)$fixTail"
        } else {
            $critiqueSummary = "VLM critique: visual criteria look satisfied$(if ($script:fixCount) { " after $($script:fixCount) auto-fix pass(es)" }). $($fr.Feedback)$fixTail"
        }
        Write-Host "  critique: $($critiqueSummary -split "`n" | Select-Object -First 1)" -ForegroundColor DarkGray
    } catch {
        # The merge already happened; a critique error MUST NOT fail the task. Log + continue.
        $critiqueSummary = "VLM critique hook errored (non-blocking, task result unchanged): $($_.Exception.Message)"
        Write-Host "  critique hook error (ignored): $($_.Exception.Message)" -ForegroundColor Yellow
    }
}

# Deferred worktree/branch cleanup: remove the merged worktree now that the (optional)
# critique has finished capturing the built App.exe from it. Idempotent + best-effort —
# identical to the pre-hook behavior for the common (no-critique) path.
if ($merged) {
    git -C $Repo worktree remove $wt --force 2>&1 | Out-Null
    git -C $Repo branch -d $branch 2>&1 | Out-Null
}

$summary = @"
TASK: $Task  ($repoName)
ASKED: $OrigPrompt
BUILD: $(if ($agentTimedOut) { Get-TimeoutStopText -Reason "$($run.TimeoutReason)" -MaxRunMinutes $MaxRunMinutes -IdleTimeoutSec $IdleTimeoutSec } elseif ($run.Capped) {"completed (bounded - $($run.CappedReason))"} elseif ($buildExit -eq 0) {'completed'} else {"agent exited with code $buildExit"})$(if ($buildAttempt -gt 1) { " (after $buildAttempt build attempts; the local model no-op'd the earlier ones)" })
TRANSCRIPT: $AgentLog
CHANGES: $(if ($hasChanges) {'yes'} else {'none made'})
TESTS: $testResult
VERIFY: $verifyResult$(if ($verifyResult -eq 'fail') { ' (build/lint/typecheck FAILED - blocked the merge)' })
SECRETS: $(if ($secretBlocked) { "BLOCKED - $($secret.detail)" } elseif ($secret.status -eq 'unavailable') { 'scan skipped (gitleaks not installed)' } else { 'clean' })
ANOMALIES: $(if ($anomaly.Anomalies.Count) { ($anomaly.Anomalies -join '; ') } else { 'none' })$(if ($concurrencyNote) { "`nNOTE (concurrency): $concurrencyNote" })$(if ($dispatchCancelled) { "`nSTOPPED: a /dispatch stop was observed mid-run; best-of-N parked after the current candidate and did not start fresh candidates or auto-merge (#771)." })
REVIEW VERDICT: $verdict$(if ($critiqueSummary) { "`nVISUAL CRITIQUE (post-merge design signal — NOT a gate, your eyeball is the verdict):`n  $($critiqueSummary -replace "`n", "`n  ")" })
RESULT: $(if ($secretBlocked) {"BLOCKED: a potential secret was detected, so nothing was committed or merged. Your changes are left UNCOMMITTED in $wt for review."} elseif ($merged) {"MERGED into your project - just open the app and try it.$(if ($mergedVia -eq 'build-only-gate') { ' (Merged via the build-only gate: the build passed cleanly but the AI code review was inconclusive - please launch and eyeball it.)' })"} elseif (-not $hasChanges) {'Nothing to merge.'} else {"NOT merged. The work is parked safely on branch '$branch' (workspace: $wt)."})
$(if (-not $merged -and $hasChanges) {@"

WHAT TO DO (no git knowledge needed):
  - Read the review findings below; then re-run this task with a sharper prompt, or
  - ask your assistant (Claude) to look at branch '$branch' in $repoName.

VERIFY DETAIL:
$verifyDetail

REVIEW FINDINGS (last lines):
$reviewTail
"@})
"@
Set-Content $Report $summary
Write-Host ""; Write-Host $summary
Write-Host "Report saved: $Report" -ForegroundColor Cyan
